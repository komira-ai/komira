# =============================================================================
# multi_key_probe_op -- the composite-key STREAMING join probe operator
# (`MultiKeyJoinProbeOp`, a `MorselOperatorImpl`): INNER.
# =============================================================================
#
# One probe morsel at a time against a composite hash table built beforehand
# from the build side and shared by every worker. Per morsel it makes the
# three calls the whole-batch INNER join makes, restricted to the morsel:
#
#   extract_join_key_columns_serial(morsel, probe keys)
#     -> MultiKeyHashJoinBuilder.probe_inner_into
#     -> assemble_join_result(morsel, build batch, ...)
#
# so the union of the per-morsel outputs is the whole-batch join's rows (the
# order across morsels differs). The number of keys and their types are
# runtime values: one operator type serves every key list the composite
# builder supports, and its float keys follow the float model (NaN equals
# NaN, -0.0 equals +0.0). Each morsel's whole output is emitted in one batch
# (NEED_MORE_INPUT).
#
# JOIN-KEY CSE (`key_cse`, on unless the constructor says otherwise). On every
# INNER output row the build key equals the probe key, so the output's build
# key columns may share the probe key columns instead of gathering their own
# copies. `komira_join_assembly.join_key_cse_aliases` proves which columns
# may; it is asked once per operator, on the first morsel, and the probe-side
# facts that proof rests on (each key's column index, type and validity
# bitmap, no NULL, the probe column count) are re-checked on every morsel,
# because a later morsel can differ and a share applied to it would emit the
# wrong column with the right row count. A morsel that differs is gathered.
# A refusal on the first morsel is kept for the operator's life.
#
# MIXED KEY TYPES. An INT32 or INT64 key paired with a FLOAT64 key compares
# as FLOAT64, as DuckDB casts the integer to DOUBLE: a morsel's integer probe
# key is rendered as FLOAT64 when its build key is FLOAT64 or the index holds
# the integer build key as FLOAT64 (`build_as_float64`); a FLOAT64 probe key
# against a build key the index holds as an integer raises, and so does a
# STRING key against a numeric key.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer
from std.time import perf_counter_ns

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_plan_ir.logical_plan import JOIN_INNER
from komira_exec_types.exec_result import ExecResult, NEED_MORE_INPUT
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_metrics.metrics_set import (
    MetricsSet,
    MetricsSnapshot,
    new_owned_metrics_set,
)
from komira_join_assembly.compiler_join_assembly import assemble_join_result
from komira_join_assembly.join_key_cse import (
    JoinKeyAliasMap,
    join_key_cse_aliases,
)

from .join_key_extract import (
    extract_join_key_columns_serial,
    join_key_is_integer,
    join_key_pairs_as_float64,
)
from .join_multi_key_builder import MultiKeyHashJoinBuilder


@always_inline
def _probe_col_index(imm batch: RecordBatch, imm name: String) -> Int:
    """Index of the FIRST column named `name`, or -1.

    The first match, as `Schema.column_index` resolves the column the
    extraction keys on and as `join_key_cse_aliases` resolves the one it
    aliases; all three must agree on a schema that repeats a name."""
    for i in range(batch.schema.num_columns()):
        if batch.schema.field_name(i) == name:
            return i
    return -1


struct MultiKeyJoinProbeOp(MorselOperatorImpl):
    """Composite-key streaming INNER probe; see the module header.

    `_index` and `_build_batch` are shared by every worker's operator and
    only read. `_probe_key_names[k]` pairs with `_build_key_names[k]`: the
    composite hash mixes keys by position, so the order is the build's.
    `_output_schema` is the probe columns then the build columns.
    """

    var _index: ArcPointer[MultiKeyHashJoinBuilder]
    var _build_batch: ArcPointer[RecordBatch]
    var _probe_key_names: List[String]
    var _build_key_names: List[String]
    var _output_schema: ArcPointer[Schema]
    var _join_type: UInt8
    var _metrics: OwnedPointer[MetricsSet]
    var _cse_gate_on: Bool
    # 0 = not yet asked, 1 = `_cse_map` holds a proved map, -1 = refused.
    var _cse_state: Int
    var _cse_map: Optional[JoinKeyAliasMap]
    var _cse_probe_ncols: Int
    var _cse_probe_key_idx: List[Int]
    var _cse_probe_key_type: List[ArrowType]
    var _cse_probe_key_has_bitmap: List[Bool]
    var _build_as_float64: List[Bool]

    def __init__(
        out self,
        var index: ArcPointer[MultiKeyHashJoinBuilder],
        var build_batch: ArcPointer[RecordBatch],
        var probe_key_names: List[String],
        var build_key_names: List[String],
        var output_schema: ArcPointer[Schema],
        join_type: UInt8 = JOIN_INNER,
        key_cse: Bool = True,
        build_as_float64: List[Bool] = List[Bool](),
    ) raises:
        """An operator probing `index` (built from `build_batch`'s
        `build_key_names` columns) with each morsel's `probe_key_names`
        columns.

        Args:
            index: The shared composite hash table.
            build_batch: The shared build side, gathered for the output.
            probe_key_names: Probe key column names, in the build keys' order.
            build_key_names: Build key column names, paired by position with
                `probe_key_names`. Required: the JOIN-KEY CSE proves its
                aliases from these.
            output_schema: The shared output schema, probe then build columns.
            join_type: JOIN_INNER; any other type raises.
            key_cse: Whether the output's build key columns may share the
                probe key columns (see the header).
            build_as_float64: Per key, True iff `index` was built with that
                integer build key rendered as FLOAT64
                (`extract_join_key_columns_serial`'s `as_float64`, from
                `join_key_pairs_as_float64`). Empty: none was.
        """
        if join_type != JOIN_INNER:
            raise Error(
                "MultiKeyJoinProbeOp: only JOIN_INNER is supported (got"
                " join_type=" + String(Int(join_type)) + ")"
            )
        self._index = index^
        self._build_batch = build_batch^
        self._probe_key_names = probe_key_names^
        self._build_key_names = build_key_names^
        self._output_schema = output_schema^
        self._join_type = join_type
        var ms_ptr = new_owned_metrics_set()
        _ = ms_ptr[].register_counter["rows_processed"]()
        _ = ms_ptr[].register_counter["rows_emitted"]()
        _ = ms_ptr[].register_time["elapsed_compute"]()
        self._metrics = ms_ptr^
        self._cse_gate_on = key_cse
        self._cse_state = 0
        self._cse_map = Optional[JoinKeyAliasMap](None)
        self._cse_probe_ncols = -1
        self._cse_probe_key_idx = List[Int]()
        self._cse_probe_key_type = List[ArrowType]()
        self._cse_probe_key_has_bitmap = List[Bool]()
        self._build_as_float64 = build_as_float64.copy()

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Replace `morsel.batch` with its INNER join output against the
        build side; NEED_MORE_INPUT. An empty morsel is left as it is."""
        var t0 = perf_counter_ns()
        var rows_in = morsel.batch.num_rows()
        if rows_in == 0:
            self._record_metrics(0, 0, t0)
            return ExecResult(NEED_MORE_INPUT)

        # Serial: this runs on a pool worker. A plain STRING key comes back
        # sharing the morsel's buffers; they are reference-counted and
        # read-only, so replacing `morsel.batch` below cannot disturb them.
        var probe_keys = extract_join_key_columns_serial(
            morsel.batch, self._probe_key_names,
            self._probe_as_float64(morsel.batch),
        )
        var build_matches = List[Int]()
        var probe_matches = List[Int]()
        self._index[].probe_inner_into(probe_keys, build_matches, probe_matches)
        _ = probe_keys^

        var joined: RecordBatch
        if self._cse_admits_morsel(morsel.batch):
            joined = assemble_join_result(
                morsel.batch,
                self._build_batch[],
                probe_matches^,
                build_matches^,
                self._output_schema[],
                key_alias_of_right=self._cse_map,
            )
        else:
            joined = assemble_join_result(
                morsel.batch,
                self._build_batch[],
                probe_matches^,
                build_matches^,
                self._output_schema[],
            )
        morsel.replace_batch(joined^)
        self._record_metrics(rows_in, morsel.batch.num_rows(), t0)
        return ExecResult(NEED_MORE_INPUT)

    def _probe_as_float64(self, imm probe_batch: RecordBatch) raises -> List[Bool]:
        """Per key, True iff the morsel's integer probe key is rendered as
        FLOAT64: its build key is FLOAT64, or the index holds the integer
        build key as FLOAT64. A FLOAT64 probe key against an integer build key
        the index holds as an integer raises (the index cannot match it), as
        does a STRING key against a numeric key (`join_key_pairs_as_float64`).
        """
        # Only the pairs the operator was told both names of are known.
        var n = min(len(self._probe_key_names), len(self._build_key_names))
        var pnames = List[String](capacity=n)
        var bnames = List[String](capacity=n)
        for k in range(n):
            pnames.append(self._probe_key_names[k])
            bnames.append(self._build_key_names[k])
        var mixed = join_key_pairs_as_float64(
            probe_batch, pnames, self._build_batch[], bnames
        )
        var out = List[Bool](capacity=n)
        for k in range(n):
            var build_f = (
                len(self._build_as_float64) > k and self._build_as_float64[k]
            )
            var probe_int = join_key_is_integer(
                probe_batch, self._probe_key_names[k]
            )
            if mixed[k] and not probe_int and not build_f:
                raise Error(
                    "MultiKeyJoinProbeOp: the FLOAT64 probe key '"
                    + self._probe_key_names[k] + "' is paired with the"
                    " integer build key '" + self._build_key_names[k]
                    + "', but the index holds that key as an integer; build"
                    " it with the key as FLOAT64 and pass build_as_float64"
                )
            out.append(probe_int and (mixed[k] or build_f))
        return out^

    def _cse_admits_morsel(mut self, imm probe_batch: RecordBatch) raises -> Bool:
        """True iff this morsel's output may take its build key columns from
        the probe key columns (the header's JOIN-KEY CSE).

        The first call asks `join_key_cse_aliases` and records the probe-side
        facts its proof rests on; every later call re-resolves each key BY
        NAME (the first match, as the extraction does: a schema that repeats
        a key name must alias the column the probe keyed on) and compares the
        facts. A key column with a validity bitmap carrying a NULL never
        shares.
        """
        if not self._cse_gate_on:
            return False
        if self._join_type != JOIN_INNER:
            return False
        if self._cse_state < 0:
            return False

        var n_keys = len(self._probe_key_names)
        if self._cse_state == 0:
            if n_keys == 0 or len(self._build_key_names) != n_keys:
                self._cse_state = -1
                return False
            var idx = List[Int](capacity=n_keys)
            for k in range(n_keys):
                var i = _probe_col_index(probe_batch, self._probe_key_names[k])
                if i < 0:
                    self._cse_state = -1
                    return False
                idx.append(i)
            var m = join_key_cse_aliases(
                probe_batch,
                self._build_batch[],
                self._probe_key_names.copy(),
                self._build_key_names.copy(),
                self._join_type,
            )
            if len(m) == 0:
                self._cse_state = -1
                return False
            var types = List[ArrowType](capacity=n_keys)
            var bmaps = List[Bool](capacity=n_keys)
            for k in range(n_keys):
                ref pk = probe_batch.column_at(idx[k])
                types.append(pk.arrow_type)
                bmaps.append(pk.has_validity_buffer())
            self._cse_probe_ncols = probe_batch.num_columns()
            self._cse_probe_key_idx = idx^
            self._cse_probe_key_type = types^
            self._cse_probe_key_has_bitmap = bmaps^
            self._cse_map = Optional[JoinKeyAliasMap](m^)
            self._cse_state = 1
            return True

        if probe_batch.num_columns() != self._cse_probe_ncols:
            return False
        if len(self._cse_probe_key_idx) != n_keys:
            return False
        for k in range(n_keys):
            var i = _probe_col_index(probe_batch, self._probe_key_names[k])
            if i != self._cse_probe_key_idx[k]:
                return False
            ref pk = probe_batch.column_at(i)
            if pk.arrow_type != self._cse_probe_key_type[k]:
                return False
            if pk.has_validity_buffer() != self._cse_probe_key_has_bitmap[k]:
                return False
            if pk.has_validity_buffer() and pk.null_count() != 0:
                return False
        return True

    @always_inline
    def _record_metrics(mut self, rows_in: Int, rows_out: Int, t0: Int):
        """Add one call's rows and time to this operator's metrics."""
        self._metrics[].counter["rows_processed"]().inc_in_pipeline(
            Int64(rows_in), worker_id=0
        )
        self._metrics[].counter["rows_emitted"]().inc_in_pipeline(
            Int64(rows_out), worker_id=0
        )
        self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
            Int64(perf_counter_ns() - t0), worker_id=0
        )

    def metrics_snapshot(self) -> MetricsSnapshot:
        """This operator's metrics, reduced (for EXPLAIN ANALYZE)."""
        return self._metrics[].reduce()

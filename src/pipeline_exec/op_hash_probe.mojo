# =============================================================================
# op_hash_probe -- OP_JOIN_PROBE: the equi-join and cross-join probe over the
# rows a build segment published
# =============================================================================
#
# A join is two segments. The build side ends in SINK_HASH_BUILD, which
# collects its rows (a `CollectSink`) and publishes them as one batch. The
# probe side's segment carries an OP_JOIN_PROBE naming that segment
# (`probe_build_seg`). When the probe segment's run begins, the builder takes
# the published build rows and makes one `HashProbeShared`: for an equi-join,
# the composite hash index over the build key columns (`op_join_probe`'s
# `MultiKeyHashJoinBuilder`), built once on the calling thread before any
# worker starts. Each worker then runs its own `HashProbeOp`, which reads that
# index and the build rows and never writes them.
#
# The join type is the probe's view: the probe side is the left input and the
# build side the right one (`lowering` mirrors LEFT and RIGHT when the plan
# builds its left child). Per probe morsel:
#
#   INNER  every pair of a probe row and a build row with equal keys;
#   LEFT   the INNER pairs, and each probe row with no partner once, its build
#          columns NULL;
#   RIGHT  the INNER pairs; every build row that found a partner is marked;
#   FULL   LEFT's rows, and the marks of RIGHT;
#   SEMI   each probe row with at least one partner, once, probe columns only;
#   ANTI   each probe row with no partner (a NULL key has none), probe columns
#          only;
#   CROSS  every pair of a probe row and a build row; the join has no key.
#
# RIGHT and FULL owe the build rows nobody matched. Those are known only once
# every worker has probed every morsel, so they are not emitted by `execute`:
# after the workers of the probe segment join, `run_segment` asks the builder
# for the operator's tail (`HashProbeShared.unmatched_build_rows`), the build
# rows no mark reached, with the probe columns NULL, and pushes it through the
# operators after the probe and into the sink. The marks are one atomic byte
# per build row, shared by the workers; a mark is only ever set, so the tail
# is the same set of rows on every worker count and schedule.
#
# What a worker's probe adds to the index:
#
#   * a morsel that arrives with a selection mask (a filter before the probe)
#     is gathered first; the index reads every row of the batch;
#   * a morsel with no row, or with no row to emit, is dropped
#     (FILTERED_EMPTY);
#   * the output schema is the probe columns, then the build columns, a build
#     name the probe side already uses suffixed `_right`
#     (`build_join_output_schema_outer`); the columns of the side an outer
#     join pads with NULL are nullable on every batch, the tail's included,
#     so every batch of one operator has one schema;
#   * a CROSS morsel whose output would pass `CROSS_CHUNK_ROWS` rows is
#     emitted in chunks of whole probe rows (HAVE_MORE_OUTPUT), each at most
#     that many rows unless one probe row alone has more partners.
#
# Keys pair by position: `probe_left_keys[k]` (the probe side's) with
# `probe_right_keys[k]` (the build side's). Key types are the kernel's: INT64
# and INT32 (compared as integers, so an INT32 key meets an INT64 key),
# FLOAT64 (NaN equals NaN, -0.0 equals +0.0), STRING and string dictionaries;
# any other key type is refused by the kernel, naming the column. A NULL key on
# either side matches nothing.
#
# The kernel stands for a NULL key by one key-slot value, the bits
# 0x7FF8000000000001 read as an INT64. A non-NULL INT64 key equal to that value
# (9,221,120,237,041,090,561) would be taken for NULL and silently matched to
# nothing; such a key is refused instead (`JOIN_KEY_RESERVED`), on the build
# side when the index is made and on the probe side per morsel.
#
# Refused when the shared part is made: an operator that is not OP_JOIN_PROBE,
# a join type the probe has no rule for, a residual, a late-materialization
# column list, the sort-merge algorithm, an equi-join whose key list is empty,
# longer than the kernel takes or of unequal lengths, and a CROSS join that
# names a key. `lowering` never emits any of them.
# =============================================================================

from std.builtin.swap import swap
from std.memory import ArcPointer

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch, Schema
from atomic_alias import AtomicU8
from column_kernels.compiler_helpers import (
    empty_batch_like_schema,
    gather_batch,
    materialize_selection_if_present,
)
from containers.slab import Slab
from exec_types.exec_result import (
    ExecResult,
    FILTERED_EMPTY,
    HAVE_MORE_OUTPUT,
    NEED_MORE_INPUT,
)
from join_assembly.compiler_join_assembly import assemble_join_result
from metrics.metrics_set import MetricsSnapshot
from morsel.morsel import Morsel
from morsel.morsel_operator import MorselOperatorImpl
from op_join_probe.join_key_extract import extract_join_key_columns_serial
from op_join_probe.join_multi_key import MAX_JOIN_KEYS, _NAN_SENTINEL_BITS
from op_join_probe.join_multi_key_builder import MultiKeyHashJoinBuilder
from op_join_probe.join_output_schema import (
    build_join_output_schema,
    build_join_output_schema_outer,
)
from op_join_probe.multi_key_probe_op import MultiKeyJoinProbeOp
from physical_plan.physical_plan import MorselOp, OP_JOIN_PROBE
from plan_ir.logical_plan import (
    JOIN_ALGO_SORT_MERGE,
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_FULL,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
)


comptime JOIN_KEY_RESERVED = "JOIN_KEY_RESERVED"
"""Refusal: an INT64 join key holds the value the join kernel reserves for a
NULL key, so the kernel cannot tell it from NULL."""

comptime CROSS_CHUNK_ROWS = 65536
"""The rows of one CROSS output chunk, unless one probe row alone has more
partners (see the module header)."""


def _keyed_by_int64_storage(t: ArrowType) -> Bool:
    """True for the key types whose key slot is their int64 storage as it
    is."""
    return (
        t == ArrowType.INT64
        or t == ArrowType.DATE64
        or t == ArrowType.TIMESTAMP
        or t == ArrowType.TIMESTAMP_S
        or t == ArrowType.TIMESTAMP_MS
        or t == ArrowType.TIMESTAMP_US
        or t == ArrowType.TIMESTAMP_NS
    )


def refuse_reserved_int64_keys(
    ref batch: RecordBatch, key_names: List[String], side: String
) raises:
    """Raise `JOIN_KEY_RESERVED`, naming the column and the side, when a
    non-NULL row of a key column keyed by its int64 storage (INT64, DATE64 or
    a TIMESTAMP) holds the kernel's NULL key-slot value. Key columns of other
    types cannot hold it and are not read."""
    for k in range(len(key_names)):
        var idx = batch.schema.column_index(key_names[k])
        ref col = batch.column_at(idx)
        if not _keyed_by_int64_storage(col.arrow_type):
            continue
        var values = col.as_primitive[DType.int64]()
        for r in range(batch.num_rows()):
            if values.get(r) == _NAN_SENTINEL_BITS and not col.is_null_at(r):
                raise Error(
                    String(JOIN_KEY_RESERVED)
                    + ": the "
                    + side
                    + " key column '"
                    + key_names[k]
                    + "' holds 9221120237041090561, the value the join"
                    " kernel reserves for a NULL key"
                )


def _same_schema(ref a: Schema, ref b: Schema) -> Bool:
    """True when `a` and `b` name the same columns with the same types, in
    the same order."""
    if a.num_columns() != b.num_columns():
        return False
    for i in range(a.num_columns()):
        if a.field_name(i) != b.field_name(i):
            return False
        if (
            a.field_at_unchecked(i).arrow_type
            != b.field_at_unchecked(i).arrow_type
        ):
            return False
    return True


def _refuse(spec_what: String) -> Error:
    return Error("pipeline_exec: OP_JOIN_PROBE refuses " + spec_what)


def _pads_build(join_type: UInt8) -> Bool:
    """True when the join emits probe rows with NULL build columns."""
    return join_type == JOIN_LEFT or join_type == JOIN_FULL


def _pads_probe(join_type: UInt8) -> Bool:
    """True when the join emits build rows with NULL probe columns: the build
    rows no probe row matched, in the tail."""
    return join_type == JOIN_RIGHT or join_type == JOIN_FULL


def _keeps_probe_only(join_type: UInt8) -> Bool:
    """True for SEMI and ANTI: the output is probe rows, probe columns only."""
    return join_type == JOIN_SEMI or join_type == JOIN_ANTI


def _served_type(join_type: UInt8) -> Bool:
    return (
        join_type == JOIN_INNER
        or join_type == JOIN_LEFT
        or join_type == JOIN_RIGHT
        or join_type == JOIN_FULL
        or join_type == JOIN_SEMI
        or join_type == JOIN_ANTI
        or join_type == JOIN_CROSS
    )


def join_output_schema(
    join_type: UInt8, ref probe_schema: Schema, ref build_schema: Schema
) raises -> Schema:
    """The schema of the rows a probe of `join_type` emits for morsels of
    `probe_schema`: the probe schema for SEMI and ANTI; otherwise the probe
    columns then the build columns, the padded side's columns nullable."""
    if _keeps_probe_only(join_type):
        return probe_schema.copy()
    return build_join_output_schema_outer(
        probe_schema,
        build_schema,
        _pads_probe(join_type),
        _pads_build(join_type),
    )


struct HashProbeShared(Movable):
    """What the per-worker probes of one OP_JOIN_PROBE share: the build rows,
    the index over their key columns (None for CROSS), each owned once and
    only read, and the marks of matched build rows (RIGHT and FULL only)."""

    var _index: Optional[ArcPointer[MultiKeyHashJoinBuilder]]
    var _build: ArcPointer[RecordBatch]
    var _probe_keys: List[String]
    var _build_keys: List[String]
    var _join_type: UInt8
    var _matched: ArcPointer[Slab[AtomicU8]]

    def __init__(out self, ref spec: MorselOp, var build: RecordBatch) raises:
        """Index `build`, the published rows of the segment `spec` names, by
        the build key columns. Raises a named refusal for a spec the probe
        does not serve (see the module header)."""
        if spec.tag != OP_JOIN_PROBE:
            raise _refuse("an operator that is not OP_JOIN_PROBE")
        var jt = spec.probe_join_type
        if not _served_type(jt):
            raise _refuse(
                "join type "
                + String(Int(jt))
                + "; INNER, LEFT, RIGHT, FULL, SEMI, ANTI and CROSS are"
                " served"
            )
        if spec.probe_residual:
            raise _refuse("a residual predicate")
        if spec.probe_output_cols:
            raise _refuse("a late-materialization column list")
        if spec.probe_algo == JOIN_ALGO_SORT_MERGE:
            raise _refuse("the sort-merge algorithm")
        var n = len(spec.probe_left_keys)
        if jt == JOIN_CROSS:
            if n != 0 or len(spec.probe_right_keys) != 0:
                raise _refuse(
                    "a CROSS join with "
                    + String(n)
                    + " probe keys and "
                    + String(len(spec.probe_right_keys))
                    + " build keys; a CROSS join has none"
                )
        elif n == 0 or n != len(spec.probe_right_keys) or n > MAX_JOIN_KEYS:
            raise _refuse(
                String(n)
                + " probe keys and "
                + String(len(spec.probe_right_keys))
                + " build keys; one to "
                + String(MAX_JOIN_KEYS)
                + " of each, in pairs, are served"
            )
        self._probe_keys = spec.probe_left_keys.copy()
        self._build_keys = spec.probe_right_keys.copy()
        self._join_type = jt
        self._index = None
        if jt != JOIN_CROSS:
            refuse_reserved_int64_keys(build, self._build_keys, "build")
            var keys = extract_join_key_columns_serial(build, self._build_keys)
            self._index = Optional(
                ArcPointer(MultiKeyHashJoinBuilder.build(keys^))
            )
        var marks = build.num_rows() if _pads_probe(jt) else 0
        self._matched = ArcPointer[Slab[AtomicU8]](
            Slab[AtomicU8].create_prefilled(marks)
        )
        self._build = ArcPointer(build^)

    def join_type(self) -> UInt8:
        """The join type, in the probe's view (probe left, build right)."""
        return self._join_type

    def output_schema(self, ref probe_schema: Schema) raises -> Schema:
        """The schema of the rows the probe emits for morsels of
        `probe_schema` (`join_output_schema`)."""
        return join_output_schema(
            self._join_type, probe_schema, self._build[].schema
        )

    def build_rows(self) -> Int:
        """The rows of the build side, NULL keys included."""
        return self._build[].num_rows()

    def has_tail(self) -> Bool:
        """True when the probe owes rows after its workers finish: the
        unmatched build rows of a RIGHT or FULL join."""
        return _pads_probe(self._join_type)

    def unmatched_build_rows(
        self, ref probe_schema: Schema, chunk_rows: Int
    ) raises -> List[RecordBatch]:
        """The tail: the build rows no probe row matched, in build row order,
        with the probe columns (of `probe_schema`) NULL, in batches of at most
        `chunk_rows` rows. Empty for a join that owes no tail. Call it only
        after every worker's probe has finished."""
        var out = List[RecordBatch]()
        if not self.has_tail():
            return out^
        var step = max(chunk_rows, 1)
        var unmatched = List[Int]()
        for b in range(len(self._matched[])):
            if self._matched[].get_mut_interior(b).load() == 0:
                unmatched.append(b)
        var schema = self.output_schema(probe_schema)
        var nulls = empty_batch_like_schema(probe_schema)
        var at = 0
        while at < len(unmatched):
            var stop = min(at + step, len(unmatched))
            var probe_idx = List[Int](capacity=stop - at)
            var build_idx = List[Int](capacity=stop - at)
            for i in range(at, stop):
                probe_idx.append(-1)
                build_idx.append(unmatched[i])
            out.append(
                assemble_join_result(
                    nulls,
                    self._build[],
                    probe_idx^,
                    build_idx^,
                    schema,
                    left_nullable=True,
                    right_nullable=_pads_build(self._join_type),
                )
            )
            at = stop
        return out^

    def make(self) -> HashProbeOp:
        """A probe for one worker."""
        var index: Optional[ArcPointer[MultiKeyHashJoinBuilder]] = None
        if self._index:
            index = Optional(ArcPointer(copy=self._index.value()))
        return HashProbeOp(
            index^,
            ArcPointer(copy=self._build),
            self._probe_keys.copy(),
            self._build_keys.copy(),
            self._join_type,
            ArcPointer(copy=self._matched),
        )


struct HashProbeOp(MorselOperatorImpl):
    """One worker's probe; see the module header."""

    var _index: Optional[ArcPointer[MultiKeyHashJoinBuilder]]
    var _build: ArcPointer[RecordBatch]
    var _probe_keys: List[String]
    var _build_keys: List[String]
    var _join_type: UInt8
    var _matched: ArcPointer[Slab[AtomicU8]]
    var _probe_schema: Optional[Schema]
    var _out_schema: Optional[Schema]
    var _kernel: Optional[MultiKeyJoinProbeOp]
    # CROSS: the morsel being emitted in chunks, and its next probe row.
    var _pending: Optional[RecordBatch]
    var _next_row: Int

    def __init__(
        out self,
        var index: Optional[ArcPointer[MultiKeyHashJoinBuilder]],
        var build: ArcPointer[RecordBatch],
        var probe_keys: List[String],
        var build_keys: List[String],
        join_type: UInt8,
        var matched: ArcPointer[Slab[AtomicU8]],
    ):
        self._index = index^
        self._build = build^
        self._probe_keys = probe_keys^
        self._build_keys = build_keys^
        self._join_type = join_type
        self._matched = matched^
        self._probe_schema = None
        self._out_schema = None
        self._kernel = None
        self._pending = None
        self._next_row = 0

    def _schema_for(mut self, ref probe_schema: Schema) raises:
        """Make the output schema (and, for INNER, the kernel) for morsels of
        `probe_schema`, unless the ones held were made for that schema."""
        if self._probe_schema and _same_schema(
            self._probe_schema.value(), probe_schema
        ):
            return
        var out_schema = join_output_schema(
            self._join_type, probe_schema, self._build[].schema
        )
        if self._join_type == JOIN_INNER:
            self._kernel = MultiKeyJoinProbeOp(
                ArcPointer(copy=self._index.value()),
                ArcPointer(copy=self._build),
                self._probe_keys.copy(),
                self._build_keys.copy(),
                ArcPointer(build_join_output_schema(
                    probe_schema, self._build[].schema
                )),
                JOIN_INNER,
            )
        self._out_schema = out_schema^
        self._probe_schema = probe_schema.copy()

    def _mark(self, ref build_matches: List[Int]):
        """Mark every build row of `build_matches` as matched."""
        for i in range(len(build_matches)):
            ref cell = self._matched[].get_mut_interior(build_matches[i])
            if cell.load() == 0:
                var expected = UInt8(0)
                _ = cell.compare_exchange(expected, UInt8(1))

    def _emit_keyed(mut self, mut morsel: Morsel) raises:
        """Replace `morsel.batch` with the rows a LEFT, RIGHT, FULL, SEMI or
        ANTI probe emits for it, and mark the matched build rows of RIGHT and
        FULL."""
        var keys = extract_join_key_columns_serial(
            morsel.batch, self._probe_keys
        )
        var build_matches = List[Int]()
        var probe_matches = List[Int]()
        self._index.value()[].probe_inner_into(
            keys, build_matches, probe_matches
        )
        _ = keys^
        var jt = self._join_type
        if _pads_probe(jt):
            self._mark(build_matches)
        var n = morsel.batch.num_rows()
        var partnered = List[Bool](length=n, fill=False)
        for i in range(len(probe_matches)):
            partnered[probe_matches[i]] = True
        if _keeps_probe_only(jt):
            var keep = jt == JOIN_SEMI
            var rows = List[Int]()
            for r in range(n):
                if partnered[r] == keep:
                    rows.append(r)
            if len(rows) == n:
                return
            var kept = gather_batch(morsel.batch, rows)
            morsel.replace_batch(kept^)
            return
        if _pads_build(jt):
            for r in range(n):
                if not partnered[r]:
                    probe_matches.append(r)
                    build_matches.append(-1)
        var joined = assemble_join_result(
            morsel.batch,
            self._build[],
            probe_matches^,
            build_matches^,
            self._out_schema.value(),
            left_nullable=_pads_probe(jt),
            right_nullable=_pads_build(jt),
        )
        morsel.replace_batch(joined^)

    def _emit_cross_chunk(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Emit the next chunk of the pending CROSS morsel into `morsel`:
        HAVE_MORE_OUTPUT while probe rows are left, NEED_MORE_INPUT with the
        last chunk."""
        var b = self._build[].num_rows()
        var per_chunk = max(CROSS_CHUNK_ROWS // b, 1)
        var n = self._pending.value().num_rows()
        var stop = min(self._next_row + per_chunk, n)
        var probe_idx = List[Int](capacity=(stop - self._next_row) * b)
        var build_idx = List[Int](capacity=(stop - self._next_row) * b)
        for p in range(self._next_row, stop):
            for j in range(b):
                probe_idx.append(p)
                build_idx.append(j)
        var chunk = assemble_join_result(
            self._pending.value(),
            self._build[],
            probe_idx^,
            build_idx^,
            self._out_schema.value(),
        )
        morsel.replace_batch(chunk^)
        self._next_row = stop
        if stop < n:
            return ExecResult(HAVE_MORE_OUTPUT)
        self._pending = None
        self._next_row = 0
        return ExecResult(NEED_MORE_INPUT)

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        if self._pending:
            return self._emit_cross_chunk(morsel)
        if morsel.batch.has_selection_mask():
            var extracted = RecordBatch()
            swap(morsel.batch, extracted)
            morsel.replace_batch(materialize_selection_if_present(extracted^))
        if morsel.num_rows() == 0:
            return ExecResult(FILTERED_EMPTY)
        self._schema_for(morsel.batch.schema)
        if self._join_type == JOIN_CROSS:
            if self._build[].num_rows() == 0:
                return ExecResult(FILTERED_EMPTY)
            var held = RecordBatch()
            swap(morsel.batch, held)
            self._pending = Optional(held^)
            self._next_row = 0
            return self._emit_cross_chunk(morsel)
        refuse_reserved_int64_keys(morsel.batch, self._probe_keys, "probe")
        if self._join_type == JOIN_INNER:
            _ = self._kernel.value().execute(morsel)
        else:
            self._emit_keyed(morsel)
        if morsel.num_rows() == 0:
            return ExecResult(FILTERED_EMPTY)
        return ExecResult(NEED_MORE_INPUT)

    def metrics_snapshot(self) -> MetricsSnapshot:
        if self._kernel:
            return self._kernel.value().metrics_snapshot()
        return MetricsSnapshot()

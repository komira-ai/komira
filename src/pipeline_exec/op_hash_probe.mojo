# =============================================================================
# op_hash_probe -- OP_JOIN_PROBE: the INNER equi-join probe over a built index
# =============================================================================
#
# A join is two segments. The build side ends in SINK_HASH_BUILD, which
# collects its rows (a `CollectSink`) and publishes them as one batch. The
# probe side's segment carries an OP_JOIN_PROBE naming that segment
# (`probe_build_seg`). When the probe segment's run begins, the builder takes
# the published build rows and makes one `HashProbeShared`: the composite hash
# index over the build key columns (`op_join_probe`'s
# `MultiKeyHashJoinBuilder`), built once on the calling thread before any
# worker starts. Each worker then runs its own `HashProbeOp`, which reads that
# index and the build rows and never writes them.
#
# A worker's probe wraps `op_join_probe`'s `MultiKeyJoinProbeOp` and adds what
# that kernel leaves to its caller:
#
#   * a morsel that arrives with a selection mask (a filter before the probe)
#     is gathered first; the kernel reads every row of the batch;
#   * a morsel with no row, or whose rows all fail to match, is dropped
#     (FILTERED_EMPTY);
#   * the output schema is the probe columns, then the build columns, a build
#     name the probe side already uses suffixed `_right`
#     (`build_join_output_schema`), made from the morsel's own schema and made
#     again if a later morsel's schema differs.
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
# a join type other than INNER, a residual, a late-materialization column
# list, the sort-merge algorithm, and a key list that is empty, longer than the
# kernel takes or of unequal lengths. `lowering` never emits any of them.
# =============================================================================

from std.memory import ArcPointer

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch, Schema
from column_kernels.compiler_helpers import materialize_selection_if_present
from exec_types.exec_result import (
    ExecResult,
    FILTERED_EMPTY,
    NEED_MORE_INPUT,
)
from metrics.metrics_set import MetricsSnapshot
from morsel.morsel import Morsel
from morsel.morsel_operator import MorselOperatorImpl
from op_join_probe.join_key_extract import extract_join_key_columns_serial
from op_join_probe.join_multi_key import MAX_JOIN_KEYS, _NAN_SENTINEL_BITS
from op_join_probe.join_multi_key_builder import MultiKeyHashJoinBuilder
from op_join_probe.join_output_schema import build_join_output_schema
from op_join_probe.multi_key_probe_op import MultiKeyJoinProbeOp
from physical_plan.physical_plan import MorselOp, OP_JOIN_PROBE
from plan_ir.logical_plan import JOIN_ALGO_SORT_MERGE, JOIN_INNER


comptime JOIN_KEY_RESERVED = "JOIN_KEY_RESERVED"
"""Refusal: an INT64 join key holds the value the join kernel reserves for a
NULL key, so the kernel cannot tell it from NULL."""


def refuse_reserved_int64_keys(
    ref batch: RecordBatch, key_names: List[String], side: String
) raises:
    """Raise `JOIN_KEY_RESERVED`, naming the column and the side, when a
    non-NULL row of an INT64 key column holds the kernel's NULL key-slot
    value. Key columns of other types cannot hold it and are not read."""
    for k in range(len(key_names)):
        var idx = batch.schema.column_index(key_names[k])
        ref col = batch.column_at(idx)
        if col.arrow_type != ArrowType.INT64:
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


struct HashProbeShared(Movable):
    """What the per-worker probes of one OP_JOIN_PROBE share: the build rows
    and the index over their key columns, each owned once and only read."""

    var _index: ArcPointer[MultiKeyHashJoinBuilder]
    var _build: ArcPointer[RecordBatch]
    var _probe_keys: List[String]
    var _build_keys: List[String]

    def __init__(out self, ref spec: MorselOp, var build: RecordBatch) raises:
        """Index `build`, the published rows of the segment `spec` names, by
        the build key columns. Raises a named refusal for a spec the probe
        does not serve (see the module header)."""
        if spec.tag != OP_JOIN_PROBE:
            raise _refuse("an operator that is not OP_JOIN_PROBE")
        if spec.probe_join_type != JOIN_INNER:
            raise _refuse(
                "join type "
                + String(Int(spec.probe_join_type))
                + "; only INNER is served"
            )
        if spec.probe_residual:
            raise _refuse("a residual predicate")
        if spec.probe_output_cols:
            raise _refuse("a late-materialization column list")
        if spec.probe_algo == JOIN_ALGO_SORT_MERGE:
            raise _refuse("the sort-merge algorithm")
        var n = len(spec.probe_left_keys)
        if n == 0 or n != len(spec.probe_right_keys) or n > MAX_JOIN_KEYS:
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
        refuse_reserved_int64_keys(build, self._build_keys, "build")
        var keys = extract_join_key_columns_serial(build, self._build_keys)
        self._index = ArcPointer(MultiKeyHashJoinBuilder.build(keys^))
        self._build = ArcPointer(build^)

    def output_schema(self, ref probe_schema: Schema) raises -> Schema:
        """The schema of the rows the probe emits for morsels of
        `probe_schema`: the probe columns, then the build columns."""
        return build_join_output_schema(probe_schema, self._build[].schema)

    def build_rows(self) -> Int:
        """The rows of the build side, NULL keys included."""
        return self._build[].num_rows()

    def make(self) -> HashProbeOp:
        """A probe for one worker."""
        return HashProbeOp(
            ArcPointer(copy=self._index),
            ArcPointer(copy=self._build),
            self._probe_keys.copy(),
            self._build_keys.copy(),
        )


struct HashProbeOp(MorselOperatorImpl):
    """One worker's INNER probe; see the module header."""

    var _index: ArcPointer[MultiKeyHashJoinBuilder]
    var _build: ArcPointer[RecordBatch]
    var _probe_keys: List[String]
    var _build_keys: List[String]
    var _probe_schema: Optional[Schema]
    var _kernel: Optional[MultiKeyJoinProbeOp]

    def __init__(
        out self,
        var index: ArcPointer[MultiKeyHashJoinBuilder],
        var build: ArcPointer[RecordBatch],
        var probe_keys: List[String],
        var build_keys: List[String],
    ):
        self._index = index^
        self._build = build^
        self._probe_keys = probe_keys^
        self._build_keys = build_keys^
        self._probe_schema = None
        self._kernel = None

    def _kernel_for(mut self, ref probe_schema: Schema) raises:
        """Make the kernel for morsels of `probe_schema`, unless the one held
        was made for that schema."""
        if self._probe_schema and _same_schema(
            self._probe_schema.value(), probe_schema
        ):
            return
        var out_schema = build_join_output_schema(
            probe_schema, self._build[].schema
        )
        self._kernel = MultiKeyJoinProbeOp(
            ArcPointer(copy=self._index),
            ArcPointer(copy=self._build),
            self._probe_keys.copy(),
            self._build_keys.copy(),
            ArcPointer(out_schema^),
            JOIN_INNER,
        )
        self._probe_schema = probe_schema.copy()

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        if morsel.batch.has_selection_mask():
            var extracted = RecordBatch()
            swap(morsel.batch, extracted)
            morsel.replace_batch(materialize_selection_if_present(extracted^))
        if morsel.num_rows() == 0:
            return ExecResult(FILTERED_EMPTY)
        refuse_reserved_int64_keys(morsel.batch, self._probe_keys, "probe")
        self._kernel_for(morsel.batch.schema)
        _ = self._kernel.value().execute(morsel)
        if morsel.num_rows() == 0:
            return ExecResult(FILTERED_EMPTY)
        return ExecResult(NEED_MORE_INPUT)

    def metrics_snapshot(self) -> MetricsSnapshot:
        if self._kernel:
            return self._kernel.value().metrics_snapshot()
        return MetricsSnapshot()

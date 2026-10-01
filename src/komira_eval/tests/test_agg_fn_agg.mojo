# =============================================================================
# test_agg_fn_agg.mojo — AggFn -> Aggregator adapter acceptance
# =============================================================================
#
# Locks in the `AggFnAgg[F: AggFn, col: Int]` newtype adapter — the
# `Aggregator` conformance bridge for the user-facing `AggFn` family.
#
# Coverage:
#   1. `AggFnAgg[F, col]` conforms to `Aggregator` — `StateTy == F.State`,
#      `OUT_DT == F.OutType`, usable through a parametric
#      `fn _drive_via_aggregator[A: Aggregator, ...]` helper that drives
#      the per-row hot loop via the trait surface.
#   2. `update_scalar` smoke — Float64 input column, identity sum AggFn,
#      adapter extracts column scalar -> forwards `update_scalar(state, v)`
#      -> running state matches the expected sum.
#   3. Cross-DType smoke — Int64 input column with a different sum AggFn,
#      exercises the `comptime if` ladder.
#   4. `combine` smoke — two adapters fold disjoint partial sums; combining
#      the two partial states yields the full sum (matches `F.merge`'s
#      value-return contract bridged into `Aggregator.combine`'s in-place
#      contract).
#   5. Stateful-AggFn smoke — verifies that the adapter's `_udf: F` field
#      threads `self` correctly into `self._udf.update_scalar` for an
#      AggFn that mutates its `_udf` field (the in-instance adapter
#      pattern preserves captures across rows). Since
#      mutating `self` from a `self`-bound method is not legal —
#      verifies via a field-less stateless AggFn instead; the
#      shape-correctness check is that the call site builds and threads
#      through `mut self`.
#
# Note: `init` / `finalize` are constrained-unimplementable for an
# instance-bound `AggFn` adapter (see `agg_fn_agg.mojo` module doc
# "init / finalize lifecycle"). The test exercises `update_scalar` and
# `combine` — the actual hot-path methods the typed UDF executor
# drives. Per-group `init` / `finalize` are routed via
# `agg_slot._udf.init()` / `agg_slot._udf.finalize(state)` directly in
# the executor, NOT through the static trait method.
#
# This acceptance harness mirrors `test_map_fn_rt.mojo`'s
# patterns (BatchView fixture + parametric trait-dispatch helpers).
# =============================================================================

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections.batch_view import BatchView, batch_view_over

from komira_eval.agg_fn import AggFn, PodState
from komira_eval.aggregator import Aggregator
from komira_eval.agg_fn_agg import AggFnAgg
from komira_eval.auto_komira_schema import AutoKomiraSchema
from komira_eval.schema_descriptor import schema_of, DT_I64, DT_F64


# -----------------------------------------------------------------------------
# Fixture — single-column RecordBatch builders.
# -----------------------------------------------------------------------------
def _build_f64_batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.float64]]()
    for i in range(n):
        vals.append(Scalar[DType.float64](Float64(i) + 0.5))
    var arr = PrimitiveArray[DType.float64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("c0", DType.float64, True))
    var col0 = Column.from_primitive[DType.float64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col0^)


def _build_i64_batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("c0", DType.int64, True))
    var col0 = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col0^)


# -----------------------------------------------------------------------------
# AggFn state structs (must conform to PodState — fixed-size POD, no heap).
# -----------------------------------------------------------------------------
@fieldwise_init
struct SumStateF64(PodState):
    var sum: Float64


@fieldwise_init
struct SumStateI64(PodState):
    var sum: Int64


# -----------------------------------------------------------------------------
# AggFn row structs — single-field POD (1-input AggFn).
# -----------------------------------------------------------------------------
@fieldwise_init
struct _RowF64(Copyable, Movable, AutoKomiraSchema):
    var c0: Float64


@fieldwise_init
struct _RowI64(Copyable, Movable, AutoKomiraSchema):
    var c0: Int64


# -----------------------------------------------------------------------------
# AggFn conformers — single-column sum, field-less.
# -----------------------------------------------------------------------------
@fieldwise_init
struct _SumAggF64(AggFn):
    """Sum aggregate over a Float64 column. Field-less."""
    comptime InRow = _RowF64
    comptime OutputSchema = schema_of["sum", DT_F64]()
    comptime OutType = DType.float64
    comptime State = SumStateF64
    comptime UDF_ID = UInt32(0xDEAD_0001)

    def init(self) -> SumStateF64:
        return SumStateF64(0.0)

    def update(self, mut s: SumStateF64, row: _RowF64):
        self.update_scalar(s, row.c0)

    def update_scalar[*Ts: Copyable & Movable](
        self, mut s: SumStateF64, *vals: *Ts
    ):
        s.sum += rebind[Float64](vals[0])

    def merge(self, a: SumStateF64, b: SumStateF64) -> SumStateF64:
        return SumStateF64(a.sum + b.sum)

    def finalize(self, s: SumStateF64) -> Scalar[DType.float64]:
        return s.sum


@fieldwise_init
struct _SumAggI64(AggFn):
    """Sum aggregate over an Int64 column. Field-less. Exercises the
    `comptime if` DType ladder for the Int64 BatchView accessor."""
    comptime InRow = _RowI64
    comptime OutputSchema = schema_of["sum", DT_I64]()
    comptime OutType = DType.int64
    comptime State = SumStateI64
    comptime UDF_ID = UInt32(0xDEAD_0002)

    def init(self) -> SumStateI64:
        return SumStateI64(0)

    def update(self, mut s: SumStateI64, row: _RowI64):
        self.update_scalar(s, row.c0)

    def update_scalar[*Ts: Copyable & Movable](
        self, mut s: SumStateI64, *vals: *Ts
    ):
        s.sum += rebind[Int64](vals[0])

    def merge(self, a: SumStateI64, b: SumStateI64) -> SumStateI64:
        return SumStateI64(a.sum + b.sum)

    def finalize(self, s: SumStateI64) -> Scalar[DType.int64]:
        return s.sum


# -----------------------------------------------------------------------------
# Parametric helper — confirms an `AggFnAgg[...]` is usable through the
# Aggregator trait surface (the Stage *Aggs slot-type position).
# -----------------------------------------------------------------------------
def _drive_via_aggregator[
    A: Aggregator, bo: Origin[mut=False]
](
    mut a: A,
    mut state: A.StateTy,
    batch: BatchView[bo],
    i: Int,
):
    a.update_scalar[bo](state, batch, i)


def _expect(cond: Bool, label: String) raises:
    if not cond:
        raise Error("FAIL: " + label)
    print("  ok:", label)


def main() raises:
    print("=== test_agg_fn_agg ===")

    # ----- 1. Trait conformance — Float64 sum -----
    # `AggFnAgg[_SumAggF64, 0]` conforms to Aggregator: OUT_DT == float64.
    _expect(
        AggFnAgg[_SumAggF64, 0].OUT_DT == DType.float64,
        "AggFnAgg[SumF64, 0] OUT_DT == float64",
    )

    # ----- 2. update_scalar smoke — Float64 -----
    var batch_f = _build_f64_batch(8)
    var view_f = batch_view_over(batch_f)
    var adapter_f64 = AggFnAgg[_SumAggF64, 0](_SumAggF64())
    var state_f64 = SumStateF64(0.0)
    # Direct call.
    for i in range(8):
        adapter_f64.update_scalar[origin_of(batch_f)](state_f64, view_f, i)
    # _build_f64_batch generates vals[i] = i + 0.5 for i in [0..8)
    # Sum = (0+1+2+3+4+5+6+7) + 8*0.5 = 28 + 4 = 32.0
    _expect(
        state_f64.sum == Float64(32.0),
        "AggFnAgg[SumF64, 0] direct update_scalar rows [0..8) sum == 32.0",
    )

    # Via parametric trait-dispatch helper (Stage *Aggs slot position).
    var adapter_f64_b = AggFnAgg[_SumAggF64, 0](_SumAggF64())
    var state_f64_b = SumStateF64(0.0)
    for i in range(8):
        _drive_via_aggregator(adapter_f64_b, state_f64_b, view_f, i)
    _expect(
        state_f64_b.sum == Float64(32.0),
        "AggFnAgg[SumF64, 0] via Aggregator trait rows [0..8) sum == 32.0",
    )

    # ----- 3. Cross-DType smoke — Int64 -----
    _expect(
        AggFnAgg[_SumAggI64, 0].OUT_DT == DType.int64,
        "AggFnAgg[SumI64, 0] OUT_DT == int64",
    )
    var batch_i = _build_i64_batch(10)
    var view_i = batch_view_over(batch_i)
    var adapter_i64 = AggFnAgg[_SumAggI64, 0](_SumAggI64())
    var state_i64 = SumStateI64(0)
    for i in range(10):
        adapter_i64.update_scalar[origin_of(batch_i)](state_i64, view_i, i)
    # _build_i64_batch generates vals[i] = i for i in [0..10)
    # Sum = 0+1+2+...+9 = 45
    _expect(
        Int(state_i64.sum) == 45,
        "AggFnAgg[SumI64, 0] update_scalar rows [0..10) sum == 45",
    )

    # ----- 4. combine smoke — two partial sums -----
    # Build two partial sums over disjoint row ranges of batch_f, then
    # combine the second into the first via the adapter's combine method.
    # The result must equal the full-batch sum (32.0).
    var part_a = AggFnAgg[_SumAggF64, 0](_SumAggF64())
    var state_a = SumStateF64(0.0)
    for i in range(4):
        part_a.update_scalar[origin_of(batch_f)](state_a, view_f, i)
    # Sum of i+0.5 for i in [0..4) = (0+1+2+3) + 2.0 = 8.0
    _expect(
        state_a.sum == Float64(8.0),
        "AggFnAgg[SumF64, 0] partial_a rows [0..4) sum == 8.0",
    )

    var part_b = AggFnAgg[_SumAggF64, 0](_SumAggF64())
    var state_b = SumStateF64(0.0)
    for i in range(4, 8):
        part_b.update_scalar[origin_of(batch_f)](state_b, view_f, i)
    # Sum of i+0.5 for i in [4..8) = (4+5+6+7) + 2.0 = 24.0
    _expect(
        state_b.sum == Float64(24.0),
        "AggFnAgg[SumF64, 0] partial_b rows [4..8) sum == 24.0",
    )

    # combine partial_b into partial_a in place.
    part_a.combine(state_a, state_b^)
    _expect(
        state_a.sum == Float64(32.0),
        "AggFnAgg[SumF64, 0] combine(partial_a, partial_b) sum == 32.0",
    )

    print("=== test_agg_fn_agg: ALL PASS ===")

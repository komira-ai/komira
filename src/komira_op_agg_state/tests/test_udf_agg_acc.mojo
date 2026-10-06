# =============================================================================
# test_udf_agg_acc.mojo — operator-level tests for AggFnAcc[F: AggFn]
# =============================================================================
#
# UDF-DESIGN Deliverable 3, Phase 1.c (the AggFnAcc re-land on top 
# — the Mac's P1.c+e punted the agg operator; this file is the agg-specific
# coverage; the map/filter operators are covered by an internal test).
# Exercises `AggFnAcc[F: AggFn]` (the engine's `Accumulator` adapter) directly:
#   (a) `AggFnAcc[WeightedAvg]` — per-group weighted-avg over the typed
#       N-column `update_record_batch` (2-input), with a NULL weight on one row
#       skipped (PROPAGATE); `finalize_to_column`.
#   (b) parallel-merge — two "worker" `AggFnAcc`s combined via `merge_aligned`.
#   (c) `AggFnAcc[SumF64]` — a 1-input UDF agg exercising the arity-1 comptime
#       fan + the single-column resolve + `ensure_capacity` + `finalize`.
#
# Conformer fixtures are fresh siblings of the internal test
# ones (a test file can't import another test file's structs). They follow the
# P1.a memo's `mut self` rule on het-pack methods (`update_scalar` is `self`,
# matching the trait — an `AggFn` scalar oracle never mutates `self`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_almost_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, SchemaBuilder, RecordBatch, RecordBatchBuilder,
)
from komira_udf.agg_fn import AggFn, PodState
from komira_udf.schema_descriptor import schema_of, DT_F64
from komira_kernels.simd_of import SimdOf
from komira_op_agg_state.agg_fn_fused_kernel import _AggFnFusedKernel
from komira_op_agg_state.agg_fn_acc import AggFnAcc
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Conformer fixtures (siblings of the test_udf_traits.mojo ones)
# =============================================================================

@fieldwise_init
struct WAvgRow(Copyable, Movable):
    var value: Float64
    var weight: Float64


@fieldwise_init
struct WAvgState(PodState):
    var sum_vw: Float64
    var sum_w: Float64


# UDF-PHASE-B3-7-SDK-A-CONFORMERS: typed output rows for *Simd sub-traits.
@fieldwise_init
struct WAvgOutRow(Copyable, Movable):
    var wavg: Float64


@fieldwise_init
struct SumVOutRow(Copyable, Movable):
    var sum_v: Float64


@fieldwise_init
struct WeightedAvg(_AggFnFusedKernel):
    # Legacy AggFn surface.
    comptime InRow = WAvgRow
    comptime InputSchema = schema_of["value", DT_F64, "weight", DT_F64]()
    comptime OutputSchema = schema_of["wavg", DT_F64]()
    comptime OutType = DType.float64
    comptime State = WAvgState
    comptime UDF_ID = UInt32(9201)

    # NEW _AggFnFusedKernel surface.
    comptime T_IN = WAvgRow
    comptime T_OUT = WAvgOutRow
    comptime STATE = WAvgState

    def init(self) -> WAvgState:
        return WAvgState(0.0, 0.0)

    def update(self, mut s: WAvgState, row: WAvgRow):
        self.update_scalar(s, row.value, row.weight)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: WAvgState, *vals: *Ts):
        s.sum_vw += rebind[Float64](vals[0]) * rebind[Float64](vals[1])
        s.sum_w += rebind[Float64](vals[1])

    def merge(self, a: WAvgState, b: WAvgState) -> WAvgState:
        return WAvgState(a.sum_vw + b.sum_vw, a.sum_w + b.sum_w)

    def finalize(self, s: WAvgState) -> Scalar[DType.float64]:
        return s.sum_vw / s.sum_w if s.sum_w != 0.0 else 0.0

    # NEW @staticmethod _AggFnFusedKernel methods.
    @staticmethod
    def init() -> WAvgState:
        return WAvgState(0.0, 0.0)

    @staticmethod
    def update_chunk[W: Int](mut state: WAvgState, input: SimdOf[WAvgRow, W]):
        var value = input.get_f64[0]()
        var weight = input.get_f64[1]()
        state.sum_vw += (value * weight).reduce_add()
        state.sum_w += weight.reduce_add()

    @staticmethod
    def update(mut state: WAvgState, input: WAvgRow):
        state.sum_vw += input.value * input.weight
        state.sum_w += input.weight

    @staticmethod
    def merge(mut a: WAvgState, b: WAvgState):
        a.sum_vw += b.sum_vw
        a.sum_w += b.sum_w

    @staticmethod
    def finalize(state: WAvgState) -> WAvgOutRow:
        return WAvgOutRow(wavg=state.sum_vw / state.sum_w if state.sum_w != 0.0 else 0.0)


# A 1-input agg — exercises the arity-1 comptime fan + single-column resolve.
@fieldwise_init
struct SumRow(Copyable, Movable):
    var v: Float64


@fieldwise_init
struct SumState(PodState):
    var s: Float64


@fieldwise_init
struct SumF64(_AggFnFusedKernel):
    # Legacy AggFn surface.
    comptime InRow = SumRow
    comptime InputSchema = schema_of["v", DT_F64]()
    comptime OutputSchema = schema_of["sum_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = SumState
    comptime UDF_ID = UInt32(9301)

    # NEW _AggFnFusedKernel surface.
    comptime T_IN = SumRow
    comptime T_OUT = SumVOutRow
    comptime STATE = SumState

    def init(self) -> SumState:
        return SumState(0.0)

    def update(self, mut s: SumState, row: SumRow):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumState, *vals: *Ts):
        s.s += rebind[Float64](vals[0])

    def merge(self, a: SumState, b: SumState) -> SumState:
        return SumState(a.s + b.s)

    def finalize(self, s: SumState) -> Scalar[DType.float64]:
        return s.s

    # NEW @staticmethod _AggFnFusedKernel methods.
    @staticmethod
    def init() -> SumState:
        return SumState(0.0)

    @staticmethod
    def update_chunk[W: Int](mut state: SumState, input: SimdOf[SumRow, W]):
        state.s += input.get_f64[0]().reduce_add()

    @staticmethod
    def update(mut state: SumState, input: SumRow):
        state.s += input.v

    @staticmethod
    def merge(mut a: SumState, b: SumState):
        a.s += b.s

    @staticmethod
    def finalize(state: SumState) -> SumVOutRow:
        return SumVOutRow(sum_v=state.s)


# =============================================================================
# Batch-builder helpers
# =============================================================================

def _f64_col(name: String, vals: List[Float64], nulls: List[Int]) raises -> Column[HeapRegion]:
    """A nullable Float64 column. `nulls` lists the indices to mark null."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, vals[i])
    for k in range(len(nulls)):
        arr._set_null(nulls[k])  # _set_null bumps null_count (fix)
    return Column.from_primitive[DType.float64](arr^)


def _wavg_batch() raises -> RecordBatch:
    # 4 rows: (10,2), (5,1), (20,4), (3, NULL) — group ids supplied separately.
    var sb = SchemaBuilder()
    sb.add_field(Field("value", ArrowType.FLOAT64, True))
    sb.add_field(Field("weight", ArrowType.FLOAT64, True))
    var b = RecordBatchBuilder()
    b.add_column(_f64_col("value", [10.0, 5.0, 20.0, 3.0], []))
    b.add_column(_f64_col("weight", [2.0, 1.0, 4.0, 0.0], [3]))
    return b.build(sb.build())


def _wavg_single_row(value: Float64, weight: Float64) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("value", ArrowType.FLOAT64, True))
    sb.add_field(Field("weight", ArrowType.FLOAT64, True))
    var b = RecordBatchBuilder()
    b.add_column(_f64_col("value", [value], []))
    b.add_column(_f64_col("weight", [weight], []))
    return b.build(sb.build())


# =============================================================================
# Tests
# =============================================================================

def test_agg_fn_acc_weighted_avg_two_groups() raises:
    # (a) Two groups via the typed N-column update_record_batch; the NULL
    #     weight on row 3 is skipped (PROPAGATE).
    var acc = AggFnAcc[WeightedAvg](WeightedAvg())
    acc.ensure_capacity(2)
    # gids: row0->g0, row1->g0, row2->g1, row3->g0 (g1 has only row2).
    # g0: (10,2),(5,1) ; row3 weight NULL -> skipped.  sum_vw = 25, sum_w = 3 -> 25/3.
    # g1: (20,4) -> 80/4 = 20.
    var gids: List[Int] = [0, 0, 1, 0]
    acc.update_record_batch(gids, _wavg_batch())
    assert_equal(acc.num_groups(), 2)
    var col = acc.finalize_to_column()
    var out = col.as_primitive[DType.float64]()
    assert_almost_equal(out.get(0), 25.0 / 3.0)
    assert_almost_equal(out.get(1), 20.0)


def test_agg_fn_acc_parallel_merge() raises:
    # (b) Two "worker" accumulators over the same gid space, then merge_aligned.
    var a = AggFnAcc[WeightedAvg](WeightedAvg())
    var b = AggFnAcc[WeightedAvg](WeightedAvg())
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    a.update_record_batch([0], _wavg_single_row(10.0, 2.0))   # a:g0 = (20, 2)
    b.update_record_batch([0], _wavg_single_row(5.0, 1.0))    # b:g0 = (5, 1)
    a.merge_aligned(b)                                          # merged = (25, 3) -> 25/3
    var col = a.finalize_to_column()
    assert_almost_equal(col.as_primitive[DType.float64]().get(0), 25.0 / 3.0)


def test_agg_fn_acc_one_input_agg() raises:
    # (c) A 1-input UDF agg via the typed update_record_batch (arity-1 fan +
    #     the single-column resolve + ensure_capacity + finalize path).
    var acc = AggFnAcc[SumF64](SumF64())
    acc.ensure_capacity(2)
    # 4 values 10, 20, 30, 40 ; gids 0,1,0,1 -> g0 = 40, g1 = 60.
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    var b = RecordBatchBuilder()
    b.add_column(_f64_col("v", [10.0, 20.0, 30.0, 40.0], []))
    acc.update_record_batch([0, 1, 0, 1], b.build(sb.build()))
    var out = acc.finalize_to_column().as_primitive[DType.float64]()
    assert_almost_equal(out.get(0), 40.0)
    assert_almost_equal(out.get(1), 60.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

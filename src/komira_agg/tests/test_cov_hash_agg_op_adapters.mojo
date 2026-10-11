# =============================================================================
# test_cov_hash_agg_op_adapters.mojo — the `HashAggOp{F64,I64,I32,F32}Agg`
# adapters, the `Aggregator` default methods, `SumProductF64Agg` and
# `CorrF64Agg`, over a SLICED RecordBatch with nulls
# =============================================================================
#
# The fixture is a 12-row, 4-column batch (f64, i64, i32, f32), every column
# nullable, sliced to rows [2, 11): the 9 visible rows sit at a non-zero
# column offset, and the rows outside the slice hold values (+-1000, 500)
# that change every answer if an adapter reads a physical instead of a
# logical row. The adapters read the raw slot; skipping a null row is the
# caller's job (the engine's), so the driver here asks `col_is_null` first,
# as SQL requires: an aggregate ignores NULL inputs.
#
# Oracles (SQL, by hand) over the slice's non-null values:
#   f64 [2.5, 1.0, -0.5, 4.0, 0.25, 1.75, 3.0]   SUM = 12.0
#   i64 [5, -3, 7, 10, 2, 4, 6]                   SUM = 31
#   i32 [7, -4, 9, 2, -8, 3, 5]                   MAX = 9
#   f32 [0.5, 1.5, -2.5, 4.0, 0.25, 1.0, -0.75]   MIN = -2.5
# The four `HashAggOp*` conformers are test-local SUM / MAX / MIN ops: the
# package ships the traits and adapters, and the engine the conformers.
#
# Also: SUM(a * b) over two f64 columns (`SumProductF64Agg`) and Pearson
# CORR(x, y) for x = [1, 2, 3, 4], y = [1, 3, 2, 4]: means 2.5 and 2.5,
# sum dx*dy = 4, sum dx^2 = sum dy^2 = 5, r = 4 / 5 = 0.8 — read from all
# four input types the CORR ladder accepts. CORR of fewer than two rows
# (SQL NULL, the code NaN) is not pinned here.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder

from komira_agg.agg_op_traits import (
    HashAggOpF64, HashAggOpI64, HashAggOpI32, HashAggOpF32,
)
from komira_agg.aggregator import Aggregator
from komira_agg.hash_agg_op_aggregator import (
    HashAggOpF64Agg, HashAggOpI64Agg, HashAggOpI32Agg, HashAggOpF32Agg,
)
from komira_agg.builtin_agg_fns_sum_product import SumProductF64Agg
from komira_agg.builtin_agg_fns_corr import CorrF64Agg, CoMomentRunningState


# -----------------------------------------------------------------------------
# Test-local HashAggOp conformers.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _SumF64(HashAggOpF64):
    comptime StateTy = Float64

    @staticmethod
    def init() -> Float64:
        return 0.0

    @staticmethod
    def update_scalar(mut state: Float64, value: Float64):
        state += value

    @staticmethod
    def finalize(state: Float64) -> Float64:
        return state

    @staticmethod
    def combine(mut state: Float64, partial: Float64):
        state += partial


@fieldwise_init
struct _SumI64(HashAggOpI64):
    comptime StateTy = Int64

    @staticmethod
    def init() -> Int64:
        return 0

    @staticmethod
    def update_scalar(mut state: Int64, value: Int64):
        state += value

    @staticmethod
    def finalize(state: Int64) -> Int64:
        return state

    @staticmethod
    def combine(mut state: Int64, partial: Int64):
        state += partial


@fieldwise_init
struct _MaxI32(HashAggOpI32):
    comptime StateTy = Int32

    @staticmethod
    def init() -> Int32:
        return Int32.MIN

    @staticmethod
    def update_scalar(mut state: Int32, value: Int32):
        if value > state:
            state = value

    @staticmethod
    def finalize(state: Int32) -> Int32:
        return state

    @staticmethod
    def combine(mut state: Int32, partial: Int32):
        if partial > state:
            state = partial


@fieldwise_init
struct _MinF32(HashAggOpF32):
    comptime StateTy = Float32

    @staticmethod
    def init() -> Float32:
        return Float32.MAX

    @staticmethod
    def update_scalar(mut state: Float32, value: Float32):
        if value < state:
            state = value

    @staticmethod
    def finalize(state: Float32) -> Float32:
        return state

    @staticmethod
    def combine(mut state: Float32, partial: Float32):
        if partial < state:
            state = partial


# -----------------------------------------------------------------------------
# Fixture: the sliced 4-column batch with nulls. `None` marks a null slot.
# -----------------------------------------------------------------------------

comptime N_FULL = 12
comptime SLICE_AT = 2
comptime SLICE_LEN = 9


def _col[
    dt: DType
](vals: List[Scalar[dt]], nulls: List[Bool]) raises -> ColumnBuilder[dt]:
    var b = ColumnBuilder[dt].with_capacity(len(vals))
    for i in range(len(vals)):
        if nulls[i]:
            b.append_null()
        else:
            b.append(vals[i])
    return b^


def _sliced_batch() raises -> RecordBatch:
    # Physical rows 0, 1 and 11 are outside the slice.
    var f64: List[Float64] = [
        1000.0, -1000.0, 2.5, 0.0, 1.0, -0.5, 0.0, 4.0, 0.25, 1.75, 3.0, 500.0
    ]
    var f64n: List[Bool] = [
        False, False, False, True, False, False, True, False, False, False, False, False
    ]
    var i64: List[Int64] = [1000, -1000, 5, 0, -3, 7, 10, 0, 2, 4, 6, 500]
    var i64n: List[Bool] = [
        False, False, False, True, False, False, False, True, False, False, False, False
    ]
    var i32: List[Int32] = [1000, -1000, 7, -4, 0, 9, 2, 0, -8, 3, 5, 500]
    var i32n: List[Bool] = [
        False, False, False, False, True, False, False, True, False, False, False, False
    ]
    var f32: List[Float32] = [
        1000.0, -1000.0, 0.5, 1.5, 0.0, -2.5, 4.0, 0.25, 0.0, 1.0, -0.75, 500.0
    ]
    var f32n: List[Bool] = [
        False, False, False, False, True, False, False, False, True, False, False, False
    ]
    var c0 = _col[DType.float64](f64, f64n).materialize().slice(SLICE_AT, SLICE_LEN)
    var c1 = _col[DType.int64](i64, i64n).materialize().slice(SLICE_AT, SLICE_LEN)
    var c2 = _col[DType.int32](i32, i32n).materialize().slice(SLICE_AT, SLICE_LEN)
    var c3 = _col[DType.float32](f32, f32n).materialize().slice(SLICE_AT, SLICE_LEN)
    var sb = SchemaBuilder()
    sb.add_field(Field("f64", DType.float64, True))
    sb.add_field(Field("i64", DType.int64, True))
    sb.add_field(Field("i32", DType.int32, True))
    sb.add_field(Field("f32", DType.float32, True))
    return RecordBatch.from_typed_columns_4(sb.build(), c0^, c1^, c2^, c3^)


# -----------------------------------------------------------------------------
# Drivers over the Aggregator surface: the batch path, the MorselView path,
# and two partials (rows [0, 4) and [4, 9)) merged with `combine`.
# -----------------------------------------------------------------------------


def _drive[
    A: Aggregator, o: Origin[mut=False]
](mut a: A, bv: BatchView[o], col: Int, lo: Int, hi: Int) -> A.StateTy:
    var s = A.init()
    for i in range(lo, hi):
        if not bv.col_is_null(col, i):
            a.update_scalar[o](s, bv, i)
    return s^


def _drive_mv[
    A: Aggregator, o: Origin[mut=False]
](mut a: A, bv: BatchView[o], col: Int) -> A.StateTy:
    var s = A.init()
    for i in range(bv.n_rows()):
        if not bv.col_is_null(col, i):
            a.update_scalar_mv[BatchView[o]](s, bv, i)
    return s^


def _drive_split[
    A: Aggregator, o: Origin[mut=False]
](mut a: A, bv: BatchView[o], col: Int) -> A.StateTy:
    var left = _drive[A, o](a, bv, col, 0, 4)
    var right = _drive[A, o](a, bv, col, 4, bv.n_rows())
    a.combine(left, right^)
    return left^


def _valid_mask[
    o: Origin[mut=False]
](bv: BatchView[o], col: Int, i: Int) -> SIMD[DType.bool, 8]:
    var m = SIMD[DType.bool, 8](fill=False)
    for lane in range(8):
        if i + lane < bv.n_rows() and not bv.col_is_null(col, i + lane):
            m[lane] = True
    return m


# =============================================================================
# The four HashAggOp adapters
# =============================================================================


def test_f64_adapter_sliced_with_nulls() raises:
    """SUM(f64) over the slice = 12.0 by every path; the rows outside the
    slice (1000, -1000, 500) would change it if read."""
    var batch = _sliced_batch()
    var bv = batch_view_over(batch)
    assert_equal(bv.n_rows(), SLICE_LEN)
    var a = HashAggOpF64Agg[_SumF64, 0].make()
    assert_equal(HashAggOpF64Agg[_SumF64, 0].finalize(_drive(a, bv, 0, 0, bv.n_rows())), 12.0)
    assert_equal(HashAggOpF64Agg[_SumF64, 0].finalize(_drive_mv(a, bv, 0)), 12.0)
    assert_equal(HashAggOpF64Agg[_SumF64, 0].finalize(_drive_split(a, bv, 0)), 12.0)


def test_i64_adapter_sliced_with_nulls() raises:
    """SUM(i64) over the slice = 31 by every path."""
    var batch = _sliced_batch()
    var bv = batch_view_over(batch)
    var a = HashAggOpI64Agg[_SumI64, 1]()
    assert_equal(HashAggOpI64Agg[_SumI64, 1].finalize(_drive(a, bv, 1, 0, bv.n_rows())), Int64(31))
    var b = HashAggOpI64Agg[_SumI64, 1].make()
    assert_equal(HashAggOpI64Agg[_SumI64, 1].finalize(_drive_mv(b, bv, 1)), Int64(31))
    assert_equal(HashAggOpI64Agg[_SumI64, 1].finalize(_drive_split(b, bv, 1)), Int64(31))


def test_i32_adapter_sliced_with_nulls() raises:
    """MAX(i32) over the slice = 9 (1000 outside the slice must not win)."""
    var batch = _sliced_batch()
    var bv = batch_view_over(batch)
    var a = HashAggOpI32Agg[_MaxI32, 2].make()
    assert_equal(HashAggOpI32Agg[_MaxI32, 2].finalize(_drive(a, bv, 2, 0, bv.n_rows())), Int32(9))
    assert_equal(HashAggOpI32Agg[_MaxI32, 2].finalize(_drive_mv(a, bv, 2)), Int32(9))
    # The maximum (9, slice row 3) is in the left partial: combine must keep it.
    assert_equal(HashAggOpI32Agg[_MaxI32, 2].finalize(_drive_split(a, bv, 2)), Int32(9))


def test_f32_adapter_sliced_with_nulls() raises:
    """MIN(f32) over the slice = -2.5 (-1000 outside the slice must not win)."""
    var batch = _sliced_batch()
    var bv = batch_view_over(batch)
    var a = HashAggOpF32Agg[_MinF32, 3].make()
    assert_equal(HashAggOpF32Agg[_MinF32, 3].finalize(_drive(a, bv, 3, 0, bv.n_rows())), Float32(-2.5))
    assert_equal(HashAggOpF32Agg[_MinF32, 3].finalize(_drive_mv(a, bv, 3)), Float32(-2.5))
    assert_equal(HashAggOpF32Agg[_MinF32, 3].finalize(_drive_split(a, bv, 3)), Float32(-2.5))


def test_four_aggregates_in_one_pass() raises:
    """SUM(f64), SUM(i64), MAX(i32), MIN(f32) folded in ONE row loop, each
    with its own null filter: the states do not interfere."""
    var batch = _sliced_batch()
    var bv = batch_view_over(batch)
    var a0 = HashAggOpF64Agg[_SumF64, 0]()
    var a1 = HashAggOpI64Agg[_SumI64, 1]()
    var a2 = HashAggOpI32Agg[_MaxI32, 2]()
    var a3 = HashAggOpF32Agg[_MinF32, 3]()
    var s0 = HashAggOpF64Agg[_SumF64, 0].init()
    var s1 = HashAggOpI64Agg[_SumI64, 1].init()
    var s2 = HashAggOpI32Agg[_MaxI32, 2].init()
    var s3 = HashAggOpF32Agg[_MinF32, 3].init()
    for i in range(bv.n_rows()):
        if not bv.col_is_null(0, i):
            a0.update_scalar(s0, bv, i)
        if not bv.col_is_null(1, i):
            a1.update_scalar(s1, bv, i)
        if not bv.col_is_null(2, i):
            a2.update_scalar(s2, bv, i)
        if not bv.col_is_null(3, i):
            a3.update_scalar(s3, bv, i)
    assert_equal(HashAggOpF64Agg[_SumF64, 0].finalize(s0), 12.0)
    assert_equal(HashAggOpI64Agg[_SumI64, 1].finalize(s1), Int64(31))
    assert_equal(HashAggOpI32Agg[_MaxI32, 2].finalize(s2), Int32(9))
    assert_equal(HashAggOpF32Agg[_MinF32, 3].finalize(s3), Float32(-2.5))


# =============================================================================
# The Aggregator default methods
# =============================================================================


def test_default_update_chunk_masks_and_bounds() raises:
    """`update_chunk[8]` folds only lanes that are in bounds AND valid.
    Chunks at 0 and 8 over the 9-row slice (lanes 1..7 of the second chunk
    are past the end) with the not-null mask give SUM = 12.0; an all-False
    mask, and a chunk starting at the end, add nothing."""
    var batch = _sliced_batch()
    var bv = batch_view_over(batch)
    var a = HashAggOpF64Agg[_SumF64, 0]()
    var s = HashAggOpF64Agg[_SumF64, 0].init()
    a.update_chunk[8](s, bv, 0, SIMD[DType.bool, 8](fill=False))
    assert_equal(s, 0.0)
    a.update_chunk[8](s, bv, 0, _valid_mask(bv, 0, 0))
    a.update_chunk[8](s, bv, 8, _valid_mask(bv, 0, 8))
    assert_equal(s, 12.0)
    a.update_chunk[8](s, bv, bv.n_rows(), SIMD[DType.bool, 8](fill=True))
    assert_equal(s, 12.0)


def test_default_update_chunk_mv_masks_and_bounds() raises:
    """The MorselView sibling `update_chunk_mv[8, BatchView]`: SUM(i64) = 31
    and MIN(f32) = -2.5 from the not-null masks, nothing from an all-False
    mask or a chunk starting at the end."""
    var batch = _sliced_batch()
    var bv = batch_view_over(batch)
    var a = HashAggOpI64Agg[_SumI64, 1]()
    var s = HashAggOpI64Agg[_SumI64, 1].init()
    a.update_chunk_mv[8](s, bv, 0, SIMD[DType.bool, 8](fill=False))
    assert_equal(s, Int64(0))
    a.update_chunk_mv[8](s, bv, 0, _valid_mask(bv, 1, 0))
    a.update_chunk_mv[8](s, bv, 8, _valid_mask(bv, 1, 8))
    assert_equal(s, Int64(31))
    a.update_chunk_mv[8](s, bv, bv.n_rows(), SIMD[DType.bool, 8](fill=True))
    assert_equal(s, Int64(31))
    # f32's nulls sit in other lanes (slice rows 2 and 6), so between the two
    # columns every lane of the first chunk folds a valid row once.
    var b = HashAggOpF32Agg[_MinF32, 3]()
    var m = HashAggOpF32Agg[_MinF32, 3].init()
    b.update_chunk_mv[8](m, bv, 0, _valid_mask(bv, 3, 0))
    b.update_chunk_mv[8](m, bv, 8, _valid_mask(bv, 3, 8))
    assert_equal(m, Float32(-2.5))


def test_default_distinct_and_exact_sum_hooks() raises:
    """A non-distinct, non-exact-sum aggregator inherits the documented
    defaults: `total_fits_i64` True, no distinct values or runs, and
    `take_distinct_into` leaves both states as they were."""
    assert_false(HashAggOpF64Agg[_SumF64, 0].EXACT_INT_SUM)
    assert_false(HashAggOpF64Agg[_SumF64, 0].IS_DISTINCT)
    assert_false(HashAggOpF64Agg[_SumF64, 0].PARALLEL_SORT_FINALIZE)
    assert_equal(HashAggOpF64Agg[_SumF64, 0].STATE_SIZE, 8)
    var a = HashAggOpF64Agg[_SumF64, 0]()
    var dst = Float64(1.5)
    var src = Float64(2.5)
    assert_true(HashAggOpF64Agg[_SumF64, 0].total_fits_i64(dst))
    assert_equal(len(a.distinct_values(dst)), 0)
    assert_equal(len(a.distinct_runs(dst)), 0)
    a.take_distinct_into(dst, src)
    assert_equal(dst, 1.5)
    assert_equal(src, 2.5)


# =============================================================================
# SUM(a * b)
# =============================================================================


def test_sum_product_sliced() raises:
    """SUM(a * b) over the slice [1, 5) of a 6-row batch: products 3.0, 0.5,
    -4.0, 2.0 sum to 1.5; the outside rows (100 * 100 twice) would add 20000.
    A two-partial `combine` gives the same."""
    var av: List[Float64] = [100.0, 1.5, 2.0, -0.5, 4.0, 100.0]
    var bvv: List[Float64] = [100.0, 2.0, 0.25, 8.0, 0.5, 100.0]
    var none: List[Bool] = [False, False, False, False, False, False]
    var sb = SchemaBuilder()
    sb.add_field(Field("a", DType.float64, False))
    sb.add_field(Field("b", DType.float64, False))
    var batch = RecordBatch.from_typed_columns_2(
        sb.build(),
        _col[DType.float64](av, none).materialize().slice(1, 4),
        _col[DType.float64](bvv, none).materialize().slice(1, 4),
    )
    var bv = batch_view_over(batch)
    var agg = SumProductF64Agg[0, 1].make()
    var s = SumProductF64Agg[0, 1].init()
    for i in range(bv.n_rows()):
        agg.update_scalar(s, bv, i)
    assert_equal(SumProductF64Agg[0, 1].finalize(s), 1.5)
    var left = SumProductF64Agg[0, 1].init()
    var right = SumProductF64Agg[0, 1].init()
    agg.update_scalar(left, bv, 0)
    for i in range(1, bv.n_rows()):
        agg.update_scalar(right, bv, i)
    agg.combine(left, right)
    assert_equal(SumProductF64Agg[0, 1].finalize(left), 1.5)


# =============================================================================
# CORR(x, y)
# =============================================================================


def _corr_batch() raises -> RecordBatch:
    var x64: List[Float64] = [1.0, 2.0, 3.0, 4.0]
    var y64: List[Int64] = [1, 3, 2, 4]
    var x32: List[Int32] = [1, 2, 3, 4]
    var y32: List[Float32] = [1.0, 3.0, 2.0, 4.0]
    var none: List[Bool] = [False, False, False, False]
    var sb = SchemaBuilder()
    sb.add_field(Field("x64", DType.float64, False))
    sb.add_field(Field("y64", DType.int64, False))
    sb.add_field(Field("x32", DType.int32, False))
    sb.add_field(Field("y32", DType.float32, False))
    return RecordBatch.from_typed_columns_4(
        sb.build(),
        _col[DType.float64](x64, none).materialize(),
        _col[DType.int64](y64, none).materialize(),
        _col[DType.int32](x32, none).materialize(),
        _col[DType.float32](y32, none).materialize(),
    )


def _close(got: Float64, want: Float64) -> Bool:
    return abs(got - want) <= 1e-12


def _corr_all[
    A: Aggregator, o: Origin[mut=False]
](mut a: A, bv: BatchView[o]) -> A.StateTy:
    var s = A.init()
    for i in range(bv.n_rows()):
        a.update_scalar(s, bv, i)
    return s^


def test_corr_reads_every_input_type() raises:
    """CORR([1,2,3,4], [1,3,2,4]) = 0.8, read as (f64, i64) and as (i32, f32):
    the four arms of the CORR input ladder."""
    var batch = _corr_batch()
    var bv = batch_view_over(batch)
    var a = CorrF64Agg[DType.float64, DType.int64, 0, 1].make()
    var r1 = CorrF64Agg[DType.float64, DType.int64, 0, 1].finalize(_corr_all(a, bv))
    assert_true(_close(r1, 0.8), "corr(f64, i64) = " + String(r1))
    var b = CorrF64Agg[DType.int32, DType.float32, 2, 3].make()
    var r2 = CorrF64Agg[DType.int32, DType.float32, 2, 3].finalize(_corr_all(b, bv))
    assert_true(_close(r2, 0.8), "corr(i32, f32) = " + String(r2))


def test_corr_combine_identity_and_split() raises:
    """`combine` with an empty partial on either side leaves the state's CORR
    unchanged; two partials (rows [0, 2) and [2, 4)) merge to 0.8."""
    comptime C = CorrF64Agg[DType.float64, DType.int64, 0, 1]
    var batch = _corr_batch()
    var bv = batch_view_over(batch)
    var a = C()
    var full = _corr_all(a, bv)
    assert_equal(full.n, Int64(4))

    var into_empty = C.init()
    a.combine(into_empty, full)
    assert_true(_close(C.finalize(into_empty), 0.8), "init <- full")
    assert_equal(into_empty.n, Int64(4))

    var keep = full
    a.combine(keep, C.init())
    assert_true(_close(C.finalize(keep), 0.8), "full <- init")
    assert_equal(keep.n, Int64(4))

    var left = C.init()
    var right = C.init()
    a.update_scalar(left, bv, 0)
    a.update_scalar(left, bv, 1)
    a.update_scalar(right, bv, 2)
    a.update_scalar(right, bv, 3)
    a.combine(left, right)
    assert_true(_close(C.finalize(left), 0.8), "split [0,2)+[2,4)")
    assert_equal(left.n, Int64(4))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

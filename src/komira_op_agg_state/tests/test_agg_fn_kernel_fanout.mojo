# =============================================================================
# test_agg_fn_kernel_fanout.mojo — EXECUTOR-KERNEL-COMPTIME Phase 1.d regression
# =============================================================================
#
# Exercises the Phase 1.d deliverables:
#
#   - SumI64.init/update/merge/finalize correctness (canonical cell).
#   - Sum widening: SumI8 over 100K * 127 doesn't overflow (widens to I64).
#   - Float NaN/Inf propagation through SumF64.
#   - MinI64 / MaxI64 with all-null input: state.seen stays False.
#   - AvgF64: (sum=10, count=4) -> finalize 2.5.
#   - CountI64 unconditional +1; PROPAGATE-null filter is on AggFnAcc, not
#     the kernel.
#   - FirstI64 / LastI64: First sticks after first row; Last overwrites.
#   - SumI64Vec.update_chunk byte-identical to scalar update_scalar loop on
#     a 4097-row mixed-magnitude Int64 sequence.
#   - Distinct monomorphizations: KERNEL_IDs distinct across 10+ cells.
#   - AggFnAcc[SumI64] end-to-end via update_record_batch on a 64-row batch
#     produces correct output (acts as the end-to-end gate against the
#     existing AggFnAcc operator path).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, SchemaBuilder, RecordBatch, RecordBatchBuilder,
)
from komira_udf.agg_fn import AggFn
from komira_op_agg_state.agg_fn_acc import AggFnAcc

from komira_agg.builtin_agg_fns_states import (
    RowI64, RowF64,
    SumStateI64, SumStateF64,
    MinMaxStateI64, MinMaxStateF64,
    CountState, AvgStateF64,
)
from komira_agg.builtin_agg_fns_sum import (
    SumI8, SumI16, SumI32, SumI64, SumU64, SumF32, SumF64,
)
from komira_agg.builtin_agg_fns_minmax import (
    MinI8, MinI64, MinF64, MaxI8, MaxI64, MaxF64,
)
from komira_agg.builtin_agg_fns_count import (
    CountI8, CountI64, CountF64,
)
from komira_agg.builtin_agg_fns_avg import AvgI64, AvgF64
from komira_agg.builtin_agg_fns_firstlast import (
    FirstI64, LastI64, FirstF64, LastF64,
)
from komira_agg.builtin_agg_fns_bool import AnyBool, AllBool, CountBool
from komira_agg.builtin_agg_fns_vec import (
    SumI64Vec, SumF64Vec, MinI64Vec, MaxI64Vec, CountI64Vec, AvgF64Vec,
)
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Fixture helpers
# =============================================================================


def _i64_col(name: String, vals: List[Int64], nulls: List[Int]) raises -> Column[HeapRegion]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, vals[i])
    for k in range(len(nulls)):
        # _set_null now bumps null_count itself (fix); no manual +=.
        arr._set_null(nulls[k])
    return Column.from_primitive[DType.int64](arr^)


def _f64_col(name: String, vals: List[Float64], nulls: List[Int]) raises -> Column[HeapRegion]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, vals[i])
    for k in range(len(nulls)):
        # _set_null now bumps null_count itself (fix); no manual +=.
        arr._set_null(nulls[k])
    return Column.from_primitive[DType.float64](arr^)


def _i64_batch(name: String, vals: List[Int64], nulls: List[Int]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, True))
    var b = RecordBatchBuilder()
    b.add_column(_i64_col(name, vals, nulls))
    return b.build(sb.build())


def _f64_batch(name: String, vals: List[Float64], nulls: List[Int]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, True))
    var b = RecordBatchBuilder()
    b.add_column(_f64_col(name, vals, nulls))
    return b.build(sb.build())


# =============================================================================
# (a) SumI64 unit checks: init, update, merge, finalize, associativity
# =============================================================================


def test_sum_i64_init_is_zero() raises:
    var f = SumI64()
    var s = f.init()
    assert_equal(Int(s.sum), 0)


def test_sum_i64_update_then_finalize() raises:
    var f = SumI64()
    var s = f.init()
    f.update(s, RowI64(Int64(42)))
    var out = f.finalize(s)
    assert_equal(Int(out), 42)


def test_sum_i64_merge_associative_commutative() raises:
    var f = SumI64()
    var a = SumStateI64(Int64(7))
    var b = SumStateI64(Int64(11))
    var c = SumStateI64(Int64(13))
    # (a+b)+c == a+(b+c)
    var ab = f.merge(a, b)
    var abc1 = f.merge(ab, c)
    var bc = f.merge(b, c)
    var abc2 = f.merge(a, bc)
    assert_equal(Int(abc1.sum), Int(abc2.sum))
    # commutativity
    var ba = f.merge(b, a)
    assert_equal(Int(ab.sum), Int(ba.sum))


# =============================================================================
# (b) SumF64 NaN/Inf propagation
# =============================================================================


def test_sum_f64_nan_propagates() raises:
    var f = SumF64()
    var s = f.init()
    var nan_val: Float64 = Float64(0.0) / Float64(0.0)
    f.update(s, RowF64(nan_val))
    f.update(s, RowF64(Float64(1.0)))
    var out = f.finalize(s)
    # NaN + 1.0 == NaN; check via self-inequality (only NaN != itself).
    assert_true(out != out)


def test_sum_f64_inf_saturates() raises:
    var f = SumF64()
    var s = f.init()
    var inf: Float64 = Float64(1.0) / Float64(0.0)
    f.update(s, RowF64(inf))
    f.update(s, RowF64(Float64(1.0)))
    var out = f.finalize(s)
    assert_true(out > Float64(1e300))


# =============================================================================
# (c) SumI8 overflow widening to I64
# =============================================================================


def test_sum_i8_widens_to_i64_no_overflow() raises:
    var f = SumI8()
    var s = f.init()
    # 100K rows of 127 (max-i8): scalar i8 would overflow at row 2; our
    # widened state should handle ~12.7M as Int64.
    for _ in range(100_000):
        f.update_scalar(s, Int8(127))
    var out = f.finalize(s)
    assert_equal(Int(out), 12_700_000)


# =============================================================================
# (d) MinI64 / MaxI64 with all-null input (no updates)
# =============================================================================


def test_min_i64_unseen_state_stays_unseen() raises:
    var f = MinI64()
    var s = f.init()
    assert_false(s.seen)
    # No updates - state remains identity sentinel + unseen.
    assert_equal(Int(s.value), 9223372036854775807)


def test_max_i64_unseen_state_stays_unseen() raises:
    var f = MaxI64()
    var s = f.init()
    assert_false(s.seen)
    assert_equal(Int(s.value), -9223372036854775808)


def test_min_i64_with_values() raises:
    var f = MinI64()
    var s = f.init()
    f.update_scalar(s, Int64(5))
    f.update_scalar(s, Int64(2))
    f.update_scalar(s, Int64(7))
    assert_true(s.seen)
    assert_equal(Int(s.value), 2)


def test_max_i64_with_values() raises:
    var f = MaxI64()
    var s = f.init()
    f.update_scalar(s, Int64(5))
    f.update_scalar(s, Int64(2))
    f.update_scalar(s, Int64(7))
    assert_true(s.seen)
    assert_equal(Int(s.value), 7)


# =============================================================================
# (e) AvgF64 finalize semantics
# =============================================================================


def test_avg_f64_basic() raises:
    var f = AvgF64()
    var s = AvgStateF64(Float64(10.0), Int64(4))
    var out = f.finalize(s)
    assert_almost_equal(out, Float64(2.5))


def test_avg_f64_empty_returns_zero() raises:
    var f = AvgF64()
    var s = f.init()
    var out = f.finalize(s)
    # count == 0 -> finalize returns 0.0 (safety; SQL would emit NULL via
    # OutputSchema nullability, but the kernel itself returns 0.0).
    assert_almost_equal(out, Float64(0.0))


# =============================================================================
# (f) CountI64 unconditional +1; PROPAGATE-null is on AggFnAcc
# =============================================================================


def test_count_i64_increments() raises:
    var f = CountI64()
    var s = f.init()
    f.update_scalar(s, Int64(0))   # value doesn't matter
    f.update_scalar(s, Int64(0))
    f.update_scalar(s, Int64(0))
    assert_equal(Int(s.count), 3)


# =============================================================================
# (g) First / Last semantics
# =============================================================================


def test_first_i64_sticks_after_first_update() raises:
    var f = FirstI64()
    var s = f.init()
    f.update_scalar(s, Int64(42))
    f.update_scalar(s, Int64(99))
    f.update_scalar(s, Int64(-1))
    assert_equal(Int(s.value), 42)
    assert_true(s.seen)


def test_last_i64_overwrites() raises:
    var f = LastI64()
    var s = f.init()
    f.update_scalar(s, Int64(42))
    f.update_scalar(s, Int64(99))
    f.update_scalar(s, Int64(-1))
    assert_equal(Int(s.value), -1)


# =============================================================================
# (h) *Vec cells — scalar fold parity with their non-Vec siblings
# (WAVE-11-UDF-F: the user-facing vectorized agg sub-trait
# was deleted; the update_chunk[W,*Ts] SIMD reduce paths were removed
# alongside it. The *Vec cells remain as distinct conformers carrying
# distinct UDF_IDs; the scalar fold body is unchanged so the per-lane
# oracle behavior is byte-identical to their non-Vec siblings. The SIMD
# fast-path surface is now the engine-internal `_AggFnFusedKernel`
# opt-in.)
# =============================================================================


def test_sum_i64_vec_matches_scalar_4097_rows() raises:
    """SumI64Vec.update_scalar on 4097 mixed-magnitude rows must match
    SumI64.update_scalar's row-by-row sum byte-for-byte (the same scalar
    body — the *Vec cell only differs in UDF_ID for plan-CSE keying)."""
    var n = 4097

    # Scalar reference: sum row-by-row via SumI64.
    var fs = SumI64()
    var s_scalar = fs.init()
    var lcg_state = UInt64(0xC0FFEE_C0FFEE)
    for i in range(n):
        # cheap LCG for mixed-magnitude inputs
        lcg_state = lcg_state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        var v = Int64(Int(lcg_state & UInt64(0x7FFFFFFFFFFFFFFF))) - Int64(1 << 62)
        fs.update_scalar(s_scalar, v)

    # Vec path: replay the same sequence via update_scalar (the
    # update_chunk path is gone post-WAVE-11-UDF-F).
    var fv = SumI64Vec()
    var s_vec = fv.init()
    lcg_state = UInt64(0xC0FFEE_C0FFEE)
    for i in range(n):
        lcg_state = lcg_state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        var v = Int64(Int(lcg_state & UInt64(0x7FFFFFFFFFFFFFFF))) - Int64(1 << 62)
        fv.update_scalar(s_vec, v)

    assert_equal(Int(s_scalar.sum), Int(s_vec.sum))


def test_min_i64_vec_matches_scalar() raises:
    var fv = MinI64Vec()
    var s = fv.init()
    fv.update_scalar(s, Int64(5))
    fv.update_scalar(s, Int64(2))
    fv.update_scalar(s, Int64(7))
    fv.update_scalar(s, Int64(-3))
    assert_equal(Int(s.value), -3)
    assert_true(s.seen)


def test_max_i64_vec_matches_scalar() raises:
    var fv = MaxI64Vec()
    var s = fv.init()
    fv.update_scalar(s, Int64(5))
    fv.update_scalar(s, Int64(2))
    fv.update_scalar(s, Int64(7))
    fv.update_scalar(s, Int64(-3))
    assert_equal(Int(s.value), 7)


def test_count_i64_vec_basic() raises:
    """CountI64Vec.update_scalar counts unconditionally per call.
    The PROPAGATE-null filter is on AggFnAcc, not the kernel."""
    var fv = CountI64Vec()
    var s = fv.init()
    fv.update_scalar(s, Int64(1))
    fv.update_scalar(s, Int64(3))
    fv.update_scalar(s, Int64(4))
    assert_equal(Int(s.count), 3)


def test_avg_f64_vec_basic() raises:
    var fv = AvgF64Vec()
    var s = fv.init()
    fv.update_scalar(s, Float64(1.0))
    fv.update_scalar(s, Float64(2.0))
    fv.update_scalar(s, Float64(3.0))
    fv.update_scalar(s, Float64(4.0))
    var out = fv.finalize(s)
    assert_almost_equal(out, Float64(2.5))
    assert_equal(Int(s.count), 4)


def test_sum_f64_vec_masked() raises:
    """SumF64Vec.update_scalar on the 2 valid lanes (skip masked
    lanes at the caller — AggFnAcc handles the validity filter for
    the engine path)."""
    var fv = SumF64Vec()
    var s = fv.init()
    fv.update_scalar(s, Float64(1.0))
    fv.update_scalar(s, Float64(3.0))
    var out = fv.finalize(s)
    assert_almost_equal(out, Float64(4.0))


# =============================================================================
# (i) Compile-time distinct monomorphizations
# =============================================================================


def test_kernel_ids_distinct() raises:
    """KERNEL_IDs (UDF_ID on the trait — Phase 1.d reuses MapFn's UDF_ID
    field as the kernel identifier) must be pairwise distinct across the
    10+ conformer cells we instantiate here. If two cells return the same
    ID the registry can't tell them apart for plan-cache."""
    # 16 cells across 6 ops
    var ids = List[UInt32]()
    ids.append(SumI8.UDF_ID)
    ids.append(SumI16.UDF_ID)
    ids.append(SumI32.UDF_ID)
    ids.append(SumI64.UDF_ID)
    ids.append(SumU64.UDF_ID)
    ids.append(SumF32.UDF_ID)
    ids.append(SumF64.UDF_ID)
    ids.append(MinI64.UDF_ID)
    ids.append(MaxI64.UDF_ID)
    ids.append(MinF64.UDF_ID)
    ids.append(MaxF64.UDF_ID)
    ids.append(CountI64.UDF_ID)
    ids.append(AvgI64.UDF_ID)
    ids.append(AvgF64.UDF_ID)
    ids.append(FirstI64.UDF_ID)
    ids.append(LastI64.UDF_ID)
    ids.append(SumI64Vec.UDF_ID)
    ids.append(MinI64Vec.UDF_ID)
    ids.append(CountI64Vec.UDF_ID)
    ids.append(AnyBool.UDF_ID)
    ids.append(AllBool.UDF_ID)

    # pair-wise distinct
    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            assert_true(
                UInt32(ids[i]) != UInt32(ids[j]),
                "duplicate KERNEL_ID found",
            )


# =============================================================================
# (j) AggFnAcc[SumI64] end-to-end via Morsel.execute
# =============================================================================


def test_agg_fn_acc_sum_i64_end_to_end() raises:
    """AggFnAcc[SumI64] on a 64-row batch over 2 gids — output column should
    match the gid-wise running sum of the input."""
    var acc = AggFnAcc[SumI64](SumI64())
    acc.ensure_capacity(2)

    var n = 64
    var vals = List[Int64]()
    var gids = List[Int]()
    var expected_g0: Int64 = 0
    var expected_g1: Int64 = 0
    for i in range(n):
        vals.append(Int64(i + 1))
        if i & 1 == 0:
            gids.append(0)
            expected_g0 += Int64(i + 1)
        else:
            gids.append(1)
            expected_g1 += Int64(i + 1)

    acc.update_record_batch(gids, _i64_batch("v", vals, []))
    var out = acc.finalize_to_column().as_primitive[DType.int64]()
    assert_equal(Int(out.get(0)), Int(expected_g0))
    assert_equal(Int(out.get(1)), Int(expected_g1))


def test_agg_fn_acc_avg_f64_end_to_end() raises:
    """AggFnAcc[AvgF64] on a 4-row batch."""
    var acc = AggFnAcc[AvgF64](AvgF64())
    acc.ensure_capacity(1)
    acc.update_record_batch([0, 0, 0, 0], _f64_batch("v", [1.0, 2.0, 3.0, 4.0], []))
    var out = acc.finalize_to_column().as_primitive[DType.float64]()
    assert_almost_equal(out.get(0), Float64(2.5))


def test_agg_fn_acc_min_i64_end_to_end() raises:
    """AggFnAcc[MinI64] over 2 gids."""
    var acc = AggFnAcc[MinI64](MinI64())
    acc.ensure_capacity(2)
    acc.update_record_batch(
        [0, 1, 0, 1, 0],
        _i64_batch("v", [Int64(5), Int64(20), Int64(2), Int64(7), Int64(99)], []),
    )
    var out = acc.finalize_to_column().as_primitive[DType.int64]()
    assert_equal(Int(out.get(0)), 2)
    assert_equal(Int(out.get(1)), 7)


def test_agg_fn_acc_count_i64_end_to_end() raises:
    """AggFnAcc[CountI64] over 2 gids, with one null row that AggFnAcc skips."""
    var acc = AggFnAcc[CountI64](CountI64())
    acc.ensure_capacity(2)
    acc.update_record_batch(
        [0, 0, 1, 0, 1],
        _i64_batch("v", [Int64(1), Int64(2), Int64(3), Int64(4), Int64(5)], [3]),
    )
    var out = acc.finalize_to_column().as_primitive[DType.int64]()
    # g0: rows 0, 1, 3 -> 3 rows; but row 3 is null (PROPAGATE skips) -> 2 counted
    # g1: rows 2, 4 -> 2 rows
    assert_equal(Int(out.get(0)), 2)
    assert_equal(Int(out.get(1)), 2)


def test_agg_fn_acc_merge_aligned() raises:
    """SumI64 across two AggFnAccs via merge_aligned."""
    var a = AggFnAcc[SumI64](SumI64())
    var b = AggFnAcc[SumI64](SumI64())
    a.ensure_capacity(2)
    b.ensure_capacity(2)
    a.update_record_batch([0, 1], _i64_batch("v", [Int64(10), Int64(20)], []))
    b.update_record_batch([0, 1], _i64_batch("v", [Int64(100), Int64(200)], []))
    a.merge_aligned(b)
    var out = a.finalize_to_column().as_primitive[DType.int64]()
    assert_equal(Int(out.get(0)), 110)
    assert_equal(Int(out.get(1)), 220)


# =============================================================================
# (k) Bool aggregations
# =============================================================================


def test_any_bool() raises:
    var f = AnyBool()
    var s = f.init()
    f.update_scalar(s, False)
    f.update_scalar(s, False)
    f.update_scalar(s, True)
    f.update_scalar(s, False)
    assert_true(s.value)


def test_all_bool() raises:
    var f = AllBool()
    var s = f.init()
    f.update_scalar(s, True)
    f.update_scalar(s, True)
    f.update_scalar(s, False)
    f.update_scalar(s, True)
    assert_false(s.value)


def test_all_bool_all_true() raises:
    var f = AllBool()
    var s = f.init()
    f.update_scalar(s, True)
    f.update_scalar(s, True)
    f.update_scalar(s, True)
    assert_true(s.value)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

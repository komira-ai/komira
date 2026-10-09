# =============================================================================
# test_acc_factory_readback.mojo — every make_single_dyn_acc tag, read back
# through its vtable: per-gid finalize, merge_at, merge_aligned
# =============================================================================
#
# `make_single_dyn_acc(tag)` wires ten vtable slots per accumulator type. The
# round-trip test beside this one checks the tag and that the new f64 tags do
# not raise; this one checks VALUES, so a slot wired to the wrong thunk (MIN's
# finalize reading MAX's state, a merge that folds the wrong gid) answers wrong.
#
# Each case puts known rows into gids 0 and 1 of a 3-group accumulator (gid 2
# is never seen), then reads:
#   - the per-gid finalize of its kind, including the documented sentinels
#     (0 / None / 0.0) for an unseen and an out-of-range gid;
#   - the three other finalize slots, which are the defaults for this kind;
#   - merge_at(2, other, 0) and merge_aligned(other), against hand sums.
# Rows go in through the trait `update_batch` with a column offset of 1, so a
# kernel that ignored the offset would read the poison value in slot 0.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_op_agg_state.accumulator_factory import make_single_dyn_acc
from komira_op_agg_state.dyn_accumulator import DynAccumulator
from komira_op_agg_state.columnar_acc_typed import (
    SumI64Acc, CountI64Acc, MinI64Acc, MaxI64Acc, SumF64KahanAcc,
)
from komira_op_agg_state.columnar_acc_typed_extra import (
    CountStarAcc, MinF64Acc, MaxF64Acc, AvgAcc,
)
from komira_op_agg_state.columnar_acc_utf8 import MinUtf8Acc, MaxUtf8Acc
from komira_op_agg_state.columnar_acc_agg import PercentileAcc
from komira_op_agg_state.columnar_agg_accumulator import (
    ACC_MIN_UTF8, ACC_MAX_UTF8, ACC_SUM_INT64, ACC_COUNT_INT64,
    ACC_MIN_INT64, ACC_MAX_INT64, ACC_PERCENTILE_F64, ACC_SUM_F64,
    ACC_COUNT_STAR, ACC_MIN_F64, ACC_MAX_F64, ACC_AVG,
)


# =============================================================================
# Helpers
# =============================================================================


def _bytes_i64(mut vals: List[Int64]) -> Span[UInt8, origin_of(vals)]:
    return Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=len(vals) * 8
    )


def _bytes_f64(mut vals: List[Float64]) -> Span[UInt8, origin_of(vals)]:
    return Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=len(vals) * 8
    )


def _gids() -> List[Int]:
    """Rows 0..3 go to groups 0, 1, 0, 1; group 2 is never seen."""
    return [0, 1, 0, 1]


def _i64_rows(a: Int64, b: Int64, c: Int64, d: Int64) -> List[Int64]:
    """Slot 0 is poison (skipped by col_offset=1)."""
    return [Int64(999_999), a, b, c, d]


def _f64_rows(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    return [Float64(999_999.0), a, b, c, d]


def _assert_int_defaults(dyn: DynAccumulator) raises:
    """An integer accumulator's utf8 / f64 slots are the default sentinels."""
    assert_false(Bool(dyn.finalize_utf8(0)))
    assert_equal(dyn.finalize_f64(0), Float64(0.0))
    assert_false(Bool(dyn.finalize_f64_optional(0)))


def _assert_f64_int_utf8_defaults(dyn: DynAccumulator) raises:
    assert_equal(dyn.finalize_int64(0), Int64(0))
    assert_false(Bool(dyn.finalize_utf8(0)))


# =============================================================================
# Int64 kinds
# =============================================================================


def _make_i64(tag: UInt8, a: Int64, b: Int64, c: Int64, d: Int64) raises -> DynAccumulator:
    var dyn = make_single_dyn_acc(tag)
    assert_equal(Int(dyn.tag), Int(tag))
    dyn.ensure_capacity(3)
    var g = _gids()
    var v = _i64_rows(a, b, c, d)
    if tag == ACC_SUM_INT64:
        dyn.as_mut[SumI64Acc]().update_batch(Span(g), _bytes_i64(v), 1, 4)
    elif tag == ACC_COUNT_INT64:
        dyn.as_mut[CountI64Acc]().update_batch(Span(g), _bytes_i64(v), 1, 4)
    elif tag == ACC_MIN_INT64:
        dyn.as_mut[MinI64Acc]().update_batch(Span(g), _bytes_i64(v), 1, 4)
    else:
        dyn.as_mut[MaxI64Acc]().update_batch(Span(g), _bytes_i64(v), 1, 4)
    return dyn^


def test_sum_int64_readback_and_merges() raises:
    var a = _make_i64(ACC_SUM_INT64, 5, -3, 7, 10)
    assert_equal(a.finalize_int64(0), Int64(12))
    assert_equal(a.finalize_int64(1), Int64(7))
    assert_equal(a.finalize_int64(2), Int64(0))
    assert_equal(a.finalize_int64(3), Int64(0), "out of range gid -> 0")
    _assert_int_defaults(a)
    var b = _make_i64(ACC_SUM_INT64, 100, 200, 1, 2)
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_int64(2), Int64(101))
    a.merge_aligned(b)
    assert_equal(a.finalize_int64(0), Int64(113))
    assert_equal(a.finalize_int64(1), Int64(209))
    assert_equal(a.finalize_int64(2), Int64(101))
    assert_equal(a.num_groups(), 3)


def test_count_int64_readback_and_merges() raises:
    var a = _make_i64(ACC_COUNT_INT64, 5, -3, 7, 10)
    assert_equal(a.finalize_int64(0), Int64(2))
    assert_equal(a.finalize_int64(1), Int64(2))
    assert_equal(a.finalize_int64(2), Int64(0))
    assert_equal(a.finalize_int64(7), Int64(0))
    _assert_int_defaults(a)
    var b = _make_i64(ACC_COUNT_INT64, 1, 1, 1, 1)
    b.as_mut[CountI64Acc]().state[0] = 5
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_int64(2), Int64(5))
    a.merge_aligned(b)
    assert_equal(a.finalize_int64(0), Int64(7))
    assert_equal(a.finalize_int64(1), Int64(4))
    assert_equal(a.finalize_int64(2), Int64(5))


def test_min_int64_readback_and_merges() raises:
    var a = _make_i64(ACC_MIN_INT64, 5, -3, 7, 10)
    assert_equal(a.finalize_int64(0), Int64(5))
    assert_equal(a.finalize_int64(1), Int64(-3))
    assert_equal(a.finalize_int64(2), Int64(0), "unseen gid -> 0")
    assert_equal(a.finalize_int64(3), Int64(0))
    _assert_int_defaults(a)
    var b = _make_i64(ACC_MIN_INT64, 4, 50, 60, 70)
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_int64(2), Int64(4))
    a.merge_aligned(b)
    assert_equal(a.finalize_int64(0), Int64(4))
    assert_equal(a.finalize_int64(1), Int64(-3))


def test_max_int64_readback_and_merges() raises:
    var a = _make_i64(ACC_MAX_INT64, 5, -3, 7, 10)
    assert_equal(a.finalize_int64(0), Int64(7))
    assert_equal(a.finalize_int64(1), Int64(10))
    assert_equal(a.finalize_int64(2), Int64(0), "unseen gid -> 0")
    assert_equal(a.finalize_int64(3), Int64(0))
    _assert_int_defaults(a)
    var b = _make_i64(ACC_MAX_INT64, 40, 5, 6, 7)
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_int64(2), Int64(40))
    a.merge_aligned(b)
    assert_equal(a.finalize_int64(0), Int64(40))
    assert_equal(a.finalize_int64(1), Int64(10))


# =============================================================================
# Utf8 kinds
# =============================================================================


def _make_utf8(tag: UInt8, a: String, b: String, c: String, d: String) raises -> DynAccumulator:
    var dyn = make_single_dyn_acc(tag)
    assert_equal(Int(dyn.tag), Int(tag))
    dyn.ensure_capacity(3)
    var g: List[UInt32] = [UInt32(0), UInt32(1), UInt32(0), UInt32(1)]
    var v: List[String] = [a, b, c, d]
    if tag == ACC_MIN_UTF8:
        dyn.as_mut[MinUtf8Acc]().update_batch(g, v, 4)
    else:
        dyn.as_mut[MaxUtf8Acc]().update_batch(g, v, 4)
    return dyn^


def _assert_utf8_defaults(dyn: DynAccumulator) raises:
    assert_equal(dyn.finalize_int64(0), Int64(0))
    assert_equal(dyn.finalize_f64(0), Float64(0.0))
    assert_false(Bool(dyn.finalize_f64_optional(0)))


def test_min_utf8_readback_and_merges() raises:
    var a = _make_utf8(ACC_MIN_UTF8, "pear", "fig", "apple", "kiwi")
    assert_equal(a.finalize_utf8(0).value(), "apple")
    assert_equal(a.finalize_utf8(1).value(), "fig")
    assert_false(Bool(a.finalize_utf8(2)), "unseen gid -> None")
    assert_false(Bool(a.finalize_utf8(3)), "out of range gid -> None")
    _assert_utf8_defaults(a)
    var b = _make_utf8(ACC_MIN_UTF8, "aardvark", "zebra", "yak", "zoo")
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_utf8(2).value(), "aardvark")
    a.merge_aligned(b)
    assert_equal(a.finalize_utf8(0).value(), "aardvark")
    assert_equal(a.finalize_utf8(1).value(), "fig")


def test_max_utf8_readback_and_merges() raises:
    var a = _make_utf8(ACC_MAX_UTF8, "pear", "fig", "apple", "kiwi")
    assert_equal(a.finalize_utf8(0).value(), "pear")
    assert_equal(a.finalize_utf8(1).value(), "kiwi")
    assert_false(Bool(a.finalize_utf8(2)))
    assert_false(Bool(a.finalize_utf8(3)))
    _assert_utf8_defaults(a)
    var b = _make_utf8(ACC_MAX_UTF8, "zebra", "apple", "a", "b")
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_utf8(2).value(), "zebra")
    a.merge_aligned(b)
    assert_equal(a.finalize_utf8(0).value(), "zebra")
    assert_equal(a.finalize_utf8(1).value(), "kiwi")


# =============================================================================
# Float64 kinds
# =============================================================================


def _make_f64(tag: UInt8, a: Float64, b: Float64, c: Float64, d: Float64, q: Float64 = 0.5) raises -> DynAccumulator:
    var dyn = make_single_dyn_acc(tag, q)
    assert_equal(Int(dyn.tag), Int(tag))
    dyn.ensure_capacity(3)
    var g = _gids()
    var v = _f64_rows(a, b, c, d)
    if tag == ACC_SUM_F64:
        dyn.as_mut[SumF64KahanAcc]().update_batch(Span(g), _bytes_f64(v), 1, 4)
    elif tag == ACC_COUNT_STAR:
        dyn.as_mut[CountStarAcc]().update_batch(Span(g), _bytes_f64(v), 1, 4)
    elif tag == ACC_MIN_F64:
        dyn.as_mut[MinF64Acc]().update_batch(Span(g), _bytes_f64(v), 1, 4)
    elif tag == ACC_MAX_F64:
        dyn.as_mut[MaxF64Acc]().update_batch(Span(g), _bytes_f64(v), 1, 4)
    elif tag == ACC_AVG:
        dyn.as_mut[AvgAcc]().update_batch(Span(g), _bytes_f64(v), 1, 4)
    else:
        dyn.as_mut[PercentileAcc]().update_batch(Span(g), _bytes_f64(v), 1, 4)
    return dyn^


def test_sum_f64_readback_and_merges() raises:
    var a = _make_f64(ACC_SUM_F64, 1.5, -2.0, 2.25, 8.0)
    assert_equal(a.finalize_f64(0), Float64(3.75))
    assert_equal(a.finalize_f64(1), Float64(6.0))
    assert_equal(a.finalize_f64(2), Float64(0.0))
    assert_equal(a.finalize_f64(3), Float64(0.0), "out of range gid -> 0.0")
    assert_false(Bool(a.finalize_f64_optional(0)), "default vtable wiring: SUM(f64) has no nullable readback")
    _assert_f64_int_utf8_defaults(a)
    var b = _make_f64(ACC_SUM_F64, 10.0, 20.0, 0.5, 0.25)
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_f64(2), Float64(10.5))
    a.merge_aligned(b)
    assert_equal(a.finalize_f64(0), Float64(14.25))
    assert_equal(a.finalize_f64(1), Float64(26.25))


def test_count_star_readback_and_merges() raises:
    var a = _make_f64(ACC_COUNT_STAR, 1.0, 2.0, 3.0, 4.0)
    assert_equal(a.finalize_int64(0), Int64(2))
    assert_equal(a.finalize_int64(1), Int64(2))
    assert_equal(a.finalize_int64(2), Int64(0))
    assert_equal(a.finalize_int64(9), Int64(0))
    _assert_int_defaults(a)
    var b = _make_f64(ACC_COUNT_STAR, 1.0, 2.0, 3.0, 4.0)
    b.as_mut[CountStarAcc]().state[0] = 6
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_int64(2), Int64(6))
    a.merge_aligned(b)
    assert_equal(a.finalize_int64(0), Int64(8))
    assert_equal(a.finalize_int64(1), Int64(4))
    assert_equal(a.finalize_int64(2), Int64(6))


def test_min_f64_readback_and_merges() raises:
    var a = _make_f64(ACC_MIN_F64, 1.5, -2.0, 0.5, 8.0)
    assert_equal(a.finalize_f64(0), Float64(0.5))
    assert_equal(a.finalize_f64(1), Float64(-2.0))
    assert_equal(a.finalize_f64(2), Float64(0.0), "unseen gid -> 0.0")
    assert_equal(a.finalize_f64(3), Float64(0.0))
    assert_equal(a.finalize_f64_optional(1).value(), Float64(-2.0))
    assert_false(Bool(a.finalize_f64_optional(2)), "unseen gid -> None")
    assert_false(Bool(a.finalize_f64_optional(3)), "out of range gid -> None")
    _assert_f64_int_utf8_defaults(a)
    var b = _make_f64(ACC_MIN_F64, -7.0, 3.0, 9.0, 9.0)
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_f64(2), Float64(-7.0))
    a.merge_aligned(b)
    assert_equal(a.finalize_f64(0), Float64(-7.0))
    assert_equal(a.finalize_f64(1), Float64(-2.0))


def test_max_f64_readback_and_merges() raises:
    var a = _make_f64(ACC_MAX_F64, 1.5, -2.0, 0.5, 8.0)
    assert_equal(a.finalize_f64(0), Float64(1.5))
    assert_equal(a.finalize_f64(1), Float64(8.0))
    assert_equal(a.finalize_f64(2), Float64(0.0))
    assert_equal(a.finalize_f64(3), Float64(0.0))
    assert_equal(a.finalize_f64_optional(0).value(), Float64(1.5))
    assert_false(Bool(a.finalize_f64_optional(2)))
    assert_false(Bool(a.finalize_f64_optional(3)))
    _assert_f64_int_utf8_defaults(a)
    var b = _make_f64(ACC_MAX_F64, 70.0, 3.0, 9.0, 9.0)
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_f64(2), Float64(70.0))
    a.merge_aligned(b)
    assert_equal(a.finalize_f64(0), Float64(70.0))
    assert_equal(a.finalize_f64(1), Float64(9.0))


def test_avg_readback_and_merges() raises:
    var a = _make_f64(ACC_AVG, 1.0, -2.0, 4.0, 8.0)
    assert_equal(a.finalize_f64(0), Float64(2.5))
    assert_equal(a.finalize_f64(1), Float64(3.0))
    assert_equal(a.finalize_f64(2), Float64(0.0), "empty group -> 0.0")
    assert_equal(a.finalize_f64(3), Float64(0.0))
    assert_equal(a.finalize_f64_optional(1).value(), Float64(3.0))
    assert_false(Bool(a.finalize_f64_optional(2)), "empty group -> None")
    assert_false(Bool(a.finalize_f64_optional(3)))
    _assert_f64_int_utf8_defaults(a)
    var b = _make_f64(ACC_AVG, 10.0, 0.0, 20.0, 0.0)
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_f64(2), Float64(15.0))
    a.merge_aligned(b)
    # g0: (1 + 4 + 10 + 20) / 4; g1: (-2 + 8 + 0 + 0) / 4.
    assert_equal(a.finalize_f64(0), Float64(8.75))
    assert_equal(a.finalize_f64(1), Float64(1.5))


def test_percentile_readback_and_merges() raises:
    # q = 0.5 over {1, 4} = 2.5; over {-2, 8} = 3.0.
    var a = _make_f64(ACC_PERCENTILE_F64, 1.0, -2.0, 4.0, 8.0)
    assert_equal(a.finalize_f64(0), Float64(2.5))
    assert_equal(a.finalize_f64(1), Float64(3.0))
    assert_equal(a.finalize_f64(2), Float64(0.0), "unseen gid -> 0.0")
    assert_equal(a.finalize_f64(3), Float64(0.0))
    assert_equal(a.finalize_f64_optional(0).value(), Float64(2.5))
    assert_false(Bool(a.finalize_f64_optional(2)))
    assert_false(Bool(a.finalize_f64_optional(3)))
    _assert_f64_int_utf8_defaults(a)
    var b = _make_f64(ACC_PERCENTILE_F64, 10.0, 0.0, 20.0, 1.0)
    a.merge_at(2, b, 0)
    assert_equal(a.finalize_f64(2), Float64(15.0))
    a.merge_aligned(b)
    # g0 = {1, 4, 10, 20}: median 7.0; g1 = {-2, 8, 0, 1}: median 0.5.
    assert_equal(a.finalize_f64(0), Float64(7.0))
    assert_equal(a.finalize_f64(1), Float64(0.5))
    # g2 = {10, 20} + b's gid 2, which is unseen: unchanged.
    assert_equal(a.finalize_f64(2), Float64(15.0))


def test_percentile_quantile_reaches_the_accumulator() raises:
    # q = 0.25 over {1, 4}: 1 + 0.25 * 3 = 1.75 (the default 0.5 gives 2.5).
    var a = _make_f64(ACC_PERCENTILE_F64, 1.0, -2.0, 4.0, 8.0, q=0.25)
    assert_equal(a.finalize_f64(0), Float64(1.75))


# =============================================================================
# Fallback tag, flush_partial and the generic (unwired) vtable
# =============================================================================


def test_unknown_tag_falls_back_to_sum_int64() raises:
    var dyn = make_single_dyn_acc(UInt8(200))
    assert_equal(Int(dyn.tag), Int(ACC_SUM_INT64))
    dyn.ensure_capacity(2)
    var g = _gids()
    var v = _i64_rows(1, 2, 3, 4)
    dyn.as_mut[SumI64Acc]().update_batch(Span(g), _bytes_i64(v), 1, 4)
    assert_equal(dyn.finalize_int64(0), Int64(4))
    assert_equal(dyn.finalize_int64(1), Int64(6))


def test_flush_partial_goes_through_the_vtable() raises:
    var dyn = _make_i64(ACC_SUM_INT64, 5, -3, 7, 10)
    var col = dyn.flush_partial()
    assert_equal(col.length(), 3)
    var p = col._data.view_typed_ro[DType.int64]()
    assert_equal(p[0], Int64(12))
    assert_equal(p[1], Int64(7))


def test_generic_vtable_refuses_merges_and_reads_sentinels() raises:
    """`DynAccumulator.create[T]` wires the default per-gid thunks: merges
    raise by name and every readback is its sentinel, whatever the state."""
    var s = SumI64Acc()
    s.ensure_capacity(1)
    s.state[0] = 42
    var a = DynAccumulator.create[SumI64Acc](s^)
    var b = DynAccumulator.create[SumI64Acc](SumI64Acc())
    assert_equal(a.finalize_int64(0), Int64(0))
    assert_false(Bool(a.finalize_utf8(0)))
    assert_equal(a.finalize_f64(0), Float64(0.0))
    assert_false(Bool(a.finalize_f64_optional(0)))
    var raised = False
    try:
        a.merge_at(0, b, 0)
    except e:
        raised = True
        assert_equal(
            String(e), "DynAccumulator.merge_at: not wired for this accumulator type"
        )
    assert_true(raised)
    raised = False
    try:
        a.merge_aligned(b)
    except e:
        raised = True
        assert_equal(
            String(e),
            "DynAccumulator.merge_aligned: not wired for this accumulator type",
        )
    assert_true(raised)
    # The wired slots still work on the generic vtable.
    assert_equal(a.num_groups(), 1)
    var col = a.flush_partial()
    assert_equal(col._data.view_typed_ro[DType.int64]()[0], Int64(42))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

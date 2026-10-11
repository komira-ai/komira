# =============================================================================
# test_int_sum_overflow.mojo — the one signed-overflow predicate, the exact
# 128-bit sum state and the refusals every integer sum() route raises
# =============================================================================
#
# What each group pins, and the defect it catches:
#
#   overflow predicate  `i64_add_overflows` is true exactly when the two addends
#                       share a sign the wrapped sum lost; `u64_cell_add_overflows`
#                       asks the SIGNED question of raw UInt64 cells (an unsigned
#                       carry test would fire on every negative addend).
#   narrowing           `i128_total_fits_i64`, `narrow_window_sum_i64` and
#                       `narrow_sum_u64` accept the range ends and refuse one past
#                       them, with the shared sentence naming the aggregand.
#   order cell          `u64_order_cell` maps unsigned order onto signed order
#                       and is its own inverse.
#   ExactIntAgg         merge is the identity for an inactive state, sums counts
#                       and totals, keeps the smaller lo and the larger hi.
#   128-bit words       `i128_addend_hi` sign-extends a signed addend only;
#                       `i128_words_add` carries out of the low word;
#                       `exact_sum_cell_fits` / `exact_sum_cell_i128` read the
#                       two-word cell back.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_op_agg_state.int_sum_overflow import (
    ExactIntAgg,
    exact_sum_cell_fits,
    exact_sum_cell_i128,
    i128_addend_hi,
    i128_total_fits_i64,
    i128_words_add,
    i64_add_overflows,
    int_sum_overflow_message,
    narrow_sum_u64,
    narrow_window_sum_i64,
    u64_cell_add_overflows,
    u64_order_cell,
    uint_sum_overflow_message,
)


comptime I128 = Scalar[DType.int128]


def _bits(v: Int64) -> UInt64:
    return bitcast[DType.uint64, 1](SIMD[DType.int64, 1](v))[0]


def _i128(v: Int64) -> I128:
    return v.cast[DType.int128]()


# =============================================================================
# The overflow predicate
# =============================================================================


def test_i64_add_overflows_only_when_the_sign_flips() raises:
    # Two positives whose wrapped sum is negative.
    assert_true(i64_add_overflows(Int64.MAX, Int64(1), Int64.MIN))
    # Two negatives whose wrapped sum is positive.
    assert_true(i64_add_overflows(Int64.MIN, Int64(-1), Int64.MAX))
    # Mixed signs never overflow, even at the range ends.
    assert_false(i64_add_overflows(Int64.MAX, Int64(-1), Int64.MAX - 1))
    assert_false(i64_add_overflows(Int64.MIN, Int64(1), Int64.MIN + 1))
    # Same sign, in range, both signs; and a sum that lands exactly on 0.
    assert_false(i64_add_overflows(Int64(5), Int64(7), Int64(12)))
    assert_false(i64_add_overflows(Int64(-5), Int64(-7), Int64(-12)))
    assert_false(i64_add_overflows(Int64(-3), Int64(3), Int64(0)))
    # The exact ends are still in range.
    assert_false(i64_add_overflows(Int64.MAX - 1, Int64(1), Int64.MAX))
    assert_false(i64_add_overflows(Int64.MIN + 1, Int64(-1), Int64.MIN))


def test_u64_cell_add_overflows_asks_the_signed_question() raises:
    # A cell holding -1 plus 1 wraps the UInt64 to 0: an unsigned carry, but
    # the signed sum -1 + 1 = 0 is exact, so this must NOT be an overflow.
    assert_false(u64_cell_add_overflows(_bits(-1), Int64(1), UInt64(0)))
    # A cell holding 10 plus -3: unsigned arithmetic would call new < cur a
    # wrap; the signed sum 7 is exact.
    assert_false(u64_cell_add_overflows(UInt64(10), Int64(-3), UInt64(7)))
    # MAX + 1 is a signed overflow even though the UInt64 did not wrap.
    assert_true(
        u64_cell_add_overflows(_bits(Int64.MAX), Int64(1), _bits(Int64.MIN))
    )
    assert_true(
        u64_cell_add_overflows(_bits(Int64.MIN), Int64(-1), _bits(Int64.MAX))
    )


def test_int_sum_overflow_message_names_the_aggregand() raises:
    var m = int_sum_overflow_message("column 3")
    assert_true(m.startswith("integer sum() overflowed INT64 (aggregand: column 3)."))
    assert_true("[-9223372036854775808, 9223372036854775807]" in m)
    var u = uint_sum_overflow_message("UINT64")
    assert_true(u.startswith("integer sum() overflowed UINT64 (aggregand: UINT64)."))
    assert_true("[0, 18446744073709551615]" in u)


# =============================================================================
# Narrowing a 128-bit total
# =============================================================================


def test_i128_total_fits_i64_at_both_ends() raises:
    assert_true(i128_total_fits_i64(_i128(Int64.MAX)))
    assert_true(i128_total_fits_i64(_i128(Int64.MIN)))
    assert_true(i128_total_fits_i64(I128(0)))
    assert_false(i128_total_fits_i64(_i128(Int64.MAX) + 1))
    assert_false(i128_total_fits_i64(_i128(Int64.MIN) - 1))


def test_narrow_window_sum_i64_returns_or_refuses() raises:
    assert_equal(narrow_window_sum_i64(_i128(Int64.MAX), "a"), Int64.MAX)
    assert_equal(narrow_window_sum_i64(_i128(Int64.MIN), "a"), Int64.MIN)
    assert_equal(narrow_window_sum_i64(I128(-42), "a"), Int64(-42))
    var raised = False
    try:
        _ = narrow_window_sum_i64(_i128(Int64.MAX) + 1, "col_a")
    except e:
        raised = True
        assert_equal(String(e), int_sum_overflow_message("col_a"))
    assert_true(raised, "MAX + 1 must refuse")
    raised = False
    try:
        _ = narrow_window_sum_i64(_i128(Int64.MIN) - 1, "col_b")
    except e:
        raised = True
        assert_equal(String(e), int_sum_overflow_message("col_b"))
    assert_true(raised, "MIN - 1 must refuse")


def test_narrow_sum_u64_returns_or_refuses() raises:
    var umax = UInt64.MAX.cast[DType.int128]()
    assert_equal(narrow_sum_u64(I128(0), "u"), UInt64(0))
    assert_equal(narrow_sum_u64(umax, "u"), UInt64.MAX)
    var raised = False
    try:
        _ = narrow_sum_u64(I128(-1), "neg")
    except e:
        raised = True
        assert_equal(String(e), uint_sum_overflow_message("neg"))
    assert_true(raised, "-1 is outside UINT64")
    raised = False
    try:
        _ = narrow_sum_u64(umax + 1, "big")
    except e:
        raised = True
        assert_equal(String(e), uint_sum_overflow_message("big"))
    assert_true(raised, "2^64 is outside UINT64")


# =============================================================================
# The order cell
# =============================================================================


def test_u64_order_cell_maps_unsigned_order_onto_signed() raises:
    # 0 is the smallest UINT64, so its cell is the smallest Int64.
    assert_equal(u64_order_cell(Int64(0)), Int64.MIN)
    # 2^64 - 1 (bits of -1) is the largest, so its cell is Int64.MAX.
    assert_equal(u64_order_cell(Int64(-1)), Int64.MAX)
    # 2^63 (bits of Int64.MIN) sits in the middle: cell 0.
    assert_equal(u64_order_cell(Int64.MIN), Int64(0))
    # Unsigned 1 < unsigned 2^63 + 5: the cells keep that order, although
    # the raw signed bits would reverse it.
    assert_true(u64_order_cell(Int64(1)) < u64_order_cell(Int64.MIN + 5))
    # The bias is an involution.
    var samples: List[Int64] = [Int64(0), Int64(1), Int64(-1), Int64.MAX, Int64.MIN, Int64(123456789)]
    for i in range(len(samples)):
        assert_equal(u64_order_cell(u64_order_cell(samples[i])), samples[i])


# =============================================================================
# ExactIntAgg
# =============================================================================


def _state(count: Int, total: I128, lo: Int64, hi: Int64, u64: Bool = False) -> ExactIntAgg:
    var s = ExactIntAgg()
    s.active = True
    s.u64 = u64
    s.count = count
    s.sum = total
    s.lo = lo
    s.hi = hi
    return s^


def test_exact_int_agg_starts_inactive_with_identity_cells() raises:
    var s = ExactIntAgg()
    assert_false(s.active)
    assert_false(s.u64)
    assert_equal(s.count, 0)
    assert_true(s.sum == I128(0))
    assert_equal(s.lo, Int64.MAX)
    assert_equal(s.hi, Int64.MIN)


def test_exact_int_agg_merge_skips_an_inactive_other() raises:
    var a = _state(2, I128(10), Int64(3), Int64(7))
    var idle = ExactIntAgg()
    # An inactive state that nonetheless carries values must still be ignored.
    idle.count = 99
    idle.sum = I128(1000)
    idle.lo = Int64(-1000)
    idle.hi = Int64(1000)
    idle.u64 = True
    a.merge(idle)
    assert_equal(a.count, 2)
    assert_true(a.sum == I128(10))
    assert_equal(a.lo, Int64(3))
    assert_equal(a.hi, Int64(7))
    assert_false(a.u64)


def test_exact_int_agg_merge_folds_counts_sums_and_extrema() raises:
    # Other widens both ends.
    var a = _state(2, I128(10), Int64(3), Int64(7))
    a.merge(_state(3, I128(-4), Int64(-2), Int64(9), u64=True))
    assert_true(a.active)
    assert_true(a.u64)
    assert_equal(a.count, 5)
    assert_true(a.sum == I128(6))
    assert_equal(a.lo, Int64(-2))
    assert_equal(a.hi, Int64(9))
    # Other inside the range: lo and hi stay.
    a.merge(_state(1, I128(5), Int64(0), Int64(4)))
    assert_equal(a.count, 6)
    assert_true(a.sum == I128(11))
    assert_equal(a.lo, Int64(-2))
    assert_equal(a.hi, Int64(9))
    assert_true(a.u64, "u64 is sticky once any partial was UINT64")
    # An inactive self takes the other's values.
    var b = ExactIntAgg()
    b.merge(_state(1, I128(8), Int64(8), Int64(8)))
    assert_true(b.active)
    assert_equal(b.count, 1)
    assert_equal(b.lo, Int64(8))
    assert_equal(b.hi, Int64(8))


def test_exact_int_agg_partials_past_int64_still_answer() raises:
    # {MAX, MAX} then {MIN, MIN}: each partial leaves INT64, the total -2 fits.
    var a = _state(2, _i128(Int64.MAX) * 2, Int64.MAX, Int64.MAX)
    a.merge(_state(2, _i128(Int64.MIN) * 2, Int64.MIN, Int64.MIN))
    assert_equal(a.sum_i64("x"), Int64(-2))
    assert_true(a.mean() == Float64(-0.5))
    # The same total read as UINT64 is outside its range.
    var raised = False
    try:
        _ = a.sum_u64("x")
    except e:
        raised = True
        assert_equal(String(e), uint_sum_overflow_message("x"))
    assert_true(raised)
    # A total past INT64 refuses as INT64 but answers as UINT64.
    var b = _state(2, _i128(Int64.MAX) + 1, Int64(1), Int64.MAX)
    assert_equal(b.sum_u64("y"), UInt64(1) << 63)
    raised = False
    try:
        _ = b.sum_i64("y")
    except e:
        raised = True
        assert_equal(String(e), int_sum_overflow_message("y"))
    assert_true(raised)


def test_exact_int_agg_mean_divides_the_unnarrowed_total() raises:
    # 2^53 + 1 + (-2^53) over 3 rows: a Float64 running sum would lose the 1.
    var p53 = Int64(1) << 53
    var a = _state(3, _i128(p53) + 1 - _i128(p53), -p53, p53)
    assert_true(a.mean() == Float64(1.0) / Float64(3.0))


# =============================================================================
# The two-word 128-bit cell
# =============================================================================


def test_i128_addend_hi_sign_extends_signed_only() raises:
    assert_equal(i128_addend_hi(Int64(-1), False), UInt64.MAX)
    assert_equal(i128_addend_hi(Int64.MIN, False), UInt64.MAX)
    assert_equal(i128_addend_hi(Int64(5), False), UInt64(0))
    assert_equal(i128_addend_hi(Int64(0), False), UInt64(0))
    # An unsigned addend's raw bits at or above 2^63 are not negative.
    assert_equal(i128_addend_hi(Int64(-1), True), UInt64(0))
    assert_equal(i128_addend_hi(Int64.MIN, True), UInt64(0))


def test_i128_words_add_carries_out_of_the_low_word() raises:
    var r = i128_words_add(UInt64(1), UInt64(0), UInt64(2), UInt64(0))
    assert_equal(r[0], UInt64(3))
    assert_equal(r[1], UInt64(0))
    # Low word wraps: carry 1 into the high word.
    r = i128_words_add(UInt64.MAX, UInt64(0), UInt64(1), UInt64(0))
    assert_equal(r[0], UInt64(0))
    assert_equal(r[1], UInt64(1))
    # 5 + (-1): lo 5 + MAX wraps to 4 with carry, hi 0 + MAX + 1 wraps to 0.
    r = i128_words_add(UInt64(5), UInt64(0), UInt64.MAX, UInt64.MAX)
    assert_equal(r[0], UInt64(4))
    assert_equal(r[1], UInt64(0))
    # A low-word sum equal to the old low word is no carry (adding 0).
    r = i128_words_add(UInt64(7), UInt64(2), UInt64(0), UInt64(3))
    assert_equal(r[0], UInt64(7))
    assert_equal(r[1], UInt64(5))


def test_exact_sum_cell_fits_reads_the_output_range() raises:
    var half = UInt64(0x8000000000000000)
    # Unsigned: only a zero high word fits.
    assert_true(exact_sum_cell_fits(UInt64.MAX, UInt64(0), True))
    assert_false(exact_sum_cell_fits(UInt64(0), UInt64(1), True))
    # Signed, low word below 2^63: a non-negative value, fits iff hi == 0.
    assert_true(exact_sum_cell_fits(half - 1, UInt64(0), False))
    assert_false(exact_sum_cell_fits(UInt64(5), UInt64.MAX, False))
    assert_false(exact_sum_cell_fits(UInt64(5), UInt64(1), False))
    # Signed, low word at or above 2^63: fits iff hi is all ones (negative).
    assert_true(exact_sum_cell_fits(half, UInt64.MAX, False))
    assert_true(exact_sum_cell_fits(UInt64.MAX, UInt64.MAX, False))
    assert_false(exact_sum_cell_fits(half, UInt64(0), False))


def test_exact_sum_cell_i128_reassembles_the_words() raises:
    assert_true(exact_sum_cell_i128(UInt64(5), UInt64(0)) == I128(5))
    assert_true(exact_sum_cell_i128(UInt64.MAX, UInt64.MAX) == I128(-1))
    assert_true(
        exact_sum_cell_i128(UInt64(0), UInt64(1))
        == UInt64.MAX.cast[DType.int128]() + 1
    )
    assert_true(
        exact_sum_cell_i128(UInt64(0x8000000000000000), UInt64.MAX)
        == _i128(Int64.MIN)
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

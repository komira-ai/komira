# =============================================================================
# decimal_threshold / eval_decimal_threshold: the exact threshold a literal
# gives on a DECIMAL column, and the kernel that applies it
# =============================================================================
#
# `decimal_threshold(V, t, s, op)` answers `column <op> V / 10^t` on a column of
# scale s as `c <op'> T` over the column's integers c. Each expected pair below
# is worked by hand from the definition: the literal in units of the column's
# last digit is V / 10^(t - s); a step is an integer; between steps q and q + 1
# `<` and `<=` are `<= q`, `>` and `>=` are `>= q + 1`, `=` is never true and
# `<>` always. (komira_decimal_compare_conformance holds DuckDB's own answers to
# the same comparisons through SQL; test_decimal_literal_compare sweeps the
# whole evaluator against a cross-multiplying oracle.)
#
# What each test proves, and the defect it catches:
#   * test_a_literal_between_two_steps_floors_or_ceils_by_operator: 0.065,
#     0.0649 and 1e-7 on a scale-2 column, both signs, every operator. Catches
#     a literal rounded to the column's scale (0.065 -> 0.07), a ceiling where
#     the floor belongs (or the reverse), a floor of a negative literal taken
#     toward zero (-6.5 -> -6 instead of -7), `=` or `<>` answered per row.
#   * test_a_literal_on_a_step_keeps_the_operator: equal scale, a finer scale
#     whose extra digits are zeros (0.060), a coarser scale, an integer.
#     Catches a rescale in the wrong direction and an operator rewritten when
#     the literal is a step.
#   * test_thresholds_are_clamped_to_38_digits: a literal far outside any
#     DECIMAL128 value keeps its order (+, -). Catches a 128-bit overflow of
#     the rescale and a clamp that changes an answer.
#   * test_scales_outside_the_decimal_range_are_refused.
#   * test_int64_kernel_matches_the_definition: the int64 SIMD kernel against
#     a per-row definition, for every operator, at thresholds on and around
#     the values, and for lengths on both sides of the 8-row block. Catches a
#     deinterleave that reads the high word, a block that skips its last rows,
#     and a tail mask off by one.
#   * test_int64_kernel_clamps_a_threshold_past_int64: a threshold beyond
#     int64 on a precision-18 column answers all rows or none. Catches a
#     narrowing cast that wraps.
#   * test_wide_kernel_compares_128_bits: precision 19 and 38 columns hold
#     values past int64, compared with 128-bit thresholds. Catches the int64
#     kernel used on a column that does not fit it.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.decimal_array import Decimal128Array
from komira_buffer.heap_region import HeapRegion
from komira_batch_eval.decimal_literal_compare import (
    DecimalThreshold,
    decimal_threshold,
    eval_decimal_threshold,
)
from komira_scalar_arithmetic.decimal_arith import I128, pow10_i256
from komira_scalar_arithmetic.decimal_compare import (
    DEC_CMP_EQ,
    DEC_CMP_GE,
    DEC_CMP_GT,
    DEC_CMP_LE,
    DEC_CMP_LT,
    DEC_CMP_NE,
)


def _ops() -> List[UInt8]:
    var ops = List[UInt8]()
    ops.append(DEC_CMP_LT)
    ops.append(DEC_CMP_LE)
    ops.append(DEC_CMP_GT)
    ops.append(DEC_CMP_GE)
    ops.append(DEC_CMP_EQ)
    ops.append(DEC_CMP_NE)
    return ops^


def _name(op: UInt8) -> String:
    if op == DEC_CMP_LT:
        return "<"
    if op == DEC_CMP_LE:
        return "<="
    if op == DEC_CMP_GT:
        return ">"
    if op == DEC_CMP_GE:
        return ">="
    if op == DEC_CMP_EQ:
        return "="
    return "<>"


def _below_all() raises -> I128:
    return -pow10_i256(38).cast[DType.int128]()


def _expect(
    value: Int, t: Int, s: Int, op: UInt8, want_op: UInt8, want_t: I128
) raises:
    var got = decimal_threshold(I128(value), t, s, op)
    var label = (
        "column(scale "
        + String(s)
        + ") "
        + _name(op)
        + " "
        + String(value)
        + "e-"
        + String(t)
    )
    assert_equal(String(got.op), String(want_op), label + ": operator")
    assert_true(got.threshold == want_t, label + ": threshold")


def _between(value: Int, t: Int, s: Int, floor_q: Int) raises:
    """A literal strictly between the steps `floor_q` and `floor_q + 1`."""
    _expect(value, t, s, DEC_CMP_LT, DEC_CMP_LE, I128(floor_q))
    _expect(value, t, s, DEC_CMP_LE, DEC_CMP_LE, I128(floor_q))
    _expect(value, t, s, DEC_CMP_GT, DEC_CMP_GE, I128(floor_q + 1))
    _expect(value, t, s, DEC_CMP_GE, DEC_CMP_GE, I128(floor_q + 1))
    _expect(value, t, s, DEC_CMP_EQ, DEC_CMP_LT, _below_all())
    _expect(value, t, s, DEC_CMP_NE, DEC_CMP_GT, _below_all())


def test_a_literal_between_two_steps_floors_or_ceils_by_operator() raises:
    # 0.065 on scale 2 is 6.5 hundredths: between 6 and 7.
    _between(65, 3, 2, 6)
    # -0.065 is -6.5 hundredths: between -7 and -6.
    _between(-65, 3, 2, -7)
    # 0.0649 is 6.49: between 6 and 7. 0.0651 is 6.51: also.
    _between(649, 4, 2, 6)
    _between(651, 4, 2, 6)
    # 0.0000001 is 0.00001 hundredths: between 0 and 1; its negative between
    # -1 and 0.
    _between(1, 7, 2, 0)
    _between(-1, 7, 2, -1)
    # 23.995 and 24.005 on scale 2: between 2399 and 2400, 2400 and 2401.
    _between(23995, 3, 2, 2399)
    _between(24005, 3, 2, 2400)
    # A scale-0 column: 0.5 is between 0 and 1.
    _between(5, 1, 0, 0)
    _between(-5, 1, 0, -1)
    # The widest gap: 38 digits of scale against scale 0.
    _between(1, 38, 0, 0)
    _between(-1, 38, 0, -1)


def test_a_literal_on_a_step_keeps_the_operator() raises:
    for op in _ops():
        # Equal scale: 0.06 on scale 2.
        _expect(6, 2, 2, op, op, I128(6))
        _expect(-6, 2, 2, op, op, I128(-6))
        # A finer scale whose extra digits are zeros: 0.060 and 0.0600.
        _expect(60, 3, 2, op, op, I128(6))
        _expect(600, 4, 2, op, op, I128(6))
        _expect(-600, 4, 2, op, op, I128(-6))
        _expect(0, 7, 2, op, op, I128(0))
        # A coarser scale: 0.1 and -0.5 on scale 2, an integer 24 on scale 2.
        _expect(1, 1, 2, op, op, I128(10))
        _expect(-5, 1, 2, op, op, I128(-50))
        _expect(24, 0, 2, op, op, I128(2400))
        _expect(-1, 0, 2, op, op, I128(-100))
        # An integer against a scale-0 column.
        _expect(24, 0, 0, op, op, I128(24))


def test_thresholds_are_clamped_to_38_digits() raises:
    var e38 = pow10_i256(38).cast[DType.int128]()
    for op in _ops():
        # 10^37 as an integer against scale 2 is 10^39 hundredths.
        var big = decimal_threshold(pow10_i256(37).cast[DType.int128](), 0, 2, op)
        assert_equal(String(big.op), String(op))
        assert_true(big.threshold == e38, "clamped to 10^38")
        var small = decimal_threshold(-pow10_i256(37).cast[DType.int128](), 0, 2, op)
        assert_equal(String(small.op), String(op))
        assert_true(small.threshold == -e38, "clamped to -10^38")
    # The largest 38-digit literal against a scale-2 column (t = 38): it is
    # 99.99.. hundredths, between 99 and 100.
    var top = pow10_i256(38).cast[DType.int128]() - I128(1)
    var lt = decimal_threshold(top, 38, 2, DEC_CMP_LT)
    assert_equal(String(lt.op), String(DEC_CMP_LE))
    assert_true(lt.threshold == I128(99), "floor of 99.99...")
    var gt = decimal_threshold(top, 38, 2, DEC_CMP_GT)
    assert_equal(String(gt.op), String(DEC_CMP_GE))
    assert_true(gt.threshold == I128(100), "ceiling of 99.99...")


def test_scales_outside_the_decimal_range_are_refused() raises:
    var refused = 0
    try:
        _ = decimal_threshold(I128(1), 39, 2, DEC_CMP_LT)
    except:
        refused += 1
    try:
        _ = decimal_threshold(I128(1), 2, 39, DEC_CMP_LT)
    except:
        refused += 1
    try:
        _ = decimal_threshold(I128(1), -1, 2, DEC_CMP_LT)
    except:
        refused += 1
    try:
        _ = decimal_threshold(I128(1), 2, -1, DEC_CMP_LT)
    except:
        refused += 1
    assert_equal(refused, 4)


def _holds(c: I128, op: UInt8, t: I128) -> Bool:
    if op == DEC_CMP_LT:
        return c < t
    if op == DEC_CMP_LE:
        return c <= t
    if op == DEC_CMP_GT:
        return c > t
    if op == DEC_CMP_GE:
        return c >= t
    if op == DEC_CMP_EQ:
        return c == t
    return c != t


def _column(values: List[I128], precision: Int) raises -> Decimal128Array[HeapRegion]:
    var arr = Decimal128Array.allocate(len(values), precision, 2)
    for i in range(len(values)):
        arr.set_i128(i, values[i])
    return arr^


def _check_kernel(values: List[I128], precision: Int, thresholds: List[I128]) raises:
    var arr = _column(values, precision)
    for ti in range(len(thresholds)):
        for op in _ops():
            var plan = DecimalThreshold(op, thresholds[ti])
            var mask = eval_decimal_threshold(arr, precision, plan)
            assert_equal(len(mask), len(values))
            for i in range(len(values)):
                var want = _holds(values[i], op, thresholds[ti])
                assert_true(
                    mask.get(i) == want,
                    "precision "
                    + String(precision)
                    + " n="
                    + String(len(values))
                    + " row "
                    + String(i)
                    + ": value "
                    + String(Int(values[i].cast[DType.int64]()))
                    + " "
                    + _name(op)
                    + " "
                    + String(Int(thresholds[ti].cast[DType.int64]()))
                    + " should be "
                    + String(want),
                )


def _narrow_values(n: Int) -> List[I128]:
    # Distinct small values, both signs, with repeats of the thresholds.
    var out = List[I128]()
    for i in range(n):
        out.append(I128((i * 7) % 23 - 11))
    return out^


def test_int64_kernel_matches_the_definition() raises:
    var thresholds = List[I128]()
    for t in [-12, -11, -1, 0, 1, 5, 11, 12]:
        thresholds.append(I128(t))
    for n in [1, 7, 8, 9, 15, 16, 17, 31, 64, 65]:
        _check_kernel(_narrow_values(n), 18, thresholds)
        _check_kernel(_narrow_values(n), 15, thresholds)


def test_int64_kernel_clamps_a_threshold_past_int64() raises:
    var values = _narrow_values(19)
    var thresholds = List[I128]()
    thresholds.append(pow10_i256(30).cast[DType.int128]())
    thresholds.append(-pow10_i256(30).cast[DType.int128]())
    thresholds.append(pow10_i256(38).cast[DType.int128]())
    thresholds.append(-pow10_i256(38).cast[DType.int128]())
    thresholds.append(I128(Int(Int64.MAX)) + I128(1))
    thresholds.append(-I128(Int(Int64.MAX)) - I128(2))
    _check_kernel(values, 18, thresholds)


def test_wide_kernel_compares_128_bits() raises:
    var m = I128(Int(Int64.MAX))
    var values = List[I128]()
    values.append(m)
    values.append(m + I128(1))
    values.append(m - I128(1))
    values.append(-m)
    values.append(-m - I128(1))
    values.append(-m - I128(2))
    values.append(I128(0))
    values.append(pow10_i256(30).cast[DType.int128]())
    values.append(-pow10_i256(30).cast[DType.int128]())
    values.append(pow10_i256(37).cast[DType.int128]())
    values.append(pow10_i256(18).cast[DType.int128]())
    var thresholds = List[I128]()
    thresholds.append(m)
    thresholds.append(m + I128(1))
    thresholds.append(-m - I128(1))
    thresholds.append(pow10_i256(30).cast[DType.int128]())
    thresholds.append(-pow10_i256(30).cast[DType.int128]())
    thresholds.append(I128(0))
    thresholds.append(pow10_i256(38).cast[DType.int128]())
    thresholds.append(-pow10_i256(38).cast[DType.int128]())
    for p in [19, 25, 38]:
        _check_kernel(values, p, thresholds)
    # A longer wide column: the block and the tail.
    var longer = List[I128]()
    for i in range(37):
        longer.append(values[i % len(values)])
    _check_kernel(longer, 38, thresholds)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_literal_between_two_steps_floors_or_ceils_by_operator]()
    suite.test[test_a_literal_on_a_step_keeps_the_operator]()
    suite.test[test_thresholds_are_clamped_to_38_digits]()
    suite.test[test_scales_outside_the_decimal_range_are_refused]()
    suite.test[test_int64_kernel_matches_the_definition]()
    suite.test[test_int64_kernel_clamps_a_threshold_past_int64]()
    suite.test[test_wide_kernel_compares_128_bits]()
    suite^.run()

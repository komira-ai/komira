# =============================================================================
# DECIMAL256 ARITHMETIC — kernel-level unit tests.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_scalar_arith.decimal256_arith import (
    I256,
    decimal256_add_i256,
    decimal256_sub_i256,
    decimal256_mul_i256,
    decimal256_div_i256,
    decimal256_add_result_ps,
    decimal256_mul_result_ps,
    decimal256_div_result_ps,
    rescale_i256_half_up,
    pow10_i256_d,
    max_dec256_i256,
    overflows_dec256_inline,
)


# --- ADD ---------------------------------------------------------------------


def test_decimal256_add_same_scale() raises:
    """123.45 + 67.89 = 191.34 (both at scale=2)."""
    var a = I256(12345)
    var b = I256(6789)
    var r = decimal256_add_i256(a, 2, b, 2, 2)
    assert_equal(Int(r.cast[DType.int64]()), 19134)


def test_decimal256_add_different_scale() raises:
    """100.5 (s=1) + 0.005 (s=3) = 100.505 (s=3)."""
    var a = I256(1005)
    var b = I256(5)
    var r = decimal256_add_i256(a, 1, b, 3, 3)
    assert_equal(Int(r.cast[DType.int64]()), 100505)


def test_decimal256_add_overflow_raises() raises:
    """Adding two values that exceed 10^76 - 1 should raise."""
    var max_v = max_dec256_i256()
    var a = max_v
    var b = I256(1)
    var raised = False
    try:
        var _r = decimal256_add_i256(a, 0, b, 0, 0)
    except:
        raised = True
    assert_true(raised, "add overflow should raise")


# --- SUB ---------------------------------------------------------------------


def test_decimal256_sub_basic() raises:
    """200.00 - 75.50 = 124.50 (s=2)."""
    var a = I256(20000)
    var b = I256(7550)
    var r = decimal256_sub_i256(a, 2, b, 2, 2)
    assert_equal(Int(r.cast[DType.int64]()), 12450)


def test_decimal256_sub_negative_result() raises:
    """10 - 25 = -15."""
    var a = I256(10)
    var b = I256(25)
    var r = decimal256_sub_i256(a, 0, b, 0, 0)
    assert_equal(Int(r.cast[DType.int64]()), -15)


# --- MUL ---------------------------------------------------------------------


def test_decimal256_mul_basic() raises:
    """5 * 7 = 35."""
    var a = I256(5)
    var b = I256(7)
    var r = decimal256_mul_i256(a, b)
    assert_equal(Int(r.cast[DType.int64]()), 35)


def test_decimal256_mul_negative() raises:
    """-3 * 4 = -12."""
    var a = I256(-3)
    var b = I256(4)
    var r = decimal256_mul_i256(a, b)
    assert_equal(Int(r.cast[DType.int64]()), -12)


def test_decimal256_mul_zero() raises:
    """0 * anything = 0 (short-circuits)."""
    var a = I256(0)
    var b = I256(1) << 200  # Would overflow if multiplied.
    var r = decimal256_mul_i256(a, b)
    assert_true(r == I256(0))


def test_decimal256_mul_overflow_raises() raises:
    """Multiplying two large values whose product exceeds 10^76 raises."""
    var max_v = max_dec256_i256()
    var a = max_v
    var b = I256(2)
    var raised = False
    try:
        var _r = decimal256_mul_i256(a, b)
    except:
        raised = True
    assert_true(raised, "mul overflow should raise")


# --- DIV ---------------------------------------------------------------------


def test_decimal256_div_basic() raises:
    """10 / 4 with s1=0, s2=0, out_scale=4 -> 25000 (logical 2.5000)."""
    var a = I256(10)
    var b = I256(4)
    var r = decimal256_div_i256(a, 0, b, 0, 4)
    assert_equal(Int(r.cast[DType.int64]()), 25000)


def test_decimal256_div_half_up_rounding() raises:
    """7 / 2 at out_scale=0 -> 4 (round half up away from zero)."""
    var a = I256(7)
    var b = I256(2)
    var r = decimal256_div_i256(a, 0, b, 0, 0)
    # 7/2 = 3.5; HALF_UP -> 4.
    assert_equal(Int(r.cast[DType.int64]()), 4)


def test_decimal256_div_half_up_negative() raises:
    """-7 / 2 at out_scale=0 -> -4 (round half away from zero, sign-aware)."""
    var a = I256(-7)
    var b = I256(2)
    var r = decimal256_div_i256(a, 0, b, 0, 0)
    assert_equal(Int(r.cast[DType.int64]()), -4)


def test_decimal256_div_by_zero_raises() raises:
    """Division by zero raises."""
    var a = I256(1)
    var b = I256(0)
    var raised = False
    try:
        var _r = decimal256_div_i256(a, 0, b, 0, 0)
    except:
        raised = True
    assert_true(raised, "div-by-zero should raise")


# --- RESULT-TYPE COMPUTATION ------------------------------------------------


def test_decimal256_add_result_ps_clamps() raises:
    """Add result precision clamps to 76 when sum would exceed."""
    var ps = decimal256_add_result_ps(76, 0, 76, 0)
    assert_equal(ps[0], 76, "precision clamped")
    assert_equal(ps[1], 0, "scale max(0, 0)")


def test_decimal256_mul_result_ps_clamps() raises:
    """Mul result precision clamps to 76."""
    var ps = decimal256_mul_result_ps(40, 5, 40, 5)
    assert_equal(ps[0], 76, "precision clamped")
    assert_equal(ps[1], 10, "scale = s1+s2")


def test_decimal256_mul_result_ps_scale_overflow_raises() raises:
    """Mul with s1+s2 > 76 raises."""
    var raised = False
    try:
        var _ps = decimal256_mul_result_ps(76, 50, 76, 30)
    except:
        raised = True
    assert_true(raised, "scale-overflow should raise")


def test_decimal256_div_result_ps() raises:
    """Div result scale = min(s1+4, 76)."""
    var ps = decimal256_div_result_ps(38, 2, 38, 2)
    assert_equal(ps[1], 6, "scale = s1+4 = 6")


# --- RESCALE ----------------------------------------------------------------


def test_decimal256_rescale_up() raises:
    """Rescale 123 (s=2) -> 12300 (s=4)."""
    var v = I256(123)
    var r = rescale_i256_half_up(v, 2, 4)
    assert_equal(Int(r.cast[DType.int64]()), 12300)


def test_decimal256_rescale_down_half_up() raises:
    """Rescale 125 (s=2) -> 1 (s=0) — 1.25 rounds to 1 (HALF_UP rounds .5 up;
    but 1.25 != .5; check: 125/100 = 1, remainder 25; 2*25 = 50 < 100, so no
    round up -> 1).  Then rescale 125 (s=2) -> at s=1 = 12, remainder 5 ->
    2*5 = 10 == 10 — rounds away from zero -> 13. So at s=1, 1.25 -> 1.3."""
    var v = I256(125)
    var r1 = rescale_i256_half_up(v, 2, 0)
    # 1.25 -> 1 (truncates toward 0, then 2*0.25 = 0.5 == 1.0? — 25 vs 100,
    # 2*25=50 < 100, no round up).
    assert_equal(Int(r1.cast[DType.int64]()), 1)
    var r2 = rescale_i256_half_up(v, 2, 1)
    # 1.25 -> 1.3 (2*5 = 10 >= 10, round up; sign positive so +1).
    assert_equal(Int(r2.cast[DType.int64]()), 13)


def test_decimal256_rescale_down_negative_half_up() raises:
    """Rescale -125 (s=2) -> -1.3 (s=1) = -13 (round half AWAY from zero)."""
    var v = I256(-125)
    var r = rescale_i256_half_up(v, 2, 1)
    assert_equal(Int(r.cast[DType.int64]()), -13)



def test_decimal256_rescale_down_negative_non_ties() raises:
    """⛔ NEGATIVE NON-TIES — the cells the -1.25 tie above cannot see.

    Mojo's integer `/` truncates and its `%` is FLOORED, so a remainder taken
    with `%` is wrong for every negative non-tie (-3.99 -> -3 and -3.01 -> -4
    at scale 0). Expectations are HALF_UP (DuckDB v1.5.3:
    `CAST(-3.99::DECIMAL(12,2) AS DECIMAL(12,0))` = -4)."""
    assert_equal(Int(rescale_i256_half_up(I256(-399), 2, 0).cast[DType.int64]()), -4)
    assert_equal(Int(rescale_i256_half_up(I256(-301), 2, 0).cast[DType.int64]()), -3)
    assert_equal(Int(rescale_i256_half_up(I256(-351), 2, 1).cast[DType.int64]()), -35)
    assert_equal(Int(rescale_i256_half_up(I256(-349), 2, 0).cast[DType.int64]()), -3)
    assert_equal(Int(rescale_i256_half_up(I256(-350), 2, 0).cast[DType.int64]()), -4)
    # The positive mirror, for symmetry.
    assert_equal(Int(rescale_i256_half_up(I256(399), 2, 0).cast[DType.int64]()), 4)
    assert_equal(Int(rescale_i256_half_up(I256(301), 2, 0).cast[DType.int64]()), 3)


def test_decimal256_div_negative_non_ties() raises:
    """-1/3 at scale 2 is -0.33 (HALF_UP), not -0.34 — the floored-`%`
    remainder rounded it away from zero. Both operand signs."""
    assert_equal(Int(decimal256_div_i256(I256(-1), 0, I256(3), 0, 2).cast[DType.int64]()), -33)
    assert_equal(Int(decimal256_div_i256(I256(-2), 0, I256(3), 0, 2).cast[DType.int64]()), -67)
    assert_equal(Int(decimal256_div_i256(I256(1), 0, I256(-3), 0, 2).cast[DType.int64]()), -33)
    assert_equal(Int(decimal256_div_i256(I256(-1), 0, I256(-3), 0, 2).cast[DType.int64]()), 33)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# AVG of an exact integer total: DuckDB's long-double steps, emulated
#
# DuckDB's avg() of an INTEGER, BIGINT or DECIMAL(p > 4) converts the exact
# 128-bit total to an x87 long double (64-bit mantissa, round to nearest even),
# divides it by count * 10^scale (the product rounded to a 64-bit mantissa; the
# scale is a double), rounds the quotient to a 64-bit mantissa, and rounds that
# once more to a double. An avg() of a SMALLINT or DECIMAL(p <= 4) divides in
# double. These tests hold `decimal_avg.mojo` to that:
#
#   * anchors worked by hand: totals at which the 64-bit rounding, and then the
#     53-bit rounding of its result, lands on a different double than one
#     rounding does (ties, carries, remainders below and above the half);
#   * a sweep against an oracle written differently from the code under test
#     (bit-by-bit rounding of 256-bit integers, the quotient from a wide integer
#     division): 39 scales, nine counts, signed totals from 0 to the 128-bit
#     limits;
#   * the fast path: its condition at both sides of each limit, and that where
#     it applies the plain double division is the emulated result.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.math import floor

from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_avg import (
    _avg_emulated,
    _avg_fast_path_applies,
    _avg_long_double,
    avg_decimal_float64,
    avg_integer_float64,
)
from komira_scalar_arithmetic.decimal_cast import hugeint_to_float64

comptime U256 = SIMD[DType.uint256, 1]
comptime U128 = SIMD[DType.uint128, 1]


# --- the oracle ---------------------------------------------------------------


def _bits(a: U256) -> Int:
    var n = 0
    var x = a
    while x != 0:
        x = x >> 1
        n += 1
    return n


struct _Rounded(Copyable, Movable):
    """`mant * 2^exp`."""

    var mant: U256
    var exp: Int

    def __init__(out self, mant: U256, exp: Int):
        self.mant = mant
        self.exp = exp


def _round_to(a: U256, exp: Int, width: Int) -> _Rounded:
    """`a * 2^exp` rounded to nearest even at `width` mantissa bits, one bit at a
    time: the last bit dropped is the round bit, any earlier one sets sticky."""
    var m = a
    var e = exp
    var round_bit = False
    var sticky = False
    for _ in range(_bits(a) - width):
        sticky = sticky or round_bit
        round_bit = (m & 1) == 1
        m = m >> 1
        e += 1
    if round_bit and (sticky or (m & 1) == 1):
        m += 1
    return _Rounded(m, e)


def _pow2(e: Int) -> Float64:
    var r = Float64(1.0)
    if e >= 0:
        for _ in range(e):
            r = r * 2.0
    else:
        for _ in range(-e):
            r = r * 0.5
    return r


def _oracle(total: I128, count: Int, scale: Int) -> Float64:
    var neg = total < 0
    var mag = total.cast[DType.int256]()
    if neg:
        mag = -mag
    var n = _round_to(mag.cast[DType.uint256](), 0, 64)
    var ten = I128(1)
    for _ in range(scale):
        ten = ten * 10
    var ms = hugeint_to_float64(ten)
    var es = 0
    while ms >= 9007199254740992.0:
        ms = ms * 0.5
        es += 1
    while ms != floor(ms):
        ms = ms * 2.0
        es -= 1
    var d = _round_to(U256(count) * ms.cast[DType.uint64]().cast[DType.uint256](), es, 64)
    var q = (n.mant << 190) // d.mant
    var rem = (n.mant << 190) - q * d.mant
    var wide = q << 1
    if rem != 0:
        wide += 1
    var qr = _round_to(wide, n.exp - d.exp - 190 - 1, 64)
    var out = _round_to(qr.mant, qr.exp, 53)
    var v = out.mant.cast[DType.float64]() * _pow2(out.exp)
    if neg:
        v = -v
    return v


# --- the anchors --------------------------------------------------------------


def _i(v: Int) -> I128:
    return I128(v)


def _two_pow(k: Int) -> I128:
    return I128(1) << I128(k)


def test_a_sum_past_2_64_is_rounded_twice() raises:
    """2^64 + 2049 is a tie at the 64-bit mantissa (kept even: 2^64 + 2048),
    which is a tie at the 53-bit one (kept even: 2^64). One rounding gives
    2^64 + 4096. This is the total of the group the issue names: DuckDB's avg
    over -(2^64 + 2049) and 3 rows is exactly -6148914691236517888."""
    var up_one_rounding = Float64(18446744073709555712.0)
    var two64 = Float64(18446744073709551616.0)
    assert_equal(avg_integer_float64(_two_pow(64) + I128(2049), 1, 64), two64)
    assert_equal(avg_integer_float64(-(_two_pow(64) + I128(2049)), 1, 64), -two64)
    assert_true(
        (_two_pow(64) + I128(2049)).cast[DType.float64]() == up_one_rounding
    )
    assert_equal(
        avg_integer_float64(-(_two_pow(64) + I128(2049)), 3, 64),
        Float64(-6148914691236517888.0),
    )
    assert_equal(
        avg_decimal_float64(-(_two_pow(64) + I128(2049)), 3, 38, 0),
        Float64(-6148914691236517888.0),
    )


def test_a_tie_at_the_64_bit_mantissa_goes_to_even() raises:
    """2^64 + 2051 is a tie whose even neighbour is above (2^64 + 2052, which
    the double rounding then takes up to 2^64 + 4096); 2^65 + 4097 and
    2^65 + 4098 drop to 2^65 + 4096, a tie at the double, kept even (2^65);
    2^65 + 4102 is a tie whose even neighbour is above."""
    var next64 = Float64(18446744073709555712.0)
    var two65 = Float64(36893488147419103232.0)
    var next65 = Float64(36893488147419111424.0)
    assert_equal(avg_integer_float64(_two_pow(64) + I128(2051), 1, 64), next64)
    assert_equal(avg_integer_float64(_two_pow(65) + I128(4097), 1, 64), two65)
    assert_equal(avg_integer_float64(_two_pow(65) + I128(4098), 1, 64), two65)
    assert_equal(avg_integer_float64(_two_pow(65) + I128(4102), 1, 64), next65)


def test_a_remainder_above_the_half_rounds_up() raises:
    """2^65 + 4099 drops 3 of 4 (above the half): 2^65 + 4100, and 2^65 + 8192
    at the double."""
    var next65 = Float64(36893488147419111424.0)
    assert_equal(avg_integer_float64(_two_pow(65) + I128(4099), 1, 64), next65)
    assert_equal(avg_integer_float64(-(_two_pow(65) + I128(4099)), 1, 64), -next65)


def test_a_carry_out_of_the_mantissa_is_2_to_the_65() raises:
    """2^65 - 1 is a tie at the 64-bit mantissa whose odd neighbour 2^64 - 1
    rounds up to 2^64 mantissa units: the value 2^65."""
    assert_equal(
        avg_integer_float64(_two_pow(65) - I128(1), 1, 64),
        Float64(36893488147419103232.0),
    )


def test_small_totals_and_count_one() raises:
    assert_equal(avg_integer_float64(I128(0), 1, 64), Float64(0.0))
    assert_equal(avg_integer_float64(I128(5), 1, 64), Float64(5.0))
    assert_equal(avg_integer_float64(I128(-5), 1, 32), Float64(-5.0))
    assert_equal(avg_integer_float64(I128(7), 2, 32), Float64(3.5))
    assert_equal(avg_integer_float64(I128(1), 3, 64), Float64(1.0) / Float64(3.0))
    assert_equal(avg_decimal_float64(I128(12345), 1, 15, 2), Float64(123.45))
    assert_equal(avg_decimal_float64(I128(100), 4, 15, 2), Float64(0.25))
    # A DECIMAL of 4 digits or fewer divides in double: 12.34, and 7 over 3000.
    assert_equal(avg_decimal_float64(I128(1234), 1, 4, 2), Float64(12.34))
    assert_equal(avg_decimal_float64(I128(7), 3, 4, 3), Float64(7.0) / Float64(3000.0))


def test_a_count_of_zero_or_no_total_is_zero() raises:
    assert_equal(avg_integer_float64(I128(5), 0, 16), Float64(0.0))
    assert_equal(avg_decimal_float64(I128(5), 0, 4, 2), Float64(0.0))
    assert_equal(_avg_long_double(I128(0), 5, 0), Float64(0.0))
    assert_equal(_avg_long_double(I128(5), 0, 0), Float64(0.0))
    assert_equal(_avg_emulated(I128(5), 0, 0), Float64(0.0))
    assert_equal(_avg_emulated(I128(0), 5, 0), Float64(0.0))


def test_the_widest_totals() raises:
    """The most negative and the most positive 128-bit total: -2^127 and
    2^127 - 1 are both 2^127 once rounded to 64 bits."""
    var two127 = Float64(170141183460469231731687303715884105728.0)
    var most_negative = -_two_pow(126) - _two_pow(126)
    assert_equal(avg_integer_float64(most_negative, 1, 64), -two127)
    assert_equal(avg_integer_float64(_two_pow(126) - I128(1) + _two_pow(126), 1, 64), two127)


def test_a_double_rounding_at_a_count_past_2048() raises:
    """2473 / 2051 is 2^-53/2051 (less than 2^-64) above a midpoint of two
    doubles: the 64-bit rounding lands on the midpoint and the tie goes to the
    even double below, where one rounding takes the one above. DuckDB's avg of
    INTEGER and BIGINT gives the lower; of SMALLINT (a double division) the
    upper."""
    var plain = Float64(2473.0) / Float64(2051.0)
    var ulp = Float64(2.220446049250313e-16)
    assert_equal(avg_integer_float64(I128(2473), 2051, 64), plain - ulp)
    assert_equal(avg_integer_float64(I128(2473), 2051, 32), plain - ulp)
    assert_equal(avg_integer_float64(I128(2473), 2051, 16), plain)
    assert_equal(avg_integer_float64(I128(2473), 2051, 8), plain)
    assert_equal(avg_integer_float64(I128(-2473), 2051, 64), -(plain - ulp))
    assert_equal(avg_decimal_float64(I128(2473), 2051, 5, 0), plain - ulp)
    assert_equal(avg_decimal_float64(I128(2473), 2051, 4, 0), plain)


def test_a_decimal_divides_by_count_times_the_scale() raises:
    """DuckDB's divisor is count * double(10^scale), one product rounded to 64
    bits, and one division: 1 / (3 * 10) and 7 / (9 * 10^10) are the
    correctly rounded quotients."""
    assert_equal(avg_decimal_float64(I128(1), 3, 10, 1), Float64(1.0) / Float64(30.0))
    assert_equal(
        avg_decimal_float64(I128(7), 9, 20, 10),
        Float64(7.0) / Float64(90000000000.0),
    )


# --- the sweep ----------------------------------------------------------------


def _totals() -> List[I128]:
    var out = List[I128]()
    var base = List[I128]()
    base.append(I128(0))
    base.append(I128(1))
    base.append(I128(5))
    base.append(I128(9007199254740991))
    base.append(I128(9007199254740992))
    base.append(I128(9007199254740993))
    base.append(_two_pow(64) - I128(1))
    base.append(_two_pow(64))
    base.append(_two_pow(64) + I128(1))
    base.append(_two_pow(64) + I128(2049))
    base.append(_two_pow(64) + I128(2051))
    base.append(_two_pow(65) - I128(1))
    base.append(_two_pow(65) + I128(4097))
    base.append(_two_pow(65) + I128(4099))
    base.append(_two_pow(70) + _two_pow(17) + I128(1))
    base.append(_two_pow(100) + _two_pow(36) + I128(1))
    base.append(_two_pow(126) + _two_pow(62) + I128(3))
    base.append(_two_pow(126) - I128(1) + _two_pow(126))
    var nines = I128(1)
    for _ in range(38):
        nines = nines * 10
    base.append(nines - I128(1))
    for i in range(len(base)):
        out.append(base[i])
        out.append(-base[i])
    out.append(-_two_pow(126) - _two_pow(126))
    var x = UInt64(0x9E3779B97F4A7C15)
    for _ in range(24):
        x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        var hi = x
        x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        var w = (hi.cast[DType.int128]() << I128(64)) | x.cast[DType.int128]()
        w = w >> I128(Int(x >> 58))
        out.append(w)
    return out^


def _counts() -> List[Int]:
    var out = List[Int]()
    out.append(1)
    out.append(2)
    out.append(3)
    out.append(7)
    out.append(1000)
    out.append(2047)
    out.append(2049)
    out.append(1000003)
    out.append(1099511627779)
    return out^


def test_the_emulation_is_the_oracle_for_every_scale() raises:
    var totals = _totals()
    var counts = _counts()
    for t in range(len(totals)):
        for c in range(len(counts)):
            for scale in range(39):
                var got = _avg_emulated(totals[t], counts[c], scale)
                var want = _oracle(totals[t], counts[c], scale)
                assert_true(
                    got == want,
                    "total "
                    + String(totals[t])
                    + " count "
                    + String(counts[c])
                    + " scale "
                    + String(scale)
                    + ": "
                    + String(got)
                    + " vs "
                    + String(want),
                )
                var fast = _avg_long_double(totals[t], counts[c], scale)
                assert_true(fast == want, "fast path at scale " + String(scale))


# --- the fast path ------------------------------------------------------------


def test_the_fast_path_condition_at_each_limit() raises:
    """|total| < 2^53 and count * 10^scale < 2048 (scale <= 3), nothing else."""
    var two53 = U128(9007199254740992)
    assert_true(_avg_fast_path_applies(two53 - 1, 2047, 0))
    assert_false(_avg_fast_path_applies(two53, 2047, 0))
    assert_true(_avg_fast_path_applies(two53 - 1, 2047, 0))
    assert_false(_avg_fast_path_applies(two53 - 1, 2048, 0))
    assert_true(_avg_fast_path_applies(U128(5), 204, 1))
    assert_false(_avg_fast_path_applies(U128(5), 205, 1))
    assert_true(_avg_fast_path_applies(U128(5), 20, 2))
    assert_false(_avg_fast_path_applies(U128(5), 21, 2))
    assert_true(_avg_fast_path_applies(U128(5), 2, 3))
    assert_false(_avg_fast_path_applies(U128(5), 3, 3))
    assert_false(_avg_fast_path_applies(U128(5), 1, 4))


def test_where_the_fast_path_applies_the_double_division_is_the_emulation() raises:
    """Below count * 10^scale = 2^11 the 64-bit rounding cannot land on a
    midpoint of two doubles (a quotient of integers below 2^53 and 2^11 is
    at least 2^-53 / 2^11 = 2^-64 from one), so the double division is the
    emulated result: checked on a sweep, with the emulation at the limits."""
    var x = UInt64(88172645463325252)
    for i in range(3000):
        x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        var n = Int((x >> 11) & UInt64(0x1FFFFFFFFFFFFF))
        var scale = i % 4
        var limit = 2047
        for _ in range(scale):
            limit = limit // 10
        var count = 1 + Int((x >> 3) % UInt64(limit))
        var d = Float64(count)
        for _ in range(scale):
            d = d * 10.0
        var plain = Float64(n) / d
        assert_true(_avg_emulated(I128(n), count, scale) == plain)
        assert_true(_avg_emulated(I128(-n), count, scale) == -plain)
    assert_true(_avg_emulated(I128(9007199254740991), 2047, 0) == Float64(9007199254740991.0) / Float64(2047.0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# float_decimal_to_f64 — w * 10^q to the nearest double, ties to even.
# =============================================================================
#
# `decimal_to_f64(w, q)` returns the IEEE 754 double nearest to w * 10^q for
# a 64-bit w (round to nearest, ties to even), in constant time:
#
#   1. Out of range: q < -342 gives +0.0 (w * 10^q < 2^64 * 10^-343, below
#      half the smallest subnormal); q > 308 gives +Inf (w >= 1).
#   2. Clinger's fast path: w <= 2^53 and |q| <= 22. Float64(w) and 10^|q|
#      are both exact, so one IEEE multiply or divide is correctly rounded.
#   3. Otherwise Eisel-Lemire (Lemire, "Number Parsing at a Gigabyte per
#      Second", 2021): w is normalised to a 64-bit word and multiplied by a
#      128-bit approximation of 5^q (float_pow5_table.mojo); the top bits of
#      the product, with the binary exponent of 10^q, give the mantissa.
#      The second 64 bits of 5^q are folded in when the first product
#      leaves the mantissa bits undecided. Mushtak and Lemire ("Fast Number
#      Parsing Without Fallback", 2023) prove this product always decides
#      the rounding for a 64-bit w and binary64, so there is no fallback.
#      Exact halfway cases (only possible for q in [-4, 23], where the
#      product is exact) round to even.
#
# This is a port of `compute_float` from the fast_float library (the same
# steps and constants), with the subnormal and overflow handling there.
# =============================================================================

from std.bit import count_leading_zeros
from std.builtin.globals import global_constant
from std.memory import bitcast

from komira_jsonl.value_parsers.float_pow5_table import (
    POW5_128_MAX_Q,
    POW5_128_MIN_Q,
    pow5_128_hi,
    pow5_128_lo,
)

comptime _MANTISSA_BITS: Int = 52
comptime _INFINITE_POWER: Int = 0x7FF
comptime _POS_INF_BITS: UInt64 = 0x7FF0000000000000

comptime _EXACT_POW10: InlineArray[Float64, 23] = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
]
"""10^k for k in [0, 22]: every one is exact in binary64 (5^22 < 2^53)."""


@always_inline
def _from_bits(bits: UInt64) -> Float64:
    return bitcast[DType.float64, 1](bits)


@always_inline
def _power(q: Int) -> Int:
    """floor(q * log2(10)) + 63, exact for q in [-342, 308]."""
    return (((152170 + 65536) * q) >> 16) + 63


def decimal_to_f64(w: UInt64, q: Int) -> Float64:
    """The double nearest to w * 10^q, ties to even, for any w (0 gives
    +0.0) and any q. Never negative: the caller applies the sign."""
    if w == 0 or q < POW5_128_MIN_Q:
        return _from_bits(0)
    if q > POW5_128_MAX_Q:
        return _from_bits(_POS_INF_BITS)
    if w <= (UInt64(1) << 53) and q >= -22 and q <= 22:
        var f = w.cast[DType.float64]()
        if q >= 0:
            return f * global_constant[_EXACT_POW10]()[q]
        return f / global_constant[_EXACT_POW10]()[-q]
    return _eisel_lemire(w, q)


def _eisel_lemire(w_in: UInt64, q: Int) -> Float64:
    """Eisel-Lemire for w_in != 0 and POW5_128_MIN_Q <= q <= POW5_128_MAX_Q
    (see the module header)."""
    var lz = Int(count_leading_zeros(w_in))
    var w = w_in << UInt64(lz)
    comptime low64 = UInt128(0xFFFFFFFFFFFFFFFF)
    var first = w.cast[DType.uint128]() * pow5_128_hi(q).cast[DType.uint128]()
    var hi = (first >> 64).cast[DType.uint64]()
    var lo = (first & low64).cast[DType.uint64]()
    # The mantissa needs the top 52 + 3 bits of `hi` (implicit bit, round
    # bit, and the bit `upperbit` may cost). When every bit below those is
    # set, the truncated tail of 5^q could carry into them: refine with the
    # next 64 bits of 5^q.
    comptime precision_mask = UInt64(0xFFFFFFFFFFFFFFFF) >> UInt64(
        _MANTISSA_BITS + 3
    )
    if (hi & precision_mask) == precision_mask:
        var second = w.cast[DType.uint128]() * pow5_128_lo(q).cast[DType.uint128]()
        var second_hi = (second >> 64).cast[DType.uint64]()
        lo = lo + second_hi  # wraps; a wrap is the carry into `hi`
        if second_hi > lo:
            hi = hi + 1

    var upperbit = Int(hi >> UInt64(63))
    var shift = upperbit + 64 - _MANTISSA_BITS - 3
    var mantissa = hi >> UInt64(shift)
    # Biased binary exponent (minimum exponent -1023).
    var power2 = _power(q) + upperbit - lz + 1023

    if power2 <= 0:
        # Subnormal (or zero). More than 64 bits below the smallest
        # exponent: zero.
        if -power2 + 1 >= 64:
            return _from_bits(0)
        mantissa >>= UInt64(-power2 + 1)
        mantissa += mantissa & UInt64(1)  # round half up; no exact
        mantissa >>= UInt64(1)  # halfway case exists down here
        # Rounding can carry into the smallest normal: the carry bit is
        # bit 52, which is exponent field 1 with a zero fraction.
        return _from_bits(mantissa)

    # An exact halfway point (the product is exact and every bit shifted
    # out of `hi` was zero) with an even neighbour below: do not round up.
    if (
        lo <= UInt64(1)
        and q >= -4
        and q <= 23
        and (mantissa & UInt64(3)) == UInt64(1)
    ):
        if (mantissa << UInt64(shift)) == hi:
            mantissa &= ~UInt64(1)

    mantissa += mantissa & UInt64(1)
    mantissa >>= UInt64(1)
    if mantissa >= (UInt64(2) << UInt64(_MANTISSA_BITS)):
        mantissa = UInt64(1) << UInt64(_MANTISSA_BITS)
        power2 += 1
    mantissa &= ~(UInt64(1) << UInt64(_MANTISSA_BITS))
    if power2 >= _INFINITE_POWER:
        return _from_bits(_POS_INF_BITS)
    return _from_bits(mantissa | (UInt64(power2) << UInt64(_MANTISSA_BITS)))

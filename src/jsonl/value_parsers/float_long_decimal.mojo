# =============================================================================
# float_long_decimal — exact rounding of a decimal with more than 19 digits.
# =============================================================================
#
# parse_float_f64 keeps the first 19 significant digits as a 64-bit w and
# rounds w * 10^q and (w + 1) * 10^q (float_decimal_to_f64.mojo). The
# decimal x lies strictly between the two (a dropped digit is nonzero), so
# when both round to the same double, so does x. When they differ they are
# adjacent doubles `below` and `above`, and x rounds to `below` exactly when
# it is under their midpoint m (to the even one of the two when it is on
# m). `round_long_decimal` decides that comparison exactly, in integers:
#
#   x = D * 10^e     (D: the first _MAX_DIGITS significant digits, e: the
#                     decimal exponent of the last one kept)
#   m = M * 2^b      (M = 2 * mantissa(below) + 1, b = exponent(below) - 1)
#   x vs m  <=>  D * 5^e * 2^e  vs  M * 2^b
#
# with 5^|e| moved to the side where it multiplies and the power of two
# moved to the side where it shifts left, so both sides are integers.
#
# Digits past the _MAX_DIGITS-th significant one are dropped and remembered
# as `tail` (a nonzero digit among them). That decides every comparison.
# x and m both lie in [w * 10^q, (w + 1) * 10^q] (w * 10^q rounds to
# `below` <= m, (w + 1) * 10^q to `above` >= m), so the leading decimal
# place L of x is at most that of m < 2^(b + 54), i.e. L <= 0.302 (b + 54).
# With b >= -1075 that gives L - 799 <= min(b, 0): m is a multiple of
# 10^(L - 799), as is the 800-digit prefix P of x (its last place). So
# P < m implies P + 10^(L - 799) <= m, and x < P + 10^(L - 799): x compares
# with m as P does, except that P == m with a nonzero tail means x > m.
#
# Size: D < 10^800, |e| <= 1123 (x is at least 2^-1075 when a decision is
# needed), and once scaled both sides are close to x * 2^-min(e, b) *
# 5^-min(e, 0): under 2700 bits (85 32-bit limbs). The work is bounded by the digit cap and that size, not by the
# length of the text beyond one scan of its digits.
# =============================================================================

from std.memory import bitcast

comptime _MAX_DIGITS: Int = 800
comptime _POW5_13: UInt32 = 1220703125
"""5^13, the largest power of five below 2^32."""


# --- Unsigned big integers: little-endian 32-bit limbs, no leading zero limb.


def _trim(mut a: List[UInt32]):
    while len(a) > 0 and a[len(a) - 1] == UInt32(0):
        _ = a.pop()


def _mul_add_small(mut a: List[UInt32], m: UInt32, add: UInt32):
    """a = a * m + add."""
    var carry = UInt64(add)
    for i in range(len(a)):
        var t = UInt64(a[i]) * UInt64(m) + carry
        a[i] = UInt32(t & UInt64(0xFFFFFFFF))
        carry = t >> UInt64(32)
    if carry != UInt64(0):
        a.append(UInt32(carry))


def _mul_pow5(mut a: List[UInt32], n: Int):
    """a = a * 5^n, n >= 0."""
    var k = n
    while k >= 13:
        _mul_add_small(a, _POW5_13, UInt32(0))
        k -= 13
    var m = UInt32(1)
    for _ in range(k):
        m *= UInt32(5)
    if m != UInt32(1):
        _mul_add_small(a, m, UInt32(0))


def _shl(mut a: List[UInt32], bits: Int):
    """a = a << bits, bits >= 0."""
    if len(a) == 0 or bits == 0:
        return
    var limbs = bits // 32
    var r = bits % 32
    if r != 0:
        var carry = UInt32(0)
        for i in range(len(a)):
            var v = a[i]
            a[i] = (v << UInt32(r)) | carry
            carry = v >> UInt32(32 - r)
        if carry != UInt32(0):
            a.append(carry)
    if limbs > 0:
        var out = List[UInt32](capacity=len(a) + limbs)
        for _ in range(limbs):
            out.append(UInt32(0))
        for i in range(len(a)):
            out.append(a[i])
        a = out^


def _cmp(a: List[UInt32], b: List[UInt32]) -> Int:
    """-1, 0 or 1 as a <, ==, > b (both trimmed)."""
    if len(a) != len(b):
        return -1 if len(a) < len(b) else 1
    var i = len(a) - 1
    while i >= 0:
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
        i -= 1
    return 0


def _from_u64(v: UInt64) -> List[UInt32]:
    var out = List[UInt32]()
    out.append(UInt32(v & UInt64(0xFFFFFFFF)))
    out.append(UInt32(v >> UInt64(32)))
    _trim(out)
    return out^


def round_long_decimal(
    bytes: Span[UInt8, _],
    int_start: Int,
    int_end: Int,
    frac_start: Int,
    frac_end: Int,
    exp10: Int,
    below: Float64,
) -> Float64:
    """The double nearest to the decimal `I.F * 10^exp10` (ties to even),
    given that it is `below` or the next double up from it.

    `bytes[int_start:int_end]` (I) and `bytes[frac_start:frac_end]` (F) are
    the ASCII digits before and after the point (either may be empty), `below` is non-negative and finite, and
    the decimal is not equal to `below` (see the module header)."""
    # D, e and tail (module header). Leading zeros are skipped; every
    # fraction digit before the cap moves the point one place.
    var d = List[UInt32]()
    var nd = 0
    var e = exp10
    var tail = False
    var chunk = UInt32(0)
    var chunk_len = 0
    for i in range(int_start, int_end):
        var v = UInt32(Int(bytes[i]) - 0x30)
        if nd >= _MAX_DIGITS:
            e += 1
            if v != UInt32(0):
                tail = True
        elif nd > 0 or v != UInt32(0):
            chunk = chunk * UInt32(10) + v
            chunk_len += 1
            nd += 1
            if chunk_len == 9:
                _mul_add_small(d, UInt32(1000000000), chunk)
                chunk = UInt32(0)
                chunk_len = 0
    for i in range(frac_start, frac_end):
        var v = UInt32(Int(bytes[i]) - 0x30)
        if nd >= _MAX_DIGITS:
            if v != UInt32(0):
                tail = True
        else:
            e -= 1
            if nd > 0 or v != UInt32(0):
                chunk = chunk * UInt32(10) + v
                chunk_len += 1
                nd += 1
                if chunk_len == 9:
                    _mul_add_small(d, UInt32(1000000000), chunk)
                    chunk = UInt32(0)
                    chunk_len = 0
    if chunk_len > 0:
        var scale = UInt32(1)
        for _ in range(chunk_len):
            scale *= UInt32(10)
        _mul_add_small(d, scale, chunk)
    _trim(d)

    # m = M * 2^b from `below`.
    var bits = bitcast[DType.uint64, 1](below)
    var field = Int((bits >> UInt64(52)) & UInt64(0x7FF))
    var frac = bits & UInt64(0xFFFFFFFFFFFFF)
    var mant: UInt64
    var exp2: Int
    if field == 0:
        mant = frac
        exp2 = -1074
    else:
        mant = frac | (UInt64(1) << UInt64(52))
        exp2 = field - 1075
    var m = _from_u64(UInt64(2) * mant + UInt64(1))
    var b = exp2 - 1

    if e >= 0:
        _mul_pow5(d, e)
    else:
        _mul_pow5(m, -e)
    if e >= b:
        _shl(d, e - b)
    else:
        _shl(m, b - e)

    var c = _cmp(d, m)
    if c == 0 and tail:
        c = 1
    var above = bitcast[DType.float64, 1](bits + UInt64(1))
    if c < 0:
        return below
    if c > 0:
        return above
    return below if (bits & UInt64(1)) == UInt64(0) else above

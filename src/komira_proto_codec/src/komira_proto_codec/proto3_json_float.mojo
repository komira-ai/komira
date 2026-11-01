# =============================================================================
# proto3_json_float.mojo — the proto3-JSON form of a `float` (float32) value,
# and of a `double` (float64) one (the last section).
# =============================================================================
#
# One writer and one reader, used by every float32 path in the codec (the
# `float` field, the `repeated float` element) and by `google.protobuf.
# FloatValue` in `komira_wkt`, so all of them print and accept the same
# text.
#
# WRITE. A finite value is a JSON number: the SHORTEST decimal that parses
# back to the same float32, as protobuf's JSON mapping prints it (0.1 is
# `0.1`, not its float64 expansion `0.10000000149011612`). The non-finite
# values are the spec's STRINGS "NaN", "Infinity", "-Infinity": a JSON
# number cannot carry them, and `null` would read back as an absent field
# (0.0).
#
# The digits are NOT the standard library's: `String(Float32)` prints too
# few digits for some small magnitudes (2^-149 * 1591867 prints as
# `2.23068e-39`, which reads back as its neighbour 2^-149 * 1591866; about
# 0.5% of a strided sweep of float32 bit patterns fails to round-trip).
# They come from the Burger-Dybvig free-format algorithm ("Printing
# Floating-Point Numbers Quickly and Accurately", PLDI), run in exact
# integer arithmetic (`_Big`, 256 bits; the largest intermediate is under
# 2^180). For v = f * 2^e the algorithm holds v and the half-gaps to its
# float32 neighbours as exact ratios r/s, m-/s, m+/s, scales them by 10^k so
# the upper end of the rounding interval is just under 1, and emits one
# digit at a time, stopping at the first digit position where the decimal
# prefix (rounded down, or up by one) lies inside the rounding interval.
# Why that is correct:
#   - Every quantity is an exact integer, so the in-interval tests are exact.
#   - The interval is the set of reals that round to v under the reader's
#     round-to-nearest-even: half a gap each side, the lower one half as
#     wide when v is a power of two above the smallest normal, and the
#     endpoints included exactly when f is even (a tie reads back as v).
#   - It stops at the first length at which ANY decimal of that length lies
#     in the interval, so the output is the shortest; at most 9 digits for
#     a float32. When both the rounded-down and the rounded-up prefix are
#     inside, the nearer one to v is chosen (ties: the even digit).
# The text layout matches the float64 writer's (`write_f64_dtoa`): positional
# for decimal exponents -5 < E < 16 (`0.0001`, `1.5`, `16777216.0`),
# otherwise `d.ddde±XX` with at least two exponent digits (`1e-05`,
# `3.4028235e+38`, `1e-45`); zero is `0.0` / `-0.0`.
#
# READ. The rules, in order:
#   1. A JSON string that is exactly "NaN", "Infinity" or "-Infinity" is
#      that value. No other spelling names a non-finite value: "inf",
#      "nan", "-inf", "infinity" (all of which the standard `atof`
#      accepts) are refused.
#   2. Any other JSON number, or JSON string holding a number of the form
#      `-?D+(.D+)?([eE][+-]?D+)?` (JSON number syntax, leading zeros
#      allowed), is rounded STRAIGHT to the nearest float32, ties to even
#      (`parse_decimal_f32` in `float32_parse.mojo`, exact integer
#      arithmetic, no length limit on the digits or the exponent). It is
#      not parsed to a Float64 first: that rounds twice, and is wrong next
#      to every float32 midpoint
#      (1.0000000596046448 would read as 1.0, and the writer's own
#      `7.038531e-26` for 0x15AE43FD would read back as 0x15AE43FE).
#      Other text (" 1.5", "+1.5", "1.5f", ".5") is refused.
#   3. A finite decimal outside float32 range is REFUSED, never read as an
#      infinity: refused exactly when it rounds past float32 max, i.e. when
#      |x| >= 2^128 - 2^103 (the midpoint between max and 2^128, which ties
#      to the even 2^128). So `3.4028235e38` (the shortest spelling of max,
#      larger than max as a double) and 2^128 - 2^103 - 1 are max, and
#      2^128 - 2^103, `3.4028236e38`, `1e39` and `1e400` are refused.
#   4. Underflow is not an error, as for the float64 reader and protobuf's
#      parsers: a value below the float32 normal range rounds to the
#      nearest subnormal, and one at or below half the smallest subnormal
#      (2^-150; exactly 2^-150 ties to the even zero) is a zero of its sign
#      (`-1e-46` is -0.0).
#
# ROUND TRIP. The writer's decimal lies inside the value's rounding
# interval (exact arithmetic), on an endpoint only when the mantissa is
# even, and the reader rounds correctly with ties to even, so every finite
# float32 reads back as itself.
# =============================================================================

from std.math import isinf, isnan
from std.memory import bitcast

from komira_json import (
    JsonValue,
    JSON_NUMBER,
    JSON_STRING,
    write_f64_dtoa,
    write_json_string,
)

from .float32_bignum import (
    big_add,
    big_cmp,
    big_from,
    big_mul_pow10,
    big_mul_small,
    big_shl,
    big_sub,
)
from .float32_parse import parse_decimal_f32
from .float64_parse import parse_decimal_f64


# =============================================================================
# Write.
# =============================================================================


def write_proto3_json_f32(mut buf: List[UInt8], v: Float32):
    """Append the proto3-JSON text of a float32: the shortest round-trip
    decimal, or one of the strings "NaN" / "Infinity" / "-Infinity"."""
    if isnan(v):
        write_json_string(buf, String("NaN"))
        return
    if isinf(v):
        if v > 0:
            write_json_string(buf, String("Infinity"))
        else:
            write_json_string(buf, String("-Infinity"))
        return
    var bits = bitcast[DType.uint32](v)
    if (bits >> UInt32(31)) != UInt32(0):
        buf.append(UInt8(ord("-")))
    var field_exp = Int((bits >> UInt32(23)) & UInt32(0xFF))
    var frac = UInt64(bits & UInt32(0x7FFFFF))
    if field_exp == 0 and frac == UInt64(0):
        _append_str(buf, "0.0")
        return
    var f: UInt64
    var e: Int
    if field_exp == 0:
        f = frac  # subnormal: no hidden bit
        e = -149
    else:
        f = frac | UInt64(0x800000)
        e = field_exp - 150
    var digits = InlineArray[UInt8, 20](fill=UInt8(0))
    var k = 0
    var n = _shortest_digits(f, e, digits, k)
    _layout(buf, digits, n, k)


comptime _LIMBS = 8  # the writer's largest intermediate is under 2^180
comptime _Big = InlineArray[UInt32, _LIMBS]


def _high_reached(r: _Big, m_plus: _Big, s: _Big, closed: Bool) -> Bool:
    """r + m+ reaches s: the upper end of the interval is at or past s
    (at, only when the interval is closed)."""
    var c = big_cmp(big_add(r, m_plus), s)
    return c > 0 or (closed and c == 0)


def _shortest_digits(
    f: UInt64, e: Int, mut digits: InlineArray[UInt8, 20], mut k: Int
) -> Int:
    """Burger-Dybvig free-format digits of v = f * 2^e (f > 0): fills
    `digits` with d1..dn (values 0..9) and sets `k` so that
    v ~ 0.d1..dn * 10^k. Returns n."""
    var closed = (f & UInt64(1)) == UInt64(0)
    # The lower gap is half the upper one at a power of two, except at the
    # smallest normal (its lower neighbour, a subnormal, is one gap away).
    var unequal = f == UInt64(0x800000) and e > -149
    var r: _Big
    var s: _Big
    var m_plus: _Big
    var m_minus: _Big
    if e >= 0:
        r = big_from[_LIMBS](f)
        big_shl(r, e + (2 if unequal else 1))
        s = big_from[_LIMBS](UInt64(4) if unequal else UInt64(2))
        m_plus = big_from[_LIMBS](UInt64(1))
        big_shl(m_plus, e + (1 if unequal else 0))
        m_minus = big_from[_LIMBS](UInt64(1))
        big_shl(m_minus, e)
    else:
        r = big_from[_LIMBS](f * (UInt64(4) if unequal else UInt64(2)))
        s = big_from[_LIMBS](UInt64(1))
        big_shl(s, (2 if unequal else 1) - e)
        m_plus = big_from[_LIMBS](UInt64(2) if unequal else UInt64(1))
        m_minus = big_from[_LIMBS](UInt64(1))
    # Estimate k = ceil(log10(v)) from the binary exponent (within one),
    # scale, then correct the estimate exactly.
    var bitlen = 0
    var t = f
    while t > UInt64(0):
        bitlen += 1
        t >>= UInt64(1)
    var e2 = e + bitlen - 1  # v in [2^e2, 2^(e2+1))
    k = (e2 * 1233) // 4096 + 1  # 1233 / 4096 ~ log10(2)
    if k >= 0:
        big_mul_pow10(s, k)
    else:
        big_mul_pow10(r, -k)
        big_mul_pow10(m_plus, -k)
        big_mul_pow10(m_minus, -k)
    # Make 10^(k-1) <= high < 10^k (high's own end per `closed`).
    while _high_reached(r, m_plus, s, closed):
        big_mul_small(s, UInt32(10))
        k += 1
    while True:
        var r10 = r.copy()
        var mp10 = m_plus.copy()
        big_mul_small(r10, UInt32(10))
        big_mul_small(mp10, UInt32(10))
        if _high_reached(r10, mp10, s, closed):
            break
        r = r10^  # cov: unreachable k never overestimates for float32: floor(e2*1233/4096) == floor(e2*log10 2) on e2 in [-149, 127], so 10^(k-1) <= v < high
        m_plus = mp10^  # cov: unreachable see the line above
        big_mul_small(m_minus, UInt32(10))  # cov: unreachable see the line above
        k -= 1  # cov: unreachable see the line above
    # Generate digits.
    var n = 0
    while n < 20:
        big_mul_small(r, UInt32(10))
        big_mul_small(m_plus, UInt32(10))
        big_mul_small(m_minus, UInt32(10))
        var d = 0
        while big_cmp(r, s) >= 0:
            big_sub(r, s)
            d += 1
        var c_low = big_cmp(r, m_minus)
        var low_ok = c_low < 0 or (closed and c_low == 0)
        var high_ok = _high_reached(r, m_plus, s, closed)
        if not low_ok and not high_ok:
            digits[n] = UInt8(d)
            n += 1
            continue
        if high_ok and not low_ok:
            d += 1
        elif low_ok and high_ok:
            var c_mid = big_cmp(big_add(r, r), s)
            if c_mid > 0 or (c_mid == 0 and d % 2 == 1):
                d += 1
        digits[n] = UInt8(d)
        n += 1
        break
    # A rounded-up last digit cannot reach 10 (a shorter decimal would have
    # been inside the interval and ended the loop earlier); propagate a
    # carry anyway rather than ever write a non-digit byte.
    var i = n - 1
    while i > 0 and digits[i] > UInt8(9):
        digits[i] = UInt8(0)  # cov: unreachable a digit rounded up is at most 9: d = 9 with high_ok would have met high_ok one digit earlier
        digits[i - 1] += UInt8(1)  # cov: unreachable see the line above
        i -= 1
    if digits[0] > UInt8(9):
        digits[0] = UInt8(1)  # cov: unreachable see line 241
        k += 1  # cov: unreachable see line 241
    while n > 1 and digits[n - 1] == UInt8(0):
        n -= 1  # cov: unreachable from the float32 writer: a float32 (24-bit mantissa) ends within 9 digits on a nonzero digit (low_ok after a 0 would have held one digit earlier); only a direct call with a wider mantissa can hit the 20-digit cap on a 0, and that truncated output is not a value to pin
    return n


def _layout(
    mut buf: List[UInt8], digits: InlineArray[UInt8, 20], n: Int, k: Int
):
    """Write 0.d1..dn * 10^k in the float64 writer's layout."""
    var exp10 = k - 1  # the decimal exponent of d1
    if exp10 < -4 or exp10 > 15:
        buf.append(UInt8(0x30) + digits[0])
        if n > 1:
            buf.append(UInt8(ord(".")))
            for i in range(1, n):
                buf.append(UInt8(0x30) + digits[i])
        buf.append(UInt8(ord("e")))
        var x = exp10
        if x < 0:
            buf.append(UInt8(ord("-")))
            x = -x
        else:
            buf.append(UInt8(ord("+")))
        if x < 10:
            buf.append(UInt8(0x30))
            buf.append(UInt8(0x30 + x))
        else:
            if x >= 100:
                buf.append(UInt8(0x30 + x // 100))
            buf.append(UInt8(0x30 + (x // 10) % 10))
            buf.append(UInt8(0x30 + x % 10))
        return
    if exp10 < 0:
        _append_str(buf, "0.")
        for _ in range(-exp10 - 1):
            buf.append(UInt8(0x30))
        for i in range(n):
            buf.append(UInt8(0x30) + digits[i])
        return
    # 0 <= exp10 <= 15: integer part, then the fraction (at least `.0`).
    for i in range(exp10 + 1):
        if i < n:
            buf.append(UInt8(0x30) + digits[i])
        else:
            buf.append(UInt8(0x30))
    buf.append(UInt8(ord(".")))
    if n <= exp10 + 1:
        buf.append(UInt8(0x30))
        return
    for i in range(exp10 + 1, n):
        buf.append(UInt8(0x30) + digits[i])


def _append_str(mut buf: List[UInt8], s: StaticString):
    buf.extend(Span(s.as_bytes()))


# =============================================================================
# Read.
# =============================================================================


def read_proto3_json_f32(v: JsonValue) raises -> Float32:
    """Read a float32 from a proto3-JSON value (a number, or a string
    holding a number or one of the three non-finite spellings), rounded
    straight to float32. Refuses a value that rounds past float32 max and
    any other non-finite spelling; see the module header for the rules."""
    if v.kind == JSON_STRING:
        if v.text == "NaN":
            return _f32_nan()
        if v.text == "Infinity":
            return _f32_inf()
        if v.text == "-Infinity":
            return -_f32_inf()
    elif v.kind != JSON_NUMBER:
        # A bool, null, object or array: the float64 reader's refusal.
        _ = v.as_float64()
        raise Error("JsonError: not a proto3 float")  # cov: unreachable as_float64() raises for every kind but a number or a string
    return parse_decimal_f32(v.text)


def _f32_inf() -> Float32:
    return bitcast[DType.float32](UInt32(0x7F800000))


def _f32_nan() -> Float32:
    return bitcast[DType.float32](UInt32(0x7FC00000))


# =============================================================================
# The `double` (float64) form: the same rules as float32's, at float64's
# width. WRITE: a finite value is the shortest round-trip JSON number
# (`write_f64_dtoa`); NaN / +Inf / -Inf are the strings "NaN" / "Infinity" /
# "-Infinity" (`write_f64_dtoa` alone would write `null`, which reads back as
# an absent field). READ: the three spec strings, or a JSON number or numeric
# string of any length rounded to the nearest double (`parse_decimal_f64`);
# a value past the double range is refused, so every value the reader
# returns is one the writer writes and reads back as itself.
# =============================================================================


def write_proto3_json_f64(mut buf: List[UInt8], v: Float64):
    """Append the proto3-JSON text of a double: a JSON number, or one of the
    strings "NaN" / "Infinity" / "-Infinity"."""
    if isnan(v):
        write_json_string(buf, String("NaN"))
    elif isinf(v):
        if v > 0:
            write_json_string(buf, String("Infinity"))
        else:
            write_json_string(buf, String("-Infinity"))
    else:
        write_f64_dtoa(buf, v)


def read_proto3_json_f64(v: JsonValue) raises -> Float64:
    """Read a double from a proto3-JSON value (a number, or a string holding
    a number or one of the three non-finite spellings), correctly rounded.
    Refuses a value that rounds past the largest double and any other
    non-finite spelling."""
    if v.kind == JSON_STRING:
        if v.text == "NaN":
            return _f64_nan()
        if v.text == "Infinity":
            return _f64_inf()
        if v.text == "-Infinity":
            return -_f64_inf()
    elif v.kind != JSON_NUMBER:
        # A bool, null, object or array: the JSON value's own refusal.
        _ = v.as_float64()
        raise Error("JsonError: not a proto3 double")  # cov: unreachable as_float64() raises for every kind but a number or a string
    return parse_decimal_f64(v.text)


def _f64_inf() -> Float64:
    return bitcast[DType.float64](UInt64(0x7FF0000000000000))


def _f64_nan() -> Float64:
    return bitcast[DType.float64](UInt64(0x7FF8000000000000))

# =============================================================================
# parse_decimal — JSON number/string → Decimal128(p, s) unscaled int128
# =============================================================================
#
# JSON has
# no native decimal literal; the Stage 2 walker accepts either a JSON
# number ("123.45") or a JSON string ("123.45") for DECIMAL128 columns.
# Both produce the same unscaled int128 representation.
#
# Public surface:
#   - `parse_decimal128_unscaled(bytes, start, end, precision, scale)
#        raises -> SIMD[DType.int128, 1]`
#       Parse the byte range as a decimal value; return the i128 with
#       value = trunc(parsed * 10^scale).
#
# Grammar:
#   [ - / + ] digits [ . digits ] [ (e / E) [ - / + ] digits ]
#   The exponent is RFC 8259's: `1e2`, `1.5E-1` and `-2e+3` are numbers.
#
# Encapsulation:
#   - Spans + scalar return; no UnsafePointer.
#
# Algorithm (no allocation; the digits are read from `bytes` in place):
#   1. Read the optional sign, the integer digits, the optional fraction
#      digits and the optional exponent. The integer and fraction digits
#      are one digit sequence D with the decimal point after the integer
#      digits.
#   2. Drop D's leading zeros; the point moves left by the number dropped,
#      then right by the exponent. `point` is now the number of significant
#      integer digits when positive (the value is 0.D x 10^point).
#   3. Validate `point` against `precision - scale` (raises on overflow),
#      before any multiply, so the i128 accumulator cannot wrap.
#   4. The unscaled value is the first `point + scale` digits of D, padded
#      with zeros past its end: excess fractional digits are truncated (no
#      rounding policy), and `point + scale <= 0` gives 0.
#   5. Apply sign.
#
# NOTE: Mojo supports `SIMD[DType.int128, 1]` (signed 128-bit
# arithmetic). The Decimal128 array's `from_i128_list` factory consumes
# this type directly.
# =============================================================================


@always_inline
def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(0x30) and b <= UInt8(0x39)


def _digit_at(
    bytes: Span[UInt8, _], int_start: Int, int_len: Int, frac_start: Int, j: Int
) -> Int:
    """Digit `j` of the integer digits followed by the fraction digits."""
    if j < int_len:
        return Int(bytes[int_start + j]) - 0x30
    return Int(bytes[frac_start + j - int_len]) - 0x30


# The exponent stops accumulating here, so it cannot wrap the Int. Unless
# the number has close to a billion digits of its own, a nonzero value with
# an exponent this large overflows any precision (point > 38) or truncates
# to 0 at any scale (point + scale < 0): a larger one changes no result.
comptime _EXP_CAP: Int = 1_000_000_000


def parse_decimal128_unscaled(
    bytes: Span[UInt8, _],
    start: Int,
    end: Int,
    precision: Int,
    scale: Int,
) raises -> SIMD[DType.int128, 1]:
    """Parse `bytes[start..end]` and return the i128 unscaled value for
    a DECIMAL128(precision, scale) column.

    Accepts an exponent (`1e2`, `1.5E-1`). Truncates excess fractional
    digits. Raises on:
      * Empty range or lone sign.
      * An `e`/`E` without exponent digits; any other trailing byte.
      * Integer overflow past `precision - scale` significant digits.
    """
    if end <= start:
        raise Error("parse_decimal128_unscaled: empty byte range")
    if precision <= 0 or precision > 38:
        raise Error("parse_decimal128_unscaled: precision out of range [1, 38]: " + String(precision))
    if scale < 0 or scale > precision:
        raise Error("parse_decimal128_unscaled: scale out of range [0, precision]: " + String(scale))

    var i = start
    # Skip a leading quote if value came in as a JSON string ("...").
    if bytes[i] == UInt8(0x22):
        i += 1

    var negative = False
    if i < end and bytes[i] == UInt8(0x2D):
        negative = True
        i += 1
    elif i < end and bytes[i] == UInt8(0x2B):
        i += 1
    if i >= end:
        raise Error("parse_decimal128_unscaled: lone sign without digits")

    # Integer digits.
    if not _is_digit(bytes[i]):
        raise Error("parse_decimal128_unscaled: non-digit at integer start position " + String(i))
    var int_start = i
    while i < end and _is_digit(bytes[i]):
        i += 1
    var int_len = i - int_start

    # Fraction digits.
    var frac_start = i
    var frac_len = 0
    if i < end and bytes[i] == UInt8(0x2E):  # '.'
        i += 1
        if i >= end or not _is_digit(bytes[i]):
            raise Error("parse_decimal128_unscaled: '.' must be followed by digits at position " + String(i))
        frac_start = i
        while i < end and _is_digit(bytes[i]):
            i += 1
        frac_len = i - frac_start

    # Exponent.
    var exp = 0
    if i < end and (bytes[i] == UInt8(0x65) or bytes[i] == UInt8(0x45)):  # e E
        i += 1
        var exp_negative = False
        if i < end and bytes[i] == UInt8(0x2D):
            exp_negative = True
            i += 1
        elif i < end and bytes[i] == UInt8(0x2B):
            i += 1
        if i >= end or not _is_digit(bytes[i]):
            raise Error("parse_decimal128_unscaled: exponent must have digits at position " + String(i))
        while i < end and _is_digit(bytes[i]):
            if exp < _EXP_CAP:
                exp = exp * 10 + (Int(bytes[i]) - 0x30)
            i += 1
        if exp_negative:
            exp = -exp

    # Tolerate optional trailing quote for JSON-string-shaped input.
    if i < end and bytes[i] == UInt8(0x22):
        i += 1
    if i < end:
        raise Error("parse_decimal128_unscaled: unexpected trailing byte at position " + String(i))

    # Drop leading zeros: they are not magnitude, so
    # "0000000000000000000000000000000000000001" is a 1-digit value and is
    # not rejected by the precision check below.
    var n_digits = int_len + frac_len
    var first = 0
    while first < n_digits and _digit_at(bytes, int_start, int_len, frac_start, first) == 0:
        first += 1
    if first == n_digits:
        return SIMD[DType.int128, 1](0)
    # The value is 0.D[first:] x 10^point.
    var point = int_len - first + exp

    # PRECISION CEILING (ASSERT=none hardening). `point` is the count of
    # significant integer digits. Checked before the accumulation below, so
    # at most `precision` (<= 38) digits are ever accumulated and the i128
    # (max ~1.7e38) cannot wrap into an arbitrary wrong value.
    var int_digits = point if point > 0 else 0
    if int_digits > precision - scale:
        raise Error(
            "parse_decimal128_unscaled: value has "
            + String(int_digits)
            + " integer digits, which does not fit DECIMAL128("
            + String(precision)
            + ", "
            + String(scale)
            + ") — at most "
            + String(precision - scale)
            + " integer digits are representable. Past ~38 significant"
            + " digits the i128 accumulator wraps and would store an"
            + " arbitrary wrong value."
        )

    # The first `point + scale` significant digits, zero-padded past the
    # last one; fewer than none truncates to 0.
    var result = SIMD[DType.int128, 1](0)
    var take = point + scale
    for j in range(take):
        var d = 0
        if first + j < n_digits:
            d = _digit_at(bytes, int_start, int_len, frac_start, first + j)
        result = result * SIMD[DType.int128, 1](10) + SIMD[DType.int128, 1](d)

    if negative:
        result = -result
    return result

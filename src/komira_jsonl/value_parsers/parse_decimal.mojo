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
#       value = round(parsed * 10^scale).
#
# Grammar:
#   [ - / + ] digits [ . digits ]    (no exponent; e/E raises)
#
# Encapsulation:
#   - Spans + scalar return; no UnsafePointer.
#
# Algorithm:
#   1. Read optional sign.
#   2. Accumulate integer part as i128.
#   3. If '.' present, accumulate fractional part with digit count.
#   4. Adjust to target `scale`:
#        if frac_digits == scale:  result = int_part * 10^scale + frac_part
#        if frac_digits < scale:   result = (int_part * 10^scale +
#                                            frac_part * 10^(scale-frac_digits))
#        if frac_digits > scale:   truncate (drops excess digits; no
#                                  rounding policy).
#   5. Apply sign.
#   6. Validate against `precision` digit-count limit (raises on overflow).
#
# NOTE: Mojo supports `SIMD[DType.int128, 1]` (signed 128-bit
# arithmetic). The Decimal128 array's `from_i128_list` factory consumes
# this type directly.
# =============================================================================


@always_inline
def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(0x30) and b <= UInt8(0x39)


def parse_decimal128_unscaled(
    bytes: Span[UInt8, _],
    start: Int,
    end: Int,
    precision: Int,
    scale: Int,
) raises -> SIMD[DType.int128, 1]:
    """Parse `bytes[start..end]` and return the i128 unscaled value for
    a DECIMAL128(precision, scale) column.

    Truncates excess fractional digits. Raises on:
      * Empty range or lone sign.
      * Exponent (`e`/`E`) — not supported.
      * Integer/fractional overflow past precision digits.
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

    # Integer part.
    if not _is_digit(bytes[i]):
        raise Error("parse_decimal128_unscaled: non-digit at integer start position " + String(i))
    var int_mag: SIMD[DType.int128, 1] = SIMD[DType.int128, 1](0)
    # SIGNIFICANT integer digits — leading zeros are not counted, so
    # "0000000000000000000000000000000000000001" is still a 1-digit value and
    # is not rejected by the precision check below.
    var int_digits = 0
    while i < end and _is_digit(bytes[i]):
        var d = Int(bytes[i]) - 0x30
        if int_digits == 0 and d == 0:
            pass  # leading zero: contributes nothing to the magnitude
        else:
            int_mag = (
                int_mag * SIMD[DType.int128, 1](10)
                + SIMD[DType.int128, 1](d)
            )
            int_digits += 1
        i += 1

    # PRECISION CEILING (ASSERT=none hardening).
    #
    # `int_mag` is a SIMD[int128, 1] accumulated as `mag * 10 + digit` with NO
    # digit-count limit. i128 tops out near 1.7e38, so a 60-digit JSON number
    # silently WRAPS and lands an arbitrary wrong value in the Decimal128
    # column. This is arithmetic wraparound, not a memory fault — no stdlib
    # bounds check was ever involved, so it fails identically at ASSERT=safe
    # and ASSERT=none — but the function's own docstring promises "Raises on
    # ... Integer/fractional overflow past precision digits", and a
    # stated-but-absent bound reads as protection during review, which is
    # worse than none.
    #
    # ONE compare, after the digit loop — not per digit. The wrap that may
    # already have happened inside the loop is harmless because the value is
    # discarded by this raise (i128 multiply wraps, it does not trap).
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

    # Fractional part.
    var frac_mag: SIMD[DType.int128, 1] = SIMD[DType.int128, 1](0)
    var frac_digits = 0
    if i < end and bytes[i] == UInt8(0x2E):  # '.'
        i += 1
        if i >= end or not _is_digit(bytes[i]):
            raise Error("parse_decimal128_unscaled: '.' must be followed by digits at position " + String(i))
        while i < end and _is_digit(bytes[i]):
            if frac_digits < scale:
                frac_mag = frac_mag * SIMD[DType.int128, 1](10) + SIMD[DType.int128, 1](Int(bytes[i]) - 0x30)
                frac_digits += 1
            else:
                # Truncate excess fractional digit.
                pass
            i += 1

    # Tolerate optional trailing quote for JSON-string-shaped input.
    if i < end and bytes[i] == UInt8(0x22):
        i += 1
    if i < end:
        raise Error("parse_decimal128_unscaled: unexpected trailing byte at position " + String(i) + " (exponent not supported)")

    # Scale-up fractional to match `scale`.
    var needed_frac_zeros = scale - frac_digits
    if needed_frac_zeros > 0:
        # frac_mag * 10^needed_frac_zeros
        var k = 0
        while k < needed_frac_zeros:
            frac_mag = frac_mag * SIMD[DType.int128, 1](10)
            k += 1

    # Combine: int_mag * 10^scale + frac_mag.
    var scaled_int = int_mag
    var k = 0
    while k < scale:
        scaled_int = scaled_int * SIMD[DType.int128, 1](10)
        k += 1
    var result = scaled_int + frac_mag

    if negative:
        result = -result
    # Precision is enforced ABOVE, on the significant-integer-digit count,
    # BEFORE the scale-up multiplies — which is the only place it can be
    # enforced cheaply and correctly (once, not per digit) and the only place
    # it is enforced before the i128 accumulator can wrap.
    return result

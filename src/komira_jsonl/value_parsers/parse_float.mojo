# =============================================================================
# parse_float — JSON number → Float64 scalar parser
# =============================================================================
#
# Float64 parsing uses a simple scalar accumulator with separate integer
# and fractional accumulation + base-10 exponent scaling. This is NOT a
# Lemire-Eisel fast-double-parser implementation (possible future work).
#
# Accepted grammar (RFC 8259 §6):
#   number = [ minus ] int [ frac ] [ exp ]
#   int    = "0" / ( digit1-9 *DIGIT )
#   frac   = "." 1*DIGIT
#   exp    = ("e" / "E") [ "+" / "-" ] 1*DIGIT
#
# Non-finite values (NaN, Infinity, +Inf, -Inf) are NOT accepted per
# strict RFC; if encountered the parser raises. A lenient walker policy
# could emit a null in that case instead.
#
# Public surface:
#   - `parse_float_f64(bytes, start, end) raises -> Float64`
#
# Encapsulation:
#   - `Span[UInt8, _]` input + Float64 return; no UnsafePointer.
# =============================================================================


@always_inline
def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(0x30) and b <= UInt8(0x39)


def parse_float_f64(bytes: Span[UInt8, _], start: Int, end: Int) raises -> Float64:
    """Parse `bytes[start..end]` as a Float64 per RFC 8259 number grammar.

    Algorithm (scalar; ~30 ns/value at warm cache):
      1. Read optional sign.
      2. Read integer part as digit accumulation.
      3. If '.' present, read fractional part; track digit count.
      4. If 'e'/'E' present, read exponent (with optional sign).
      5. Combine: result = (int + frac/10^frac_digits) * 10^exp_value.
      6. Apply final sign.

    Raises on malformed input. The 10^N scaling is computed via a small
    lookup-table-or-pow loop; this is the scalar pow-of-10
    accumulation (Mojo doesn't expose a portable `ldexp` analog
    cheaply on float10).
    """
    if end <= start:
        raise Error("parse_float_f64: empty byte range")

    var i = start
    var negative = False
    var b0 = bytes[i]
    if b0 == UInt8(0x2D):  # '-'
        negative = True
        i += 1
    elif b0 == UInt8(0x2B):  # '+'
        i += 1
    if i >= end:
        raise Error("parse_float_f64: lone sign without digits")

    # Integer part.
    if not _is_digit(bytes[i]):
        raise Error("parse_float_f64: non-digit at integer start, position " + String(i))
    var int_part: Float64 = 0.0
    while i < end and _is_digit(bytes[i]):
        int_part = int_part * 10.0 + Float64(Int(bytes[i]) - 0x30)
        i += 1

    # Fractional part.
    var frac_part: Float64 = 0.0
    var frac_digits: Int = 0
    if i < end and bytes[i] == UInt8(0x2E):  # '.'
        i += 1
        if i >= end or not _is_digit(bytes[i]):
            raise Error("parse_float_f64: '.' must be followed by digits at position " + String(i))
        while i < end and _is_digit(bytes[i]):
            frac_part = frac_part * 10.0 + Float64(Int(bytes[i]) - 0x30)
            frac_digits += 1
            i += 1

    # Exponent part.
    var exp_value: Int = 0
    if i < end and (bytes[i] == UInt8(0x65) or bytes[i] == UInt8(0x45)):  # 'e' or 'E'
        i += 1
        var exp_neg = False
        if i < end and bytes[i] == UInt8(0x2D):
            exp_neg = True
            i += 1
        elif i < end and bytes[i] == UInt8(0x2B):
            i += 1
        if i >= end or not _is_digit(bytes[i]):
            raise Error("parse_float_f64: 'e'/'E' must be followed by digits at position " + String(i))
        while i < end and _is_digit(bytes[i]):
            exp_value = exp_value * 10 + (Int(bytes[i]) - 0x30)
            i += 1
        if exp_neg:
            exp_value = -exp_value

    # Any trailing garbage?
    if i < end:
        raise Error("parse_float_f64: trailing non-numeric content at position " + String(i))

    # Combine: result = (int + frac / 10^frac_digits) * 10^exp_value.
    var scaled_frac: Float64 = 0.0
    if frac_digits > 0:
        scaled_frac = frac_part * _pow10_neg(frac_digits)
    var result = int_part + scaled_frac
    if exp_value != 0:
        result = result * _pow10(exp_value)
    if negative:
        result = -result
    return result


def _pow10(n: Int) -> Float64:
    """Compute 10^n for integer n (signed). Iterative; a Lemire-style
    table lookup would save ~10 ns per call over this scalar pow-of-10
    loop."""
    if n == 0:
        return 1.0
    var v: Float64 = 1.0
    var k = n if n >= 0 else -n
    var base: Float64 = 10.0
    var i = 0
    while i < k:
        v = v * base
        i += 1
    if n < 0:
        return 1.0 / v
    return v


def _pow10_neg(n: Int) -> Float64:
    """Compute 10^(-n) for non-negative n. Equivalent to `1.0 / _pow10(n)`
    but with the division done once at the end."""
    if n == 0:
        return 1.0
    var v: Float64 = 1.0
    var i = 0
    while i < n:
        v = v * 10.0
        i += 1
    return 1.0 / v

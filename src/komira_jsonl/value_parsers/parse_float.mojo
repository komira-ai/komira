# =============================================================================
# parse_float — JSON number → Float64 scalar parser
# =============================================================================
#
# The result is the IEEE 754 double nearest to the decimal (round to
# nearest, ties to even) for every input, of any length and any exponent:
# a decimal past the double range is +-Inf, one below half the smallest
# subnormal is a zero of its sign.
#
# Accepted grammar (RFC 8259 §6), plus a leading `+` and leading zeros
# (the JSONL line validator refuses both before a value reaches here):
#   number = [ minus ] int [ frac ] [ exp ]
#   int    = "0" / ( digit1-9 *DIGIT )
#   frac   = "." 1*DIGIT
#   exp    = ("e" / "E") [ "+" / "-" ] 1*DIGIT
#
# Non-finite values (NaN, Infinity, +Inf, -Inf) are NOT accepted per
# strict RFC; if encountered the parser raises.
#
# Algorithm (one pass over the bytes, then constant work):
#   1. The first 19 significant digits accumulate exactly in a UInt64 w;
#      later digits are counted (and noted if nonzero). The point and the
#      dropped integer digits set q, the decimal exponent of w.
#   2. The exponent part accumulates exactly until it reaches a cap of the
#      byte range's length plus 1000, and is then held (saturated). |q| before the
#      exponent part is at most that length, so a saturated exponent still
#      puts q + exponent beyond +-1000: +Inf or zero, as the exact exponent
#      would. Below the cap nothing is lost, and nothing overflows an Int.
#   3. `decimal_to_f64(w, q)` (float_decimal_to_f64.mojo) rounds w * 10^q in
#      constant time: Clinger's exact fast path when w <= 2^53 and
#      |q| <= 22, otherwise Eisel-Lemire with a 128-bit power-of-five
#      table. No loop runs once per unit of exponent.
#   4. More than 19 significant digits with a nonzero one dropped: the
#      value lies strictly between w * 10^q and (w + 1) * 10^q. If both
#      round to the same double, that is the answer; otherwise
#      `round_long_decimal` (float_long_decimal.mojo) decides between the
#      two adjacent doubles exactly, with big integers bounded by an
#      800-digit cap.
#
# Public surface:
#   - `parse_float_f64(bytes, start, end) raises -> Float64`
#
# Encapsulation:
#   - `Span[UInt8, _]` input + Float64 return; no UnsafePointer.
# =============================================================================

from komira_jsonl.value_parsers.float_decimal_to_f64 import decimal_to_f64
from komira_jsonl.value_parsers.float_long_decimal import round_long_decimal

comptime _W_DIGITS: Int = 19
"""Significant digits kept in w: 10^19 - 1 < 2^64, and w + 1 fits too."""


@always_inline
def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(0x30) and b <= UInt8(0x39)


def parse_float_f64(bytes: Span[UInt8, _], start: Int, end: Int) raises -> Float64:
    """Parse `bytes[start..end]` as a Float64 per RFC 8259 number grammar,
    correctly rounded (nearest, ties to even; see the module header).

    Raises on malformed input. Work is one pass over the bytes plus a
    constant (or, for more than 19 significant digits that the first 19 do
    not decide, a bounded big-integer comparison); it does not grow with
    the value of the exponent.
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
    var w: UInt64 = 0
    var nd = 0  # significant digits seen (leading zeros excluded)
    var q = 0  # w * 10^q is the value of the digits kept so far
    var dropped_nonzero = False
    var int_start = i
    while i < end and _is_digit(bytes[i]):
        var d = UInt64(Int(bytes[i]) - 0x30)
        if nd < _W_DIGITS:
            if nd > 0 or d != UInt64(0):
                w = w * UInt64(10) + d
                nd += 1
        else:
            nd += 1
            q += 1
            if d != UInt64(0):
                dropped_nonzero = True
        i += 1
    var int_end = i

    # Fractional part.
    var frac_start = i
    var frac_end = i
    if i < end and bytes[i] == UInt8(0x2E):  # '.'
        i += 1
        if i >= end or not _is_digit(bytes[i]):
            raise Error("parse_float_f64: '.' must be followed by digits at position " + String(i))
        frac_start = i
        while i < end and _is_digit(bytes[i]):
            var d = UInt64(Int(bytes[i]) - 0x30)
            if nd < _W_DIGITS:
                if nd > 0 or d != UInt64(0):
                    w = w * UInt64(10) + d
                    nd += 1
                q -= 1
            else:
                nd += 1
                if d != UInt64(0):
                    dropped_nonzero = True
            i += 1
        frac_end = i

    # Exponent part, saturated at `exp_cap` (module header, step 2).
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
        var exp_cap = (end - start) + 1000
        while i < end and _is_digit(bytes[i]):
            if exp_value < exp_cap:
                exp_value = exp_value * 10 + (Int(bytes[i]) - 0x30)
            i += 1
        if exp_neg:
            exp_value = -exp_value

    # Any trailing garbage?
    if i < end:
        raise Error("parse_float_f64: trailing non-numeric content at position " + String(i))

    # w == 0: every digit was zero; the result is a zero of the sign.
    var result = decimal_to_f64(w, q + exp_value)
    if dropped_nonzero:
        var above = decimal_to_f64(w + UInt64(1), q + exp_value)
        if above != result:
            result = round_long_decimal(
                bytes, int_start, int_end, frac_start, frac_end, exp_value, result
            )
    if negative:
        result = -result
    return result

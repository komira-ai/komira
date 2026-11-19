# =============================================================================
# float64_parse.mojo — a decimal number, correctly rounded to float64.
# =============================================================================
#
# `parse_decimal_f64` reads a JSON number of any length and returns the
# nearest double (round to nearest, ties to even). It is the float64
# counterpart of `parse_decimal_f32` (`float32_parse.mojo`) and uses the
# same method, with float64's widths:
#
# Fast path (Clinger). When the significant digits D fit in 15 decimal
# digits and x = D * 10^Q with |Q| <= 22, D and 10^|Q| are exact doubles,
# so one IEEE multiply or divide rounds x correctly.
#
# Exact path. With x in [10^(lead-1), 10^lead) and lead in [-323, 309]
# (outside that range x is below 2^-1075, so a zero, or at least 10^309,
# so past the double range), pick a binary exponent b at or below the one
# that puts x's leading bit at 2^(b+53), and compute q = floor(x / 2^b) and
# whether the remainder is zero, exactly: q = floor(num / den) by restoring
# division on big integers, with num and den the integers
# D * 10^max(Q,0) * 2^max(-b,0) and 10^max(-Q,0) * 2^max(b,0). Shifting q
# right until it has 54 bits (the shifted-out bits join the remainder) gives
# the 53-bit mantissa, the round bit and the sticky bit, from which
# round-to-nearest-even is exact. b is never below -1075, so a value below
# the normal range keeps the subnormal grid of 2^-1074.
#
# The exponent part is read exactly up to a cap of the text's length plus
# 400, past which any value is out of range or a zero whatever the digits
# (see `parse_decimal_f64`), so there is no length limit on the digits or
# the exponent, and the time is linear in the text's length (no loop runs
# once per unit of the exponent).
#
# Digits past the 800th significant one are dropped and remembered as a
# nonzero tail (trailing zeros are stripped first, so a dropped tail is
# never zero). That decides every comparison exactly: x is within a factor
# of two of the double grid points it is compared with, and every double
# midpoint, an odd multiple of 2^e with e >= -1075 and fewer than 2^55 times
# that, has at most 768 significant decimal digits, so the 800-digit prefix
# is above, below or equal to the midpoint exactly when x is, with "equal
# and a nonzero tail" meaning above.
#
# Size bound: num and den stay under 2^3800 (D < 10^800, 10^1123 for the
# smallest lead with 800 digits, a shift of at most 1075, and 63 more for
# the division), so 128 limbs (4096 bits) hold them.
#
# Out of range: a value that rounds past the largest double, i.e.
# |x| >= 2^1024 - 2^970 (the midpoint between max and 2^1024, which ties to
# the even 2^1024), is REFUSED, never read as an infinity. protobuf's JSON
# parsers refuse it too: the C++ lexer (`JsonLexer::ParseNumber`) rejects a
# number whose `SimpleAtod` result is not finite, Java's `JsonFormat`
# throws "Out of range double value", and the conformance suite requires
# `{"optionalDouble": 1.89769e+308}` to fail (DoubleFieldTooLarge).
# =============================================================================

from std.memory import bitcast

from .float32_bignum import (
    big_add_small,
    big_cmp,
    big_from,
    big_is_zero,
    big_mul_pow10,
    big_mul_small,
    big_shl,
    big_shr1,
    big_sub,
)

comptime _PN = 128
comptime _MAX_DIGITS = 800


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("0")) and c <= UInt8(ord("9"))


def _pow10_f64(k: Int) -> Float64:
    """10^k for 0 <= k <= 22, exact (every product below is exact)."""
    var p = Float64(1.0)
    for _ in range(k):
        p *= Float64(10.0)
    return p


def parse_decimal_f64(text: String) raises -> Float64:
    """The double nearest to the decimal `text` (ties to even), for text of
    the form `-?D+(.D+)?([eE][+-]?D+)?` (leading zeros allowed). Raises
    `not a proto3 double` for any other text and `value out of double range`
    when the value rounds past the largest double
    (|x| >= 2^1024 - 2^970). A value that rounds below the smallest
    subnormal is a zero of the same sign."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    var neg = False
    if i < n and b[i] == UInt8(ord("-")):
        neg = True
        i += 1
    var digits = List[UInt8](capacity=min(n, _MAX_DIGITS))
    var q = 0  # x = D * 10^q before the exponent part
    var tail = False  # a nonzero digit was dropped past the 800th
    var int_count = 0
    while i < n and _is_digit(b[i]):
        var d = b[i] - UInt8(ord("0"))
        if len(digits) == 0 and d == UInt8(0):
            pass  # a leading zero
        elif len(digits) < _MAX_DIGITS:
            digits.append(d)
        else:
            q += 1
            if d != UInt8(0):
                tail = True
        int_count += 1
        i += 1
    if int_count == 0:
        raise Error("JsonError: not a proto3 double: " + text)
    if i < n and b[i] == UInt8(ord(".")):
        i += 1
        var frac_count = 0
        while i < n and _is_digit(b[i]):
            var d = b[i] - UInt8(ord("0"))
            if len(digits) == 0 and d == UInt8(0):
                q -= 1
            elif len(digits) < _MAX_DIGITS:
                digits.append(d)
                q -= 1
            elif d != UInt8(0):
                tail = True
            frac_count += 1
            i += 1
        if frac_count == 0:
            raise Error("JsonError: not a proto3 double: " + text)
    var exp = 0
    if i < n and (b[i] == UInt8(ord("e")) or b[i] == UInt8(ord("E"))):
        i += 1
        var exp_neg = False
        if i < n and (b[i] == UInt8(ord("+")) or b[i] == UInt8(ord("-"))):
            exp_neg = b[i] == UInt8(ord("-"))
            i += 1
        # Saturate the exponent at n + 400 (n = the text's byte length).
        # |q| and the digit count are each at most n, so an exponent that
        # big puts lead = nd + q + exp beyond +-400, out of [-323, 309] in
        # the same direction as the true exponent: the result (out of
        # range, or a signed zero) is the one the exact exponent gives.
        # Below the cap the exponent is exact, and it cannot overflow an
        # Int.
        var exp_cap = n + 400
        var exp_count = 0
        while i < n and _is_digit(b[i]):
            if exp < exp_cap:
                exp = exp * 10 + Int(b[i] - UInt8(ord("0")))
            exp_count += 1
            i += 1
        if exp_count == 0:
            raise Error("JsonError: not a proto3 double: " + text)
        if exp_neg:
            exp = -exp
    if i != n:
        raise Error("JsonError: not a proto3 double: " + text)
    while len(digits) > 0 and digits[len(digits) - 1] == UInt8(0):
        _ = digits.pop()
        q += 1
    var nd = len(digits)
    var sign = UInt64(1) << UInt64(63) if neg else UInt64(0)
    if nd == 0:
        return bitcast[DType.float64](sign)
    var big_q = q + exp
    var lead = nd + big_q  # x in [10^(lead-1), 10^lead)
    if lead > 309:
        raise Error("JsonError: value out of double range: " + text)
    if lead < -323:
        return bitcast[DType.float64](sign)  # x < 10^-324 < 2^-1075
    if not tail and nd <= 15 and big_q >= -22 and big_q <= 22:
        var dv = UInt64(0)
        for k in range(nd):
            dv = dv * UInt64(10) + UInt64(digits[k])
        var r = Float64(dv)  # exact: dv < 10^15 < 2^53
        if big_q >= 0:
            r = r * _pow10_f64(big_q)
        else:
            r = r / _pow10_f64(-big_q)
        return -r if neg else r
    var num = big_from[_PN](UInt64(0))
    var k = 0
    while k < nd:
        # Nine digits at a time: num = num * 10^c + chunk.
        var chunk = UInt32(0)
        var mult = UInt32(1)
        var c = 0
        while c < 9 and k < nd:
            chunk = chunk * UInt32(10) + UInt32(digits[k])
            mult *= UInt32(10)
            c += 1
            k += 1
        big_mul_small(num, mult)
        big_add_small(num, chunk)
    var den = big_from[_PN](UInt64(1))
    if big_q >= 0:
        big_mul_pow10(num, big_q)
    else:
        big_mul_pow10(den, -big_q)
    # A lower bound on floor(log2 x): x >= 10^(lead-1), and
    # 3.321928 < log2(10); the -2 covers the rounding of `//`.
    var log2_low = ((lead - 1) * 3321928) // 1000000 - 2
    var e_f = max(-1074, log2_low - 52)  # the mantissa's unit, 2^e_f
    var bexp = e_f - 1  # q's unit: one bit below the mantissa
    if bexp >= 0:
        big_shl(den, bexp)
    else:
        big_shl(num, -bexp)
    # q = floor(num / den) < 2^61 (log2_low is at most 7 below
    # floor(log2 x), so q has at most 54 + 7 bits), by restoring division
    # over 64 bits.
    var t = den.copy()
    big_shl(t, 63)
    var qv = UInt64(0)
    for bit in reversed(range(64)):
        if big_cmp(num, t) >= 0:
            big_sub(num, t)
            qv |= UInt64(1) << UInt64(bit)
        big_shr1(t)
    var sticky = tail or not big_is_zero(num)
    while qv >= (UInt64(1) << UInt64(54)):
        if (qv & UInt64(1)) != UInt64(0):
            sticky = True
        qv >>= UInt64(1)
        e_f += 1
    var mant = qv >> UInt64(1)
    var half = (qv & UInt64(1)) != UInt64(0)
    if half and (sticky or (mant & UInt64(1)) != UInt64(0)):
        mant += UInt64(1)
    if mant == (UInt64(1) << UInt64(53)):
        mant = UInt64(1) << UInt64(52)
        e_f += 1
    var bits: UInt64
    if mant >= (UInt64(1) << UInt64(52)):
        var field = e_f + 1075
        if field >= 2047:
            raise Error("JsonError: value out of double range: " + text)
        bits = (UInt64(field) << UInt64(52)) | (
            mant & ((UInt64(1) << UInt64(52)) - UInt64(1))
        )
    else:
        bits = mant  # subnormal or zero: e_f is -1074
    return bitcast[DType.float64](bits | sign)

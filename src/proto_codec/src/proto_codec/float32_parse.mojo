# =============================================================================
# float32_parse.mojo — a decimal number, correctly rounded to float32.
# =============================================================================
#
# `parse_decimal_f32` rounds the decimal STRAIGHT to float32 (round to
# nearest, ties to even), in exact integer arithmetic. It does not go
# through a Float64: rounding to float64 first can land exactly on a float32
# midpoint the decimal was not on, and the second rounding then breaks that
# tie the wrong way (1.0000000596046448 is above the midpoint 1 + 2^-24 but
# parses to it as a float64, which narrows to 1.0, not 0x3F800001).
#
# The method. x = D * 10^Q with D the significant digits. With x in
# [10^(lead-1), 10^lead) and lead in [-45, 39] (outside that range x is
# below 2^-150, so zero, or at least 10^39, so past float32 max), pick a
# binary exponent b at or below the one that puts x's leading bit at
# 2^(b+24), and compute q = floor(x / 2^b) and whether the remainder is zero,
# exactly: q = floor(num / den) by restoring division on big integers, with
# num and den the integers D * 10^max(Q,0) * 2^max(-b,0) and
# 10^max(-Q,0) * 2^max(b,0). Shifting q right until it has 25 bits (the
# shifted-out bits join the remainder) gives the 24-bit mantissa, the round
# bit and the sticky bit, from which round-to-nearest-even is exact. b is
# never below -150, so a value below the normal range keeps the subnormal
# grid of 2^-149.
#
# The exponent part is read exactly up to a cap of the text's length plus
# 100, past which any value is out of range or a zero whatever the digits
# (see `parse_decimal_f32`), so there is no length limit on the digits or
# the exponent.
#
# Digits past the 120th significant one are dropped and remembered as a
# nonzero tail (trailing zeros are stripped first, so a dropped tail is
# never zero). That decides every comparison exactly: x is within a factor
# of two of the float32 grid points it is compared with, and every float32
# midpoint, an odd multiple of 2^e with e >= -150 and fewer than 2^26 times
# that, has at most 113 significant decimal digits, so the 120-digit prefix
# is above, below or equal to the midpoint exactly when x is, with "equal
# and a nonzero tail" meaning above.
#
# Size bound: num and den stay under 2^600 (D < 10^120, 10^165 for the
# smallest lead, a shift of at most 157, and 35 more for the division), so
# 24 limbs (768 bits) hold them.
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

comptime _PN = 24
comptime _MAX_DIGITS = 120


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("0")) and c <= UInt8(ord("9"))


def parse_decimal_f32(text: String) raises -> Float32:
    """The float32 nearest to the decimal `text` (ties to even), for text of
    the form `-?D+(.D+)?([eE][+-]?D+)?` (leading zeros allowed). Raises
    `not a proto3 float` for any other text and `value out of float32 range`
    when the value rounds past float32 max (|x| >= 2^128 - 2^103). A value
    that rounds below the smallest subnormal is a zero of the same sign."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    var neg = False
    if i < n and b[i] == UInt8(ord("-")):
        neg = True
        i += 1
    var digits = InlineArray[UInt8, _MAX_DIGITS](fill=UInt8(0))
    var nd = 0
    var q = 0  # x = D * 10^q before the exponent part
    var tail = False  # a nonzero digit was dropped past the 120th
    var int_count = 0
    while i < n and _is_digit(b[i]):
        var d = b[i] - UInt8(ord("0"))
        if nd == 0 and d == UInt8(0):
            pass  # a leading zero
        elif nd < _MAX_DIGITS:
            digits[nd] = d
            nd += 1
        else:
            q += 1
            if d != UInt8(0):
                tail = True
        int_count += 1
        i += 1
    if int_count == 0:
        raise Error("JsonError: not a proto3 float: " + text)
    if i < n and b[i] == UInt8(ord(".")):
        i += 1
        var frac_count = 0
        while i < n and _is_digit(b[i]):
            var d = b[i] - UInt8(ord("0"))
            if nd == 0 and d == UInt8(0):
                q -= 1
            elif nd < _MAX_DIGITS:
                digits[nd] = d
                nd += 1
                q -= 1
            elif d != UInt8(0):
                tail = True
            frac_count += 1
            i += 1
        if frac_count == 0:
            raise Error("JsonError: not a proto3 float: " + text)
    var exp = 0
    if i < n and (b[i] == UInt8(ord("e")) or b[i] == UInt8(ord("E"))):
        i += 1
        var exp_neg = False
        if i < n and (b[i] == UInt8(ord("+")) or b[i] == UInt8(ord("-"))):
            exp_neg = b[i] == UInt8(ord("-"))
            i += 1
        # Saturate the exponent at n + 100 (n = the text's byte length).
        # |q| and nd are each at most n, so an exponent that big puts
        # lead = nd + q + exp beyond +-100, out of [-45, 39] in the same
        # direction as the true exponent: the result (out of range, or a
        # signed zero) is the one the exact exponent gives. Below the cap
        # the exponent is exact, and it cannot overflow an Int.
        var exp_cap = n + 100
        var exp_count = 0
        while i < n and _is_digit(b[i]):
            if exp < exp_cap:
                exp = exp * 10 + Int(b[i] - UInt8(ord("0")))
            exp_count += 1
            i += 1
        if exp_count == 0:
            raise Error("JsonError: not a proto3 float: " + text)
        if exp_neg:
            exp = -exp
    if i != n:
        raise Error("JsonError: not a proto3 float: " + text)
    while nd > 0 and digits[nd - 1] == UInt8(0):
        nd -= 1
        q += 1
    var sign = UInt32(0x80000000) if neg else UInt32(0)
    if nd == 0:
        return bitcast[DType.float32](sign)
    var big_q = q + exp
    var lead = nd + big_q  # x in [10^(lead-1), 10^lead)
    if lead > 39:
        raise Error("JsonError: value out of float32 range: " + text)
    if lead < -45:
        return bitcast[DType.float32](sign)  # x < 10^-46 < 2^-150
    var num = big_from[_PN](UInt64(0))
    for k in range(nd):
        big_mul_small(num, UInt32(10))
        big_add_small(num, UInt32(digits[k]))
    var den = big_from[_PN](UInt64(1))
    if big_q >= 0:
        big_mul_pow10(num, big_q)
    else:
        big_mul_pow10(den, -big_q)
    # A lower bound on floor(log2 x): x >= 10^(lead-1), and
    # 3.321928 < log2(10); the -2 covers the rounding of `//`.
    var log2_low = ((lead - 1) * 3321928) // 1000000 - 2
    var e_f = max(-149, log2_low - 23)  # the mantissa's unit, 2^e_f
    var bexp = e_f - 1  # q's unit: one bit below the mantissa
    if bexp >= 0:
        big_shl(den, bexp)
    else:
        big_shl(num, -bexp)
    # q = floor(num / den) < 2^32 (log2_low is at most 7 below
    # floor(log2 x), so q has at most 25 + 7 bits), by restoring division
    # over 36 bits.
    var t = den.copy()
    big_shl(t, 35)
    var qv = UInt64(0)
    for bit in reversed(range(36)):
        if big_cmp(num, t) >= 0:
            big_sub(num, t)
            qv |= UInt64(1) << UInt64(bit)
        big_shr1(t)
    var sticky = tail or not big_is_zero(num)
    while qv >= (UInt64(1) << UInt64(25)):
        if (qv & UInt64(1)) != UInt64(0):
            sticky = True
        qv >>= UInt64(1)
        e_f += 1
    var mant = qv >> UInt64(1)
    var half = (qv & UInt64(1)) != UInt64(0)
    if half and (sticky or (mant & UInt64(1)) != UInt64(0)):
        mant += UInt64(1)
    if mant == (UInt64(1) << UInt64(24)):
        mant = UInt64(1) << UInt64(23)
        e_f += 1
    var bits: UInt32
    if mant >= (UInt64(1) << UInt64(23)):
        var field = e_f + 150
        if field >= 255:
            raise Error("JsonError: value out of float32 range: " + text)
        bits = (UInt32(field) << UInt32(23)) | UInt32(
            mant & UInt64(0x7FFFFF)
        )
    else:
        bits = UInt32(mant)  # subnormal or zero: e_f is -149
    return bitcast[DType.float32](bits | sign)

# =============================================================================
# DECIMAL128 CASTS — int<->decimal, float<->decimal, decimal rescale,
#                    decimal<->string.
# =============================================================================
#
# HALF_UP (round half away from
# zero) for float->decimal and decimal-rescale-down (matches arrow-rs +
# DuckDB + PostgreSQL).  Float->decimal on NaN/+-Inf and on overflow -> NULL
# (safe-cast semantics — there is no unsafe cast mode — matches DuckDB's
# TRY_CAST and arrow-rs's default safe cast).
#
# ⛔⛔ DECIMAL -> INTEGER IS **HALF_UP TOO**, NOT "TRUNCATE toward zero".
# MEASURED on DuckDB v1.5.3: `CAST(3.5000::DECIMAL(18,4) AS BIGINT)` is 4 and
# `CAST(-2.5000 ...)` is -3 — DuckDB rounds half AWAY FROM ZERO, as PostgreSQL
# does. A truncating `decimal_to_int64` would answer 3 / -2 with a success
# code; it rounds HALF_UP, through the same `rescale_i256_half_up` the
# rescale-down path uses.
# =============================================================================

from std.math import floor, ceil

from komira_scalar_arithmetic.decimal_arith import (
    I128,
    I256,
    pow10_i128,
    pow10_i256,
    overflows_dec128,
    max_dec128_i256,
    rescale_i256_half_up,
    DEC128_MAX_PRECISION,
)


@always_inline
def _digits_of_i128(v: I128) -> Int:
    """Number of decimal digits in |v| (0 -> 1)."""
    var av = v
    if av < I128(0):
        av = -av
    if av == I128(0):
        return 1
    var n = 0
    var ten = I128(10)
    while av > I128(0):
        av = av / ten
        n += 1
    return n


@always_inline
def _fits_precision(v: I128, precision: Int) -> Bool:
    """True if |v| has <= `precision` decimal digits and v fits Decimal128."""
    if precision < 1 or precision > DEC128_MAX_PRECISION:
        return False
    return _digits_of_i128(v) <= precision


# --- int -> decimal --------------------------------------------------------


@always_inline
def int_to_decimal_i128(int_val: Int64, precision: Int, scale: Int) raises -> I128:
    """Cast an Int64 to D(precision, scale): multiply by 10^scale, check fit.
    Raises if it doesn't fit the target precision."""
    var r256 = SIMD[DType.int128, 1](int_val).cast[DType.int256]() * pow10_i256(scale)
    if overflows_dec128(r256):
        raise Error("Decimal128 cast: integer " + String(int_val) + " overflows DECIMAL(" + String(precision) + "," + String(scale) + ")")
    var r = r256.cast[DType.int128]()
    if not _fits_precision(r, precision):
        raise Error("Decimal128 cast: integer " + String(int_val) + " does not fit DECIMAL(" + String(precision) + "," + String(scale) + ")")
    return r


# --- float64 -> decimal (returns Optional — None == NULL) ------------------


@always_inline
def float_to_decimal_i128(f: Float64, precision: Int, scale: Int) raises -> Optional[I128]:
    """Cast a Float64 to D(precision, scale), rounding HALF_UP.

    Returns None (NULL) for NaN / +-Inf / overflow (safe-cast semantics).
    """
    # NaN check (NaN != NaN).
    if f != f:
        return None
    # +-Inf check.
    if f > Float64(1.0e308) or f < Float64(-1.0e308):
        # 1e308 is the largest finite power-of-ten below DBL_MAX; anything
        # this big also overflows Decimal128 anyway.
        return None
    # Build 10^scale as a float (scale <= 38; 1e38 representable in f64).
    var pow_f = Float64(1.0)
    for _ in range(scale):
        pow_f *= 10.0
    var scaled = SIMD[DType.float64, 1](f) * SIMD[DType.float64, 1](pow_f)
    # HALF_UP: floor(x + 0.5) for x >= 0; ceil(x - 0.5) for x < 0.
    var rounded: SIMD[DType.float64, 1]
    if scaled >= SIMD[DType.float64, 1](0.0):
        rounded = floor(scaled + SIMD[DType.float64, 1](0.5))
    else:
        rounded = ceil(scaled - SIMD[DType.float64, 1](0.5))
    # Range guard before the cast — a magnitude beyond ~1.7e38 would
    # produce an undefined int128 cast.
    if rounded > SIMD[DType.float64, 1](1.7e38) or rounded < SIMD[DType.float64, 1](-1.7e38):
        return None
    var r = rounded.cast[DType.int128]()
    if overflows_dec128(r.cast[DType.int256]()):
        return None
    if not _fits_precision(r, precision):
        return None
    return Optional[I128](r)


# --- decimal -> float64 ----------------------------------------------------


@always_inline
def decimal_to_float64(v: I128, scale: Int) -> Float64:
    """Cast a D(_, scale) value to Float64 (lossy for >15 sig digits)."""
    var fv = v.cast[DType.float64]()
    var pow_f = Float64(1.0)
    for _ in range(scale):
        pow_f *= 10.0
    return Float64(fv) / pow_f


# --- decimal -> int64 (HALF_UP: round half away from zero) ----------------


@always_inline
def decimal_to_int64(v: I128, scale: Int) raises -> Int64:
    """Cast a D(_, scale) value to Int64, rounding HALF AWAY FROM ZERO —
    DuckDB v1.5.3's `CAST(<decimal> AS BIGINT / INTEGER)`, measured:
    3.5 -> 4, -2.5 -> -3, 3.99 -> 4, 7.49 -> 7. Raises if the ROUNDED value
    doesn't fit Int64.

    ⛔ A TRUNCATING cast (3.99 -> 3) is NOT DuckDB's rule: every
    `CAST(dec AS BIGINT)` over a fractional value would answer a wrong integer
    with a success code.

    ⭐ THE ROUNDING IS `rescale_i256_half_up` TO SCALE 0, NOT A SECOND COPY OF
    THE RULE: a decimal -> integer cast IS a rescale to scale 0 plus a width
    check. Done in I256 so the `2 * |remainder|` inside the rescale cannot
    overflow at scale 38."""
    var q = rescale_i256_half_up(v.cast[DType.int256](), scale, 0)
    # Int64 range: [-2^63, 2^63 - 1].
    var i64_max = I256(9223372036854775807)
    var i64_min = -i64_max - I256(1)
    if q > i64_max or q < i64_min:
        raise Error("Decimal128 cast to INTEGER: value out of Int64 range")
    return Int64(q.cast[DType.int64]())


# --- decimal -> decimal (rescale + precision re-check) ---------------------


@always_inline
def decimal_rescale_i128(v: I128, from_scale: Int, to_precision: Int, to_scale: Int) raises -> I128:
    """Rescale a D(_, from_scale) value to D(to_precision, to_scale),
    rounding HALF_UP when scaling down.  Raises if the result doesn't fit
    the target precision (covers both upscale-overflows-precision and
    downscale-still-doesn't-fit cases)."""
    var r256 = rescale_i256_half_up(v.cast[DType.int256](), from_scale, to_scale)
    if overflows_dec128(r256):
        raise Error("Decimal128 rescale: value overflows DECIMAL(" + String(to_precision) + "," + String(to_scale) + ")")
    var r = r256.cast[DType.int128]()
    if not _fits_precision(r, to_precision):
        raise Error("Decimal128 rescale: value has more than " + String(to_precision) + " digits — does not fit DECIMAL(" + String(to_precision) + "," + String(to_scale) + ")")
    return r


# --- decimal -> string -----------------------------------------------------


def decimal_to_string(v: I128, scale: Int) -> String:
    """Format a D(_, scale) value: insert the decimal point `scale` digits
    from the right, left-pad with '0.' for pure-fractional values, '-'
    prefix for negatives, no trailing-zero trimming, no point at scale 0.
    """
    var neg = v < I128(0)
    # The magnitude in int256: -I128.MIN wraps in int128 (it printed "-0").
    var av = v.cast[DType.int256]()
    if neg:
        av = -av
    # Extract decimal digits of the magnitude (least-significant first).
    var digits = List[UInt8]()
    var ten = I256(10)
    if av == I256(0):
        digits.append(UInt8(0))
    else:
        var tmp = av
        while tmp > I256(0):
            var d = tmp % ten
            digits.append(UInt8(Int(d)))
            tmp = tmp / ten
    # Ensure at least scale+1 digits so there's an integer part of >=1 digit.
    while len(digits) < scale + 1:
        digits.append(UInt8(0))
    # Build the string, most-significant first.
    var out = String("")
    if neg:
        out += "-"
    var n = len(digits)
    var int_len = n - scale
    var i = n - 1
    while i >= 0:
        var pos = n - 1 - i  # 0-based position from the left
        if scale > 0 and pos == int_len:
            out += "."
        out += chr(Int(digits[i]) + Int(ord("0")))
        i -= 1
    return out^


# --- string -> decimal -----------------------------------------------------


def _is_ascii_ws(c: UInt8) -> Bool:
    return c == UInt8(32) or c == UInt8(9) or c == UInt8(10) or c == UInt8(13) or c == UInt8(11) or c == UInt8(12)


def _parse_overflow(s: String, precision: Int, scale: Int) -> Error:
    return Error("Decimal128 parse: '" + s + "' overflows DECIMAL(" + String(precision) + "," + String(scale) + ")")


def string_to_decimal_i128(s: String, precision: Int, scale: Int) raises -> I128:
    """Parse a decimal literal (optionally with sign / fractional part /
    scientific exponent) into a D(precision, scale) value, rounding
    HALF_UP if the source has more fractional digits than `scale`.

    Trims surrounding ASCII whitespace.  Raises on garbage / empty /
    embedded whitespace / out-of-range.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    # Trim surrounding whitespace.
    var lo = 0
    while lo < n and _is_ascii_ws(bytes[lo]):
        lo += 1
    var hi = n
    while hi > lo and _is_ascii_ws(bytes[hi - 1]):
        hi -= 1
    if lo >= hi:
        raise Error("Decimal128 parse: empty or whitespace-only string")
    var i = lo
    var neg = False
    if bytes[i] == UInt8(ord("+")):
        i += 1
    elif bytes[i] == UInt8(ord("-")):
        neg = True
        i += 1
    # Mantissa: digits [. digits]. ⛔ At most 76 SIGNIFICANT digits are kept
    # (10^76 - 1 fits int256); a longer literal used to wrap the mantissa.
    # Past the cap an integer-part digit is a factor of ten (`dropped_int`)
    # and a fractional one is discarded: a Decimal128 result keeps at most 38
    # of the 76 kept digits, so the cut to the target scale lands inside them
    # and HALF_UP reads only the first digit it cuts.
    var mantissa = I256(0)
    var ten = I256(10)
    var frac_digits = 0
    var kept = 0
    var dropped_int = 0
    var seen_digit = False
    var seen_dot = False
    while i < hi:
        var c = bytes[i]
        if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
            if kept < 76:
                mantissa = mantissa * ten + I256(Int(c) - Int(ord("0")))
                if mantissa != I256(0):
                    kept += 1
                if seen_dot:
                    frac_digits += 1
            elif not seen_dot:
                dropped_int += 1
            seen_digit = True
            i += 1
        elif c == UInt8(ord(".")) and not seen_dot:
            seen_dot = True
            i += 1
        else:
            break
    if not seen_digit:
        raise Error("Decimal128 parse: no digits in '" + s + "'")
    # Optional exponent.
    var exp = 0
    if i < hi and (bytes[i] == UInt8(ord("e")) or bytes[i] == UInt8(ord("E"))):
        i += 1
        var eneg = False
        if i < hi and bytes[i] == UInt8(ord("+")):
            i += 1
        elif i < hi and bytes[i] == UInt8(ord("-")):
            eneg = True
            i += 1
        var edigits = 0
        while i < hi and bytes[i] >= UInt8(ord("0")) and bytes[i] <= UInt8(ord("9")):
            # Saturate: past 10^9 any nonzero value over- or underflows alike.
            if exp <= 100000000:
                exp = exp * 10 + (Int(bytes[i]) - Int(ord("0")))
            edigits += 1
            i += 1
        if edigits == 0:
            raise Error("Decimal128 parse: malformed exponent in '" + s + "'")
        if eneg:
            exp = -exp
    if i != hi:
        raise Error("Decimal128 parse: trailing garbage in '" + s + "'")
    # Source scale = frac_digits - exp (digits after the implied point).
    var src_scale = frac_digits - exp - dropped_int
    # Rescale mantissa from src_scale to target scale (HALF_UP on down).
    var r256: I256
    if mantissa == I256(0):
        # Zero at any exponent ("0e100") is zero.
        r256 = I256(0)
    elif src_scale <= scale:
        # Up: a nonzero mantissa times 10^39 or more is past 10^38 - 1; below
        # that, check before multiplying (a 76-digit mantissa would wrap).
        var up = scale - src_scale
        if up > DEC128_MAX_PRECISION or mantissa > max_dec128_i256() / pow10_i256(up):
            raise _parse_overflow(s, precision, scale)
        r256 = mantissa * pow10_i256(up)
    elif src_scale - scale > 76:
        # Down by more than 76 digits: |mantissa| < 10^76 is below one half
        # of a unit at the target scale, so it rounds to zero ("1e-100").
        r256 = I256(0)
    else:
        r256 = rescale_i256_half_up(mantissa, src_scale, scale)
    if overflows_dec128(r256):
        raise _parse_overflow(s, precision, scale)
    var r = r256.cast[DType.int128]()
    if neg:
        r = -r
    if not _fits_precision(r, precision):
        raise Error("Decimal128 parse: '" + s + "' has more than " + String(precision) + " digits — does not fit DECIMAL(" + String(precision) + "," + String(scale) + ")")
    return r

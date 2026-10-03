# =============================================================================
# DECIMAL256 ARITHMETIC — scalar i256 add / sub / mul / div with scale
#                          tracking, overflow-checked by default.
# =============================================================================
#
# Mirrors `decimal_arith.mojo` (Decimal128) at 256-bit width.  Mojo has
# native SIMD[DType.int256, 1].
# Decimal256 max precision is 76; an i512 intermediate would be needed for
# overflow-safe multiplication of two 76-digit operands, but Mojo
# does NOT expose SIMD[DType.int512, 1].  We use a **range-check predicate**
# instead: any multiplication whose operand magnitudes would produce a
# product exceeding 10^76 - 1 is detected by checking the operand magnitudes
# against 10^(76-other_p) BEFORE multiplying.  This guards the common case
# (operands well within range) without an i512 intermediate.
#
# Result precision/scale rules — follow the Decimal128 spec extended to
# Decimal256's 76-digit bound:
#   add/sub: result_scale     = max(s1, s2)
#            result_precision = min(max(p1-s1, p2-s2) + result_scale + 1, 76)
#   mul:     result_scale     = s1 + s2  (clamped to 76)
#            result_precision = min(p1 + p2 + 1, 76)
#   div:     result_scale     = min(s1 + 4, 76)         (Hive convention)
#            mul_pow          = result_scale - s1 + s2  (>= 0 always)
#            result_precision = min(mul_pow + p1, 76)
#            Numerator scaled UP by 10^mul_pow, divided, then ROUNDED
#            HALF_UP (round half away from zero).  Matches Decimal128.
#
# Overflow: every op that would produce a value outside +/-(10^76 - 1)
# raises Error("Decimal256 overflow ...").  No unchecked mode.
# =============================================================================


# Convenience alias (value type — no pointers).
comptime I256 = SIMD[DType.int256, 1]

comptime DEC256_MAX_PRECISION: Int = 76
comptime DEC256_MAX_SCALE: Int = 76


# --- pow10 table for i256 --------------------------------------------------
#
# 10^0 .. 10^76 fits in i256 (10^76 < 2^255).


@always_inline
def pow10_i256_d(n: Int) raises -> I256:
    """10^n as a native int256.  Requires 0 <= n <= 76 (else raises).

    Distinct from `decimal_arith.pow10_i256` (which bounds at 76 for
    Decimal128 mul/div intermediate); functionally identical.  Local
    copy avoids an import dependency on the Decimal128 module.
    """
    if n < 0 or n > DEC256_MAX_PRECISION:
        raise Error(
            "pow10_i256_d: exponent " + String(n) + " out of range [0, 76]"
        )
    var r = I256(1)
    var ten = I256(10)
    for _ in range(n):
        r = r * ten
    return r


@always_inline
def max_dec256_i256() raises -> I256:
    """10^76 - 1 as an int256 (the maximum-magnitude Decimal256 value)."""
    return pow10_i256_d(DEC256_MAX_PRECISION) - I256(1)


@always_inline
def i256_abs(v: I256) -> I256:
    if v < I256(0):
        return -v
    return v


@always_inline
def i256_sign(v: I256) -> I256:
    if v > I256(0):
        return I256(1)
    if v < I256(0):
        return I256(-1)
    return I256(0)


@always_inline
def overflows_dec256_inline(v: I256) raises -> Bool:
    """True if |v| exceeds 10^76 - 1 (the Decimal256 range)."""
    var m = max_dec256_i256()
    return i256_abs(v) > m


@always_inline
def rescale_i256_half_up(v: I256, from_scale: Int, to_scale: Int) raises -> I256:
    """Rescale `v` (an unscaled integer at `from_scale`) to `to_scale`,
    rounding HALF_UP (round half away from zero) when scaling down.
    Used by mul (precision clamp), div, and decimal->decimal cast.
    """
    if to_scale == from_scale:
        return v
    if to_scale > from_scale:
        return v * pow10_i256_d(to_scale - from_scale)
    # scale down: divide + round half away from zero.
    var div = pow10_i256_d(from_scale - to_scale)
    var q = v / div
    # ⛔ `v - q * div`, NOT `v % div`: Mojo's integer `/` truncates and its `%`
    # is FLOORED, so the `%` remainder would round every NEGATIVE NON-tie the
    # wrong way (-3.99 -> -3). Same rule as `decimal_arith.rescale_i256_half_up`.
    var rem = v - q * div
    var two_abs_rem = i256_abs(rem) * I256(2)
    if two_abs_rem >= div:
        q = q + i256_sign(v)
    return q


# --- result-type computation -----------------------------------------------


@always_inline
def decimal256_add_result_ps(
    p1: Int, s1: Int, p2: Int, s2: Int
) -> Tuple[Int, Int]:
    """(precision, scale) of D256(p1,s1) +/- D256(p2,s2)."""
    var s = max(s1, s2)
    var int_digits = max(p1 - s1, p2 - s2)
    var p = min(int_digits + s + 1, DEC256_MAX_PRECISION)
    return (p, s)


@always_inline
def decimal256_mul_result_ps(
    p1: Int, s1: Int, p2: Int, s2: Int
) raises -> Tuple[Int, Int]:
    """(precision, scale) of D256(p1,s1) * D256(p2,s2)."""
    var raw_s = s1 + s2
    if raw_s > DEC256_MAX_SCALE:
        raise Error(
            "Decimal256 mul: result scale "
            + String(raw_s)
            + " exceeds 76 — cast an operand to a smaller scale or to DOUBLE"
        )
    var p = min(p1 + p2 + 1, DEC256_MAX_PRECISION)
    return (p, raw_s)


@always_inline
def decimal256_div_result_ps(
    p1: Int, s1: Int, p2: Int, s2: Int
) -> Tuple[Int, Int]:
    """(precision, scale) of D256(p1,s1) / D256(p2,s2)."""
    var s = min(s1 + 4, DEC256_MAX_SCALE)
    var mul_pow = s - s1 + s2
    var p = min(mul_pow + p1, DEC256_MAX_PRECISION)
    return (p, s)


# --- the four scalar ops ---------------------------------------------------
#
# No i512 intermediate is available in Mojo.  For ADD/SUB the
# intermediate at scale max(s1,s2) is bounded by ~2 * 10^76 which can
# overflow i256 (the bound is 10^76 - 1, but the rescaled operand bounds
# are tighter — see overflows_dec256_inline check after the op).
#
# For MUL the raw product can be up to ~10^(p1+p2) which is < 10^152;
# this WILL overflow i256 if p1+p2 > 76.  We pre-check operand magnitudes
# against 10^(76-p1) bound to detect overflow before it happens.


@always_inline
def decimal256_add_i256(
    a: I256, s1: Int, b: I256, s2: Int, out_scale: Int
) raises -> I256:
    """Add `a` (at scale s1) + `b` (at scale s2), result at scale out_scale.

    Raises on Decimal256 overflow."""
    var a_rescaled = a * pow10_i256_d(out_scale - s1)
    var b_rescaled = b * pow10_i256_d(out_scale - s2)
    var r = a_rescaled + b_rescaled
    if overflows_dec256_inline(r):
        raise Error(
            "Decimal256 overflow in add: result exceeds DECIMAL256(76,...) range"
        )
    return r


@always_inline
def decimal256_sub_i256(
    a: I256, s1: Int, b: I256, s2: Int, out_scale: Int
) raises -> I256:
    """Subtract `a` (at scale s1) - `b` (at scale s2), result at scale out_scale.

    Raises on Decimal256 overflow."""
    var a_rescaled = a * pow10_i256_d(out_scale - s1)
    var b_rescaled = b * pow10_i256_d(out_scale - s2)
    var r = a_rescaled - b_rescaled
    if overflows_dec256_inline(r):
        raise Error(
            "Decimal256 overflow in sub: result exceeds DECIMAL256(76,...) range"
        )
    return r


@always_inline
def decimal256_mul_i256(a: I256, b: I256) raises -> I256:
    """Multiply `a` * `b` — the raw product (scale = s1 + s2, kept as-is).

    Pre-checks operand magnitudes to detect overflow before multiplication (no
    i512 intermediate available).  Raises on Decimal256 overflow."""
    # If a == 0 or b == 0, no overflow possible.
    if a == I256(0) or b == I256(0):
        return I256(0)
    # Overflow guard: |a*b| > MAX iff |a| > MAX/|b| (integer division).
    var max_v = max_dec256_i256()
    var abs_a = i256_abs(a)
    var abs_b = i256_abs(b)
    if abs_a > max_v / abs_b:
        raise Error(
            "Decimal256 overflow in mul: result exceeds DECIMAL256(76,...) range"
        )
    return a * b


@always_inline
def decimal256_div_i256(
    a: I256, s1: Int, b: I256, s2: Int, out_scale: Int
) raises -> I256:
    """Divide `a` (scale s1) / `b` (scale s2), result at out_scale = min(s1+4, 76).

    HALF_UP rounding (DuckDB / PostgreSQL convention; mirrors Decimal128).
    Raises on division-by-zero or Decimal256 overflow."""
    if b == I256(0):
        raise Error("Decimal256 division by zero")
    var mul_pow = out_scale - s1 + s2
    if mul_pow < 0:
        raise Error("Decimal256 div: negative rescale exponent (internal)")
    # Numerator scaled up — may overflow i256 if a is large + mul_pow large.
    # We can't form an i512 intermediate; guard via magnitude check.
    var abs_a = i256_abs(a)
    var pow10 = pow10_i256_d(mul_pow)
    var max_v = max_dec256_i256()
    if abs_a > max_v / pow10:
        raise Error(
            "Decimal256 overflow in div: scaled numerator exceeds DECIMAL256(76,...) range"
        )
    var num = a * pow10
    var den = b
    var q = num / den
    # ⛔ truncated remainder, not Mojo's FLOORED `%` — see the rescale above.
    var rem = num - q * den
    var two_abs_rem = i256_abs(rem) * I256(2)
    if two_abs_rem >= i256_abs(den):
        var qsign = i256_sign(num) * i256_sign(den)
        q = q + qsign
    if overflows_dec256_inline(q):
        raise Error(
            "Decimal256 overflow in div: result exceeds DECIMAL256(76,...) range"
        )
    return q

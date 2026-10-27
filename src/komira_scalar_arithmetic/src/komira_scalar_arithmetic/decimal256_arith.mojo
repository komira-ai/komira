# =============================================================================
# DECIMAL256 ARITHMETIC — scalar i256 add / sub / mul / div with scale
#                          tracking, overflow-checked by default.
# =============================================================================
#
# Mirrors `decimal_arith.mojo` (Decimal128) at 256-bit width.  Mojo has
# native SIMD[DType.int256, 1].
# Decimal256 max precision is 76; an i512 intermediate would be needed for
# overflow-safe multiplication of two 76-digit operands, but Mojo
# does NOT expose SIMD[DType.int512, 1].  No op here forms a value that can
# leave int256 instead (see "the four scalar ops" below): mul checks
# |a| > (10^76 - 1) / |b| on exact magnitudes BEFORE multiplying, add/sub
# range-check before rescaling, div produces its fractional digits one at a
# time.
#
# Result precision/scale rules — follow the Decimal128 spec extended to
# Decimal256's 76-digit bound:
#   add/sub: result_scale     = max(s1, s2)
#            result_precision = min(max(p1-s1, p2-s2) + result_scale + 1, 76)
#   mul:     result_scale     = s1 + s2  (raises above 76)
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


# Convenience aliases (value types — no pointers).
comptime I256 = SIMD[DType.int256, 1]
comptime U256 = SIMD[DType.uint256, 1]

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
    # ⛔ Both bounds, never `i256_abs(v)`: |-2^255| wraps back to -2^255.
    if v > m:
        return True
    return v < -m


@always_inline
def _mag_u256(v: I256) -> U256:
    """|v| as a uint256: exact for EVERY int256. `i256_abs` cannot be, since
    2^255 is not an int256 and `-(-2^255)` wraps back to -2^255."""
    if v == I256.MIN:
        return U256(1) << U256(255)
    return i256_abs(v).cast[DType.uint256]()


@always_inline
def rescale_i256_half_up(v: I256, from_scale: Int, to_scale: Int) raises -> I256:
    """Rescale `v` (an unscaled integer at `from_scale`) to `to_scale`,
    rounding HALF_UP (round half away from zero) when scaling down.
    Scaling up raises when the result leaves +/-(10^76 - 1). No op in this
    module calls it (Decimal128 code uses `decimal_arith.rescale_i256_half_up`).
    """
    if to_scale == from_scale:
        return v
    if to_scale > from_scale:
        var up = pow10_i256_d(to_scale - from_scale)
        # ⛔ Range-check BEFORE multiplying: 1.2*10^74 * 10^3 passes 2^255 and
        # wraps into a value that looks valid.
        var lim = max_dec256_i256() / up
        if v > lim or v < -lim:
            raise Error(
                "Decimal256 overflow in rescale: result exceeds DECIMAL256(76,...) range"
            )
        return v * up
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
# No i512 intermediate is available in Mojo, so no op forms a value that can
# leave int256:
#   ADD/SUB split the operand that is NOT rescaled by the rescale factor
#           10^k, so the result is (hi * 10^k + lo) with |lo| < 10^k, and hi is
#           range-checked before it is multiplied (`_add_sub_exact`).
#   MUL     checks |a| > MAX / |b| on exact uint256 magnitudes first.
#   DIV     never forms a * 10^mul_pow: it divides once, then produces the
#           mul_pow fractional digits one at a time (`_div_scaled_half_up`).


@always_inline
def _add_overflowed(x: I256, y: I256, r: I256) -> Bool:
    """`r` is the wrapped x + y: it wrapped iff x and y share a sign r lacks."""
    return ((x ^ r) & (y ^ r)) < I256(0)


@always_inline
def _sub_overflowed(x: I256, y: I256, r: I256) -> Bool:
    """`r` is the wrapped x - y: it wrapped iff x and y differ in sign and r's
    sign differs from x's."""
    return ((x ^ y) & (x ^ r)) < I256(0)


def _add_sub_overflow(subtract: Bool) -> Error:
    if subtract:
        return Error("Decimal256 overflow in sub: result exceeds DECIMAL256(76,...) range")
    return Error("Decimal256 overflow in add: result exceeds DECIMAL256(76,...) range")


def _add_sub_exact(
    a: I256, s1: Int, b: I256, s2: Int, out_scale: Int, subtract: Bool
) raises -> I256:
    """a (scale s1) +/- b (scale s2) at out_scale, EXACT, raising when the
    result leaves +/-(10^76 - 1). Neither operand is rescaled in place: the
    one at the smaller scale would need 10^k and can pass 2^255 (1.2*10^74 at
    scale 3 is 1.2*10^77, past int256), wrapping into a value that then passes
    the range check."""
    # Both exponents in [0, 76], as the rescaled form requires.
    _ = pow10_i256_d(out_scale - s1)
    _ = pow10_i256_d(out_scale - s2)
    var s = max(s1, s2)
    var pk = pow10_i256_d(s - min(s1, s2))
    # Step 1, at scale s: result = hi * pk + lo, |lo| < pk.
    var hi: I256
    var lo: I256
    var wrapped: Bool
    if s1 < s2:
        # a * pk +/- b = (a +/- q) * pk +/- rem, q = trunc(b / pk).
        var q = b / pk
        var rem = b - q * pk
        if subtract:
            hi = a - q
            wrapped = _sub_overflowed(a, q, hi)
            lo = -rem
        else:
            hi = a + q
            wrapped = _add_overflowed(a, q, hi)
            lo = rem
    else:
        # a +/- b * pk = (q +/- b) * pk + rem, q = trunc(a / pk).
        var q = a / pk
        lo = a - q * pk
        if subtract:
            hi = q - b
            wrapped = _sub_overflowed(q, b, hi)
        else:
            hi = q + b
            wrapped = _add_overflowed(q, b, hi)
    if wrapped:
        raise _add_sub_overflow(subtract)
    # |hi| >= MAX / pk + 2 puts |hi * pk + lo| past MAX; below that,
    # |hi * pk| <= MAX + pk < 2 * 10^76 fits int256.
    var lim = max_dec256_i256() / pk + I256(1)
    if hi > lim or hi < -lim:
        raise _add_sub_overflow(subtract)
    var r = hi * pk + lo
    if overflows_dec256_inline(r):
        raise _add_sub_overflow(subtract)
    # Step 2: up to out_scale (k = 0 under the add rule, out_scale = max(s1, s2)).
    var up = pow10_i256_d(out_scale - s)
    var up_lim = max_dec256_i256() / up
    if r > up_lim or r < -up_lim:
        raise _add_sub_overflow(subtract)
    return r * up


@always_inline
def decimal256_add_i256(
    a: I256, s1: Int, b: I256, s2: Int, out_scale: Int
) raises -> I256:
    """Add `a` (at scale s1) + `b` (at scale s2), result at scale out_scale.

    Raises on Decimal256 overflow."""
    return _add_sub_exact(a, s1, b, s2, out_scale, False)


@always_inline
def decimal256_sub_i256(
    a: I256, s1: Int, b: I256, s2: Int, out_scale: Int
) raises -> I256:
    """Subtract `a` (at scale s1) - `b` (at scale s2), result at scale out_scale.

    Raises on Decimal256 overflow."""
    return _add_sub_exact(a, s1, b, s2, out_scale, True)


@always_inline
def decimal256_mul_i256(a: I256, b: I256) raises -> I256:
    """Multiply `a` * `b` — the raw product (scale = s1 + s2, kept as-is).

    Pre-checks operand magnitudes to detect overflow before multiplication (no
    i512 intermediate available).  Raises on Decimal256 overflow."""
    # If a == 0 or b == 0, no overflow possible.
    if a == I256(0) or b == I256(0):
        return I256(0)
    # Overflow guard: |a*b| > MAX iff |a| > MAX/|b| (integer division), on
    # exact uint256 magnitudes (an `i256_abs` of -2^255 wraps and passes).
    var max_u = max_dec256_i256().cast[DType.uint256]()
    if _mag_u256(a) > max_u / _mag_u256(b):
        raise Error(
            "Decimal256 overflow in mul: result exceeds DECIMAL256(76,...) range"
        )
    return a * b


@always_inline
def _double_mod(x: U256, d: U256) -> Tuple[U256, U256]:
    """(c, y) with 2x = c*d + y, 0 <= y < d, for x < d <= 2^255 (so 2x fits)."""
    var y = x + x
    if y >= d:
        return (U256(1), y - d)
    return (U256(0), y)


def _div_scaled_half_up(a: I256, mul_pow: Int, b: I256) raises -> I256:
    """a * 10^mul_pow / b rounded half away from zero, EXACT for every int256
    a and nonzero b, raising when the result leaves +/-(10^76 - 1).

    Long division on uint256 magnitudes: the integer quotient first, then one
    fractional digit per step. A step needs floor(10r / d) with r < d, and 10r
    passes 2^256 once d > 2^256 / 10, so 10r is taken as 8r + 2r through three
    modular doublings, each of which fits (2r < 2d <= 2^256)."""
    var msg = "Decimal256 overflow in div: result exceeds DECIMAL256(76,...) range"
    var n = _mag_u256(a)
    var d = _mag_u256(b)
    var max_u = max_dec256_i256().cast[DType.uint256]()
    var q = n / d
    var r = n - q * d
    if q > max_u:
        raise Error(msg)
    var q_lim = max_u / U256(10)
    for _ in range(mul_pow):
        var t2 = _double_mod(r, d)
        var t4 = _double_mod(t2[1], d)
        var t8 = _double_mod(t4[1], d)
        # 10r = (5*c2 + 2*c4 + c8) * d + (r8 + r2), and r8 + r2 < 2d.
        var digit = U256(5) * t2[0] + U256(2) * t4[0] + t8[0]
        var rest = t8[1] + t2[1]
        if rest >= d:
            rest = rest - d
            digit = digit + U256(1)
        r = rest
        # q <= floor(MAX / 10) keeps q * 10 + digit <= MAX (MAX ends in 9).
        if q > q_lim:
            raise Error(msg)
        q = q * U256(10) + digit
    # HALF_UP: 2r >= d rounds the magnitude up (2r < 2d <= 2^256 fits).
    if r + r >= d:
        q = q + U256(1)
        if q > max_u:
            raise Error(msg)
    var out = q.cast[DType.int256]()
    if (a < I256(0)) != (b < I256(0)):
        return -out
    return out


@always_inline
def decimal256_div_i256(
    a: I256, s1: Int, b: I256, s2: Int, out_scale: Int
) raises -> I256:
    """Divide `a` (scale s1) / `b` (scale s2), result at out_scale = min(s1+4, 76).

    HALF_UP rounding (DuckDB / PostgreSQL convention; mirrors Decimal128).
    Exact for every operand: the scaled numerator a * 10^mul_pow is never
    formed (`_div_scaled_half_up`), so MAX / MAX at scale 4 answers 1.0000.
    Raises on division-by-zero or Decimal256 overflow."""
    if b == I256(0):
        raise Error("Decimal256 division by zero")
    var mul_pow = out_scale - s1 + s2
    if mul_pow < 0:
        raise Error("Decimal256 div: negative rescale exponent (internal)")
    return _div_scaled_half_up(a, mul_pow, b)

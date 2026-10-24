# =============================================================================
# DECIMAL128 ARITHMETIC — scalar i128/i256 add / sub / mul / div with scale
#                          tracking, overflow-checked by default.
# =============================================================================
#
# Mojo has native SIMD[DType.int128, 1] and SIMD[DType.int256, 1] —
# i128 mul/div/cmp are native scalar arithmetic; the mul/div rescale step
# uses an i256 intermediate so no mid-operation overflow detection is
# needed.  There is NO 128-bit-lane SIMD multiply on x86/ARM (Arrow knows
# this — its decimal kernels are scalar i128 per-element loops too), so
# these are scalar per-row loops over int128 values.  Perf is explicitly
# NOT the goal here; correctness is.
#
# Result precision/scale rules (the spec — conform to arrow-rs current
# `arrow-arith/src/numeric.rs` `decimal_op`, except `div` ROUNDING which is
# a DELIBERATE divergence — see `decimal_div_i128` below).  MAX_PRECISION =
# MAX_SCALE = 38 for Decimal128:
#   add/sub: result_scale     = max(s1, s2)
#            result_precision = min(max(p1-s1, p2-s2) + result_scale + 1, 38)
#   mul:     result_scale     = s1 + s2
#            result_precision = min(p1 + p2 + 1, 38)
#            A result_scale above 38 RAISES (DuckDB: "Needed scale N to
#            accurately represent the multiplication result, but this is
#            out of range"); see `decimal_mul_result_ps`.
#   div:     result_scale     = min(s1 + 4, 38)        (Hive convention)
#            mul_pow          = result_scale - s1 + s2  (>= 0 always under
#                                                        this rule)
#            result_precision = min(mul_pow + p1, 38)
#            Numerator scaled UP by 10^mul_pow, divided, then ROUNDED
#            HALF_UP (round half away from zero).  arrow-rs TRUNCATES toward
#            zero; we deliberately round (DuckDB/PostgreSQL behavior — what
#            SQL users expect).  Division-rounding test oracle = DuckDB.
#
# Overflow: every op that would produce a value outside +/-(10^38 - 1)
# raises Error("Decimal128 overflow ...").  No unchecked mode exposed.
# =============================================================================


# Convenience aliases (value types — no pointers).
comptime I128 = SIMD[DType.int128, 1]
comptime I256 = SIMD[DType.int256, 1]

comptime DEC128_MAX_PRECISION: Int = 38
comptime DEC128_MAX_SCALE: Int = 38


# --- pow10 tables ----------------------------------------------------------
#
# 10^0 .. 10^38 fits in i128 (10^38 < 2^127).  10^0 .. 10^76 fits in i256
# (10^76 < 2^255).  We build the tables iteratively at call time (the loops
# are small and only run on the cold decimal path); a comptime table would
# need int128/int256 InlineArray which is overkill here.


@always_inline
def pow10_i128(n: Int) raises -> I128:
    """10^n as a native int128.  Requires 0 <= n <= 38 (else raises)."""
    if n < 0 or n > DEC128_MAX_PRECISION:
        raise Error("pow10_i128: exponent " + String(n) + " out of range [0, 38]")
    var r = I128(1)
    var ten = I128(10)
    for _ in range(n):
        r = r * ten
    return r


@always_inline
def pow10_i256(n: Int) raises -> I256:
    """10^n as a native int256.  Requires 0 <= n <= 76 (else raises)."""
    if n < 0 or n > 76:
        raise Error("pow10_i256: exponent " + String(n) + " out of range [0, 76]")
    var r = I256(1)
    var ten = I256(10)
    for _ in range(n):
        r = r * ten
    return r


@always_inline
def max_dec128_i256() raises -> I256:
    """10^38 - 1 as an int256 (the maximum-magnitude Decimal128 value)."""
    return pow10_i256(DEC128_MAX_PRECISION) - I256(1)


@always_inline
def overflows_dec128(v: I256) -> Bool:
    """True if |v| exceeds 10^38 - 1 (the Decimal128 range)."""
    # 10^38 - 1 inline (avoid `raises` in this hot helper).
    var m = I256(10)
    for _ in range(37):
        m = m * I256(10)
    m = m - I256(1)
    # ⛔ Compare against both bounds, never `-v`: -(-2^255) wraps back to
    # -2^255, which an `|v| > m` test reads as in range.
    if v > m:
        return True
    return v < -m


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
def rescale_i256_half_up(v: I256, from_scale: Int, to_scale: Int) raises -> I256:
    """Rescale `v` (an unscaled integer at `from_scale`) to `to_scale`,
    rounding HALF_UP (round half away from zero) when scaling down.

    Used by mul (precision clamp), div, and decimal->decimal cast.
    """
    if to_scale == from_scale:
        return v
    if to_scale > from_scale:
        return v * pow10_i256(to_scale - from_scale)
    # scale down: divide + round half away from zero.
    var div = pow10_i256(from_scale - to_scale)
    var q = v / div
    # ⛔⛔ THE REMAINDER IS `v - q * div`, NOT `v % div`. Mojo's integer SIMD
    # `/` TRUNCATES toward zero but its `%` is FLOORED (the divisor's sign):
    # `SIMD[int256](-399) / 100 == -3` and `% 100 == 1`.
    # The pair `(v / div, v % div)` is therefore not a division identity for a
    # NEGATIVE `v`, and would round every negative NON-tie the wrong way:
    # -3.99 -> -3 (true -4) and -3.01 -> -4 (true -3). Ties come out right by
    # coincidence (the floored remainder of an exact half IS the half), so a
    # test over ties alone (e.g. -1.25) cannot catch it.
    var rem = v - q * div
    var two_abs_rem = i256_abs(rem) * I256(2)
    if two_abs_rem >= div:
        q = q + i256_sign(v)
    return q


# --- result-type computation ----------------------------------------------


@always_inline
def decimal_add_result_ps(p1: Int, s1: Int, p2: Int, s2: Int) -> Tuple[Int, Int]:
    """(precision, scale) of D(p1,s1) +/- D(p2,s2)."""
    var s = max(s1, s2)
    var int_digits = max(p1 - s1, p2 - s2)
    var p = min(int_digits + s + 1, DEC128_MAX_PRECISION)
    return (p, s)


@always_inline
def decimal_mul_result_ps_checked(
    p1: Int, s1: Int, p2: Int, s2: Int
) -> Tuple[Int, Int, Bool]:
    """★ THE DECIMAL-MUL RESULT RULE, ONCE — `(precision, scale,
    representable)`. NON-RAISING.

    `decimal_mul_result_ps` is a thin RAISING WRAPPER over this, so the rule
    itself is stated in exactly one place and the two callers differ only in
    what they do about an unrepresentable result.

    ⚠ THE SPLIT EXISTS BECAUSE A NON-RAISING CALLER NEEDS THE RULE.
    `plan/expr_walk.walk_expr_field` is
    the ONE output-field inference for the whole tree, and it MUST be
    non-raising: `LogicalPlan.project` / `.project_with_udf` / `.aggregate` /
    `.aggregate_with_udf` are non-raising CONSTRUCTORS that synthesize
    `output_schema` through it. Mojo's effect system is per-function, so a
    single call to a `raises` function would have made the whole walk raising
    and those four constructors with it. Re-deriving `min(p1+p2+1, 38)` and
    `s1+s2` inside the walk instead would be a SECOND COPY OF THIS RULE --
    precisely the defect class a single rule exists to prevent.
    """
    var raw_s = s1 + s2
    var p = min(p1 + p2 + 1, DEC128_MAX_PRECISION)
    return (p, raw_s, raw_s <= DEC128_MAX_SCALE)


@always_inline
def decimal_mul_result_ps(p1: Int, s1: Int, p2: Int, s2: Int) raises -> Tuple[Int, Int]:
    """(precision, scale) of D(p1,s1) * D(p2,s2) — standard SQL rule
    (arrow-rs / DuckDB-compatible): result_scale = s1 + s2,
    result_precision = min(p1 + p2 + 1, 38).

    If the raw scale s1+s2 > 38 the result is unrepresentable — raises
    (matches DuckDB's "Needed scale N to accurately represent the
    multiplication result, but this is out of range"; arrow-rs's behavior
    in that corner is murky — scale > precision).  When p1+p2+1 > 38 but
    s1+s2 <= 38 the precision clamps to 38 and any per-value product that
    needs more than 38 digits raises at runtime.

    ⚠ THE RULE LIVES IN `decimal_mul_result_ps_checked`, NOT HERE. This is
    the raising presentation of it; keep them that way round.
    """
    var r = decimal_mul_result_ps_checked(p1, s1, p2, s2)
    if not r[2]:
        raise Error(
            "Decimal128 mul: result scale "
            + String(r[1])
            + " exceeds 38 — cast an operand to a smaller scale or to DOUBLE"
        )
    return (r[0], r[1])


@always_inline
def decimal_div_result_ps(p1: Int, s1: Int, p2: Int, s2: Int) -> Tuple[Int, Int]:
    """(precision, scale) of D(p1,s1) / D(p2,s2) — Hive/arrow-rs `decimal_op`
    rule: result_scale = min(s1 + 4, 38)."""
    var s = min(s1 + 4, DEC128_MAX_SCALE)
    var mul_pow = s - s1 + s2
    var p = min(mul_pow + p1, DEC128_MAX_PRECISION)
    return (p, s)


# --- the four scalar ops ---------------------------------------------------


@always_inline
def decimal_add_i128(a: I128, s1: Int, b: I128, s2: Int, out_scale: Int) raises -> I128:
    """Add `a` (at scale s1) + `b` (at scale s2), result at scale out_scale.

    Raises on Decimal128 overflow."""
    var a256 = a.cast[DType.int256]() * pow10_i256(out_scale - s1)
    var b256 = b.cast[DType.int256]() * pow10_i256(out_scale - s2)
    var r = a256 + b256
    if overflows_dec128(r):
        raise Error("Decimal128 overflow in add: result exceeds DECIMAL128(38,...) range")
    return r.cast[DType.int128]()


@always_inline
def decimal_sub_i128(a: I128, s1: Int, b: I128, s2: Int, out_scale: Int) raises -> I128:
    """Subtract `a` (at scale s1) - `b` (at scale s2), result at scale out_scale.

    Raises on Decimal128 overflow."""
    var a256 = a.cast[DType.int256]() * pow10_i256(out_scale - s1)
    var b256 = b.cast[DType.int256]() * pow10_i256(out_scale - s2)
    var r = a256 - b256
    if overflows_dec128(r):
        raise Error("Decimal128 overflow in sub: result exceeds DECIMAL128(38,...) range")
    return r.cast[DType.int128]()


@always_inline
def decimal_mul_i128(a: I128, b: I128) raises -> I128:
    """Multiply `a` * `b` — the raw product (scale = s1 + s2, kept as-is).

    The result precision clamps to 38 in the type, so a product needing more
    than 38 digits raises here.  Raises on Decimal128 overflow."""
    var prod = a.cast[DType.int256]() * b.cast[DType.int256]()
    if overflows_dec128(prod):
        raise Error("Decimal128 overflow in mul: result exceeds DECIMAL128(38,...) range")
    return prod.cast[DType.int128]()


@always_inline
def decimal_div_i128(a: I128, s1: Int, b: I128, s2: Int, out_scale: Int) raises -> I128:
    """Divide `a` (scale s1) / `b` (scale s2), result at out_scale = min(s1+4, 38).

    DELIBERATE DIVERGENCE FROM arrow-rs: arrow-rs's `div` kernel TRUNCATES
    toward zero; we round HALF_UP (round half away from zero) — that is
    what DuckDB and PostgreSQL do, and truncating SQL division surprises
    users.  Division-rounding test oracle is DuckDB, NOT arrow-rs.

    Raises on division-by-zero or Decimal128 overflow.
    """
    if b == I128(0):
        raise Error("Decimal128 division by zero")
    var mul_pow = out_scale - s1 + s2
    if mul_pow < 0:
        # Unreachable under out_scale = min(s1+4, 38), but guard anyway.
        raise Error("Decimal128 div: negative rescale exponent (internal)")
    # ⛔ The scaled numerator can pass 2^255 (DECIMAL(38,0) / DECIMAL(38,38)
    # at scale 4 has mul_pow 42) and would WRAP. When it does not fit int256
    # the quotient cannot fit Decimal128 either: |num| > 2^255 and
    # |den| <= 2^127 put |q| above 2^128 > 10^38. |a| <= 2^127 cannot wrap
    # in int256.
    var a256 = a.cast[DType.int256]()
    var scale_up = pow10_i256(mul_pow)
    if i256_abs(a256) > I256.MAX / scale_up:
        raise Error("Decimal128 overflow in div: result exceeds DECIMAL128(38,...) range")
    var num = a256 * scale_up
    var den = b.cast[DType.int256]()
    var q = num / den
    # ⛔ `num - q * den`, NOT `num % den` — Mojo's integer `%` is FLOORED while
    # `/` truncates; see `rescale_i256_half_up`. `-1 / 3` at scale 2 would
    # answer -0.34 (true -0.33) with the floored remainder.
    var rem = num - q * den
    # HALF_UP: if 2*|rem| >= |den|, round the quotient away from zero,
    # using the sign of the true quotient (sign(num) XOR sign(den)).
    var two_abs_rem = i256_abs(rem) * I256(2)
    if two_abs_rem >= i256_abs(den):
        var qsign = i256_sign(num) * i256_sign(den)
        q = q + qsign
    if overflows_dec128(q):
        raise Error("Decimal128 overflow in div: result exceeds DECIMAL128(38,...) range")
    return q.cast[DType.int128]()

# =============================================================================
# xl_scalar_numeric.mojo — ★ THE TRANSCENDENTAL + INTEGER-SHAPING KERNELS.
#            THE FAMILY THE CENSUS WAS NOT EVEN ABLE TO SAY IT DID NOT HAVE.
# =============================================================================
#
# ============ ⚠⚠ WHY THIS FILE EXISTS, AND IT IS NOT "MORE FUNCTIONS" =======
#
# Measured 2026-09-04, over `xl_fn_table` at : the Excel census
# spoke about **99 names** — 83 rows plus 16 stated absences. Twenty-one of the
# names below were in NEITHER set. `EXP`, `LN`, `LOG`, `LOG10`, `PI`, the whole
# trig block: a non-Mojo caller asking `komira_xl_functions` *"does this
# engine do LN?"* got **no answer at all**, which is a different and worse
# thing than getting `no`.
#
# ⛔ AND THE CENSUS'S OWN INSTRUMENT COULD NOT REPORT IT.
# `test_no_absent_name_resolves` only REDs on GOOD news — a listed name that
# starts resolving. Nothing goes red in the other direction, because a name
# nobody wrote down is invisible to a check that walks what was written down.
# So the absence list's docstring ("IT IS AN ASSERTION, NOT A WISH LIST") was
# true about every name IN it and said nothing about the ones that were not.
#
# ⇒ Every name here is now a ROW. The ones that stay out are now stated
# ABSENCES with measured reasons, which is the half that was missing.
#
# ==================== THE SEAM (see `xl_scalar_math.mojo`) ==================
#
# ============ ⚠⚠ WHERE THE TRANSCENDENTALS COME FROM, AND WHY ==============
#
# `external_call["log", Float64](x)` and friends — the SAME libm the SQL
# surface's `scalar_math.mojo` calls, for the same reason it gives: DuckDB
# calls libm too, so going to libm makes a cross-surface comparison
# BIT-IDENTICAL where an identity reconstruction (`log10 = log(x)/ln(10)`)
# would be right to within an ulp and would put a last-bit disagreement into a
# parity cell that no kernel work could ever close.
#
# ⚠ `floor` / `ceil` / `pi` STAY ON `std.math` — those are exact, with a single
# correctly-rounded answer and no oracle to diverge from.
#
# Encapsulation rule : values only. No `UnsafePointer`, no wildcard
# origins, no `unsafe_from_address`.
# =============================================================================

from std.ffi import external_call
from std.math import floor, ceil, pi, atan2

from komira_core.plan.excel_error_code import XL_ERR_DIV0, XL_ERR_NUM

from .formula_value import FormulaValue
from .xl_scalar_math import _half_away_from_zero


comptime _RAD_PER_DEG: Float64 = pi / 180.0
comptime _DEG_PER_RAD: Float64 = 180.0 / pi
comptime _HALF_PI: Float64 = pi / 2.0
"""⚠ USED BY `ACOT`, WHOSE IDENTITY IS `pi/2 - atan(x)`. Spelled as a
comptime division of the stdlib `pi` rather than a transcribed literal so it
cannot drift from the `PI()` this same module returns."""


def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` as a NUMBER, or the error that stops the call.

    Identical in contract to `xl_scalar_math._num` and deliberately re-spelled
    rather than imported: it is four lines, and a cross-module import of a
    private helper is the kind of edge that makes a "kernels only" module stop
    being one. ⚠ IF THE DOMINANCE RULE EVER CHANGES, BOTH CHANGE."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def _trunc_toward_zero(x: Float64) -> Float64:
    """The integer part, TOWARD ZERO. ⚠ NOT `floor` — they differ on every
    negative non-integer, which is the whole difference between `TRUNC`/
    `QUOTIENT` (truncate) and `INT`/`MOD` (floor)."""
    return floor(x) if x >= 0.0 else ceil(x)


# =============================================================================
# ★ THE LOGARITHM / EXPONENTIAL FAMILY
#
# ⚠⚠ THE DOMAIN REFUSALS ARE THE WHOLE POINT OF THESE BEING KERNELS RATHER
# THAN ONE-LINE FORWARDS TO libm. `log(0.0)` in C is `-inf` and `log(-1.0)` is
# `NaN`; both are FINITE-LOOKING Float64 values that travel silently through
# every comparison and every aggregate above them. Excel answers `#NUM!` and
# `#DIV/0!`, which STOP.
# =============================================================================
def xl_exp(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`EXP(number)` — e raised to `number`.

    ⚠ NO OVERFLOW REFUSAL, AND THAT IS EXCEL'S BEHAVIOUR RATHER THAN AN
    OMISSION: Excel's `EXP(1000)` is `#NUM!` because its own numeric range
    stops at ~1.798e308 — which is binary64's, the same ceiling this returns
    `inf` at. DIVERGENCE, STATED: an overflowing `EXP` is `+inf` here and
    `#NUM!` in Excel. Refusing on `isinf` would be the closer answer and is NOT
    taken here, because it cannot distinguish an overflow from an `+inf`
    argument the caller passed in deliberately."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(external_call["exp", Float64](x.num))


def xl_ln(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`LN(number)` — the natural logarithm.

    ⛔ THE TWO DEGENERATE INPUTS ARE **ERRORS**, NOT libm's NUMBERS. `LN(0)` is
    `#NUM!` in Excel where C's `log(0.0)` is `-inf`, and `LN(-1)` is `#NUM!`
    where C gives `NaN`. Both C answers are Float64 values that keep
    travelling: `-inf` compares, sorts and sums; `NaN` makes every comparison
    above it FALSE without ever raising. An all-positive fixture cannot tell
    this guard from its absence, which is why the test uses `signedmix`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(external_call["log", Float64](x.num))


def xl_log10(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`LOG10(number)` — base-10. Same domain refusal as `LN`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(external_call["log10", Float64](x.num))


def xl_log(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`LOG(number, [base])` — ⛔ **TWO ARGUMENTS IN EXCEL, BASE DEFAULTING TO
    10**, where this repo's SQL surface has a ONE-argument base-10 `log` and
    most languages' `log` is the NATURAL one.

    So there are two ways to get this silently wrong and they point opposite
    ways: forwarding to `ln` makes `LOG(100)` answer 4.605 instead of 2, and
    ignoring the second argument makes `LOG(8, 2)` answer 0.903 instead of 3.
    Both are plausible positive numbers.

    ⚠ THE DEGENERATE BASES ARE ERRORS, AND WHICH ERROR IS THIS KERNEL'S
    READING OF EXCEL'S `LN(n)/LN(base)` DECOMPOSITION rather than a value
    checked against a live Excel: `base <= 0` is `#NUM!` (the numerator rule
    applied to the base) and `base == 1` is `#DIV/0!` (an exact division by
    `LN(1) == 0`). A caller sees a REFUSAL either way; only the code could
    differ from a real sheet, and that is written here rather than presented as
    verified."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    if len(args) < 2:
        return FormulaValue.number(external_call["log10", Float64](x.num))
    var b = _num(args, 1)
    if b.is_error():
        return b^
    if b.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    if b.num == 1.0:
        return FormulaValue.error(XL_ERR_DIV0)
    var ln_b = external_call["log", Float64](b.num)
    return FormulaValue.number(external_call["log", Float64](x.num) / ln_b)


def xl_pi(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PI()` — the constant, to binary64 precision.

    ⚠ ZERO ARGUMENTS, and it still takes the list because every registry thunk
    has one signature. `args` is empty and unread — same shape as `NA()`."""
    return FormulaValue.number(pi)


# =============================================================================
# ★ THE INTEGER-SHAPING FAMILY — and every one of them rounds AWAY FROM ZERO,
#   which is the opposite of what the names suggest to anyone who has used
#   `math.floor` / `math.trunc`.
# =============================================================================
def xl_trunc(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TRUNC(number, [num_digits])` — chop toward zero, digits default 0.

    ⚠ IT IS **NOT** `INT`, AND THE TWO AGREE ON EVERY POSITIVE VALUE. Excel's
    `INT` FLOORS: `INT(-8.9)` is -9. `TRUNC(-8.9)` is -8. A fixture with no
    negative numbers cannot tell these two functions apart at all, which is why
    the test asserts the pair together.

    ⚠ AND IT IS NOT `ROUNDDOWN` EITHER, ALTHOUGH THEY COMPUTE THE SAME THING.
    Excel really does ship both; the difference is only that `ROUNDDOWN`
    REQUIRES the digits argument in some Excel versions and `TRUNC` does not.
    Registering one as a synonym of the other would be right today and would
    hide the day one of them gains a semantic the other lacks."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var digits = 0
    if len(args) >= 2:
        var d = _num(args, 1)
        if d.is_error():
            return d^
        digits = Int(d.num)
    var f = Float64(1.0)
    var n = digits if digits >= 0 else -digits
    for _ in range(n):
        f = f * 10.0
    if digits < 0:
        f = 1.0 / f
    return FormulaValue.number(_trunc_toward_zero(x.num * f) / f)


def xl_even(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`EVEN(number)` — up to the next EVEN integer, AWAY FROM ZERO.

    ⛔ `EVEN(3)` IS **4**, NOT 3 — it does not "round to the nearest even", it
    moves away from zero until it lands on an even integer, and an odd integer
    input is therefore CHANGED. `EVEN(2)` is 2 (already even), `EVEN(0)` is 0,
    and `EVEN(-1.5)` is **-2** rather than -1: away from zero on the negative
    side means DOWN. An implementation built on IEEE round-half-to-even gets
    every one of those wrong."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num == 0.0:
        return FormulaValue.number(0.0)
    var half = x.num / 2.0
    var up = ceil(half) if half > 0.0 else floor(half)
    return FormulaValue.number(up * 2.0)


def xl_odd(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ODD(number)` — up to the next ODD integer, AWAY FROM ZERO.

    ⛔ `ODD(0)` IS **1**, NOT 0. Zero is the one input where the "move away
    from zero" rule has no direction to take, and Excel picks +1. `ODD(2)` is
    3, `ODD(3)` is 3, `ODD(-2)` is -3."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num == 0.0:
        return FormulaValue.number(1.0)
    var neg = x.num < 0.0
    var mag = -x.num if neg else x.num
    # (mag + 1) / 2 rounded up, doubled, minus 1 — the odd integer at or above
    # `mag`. Integer-exact for every |x| below 2**52.
    var k = ceil((mag + 1.0) / 2.0)
    var result = k * 2.0 - 1.0
    return FormulaValue.number(-result if neg else result)


def xl_quotient(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`QUOTIENT(numerator, denominator)` — the integer part of the division.

    ⛔⛔ IT TRUNCATES TOWARD ZERO WHILE `MOD` FLOORS, AND SO THE DIVISION
    IDENTITY DOES NOT HOLD IN EXCEL. `QUOTIENT(-5, 2)` is **-2** and
    `MOD(-5, 2)` is **1**, so `QUOTIENT(n,d)*d + MOD(n,d)` is -3 and not -5.
    That is Excel's own inconsistency, faithfully reproduced; making the two
    agree would require picking one of them to be wrong. Anyone who "fixes"
    this kernel to floor will make it agree with `MOD` and disagree with every
    spreadsheet.

    A zero denominator is `#DIV/0!`."""
    var n = _num(args, 0)
    if n.is_error():
        return n^
    var d = _num(args, 1)
    if d.is_error():
        return d^
    if d.num == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    return FormulaValue.number(_trunc_toward_zero(n.num / d.num))


# =============================================================================
# ★ TRIGONOMETRY — radians throughout, and ONE argument-order trap.
# =============================================================================
def xl_sin(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SIN(number)` — `number` in RADIANS. `SIN(30)` is not 0.5; `SIN(RADIANS(30))` is."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(external_call["sin", Float64](x.num))


def xl_cos(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`COS(number)` — RADIANS."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(external_call["cos", Float64](x.num))


def xl_tan(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TAN(number)` — RADIANS.

    ⚠ NO REFUSAL AT THE POLES, and it matches Excel: `TAN(PI()/2)` is a huge
    finite number in Excel too (1.633e16), because pi/2 is not exactly
    representable so the tangent is never actually asked for at the pole."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(external_call["tan", Float64](x.num))


def xl_asin(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ASIN(number)` — RADIANS out, and the domain is [-1, 1].

    ⛔ OUTSIDE THE DOMAIN IS `#NUM!`, NOT `NaN`. C's `asin(2.0)` is `NaN`,
    which is a Float64 that keeps travelling and makes every comparison above
    it FALSE without raising anything."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num < -1.0 or x.num > 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(external_call["asin", Float64](x.num))


def xl_acos(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ACOS(number)` — the same domain refusal as `ASIN`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num < -1.0 or x.num > 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(external_call["acos", Float64](x.num))


def xl_atan(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ATAN(number)` — the whole real line, result in (-pi/2, pi/2)."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(external_call["atan", Float64](x.num))


def xl_atan2(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ATAN2(x_num, y_num)` — ⛔⛔ **EXCEL'S ARGUMENTS ARE THE REVERSE OF C'S,
    AND OF THIS REPO'S OWN SQL `atan2`.**

        Excel        ATAN2(x, y)      x FIRST
        C / libm     atan2(y, x)      y FIRST
        komira SQL   atan2(y, x)      y FIRST  (sql_fn_table.mojo, MATH2_ATAN2)

    So the correct forward is `atan2(args[1], args[0])`, spelled below with the
    indices deliberately crossed. Getting it wrong is not a crash and not an
    error value: `ATAN2(1, 0)` is **0** (the point (1,0) lies along +x) and a
    swapped kernel answers **pi/2**; `ATAN2(0, 1)` is **pi/2** and a swapped
    kernel answers **0**. `ATAN2(1, 1)` answers the SAME 0.785 either way — the
    diagonal is exactly where the bug hides, and it is the first case anybody
    tests.

    ⚠ AND THE CROSS-SURFACE COMPARISON CANNOT SEE IT EITHER, because the SQL
    door and the Excel door take their arguments in opposite orders BY
    SPECIFICATION. A matrix cell feeding both the same two values and comparing
    outputs is asserting that this bug EXISTS.

    `ATAN2(0, 0)` is `#DIV/0!` in Excel, where C's `atan2(0.0, 0.0)` is 0.0."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var y = _num(args, 1)
    if y.is_error():
        return y^
    if x.num == 0.0 and y.num == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    # ⚠ CROSSED ON PURPOSE. See the docstring: Excel is (x, y), libm is (y, x).
    # ⚠ AND IT IS `std.math.atan2`, NOT `external_call` — see the import. The
    # crossing is unchanged; only the declaration channel is.
    return FormulaValue.number(atan2(y.num, x.num))


def xl_sinh(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SINH(number)`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(external_call["sinh", Float64](x.num))


def xl_cosh(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`COSH(number)`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(external_call["cosh", Float64](x.num))


def xl_tanh(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TANH(number)`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(external_call["tanh", Float64](x.num))


# =============================================================================
# ⭐⭐ THE RECIPROCAL CIRCULAR FAMILY (2026-09-14) — SEC / CSC / COT.
#
# ⚠ AND THE GUARD IS ON THE **DENOMINATOR**, NOT ON THE ARGUMENT. `sin(pi)` is
# 1.2246e-16 and not 0, so `CSC(PI())` is a large finite number in Excel too;
# testing `x == 0.0` would refuse the wrong set.
# =============================================================================
def xl_sec(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SEC(number)` — the secant, 1/cos(number), `number` in RADIANS.

    ⚠ NO DEGENERATE INPUT: `cos` has no exact zero in binary64, so this never
    divides by zero. `SEC(0)` is 1 — which is also `SECH(0)`, `COSH(0)` and
    `1/COS(0)`, so a fixture at 0 alone cannot tell four functions apart."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(1.0 / external_call["cos", Float64](x.num))


def xl_csc(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CSC(number)` — the cosecant, 1/sin(number).

    ⛔ `CSC(0)` IS `#DIV/0!`, NOT `+inf` and not a huge number. `sin(0.0)` is
    exactly 0.0, which is the one input where the reciprocal is undefined."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var d = external_call["sin", Float64](x.num)
    if d == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    return FormulaValue.number(1.0 / d)


def xl_cot(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`COT(number)` — the cotangent, cos(number)/sin(number).

    ⛔ `COT(0)` IS `#DIV/0!`.

    ⚠ SPELLED `cos/sin` AND NOT `1/tan`, AND THE TWO ARE NOT THE SAME FUNCTION
    NEAR pi/2: `tan(pi/2)` is 1.633e16 (a finite double, because pi/2 is not
    representable), so `1/tan` is 6.12e-17 while `cos/sin` is the same value
    computed without the intermediate overflow. The division that matters is
    the one by `sin`, which is what is guarded."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var d = external_call["sin", Float64](x.num)
    if d == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    return FormulaValue.number(external_call["cos", Float64](x.num) / d)


# =============================================================================
# ⭐⭐ THE RECIPROCAL HYPERBOLIC FAMILY (2026-09-14) — SECH / CSCH / COTH.
# Same split: `cosh` is never 0, `sinh(0)` and `tanh(0)` are exactly 0.
# =============================================================================
def xl_sech(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SECH(number)` — 1/cosh(number). No degenerate input; `SECH(0)` is 1.

    ⚠ `cosh` OVERFLOWS TO `+inf` ABOVE ~710, and 1/inf is 0.0 — which is the
    mathematically right answer and NOT an overflow, so this one genuinely does
    return a number where `COSH` itself is now `#NUM!`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(1.0 / external_call["cosh", Float64](x.num))


def xl_csch(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CSCH(number)` — 1/sinh(number). `CSCH(0)` is `#DIV/0!`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var d = external_call["sinh", Float64](x.num)
    if d == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    return FormulaValue.number(1.0 / d)


def xl_coth(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`COTH(number)` — 1/tanh(number). `COTH(0)` is `#DIV/0!`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var d = external_call["tanh", Float64](x.num)
    if d == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    return FormulaValue.number(1.0 / d)


# =============================================================================
# ⭐⭐ THE INVERSE FAMILY (2026-09-14) — ACOT / ACOTH / ASINH / ACOSH / ATANH.
#
# ⛔⛔ `ACOT` IS THE ONE WITH A TRAP, AND IT IS A **BRANCH** AND NOT A
# PRECISION QUESTION. Excel's ACOT returns a value in (0, pi) — the principal
# branch of the cotangent's inverse — so `ACOT(-1)` is 3pi/4. The obvious
# spelling `ATAN(1/x)` returns -pi/4 there: an answer wrong by exactly pi, from
# a kernel that is exactly right for every POSITIVE argument. A fixture with no
# negative argument cannot see it. `pi/2 - ATAN(x)` is the identity that holds
# on both sides, and it also removes the division that `ACOT(0)` would trip.
# =============================================================================
def xl_acot(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ACOT(number)` — the inverse cotangent, in RADIANS, on (0, pi).

    ⛔ `pi/2 - atan(x)`, NEVER `atan(1/x)`. `ACOT(0)` is pi/2 (the 1/x spelling
    divides by zero) and `ACOT(-1)` is 3pi/4 (the 1/x spelling answers -pi/4,
    off by pi, with no error and no infinity to notice). TOTAL: every finite
    argument has an answer."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(_HALF_PI - external_call["atan", Float64](x.num))


def xl_acoth(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ACOTH(number)` — the inverse hyperbolic cotangent.

    ⛔ THE DOMAIN IS `|number| > 1`, STRICTLY, AND IT IS THE MIRROR OF
    `ATANH`'s: `ACOTH(1)` and `ACOTH(0.5)` are `#NUM!` where `ATANH(0.5)` is a
    number and `ATANH(1)` is `#NUM!`. The two are the same formula reading
    `(x+1)/(x-1)` and `(1+x)/(1-x)`, so a kernel that copied one into the other
    answers plausible numbers on exactly the inputs the other refuses."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var v = x.num
    if v <= 1.0 and v >= -1.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(
        0.5 * external_call["log", Float64]((v + 1.0) / (v - 1.0))
    )


def xl_asinh(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ASINH(number)` — TOTAL, no domain refusal, and the only one of the
    three inverse hyperbolics that has none."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(external_call["asinh", Float64](x.num))


def xl_acosh(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ACOSH(number)` — the domain is `number >= 1`; below it, `#NUM!`.

    ⛔ libm's `acosh(0.5)` is `NaN`, a Float64 that keeps travelling and makes
    every comparison above it FALSE without raising. `ACOSH(1)` is 0 — which is
    also `ASINH(0)` and `ATANH(0)`, so the zero is not a discriminator."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num < 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(external_call["acosh", Float64](x.num))


def xl_atanh(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ATANH(number)` — the domain is `|number| < 1`, STRICTLY.

    ⛔ `ATANH(1)` IS `#NUM!`, NOT `+inf`. libm's `atanh(1.0)` is `+inf` and
    `atanh(2.0)` is `NaN`; both are the finite-looking travellers this whole
    family of guards exists to stop."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num >= 1.0 or x.num <= -1.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(external_call["atanh", Float64](x.num))


def xl_sqrtpi(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SQRTPI(number)` — sqrt(number * pi).

    ⛔ A NEGATIVE ARGUMENT IS `#NUM!` and not `NaN`, the same guard `SQRT`
    carries. `SQRTPI(0)` is 0 exactly; `SQRTPI(1)` is sqrt(pi), which is the
    cell that separates this from a kernel that forgot the pi."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(
        external_call["sqrt", Float64](x.num * pi)
    )


def xl_degrees(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DEGREES(angle)` — radians to degrees. One exact multiplication."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(x.num * _DEG_PER_RAD)


def xl_radians(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`RADIANS(angle)` — degrees to radians."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(x.num * _RAD_PER_DEG)


# =============================================================================
# ★ THE PARITY PREDICATES — Excel files them under Information, and their
#   ERROR CLASS is the opposite of every other `IS*`.
# =============================================================================
def xl_isodd(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ISODD(number)` — TRUE when the TRUNCATED value is odd.

    ⚠ IT TRUNCATES TOWARD ZERO, IT DOES NOT FLOOR. `ISEVEN(-1.5)` truncates to
    -1 and is FALSE; a floor would give -2 and answer TRUE. As everywhere else
    in this file, the two rules agree on every positive input.

    ⛔⛔ ITS ERROR CLASS IS **DOMINANCE**, NOT THE `ERRH_MANUAL` THE REST OF
    THE `IS*` FAMILY USES, AND THE DIFFERENCE IS REAL RATHER THAN A REGISTRY
    DETAIL. `ISERROR`/`ISNA`/`ISBLANK` exist to LOOK AT a value, so an error
    argument is their subject matter. `ISODD` asks an ARITHMETIC question, and
    Excel's `ISODD(1/0)` is `#DIV/0!` — the error propagates exactly as it does
    through `MOD`. Registering these two as `ERRH_MANUAL` alongside their
    alphabetical neighbours would make `ISODD(1/0)` answer FALSE, which is a
    confident boolean where Excel refuses.

    Non-numeric text is `#VALUE!`, via the shared coercion."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var t = _trunc_toward_zero(x.num)
    var half = _trunc_toward_zero(t / 2.0)
    return FormulaValue.logical_val(t - half * 2.0 != 0.0)


def xl_iseven(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ISEVEN(number)` — the complement of `ISODD` over the truncated value.
    Same dominance error class; see `xl_isodd`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var t = _trunc_toward_zero(x.num)
    var half = _trunc_toward_zero(t / 2.0)
    return FormulaValue.logical_val(t - half * 2.0 == 0.0)


# =============================================================================
# ★ GCD / LCM / MROUND — the integer-arithmetic trio.
#
# ⚠ THEY WORK IN `Int` INTERNALLY AND THAT IS A REAL LIMIT, NOT AN OVERSIGHT.
# `FormulaValue` carries `Float64`, which represents every integer exactly up to
# 2**53; Excel's own documented ceiling for `GCD`/`LCM` arguments is 2**53 as
# well (it states "less than 9.99E+14"). Beyond that a Float64 argument is not
# an integer any more and the answer would be about the rounded value, so the
# kernels REFUSE rather than compute one.
# =============================================================================
comptime _INT_EXACT_MAX: Float64 = 9007199254740992.0  # 2**53


def _int_arg(imm v: FormulaValue) -> Optional[Int]:
    """A NUMBER argument as a non-negative exactly-representable integer.

    ⚠ EXCEL TRUNCATES EACH ARGUMENT TO AN INTEGER — `GCD(12.9, 8)` is
    `GCD(12, 8)` = 4 — so the truncation is the specified behaviour and not a
    convenience. `None` means the value is out of the exactly-representable
    range and the caller must refuse."""
    var t = _trunc_toward_zero(v.num)
    if t < 0.0 or t > _INT_EXACT_MAX:
        return Optional[Int]()
    return Optional[Int](Int(t))


def _gcd2(a: Int, b: Int) -> Int:
    """Euclid. `gcd(0, n)` is `n`, which is what makes the variadic fold start
    from 0 correctly."""
    var x = a
    var y = b
    while y != 0:
        var t = x % y
        x = y
        y = t
    return x


def xl_gcd(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GCD(number1, ...)` — the greatest common divisor, variadic.

    ⚠ EVERY ARGUMENT IS TRUNCATED TO AN INTEGER FIRST (`GCD(12.9, 8)` is 4),
    and a NEGATIVE argument is `#NUM!` — Excel refuses rather than taking the
    absolute value, so `GCD(-4, 8)` is an error and not 4.

    ⚠ `GCD(0, 0)` IS 0, which falls out of the fold and is Excel's answer."""
    var acc = 0
    for i in range(len(args)):
        var v = _num(args, i)
        if v.is_error():
            return v^
        var iv = _int_arg(v)
        if not iv:
            return FormulaValue.error(XL_ERR_NUM)
        acc = _gcd2(acc, iv.value())
    return FormulaValue.number(Float64(acc))


def xl_lcm(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`LCM(number1, ...)` — the least common multiple, variadic.

    ⚠ THE FOLD DIVIDES BEFORE IT MULTIPLIES (`a / gcd * b`, not
    `a * b / gcd`), which is what keeps an intermediate from overflowing on a
    pair whose LCM is perfectly representable.

    ⚠ ANY ZERO ARGUMENT MAKES THE RESULT 0, which is Excel's answer and is also
    what the fold gives; a negative argument is `#NUM!`, as for `GCD`. An
    overflow past 2**53 is `#NUM!` rather than a silently rounded number."""
    var acc = 1
    for i in range(len(args)):
        var v = _num(args, i)
        if v.is_error():
            return v^
        var iv = _int_arg(v)
        if not iv:
            return FormulaValue.error(XL_ERR_NUM)
        var b = iv.value()
        if b == 0:
            return FormulaValue.number(0.0)
        var g = _gcd2(acc, b)
        var step = (acc // g)
        if Float64(step) * Float64(b) > _INT_EXACT_MAX:
            return FormulaValue.error(XL_ERR_NUM)
        acc = step * b
    return FormulaValue.number(Float64(acc))


def xl_mround(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`MROUND(number, multiple)` — the nearest multiple, ties AWAY FROM ZERO.

    ⛔ `number` AND `multiple` MUST SHARE A SIGN OR IT IS `#NUM!`. That is
    Excel's rule and it is the one thing about this function nobody expects:
    `MROUND(10, -3)` is an ERROR, not -9 and not 9. A kernel that just computed
    `round(n/m)*m` answers 9 and never refuses.

    ⚠ A ZERO MULTIPLE IS 0, not `#DIV/0!`.

    ⚠ AND THE TIE RULE IS AWAY FROM ZERO, matching `ROUND` and not the IEEE
    half-to-even a language `round()` gives: `MROUND(1.5, 1)` is 2.

    ⚠ IT SHARES `ROUND`'S TIE RULE AND NOW SHARES ITS IMPLEMENTATION. Until
    2026-09-14 the rule was spelled out TWICE — here and in `xl_round` — so the
    two names could have drifted apart silently; both now call
    `_half_away_from_zero`. ⛔ THAT HELPER'S DOCSTRING RECORDS A MEASURED
    NEGATIVE RESULT: the textbook `floor(x+0.5)` fix moves both kernels AWAY
    from Excel, so the spelling was KEPT after measurement rather than through
    inattention."""
    var n = _num(args, 0)
    if n.is_error():
        return n^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    if m.num == 0.0:
        return FormulaValue.number(0.0)
    if (n.num > 0.0 and m.num < 0.0) or (n.num < 0.0 and m.num > 0.0):
        return FormulaValue.error(XL_ERR_NUM)
    var q = n.num / m.num
    return FormulaValue.number(_half_away_from_zero(q) * m.num)


# =============================================================================
# =============================================================================
def xl_neg(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NEG(number)` — arithmetic negation, the function spelling of unary `-`.
    Defined by ODF OpenFormula and OOXML; not on Microsoft's list.

    ⛔ THE TWIN IS `ABS`, AND HALF THE NUMBER LINE CANNOT TELL THEM APART:
    `NEG(-3)` and `ABS(-3)` are both 3. The graded cell is at a POSITIVE
    argument, where NEG is -3 and ABS is 3.

    ⚠ `NEG(0)` IS `0` AND NOT `-0`, AND THE GUARD IS HERE ON PURPOSE. The
    RENDER already hides it — `_format_number_general` asks
    `Float64(Int64(v)) == v`, and `-0.0 == 0.0` is TRUE, so a stored `-0.0`
    prints "0" — but the stored Float64 would still be `-0.0` and would carry
    into any comparison, aggregate or sign test above this call. Normalising at
    the CONSTRUCTION is the same argument `FormulaValue.number` makes for
    refusing non-finites at the choke point rather than at the render."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num == 0.0:
        return FormulaValue.number(0.0)
    return FormulaValue.number(-x.num)

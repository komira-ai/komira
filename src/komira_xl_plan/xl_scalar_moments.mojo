# =============================================================================
# xl_scalar_moments.mojo — ★★ THE VARIADIC-OVER-ARGUMENTS STATISTICS, AND THE
#                             REFUSAL THEY WERE HELD OUT BY WAS ABOUT A
#                             DIFFERENT SURFACE.
# =============================================================================
#
# ⭐⭐ THE FINDING THAT OPENED THIS FILE IS A **MIS-SCOPED REFUSAL**, AND IT
# COST FOUR NAMES. `xl_absent_common_names()` refused `STDEV.P` / `VAR.P`
# (and, through them, the pre-2010 spellings `STDEVP` / `VARP`) with a reason
# every word of which is TRUE and every word of which is about the RELATIONAL
# plan surface:
#
#     "AGG_STDDEV_POP_F64 exists at the ENGINE op layer ... there is no
#      AGG_VAR_POP_F64 at all, and _merge_agg_cells RAISES on STDDEV_POP
#      because it is not combine-stable. ⛔ AND ddof CANNOT RIDE THE EXISTING
#      TAG ..."
#
# ⛔ NOT ONE CLAUSE OF THAT IS A PROPERTY OF THE **SCALAR** DOOR. Microsoft
# publishes `STDEV.P(number1, [number2], ...)` — the variadic-over-loose-
# arguments shape `SUM` and `AVERAGE` have served since w2d — and a scalar
# call needs no plan-IR tag, no `AggExpr` options field, no wire vocabulary
# member and no combine step, because there is nothing to combine: every
# value is already in one argument list. The refusal refused the name on
# EVERY surface for a blocker that exists on exactly ONE.
#
# ⇒ WHAT IS IN THIS FILE IS THE VARIADIC HALF ONLY. `STDEV.P(A1:A9)` over a
# BOUND COLUMN is still refused, and is still refused for the reason quoted
# above — that reason now sits on the row's note where it is scoped to the
# surface it is true of, instead of on an absence list where it closed the
# name outright.
#
# ============ ⛔⛔ WHY EVERY ONE OF THESE NEEDS A **VALUE** CELL ============
#
# This family is the effort's named vacuity in its purest form: ELEVEN of
# the twelve functions below return a NUMBER OF THE RIGHT SIGN, THE RIGHT
# UNITS AND A PLAUSIBLE MAGNITUDE when wired to the wrong sibling.
#
#   VAR.P vs VAR.S       divide by n or by n-1. At n=5 the ratio is 0.8 —
#                        a 20% error that no range check and no `ISNUMBER`
#                        can see. This is the `var_pop` aliased to `var_samp`
#                        shape this effort already measured once.
#   STDEV.P vs STDEV.S   the same error under a square root (ratio 0.894).
#   GEOMEAN vs HARMEAN   both are "an average", both lie between MIN and MAX,
#                        and both are BELOW the arithmetic mean for any
#                        non-constant positive data. Over {1,2,4} they are
#                        2 and 12/7 = 1.714286.
#   AVEDEV vs DEVSQ      one is a mean absolute deviation, one a SUM of
#                        squares; a fixture over {1,2,3} gives 2/3 and 2.
#   SKEW vs SKEW.P       the SAME third moment scaled by n/((n-1)(n-2)) or by
#                        1/n. MEASURED over {1,2,3,4,10}: 1.697056 and
#                        1.138420 -- same sign, same order of magnitude, 49%
#                        apart, and the ratio sqrt(n(n-1))/(n-2) is never 1.
#   KURT                 EXCESS kurtosis: its documented form SUBTRACTS
#                        3(n-1)^2/((n-2)(n-3)), which at n=5 is 8. MEASURED
#                        over {1,2,3,4,10}: 3.152 against the uncorrected
#                        11.152 -- still positive, still a kurtosis.
#
# ============ THE ARGUMENT CONVENTION, WHICH IS **NOT** A JUDGEMENT CALL ====
#
# Excel's documented rule for a statistical function's DIRECT arguments (as
# opposed to values reached through a reference) is that logical values and
# text representations of numbers ARE counted, and text that cannot be
# converted is an error. This door has no references at all — every argument
# is a direct scalar — so `_collect` below routes every non-blank argument
# through `FormulaValue.coerce_number`, exactly as `fn_agg._xl_sum` has since
# w2d. Blanks are skipped; an error argument dominates and returns itself.
#
# Encapsulation rule : values only. No `UnsafePointer`, no wildcard
# origins, no `unsafe_from_address`.
# =============================================================================

from std.ffi import external_call
from std.math import sqrt as _sqrt

from komira_core.plan.excel_error_code import XL_ERR_DIV0, XL_ERR_NUM

from .formula_value import FormulaValue


# =============================================================================
# `_collect` — the ONE argument reader for this whole family.
# =============================================================================
@fieldwise_init
struct _Sample(Copyable, Movable):
    """The numbers a variadic statistical call was given, or the error that
    stopped it.

    ⚠ A STRUCT AND NOT A TUPLE BECAUSE THE ERROR IS NOT AN EXCEPTION. Under
    `ERRH_PROPAGATE_DOMINANT` the leftmost error argument is the RESULT, so
    the reader has to hand back a value, not raise."""

    var vals: List[Float64]
    var err: FormulaValue
    var failed: Bool

    def copy(self) -> Self:
        return Self(self.vals.copy(), self.err.copy(), self.failed)


def _collect(imm args: List[FormulaValue]) -> _Sample:
    """Every non-blank argument coerced to a number, in argument order.

    ⚠ BLANK IS SKIPPED, NOT ZERO. `FormulaValue.coerce_number` maps BLANK to
    0.0, which is right for `1+A1` and WRONG for `AVERAGE(1, , 3)` — a
    skipped blank gives 2 and a zeroed one gives 4/3. `fn_agg._xl_average`
    makes the same distinction; this reader is the only place the whole
    moment family makes it, so the two cannot drift apart."""
    var out = List[Float64]()
    for i in range(len(args)):
        if args[i].is_error():
            return _Sample(out^, args[i].copy(), True)
        if args[i].is_blank():
            continue
        var n = args[i].coerce_number()
        if n.is_error():
            return _Sample(out^, n^, True)
        out.append(n.num)
    return _Sample(out^, FormulaValue.blank(), False)


def _mean(imm v: List[Float64]) -> Float64:
    var acc = 0.0
    for i in range(len(v)):
        acc += v[i]
    return acc / Float64(len(v))


def _sum_pow_dev(imm v: List[Float64], mu: Float64, p: Int) -> Float64:
    """`sum((v[i] - mu) ** p)` for p in {2, 3, 4}, by repeated multiplication.

    ⚠ NOT `**`. `docs`-level note from this repo's own measurement: Mojo's
    `**` on Float64 is not libm `pow` and an integral exponent through it is
    not guaranteed exact, which for a third central moment near zero is the
    difference between a small positive and a small negative SKEW."""
    var acc = 0.0
    for i in range(len(v)):
        var d = v[i] - mu
        var t = d * d
        if p == 3:
            t = t * d
        elif p == 4:
            t = t * t
        acc += t
    return acc


# =============================================================================
# ★ THE POPULATION / SAMPLE PAIR — the four names the refusal was scoped wrong
#   for, plus the two the plan door already served under a different reach.
# =============================================================================
def _variance(imm args: List[FormulaValue], sample: Bool) -> FormulaValue:
    """`VAR.S` (sample, /(n-1)) or `VAR.P` (population, /n).

    ⛔ THE DIVISOR IS THE WHOLE FUNCTION. Over `{2,4,4,4,5,5,7,9}` — the
    textbook sample Microsoft's own STDEV.P page uses — the population
    variance is 4 and the sample variance is 32/7 = 4.571. Both are positive,
    both are in the same units, and nothing but the number tells them apart.

    ⚠ THE `n < 2` ARM IS `#DIV/0!` FOR THE SAMPLE FORM AND FOR THE POPULATION
    FORM AT `n == 0`, which is what Excel answers — NOT `#NUM!` and not 0.
    `VAR.P(5)` is 0, a real answer; `VAR.S(5)` is `#DIV/0!` because the
    divisor n-1 is zero. A kernel sharing one guard between the two gets one
    of these wrong."""
    var s = _collect(args)
    if s.failed:
        return s.err.copy()
    var n = len(s.vals)
    var denom = Float64(n - 1) if sample else Float64(n)
    if denom <= 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    var mu = _mean(s.vals)
    return FormulaValue.number(_sum_pow_dev(s.vals, mu, 2) / denom)


def xl_var_p(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`VAR.P(number1, ...)` / `VARP(...)` — the POPULATION variance."""
    return _variance(args, False)


def xl_var_s(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`VAR.S(number1, ...)` / `VAR(...)` — the SAMPLE variance."""
    return _variance(args, True)


def xl_stdev_p(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`STDEV.P(number1, ...)` / `STDEVP(...)` — the POPULATION deviation."""
    var v = _variance(args, False)
    if v.is_error():
        return v^
    return FormulaValue.number(_sqrt(v.num))


def xl_stdev_s(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`STDEV.S(number1, ...)` / `STDEV(...)` — the SAMPLE deviation."""
    var v = _variance(args, True)
    if v.is_error():
        return v^
    return FormulaValue.number(_sqrt(v.num))


# =============================================================================
# ★ THE DEVIATION PAIR — one MEAN of absolute deviations, one SUM of squares.
# =============================================================================
def xl_avedev(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`AVEDEV(number1, ...)` — the MEAN of `|x - mean|`.

    ⚠ ABSOLUTE DEVIATION, NOT ROOT-MEAN-SQUARE. Over `{1,2,3}` AVEDEV is 2/3
    and the population STDEV is 0.8165; over a symmetric two-point sample they
    coincide, which is the blind input."""
    var s = _collect(args)
    if s.failed:
        return s.err.copy()
    var n = len(s.vals)
    if n == 0:
        return FormulaValue.error(XL_ERR_NUM)
    var mu = _mean(s.vals)
    var acc = 0.0
    for i in range(n):
        var d = s.vals[i] - mu
        acc += -d if d < 0.0 else d
    return FormulaValue.number(acc / Float64(n))


def xl_devsq(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DEVSQ(number1, ...)` — the SUM of squared deviations from the mean.

    ⚠ A SUM, NOT A MEAN. It is `VAR.P * n` and `VAR.S * (n-1)`, so a kernel
    that divided by anything at all returns a smaller plausible number. Over
    `{1,2,3}` DEVSQ is 2 where VAR.P is 2/3 and VAR.S is 1."""
    var s = _collect(args)
    if s.failed:
        return s.err.copy()
    var n = len(s.vals)
    if n == 0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(_sum_pow_dev(s.vals, _mean(s.vals), 2))


# =============================================================================
# ★ THE TWO NON-ARITHMETIC MEANS — both "an average", both between MIN and MAX.
# =============================================================================
def xl_geomean(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GEOMEAN(number1, ...)` — the nth root of the product.

    ⛔ `#NUM!` IF ANY VALUE IS <= 0, and that refusal is the function: a
    geometric mean of a set containing zero is zero and of one containing a
    negative is not real, so Excel refuses rather than answering either.
    ⚠ COMPUTED IN LOG SPACE. The direct product overflows at ~300 values of
    magnitude 10 and `FormulaValue.number` would then correctly refuse it as
    `#NUM!` — a REFUSAL WHERE EXCEL ANSWERS, which is the failure mode this
    effort cares about even though it is the safe direction."""
    var s = _collect(args)
    if s.failed:
        return s.err.copy()
    var n = len(s.vals)
    if n == 0:
        return FormulaValue.error(XL_ERR_NUM)
    var acc = 0.0
    for i in range(n):
        if s.vals[i] <= 0.0:
            return FormulaValue.error(XL_ERR_NUM)
        acc += external_call["log", Float64](s.vals[i])
    return FormulaValue.number(external_call["exp", Float64](acc / Float64(n)))


def xl_harmean(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`HARMEAN(number1, ...)` — `n / sum(1/x)`.

    ⛔ `#NUM!` IF ANY VALUE IS <= 0, the same refusal GEOMEAN makes and for a
    related reason: a zero makes the reciprocal sum infinite and a negative
    lets two terms cancel, producing a harmonic mean OUTSIDE the data range.
    ⚠ THE INEQUALITY IS STRICT AND IS THE DISCRIMINATOR: for any non-constant
    positive data HARMEAN < GEOMEAN < AVERAGE, so a fixture of equal values
    cannot tell the three apart at all."""
    var s = _collect(args)
    if s.failed:
        return s.err.copy()
    var n = len(s.vals)
    if n == 0:
        return FormulaValue.error(XL_ERR_NUM)
    var acc = 0.0
    for i in range(n):
        if s.vals[i] <= 0.0:
            return FormulaValue.error(XL_ERR_NUM)
        acc += 1.0 / s.vals[i]
    return FormulaValue.number(Float64(n) / acc)


# =============================================================================
# ★ THE SHAPE MOMENTS — the third and fourth, where the SCALING is the answer.
# =============================================================================
def xl_skew(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SKEW(number1, ...)` — the SAMPLE skewness, Excel's documented form:

        n/((n-1)(n-2)) * sum(((x - mean)/s)^3),   s = the SAMPLE stdev

    ⛔ `#DIV/0!` for `n < 3` or `s == 0`, which is Excel's answer and not
    `#NUM!` and not 0."""
    var s = _collect(args)
    if s.failed:
        return s.err.copy()
    var n = len(s.vals)
    if n < 3:
        return FormulaValue.error(XL_ERR_DIV0)
    var mu = _mean(s.vals)
    var sd = _sqrt(_sum_pow_dev(s.vals, mu, 2) / Float64(n - 1))
    if sd == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    var m3 = _sum_pow_dev(s.vals, mu, 3) / (sd * sd * sd)
    var nf = Float64(n)
    return FormulaValue.number(nf / (Float64(n - 1) * Float64(n - 2)) * m3)


def xl_skew_p(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SKEW.P(number1, ...)` — the POPULATION skewness:

        (1/n) * sum(((x - mean)/sigma)^3),   sigma = the POPULATION stdev

    ⛔ IT IS NOT `SKEW` WITH A DIFFERENT NAME AND IT IS NOT `SKEW` TIMES A
    CONSTANT A READER WOULD GUESS. Both the outer factor AND the deviation
    inside the cube change, so the ratio SKEW/SKEW.P is
    `sqrt(n(n-1))/(n-2)` — MEASURED 1.4907 at n=5, not 1, and never 1 for
    any n. A row wired to the sibling
    answers the same sign and the same order of magnitude.

    ⚠ `#DIV/0!` FOR `n < 3`, matching SKEW. Microsoft documents SKEW.P as
    requiring at least three points even though the population formula is
    defined at n=2; the refusal is the documented one, not the algebraic
    one."""
    var s = _collect(args)
    if s.failed:
        return s.err.copy()
    var n = len(s.vals)
    if n < 3:
        return FormulaValue.error(XL_ERR_DIV0)
    var mu = _mean(s.vals)
    var sg = _sqrt(_sum_pow_dev(s.vals, mu, 2) / Float64(n))
    if sg == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    var m3 = _sum_pow_dev(s.vals, mu, 3) / (sg * sg * sg)
    return FormulaValue.number(m3 / Float64(n))


def xl_kurt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`KURT(number1, ...)` — the EXCESS kurtosis, Excel's documented form:

        n(n+1)/((n-1)(n-2)(n-3)) * sum(((x-mean)/s)^4)
          - 3(n-1)^2/((n-2)(n-3))

    ⛔⛔ THE TRAILING SUBTRACTION IS WHY THIS IS NOT A FOURTH MOMENT, AND THE
    AMOUNT IT SUBTRACTS IS **NOT** THE TEXTBOOK 3. Excel's correction is
    `3(n-1)^2/((n-2)(n-3))`, which at n=5 is 8. MEASURED over {1,2,3,4,10}:
    this answers 3.152, a kernel that DROPPED the term answers 11.152, and one
    that subtracted the textbook 3 answers 8.152 — all three positive, all
    three a plausible kurtosis. `#DIV/0!` for `n < 4` or `s == 0`, which is
    Excel's answer."""
    var s = _collect(args)
    if s.failed:
        return s.err.copy()
    var n = len(s.vals)
    if n < 4:
        return FormulaValue.error(XL_ERR_DIV0)
    var mu = _mean(s.vals)
    var sd = _sqrt(_sum_pow_dev(s.vals, mu, 2) / Float64(n - 1))
    if sd == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    var s2 = sd * sd
    var m4 = _sum_pow_dev(s.vals, mu, 4) / (s2 * s2)
    var nf = Float64(n)
    var lead = nf * (nf + 1.0) / (
        Float64(n - 1) * Float64(n - 2) * Float64(n - 3)
    )
    var corr = 3.0 * Float64(n - 1) * Float64(n - 1) / (
        Float64(n - 2) * Float64(n - 3)
    )
    return FormulaValue.number(lead * m4 - corr)

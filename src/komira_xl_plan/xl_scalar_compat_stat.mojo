# =============================================================================
# xl_scalar_compat_stat.mojo — ★ THE PRE-2010 STATISTICAL SPELLINGS, AND THE
#                                ARGUMENT CONVENTIONS THAT MAKE THEM NOT
#                                ALIASES.
# =============================================================================
#
# ============ ⛔⛔ WHAT MICROSOFT CALLS "COMPATIBILITY" IS NOT "ALIAS" =======
#
#   OLD                 NEW                     HOW THEY DIFFER
#   ------------------- ----------------------- ---------------------------
#   CHIDIST(x,df)       CHISQ.DIST.RT           RIGHT tail. CHISQ.DIST is LEFT:
#                                               at (1,2) 0.6065 vs 0.3935.
#   CHIINV(p,df)        CHISQ.INV.RT            RIGHT-tail inverse. At (0.05,2)
#                                               5.9915 vs CHISQ.INV's 0.10259.
#   FDIST(x,d1,d2)      F.DIST.RT               RIGHT tail. At (3,2,2) 0.25 vs
#                                               F.DIST's 0.75.
#   FINV(p,d1,d2)       F.INV.RT                RIGHT-tail inverse. At (0.25,2,2)
#                                               3 vs F.INV's 1/3.
#   TDIST(x,df,tails)   T.DIST.RT / T.DIST.2T   A `tails` SELECTOR the modern
#                                               names do not have, AND `x < 0`
#                                               is #NUM! here where T.DIST
#                                               accepts it.
#   TINV(p,df)          T.INV.2T                TWO-TAILED. At (0.5,1) 1 vs
#                                               T.INV's 0.
#   BETADIST(x,a,b,A,B) BETA.DIST(x,a,b,cum,A,B) NO `cumulative` ARGUMENT, so
#                                               A and B sit at positions 4/5
#                                               where BETA.DIST has cum/A.
#   LOGNORMDIST(x,m,s)  LOGNORM.DIST(x,m,s,cum) CUMULATIVE ONLY — arity 3.
#   NEGBINOMDIST(f,s,p) NEGBINOM.DIST(f,s,p,cum) PROBABILITY MASS ONLY.
#   HYPGEOMDIST(...)    HYPGEOM.DIST(...,cum)   PROBABILITY MASS ONLY.
#   NORMSDIST(z)        NORM.S.DIST(z,cum)      CUMULATIVE ONLY — arity 1.
#
# (Eleven rows, and they are eleven NAMES — two of them, CHIINV and FINV, are
# the inverse halves of pairs already listed, so the number of DISTINCT
# conventions at issue is nine. The other THIRTEEN names ARE exact renames,
# and every one of them says so in its own docstring and carries
# `_compat_rename_note` in the census rather than an empty note — an empty
# note is indistinguishable from an unchecked one.)
#
# ============ ⚠ WHAT IS **NOT** HERE, AND WHY =============================
#
# The SEVEN Compatibility names that consume a RANGE — CHITEST COVAR FTEST
# PERCENTRANK QUARTILE TTEST ZTEST — are refused by NAME in
# `xl_absent_common_names()` with the measured blocker each one hits. They are
# not distributions with an awkward argument; they are aggregates, and the
# scalar `FormulaValue` lattice has no array member at all.
#
# Encapsulation rule : values only. No `UnsafePointer`, no wildcard
# origins, no `unsafe_from_address`.
# =============================================================================

from std.ffi import external_call
from std.math import floor, ceil, sqrt

from komira_core.plan.excel_error_code import XL_ERR_NUM, XL_ERR_VALUE

from .formula_value import FormulaValue
from .xl_stat_special import (
    betainc_reg,
    gamma_p,
    gamma_q,
    norm_pdf,
    norm_sdist,
    norm_sinv,
    xl_lgamma,
)


# Excel's own ceiling on a degrees-of-freedom argument, documented on CHIDIST,
# CHIINV, FDIST and FINV. ⚠ IT IS A REFUSAL AND NOT A CLAMP: a df of 1e11 is a
# user error, and clamping it would answer a question nobody asked.
comptime _DF_MAX: Float64 = 1.0e10
comptime _INT_EXACT_MAX: Float64 = 9007199254740992.0


def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` as a NUMBER, or the error that stops the call. Same
    contract as `xl_scalar_math._num` / `xl_scalar_numeric._num` /
    `xl_scalar_exact._num`, re-spelled for the same reason those three are.
    ⚠ IF THE DOMINANCE RULE EVER CHANGES, ALL FOUR CHANGE."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def _flag(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` as a LOGICAL — the `cumulative` selector. Excel coerces a
    NUMBER here (0 is FALSE, anything else TRUE), which is why this is
    `coerce_logical` and not a type test."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_logical()


def _trunc_toward_zero(x: Float64) -> Float64:
    return floor(x) if x >= 0.0 else ceil(x)


def _err_num() -> FormulaValue:
    return FormulaValue.error(XL_ERR_NUM)


# =============================================================================
# THE TWO INVERSE SEARCHES. Bisection over a MONOTONE regularized function.
#
# ⛔ BISECTION AND NOT NEWTON, DELIBERATELY. Newton on an incomplete-gamma tail
# leaves the bracket for a tiny derivative and returns a confident number from
# the wrong basin; bisection cannot, because it never leaves an interval whose
# endpoints straddle the answer. The cost is ~60 evaluations, which is nothing
# for a per-cell scalar call and is the reason this is not on a hot path.
# =============================================================================
comptime _BISECT_STEPS: Int = 200


def _invert_gamma_p(p: Float64, a: Float64) -> Float64:
    """The `x >= 0` with `gamma_p(a, x) == p`, for `0 < p < 1`, `a > 0`."""
    var hi = 1.0 if a < 1.0 else a
    for _i in range(_BISECT_STEPS):
        if gamma_p(a, hi) >= p:
            break
        hi *= 2.0
    var lo = 0.0
    for _i in range(_BISECT_STEPS):
        var mid = 0.5 * (lo + hi)
        if hi - lo <= 1.0e-15 * (1.0 + hi):
            break
        if gamma_p(a, mid) < p:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def _invert_gamma_q(q: Float64, a: Float64) -> Float64:
    """The `x >= 0` with `gamma_q(a, x) == q`, for `0 < q < 1`, `a > 0`.

    ⛔ NOT `_invert_gamma_p(1 - q, a)`, AND THE DIFFERENCE IS MEASURABLE. At
    `q = 1e-12` the complement `1 - q` rounds to 1.0 in Float64 and the search
    runs away to the bracket ceiling; inverting the tail that was ASKED FOR
    keeps every digit. `CHIINV` is a right-tail function and small right tails
    are its whole use."""
    var hi = 1.0 if a < 1.0 else a
    for _i in range(_BISECT_STEPS):
        if gamma_q(a, hi) <= q:
            break
        hi *= 2.0
    var lo = 0.0
    for _i in range(_BISECT_STEPS):
        var mid = 0.5 * (lo + hi)
        if hi - lo <= 1.0e-15 * (1.0 + hi):
            break
        if gamma_q(a, mid) > q:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def _invert_betainc(p: Float64, a: Float64, b: Float64) -> Float64:
    """The `x` in `[0, 1]` with `betainc_reg(a, b, x) == p`, for `0 <= p <= 1`."""
    var lo = 0.0
    var hi = 1.0
    for _i in range(_BISECT_STEPS):
        var mid = 0.5 * (lo + hi)
        if hi - lo <= 1.0e-16:
            break
        if betainc_reg(a, b, mid) < p:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


# =============================================================================
# ★ THE NORMAL FAMILY
# =============================================================================
def xl_normsdist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NORMSDIST(z)` — the STANDARD normal CUMULATIVE distribution.

    ⛔ ARITY 1, AND THAT IS THE DIVERGENCE FROM ITS REPLACEMENT.
    `NORM.S.DIST(z, cumulative)` takes TWO arguments and REFUSES one; this name
    takes exactly one and is ALWAYS cumulative. A row wired to a two-argument
    kernel would make `NORMSDIST(1)` an arity error — visible — but a row
    wired to the DENSITY would answer 0.2420 where the truth is 0.8413, which
    is not. The oracle grades the value."""
    var z = _num(args, 0)
    if z.is_error():
        return z^
    return FormulaValue.number(norm_sdist(z.num))


def xl_normsinv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NORMSINV(probability)` — the inverse of the standard normal CDF.

    ⚠ `p <= 0` OR `p >= 1` IS `#NUM!`, NOT an infinity. Both bounds are open:
    the answer at either is unbounded, and a kernel that returned `inf` would
    put a finite-looking Float64 into every aggregate above it."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    if p.num <= 0.0 or p.num >= 1.0:
        return _err_num()
    return FormulaValue.number(norm_sinv(p.num))


def xl_normdist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NORMDIST(x, mean, standard_dev, cumulative)` — the normal distribution.

    ⚠ THE FOURTH ARGUMENT SELECTS A DIFFERENT FUNCTION, not a display option:
    TRUE is the CDF and FALSE is the DENSITY. At `(1, 0, 1)` they are 0.8413
    and 0.2420. A kernel that ignored the flag answers one of them for both
    and passes any fixture that only ever asks for the cumulative form."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var s = _num(args, 2)
    if s.is_error():
        return s^
    var cum = _flag(args, 3)
    if cum.is_error():
        return cum^
    if s.num <= 0.0:
        return _err_num()
    var z = (x.num - m.num) / s.num
    if cum.logical:
        return FormulaValue.number(norm_sdist(z))
    return FormulaValue.number(norm_pdf(z) / s.num)


def xl_norminv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NORM.INV(probability, mean, standard_dev)` — the inverse normal CDF.
    `UPSTREAM_CATEGORY_DEFECTS`."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var s = _num(args, 2)
    if s.is_error():
        return s^
    if p.num <= 0.0 or p.num >= 1.0:
        return _err_num()
    if s.num <= 0.0:
        return _err_num()
    return FormulaValue.number(m.num + s.num * norm_sinv(p.num))


def xl_lognormdist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`LOGNORMDIST(x, mean, standard_dev)` — the CUMULATIVE lognormal.

    ⛔ ARITY 3 AND CUMULATIVE ONLY. `LOGNORM.DIST(x, mean, sd, cumulative)`
    added a fourth argument in 2010; this name has no density form at all. A
    row wired to the modern kernel with a defaulted flag answers the DENSITY
    whenever that default is FALSE — 0.1569 against 0.7559 at `(2, 0, 1)`.

    ⚠ `x <= 0` IS `#NUM!`: the lognormal has no mass at or below zero, and
    `log(0)` is `-inf`, which would travel."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var s = _num(args, 2)
    if s.is_error():
        return s^
    if x.num <= 0.0 or s.num <= 0.0:
        return _err_num()
    var ln = external_call["log", Float64](x.num)
    return FormulaValue.number(norm_sdist((ln - m.num) / s.num))


def xl_loginv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`LOGINV(probability, mean, standard_dev)` — the inverse of the
    cumulative lognormal, i.e. `exp(mean + sd * NORMSINV(p))`."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var s = _num(args, 2)
    if s.is_error():
        return s^
    if p.num <= 0.0 or p.num >= 1.0:
        return _err_num()
    if s.num <= 0.0:
        return _err_num()
    var z = m.num + s.num * norm_sinv(p.num)
    return FormulaValue.number(external_call["exp", Float64](z))


def xl_confidence(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CONFIDENCE(alpha, standard_dev, size)` — the half-width of the
    `1 - alpha` confidence interval for a population mean.

    ⚠ `NORMSINV(1 - alpha/2)`, NOT `NORMSINV(1 - alpha)`. The interval is
    TWO-SIDED, so alpha is split between the tails; the one-sided spelling
    answers 1.645 where the truth is 1.960 at alpha = 0.05 — a 16% narrower
    interval, and a number nobody looking at it would question. Its 2010
    replacement `CONFIDENCE.NORM` is an EXACT rename: same arguments, same
    order, same answer at every input."""
    var al = _num(args, 0)
    if al.is_error():
        return al^
    var sd = _num(args, 1)
    if sd.is_error():
        return sd^
    var n = _num(args, 2)
    if n.is_error():
        return n^
    if al.num <= 0.0 or al.num >= 1.0:
        return _err_num()
    if sd.num <= 0.0:
        return _err_num()
    var nt = _trunc_toward_zero(n.num)
    if nt < 1.0:
        return _err_num()
    return FormulaValue.number(
        norm_sinv(1.0 - al.num * 0.5) * sd.num / sqrt(nt)
    )


# =============================================================================
# ★ THE CONTINUOUS DISTRIBUTIONS WITH A `cumulative` FLAG
# =============================================================================
def xl_expondist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`EXPONDIST(x, lambda, cumulative)` — the exponential distribution.
    An EXACT rename to `EXPON.DIST`: same three arguments in the same order.
    ⚠ `lambda` IS A RATE, NOT A MEAN — the cumulative form is
    `1 - exp(-lambda*x)`, so a kernel that read it as a mean answers
    `1 - exp(-x/lambda)` and agrees with this one at exactly `lambda = 1`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var lam = _num(args, 1)
    if lam.is_error():
        return lam^
    var cum = _flag(args, 2)
    if cum.is_error():
        return cum^
    if x.num < 0.0 or lam.num <= 0.0:
        return _err_num()
    var e = external_call["exp", Float64](-lam.num * x.num)
    if cum.logical:
        return FormulaValue.number(1.0 - e)
    return FormulaValue.number(lam.num * e)


def xl_weibull(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`WEIBULL(x, alpha, beta, cumulative)` — the Weibull distribution.
    An EXACT rename to `WEIBULL.DIST`.

    ⚠ `alpha` IS THE SHAPE AND `beta` THE SCALE, and at `alpha = 1` the
    Weibull IS the exponential — so a fixture confined to `alpha = 1` cannot
    tell a correct kernel from one that ignores the shape entirely. The oracle
    grades at `alpha = 2`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    var cum = _flag(args, 3)
    if cum.is_error():
        return cum^
    if x.num < 0.0 or al.num <= 0.0 or be.num <= 0.0:
        return _err_num()
    var r = x.num / be.num
    var pw = external_call["pow", Float64](r, al.num)
    var e = external_call["exp", Float64](-pw)
    if cum.logical:
        return FormulaValue.number(1.0 - e)
    if x.num == 0.0 and al.num < 1.0:
        return _err_num()
    var pwm = external_call["pow", Float64](r, al.num - 1.0)
    return FormulaValue.number(al.num / be.num * pwm * e)


def xl_gammadist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GAMMADIST(x, alpha, beta, cumulative)` — the gamma distribution.
    An EXACT rename to `GAMMA.DIST`.

    ⚠ `beta` IS THE SCALE, NOT THE RATE. The cumulative form is
    `gamma_p(alpha, x/beta)`; the rate parameterisation would be
    `gamma_p(alpha, x*beta)`, and the two agree for every `beta = 1` fixture."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    var cum = _flag(args, 3)
    if cum.is_error():
        return cum^
    if x.num < 0.0 or al.num <= 0.0 or be.num <= 0.0:
        return _err_num()
    if cum.logical:
        return FormulaValue.number(gamma_p(al.num, x.num / be.num))
    if x.num == 0.0:
        if al.num < 1.0:
            return _err_num()
        if al.num == 1.0:
            return FormulaValue.number(1.0 / be.num)
        return FormulaValue.number(0.0)
    var t = x.num / be.num
    var lg = (al.num - 1.0) * external_call["log", Float64](t) - t \
        - xl_lgamma(al.num) - external_call["log", Float64](be.num)
    return FormulaValue.number(external_call["exp", Float64](lg))


def xl_gammainv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GAMMAINV(probability, alpha, beta)` — the inverse gamma CDF.
    An EXACT rename to `GAMMA.INV`."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    if al.num <= 0.0 or be.num <= 0.0:
        return _err_num()
    if p.num < 0.0 or p.num >= 1.0:
        return _err_num()
    if p.num == 0.0:
        return FormulaValue.number(0.0)
    return FormulaValue.number(be.num * _invert_gamma_p(p.num, al.num))


# =============================================================================
# ★ THE RIGHT-TAIL FAMILY — ⛔ THE FOUR NAMES THIS WHOLE SLICE IS ABOUT
# =============================================================================
def xl_chidist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHIDIST(x, deg_freedom)` — the **RIGHT-TAILED** chi-square probability.

    ⛔⛔ ITS 2010 REPLACEMENT IS `CHISQ.DIST.RT`, **NOT** `CHISQ.DIST`, and the
    two differ by the complement at every input. `CHIDIST(1, 2)` is
    `exp(-0.5) = 0.6065306597126334`; `CHISQ.DIST(1, 2, TRUE)` is
    `0.3934693402873666`. Both are probabilities, both are in range, both look
    like a chi-square answer, and a p-value read off the wrong one inverts
    every conclusion drawn from it. This is the exemplar the effort brief
    names — an alias that is subtly wrong is a silent wrong answer.

    ⚠ `deg_freedom` IS TRUNCATED and must be in `[1, 1e10]`; `x < 0` is
    `#NUM!`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var d = _trunc_toward_zero(df.num)
    if x.num < 0.0 or d < 1.0 or d > _DF_MAX:
        return _err_num()
    return FormulaValue.number(gamma_q(d * 0.5, x.num * 0.5))


def xl_chiinv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHIINV(probability, deg_freedom)` — the inverse of the **RIGHT-TAILED**
    chi-square probability, i.e. the `x` with `CHIDIST(x, df) == probability`.

    ⛔ ITS REPLACEMENT IS `CHISQ.INV.RT`. `CHIINV(0.05, 2)` is
    `-2*ln(0.05) = 5.991464547107982` — the familiar 5% critical value — where
    the LEFT-tail `CHISQ.INV(0.05, 2)` is `-2*ln(0.95) = 0.10258658877510106`.
    A critical value off by a factor of 58 is not a rounding difference."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var d = _trunc_toward_zero(df.num)
    if p.num <= 0.0 or p.num > 1.0 or d < 1.0 or d > _DF_MAX:
        return _err_num()
    if p.num == 1.0:
        return FormulaValue.number(0.0)
    return FormulaValue.number(2.0 * _invert_gamma_q(p.num, d * 0.5))


def xl_fdist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FDIST(x, deg_freedom1, deg_freedom2)` — the **RIGHT-TAILED** F
    probability.

    ⛔ ITS REPLACEMENT IS `F.DIST.RT`, NOT `F.DIST`. `FDIST(3, 2, 2)` is
    `1/(1+3) = 0.25`; `F.DIST(3, 2, 2, TRUE)` is 0.75. And `F.DIST` takes a
    FOURTH argument this name does not have, so a naive re-point is an arity
    error at the door and a wrong number after somebody "fixes" it."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var d1v = _num(args, 1)
    if d1v.is_error():
        return d1v^
    var d2v = _num(args, 2)
    if d2v.is_error():
        return d2v^
    var d1 = _trunc_toward_zero(d1v.num)
    var d2 = _trunc_toward_zero(d2v.num)
    if x.num < 0.0:
        return _err_num()
    if d1 < 1.0 or d1 > _DF_MAX or d2 < 1.0 or d2 > _DF_MAX:
        return _err_num()
    var z = d2 / (d2 + d1 * x.num)
    return FormulaValue.number(betainc_reg(d2 * 0.5, d1 * 0.5, z))


def xl_finv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FINV(probability, deg_freedom1, deg_freedom2)` — the inverse of the
    **RIGHT-TAILED** F probability. Replacement: `F.INV.RT`.

    `FINV(0.25, 2, 2)` is 3 where the left-tail `F.INV(0.25, 2, 2)` is 1/3 —
    reciprocals of each other, which is the most plausible-looking wrong
    answer a critical value can have."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var d1v = _num(args, 1)
    if d1v.is_error():
        return d1v^
    var d2v = _num(args, 2)
    if d2v.is_error():
        return d2v^
    var d1 = _trunc_toward_zero(d1v.num)
    var d2 = _trunc_toward_zero(d2v.num)
    if p.num <= 0.0 or p.num > 1.0:
        return _err_num()
    if d1 < 1.0 or d1 > _DF_MAX or d2 < 1.0 or d2 > _DF_MAX:
        return _err_num()
    if p.num == 1.0:
        return FormulaValue.number(0.0)
    var z = _invert_betainc(p.num, d2 * 0.5, d1 * 0.5)
    if z <= 0.0:
        return _err_num()
    return FormulaValue.number(d2 * (1.0 - z) / (d1 * z))


def xl_tdist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TDIST(x, deg_freedom, tails)` — the Student's-t probability, with a
    `tails` SELECTOR: 1 is the right tail, 2 is both tails.

    ⛔⛔ THREE DIVERGENCES FROM THE MODERN SPELLINGS, AND EVERY ONE OF THEM
    RETURNS A NUMBER:
      * `T.DIST(x, df, TRUE)` is the LEFT tail. `TDIST(1, 1, 1)` is 0.25;
        `T.DIST(1, 1, TRUE)` is 0.75.
      * the `tails` argument doubles the answer. `TDIST(1, 1, 2)` is 0.5 —
        exactly twice the one-tail value — so a kernel that ignored the
        selector is wrong by a factor of two, in range, every time.
      * ⚠ `x < 0` IS `#NUM!` HERE. Excel's TDIST refuses a negative x and the
        2010 `T.DIST` accepts it, so a re-pointed row turns a documented
        REFUSAL into a confident probability."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var tl = _num(args, 2)
    if tl.is_error():
        return tl^
    var d = _trunc_toward_zero(df.num)
    var t = _trunc_toward_zero(tl.num)
    if x.num < 0.0 or d < 1.0:
        return _err_num()
    if t != 1.0 and t != 2.0:
        return _err_num()
    var z = d / (d + x.num * x.num)
    var right = 0.5 * betainc_reg(d * 0.5, 0.5, z)
    if t == 2.0:
        return FormulaValue.number(2.0 * right)
    return FormulaValue.number(right)


def xl_tinv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TINV(probability, deg_freedom)` — the **TWO-TAILED** inverse t.

    ⛔ ITS REPLACEMENT IS `T.INV.2T`, NOT `T.INV`. `TINV(0.5, 1)` is
    `tan(pi/4) = 1`; the one-tailed `T.INV(0.5, 1)` is **0**, because the
    median of a symmetric distribution is its centre. A `t` critical value of
    0 passes every significance test ever run against it."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var d = _trunc_toward_zero(df.num)
    if p.num <= 0.0 or p.num > 1.0 or d < 1.0:
        return _err_num()
    if p.num == 1.0:
        return FormulaValue.number(0.0)
    var z = _invert_betainc(p.num, d * 0.5, 0.5)
    if z <= 0.0:
        return _err_num()
    return FormulaValue.number(sqrt(d * (1.0 - z) / z))


# =============================================================================
# ★ THE BETA PAIR — the ARGUMENT-POSITION divergence
# =============================================================================
def _beta_bounds(imm args: List[FormulaValue], lo_i: Int, hi_i: Int) \
        -> List[Float64]:
    """`[A, B]` from the OPTIONAL bound arguments, defaulting to `[0, 1]`.
    Returns an empty list when a bound argument is an error or non-numeric —
    the caller then propagates."""
    var out = List[Float64]()
    var a = 0.0
    var b = 1.0
    if len(args) > lo_i:
        var av = _num(args, lo_i)
        if av.is_error():
            return out^
        a = av.num
    if len(args) > hi_i:
        var bv = _num(args, hi_i)
        if bv.is_error():
            return out^
        b = bv.num
    out.append(a)
    out.append(b)
    return out^


def xl_betadist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BETADIST(x, alpha, beta, [A], [B])` — the CUMULATIVE beta distribution
    over `[A, B]`, `A` defaulting to 0 and `B` to 1.

    ⛔⛔ THE POSITIONS ARE THE DIVERGENCE, AND IT IS THE WORST KIND. The 2010
    replacement is `BETA.DIST(x, alpha, beta, cumulative, [A], [B])` — it
    INSERTED a `cumulative` argument at position 4, where this name has `A`.
    So `BETADIST(2, 1, 1, 1, 3)`, which is `(2-1)/(3-1) = 0.5`, reads under the
    modern signature as `cumulative = 1 (TRUE)` with `A = 3` — a completely
    different call. A row wired to `BETA.DIST` does not fail: it answers
    something.

    ⚠ AND THERE IS NO DENSITY FORM. `BETADIST` is cumulative by definition."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    var bounds = _beta_bounds(args, 3, 4)
    if len(bounds) != 2:
        return FormulaValue.error(XL_ERR_VALUE)
    var lo = bounds[0]
    var hi = bounds[1]
    if al.num <= 0.0 or be.num <= 0.0:
        return _err_num()
    if hi <= lo:
        return _err_num()
    if x.num < lo or x.num > hi:
        return _err_num()
    return FormulaValue.number(
        betainc_reg(al.num, be.num, (x.num - lo) / (hi - lo))
    )


def xl_betainv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BETAINV(probability, alpha, beta, [A], [B])` — the inverse of
    `BETADIST`. An EXACT rename to `BETA.INV`: the modern spelling did NOT
    gain a `cumulative` argument (an inverse has no density form to select),
    so this one pair keeps its positions. ⭐ SAYING SO IS THE POINT — the
    reader must not generalise `BETADIST`'s shift onto its inverse."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    var bounds = _beta_bounds(args, 3, 4)
    if len(bounds) != 2:
        return FormulaValue.error(XL_ERR_VALUE)
    var lo = bounds[0]
    var hi = bounds[1]
    if al.num <= 0.0 or be.num <= 0.0:
        return _err_num()
    if hi <= lo:
        return _err_num()
    if p.num <= 0.0 or p.num > 1.0:
        return _err_num()
    var z = _invert_betainc(p.num, al.num, be.num)
    return FormulaValue.number(lo + (hi - lo) * z)


# =============================================================================
# ★ THE DISCRETE FAMILY
# =============================================================================
def _log_choose(n: Float64, k: Float64) -> Float64:
    """`log C(n, k)` through `lgamma`. ⚠ NOT a product loop: `C(1000, 500)` is
    2.7e299 and a loop that forms the numerator first overflows to `inf` while
    the ANSWER is representable."""
    return xl_lgamma(n + 1.0) - xl_lgamma(k + 1.0) - xl_lgamma(n - k + 1.0)


def _binom_cdf(k: Float64, n: Float64, p: Float64) -> Float64:
    """`P(X <= k)` for `Binomial(n, p)`, over `0 <= k <= n` and `0 <= p <= 1`.

    ⚠ ONE SPELLING, SHARED BY `BINOMDIST`'s cumulative arm AND `CRITBINOM`'s
    search, because the two must agree BY CONSTRUCTION: `CRITBINOM` is defined
    as the smallest `k` whose `BINOMDIST` cumulative reaches `alpha`, and two
    copies of that cumulative would let the definition drift into an
    off-by-one that only shows up at a boundary alpha."""
    if k >= n:
        return 1.0
    if p == 0.0:
        return 1.0
    if p == 1.0:
        return 0.0
    return betainc_reg(n - k, k + 1.0, 1.0 - p)


def xl_binomdist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BINOMDIST(number_s, trials, probability_s, cumulative)` — the binomial.
    An EXACT rename to `BINOM.DIST`.

    ⚠ THE CUMULATIVE ARM IS `I_{1-p}(n-k, k+1)`, not a summation loop — the
    identity is exact and `n` may be 1e6. At `(2, 5, 0.5)` the two arms are
    0.3125 and 0.5, which is the pair the oracle grades."""
    var kv = _num(args, 0)
    if kv.is_error():
        return kv^
    var nv = _num(args, 1)
    if nv.is_error():
        return nv^
    var pv = _num(args, 2)
    if pv.is_error():
        return pv^
    var cum = _flag(args, 3)
    if cum.is_error():
        return cum^
    var k = _trunc_toward_zero(kv.num)
    var n = _trunc_toward_zero(nv.num)
    if k < 0.0 or k > n or n > _INT_EXACT_MAX:
        return _err_num()
    if pv.num < 0.0 or pv.num > 1.0:
        return _err_num()
    var p = pv.num
    if cum.logical:
        return FormulaValue.number(_binom_cdf(k, n, p))
    if p == 0.0:
        return FormulaValue.number(1.0 if k == 0.0 else 0.0)
    if p == 1.0:
        return FormulaValue.number(1.0 if k == n else 0.0)
    var lg = _log_choose(n, k) \
        + k * external_call["log", Float64](p) \
        + (n - k) * external_call["log", Float64](1.0 - p)
    return FormulaValue.number(external_call["exp", Float64](lg))


def xl_negbinomdist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NEGBINOMDIST(number_f, number_s, probability_s)` — the probability of
    exactly `number_f` failures before the `number_s`-th success.

    ⛔ PROBABILITY MASS ONLY, ARITY 3. `NEGBINOM.DIST` added a `cumulative`
    fourth argument in 2010. At `(2, 3, 0.5)` the mass is
    `C(4,2)/32 = 0.1875` and the cumulative is 0.6875 — a wrong answer that is
    still a probability, still monotone in its arguments, and larger by 3.7x.

    ⚠ `number_s < 1` IS `#NUM!`: zero successes is not a waiting time."""
    var fv = _num(args, 0)
    if fv.is_error():
        return fv^
    var sv = _num(args, 1)
    if sv.is_error():
        return sv^
    var pv = _num(args, 2)
    if pv.is_error():
        return pv^
    var f = _trunc_toward_zero(fv.num)
    var s = _trunc_toward_zero(sv.num)
    if f < 0.0 or s < 1.0:
        return _err_num()
    if pv.num <= 0.0 or pv.num > 1.0:
        return _err_num()
    var lg = _log_choose(f + s - 1.0, f) \
        + s * external_call["log", Float64](pv.num)
    if f > 0.0:
        if pv.num >= 1.0:
            return FormulaValue.number(0.0)
        lg += f * external_call["log", Float64](1.0 - pv.num)
    return FormulaValue.number(external_call["exp", Float64](lg))


def xl_hypgeomdist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`HYPGEOMDIST(sample_s, number_sample, population_s, number_pop)` — the
    hypergeometric probability MASS.

    ⛔ MASS ONLY, ARITY 4. `HYPGEOM.DIST` added a `cumulative` fifth argument.
    `HYPGEOMDIST(1, 4, 8, 20)` is `C(8,1)C(12,3)/C(20,4) = 1760/4845`.

    ⚠ THE FEASIBILITY BOUNDS ARE TWO-SIDED AND BOTH ARE `#NUM!`: a sample
    cannot contain more successes than it has draws OR than the population
    holds, and it cannot contain FEWER than `n - (N - M)` when the failures
    run out. A kernel that only checked the upper bound returns a NEGATIVE
    binomial coefficient's exponential — a positive number — for the lower
    one."""
    var xv = _num(args, 0)
    if xv.is_error():
        return xv^
    var nv = _num(args, 1)
    if nv.is_error():
        return nv^
    var mv = _num(args, 2)
    if mv.is_error():
        return mv^
    var bigv = _num(args, 3)
    if bigv.is_error():
        return bigv^
    var x = _trunc_toward_zero(xv.num)
    var n = _trunc_toward_zero(nv.num)
    var m = _trunc_toward_zero(mv.num)
    var big = _trunc_toward_zero(bigv.num)
    if big <= 0.0 or big > _INT_EXACT_MAX:
        return _err_num()
    if n <= 0.0 or n > big or m <= 0.0 or m > big:
        return _err_num()
    if x < 0.0 or x > n or x > m:
        return _err_num()
    var floor_k = n - (big - m)
    if x < floor_k:
        return _err_num()
    var lg = _log_choose(m, x) + _log_choose(big - m, n - x) \
        - _log_choose(big, n)
    return FormulaValue.number(external_call["exp", Float64](lg))


def xl_poisson(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`POISSON(x, mean, cumulative)` — the Poisson distribution.
    An EXACT rename to `POISSON.DIST`.

    ⚠ THE CUMULATIVE ARM IS `gamma_q(x+1, mean)`, the closed form, not a
    summation — `mean` may be 1e6 and the loop would be the runtime. At
    `(2, 3)` the two arms are `4.5*exp(-3)` and `8.5*exp(-3)`."""
    var xv = _num(args, 0)
    if xv.is_error():
        return xv^
    var mv = _num(args, 1)
    if mv.is_error():
        return mv^
    var cum = _flag(args, 2)
    if cum.is_error():
        return cum^
    var k = _trunc_toward_zero(xv.num)
    if k < 0.0 or mv.num < 0.0:
        return _err_num()
    var lam = mv.num
    if cum.logical:
        if lam == 0.0:
            return FormulaValue.number(1.0)
        return FormulaValue.number(gamma_q(k + 1.0, lam))
    if lam == 0.0:
        return FormulaValue.number(1.0 if k == 0.0 else 0.0)
    var lg = -lam + k * external_call["log", Float64](lam) \
        - xl_lgamma(k + 1.0)
    return FormulaValue.number(external_call["exp", Float64](lg))


def xl_critbinom(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CRITBINOM(trials, probability_s, alpha)` — the SMALLEST `k` whose
    cumulative binomial is at least `alpha`. An EXACT rename to `BINOM.INV`.

    ⚠ `>=`, NOT `>`. At `(10, 0.5, 0.5)` the cumulative reaches exactly
    0.623046875 at k=5 and 0.376953125 at k=4, so the boundary is not
    exercised there; at an alpha that lands ON a cumulative value the two
    comparisons differ by one whole trial.

    ⛔⛔ THE SEARCH IS A BISECTION AND IT USED TO BE A LINEAR SCAN, WHICH WAS A
    HANG RATHER THAN A REFUSAL. Each step costs one REGULARIZED INCOMPLETE BETA
    evaluation — a continued fraction of ~60 iterations — so a scan from 0 over
    `CRITBINOM(1000000, 0.5, 0.5)`, a perfectly legal Excel call, is ~1e8
    inner steps ON A PER-CELL PATH. Found by reading the kernel back after it
    was green; no cell in the value oracle reaches it, which is exactly why a
    green sweep is not a substitute for reading the code.

    ⚠ AND THE BACK-WALK IS NOT BELT-AND-BRACES. A bisection returns SOME `k`
    satisfying the predicate only if the predicate is monotone, and
    `betainc_reg` is monotone in exact arithmetic and merely NEARLY monotone in
    Float64 — across a plateau two adjacent `k` can compare the wrong way by an
    ulp. The bounded walk backward restores *the FIRST such k*, which is what
    the function is defined as. It is capped so that a pathological wobble
    cannot turn the repair into the linear scan it replaced."""
    var nv = _num(args, 0)
    if nv.is_error():
        return nv^
    var pv = _num(args, 1)
    if pv.is_error():
        return pv^
    var av = _num(args, 2)
    if av.is_error():
        return av^
    var n = _trunc_toward_zero(nv.num)
    if n < 0.0 or n > _INT_EXACT_MAX:
        return _err_num()
    if pv.num < 0.0 or pv.num > 1.0:
        return _err_num()
    if av.num < 0.0 or av.num > 1.0:
        return _err_num()
    var p = pv.num
    var alpha = av.num
    var lo = 0
    var hi = Int(n)
    while lo < hi:
        var mid = lo + (hi - lo) // 2
        if _binom_cdf(Float64(mid), n, p) >= alpha:
            hi = mid
        else:
            lo = mid + 1
    var k = lo
    var back = 0
    while k > 0 and back < 64:
        if _binom_cdf(Float64(k - 1), n, p) < alpha:
            break
        k -= 1
        back += 1
    return FormulaValue.number(Float64(k))

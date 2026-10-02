# =============================================================================
# xl_scalar_stat.mojo — ★ THE EXCEL STATISTICAL DISTRIBUTION FAMILY.
#                          FORTY-ONE NAMES OVER FIVE PRIMITIVES.
# =============================================================================
#
# ======= ⭐ WHY THIS IS ONE SLICE AND NOT FORTY-ONE ==========================
#
#   CHISQ.*  -> gamma_p(df/2, x/2)          POISSON.DIST -> gamma_q(k+1, mu)
#   GAMMA.*  -> gamma_p(alpha, x/beta)      EXPON.DIST   -> elementary
#   T.*      -> betai(df/2, 1/2, df/(df+t2))
#   F.*      -> betai(d2/2, d1/2, d2/(d2+d1 x))
#   BETA.*   -> betai(alpha, beta, (x-A)/(B-A))
#   BINOM/NEGBINOM -> betai            HYPGEOM -> lgamma
#
# ⇒ The primitives are in `xl_special_fn.mojo`, separately, so they can be
# graded as MATHEMATICS against published tables. This file is graded as
# SPREADSHEET BEHAVIOUR: argument order, the `cumulative` flag, and the domain
# refusals.
#
# ======= ⛔⛔ THE NAMED VACUITY, AND WHERE IT BITES HARDEST ==================
#
# *A registry row wired to the WRONG KERNEL still answers, so it is not
# `#NAME?`, so a recognition cell passes.* This family is the worst case in the
# whole Excel surface for it, because **the wrong answer is still a
# probability**. Every one of these near-neighbours returns a number in [0,1]:
#
#   CHISQ.DIST      <-> CHISQ.DIST.RT     one is 1 minus the other
#   CHISQ.INV       <-> CHISQ.INV.RT      likewise
#   F.INV           <-> F.INV.RT          likewise
#   T.DIST.RT       <-> T.DIST.2T         differ by EXACTLY A FACTOR OF 2
#   T.INV           <-> T.INV.2T          likewise, in the argument
#   NORM.S.DIST(z,TRUE) <-> (z,FALSE)     the cumulative flag ignored
#   PHI             <-> GAUSS             density vs CDF-minus-a-half
#   GAMMALN         <-> LN                GAMMALN(4)=1.7918, LN(4)=1.3863
#   GAMMA           <-> FACT              agree at every integer, differ at 2.5
#   PERMUT          <-> COMBIN            PERMUT(5,2)=20, COMBIN(5,2)=10
#   PERMUTATIONA    <-> PERMUT            PERMUTATIONA(3,2)=9, PERMUT(3,2)=6
#   CONFIDENCE.NORM <-> CONFIDENCE.T      agree asymptotically in n
#
# ======= ⚠ THE `.DIST`/`.INV` PAIRS ARE GRADED AGAINST PUBLISHED VALUES =====
#
# An inverse implemented by bisection over its own forward function agrees with
# itself and diverges from Excel. The inverse cells in the oracle carry
# PUBLISHED statistical-table values — CHISQ.INV.RT(0.05,10) = 18.30703805,
# T.INV.2T(0.05,10) = 2.228138852, F.INV.RT(0.01,6,4) = 15.20686 — and a round
# trip is a SECONDARY check, labelled as one.
#
# ======= ⚠ WHAT IS **NOT** HERE, AND THE PRIMITIVE THAT IS MISSING ==========
#
# The Excel statistical RANGE functions — LARGE, SMALL, PERCENTILE.*,
# QUARTILE.*, PERCENTRANK.*, RANK.*, TRIMMEAN, MODE.MULT, FREQUENCY,
# CORREL/COVARIANCE/SLOPE/INTERCEPT/RSQ/STEYX/LINEST/TREND — every one takes an
# **ARRAY** argument. `FormulaValue` has FIVE kinds (BLANK / NUMBER / TEXT /
# LOGICAL / ERROR) and no array kind, and no C entry point binds a range to a
# scalar argument, so `LARGE(array, k)` CANNOT BE SPELLED on the scalar door at
# all. That is a missing PRIMITIVE and not a missing kernel; refusing those
# names by name is the honest census entry, and it is what the absence list
# now says.
#
# Encapsulation rule : values only. No `UnsafePointer`, no wildcard
# origins, no `unsafe_from_address`.
# =============================================================================

from std.ffi import external_call
from std.math import floor, ceil, sqrt

from komira_core.plan.excel_error_code import (
    XL_ERR_DIV0,
    XL_ERR_NA,
    XL_ERR_NUM,
)

from .formula_value import FormulaValue
from .xl_special_fn import (
    betai,
    betai_inv,
    gamma_p,
    gamma_p_inv,
    gamma_q,
    norm_s_cdf,
    norm_s_inv,
    norm_s_pdf,
    xs_exp,
    xs_lgamma,
    xs_log,
    xs_pow,
)


comptime _INT_EXACT_MAX: Float64 = 9007199254740992.0
"""`2**53`. Past it an "integer" argument is already a rounded one."""


def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` as a NUMBER, or the error that stops the call. Same
    contract as `xl_scalar_math._num` / `xl_scalar_numeric._num` /
    `xl_scalar_exact._num`, re-spelled for the same reason those three are: a
    cross-module import of a private helper is the edge that makes a "kernels
    only" module stop being one. ⚠ IF THE DOMINANCE RULE EVER CHANGES, ALL
    FOUR CHANGE."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def _flag(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` as a LOGICAL — the `cumulative` switch every `.DIST` in
    this family carries.

    ⚠ IT COERCES, AND EXCEL DOES TOO. `NORM.DIST(x, m, s, 1)` is the
    cumulative form in Excel: a non-zero NUMBER is TRUE. A kernel that
    accepted only a LOGICAL would refuse the spelling most sheets use."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_logical()


def _trunc_toward_zero(x: Float64) -> Float64:
    """The integer part, TOWARD ZERO. ⚠ NOT `floor`."""
    return floor(x) if x >= 0.0 else ceil(x)


def _err_num() -> FormulaValue:
    return FormulaValue.error(XL_ERR_NUM)


# =============================================================================
# ★ THE GAMMA FUNCTION ITSELF — and the twin is FACT
# =============================================================================
def xl_gammaln(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GAMMALN(x)` — the natural log of the gamma function, ln Γ(x).

    ⛔ THE TWIN IS `LN`, ALREADY REGISTERED IN THIS TREE, and the two are the
    same SHAPE of function — one positive argument, one refusal at zero — so a
    mis-wired row answers a plausible number for every input. They separate at
    the very first integer: `GAMMALN(4)` is 1.791759469 (= ln 3! = ln 6) and
    `LN(4)` is 1.386294361.

    ⚠ `x <= 0` IS `#NUM!`. Γ has poles at 0 and every negative integer, and
    libm's `lgamma` returns `+inf` there and a FINITE number between the poles
    (where Γ is negative and its log is not real). Excel refuses the whole
    non-positive half-line; so does this."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num <= 0.0:
        return _err_num()
    return FormulaValue.number(xs_lgamma(x.num))


def xl_gammaln_precise(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GAMMALN.PRECISE(x)` — the Excel-2010 respelling of `GAMMALN`.

    ⚠ THE SAME NUMBER, DELIBERATELY, AND THE CENSUS SAYS SO RATHER THAN
    IMPLYING A DISCRIMINATION THERE IS NOT. Microsoft introduced the `.PRECISE`
    spelling for consistency with `CEILING.PRECISE` / `FLOOR.PRECISE`, where
    the suffix DOES change behaviour; here it does not, and the legacy
    `GAMMALN` is documented as retained for compatibility only. A kernel that
    invented a difference would be wrong in a way no fixture would catch."""
    return xl_gammaln(args)


def xl_gamma_fn(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GAMMA(x)` — Γ(x) itself.

    ⛔ THE TWIN IS `FACT`, AND THEY AGREE AT EVERY POSITIVE INTEGER: Γ(n) =
    (n-1)!, so `GAMMA(5)` = 24 = `FACT(4)`, and a fixture of integers cannot
    tell a shifted-factorial kernel from this one. They separate at a
    NON-integer: `GAMMA(2.5)` is 1.329340388 where `FACT` truncates its
    argument to 2 and answers 2.

    ⚠ ZERO AND THE NEGATIVE INTEGERS ARE `#NUM!` (the poles). ⚠ NEGATIVE
    NON-INTEGERS ARE **DEFINED** and this serves them — `GAMMA(-1.5)` is
    2.363271801 — via the reflection formula, because `lgamma` can only give
    the magnitude and the sign alternates."""
    var xv = _num(args, 0)
    if xv.is_error():
        return xv^
    var x = xv.num
    if x > 0.0:
        if x > 171.61:
            return _err_num()
        return FormulaValue.number(xs_exp(xs_lgamma(x)))
    # x <= 0: the poles are the non-positive integers.
    if x == floor(x):
        return _err_num()
    # Reflection: Γ(x)·Γ(1-x) = π / sin(πx). ⚠ THE SIGN IS THE WHOLE REASON
    # this is not `exp(lgamma(x))`: lgamma gives log|Γ| and Γ alternates sign
    # on the negative axis, so the exponential alone is always positive.
    var pi_v: Float64 = 3.141592653589793
    var s = _sin_pi(x)
    if s == 0.0:
        return _err_num()
    return FormulaValue.number(pi_v / (s * xs_exp(xs_lgamma(1.0 - x))))


def _sin_pi(x: Float64) -> Float64:
    """sin(πx), argument-reduced so the reflection formula keeps its digits at
    large negative x. ⚠ A DIRECT `sin(pi*x)` LOSES THE ARGUMENT: `pi*x` for x
    near -170 rounds away the fractional part that is the entire answer."""
    var r = x - 2.0 * floor(x / 2.0)  # x mod 2, in [0, 2)
    var pi_v: Float64 = 3.141592653589793
    if r > 1.0:
        return -_sin_small(pi_v * (r - 1.0))
    return _sin_small(pi_v * r)


def _sin_small(t: Float64) -> Float64:
    """sin(t) for t in [0, π] via libm. ⚠ `sin` IS **NOT** IMPORTED FROM
    `std.math` IN THIS FILE, DELIBERATELY: an `external_call` of a spelling the
    same TU also imports from `std.math` is a hard build error (a second declaration of the same libm
    symbol conflicts in attributes)."""
    return external_call["sin", Float64](t)


# =============================================================================
# ★ THE STANDARD NORMAL — four names, and the flag is the discriminator
# =============================================================================
def xl_norm_s_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NORM.S.DIST(z, cumulative)` — the STANDARD normal, mean 0 and sd 1.

    ⛔ THE TWIN IS ITS OWN OTHER ARM: a kernel that ignored the flag answers
    `NORM.S.DIST(0, FALSE)` = 0.5 instead of 0.3989422804."""
    var z = _num(args, 0)
    if z.is_error():
        return z^
    var c = _flag(args, 1)
    if c.is_error():
        return c^
    if c.logical:
        return FormulaValue.number(norm_s_cdf(z.num))
    return FormulaValue.number(norm_s_pdf(z.num))


def xl_norm_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NORM.DIST(x, mean, standard_dev, cumulative)`.

    ⚠ `standard_dev <= 0` IS `#NUM!` — including EXACTLY ZERO, which a
    divide-first kernel turns into `inf`/`NaN` and then into a plausible 0 or
    1. Excel refuses; so does this.

    ⚠ THE DENSITY ARM DIVIDES BY sd. `NORM.DIST(x, m, s, FALSE)` is
    φ((x-m)/s)/s, NOT φ((x-m)/s): dropping the Jacobian gives a curve that
    integrates to s instead of 1, and at sd=1 — the only place a lazy fixture
    looks — the two are identical."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var s = _num(args, 2)
    if s.is_error():
        return s^
    var c = _flag(args, 3)
    if c.is_error():
        return c^
    if s.num <= 0.0:
        return _err_num()
    var z = (x.num - m.num) / s.num
    if c.logical:
        return FormulaValue.number(norm_s_cdf(z))
    return FormulaValue.number(norm_s_pdf(z) / s.num)


def xl_norm_s_inv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NORM.S.INV(probability)` — Φ⁻¹, the standard normal quantile.

    ⚠ THE OPEN INTERVAL. `p <= 0` and `p >= 1` are `#NUM!`; the answers are
    ∓∞ and Excel refuses rather than returning an infinity that keeps
    travelling. ⚠ `p = 0.5` IS EXACTLY 0 and is the one input a constant-zero
    kernel survives, so the oracle grades 0.975 and 0.001."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    if p.num <= 0.0 or p.num >= 1.0:
        return _err_num()
    return FormulaValue.number(norm_s_inv(p.num))


def xl_norm_inv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NORM.INV(probability, mean, standard_dev)`.

    ⚠ NOTE THE ARGUMENT ORDER AGAINST `NORM.DIST`: the probability comes
    FIRST here and the value comes first there. A kernel that shared an
    argument-unpacking helper with `NORM.DIST` would read mean as the
    probability and still answer a number."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var s = _num(args, 2)
    if s.is_error():
        return s^
    if s.num <= 0.0:
        return _err_num()
    if p.num <= 0.0 or p.num >= 1.0:
        return _err_num()
    return FormulaValue.number(m.num + s.num * norm_s_inv(p.num))


def xl_phi(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PHI(x)` — the standard normal DENSITY.

    ⛔ THE TWIN IS `GAUSS`, its sibling in the same Excel-2013 pair, and both
    return a number in (0, 0.4) for a positive argument. `PHI(0.75)` is
    0.3011374 and `GAUSS(0.75)` is 0.2733726."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    return FormulaValue.number(norm_s_pdf(x.num))


def xl_gauss(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GAUSS(z)` — `NORM.S.DIST(z, TRUE) - 0.5`, the probability a standard
    normal lies between 0 and z.

    ⛔ THE TWIN IS `NORM.S.DIST(z, TRUE)` ITSELF: forgetting the `- 0.5` gives
    0.9772 for `GAUSS(2)` where Excel says 0.4772. Both are probabilities."""
    var z = _num(args, 0)
    if z.is_error():
        return z^
    return FormulaValue.number(norm_s_cdf(z.num) - 0.5)


# =============================================================================
# ★ LOGNORMAL
# =============================================================================
def xl_lognorm_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`LOGNORM.DIST(x, mean, standard_dev, cumulative)`.

    ⚠ `mean` AND `standard_dev` ARE THOSE OF ln(x), NOT OF x. A kernel that
    standardised x directly would be computing `NORM.DIST`, which is exactly
    the near-neighbour: at x=4, mean=3.5, sd=1.2 Excel says 0.0390836 and
    `NORM.DIST(4,3.5,1.2,TRUE)` says 0.6615.

    ⚠ `x <= 0` IS `#NUM!` (the support is the positive half-line), and the
    density arm carries the 1/x Jacobian."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var s = _num(args, 2)
    if s.is_error():
        return s^
    var c = _flag(args, 3)
    if c.is_error():
        return c^
    if s.num <= 0.0 or x.num <= 0.0:
        return _err_num()
    var z = (xs_log(x.num) - m.num) / s.num
    if c.logical:
        return FormulaValue.number(norm_s_cdf(z))
    return FormulaValue.number(norm_s_pdf(z) / (x.num * s.num))


def xl_lognorm_inv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`LOGNORM.INV(probability, mean, standard_dev)` — `EXP(NORM.INV(p,m,s))`.

    ⛔ THE TWIN IS `NORM.INV`: dropping the exponential answers 1.3866 where
    Excel says 4.0000252 for (0.039084, 3.5, 1.2). Both are numbers."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var s = _num(args, 2)
    if s.is_error():
        return s^
    if s.num <= 0.0:
        return _err_num()
    if p.num <= 0.0 or p.num >= 1.0:
        return _err_num()
    return FormulaValue.number(xs_exp(m.num + s.num * norm_s_inv(p.num)))


def xl_standardize(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`STANDARDIZE(x, mean, standard_dev)` — the z-score.

    ⚠ `standard_dev <= 0` IS `#NUM!`, INCLUDING ZERO — where the obvious
    spelling divides and returns `inf`, a finite-looking Float64 that travels
    through every comparison above it."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var s = _num(args, 2)
    if s.is_error():
        return s^
    if s.num <= 0.0:
        return _err_num()
    return FormulaValue.number((x.num - m.num) / s.num)


# =============================================================================
# ★ FISHER'S z — a matched inverse pair with an EXACT closed form, so it is
#   the one `.INV` in this file whose round trip IS a legitimate grading.
# =============================================================================
def xl_fisher(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FISHER(x)` — the Fisher transformation, `0.5·ln((1+x)/(1-x))`, i.e.
    `atanh(x)`.

    ⚠ THE DOMAIN IS THE **OPEN** INTERVAL: `|x| >= 1` is `#NUM!`. At exactly
    ±1 the argument of the log is 0 or ∞, and C's `log` answers -inf / inf
    rather than refusing."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if x.num <= -1.0 or x.num >= 1.0:
        return _err_num()
    return FormulaValue.number(0.5 * xs_log((1.0 + x.num) / (1.0 - x.num)))


def xl_fisherinv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FISHERINV(y)` — `(e^{2y} - 1)/(e^{2y} + 1)`, i.e. `tanh(y)`.

    ⚠ NO DOMAIN REFUSAL — the whole real line maps into (-1, 1). A kernel that
    copied `FISHER`'s |x|<1 guard would refuse `FISHERINV(2)`, which Excel
    answers 0.96402758."""
    var y = _num(args, 0)
    if y.is_error():
        return y^
    var e2 = xs_exp(2.0 * y.num)
    return FormulaValue.number((e2 - 1.0) / (e2 + 1.0))


# =============================================================================
# ★ COUNTING — and both twins are already registered in this tree
# =============================================================================
def xl_permut(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PERMUT(number, number_chosen)` — n!/(n-k)!, ORDERED selections without
    repetition.

    ⛔ THE TWIN IS `COMBIN`, WHICH IS ALREADY REGISTERED: `PERMUT(5,2)` is 20
    and `COMBIN(5,2)` is 10. They agree at k=0 and k=1, which is where a thin
    fixture looks.

    ⚠ ARGUMENTS ARE TRUNCATED, and `n < 0`, `k < 0` or `k > n` is `#NUM!`."""
    var nv = _num(args, 0)
    if nv.is_error():
        return nv^
    var kv = _num(args, 1)
    if kv.is_error():
        return kv^
    var n = _trunc_toward_zero(nv.num)
    var k = _trunc_toward_zero(kv.num)
    if n < 0.0 or k < 0.0 or k > n or n > _INT_EXACT_MAX:
        return _err_num()
    var acc: Float64 = 1.0
    var i: Float64 = 0.0
    while i < k:
        acc *= n - i
        i += 1.0
    return FormulaValue.number(acc)


def xl_permutationa(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PERMUTATIONA(number, number_chosen)` — n^k, ordered selections WITH
    repetition.

    ⛔ THE TWIN IS `PERMUT`: `PERMUTATIONA(3,2)` is 9 and `PERMUT(3,2)` is 6.
    ⚠ AND `k > n` IS LEGAL HERE where `PERMUT` refuses it — `PERMUTATIONA(2,3)`
    is 8 — which is the second discriminator and the one a numeric-only
    fixture misses entirely."""
    var nv = _num(args, 0)
    if nv.is_error():
        return nv^
    var kv = _num(args, 1)
    if kv.is_error():
        return kv^
    var n = _trunc_toward_zero(nv.num)
    var k = _trunc_toward_zero(kv.num)
    if n < 0.0 or k < 0.0:
        return _err_num()
    if n == 0.0 and k == 0.0:
        return FormulaValue.number(1.0)
    return FormulaValue.number(xs_pow(n, k))


# =============================================================================
# ★ THE GAMMA-FAMILY CONTINUOUS DISTRIBUTIONS
# =============================================================================
def xl_expon_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`EXPON.DIST(x, lambda, cumulative)`.

    ⚠ `lambda` IS THE RATE, NOT THE MEAN. Excel's parameter is λ, so
    `EXPON.DIST(0.2, 10, TRUE)` is `1 - e^{-2}` = 0.8646647; a mean-parameter
    kernel would answer 1 - e^{-0.02} = 0.0198.

    ⚠ THE DENSITY ARM IS λe^{-λx}, WHICH EXCEEDS 1: `EXPON.DIST(0.2,10,FALSE)`
    is 1.3533528. A kernel that clamped to a probability would be wrong and
    would look safe."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var lam = _num(args, 1)
    if lam.is_error():
        return lam^
    var c = _flag(args, 2)
    if c.is_error():
        return c^
    if x.num < 0.0 or lam.num <= 0.0:
        return _err_num()
    var e = xs_exp(-lam.num * x.num)
    if c.logical:
        return FormulaValue.number(1.0 - e)
    return FormulaValue.number(lam.num * e)


def xl_weibull_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`WEIBULL.DIST(x, alpha, beta, cumulative)` — shape α, scale β.

    ⚠ ARGUMENT ORDER IS SHAPE THEN SCALE, which is the reverse of several
    libraries' convention; swapped, `WEIBULL.DIST(105,20,100,TRUE)` answers
    1.0 instead of 0.9295813."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    var c = _flag(args, 3)
    if c.is_error():
        return c^
    if x.num < 0.0 or al.num <= 0.0 or be.num <= 0.0:
        return _err_num()
    var t = xs_pow(x.num / be.num, al.num)
    if c.logical:
        return FormulaValue.number(1.0 - xs_exp(-t))
    if x.num == 0.0 and al.num < 1.0:
        return _err_num()
    return FormulaValue.number(
        al.num / xs_pow(be.num, al.num)
        * xs_pow(x.num, al.num - 1.0) * xs_exp(-t)
    )


def xl_gamma_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GAMMA.DIST(x, alpha, beta, cumulative)` — shape α, SCALE β.

    ⚠ β IS A SCALE, NOT A RATE. `GAMMA.DIST(10.00001131, 9, 2, TRUE)` is
    0.068094; a rate-parameter kernel (which divides where this multiplies)
    answers 1.0 to nine digits — a number nothing in a range check rejects."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    var c = _flag(args, 3)
    if c.is_error():
        return c^
    if x.num < 0.0 or al.num <= 0.0 or be.num <= 0.0:
        return _err_num()
    var t = x.num / be.num
    if c.logical:
        return FormulaValue.number(gamma_p(al.num, t))
    if x.num == 0.0:
        if al.num < 1.0:
            return _err_num()
        if al.num == 1.0:
            return FormulaValue.number(1.0 / be.num)
        return FormulaValue.number(0.0)
    return FormulaValue.number(
        xs_exp((al.num - 1.0) * xs_log(t) - t - xs_lgamma(al.num)) / be.num
    )


def xl_gamma_inv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`GAMMA.INV(probability, alpha, beta)`.

    ⚠ GRADED AGAINST A PUBLISHED VALUE, NOT A ROUND TRIP: with α=9, β=2 this
    is the chi-square with 18 degrees of freedom, whose published median is
    17.33790. A round trip against this file's own `GAMMA.DIST` would agree
    with a wrong `GAMMA.DIST`."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    if p.num < 0.0 or p.num >= 1.0 or al.num <= 0.0 or be.num <= 0.0:
        return _err_num()
    if p.num == 0.0:
        return FormulaValue.number(0.0)
    return FormulaValue.number(be.num * gamma_p_inv(al.num, p.num))


def xl_chisq_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHISQ.DIST(x, deg_freedom, cumulative)` — the **LEFT**-tailed χ².

    ⛔ THE TWIN IS `CHISQ.DIST.RT`, WHICH IS ONE MINUS THIS, and both are
    probabilities. `CHISQ.DIST(0.5, 1, TRUE)` is 0.5204999 and
    `CHISQ.DIST.RT(0.5, 1)` is 0.4795001 — near enough to each other at this
    input that a fixture with one cell and a loose tolerance would pass either
    way, which is why the oracle also grades df=10 at x=18.307."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var c = _flag(args, 2)
    if c.is_error():
        return c^
    var k = _trunc_toward_zero(df.num)
    if x.num < 0.0 or k < 1.0 or k > 1e10:
        return _err_num()
    if c.logical:
        return FormulaValue.number(gamma_p(k / 2.0, x.num / 2.0))
    if x.num == 0.0:
        if k < 2.0:
            return _err_num()
        if k == 2.0:
            return FormulaValue.number(0.5)
        return FormulaValue.number(0.0)
    var a = k / 2.0
    return FormulaValue.number(
        xs_exp((a - 1.0) * xs_log(x.num / 2.0) - x.num / 2.0 - xs_lgamma(a)) / 2.0
    )


def xl_chisq_dist_rt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHISQ.DIST.RT(x, deg_freedom)` — the **RIGHT**-tailed χ², arity 2 and
    no `cumulative` argument (it is always cumulative).

    ⭐ COMPUTED AS `gamma_q`, NOT AS `1 - gamma_p`. In the far right tail the
    subtraction returns exactly 0.0 where the true value is ~1e-17, and a
    p-value of 0 is the single most consequential wrong answer this family can
    produce."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var k = _trunc_toward_zero(df.num)
    if x.num < 0.0 or k < 1.0 or k > 1e10:
        return _err_num()
    return FormulaValue.number(gamma_q(k / 2.0, x.num / 2.0))


def xl_chisq_inv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHISQ.INV(probability, deg_freedom)` — the LEFT-tailed quantile.

    ⚠ PUBLISHED GRADING: `CHISQ.INV(0.93, 1)` = 3.283020. ⛔ THE TWIN IS
    `CHISQ.INV.RT`, and at p = 0.5 with df = 1 the two differ by a factor of
    ~4.3 — but both are positive numbers of the right magnitude."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var k = _trunc_toward_zero(df.num)
    if p.num < 0.0 or p.num >= 1.0 or k < 1.0 or k > 1e10:
        return _err_num()
    if p.num == 0.0:
        return FormulaValue.number(0.0)
    return FormulaValue.number(2.0 * gamma_p_inv(k / 2.0, p.num))


def xl_chisq_inv_rt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHISQ.INV.RT(probability, deg_freedom)` — the RIGHT-tailed quantile,
    the one every published χ² table prints.

    ⚠ PUBLISHED GRADING: `CHISQ.INV.RT(0.05, 10)` = 18.30703805327515, the
    0.05 column of the standard table at 10 df. Measured here:
    18.307038053275143 (rel 3.9e-16)."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var k = _trunc_toward_zero(df.num)
    if p.num <= 0.0 or p.num > 1.0 or k < 1.0 or k > 1e10:
        return _err_num()
    if p.num == 1.0:
        return FormulaValue.number(0.0)
    return FormulaValue.number(2.0 * gamma_p_inv(k / 2.0, 1.0 - p.num))


def xl_poisson_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`POISSON.DIST(x, mean, cumulative)`.

    ⭐ THE CUMULATIVE ARM IS `gamma_q(k+1, mu)`, NOT A SUM OF TERMS. The
    identity is exact and the sum loses the far tail; more practically, a
    summation kernel is O(k) and Excel's `POISSON.DIST(1e6, 1e6, TRUE)` is a
    single call here.

    ⚠ `x` IS TRUNCATED and a NEGATIVE `x` or `mean` is `#NUM!`."""
    var xv = _num(args, 0)
    if xv.is_error():
        return xv^
    var mu = _num(args, 1)
    if mu.is_error():
        return mu^
    var c = _flag(args, 2)
    if c.is_error():
        return c^
    var k = _trunc_toward_zero(xv.num)
    if k < 0.0 or mu.num < 0.0:
        return _err_num()
    if c.logical:
        if mu.num == 0.0:
            return FormulaValue.number(1.0)
        return FormulaValue.number(gamma_q(k + 1.0, mu.num))
    if mu.num == 0.0:
        return FormulaValue.number(1.0 if k == 0.0 else 0.0)
    return FormulaValue.number(
        xs_exp(-mu.num + k * xs_log(mu.num) - xs_lgamma(k + 1.0))
    )


# =============================================================================
# ★ THE BETA-FAMILY: BETA, STUDENT'S t AND F
# =============================================================================
def xl_beta_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BETA.DIST(x, alpha, beta, cumulative, [A], [B])` — arity 4..6.

    ⚠ `A` AND `B` RESCALE THE SUPPORT and default to 0 and 1. Excel's own
    documented example is `BETA.DIST(2, 8, 10, TRUE, 1, 3)` = 0.6854706, which
    is `I_{0.5}(8,10)` — a kernel that ignored A and B would evaluate at x=2,
    outside [0,1], and answer 1.

    ⚠ `x < A` or `x > B` is `#NUM!`, and so is `A >= B`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    var c = _flag(args, 3)
    if c.is_error():
        return c^
    var lo: Float64 = 0.0
    var hi: Float64 = 1.0
    if len(args) >= 5:
        var lv = _num(args, 4)
        if lv.is_error():
            return lv^
        lo = lv.num
    if len(args) >= 6:
        var hv = _num(args, 5)
        if hv.is_error():
            return hv^
        hi = hv.num
    if al.num <= 0.0 or be.num <= 0.0 or lo >= hi:
        return _err_num()
    if x.num < lo or x.num > hi:
        return _err_num()
    var t = (x.num - lo) / (hi - lo)
    if c.logical:
        return FormulaValue.number(betai(al.num, be.num, t))
    if t <= 0.0 or t >= 1.0:
        return FormulaValue.number(0.0)
    # ⚠ THE DENSITY CARRIES THE 1/(B-A) JACOBIAN. Excel's example
    # BETA.DIST(2,8,10,FALSE,1,3) is 1.4837646, which is the unit-interval
    # density 2.9675 HALVED — dropping it doubles the answer.
    return FormulaValue.number(
        xs_exp(
            xs_lgamma(al.num + be.num) - xs_lgamma(al.num) - xs_lgamma(be.num)
            + (al.num - 1.0) * xs_log(t) + (be.num - 1.0) * xs_log(1.0 - t)
        ) / (hi - lo)
    )


def xl_beta_inv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BETA.INV(probability, alpha, beta, [A], [B])` — arity 3..5.

    ⚠ PUBLISHED GRADING: Excel's own example round-trips its `BETA.DIST` one —
    `BETA.INV(0.685470581, 8, 10, 1, 3)` = 2 — and that IS a published pair, so
    it is graded as a value rather than as a self-consistency check."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var al = _num(args, 1)
    if al.is_error():
        return al^
    var be = _num(args, 2)
    if be.is_error():
        return be^
    var lo: Float64 = 0.0
    var hi: Float64 = 1.0
    if len(args) >= 4:
        var lv = _num(args, 3)
        if lv.is_error():
            return lv^
        lo = lv.num
    if len(args) >= 5:
        var hv = _num(args, 4)
        if hv.is_error():
            return hv^
        hi = hv.num
    if al.num <= 0.0 or be.num <= 0.0 or lo >= hi:
        return _err_num()
    if p.num <= 0.0 or p.num > 1.0:
        return _err_num()
    return FormulaValue.number(lo + (hi - lo) * betai_inv(al.num, be.num, p.num))


def _t_cdf(t: Float64, df: Float64) -> Float64:
    """The LEFT-tailed Student's t CDF, via `betai`.

    ⚠ THE HALF-SPLIT IS WHAT MAKES IT CORRECT FOR NEGATIVE t: the incomplete
    beta gives the TWO-tailed mass `I_{df/(df+t²)}(df/2, 1/2)`, which is even
    in t, so the sign has to be put back by hand."""
    var xb = df / (df + t * t)
    var two_tail = betai(df / 2.0, 0.5, xb)
    if t >= 0.0:
        return 1.0 - 0.5 * two_tail
    return 0.5 * two_tail


def xl_t_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`T.DIST(x, deg_freedom, cumulative)` — the **LEFT**-tailed Student's t.

    ⛔ THE FAMILY HAS THREE `.DIST` SPELLINGS AND THEY ARE ALL DIFFERENT
    NUMBERS: left-tail (this), right-tail, and two-tail. At x=1.812461, df=10
    they are 0.95, 0.05 and 0.10 — and `T.DIST.2T` is EXACTLY twice
    `T.DIST.RT` for positive x, so a wiring swap between those two is a factor
    of 2 that looks like a tolerance problem.

    ⚠ `x` MAY BE NEGATIVE HERE and `T.DIST.2T` refuses a negative — the one
    domain difference inside the family."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var c = _flag(args, 2)
    if c.is_error():
        return c^
    var k = _trunc_toward_zero(df.num)
    if k < 1.0:
        return _err_num()
    if c.logical:
        return FormulaValue.number(_t_cdf(x.num, k))
    return FormulaValue.number(
        xs_exp(
            xs_lgamma((k + 1.0) / 2.0) - xs_lgamma(k / 2.0)
            - 0.5 * xs_log(k * 3.141592653589793)
            - ((k + 1.0) / 2.0) * xs_log(1.0 + x.num * x.num / k)
        )
    )


def xl_t_dist_rt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`T.DIST.RT(x, deg_freedom)` — the RIGHT tail, arity 2.

    ⚠ A NEGATIVE `x` IS LEGAL and gives a value ABOVE 0.5: `T.DIST.RT(-1, 10)`
    is 0.8296. A kernel that took `|x|` — the obvious way to reuse the
    two-tailed form — answers 0.1704 and is wrong on exactly half the line."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var k = _trunc_toward_zero(df.num)
    if k < 1.0:
        return _err_num()
    return FormulaValue.number(1.0 - _t_cdf(x.num, k))


def xl_t_dist_2t(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`T.DIST.2T(x, deg_freedom)` — the TWO-tailed mass, arity 2.

    ⛔ `x < 0` IS `#NUM!` — the one refusal that separates this name from
    `T.DIST.RT`, which accepts the whole line. A kernel sharing RT's body
    would answer 1.83 for `T.DIST.2T(-1, 10)`: a "probability" above 1."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var k = _trunc_toward_zero(df.num)
    if k < 1.0 or x.num < 0.0:
        return _err_num()
    return FormulaValue.number(betai(k / 2.0, 0.5, k / (k + x.num * x.num)))


def xl_t_inv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`T.INV(probability, deg_freedom)` — the LEFT-tailed t quantile.

    ⚠ PUBLISHED GRADING: `T.INV(0.75, 2)` = 0.8164966 (Microsoft's own
    documented example). ⚠ AND IT IS SIGNED — `T.INV(0.25, 2)` is
    -0.8164966 — where `T.INV.2T` is always positive."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var k = _trunc_toward_zero(df.num)
    if k < 1.0 or p.num <= 0.0 or p.num >= 1.0:
        return _err_num()
    if p.num == 0.5:
        return FormulaValue.number(0.0)
    var tail = 2.0 * (p.num if p.num < 0.5 else 1.0 - p.num)
    var xb = betai_inv(k / 2.0, 0.5, tail)
    var t = sqrt(k * (1.0 - xb) / xb)
    if p.num < 0.5:
        return FormulaValue.number(-t)
    return FormulaValue.number(t)


def xl_t_inv_2t(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`T.INV.2T(probability, deg_freedom)` — the TWO-tailed t quantile, the
    one every published t-table prints.

    ⚠ PUBLISHED GRADING: `T.INV.2T(0.05, 10)` = 2.228138852, the 95% row of
    the standard table at 10 df. Measured here: 2.228138851986275.

    ⛔ `probability` IS THE TOTAL TAIL MASS, so it maps to the 1-p/2 quantile,
    NOT the 1-p one. Off by that factor, `T.INV.2T(0.05,10)` answers 1.812461
    — the 0.05 RIGHT-tail value, which is a real entry in the same table."""
    var p = _num(args, 0)
    if p.is_error():
        return p^
    var df = _num(args, 1)
    if df.is_error():
        return df^
    var k = _trunc_toward_zero(df.num)
    if k < 1.0 or p.num <= 0.0 or p.num > 1.0:
        return _err_num()
    if p.num == 1.0:
        return FormulaValue.number(0.0)
    var xb = betai_inv(k / 2.0, 0.5, p.num)
    return FormulaValue.number(sqrt(k * (1.0 - xb) / xb))


def _f_sf(x: Float64, d1: Float64, d2: Float64) -> Float64:
    """The RIGHT-tail of the F distribution, `I_{d2/(d2+d1x)}(d2/2, d1/2)`."""
    if x <= 0.0:
        return 1.0
    return betai(d2 / 2.0, d1 / 2.0, d2 / (d2 + d1 * x))


def xl_f_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`F.DIST(x, deg_freedom1, deg_freedom2, cumulative)` — LEFT-tailed.

    ⚠ THE TWO df ARE NOT INTERCHANGEABLE. `F.DIST(15.2069, 6, 4, TRUE)` is
    0.99 and with the df swapped it is 0.9791 — both plausible, and equal only
    when d1 == d2."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var d1v = _num(args, 1)
    if d1v.is_error():
        return d1v^
    var d2v = _num(args, 2)
    if d2v.is_error():
        return d2v^
    var c = _flag(args, 3)
    if c.is_error():
        return c^
    var d1 = _trunc_toward_zero(d1v.num)
    var d2 = _trunc_toward_zero(d2v.num)
    if x.num < 0.0 or d1 < 1.0 or d2 < 1.0 or d1 > 1e10 or d2 > 1e10:
        return _err_num()
    if c.logical:
        return FormulaValue.number(1.0 - _f_sf(x.num, d1, d2))
    if x.num == 0.0:
        if d1 < 2.0:
            return _err_num()
        if d1 == 2.0:
            return FormulaValue.number(1.0)
        return FormulaValue.number(0.0)
    var lg = (
        xs_lgamma((d1 + d2) / 2.0) - xs_lgamma(d1 / 2.0) - xs_lgamma(d2 / 2.0)
        + (d1 / 2.0) * xs_log(d1 / d2)
        + (d1 / 2.0 - 1.0) * xs_log(x.num)
        - ((d1 + d2) / 2.0) * xs_log(1.0 + d1 * x.num / d2)
    )
    return FormulaValue.number(xs_exp(lg))


def xl_f_dist_rt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`F.DIST.RT(x, deg_freedom1, deg_freedom2)` — RIGHT-tailed, arity 3, no
    `cumulative` argument.

    ⚠ PUBLISHED GRADING: `F.DIST.RT(15.20686, 6, 4)` = 0.01, Microsoft's own
    documented example and the complement of `F.DIST`'s."""
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
    if x.num < 0.0 or d1 < 1.0 or d2 < 1.0 or d1 > 1e10 or d2 > 1e10:
        return _err_num()
    return FormulaValue.number(_f_sf(x.num, d1, d2))


def xl_f_inv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`F.INV(probability, deg_freedom1, deg_freedom2)` — LEFT-tailed.

    ⚠ PUBLISHED GRADING: `F.INV(0.01, 6, 4)` = 0.10903, which is the
    RECIPROCAL of `F.INV.RT(0.01, 4, 6)`'s 9.148 — the relationship that makes
    a df-swap AND a tail-swap look consistent with each other."""
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
    if p.num < 0.0 or p.num > 1.0 or d1 < 1.0 or d2 < 1.0:
        return _err_num()
    if p.num == 0.0:
        return FormulaValue.number(0.0)
    var xb = betai_inv(d2 / 2.0, d1 / 2.0, 1.0 - p.num)
    if xb <= 0.0:
        return _err_num()
    return FormulaValue.number(d2 * (1.0 - xb) / (d1 * xb))


def xl_f_inv_rt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`F.INV.RT(probability, deg_freedom1, deg_freedom2)` — RIGHT-tailed, the
    one every published F-table prints.

    ⚠ PUBLISHED GRADING: `F.INV.RT(0.01, 6, 4)` = 15.20686 (Microsoft's own
    example). Measured here: 15.206864861."""
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
    if p.num < 0.0 or p.num > 1.0 or d1 < 1.0 or d2 < 1.0:
        return _err_num()
    if p.num == 1.0:
        return FormulaValue.number(0.0)
    var xb = betai_inv(d2 / 2.0, d1 / 2.0, p.num)
    if xb <= 0.0:
        return _err_num()
    return FormulaValue.number(d2 * (1.0 - xb) / (d1 * xb))


# =============================================================================
# ★ THE DISCRETE DISTRIBUTIONS
# =============================================================================
def _binom_pmf(k: Float64, n: Float64, p: Float64) -> Float64:
    """C(n,k) p^k (1-p)^{n-k}, computed in LOG SPACE.
    same call is exact to the last few ulps."""
    if p <= 0.0:
        return 1.0 if k == 0.0 else 0.0
    if p >= 1.0:
        return 1.0 if k == n else 0.0
    return xs_exp(
        xs_lgamma(n + 1.0) - xs_lgamma(k + 1.0) - xs_lgamma(n - k + 1.0)
        + k * xs_log(p) + (n - k) * xs_log(1.0 - p)
    )


def _binom_cdf(k: Float64, n: Float64, p: Float64) -> Float64:
    """P(X <= k) for Binomial(n,p), as `betai(n-k, k+1, 1-p)`.

    ⭐ THE CLOSED FORM, NOT A LOOP. A summation kernel over k terms is O(k) and
    loses the tail; the incomplete-beta identity is exact and O(1)."""
    if k < 0.0:
        return 0.0
    if k >= n:
        return 1.0
    return betai(n - k, k + 1.0, 1.0 - p)


def xl_binom_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BINOM.DIST(number_s, trials, probability_s, cumulative)`.

    ⚠ ARGUMENT ORDER IS SUCCESSES THEN TRIALS. Swapped, `BINOM.DIST(6,10,0.5,
    FALSE)` becomes `BINOM.DIST(10,6,…)` which is `#NUM!` — so the swap is
    caught here — but `BINOM.DIST(3,6,0.5,FALSE)` swapped is a legal call
    returning a different number, which is not.

    ⚠ `number_s > trials`, `number_s < 0` and `p` outside [0,1] are `#NUM!`."""
    var kv = _num(args, 0)
    if kv.is_error():
        return kv^
    var nv = _num(args, 1)
    if nv.is_error():
        return nv^
    var pv = _num(args, 2)
    if pv.is_error():
        return pv^
    var c = _flag(args, 3)
    if c.is_error():
        return c^
    var k = _trunc_toward_zero(kv.num)
    var n = _trunc_toward_zero(nv.num)
    if k < 0.0 or k > n or pv.num < 0.0 or pv.num > 1.0:
        return _err_num()
    if c.logical:
        return FormulaValue.number(_binom_cdf(k, n, pv.num))
    return FormulaValue.number(_binom_pmf(k, n, pv.num))


def xl_binom_dist_range(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BINOM.DIST.RANGE(trials, probability_s, number_s, [number_s2])` — the
    probability of between `number_s` and `number_s2` successes.

    ⛔ THE ARGUMENT ORDER IS THE REVERSE OF `BINOM.DIST`'s: TRIALS FIRST here,
    successes first there. A shared unpacking helper reads `trials` as
    `number_s` and answers a plausible probability.

    ⚠ WITH `number_s2` OMITTED IT IS THE POINT MASS at `number_s`, i.e.
    `BINOM.DIST(…, FALSE)` — not a cumulative."""
    var nv = _num(args, 0)
    if nv.is_error():
        return nv^
    var pv = _num(args, 1)
    if pv.is_error():
        return pv^
    var k1v = _num(args, 2)
    if k1v.is_error():
        return k1v^
    var n = _trunc_toward_zero(nv.num)
    var k1 = _trunc_toward_zero(k1v.num)
    if n < 0.0 or pv.num < 0.0 or pv.num > 1.0 or k1 < 0.0 or k1 > n:
        return _err_num()
    if len(args) < 4:
        return FormulaValue.number(_binom_pmf(k1, n, pv.num))
    var k2v = _num(args, 3)
    if k2v.is_error():
        return k2v^
    var k2 = _trunc_toward_zero(k2v.num)
    if k2 < k1 or k2 > n:
        return _err_num()
    return FormulaValue.number(
        _binom_cdf(k2, n, pv.num) - _binom_cdf(k1 - 1.0, n, pv.num)
    )


def xl_binom_inv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BINOM.INV(trials, probability_s, alpha)` — the SMALLEST k whose
    cumulative binomial is >= alpha.

    ⚠ IT RETURNS AN INTEGER, and the ">=" is the whole definition: Excel's own
    example `BINOM.INV(6, 0.5, 0.75)` is 4, and a kernel using strict ">"
    answers 4 as well at that input but differs wherever the CDF hits alpha
    exactly. ⚠ A LINEAR SCAN IS CORRECT AND IS WHAT EXCEL DOES."""
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
    if n < 0.0 or pv.num < 0.0 or pv.num > 1.0:
        return _err_num()
    if av.num <= 0.0 or av.num >= 1.0:
        return _err_num()
    var k: Float64 = 0.0
    while k < n:
        if _binom_cdf(k, n, pv.num) >= av.num:
            return FormulaValue.number(k)
        k += 1.0
    return FormulaValue.number(n)


def xl_negbinom_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NEGBINOM.DIST(number_f, number_s, probability_s, cumulative)` — the
    probability of `number_f` FAILURES before the `number_s`-th SUCCESS.

    ⛔ THE TWIN IS `BINOM.DIST`, and the first two arguments are FAILURES then
    SUCCESSES rather than successes then trials. Excel's own example
    `NEGBINOM.DIST(10, 5, 0.25, FALSE)` is 0.055049; read as a binomial it is
    `#NUM!` at that input but a legal number at many others.

    ⚠ `number_s < 1` IS `#NUM!` — zero successes is not a stopping rule."""
    var fv = _num(args, 0)
    if fv.is_error():
        return fv^
    var sv = _num(args, 1)
    if sv.is_error():
        return sv^
    var pv = _num(args, 2)
    if pv.is_error():
        return pv^
    var c = _flag(args, 3)
    if c.is_error():
        return c^
    var f = _trunc_toward_zero(fv.num)
    var s = _trunc_toward_zero(sv.num)
    if f < 0.0 or s < 1.0 or pv.num <= 0.0 or pv.num > 1.0:
        return _err_num()
    if c.logical:
        # P(F <= f) = I_p(s, f+1)
        return FormulaValue.number(betai(s, f + 1.0, pv.num))
    return FormulaValue.number(
        xs_exp(
            xs_lgamma(f + s) - xs_lgamma(s) - xs_lgamma(f + 1.0)
            + s * xs_log(pv.num) + f * xs_log(1.0 - pv.num)
        )
    )


def xl_hypgeom_dist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`HYPGEOM.DIST(sample_s, number_sample, population_s, number_pop,
    cumulative)` — sampling WITHOUT replacement.

    ⚠ FOUR INTEGER ARGUMENTS IN AN ORDER NOTHING ELSE IN THIS FAMILY SHARES,
    and every permutation of them returns a plausible probability. Excel's own
    example `HYPGEOM.DIST(1, 4, 8, 20, FALSE)` is 0.3632422; with the middle
    pair swapped it is 0.0001 and with the outer pair swapped `#NUM!`.

    ⚠ THE CUMULATIVE ARM IS A SUM — there is no closed form — and it is O(k),
    which is bounded by the sample size."""
    var xv = _num(args, 0)
    if xv.is_error():
        return xv^
    var nv = _num(args, 1)
    if nv.is_error():
        return nv^
    var mv = _num(args, 2)
    if mv.is_error():
        return mv^
    var Nv = _num(args, 3)
    if Nv.is_error():
        return Nv^
    var c = _flag(args, 4)
    if c.is_error():
        return c^
    var x = _trunc_toward_zero(xv.num)
    var n = _trunc_toward_zero(nv.num)
    var m = _trunc_toward_zero(mv.num)
    var Np = _trunc_toward_zero(Nv.num)
    if Np <= 0.0 or n < 0.0 or n > Np or m < 0.0 or m > Np:
        return _err_num()
    if x < 0.0 or x > n or x > m or (n - x) > (Np - m):
        return _err_num()
    if c.logical:
        var acc: Float64 = 0.0
        var i: Float64 = 0.0
        while i <= x:
            if i <= m and (n - i) <= (Np - m):
                acc += _hyp_pmf(i, n, m, Np)
            i += 1.0
        return FormulaValue.number(acc)
    return FormulaValue.number(_hyp_pmf(x, n, m, Np))


def _hyp_pmf(x: Float64, n: Float64, m: Float64, Np: Float64) -> Float64:
    """C(m,x)·C(N-m,n-x)/C(N,n), in LOG SPACE for the same reason
    `_binom_pmf` is."""
    return xs_exp(
        _lchoose(m, x) + _lchoose(Np - m, n - x) - _lchoose(Np, n)
    )


def _lchoose(n: Float64, k: Float64) -> Float64:
    """log C(n,k)."""
    if k < 0.0 or k > n:
        return -745.0
    return xs_lgamma(n + 1.0) - xs_lgamma(k + 1.0) - xs_lgamma(n - k + 1.0)


# =============================================================================
# ★ CONFIDENCE INTERVALS — the pair whose whole difference is the tail table
# =============================================================================
def xl_confidence_norm(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CONFIDENCE.NORM(alpha, standard_dev, size)` — the half-width of the
    NORMAL confidence interval, `z_{1-α/2}·σ/√n`.

    ⛔ THE TWIN IS `CONFIDENCE.T`, and the two AGREE ASYMPTOTICALLY in n — at
    n=1000 they differ in the fourth digit — so a large-n fixture cannot tell
    them apart. Excel's own examples are at n=50, where CONFIDENCE.NORM(0.05,
    2.5, 50) = 0.6929519 and the t version at σ=1 is 0.2841969.

    ⚠ `size` IS TRUNCATED and `size < 1` is `#NUM!`; `alpha` outside (0,1) is
    `#NUM!`, and `standard_dev <= 0` likewise."""
    var a = _num(args, 0)
    if a.is_error():
        return a^
    var s = _num(args, 1)
    if s.is_error():
        return s^
    var nv = _num(args, 2)
    if nv.is_error():
        return nv^
    var n = _trunc_toward_zero(nv.num)
    if a.num <= 0.0 or a.num >= 1.0 or s.num <= 0.0 or n < 1.0:
        return _err_num()
    return FormulaValue.number(
        norm_s_inv(1.0 - a.num / 2.0) * s.num / sqrt(n)
    )


def xl_confidence_t(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CONFIDENCE.T(alpha, standard_dev, size)` — the STUDENT'S t half-width,
    `t_{α,n-1}·s/√n`.

    ⛔ `size == 1` IS `#DIV/0!`, NOT `#NUM!`, AND THAT IS THE DISCRIMINATOR
    FROM `CONFIDENCE.NORM`, which happily answers at n=1. With one observation
    there are zero degrees of freedom; Excel reports the division, not a
    domain error. A kernel that shared the NORM guard would return a number."""
    var a = _num(args, 0)
    if a.is_error():
        return a^
    var s = _num(args, 1)
    if s.is_error():
        return s^
    var nv = _num(args, 2)
    if nv.is_error():
        return nv^
    var n = _trunc_toward_zero(nv.num)
    if a.num <= 0.0 or a.num >= 1.0 or s.num <= 0.0 or n < 1.0:
        return _err_num()
    if n == 1.0:
        return FormulaValue.error(XL_ERR_DIV0)
    var df = n - 1.0
    var xb = betai_inv(df / 2.0, 0.5, a.num)
    var t = sqrt(df * (1.0 - xb) / xb)
    return FormulaValue.number(t * s.num / sqrt(n))


# =============================================================================
# ⭐ WHAT IS **NOT** HERE, AND WHY THIS SLICE DID NOT OVERRULE A LANDED REFUSAL
# =============================================================================
#
#   "**Array or reference arguments** that contain text evaluate as 0 (zero).
#    Empty text ("") evaluates as 0 (zero)."
#   "Arguments that are error values or text that cannot be translated into
#    numbers cause errors."
#
# ⚠⚠ AND THE SAME FETCH OPENED A **BIGGER** CELL, ON A **SERVED** NAME. The
# AVERAGE page says "Logical values and text representations of numbers that
# you type directly into the list of arguments are **not** counted", while the
# AVERAGEA / MAXA / VARA / STDEVA pages say they **are**; MAXA / VARA / STDEVA
# then carry BOTH "arguments that contain text ... evaluate as 0 (zero)"
# (unscoped) AND the "cannot be translated ... cause errors" bullet one bullet
# later. This door COUNTS them (`coerce_number`: TRUE->1, "3"->3), which every
# worked example agrees with and that one AVERAGE bullet does not.
#
#     AVERAGE(2,TRUE)  => 1.5   HERE     (the logical IS counted: TRUE -> 1)
#     AVERAGE(2,"3")   => 2.5   HERE     (the text-number IS counted)
#     MAX(-1,TRUE)     => 1     HERE
#
# If the AVERAGE page's bullet is literal, Excel does not count a directly
# typed logical at all, so it answers `AVERAGE(2,TRUE)` = **2** (mean of one
# value) and `MAX(-1,TRUE)` = **-1**. ⇒ the gap runs HERE-1.5 / EXCEL-2, not
# the reverse. That is a silent wrong answer in a name that IS SERVED, which
# is a strictly larger exposure than seven refused ones.
#
# ⇒ SERVING SEVEN ROWS ON AN UNVERIFIED READING IS THE WRONG-ANSWER CLASS THIS
# CAMPAIGN EXISTS TO STOP, so the refusal STANDS and the disagreement is a
# BOARD CARD rather than a commit:  carries
# the two cells that settle it. ⛔ Do not close it by re-reading the
# documentation — that is what produced two confident opposite answers.
#
# =============================================================================
#
# `CHISQDIST` / `CHISQINV` / `B` are NOT on Microsoft's worksheet-function list.
# They are in the published 532-name union because OOXML and ODF OpenFormula
# define them, and a reader of an `.ods` or of OOXML formula text meets them.
# ⛔ SERVING ONE IS A DECISION, NOT A DEFAULT: each is served because the
# standard defines it in terms of a kernel THIS FILE ALREADY HAS, so the row
# adds a SPELLING and not a second opinion about the mathematics. The five that
# are refused instead (DDE FORMULA MULTIPLE.OPERATIONS TABLE MVALUE) are
# refused BY NAME in `xl_absent_common_names()`, with the reason.
# =============================================================================


def xl_chisqdist(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHISQDIST(x, degrees_of_freedom[, cumulative])` — the OpenFormula
    LEFT-tailed χ², with `cumulative` OPTIONAL and defaulting to TRUE.

    ⛔ TWO DISCRIMINATORS, NOT ONE. (1) It is the LEFT tail, so its twin is
    Excel's legacy `CHIDIST`, which is the RIGHT one — at (0.5, 1) the answers
    are 0.5205 and 0.4795. (2) THE ARITY IS 2..3 WHERE `CHISQ.DIST` IS 3..3:
    omitting `cumulative` must give the CDF, and a row that simply forwarded a
    2-argument call to `CHISQ.DIST` would be an arity error instead."""
    var a3 = List[FormulaValue]()
    a3.append(args[0].copy())
    a3.append(args[1].copy())
    if len(args) >= 3:
        a3.append(args[2].copy())
    else:
        a3.append(FormulaValue.logical_val(True))
    return xl_chisq_dist(a3)


def xl_chisqinv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHISQINV(probability, degrees_of_freedom)` — the OpenFormula
    LEFT-tailed χ² quantile, i.e. `CHISQ.INV`.

    ⛔ THE TWIN IS THE LEGACY `CHIINV`, WHICH IS THE RIGHT-TAILED ONE, and both
    are positive numbers of the right magnitude: at (0.5, 1) the left quantile
    is 0.4549 and the right one is 0.4549 as well — so the cell that grades
    this must NOT be at p=0.5, where the two coincide by symmetry of the
    definition. The oracle grades (0.93, 1) = 3.28302, where CHIINV answers
    0.00784."""
    return xl_chisq_inv(args)


def xl_b_fn(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`B(trials, SP, T1[, T2])` — the OpenFormula binomial probability: the
    chance of exactly `T1` successes, or of between `T1` and `T2` of them.

    ⚠ THAT IS EXACTLY EXCEL'S `BINOM.DIST.RANGE`, argument for argument, so
    this forwards to it rather than restating the mathematics. ⛔ ITS TWIN IS
    `BINOM.DIST`, WHOSE ARGUMENT ORDER IS THE REVERSE — successes FIRST there,
    trials FIRST here — and `BINOM.DIST.RANGE`'s own docstring records that a
    shared unpacking helper reads one as the other and still answers a
    plausible probability. ⚠ AND THE 3-ARGUMENT FORM IS THE POINT MASS, NOT A
    CUMULATIVE: `B(10,0.5,5)` is 0.24609375 (= C(10,5)/2^10, EXACT in binary)
    where the cumulative through 5 is 0.623046875."""
    return xl_binom_dist_range(args)

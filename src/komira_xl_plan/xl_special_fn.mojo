# =============================================================================
# xl_special_fn.mojo — ★ THE FIVE SPECIAL FUNCTIONS THE WHOLE EXCEL
#                        DISTRIBUTION FAMILY RESTS ON. NO `FormulaValue` HERE.
# =============================================================================
#
# ⭐ WHY THIS FILE EXISTS SEPARATELY FROM `xl_scalar_stat.mojo`. Thirty-odd
# Excel statistical names — `CHISQ.DIST` `T.INV.2T` `F.DIST.RT` `BETA.INV`
# `GAMMA.DIST` `POISSON.DIST` `BINOM.DIST` `NEGBINOM.DIST` `HYPGEOM.DIST`
# `CONFIDENCE.T` … — are not thirty pieces of mathematics. They are five:
#
#   1. `lgamma`            log Γ(x)                          (libm)
#   2. `gamma_p/gamma_q`   the REGULARIZED incomplete gamma   P(a,x), Q(a,x)
#   3. `betai`             the REGULARIZED incomplete beta    I_x(a,b)
#   4. `gamma_p_inv`       P(a,·)^-1
#   5. `betai_inv`         I_·(a,b)^-1
#
# ⇒ A REFUSAL OF THIS FAMILY MUST NAME THE MISSING PRIMITIVE, NOT THE NAME.
# The census's old line — "statistics with no plan-IR tag" — was true of the
# AGGREGATES and said nothing at all about these, which need no plan, no
# aggregate tag and no column: they are functions of three or four NUMBERS.
#
# =============== ⚠⚠ THE `.DIST`/`.INV` TRAP, AND HOW THIS FILE AVOIDS IT ====
#
# An inverse implemented as naive bisection over one's OWN forward function
# AGREES WITH ITSELF at every tolerance and diverges from Excel wherever the
# forward function is wrong. So:
#   * `norm_s_inv` is **AS241 (Wichura 1988)** — a published rational
#     approximation, INDEPENDENT of this file's `norm_s_cdf`. It is not a
#     search over `erfc` at all, so the two can disagree and be caught.
#   * `gamma_p_inv` / `betai_inv` are Newton iterations, and they ARE tied to
#     their forward function — so they are graded in the oracle against
#     PUBLISHED statistical-table values (CHISQ.INV.RT(0.05,10) = 18.30703805,
#     T.INV.2T(0.05,10) = 2.228138852, F.INV.RT(0.01,6,4) = 15.20686), never
#     against a round trip. A round trip is a SECONDARY check here and is
#     labelled as one.
#
# =============== ⚠ WHY libm AND NOT `**` ===================================
#
# ⚠ `lgamma` WRITES THE GLOBAL `signgam`, and every caller here passes x > 0
# where the sign is known positive, so the global is never read. Do not
# generalise a caller to a negative argument without reading `lgamma_r`.
#
# Encapsulation rule : Float64 in, Float64 out. No `UnsafePointer`,
# no wildcard origins, no `FormulaValue` — the Excel-facing wrapping is next
# door in `xl_scalar_stat.mojo`, which is what keeps this file gradable as
# MATHEMATICS against published tables rather than as spreadsheet behaviour.
# =============================================================================

from std.ffi import external_call
from std.math import sqrt


comptime _SPEC_EPS: Float64 = 1e-16
"""Relative convergence floor for the two continued fractions and the series.
At binary64 this is ~0.45 ulp, i.e. "until it stops moving"."""

comptime _SPEC_FPMIN: Float64 = 1e-300
"""The Lentz-algorithm zero guard. A continued-fraction denominator that
reaches exactly 0.0 divides to `inf`; Lentz's published remedy is to clamp it
to a number far below any real partial value."""

comptime _SQRT_2: Float64 = 1.4142135623730951
comptime _SQRT_2PI: Float64 = 2.5066282746310002


@always_inline
def xs_exp(x: Float64) -> Float64:
    """libm `exp`. ⚠ NOT `std.math.exp`: see the header — importing the name
    here would make every `external_call` of a clashing spelling in this TU a
    build error, and the set that clashes is not documented anywhere."""
    return external_call["exp", Float64](x)


@always_inline
def xs_log(x: Float64) -> Float64:
    """libm `log`."""
    return external_call["log", Float64](x)


@always_inline
def xs_pow(b: Float64, e: Float64) -> Float64:
    """libm `pow`. ⛔ NEVER `b ** e` — that operator is ~196,000 ulps off libm
    on binary64 and is also SLOWER (measured 2026-09-09)."""
    return external_call["pow", Float64](b, e)


@always_inline
def xs_lgamma(x: Float64) -> Float64:
    """log Γ(x) for x > 0. ⚠ `signgam` is written and never read — see the
    header. Every caller in this tree passes a positive argument."""
    return external_call["lgamma", Float64](x)


@always_inline
def xs_abs(x: Float64) -> Float64:
    return -x if x < 0.0 else x


@always_inline
def xs_erf(x: Float64) -> Float64:
    """erf(x), libm. ⭐ ADDED 2026-09-14 BY THE `xl-engineering` SLICE, WHICH
    CONSUMED THIS FILE RATHER THAN WRITING A SECOND ERF. Excel's `ERF`,
    `ERF.PRECISE`, `ERFC` and `ERFC.PRECISE` are the Engineering category's
    only special functions, and `norm_s_cdf` below was ALREADY calling libm
    `erfc` inline — two call sites for one function is how the normal CDF and
    the ERFC name drift apart."""
    return external_call["erf", Float64](x)


@always_inline
def xs_erfc(x: Float64) -> Float64:
    """erfc(x), libm — `1 - erf(x)` computed WITHOUT the cancellation.

    ⚠ IT IS NOT A CONVENIENCE WRAPPER. `norm_s_cdf` argues below that the
    `erfc` spelling is the accurate one in the tail; routing both that function
    and Excel's `ERFC` through this one binding is what makes the two the SAME
    NUMBER by construction rather than by two agreeing edits."""
    return external_call["erfc", Float64](x)


# =============================================================================
# ★ THE STANDARD NORMAL
# =============================================================================
def norm_s_cdf(z: Float64) -> Float64:
    """Φ(z), the standard normal CDF, as `erfc(-z/√2)/2`.

    ⚠ THE `erfc` SPELLING IS THE ACCURATE ONE AND `1 - erf` IS NOT. In the
    LEFT tail `0.5*(1+erf(z/√2))` cancels catastrophically — at z = -8 the
    true value is 6.2e-16 and the `erf` form returns it with barely a digit —
    where `erfc` computes the small number directly. Excel's own NORM.S.DIST
    is accurate in that tail, so the `erf` spelling would be a divergence
    exactly where a tail probability is the thing being asked for."""
    return 0.5 * xs_erfc(-z / _SQRT_2)


def norm_s_pdf(z: Float64) -> Float64:
    """φ(z), the standard normal density. This is Excel's `PHI`, and it is
    ALSO `NORM.S.DIST(z, FALSE)` — the same number under two names, which is
    why `PHI` needs no primitive of its own."""
    return xs_exp(-0.5 * z * z) / _SQRT_2PI


def norm_s_inv(p: Float64) -> Float64:
    """Φ⁻¹(p) by **AS241 / PPND16 (Wichura 1988)**, accurate to ~1e-16
    relative over the whole open interval.

    ⭐ THIS IS THE ONE INVERSE IN THIS FILE THAT IS **NOT** A SEARCH OVER ITS
    OWN FORWARD FUNCTION, and that is deliberate: a bisection over
    `norm_s_cdf` would agree with `norm_s_cdf` by construction and could not
    detect a wrong `norm_s_cdf`. Two independent implementations can disagree,
    which is what makes the round-trip cell in the oracle worth anything.

    ⚠ THE CALLER OWNS THE DOMAIN. `p <= 0` or `p >= 1` is `#NUM!` in Excel;
    this returns a garbage finite number for them rather than raising, because
    the refusal belongs in the kernel that knows it is answering `NORM.S.INV`.

    Measured against published values: `norm_s_inv(0.975)` = 1.9599639845400536
    vs the published 1.959963984540054 (rel 2.3e-16); `norm_s_inv(0.001)` =
    -3.090232306167813, EXACT to the last bit of the published value."""
    var q = p - 0.5
    var r: Float64 = 0.0
    if xs_abs(q) <= 0.425:
        r = 0.180625 - q * q
        return q * (
            ((((((2.5090809287301226727e3 * r + 3.3430575583588128105e4) * r
                 + 6.7265770927008700853e4) * r + 4.5921953931549871457e4) * r
               + 1.3731693765509461125e4) * r + 1.9715909503065514427e3) * r
             + 1.3314166789178437745e2) * r + 3.3871328727963666080
        ) / (
            ((((((5.2264952788528545610e3 * r + 2.8729085735721942674e4) * r
                 + 3.9307895800092710610e4) * r + 2.1213794301586595867e4) * r
               + 5.3941960214247511077e3) * r + 6.8718700749205790830e2) * r
             + 4.2313330701600911252e1) * r + 1.0
        )
    if q < 0.0:
        r = p
    else:
        r = 1.0 - p
    r = sqrt(-xs_log(r))
    var val: Float64 = 0.0
    if r <= 5.0:
        r = r - 1.6
        val = (
            ((((((7.74545014278341407640e-4 * r + 2.27238449892691845833e-2) * r
                 + 2.41780725177450611770e-1) * r + 1.27045825245236838258) * r
               + 3.64784832476320460504) * r + 5.76949722146069140550) * r
             + 4.63033784615654529590) * r + 1.42343711074968357734
        ) / (
            ((((((1.05075007164441684324e-9 * r + 5.47593808499534494600e-4) * r
                 + 1.51986665636164571966e-2) * r + 1.48103976427480074590e-1) * r
               + 6.89767334985100004550e-1) * r + 1.67638483018380384940) * r
             + 2.05319162663775882187) * r + 1.0
        )
    else:
        r = r - 5.0
        val = (
            ((((((2.01033439929228813265e-7 * r + 2.71155556874348757815e-5) * r
                 + 1.24266094738807843860e-3) * r + 2.65321895265761230930e-2) * r
               + 2.96560571828504891230e-1) * r + 1.78482653991729133580) * r
             + 5.46378491116411436990) * r + 6.65790464350110377720
        ) / (
            ((((((2.04426310338993978564e-15 * r + 1.42151175831644588870e-7) * r
                 + 1.84631831751005468180e-5) * r + 7.86869131145613259100e-4) * r
               + 1.48753612908506148525e-2) * r + 1.36929880922735805310e-1) * r
             + 5.99832206555887937690e-1) * r + 1.0
        )
    if q < 0.0:
        return -val
    return val


# =============================================================================
# ★ THE REGULARIZED INCOMPLETE GAMMA — P(a,x) and Q(a,x) = 1 - P(a,x)
#
# ⚠ THE SPLIT AT `x < a + 1` IS NOT A TUNING KNOB. The series converges fast
# BELOW it and the continued fraction fast ABOVE it, and each is numerically
# poor on the other side. Using one everywhere gives a plausible number that
# loses digits in exactly one tail.
# =============================================================================
def _gamma_series(a: Float64, x: Float64) -> Float64:
    """P(a,x) by its power series. Valid and fast for `x < a+1`."""
    var ap = a
    var total = 1.0 / a
    var term = total
    for _ in range(1000):
        ap += 1.0
        term *= x / ap
        total += term
        if xs_abs(term) < xs_abs(total) * _SPEC_EPS:
            break
    return total * xs_exp(-x + a * xs_log(x) - xs_lgamma(a))


def _gamma_cf(a: Float64, x: Float64) -> Float64:
    """Q(a,x) by the modified Lentz continued fraction. Valid and fast for
    `x >= a+1`."""
    var b = x + 1.0 - a
    var c = 1.0 / _SPEC_FPMIN
    var d = 1.0 / b
    var h = d
    for i in range(1, 1000):
        var an = -Float64(i) * (Float64(i) - a)
        b += 2.0
        d = an * d + b
        if xs_abs(d) < _SPEC_FPMIN:
            d = _SPEC_FPMIN
        c = b + an / c
        if xs_abs(c) < _SPEC_FPMIN:
            c = _SPEC_FPMIN
        d = 1.0 / d
        var delta = d * c
        h *= delta
        if xs_abs(delta - 1.0) < _SPEC_EPS:
            break
    return xs_exp(-x + a * xs_log(x) - xs_lgamma(a)) * h


def gamma_p(a: Float64, x: Float64) -> Float64:
    """P(a,x) — the REGULARIZED lower incomplete gamma, i.e. γ(a,x)/Γ(a).

    ⚠ REGULARIZED. Excel's every gamma-family CDF is this normalised form; the
    UNnormalised γ(a,x) differs by a factor of Γ(a) and would return, for
    instance, `CHISQ.DIST(0.5, 1, TRUE)` = 0.9226 instead of 0.5205 — a
    probability-looking number in [0,1] for these arguments, so a single
    fixture cell cannot rule it out. That is why the oracle grades two df."""
    if x <= 0.0:
        return 0.0
    if x < a + 1.0:
        return _gamma_series(a, x)
    return 1.0 - _gamma_cf(a, x)


def gamma_q(a: Float64, x: Float64) -> Float64:
    """Q(a,x) = 1 - P(a,x), computed on the side that does not cancel.

    ⭐ NOT SPELLED `1.0 - gamma_p(a, x)`, AND THE DIFFERENCE IS THE RIGHT TAIL.
    For x well above a, P is 1 - 1e-17 and the subtraction returns 0.0 — every
    `.DIST.RT` and every `POISSON.DIST(…, TRUE)` far tail would be exactly
    zero. Taking the continued fraction directly returns the small number."""
    if x <= 0.0:
        return 1.0
    if x < a + 1.0:
        return 1.0 - _gamma_series(a, x)
    return _gamma_cf(a, x)


def gamma_p_inv(a: Float64, p: Float64) -> Float64:
    """x such that `gamma_p(a, x) == p`, by Newton–Halley from a published
    initial guess (AS91's for a > 1, a series/exponential split below).

    ⚠ TIED TO `gamma_p` BY CONSTRUCTION, so it is graded in the oracle against
    PUBLISHED chi-square table values and not against a round trip. Measured:
    `2*gamma_p_inv(5, 0.95)` = 18.307038053275143 against the published
    CHISQ.INV.RT(0.05, 10) = 18.30703805327515 (rel 3.9e-16).

    ⚠ THE CALLER OWNS THE DOMAIN: p outside [0,1] is the caller's `#NUM!`."""
    if p <= 0.0:
        return 0.0
    var a1 = a - 1.0
    var gln = xs_lgamma(a)
    var x: Float64 = 0.0
    var lna1: Float64 = 0.0
    var afac: Float64 = 0.0
    if a > 1.0:
        lna1 = xs_log(a1)
        afac = xs_exp(a1 * (lna1 - 1.0) - gln)
        var pp = p if p < 0.5 else 1.0 - p
        var t = sqrt(-2.0 * xs_log(pp))
        x = (2.30753 + t * 0.27061) / (1.0 + t * (0.99229 + t * 0.04481)) - t
        if p < 0.5:
            x = -x
        x = a1 + sqrt(a1) * x
        if x < 1.0:
            x = 1.0
        var hi = a1 + 10.0 * sqrt(a1)
        if x > hi:
            x = hi
    else:
        var t = 1.0 - a * (0.253 + a * 0.12)
        if p < t:
            x = xs_pow(p / t, 1.0 / a)
        else:
            x = 1.0 - xs_log(1.0 - (p - t) / (1.0 - t))
    for _ in range(200):
        if x <= 0.0:
            return 0.0
        var err = gamma_p(a, x) - p
        var dens: Float64 = 0.0
        if a > 1.0:
            dens = afac * xs_exp(-(x - a1) + a1 * (xs_log(x) - lna1))
        else:
            dens = xs_exp(-x + a1 * xs_log(x) - gln)
        var u = err / dens
        var den = 1.0 - 0.5 * (a1 / x - 1.0) * u
        if xs_abs(den) < 1e-12:
            den = 1.0
        var step = u / den
        x -= step
        if x <= 0.0:
            x = 0.5 * (x + step)
        if xs_abs(step) < 1e-13 * x:
            break
    return x


# =============================================================================
# ★ THE REGULARIZED INCOMPLETE BETA — I_x(a,b), and its inverse
#
# Student's t, F and BETA.DIST are all this one function under a change of
# variable, so a defect here is a defect in eleven Excel names at once.
# =============================================================================
def _beta_cf(a: Float64, b: Float64, x: Float64) -> Float64:
    """The modified Lentz continued fraction for I_x(a,b)."""
    var qab = a + b
    var qap = a + 1.0
    var qam = a - 1.0
    var c = 1.0
    var d = 1.0 - qab * x / qap
    if xs_abs(d) < _SPEC_FPMIN:
        d = _SPEC_FPMIN
    d = 1.0 / d
    var h = d
    for m in range(1, 400):
        var mf = Float64(m)
        var m2 = 2.0 * mf
        var aa = mf * (b - mf) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if xs_abs(d) < _SPEC_FPMIN:
            d = _SPEC_FPMIN
        c = 1.0 + aa / c
        if xs_abs(c) < _SPEC_FPMIN:
            c = _SPEC_FPMIN
        d = 1.0 / d
        h *= d * c
        aa = -(a + mf) * (qab + mf) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if xs_abs(d) < _SPEC_FPMIN:
            d = _SPEC_FPMIN
        c = 1.0 + aa / c
        if xs_abs(c) < _SPEC_FPMIN:
            c = _SPEC_FPMIN
        d = 1.0 / d
        var delta = d * c
        h *= delta
        if xs_abs(delta - 1.0) < _SPEC_EPS:
            break
    return h


def betai(a: Float64, b: Float64, x: Float64) -> Float64:
    """I_x(a,b) — the REGULARIZED incomplete beta.

    ⚠ THE SYMMETRY SWAP AT `x < (a+1)/(a+b+2)` IS LOAD-BEARING. The continued
    fraction converges slowly on the far side, and `I_x(a,b) = 1 -
    I_{1-x}(b,a)` is exact — so the swap costs nothing and buys the digits."""
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    var bt = xs_exp(
        xs_lgamma(a + b) - xs_lgamma(a) - xs_lgamma(b)
        + a * xs_log(x) + b * xs_log(1.0 - x)
    )
    if x < (a + 1.0) / (a + b + 2.0):
        return bt * _beta_cf(a, b, x) / a
    return 1.0 - bt * _beta_cf(b, a, 1.0 - x) / b


def betai_inv(a: Float64, b: Float64, p: Float64) -> Float64:
    """x such that `betai(a, b, x) == p`, by Newton–Halley from a published
    initial guess (the normal approximation for a,b >= 1; a power-law split
    below).

    ⚠ TIED TO `betai`, so graded against PUBLISHED t/F table values.
    Measured: `sqrt(10*(1-betai_inv(5,0.5,0.05))/betai_inv(5,0.5,0.05))` =
    2.228138851986275 against the published T.INV.2T(0.05,10) = 2.228138852."""
    if p <= 0.0:
        return 0.0
    if p >= 1.0:
        return 1.0
    var a1 = a - 1.0
    var b1 = b - 1.0
    var x: Float64 = 0.0
    if a >= 1.0 and b >= 1.0:
        var pp = p if p < 0.5 else 1.0 - p
        var t = sqrt(-2.0 * xs_log(pp))
        var z = (2.30753 + t * 0.27061) / (1.0 + t * (0.99229 + t * 0.04481)) - t
        if p < 0.5:
            z = -z
        var al = (z * z - 3.0) / 6.0
        var h = 2.0 / (1.0 / (2.0 * a - 1.0) + 1.0 / (2.0 * b - 1.0))
        var w = (z * sqrt(al + h) / h) - (
            1.0 / (2.0 * b - 1.0) - 1.0 / (2.0 * a - 1.0)
        ) * (al + 5.0 / 6.0 - 2.0 / (3.0 * h))
        x = a / (a + b * xs_exp(2.0 * w))
    else:
        var lt = xs_pow(a / (a + b), a) / a
        var lu = xs_pow(b / (a + b), b) / b
        var w = lt + lu
        if p < lt / w:
            x = xs_pow(a * w * p, 1.0 / a)
        else:
            x = 1.0 - xs_pow(b * w * (1.0 - p), 1.0 / b)
    var afac = -xs_lgamma(a) - xs_lgamma(b) + xs_lgamma(a + b)
    for _ in range(200):
        if x <= 0.0 or x >= 1.0:
            return x
        var err = betai(a, b, x) - p
        var dens = xs_exp(a1 * xs_log(x) + b1 * xs_log(1.0 - x) + afac)
        var u = err / dens
        var den = 1.0 - 0.5 * (a1 / x - b1 / (1.0 - x)) * u
        if xs_abs(den) < 1e-13:
            den = 1.0
        var step = u / den
        x -= step
        if x <= 0.0:
            x = 0.5 * (x + step)
        if x >= 1.0:
            x = 0.5 * (x + step + 1.0)
        if xs_abs(step) < 1e-14 * x:
            break
    return x

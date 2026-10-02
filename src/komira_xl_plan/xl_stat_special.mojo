# =============================================================================
# xl_stat_special.mojo — ★ THE SPECIAL-FUNCTION FLOOR THE COMPATIBILITY
#                          DISTRIBUTIONS STAND ON. NO EXCEL NAME LIVES HERE.
# =============================================================================
#
# ============ ⚠⚠ WHY THIS IS A SEPARATE FILE FROM `xl_scalar_compat_stat` ===
#
# ⭐ NOTHING HERE TAKES A `FormulaValue` AND NOTHING HERE KNOWS WHAT AN EXCEL
# ERROR IS. Every entry point is `Float64 -> Float64` over an argument domain
# its CALLER has already checked. That is the property that makes these
# testable as MATHEMATICS — `test_xl_compat_stat_kernels.mojo` grades them at
# inputs whose answers are closed forms (`gamma_q(1, x) == exp(-x)`,
# `betainc_reg(x, 1, 1) == x`), which is a check no fixture over the Excel
# names could make, because at the Excel altitude the closed form is hidden
# behind an argument convention.
#
# ⛔ AND THE DOMAIN GUARDS ARE THE CALLER'S, DELIBERATELY. A primitive that
# returned `#NUM!` would have to know the Excel error lattice, which would put
# `formula_value` in this file's import list and make it the sixth kernel
# sibling rather than the floor beneath them. The contract is stated per
# function and `xl_scalar_compat_stat.mojo` refuses BEFORE calling.
#
# ============ ⛔⛔ WHY NOT libm's `lgamma`, WHICH IS RIGHT THERE ============
#
# Two measured reasons, and the second is the one that matters:
#
#  1. `lgamma` IS NOT REENTRANT in the C standard — it writes the sign of the
#     gamma function to the global `signgam`. The reentrant spelling is
#     `lgamma_r`, which is a GNU/BSD extension and not on every libc this tree
#     targets. An `external_call["lgamma"]` in a per-morsel kernel is a data
#     race that shows up as a wrong SIGN, not as a crash.
#  2. `komira_core/plan/expr.mojo:525` records the measurement that BLOCKED
#     `lgamma` as a SQL op here: libm and CPython DISAGREE in the last two
#     digits (`lgamma(5.0)` is `3.1780538303479453` from libm and
#     `3.1780538303479444` from CPython), and this repo's oracles take their
#     expected values from Python. A Lanczos series written HERE is a third
#     implementation, so the oracle is held at inputs where the answer has a
#     CLOSED FORM and neither libm's nor CPython's last digit is the subject.
#
# Encapsulation rule : `Float64` values only. No `UnsafePointer`,
# no wildcard origins, no `unsafe_from_address`, no heap allocation at all.
# =============================================================================

from std.ffi import external_call
from std.math import pi, sqrt


# The iteration ceilings. ⚠ BOTH ARE CEILINGS AND NEITHER IS A TARGET: every
# loop below breaks on a RELATIVE convergence test and reaches it in well under
# 100 iterations over the argument ranges an Excel sheet produces. The ceiling
# exists so that a caller who defeats the domain guard gets a WRONG NUMBER
# rather than a hung query, which is the lesser of the two.
comptime _ITMAX: Int = 1000
comptime _EPS: Float64 = 3.0e-16
# ⚠ NOT `Float64.MIN_FINITE`. This is the modified-Lentz renormalisation floor
# (Numerical Recipes §5.2): a continued-fraction denominator that lands on
# EXACTLY zero is nudged to this instead, so the next reciprocal is huge rather
# than infinite. A value near the true float minimum would UNDERFLOW the
# reciprocal back to infinity and defeat the guard.
comptime _FPMIN: Float64 = 1.0e-300

comptime _SQRT_2PI: Float64 = 2.5066282746310002
comptime _LOG_SQRT_2PI: Float64 = 0.9189385332046727


@always_inline
def _fabs(x: Float64) -> Float64:
    """Absolute value, spelled the way `xl_abs` spells it. ⚠ NOT a call into
    libm: `fabs` is one comparison and a negation, and this tree keeps the
    Excel kernels free of external symbols it does not need."""
    return -x if x < 0.0 else x


@always_inline
def _exp(x: Float64) -> Float64:
    return external_call["exp", Float64](x)


@always_inline
def _log(x: Float64) -> Float64:
    return external_call["log", Float64](x)


@always_inline
def _sin(x: Float64) -> Float64:
    return external_call["sin", Float64](x)


# =============================================================================
# ★ log Γ(x) — the Lanczos series, g = 7, nine coefficients.
# =============================================================================
def _lgamma_core(z: Float64) -> Float64:
    """log Γ(z) for `z >= 0.5`. The Lanczos approximation with `g = 7` and the
    nine-coefficient set, which is accurate to ~1e-15 RELATIVE across that
    half-line — comfortably inside every tolerance this file's callers declare.
    distribution."""
    var x = z - 1.0
    var a = 0.99999999999980993
    a += 676.5203681218851 / (x + 1.0)
    a += -1259.1392167224028 / (x + 2.0)
    a += 771.32342877765313 / (x + 3.0)
    a += -176.61502916214059 / (x + 4.0)
    a += 12.507343278686905 / (x + 5.0)
    a += -0.13857109526572012 / (x + 6.0)
    a += 9.9843695780195716e-6 / (x + 7.0)
    a += 1.5056327351493116e-7 / (x + 8.0)
    var t = x + 7.5
    return _LOG_SQRT_2PI + (x + 0.5) * _log(t) - t + _log(a)


def xl_lgamma(z: Float64) -> Float64:
    """log Γ(z) for any `z > 0`.

    ⚠ THE REFLECTION ARM IS NOT DECORATION. `BETADIST(x, 0.25, 3)` is a legal
    Excel call — Excel's only constraint on `alpha` is `> 0` — and the Lanczos
    series above is stated for `z >= 0.5`. Below that,
    `Γ(z)Γ(1-z) = pi / sin(pi z)` moves the argument onto the good half-line.
    A file that dropped this arm would be correct for every DEGREE-OF-FREEDOM
    argument (always `>= 0.5`) and wrong for a small shape parameter, which is
    the failure that hides behind a plausible chi-square test."""
    if z >= 0.5:
        return _lgamma_core(z)
    return _log(pi / _fabs(_sin(pi * z))) - _lgamma_core(1.0 - z)


# =============================================================================
# ★ THE REGULARIZED INCOMPLETE GAMMA PAIR — P(a,x) and Q(a,x) = 1 - P(a,x).
#
# ⛔ `Q` IS COMPUTED, NOT DERIVED FROM `1 - P`, AND THAT IS THE WHOLE REASON
# THE PAIR EXISTS. `CHIDIST` IS A RIGHT-TAIL FUNCTION: at `CHIDIST(100, 2)` the
# answer is 1.9e-22, and `1 - P` where `P` is 0.999...  loses EVERY significant
# digit to cancellation and returns a plausible zero. The series and the
# continued fraction each converge fast on one side of `x = a + 1`, so each
# tail is computed by the branch that is accurate there.
# =============================================================================
def _gser(a: Float64, x: Float64) -> Float64:
    """P(a, x) by the ascending series. Accurate for `x < a + 1`."""
    if x <= 0.0:
        return 0.0
    var ap = a
    var s = 1.0 / a
    var d = s
    for _i in range(_ITMAX):
        ap += 1.0
        d *= x / ap
        s += d
        if _fabs(d) < _fabs(s) * _EPS:
            break
    return s * _exp(-x + a * _log(x) - xl_lgamma(a))


def _gcf(a: Float64, x: Float64) -> Float64:
    """Q(a, x) by the continued fraction (modified Lentz). Accurate for
    `x >= a + 1`."""
    var b = x + 1.0 - a
    var c = 1.0 / _FPMIN
    var d = 1.0 / b
    var h = d
    for i in range(1, _ITMAX + 1):
        var fi = Float64(i)
        var an = -fi * (fi - a)
        b += 2.0
        d = an * d + b
        if _fabs(d) < _FPMIN:
            d = _FPMIN
        c = b + an / c
        if _fabs(c) < _FPMIN:
            c = _FPMIN
        d = 1.0 / d
        var de = d * c
        h *= de
        if _fabs(de - 1.0) < _EPS:
            break
    return _exp(-x + a * _log(x) - xl_lgamma(a)) * h


def gamma_p(a: Float64, x: Float64) -> Float64:
    """The regularized LOWER incomplete gamma `P(a, x)`, for `a > 0, x >= 0`.

    Closed forms a test can hold this to: `P(1, x) = 1 - exp(-x)` and
    `P(0.5, x) = erf(sqrt(x))`."""
    if x <= 0.0:
        return 0.0
    if x < a + 1.0:
        return _gser(a, x)
    return 1.0 - _gcf(a, x)


def gamma_q(a: Float64, x: Float64) -> Float64:
    """The regularized UPPER incomplete gamma `Q(a, x) = 1 - P(a, x)`, for
    `a > 0, x >= 0`. ⭐ THIS IS THE FUNCTION `CHIDIST` IS: `CHIDIST(x, df)` is
    `Q(df/2, x/2)` exactly, and `CHISQ.DIST(x, df, TRUE)` is `P` — the two
    2010-era spellings of the same distribution differ by WHICH OF THESE TWO
    they call, which is why an alias wired to the wrong one is a silent wrong
    answer and not an error."""
    if x <= 0.0:
        return 1.0
    if x < a + 1.0:
        return 1.0 - _gser(a, x)
    return _gcf(a, x)


# =============================================================================
# ★ THE REGULARIZED INCOMPLETE BETA — I_x(a, b).
# =============================================================================
def _betacf(a: Float64, b: Float64, x: Float64) -> Float64:
    """The continued fraction for the incomplete beta (modified Lentz)."""
    var qab = a + b
    var qap = a + 1.0
    var qam = a - 1.0
    var c = 1.0
    var d = 1.0 - qab * x / qap
    if _fabs(d) < _FPMIN:
        d = _FPMIN
    d = 1.0 / d
    var h = d
    for m in range(1, _ITMAX + 1):
        var fm = Float64(m)
        var m2 = 2.0 * fm
        var aa = fm * (b - fm) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if _fabs(d) < _FPMIN:
            d = _FPMIN
        c = 1.0 + aa / c
        if _fabs(c) < _FPMIN:
            c = _FPMIN
        d = 1.0 / d
        h *= d * c
        aa = -(a + fm) * (qab + fm) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if _fabs(d) < _FPMIN:
            d = _FPMIN
        c = 1.0 + aa / c
        if _fabs(c) < _FPMIN:
            c = _FPMIN
        d = 1.0 / d
        var de = d * c
        h *= de
        if _fabs(de - 1.0) < _EPS:
            break
    return h


def betainc_reg(a: Float64, b: Float64, x: Float64) -> Float64:
    """The regularized incomplete beta `I_x(a, b)`, for `a > 0, b > 0`, any x.

    ⚠ THE SYMMETRY SWAP AT `x = (a+1)/(a+b+2)` IS NOT AN OPTIMISATION. The
    continued fraction converges slowly on the far side of the distribution's
    mass; `I_x(a,b) = 1 - I_{1-x}(b,a)` moves every evaluation onto the fast
    side. Removing it does not change the answer where it converges and
    silently returns the ITERATION CEILING's partial sum where it does not.

    Closed forms a test can hold this to: `I_x(1,1) = x`, `I_x(2,1) = x^2`,
    `I_x(1,2) = 1-(1-x)^2`, `I_x(0.5,0.5) = (2/pi) asin(sqrt(x))`."""
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    var bt = _exp(
        xl_lgamma(a + b) - xl_lgamma(a) - xl_lgamma(b)
        + a * _log(x) + b * _log(1.0 - x)
    )
    if x < (a + 1.0) / (a + b + 2.0):
        return bt * _betacf(a, b, x) / a
    return 1.0 - bt * _betacf(b, a, 1.0 - x) / b


# =============================================================================
# ★ THE STANDARD NORMAL — CDF and its inverse.
# =============================================================================
def norm_sdist(z: Float64) -> Float64:
    """The standard normal CDF `Phi(z)`, for any finite `z`.

    ⚠ BUILT ON `gamma_p`/`gamma_q` RATHER THAN ON `erf`, for the tail reason
    the incomplete-gamma pair's header states: `Phi(-9)` is 1.1e-19 and
    `0.5*(1 - erf(9/sqrt(2)))` is zero in Float64. Routing the NEGATIVE half
    through `gamma_q` keeps every digit."""
    if z == 0.0:
        return 0.5
    var t = z * z * 0.5
    if z > 0.0:
        return 0.5 * (1.0 + gamma_p(0.5, t))
    return 0.5 * gamma_q(0.5, t)


def norm_sinv(p: Float64) -> Float64:
    """`Phi^-1(p)` for `0 < p < 1`. Acklam's rational approximation followed by
    TWO Halley refinements against `norm_sdist`.

    ⛔ THE REFINEMENT IS NOT POLISH. Acklam alone is accurate to ~1.15e-9
    RELATIVE, which at `p = 0.975` is an absolute error of ~2e-9 — the SAME
    order as the tolerance the value oracle declares, so the cell would be
    deciding on noise. Two Halley steps take it to full double precision, and
    `norm_sinv(0.5)` is then EXACTLY 0 rather than 1e-17.

    ⚠ THE REFINEMENT IS SKIPPED BEYOND |z| = 6. Its step needs
    `exp(z*z/2)`, which overflows Float64 at |z| ~ 38 and is already 1e7 at 6;
    out there Acklam's own accuracy is what is on offer and a refinement would
    make it worse, not better. No Excel cell this file serves reaches it."""
    var x: Float64
    if p < 0.02425:
        var q = sqrt(-2.0 * _log(p))
        x = (
            ((((-7.784894002430293e-03 * q + -3.223964580411365e-01) * q
               + -2.400758277161838e+00) * q + -2.549732539343734e+00) * q
             + 4.374664141464968e+00) * q + 2.938163982698783e+00
        ) / (
            (((7.784695709041462e-03 * q + 3.224671290700398e-01) * q
              + 2.445134137142996e+00) * q + 3.754408661907416e+00) * q + 1.0
        )
    elif p <= 0.97575:
        var q = p - 0.5
        var r = q * q
        x = (
            (((((-3.969683028665376e+01 * r + 2.209460984245205e+02) * r
                + -2.759285104469687e+02) * r + 1.383577518672690e+02) * r
              + -3.066479806614716e+01) * r + 2.506628277459239e+00) * q
        ) / (
            ((((-5.447609879822406e+01 * r + 1.615858368580409e+02) * r
               + -1.556989798598866e+02) * r + 6.680131188771972e+01) * r
             + -1.328068155288572e+01) * r + 1.0
        )
    else:
        var q = sqrt(-2.0 * _log(1.0 - p))
        x = -(
            ((((-7.784894002430293e-03 * q + -3.223964580411365e-01) * q
               + -2.400758277161838e+00) * q + -2.549732539343734e+00) * q
             + 4.374664141464968e+00) * q + 2.938163982698783e+00
        ) / (
            (((7.784695709041462e-03 * q + 3.224671290700398e-01) * q
              + 2.445134137142996e+00) * q + 3.754408661907416e+00) * q + 1.0
        )
    if _fabs(x) < 6.0:
        for _i in range(2):
            var e = norm_sdist(x) - p
            var u = e * _SQRT_2PI * _exp(x * x * 0.5)
            x = x - u / (1.0 + x * u * 0.5)
    return x


def norm_pdf(z: Float64) -> Float64:
    """The standard normal DENSITY. ⚠ A SEPARATE ENTRY POINT BECAUSE
    `NORMDIST(x, m, s, FALSE)` IS A DIFFERENT FUNCTION FROM `NORMDIST(..., TRUE)`
    and a kernel that ignored the flag would answer the CDF for both — a
    number in [0,1] that looks exactly as plausible as the density."""
    return _exp(-0.5 * z * z) / _SQRT_2PI

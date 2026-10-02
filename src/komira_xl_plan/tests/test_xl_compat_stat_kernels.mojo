# =============================================================================
# test_xl_compat_stat_kernels.mojo — ★ THE COMPATIBILITY TRANCHE'S KERNELS,
#   EXECUTED. Welded to `:komira_xl_plan` so a red here blocks the artifact.
# =============================================================================
#
# ⛔⛔ EVERY ASSERTION BELOW IS A CLOSED FORM, AND THAT IS THE DESIGN. The
# kernels compute these through a Lanczos log-gamma, a regularized incomplete
# gamma (series + continued fraction) and a regularized incomplete beta
# (modified Lentz). A test that ported those algorithms would assert the
# engine agrees with itself. So every expectation here is derivable with
# pencil and paper from the DEFINITION:
#
#   gamma_q(1, x)        == exp(-x)                (the exponential tail)
#   gamma_p(0.5, x)      == erf(sqrt(x))           (so Phi is pinned)
#   betainc_reg(1,1,x)   == x                      (the uniform)
#   betainc_reg(2,1,x)   == x^2
#   betainc_reg(.5,.5,x) == (2/pi)*asin(sqrt(x))   (the arcsine law)
#   CHIDIST(x, 2)        == exp(-x/2)
#   FDIST(x, 2, 2)       == 1/(1+x)
#   TDIST(x, 1, 2)       == 1 - (2/pi)*atan(x)     (the Cauchy)
#
# ============ ⛔ AND THE OTHER HALF: THE **RIVAL** VALUE IS ASSERTED TOO ====
#
# "Compatibility" does not mean "alias". Eleven of the twenty-four pre-2010
# names return a DIFFERENT NUMBER from their 2010 replacement at the same
# arguments, and every one of those rivals is a plausible probability. So the
# right-tail / two-tail / mass-only cases below assert BOTH what the kernel
# must answer AND that it must NOT answer the rival — the mis-wiring this
# effort is named for is a wrong VALUE, never a `#NAME?`.
#
# ⚠ TOLERANCE. `_close` is 1e-12 ABSOLUTE and is used only where the answer is
# irrational; the exactly-representable cases (0.25, 0.5, 0.1875, 3, 6) are
# asserted EXACT with `_assert_num` wherever the arithmetic permits it.
# =============================================================================

from std.ffi import external_call
from std.math import pi, sqrt
from std.testing import TestSuite, assert_equal, assert_true

from komira_core.plan.excel_error_code import XL_ERR_NUM

from komira_xl_plan.formula_value import FormulaValue
from komira_xl_plan.xl_stat_special import (
    betainc_reg,
    gamma_p,
    gamma_q,
    norm_pdf,
    norm_sdist,
    norm_sinv,
    xl_lgamma,
)
from komira_xl_plan.xl_scalar_compat_stat import (
    xl_betadist,
    xl_betainv,
    xl_binomdist,
    xl_chidist,
    xl_chiinv,
    xl_confidence,
    xl_critbinom,
    xl_expondist,
    xl_fdist,
    xl_finv,
    xl_gammadist,
    xl_gammainv,
    xl_hypgeomdist,
    xl_loginv,
    xl_lognormdist,
    xl_negbinomdist,
    xl_norminv,
    xl_normdist,
    xl_normsdist,
    xl_normsinv,
    xl_poisson,
    xl_tdist,
    xl_tinv,
    xl_weibull,
)
from komira_xl_plan.xl_scalar_web import xl_encodeurl


comptime _TOL: Float64 = 1.0e-12


# ⚠ EXPLICIT-ARITY BUILDERS RATHER THAN ONE VARIADIC. The `cumulative` flag
# has to arrive as a LOGICAL and not as the number 1 — the kernel coerces
# either, but a sheet sends the logical, and a builder that decided which
# trailing argument to re-tag by counting a variadic would be one more thing
# to get wrong in a file whose whole subject is argument POSITION.
def _a1(x0: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(x0))
    return a^


def _a2(x0: Float64, x1: Float64) -> List[FormulaValue]:
    var a = _a1(x0)
    a.append(FormulaValue.number(x1))
    return a^


def _a3(x0: Float64, x1: Float64, x2: Float64) -> List[FormulaValue]:
    var a = _a2(x0, x1)
    a.append(FormulaValue.number(x2))
    return a^


def _a4(
    x0: Float64, x1: Float64, x2: Float64, x3: Float64
) -> List[FormulaValue]:
    var a = _a3(x0, x1, x2)
    a.append(FormulaValue.number(x3))
    return a^


def _a5(
    x0: Float64, x1: Float64, x2: Float64, x3: Float64, x4: Float64
) -> List[FormulaValue]:
    var a = _a4(x0, x1, x2, x3)
    a.append(FormulaValue.number(x4))
    return a^


def _b2(x0: Float64, x1: Float64, cum: Bool) -> List[FormulaValue]:
    """Two numbers then a LOGICAL `cumulative` flag."""
    var a = _a2(x0, x1)
    a.append(FormulaValue.logical_val(cum))
    return a^


def _b3(
    x0: Float64, x1: Float64, x2: Float64, cum: Bool
) -> List[FormulaValue]:
    """Three numbers then a LOGICAL `cumulative` flag."""
    var a = _a3(x0, x1, x2)
    a.append(FormulaValue.logical_val(cum))
    return a^


def _text(s: String) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.text_val(s))
    return a^


def _fabs(x: Float64) -> Float64:
    return -x if x < 0.0 else x


def _close(r: FormulaValue, want: Float64, why: String) raises:
    assert_true(
        r.is_number(),
        why + " — expected a NUMBER, got `" + r.render() + "`",
    )
    assert_true(
        _fabs(r.num - want) <= _TOL,
        why + " — got " + String(r.num) + ", want " + String(want),
    )


def _not_close(r: FormulaValue, rival: Float64, why: String) raises:
    """⭐ THE OTHER HALF OF EVERY DIVERGENCE ASSERTION. A kernel wired to the
    2010 replacement answers `rival`, which is a probability in range; saying
    only "it equals the truth" leaves the reader to trust that the two differ
    at this input, and several of them do NOT at the inputs people pick."""
    assert_true(r.is_number(), why)
    assert_true(
        _fabs(r.num - rival) > 1.0e-6,
        why + " — the kernel answered the RIVAL definition's value "
        + String(rival),
    )


def _num(r: FormulaValue, want: Float64, why: String) raises:
    assert_true(
        r.is_number(),
        why + " — expected a NUMBER, got `" + r.render() + "`",
    )
    assert_equal(r.num, want, why)


def _err(r: FormulaValue, code: UInt8, why: String) raises:
    assert_true(
        r.is_error(), why + " — expected an ERROR, got `" + r.render() + "`"
    )
    assert_equal(Int(r.error_code), Int(code), why)


def _exp(x: Float64) -> Float64:
    return external_call["exp", Float64](x)


def _atan(x: Float64) -> Float64:
    return external_call["atan", Float64](x)


def _asin(x: Float64) -> Float64:
    return external_call["asin", Float64](x)


def _log(x: Float64) -> Float64:
    return external_call["log", Float64](x)


# =============================================================================
# ★ THE SPECIAL-FUNCTION FLOOR, HELD TO CLOSED FORMS
# =============================================================================
def test_lgamma_is_held_to_exact_factorials_and_the_half_integer() raises:
    """`lgamma(n+1) = log(n!)` exactly for small n, and `lgamma(0.5)` is
    `log(sqrt(pi))` — the value that pins the REFLECTION-free branch at its
    lower edge. ⚠ 0.5 is the smallest argument any degrees-of-freedom
    computation produces (df=1 -> df/2), so a series stated for `z >= 0.5`
    is exercised exactly at its boundary here."""
    _close_f(xl_lgamma(1.0), 0.0, "lgamma(1) = log(0!) = 0")
    _close_f(xl_lgamma(2.0), 0.0, "lgamma(2) = log(1!) = 0")
    _close_f(xl_lgamma(5.0), _log(24.0), "lgamma(5) = log(4!) = log 24")
    _close_f(xl_lgamma(11.0), _log(3628800.0), "lgamma(11) = log(10!)")
    _close_f(xl_lgamma(0.5), _log(sqrt(pi)), "lgamma(0.5) = log(sqrt(pi))")
    # ⭐ THE REFLECTION ARM. `BETADIST(x, 0.25, 3)` is a legal Excel call, so
    # `z < 0.5` is reachable; `Gamma(1/4)Gamma(3/4) = pi/sin(pi/4)`.
    _close_f(
        xl_lgamma(0.25) + xl_lgamma(0.75),
        _log(pi / (sqrt(2.0) / 2.0)),
        "the reflection formula holds across the z=0.5 boundary",
    )


def _close_f(got: Float64, want: Float64, why: String) raises:
    assert_true(
        _fabs(got - want) <= 1.0e-12,
        why + " — got " + String(got) + ", want " + String(want),
    )


def test_the_incomplete_gamma_pair_matches_its_closed_forms() raises:
    """`P(1,x) = 1-exp(-x)`, `Q(1,x) = exp(-x)`, `P(2,x) = 1-exp(-x)(1+x)`,
    and `P(0.5,x) = erf(sqrt(x))` pinned at `erf(1)`.

    ⛔ AND `Q` IS NOT `1-P` IN THE FAR TAIL, which is why both exist:
    `Q(1, 60)` is 8.76e-27 and a `1-P` spelling returns a clean 0."""
    _close_f(gamma_p(1.0, 2.0), 1.0 - _exp(-2.0), "P(1,x) = 1-exp(-x)")
    _close_f(gamma_q(1.0, 2.0), _exp(-2.0), "Q(1,x) = exp(-x)")
    _close_f(gamma_p(1.0, 0.25), 1.0 - _exp(-0.25),
             "and on the SERIES side of the x < a+1 branch too")
    _close_f(gamma_p(2.0, 2.0), 1.0 - _exp(-2.0) * 3.0,
             "P(2,x) = 1 - exp(-x)(1+x)")
    _close_f(gamma_p(0.5, 1.0), 0.8427007929497149,
             "P(0.5,1) = erf(1) = 0.8427007929497149")
    assert_true(
        gamma_q(1.0, 60.0) > 0.0,
        "⭐ Q IS NOT 1-P IN THE TAIL: Q(1,60) is 8.8e-27 and a `1 - P` "
        "spelling returns exactly 0, losing every digit to cancellation",
    )
    _close_f(gamma_p(3.0, 1.0) + gamma_q(3.0, 1.0), 1.0,
             "the two halves still sum to 1 where both are representable")


def test_the_incomplete_beta_matches_its_closed_forms() raises:
    """`I_x(1,1) = x`, `I_x(2,1) = x^2`, `I_x(1,2) = 1-(1-x)^2` and the
    arcsine law `I_x(0.5,0.5) = (2/pi) asin(sqrt(x))`.

    ⚠ THE LAST ONE IS THE ONE THAT MATTERS: it is the shape `TDIST` uses
    (`a = df/2`, `b = 0.5`), and it is the only one of the four that is not
    a polynomial, so it exercises the continued fraction rather than a
    degenerate case of it."""
    _close_f(betainc_reg(1.0, 1.0, 0.25), 0.25, "I_x(1,1) = x")
    _close_f(betainc_reg(2.0, 1.0, 0.5), 0.25, "I_x(2,1) = x^2")
    _close_f(betainc_reg(1.0, 2.0, 0.5), 0.75, "I_x(1,2) = 1-(1-x)^2")
    _close_f(betainc_reg(0.5, 0.5, 0.5), 0.5,
             "the arcsine law at its own median")
    _close_f(betainc_reg(0.5, 0.5, 0.25),
             (2.0 / pi) * _asin(sqrt(0.25)),
             "I_x(0.5,0.5) = (2/pi) asin(sqrt(x)) — the TDIST shape")
    _close_f(betainc_reg(3.0, 5.0, 0.4) + betainc_reg(5.0, 3.0, 0.6), 1.0,
             "the symmetry I_x(a,b) + I_{1-x}(b,a) = 1, which is what the "
             "convergence swap inside `betainc_reg` relies on")


def test_the_normal_cdf_and_its_inverse_round_trip_exactly() raises:
    """`Phi(0) = 0.5` EXACTLY, `Phi(1) = 0.8413447460685429`, and the inverse
    at 0.975 is 1.959963984540054 — the number every confidence interval in
    the world is built on.

    ⛔ THE INVERSE'S HALLEY REFINEMENT IS WHAT THIS PINS. Acklam's rational
    approximation ALONE is accurate to ~2e-9 at this point, which is three
    orders of magnitude coarser than the tolerance here, so a build that
    dropped the refinement reds."""
    _close_f(norm_sdist(0.0), 0.5, "Phi(0) is 0.5")
    _close_f(norm_sdist(1.0), 0.8413447460685429, "Phi(1)")
    _close_f(norm_sdist(-2.0), 0.022750131948179216,
             "Phi(-2) — the LEFT tail, which routes through gamma_q")
    _close_f(norm_sdist(1.0) + norm_sdist(-1.0), 1.0, "the symmetry")
    _close_f(norm_sinv(0.5), 0.0, "the inverse at the median is EXACTLY 0")
    _close_f(norm_sinv(0.975), 1.959963984540054, "the 97.5% point")
    _close_f(norm_sinv(norm_sdist(0.7)), 0.7, "and the pair round-trips")
    _close_f(norm_pdf(0.0), 1.0 / sqrt(2.0 * pi), "the density at 0")
    _close_f(norm_pdf(1.0), 0.24197072451914337,
             "⭐ the DENSITY at z=1 — 0.2420, NOT the CDF's 0.8413")


# =============================================================================
# ⛔ THE RIGHT-TAIL FAMILY — the four names that are NOT aliases
# =============================================================================
def test_CHIDIST_is_the_RIGHT_tail_and_not_CHISQ_DIST() raises:
    """`CHIDIST(x, 2) = exp(-x/2)`. Its 2010 replacement is `CHISQ.DIST.RT`;
    `CHISQ.DIST` is the LEFT tail and answers the COMPLEMENT."""
    _close(xl_chidist(_a2(1.0, 2.0)), _exp(-0.5), "CHIDIST(1,2) = exp(-0.5)")
    _not_close(xl_chidist(_a2(1.0, 2.0)), 1.0 - _exp(-0.5),
               "⛔ CHIDIST(1,2) must not be the LEFT tail 0.39347")
    _close(xl_chidist(_a2(2.0, 2.0)), _exp(-1.0), "CHIDIST(2,2) = exp(-1)")
    _close(xl_chidist(_a2(1.0, 4.0)), _exp(-0.5) * 1.5,
           "df=4 picks up a second series term: exp(-0.5)*(1+0.5)")
    # ⚠ THE MEDIAN IS THE BLIND POINT: both tails are 0.5 there, so a fixture
    # that tested only at the median could not tell the conventions apart.
    _close(xl_chidist(_a2(2.0 * _log(2.0), 2.0)), 0.5,
           "at the df=2 MEDIAN both tails are 0.5 — the blind input")
    _num(xl_chidist(_a2(0.0, 2.0)), 1.0, "the whole mass lies to the right of 0")
    _err(xl_chidist(_a2(-1.0, 2.0)), XL_ERR_NUM, "a negative x is #NUM!")
    _err(xl_chidist(_a2(1.0, 0.0)), XL_ERR_NUM, "df < 1 is #NUM!")
    _err(xl_chidist(_a2(1.0, 2.0e10)), XL_ERR_NUM,
         "df above 1e10 is Excel's own documented ceiling and a REFUSAL, "
         "not a clamp")


def test_CHIINV_inverts_the_RIGHT_tail_and_not_CHISQ_INV() raises:
    """`CHIINV(0.05, 2) = -2*ln(0.05) = 5.9915` — the 5% critical value. The
    LEFT-tail `CHISQ.INV(0.05,2)` is `-2*ln(0.95) = 0.10259`, a factor of 58
    away and still a positive chi-square-looking number."""
    _close(xl_chiinv(_a2(0.05, 2.0)), -2.0 * _log(0.05),
           "CHIINV(0.05,2) = 5.991464547107982")
    _not_close(xl_chiinv(_a2(0.05, 2.0)), -2.0 * _log(0.95),
               "⛔ it must not be the LEFT-tail 0.10259")
    _close(xl_chiinv(_a2(0.5, 2.0)), -2.0 * _log(0.5), "the median")
    _num(xl_chiinv(_a2(1.0, 2.0)), 0.0, "p=1 is the whole mass, so x=0")
    # ⭐ THE ROUND TRIP, which no single-value assertion can make.
    _close(xl_chidist(_a2(xl_chiinv(_a2(0.05, 2.0)).num, 2.0)), 0.05,
           "CHIDIST(CHIINV(p)) == p")
    _err(xl_chiinv(_a2(1.5, 2.0)), XL_ERR_NUM, "p > 1 is #NUM!")
    _err(xl_chiinv(_a2(0.0, 2.0)), XL_ERR_NUM, "p = 0 is unbounded, #NUM!")


def test_FDIST_is_the_RIGHT_tail_and_FINV_is_its_inverse() raises:
    """`FDIST(x, 2, 2) = 1/(1+x)` exactly. `F.DIST` is the LEFT tail and
    `F.INV` answers the RECIPROCAL of `FINV` — the most plausible wrong value
    a critical value can take."""
    _close(xl_fdist(_a3(3.0, 2.0, 2.0)), 0.25, "FDIST(3,2,2) = 1/(1+3)")
    _not_close(xl_fdist(_a3(3.0, 2.0, 2.0)), 0.75,
               "⛔ it must not be the LEFT tail 0.75")
    _close(xl_fdist(_a3(1.0, 2.0, 2.0)), 0.5,
           "⚠ x=1 with equal df is the BLIND point: both tails are 0.5")
    _close(xl_finv(_a3(0.25, 2.0, 2.0)), 3.0, "FINV(0.25,2,2) = 3")
    _not_close(xl_finv(_a3(0.25, 2.0, 2.0)), 1.0 / 3.0,
               "⛔ it must not be F.INV's reciprocal 1/3")
    _num(xl_finv(_a3(1.0, 2.0, 2.0)), 0.0, "p=1 is the whole mass")
    _close(xl_fdist(_a3(xl_finv(_a3(0.1, 4.0, 6.0)).num, 4.0, 6.0)), 0.1,
           "the round trip at NON-degenerate degrees of freedom, where "
           "neither side has a polynomial closed form")
    _err(xl_fdist(_a3(-1.0, 2.0, 2.0)), XL_ERR_NUM, "x < 0 is #NUM!")
    _err(xl_finv(_a3(0.0, 2.0, 2.0)), XL_ERR_NUM, "p = 0 is #NUM!")


def test_TDIST_carries_a_tails_selector_and_REFUSES_a_negative_x() raises:
    """Three divergences from `T.DIST`, and all three return a number under
    the wrong wiring: the LEFT/RIGHT tail, the `tails` doubling, and the
    negative-x REFUSAL that `T.DIST` does not make."""
    _close(xl_tdist(_a3(1.0, 1.0, 1.0)), 0.5 - _atan(1.0) / pi,
           "TDIST(1,1,1) = 0.25, the Cauchy right tail")
    _not_close(xl_tdist(_a3(1.0, 1.0, 1.0)), 0.75,
               "⛔ it must not be T.DIST's LEFT tail 0.75")
    _close(xl_tdist(_a3(1.0, 1.0, 2.0)), 2.0 * (0.5 - _atan(1.0) / pi),
           "TDIST(1,1,2) is EXACTLY TWICE the one-tailed value")
    _close(xl_tdist(_a3(1.0, 2.0, 2.0)), 1.0 - 1.0 / sqrt(3.0),
           "df=2: 1 - t/sqrt(2+t^2)")
    _close(xl_tdist(_a3(0.0, 1.0, 1.0)), 0.5,
           "⚠ x=0 is the BLIND point: the right tail and the left one are "
           "both 0.5 there")
    # ⛔ THE CELL THAT CATCHES A ROW RE-POINTED AT `T.DIST`.
    _err(xl_tdist(_a3(-1.0, 1.0, 2.0)), XL_ERR_NUM,
         "⭐ a NEGATIVE x is #NUM! in Excel's TDIST and is ACCEPTED by the "
         "2010 T.DIST — a refusal that would become a confident probability")
    _err(xl_tdist(_a3(1.0, 1.0, 3.0)), XL_ERR_NUM,
         "`tails` must be 1 or 2; multiplying by whatever arrives would "
         "answer 0.75 for a call Excel refuses")
    _err(xl_tdist(_a3(1.0, 0.0, 1.0)), XL_ERR_NUM, "df < 1 is #NUM!")


def test_TINV_is_the_TWO_tailed_inverse_and_not_T_INV() raises:
    """`TINV(0.5, 1) = tan(pi/4) = 1`. The one-tailed `T.INV(0.5,1)` is
    **0** — the median of a symmetric distribution — and a t critical value
    of 0 passes every significance test ever run against it."""
    _close(xl_tinv(_a2(0.5, 1.0)), 1.0, "TINV(0.5,1) = tan(pi/4) = 1")
    _not_close(xl_tinv(_a2(0.5, 1.0)), 0.0,
               "⛔ it must not be T.INV's 0")
    _close(xl_tinv(_a2(0.5, 2.0)), 0.5 * sqrt(2.0 / 0.75),
           "the df argument is USED: 0.8165 at df=2, not 1")
    _num(xl_tinv(_a2(1.0, 1.0)), 0.0, "p=1 is the whole mass")
    _close(xl_tdist(_a3(xl_tinv(_a2(0.2, 5.0)).num, 5.0, 2.0)), 0.2,
           "the round trip through the TWO-TAILED convention at df=5")
    _err(xl_tinv(_a2(0.0, 1.0)), XL_ERR_NUM, "p = 0 is unbounded, #NUM!")


# =============================================================================
# ⛔ THE NAMES THAT LOST A `cumulative` ARGUMENT
# =============================================================================
def test_NORMSDIST_is_arity_one_and_cumulative_not_the_density() raises:
    _close(xl_normsdist(_a1(1.0)), 0.8413447460685429, "Phi(1)")
    _not_close(xl_normsdist(_a1(1.0)), 0.24197072451914337,
               "⛔ it must not be the DENSITY 0.2420")
    _num(xl_normsdist(_a1(0.0)), 0.5, "Phi(0) is exactly 0.5")
    _close(xl_normsinv(_a1(0.975)), 1.959963984540054, "the 97.5% point")
    _num(xl_normsinv(_a1(0.5)), 0.0, "and EXACTLY 0 at the median")
    _err(xl_normsinv(_a1(0.0)), XL_ERR_NUM, "p <= 0 is #NUM!")
    _err(xl_normsinv(_a1(1.0)), XL_ERR_NUM, "p >= 1 is #NUM!")


def test_NORMDIST_reads_its_cumulative_flag_and_its_location_scale() raises:
    _close(xl_normdist(_b3(1.0, 0.0, 1.0, True)), 0.8413447460685429,
           "the CUMULATIVE arm")
    _close(xl_normdist(_b3(1.0, 0.0, 1.0, False)), 0.24197072451914337,
           "⭐ the DENSITY arm — a DIFFERENT function, not a display option")
    _close(xl_normdist(_b3(7.0, 5.0, 2.0, True)), 0.8413447460685429,
           "mean and sd are USED: (7-5)/2 = 1, so this equals the z=1 value")
    _not_close(xl_normdist(_b3(7.0, 5.0, 2.0, True)), 1.0,
               "⛔ a kernel ignoring location and scale answers Phi(7) = 1")
    _close(xl_normdist(_b3(7.0, 5.0, 2.0, False)),
           0.24197072451914337 / 2.0,
           "and the DENSITY carries the 1/sd Jacobian, which a kernel that "
           "only standardised the argument would drop")
    _err(xl_normdist(_b3(1.0, 0.0, 0.0, True)), XL_ERR_NUM, "sd = 0 is #NUM!")
    _close(xl_norminv(_a3(0.975, 0.0, 1.0)), 1.959963984540054, "NORM.INV")
    _num(xl_norminv(_a3(0.5, 3.0, 2.0)), 3.0, "exactly the mean")


def test_LOGNORMDIST_is_cumulative_only_and_LOGINV_inverts_it() raises:
    _close(xl_lognormdist(_a3(2.0, 0.0, 1.0)), 0.7558914042144171,
           "Phi(ln 2) — CUMULATIVE, at arity 3")
    _not_close(xl_lognormdist(_a3(2.0, 0.0, 1.0)), 0.156874019278,
               "⛔ it must not be the lognormal DENSITY, which is what a "
               "LOGNORM.DIST-wired row answers when the flag defaults FALSE")
    _num(xl_lognormdist(_a3(1.0, 0.0, 1.0)), 0.5, "ln 1 = 0, so exactly 0.5")
    _err(xl_lognormdist(_a3(0.0, 0.0, 1.0)), XL_ERR_NUM, "x <= 0 is #NUM!")
    _close(xl_loginv(_a3(0.5, 0.0, 1.0)), 1.0, "exp(0) = 1")
    _close(xl_loginv(_a3(0.975, 0.0, 1.0)), 7.099071384231331,
           "exp(1.95996) — only right if the inverse normal is right to "
           "more than nine digits")
    _close(xl_lognormdist(_a3(xl_loginv(_a3(0.3, 1.0, 2.0)).num, 1.0, 2.0)),
           0.3, "the round trip")


def test_NEGBINOMDIST_and_HYPGEOMDIST_are_MASS_only() raises:
    """Both lost a `cumulative` argument in 2010, and both rivals are larger
    probabilities that move monotonically in the same arguments."""
    _close(xl_negbinomdist(_a3(2.0, 3.0, 0.5)), 0.1875,
           "C(4,2)*0.5^5 = 0.1875, the MASS")
    _not_close(xl_negbinomdist(_a3(2.0, 3.0, 0.5)), 0.5,
               "⛔ NEGBINOM.DIST's CUMULATIVE answers 0.5 — 2.7x larger and "
               "still a probability")
    _close(xl_negbinomdist(_a3(0.0, 3.0, 0.5)), 0.125,
           "⚠ AT ZERO FAILURES THE CUMULATIVE HAS ONE TERM, so mass and "
           "cumulative coincide — the blind input, and the first case "
           "anybody writes")
    _err(xl_negbinomdist(_a3(2.0, 0.0, 0.5)), XL_ERR_NUM,
         "number_s < 1 is #NUM!: zero successes is not a waiting time")
    _close(xl_hypgeomdist(_a4(1.0, 4.0, 8.0, 20.0)), 0.3632610939112487,
           "C(8,1)C(12,3)/C(20,4)")
    _close(xl_hypgeomdist(_a4(1.0, 2.0, 3.0, 6.0)), 0.6,
           "9/15 on a second parameter set, so one hard-coded combinatorial "
           "shape cannot pass both")
    _err(xl_hypgeomdist(_a4(3.0, 2.0, 3.0, 6.0)), XL_ERR_NUM,
         "more successes than draws is #NUM!")
    _err(xl_hypgeomdist(_a4(0.0, 4.0, 2.0, 5.0)), XL_ERR_NUM,
         "⭐ THE **LOWER** FEASIBILITY BOUND. 4 draws from a population of "
         "5 holding 2 successes and only 3 failures MUST contain at least "
         "one success, so 0 is infeasible and Excel answers #NUM!. A "
         "kernel that checked only the upper bound reaches exp() of a "
         "log-binomial with a negative argument and returns a positive "
         "number. ⚠ The bound is n-(N-M) and NOT zero: at (0,4,1,5) — one "
         "success and FOUR failures — zero successes IS feasible, which is "
         "why this case names M=2")


# =============================================================================
# ★ THE EXACT RENAMES — asserted rather than assumed
# =============================================================================
def test_the_exponential_gamma_and_weibull_agree_only_at_shape_one() raises:
    """⚠ THE BLINDNESS IS THE POINT. At shape 1 the gamma and the Weibull ARE
    the exponential, so a fixture confined to shape 1 cannot tell the three
    functions apart at all. Shape 2 is where they separate."""
    _close(xl_expondist(_b2(2.0, 1.0, True)), 1.0 - _exp(-2.0),
           "EXPONDIST cumulative")
    _close(xl_expondist(_b2(2.0, 1.0, False)), _exp(-2.0), "and its density")
    _err(xl_expondist(_b2(1.0, 0.0, True)), XL_ERR_NUM, "lambda <= 0 is #NUM!")
    _close(xl_gammadist(_b3(2.0, 1.0, 1.0, True)), 1.0 - _exp(-2.0),
           "⚠ BLIND: the gamma at shape 1 IS the exponential")
    _close(xl_weibull(_b3(2.0, 1.0, 1.0, True)), 1.0 - _exp(-2.0),
           "⚠ BLIND: the Weibull at shape 1 IS the exponential too")
    _close(xl_gammadist(_b3(2.0, 2.0, 1.0, True)), 1.0 - 3.0 * _exp(-2.0),
           "SHARP: at shape 2 the gamma separates")
    _close(xl_gammadist(_b3(2.0, 2.0, 1.0, False)), 2.0 * _exp(-2.0),
           "and its density")
    _close(xl_weibull(_b3(2.0, 2.0, 1.0, True)), 1.0 - _exp(-4.0),
           "SHARP: at shape 2 the Weibull separates differently again")
    _close(xl_weibull(_b3(2.0, 2.0, 1.0, False)), 4.0 * _exp(-4.0),
           "and its density")
    _close(xl_gammadist(_b3(4.0, 2.0, 2.0, True)), 1.0 - 3.0 * _exp(-2.0),
           "⚠ beta is the SCALE: (4/2) reproduces the shape-2 value at x=2. "
           "A RATE parameterisation would answer the x=8 value instead")
    _close(xl_gammainv(_a3(0.5, 1.0, 2.0)), -2.0 * _log(0.5),
           "GAMMAINV at shape 1 is -beta*ln(1-p)")
    _close(xl_gammadist(_b3(xl_gammainv(_a3(0.4, 3.0, 1.5)).num,
                              3.0, 1.5, True)), 0.4,
           "the round trip at a NON-integer scale and shape 3")
    _err(xl_gammadist(_b3(1.0, 0.0, 1.0, True)), XL_ERR_NUM,
         "alpha <= 0 is #NUM!")


def test_the_discrete_family_is_exact_where_the_answer_is_a_rational() raises:
    # ⛔ MEASURED RED ON ITS FIRST RUN, AND THE ASSERTION WAS THE THING THAT
    # WAS WRONG. This line read `_num(..., 0.3125)` — an EXACT equality — on
    # the argument that C(5,2)/32 is exactly representable. It is; the
    # kernel's ROUTE to it is not. `exp(lgamma - lgamma - lgamma + k*log p +
    # ...)` landed on 0.31249999999999994, five ulps low. ⭐ THE DISTANCE IS
    # 5.6e-17 AND THE GRADED TOLERANCE IS 1e-12, so this is a correction of a
    # claim about the IMPLEMENTATION, not a loosening of a claim about the
    # VALUE — Excel itself computes this in binary floating point and makes no
    # exactness promise. It is also the measurement that says the value
    # oracle's atol=1e-12 is load-bearing rather than decorative: an
    # exact-equality cell there would red on a correct kernel.
    _close(xl_binomdist(_b3(2.0, 5.0, 0.5, False)), 0.3125,
           "C(5,2)/32 = 0.3125 to within 1e-12")
    _close(xl_binomdist(_b3(2.0, 5.0, 0.5, True)), 0.5,
           "the cumulative, through the incomplete-beta identity")
    _num(xl_binomdist(_b3(5.0, 5.0, 0.5, True)), 1.0,
         "k = n is the whole mass and must be EXACTLY 1, which the beta "
         "identity would not give — the kernel short-circuits it")
    _err(xl_binomdist(_b3(6.0, 5.0, 0.5, False)), XL_ERR_NUM,
         "more successes than trials is #NUM!")
    _close(xl_poisson(_b2(2.0, 3.0, False)), 4.5 * _exp(-3.0), "the mass")
    _close(xl_poisson(_b2(2.0, 3.0, True)), 8.5 * _exp(-3.0),
           "the cumulative, through gamma_q(k+1, mean)")
    _err(xl_poisson(_b2(-1.0, 3.0, True)), XL_ERR_NUM, "x < 0 is #NUM!")
    _num(xl_critbinom(_a3(10.0, 0.5, 0.75)), 6.0,
         "the first k whose cdf reaches 0.75")
    _num(xl_critbinom(_a3(10.0, 0.5, 0.5)), 5.0,
         "one lower — the alpha argument moves the answer by exactly one "
         "trial, the smallest change this function can express")
    _err(xl_critbinom(_a3(10.0, 0.5, 1.5)), XL_ERR_NUM,
         "alpha > 1 is #NUM!; returning `trials` would be plausible and wrong")
    # ⭐⭐ THE CELL THAT WOULD HAVE HUNG. CRITBINOM's search was a LINEAR scan
    # over `trials`, one incomplete-beta continued fraction per step, so this
    # legal call was ~1e8 inner iterations on a per-cell path. It is a
    # BISECTION now, and this asserts BOTH that it terminates and that it
    # lands on the right side of a symmetric distribution's median: at
    # p = 0.5 the cumulative first reaches 0.5 at k = n/2.
    _num(xl_critbinom(_a3(1000000.0, 0.5, 0.5)), 500000.0,
         "CRITBINOM over a million trials — O(log n) evaluations, not O(n)")
    _num(xl_critbinom(_a3(1000000.0, 0.5, 0.0)), 0.0,
         "⚠ alpha = 0 IS SATISFIED AT k = 0, and the BACK-WALK is what makes "
         "that the answer: a bisection alone may land anywhere in the "
         "plateau where every k satisfies the predicate")
    _close(xl_confidence(_a3(0.05, 1.0, 100.0)), 0.19599639845400535,
           "⭐ TWO-SIDED: NORMSINV(1-alpha/2)/10")
    _not_close(xl_confidence(_a3(0.05, 1.0, 100.0)), 0.16448536269514722,
               "⛔ the ONE-SIDED spelling gives a 16% narrower interval and "
               "a number nobody would question")
    _err(xl_confidence(_a3(0.0, 1.0, 100.0)), XL_ERR_NUM, "alpha <= 0 is #NUM!")


def test_BETADIST_reads_arguments_four_and_five_as_BOUNDS() raises:
    """⛔ THE ARGUMENT-POSITION DIVERGENCE. `BETA.DIST` inserted `cumulative`
    at position 4, exactly where this name has the lower bound `A`."""
    _close(xl_betadist(_a3(0.5, 2.0, 1.0)), 0.25, "I_x(2,1) = x^2")
    _close(xl_betadist(_a5(2.0, 1.0, 1.0, 1.0, 3.0)), 0.5,
           "⭐ arguments 4 and 5 are A and B: (2-1)/(3-1) = 0.5")
    # ⚠ THE SAME CORRECTION, AND A SHARPER ONE: the UNIFORM case is the
    # identity `I_x(1,1) = x`, so an exact 0.5 looks obviously right — and the
    # modified-Lentz continued fraction reaches it as 0.4999999999999991, nine
    # ulps low. A continued fraction does not terminate on a polynomial.
    _close(xl_betadist(_a3(0.5, 1.0, 1.0)), 0.5,
           "⚠ THE BLIND CELL: with the bounds defaulted the uniform case is "
           "the identity and every reading of the trailing arguments agrees")
    _err(xl_betadist(_a5(4.0, 1.0, 1.0, 1.0, 3.0)), XL_ERR_NUM,
         "x above B is #NUM!")
    _err(xl_betadist(_a3(0.5, 0.0, 1.0)), XL_ERR_NUM, "alpha <= 0 is #NUM!")
    _close(xl_betainv(_a3(0.25, 2.0, 1.0)), 0.5,
           "BETAINV inverts it: sqrt(0.25)")
    _close(xl_betainv(_a5(0.5, 1.0, 1.0, 1.0, 3.0)), 2.0,
           "and BETA.INV kept these positions — the shift that hit BETADIST "
           "did NOT hit its inverse")
    _close(xl_betadist(_a3(xl_betainv(_a3(0.7, 2.5, 3.5)).num, 2.5, 3.5)),
           0.7, "the round trip at NON-INTEGER shapes, where the reflection "
           "arm of `xl_lgamma` is on the path")


# =============================================================================
# ⭐ THE ONE `Web` NAME THAT NEEDS NO NETWORK
# =============================================================================
def test_ENCODEURL_percent_encodes_the_UTF8_BYTES() raises:
    """⭐ THE BRIEF THAT OPENED THIS SLICE SAID THE WHOLE `Web` CATEGORY NEEDED
    NETWORK ACCESS. `ENCODEURL` performs no I/O at all."""
    assert_equal(
        xl_encodeurl(_text(String("a b"))).text, String("a%20b"),
        "SPACE is %20",
    )
    assert_equal(
        xl_encodeurl(_text(String("http://x.com/a b"))).text,
        String("http%3A%2F%2Fx.com%2Fa%20b"),
        "the shape Microsoft's published example pins: `:` and `/` escaped, "
        "`.` and the alphanumerics not, hex digits UPPER-CASE",
    )
    assert_equal(
        xl_encodeurl(_text(String("ä"))).text, String("%C3%A4"),
        "⭐ THE UTF-8 BYTES, NOT THE CODE POINT: a Latin-1 encoder answers "
        "%E4 and an ASCII-only fixture cannot tell the two apart",
    )
    assert_equal(
        xl_encodeurl(_text(String("aZ09"))).text, String("aZ09"),
        "alphanumerics pass through untouched",
    )
    assert_equal(
        xl_encodeurl(_text(String(""))).text, String(""),
        "the empty string is the empty string, not an error",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

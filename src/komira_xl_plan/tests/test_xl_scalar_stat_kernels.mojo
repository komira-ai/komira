# =============================================================================
# test_xl_scalar_stat_kernels.mojo — ★ THE EXCEL STATISTICAL DISTRIBUTION
#                                      FAMILY, GRADED AT PUBLISHED VALUES.
# =============================================================================
#
# Sibling of `test_xl_scalar_kernels.mojo` and bound by the same two rules,
# which this family makes sharper than any other:
#
#   1. ⛔ EVERY ASSERTION IS ABOUT A CASE WHERE THE OBVIOUS IMPLEMENTATION IS
#      WRONG. Not one test per function.
#   2. ⛔ AND THE ARGUMENT HAS TO BE ONE WHERE THE WRONG IMPLEMENTATION ANSWERS
#      DIFFERENTLY. That second half cost the sibling eight silent kernels —
#      every transcendental was asserted at x = 0, where `sin`/`tan`/`atan`/
#      `asin`/`sinh`/`tanh` all return 0.0, so eight mutants each swapping one
#      libm call for a sibling's passed.
#
# ======= ⛔⛔ WHY THIS FAMILY IS THE WORST CASE FOR RULE 2 ===================
#
# **THE WRONG ANSWER IS STILL A PROBABILITY.** Every near-neighbour below
# returns a number in [0,1] for the same arguments, so a range check, a
# "is it finite" check and a loose tolerance all pass on the mis-wired kernel:
#
#   CHISQ.DIST <-> CHISQ.DIST.RT      one is 1 minus the other
#   T.DIST.RT  <-> T.DIST.2T          differ by EXACTLY a factor of 2
#   F.INV      <-> F.INV.RT           reciprocal-ish, both positive
#   NORM.S.DIST(z,TRUE) <-> (z,FALSE) the flag ignored
#   PHI        <-> GAUSS              0.3011 vs 0.2734 at x=0.75
#   GAMMALN    <-> LN                 1.7918 vs 1.3863 at 4
#   GAMMA      <-> FACT               EQUAL at every integer
#   PERMUT     <-> COMBIN             20 vs 10 at (5,2); EQUAL at k<=1
#   CONFIDENCE.NORM <-> CONFIDENCE.T  agree asymptotically in n
#
# ======= ⚠ THE `.DIST`/`.INV` TRAP, AND HOW THIS FILE AVOIDS IT =============
#
# An inverse implemented by bisection over its OWN forward function agrees with
# itself at every tolerance. So every `.INV` assertion here carries a
# **PUBLISHED** value — the standard chi-square / t / F tables, and Microsoft's
# own documented worked examples — and NOT a round trip. The two round-trip
# tests present are LABELLED as secondary and are about the ARGUMENT
# TRANSFORM, not about the numerics.
#
# ⚠ TOLERANCES ARE RELATIVE AND ARGUED, not uniform: 1e-12 where the published
# value carries 16 digits (the chi-square table, AS241), 1e-6 where Microsoft's
# documentation rounds its example to 7 significant figures. A single loose
# tolerance everywhere would hide a real divergence in the tight cells.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.plan.excel_error_code import (
    XL_ERR_DIV0,
    XL_ERR_NUM,
)

from komira_xl_plan.formula_value import FormulaValue
from komira_xl_plan.xl_special_fn import (
    betai,
    gamma_p,
    gamma_q,
    norm_s_cdf,
    norm_s_inv,
    norm_s_pdf,
    xs_lgamma,
)

# ⭐⭐ THE SECOND IMPLEMENTATION. `xl_stat_special.mojo` landed on trunk the
# SAME DAY as `xl_special_fn.mojo`, from a different worktree, carrying the
# SAME FIVE PRIMITIVES for the Compatibility category's pre-2010 spellings.
# See `test_the_TWO_special_function_modules_AGREE` at the end of this file.
from komira_xl_plan.xl_stat_special import (
    betainc_reg,
    norm_sdist,
    norm_sinv,
    xl_lgamma,
)
from komira_xl_plan.xl_scalar_compat_stat import xl_norminv
from komira_xl_plan.xl_stat_special import gamma_p as gamma_p_2
from komira_xl_plan.xl_stat_special import gamma_q as gamma_q_2
from komira_xl_plan.xl_scalar_stat import (
    xl_beta_dist,
    xl_beta_inv,
    xl_binom_dist,
    xl_binom_dist_range,
    xl_binom_inv,
    xl_chisq_dist,
    xl_chisq_dist_rt,
    xl_chisq_inv,
    xl_chisq_inv_rt,
    xl_confidence_norm,
    xl_confidence_t,
    xl_expon_dist,
    xl_f_dist,
    xl_f_dist_rt,
    xl_f_inv,
    xl_f_inv_rt,
    xl_fisher,
    xl_fisherinv,
    xl_gamma_dist,
    xl_gamma_fn,
    xl_gamma_inv,
    xl_gammaln,
    xl_gammaln_precise,
    xl_gauss,
    xl_hypgeom_dist,
    xl_lognorm_dist,
    xl_lognorm_inv,
    xl_negbinom_dist,
    xl_norm_dist,
    xl_norm_inv,
    xl_norm_s_dist,
    xl_norm_s_inv,
    xl_permut,
    xl_permutationa,
    xl_phi,
    xl_poisson_dist,
    xl_standardize,
    xl_t_dist,
    xl_t_dist_2t,
    xl_t_dist_rt,
    xl_t_inv,
    xl_t_inv_2t,
    xl_weibull_dist,
)


# =============================================================================
# Argument builders. ⚠ ONE PER ARITY — a variadic builder would hide an arity
# defect, which is half of what this family gets wrong.
# =============================================================================
def _a1(a0: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(a0))
    return a^


def _a2(a0: Float64, a1: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(a0))
    a.append(FormulaValue.number(a1))
    return a^


def _a3(a0: Float64, a1: Float64, a2: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(a0))
    a.append(FormulaValue.number(a1))
    a.append(FormulaValue.number(a2))
    return a^


def _a1b(a0: Float64, flag: Bool) -> List[FormulaValue]:
    """⚠ ARITY **2**: one number and the `cumulative` flag. `NORM.S.DIST` is
    the only member of this family shaped like that, and building it with the
    3-arity `_a2b` silently passes 0.0 as `cumulative` — which coerces to
    FALSE and returns the DENSITY. That mistake is what this builder exists to
    make unspellable."""
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(a0))
    a.append(FormulaValue.logical_val(flag))
    return a^


def _a2b(a0: Float64, a1: Float64, flag: Bool) -> List[FormulaValue]:
    var a = _a2(a0, a1)
    a.append(FormulaValue.logical_val(flag))
    return a^


def _a3b(a0: Float64, a1: Float64, a2: Float64, flag: Bool) -> List[FormulaValue]:
    var a = _a3(a0, a1, a2)
    a.append(FormulaValue.logical_val(flag))
    return a^


def _abs(x: Float64) -> Float64:
    return -x if x < 0.0 else x


def _close(r: FormulaValue, want: Float64, rel: Float64, why: String) raises:
    """Assert a NUMBER within a RELATIVE tolerance of a published value.

    ⛔ IT REFUSES AN ERROR RESULT BY NAME rather than comparing `.num`, which
    on an error `FormulaValue` is 0.0 — and `0.0` would silently pass any cell
    whose published value is 0."""
    assert_true(
        r.is_number(),
        why + " — expected a NUMBER, got `" + r.render() + "`",
    )
    var d = _abs(r.num - want)
    var denom = _abs(want) if want != 0.0 else 1.0
    assert_true(
        d / denom <= rel,
        why
        + " — got "
        + String(r.num)
        + ", published "
        + String(want)
        + ", rel err "
        + String(d / denom),
    )


def _apart(a: FormulaValue, b: FormulaValue, why: String) raises:
    """⭐ THE ANTI-VACUITY ASSERTION. Two kernels that are near-neighbours must
    NOT return the same number at the graded input — otherwise the cell above
    grades nothing, because either wiring passes it."""
    assert_true(a.is_number() and b.is_number(), why + " — both must answer")
    assert_true(
        _abs(a.num - b.num) > 1e-9 * (1.0 + _abs(a.num)),
        why
        + " — the two answers COLLIDE at "
        + String(a.num)
        + ", so the graded cell cannot discriminate",
    )


def _assert_err(r: FormulaValue, code: UInt8, why: String) raises:
    assert_true(
        r.is_error(), why + " — expected an ERROR, got `" + r.render() + "`"
    )
    assert_equal(Int(r.error_code), Int(code), why)


# =============================================================================
# ★★ THE STANDARD NORMAL
# =============================================================================
def test_norm_s_dist_honours_the_cumulative_flag() raises:
    """⛔ THE TWIN IS ITS OWN OTHER ARM. A kernel that ignored `cumulative`
    answers 0.5 for `NORM.S.DIST(0, FALSE)` where Excel says 0.3989422804 —
    and 0.5 is a perfectly plausible probability."""
    _close(
        xl_norm_s_dist(_a1b(1.96, True)),
        0.9750021048517795,
        1e-13,
        "NORM.S.DIST(1.96, TRUE) is the published 0.9750021048517795",
    )
    _close(
        xl_norm_s_dist(_a1b(0.0, False)),
        0.3989422804014327,
        1e-14,
        "★ NORM.S.DIST(0, FALSE) is the DENSITY 1/sqrt(2pi), not the CDF 0.5",
    )
    _apart(
        xl_norm_s_dist(_a1b(0.0, True)),
        xl_norm_s_dist(_a1b(0.0, False)),
        "★ the two arms must differ at z=0 or the flag is untested",
    )


def test_norm_s_inv_matches_AS241_at_published_quantiles() raises:
    """⚠ GRADED AT 0.975 AND 0.001, NOT AT 0.5. `NORM.S.INV(0.5)` is EXACTLY
    0 and a constant-zero kernel survives it; the two published quantiles
    below are the standard two-sided 95% critical value and a deep tail."""
    _close(
        xl_norm_s_inv(_a1(0.975)),
        1.959963984540054,
        1e-14,
        "NORM.S.INV(0.975) is the published 1.959963984540054",
    )
    _close(
        xl_norm_s_inv(_a1(0.001)),
        -3.090232306167813,
        1e-14,
        "★ THE DEEP TAIL. AS241's third branch; a two-branch approximation "
        "loses digits here and nowhere else",
    )
    _assert_err(
        xl_norm_s_inv(_a1(0.0)),
        XL_ERR_NUM,
        "⛔ p=0 is #NUM!, not -inf — an infinity travels through every "
        "comparison above it",
    )
    _assert_err(
        xl_norm_s_inv(_a1(1.0)),
        XL_ERR_NUM,
        "and p=1 likewise",
    )


def test_norm_dist_density_carries_the_sd_jacobian() raises:
    """⛔ THE DEFECT A SD OF 1 CANNOT SEE. `NORM.DIST(x,m,s,FALSE)` is
    phi(z)/s; dropping the /s gives a curve integrating to s instead of 1, and
    at s=1 the two are IDENTICAL. Graded at s=1.5."""
    _close(
        xl_norm_dist(_a3b(42.0, 40.0, 1.5, True)),
        0.9087887802741321,
        1e-12,
        "NORM.DIST(42,40,1.5,TRUE) — Microsoft's own documented example",
    )
    _close(
        xl_norm_dist(_a3b(42.0, 40.0, 1.5, False)),
        0.10934004978399577,
        1e-12,
        "★ NORM.DIST(42,40,1.5,FALSE) = phi(4/3)/1.5. WITHOUT the 1/s it is "
        "0.16401, which is still a plausible density",
    )
    _assert_err(
        xl_norm_dist(_a3b(42.0, 40.0, 0.0, True)),
        XL_ERR_NUM,
        "⛔ sd = 0 is #NUM!, NOT a division producing inf then a plausible 1.0",
    )


def test_norminv_takes_the_probability_FIRST_and_matches_its_twin() raises:
    """⚠ THE ARGUMENT ORDER IS REVERSED FROM `NORM.DIST`'s. A shared unpacking
    helper would read `mean` as the probability and still answer a number.

    ⭐ AND THE CENSUS SPELLING IS `NORMINV`, NOT `NORM.INV`. Microsoft's own
    alphabetical list files `NORM.INV` under *Compatibility* and `NORMINV`
    under *Statistical* — inverted against every other legacy/modern pair on
    the page — so the two slices working that day each took the row their
    published category gave them. Both spellings are now served, by TWO
    kernels, and the last assertion here grades them against each other rather
    than assuming an alias."""
    _close(
        xl_norm_inv(_a3(0.908789, 40.0, 1.5)),
        42.00000200956616,
        1e-10,
        "NORMINV(0.908789,40,1.5) round-trips Microsoft's NORM.DIST example",
    )
    _assert_err(
        xl_norm_inv(_a3(1.0, 40.0, 1.5)),
        XL_ERR_NUM,
        "p = 1 is #NUM!",
    )
    for i in range(1, 20):
        var pr = Float64(i) * 0.05
        var mine = xl_norm_inv(_a3(pr, 40.0, 1.5))
        var theirs = xl_norminv(_a3(pr, 40.0, 1.5))
        assert_true(
            mine.is_number() and theirs.is_number()
            and _abs(mine.num - theirs.num) <= 1e-10,
            "★ NORMINV and NORM.INV must answer the SAME number at p="
            + String(pr),
        )


def test_phi_is_a_density_and_gauss_is_a_cdf_minus_a_half() raises:
    """⛔ THE 2013 PAIR. Both return a number in (0, 0.5) for a positive
    argument, so only the VALUE separates them."""
    _close(
        xl_phi(_a1(0.75)),
        0.30113743215480443,
        1e-13,
        "PHI(0.75) — Microsoft's documented 0.301137432",
    )
    _close(
        xl_gauss(_a1(2.0)),
        0.4772498680518208,
        1e-13,
        "GAUSS(2) — Microsoft's documented 0.477250, i.e. Phi(2) - 0.5",
    )
    _apart(
        xl_phi(_a1(0.75)),
        xl_gauss(_a1(0.75)),
        "★ PHI and GAUSS must differ at 0.75",
    )
    _apart(
        xl_gauss(_a1(2.0)),
        xl_norm_s_dist(_a1b(2.0, True)),
        "★ and GAUSS is NOT NORM.S.DIST — forgetting the -0.5 gives 0.9772",
    )


# =============================================================================
# ★★ GAMMALN / GAMMA — the two twins already registered in this tree
# =============================================================================
def test_gammaln_is_not_ln_and_gamma_is_not_fact() raises:
    """⛔ BOTH TWINS ARE LIVE ROWS IN `xl_fn_table` ALREADY — `LN` and `FACT` —
    so a mis-wired registry row here reaches a REAL kernel of the right shape
    and answers a plausible number rather than `#NAME?`."""
    _close(
        xl_gammaln(_a1(4.0)),
        1.791759469228055,
        1e-13,
        "GAMMALN(4) = ln(3!) = ln 6 = 1.791759469. `LN(4)` is 1.386294361",
    )
    _close(
        xl_gammaln_precise(_a1(2.5)),
        0.2846828704729196,
        1e-13,
        "GAMMALN.PRECISE(2.5) — the SAME function as GAMMALN, deliberately",
    )
    _close(
        xl_gamma_fn(_a1(2.5)),
        1.329340388179137,
        1e-13,
        "★ GAMMA(2.5) = 1.329340388. `FACT` truncates to 2 and answers 2 — "
        "the ONLY kind of argument that separates them, since GAMMA(n) = "
        "(n-1)! at every integer",
    )
    _close(
        xl_gamma_fn(_a1(5.0)),
        24.0,
        1e-13,
        "⚠ THE COLLISION, PINNED: GAMMA(5) IS 24 = FACT(4), so an integer "
        "fixture cannot tell a shifted factorial from this",
    )
    _close(
        xl_gamma_fn(_a1(-1.5)),
        2.363271801207355,
        1e-12,
        "★ A NEGATIVE NON-INTEGER IS DEFINED and POSITIVE here — "
        "`exp(lgamma(x))` alone cannot produce the alternating sign",
    )
    _assert_err(
        xl_gamma_fn(_a1(-2.0)),
        XL_ERR_NUM,
        "⛔ a negative INTEGER is a POLE — #NUM!, not a finite number",
    )
    _assert_err(
        xl_gammaln(_a1(0.0)),
        XL_ERR_NUM,
        "GAMMALN(0) is #NUM! where libm lgamma(0) is +inf",
    )


# =============================================================================
# ★★ CHI-SQUARE — left tail, right tail, and both inverses
# =============================================================================
def test_chisq_left_and_right_tails_are_different_numbers() raises:
    """⛔ ONE IS 1 MINUS THE OTHER AND BOTH ARE PROBABILITIES."""
    _close(
        xl_chisq_dist(_a2b(0.5, 1.0, True)),
        0.5204998778130465,
        1e-12,
        "CHISQ.DIST(0.5,1,TRUE) — Microsoft's documented 0.52049988",
    )
    _close(
        xl_chisq_dist(_a2b(0.5, 1.0, False)),
        0.43939128946772243,
        1e-12,
        "★ the DENSITY arm. Microsoft's documented 0.439391289",
    )
    _close(
        xl_chisq_dist_rt(_a2(18.307038053275146, 10.0)),
        0.05,
        1e-11,
        "CHISQ.DIST.RT(18.30703805,10) is the published 0.05 table entry",
    )
    _apart(
        xl_chisq_dist(_a2b(18.307038053275146, 10.0, True)),
        xl_chisq_dist_rt(_a2(18.307038053275146, 10.0)),
        "★ LEFT and RIGHT tail must differ — 0.95 against 0.05",
    )


def test_the_chisq_inverses_match_the_published_table() raises:
    """⚠ PUBLISHED VALUES, NOT A ROUND TRIP. 18.30703805327515 is the 0.05
    column at 10 df of the standard chi-square table."""
    _close(
        xl_chisq_inv_rt(_a2(0.05, 10.0)),
        18.3070380533,
        1e-10,
        "CHISQ.INV.RT(0.05,10) is the published 18.30703805327515",
    )
    _close(
        xl_chisq_inv(_a2(0.93, 1.0)),
        3.283020287,
        1e-8,
        "CHISQ.INV(0.93,1) — Microsoft's documented 3.283020287",
    )
    _apart(
        xl_chisq_inv(_a2(0.05, 10.0)),
        xl_chisq_inv_rt(_a2(0.05, 10.0)),
        "★ the two inverses must differ — 3.94 against 18.31",
    )
    _assert_err(
        xl_chisq_dist_rt(_a2(1.0, 0.0)),
        XL_ERR_NUM,
        "df = 0 is #NUM!",
    )


# =============================================================================
# ★★ STUDENT'S t — THREE `.DIST` spellings and TWO inverses
# =============================================================================
def test_the_three_t_dist_spellings_are_three_numbers() raises:
    """⛔ `T.DIST.2T` IS EXACTLY TWICE `T.DIST.RT` FOR POSITIVE x, so a wiring
    swap between those two looks like a factor-of-2 tolerance problem rather
    than a wrong function."""
    var x: Float64 = 1.8124611228107335  # the 0.05 right-tail point at 10 df
    _close(
        xl_t_dist(_a2b(x, 10.0, True)),
        0.95,
        1e-11,
        "T.DIST(1.81246,10,TRUE) is the LEFT tail 0.95",
    )
    _close(
        xl_t_dist_rt(_a2(x, 10.0)),
        0.05,
        1e-10,
        "T.DIST.RT(1.81246,10) is the published right tail 0.05",
    )
    _close(
        xl_t_dist_2t(_a2(x, 10.0)),
        0.10,
        1e-10,
        "★ and T.DIST.2T is 0.10 — EXACTLY TWICE the right tail",
    )
    _close(
        xl_t_dist(_a2b(60.0, 1.0, True)),
        0.9946953263673768,
        1e-12,
        "T.DIST(60,1,TRUE) — Microsoft's documented 0.99469533",
    )
    _close(
        xl_t_dist(_a2b(8.0, 3.0, False)),
        0.0007369065209469264,
        1e-12,
        "★ the DENSITY arm at df=3 — Microsoft's documented 0.000736910",
    )


def test_t_dist_rt_is_signed_where_t_dist_2t_REFUSES_a_negative() raises:
    """⭐ THE ONE DOMAIN DIFFERENCE INSIDE THE t FAMILY, and it is what makes
    the two names distinguishable by SHAPE and not only by value. A kernel
    sharing `T.DIST.RT`'s body would answer 1.83 for `T.DIST.2T(-1,10)` — a
    "probability" ABOVE 1 — and a kernel taking `|x|` in RT would answer
    0.1704 instead of 0.8296 for `T.DIST.RT(-1,10)`."""
    _close(
        xl_t_dist_rt(_a2(-1.0, 10.0)),
        0.8295534338489701,
        1e-11,
        "★ T.DIST.RT(-1,10) is ABOVE 0.5 — an |x| kernel answers 0.1704",
    )
    _assert_err(
        xl_t_dist_2t(_a2(-1.0, 10.0)),
        XL_ERR_NUM,
        "⛔ T.DIST.2T REFUSES a negative x; T.DIST.RT does not",
    )


def test_the_t_inverses_match_the_published_table() raises:
    """⚠ 2.228138852 is the 95% two-sided row at 10 df of the standard
    t-table. ⛔ `T.INV.2T`'s argument is the TOTAL tail mass: off by that
    factor it answers 1.812461, which is a REAL entry in the same table."""
    _close(
        xl_t_inv_2t(_a2(0.05, 10.0)),
        2.228138852,
        1e-9,
        "T.INV.2T(0.05,10) is the published 2.228138852",
    )
    _close(
        xl_t_inv(_a2(0.75, 2.0)),
        0.8164965809277261,
        1e-11,
        "T.INV(0.75,2) — Microsoft's documented 0.816496581",
    )
    _close(
        xl_t_inv(_a2(0.25, 2.0)),
        -0.8164965809277261,
        1e-11,
        "★ T.INV IS SIGNED below p=0.5 where T.INV.2T is always positive",
    )
    _apart(
        xl_t_inv(_a2(0.05, 10.0)),
        xl_t_inv_2t(_a2(0.05, 10.0)),
        "★ the two t inverses must differ — -1.81 against +2.23",
    )


# =============================================================================
# ★★ F — and the two df are not interchangeable
# =============================================================================
def test_the_f_family_matches_the_published_table() raises:
    """⚠ Microsoft's own worked example is F.DIST.RT(15.20686,6,4) = 0.01 and
    F.INV.RT(0.01,6,4) = 15.20686. ⛔ SWAPPING THE TWO df GIVES 0.0209 — also
    a p-value — and they are equal only when d1 == d2."""
    _close(
        xl_f_dist_rt(_a3(15.20686, 6.0, 4.0)),
        0.01,
        1e-6,
        "F.DIST.RT(15.20686,6,4) is the documented 0.01",
    )
    _close(
        xl_f_inv_rt(_a3(0.01, 6.0, 4.0)),
        15.20686,
        1e-6,
        "F.INV.RT(0.01,6,4) is the documented 15.20686",
    )
    _close(
        xl_f_dist(_a3b(15.20686, 6.0, 4.0, True)),
        0.99,
        1e-6,
        "★ F.DIST is the LEFT tail — the complement of the row above",
    )
    _apart(
        xl_f_dist_rt(_a3(15.20686, 6.0, 4.0)),
        xl_f_dist_rt(_a3(15.20686, 4.0, 6.0)),
        "★ THE TWO df ARE NOT INTERCHANGEABLE — a swap must change the answer",
    )
    _apart(
        xl_f_inv(_a3(0.01, 6.0, 4.0)),
        xl_f_inv_rt(_a3(0.01, 6.0, 4.0)),
        "★ F.INV against F.INV.RT — 0.109 against 15.21",
    )


# =============================================================================
# ★★ BETA — the rescaled support is the discriminator
# =============================================================================
def test_beta_dist_rescales_by_A_and_B_and_the_density_carries_the_jacobian() raises:
    """⚠ Microsoft's own example is `BETA.DIST(2,8,10,TRUE,1,3)` = 0.6854706 —
    which is `I_0.5(8,10)`. ⛔ A KERNEL IGNORING A AND B evaluates at x=2,
    outside [0,1], and answers exactly 1.0.

    ⛔ AND THE DENSITY ARM CARRIES 1/(B-A): Microsoft's 1.4837646 is the
    unit-interval density 2.9675 HALVED. Dropping the Jacobian doubles it."""
    # ⚠ THE 6-ARITY FORM IS BUILT BY HAND: `cumulative` is argument 4 and
    # A / B are 5 and 6, so no positional builder in this file fits it.
    var cum = List[FormulaValue]()
    cum.append(FormulaValue.number(2.0))
    cum.append(FormulaValue.number(8.0))
    cum.append(FormulaValue.number(10.0))
    cum.append(FormulaValue.logical_val(True))
    cum.append(FormulaValue.number(1.0))
    cum.append(FormulaValue.number(3.0))
    _close(
        xl_beta_dist(cum),
        0.685470581,
        1e-8,
        "BETA.DIST(2,8,10,TRUE,1,3) — Microsoft's documented 0.685470581",
    )
    var den = List[FormulaValue]()
    den.append(FormulaValue.number(2.0))
    den.append(FormulaValue.number(8.0))
    den.append(FormulaValue.number(10.0))
    den.append(FormulaValue.logical_val(False))
    den.append(FormulaValue.number(1.0))
    den.append(FormulaValue.number(3.0))
    _close(
        xl_beta_dist(den),
        1.4837646484375062,
        1e-10,
        "★ the DENSITY arm carries 1/(B-A) — Microsoft's documented 1.4837646",
    )
    var inv = List[FormulaValue]()
    inv.append(FormulaValue.number(0.6854705810546875))
    inv.append(FormulaValue.number(8.0))
    inv.append(FormulaValue.number(10.0))
    inv.append(FormulaValue.number(1.0))
    inv.append(FormulaValue.number(3.0))
    _close(
        xl_beta_inv(inv),
        2.0,
        1e-9,
        "BETA.INV(0.685470581,8,10,1,3) = 2 — Microsoft's documented PAIR, so "
        "this is a PUBLISHED value and not a self-consistency check",
    )
    var oob = List[FormulaValue]()
    oob.append(FormulaValue.number(0.5))
    oob.append(FormulaValue.number(8.0))
    oob.append(FormulaValue.number(10.0))
    oob.append(FormulaValue.logical_val(True))
    oob.append(FormulaValue.number(1.0))
    oob.append(FormulaValue.number(3.0))
    _assert_err(
        xl_beta_dist(oob),
        XL_ERR_NUM,
        "⛔ x below A is #NUM!, not a clamp to 0",
    )


# =============================================================================
# ★★ THE GAMMA-FAMILY CONTINUOUS DISTRIBUTIONS
# =============================================================================
def test_gamma_dist_beta_is_a_SCALE_not_a_rate() raises:
    """⛔ A RATE-PARAMETER KERNEL (dividing where this multiplies) answers
    1.0 to nine digits for Microsoft's own example — a number no range check
    rejects."""
    _close(
        xl_gamma_dist(_a3b(10.00001131, 9.0, 2.0, True)),
        0.06809400386978731,
        1e-9,
        "GAMMA.DIST(10.00001131,9,2,TRUE) — Microsoft's documented 0.068094",
    )
    _close(
        xl_gamma_dist(_a3b(10.00001131, 9.0, 2.0, False)),
        0.03263913041829396,
        1e-11,
        "★ the DENSITY arm — Microsoft's documented 0.032639",
    )
    _close(
        xl_gamma_inv(_a3(0.068094, 9.0, 2.0)),
        10.0000112,
        1e-7,
        "★ GAMMA.INV(0.068094,9,2) = 10.0000112 — Microsoft's own documented "
        "PAIR with the GAMMA.DIST cell above, so it is a PUBLISHED value and "
        "not a round trip over this tree's own forward function",
    )


def test_poisson_cumulative_is_the_gamma_q_identity() raises:
    """⚠ Microsoft's own example: POISSON.DIST(2,5,TRUE) = 0.124652 and
    (2,5,FALSE) = 0.084224. ⛔ A KERNEL IGNORING THE FLAG passes whichever
    single cell it is given."""
    _close(
        xl_poisson_dist(_a2b(2.0, 5.0, True)),
        0.12465201948308113,
        1e-11,
        "POISSON.DIST(2,5,TRUE) — Microsoft's documented 0.124652",
    )
    _close(
        xl_poisson_dist(_a2b(2.0, 5.0, False)),
        0.08422433748856832,
        1e-11,
        "★ POISSON.DIST(2,5,FALSE) — the point mass, 0.084224",
    )
    _apart(
        xl_poisson_dist(_a2b(2.0, 5.0, True)),
        xl_poisson_dist(_a2b(2.0, 5.0, False)),
        "★ the two arms must differ",
    )


def test_expon_dist_lambda_is_a_RATE_and_the_density_exceeds_one() raises:
    """⛔ A MEAN-PARAMETER KERNEL answers 0.0198 where Excel says 0.8646647,
    and a kernel that clamped the density to a probability would be wrong
    and would look safe: EXPON.DIST(0.2,10,FALSE) is 1.3533528."""
    _close(
        xl_expon_dist(_a2b(0.2, 10.0, True)),
        0.8646647167633873,
        1e-13,
        "EXPON.DIST(0.2,10,TRUE) — Microsoft's documented 0.864665",
    )
    _close(
        xl_expon_dist(_a2b(0.2, 10.0, False)),
        1.353352832366127,
        1e-13,
        "★ EXPON.DIST(0.2,10,FALSE) is 1.3533 — a DENSITY above 1",
    )


def test_weibull_is_shape_then_scale() raises:
    """⚠ SWAPPED, `WEIBULL.DIST(105,20,100,TRUE)` answers 1.0 instead of
    0.9295813 — a wrong answer at the top of the probability range."""
    _close(
        xl_weibull_dist(_a3b(105.0, 20.0, 100.0, True)),
        0.9295813900692769,
        1e-11,
        "WEIBULL.DIST(105,20,100,TRUE) — Microsoft's documented 0.929581",
    )
    _close(
        xl_weibull_dist(_a3b(105.0, 20.0, 100.0, False)),
        0.0355888640245043,
        1e-11,
        "★ the DENSITY arm — Microsoft's documented 0.035589",
    )


def test_lognormal_is_not_normal_and_its_inverse_exponentiates() raises:
    """⛔ THE TWIN IS `NORM.DIST` ON THE SAME ARGUMENTS: 0.6615 against
    0.0390836. Both probabilities."""
    _close(
        xl_lognorm_dist(_a3b(4.0, 3.5, 1.2, True)),
        0.0390835557068005,
        1e-12,
        "LOGNORM.DIST(4,3.5,1.2,TRUE) — Microsoft's documented 0.0390836",
    )
    _apart(
        xl_lognorm_dist(_a3b(4.0, 3.5, 1.2, True)),
        xl_norm_dist(_a3b(4.0, 3.5, 1.2, True)),
        "★ LOGNORM.DIST must not equal NORM.DIST on the same arguments",
    )
    _close(
        xl_lognorm_inv(_a3(0.039084, 3.5, 1.2)),
        4.000025218680636,
        1e-10,
        "LOGNORM.INV(0.039084,3.5,1.2) — Microsoft's documented 4.0000252",
    )
    _assert_err(
        xl_lognorm_dist(_a3b(0.0, 3.5, 1.2, True)),
        XL_ERR_NUM,
        "⛔ x = 0 is outside the support — #NUM!, not 0",
    )


# =============================================================================
# ★★ THE DISCRETE FAMILY
# =============================================================================
def test_binom_pmf_and_cdf_and_the_RANGE_form_argument_order() raises:
    """⛔ `BINOM.DIST.RANGE` TAKES TRIALS FIRST WHERE `BINOM.DIST` TAKES
    SUCCESSES FIRST. A shared unpacking helper answers a plausible
    probability."""
    _close(
        xl_binom_dist(_a3b(6.0, 10.0, 0.5, False)),
        0.205078125,
        1e-14,
        "BINOM.DIST(6,10,0.5,FALSE) = 210/1024 — EXACT in binary64",
    )
    _close(
        xl_binom_dist(_a3b(6.0, 10.0, 0.5, True)),
        0.828125,
        1e-13,
        "★ the CUMULATIVE arm = 848/1024, also exact",
    )
    var rng = List[FormulaValue]()
    rng.append(FormulaValue.number(60.0))
    rng.append(FormulaValue.number(0.75))
    rng.append(FormulaValue.number(48.0))
    _close(
        xl_binom_dist_range(rng),
        0.08397496742904985,
        1e-9,
        "BINOM.DIST.RANGE(60,0.75,48) — Microsoft's documented 0.084, and it "
        "is the POINT MASS, not a cumulative",
    )
    var rng2 = List[FormulaValue]()
    rng2.append(FormulaValue.number(60.0))
    rng2.append(FormulaValue.number(0.75))
    rng2.append(FormulaValue.number(45.0))
    rng2.append(FormulaValue.number(50.0))
    _close(
        xl_binom_dist_range(rng2),
        0.5236297934718872,
        1e-9,
        "★ BINOM.DIST.RANGE(60,0.75,45,50) — Microsoft's documented 0.5236, "
        "the INCLUSIVE band",
    )


def test_binom_inv_is_the_smallest_k_at_or_above_alpha() raises:
    """⚠ Microsoft's own example: BINOM.INV(6,0.5,0.75) = 4."""
    _close(
        xl_binom_inv(_a3(6.0, 0.5, 0.75)),
        4.0,
        0.0,
        "BINOM.INV(6,0.5,0.75) = 4 — an EXACT integer, tolerance 0",
    )


def test_negbinom_is_failures_then_successes() raises:
    """⛔ THE TWIN IS `BINOM.DIST` AND THE FIRST TWO ARGUMENTS MEAN DIFFERENT
    THINGS. Microsoft's own example is NEGBINOM.DIST(10,5,0.25,FALSE) =
    0.055049."""
    _close(
        xl_negbinom_dist(_a3b(10.0, 5.0, 0.25, False)),
        0.05504866037517786,
        1e-11,
        "NEGBINOM.DIST(10,5,0.25,FALSE) — Microsoft's documented 0.055049",
    )
    _close(
        xl_negbinom_dist(_a3b(10.0, 5.0, 0.25, True)),
        0.3135140584781766,
        1e-11,
        "★ the CUMULATIVE arm, via the incomplete beta identity",
    )
    _assert_err(
        xl_negbinom_dist(_a3b(10.0, 0.0, 0.25, False)),
        XL_ERR_NUM,
        "⛔ zero successes is not a stopping rule — #NUM!",
    )


def test_hypgeom_four_argument_order() raises:
    """⚠ FOUR INTEGER ARGUMENTS IN AN ORDER NOTHING ELSE SHARES, and every
    permutation returns a plausible probability. Microsoft's own example:
    HYPGEOM.DIST(1,4,8,20,FALSE) = 0.3632422."""
    var h = List[FormulaValue]()
    h.append(FormulaValue.number(1.0))
    h.append(FormulaValue.number(4.0))
    h.append(FormulaValue.number(8.0))
    h.append(FormulaValue.number(20.0))
    h.append(FormulaValue.logical_val(False))
    _close(
        xl_hypgeom_dist(h),
        0.3632610939112487,
        1e-11,
        "HYPGEOM.DIST(1,4,8,20,FALSE) — Microsoft's documented 0.363242",
    )
    var hc = List[FormulaValue]()
    hc.append(FormulaValue.number(1.0))
    hc.append(FormulaValue.number(4.0))
    hc.append(FormulaValue.number(8.0))
    hc.append(FormulaValue.number(20.0))
    hc.append(FormulaValue.logical_val(True))
    _close(
        xl_hypgeom_dist(hc),
        0.46542827657378744,
        1e-11,
        "★ the CUMULATIVE arm — P(X<=1), strictly greater than the point mass",
    )


# =============================================================================
# ★★ COUNTING — both twins already registered
# =============================================================================
def test_permut_is_not_combin_and_permutationa_is_not_permut() raises:
    """⛔ `COMBIN` IS A LIVE ROW IN THIS TREE. PERMUT(5,2)=20, COMBIN(5,2)=10 —
    and they AGREE at k<=1, which is where a thin fixture looks."""
    _close(
        xl_permut(_a2(5.0, 2.0)),
        20.0,
        0.0,
        "PERMUT(5,2) = 20, EXACT. COMBIN(5,2) is 10",
    )
    _close(
        xl_permut(_a2(100.0, 3.0)),
        970200.0,
        0.0,
        "PERMUT(100,3) — Microsoft's documented 970200",
    )
    _close(
        xl_permutationa(_a2(3.0, 2.0)),
        9.0,
        0.0,
        "★ PERMUTATIONA(3,2) = 3^2 = 9 where PERMUT(3,2) = 6",
    )
    _close(
        xl_permutationa(_a2(2.0, 3.0)),
        8.0,
        0.0,
        "⭐ k > n IS LEGAL for PERMUTATIONA — 2^3 = 8 — and #NUM! for PERMUT. "
        "That SHAPE difference is what a numeric-only fixture misses",
    )
    _assert_err(
        xl_permut(_a2(2.0, 3.0)),
        XL_ERR_NUM,
        "⛔ PERMUT refuses k > n",
    )


def test_fisher_pair_round_trips_and_fisherinv_has_no_domain_guard() raises:
    """⚠ THE ONE PAIR IN THIS FILE WHOSE ROUND TRIP IS A LEGITIMATE GRADING:
    both halves are EXACT closed forms (atanh / tanh), so neither is a search
    over the other. ⛔ AND `FISHERINV` MUST NOT COPY `FISHER`'s |x|<1 GUARD —
    its domain is the whole line."""
    _close(
        xl_fisher(_a1(0.75)),
        0.9729550745276566,
        1e-13,
        "FISHER(0.75) — Microsoft's documented 0.972955",
    )
    _close(
        xl_fisherinv(_a1(0.9729550745276566)),
        0.75,
        1e-12,
        "FISHERINV round-trips it",
    )
    _close(
        xl_fisherinv(_a1(2.0)),
        0.9640275800758169,
        1e-13,
        "⭐ FISHERINV(2) IS DEFINED — a copied |x|<1 guard would refuse it",
    )
    _assert_err(
        xl_fisher(_a1(1.0)),
        XL_ERR_NUM,
        "⛔ FISHER's domain is OPEN — |x| = 1 is #NUM!, not +inf",
    )


def test_standardize_refuses_a_zero_sd_rather_than_returning_inf() raises:
    _close(
        xl_standardize(_a3(42.0, 40.0, 1.5)),
        1.3333333333333333,
        1e-14,
        "STANDARDIZE(42,40,1.5) — Microsoft's documented 1.333333333",
    )
    _assert_err(
        xl_standardize(_a3(42.0, 40.0, 0.0)),
        XL_ERR_NUM,
        "⛔ sd = 0 is #NUM! — the obvious spelling returns inf, which travels",
    )


def test_confidence_t_refuses_n_equals_one_where_confidence_norm_answers() raises:
    """⭐ THE DISCRIMINATOR IS A **DIFFERENT ERROR CODE**, not a value. The two
    functions agree asymptotically in n, so a large-n fixture cannot tell them
    apart; at n = 1 `CONFIDENCE.T` is `#DIV/0!` (zero degrees of freedom) and
    `CONFIDENCE.NORM` answers a number."""
    _close(
        xl_confidence_norm(_a3(0.05, 2.5, 50.0)),
        0.6929519121748386,
        1e-12,
        "CONFIDENCE.NORM(0.05,2.5,50) — Microsoft's documented 0.692951912",
    )
    _close(
        xl_confidence_t(_a3(0.05, 1.0, 50.0)),
        0.284196855,
        1e-8,
        "CONFIDENCE.T(0.05,1,50) — Microsoft's documented 0.284196855",
    )
    _apart(
        xl_confidence_norm(_a3(0.05, 1.0, 50.0)),
        xl_confidence_t(_a3(0.05, 1.0, 50.0)),
        "★ the two must differ at n=50",
    )
    _assert_err(
        xl_confidence_t(_a3(0.05, 1.0, 1.0)),
        XL_ERR_DIV0,
        "⛔ n = 1 is #DIV/0! for CONFIDENCE.T — a DIFFERENT code from #NUM!",
    )
    assert_true(
        xl_confidence_norm(_a3(0.05, 1.0, 1.0)).is_number(),
        "★ and CONFIDENCE.NORM ANSWERS at n = 1 — the shape difference",
    )


# =============================================================================
# ★★ THE PRIMITIVE ITSELF — asserted directly, because eleven names share it
# =============================================================================
def test_norm_s_inv_is_INDEPENDENT_of_norm_s_cdf() raises:
    """⭐ THE `.DIST`/`.INV` TRAP, PINNED. `norm_s_inv` is AS241 — a published
    rational approximation — and `norm_s_cdf` is `erfc`. They are two
    independent implementations, so a round trip between them is EVIDENCE.
    A bisection-over-erfc inverse would make this test vacuous, and this
    assertion is the record that it is not one."""
    var z = norm_s_inv(0.975)
    var back = norm_s_cdf(z)
    assert_true(
        _abs(back - 0.975) < 1e-15,
        "AS241 and erfc agree to 1e-15 — two independent implementations",
    )
    assert_true(
        _abs(norm_s_inv(0.975) - 1.959963984540054) < 2e-15,
        "★ AND THE FORWARD VALUE IS PUBLISHED, which is what makes the round "
        "trip above mean anything",
    )


# =============================================================================
# ⭐⭐ THE DUPLICATION GUARD — TWO MODULES, ONE MATHEMATICS
# =============================================================================
def test_the_TWO_special_function_modules_AGREE() raises:
    """⛔⛔ `komira_xl_plan` CONTAINS **TWO** IMPLEMENTATIONS OF THE SAME FIVE
    SPECIAL FUNCTIONS, AND THIS IS THE ONLY THING HOLDING THEM TOGETHER.

    MEASURED 2026-09-14. `xl_stat_special.mojo` (Compatibility category — the
    pre-2010 spellings NORMDIST / CHIDIST / TDIST / FDIST / BETADIST / …) and
    `xl_special_fn.mojo` (Statistical category — the 2010 `.DIST` / `.INV`
    spellings) were authored the same day in two worktrees and landed hours
    apart. Each carries log-gamma, the regularized incomplete gamma P and Q,
    the regularized incomplete beta, and the standard normal.

    ⚠ THEY ARE NOT THE SAME CODE, which is why this can fail:
      * log-gamma — `xl_stat_special` implements LANCZOS in Mojo;
        `xl_special_fn` calls libm `lgamma`.
      * the normal CDF — `xl_stat_special` routes through `gamma_p`/`gamma_q`
        at a = 1/2; `xl_special_fn` calls libm `erfc`.
      * the normal QUANTILE — `xl_stat_special` is ACKLAM plus two Halley
        refinements **against its own CDF**; `xl_special_fn` is AS241, a
        published rational approximation that touches no CDF at all.

    ⛔ SO THE DUPLICATION IS REAL DEBT AND IT HAS A CARD. What this test buys
    is that it cannot DRIFT: a change to either module that moves any of these
    numbers REDS here, in a gated build, instead of leaving the Statistical
    door and the Compatibility door quietly disagreeing about the same
    probability — the worst outcome available, because each would stay
    self-consistent and neither could detect the other.
    """
    # ---- log-gamma: Lanczos against libm --------------------------------
    for i in range(1, 40):
        var z = Float64(i) * 0.37
        assert_true(
            _abs(xl_lgamma(z) - xs_lgamma(z)) <= 1e-11 * (1.0 + _abs(xs_lgamma(z))),
            "★ LANCZOS vs libm lgamma diverge at z=" + String(z)
            + ": " + String(xl_lgamma(z)) + " vs " + String(xs_lgamma(z)),
        )
    # ---- the incomplete gamma, both tails --------------------------------
    for ai in range(1, 12):
        for xi in range(1, 12):
            var a = Float64(ai) * 0.8
            var x = Float64(xi) * 1.3
            assert_true(
                _abs(gamma_p(a, x) - gamma_p_2(a, x)) <= 1e-12,
                "★ gamma_p diverges at a=" + String(a) + " x=" + String(x),
            )
            assert_true(
                _abs(gamma_q(a, x) - gamma_q_2(a, x)) <= 1e-12,
                "★ gamma_q diverges at a=" + String(a) + " x=" + String(x)
                + " — ⚠ THE RIGHT TAIL IS THE HALF THAT MATTERS: both modules "
                "compute it directly rather than as 1-P, and a regression to "
                "the subtraction shows up HERE and in no `.DIST` cell",
            )
    # ---- the incomplete beta ---------------------------------------------
    for ai in range(1, 8):
        for bi in range(1, 8):
            for zi in range(1, 10):
                var a = Float64(ai) * 1.5
                var b = Float64(bi) * 1.1
                var z = Float64(zi) * 0.1
                assert_true(
                    _abs(betai(a, b, z) - betainc_reg(a, b, z)) <= 1e-12,
                    "★ the incomplete beta diverges at a=" + String(a)
                    + " b=" + String(b) + " z=" + String(z),
                )
    # ---- the normal CDF: erfc against the gamma route --------------------
    for i in range(-60, 61):
        var z = Float64(i) * 0.1
        assert_true(
            _abs(norm_s_cdf(z) - norm_sdist(z)) <= 1e-14,
            "★ erfc and the gamma_p/gamma_q route disagree at z=" + String(z),
        )
    # ---- the normal QUANTILE: AS241 against Acklam+Halley ----------------
    # ⚠ THE TOLERANCE IS LOOSER HERE ON PURPOSE AND IT IS ARGUED: Acklam's
    # own accuracy is ~1.15e-9 relative and the two Halley steps take it to
    # full precision only where the refinement RUNS — its own docstring says
    # it is skipped beyond |z| = 6. 1e-11 absolute covers the refined band
    # and is still four orders tighter than Acklam unrefined, so a DROPPED
    # refinement reds this.
    for i in range(1, 100):
        var pr = Float64(i) * 0.01
        assert_true(
            _abs(norm_s_inv(pr) - norm_sinv(pr)) <= 1e-11,
            "★ AS241 and Acklam+Halley disagree at p=" + String(pr)
            + ": " + String(norm_s_inv(pr)) + " vs " + String(norm_sinv(pr)),
        )
    # ---- and the density, which is the same one line in both -------------
    assert_true(
        _abs(norm_s_pdf(0.75) - 0.30113743215480443) < 1e-15,
        "the density is pinned to its published value in both modules",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

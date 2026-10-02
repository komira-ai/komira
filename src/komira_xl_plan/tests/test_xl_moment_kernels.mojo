# =============================================================================
# test_xl_moment_kernels.mojo — ★★ THE VARIADIC STATISTICS, GRADED AT THE
#                                  INPUT WHERE THE NEAREST SIBLING DIVERGES.
# =============================================================================
#
#
#
# ⭐ WHY THIS IS ITS OWN FILE AND NOT AN APPEND. The sibling kernel files each
# state a SELECTION RULE and each one is different: `test_xl_scalar_kernels`
# takes "a case where the obvious implementation is wrong", the financial file
# takes "an input where a wrong kernel returns the right sign and magnitude",
# the distribution file takes "the wrong answer is still a probability". This
# family's rule is narrower than all three:
#
#   ⛔ **EVERY FUNCTION HERE HAS A SIBLING THAT IS THE SAME KERNEL WITH ONE
#      CONSTANT CHANGED**, and the two sit next to each other in the same
#      Microsoft category under names one character apart. VAR.P and VAR.S
#      differ by a divisor; SKEW and SKEW.P by a scaling; GEOMEAN and HARMEAN
#      by which mean; AVEDEV and DEVSQ by a square and a division. So a test
#      here is only worth writing if it asserts the value AND asserts that the
#      SIBLING'S value is not what came back.
#
# ⇒ every `_close` below that grades a moment is followed by a `_not_close`
# against the rival definition, computed IN THIS FILE from the same inputs.
#
# ⚠⚠ AND THE FIXTURE IS CHOSEN SO THE RIVALS ACTUALLY SEPARATE, WHICH IS NOT
# AUTOMATIC. Over {1,2,3}, AVEDEV is 0.6667 and VAR.P is 0.6667 — the same
# number, by coincidence and not by identity — so a suite that used only that
# input would pass with the two kernels swapped. `{1,2,3,4}` separates them
# (1.0 vs 1.25) and both are asserted.
#
# ⚠ NO `EngineContext`, NO FILE, NO FIXTURE FILE — this file is welded to
# `komira_xl_plan`, which downstream bindings link, so every assertion is a
# pure function of a `FormulaValue`.
# =============================================================================

from std.math import sqrt
from std.testing import TestSuite, assert_equal, assert_true

from komira_core.plan.excel_error_code import XL_ERR_DIV0, XL_ERR_NUM, XL_ERR_VALUE

from komira_xl_plan.formula_value import FormulaValue
from komira_xl_plan.xl_scalar_moments import (
    xl_avedev,
    xl_devsq,
    xl_geomean,
    xl_harmean,
    xl_kurt,
    xl_skew,
    xl_skew_p,
    xl_stdev_p,
    xl_stdev_s,
    xl_var_p,
    xl_var_s,
)


# =============================================================================
# Helpers.
# =============================================================================
def _vals(imm xs: List[Float64]) -> List[FormulaValue]:
    var v = List[FormulaValue]()
    for i in range(len(xs)):
        v.append(FormulaValue.number(xs[i]))
    return v^


def _ms() -> List[Float64]:
    """Microsoft's own STDEV.P worked example: {2,4,4,4,5,5,7,9}, n=8, mean 5,
    sum of squared deviations 32. ⭐ CHOSEN BECAUSE THE POPULATION VARIANCE IS
    EXACTLY 4 AND THE POPULATION DEVIATION EXACTLY 2 — both are representable,
    so the population arm needs no tolerance at all, while the sample arm
    (32/7) does. A fixture where both were irrational would hide a divisor
    swap behind a shared epsilon."""
    var v = List[Float64]()
    v.append(2.0)
    v.append(4.0)
    v.append(4.0)
    v.append(4.0)
    v.append(5.0)
    v.append(5.0)
    v.append(7.0)
    v.append(9.0)
    return v^


def _skewed() -> List[Float64]:
    """{1,2,3,4,10} — n=5 with one far point, so the third and fourth moments
    are large enough that a scaling error is orders of magnitude above any
    tolerance."""
    var v = List[Float64]()
    v.append(1.0)
    v.append(2.0)
    v.append(3.0)
    v.append(4.0)
    v.append(10.0)
    return v^


def _abs(x: Float64) -> Float64:
    return -x if x < 0.0 else x


def _close(r: FormulaValue, want: Float64, why: String) raises:
    """A NUMBER equal to `want` to within 1e-12 RELATIVE (absolute below 1).

    ⚠ 1e-12 IS THE CORPUS'S EXISTING MAXIMUM DECLARED TOLERANCE, not a new
    one, and every divergence this file asserts about is at least eight orders
    of magnitude above it — the tightest is VAR.P 4 against VAR.S 4.5714,
    which is 0.125 RELATIVE."""
    assert_true(
        r.is_number(),
        why + " (expected a NUMBER, got `" + r.render() + "`)",
    )
    var scale = _abs(want)
    if scale < 1.0:
        scale = 1.0
    assert_true(
        _abs(r.num - want) <= 1e-12 * scale,
        why + " (want " + String(want) + ", got " + String(r.num) + ")",
    )


def _not_close(r: FormulaValue, rival: Float64, why: String) raises:
    """★ THE HALF THAT MAKES THE ASSERTION ABOVE MEAN SOMETHING. `r` must NOT
    be the value the NEAREST SIBLING would have produced on the same input.
    A `_close` alone cannot tell a correct kernel from one whose rival happens
    to agree at the fixture, and in this family the rivals agree at more
    inputs than they differ at."""
    assert_true(r.is_number(), why + " (expected a NUMBER)")
    assert_true(
        _abs(r.num - rival) > 1e-9 * (1.0 if _abs(rival) < 1.0 else _abs(rival)),
        why + " — it answered the RIVAL definition's value "
        + String(rival) + ", which is the mis-wiring this cell exists for",
    )


def _err(r: FormulaValue, code: UInt8, why: String) raises:
    assert_true(
        r.is_error() and r.error_code == code,
        why + " (got `" + r.render() + "`)",
    )


# =============================================================================
# ★★ THE POPULATION / SAMPLE DIVISOR — the four names whose refusal was
#    scoped to a surface they were not being served on.
# =============================================================================
def test_VAR_P_divides_by_n_and_VAR_S_by_n_minus_1() raises:
    """⛔ THE DIVISOR IS THE WHOLE FUNCTION, AND BOTH ANSWERS ARE PLAUSIBLE.
    surface."""
    var a = _vals(_ms())
    _close(xl_var_p(a), 4.0, "VAR.P over the MS sample is exactly 4")
    _not_close(xl_var_p(a), 32.0 / 7.0, "VAR.P must not be the SAMPLE variance")
    _close(xl_var_s(a), 32.0 / 7.0, "VAR.S over the MS sample is 32/7")
    _not_close(xl_var_s(a), 4.0, "VAR.S must not be the POPULATION variance")


def test_STDEV_P_and_STDEV_S_are_the_square_roots_of_their_own_variances() raises:
    """⚠ THE SQUARE ROOT SHRINKS THE DIVERGENCE, WHICH IS WHY IT IS ASSERTED
    SEPARATELY. sqrt(4) = 2 against sqrt(32/7) = 2.1381 is 6.9% apart where
    the variances were 14% apart — still far above any tolerance, but a
    reviewer eyeballing "about 2" cannot see it."""
    var a = _vals(_ms())
    _close(xl_stdev_p(a), 2.0, "STDEV.P over the MS sample is exactly 2")
    _not_close(xl_stdev_p(a), sqrt(32.0 / 7.0), "STDEV.P is not the SAMPLE sd")
    _close(xl_stdev_s(a), sqrt(32.0 / 7.0), "STDEV.S over the MS sample")
    _not_close(xl_stdev_s(a), 2.0, "STDEV.S is not the POPULATION sd")


def test_the_two_forms_differ_in_their_SMALL_SAMPLE_REFUSAL_as_well() raises:
    """★ ONE VALUE IS A LEGAL POPULATION AND NOT A LEGAL SAMPLE.

    `VAR.P(5)` is 0 — a real answer, the variance of a one-element population
    — and `VAR.S(5)` is `#DIV/0!` because its divisor n-1 is zero. A kernel
    that shared ONE arity guard between the two gets exactly one of these
    wrong, and neither failure is visible at n >= 2 where every fixture
    lives."""
    var one = List[Float64]()
    one.append(5.0)
    var a = _vals(one)
    _close(xl_var_p(a), 0.0, "VAR.P of a single value is 0, not an error")
    _close(xl_stdev_p(a), 0.0, "STDEV.P of a single value is 0")
    _err(xl_var_s(a), XL_ERR_DIV0, "VAR.S of a single value is #DIV/0!")
    _err(xl_stdev_s(a), XL_ERR_DIV0, "STDEV.S of a single value is #DIV/0!")


# =============================================================================
# ★ THE DEVIATION PAIR.
# =============================================================================
def test_DEVSQ_is_a_SUM_and_AVEDEV_is_a_MEAN_of_ABSOLUTE_deviations() raises:
    """⛔ AND THE {1,2,3} FIXTURE CANNOT TELL THEM APART FROM VAR.P.

    Over {1,2,3} the mean absolute deviation is 2/3 and the POPULATION
    VARIANCE is also 2/3 — the same number, by coincidence. That is the blind
    input, and it is asserted here so the second fixture below is visibly the
    discriminator rather than a duplicate."""
    var three = List[Float64]()
    three.append(1.0)
    three.append(2.0)
    three.append(3.0)
    var a = _vals(three)
    _close(xl_avedev(a), 2.0 / 3.0, "AVEDEV{1,2,3} is 2/3")
    _close(xl_var_p(a), 2.0 / 3.0,
           "⚠ THE BLIND INPUT: VAR.P{1,2,3} is ALSO 2/3")
    _close(xl_devsq(a), 2.0, "DEVSQ{1,2,3} is the SUM, 2")

    var four = List[Float64]()
    four.append(1.0)
    four.append(2.0)
    four.append(3.0)
    four.append(4.0)
    var b = _vals(four)
    _close(xl_avedev(b), 1.0, "AVEDEV{1,2,3,4} is 1")
    _not_close(xl_avedev(b), 1.25,
               "★ THE DISCRIMINATOR: VAR.P{1,2,3,4} is 1.25 and AVEDEV is 1")
    _close(xl_devsq(b), 5.0, "DEVSQ{1,2,3,4} is 5")
    _not_close(xl_devsq(b), 1.25, "DEVSQ is a SUM, not VAR.P")
    _not_close(xl_devsq(b), 5.0 / 3.0, "DEVSQ is a SUM, not VAR.S")


# =============================================================================
# ★ THE TWO NON-ARITHMETIC MEANS.
# =============================================================================
def test_GEOMEAN_and_HARMEAN_are_both_averages_and_are_not_each_other() raises:
    """⛔ ALL THREE MEANS LIE BETWEEN MIN AND MAX, so a range check passes on
    every mis-wiring. Over {1,2,4}: HARMEAN 12/7 = 1.7143, GEOMEAN exactly 2,
    AVERAGE 7/3 = 2.3333. The ordering HARMEAN <= GEOMEAN <= AVERAGE is strict
    here and collapses to equality on constant data, which is the blind
    input."""
    var v = List[Float64]()
    v.append(1.0)
    v.append(2.0)
    v.append(4.0)
    var a = _vals(v)
    _close(xl_geomean(a), 2.0, "GEOMEAN{1,2,4} is exactly 2")
    _not_close(xl_geomean(a), 12.0 / 7.0, "GEOMEAN is not HARMEAN")
    _not_close(xl_geomean(a), 7.0 / 3.0, "GEOMEAN is not the arithmetic mean")
    _close(xl_harmean(a), 12.0 / 7.0, "HARMEAN{1,2,4} is 12/7")
    _not_close(xl_harmean(a), 2.0, "HARMEAN is not GEOMEAN")

    # ⚠ THE BLIND INPUT, ASSERTED: on constant data the three coincide.
    var c = List[Float64]()
    c.append(3.0)
    c.append(3.0)
    var b = _vals(c)
    _close(xl_geomean(b), 3.0, "constant data: GEOMEAN is the value")
    _close(xl_harmean(b), 3.0,
           "⚠ AND SO IS HARMEAN — a constant fixture discriminates nothing")


def test_both_nonarithmetic_means_REFUSE_a_nonpositive_value() raises:
    """⛔ `#NUM!` AND NOT AN ANSWER, which is the function rather than an edge
    case: a geometric mean over a set containing a negative is not real, and a
    harmonic mean over one can fall OUTSIDE the data range. A kernel that
    skipped the non-positive values instead would answer the mean of what is
    left — a plausible number from a well-formed call."""
    var v = List[Float64]()
    v.append(1.0)
    v.append(0.0)
    v.append(4.0)
    _err(xl_geomean(_vals(v)), XL_ERR_NUM, "GEOMEAN with a zero is #NUM!")
    _err(xl_harmean(_vals(v)), XL_ERR_NUM, "HARMEAN with a zero is #NUM!")
    var w = List[Float64]()
    w.append(1.0)
    w.append(-2.0)
    _err(xl_geomean(_vals(w)), XL_ERR_NUM, "GEOMEAN with a negative is #NUM!")
    _err(xl_harmean(_vals(w)), XL_ERR_NUM, "HARMEAN with a negative is #NUM!")


# =============================================================================
# ★ THE SHAPE MOMENTS.
# =============================================================================
def test_SKEW_and_SKEW_P_differ_by_a_SCALING_that_is_never_1() raises:
    """⛔ SAME SIGN, SAME ORDER OF MAGNITUDE, 49% APART.

    Over {1,2,3,4,10}: SKEW is 1.697056 and SKEW.P is 1.138420. The ratio is
    `sqrt(n(n-1))/(n-2)` = sqrt(20)/3 = 1.4907 — it is never 1 for any n, so
    there is NO sample size at which the two agree and no fixture that could
    hide a swap. Both are positive, both say "right-skewed", and only the
    number distinguishes them."""
    var a = _vals(_skewed())
    _close(xl_skew(a), 1.697056274847714, "SKEW{1,2,3,4,10}")
    _not_close(xl_skew(a), 1.1384199576606164, "SKEW is not SKEW.P")
    _close(xl_skew_p(a), 1.1384199576606164, "SKEW.P{1,2,3,4,10}")
    _not_close(xl_skew_p(a), 1.697056274847714, "SKEW.P is not SKEW")


def test_KURT_is_the_EXCESS_kurtosis_and_the_correction_is_8_not_3() raises:
    """⛔⛔ THE TRAILING SUBTRACTION IS WHY THIS IS NOT A FOURTH MOMENT, AND
    THE TEXTBOOK NUMBER 3 IS THE WRONG ONE FOR EXCEL'S SAMPLE FORM.

    Excel's KURT subtracts `3(n-1)^2/((n-2)(n-3))`, which at n=5 is 8 — not 3.
    MEASURED over {1,2,3,4,10}: KURT is 3.152 and the same expression WITHOUT
    the correction is 11.152. A kernel that dropped the term answers a number
    that is still positive, still a kurtosis, and 8 too large; one that
    subtracted the textbook 3 answers 8.152 and is wrong by 5."""
    var a = _vals(_skewed())
    _close(xl_kurt(a), 3.1519999999999992, "KURT{1,2,3,4,10}")
    _not_close(xl_kurt(a), 11.152, "KURT must SUBTRACT the correction term")
    _not_close(xl_kurt(a), 8.152,
               "★ AND THE CORRECTION IS 3(n-1)^2/((n-2)(n-3)) = 8 at n=5, "
               "not the textbook constant 3")


def test_the_shape_moments_REFUSE_a_sample_too_small_with_DIV0() raises:
    """⚠ `#DIV/0!`, NOT `#NUM!` AND NOT 0. SKEW and SKEW.P need n >= 3 and
    KURT needs n >= 4; below that Excel answers #DIV/0! because the documented
    denominator is literally zero. A kernel returning 0 would be a confident
    claim of symmetry."""
    var two = List[Float64]()
    two.append(1.0)
    two.append(2.0)
    _err(xl_skew(_vals(two)), XL_ERR_DIV0, "SKEW needs n >= 3")
    _err(xl_skew_p(_vals(two)), XL_ERR_DIV0, "SKEW.P needs n >= 3")
    var three = List[Float64]()
    three.append(1.0)
    three.append(2.0)
    three.append(3.0)
    _err(xl_kurt(_vals(three)), XL_ERR_DIV0, "KURT needs n >= 4")
    # ⚠ AND A ZERO DEVIATION AT A LEGAL SIZE IS THE SAME REFUSAL, reached by a
    #   different branch: the sample is big enough and s is 0.
    var flat = List[Float64]()
    flat.append(7.0)
    flat.append(7.0)
    flat.append(7.0)
    flat.append(7.0)
    _err(xl_skew(_vals(flat)), XL_ERR_DIV0, "SKEW of constant data is #DIV/0!")
    _err(xl_kurt(_vals(flat)), XL_ERR_DIV0, "KURT of constant data is #DIV/0!")


# =============================================================================
# ★ THE SHARED ARGUMENT READER — one reader, so the dominance and the
#   blank rule cannot differ between eleven kernels.
# =============================================================================
def test_a_BLANK_argument_is_SKIPPED_and_not_ZERO() raises:
    """⛔ `FormulaValue.coerce_number` MAPS BLANK TO 0.0, WHICH IS RIGHT FOR
    `1+A1` AND WRONG HERE. `AVERAGE(1, , 3)` is 2 and not 4/3, and the same
    distinction changes n for every moment below. Over {1,3} with a blank in
    the middle the population variance is 1; zeroing the blank gives a
    three-element sample {1,0,3} whose population variance is 14/9 = 1.5556 —
    a plausible number, larger, and never an error."""
    var v = List[FormulaValue]()
    v.append(FormulaValue.number(1.0))
    v.append(FormulaValue.blank())
    v.append(FormulaValue.number(3.0))
    _close(xl_var_p(v), 1.0, "VAR.P{1,BLANK,3} skips the blank: n=2, var 1")
    _not_close(xl_var_p(v), 14.0 / 9.0,
               "★ a ZEROED blank gives {1,0,3} and 14/9")
    _close(xl_devsq(v), 2.0, "DEVSQ{1,BLANK,3} is 2, not 14/3")


def test_an_ERROR_argument_DOMINATES_and_returns_ITSELF() raises:
    """The `ERRH_PROPAGATE_DOMINANT` contract, asserted at the kernel rather
    than trusted from the descriptor row: the LEFTMOST error argument is the
    result, and it comes back with its own code rather than a generic
    `#VALUE!`. A moment of a set containing `#DIV/0!` is `#DIV/0!`."""
    var v = List[FormulaValue]()
    v.append(FormulaValue.number(1.0))
    v.append(FormulaValue.error(XL_ERR_DIV0))
    v.append(FormulaValue.number(3.0))
    _err(xl_var_p(v), XL_ERR_DIV0, "VAR.P propagates the argument's own code")
    _err(xl_geomean(v), XL_ERR_DIV0, "GEOMEAN propagates it too")
    _err(xl_skew(v), XL_ERR_DIV0,
         "⚠ AND BEFORE ITS OWN n<3 GUARD — the error is dominant, and this "
         "list has only two numbers in it")


def test_a_NONNUMERIC_TEXT_argument_is_VALUE_and_a_NUMERIC_ONE_COERCES() raises:
    """⚠ EXCEL'S RULE FOR **DIRECT** ARGUMENTS, WHICH IS THE ONLY KIND THIS
    DOOR HAS. Text that parses as a number counts; text that does not is
    `#VALUE!`. That is also why the seven `A`-suffixed names are refused
    rather than served: their whole documented difference is about values
    reached THROUGH A REFERENCE, and there is no reference in this value
    lattice — so AVERAGEA and AVERAGE would be the same function on every
    input expressible here."""
    var ok = List[FormulaValue]()
    ok.append(FormulaValue.number(1.0))
    ok.append(FormulaValue.text_val(String("3")))
    _close(xl_var_p(ok), 1.0, 'VAR.P{1,"3"} coerces the text: mean 2, var 1')
    var bad = List[FormulaValue]()
    bad.append(FormulaValue.number(1.0))
    bad.append(FormulaValue.text_val(String("zzz")))
    _err(xl_var_p(bad), XL_ERR_VALUE, "non-numeric text is #VALUE!")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

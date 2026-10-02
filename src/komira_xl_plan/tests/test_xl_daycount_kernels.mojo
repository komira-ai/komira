# =============================================================================
# test_xl_daycount_kernels.mojo — ★★ ONE PRIMITIVE GRADED BEFORE ANY MONEY
#                                    FORMULA IS ALLOWED TO READ IT.
# =============================================================================
#
#
# ============ ⛔⛔ WHY THIS FILE EXISTS SEPARATELY FROM THE FINANCIAL SIBLING
#
# `xl_absent_common_names()` refused 24 `Financial` names on 2026-09-14 with
# ONE sentence: *"ONE WRONG `yearfrac` WOULD INFECT ALL TWENTY-FOUR AT ONCE,
# and every one of them would answer a plausible price."* That is a statement
# about a SHARED DEPENDENCY, and the test structure has to match it: the FIRST
# HALF of this file grades `YEARFRAC` ALONE, over all five bases, with no money
# anywhere; only the second half lets the eight Financial names read it.
#
# ⇒ IF A BASIS ARM BREAKS, THE FIRST HALF GOES RED AND SAYS WHICH BASIS. A
#   suite that only asserted bond prices would go red in eight places at once
#   and name none of them.
#
# ============ ★ WHERE EVERY EXPECTATION CAME FROM. NO CALCULATOR.
#
# TIER 1 — MICROSOFT'S OWN PUBLISHED PAGES (support.microsoft.com, fetched
#   2026-09-15). Eight of the nine names carry a worked example on their page
#   and every one of those is asserted here, to the last published digit:
#     YEARFRAC   0.58055556 / 0.57650273 / 0.57808219  (bases 0, 1, 3)
#     ACCRINTM   20.54794521
#     INTRATE    0.05768
#     RECEIVED   $1,014,584.65
#     PRICEDISC  $99.80            (page rounds to cents)
#     YIELDDISC  0.052823
#     PRICEMAT   $99.98            (page rounds to cents)
#     YIELDMAT   0.060954
#   ⚠ AND TWO FREE ASSERTIONS ABOUT THE SERIAL MAP ITSELF: the ACCRINTM page
#   gives its dates as RAW SERIALS (39539, 39614) and the DISC page states
#   "January 1, 2018 is serial number 43101". Both are used below as literals,
#   so `_serial_to_ymd` disagreeing with Excel would break these tests rather
#   than quietly shift a day count.
#
# ⛔ TIER 0 — NOTHING. No online calculator was consulted, and one published
#   example was measured to be WRONG (DISC's; see `test_DISC_...` below).
#
# ============ ⚠ THE CLAUSE-ORDER CHOICE IS UNVERIFIED AGAINST A LIVE EXCEL
#
# flags exactly this and it is true: there is no
# live Excel reachable from this tree, the basis-0 clause order changes a real
# answer, and the choice made here is the ODF/LibreOffice one. It is written
# down in `xl_daycount.mojo`'s header in full, with the two measured
# consequences of the two alternative readings, and the tests below assert the
# reading rather than hiding it. ⇒ IF A LIVE EXCEL EVER CONTRADICTS ONE OF
# THESE CELLS, THE CELL IS WHERE TO LOOK — that is what an asserted choice buys
# over a silent one.
#
# ⚠ NO `EngineContext`, NO FILE, NO FIXTURE — this file is welded to
# `komira_xl_plan`, which downstream bindings link, so every assertion is a
# pure function of a `FormulaValue`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.plan.excel_error_code import (
    XL_ERR_NA,
    XL_ERR_NUM,
    XL_ERR_VALUE,
)

from komira_xl_plan.formula_value import FormulaValue
from komira_xl_plan.xl_scalar_date import xl_days360
from komira_xl_plan.xl_daycount import (
    xl_accrintm,
    xl_disc,
    xl_intrate,
    xl_pricedisc,
    xl_pricemat,
    xl_received,
    xl_yearfrac,
    xl_yielddisc,
    xl_yieldmat,
)


# =============================================================================
# ★ THE DATES, AS EXCEL SERIALS, SPELLED ONCE.
#
# ⚠ SERIALS AND NOT `DATE(y, m, d)` CALLS, deliberately. Two of them are
# MICROSOFT'S OWN LITERALS (39539 / 39614 from the ACCRINTM page, 43101 from
# the DISC page's Remarks), so writing the serial is what lets those pages
# grade this tree's serial arithmetic as well as its day count. The civil date
# is in the name of every constant.
# =============================================================================
comptime _D2007_11_08: Float64 = 39394.0
comptime _D2007_11_11: Float64 = 39397.0
comptime _D2008_02_15: Float64 = 39493.0
comptime _D2008_02_16: Float64 = 39494.0
comptime _D2008_03_01: Float64 = 39508.0
comptime _D2008_03_15: Float64 = 39522.0
comptime _D2008_04_01: Float64 = 39539.0   # MS ACCRINTM page, verbatim
comptime _D2008_04_13: Float64 = 39551.0
comptime _D2008_05_15: Float64 = 39583.0
comptime _D2008_06_15: Float64 = 39614.0   # MS ACCRINTM page, verbatim
comptime _D2008_11_03: Float64 = 39755.0
comptime _D2012_01_01: Float64 = 40909.0
comptime _D2012_07_30: Float64 = 41120.0
comptime _D2018_01_01: Float64 = 43101.0   # MS DISC page Remarks, verbatim
comptime _D2018_01_31: Float64 = 43131.0
comptime _D2018_02_28: Float64 = 43159.0
comptime _D2018_07_01: Float64 = 43282.0
comptime _D2019_01_01: Float64 = 43466.0
comptime _D2019_07_01: Float64 = 43647.0
comptime _D2020_01_01: Float64 = 43831.0
comptime _D2020_02_29: Float64 = 43890.0
comptime _D2020_06_30: Float64 = 44012.0
comptime _D2020_07_01: Float64 = 44013.0
comptime _D2021_01_01: Float64 = 44197.0
comptime _D2021_02_28: Float64 = 44255.0
comptime _D2021_03_31: Float64 = 44286.0
comptime _D2038_01_01: Float64 = 50406.0
comptime _D2048_01_01: Float64 = 54058.0


# ⚠ OVERLOADED BY ARITY AND NOT VARIADIC. A `*vals: Float64` pack has no other
# use in this package, and the one thing every call site here needs is that the
# ARITY IS VISIBLE at the call — `_a(a, b)` is a two-argument YEARFRAC and
# `_a(a, b, 0.0)` is a three-argument one, which is the distinction the
# default-basis assertions rest on.
def _a(a: Float64, b: Float64) -> List[FormulaValue]:
    var v = List[FormulaValue]()
    v.append(FormulaValue.number(a))
    v.append(FormulaValue.number(b))
    return v^


def _a(a: Float64, b: Float64, c: Float64) -> List[FormulaValue]:
    var v = _a(a, b)
    v.append(FormulaValue.number(c))
    return v^


def _a(a: Float64, b: Float64, c: Float64,
       d: Float64) -> List[FormulaValue]:
    var v = _a(a, b, c)
    v.append(FormulaValue.number(d))
    return v^


def _a(a: Float64, b: Float64, c: Float64, d: Float64,
       e: Float64) -> List[FormulaValue]:
    var v = _a(a, b, c, d)
    v.append(FormulaValue.number(e))
    return v^


def _a(a: Float64, b: Float64, c: Float64, d: Float64, e: Float64,
       f: Float64) -> List[FormulaValue]:
    var v = _a(a, b, c, d, e)
    v.append(FormulaValue.number(f))
    return v^


def _close(r: FormulaValue, want: Float64, why: String) raises:
    """A NUMBER equal to `want` to within 1e-9 RELATIVE (absolute below 1).

    Same contract and the same reasoning as `test_xl_financial_kernels._close`:
    the values here span seven orders of magnitude (0.00068 for a 30-year
    discount rate, 1014584.65 for a redemption amount) so one absolute epsilon
    is either meaningless at one end or brittle at the other. 1e-9 relative is
    five orders TIGHTER than the smallest divergence this file asserts about
    (YIELDDISC against DISC, 0.21% relative)."""
    assert_true(r.is_number(), why + " (expected a NUMBER, got `"
                + r.render() + "`)")
    var d = r.num - want
    if d < 0.0:
        d = -d
    var scale = want if want >= 0.0 else -want
    if scale < 1.0:
        scale = 1.0
    assert_true(
        d <= scale * 1e-9,
        why + " — got " + String(r.num) + ", want " + String(want),
    )


def _apart(a: FormulaValue, b: FormulaValue, why: String) raises:
    """⭐ THE ASSERTION THAT MAKES A PAIR MEAN SOMETHING. Two bases that answer
    the same number on a date pair cannot be told apart by it, however many
    cells the fixture has — and in THIS family that is the dominant failure
    mode, because four of the five bases are within 1.5% of each other on a
    typical span."""
    assert_true(a.is_number() and b.is_number(), why + " (both must answer)")
    var d = a.num - b.num
    if d < 0.0:
        d = -d
    var scale = a.num if a.num >= 0.0 else -a.num
    if scale < 1.0:
        scale = 1.0
    assert_true(d > scale * 1e-6, why + " — both answered "
                + String(a.num) + ", so this input DISCRIMINATES NOTHING")


def _err(r: FormulaValue, code: UInt8, why: String) raises:
    assert_true(r.is_error(), why + " — expected an ERROR, got `"
                + r.render() + "`")
    assert_equal(Int(r.error_code), Int(code), why)


# =============================================================================
# ★★ PART ONE — `YEARFRAC` ALONE. No money in this half.
# =============================================================================
def test_YEARFRAC_reproduces_all_THREE_microsoft_published_cells() raises:
    """★★ THE ANCHOR. Microsoft's YEARFRAC page publishes three results for the
    single pair 2012-01-01 / 2012-07-30, and this kernel must hit all three to
    the last digit they print:

        =YEARFRAC(A2,A3)     0.58055556   basis omitted -> 0 -> 209/360
        =YEARFRAC(A2,A3,1)   0.57650273   actual/actual -> 211/366
        =YEARFRAC(A2,A3,3)   0.57808219   actual/365    -> 211/365

    ⭐ THE basis-1 CELL IS THE LOAD-BEARING ONE AND MICROSOFT SAYS WHY ON THE
    PAGE: *"Because 2012 is a Leap year, it has a 366 day basis."* Same
    numerator as basis 3, different denominator — so this one cell grades the
    "both ends in ONE calendar year and that year is a leap year -> 366" arm,
    which a kernel that hardcodes 365 gets wrong by 0.27% and by nothing that
    looks like an error.

    ⚠ AND THE OMITTED-ARGUMENT CELL GRADES THE DEFAULT. Basis defaults to 0
    (US 30/360), not to 1: 209/360 = 0.58055556 where actual/actual would be
    0.57650273. A kernel defaulting to actual/actual is wrong on every call
    that omits the argument, which is most of them."""
    var two = _a(_D2012_01_01, _D2012_07_30)
    _close(xl_yearfrac(two), 0.5805555555555556,
           "★ MS published 0.58055556 — basis OMITTED is basis 0, = 209/360")
    _close(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 0.0)),
           0.5805555555555556, "basis 0 stated explicitly == basis omitted")
    _close(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 1.0)),
           0.5765027322404371,
           "★★ MS published 0.57650273 — actual/actual, 211/366 because 2012"
           " is a LEAP year")
    _close(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 3.0)),
           0.5780821917808219,
           "★ MS published 0.57808219 — actual/365, 211/365")
    # ⭐ The pair that makes the middle cell mean something: same 211 days,
    #   two denominators. If these ever agree the leap-year arm is dead.
    _apart(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 1.0)),
           xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 3.0)),
           "★★ basis 1 and basis 3 share the NUMERATOR (211) and must differ"
           " in the denominator (366 vs 365)")


def test_YEARFRAC_bases_2_and_4_from_the_ODF_rule() raises:
    """The two bases Microsoft's page does not print a cell for, on the SAME
    date pair so the arithmetic is comparable by eye.

        basis 2  actual/360   211/360 = 0.58611111
        basis 4  30E/360      209/360 = 0.58055556

    ⚠ BASIS 4 COINCIDES WITH BASIS 0 HERE, AND THAT IS THE POINT OF PUTTING
    THEM SIDE BY SIDE: neither end of this pair is a 31st and neither is an
    end-of-February, so the US and European rules have nothing to disagree
    about. ⛔ THIS PAIR THEREFORE PROVES NOTHING ABOUT basis 0 vs basis 4 —
    the next test carries the pairs that do, and this assertion exists to say
    out loud that this one is BLIND rather than to let a later reader mistake
    it for coverage.

    Source: ODF 1.2 part 2 §4.11.7.7.4 (actual/360) and §4.11.7.7.5 (30E/360),
    LibreOffice `GetYearFrac()` at tag `libreoffice-25.2.5.2`."""
    _close(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 2.0)),
           0.5861111111111111, "basis 2 = 211/360 (ACTUAL days over 360)")
    _close(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 4.0)),
           0.5805555555555556, "basis 4 = 209/360 (30E/360)")
    _apart(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 2.0)),
           xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 4.0)),
           "basis 2 and 4 share the DENOMINATOR (360) and must differ in the"
           " numerator (211 actual vs 209 thirty-day)")
    assert_equal(
        xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 0.0)).num,
        xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 4.0)).num,
        "⚠ DECLARED BLIND: no 31st and no end-of-February in this pair, so US"
        " and European 30/360 have nothing to disagree about here",
    )


def test_basis_0_END_OF_MONTH_rules_are_NOT_basis_4_clamping() raises:
    """⛔⛔ THE CLAUSE ORDER AND THE NESTING, ASSERTED. Every cell in it is a place where the
    published US (NASD) rule and a plausible re-derivation of it differ.

    ODF 1.2 part 2 §4.11.7.7.2, LibreOffice `GetYearFrac()` at
    `libreoffice-25.2.5.2`:
        1. day1 == 31              -> day1 = 30
        2. day1 == 30 and day2 == 31 -> day2 = 30
        3. ELSE: day1 is last-of-February -> day1 = 30, AND NESTED INSIDE THAT,
           day2 is last-of-February -> day2 = 30.

    THE FOUR CELLS AND WHAT EACH ONE KILLS:

      2020-02-29 -> 2021-02-28   basis 0 is EXACTLY 1.0 (360/360).
        ⭐ KILLS a flattened nesting. Drop the INNER clause and the end date
        stays at 28, giving 358/360 = 0.99444 — a plausible year fraction, no
        error anywhere. basis 4 gives 359/360 here, because European never
        touches February at all.

      2021-02-28 -> 2021-03-31   basis 0 is 31/360, basis 4 is 32/360.
        ⭐ KILLS the reading that runs the February arm BEFORE clause 2. Under
        this rule day1 was still 28 when clause 2 tested it, so day2 keeps its
        31 and the span is THIRTY-ONE thirty-day days — one day LONGER than the
        calendar month it spans. Under the other reading day1 would already be
        30 and day2 would drop to 30, giving 30/360.

      2018-01-01 -> 2018-01-31   basis 0 is 30/360, basis 4 is 29/360.
        ⭐ KILLS "basis 0 and basis 4 are the same rule". The European rule
        moves a 31st unconditionally; the US rule moves it only when day1 is
        already a 30th.

      2018-01-31 -> 2018-02-28   BOTH are 28/360.
        ⚠ DECLARED BLIND between 0 and 4 — asserted equal on purpose so no
        reader counts it as separating them. It is NOT blind against DAYS360;
        see the next test."""
    var feb29_20 = _D2020_02_29
    var feb28_21 = _D2021_02_28
    _close(xl_yearfrac(_a(feb29_20, feb28_21, 0.0)), 1.0,
           "★★ basis 0: BOTH ends are last-of-February, so both move to the"
           " 30th and the span is EXACTLY 360/360 = one year")
    _close(xl_yearfrac(_a(feb29_20, feb28_21, 4.0)), 0.9972222222222222,
           "basis 4 leaves both February days alone: 359/360")
    _apart(xl_yearfrac(_a(feb29_20, feb28_21, 0.0)),
           xl_yearfrac(_a(feb29_20, feb28_21, 4.0)),
           "★ the February arm is the whole difference between 0 and 4 here")

    _close(xl_yearfrac(_a(_D2021_02_28, _D2021_03_31, 0.0)),
           0.08611111111111111,
           "★★ basis 0: start moves to the 30th (February arm) and the end"
           " KEEPS its 31st, because clause 2 ran first and saw day1 == 28."
           " 31/360")
    _close(xl_yearfrac(_a(_D2021_02_28, _D2021_03_31, 4.0)),
           0.08888888888888889,
           "basis 4: only the 31st moves. 28 stays 28. 32/360")

    _close(xl_yearfrac(_a(_D2018_01_01, _D2018_01_31, 0.0)),
           0.08333333333333333,
           "★ basis 0: day1 is 1, so clause 2 does not fire and the 31st"
           " STAYS. 30/360")
    _close(xl_yearfrac(_a(_D2018_01_01, _D2018_01_31, 4.0)),
           0.08055555555555556,
           "★ basis 4: the 31st moves unconditionally. 29/360")
    _apart(xl_yearfrac(_a(_D2018_01_01, _D2018_01_31, 0.0)),
           xl_yearfrac(_a(_D2018_01_01, _D2018_01_31, 4.0)),
           "★ an end-of-month 31st separates US from European")

    assert_equal(
        xl_yearfrac(_a(_D2018_01_31, _D2018_02_28, 0.0)).num,
        xl_yearfrac(_a(_D2018_01_31, _D2018_02_28, 4.0)).num,
        "⚠ DECLARED BLIND between bases 0 and 4: both answer 28/360",
    )
    _close(xl_yearfrac(_a(_D2018_01_31, _D2018_02_28, 0.0)),
           0.07777777777777778,
           "both bases: 31 -> 30, February untouched (day2 is not a 31st and"
           " clause 3 never runs because day1 is not in February). 28/360")


def test_YEARFRAC_basis_0_IS_NOT_DAYS360_over_360() raises:
    """⛔⛔ THE TRAP THIS WHOLE FILE EXISTS TO PIN. This tree ALREADY has a
    30/360 — `xl_scalar_date.xl_days360` — and it is a DIFFERENT ALGORITHM
    from YEARFRAC basis 0. A reader who "unifies" them breaks one.

    Microsoft's DAYS360 US (NASD) wording moves the start to the 30th when it
    is the LAST DAY OF ANY MONTH and can push the end date into the NEXT
    MONTH; ODF's YEARFRAC basis 0 tests the 31st, then the 30/31 pair, then
    February only. Measured on two ordinary date pairs:

        pair                      DAYS360 US   YEARFRAC(.,0)*360
        2018-01-31 -> 2018-02-28      30             28
        2021-02-28 -> 2021-03-31      30             31

    ⇒ The second pair is the sharp one: DAYS360 is BETWEEN the two YEARFRAC
      answers, so a kernel that shared one implementation would have to be
      wrong for one of the two functions no matter which way it went.

    This test calls BOTH kernels on the SAME serials, so the divergence cannot
    drift: a future edit that made them agree goes red here."""
    var d1 = xl_days360(_a(_D2018_01_31, _D2018_02_28))
    _close(d1, 30.0, "DAYS360 US: both ends are last-of-month -> both 30")
    _close(xl_yearfrac(_a(_D2018_01_31, _D2018_02_28, 0.0)),
           28.0 / 360.0, "YEARFRAC basis 0 on the SAME dates: 28, not 30")
    _apart(FormulaValue.number(d1.num / 360.0),
           xl_yearfrac(_a(_D2018_01_31, _D2018_02_28, 0.0)),
           "★★ DAYS360/360 and YEARFRAC(.,0) MUST NOT agree here")

    var d2 = xl_days360(_a(_D2021_02_28, _D2021_03_31))
    _close(d2, 30.0, "DAYS360 US: the start's last-of-February becomes 30")
    _close(xl_yearfrac(_a(_D2021_02_28, _D2021_03_31, 0.0)),
           31.0 / 360.0, "YEARFRAC basis 0 on the SAME dates: 31, not 30")
    _apart(FormulaValue.number(d2.num / 360.0),
           xl_yearfrac(_a(_D2021_02_28, _D2021_03_31, 0.0)),
           "★★ DAYS360/360 and YEARFRAC(.,0) MUST NOT agree here either")


def test_basis_1_LEAP_SPANNING_denominator() raises:
    """⛔⛔ THE actual/actual RULE A NAIVE KERNEL DROPS, AND IT ANSWERS EXACTLY
    1.0 WHEN IT IS DROPPED — the most plausible wrong answer in the file.

    ODF 1.2 part 2 §4.11.7.7.9/.10: when the span crosses at most one
    anniversary, the denominator is 366 iff a 29 February lies in the CLOSED
    interval [start, end].

        YEARFRAC(2019-07-01, 2020-06-30, 1) = 365/366 = 0.99726776

    ⭐ 2019 IS NOT A LEAP YEAR AND NEITHER END IS IN FEBRUARY. The 366 comes
    from 2020-02-29 sitting INSIDE the span — which is the only way to know,
    and exactly what a kernel that looks at the START year's length misses. It
    would answer 365/365 = 1.0: a full year reported for a span one day short
    of one, with no error and a number a reviewer would not query.

    ⚠ basis 3 ON THE SAME DATES IS 1.0, asserted here so the discriminator is
    visibly a discriminator rather than a coincidence."""
    var b1 = xl_yearfrac(_a(_D2019_07_01, _D2020_06_30, 1.0))
    _close(b1, 0.9972677595628415,
           "★★ actual/actual across 2020-02-29: 365 days over a 366-day basis")
    _close(xl_yearfrac(_a(_D2019_07_01, _D2020_06_30, 3.0)), 1.0,
           "★ actual/365 on the SAME dates is EXACTLY 1.0 — which is the"
           " number a basis-1 kernel without the leap-spanning rule returns")
    _apart(b1, xl_yearfrac(_a(_D2019_07_01, _D2020_06_30, 3.0)),
           "★★ if basis 1 and basis 3 agree here the leap-spanning rule is"
           " dead and the failure is invisible")


def test_basis_1_MULTI_YEAR_denominator_is_an_AVERAGE() raises:
    """ODF 1.2 part 2 §4.11.7.7.7: when the span covers MORE THAN ONE
    anniversary, the denominator is the AVERAGE length of the calendar years
    it touches, INCLUSIVE of both ends.

        YEARFRAC(2019-01-01, 2021-01-01, 1)
          numerator   731 actual days (2019 = 365, 2020 = 366)
          denominator (365 + 366 + 365) / 3 = 1096/3 = 365.333...
          = 2.00091241

    ⭐ THE INCLUSIVE COUNT IS THE TRAP: the span touches THREE calendar years
    (2019, 2020 AND the single instant of 2021), so the divisor is 3 and not
    2. Dividing by `y2 - y1` would answer 731/548 = 1.334 for a two-year span,
    which is at least loud. The quiet failures are the two below.

    ⚠ basis 3 on the same dates is 2.00273973 — a 0.09% difference, which is
    the size of a rounding disagreement and not of a bug. ASSERTED APART."""
    var b1 = xl_yearfrac(_a(_D2019_01_01, _D2021_01_01, 1.0))
    _close(b1, 2.0009124087591244,
           "★★ actual/actual over 2 years: 731 / (1096/3)")
    _close(xl_yearfrac(_a(_D2019_01_01, _D2021_01_01, 3.0)),
           2.0027397260273974, "actual/365 on the same span: 731/365")
    _apart(b1, xl_yearfrac(_a(_D2019_01_01, _D2021_01_01, 3.0)),
           "★ the averaging rule must move the answer off 731/365")
    # ⭐ AND OFF THE OTHER PLAUSIBLE WRONG DENOMINATOR: 731/366 (the "it
    #   contains a leap year so use 366" reading) is 1.99727.
    _apart(b1, FormulaValue.number(731.0 / 366.0),
           "★★ the averaging rule must also differ from a flat 366")


def test_basis_1_SAME_YEAR_arm_and_its_leap_switch() raises:
    """§4.11.7.7.8 — both ends in ONE calendar year: 366 if that year is a leap
    year, else 365. Two spans of the same shape, one year apart:

        2020-01-01 -> 2020-07-01   182 actual days / 366 = 0.49726776
        2018-01-01 -> 2018-07-01   181 actual days / 365 = 0.49589041

    ⚠ THE NON-LEAP CELL IS A DECLARED BLIND INPUT: for a non-leap year basis 1
    and basis 3 are the SAME computation, so that pair separates nothing and is
    asserted EQUAL on purpose. The leap cell is where they part."""
    _close(xl_yearfrac(_a(_D2020_01_01, _D2020_07_01, 1.0)),
           0.4972677595628415, "★ same year, LEAP: 182/366")
    _close(xl_yearfrac(_a(_D2020_01_01, _D2020_07_01, 3.0)),
           0.4986301369863014, "actual/365 on the same span: 182/365")
    _apart(xl_yearfrac(_a(_D2020_01_01, _D2020_07_01, 1.0)),
           xl_yearfrac(_a(_D2020_01_01, _D2020_07_01, 3.0)),
           "★ inside a leap year, basis 1 and basis 3 must differ")
    _close(xl_yearfrac(_a(_D2018_01_01, _D2018_07_01, 1.0)),
           0.4958904109589041, "same year, NON-leap: 181/365")
    assert_equal(
        xl_yearfrac(_a(_D2018_01_01, _D2018_07_01, 1.0)).num,
        xl_yearfrac(_a(_D2018_01_01, _D2018_07_01, 3.0)).num,
        "⚠ DECLARED BLIND: in a non-leap year actual/actual IS actual/365",
    )


def test_YEARFRAC_is_SYMMETRIC_where_DAYS360_is_SIGNED() raises:
    """⚠ A SEMANTIC DIVERGENCE BETWEEN TWO NEIGHBOURING FUNCTIONS, and getting
    it backwards is silent. ODF orders the two dates before counting, so
    YEARFRAC is never negative; `DAYS360` is a SIGNED difference and its own
    docstring says so. Identical dates are 0 under every basis, including the
    30/360 ones where the adjustment clauses could otherwise produce a
    non-zero span out of two equal days."""
    for b in range(0, 5):
        _close(xl_yearfrac(_a(_D2012_07_30, _D2012_01_01, Float64(b))),
               xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, Float64(b))).num,
               "★ YEARFRAC is symmetric under basis " + String(b))
        _close(xl_yearfrac(_a(_D2012_01_01, _D2012_01_01, Float64(b))), 0.0,
               "★ identical dates are 0 under basis " + String(b))
    _close(xl_days360(_a(_D2012_07_30, _D2012_01_01)), -209.0,
           "⚠ and DAYS360 REVERSED is NEGATIVE — the neighbouring function"
           " does not share this rule")


def test_basis_out_of_range_is_NUM_and_truncation_is_TOWARD_ZERO() raises:
    """Every page in this family states the same two sentences: *"basis < 0 or
    basis > 4 returns #NUM!"* and *"all arguments are truncated to integers"*.

    ⚠ TRUNCATION IS TOWARD ZERO AND NOT FLOORING, and `basis` is where the two
    differ: -0.5 truncates to 0 (the default basis, a legal call) and FLOORS to
    -1 (a `#NUM!`). A flooring kernel agrees on every positive input.

    ⚠ `4.9` IS A LEGAL BASIS, truncating to 4. A kernel that range-checked
    BEFORE truncating would refuse it."""
    _err(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 5.0)), XL_ERR_NUM,
         "basis 5 is #NUM!")
    _err(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, -1.0)), XL_ERR_NUM,
         "basis -1 is #NUM!")
    _close(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, -0.5)),
           0.5805555555555556,
           "★ -0.5 TRUNCATES toward zero to basis 0; a flooring kernel would"
           " make it -1 and answer #NUM!")
    _close(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 4.9)),
           0.5805555555555556,
           "★ 4.9 truncates to 4 and is LEGAL — the range check must come"
           " AFTER the truncation")
    _close(xl_yearfrac(_a(_D2012_01_01, _D2012_07_30, 1.9)),
           0.5765027322404371, "1.9 truncates to basis 1")
    _err(xl_yearfrac(_a(-1.0, _D2012_07_30, 0.0)), XL_ERR_VALUE,
         "a negative serial is #VALUE!, not #NUM! — the pages distinguish"
         " 'not a valid serial date' from an out-of-domain number")


def test_an_ERROR_argument_DOMINATES_every_name() raises:
    """`ERRH_PROPAGATE_DOMINANT` is what the descriptor rows declare, so an
    error argument must stop the call rather than be coerced. Asserted at the
    KERNEL so it holds even if a descriptor row is mis-wired."""
    var a = List[FormulaValue]()
    a.append(FormulaValue.error(XL_ERR_NA))
    a.append(FormulaValue.number(_D2012_07_30))
    _err(xl_yearfrac(a), XL_ERR_NA, "YEARFRAC with an error start date")
    var b = List[FormulaValue]()
    b.append(FormulaValue.number(_D2008_02_15))
    b.append(FormulaValue.number(_D2008_05_15))
    b.append(FormulaValue.number(1000000.0))
    b.append(FormulaValue.error(XL_ERR_NA))
    _err(xl_intrate(b), XL_ERR_NA, "INTRATE with an error redemption")


# =============================================================================
# ★ PART TWO — THE EIGHT `Financial` NAMES, each against its OWN published
#   worked example. Nothing here re-derives a day count.
# =============================================================================
def test_ACCRINTM_matches_the_MS_published_example() raises:
    """MS ACCRINTM page (fetched 2026-09-15): issue 39539, settlement 39614,
    rate 0.1, par 1000, basis 3 -> **20.54794521**.

    `ACCRINTM = par x rate x A/D` = 1000 * 0.1 * 75/365.

    ⭐ THE PAGE GIVES ITS DATES AS RAW SERIALS, so this cell also grades this
    tree's serial map: 39539 must decode to 2008-04-01 and 39614 to
    2008-06-15, or the numerator is not 75.

    ⚠ AND THE SECOND CELL GRADES THE DEFAULT BASIS. Omit the argument and the
    answer is 20.55555556 (basis 0, 74 thirty-day days over 360), not
    20.54794521. The two are 0.04% apart — a kernel that ignored `basis`
    entirely would pass any check looser than that."""
    _close(xl_accrintm(_a(_D2008_04_01, _D2008_06_15, 0.1, 1000.0, 3.0)),
           20.54794520547945,
           "★★ MS published 20.54794521 = 1000 * 0.1 * 75/365")
    var dflt = xl_accrintm(_a(_D2008_04_01, _D2008_06_15, 0.1, 1000.0))
    _close(dflt, 20.555555555555554,
           "★ basis OMITTED is basis 0: 1000 * 0.1 * 74/360")
    _apart(dflt, xl_accrintm(_a(_D2008_04_01, _D2008_06_15, 0.1, 1000.0, 3.0)),
           "★ the `basis` argument must MOVE the answer")
    _err(xl_accrintm(_a(_D2008_06_15, _D2008_04_01, 0.1, 1000.0, 3.0)),
         XL_ERR_NUM, "issue >= settlement is #NUM! (not a negative accrual)")
    _err(xl_accrintm(_a(_D2008_04_01, _D2008_06_15, 0.0, 1000.0, 3.0)),
         XL_ERR_NUM, "rate <= 0 is #NUM!")
    _err(xl_accrintm(_a(_D2008_04_01, _D2008_06_15, 0.1, 0.0, 3.0)),
         XL_ERR_NUM, "par <= 0 is #NUM!")


def test_DISC_and_the_MS_page_whose_OWN_EXAMPLE_DOES_NOT_REPRODUCE() raises:
    """⛔⛔ THE ONE PLACE IN THIS FILE WHERE THE PUBLISHED ORACLE IS WRONG, and
    it is recorded rather than worked around.

    Microsoft's DISC page (fetched 2026-09-15) shows settlement 07/01/2018,
    maturity **01/01/2048**, pr 97.975, redemption 100, basis 1, and Result
    **0.001038**. That result is not reachable from those inputs under any
    basis: the span is 29.5 years, and 0.02025/29.5 is 0.000686. It IS
    reproduced to all seven published digits with maturity **01/01/2038**.

    THE EVIDENCE THAT 2038 IS THE INTENDED DATE, not a convenient fit:
      * the SAME page's Remarks describe "a 30-year bond ... issued on
        January 1, 2018 ... the maturity date would be January 1, 2048";
      * PRICEMAT's and YIELDMAT's Remarks describe the same 30-year bond and
        still say "issued on January 1, 2008 ... January 1, 2038".
      ⇒ The page's PROSE and DATA cells were re-dated 2008 -> 2018 and the
        RESULT CELL was never recomputed. `2038-01-01` is the maturity the
        published number was computed against.

    ⇒ SO THIS TEST ASSERTS BOTH: the published number at the maturity that
      produces it, AND the value at the page's own printed inputs — labelled as
      the page's arithmetic error, so nobody "fixes" the kernel toward it. A
      kernel bent until it printed 0.001038 for the 2048 inputs would be wrong
      by a factor of 1.5.

    `DISC = ((redemption - pr)/redemption) x (B/DSM)`."""
    _close(xl_disc(_a(_D2018_07_01, _D2038_01_01, 97.975, 100.0, 1.0)),
           0.0010381908237747707,
           "★★ MS published 0.001038 — reproduced EXACTLY, at the 2038"
           " maturity the page's own Remarks describe")
    _close(xl_disc(_a(_D2018_07_01, _D2048_01_01, 97.975, 100.0, 1.0)),
           0.0006863841691213483,
           "⛔ the value at the page's PRINTED inputs (2048). The page's"
           " Result cell is stale, NOT this kernel")
    _err(xl_disc(_a(_D2038_01_01, _D2018_07_01, 97.975, 100.0, 1.0)),
         XL_ERR_NUM, "settlement >= maturity is #NUM!")
    _err(xl_disc(_a(_D2018_07_01, _D2038_01_01, 0.0, 100.0, 1.0)),
         XL_ERR_NUM, "pr <= 0 is #NUM!")


def test_INTRATE_and_RECEIVED_are_NOT_each_others_inverse() raises:
    """Both MS pages use the SAME bond — 2008-02-15 -> 2008-05-15, basis 2,
    investment 1,000,000 — which makes the pair a free check that the two
    formulas are not one formula written twice.

        INTRATE(.., 1000000, 1014420, 2)   published 0.05768
        RECEIVED(.., 1000000, 0.0575,  2)  published $1,014,584.65

    ⚠ NOTE 1,014,420 AGAINST 1,014,584.65 ON THE SAME BOND: a 5.75% DISCOUNT
    and a 5.768% interest RATE are different quantities, and the redemption
    amounts they imply differ by $165. A kernel that made RECEIVED the inverse
    of INTRATE would answer 1,014,420 — inside 0.02% of the right number.

    ⚠ AND RECEIVED IS A DIVISION. `investment * (1 + discount*yf)` gives
    1,014,375.00 — $209 low, 0.02%, which reads as somebody else's rounding.
    ASSERTED APART."""
    var yf_basis2 = xl_yearfrac(_a(_D2008_02_15, _D2008_05_15, 2.0))
    _close(yf_basis2, 0.25,
           "★ the shared day count is EXACTLY 90/360 — both published cells"
           " rest on it")
    _close(xl_intrate(_a(_D2008_02_15, _D2008_05_15, 1000000.0, 1014420.0,
                         2.0)),
           0.0576800000000004, "★★ MS published 0.05768")
    var rec = xl_received(_a(_D2008_02_15, _D2008_05_15, 1000000.0, 0.0575,
                             2.0))
    _close(rec, 1014584.6544071021, "★★ MS published $1,014,584.65")
    _apart(rec, FormulaValue.number(1000000.0 * (1.0 + 0.0575 * 0.25)),
           "★★ RECEIVED DIVIDES by (1 - d*t); multiplying by (1 + d*t) gives"
           " 1014375.00, which is $209 low and looks like rounding")
    _apart(rec, FormulaValue.number(1014420.0),
           "★ RECEIVED is not the inverse of INTRATE on this bond")
    _err(xl_received(_a(_D2008_02_15, _D2008_05_15, 1000000.0, 0.0, 2.0)),
         XL_ERR_NUM, "discount <= 0 is #NUM!")


def test_PRICEDISC_and_YIELDDISC_differ_only_in_ONE_denominator() raises:
    """Both MS pages use the SAME 14-day bill — 2008-02-16 -> 2008-03-01,
    basis 2 — and the second's `pr` is the first's answer rounded, so the pair
    is a round trip.

        PRICEDISC(.., 0.0525, 100, 2)      published $99.80  (exact 99.79583333)
        YIELDDISC(.., 99.795, 100, 2)      published 0.052823

    ⚠ THE DAY COUNT IS 14 AND NOT 13 because 2008 is a leap year and February
    has 29 days. A non-leap February gives 99.81041667 — a cent and a half out
    on a $100 bond.

    ⛔ AND YIELDDISC IS NOT `DISC`. The only algebraic difference is which side
    of the ratio is the divisor: YIELDDISC divides by `pr`, DISC by
    `redemption`. On this bill that is 0.052822572 against 0.052714286 — 0.21%
    apart, far inside the spread between two bases, so nothing but an exact
    check separates them. ASSERTED APART."""
    _close(xl_yearfrac(_a(_D2008_02_16, _D2008_03_01, 2.0)), 14.0 / 360.0,
           "★ 14 days, because 2008-02 has 29 days")
    _close(xl_pricedisc(_a(_D2008_02_16, _D2008_03_01, 0.0525, 100.0, 2.0)),
           99.79583333333333,
           "★★ MS published $99.80 — exactly 100 - 5.25*14/360")
    var yd = xl_yielddisc(_a(_D2008_02_16, _D2008_03_01, 99.795, 100.0, 2.0))
    _close(yd, 0.052822571986860085, "★★ MS published 0.052823")
    _apart(yd, xl_disc(_a(_D2008_02_16, _D2008_03_01, 99.795, 100.0, 2.0)),
           "★★ YIELDDISC divides by `pr` and DISC by `redemption`: 0.0528226"
           " against 0.0527143, 0.21% apart")
    _err(xl_pricedisc(_a(_D2008_02_16, _D2008_03_01, 0.0525, 0.0, 2.0)),
         XL_ERR_NUM, "redemption <= 0 is #NUM!")


def test_PRICEMAT_is_THREE_day_counts_from_ONE_basis() raises:
    """★ THE SHARPEST GRADE IN THE FILE. MS PRICEMAT page: settlement
    2008-02-15, maturity 2008-04-13, issue 2007-11-11, rate 6.10%, yld 6.10%,
    **basis 0** -> **$99.98** (the page rounds to cents; exact
    99.98449887555697).

    It reads THREE spans off the SAME basis — DIM (issue->maturity), DSM
    (settlement->maturity) and A (issue->settlement) — and TWO of them cross a
    year boundary with a NEGATIVE month difference (11 -> 4 and 11 -> 2)
    carried by the year term. That is the arm a 30/360 kernel that clamps a
    month difference to a positive range gets wrong.

    MEASURED, so the tolerance is justified: a DSM off by ONE thirty-day day
    lands at 100.00155 or 99.96746, and an `A` off by one at 100.00144. None of
    them is "$99.98" even to the cent the page prints — so this cell really
    does grade the day count and not just the algebra.

    ⚠ `rate < 0` AND `yld < 0` ARE `#NUM!` — strictly `<`. A zero-coupon
    security at a zero yield is a legal and exactly-computable call (the price
    is par), and `<=` would refuse the simplest input the formula has."""
    _close(xl_pricemat(_a(_D2008_02_15, _D2008_04_13, _D2007_11_11, 0.061,
                          0.061, 0.0)),
           99.98449887555694, "★★ MS published $99.98 (exact 99.98449888)")
    _close(xl_pricemat(_a(_D2008_02_15, _D2008_04_13, _D2007_11_11, 0.0, 0.0,
                          0.0)),
           100.0,
           "★ a zero coupon at a zero yield prices at PAR — `rate = 0` and"
           " `yld = 0` must be ACCEPTED, not refused")
    _err(xl_pricemat(_a(_D2008_02_15, _D2008_04_13, _D2007_11_11, -0.01, 0.061,
                        0.0)),
         XL_ERR_NUM, "rate < 0 is #NUM!")
    _err(xl_pricemat(_a(_D2008_04_13, _D2008_02_15, _D2007_11_11, 0.061, 0.061,
                        0.0)),
         XL_ERR_NUM, "settlement >= maturity is #NUM!")


def test_YIELDMAT_is_not_the_algebraic_inverse_of_PRICEMAT() raises:
    """MS YIELDMAT page: settlement 2008-03-15, maturity 2008-11-03, issue
    2007-11-08, rate 6.25%, pr 100.0123, **basis 0** -> **0.060954**
    (exact 0.06095433369153868).

    ⛔ IT MUST NOT BE WRITTEN AS "solve PRICEMAT for yld". PRICEMAT discounts
    by `1 + DSM/B x yld`; YIELDMAT divides by `B/DSM` at the END, over an
    accrual base that already carries the accrued coupon. The two coincide only
    in the limit of a short span, so an inverse-of-PRICEMAT kernel agrees on a
    60-day bill and drifts over a year — and this example is a 233-day span.

    ⚠ THE TWO ERROR THRESHOLDS DIFFER AND THE PAGE SAYS SO: `rate < 0` is
    `#NUM!` but `rate = 0` is legal, while `pr <= 0` is `#NUM!` — because `pr`
    is a divisor and `rate` is not. A kernel that used one threshold for both
    is right on every ordinary call."""
    _close(xl_yieldmat(_a(_D2008_03_15, _D2008_11_03, _D2007_11_08, 0.0625,
                          100.0123, 0.0)),
           0.06095433369153868, "★★ MS published 0.060954")
    _err(xl_yieldmat(_a(_D2008_03_15, _D2008_11_03, _D2007_11_08, 0.0625, 0.0,
                        0.0)),
         XL_ERR_NUM, "pr <= 0 is #NUM! — it is a divisor")
    _err(xl_yieldmat(_a(_D2008_03_15, _D2008_11_03, _D2007_11_08, -0.01,
                        100.0123, 0.0)),
         XL_ERR_NUM, "rate < 0 is #NUM!")
    var zero_rate = xl_yieldmat(_a(_D2008_03_15, _D2008_11_03, _D2007_11_08,
                                   0.0, 100.0123, 0.0))
    assert_true(zero_rate.is_number(),
                "★ rate = 0 is LEGAL — a zero-coupon security has a yield")


def test_every_financial_name_MOVES_when_the_basis_MOVES() raises:
    """⭐ THE ONE ASSERTION THAT COVERS THE WIRING RATHER THAN THE ALGEBRA. A
    kernel that read `basis` and then ignored it — or that hardcoded one basis
    — answers a plausible number for every call and passes every single-cell
    check above, because each of those states one basis.

    Every name is called TWICE on the same bond, basis 0 against basis 2, and
    the two answers must differ. 2008-02-15 -> 2008-05-15 is 90/360 = 0.25
    under basis 2 and 90/360 = 0.25 under basis 0 as well — ⛔ SO THAT BOND
    CANNOT BE USED, and the span here (2007-11-11 -> 2008-04-13) is chosen
    because its two counts are 152/360 and 154/360."""
    _apart(xl_yearfrac(_a(_D2007_11_11, _D2008_04_13, 0.0)),
           xl_yearfrac(_a(_D2007_11_11, _D2008_04_13, 2.0)),
           "the fixture span must itself discriminate basis 0 from basis 2")
    _apart(xl_accrintm(_a(_D2007_11_11, _D2008_04_13, 0.05, 1000.0, 0.0)),
           xl_accrintm(_a(_D2007_11_11, _D2008_04_13, 0.05, 1000.0, 2.0)),
           "ACCRINTM reads `basis`")
    _apart(xl_disc(_a(_D2007_11_11, _D2008_04_13, 97.0, 100.0, 0.0)),
           xl_disc(_a(_D2007_11_11, _D2008_04_13, 97.0, 100.0, 2.0)),
           "DISC reads `basis`")
    _apart(xl_intrate(_a(_D2007_11_11, _D2008_04_13, 1000.0, 1050.0, 0.0)),
           xl_intrate(_a(_D2007_11_11, _D2008_04_13, 1000.0, 1050.0, 2.0)),
           "INTRATE reads `basis`")
    _apart(xl_received(_a(_D2007_11_11, _D2008_04_13, 1000.0, 0.05, 0.0)),
           xl_received(_a(_D2007_11_11, _D2008_04_13, 1000.0, 0.05, 2.0)),
           "RECEIVED reads `basis`")
    _apart(xl_pricedisc(_a(_D2007_11_11, _D2008_04_13, 0.05, 100.0, 0.0)),
           xl_pricedisc(_a(_D2007_11_11, _D2008_04_13, 0.05, 100.0, 2.0)),
           "PRICEDISC reads `basis`")
    _apart(xl_yielddisc(_a(_D2007_11_11, _D2008_04_13, 97.0, 100.0, 0.0)),
           xl_yielddisc(_a(_D2007_11_11, _D2008_04_13, 97.0, 100.0, 2.0)),
           "YIELDDISC reads `basis`")
    _apart(xl_pricemat(_a(_D2008_02_15, _D2008_04_13, _D2007_11_11, 0.061,
                          0.061, 0.0)),
           xl_pricemat(_a(_D2008_02_15, _D2008_04_13, _D2007_11_11, 0.061,
                          0.061, 2.0)),
           "PRICEMAT reads `basis`")
    _apart(xl_yieldmat(_a(_D2008_03_15, _D2008_11_03, _D2007_11_08, 0.0625,
                          100.0123, 0.0)),
           xl_yieldmat(_a(_D2008_03_15, _D2008_11_03, _D2007_11_08, 0.0625,
                          100.0123, 2.0)),
           "YIELDMAT reads `basis`")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_xl_financial_kernels.mojo — ★ THE CATEGORY THAT WAS AT ZERO, GRADED.
# =============================================================================
#
#
# ============ ⛔⛔ THE SELECTION RULE, AND IT IS SHARPER HERE THAN ANYWHERE
#
# Every other kernel family in this tree can be wrong in a way a reader
# notices. A financial function cannot. So the rule this file follows is not
# "one test per function" and it is not even the sibling file's "a case where
# the obvious implementation is wrong" — it is **an input where a
# plausible-but-wrong kernel returns a number of the right sign, the right
# magnitude and the wrong value**:
#
#   PMT        the SIGN. -162.745 and not +162.745; the magnitude is what a
#              reviewer's mental arithmetic checks, and it is the half that is
#              right in both implementations
#   rate = 0   the LIMIT arm. Without it every interest-free loan is 0/0
#   type = 1   one extra period of interest on every payment: 231 vs 210
#   IPMT/PPMT  two negative numbers of the same order that must SUM to PMT
#   ISPMT      one letter from IPMT, -64814.81 against -66666.67
#   NPV        the first value discounted ONE period: 90.909 and not 100
#   RATE       a residual with TWO roots, both exact, selected by the GUESS
#   DB         the documented THREE-DECIMAL rate rounding: 186083.33 against
#              185912.96, a 0.09% difference that looks like float drift
#   DDB        the salvage CLIP: 22.12 against the unclipped curve's 64.42,
#              and the clip only bites in the last periods a fixture omits
#   SLN/SYD    they AGREE at the middle period of an odd-life asset
#
# ⚠ NO `EngineContext`, NO FILE, NO FIXTURE — this file is welded to
# `komira_xl_plan`, which downstream bindings link, so every assertion is a
# pure function of a `FormulaValue`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.plan.excel_error_code import (
    XL_ERR_DIV0,
    XL_ERR_NA,
    XL_ERR_NUM,
    XL_ERR_VALUE,
)

from komira_xl_plan.formula_value import FormulaValue
from komira_xl_plan.xl_scalar_financial import (
    xl_cumipmt,
    xl_cumprinc,
    xl_db,
    xl_ddb,
    xl_dollarde,
    xl_dollarfr,
    xl_effect,
    xl_fv,
    xl_ipmt,
    xl_ispmt,
    xl_nominal,
    xl_nper,
    xl_npv,
    xl_pduration,
    xl_pmt,
    xl_ppmt,
    xl_pv,
    xl_rate,
    xl_rri,
    xl_sln,
    xl_syd,
)


# =============================================================================
# Argument helpers — a kernel takes a `List[FormulaValue]`.
# =============================================================================
def _a1(a: Float64) -> List[FormulaValue]:
    var v = List[FormulaValue]()
    v.append(FormulaValue.number(a))
    return v^


def _a2(a: Float64, b: Float64) -> List[FormulaValue]:
    var v = List[FormulaValue]()
    v.append(FormulaValue.number(a))
    v.append(FormulaValue.number(b))
    return v^


def _a3(a: Float64, b: Float64, c: Float64) -> List[FormulaValue]:
    var v = List[FormulaValue]()
    v.append(FormulaValue.number(a))
    v.append(FormulaValue.number(b))
    v.append(FormulaValue.number(c))
    return v^


def _a4(a: Float64, b: Float64, c: Float64, d: Float64) -> List[FormulaValue]:
    var v = _a3(a, b, c)
    v.append(FormulaValue.number(d))
    return v^


def _a5(a: Float64, b: Float64, c: Float64, d: Float64,
        e: Float64) -> List[FormulaValue]:
    var v = _a4(a, b, c, d)
    v.append(FormulaValue.number(e))
    return v^


def _a6(a: Float64, b: Float64, c: Float64, d: Float64, e: Float64,
        f: Float64) -> List[FormulaValue]:
    var v = _a5(a, b, c, d, e)
    v.append(FormulaValue.number(f))
    return v^


def _close(r: FormulaValue, want: Float64, why: String) raises:
    """A NUMBER equal to `want` to within 1e-9 RELATIVE (absolute below 1).

    ⚠ RELATIVE AND NOT ABSOLUTE, WHICH THE SIBLING FILE'S `_assert_close` IS.
    The values here span nine orders of magnitude — `RRI(96, 10000, 11000)` is
    0.00099 and `DB(1000000, 100000, 6, 1, 7)` is 186083.33 — and a single
    absolute epsilon is either meaningless at one end or brittle at the other.
    1e-9 relative is ~4.5e6 times LOOSER than one ulp and still ~5 orders of
    magnitude TIGHTER than every divergence this file asserts about (the
    smallest is DB's rounded-vs-unrounded 170.37 on 186083.33, i.e. 9e-4
    relative)."""
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
    """⭐ THE ASSERTION THAT MAKES A PAIR MEAN SOMETHING. Two kernels that
    answer the same number on the fixture cannot be told apart by it, however
    many cells the fixture has."""
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
# ★★ PMT — the SIGN is the finding.
# =============================================================================
def test_pmt_is_NEGATIVE_because_you_pay_it() raises:
    """⛔⛔ THE MAGNITUDE IS RIGHT IN BOTH IMPLEMENTATIONS AND THE SIGN IS NOT.
    Excel's convention is that money you PAY is negative: you received 1000
    and you pay 162.75 a period back, so `PMT(0.1, 10, 1000)` is
    **-162.745394882…**. A kernel returning +162.745 agrees with every mental
    arithmetic check a reviewer makes.

    ⚠ ASSERTED AS A SIGN **AND** A VALUE. A sign-only assertion passes for a
    kernel that returns -1."""
    var p = xl_pmt(_a3(0.1, 10.0, 1000.0))
    _close(p, -162.74539488251153, "PMT(0.1,10,1000)")
    assert_true(p.num < 0.0, "★ THE SIGN: a payment you make is NEGATIVE")


def test_the_rate_zero_arm_is_the_LIMIT_and_not_a_division_by_zero() raises:
    """⛔ `((1+r)^n - 1)/r` IS `0/0` AT r = 0 AND ITS LIMIT IS `n`. An
    interest-free loan is an entirely ordinary spreadsheet; without the limit
    arm every one of these four is `#DIV/0!` or NaN.

    ⭐ AND THE FOUR ANSWERS ARE THE ONES ARITHMETIC DEMANDS: ten payments of a
    tenth, and a present value that equals a future value because there is
    nothing to discount by."""
    _close(xl_pmt(_a3(0.0, 10.0, 1000.0)), -100.0, "PMT(0,10,1000)")
    _close(xl_fv(_a3(0.0, 2.0, -100.0)), 200.0, "FV(0,2,-100)")
    _close(xl_pv(_a3(0.0, 2.0, -100.0)), 200.0, "PV(0,2,-100)")
    _close(xl_nper(_a3(0.0, -100.0, 1000.0)), 10.0, "NPER(0,-100,1000)")


def test_pmt_refuses_nper_zero_with_NUM_rather_than_leaking_an_infinity() raises:
    """⚠ `-(fv + pv)/0` IS `-inf` IN IEEE AND `inf` TRAVELS. There is no
    payment that amortises a balance over no periods, and `#NUM!` says so
    where an infinity would sum happily into a total."""
    _err(xl_pmt(_a3(0.1, 0.0, 1000.0)), XL_ERR_NUM, "PMT(0.1,0,1000)")


# =============================================================================
# ★★ FV / PV — the blind input is rate = 0, where they COINCIDE.
# =============================================================================
def test_fv_and_pv_AGREE_at_rate_zero_and_DIVERGE_at_ten_percent() raises:
    """⭐⭐ THE BLINDNESS EVIDENCE, BOTH HALVES. At rate = 0 there is no
    discounting, so FV and PV are the SAME NUMBER (200) and a fixture confined
    to interest-free cash flows cannot tell the two functions apart AT ALL. At
    10% they are 210 and 173.554 — compounding forward versus discounting
    back. Stating only the second half is the omission this effort is named
    for."""
    var fv0 = xl_fv(_a3(0.0, 2.0, -100.0))
    var pv0 = xl_pv(_a3(0.0, 2.0, -100.0))
    assert_equal(fv0.num, pv0.num, "★ THE BLIND INPUT: at rate 0 they AGREE")
    var fv1 = xl_fv(_a3(0.1, 2.0, -100.0))
    var pv1 = xl_pv(_a3(0.1, 2.0, -100.0))
    _close(fv1, 210.0, "FV(0.1,2,-100)")
    _close(pv1, 173.55371900826458, "PV(0.1,2,-100)")
    _apart(fv1, pv1, "★ THE SHARP INPUT: FV compounds, PV discounts")


def test_type_one_buys_every_payment_one_more_period_of_interest() raises:
    """⚠ `type` IS NOT DECORATION. `FV(0.1,2,-100,0,1)` is **231** where
    `FV(0.1,2,-100)` is 210: payments at the START of a period each earn one
    more period of interest, and 231 = 210 * 1.1 exactly. A kernel that
    ignored `type` answers 210 for both — a correct number for the wrong
    contract."""
    var end = xl_fv(_a5(0.1, 2.0, -100.0, 0.0, 0.0))
    var begin = xl_fv(_a5(0.1, 2.0, -100.0, 0.0, 1.0))
    _close(end, 210.0, "FV type=0")
    _close(begin, 231.0, "FV type=1")
    _close(begin, end.num * 1.1,
           "★ the beginning-of-period annuity is the end-of-period one "
           "compounded ONE more period")


def test_pv_of_a_one_period_annuity_IS_npv_of_one_value() raises:
    """★ A RELATION NEITHER KERNEL KNOWS ABOUT, WHICH IS WHAT MAKES IT
    EVIDENCE. `PV(0.1, 1, -100)` and `NPV(0.1, 100)` are both
    **90.9090909…** because a one-period annuity IS a one-element series. Two
    independently-written kernels that agree here are both discounting by one
    full period; a kernel that started NPV's exponent at 0 answers 100."""
    var pv = xl_pv(_a3(0.1, 1.0, -100.0))
    var npv = xl_npv(_a2(0.1, 100.0))
    _close(pv, 90.90909090909091, "PV(0.1,1,-100)")
    _close(npv, 90.90909090909091, "NPV(0.1,100)")
    _close(npv, pv.num, "★ the two kernels AGREE without sharing code")


# =============================================================================
# ★★ NPV — the first value is discounted ONE period.
# =============================================================================
def test_npv_discounts_the_FIRST_value_a_full_period() raises:
    """⛔⛔ THE MOST-REPORTED GOTCHA IN THE WHOLE CATEGORY. `NPV(0.1, 100)` is
    90.909…, NOT 100: Excel's NPV assumes every cash flow arrives at the END
    of its period, so an investment made TODAY has to be added outside the
    call. A kernel that started the exponent at 0 answers **100** — a round
    number that looks like a correct answer.

    ⭐ AND THE SECOND VALUE PINS THE EXPONENT'S STEP: `NPV(0.1, 100, 200)` is
    256.198…, i.e. 100/1.1 + 200/1.21. A kernel that discounted every term by
    ONE period (rather than by its index) answers 272.7."""
    _close(xl_npv(_a2(0.1, 100.0)), 90.90909090909091, "NPV(0.1,100)")
    _close(xl_npv(_a3(0.1, 100.0, 200.0)), 256.198347107438,
           "NPV(0.1,100,200)")
    var flat = 100.0 / 1.1 + 200.0 / 1.1
    var got = xl_npv(_a3(0.1, 100.0, 200.0))
    var d = got.num - flat
    if d < 0.0:
        d = -d
    assert_true(d > 1.0,
                "★ the exponent ADVANCES per term; a one-period-for-all "
                "kernel answers " + String(flat))


def test_npv_rate_minus_one_is_a_division_by_zero_and_says_so() raises:
    """⚠ THE FIRST DISCOUNT FACTOR IS EXACTLY ZERO at rate = -1. `#DIV/0!`
    names the operation that failed, where `#NUM!` would not."""
    _err(xl_npv(_a2(-1.0, 100.0)), XL_ERR_DIV0, "NPV(-1,100)")


# =============================================================================
# ★★ IPMT / PPMT — two negative numbers that MUST sum to PMT.
# =============================================================================
def test_ipmt_plus_ppmt_is_PMT_for_EVERY_period_of_a_schedule() raises:
    """⛔ ASSERTED ACROSS THE WHOLE SCHEDULE AND NOT AT ONE PERIOD. Two
    kernels that each drift by the same amount satisfy this at a single
    point; ten periods of a 10% loan do not let them.

    ★ AND IT IS AN INVARIANT NEITHER KERNEL CAN SEE — `xl_ppmt` computes
    `PMT - IPMT`, so the sum is trivially PMT *only if* `_ipmt_raw` is the
    same function `xl_ipmt` exposes. A wiring that pointed `PPMT` at a
    SECOND derivation of the split is exactly what this catches."""
    var pmt = xl_pmt(_a3(0.1, 10.0, 1000.0))
    var per = 1
    while per <= 10:
        var ip = xl_ipmt(_a4(0.1, Float64(per), 10.0, 1000.0))
        var pp = xl_ppmt(_a4(0.1, Float64(per), 10.0, 1000.0))
        _close(FormulaValue.number(ip.num + pp.num), pmt.num,
               "IPMT + PPMT == PMT at period " + String(per))
        per += 1


def test_ipmt_and_ppmt_are_NOT_each_other() raises:
    """⛔⛔ THE MOST DANGEROUS PAIR IN THE FAMILY: both negative, both the same
    order of magnitude, both varying smoothly with the period, and a schedule
    built from the wrong one still sums to the right TOTAL over the full term.
    At period 1 of a 10-period 10% loan on 1000 they are **-100** and
    **-62.745**; by period 10 they have CROSSED, to -14.795 and -147.950.

    ★ THE CROSSING IS THE ASSERTION. A fixture confined to early periods
    cannot distinguish "interest falls" from "principal falls"."""
    var i1 = xl_ipmt(_a4(0.1, 1.0, 10.0, 1000.0))
    var p1 = xl_ppmt(_a4(0.1, 1.0, 10.0, 1000.0))
    _close(i1, -100.0, "IPMT period 1 is just the interest on 1000 at 10%")
    _close(p1, -62.74539488251153, "PPMT period 1")
    _apart(i1, p1, "period 1")
    var i10 = xl_ipmt(_a4(0.1, 10.0, 10.0, 1000.0))
    var p10 = xl_ppmt(_a4(0.1, 10.0, 10.0, 1000.0))
    _close(i10, -14.795035898410152, "IPMT period 10")
    _close(p10, -147.95035898410137, "PPMT period 10")
    assert_true(i1.num < p1.num and i10.num > p10.num,
                "★ THE SCHEDULE CROSSES: interest dominates early and "
                "principal dominates late")


def test_ipmt_period_2_needs_the_balance_ROLLED_FORWARD() raises:
    """★ PERIOD 1 IS THE CELL A WRONG KERNEL PASSES. -100 falls out of several
    wrong formulas (it is just `-pv * rate`). Period 2 is **-93.7254605116**,
    which requires the balance after one payment to have been computed
    correctly — `1000*1.1 - 162.745 = 937.255`, times 10%."""
    _close(xl_ipmt(_a4(0.1, 2.0, 10.0, 1000.0)), -93.72546051174885,
           "IPMT(0.1,2,10,1000)")


def test_ipmt_type_one_first_period_has_NO_interest_at_all() raises:
    """⚠ NOT AN OFF-BY-ONE OF THE type = 0 ARM. With payments at the START of
    a period the first one is made before any interest has accrued, so
    `IPMT(…, per = 1, type = 1)` is **exactly 0** where the type = 0 answer is
    -100. A kernel that shifted the period index by one answers -90.909."""
    var t1 = xl_ipmt(_a6(0.1, 1.0, 10.0, 1000.0, 0.0, 1.0))
    assert_equal(t1.num, 0.0,
                 "★ EXACTLY ZERO — a payment made before interest accrues")
    var t0 = xl_ipmt(_a6(0.1, 1.0, 10.0, 1000.0, 0.0, 0.0))
    _close(t0, -100.0, "and the type=0 answer is NOT zero")


def test_ipmt_refuses_a_period_outside_the_schedule() raises:
    """⚠ `per` OUTSIDE `1..nper` IS `#NUM!`, not an extrapolated number. A
    declining-balance formula happily evaluates at period 0 and period 11."""
    _err(xl_ipmt(_a4(0.1, 0.0, 10.0, 1000.0)), XL_ERR_NUM, "IPMT per=0")
    _err(xl_ipmt(_a4(0.1, 11.0, 10.0, 1000.0)), XL_ERR_NUM, "IPMT per=11")
    _err(xl_ppmt(_a4(0.1, 11.0, 10.0, 1000.0)), XL_ERR_NUM, "PPMT per=11")


def test_ispmt_is_ONE_LETTER_from_ipmt_and_a_different_function() raises:
    """⛔⛔ `ISPMT` AND `IPMT` DIFFER BY ONE LETTER AND BY A WHOLE MODEL.
    `IPMT` splits a LEVEL payment; `ISPMT` assumes the principal is repaid in
    equal slices, so its interest falls LINEARLY. On the published example
    `(0.1/12, 1, 36, 8000000)` they are **-64814.8148…** and **-66666.667** —
    both negative five-figure numbers, 2.8% apart, and only one is right."""
    var a = xl_ispmt(_a4(0.1 / 12.0, 1.0, 36.0, 8000000.0))
    var b = xl_ipmt(_a4(0.1 / 12.0, 1.0, 36.0, 8000000.0))
    _close(a, -64814.81481481482, "ISPMT(0.1/12,1,36,8000000)")
    _close(b, -66666.66666666667, "IPMT at the same arguments")
    _apart(a, b, "ISPMT is not IPMT")
    _err(xl_ispmt(_a4(0.1, 1.0, 0.0, 1000.0)), XL_ERR_DIV0, "ISPMT nper=0")


# =============================================================================
# ★★ CUMIPMT / CUMPRINC — the sums, and their five refusals.
# =============================================================================
def test_cumipmt_over_one_period_IS_ipmt_and_over_a_year_is_not() raises:
    """★ THE ONE-PERIOD CELL IS THE CONTROL THAT SAYS THE SUM SUMS THE RIGHT
    THING: `CUMIPMT(0.09/12, 360, 125000, 1, 1, 0)` is **-937.50**, exactly
    `IPMT` at period 1. The twelve-period cell (**-11135.23**, the second
    year of the published example) is the one no single-period kernel can
    produce."""
    _close(xl_cumipmt(_a6(0.09 / 12.0, 360.0, 125000.0, 1.0, 1.0, 0.0)),
           -937.5, "CUMIPMT one period")
    _close(xl_ipmt(_a4(0.09 / 12.0, 1.0, 360.0, 125000.0)),
           -937.5, "IPMT period 1 — the control")
    _close(xl_cumipmt(_a6(0.09 / 12.0, 360.0, 125000.0, 13.0, 24.0, 0.0)),
           -11135.232130750845, "CUMIPMT year 2")


def test_cumprinc_and_cumipmt_are_an_ORDER_OF_MAGNITUDE_apart_early() raises:
    """⛔ BOTH ARE LARGE AND NEGATIVE OVER A FULL TERM, so a total-only
    fixture cannot tell them apart. Over the SECOND YEAR of a 30-year 9%
    mortgage they are **-11135.23** and **-934.107** — because early payments
    are almost all interest. Over the last year the ordering reverses, which
    is why one end of the schedule proves nothing."""
    var i = xl_cumipmt(_a6(0.09 / 12.0, 360.0, 125000.0, 13.0, 24.0, 0.0))
    var p = xl_cumprinc(_a6(0.09 / 12.0, 360.0, 125000.0, 13.0, 24.0, 0.0))
    _close(p, -934.1071234208781, "CUMPRINC year 2")
    _apart(i, p, "CUMIPMT vs CUMPRINC in year 2")
    assert_true(i.num < p.num * 10.0,
                "★ interest dominates by an order of magnitude early on")


def test_the_cumulative_pair_refuses_FIVE_ways_and_every_one_is_NUM() raises:
    """⚠ `type` OUTSIDE {0, 1} IS `#NUM!` AND NOT `#VALUE!` — the opposite of
    what a "bad argument" instinct produces, and Microsoft states it. A
    silently-clamped `type` would produce a wrong TOTAL rather than a wrong
    single payment, which is the harder error to notice."""
    _err(xl_cumipmt(_a6(0.0, 360.0, 125000.0, 1.0, 1.0, 0.0)),
         XL_ERR_NUM, "rate <= 0")
    _err(xl_cumipmt(_a6(0.01, 0.0, 125000.0, 1.0, 1.0, 0.0)),
         XL_ERR_NUM, "nper <= 0")
    _err(xl_cumipmt(_a6(0.01, 360.0, 0.0, 1.0, 1.0, 0.0)),
         XL_ERR_NUM, "pv <= 0")
    _err(xl_cumipmt(_a6(0.01, 360.0, 125000.0, 5.0, 2.0, 0.0)),
         XL_ERR_NUM, "start > end")
    _err(xl_cumprinc(_a6(0.01, 360.0, 125000.0, 1.0, 1.0, 2.0)),
         XL_ERR_NUM, "★ type = 2 is #NUM!, not #VALUE!")


# =============================================================================
# ★★ NPER / RATE — the two that INVERT the relation.
# =============================================================================
def test_nper_inverts_pmt_and_rate_inverts_both() raises:
    """★★ THE ROUND TRIP NOBODY CAN FAKE. `PMT(0.1, 10, 1000)` is some
    number; feed it back and `NPER` must return **10** and `RATE` must return
    **0.1**. Three kernels, one relation, and a sign error or a `type`
    confusion in ANY of them breaks the circuit."""
    var pmt = xl_pmt(_a3(0.1, 10.0, 1000.0))
    _close(xl_nper(_a3(0.1, pmt.num, 1000.0)), 10.0,
           "NPER(0.1, PMT(0.1,10,1000), 1000) == 10")
    _close(xl_rate(_a3(10.0, pmt.num, 1000.0)), 0.1,
           "RATE(10, PMT(0.1,10,1000), 1000) == 0.1")


def test_nper_second_argument_is_the_PAYMENT_and_every_sibling_differs() raises:
    """⚠ `NPER(rate, pmt, pv, …)` — and every other member of this family is
    `(rate, nper, …)`. Swapping `pmt` and `pv` answers a plausible number of
    periods for almost any input, so the published example is asserted in
    full: `NPER(0.12/12, -100, -1000, 10000, 1)` is **59.6738656743**."""
    _close(xl_nper(_a5(0.12 / 12.0, -100.0, -1000.0, 10000.0, 1.0)),
           59.67386567429457, "the published NPER example")
    var swapped = xl_nper(_a5(0.12 / 12.0, -1000.0, -100.0, 10000.0, 1.0))
    _apart(xl_nper(_a5(0.12 / 12.0, -100.0, -1000.0, 10000.0, 1.0)), swapped,
           "★ the argument order MATTERS and the swap answers a number")


def test_nper_refuses_when_the_payments_never_retire_the_balance() raises:
    """⛔ `log` OF A NON-POSITIVE RATIO IS `#NUM!` AND IT IS NOT A DEFENSIVE
    CHECK: it is the case where there IS no number of periods. libm would
    hand back `nan`, which is not `<`, not `>` and not `==` anything.

    ⛔⛔ AND THE FIRST SPELLING OF THIS TEST WAS WRONG IN A WAY THE GATE
    CAUGHT, WHICH IS WHY IT IS WRITTEN OUT. It asserted `#NUM!` for
    `NPER(0.1, 100, 1000)` — and the right answer there is **-7.2725…**, a
    NEGATIVE number of periods, which is the genuine solution of the relation
    and is what Excel returns. "The arguments look economically odd" is not
    the refusal condition; `num/den <= 0` is, and `den == 0` is its own arm."""
    _err(xl_nper(_a3(0.1, 100.0, -2000.0)), XL_ERR_NUM,
         "★ the ratio is NEGATIVE, so the logarithm has no real value")
    _err(xl_nper(_a3(0.1, 100.0, -1000.0)), XL_ERR_NUM,
         "★ the denominator is EXACTLY zero — its own arm")
    _close(xl_nper(_a3(0.1, 100.0, 1000.0)), -7.272540897341713,
           "★ AND A NEGATIVE ANSWER IS NOT A REFUSAL: this one is real")


def test_rate_converges_to_a_DIFFERENT_ROOT_PER_GUESS() raises:
    """⭐⭐ THE CELL THE BRIEF ASKED FOR: an input where a naive implementation
    converges to a different root. `RATE(2, -2.8, 1, 4.72)` has the residual
    `r^2 - 0.8r + 0.12`, whose roots are **0.2 and 0.6** — BOTH exact
    solutions of Excel's own annuity equation, and Microsoft says so:
    *"RATE is calculated by iteration and can have zero or more solutions."*

    The default guess 0.1 finds 0.2; `guess = 0.5` finds 0.6. ⛔ A SOLVER THAT
    IGNORED THE GUESS — a bisection over a fixed bracket, say — answers the
    SAME number twice and passes any single-cell test.

    ★ BOTH ANSWERS ARE THEN CHECKED AGAINST THE RELATION ITSELF, via `FV`: a
    root of the residual is a rate at which the future value is zero. That is
    what makes this a correctness assertion and not a transcription."""
    var lo = xl_rate(_a6(2.0, -2.8, 1.0, 4.72, 0.0, 0.1))
    var hi = xl_rate(_a6(2.0, -2.8, 1.0, 4.72, 0.0, 0.5))
    _close(lo, 0.2, "the default guess finds the LOWER root")
    _close(hi, 0.6, "guess = 0.5 finds the UPPER root")
    _apart(lo, hi, "★ the GUESS selects the root")
    # ⭐ EACH ROOT REPRODUCES THE `fv` RATE WAS GIVEN. Excel's relation is
    # `raw + fv = 0` and `FV` is `-raw`, so `FV(root, …)` is exactly the `fv`
    # argument — a closed circuit through a DIFFERENT kernel, which is what
    # makes this a correctness assertion rather than a transcription.
    _close(xl_fv(_a4(lo.num, 2.0, -2.8, 1.0)), 4.72,
           "the lower root reproduces the fv RATE was given")
    _close(xl_fv(_a4(hi.num, 2.0, -2.8, 1.0)), 4.72,
           "and so does the upper one")


def test_rate_returns_NUM_when_it_does_not_converge() raises:
    """⛔ THE ITERATION CAP IS PART OF THE PUBLISHED CONTRACT, NOT A TUNING
    KNOB: *"If the successive results of RATE do not converge to within
    0.0000001 after 20 iterations, RATE returns the #NUM! error value."*
    `RATE(3, 100, 100)` has cash flows that never change sign, so the residual
    has no root at all — a kernel that iterated to machine precision would
    return whatever it drifted to, and a number here is worse than an error."""
    _err(xl_rate(_a3(3.0, 100.0, 100.0)), XL_ERR_NUM,
         "no sign change, so no root")
    _err(xl_rate(_a3(0.0, -100.0, 1000.0)), XL_ERR_NUM, "nper = 0")


# =============================================================================
# ★★ EFFECT / NOMINAL — inverses, and they AGREE at npery = 1.
# =============================================================================
def test_effect_and_nominal_AGREE_at_npery_one_and_INVERT_everywhere() raises:
    """⭐ THE BLIND INPUT IS `npery = 1`, where BOTH functions are the
    identity — a fixture confined to annual compounding cannot tell them
    apart at all. At `npery = 4` on a 100% nominal rate they are
    **1.44140625** and **0.7568284600…**, on OPPOSITE sides of the input.

    ★ AND THE ROUND TRIP IS THE ASSERTION NOBODY CAN FAKE:
    `NOMINAL(EFFECT(r, n), n) == r` for every r and n, the way
    `DECIMAL(BASE(x, b), b) == x` is for the radix pair."""
    var e1 = xl_effect(_a2(1.0, 1.0))
    var n1 = xl_nominal(_a2(1.0, 1.0))
    assert_equal(e1.num, n1.num, "★ THE BLIND INPUT: npery = 1")
    var e4 = xl_effect(_a2(1.0, 4.0))
    var n4 = xl_nominal(_a2(1.0, 4.0))
    _close(e4, 1.44140625, "EFFECT(1,4) — 1.25^4 - 1, exactly representable")
    _close(n4, 0.7568284600108841, "NOMINAL(1,4)")
    _apart(e4, n4, "★ THE SHARP INPUT")
    assert_true(e4.num > 1.0 and n4.num < 1.0,
                "★ they land on OPPOSITE SIDES of the 100% input")
    # The published example, and the round trip through it.
    var eff = xl_effect(_a2(0.0525, 4.0))
    _close(eff, 0.05354266737075819, "the published EFFECT example")
    _close(xl_nominal(_a2(eff.num, 4.0)), 0.0525,
           "★ NOMINAL(EFFECT(r,n),n) == r")


def test_npery_is_TRUNCATED_and_the_domain_refusals_are_NUM() raises:
    """⚠ EXCEL TRUNCATES `npery` RATHER THAN ROUNDING, so `EFFECT(0.0525,
    4.9)` is the QUARTERLY answer. A rounding kernel computes a
    five-period-per-year rate, which is a number nobody can spot as wrong."""
    _close(xl_effect(_a2(0.0525, 4.9)), 0.05354266737075819,
           "★ 4.9 TRUNCATES to 4")
    _err(xl_effect(_a2(0.0, 4.0)), XL_ERR_NUM, "nominal_rate <= 0")
    _err(xl_effect(_a2(0.05, 0.0)), XL_ERR_NUM, "npery < 1")
    _err(xl_nominal(_a2(0.0, 4.0)), XL_ERR_NUM, "effect_rate <= 0")


def test_rri_and_pduration_are_INVERSES() raises:
    """★ THE ROUND TRIP GRADES BOTH. `RRI(2, 100, 121)` is **0.1** and
    `PDURATION(0.1, 100, 121)` is **2**. Neither number is producible by a
    kernel with the exponent the wrong way up — `(121/100)^2 - 1` is 0.4641.

    ⚠ AND BOTH PUBLISHED EXAMPLES ARE ASSERTED, because a two-period
    round-trip is symmetric enough that an exponent error could cancel."""
    _close(xl_rri(_a3(2.0, 100.0, 121.0)), 0.1, "RRI(2,100,121)")
    _close(xl_pduration(_a3(0.1, 100.0, 121.0)), 2.0, "PDURATION(0.1,100,121)")
    _close(xl_rri(_a3(96.0, 10000.0, 11000.0)), 0.0009933073762913303,
           "the published RRI example")
    _close(xl_pduration(_a3(0.025, 2000.0, 2200.0)), 3.859866162622655,
           "the published PDURATION example")
    _err(xl_rri(_a3(0.0, 100.0, 121.0)), XL_ERR_NUM, "nper <= 0")
    _err(xl_pduration(_a3(0.0, 100.0, 121.0)), XL_ERR_NUM, "rate <= 0")
    _err(xl_pduration(_a3(0.1, 0.0, 121.0)), XL_ERR_NUM, "pv <= 0")


# =============================================================================
# ★★ DOLLARDE / DOLLARFR — the fraction is a NUMERATOR, not a decimal.
# =============================================================================
def test_dollarde_reads_the_fraction_as_a_NUMERATOR_in_a_FIELD() raises:
    """⛔⛔ `1.02` IN SIXTEENTHS IS **1.125**, i.e. one dollar and two
    SIXTEENTHS. The `.02` is scaled by `10^ceil(log10(16))` = 100 FIRST and
    only then divided by 16. A kernel that read `.02` as two hundredths
    answers `1 + 0.02/16` = **1.00125** — a dollar-shaped number wrong by a
    factor of 100.

    ⭐ THE BLIND INPUT IS A WHOLE NUMBER: `DOLLARDE(2,16)` and
    `DOLLARFR(2,16)` are BOTH 2, because a price with no fractional part has
    nothing to re-scale."""
    _close(xl_dollarde(_a2(1.02, 16.0)), 1.125, "DOLLARDE(1.02,16)")
    _close(xl_dollarde(_a2(1.1, 32.0)), 1.3125, "DOLLARDE(1.1,32)")
    var de2 = xl_dollarde(_a2(2.0, 16.0))
    var fr2 = xl_dollarfr(_a2(2.0, 16.0))
    assert_equal(de2.num, fr2.num, "★ THE BLIND INPUT: a whole-dollar price")
    var de = xl_dollarde(_a2(1.125, 16.0))
    var fr = xl_dollarfr(_a2(1.125, 16.0))
    _close(de, 1.78125, "DOLLARDE(1.125,16)")
    _close(fr, 1.02, "DOLLARFR(1.125,16)")
    _apart(de, fr, "★ THE SHARP INPUT: the two run in opposite directions")


def test_the_dollar_pair_round_trips_and_refuses_two_DIFFERENT_ways() raises:
    """★ `DOLLARDE(DOLLARFR(x, b), b) == x` — the radix pair's property.

    ⚠ `fraction = 0` IS `#DIV/0!` AND A NEGATIVE ONE IS `#NUM!`. Two different
    errors for two different reasons, and a kernel that reported one for both
    loses the distinction Excel makes."""
    var fr = xl_dollarfr(_a2(1.3125, 32.0))
    _close(fr, 1.1, "DOLLARFR(1.3125,32)")
    _close(xl_dollarde(_a2(fr.num, 32.0)), 1.3125, "★ the round trip")
    _err(xl_dollarde(_a2(1.02, 0.0)), XL_ERR_DIV0, "fraction = 0")
    _err(xl_dollarde(_a2(1.02, -4.0)), XL_ERR_NUM, "fraction < 0")
    _err(xl_dollarfr(_a2(1.02, 0.0)), XL_ERR_DIV0, "fraction = 0")


# =============================================================================
# ★★ DEPRECIATION — four schedules, and two pairs that AGREE somewhere.
# =============================================================================
def test_sln_and_syd_AGREE_at_the_MIDDLE_period_of_an_odd_life() raises:
    """⭐⭐ THE BLINDNESS EVIDENCE. The sum-of-years schedule crosses the
    straight line EXACTLY at `per = (life+1)/2`, so `SLN(3000,0,3)` and
    `SYD(3000,0,3,2)` are BOTH 1000 and a fixture that only ever asks about
    the middle period cannot tell an accelerating schedule from a flat one.
    At the ends they are 1500 and 500 — a 3:1 ratio that says the schedule
    accelerates at the DOCUMENTED rate and not some other one."""
    var sln = xl_sln(_a3(3000.0, 0.0, 3.0))
    var mid = xl_syd(_a4(3000.0, 0.0, 3.0, 2.0))
    assert_equal(sln.num, mid.num, "★ THE BLIND INPUT: the middle period")
    var first = xl_syd(_a4(3000.0, 0.0, 3.0, 1.0))
    var last = xl_syd(_a4(3000.0, 0.0, 3.0, 3.0))
    _close(first, 1500.0, "SYD first period")
    _close(last, 500.0, "SYD last period")
    _apart(sln, first, "★ THE SHARP INPUT: the first period")
    _close(FormulaValue.number(first.num / last.num), 3.0,
           "★ the 3:1 ratio pins the ACCELERATION")
    # The published examples.
    _close(xl_sln(_a3(30000.0, 7500.0, 10.0)), 2250.0, "published SLN")
    _close(xl_syd(_a4(30000.0, 7500.0, 10.0, 1.0)), 4090.909090909091,
           "published SYD")


def test_syd_refuses_a_period_past_the_life() raises:
    """⚠ `per > life` IS `#NUM!`, NOT 0: there is no such period, and the
    formula would happily return a NEGATIVE depreciation."""
    _err(xl_syd(_a4(3000.0, 0.0, 3.0, 4.0)), XL_ERR_NUM, "per > life")
    _err(xl_syd(_a4(3000.0, 0.0, 0.0, 1.0)), XL_ERR_NUM, "life <= 0")
    _err(xl_sln(_a3(3000.0, 0.0, 0.0)), XL_ERR_DIV0, "SLN life = 0")


def test_db_uses_the_THREE_DECIMAL_ROUNDED_rate_and_that_is_the_function() raises:
    """⛔⛔ THE DOCUMENTED WART, AND IT IS WHAT MAKES `DB` A DIFFERENT
    FUNCTION RATHER THAN A FLOATING-POINT VARIATION ON A CONTINUOUS DECLINING
    BALANCE. Microsoft defines the rate as
    `ROUND(1 - (salvage/cost)^(1/life), 3)`. On the published example the
    unrounded rate is 0.3187079309… and the rounded one is 0.319:

        rounded    186083.33333333334   <- Excel
        unrounded  185912.95971618922

    a 170.37 difference on 186083 — **0.09%**, which looks exactly like
    accumulated float error and is not. ★ BOTH numbers are written down here
    so the assertion cannot be satisfied by the wrong one."""
    var p1 = xl_db(_a5(1000000.0, 100000.0, 6.0, 1.0, 7.0))
    _close(p1, 186083.33333333334, "the published DB first period")
    var unrounded = 185912.95971618922
    var d = p1.num - unrounded
    if d < 0.0:
        d = -d
    assert_true(d > 100.0,
                "★ the UNROUNDED rate answers " + String(unrounded)
                + ", which this kernel must NOT produce")
    _close(xl_db(_a5(1000000.0, 100000.0, 6.0, 2.0, 7.0)),
           259639.41666666666,
           "★ period 2 — it needs period 1's total to be right")
    _close(xl_db(_a5(1000000.0, 100000.0, 6.0, 7.0, 7.0)),
           15845.098473848071,
           "★ period life+1 — the stub year, pro-rated by (12-month)/12")


def test_db_honours_the_MONTH_argument() raises:
    """⛔ `month` IS THE NUMBER OF MONTHS IN THE FIRST YEAR (default 12), so
    period 1 is pro-rated by `month/12`. A kernel that ignored it answers the
    FULL-YEAR number for period 1 and then disagrees with Excel for the whole
    rest of the schedule, because the running total is wrong from period 2
    onward.

    ⭐ ON THE MATCHED PAIR THE RATIO IS EXACTLY 6/12: `DB(1000, 107.3741824,
    10, 1)` is 200 and the same call with `month = 6` is **100**."""
    var full = xl_db(_a4(1000.0, 107.3741824, 10.0, 1.0))
    var half = xl_db(_a5(1000.0, 107.3741824, 10.0, 1.0, 6.0))
    _close(full, 200.0, "DB with the default month = 12")
    _close(half, 100.0, "DB with month = 6")
    _apart(full, half, "★ the month argument is READ")
    _err(xl_db(_a5(1000.0, 100.0, 6.0, 1.0, 0.0)), XL_ERR_NUM, "month = 0")
    _err(xl_db(_a5(1000.0, 100.0, 6.0, 1.0, 13.0)), XL_ERR_NUM, "month = 13")
    _err(xl_db(_a4(1000.0, 100.0, 6.0, 8.0)), XL_ERR_NUM, "period > life + 1")


def test_db_and_ddb_AGREE_on_a_matched_pair_and_the_MONTH_splits_them() raises:
    """⭐⭐ THE MIS-WIRING TWIN, AND THE INPUT WHERE IT IS INVISIBLE.
    `0.8^10` is exactly 0.1073741824, so for `(1000, 107.3741824, 10)` the
    rate `1 - (s/c)^(1/10)` is exactly `2/10` — `DB`'s rounded rate and
    `DDB`'s `factor/life` COINCIDE, and both answer **200** at period 1. A
    fixture built on a round salvage ratio cannot tell `DB` from `DDB` at all.

    The sharp input is the `month` argument, which `DDB` does not have."""
    var db = xl_db(_a4(1000.0, 107.3741824, 10.0, 1.0))
    var ddb = xl_ddb(_a4(1000.0, 107.3741824, 10.0, 1.0))
    assert_equal(db.num, ddb.num,
                 "★ THE BLIND INPUT: the two schedules COINCIDE here")
    var db6 = xl_db(_a5(1000.0, 107.3741824, 10.0, 1.0, 6.0))
    _apart(db6, ddb, "★ THE SHARP INPUT: DB pro-rates the first year")


def test_ddb_CLIPS_at_the_salvage_value_and_then_stops() raises:
    """⛔⛔ THE SALVAGE FLOOR IS A `MIN`, NOT A SUBTRACTION, AND IT ONLY BITES
    IN THE PERIODS A FIXTURE OMITS. The declining-balance curve never reaches
    the salvage value on its own, so Excel CLIPS the last productive period
    and every later one depreciates 0:

        period 10  clipped 22.122547200…   unclipped 64.4245094400…
        period 11  clipped 0               unclipped 51.5396075520…

    An unclipped kernel agrees with Excel for the first NINE periods."""
    _close(xl_ddb(_a4(2400.0, 300.0, 10.0, 1.0)), 480.0, "published DDB p1")
    var p10 = xl_ddb(_a4(2400.0, 300.0, 10.0, 10.0))
    _close(p10, 22.122547200000156, "★ the CLIPPED tenth period")
    var unclipped = 2400.0 * 0.8 * 0.8 * 0.8 * 0.8 * 0.8 * 0.8 * 0.8 * 0.8 \
        * 0.8 * 0.2
    var d = p10.num - unclipped
    if d < 0.0:
        d = -d
    assert_true(d > 1.0,
                "★ the UNCLIPPED curve answers " + String(unclipped))
    _close(xl_ddb(_a4(2400.0, 300.0, 10.0, 11.0)), 0.0,
           "★ past the clip there is nothing left to depreciate")


def test_ddb_factor_is_read_and_factor_one_is_NOT_straight_line() raises:
    """⚠ `factor` DEFAULTS TO **2**, NOT TO 1 OR 0. A kernel whose optional
    argument defaulted to zero answers 0 for every period — which looks like a
    fully-depreciated asset rather than like a bug. And `factor = 1` is a
    declining balance at `1/life`, NOT the straight line `SLN` gives: 240
    against 210."""
    _close(xl_ddb(_a4(2400.0, 300.0, 10.0, 1.0)), 480.0, "default factor is 2")
    var f1 = xl_ddb(_a5(2400.0, 300.0, 10.0, 1.0, 1.0))
    _close(f1, 240.0, "factor = 1 is a 1/life declining balance")
    var sl = xl_sln(_a3(2400.0, 300.0, 10.0))
    _close(sl, 210.0, "SLN over the same asset")
    _apart(f1, sl, "★ factor = 1 is NOT the straight line")
    _err(xl_ddb(_a5(2400.0, 300.0, 10.0, 1.0, 0.0)), XL_ERR_NUM, "factor = 0")
    _err(xl_ddb(_a4(2400.0, 300.0, 0.0, 1.0)), XL_ERR_NUM, "life = 0")


# =============================================================================
# ★ THE ERROR ALGEBRA — every kernel is `ERRH_PROPAGATE_DOMINANT`.
# =============================================================================
def test_every_financial_kernel_propagates_the_LEFTMOST_error() raises:
    """⚠ THE WHOLE FAMILY IS `ERRH_PROPAGATE_DOMINANT`: an error argument is
    returned as ITSELF and the kernel never runs. Asserted over all 21 names
    rather than a sample, because a kernel that read its arguments in a
    different order would return the WRONG error — and an error is still an
    error, so a one-error fixture cannot see it.

    ★ THE ARGUMENT LIST CARRIES TWO DIFFERENT ERRORS, so `#DIV/0!` coming
    back means the LEFTMOST won and `#N/A` would mean the kernel picked."""
    var a = List[FormulaValue]()
    a.append(FormulaValue.error(XL_ERR_DIV0))
    a.append(FormulaValue.error(XL_ERR_VALUE))
    a.append(FormulaValue.error(XL_ERR_VALUE))
    a.append(FormulaValue.error(XL_ERR_VALUE))
    a.append(FormulaValue.error(XL_ERR_VALUE))
    a.append(FormulaValue.error(XL_ERR_VALUE))
    _err(xl_fv(a), XL_ERR_DIV0, "FV")
    _err(xl_pv(a), XL_ERR_DIV0, "PV")
    _err(xl_pmt(a), XL_ERR_DIV0, "PMT")
    _err(xl_nper(a), XL_ERR_DIV0, "NPER")
    _err(xl_rate(a), XL_ERR_DIV0, "RATE")
    _err(xl_ipmt(a), XL_ERR_DIV0, "IPMT")
    _err(xl_ppmt(a), XL_ERR_DIV0, "PPMT")
    _err(xl_cumipmt(a), XL_ERR_DIV0, "CUMIPMT")
    _err(xl_cumprinc(a), XL_ERR_DIV0, "CUMPRINC")
    _err(xl_ispmt(a), XL_ERR_DIV0, "ISPMT")
    _err(xl_npv(a), XL_ERR_DIV0, "NPV")
    _err(xl_effect(a), XL_ERR_DIV0, "EFFECT")
    _err(xl_nominal(a), XL_ERR_DIV0, "NOMINAL")
    _err(xl_rri(a), XL_ERR_DIV0, "RRI")
    _err(xl_pduration(a), XL_ERR_DIV0, "PDURATION")
    _err(xl_dollarde(a), XL_ERR_DIV0, "DOLLARDE")
    _err(xl_dollarfr(a), XL_ERR_DIV0, "DOLLARFR")
    _err(xl_sln(a), XL_ERR_DIV0, "SLN")
    _err(xl_syd(a), XL_ERR_DIV0, "SYD")
    _err(xl_db(a), XL_ERR_DIV0, "DB")
    _err(xl_ddb(a), XL_ERR_DIV0, "DDB")


def test_an_error_in_a_LATER_argument_still_stops_the_call() raises:
    """⛔ THE FIRST-ARGUMENT-ONLY TRAP. A kernel that checked `args[0]` and
    then computed would pass every cell above, because every cell above puts
    the error FIRST. `NPV` is the sharpest case: its error can be in any of
    255 variadic positions."""
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(0.1))
    a.append(FormulaValue.number(100.0))
    a.append(FormulaValue.error(XL_ERR_VALUE))
    _err(xl_npv(a), XL_ERR_VALUE, "NPV with the error in value2")
    var b = List[FormulaValue]()
    b.append(FormulaValue.number(0.1))
    b.append(FormulaValue.number(10.0))
    b.append(FormulaValue.error(XL_ERR_NUM))
    _err(xl_pmt(b), XL_ERR_NUM, "PMT with the error in pv")
    var c = List[FormulaValue]()
    c.append(FormulaValue.number(0.1))
    c.append(FormulaValue.number(1.0))
    c.append(FormulaValue.number(10.0))
    c.append(FormulaValue.number(1000.0))
    c.append(FormulaValue.number(0.0))
    c.append(FormulaValue.error(XL_ERR_NA))
    _err(xl_ipmt(c), XL_ERR_NA, "IPMT with the error in `type`")


def test_a_TEXT_argument_that_is_not_a_number_is_VALUE() raises:
    """⚠ COERCION, NOT REFUSAL, IS THE DEFAULT: `"1000"` is a number to Excel
    and `"ten"` is `#VALUE!`. A kernel that refused all text would break the
    first; one that coerced blindly would make the second a 0 and answer a
    plausible payment."""
    var ok = List[FormulaValue]()
    ok.append(FormulaValue.number(0.1))
    ok.append(FormulaValue.number(10.0))
    ok.append(FormulaValue.text_val(String("1000")))
    _close(xl_pmt(ok), -162.74539488251153, "★ numeric TEXT coerces")
    var bad = List[FormulaValue]()
    bad.append(FormulaValue.number(0.1))
    bad.append(FormulaValue.number(10.0))
    bad.append(FormulaValue.text_val(String("ten")))
    _err(xl_pmt(bad), XL_ERR_VALUE, "★ non-numeric TEXT is #VALUE!")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

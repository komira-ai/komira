# =============================================================================
# xl_scalar_financial.mojo — ★ THE ANNUITY ALGEBRA, THE RATE SOLVER, AND THE
#                              DEPRECIATION SCHEDULES.
# =============================================================================
#
# ============ ⛔⛔ MONEY IS THE ONE DOMAIN WHERE A PLAUSIBLE ANSWER IS THE
#                  DANGEROUS OUTCOME
#
# Every other kernel family in this tree can be wrong in a way a reader
# notices. A financial function cannot: `PMT` off by the payment-timing
# convention answers a number of exactly the right magnitude and sign, and
# `DB` implemented without its documented THREE-DECIMAL rate rounding is
# within 0.2% of the right answer for the whole schedule. So the selection
# rule for this file is NOT "the functions people ask for" — it is **the
# functions whose answer can be graded EXACTLY against a published rule**,
# and everything else is a stated refusal in `xl_absent_common_names()` with
# the missing primitive named.
#
# ⇒ WHAT IS HERE (21 names) and WHY IT IS ONE GROUP: every one of them is a
#   closed form over its arguments, or — for `RATE` alone — an iteration whose
#   seed, iteration cap, tolerance and `#NUM!` condition are all PUBLISHED and
#   therefore gradable.
#
#   annuity algebra   PV FV PMT NPER RATE IPMT PPMT CUMIPMT CUMPRINC ISPMT NPV
#   rate conversion   EFFECT NOMINAL RRI PDURATION
#   price notation    DOLLARDE DOLLARFR
#   depreciation      SLN SYD DB DDB
#
# ⇒ WHAT IS DELIBERATELY NOT (34 names), and each class names its MISSING
#   PRIMITIVE rather than being skipped:
#
#   * the DAY-COUNT BASIS family (DISC INTRATE RECEIVED PRICEDISC YIELDDISC
#     PRICEMAT YIELDMAT ACCRINT ACCRINTM DURATION MDURATION PRICE YIELD
#     TBILL* COUP* ODD*) needs `yearfrac(d1, d2, basis)` over FIVE bases, and
#     basis 0 (US 30/360) and basis 1 (actual/actual) each carry end-of-month
#     and leap-spanning rules that a half-built version gets subtly wrong for
#     the DEFAULT basis. One wrong `yearfrac` would infect every one of them
#     at once.
#   * the ARRAY-ARGUMENT family (IRR MIRR XIRR XNPV FVSCHEDULE) cannot be
#     SPELLED through the door that serves this file: `formula_parser` has no
#     `{...}` array literal and `komira_xl_bind` binds only
#     `<table>[.<column>]`, so `IRR({-100,50,60})` is a PARSE ERROR and
#     `IRR(A1:A3)` has no range to name. ⚠ `NPV` is here and they are not
#     BECAUSE NPV IS VARIADIC IN EXCEL (`NPV(rate, v1, v2, ...)`) — it is the
#     one member of the family whose published signature takes loose scalars.
#   * VDB needs the straight-line SWITCH-OVER schedule with FRACTIONAL start
#     and end periods. Excel's own implementation carries a partial-period
#     correction (the `life1 += 1` half-life adjustment) that no published
#     formula states in closed form, and a plausible sum-of-DDB answers a
#     number for every input it is given.
#   * AMORDEGRC / AMORLINC need the French fiscal-depreciation coefficient
#     table AND `AMORDEGRC`'s documented rounding wart.
#
# ============ ⚠⚠ THE ONE RELATION EVERY ANNUITY NAME IS A REARRANGEMENT OF
#
# Excel publishes exactly one equation and solves it for a different unknown
# under each of six names:
#
#     pv*(1+rate)^nper
#       + pmt*(1 + rate*type)*((1+rate)^nper - 1)/rate
#       + fv  =  0                                      (rate != 0)
#     pmt*nper + pv + fv = 0                            (rate == 0)
#
# `_annuity_raw` below is that left-hand side minus `fv`, and PV / FV / PMT /
# NPER / RATE / IPMT / PPMT are all written in terms of it. ⛔ THE rate == 0
# ARM IS NOT AN OPTIMISATION — it is the LIMIT, and the general arm divides by
# `rate`. A kernel without it answers `#DIV/0!` (or NaN) for every
# interest-free loan, which is a perfectly ordinary spreadsheet.
#
# ============ ⚠ THE SIGN CONVENTION IS EXCEL'S AND IT IS NOT A CHOICE
#
# Money you PAY is negative; money you RECEIVE is positive. `PMT(0.1,10,1000)`
# is **-162.745** and not +162.745, and a kernel that returned the magnitude
# would agree with every mental arithmetic check a reviewer makes and disagree
# with Excel on every cell. The oracle grades the SIGN.
#
# Encapsulation rule : values only. No `UnsafePointer`, no wildcard
# origins, no `unsafe_from_address`.
# =============================================================================

from std.ffi import external_call
from std.math import floor, ceil

from komira_core.plan.excel_error_code import (
    XL_ERR_DIV0,
    XL_ERR_NUM,
    XL_ERR_VALUE,
)

from .formula_value import FormulaValue


# `2**53` — past it an "integer" period index is already a rounded one.
comptime _INT_EXACT_MAX: Float64 = 9007199254740992.0

# ⛔ EXCEL'S OWN PUBLISHED CONVERGENCE CONTRACT FOR `RATE`, AND BOTH HALVES OF
# IT ARE GRADED. Microsoft: *"If the successive results of RATE do not
# converge to within 0.0000001 after 20 iterations, RATE returns the #NUM!
# error value."* Neither number is a tuning knob — they are the specification,
# so a kernel that iterated to machine precision would ANSWER where Excel
# refuses, and one that iterated 200 times would answer a DIFFERENT root.
comptime _RATE_TOL: Float64 = 0.0000001
comptime _RATE_MAX_ITER: Int = 20


def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` as a NUMBER, or the error that stops the call. Same
    contract as `xl_scalar_math._num` / `xl_scalar_exact._num`, re-spelled for
    the same reason those two are: a cross-module import of a private helper
    is the edge that makes a "kernels only" module stop being one.
    ⚠ IF THE DOMINANCE RULE EVER CHANGES, ALL FOUR CHANGE."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def _opt(imm args: List[FormulaValue], i: Int, dflt: Float64) -> FormulaValue:
    """An OPTIONAL numeric argument, defaulting to `dflt` when absent.

    ⚠ ABSENT AND ZERO MUST STAY DISTINGUISHABLE AT THE CALL SITE. Every
    default in this file is the value Excel documents (`fv` = 0, `type` = 0,
    `factor` = 2, `month` = 12, `guess` = 0.1), and three of those are NOT
    zero — so a helper that treated a missing argument as 0.0 would silently
    turn `DDB(...)` into a straight-line-ish schedule and `DB(...)` into a
    zero-month first year."""
    if len(args) <= i:
        return FormulaValue.number(dflt)
    return _num(args, i)


def _pw(b: Float64, e: Float64) -> Float64:
    """libm `pow`. ⛔ NOT MOJO'S `**`, which is an approximate exp2/log2 kernel
    — measured 2026-09-09, `3.5 ** 0.75` is wrong by ~196,000 ulps. The
    canonical statement is `xl_scalar_math.xl_power`'s docstring; every
    compounding factor in this file goes through here so a schedule's terms
    cannot disagree with each other about which power function they used."""
    return external_call["pow", Float64](b, e)


def _ln(x: Float64) -> Float64:
    """libm `log`. NPER and PDURATION are the two names that need it, and both
    guard their domain BEFORE the call so libm's `-inf`/NaN is unreachable."""
    return external_call["log", Float64](x)


def _is_nan(x: Float64) -> Bool:
    """⚠ THE ONE GUARD THAT CANNOT BE WRITTEN AS A DOMAIN CHECK. A negative
    base with a fractional exponent — `(1+rate)` below -1 with a fractional
    `nper` — has a COMPLEX answer, and libm returns NaN. NaN travels silently
    through every comparison (it is not `<`, not `>`, not `==` anything), so a
    kernel that let it out would put a number-shaped non-number into a sum."""
    return x != x


def _trunc0(x: Float64) -> Float64:
    """The integer part, TOWARD ZERO. ⚠ NOT `floor` — Excel truncates the
    period/count arguments of this family, so `IPMT(r, 1.9, ...)` is period 1
    and a flooring kernel agrees on every POSITIVE input and diverges on the
    negative ones the error arms are about."""
    return floor(x) if x >= 0.0 else ceil(x)


def _round3(x: Float64) -> Float64:
    """`ROUND(x, 3)` — HALF AWAY FROM ZERO, the rule `xl_scalar_math.xl_round`
    states. ⛔ IT EXISTS FOR EXACTLY ONE CALLER AND IT IS NOT A CONVENIENCE:
    `DB`'s depreciation rate is DEFINED as the three-decimal rounding of
    `1 - (salvage/cost)^(1/life)`, and that deliberate wart is the whole
    difference between `DB` and `DDB` on a matched pair of inputs."""
    var s = x * 1000.0
    var r = floor(s + 0.5) if s >= 0.0 else ceil(s - 0.5)
    return r / 1000.0


def _digits10(n: Float64) -> Float64:
    """`10 ** ceil(log10(n))` for an integer `n >= 1` — the width of the
    numerator field in a fractional price.

    ⛔ COMPUTED BY AN INTEGER LOOP AND NOT BY `pow(10, ceil(log10(n)))`.
    `log10` of an exact power of ten can land a hair below it, so
    `ceil(log10(1000))` is 3 on one libm and 4 on another, and the DOLLARDE
    pair would then divide by the wrong power of ten for exactly the
    denominators (10, 100, 1000) a price is most likely to use."""
    var t = Float64(1.0)
    while t < n:
        t = t * 10.0
    return t


# =============================================================================
# ★★ THE ONE RELATION. Everything in the annuity block is a rearrangement.
# =============================================================================
def _annuity_raw(rate: Float64, nper: Float64, pmt: Float64, pv: Float64,
                 typ: Float64) -> Float64:
    """`pv*(1+r)^n + pmt*(1+r*t)*((1+r)^n - 1)/r`, i.e. Excel's annuity
    equation with `fv` moved to the other side.

    ⚠ EXCEL'S `FV` IS THE **NEGATION** OF THIS, and every other name in the
    block is written against this un-negated form so the sign flip happens in
    exactly one place. `xl_fv` is `-_annuity_raw(...)`.

    ⛔ THE `rate == 0` ARM IS THE LIMIT, NOT A SHORTCUT. `(( 1+r)^n - 1)/r` is
    `0/0` at r = 0 and its limit is `n`; without this arm an interest-free
    loan — an entirely ordinary spreadsheet — is a division by zero."""
    if rate == 0.0:
        return pv + pmt * nper
    var g = _pw(1.0 + rate, nper)
    return pv * g + pmt * (1.0 + rate * typ) * (g - 1.0) / rate


def _fv_excel(rate: Float64, nper: Float64, pmt: Float64, pv: Float64,
              typ: Float64) -> Float64:
    """Excel's `FV` as a Float64 — the negated relation. IPMT reads the
    remaining balance through this, which is what keeps the two functions
    from drifting apart."""
    return -_annuity_raw(rate, nper, pmt, pv, typ)


def _pmt_excel(rate: Float64, nper: Float64, pv: Float64, fv: Float64,
               typ: Float64) -> Float64:
    """Excel's `PMT` as a Float64. ⚠ THE CALLER MUST HAVE ALREADY REFUSED
    `nper == 0`; this helper divides by it."""
    if rate == 0.0:
        return -(fv + pv) / nper
    var g = _pw(1.0 + rate, nper)
    var den = (1.0 + rate * typ) * (g - 1.0) / rate
    return -(fv + pv * g) / den


# =============================================================================
# ★ PV / FV / PMT / NPER — the four closed-form rearrangements.
# =============================================================================
def xl_fv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FV(rate, nper, pmt, [pv], [type])` — the future value of an annuity.

    ⚠ `type` SELECTS WHEN THE PAYMENT LANDS: 0 (the default) is END of period,
    1 is BEGINNING, and the difference is exactly one period of interest on
    every payment — `FV(0.1,2,-100,0,1)` is 231 where `FV(0.1,2,-100)` is 210.
    A kernel that ignored `type` answers 210 for both, which is a correct
    number for the wrong contract.

    ⭐ THE BLIND INPUT IS `rate = 0`, where FV and PV COINCIDE at 200 for
    `(0, 2, -100)` because there is no discounting to tell them apart. The
    oracle carries that cell as the pair's `#pair` blind."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var nper = _num(args, 1)
    if nper.is_error():
        return nper^
    var pmt = _num(args, 2)
    if pmt.is_error():
        return pmt^
    var pv = _opt(args, 3, 0.0)
    if pv.is_error():
        return pv^
    var typ = _opt(args, 4, 0.0)
    if typ.is_error():
        return typ^
    var r = _fv_excel(rate.num, nper.num, pmt.num, pv.num, typ.num)
    if _is_nan(r):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(r)


def xl_pv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PV(rate, nper, pmt, [fv], [type])` — the present value of an annuity.

    ⛔ IT IS **NOT** `FV` WITH THE SIGN FLIPPED, and at `rate = 0` it is —
    which is why that input is the pair's blind cell. `PV(0.1,2,-100)` is
    173.554 and `FV(0.1,2,-100)` is 210: the same cash flows discounted to t=0
    rather than compounded to t=n.

    ⚠ `PV(0.1, 1, -100)` IS EXACTLY `NPV(0.1, 100)` = 90.909…, and that is not
    a coincidence: a one-period annuity IS a one-element series. The two names
    diverge the moment the series stops being level, which is the input the
    oracle uses."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var nper = _num(args, 1)
    if nper.is_error():
        return nper^
    var pmt = _num(args, 2)
    if pmt.is_error():
        return pmt^
    var fv = _opt(args, 3, 0.0)
    if fv.is_error():
        return fv^
    var typ = _opt(args, 4, 0.0)
    if typ.is_error():
        return typ^
    if rate.num == 0.0:
        return FormulaValue.number(-(fv.num + pmt.num * nper.num))
    var g = _pw(1.0 + rate.num, nper.num)
    if _is_nan(g) or g == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var series = pmt.num * (1.0 + rate.num * typ.num) * (g - 1.0) / rate.num
    return FormulaValue.number(-(fv.num + series) / g)


def xl_pmt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PMT(rate, nper, pv, [fv], [type])` — the level payment.

    ⛔⛔ THE SIGN IS THE FINDING. `PMT(0.1, 10, 1000)` is **-162.745394883889**:
    you BORROWED 1000 (positive, received) and you PAY 162.75 a period
    (negative). A kernel returning the magnitude passes every mental check a
    reviewer makes and disagrees with Excel on every cell it ever computes.

    ⚠ `nper = 0` IS `#NUM!`, not a division by zero escaping as `inf`. There
    is no payment that amortises a balance over no periods.

    ⚠ THE `rate = 0` ARM IS `-(fv + pv)/nper` — ten equal payments of a
    tenth. Without it `PMT(0, 10, 1000)` is `0/0`."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var nper = _num(args, 1)
    if nper.is_error():
        return nper^
    var pv = _num(args, 2)
    if pv.is_error():
        return pv^
    var fv = _opt(args, 3, 0.0)
    if fv.is_error():
        return fv^
    var typ = _opt(args, 4, 0.0)
    if typ.is_error():
        return typ^
    if nper.num == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    if rate.num != 0.0:
        var g = _pw(1.0 + rate.num, nper.num)
        if _is_nan(g) or g == 1.0:
            return FormulaValue.error(XL_ERR_NUM)
    var p = _pmt_excel(rate.num, nper.num, pv.num, fv.num, typ.num)
    if _is_nan(p):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(p)


def xl_nper(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NPER(rate, pmt, pv, [fv], [type])` — how many periods it takes.

    ⚠ THE ARGUMENT ORDER IS `(rate, pmt, pv)` AND EVERY OTHER MEMBER OF THIS
    BLOCK IS `(rate, nper, …)`. NPER is the one name whose second argument is
    the PAYMENT, because `nper` is what it solves for. Swapping `pmt` and `pv`
    answers a plausible number of periods for almost any input.

    ⛔ `log(num/den)` IS `#NUM!` WHEN THE RATIO IS NOT POSITIVE, and that is
    not a defensive check: it is the case where the payments never retire the
    balance, so there IS no number of periods. libm would hand back `nan`."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var pmt = _num(args, 1)
    if pmt.is_error():
        return pmt^
    var pv = _num(args, 2)
    if pv.is_error():
        return pv^
    var fv = _opt(args, 3, 0.0)
    if fv.is_error():
        return fv^
    var typ = _opt(args, 4, 0.0)
    if typ.is_error():
        return typ^
    if rate.num == 0.0:
        if pmt.num == 0.0:
            return FormulaValue.error(XL_ERR_NUM)
        return FormulaValue.number(-(pv.num + fv.num) / pmt.num)
    if 1.0 + rate.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var k = pmt.num * (1.0 + rate.num * typ.num)
    var num = k - fv.num * rate.num
    var den = pv.num * rate.num + k
    if den == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var q = num / den
    if q <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(_ln(q) / _ln(1.0 + rate.num))


# =============================================================================
# ★★ RATE — the ONE iterative name here, and its contract is PUBLISHED.
# =============================================================================
def _annuity_f(rate: Float64, nper: Float64, pmt: Float64, pv: Float64,
               fv: Float64, typ: Float64) -> Float64:
    """The annuity residual whose root `RATE` is."""
    return _annuity_raw(rate, nper, pmt, pv, typ) + fv


def _annuity_df(rate: Float64, nper: Float64, pmt: Float64, pv: Float64,
                typ: Float64) -> Float64:
    """`d/drate` of the residual, ANALYTIC.

    ⚠ THE `rate == 0` ARM IS AGAIN THE LIMIT. `((1+r)^n - 1)/r -> n` and its
    derivative tends to `n*(n-1)/2`, so the derivative at zero is
    `pv*n + pmt*(n*(n-1)/2 + n*type)`. A Newton step that hit r = 0 with the
    general arm would divide by zero and hand back NaN, which the caller
    cannot distinguish from a diverging iteration."""
    if rate == 0.0:
        return pv * nper + pmt * (nper * (nper - 1.0) / 2.0 + nper * typ)
    var g = _pw(1.0 + rate, nper)
    var dg = nper * _pw(1.0 + rate, nper - 1.0)
    var s = (g - 1.0) / rate
    var ds = (dg * rate - (g - 1.0)) / (rate * rate)
    return pv * dg + pmt * (typ * s + (1.0 + rate * typ) * ds)


def xl_rate(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`RATE(nper, pmt, pv, [fv], [type], [guess])` — Newton on the annuity
    residual, seeded at `guess` (default **0.1**).

    ⛔⛔ THE ITERATION IS PART OF THE CONTRACT, NOT AN IMPLEMENTATION DETAIL.
    Microsoft publishes all four halves and this kernel grades against all
    four: seed `guess` defaulting to 0.1, **20** iterations, convergence
    **0.0000001** on successive results, and `#NUM!` when it does not
    converge. A kernel that iterated to machine precision would ANSWER where
    Excel refuses; one that iterated 200 times would answer a DIFFERENT root.

    ⭐⭐ AND THE ROOT IS NOT UNIQUE, WHICH IS WHY THE GUESS IS AN ARGUMENT.
    Microsoft: *"RATE is calculated by iteration and can have zero or more
    solutions."* `RATE(2, -2.8, 1, 4.72)` has the residual `r^2 - 0.8r + 0.12`,
    whose roots are **0.2 and 0.6** — BOTH exact solutions of Excel's own
    annuity equation. The default guess 0.1 converges to 0.2; `guess = 0.5`
    converges to 0.6. The oracle carries BOTH cells, and a solver that ignored
    the guess (a bisection over a fixed bracket, say) would answer the same
    number twice and pass any single-cell test.

    ⚠ `1 + rate <= 0` STOPS THE ITERATION with `#NUM!` rather than being
    clamped back into range. A Newton step can overshoot below -100% interest,
    where `(1+r)^n` for a fractional `n` is complex; clamping would silently
    restart the search somewhere the caller did not ask about."""
    var nper = _num(args, 0)
    if nper.is_error():
        return nper^
    var pmt = _num(args, 1)
    if pmt.is_error():
        return pmt^
    var pv = _num(args, 2)
    if pv.is_error():
        return pv^
    var fv = _opt(args, 3, 0.0)
    if fv.is_error():
        return fv^
    var typ = _opt(args, 4, 0.0)
    if typ.is_error():
        return typ^
    var guess = _opt(args, 5, 0.1)
    if guess.is_error():
        return guess^
    if nper.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var r = guess.num
    for _ in range(_RATE_MAX_ITER):
        if 1.0 + r <= 0.0:
            return FormulaValue.error(XL_ERR_NUM)
        var f = _annuity_f(r, nper.num, pmt.num, pv.num, fv.num, typ.num)
        if _is_nan(f):
            return FormulaValue.error(XL_ERR_NUM)
        var d = _annuity_df(r, nper.num, pmt.num, pv.num, typ.num)
        if d == 0.0 or _is_nan(d):
            return FormulaValue.error(XL_ERR_NUM)
        var nxt = r - f / d
        var step = nxt - r
        if step < 0.0:
            step = -step
        r = nxt
        if step < _RATE_TOL:
            if 1.0 + r <= 0.0:
                return FormulaValue.error(XL_ERR_NUM)
            return FormulaValue.number(r)
    return FormulaValue.error(XL_ERR_NUM)


# =============================================================================
# ★ IPMT / PPMT — the split of one payment, and they MUST sum to PMT.
# =============================================================================
def _period_arg(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """A period index, TRUNCATED to an exactly-representable integer."""
    var v = _num(args, i)
    if v.is_error():
        return v^
    var t = _trunc0(v.num)
    if t > _INT_EXACT_MAX or t < -_INT_EXACT_MAX:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(t)


def _ipmt_raw(rate: Float64, per: Float64, nper: Float64, pv: Float64,
              fv: Float64, typ: Float64) -> Float64:
    """The interest portion of payment `per`, as a Float64.

    ★ DERIVED FROM THE BALANCE, NOT FROM A SEPARATE FORMULA: the interest
    charged in a period is `rate` times the balance OUTSTANDING at the start
    of it, and that balance is `FV` over the periods already elapsed. So this
    is three lines and cannot drift away from `xl_fv`.

    ⚠ THE `type = 1` ARM IS NOT AN OFF-BY-ONE OF THE `type = 0` ARM. With
    payments at the START of a period, the FIRST payment is made before any
    interest has accrued, so `IPMT(per = 1)` is **exactly 0** — and for later
    periods the interest being paid is the interest that accrued during the
    PREVIOUS period, hence `per - 2` and the `- pmt` correction that un-does
    the payment made at the start of the period being measured."""
    var pmt = _pmt_excel(rate, nper, pv, fv, typ)
    var ip: Float64
    if per == 1.0:
        ip = 0.0 if typ == 1.0 else -pv
    elif typ == 1.0:
        ip = _fv_excel(rate, per - 2.0, pmt, pv, 1.0) - pmt
    else:
        ip = _fv_excel(rate, per - 1.0, pmt, pv, 0.0)
    return ip * rate


def xl_ipmt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`IPMT(rate, per, nper, pv, [fv], [type])` — the INTEREST half.

    ⭐ `IPMT(0.1, 1, 10, 1000)` is **-100**: the first period's interest on a
    1000 balance at 10% and nothing else. That is the cell a wrong kernel is
    most likely to pass, because -100 also falls out of several wrong
    formulas; `IPMT(0.1, 2, 10, 1000)` = **-93.7254605116** is the one that
    needs the balance to have been rolled forward correctly.

    ⛔ THE INVARIANT IS `IPMT + PPMT == PMT`, EXACTLY, for every period — and
    `test_xl_financial_kernels` asserts it across a whole schedule rather than
    at one period, because a pair of kernels that each drift by the same
    amount would satisfy it at a single point."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var per = _period_arg(args, 1)
    if per.is_error():
        return per^
    var nper = _num(args, 2)
    if nper.is_error():
        return nper^
    var pv = _num(args, 3)
    if pv.is_error():
        return pv^
    var fv = _opt(args, 4, 0.0)
    if fv.is_error():
        return fv^
    var typ = _opt(args, 5, 0.0)
    if typ.is_error():
        return typ^
    if nper.num == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    if per.num < 1.0 or per.num > nper.num:
        return FormulaValue.error(XL_ERR_NUM)
    var v = _ipmt_raw(rate.num, per.num, nper.num, pv.num, fv.num, typ.num)
    if _is_nan(v):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(v)


def xl_ppmt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PPMT(rate, per, nper, pv, [fv], [type])` — the PRINCIPAL half.

    ⛔⛔ THE MIS-WIRING TWIN IS `IPMT`, AND IT IS THE MOST DANGEROUS PAIR IN
    THIS FILE: both return a negative number of the same order of magnitude,
    both vary smoothly with the period, and a schedule built from the wrong
    one still sums to the right total over the full term. They are separated
    at period 1 of a 10-period 10% loan on 1000, where IPMT is **-100** and
    PPMT is **-62.745394883889** — and the oracle carries both.

    ⚠ IT IS DEFINED AS `PMT - IPMT` AND NOT RE-DERIVED. Two independent
    derivations of the same split is how the two halves stop adding up."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var per = _period_arg(args, 1)
    if per.is_error():
        return per^
    var nper = _num(args, 2)
    if nper.is_error():
        return nper^
    var pv = _num(args, 3)
    if pv.is_error():
        return pv^
    var fv = _opt(args, 4, 0.0)
    if fv.is_error():
        return fv^
    var typ = _opt(args, 5, 0.0)
    if typ.is_error():
        return typ^
    if nper.num == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    if per.num < 1.0 or per.num > nper.num:
        return FormulaValue.error(XL_ERR_NUM)
    var pmt = _pmt_excel(rate.num, nper.num, pv.num, fv.num, typ.num)
    var ip = _ipmt_raw(rate.num, per.num, nper.num, pv.num, fv.num, typ.num)
    var v = pmt - ip
    if _is_nan(v):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(v)


# =============================================================================
# ★ CUMIPMT / CUMPRINC — the two cumulative forms, and their FIVE refusals.
# =============================================================================
def _cum_guard(rate: Float64, nper: Float64, pv: Float64, start: Float64,
               end: Float64, typ: Float64) -> Bool:
    """Excel's documented refusal set for the two cumulative names, all five
    of them `#NUM!`.

    ⚠ `type` OUTSIDE {0, 1} IS `#NUM!` HERE AND NOT `#VALUE!`, which is the
    opposite of what a "bad argument" instinct produces — Microsoft states
    `#NUM!` explicitly for these two names. The whole point of a cumulative
    function is a range of periods, so a silently-clamped `type` would produce
    a wrong TOTAL rather than a wrong single payment."""
    if rate <= 0.0 or nper <= 0.0 or pv <= 0.0:
        return False
    if start < 1.0 or end < 1.0 or start > end:
        return False
    if typ != 0.0 and typ != 1.0:
        return False
    return True


def xl_cumipmt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CUMIPMT(rate, nper, pv, start_period, end_period, type)` — the
    interest paid between two periods INCLUSIVE.

    ⚠ ALL SIX ARGUMENTS ARE REQUIRED. `type` has no default here where it has
    one on `PMT`/`IPMT`, and a 5-argument call is an arity refusal rather than
    an assumed 0.

    ⭐ `CUMIPMT(0.09/12, 360, 125000, 1, 1, 0)` is **-937.50** — the same
    number as `IPMT` at period 1, which is the control that says the sum is a
    sum of the right thing. `(…, 13, 24, 0)` is **-11135.23**, the second
    year, which no single-period kernel can produce."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var nper = _num(args, 1)
    if nper.is_error():
        return nper^
    var pv = _num(args, 2)
    if pv.is_error():
        return pv^
    var start = _period_arg(args, 3)
    if start.is_error():
        return start^
    var end = _period_arg(args, 4)
    if end.is_error():
        return end^
    var typ = _num(args, 5)
    if typ.is_error():
        return typ^
    if not _cum_guard(rate.num, nper.num, pv.num, start.num, end.num, typ.num):
        return FormulaValue.error(XL_ERR_NUM)
    var acc: Float64 = 0.0
    var p = start.num
    while p <= end.num:
        acc = acc + _ipmt_raw(rate.num, p, nper.num, pv.num, 0.0, typ.num)
        p = p + 1.0
    if _is_nan(acc):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(acc)


def xl_cumprinc(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CUMPRINC(rate, nper, pv, start_period, end_period, type)` — the
    PRINCIPAL repaid between two periods inclusive.

    ⛔ THE TWIN IS `CUMIPMT` AND OVER A FULL TERM THEY ARE BOTH LARGE AND
    NEGATIVE. They are separated early: over the second year of a 30-year 9%
    mortgage on 125000, CUMIPMT is **-11135.23** and CUMPRINC is **-934.107**
    — an order of magnitude apart, because early payments are almost all
    interest. Over the LAST year the ordering reverses, which is why a fixture
    confined to one end of the schedule proves nothing."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var nper = _num(args, 1)
    if nper.is_error():
        return nper^
    var pv = _num(args, 2)
    if pv.is_error():
        return pv^
    var start = _period_arg(args, 3)
    if start.is_error():
        return start^
    var end = _period_arg(args, 4)
    if end.is_error():
        return end^
    var typ = _num(args, 5)
    if typ.is_error():
        return typ^
    if not _cum_guard(rate.num, nper.num, pv.num, start.num, end.num, typ.num):
        return FormulaValue.error(XL_ERR_NUM)
    var pmt = _pmt_excel(rate.num, nper.num, pv.num, 0.0, typ.num)
    var acc: Float64 = 0.0
    var p = start.num
    while p <= end.num:
        acc = acc + (pmt
                     - _ipmt_raw(rate.num, p, nper.num, pv.num, 0.0, typ.num))
        p = p + 1.0
    if _is_nan(acc):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(acc)


def xl_ispmt(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ISPMT(rate, per, nper, pv)` — the interest of a STRAIGHT-LINE
    principal repayment.

    ⛔⛔ THIS IS NOT `IPMT` AND THE NAMES ARE ONE LETTER APART. `IPMT` splits a
    LEVEL payment; `ISPMT` assumes the principal is repaid in equal slices, so
    its interest falls LINEARLY: `pv * rate * (per/nper - 1)`. On
    `(0.1/12, 1, 36, 8000000)` ISPMT is **-64814.8148…** where IPMT is
    **-66666.667**. Both are negative six-figure numbers; only one is right.

    ⚠ `nper = 0` IS `#DIV/0!` AND NOT `#NUM!` — the formula divides by it
    directly, and this kernel reports the division that actually failed."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var per = _num(args, 1)
    if per.is_error():
        return per^
    var nper = _num(args, 2)
    if nper.is_error():
        return nper^
    var pv = _num(args, 3)
    if pv.is_error():
        return pv^
    if nper.num == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    return FormulaValue.number(pv.num * rate.num * (per.num / nper.num - 1.0))


def xl_npv(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NPV(rate, value1, [value2], …)` — the net present value of a series.

    ⛔⛔ THE FIRST VALUE IS DISCOUNTED **ONE** PERIOD, NOT ZERO. This is the
    single most-reported Excel gotcha in the whole Financial category:
    `NPV(0.1, 100)` is **90.9090909…**, not 100. Excel's NPV assumes every
    cash flow arrives at the END of its period, so an investment made TODAY
    has to be added outside the call (`NPV(r, …) + C0`). A kernel that started
    the exponent at 0 answers 100 here — a round number that looks like a
    correct answer to a test written by the same person.

    ⚠ IT IS VARIADIC OVER LOOSE SCALARS, WHICH IS WHY IT IS IN THIS FILE AND
    `IRR` IS NOT. Excel's published signature for NPV takes `value1, value2,
    …`; IRR / MIRR / XIRR / XNPV / FVSCHEDULE take an ARRAY OR RANGE, and this
    door has neither an array literal nor a range binding.

    ⚠ `rate = -1` IS `#DIV/0!`: the first discount factor is exactly zero."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    if rate.num == -1.0:
        return FormulaValue.error(XL_ERR_DIV0)
    var acc: Float64 = 0.0
    var f = 1.0 + rate.num
    var disc = f
    for i in range(1, len(args)):
        var v = _num(args, i)
        if v.is_error():
            return v^
        acc = acc + v.num / disc
        disc = disc * f
    if _is_nan(acc):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(acc)


# =============================================================================
# ★ THE RATE CONVERSIONS — EFFECT / NOMINAL / RRI / PDURATION.
# =============================================================================
def _npery(imm v: FormulaValue) -> Float64:
    """`npery` TRUNCATED. ⚠ Excel truncates rather than rounding, so
    `EFFECT(0.0525, 4.9)` is the QUARTERLY answer and not the monthly-ish one
    a rounding kernel would compute."""
    return _trunc0(v.num)


def xl_effect(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`EFFECT(nominal_rate, npery)` — `(1 + nominal/npery)^npery - 1`.

    ⭐ THE BLIND INPUT IS `npery = 1`, where EFFECT and NOMINAL are BOTH the
    identity and a fixture confined to it cannot tell them apart at all. At
    `npery = 4` and 5% they are 0.05094533691406264 and 0.04908893771615065 —
    on OPPOSITE sides of the input, which is the discrimination.

    ⚠ `npery < 1` AND `nominal_rate <= 0` ARE BOTH `#NUM!`."""
    var nom = _num(args, 0)
    if nom.is_error():
        return nom^
    var np = _num(args, 1)
    if np.is_error():
        return np^
    var n = _npery(np)
    if nom.num <= 0.0 or n < 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(_pw(1.0 + nom.num / n, n) - 1.0)


def xl_nominal(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`NOMINAL(effect_rate, npery)` — `((1 + effect)^(1/npery) - 1) * npery`,
    the exact inverse of `EFFECT`.

    ⭐ THE ROUND TRIP IS THE ASSERTION NOBODY CAN FAKE:
    `NOMINAL(EFFECT(r, n), n) == r` for every `r` and `n`, the way
    `DECIMAL(BASE(x, b), b) == x` is for the radix pair. A kernel that
    confused the two directions passes at `npery = 1` and fails the round trip
    everywhere else."""
    var eff = _num(args, 0)
    if eff.is_error():
        return eff^
    var np = _num(args, 1)
    if np.is_error():
        return np^
    var n = _npery(np)
    if eff.num <= 0.0 or n < 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number((_pw(1.0 + eff.num, 1.0 / n) - 1.0) * n)


def xl_rri(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`RRI(nper, pv, fv)` — the equivalent interest RATE of a growth:
    `(fv/pv)^(1/nper) - 1`.

    ⭐ RRI AND PDURATION ARE INVERSES AND THE ROUND TRIP GRADES BOTH:
    `RRI(2, 100, 121)` is **0.1** and `PDURATION(0.1, 100, 121)` is **2**.
    Neither number can be produced by a kernel that has the exponent the wrong
    way up, because `(121/100)^2 - 1` is 0.4641.

    ⚠ `nper <= 0` AND `pv = 0` ARE `#NUM!`. A zero starting value has no
    growth rate to report, and Excel refuses rather than returning `inf`."""
    var nper = _num(args, 0)
    if nper.is_error():
        return nper^
    var pv = _num(args, 1)
    if pv.is_error():
        return pv^
    var fv = _num(args, 2)
    if fv.is_error():
        return fv^
    if nper.num <= 0.0 or pv.num == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var ratio = fv.num / pv.num
    if ratio < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var v = _pw(ratio, 1.0 / nper.num) - 1.0
    if _is_nan(v):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(v)


def xl_pduration(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PDURATION(rate, pv, fv)` — how many periods at `rate` take `pv` to
    `fv`: `(ln(fv) - ln(pv)) / ln(1 + rate)`.

    ⚠ ALL THREE DEGENERATE CASES ARE `#NUM!` AND EACH IS A DIFFERENT
    STATEMENT: `rate <= 0` means the value never grows, `pv <= 0` and
    `fv <= 0` mean the logarithm has no real value. libm would hand back
    `-inf` for the second and `nan` for the third, and both would travel."""
    var rate = _num(args, 0)
    if rate.is_error():
        return rate^
    var pv = _num(args, 1)
    if pv.is_error():
        return pv^
    var fv = _num(args, 2)
    if fv.is_error():
        return fv^
    if rate.num <= 0.0 or pv.num <= 0.0 or fv.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(
        (_ln(fv.num) - _ln(pv.num)) / _ln(1.0 + rate.num))


# =============================================================================
# ★ DOLLARDE / DOLLARFR — the fractional price notation, and they are inverses.
# =============================================================================
def xl_dollarde(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DOLLARDE(fractional_dollar, fraction)` — `1.02` sixteenths is
    **1.125**, i.e. one dollar and two SIXTEENTHS.

    ⛔⛔ THE FRACTIONAL PART IS A NUMERATOR IN A FIXED-WIDTH FIELD, NOT A
    DECIMAL. `1.02` with `fraction = 16` means `1 + 02/16`, so the `.02` is
    scaled by `10^ceil(log10(16))` = 100 first and only THEN divided by 16. A
    kernel that read `.02` as two hundredths answers `1 + 0.02/16` = 1.00125 —
    a dollar-shaped number that is wrong by a factor of 100.

    ⚠ `fraction = 0` IS `#DIV/0!` AND A NEGATIVE ONE IS `#NUM!`; the two are
    different errors for two different reasons and Excel reports both.

    ⚠ THE WIDTH IS COMPUTED BY AN INTEGER LOOP (`_digits10`), not by
    `pow(10, ceil(log10(n)))` — see that helper for the libm reason."""
    var fd = _num(args, 0)
    if fd.is_error():
        return fd^
    var fr = _num(args, 1)
    if fr.is_error():
        return fr^
    var f = _trunc0(fr.num)
    if f < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    if f == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    var whole = _trunc0(fd.num)
    var part = fd.num - whole
    return FormulaValue.number(whole + part * _digits10(f) / f)


def xl_dollarfr(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DOLLARFR(decimal_dollar, fraction)` — the exact inverse of
    `DOLLARDE`: **1.125** in sixteenths is `1.02`.

    ⛔ THE TWIN IS `DOLLARDE` AND THE TWO AGREE ON EVERY WHOLE NUMBER —
    `DOLLARDE(2, 16)` and `DOLLARFR(2, 16)` are both 2, because a price with
    no fractional part has nothing to re-scale. That is the blind input the
    oracle carries; the sharp one is `1.125`, where DOLLARFR is 1.02 and
    DOLLARDE is 1.78125."""
    var dd = _num(args, 0)
    if dd.is_error():
        return dd^
    var fr = _num(args, 1)
    if fr.is_error():
        return fr^
    var f = _trunc0(fr.num)
    if f < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    if f == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    var whole = _trunc0(dd.num)
    var part = dd.num - whole
    return FormulaValue.number(whole + part * f / _digits10(f))


# =============================================================================
# ★★ DEPRECIATION — SLN / SYD / DB / DDB, four schedules over one asset.
# =============================================================================
def xl_sln(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SLN(cost, salvage, life)` — `(cost - salvage) / life`, the same amount
    every period.

    ⭐ THE BLIND INPUT AGAINST `SYD` IS THE MIDDLE PERIOD OF AN ODD-LIFE
    ASSET. `SLN(3000, 0, 3)` is 1000 and `SYD(3000, 0, 3, 2)` is ALSO 1000,
    because the sum-of-years schedule crosses the straight line exactly at
    `per = (life+1)/2`. A fixture that only ever asks about the middle period
    cannot tell an accelerating schedule from a flat one.

    ⚠ `life = 0` IS `#DIV/0!` — the formula divides by it."""
    var cost = _num(args, 0)
    if cost.is_error():
        return cost^
    var sal = _num(args, 1)
    if sal.is_error():
        return sal^
    var life = _num(args, 2)
    if life.is_error():
        return life^
    if life.num == 0.0:
        return FormulaValue.error(XL_ERR_DIV0)
    return FormulaValue.number((cost.num - sal.num) / life.num)


def xl_syd(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SYD(cost, salvage, life, per)` — sum-of-years'-digits:
    `(cost - salvage) * (life - per + 1) * 2 / (life * (life + 1))`.

    ⛔ THE `+ 1` IN `(life - per + 1)` IS THE WHOLE FUNCTION. Without it the
    LAST period depreciates nothing and every earlier period is short; with
    `per` and `life` swapped the schedule runs backwards. `SYD(3000,0,3,1)` is
    **1500** and `SYD(3000,0,3,3)` is **500** — the ratio 3:1 is what says the
    schedule accelerates at the documented rate and not some other one.

    ⚠ `per > life` IS `#NUM!`, not 0: there is no such period."""
    var cost = _num(args, 0)
    if cost.is_error():
        return cost^
    var sal = _num(args, 1)
    if sal.is_error():
        return sal^
    var life = _num(args, 2)
    if life.is_error():
        return life^
    var per = _num(args, 3)
    if per.is_error():
        return per^
    if life.num <= 0.0 or per.num <= 0.0 or per.num > life.num:
        return FormulaValue.error(XL_ERR_NUM)
    var num = (cost.num - sal.num) * (life.num - per.num + 1.0) * 2.0
    return FormulaValue.number(num / (life.num * (life.num + 1.0)))


def xl_db(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DB(cost, salvage, life, period, [month])` — FIXED-declining balance.

    ⛔⛔ THE THREE-DECIMAL ROUNDING OF THE RATE IS A DOCUMENTED WART AND IT IS
    NOT OPTIONAL. Microsoft defines the rate as
    `ROUND(1 - (salvage/cost)^(1/life), 3)`, and that rounding is what makes
    `DB` a DIFFERENT function from a continuous declining balance rather than
    a floating-point variation on one. On `(1000000, 100000, 6, 1, 7)` the
    unrounded rate is 0.3187080… and the rounded one is 0.319; the answer is
    **186083.33333333334** with the rounding and 186079.72… without it — a
    0.002% difference that looks exactly like accumulated float error and is
    not.

    ⛔ AND `month` IS THE SECOND HALF. It is the number of months in the FIRST
    year (default 12), so period 1 is pro-rated by `month/12` and the asset
    depreciates over `life + 1` periods, with the last one pro-rated by
    `(12 - month)/12`. A kernel that ignored `month` answers the full-year
    number for the first period — 319000 instead of 186083.33 — and then
    disagrees with Excel for the whole rest of the schedule because the
    running total is wrong from period 2 onward.

    ⭐ THE MIS-WIRING TWIN IS `DDB`, AND THERE IS AN INPUT WHERE THEY AGREE
    EXACTLY. `DB(1000, 107.3741824, 10, 1)` is 200 and so is
    `DDB(1000, 107.3741824, 10, 1)`, because `0.8^10` is exactly that salvage
    ratio and so `1 - (s/c)^(1/10)` is exactly `2/10`. The oracle carries that
    cell as the pair's blind and `DB(…, 1, 6)` = 100 as the sharp one."""
    var cost = _num(args, 0)
    if cost.is_error():
        return cost^
    var sal = _num(args, 1)
    if sal.is_error():
        return sal^
    var life = _num(args, 2)
    if life.is_error():
        return life^
    var per = _period_arg(args, 3)
    if per.is_error():
        return per^
    var mon = _opt(args, 4, 12.0)
    if mon.is_error():
        return mon^
    var m = _trunc0(mon.num)
    if m < 1.0 or m > 12.0:
        return FormulaValue.error(XL_ERR_NUM)
    if life.num <= 0.0 or per.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    if per.num > life.num + 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    if cost.num <= 0.0 or sal.num < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var rate = _round3(1.0 - _pw(sal.num / cost.num, 1.0 / life.num))
    if _is_nan(rate):
        return FormulaValue.error(XL_ERR_NUM)
    var total: Float64 = 0.0
    var d: Float64 = 0.0
    var p: Float64 = 1.0
    while p <= per.num:
        if p == 1.0:
            d = cost.num * rate * m / 12.0
        elif p == life.num + 1.0:
            d = (cost.num - total) * rate * (12.0 - m) / 12.0
        else:
            d = (cost.num - total) * rate
        total = total + d
        p = p + 1.0
    return FormulaValue.number(d)


def xl_ddb(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DDB(cost, salvage, life, period, [factor])` — DOUBLE-declining balance
    (any `factor`, defaulting to 2).

    ⛔ THE SALVAGE FLOOR IS A `MIN`, NOT A SUBTRACTION. The declining-balance
    schedule never reaches the salvage value on its own, so Excel CLIPS the
    last productive period: when the balance would fall below `salvage`, that
    period depreciates only down to it and every later period depreciates
    **0**. `DDB(2400, 300, 10, 10)` is **22.122547200000042**, not the
    51.54 the unclipped curve gives — and an unclipped kernel agrees with
    Excel for the first nine periods, which is where a fixture stops.

    ⛔ THE TWIN IS `DB`, AND `DB`'S ROUNDED RATE IS THE ONLY THING SEPARATING
    THEM ON a matched input — see `xl_db`'s docstring for the pair that agrees
    at 200 and the `month` argument that splits it.

    ⚠ `factor` IS A RATE MULTIPLIER OVER `life`, so `factor = life` is a
    100%-per-period write-off; the closed form handles it because
    `pow(0, 0)` is 1 and `pow(0, k>0)` is 0, which is exactly the "everything
    in period 1, nothing after" schedule."""
    var cost = _num(args, 0)
    if cost.is_error():
        return cost^
    var sal = _num(args, 1)
    if sal.is_error():
        return sal^
    var life = _num(args, 2)
    if life.is_error():
        return life^
    var per = _num(args, 3)
    if per.is_error():
        return per^
    var fac = _opt(args, 4, 2.0)
    if fac.is_error():
        return fac^
    if cost.num < 0.0 or sal.num < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    if life.num <= 0.0 or per.num <= 0.0 or fac.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var rate = fac.num / life.num
    if rate > 1.0:
        rate = 1.0
    var old = cost.num * _pw(1.0 - rate, per.num - 1.0)
    var new = cost.num * _pw(1.0 - rate, per.num)
    var d = (old - sal.num) if new < sal.num else (old - new)
    if d < 0.0:
        d = 0.0
    if _is_nan(d):
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(d)

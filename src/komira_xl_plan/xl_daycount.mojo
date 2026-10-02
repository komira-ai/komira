# =============================================================================
# xl_daycount.mojo — ★★ ONE PRIMITIVE, NINE NAMES: `YEARFRAC` OVER FIVE
#                       DAY-COUNT BASES, AND THE EIGHT `Financial` FUNCTIONS
#                       THAT ARE CLOSED FORMS OVER IT.
# =============================================================================
#
# `xl_scalar_financial.mojo`'s header names the reason all 34 remaining
# `Financial` names were refused on 2026-09-14, and CLASS 1 of that refusal —
# 24 of the 34 — was ONE missing primitive:
#
#     yearfrac(date1, date2, basis)   basis in {0,1,2,3,4}
#
# ⛔ AND THE REFUSAL'S OWN WORDING IS WHY THIS FILE EXISTS RATHER THAN A PATCH
# TO A SIBLING: *"ONE WRONG `yearfrac` WOULD INFECT ALL TWENTY-FOUR AT ONCE,
# and every one of them would answer a plausible price."* So the primitive is
# written ONCE, in one function, graded against published values BY ITSELF
# before any money formula reads it, and every name below calls that one
# function. There is no second spelling of a day count in this file.
#
# ============ ⚠⚠ THERE IS ALREADY A 30/360 IN THIS TREE AND IT IS A DIFFERENT
#                 FUNCTION. `DAYS360` IS NOT `YEARFRAC(..., 0) * 360`.
#
# `xl_scalar_date.xl_days360` implements Microsoft's DAYS360 US (NASD) wording;
# `_yearfrac` below implements the ODF 1.2 YEARFRAC basis-0 rule. They are
# DIFFERENT ALGORITHMS and they disagree on ordinary dates. Measured here:
#
#     dates                     DAYS360 US    YEARFRAC(.,0)*360
#     2018-01-31 -> 2018-02-28      30              28
#     2021-02-28 -> 2021-03-31      30              31
#
# ⇒ A READER WHO "UNIFIES" THE TWO BREAKS ONE OF THEM. Both are asserted, in
#   `test_xl_daycount_kernels.mojo` and `test_xl_scalar_kernels.mojo`, on the
#   same two date pairs, so the divergence is pinned from both sides.
#
# ============ ★ PROVENANCE OF THE BASIS RULES, AND THE CLAUSE ORDER
#
#   ⚠ THE CLAUSE ORDER CHOSEN, STATED SO IT CAN BE FALSIFIED (basis 0):
#       1. if day1 == 31            -> day1 = 30
#       2. if day1 == 30 and day2 == 31 -> day2 = 30
#       3. ELSE (and only else) the FEBRUARY arm: if day1 is the last day of
#          February -> day1 = 30, AND ONLY THEN, NESTED INSIDE IT, if day2 is
#          also the last day of February -> day2 = 30.
#     Two things a re-derivation gets wrong. (a) The February arm is the ELSE
#     of clause 2, not a third independent clause. (b) day2's February
#     adjustment is NESTED INSIDE day1's — an end-of-February END date is only
#     moved to the 30th when the START date was also an end-of-February.
#     MEASURED CONSEQUENCE of flattening the nesting: YEARFRAC(2020-02-29,
#     2021-02-28, 0) is EXACTLY 1.0 under this reading and 358/360 =
#     0.99444... under a reading that drops the inner clause, and 0.99444 is
#     not an error — it is a plausible year fraction.
#
#   ⚠ AND THE ASYMMETRY IS REAL, NOT A TRANSCRIPTION SLIP:
#     YEARFRAC(2021-02-28, 2021-03-31, 0) is 31/360. The start moves to the
#     30th (February arm) and the end stays at the 31st, because clause 2 was
#     evaluated BEFORE the February arm ran and day1 was 28 at the time. A
#     reader who "fixes" that to 30/360 has re-derived DAYS360.
#
# ============ ⛔ WHAT THE PUBLISHED SOURCES DISAGREE ABOUT, MEASURED
#
# LibreOffice at that same tag calls TWO DIFFERENT day-count routines from the
# Financial names: `GetYearFrac()` (the ODF §4.11.7 one above) from DISC,
# PRICEMAT, YIELDDISC, YIELDMAT and TBILLPRICE, but `GetYearDiff()` — an older
# routine with a DIFFERENT basis-0 rule and a basis-1 denominator that is
# simply "days in the START year" — from ACCRINTM, RECEIVED, PRICEDISC and
# INTRATE. Microsoft's pages define ALL EIGHT uniformly as a ratio of "number
# of days between" to "B = number of days in a year, depending on the year
# basis", i.e. as ONE day-count fraction.
#
# ⇒ THIS FILE FOLLOWS MICROSOFT'S PUBLISHED CLOSED FORMS and calls the ONE
#   `_yearfrac` everywhere. Every one of the eight reproduces its own MS
#   published worked example EXACTLY (see the test file), including the four
#   LibreOffice routes through `GetYearDiff`, which is the evidence for the
#   choice rather than a preference.
#
# ============ ⛔ A PUBLISHED EXAMPLE THAT IS ITSELF WRONG — MEASURED 2026-09-15
#
# Microsoft's DISC page (fetched 2026-09-15) shows settlement 07/01/2018,
# maturity 01/01/2048, pr 97.975, redemption 100, basis 1, Result **0.001038**.
# That result is NOT reproducible from those inputs by any basis: the span is
# 29.5 years and 0.02025 / 29.5 is 0.000686. It IS reproduced EXACTLY — to all
# seven published digits, 0.0010381908 — with maturity **01/01/2038**. The same
# page's own Remarks describe "a 30-year bond ... issued on January 1, 2018 ...
# maturity date would be January 1, 2048", while PRICEMAT's and YIELDMAT's
# Remarks still say "issued on January 1, 2008 ... January 1, 2038": the page's
# PROSE and DATA were re-dated 2008->2018 and the RESULT CELL was not
# recomputed. ⇒ The DISC assertion in the test file uses the 2038 maturity and
# says why. This is the whole reason the brief forbids taking an oracle on
# faith: the oracle was wrong, and the formula was right.
#
# ============ ⛔ WHAT THIS PRIMITIVE DOES *NOT* UNLOCK — REFUSED BY NAME
#
# yearfrac alone does not reach the COUP* six, ACCRINT, DURATION, MDURATION,
# PRICE, YIELD or the ODD* four: every one of those needs a COUPON SCHEDULE
# (previous/next coupon date from settlement, maturity and frequency), which
# is calendar arithmetic over a basis-aware date, not a day count. And
# TBILLEQ / TBILLPRICE / TBILLYIELD are refused for a DIFFERENT, sharper
# reason stated in `xl_absent_common_names()`. All stay refused.
#
# Encapsulation rule : values only, no `UnsafePointer`.
# =============================================================================

from std.math import ceil, floor

from komira_core.plan.excel_error_code import XL_ERR_NUM, XL_ERR_VALUE

from .formula_value import FormulaValue
from .xl_date_serial import _leap, _serial_to_ymd


def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` as a NUMBER, or the error that stops the call. Same
    contract as `xl_scalar_financial._num`; re-spelled rather than imported for
    the reason that file states — a cross-module import of a private helper is
    the edge that makes a "kernels only" module stop being one."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def _trunc0(x: Float64) -> Float64:
    """The integer part, TOWARD ZERO. Every page in this family says the same
    sentence — *"settlement, maturity, issue and basis are truncated to
    integers"* — and it is TRUNCATION, not flooring. Dates are positive so the
    two agree there; `basis` is where it bites, because a flooring kernel turns
    `-0.5` into -1 (a `#NUM!`) where Excel turns it into 0 (the default
    basis)."""
    return floor(x) if x >= 0.0 else ceil(x)


def _basis_arg(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """The OPTIONAL `basis` argument, truncated, defaulting to 0.

    ⛔ THE DEFAULT IS 0 (US 30/360) AND NOT 1. Every page in this family says
    "0 or omitted -> US (NASD) 30/360", and 0 is the basis whose end-of-month
    rules are the ones a half-built kernel gets wrong — so a kernel that
    defaulted to actual/actual would be wrong on exactly the calls that omit
    the argument, which is most of them.

    Returns a NUMBER value holding the basis, or `#NUM!` outside 0..4 — which
    is the error every page in the family documents for it."""
    if len(args) <= i:
        return FormulaValue.number(0.0)
    var b = _num(args, i)
    if b.is_error():
        return b^
    var t = _trunc0(b.num)
    if t < 0.0 or t > 4.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(t)


def _serial_arg(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """A DATE argument, truncated to its serial. A serial below 0 is not a
    valid Excel date, and every page in this family documents `#VALUE!` — not
    `#NUM!` — for "not a valid serial date number"."""
    var v = _num(args, i)
    if v.is_error():
        return v^
    var t = _trunc0(v.num)
    if t < 0.0:
        return FormulaValue.error(XL_ERR_VALUE)
    return FormulaValue.number(t)


# =============================================================================
# ★★ THE PRIMITIVE. ODF 1.2 part 2 §4.11.7; LibreOffice `GetYearFrac()` at tag
#    `libreoffice-25.2.5.2`. EVERY NAME IN THIS FILE GOES THROUGH IT.
# =============================================================================
def _yearfrac(s1_in: Int, s2_in: Int, basis: Int) raises -> Float64:
    """The year fraction between two Excel serials under one of five bases.

    ⚠ IT IS SYMMETRIC AND NEVER NEGATIVE. ODF orders the two dates before
    counting, so `YEARFRAC(b, a)` equals `YEARFRAC(a, b)`. ⛔ THIS IS THE
    OPPOSITE OF `DAYS360`, which is a SIGNED difference — the two functions are
    not two spellings of one idea and the header says why.

    ⚠ THE ACTUAL-DAY NUMERATOR IS A SERIAL SUBTRACTION, ON PURPOSE. Excel's
    serial 60 is the Lotus phantom 1900-02-29, so a span crossing it counts one
    more day than the true Gregorian calendar does. Subtracting serials is what
    Excel does; converting both ends to civil dates and differencing them would
    "fix" the phantom and disagree with Excel for every span across 1900-02-28.
    The y/m/d DECOMPOSITION still goes through `_serial_to_ymd`, which carries
    the phantom, so the 30/360 arms see the same calendar Excel does."""
    if s1_in == s2_in:
        return 0.0
    var s1 = s1_in
    var s2 = s2_in
    if s1 > s2:
        s1 = s2_in
        s2 = s1_in

    var p = _serial_to_ymd(s1)
    var q = _serial_to_ymd(s2)
    var y1 = p.y
    var m1 = p.m
    var d1 = p.d
    var y2 = q.y
    var m2 = q.m
    var d2 = q.d

    if basis == 0:
        # ---- 0 = US (NASD) 30/360. ODF §4.11.7.7.2. THE CLAUSE ORDER AND THE
        #      NESTING ARE THE WHOLE RULE; the header states the two measured
        #      consequences of getting either wrong.
        if d1 == 31:
            d1 = 30
        if d1 == 30 and d2 == 31:
            d2 = 30
        else:
            var last1 = 29 if _leap(y1) else 28
            if m1 == 2 and d1 == last1:
                d1 = 30
                # ⛔ NESTED, NOT A SIBLING. An end-of-February END date moves to
                # the 30th ONLY when the START date was one too.
                var last2 = 29 if _leap(y2) else 28
                if m2 == 2 and d2 == last2:
                    d2 = 30
        return Float64((y2 - y1) * 360 + (m2 - m1) * 30 + (d2 - d1)) / 360.0

    if basis == 4:
        # ---- 4 = European 30E/360. ODF §4.11.7.7.5. ⚠ IT IS *NOT* "clamp to
        #      30": only the 31st moves, and it moves on BOTH ends
        #      unconditionally — no February clause, no next-month push. That
        #      is exactly the difference basis 0's February arm makes.
        if d1 == 31:
            d1 = 30
        if d2 == 31:
            d2 = 30
        return Float64((y2 - y1) * 360 + (m2 - m1) * 30 + (d2 - d1)) / 360.0

    var actual = Float64(s2 - s1)
    if basis == 2:
        return actual / 360.0
    if basis == 3:
        return actual / 365.0

    # ---- 1 = actual/actual. ODF §4.11.7.7.7 .. .10. The NUMERATOR is trivial;
    #      EVERY difficulty is in the DENOMINATOR, and it has three arms.
    var diff_year = y1 != y2
    if diff_year and (
        y2 != y1 + 1 or m1 < m2 or (m1 == m2 and d1 < d2)
    ):
        # ARM 1 — the span covers MORE THAN ONE anniversary. §4.11.7.7.7: the
        # denominator is the AVERAGE length of the calendar years the span
        # touches, INCLUSIVE of both ends. ⚠ `y2 - y1 + 1` and not `y2 - y1`:
        # 2019-01-01 -> 2021-01-01 touches THREE years, and dividing by two
        # would answer 1.334 years for a two-year span.
        var total = 0
        var i = y1
        while i <= y2:
            total += 366 if _leap(i) else 365
            i += 1
        return actual / (Float64(total) / Float64(y2 - y1 + 1))

    if not diff_year:
        # ARM 2 — one calendar year. §4.11.7.7.8.
        return actual / (366.0 if _leap(y1) else 365.0)

    # ARM 3 — at most one anniversary. §4.11.7.7.9/.10: the denominator is 366
    # iff a 29 February lies in the CLOSED interval [date1, date2].
    # ⚠⚠ THIS IS THE LEAP-SPANNING RULE AND IT IS THE ONE A NAIVE KERNEL DROPS.
    # MEASURED: YEARFRAC(2019-07-01, 2020-06-30, 1) is 365/366 = 0.99726776
    # here and 365/365 = EXACTLY 1.0 without it — a whole year reported for a
    # span that is one day short of one, with no error anywhere.
    var starts_before_feb29 = _leap(y1) and (m1 < 2 or (m1 == 2 and d1 <= 29))
    var ends_after_feb29 = _leap(y2) and (m2 > 2 or (m2 == 2 and d2 == 29))
    if starts_before_feb29 or ends_after_feb29:
        return actual / 366.0
    return actual / 365.0


def xl_yearfrac(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`YEARFRAC(start_date, end_date, [basis])`.

    GRADED AGAINST MICROSOFT'S OWN PUBLISHED PAGE (fetched 2026-09-15), which
    prints three values for the pair 2012-01-01 / 2012-07-30 and this kernel
    reproduces all three to the last published digit:

        basis omitted (0)  0.58055556   = 209/360
        basis 1            0.57650273   = 211/366   (2012 is a leap year)
        basis 3            0.57808219   = 211/365

    ⭐ THE basis-1 CELL IS THE LOAD-BEARING ONE: it is the same numerator as
    basis 3 over a DIFFERENT denominator, so it grades the "same calendar year
    and that year is a leap year -> 366" arm, which is the arm a kernel that
    hardcodes 365 gets wrong by 0.3%.

    `basis` outside 0..4 is `#NUM!`; a negative serial is `#VALUE!`. Both are
    the errors the page documents."""
    var a = _serial_arg(args, 0)
    if a.is_error():
        return a^
    var b = _serial_arg(args, 1)
    if b.is_error():
        return b^
    var bs = _basis_arg(args, 2)
    if bs.is_error():
        return bs^
    return FormulaValue.number(_yearfrac(Int(a.num), Int(b.num), Int(bs.num)))


# =============================================================================
# ★ THE EIGHT `Financial` NAMES. Each is Microsoft's published closed form over
#   `_yearfrac` and NOTHING ELSE — no second day count, no rounding wart.
#
# ⚠ THE GUARD SET IS THE SAME FIVE SENTENCES ON EVERY PAGE and the ORDER
#   matters: argument errors dominate first, then `basis` out of range
#   (`#NUM!`), then the domain (`#NUM!`). A kernel that checked the domain
#   before the basis would answer `#NUM!` for both and be indistinguishable —
#   until a caller passes a valid basis and an invalid domain, where the two
#   orderings still agree, or an invalid basis and a valid domain, where they
#   agree again. It is checked in this order because the pages list it in this
#   order, not because a fixture separates them.
# =============================================================================
def _guard2(imm a: FormulaValue, imm b: FormulaValue) -> FormulaValue:
    """settlement/issue < maturity/settlement, else `#NUM!`. Every page in the
    family says `settlement >= maturity` is `#NUM!` — ⛔ NOT a sign flip and
    NOT zero. A kernel that let the dates cross answers a NEGATIVE price."""
    if a.num >= b.num:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(0.0)


def xl_accrintm(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ACCRINTM(issue, settlement, rate, par, [basis])` — accrued interest for
    a security that pays interest AT MATURITY.

    Microsoft: `ACCRINTM = par x rate x A/D`, A = days issue->settlement,
    D = annual year basis. So it is `par * rate * yearfrac(issue, settlement)`.

    PUBLISHED EXAMPLE (MS page, fetched 2026-09-15): issue serial 39539
    (2008-04-01), settlement serial 39614 (2008-06-15), rate 0.1, par 1000,
    basis 3 -> **20.54794521**. This kernel: 1000 * 0.1 * 75/365 =
    20.54794520547945. ⚠ THE PAGE GIVES THE DATES AS RAW SERIALS, which is
    also a free assertion that this tree's serial->civil map agrees with
    Excel's: 39539 must decode to 2008-04-01 or the 75 is not 75.

    `rate <= 0` or `par <= 0` is `#NUM!`; `issue >= settlement` is `#NUM!`."""
    var issue = _serial_arg(args, 0)
    if issue.is_error():
        return issue^
    var settle = _serial_arg(args, 1)
    if settle.is_error():
        return settle^
    var rate = _num(args, 2)
    if rate.is_error():
        return rate^
    var par = _num(args, 3)
    if par.is_error():
        return par^
    var bs = _basis_arg(args, 4)
    if bs.is_error():
        return bs^
    if rate.num <= 0.0 or par.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var g = _guard2(issue, settle)
    if g.is_error():
        return g^
    var yf = _yearfrac(Int(issue.num), Int(settle.num), Int(bs.num))
    return FormulaValue.number(par.num * rate.num * yf)


def xl_disc(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DISC(settlement, maturity, pr, redemption, [basis])` — the discount rate.

    Microsoft: `DISC = ((redemption - pr)/redemption) x (B/DSM)`, which is
    `(1 - pr/redemption) / yearfrac(settlement, maturity)`.

    ⛔⛔ THE PUBLISHED EXAMPLE ON MICROSOFT'S OWN DISC PAGE DOES NOT REPRODUCE
    FROM ITS OWN INPUTS, and the file header carries the measurement. The page
    shows maturity 01/01/2048 and Result 0.001038; 0.001038 is the answer for
    maturity 01/01/**2038** (0.0010381908237748, all seven published digits),
    and the sibling PRICEMAT/YIELDMAT pages still describe the same bond with
    the 2038 maturity. The assertion in the test file therefore uses 2038 and
    names the discrepancy. A kernel "corrected" until it printed 0.001038 for
    the 2048 inputs would have to be wrong by a factor of 1.5.

    `pr <= 0` or `redemption <= 0` is `#NUM!`; `settlement >= maturity` is
    `#NUM!`."""
    var settle = _serial_arg(args, 0)
    if settle.is_error():
        return settle^
    var mat = _serial_arg(args, 1)
    if mat.is_error():
        return mat^
    var pr = _num(args, 2)
    if pr.is_error():
        return pr^
    var red = _num(args, 3)
    if red.is_error():
        return red^
    var bs = _basis_arg(args, 4)
    if bs.is_error():
        return bs^
    if pr.num <= 0.0 or red.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var g = _guard2(settle, mat)
    if g.is_error():
        return g^
    var yf = _yearfrac(Int(settle.num), Int(mat.num), Int(bs.num))
    if yf == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number((1.0 - pr.num / red.num) / yf)


def xl_intrate(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`INTRATE(settlement, maturity, investment, redemption, [basis])` — the
    interest rate for a fully invested security.

    Microsoft: `INTRATE = ((redemption - investment)/investment) x (B/DIM)`.

    PUBLISHED EXAMPLE (MS page): 2008-02-15 -> 2008-05-15, investment 1000000,
    redemption 1014420, basis 2 -> **0.05768**. This kernel: yearfrac basis 2
    is 90/360 = 0.25 exactly, and 0.01442/0.25 = 0.05768.
    the two agree; the published MS formula is what is implemented."""
    var settle = _serial_arg(args, 0)
    if settle.is_error():
        return settle^
    var mat = _serial_arg(args, 1)
    if mat.is_error():
        return mat^
    var inv = _num(args, 2)
    if inv.is_error():
        return inv^
    var red = _num(args, 3)
    if red.is_error():
        return red^
    var bs = _basis_arg(args, 4)
    if bs.is_error():
        return bs^
    if inv.num <= 0.0 or red.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var g = _guard2(settle, mat)
    if g.is_error():
        return g^
    var yf = _yearfrac(Int(settle.num), Int(mat.num), Int(bs.num))
    if yf == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number((red.num / inv.num - 1.0) / yf)


def xl_received(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`RECEIVED(settlement, maturity, investment, discount, [basis])` — the
    amount received at maturity for a fully invested security.

    Microsoft: `RECEIVED = investment / (1 - (discount x DIM/B))`.

    PUBLISHED EXAMPLE (MS page): 2008-02-15 -> 2008-05-15, investment 1000000,
    discount 0.0575, basis 2 -> **$1,014,584.65**. This kernel:
    1000000 / (1 - 0.0575*0.25) = 1014584.6544071021.

    ⚠ IT IS A DIVISION BY `1 - discount*yearfrac` AND NOT A MULTIPLICATION BY
    `1 + discount*yearfrac`. On this example the two differ by 209 dollars out
    of a million — 0.02%, which reads as a rounding difference and is not one.
    A `1 - d*t == 0` denominator is `#NUM!` rather than an infinity."""
    var settle = _serial_arg(args, 0)
    if settle.is_error():
        return settle^
    var mat = _serial_arg(args, 1)
    if mat.is_error():
        return mat^
    var inv = _num(args, 2)
    if inv.is_error():
        return inv^
    var disc = _num(args, 3)
    if disc.is_error():
        return disc^
    var bs = _basis_arg(args, 4)
    if bs.is_error():
        return bs^
    if inv.num <= 0.0 or disc.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var g = _guard2(settle, mat)
    if g.is_error():
        return g^
    var yf = _yearfrac(Int(settle.num), Int(mat.num), Int(bs.num))
    var den = 1.0 - disc.num * yf
    if den == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(inv.num / den)


def xl_pricedisc(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PRICEDISC(settlement, maturity, discount, redemption, [basis])` — the
    price per $100 of a discounted security.

    Microsoft: `PRICEDISC = redemption - discount x redemption x DSM/B`.

    PUBLISHED EXAMPLE (MS page): 2008-02-16 -> 2008-03-01, discount 0.0525,
    redemption 100, basis 2 -> **$99.80** (the page rounds to cents). This
    kernel: 100 - 0.0525*100*14/360 = 99.79583333333333.

    ⚠ THE DAY COUNT IS 14 AND NOT 13: 2008 is a leap year, so February has 29
    days. A kernel using a non-leap February answers 99.81041667 — off by a cent
    and a half on a $100 bond, which is exactly the size of error that reads as
    somebody else's rounding."""
    var settle = _serial_arg(args, 0)
    if settle.is_error():
        return settle^
    var mat = _serial_arg(args, 1)
    if mat.is_error():
        return mat^
    var disc = _num(args, 2)
    if disc.is_error():
        return disc^
    var red = _num(args, 3)
    if red.is_error():
        return red^
    var bs = _basis_arg(args, 4)
    if bs.is_error():
        return bs^
    if disc.num <= 0.0 or red.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var g = _guard2(settle, mat)
    if g.is_error():
        return g^
    var yf = _yearfrac(Int(settle.num), Int(mat.num), Int(bs.num))
    return FormulaValue.number(red.num - disc.num * red.num * yf)


def xl_yielddisc(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`YIELDDISC(settlement, maturity, pr, redemption, [basis])` — the annual
    yield of a discounted security.

    Microsoft: `YIELDDISC = ((redemption - pr)/pr) x (B/DSM)`.

    PUBLISHED EXAMPLE (MS page): 2008-02-16 -> 2008-03-01, pr 99.795,
    redemption 100, basis 2 -> **0.052823**. This kernel: 0.052822571986860085.

    ⛔ THE DENOMINATOR OF THE RATIO IS `pr`, WHERE `DISC`'s IS `redemption`.
    That is the ONLY algebraic difference between this function and DISC, and
    on the published example the two differ by 0.21% — 0.052822572 against
    0.052714286 — far smaller than the spread between two bases, and so
    invisible to any check that is not exact."""
    var settle = _serial_arg(args, 0)
    if settle.is_error():
        return settle^
    var mat = _serial_arg(args, 1)
    if mat.is_error():
        return mat^
    var pr = _num(args, 2)
    if pr.is_error():
        return pr^
    var red = _num(args, 3)
    if red.is_error():
        return red^
    var bs = _basis_arg(args, 4)
    if bs.is_error():
        return bs^
    if pr.num <= 0.0 or red.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var g = _guard2(settle, mat)
    if g.is_error():
        return g^
    var yf = _yearfrac(Int(settle.num), Int(mat.num), Int(bs.num))
    if yf == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number((red.num / pr.num - 1.0) / yf)


def xl_pricemat(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PRICEMAT(settlement, maturity, issue, rate, yld, [basis])` — the price
    per $100 of a security that pays interest at maturity.

    Microsoft:

        PRICEMAT = [ 100 + (DIM/B x rate x 100) ] / [ 1 + (DSM/B x yld) ]
                   - (A/B x rate x 100)

    THREE day counts from the SAME basis: DIM = issue->maturity,
    DSM = settlement->maturity, A = issue->settlement.

    PUBLISHED EXAMPLE (MS page): settlement 2008-02-15, maturity 2008-04-13,
    issue 2007-11-11, rate 0.061, yld 0.061, basis 0 -> **$99.98** (the page
    rounds to cents). This kernel: 99.98449887555697.

    ⭐ IT IS THE SHARPEST GRADE IN THIS FILE AND THAT IS WHY IT IS HERE. The
    example runs on basis 0 and CROSSES A YEAR BOUNDARY IN TWO OF THE THREE
    SPANS, so the 30/360 month/year arithmetic is exercised three times with
    different month pairs (11->4 and 11->2 across a year, 2->4 within one) —
    two of them a NEGATIVE month difference carried by the year term, which is
    the arm a kernel that clamps a month difference to a positive range gets
    wrong. MEASURED: a DSM off by one day lands at 100.00155 or 99.96746 and an
    `A` off by one at 100.00144 — not one of them "$99.98" even to the cent the
    page prints.

    `rate < 0` or `yld < 0` is `#NUM!` — ⚠ STRICTLY `<`, not `<=`: a zero-coupon
    security priced at a zero yield is a legitimate (and exactly computable)
    call, and rejecting it would refuse the simplest input the formula has."""
    var settle = _serial_arg(args, 0)
    if settle.is_error():
        return settle^
    var mat = _serial_arg(args, 1)
    if mat.is_error():
        return mat^
    var issue = _serial_arg(args, 2)
    if issue.is_error():
        return issue^
    var rate = _num(args, 3)
    if rate.is_error():
        return rate^
    var yld = _num(args, 4)
    if yld.is_error():
        return yld^
    var bs = _basis_arg(args, 5)
    if bs.is_error():
        return bs^
    if rate.num < 0.0 or yld.num < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var g = _guard2(settle, mat)
    if g.is_error():
        return g^
    var b = Int(bs.num)
    var dim = _yearfrac(Int(issue.num), Int(mat.num), b)
    var dsm = _yearfrac(Int(settle.num), Int(mat.num), b)
    var a = _yearfrac(Int(issue.num), Int(settle.num), b)
    var den = 1.0 + dsm * yld.num
    if den == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(
        (100.0 + dim * rate.num * 100.0) / den - a * rate.num * 100.0
    )


def xl_yieldmat(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`YIELDMAT(settlement, maturity, issue, rate, pr, [basis])` — the annual
    yield of a security that pays interest at maturity.

    Microsoft:

        YIELDMAT = [ (1 + DIM/B x rate) - (pr/100 + A/B x rate) ]
                   / ( pr/100 + A/B x rate)   x   B/DSM

    PUBLISHED EXAMPLE (MS page): settlement 2008-03-15, maturity 2008-11-03,
    issue 2007-11-08, rate 0.0625, pr 100.0123, basis 0 -> **0.060954**. This
    kernel: 0.06095433369153868.

    ⛔ IT IS NOT THE ALGEBRAIC INVERSE OF `PRICEMAT` AND MUST NOT BE WRITTEN AS
    ONE. PRICEMAT discounts by `1 + DSM/B x yld`; this divides by `B/DSM` at
    the END, over an accrual base that already includes the accrued coupon. The
    two are inverse only in the limit of a short span, so a `yieldmat` built by
    solving PRICEMAT would agree on a 60-day bill and drift on a year.

    `rate < 0` or `pr <= 0` is `#NUM!`. ⚠ THE TWO THRESHOLDS DIFFER — `rate`
    admits zero and `pr` does not, exactly as the page states, because `pr` is
    a divisor and `rate` is not."""
    var settle = _serial_arg(args, 0)
    if settle.is_error():
        return settle^
    var mat = _serial_arg(args, 1)
    if mat.is_error():
        return mat^
    var issue = _serial_arg(args, 2)
    if issue.is_error():
        return issue^
    var rate = _num(args, 3)
    if rate.is_error():
        return rate^
    var pr = _num(args, 4)
    if pr.is_error():
        return pr^
    var bs = _basis_arg(args, 5)
    if bs.is_error():
        return bs^
    if rate.num < 0.0 or pr.num <= 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    var g = _guard2(settle, mat)
    if g.is_error():
        return g^
    var b = Int(bs.num)
    var dim = _yearfrac(Int(issue.num), Int(mat.num), b)
    var dsm = _yearfrac(Int(settle.num), Int(mat.num), b)
    var a = _yearfrac(Int(issue.num), Int(settle.num), b)
    var base = pr.num / 100.0 + a * rate.num
    if base == 0.0 or dsm == 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(((1.0 + dim * rate.num) - base) / base / dsm)

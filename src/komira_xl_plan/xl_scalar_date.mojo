# =============================================================================
# xl_scalar_date.mojo — ★ THE DATE BREADTH KERNELS: NOW / WEEKDAY / EDATE /
#                         DAYS, and the TIME-OF-DAY FAMILY.
# =============================================================================
#
# ⛔⛔ THE PARAGRAPH THAT USED TO STAND HERE WAS A CATEGORY ERROR, AND IT KEPT
# FOUR FUNCTIONS OUT OF THIS ENGINE FOR IT. Verbatim, until 2026-09-04:
#
#     "HOUR / MINUTE / SECOND / TIME read the FRACTIONAL part of a serial, and
#      this engine has no clock at all... Answering HOUR(NOW()) with 0 is not a
#      smaller answer, it is a WRONG one that never varies, so those four stay
#      on xl_absent_common_names."
#
# ★ FALSE FOR `TIME`, WHICH READS NO SERIAL AND TOUCHES NO CLOCK.
# `TIME(h, m, s)` is `(h*3600 + m*60 + s) / 86400` — a pure function of three
# NUMERIC ARGUMENTS that **PRODUCES** a fraction. The record generalised
# "reads a fraction" from three functions to four and then used the clock, which
# is irrelevant to all four, as the reason.
#
# ★ AND OVERBROAD FOR THE OTHER THREE, which are pure functions of whatever
# VALUE they are handed. `FormulaValue` carries `Float64` (`formula_value.mojo`,
# `FV_NUMBER`), so a fractional serial is representable in this value model
# TODAY: `HOUR(TIME(13,30,0))` is 13, and it was a right answer being refused.
# The clock degrades EXACTLY ONE call shape — `HOUR(NOW())` — and `NOW`'s own
# row has documented that since the day `NOW` landed.
#
# ⇒ The four landed 2026-09-04. `TIME` landed FIRST and deliberately: it is the
# only one of them that can MANUFACTURE a fractional serial, so it is what
# makes the other three testable at all. Without it every `HOUR` assertion
# would read an INTEGER serial, where 0 is the right answer whether the kernel
# works or not — the all-timestamps-in-1970 fixture failure exactly.
#
# Encapsulation rule : values only.
# =============================================================================

from std.math import floor

from komira_core.plan.excel_error_code import XL_ERR_NUM, XL_ERR_VALUE

from .formula_value import FormulaValue
from .xl_date_serial import (
    _civil_from_days,
    _date_to_serial,
    _days_from_civil,
    _days_in_month,
    _serial_to_ymd,
)


def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def xl_now(today_serial: Int) raises -> FormulaValue:
    """`NOW()` — the bind-time-captured serial.

    ⚠⚠ DIVERGENCE FROM EXCEL, AND IT IS STRUCTURAL RATHER THAN A ROUNDING
    DIFFERENCE. Excel's NOW() is a date PLUS a fractional time of day, and this
    engine has no clock: `SemanticsProfile` captures one INTEGER at bind time
    (`today_serial`), which is the same value `TODAY()` returns. So NOW() here
    is always midnight, and `NOW() - TODAY()` is 0 where Excel gives the
    fraction of the day elapsed.

    An UNCAPTURED serial (<= 0) is `#VALUE!`, exactly as `TODAY()` is, rather
    than a guess at what day it is."""
    if today_serial > 0:
        return FormulaValue.number(Float64(today_serial))
    return FormulaValue.error(XL_ERR_VALUE)


def xl_weekday(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`WEEKDAY(serial, [return_type])` — the day of the week.

    ⚠ THREE RETURN TYPES AND THEY DISAGREE ON BOTH THE ORIGIN AND THE FIRST
    DAY, which is why a kernel serving only the default is wrong for two-thirds
    of real callers:

        1 (default)  Sunday = 1 .. Saturday = 7
        2            Monday = 1 .. Sunday   = 7
        3            Monday = 0 .. Sunday   = 6

    ⚠ AND THE PHANTOM DAY IS WHY THIS GOES THROUGH `_serial_to_ymd` RATHER THAN
    TAKING `serial % 7`. Excel's serial 60 is 1900-02-29, a day that never
    existed, so the serial-to-weekday relation is NOT a fixed modulus across
    the bug — every serial at or after 61 is shifted by one against the true
    day count. Round-tripping through the calendar is what makes the answer
    right on both sides of it.

    A return_type outside {1, 2, 3} is `#NUM!`, which is Excel's own error for
    it; a serial below 1 is `#NUM!` too."""
    var s = _num(args, 0)
    if s.is_error():
        return s^
    if s.num < 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    var rt = 1
    if len(args) >= 2:
        var r = _num(args, 1)
        if r.is_error():
            return r^
        rt = Int(r.num)
        if rt != 1 and rt != 2 and rt != 3:
            return FormulaValue.error(XL_ERR_NUM)

    var ymd = _serial_to_ymd(Int(s.num))
    # Hinnant days are relative to 1970-01-01, a THURSDAY. `+ 4` moves the
    # origin to a Sunday so the modulus is Sunday-based, matching return_type 1
    # before any shift.
    var dow = (_days_from_civil(ymd.y, ymd.m, ymd.d) + 4) % 7  # 0 = Sunday
    if dow < 0:
        dow += 7
    if rt == 1:
        return FormulaValue.number(Float64(dow + 1))
    if rt == 2:
        return FormulaValue.number(Float64((dow + 6) % 7 + 1))
    return FormulaValue.number(Float64((dow + 6) % 7))


def xl_edate(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`EDATE(start_date, months)` — the same day-of-month `months` later.

    ⚠ THE DAY IS CLAMPED TO THE TARGET MONTH'S LENGTH, NOT ROLLED OVER.
    `EDATE(2026-01-31, 1)` is 2026-02-28, NOT 2026-03-03. `_date_to_serial`
    rolls a day overflow forward by construction (it is linear day arithmetic),
    so passing day 31 into February there would produce March — a month later
    than the user asked for. The clamp has to happen HERE, before the serial is
    built.

    ⚠ NEGATIVE `months` GOES BACKWARDS, which is Excel's behaviour and is what
    the floor-division normalisation below gives."""
    var s = _num(args, 0)
    if s.is_error():
        return s^
    if s.num < 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    var m = _num(args, 1)
    if m.is_error():
        return m^

    var ymd = _serial_to_ymd(Int(s.num))
    var total = ymd.y * 12 + (ymd.m - 1) + Int(m.num)
    var y2 = total // 12
    var m2 = total % 12 + 1
    var d2 = ymd.d
    var last = _days_in_month(y2, m2)
    if d2 > last:
        d2 = last
    return FormulaValue.number(Float64(_date_to_serial(y2, m2, d2)))


def xl_days(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DAYS(end_date, start_date)` — the day count between two serials.

    ⚠ THE ARGUMENT ORDER IS END-THEN-START, which is the reverse of what most
    people write first, and it is Excel's. `DAYS(a, b)` is `a - b`.

    ⚠ AND IT IS A DIFFERENCE OF **TRUE** DAY COUNTS, NOT OF SERIALS. Across the
    Lotus phantom day the two disagree by one: serial 61 minus serial 59 is 2,
    but 1900-03-01 is only ONE day after 1900-02-28. Excel itself answers 2
    here — it subtracts serials — so this function does too, and the
    disagreement with the calendar is Excel's, faithfully reproduced. Anything
    else would make `DAYS` disagree with `EDATE`/`WEEKDAY`, which round-trip
    through the calendar, in a way no user could predict."""
    var e = _num(args, 0)
    if e.is_error():
        return e^
    var s = _num(args, 1)
    if s.is_error():
        return s^
    return FormulaValue.number(e.num - s.num)


# =============================================================================
# ★★ THE TIME-OF-DAY FAMILY (2026-09-04) — TIME / HOUR / MINUTE / SECOND.
#
# ⚠ THE FRACTIONAL PART OF AN EXCEL SERIAL **IS** THE TIME OF DAY, by
# definition and not by convention: 0.5 is noon, 0.75 is 18:00. Nothing about
# that needs a clock. What needs a clock is knowing what time it is NOW, and
# that is `NOW()`'s problem, stated in `NOW()`'s own row.
# =============================================================================
comptime _SECONDS_PER_DAY: Float64 = 86400.0


def _time_of_day_seconds(serial: Float64) -> Int:
    """The whole seconds elapsed since midnight, from a serial's FRACTION.

    ⚠⚠ IT ROUNDS TO THE NEAREST SECOND, AND WITHOUT THAT ROUNDING THE FAMILY
    IS OFF BY ONE ON A SPARSE, UNPREDICTABLE SUBSET OF SECONDS — which is worse
    than being off everywhere, because almost every value anyone tests is fine.

    ★ MEASURED OVER ALL 86,400 SECONDS OF DAY 0 (2026-09-04): the `s/86400 *
    86400` round trip is EXACT for all but **7** of them, and the seven are
    11, 22, 29, 44, 58, 61 and 85. `TIME(0,0,11)` is `11/86400`, and
    multiplying back gives **10.999999999999998** — so a truncating kernel
    answers `SECOND(...)` = 10. Every other second in the first two minutes is
    exact, 59 included.

    ⛔ THAT SPARSENESS IS THE HAZARD AND IT IS WHY THIS PARAGRAPH NAMES ACTUAL
    NUMBERS. A test written around 59 (the plausible-looking boundary) or
    around 13:30:45 stays GREEN through a truncating implementation; the first
    revision of `test_SECOND_rounds_to_the_nearest_second` did exactly that,
    and an armed truncation mutant passed it. Assert 11.

    ⚠ AND THE ROUND CAN CARRY TO A FULL DAY. A serial whose fraction rounds up
    to 86400 seconds is midnight of the NEXT day, so the result is 0 rather
    than an hour of 24."""
    var frac = serial - floor(serial)
    var total = floor(frac * _SECONDS_PER_DAY + 0.5)
    if total >= _SECONDS_PER_DAY:
        return 0
    return Int(total)


def xl_time(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TIME(hour, minute, second)` — the FRACTION of a day, in [0, 1).

    ★ IT IS A PURE FUNCTION OF THREE ARGUMENTS AND READS NOTHING. That is why
    it landed while the record said it could not: it PRODUCES a fraction, it
    does not consume one, and no clock is involved at any point.

    ⚠ IT WRAPS AT 24 HOURS RATHER THAN REFUSING, WHICH IS EXCEL'S RULE:
    `TIME(27, 0, 0)` is 03:00, i.e. 0.125, not `#NUM!`. Minutes and seconds
    beyond their ranges carry upward first — `TIME(0, 90, 0)` is 01:30 — so the
    wrap is applied ONCE, to the total, and not per field.

    ⚠ A NEGATIVE COMPONENT IS `#NUM!`. Excel refuses each field below zero
    rather than borrowing from the one above it, so `TIME(1, -30, 0)` is an
    error and NOT 00:30.

    ⚠ THE RESULT IS A BARE FRACTION WITH NO DATE PART, which is Excel's own
    answer and is why `TIME(13,30,0) + DATE(2026,1,1)` is the composition that
    builds a timestamp. A kernel that added `today_serial` would be a different
    and more useful function that is not `TIME`."""
    var h = _num(args, 0)
    if h.is_error():
        return h^
    var m = _num(args, 1)
    if m.is_error():
        return m^
    var sec = _num(args, 2)
    if sec.is_error():
        return sec^
    if h.num < 0.0 or m.num < 0.0 or sec.num < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    # Excel truncates each field to an integer before summing.
    var total = (
        floor(h.num) * 3600.0 + floor(m.num) * 60.0 + floor(sec.num)
    )
    var day_seconds = total - floor(total / _SECONDS_PER_DAY) * _SECONDS_PER_DAY
    return FormulaValue.number(day_seconds / _SECONDS_PER_DAY)


def xl_hour(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`HOUR(serial)` — 0..23, from the serial's FRACTIONAL part.

    ⚠ DIVERGENCE THAT IS `NOW`'s AND NOT THIS KERNEL'S: `HOUR(NOW())` is 0
    here, because this engine has no clock and `SemanticsProfile` captures one
    INTEGER serial at bind time, so `NOW()` is always midnight. `NOW`'s own
    census row has said so since it landed. `HOUR` of any OTHER value —
    `HOUR(TIME(13,30,0))` is 13, `HOUR(0.75)` is 18 — is exact.

    A negative serial is `#NUM!`, as it is for every date function here."""
    var s = _num(args, 0)
    if s.is_error():
        return s^
    if s.num < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(Float64(_time_of_day_seconds(s.num) // 3600))


def xl_minute(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`MINUTE(serial)` — 0..59. Same fraction, same rounding; see
    `_time_of_day_seconds` for why the rounding is load-bearing."""
    var s = _num(args, 0)
    if s.is_error():
        return s^
    if s.num < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(
        Float64((_time_of_day_seconds(s.num) // 60) % 60)
    )


def xl_second(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SECOND(serial)` — 0..59.

    ⚠ THIS IS THE ONE WHERE THE ROUNDING IS VISIBLE. `SECOND(TIME(0,0,59))`
    must be 59; the exact binary64 product is 58.999999999999993, so a
    truncating implementation answers 58 and every test built from whole
    minutes stays green through it."""
    var s = _num(args, 0)
    if s.is_error():
        return s^
    if s.num < 0.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(Float64(_time_of_day_seconds(s.num) % 60))


# =============================================================================
# ★ ISOWEEKNUM — the ONE week-numbering rule that has no options.
# =============================================================================
def xl_isoweeknum(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ISOWEEKNUM(date)` — the ISO 8601 week number, 1..53.

    ★ IT IS HERE AND `WEEKNUM` IS NOT, AND THAT IS THE WHOLE REASON FOR THE
    SPLIT. Excel's `WEEKNUM` has **ten** `return_type` values selecting which
    day starts the week and whether week 1 is the one containing Jan 1 or the
    one containing the first Thursday. A kernel serving the default and
    refusing the rest is a surface no sheet can rely on, and `_weekday_note`
    already records what happens when a multi-return-type function is served at
    one return type. `ISOWEEKNUM` has exactly one definition and no options, so
    it can be right rather than partially right.

    ⚠⚠ THE WEEK BELONGS TO THE YEAR OF ITS **THURSDAY**, which is the entire
    ISO rule and the only thing an implementation can get wrong. 2027-01-01 is
    a Friday, so its week's Thursday falls in 2026 and the answer is week 53 of
    2026 — NOT week 1. An implementation that divided the day-of-year by 7
    returns 1 and is wrong for a few days at each end of most years: a plausible
    small integer, on a handful of dates nobody has in a fixture.

    ⚠ IT GOES THROUGH THE CALENDAR RATHER THAN THE SERIAL, for the same reason
    `WEEKDAY` does: Excel's serial 60 is the phantom 1900-02-29, so the
    serial-to-weekday relation is not a fixed modulus across it.

    A serial below 1 is `#NUM!`."""
    var s = _num(args, 0)
    if s.is_error():
        return s^
    if s.num < 1.0:
        return FormulaValue.error(XL_ERR_NUM)
    var ymd = _serial_to_ymd(Int(s.num))
    var days = _days_from_civil(ymd.y, ymd.m, ymd.d)
    # 1970-01-01 is a THURSDAY, so `days == 0` must map to 4 under Mon=1..Sun=7.
    var dow = ((days + 3) % 7 + 7) % 7 + 1
    # The Thursday of this ISO week decides which year the week belongs to.
    var thursday = days + (4 - dow)
    var ty = _civil_from_days(thursday)
    var jan1 = _days_from_civil(ty.y, 1, 1)
    return FormulaValue.number(Float64((thursday - jan1) // 7 + 1))

# =============================================================================
# ⭐⭐ THE 2026-09-14 DATE TRANCHE — DAYS360 / TIMEVALUE / DATEVALUE.
# =============================================================================
def xl_days360(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DAYS360(start, end, [method])` — days between two dates on a 360-day
    year of twelve 30-day months.

    ⛔⛔ THERE ARE TWO METHODS AND THEY DISAGREE ON REAL DATES, so a kernel
    that served one and ignored the argument returns a CONFIDENT WRONG INTEGER.
    `method` FALSE/omitted is US (NASD); TRUE is EUROPEAN. Three inputs where
    they differ, all carried as VALUE cells:

        DAYS360("2026-01-15","2026-03-31")   US 76   EUROPEAN 75
        DAYS360("2026-01-31","2026-02-28")   US 30   EUROPEAN 28
        DAYS360("2026-02-28","2026-03-31")   US 30   EUROPEAN 32

    ★ THE RULE IMPLEMENTED IS MICROSOFT'S DOCUMENTED ONE, VERBATIM, because
    there is no live Excel to check against from here and a plausible
    reconstruction is exactly what this effort exists to stop:

      US (NASD) — "If the starting date is the last day of a month, it becomes
        equal to the 30th day of the same month. If the ending date is the last
        day of a month AND the starting date is earlier than the 30th day of a
        month, the ending date becomes equal to the 1st day of the next month;
        otherwise the ending date becomes equal to the 30th day of the same
        month."
      EUROPEAN — "Starting dates and ending dates that occur on the 31st day of
        a month become equal to the 30th day of the same month."

    ⛔ SO THE TWO RULES ARE NOT "CLAMP EVERYTHING TO 30". Three differences a
    clamping kernel erases: US says LAST DAY OF A MONTH (so 28 February counts
    and European's 31-only test does not), US's end-date adjustment READS the
    already-adjusted start day, and US can push the end date into the NEXT
    MONTH — an adjustment that ADDS days where every other clause removes them.

    ⚠ "the 1st day of the next month" AND "leave the day at 31" ARE THE SAME
    NUMBER in the (y,m,d) formula below, and it is written the documented way
    anyway: a reader checking this against Microsoft's page must find
    Microsoft's sentence, not an algebraic equivalent they have to re-derive.

    ⚠ IT IS A SIGNED DIFFERENCE. `DAYS360(end, start)` is the negative, not an
    error and not the absolute value."""
    var a = _num(args, 0)
    if a.is_error():
        return a^
    var b = _num(args, 1)
    if b.is_error():
        return b^
    var european = False
    if len(args) >= 3:
        var m = args[2].coerce_logical()
        if m.is_error():
            return m^
        european = m.logical
    var s1 = Int(floor(a.num))
    var s2 = Int(floor(b.num))
    if s1 < 0 or s2 < 0:
        return FormulaValue.error(XL_ERR_NUM)
    var p = _serial_to_ymd(s1)
    var q = _serial_to_ymd(s2)
    var y1 = p.y
    var m1 = p.m
    var d1 = p.d
    var y2 = q.y
    var m2 = q.m
    var d2 = q.d
    if european:
        if d1 == 31:
            d1 = 30
        if d2 == 31:
            d2 = 30
    else:
        if d1 == _days_in_month(y1, m1):
            d1 = 30
        if d2 == _days_in_month(y2, m2):
            if d1 < 30:
                # "the 1st day of the NEXT month" — the one adjustment in
                # either method that moves the MONTH and not just the day.
                d2 = 1
                m2 += 1
                if m2 == 13:
                    m2 = 1
                    y2 += 1
            else:
                d2 = 30
    var days = (y2 - y1) * 360 + (m2 - m1) * 30 + (d2 - d1)
    return FormulaValue.number(Float64(days))


def _digits_at(imm t: String, start: Int, n: Int) -> Int:
    """`n` ASCII digits of `t` at byte `start`, or -1 if any byte is not one.

    ⚠ -1 AND NOT AN EXCEPTION: every caller turns it into `#VALUE!`, which is
    what Excel answers for text it cannot read as a date.

    ⚠ TAKES THE `String` AND NOT ITS BYTES because a `Span` parameter needs an
    origin this leaf module has no reason to name; the slices here are at most
    four bytes."""
    var b = t.as_bytes()
    var v = 0
    for i in range(start, start + n):
        if i >= len(b):
            return -1
        var c = Int(b[i])
        if c < 48 or c > 57:
            return -1
        v = v * 10 + (c - 48)
    return v


def xl_timevalue(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TIMEVALUE(time_text)` — a time STRING to the fraction of a day.

    ⚠ `HH:MM` AND `HH:MM:SS` ONLY, 24-HOUR, AND THE NARROWING IS DELIBERATE.
    Excel also reads `1:30 PM` and whatever the system locale's time separator
    is; both of those are LOCALE state this engine does not carry, and a kernel
    that guessed would read `1:30` as 13:30 for one user and 01:30 for another.
    ⛔ A `#VALUE!` FOR A FORM WE CANNOT READ IS THE HONEST ANSWER; a plausible
    number for the wrong reading is not. See `_timevalue_note`.

    ⚠ THE RESULT HAS NO DATE PART — `TIMEVALUE("13:30")` is 0.5625 exactly,
    the same value `TIME(13,30,0)` produces, which is what makes the two
    cross-checkable.

    ⚠ HOURS ABOVE 23 ARE `#VALUE!` HERE. `TIME(27,0,0)` WRAPS, deliberately,
    because it is doing arithmetic; this one is PARSING a clock reading, and
    `"27:00"` is not one."""
    if len(args) == 0:
        return FormulaValue.error(XL_ERR_VALUE)
    if args[0].is_error():
        return args[0].copy()
    if not args[0].is_text():
        return FormulaValue.error(XL_ERR_VALUE)
    var txt = args[0].text.copy()
    var b = txt.as_bytes()
    if len(b) != 5 and len(b) != 8:
        return FormulaValue.error(XL_ERR_VALUE)
    if b[2] != UInt8(ord(":")):
        return FormulaValue.error(XL_ERR_VALUE)
    var hh = _digits_at(txt, 0, 2)
    var mm = _digits_at(txt, 3, 2)
    if hh < 0 or mm < 0 or hh > 23 or mm > 59:
        return FormulaValue.error(XL_ERR_VALUE)
    var ss = 0
    if len(b) == 8:
        if b[5] != UInt8(ord(":")):
            return FormulaValue.error(XL_ERR_VALUE)
        ss = _digits_at(txt, 6, 2)
        if ss < 0 or ss > 59:
            return FormulaValue.error(XL_ERR_VALUE)
    var total = Float64(hh) * 3600.0 + Float64(mm) * 60.0 + Float64(ss)
    return FormulaValue.number(total / _SECONDS_PER_DAY)


def xl_datevalue(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DATEVALUE(date_text)` — a date STRING to an Excel 1900 serial.

    ⚠⚠ ISO `YYYY-MM-DD` ONLY, AND THAT IS A NARROWING WITH A REASON RATHER
    THAN AN OMISSION. Excel's DATEVALUE reads whatever the SYSTEM LOCALE calls
    a date, so `"03/04/2026"` is 4 March in the UK and 3 April in the US — the
    SAME STRING, two different serials, 30 days apart, neither an error. This
    engine carries no locale, so serving `MM/DD/YYYY` would be picking one
    country's answer for everybody and would look right in every US fixture.
    ⛔ ISO 8601 IS THE ONE SPELLING THAT IS UNAMBIGUOUS IN EVERY LOCALE, so it
    is the one spelling served; every other form is `#VALUE!`. See
    `_datevalue_note`.

    ⚠ THE RESULT IS THE **1900-SERIAL**, LOTUS BUG INCLUDED, because that is
    what every other date function in this engine consumes:
    `DATEVALUE("1900-03-01")` is 61, not 60. A kernel that computed a true
    proleptic day count would be off by one against `DATE(1900,3,1)` — the two
    would disagree about the same day, silently.

    ⚠ THE DATE MUST BE REAL. `"2026-02-30"` is `#VALUE!` and NOT a rolled-over
    2026-03-02, which is what `DATE(2026,2,30)` deliberately returns. DATE does
    ARITHMETIC (and Excel documents the rollover); this READS a written date,
    and a written 30 February is a typo."""
    if len(args) == 0:
        return FormulaValue.error(XL_ERR_VALUE)
    if args[0].is_error():
        return args[0].copy()
    if not args[0].is_text():
        return FormulaValue.error(XL_ERR_VALUE)
    var txt = args[0].text.copy()
    var b = txt.as_bytes()
    if len(b) != 10:
        return FormulaValue.error(XL_ERR_VALUE)
    if b[4] != UInt8(ord("-")) or b[7] != UInt8(ord("-")):
        return FormulaValue.error(XL_ERR_VALUE)
    var y = _digits_at(txt, 0, 4)
    var m = _digits_at(txt, 5, 2)
    var d = _digits_at(txt, 8, 2)
    if y < 0 or m < 0 or d < 0:
        return FormulaValue.error(XL_ERR_VALUE)
    # ⚠ EXCEL'S SERIAL SPACE STARTS AT 1900-01-01. A year below 1900 has no
    # serial at all, and answering a negative one would be a number where the
    # sheet has none.
    if y < 1900 or y > 9999 or m < 1 or m > 12:
        return FormulaValue.error(XL_ERR_VALUE)
    if d < 1 or d > _days_in_month(y, m):
        return FormulaValue.error(XL_ERR_VALUE)
    return FormulaValue.number(Float64(_date_to_serial(y, m, d)))


# =============================================================================
# =============================================================================
def xl_eastersunday(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`EASTERSUNDAY(year)` — the serial of Easter Sunday in the GREGORIAN
    computus. Defined by ODF OpenFormula and by OOXML; Microsoft's worksheet
    function list does not contain it.

    ⛔ IT IS NOT A FIXED OFFSET FROM ANYTHING AND NOT A TABLE LOOKUP. The
    lunisolar computus moves it between 22 March and 25 April, so two adjacent
    years are the discriminating pair: 2026 is 5 April and 2027 is 28 March —
    a step BACKWARD of 8 days, which no `base + k` kernel can produce.

    ⚠ THE TWO-DIGIT SHORTHAND IS PART OF THE SPEC: a `year` in 0..99 means
    1900..1999, so `EASTERSUNDAY(26)` is 1926 and not year 26.

    ⚠ A YEAR WHOSE EASTER PREDATES 1900-01-01 IS `#NUM!`, because that is
    where this door's serial origin is. The computus itself is Gregorian from
    1583 and this kernel would compute it; what cannot be REPRESENTED is the
    serial, so the refusal is about the carrier and says so rather than
    pretending the mathematics stops."""
    var yv = _num(args, 0)
    if yv.is_error():
        return yv^
    var yf = floor(yv.num)
    if yf >= 0.0 and yf <= 99.0:
        yf += 1900.0
    if yf < 1583.0 or yf > 9956.0:
        return FormulaValue.error(XL_ERR_NUM)
    var y = Int(yf)
    # The anonymous Gregorian computus (Meeus/Jones/Butcher).
    var a = y % 19
    var b = y // 100
    var c = y % 100
    var d = b // 4
    var e = b % 4
    var f = (b + 8) // 25
    var g = (b - f + 1) // 3
    var h = (19 * a + b - d - g + 15) % 30
    var i = c // 4
    var k = c % 4
    var el = (32 + 2 * e + 2 * i - h - k) % 7
    var m = (a + 11 * h + 22 * el) // 451
    var t = h + el - 7 * m + 114
    var month = t // 31
    var day = (t % 31) + 1
    var serial = _date_to_serial(y, month, day)
    if serial < 1:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(Float64(serial))

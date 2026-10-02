# =============================================================================
# test_xl_date_serial.mojo — ★ THE FIRST EXECUTABLE ASSERTION THIS TREE HAS EVER
#                              HAD ABOUT THE 1900 SERIAL ARITHMETIC.
# =============================================================================
#
# ⛔⛔ THE SUBJECT IS A DELIBERATE BUG. Lotus 1-2-3 treated 1900 as a leap year;
# Excel reproduces it for compatibility:
#
#     serial 59 = 1900-02-28
#     serial 60 = 1900-02-29   ⛔ A DAY THAT NEVER EXISTED
#     serial 61 = 1900-03-01
#
# So every date at or after 1900-03-01 is shifted +1 against the true proleptic
# Gregorian count. An implementation that "fixes" the bug is off by one for
# EVERY MODERN DATE — the failure is not at the boundary, it is everywhere
# after it — and until this file there was nothing that could say so.
#
# ⚠ NO `EngineContext`, NO FILE, NO FIXTURE: welded to `komira_xl_plan`, which
# downstream bindings link.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.plan.excel_error_code import XL_ERR_NUM, XL_ERR_VALUE

from komira_xl_plan.formula_value import FormulaValue
from komira_xl_plan.xl_date_serial import (
    _date_to_serial,
    _serial_to_ymd,
    _days_in_month,
    _leap,
)
from komira_xl_plan.xl_scalar_date import (
    xl_now,
    xl_weekday,
    xl_edate,
    xl_days,
)


def _n(v: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(v))
    return a^


def _nn(a0: Float64, a1: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(a0))
    a.append(FormulaValue.number(a1))
    return a^


def _assert_num(r: FormulaValue, want: Float64, why: String) raises:
    assert_true(r.is_number(), why + " — got `" + r.render() + "`")
    assert_equal(r.num, want, why)


# =============================================================================
# ★★ THE LOTUS PHANTOM DAY
# =============================================================================


def test_the_1900_phantom_leap_day_is_REPRODUCED_not_fixed() raises:
    """★ THE THREE SERIALS THAT PIN IT. Serial 60 must be 1900-02-29 — a date
    that does not exist in any calendar — and 61 must be 1900-03-01. An
    implementation that skipped the phantom day would map 60 to 1900-03-01 and
    61 to 1900-03-02, and would then be off by one for every date after it."""
    var d59 = _serial_to_ymd(59)
    assert_equal(d59.y, 1900)
    assert_equal(d59.m, 2)
    assert_equal(d59.d, 28, "serial 59 is 1900-02-28")

    var d60 = _serial_to_ymd(60)
    assert_equal(d60.y, 1900)
    assert_equal(d60.m, 2)
    assert_equal(
        d60.d, 29,
        "★ serial 60 must be the PHANTOM 1900-02-29. A calendar-correct answer"
        " here (1900-03-01) means the Lotus bug was 'fixed', which shifts every"
        " modern date by one against Excel",
    )

    var d61 = _serial_to_ymd(61)
    assert_equal(d61.y, 1900)
    assert_equal(d61.m, 3)
    assert_equal(d61.d, 1, "serial 61 is 1900-03-01")


def test_a_modern_date_round_trips_and_carries_the_plus_one_shift() raises:
    """★ THE SHIFT IS NOT LOCAL TO 1900 — it is carried forward forever, which
    is why the phantom day matters at all. `2026-09-04` is Excel serial 46269;
    a phantom-free implementation would answer 46268.

    ⚠ THE ROUND TRIP ALONE IS NOT ENOUGH and would be green under BOTH: a
    consistent off-by-one round-trips perfectly. The LITERAL is the oracle.

    ⚠⚠ AND THE LITERAL CAME FROM AN INDEPENDENT COMPUTATION, NOT FROM THIS
    ENGINE — Python's `datetime`, `(date(2026,9,4) - date(1899,12,31)).days + 1`
    for a date at or after 1900-03-01. The first revision of this line said
    46265, which was a GUESS; the test went RED and the ENGINE was right. That
    is the oracle working in the direction that matters, and it is why a
    transcribed number would have been worthless here."""
    var s = _date_to_serial(2026, 9, 4)
    assert_equal(
        s, 46269,
        "★ 2026-09-04 is Excel serial 46269. 46268 means the phantom day is"
        " missing and every modern date is one short",
    )
    var back = _serial_to_ymd(s)
    assert_equal(back.y, 2026)
    assert_equal(back.m, 9)
    assert_equal(back.d, 4)


def test_the_first_and_last_pre_bug_serials_are_unshifted() raises:
    """Before 1900-03-01 there is no shift, so serial 1 is 1900-01-01. A
    blanket +1 would put it at 1899-12-31."""
    assert_equal(_date_to_serial(1900, 1, 1), 1)
    var d1 = _serial_to_ymd(1)
    assert_equal(d1.y, 1900)
    assert_equal(d1.m, 1)
    assert_equal(d1.d, 1)


def test_leap_and_month_length_agree_on_the_century_rule() raises:
    """1900 is NOT a leap year (divisible by 100, not by 400) — which is the
    whole reason serial 60 is a bug — and 2000 IS."""
    assert_false(_leap(1900), "1900 is not a leap year in any real calendar")
    assert_true(_leap(2000), "2000 is, by the 400 rule")
    assert_true(_leap(2024))
    assert_equal(_days_in_month(1900, 2), 28, "the REAL February 1900")
    assert_equal(_days_in_month(2000, 2), 29)
    assert_equal(_days_in_month(2026, 4), 30)


# =============================================================================
# ★★ WEEKDAY — three return types
# =============================================================================


def test_weekday_serves_all_three_return_types() raises:
    """★ 2026-09-04 IS A FRIDAY. The three types disagree on both the origin
    and the first day, so a kernel serving only the default is wrong for two
    thirds of callers — and all three land on ONE known date here, which is
    what makes the disagreement visible."""
    var friday = Float64(_date_to_serial(2026, 9, 4))
    _assert_num(xl_weekday(_n(friday)), 6.0, "type 1 (default): Sun=1, so Friday=6")
    _assert_num(xl_weekday(_nn(friday, 1.0)), 6.0, "type 1 explicitly")
    _assert_num(xl_weekday(_nn(friday, 2.0)), 5.0, "type 2: Mon=1, so Friday=5")
    _assert_num(xl_weekday(_nn(friday, 3.0)), 4.0, "type 3: Mon=0, so Friday=4")


def test_weekday_is_right_on_BOTH_SIDES_of_the_phantom_day() raises:
    """★★ THE ASSERTION `serial % 7` CANNOT PASS. 1900-02-28 was a Wednesday
    and 1900-03-01 was a Thursday — ONE real day apart — but their serials are
    59 and 61, TWO apart. A modulus over the serial makes them two weekdays
    apart; going through the calendar makes them one."""
    _assert_num(xl_weekday(_n(59.0)), 4.0, "1900-02-28 was a WEDNESDAY (Sun=1)")
    _assert_num(
        xl_weekday(_n(61.0)), 5.0,
        "★ 1900-03-01 was a THURSDAY — ONE weekday after serial 59, though the"
        " serials are TWO apart. A `serial % 7` kernel answers Friday here",
    )


def test_weekday_refuses_an_unknown_return_type_and_a_bad_serial() raises:
    """A return_type outside {1,2,3} is `#NUM!` in Excel — not a silent fall
    back to the default, which would answer a question nobody asked."""
    var friday = Float64(_date_to_serial(2026, 9, 4))
    var r = xl_weekday(_nn(friday, 4.0))
    assert_true(r.is_error() and r.error_code == XL_ERR_NUM, "type 4 is #NUM!")
    var z = xl_weekday(_n(0.0))
    assert_true(z.is_error() and z.error_code == XL_ERR_NUM, "serial 0 is #NUM!")


# =============================================================================
# ★★ EDATE — the clamp
# =============================================================================


def test_edate_CLAMPS_the_day_instead_of_rolling_it_over() raises:
    """★ THE ONE INPUT THAT SEPARATES THE TWO IMPLEMENTATIONS. Jan 31 + 1 month
    is Feb 28, not Mar 3. The serial builder is linear day arithmetic and rolls
    an overflow FORWARD, so an unclamped EDATE lands a MONTH later than asked —
    a plausible date, silently wrong."""
    var jan31 = Float64(_date_to_serial(2026, 1, 31))
    var got = xl_edate(_nn(jan31, 1.0))
    assert_true(got.is_number(), "EDATE must return a serial")
    var ymd = _serial_to_ymd(Int(got.num))
    assert_equal(ymd.y, 2026)
    assert_equal(ymd.m, 2, "★ ONE month later is FEBRUARY. March means the day overflowed")
    assert_equal(ymd.d, 28, "clamped to February's last day")


def test_edate_clamps_into_a_LEAP_February_too() raises:
    """The clamp reads the TARGET month's length, so 2024 gives 29 where 2026
    gives 28 — a hardcoded 28 would pass the test above and fail here."""
    var jan31 = Float64(_date_to_serial(2024, 1, 31))
    var ymd = _serial_to_ymd(Int(xl_edate(_nn(jan31, 1.0)).num))
    assert_equal(ymd.m, 2)
    assert_equal(ymd.d, 29, "2024 is a leap year, so the clamp is 29 not 28")


def test_edate_goes_BACKWARDS_and_crosses_a_year_boundary() raises:
    """Negative months are Excel's behaviour; the floor-division normalisation
    is what makes a negative month index land in the previous YEAR rather than
    at month 0 or -1."""
    var mar15 = Float64(_date_to_serial(2026, 3, 15))
    var ymd = _serial_to_ymd(Int(xl_edate(_nn(mar15, -4.0)).num))
    assert_equal(ymd.y, 2025, "four months before March 2026 is November 2025")
    assert_equal(ymd.m, 11)
    assert_equal(ymd.d, 15)


# =============================================================================
# DAYS / NOW
# =============================================================================


def test_days_is_end_minus_start_in_that_order() raises:
    """★ THE ARGUMENT ORDER IS THE REVERSE OF WHAT MOST PEOPLE WRITE FIRST, so
    the negative case is the assertion: swapped arguments give -N, not N."""
    var a = Float64(_date_to_serial(2026, 9, 4))
    var b = Float64(_date_to_serial(2026, 9, 1))
    _assert_num(xl_days(_nn(a, b)), 3.0, "DAYS(end, start) is end - start")
    _assert_num(
        xl_days(_nn(b, a)), -3.0,
        "★ swapped, it must be NEGATIVE — an abs() here would hide the order",
    )


def test_days_subtracts_SERIALS_across_the_phantom_day_as_excel_does() raises:
    """⚠ A DELIBERATE DISAGREEMENT WITH THE CALENDAR, and Excel's. 1900-03-01
    is ONE real day after 1900-02-28, but their serials are 61 and 59, so
    `DAYS` answers 2. Excel answers 2 as well. Asserting the calendar-correct 1
    here would make this engine disagree with the thing it emulates."""
    _assert_num(
        xl_days(_nn(61.0, 59.0)), 2.0,
        "DAYS subtracts serials, so the phantom day is counted — as in Excel",
    )


def test_now_is_the_captured_serial_and_refuses_when_uncaptured() raises:
    """★ NO CLOCK, SO NO GUESS. The captured value is an ARGUMENT here rather
    than ambient state, which is both what keeps the kernel out of the evaluator and what makes this assertion possible at all."""
    _assert_num(xl_now(46269), 46269.0, "NOW returns the captured serial (46269 = 2026-09-04)")
    var un = xl_now(0)
    assert_true(
        un.is_error() and un.error_code == XL_ERR_VALUE,
        "an UNCAPTURED serial is #VALUE!, never a guess at today's date",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# komira_job_supervisor/tests/test_clock_helper_negative_era.mojo
#   `_civil_from_days` and `utc_stamp_from_unix_ms` give the proleptic
#   Gregorian date for days before 0000-03-01 too.
# =============================================================================
#
# Hinnant's C++ `civil_from_days` computes the era with truncating division
# and subtracts 146096 from a negative shifted day count to round it toward
# negative infinity. Mojo's `//` already floors, so keeping that adjustment
# applies it twice: every day before 0000-02-29 came out one day late
# (komira-ai/komira#1240). This test catches that defect and any other
# off-by-one in the era arithmetic:
#   * anchor days on both sides of 0000-03-01 and in year -0001;
#   * the stamp of 0000-01-01T00:00:00Z and of 0000-02-28T23:59:59.999Z;
#   * a day-by-day sweep from 1970-01-01 back to -0401-01-01 against a
#     calendar this test counts itself (leap rule only, no era arithmetic),
#     whose end must land on the day number worked out by hand.
# =============================================================================

from std.testing import assert_equal

from komira_job_supervisor.clock_helper import (
    _civil_from_days,
    utc_stamp_from_unix_ms,
)


def _ymd(days: Int) -> String:
    var t = _civil_from_days(days)
    return String(t[0]) + "-" + String(t[1]) + "-" + String(t[2])


def test_anchor_days() raises:
    assert_equal(_ymd(0), "1970-1-1")
    assert_equal(_ymd(-719468), "0-3-1")
    assert_equal(_ymd(-719469), "0-2-29")
    assert_equal(_ymd(-719470), "0-2-28")
    assert_equal(_ymd(-719528), "0-1-1")
    assert_equal(_ymd(-719529), "-1-12-31")
    assert_equal(_ymd(-719893), "-1-1-1")


def test_stamps_before_0000_03_01() raises:
    # 0000-01-01T00:00:00Z: -719528 days.
    assert_equal(
        utc_stamp_from_unix_ms(Int64(-719528) * 86400000),
        "00000101T000000Z",
    )
    # 0000-02-28T23:59:59.999Z: one millisecond before 0000-02-29.
    assert_equal(
        utc_stamp_from_unix_ms(Int64(-719469) * 86400000 - 1),
        "00000228T235959Z",
    )


def _is_leap(y: Int) -> Bool:
    # Mojo's `%` floors, so this holds for negative years too.
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def _month_len(y: Int, m: Int) -> Int:
    if m == 2:
        return 29 if _is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def test_day_by_day_back_to_minus_0401() raises:
    var y = 1970
    var m = 1
    var d = 1
    var day = 0
    while True:
        var got = _civil_from_days(day)
        if got[0] != y or got[1] != m or got[2] != d:
            assert_equal(
                _ymd(day),
                String(y) + "-" + String(m) + "-" + String(d),
                String("day ") + String(day),
            )
        if y == -401 and m == 1 and d == 1:
            break
        # Step the counted calendar back one day.
        day -= 1
        d -= 1
        if d == 0:
            m -= 1
            if m == 0:
                m = 12
                y -= 1
            d = _month_len(y, m)
    # 400 Gregorian years are 146097 days: -0400-01-01 is 0000-01-01
    # (-719528) minus 146097, and -0401 is a common year.
    assert_equal(day, -719528 - 146097 - 365)


def main() raises:
    print("test_clock_helper_negative_era:")
    test_anchor_days()
    test_stamps_before_0000_03_01()
    test_day_by_day_back_to_minus_0401()
    print("test_clock_helper_negative_era: ALL PASS")

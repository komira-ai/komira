# =============================================================================
# test_jsonl_date32_negative_era.mojo -- DATE32 days before 0000-03-01
# =============================================================================
#
# Refs #1114. `write_date32` (through `_civil_from_days`) wrote every day
# before 0000-02-29 one day late: the era of a day before 0000-03-01 was
# computed with the C++ truncating-division adjustment on top of Mojo's
# flooring `//`, one era too low. `_days_from_civil` in `parse_date` had the
# same shape for years before -0001 (unreachable through `parse_date32`,
# which reads four-digit years only).
#
#   * test_anchor_days -- fixed days around the shifted epoch 0000-03-01 and
#     year -0001, written out here. Before the fix 0000-01-01 wrote
#     "0000-01-02" and 0000-02-28 wrote "0000-02-29".
#   * test_sweep_negative_years -- every day of -0401-01-01 .. 0001-12-31
#     against a day-by-day calendar counted here (month lengths, the
#     4/100/400 rule on proleptic years: -0400 and 0000 leap, -0100 not),
#     and `_days_from_civil` of each date back to the same day number. The
#     first day is the day count of 0000-01-01 minus the year lengths of
#     -0401 .. -0001, counted here too.
#   * test_round_trip_int32_range -- `_civil_from_days` then
#     `_days_from_civil` returns the same day for Int32 min and max and a
#     stride across the whole Int32 range, and each month and day is in
#     range.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_jsonl.json_writer import _civil_from_days, write_date32
from komira_jsonl.value_parsers.parse_date import _days_from_civil


def _text(buf: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(buf))


def _date(days: Int) -> String:
    var buf = List[UInt8]()
    write_date32(buf, Int32(days))
    return _text(buf)


def _is_leap(y: Int) -> Bool:
    # Mojo's `%` floors, so a negative multiple of 4 has remainder 0.
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


def _month_days(y: Int, m: Int) -> Int:
    if m == 2:
        return 29 if _is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _pad(v: Int, width: Int) -> String:
    var s = String(v)
    while s.byte_length() < width:
        s = "0" + s
    return s


def _iso(y: Int, m: Int, d: Int) -> String:
    var year = ("-" + _pad(-y, 4)) if y < 0 else _pad(y, 4)
    return '"' + year + "-" + _pad(m, 2) + "-" + _pad(d, 2) + '"'


def test_anchor_days() raises:
    assert_equal(_date(-719468), '"0000-03-01"')
    assert_equal(_date(-719469), '"0000-02-29"')
    assert_equal(_date(-719470), '"0000-02-28"')
    assert_equal(_date(-719528), '"0000-01-01"')
    assert_equal(_date(-719529), '"-0001-12-31"')
    assert_equal(_date(-719893), '"-0001-01-01"')
    assert_equal(_date(-719894), '"-0002-12-31"')
    assert_equal(_days_from_civil(0, 1, 1), -719528)
    assert_equal(_days_from_civil(-1, 1, 1), -719893)
    assert_equal(_days_from_civil(-2, 12, 31), -719894)


def test_sweep_negative_years() raises:
    var first_year = -401
    var day = -719528  # 0000-01-01
    for y in range(first_year, 0):
        day -= 366 if _is_leap(y) else 365
    var y = first_year
    var m = 1
    var d = 1
    while y < 2:
        assert_equal(_date(day), _iso(y, m, d), String(day))
        assert_equal(_days_from_civil(y, m, d), day, _iso(y, m, d))
        day += 1
        d += 1
        if d > _month_days(y, m):
            d = 1
            m += 1
            if m > 12:
                m = 1
                y += 1
    assert_equal(day, -719528 + 366 + 365)  # 0002-01-01


def _round_trip(z: Int) raises:
    var ymd = _civil_from_days(z)
    var m = ymd[1]
    var d = ymd[2]
    assert_true(m >= 1 and m <= 12, "month of day " + String(z))
    assert_true(d >= 1 and d <= _month_days(ymd[0], m), "day of " + String(z))
    assert_equal(_days_from_civil(ymd[0], m, d), z, String(z))


def test_round_trip_int32_range() raises:
    var lo = Int(Int32.MIN)
    var hi = Int(Int32.MAX)
    _round_trip(lo)
    _round_trip(hi)
    var z = lo
    while z <= hi:
        _round_trip(z)
        z += 999983


def main() raises:
    test_anchor_days()
    test_sweep_negative_years()
    test_round_trip_int32_range()
    print("test_jsonl_date32_negative_era: all passed")

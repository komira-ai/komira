# =============================================================================
# Tests for `temporal_extract`: the field extracts (year, month, day, quarter,
# hour, minute, second, the day-index family, the ISO week-date family and the
# sub-second family) over DATE32 and every TIMESTAMP_* unit.
#
# THE ORACLE IS THE TABLE BELOW, NOT THE KERNEL'S OWN ARITHMETIC. Every row's
# fields were worked out from the proleptic Gregorian calendar (a year is leap
# when divisible by 4, except centuries not divisible by 400; year 0 exists
# and is leap, ISO 8601 astronomical numbering) and the ISO 8601 week rules (a
# week starts on Monday and belongs to the year holding its Thursday). The AD
# rows were cross-checked against an established Gregorian implementation;
# the BC rows were moved forward by five 400-year cycles (5 * 146097 days, a
# whole number of weeks, so the calendar and the weekday repeat exactly) and
# checked the same way. Three of the BC rows are the ones the kernel's own
# documentation quotes as measured against DuckDB (isoyear -45 week 52
# yearweek -4552; isoyear -44 week 11 yearweek -4411; dayofyear 75).
#
# The unit codes passed to the day-index / ISO-week / sub-second kernels are
# the plan IR's own `EXTRACT_*` constants, imported from `komira_plan_expr`:
# the kernel mirrors those numbers, so a drifted mirror answers a wrong field
# here (or raises) instead of compiling quietly.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.testing import assert_raises

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    EXTRACT_DAYOFWEEK,
    EXTRACT_ISODOW,
    EXTRACT_DAYOFYEAR,
    EXTRACT_WEEK,
    EXTRACT_ISOYEAR,
    EXTRACT_YEARWEEK,
    EXTRACT_MILLISECOND,
    EXTRACT_MICROSECOND,
)
from komira_kernels.temporal_extract import (
    compose_yearweek,
    extract_year_date32,
    extract_month_date32,
    extract_day_date32,
    extract_quarter_date32,
    extract_subday_zero_date32,
    extract_year_ts,
    extract_month_ts,
    extract_day_ts,
    extract_quarter_ts,
    extract_hour_ts,
    extract_minute_ts,
    extract_second_ts,
    extract_day_index_date32,
    extract_day_index_ts,
    extract_iso_week_date32,
    extract_iso_week_ts,
    extract_subsecond_ts,
)


# -----------------------------------------------------------------------------
# The calendar table
# -----------------------------------------------------------------------------


@fieldwise_init
struct _Day(Copyable, Movable):
    """One calendar day and every field this file's kernels can extract."""

    var days: Int  # days since the epoch day 0 (negative before it)
    var y: Int
    var m: Int
    var d: Int
    var q: Int
    var dow: Int  # Sunday = 0 .. Saturday = 6
    var isodow: Int  # Monday = 1 .. Sunday = 7
    var doy: Int  # 1-based
    var isoyear: Int
    var week: Int
    var yearweek: Int


def _table() -> List[_Day]:
    var t = List[_Day]()
    # Day 0 is a Thursday: ISO week 1 of its own year.
    t.append(_Day(0, 1970, 1, 1, 1, 4, 4, 1, 1970, 1, 197001))
    # The day before: a Wednesday whose Thursday is day 0, so its ISO year
    # is one more than its civil year.
    t.append(_Day(-1, 1969, 12, 31, 4, 3, 3, 365, 1970, 1, 197001))
    # Day 60 of a year divisible by 400 (leap): month 2 has a 29th.
    t.append(_Day(11016, 2000, 2, 29, 1, 2, 2, 60, 2000, 9, 200009))
    # Day 366 of that leap year, a Sunday: dayofweek 0, isodow 7.
    t.append(_Day(11322, 2000, 12, 31, 4, 0, 7, 366, 2000, 52, 200052))
    # A century not divisible by 400 is common: month 3 day 1 is day 60.
    t.append(_Day(-25508, 1900, 3, 1, 1, 4, 4, 60, 1900, 9, 190009))
    # A January Saturday in ISO week 53 of the previous ISO year.
    t.append(_Day(12784, 2005, 1, 1, 1, 6, 6, 1, 2004, 53, 200453))
    # A December Monday in ISO week 1 of the next ISO year.
    t.append(_Day(14242, 2008, 12, 29, 4, 1, 1, 364, 2009, 1, 200901))
    # A third-quarter row.
    t.append(_Day(11184, 2000, 8, 15, 3, 2, 2, 228, 2000, 33, 200033))
    # Day 1 of a year that starts on a Saturday: ISO week 52 of the year
    # before.
    t.append(_Day(10957, 2000, 1, 1, 1, 6, 6, 1, 1999, 52, 199952))
    # The last day of months 1, 3 and 8 (31 days each): the month proxy
    # `(5 * doy + 2) // 153` sits one step below the next month here, so a
    # rounding change moves these rows to day 0 of the following month.
    t.append(_Day(10987, 2000, 1, 31, 1, 1, 1, 31, 2000, 5, 200005))
    t.append(_Day(11047, 2000, 3, 31, 1, 5, 5, 91, 2000, 13, 200013))
    t.append(_Day(11200, 2000, 8, 31, 3, 4, 4, 244, 2000, 35, 200035))
    # BC rows (astronomical numbering). A Sunday on day 1 of year -44,
    # whose Thursday lies in year -45: the week half of yearweek is negated
    # for a non-positive ISO year.
    t.append(_Day(-735599, -44, 1, 1, 1, 0, 7, 1, -45, 52, -4552))
    # Year -44 is leap (divisible by 4): month 3 day 15 is day 75.
    t.append(_Day(-735525, -44, 3, 15, 1, 4, 4, 75, -44, 11, -4411))
    # ISO year ZERO: `iso_y * 100` is 0, so the sign of the week half is
    # the whole answer (-15, not +15). A second-quarter row.
    t.append(_Day(-719428, 0, 4, 10, 2, 1, 1, 101, 0, 15, -15))
    # Day 1 of year 0, a Saturday: its Thursday is in year -1.
    t.append(_Day(-719528, 0, 1, 1, 1, 6, 6, 1, -1, 52, -152))
    return t^


# The table rows whose tick count fits Int64 in nanoseconds (the first twelve;
# the BC rows are past the roughly 292-year nanosecond range).
comptime _NS_ROWS = 12

# Every timestamp row is at hour 13, minute 45, second 30 of its day.
comptime _SOD = 13 * 3600 + 45 * 60 + 30


def _date32_with_null(t: List[_Day]) raises -> PrimitiveArray[DType.int32]:
    """The table's day counts with one NULL row inserted at index 2 and one
    appended: a null in the middle and a null at the end."""
    var n = len(t) + 2
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    var r = 0
    for i in range(n):
        if i == 2 or i == n - 1:
            arr.set(i, Scalar[DType.int32](Int32(777)))
            arr._set_null(i)
        else:
            arr.set(i, Scalar[DType.int32](Int32(t[r].days)))
            r += 1
    return arr^


def _row_of(i: Int, n: Int) -> Int:
    """The table index the array index `i` holds, or -1 for a NULL row."""
    if i == 2 or i == n - 1:
        return -1
    if i < 2:
        return i
    return i - 1


def _check_date32(
    res: PrimitiveArray[DType.int64], t: List[_Day], field: String
) raises:
    var n = res.length
    assert_equal(n, len(t) + 2)
    assert_equal(res.null_count, 2)
    for i in range(n):
        var r = _row_of(i, n)
        if r < 0:
            assert_true(res.is_null(i), field + ": null row stays null")
            assert_equal(Int(res.get(i)), 0, field + ": null data lane is 0")
            continue
        assert_false(res.is_null(i), field)
        var want: Int
        if field == "year":
            want = t[r].y
        elif field == "month":
            want = t[r].m
        elif field == "day":
            want = t[r].d
        elif field == "quarter":
            want = t[r].q
        elif field == "dow":
            want = t[r].dow
        elif field == "isodow":
            want = t[r].isodow
        elif field == "doy":
            want = t[r].doy
        elif field == "isoyear":
            want = t[r].isoyear
        elif field == "week":
            want = t[r].week
        else:
            want = t[r].yearweek
        assert_equal(
            Int(res.get(i)), want, field + " of day " + String(t[r].days)
        )


# -----------------------------------------------------------------------------
# DATE32
# -----------------------------------------------------------------------------


def test_date32_year_month_day_quarter() raises:
    var t = _table()
    var arr = _date32_with_null(t)
    _check_date32(extract_year_date32(arr), t, "year")
    _check_date32(extract_month_date32(arr), t, "month")
    _check_date32(extract_day_date32(arr), t, "day")
    _check_date32(extract_quarter_date32(arr), t, "quarter")


def _month_lengths(leap: Bool) -> List[Int]:
    """The Gregorian month lengths; month 2 has 29 days in a leap year."""
    var feb = 29 if leap else 28
    return [31, feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]


def _year_starts() -> List[Tuple[Int, Int, Bool]]:
    """(day count of day 1, year, leap): a 400-divisible leap year, a
    common century year, and a BC leap year."""
    var y = List[Tuple[Int, Int, Bool]]()
    y.append((10957, 2000, True))
    y.append((-25567, 1900, False))
    y.append((-735599, -44, True))
    return y^


def test_date32_every_day_of_three_years() raises:
    """Every day of three whole years against a walk over the month
    lengths: each first and last day of every month is a row, so a month
    boundary that moves by one day anywhere in the year is seen."""
    for ys in _year_starts():
        var start = ys[0]
        var lens = _month_lengths(ys[2])
        var n = 366 if ys[2] else 365
        var vals = List[Scalar[DType.int32]]()
        for i in range(n):
            vals.append(Int32(start + i))
        var arr = PrimitiveArray[DType.int32].from_list(vals)
        var ry = extract_year_date32(arr)
        var rm = extract_month_date32(arr)
        var rd = extract_day_date32(arr)
        var rq = extract_quarter_date32(arr)
        var rdoy = extract_day_index_date32(arr, EXTRACT_DAYOFYEAR)
        var i = 0
        for m in range(1, 13):
            for d in range(1, lens[m - 1] + 1):
                var what = "day " + String(start + i)
                assert_equal(Int(ry.get(i)), ys[1], what)
                assert_equal(Int(rm.get(i)), m, what)
                assert_equal(Int(rd.get(i)), d, what)
                assert_equal(Int(rq.get(i)), (m + 2) // 3, what)
                assert_equal(Int(rdoy.get(i)), i + 1, what)
                i += 1
        assert_equal(i, n)


def test_date32_day_index_family() raises:
    var t = _table()
    var arr = _date32_with_null(t)
    _check_date32(extract_day_index_date32(arr, EXTRACT_DAYOFWEEK), t, "dow")
    _check_date32(extract_day_index_date32(arr, EXTRACT_ISODOW), t, "isodow")
    _check_date32(extract_day_index_date32(arr, EXTRACT_DAYOFYEAR), t, "doy")


def test_date32_iso_week_family() raises:
    var t = _table()
    var arr = _date32_with_null(t)
    _check_date32(extract_iso_week_date32(arr, EXTRACT_WEEK), t, "week")
    _check_date32(extract_iso_week_date32(arr, EXTRACT_ISOYEAR), t, "isoyear")
    _check_date32(
        extract_iso_week_date32(arr, EXTRACT_YEARWEEK), t, "yearweek"
    )


def test_date32_subday_fields_are_zero_and_null_stays_null() raises:
    var t = _table()
    var arr = _date32_with_null(t)
    var res = extract_subday_zero_date32(arr)
    assert_equal(res.length, arr.length)
    assert_equal(res.null_count, 2)
    for i in range(res.length):
        assert_equal(Int(res.get(i)), 0)
        assert_equal(res.is_null(i), _row_of(i, res.length) < 0)


def test_date32_non_nullable_input_has_no_validity() raises:
    """An input with no validity bitmap gives an output with none: the
    clone is skipped, not an all-valid bitmap invented."""
    var vals = List[Scalar[DType.int32]]()
    vals.append(Int32(11016))
    vals.append(Int32(-735525))
    var arr = PrimitiveArray[DType.int32].from_list(vals)
    var res = extract_month_date32(arr)
    assert_false(Bool(res.validity))
    assert_equal(res.null_count, 0)
    assert_equal(Int(res.get(0)), 2)
    assert_equal(Int(res.get(1)), 3)
    var z = extract_subday_zero_date32(arr)
    assert_false(Bool(z.validity))
    assert_equal(Int(z.get(1)), 0)


def test_date32_empty_input() raises:
    var arr = PrimitiveArray[DType.int32].from_list(List[Scalar[DType.int32]]())
    assert_equal(extract_year_date32(arr).length, 0)
    assert_equal(extract_iso_week_date32(arr, EXTRACT_WEEK).length, 0)


def test_yearweek_sign_rule() raises:
    """`compose_yearweek` negates the week half for a non-positive ISO year:
    the kernel's documented, DuckDB-measured rule. Year 1 is the first
    positive year and keeps the week positive; year 0 is the row where the
    week half is the whole answer."""
    assert_equal(compose_yearweek(1, 1), 101)
    assert_equal(compose_yearweek(2020, 53), 202053)
    assert_equal(compose_yearweek(0, 52), -52)
    assert_equal(compose_yearweek(-1, 52), -152)
    assert_equal(compose_yearweek(-45, 52), -4552)


# -----------------------------------------------------------------------------
# TIMESTAMP_*
# -----------------------------------------------------------------------------


def _tps(unit: ArrowType) -> Int:
    if unit == ArrowType.TIMESTAMP_S:
        return 1
    if unit == ArrowType.TIMESTAMP_MS:
        return 1_000
    if unit == ArrowType.TIMESTAMP_NS:
        return 1_000_000_000
    return 1_000_000


def _frac(unit: ArrowType) -> Int:
    """The sub-second ticks every row carries: .123, .123456, .123456789
    seconds, in the unit's own ticks (none for seconds)."""
    if unit == ArrowType.TIMESTAMP_S:
        return 0
    if unit == ArrowType.TIMESTAMP_MS:
        return 123
    if unit == ArrowType.TIMESTAMP_NS:
        return 123_456_789
    return 123_456


def _rows_for(unit: ArrowType) -> Int:
    if unit == ArrowType.TIMESTAMP_NS:
        return _NS_ROWS
    return len(_table())


def _ts_with_null(t: List[_Day], unit: ArrowType) raises -> PrimitiveArray[DType.int64]:
    """Each row at 13:45:30 plus the unit's fraction, as ticks of `unit`,
    with NULL rows at index 2 and at the end."""
    var rows = _rows_for(unit)
    var n = rows + 2
    var tps = _tps(unit)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var r = 0
    for i in range(n):
        if i == 2 or i == n - 1:
            arr.set(i, Scalar[DType.int64](Int64(5)))
            arr._set_null(i)
        else:
            var ticks = (t[r].days * 86400 + _SOD) * tps + _frac(unit)
            arr.set(i, Scalar[DType.int64](Int64(ticks)))
            r += 1
    return arr^


def _check_ts(
    res: PrimitiveArray[DType.int64],
    t: List[_Day],
    field: String,
    const_want: Int,
) raises:
    """`const_want` is the answer for a time-of-day field (every row is at
    the same time of day); calendar fields read the table."""
    var n = res.length
    assert_equal(res.null_count, 2)
    for i in range(n):
        var r = _row_of(i, n)
        if r < 0:
            assert_true(res.is_null(i), field + ": null row stays null")
            assert_equal(Int(res.get(i)), 0, field + ": null data lane is 0")
            continue
        assert_false(res.is_null(i), field)
        var want = const_want
        if field == "year":
            want = t[r].y
        elif field == "month":
            want = t[r].m
        elif field == "day":
            want = t[r].d
        elif field == "quarter":
            want = t[r].q
        elif field == "dow":
            want = t[r].dow
        elif field == "isodow":
            want = t[r].isodow
        elif field == "doy":
            want = t[r].doy
        elif field == "isoyear":
            want = t[r].isoyear
        elif field == "week":
            want = t[r].week
        elif field == "yearweek":
            want = t[r].yearweek
        assert_equal(
            Int(res.get(i)), want, field + " of day " + String(t[r].days)
        )


def _units() -> List[ArrowType]:
    var u = List[ArrowType]()
    u.append(ArrowType.TIMESTAMP_S)
    u.append(ArrowType.TIMESTAMP_MS)
    u.append(ArrowType.TIMESTAMP_US)
    u.append(ArrowType.TIMESTAMP_NS)
    # The legacy alias reads as microseconds.
    u.append(ArrowType.TIMESTAMP)
    return u^


def test_ts_calendar_fields_every_unit() raises:
    var t = _table()
    for unit in _units():
        var arr = _ts_with_null(t, unit)
        _check_ts(extract_year_ts(arr, unit), t, "year", 0)
        _check_ts(extract_month_ts(arr, unit), t, "month", 0)
        _check_ts(extract_day_ts(arr, unit), t, "day", 0)
        _check_ts(extract_quarter_ts(arr, unit), t, "quarter", 0)


def test_ts_time_of_day_fields_every_unit() raises:
    var t = _table()
    for unit in _units():
        var arr = _ts_with_null(t, unit)
        _check_ts(extract_hour_ts(arr, unit), t, "hour", 13)
        _check_ts(extract_minute_ts(arr, unit), t, "minute", 45)
        _check_ts(extract_second_ts(arr, unit), t, "second", 30)


def test_ts_day_index_and_iso_week_every_unit() raises:
    var t = _table()
    for unit in _units():
        var arr = _ts_with_null(t, unit)
        _check_ts(extract_day_index_ts(arr, unit, EXTRACT_DAYOFWEEK), t, "dow", 0)
        _check_ts(extract_day_index_ts(arr, unit, EXTRACT_ISODOW), t, "isodow", 0)
        _check_ts(extract_day_index_ts(arr, unit, EXTRACT_DAYOFYEAR), t, "doy", 0)
        _check_ts(extract_iso_week_ts(arr, unit, EXTRACT_WEEK), t, "week", 0)
        _check_ts(extract_iso_week_ts(arr, unit, EXTRACT_ISOYEAR), t, "isoyear", 0)
        _check_ts(extract_iso_week_ts(arr, unit, EXTRACT_YEARWEEK), t, "yearweek", 0)


def test_ts_subsecond_folds_in_the_seconds() raises:
    """The millisecond / microsecond answers count from the start of the MINUTE (second
    30 plus the fraction). A seconds column has no fraction; a nanosecond
    column's last three digits are discarded."""
    var t = _table()
    for unit in _units():
        var arr = _ts_with_null(t, unit)
        var us: Int
        if unit == ArrowType.TIMESTAMP_S:
            us = 30_000_000
        elif unit == ArrowType.TIMESTAMP_MS:
            us = 30_123_000
        else:
            us = 30_123_456
        _check_ts(extract_subsecond_ts(arr, unit, EXTRACT_MICROSECOND), t, "us", us)
        _check_ts(extract_subsecond_ts(arr, unit, EXTRACT_MILLISECOND), t, "ms", us // 1000)


def test_ts_one_tick_before_the_epoch() raises:
    """Tick -1 is the last tick of day -1 in every unit: floor division,
    not truncation toward zero (which would answer day 0, hour 0)."""
    for unit in _units():
        var vals = List[Scalar[DType.int64]]()
        vals.append(Int64(-1))
        var arr = PrimitiveArray[DType.int64].from_list(vals)
        assert_equal(Int(extract_year_ts(arr, unit).get(0)), 1969)
        assert_equal(Int(extract_month_ts(arr, unit).get(0)), 12)
        assert_equal(Int(extract_day_ts(arr, unit).get(0)), 31)
        assert_equal(Int(extract_quarter_ts(arr, unit).get(0)), 4)
        assert_equal(Int(extract_hour_ts(arr, unit).get(0)), 23)
        assert_equal(Int(extract_minute_ts(arr, unit).get(0)), 59)
        assert_equal(Int(extract_second_ts(arr, unit).get(0)), 59)
        assert_equal(
            Int(extract_day_index_ts(arr, unit, EXTRACT_DAYOFWEEK).get(0)), 3
        )
        assert_equal(Int(extract_iso_week_ts(arr, unit, EXTRACT_ISOYEAR).get(0)), 1970)
        var us_want: Int
        if unit == ArrowType.TIMESTAMP_S:
            us_want = 59_000_000
        elif unit == ArrowType.TIMESTAMP_MS:
            us_want = 59_999_000
        else:
            us_want = 59_999_999
        assert_equal(
            Int(extract_subsecond_ts(arr, unit, EXTRACT_MICROSECOND).get(0)), us_want
        )
        assert_equal(
            Int(extract_subsecond_ts(arr, unit, EXTRACT_MILLISECOND).get(0)),
            us_want // 1000,
        )
        assert_false(Bool(extract_year_ts(arr, unit).validity))


# -----------------------------------------------------------------------------
# Refusals
# -----------------------------------------------------------------------------


def _one_ts() -> PrimitiveArray[DType.int64]:
    var vals = List[Scalar[DType.int64]]()
    vals.append(Int64(0))
    return PrimitiveArray[DType.int64].from_list(vals)


def _one_date() -> PrimitiveArray[DType.int32]:
    var vals = List[Scalar[DType.int32]]()
    vals.append(Int32(0))
    return PrimitiveArray[DType.int32].from_list(vals)


def test_non_timestamp_unit_is_refused() raises:
    """A DATE32 or INT64 type passed as a timestamp unit is refused by every
    TIMESTAMP_* kernel rather than read at some default scale."""
    var arr = _one_ts()
    with assert_raises(contains="unsupported timestamp unit type_id=15"):
        _ = extract_year_ts(arr, ArrowType.DATE32)
    with assert_raises(contains="unsupported timestamp unit type_id=5"):
        _ = extract_hour_ts(arr, ArrowType.INT64)
    with assert_raises(contains="unsupported timestamp unit"):
        _ = extract_subsecond_ts(arr, ArrowType.INT64, EXTRACT_MICROSECOND)


def test_wrong_family_unit_is_refused() raises:
    """Each family refuses a unit of another family instead of answering a
    field the caller did not ask for."""
    with assert_raises(contains="not a day-index unit: 10"):
        _ = extract_day_index_date32(_one_date(), EXTRACT_WEEK)
    with assert_raises(contains="not a day-index unit: 13"):
        _ = extract_day_index_ts(
            _one_ts(), ArrowType.TIMESTAMP_US, EXTRACT_MILLISECOND
        )
    with assert_raises(contains="not an ISO week-date unit: 7"):
        _ = extract_iso_week_date32(_one_date(), EXTRACT_DAYOFWEEK)
    with assert_raises(contains="not an ISO week-date unit: 9"):
        _ = extract_iso_week_ts(_one_ts(), ArrowType.TIMESTAMP_S, EXTRACT_DAYOFYEAR)
    with assert_raises(contains="not a sub-second unit: 12"):
        _ = extract_subsecond_ts(_one_ts(), ArrowType.TIMESTAMP_NS, EXTRACT_YEARWEEK)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

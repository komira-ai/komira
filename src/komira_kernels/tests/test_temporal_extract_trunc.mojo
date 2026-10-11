# =============================================================================
# Tests for `temporal_extract`: `date_trunc` over DATE32 and TIMESTAMP_*, and
# `parse_trunc_unit`.
#
# THE ORACLE: each expected period start was worked out from the proleptic
# Gregorian calendar (leap years divisible by 4, centuries only when divisible
# by 400; year 0 exists and is leap) and ISO 8601 weeks (a week starts on
# Monday), as a day count from the epoch day 0. AD rows were cross-checked
# against an established Gregorian implementation; the BC row was moved
# forward by five 400-year cycles (5 * 146097 days, a whole number of weeks)
# and checked the same way. Timestamps multiply that day count back into
# ticks; sub-day truncation is plain floor arithmetic on ticks, written out
# per row.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.testing import assert_raises

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_kernels.temporal_extract import (
    TRUNC_YEAR,
    TRUNC_QUARTER,
    TRUNC_MONTH,
    TRUNC_WEEK,
    TRUNC_DAY,
    TRUNC_HOUR,
    TRUNC_MINUTE,
    TRUNC_SECOND,
    TRUNC_MILLISECOND,
    TRUNC_MICROSECOND,
    date_trunc_date32,
    date_trunc_ts,
    parse_trunc_unit,
)


@fieldwise_init
struct _Trunc(Copyable, Movable):
    """A day and the first day of its year, quarter, month and ISO week."""

    var days: Int
    var year: Int
    var quarter: Int
    var month: Int
    var week: Int


def _table() -> List[_Trunc]:
    var t = List[_Trunc]()
    # Day 60 (the 29th of month 2) of a leap year divisible by 400, a
    # Tuesday: first quarter, so year and quarter starts agree.
    t.append(_Trunc(11016, 10957, 10957, 10988, 11015))
    # Day 366 of that year, a Sunday (the week starts six days before): Q4.
    t.append(_Trunc(11322, 10957, 11231, 11292, 11316))
    # A third-quarter Tuesday of the same year.
    t.append(_Trunc(11184, 10957, 11139, 11170, 11183))
    # Day -1, a Wednesday: every start is before the epoch.
    t.append(_Trunc(-1, -365, -92, -31, -3))
    # The last day of months 1 (a Monday), 3 (a Friday) and 8 (a Thursday):
    # month and quarter starts must stay in the same month.
    t.append(_Trunc(10987, 10957, 10957, 10957, 10987))
    t.append(_Trunc(11047, 10957, 10957, 11017, 11043))
    t.append(_Trunc(11200, 10957, 11139, 11170, 11197))
    # Day 0 itself, a Thursday: day, year, quarter and month starts are 0.
    t.append(_Trunc(0, 0, 0, 0, -3))
    # BC: day 75 of leap year -44 (month 3 day 15), a Thursday.
    t.append(_Trunc(-735525, -735599, -735599, -735539, -735528))
    # Year 0 (leap), month 4 day 10, a Monday: second quarter, and the week
    # starts on the day itself.
    t.append(_Trunc(-719428, -719528, -719437, -719437, -719428))
    return t^


def _want(row: _Trunc, unit: UInt8) -> Int:
    if unit == TRUNC_YEAR:
        return row.year
    if unit == TRUNC_QUARTER:
        return row.quarter
    if unit == TRUNC_MONTH:
        return row.month
    if unit == TRUNC_WEEK:
        return row.week
    return row.days


def _calendar_units() -> List[UInt8]:
    var u = List[UInt8]()
    u.append(TRUNC_YEAR)
    u.append(TRUNC_QUARTER)
    u.append(TRUNC_MONTH)
    u.append(TRUNC_WEEK)
    u.append(TRUNC_DAY)
    return u^


def _all_units() -> List[UInt8]:
    var u = _calendar_units()
    u.append(TRUNC_HOUR)
    u.append(TRUNC_MINUTE)
    u.append(TRUNC_SECOND)
    u.append(TRUNC_MILLISECOND)
    u.append(TRUNC_MICROSECOND)
    return u^


# -----------------------------------------------------------------------------
# DATE32
# -----------------------------------------------------------------------------


def test_date32_trunc_every_unit() raises:
    """Calendar units round down to the period's first day; day and every
    sub-day unit leave a DATE32 unchanged (it has no sub-day part). A NULL
    row in the middle stays NULL with a 0 data lane."""
    var t = _table()
    var n = len(t) + 1
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(len(t)):
        arr.set(i + 1, Scalar[DType.int32](Int32(t[i].days)))
    arr.set(0, Scalar[DType.int32](Int32(4242)))
    arr._set_null(0)
    for unit in _all_units():
        var res = date_trunc_date32(arr, unit)
        assert_equal(res.length, n)
        assert_equal(res.null_count, 1)
        assert_true(res.is_null(0))
        assert_equal(Int(res.get(0)), 0)
        for i in range(len(t)):
            assert_false(res.is_null(i + 1))
            assert_equal(
                Int(res.get(i + 1)),
                _want(t[i], unit),
                "unit " + String(Int(unit)) + " day " + String(t[i].days),
            )


def test_date32_month_and_quarter_trunc_every_day_of_three_years() raises:
    """Every day of a 400-divisible leap year, a common century year and a
    BC leap year: month and quarter starts from a walk over the Gregorian
    month lengths, so every first and last day of a month is a row."""
    var starts = [10957, -25567, -735599]
    var leaps = [True, False, True]
    for k in range(3):
        var feb = 29 if leaps[k] else 28
        var lens = [31, feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var vals = List[Scalar[DType.int32]]()
        var month_start = List[Int]()
        var quarter_start = List[Int]()
        var first = starts[k]
        var q_first = first
        for m in range(12):
            if m % 3 == 0:
                q_first = first
            for _ in range(lens[m]):
                vals.append(Int32(starts[k] + len(month_start)))
                month_start.append(first)
                quarter_start.append(q_first)
            first += lens[m]
        var arr = PrimitiveArray[DType.int32].from_list(vals)
        var rm = date_trunc_date32(arr, TRUNC_MONTH)
        var rq = date_trunc_date32(arr, TRUNC_QUARTER)
        var ry = date_trunc_date32(arr, TRUNC_YEAR)
        for i in range(len(month_start)):
            var what = "day " + String(starts[k] + i)
            assert_equal(Int(rm.get(i)), month_start[i], what)
            assert_equal(Int(rq.get(i)), quarter_start[i], what)
            assert_equal(Int(ry.get(i)), starts[k], what)


def test_date32_trunc_non_nullable_has_no_validity() raises:
    var vals = List[Scalar[DType.int32]]()
    vals.append(Int32(11322))
    var arr = PrimitiveArray[DType.int32].from_list(vals)
    var res = date_trunc_date32(arr, TRUNC_MONTH)
    assert_false(Bool(res.validity))
    assert_equal(Int(res.get(0)), 11292)


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


def _units() -> List[ArrowType]:
    var u = List[ArrowType]()
    u.append(ArrowType.TIMESTAMP_S)
    u.append(ArrowType.TIMESTAMP_MS)
    u.append(ArrowType.TIMESTAMP_US)
    u.append(ArrowType.TIMESTAMP_NS)
    u.append(ArrowType.TIMESTAMP)
    return u^


def test_ts_calendar_trunc_every_unit() raises:
    """Every row at 13:45:30 and a fraction rounds down to its period's first
    day at midnight, in the column's own ticks."""
    var t = _table()
    for unit in _units():
        var tps = _tps(unit)
        var tpd = 86400 * tps
        var rows = len(t)
        if unit == ArrowType.TIMESTAMP_NS:
            rows = 8  # the BC rows are past the nanosecond Int64 range
        var arr = PrimitiveArray[DType.int64].allocate_nullable(rows + 1)
        for i in range(rows):
            var ticks = t[i].days * tpd + 49530 * tps + (tps - 1) // 3
            arr.set(i, Scalar[DType.int64](Int64(ticks)))
        arr.set(rows, Scalar[DType.int64](Int64(99)))
        arr._set_null(rows)
        for cu in _calendar_units():
            var res = date_trunc_ts(arr, unit, cu)
            assert_equal(res.null_count, 1)
            assert_true(res.is_null(rows))
            assert_equal(Int(res.get(rows)), 0)
            for i in range(rows):
                assert_equal(
                    Int(res.get(i)),
                    _want(t[i], cu) * tpd,
                    "unit " + String(Int(cu)) + " day " + String(t[i].days),
                )


def _ts_one(v: Int) -> PrimitiveArray[DType.int64]:
    var vals = List[Scalar[DType.int64]]()
    vals.append(Int64(v))
    return PrimitiveArray[DType.int64].from_list(vals)


def _trunc1(v: Int, unit: ArrowType, tu: UInt8) raises -> Int:
    var res = date_trunc_ts(_ts_one(v), unit, tu)
    assert_false(Bool(res.validity))
    return Int(res.get(0))


def test_ts_subday_trunc_nanoseconds() raises:
    """Day 11016 at 13:45:30.123456789 in nanoseconds: 951831930 whole
    seconds since the epoch, then the fraction."""
    var s = 951831930
    var ns = ArrowType.TIMESTAMP_NS
    var v = s * 1_000_000_000 + 123_456_789
    var g = 1_000_000_000
    assert_equal(_trunc1(v, ns, TRUNC_HOUR), (s - 45 * 60 - 30) * g)
    assert_equal(_trunc1(v, ns, TRUNC_MINUTE), (s - 30) * g)
    assert_equal(_trunc1(v, ns, TRUNC_SECOND), s * g)
    assert_equal(_trunc1(v, ns, TRUNC_MILLISECOND), s * g + 123_000_000)
    assert_equal(_trunc1(v, ns, TRUNC_MICROSECOND), s * g + 123_456_000)


def test_ts_subday_trunc_microseconds() raises:
    var s = 951831930
    var v = s * 1_000_000 + 123_456
    for unit in [ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP]:
        assert_equal(_trunc1(v, unit, TRUNC_HOUR), (s - 45 * 60 - 30) * 1_000_000)
        assert_equal(_trunc1(v, unit, TRUNC_MINUTE), (s - 30) * 1_000_000)
        assert_equal(_trunc1(v, unit, TRUNC_SECOND), s * 1_000_000)
        assert_equal(_trunc1(v, unit, TRUNC_MILLISECOND), s * 1_000_000 + 123_000)
        # The column's own resolution: microsecond truncation is a no-op.
        assert_equal(_trunc1(v, unit, TRUNC_MICROSECOND), v)


def test_ts_subday_trunc_coarse_units_are_noops_below_their_resolution() raises:
    """Milliseconds and seconds columns: truncating to a finer unit than the
    column holds returns the value unchanged."""
    var s = 951831930
    var ms = s * 1_000 + 123
    var u_ms = ArrowType.TIMESTAMP_MS
    assert_equal(_trunc1(ms, u_ms, TRUNC_SECOND), s * 1_000)
    assert_equal(_trunc1(ms, u_ms, TRUNC_MILLISECOND), ms)
    assert_equal(_trunc1(ms, u_ms, TRUNC_MICROSECOND), ms)
    var u_s = ArrowType.TIMESTAMP_S
    assert_equal(_trunc1(s, u_s, TRUNC_MINUTE), s - 30)
    assert_equal(_trunc1(s, u_s, TRUNC_MILLISECOND), s)
    assert_equal(_trunc1(s, u_s, TRUNC_MICROSECOND), s)


def test_ts_trunc_one_tick_before_the_epoch_floors() raises:
    """Tick -1 belongs to the last unit of the previous period: floor, not
    truncation toward zero (which would answer 0 for every row here)."""
    var us = ArrowType.TIMESTAMP_US
    var day = 86_400_000_000
    assert_equal(_trunc1(-1, us, TRUNC_YEAR), -365 * day)
    assert_equal(_trunc1(-1, us, TRUNC_QUARTER), -92 * day)
    assert_equal(_trunc1(-1, us, TRUNC_MONTH), -31 * day)
    assert_equal(_trunc1(-1, us, TRUNC_WEEK), -3 * day)
    assert_equal(_trunc1(-1, us, TRUNC_DAY), -day)
    assert_equal(_trunc1(-1, us, TRUNC_HOUR), -3_600_000_000)
    assert_equal(_trunc1(-1, us, TRUNC_MINUTE), -60_000_000)
    assert_equal(_trunc1(-1, us, TRUNC_SECOND), -1_000_000)
    assert_equal(_trunc1(-1, us, TRUNC_MILLISECOND), -1_000)
    var ns = ArrowType.TIMESTAMP_NS
    assert_equal(_trunc1(-1, ns, TRUNC_MILLISECOND), -1_000_000)
    assert_equal(_trunc1(-1, ns, TRUNC_MICROSECOND), -1_000)


def test_ts_trunc_one_tick_before_the_epoch_every_unit() raises:
    """The same floor at tick -1 for every timestamp unit, the legacy
    microsecond alias included. Truncating to a unit at or below the
    column's own resolution leaves -1 unchanged."""
    var units = [
        ArrowType.TIMESTAMP_S,
        ArrowType.TIMESTAMP_MS,
        ArrowType.TIMESTAMP_US,
        ArrowType.TIMESTAMP_NS,
        ArrowType.TIMESTAMP,
    ]
    for unit in units:
        var tps = _tps(unit)
        var day = 86400 * tps
        assert_equal(_trunc1(-1, unit, TRUNC_YEAR), -365 * day)
        assert_equal(_trunc1(-1, unit, TRUNC_QUARTER), -92 * day)
        assert_equal(_trunc1(-1, unit, TRUNC_MONTH), -31 * day)
        assert_equal(_trunc1(-1, unit, TRUNC_WEEK), -3 * day)
        assert_equal(_trunc1(-1, unit, TRUNC_DAY), -day)
        assert_equal(_trunc1(-1, unit, TRUNC_HOUR), -3600 * tps)
        assert_equal(_trunc1(-1, unit, TRUNC_MINUTE), -60 * tps)
        assert_equal(_trunc1(-1, unit, TRUNC_SECOND), -tps)
        var ms_want = -1
        if tps > 1_000:
            ms_want = -(tps // 1_000)
        assert_equal(_trunc1(-1, unit, TRUNC_MILLISECOND), ms_want)
        var us_want = -1
        if tps > 1_000_000:
            us_want = -(tps // 1_000_000)
        assert_equal(_trunc1(-1, unit, TRUNC_MICROSECOND), us_want)


def test_ts_trunc_refuses_a_non_timestamp_unit() raises:
    with assert_raises(contains="unsupported timestamp unit type_id=15"):
        _ = date_trunc_ts(_ts_one(0), ArrowType.DATE32, TRUNC_DAY)


# -----------------------------------------------------------------------------
# parse_trunc_unit
# -----------------------------------------------------------------------------


def _check_names(names: List[String], want: UInt8) raises:
    for name in names:
        assert_equal(parse_trunc_unit(name), want, name)
        assert_equal(parse_trunc_unit(name.upper()), want, name.upper())


def test_parse_trunc_unit_every_name_and_alias() raises:
    """Every name the docstring lists, in lower and upper case (the parser
    lower-cases first)."""
    _check_names(["year", "years", "yr"], TRUNC_YEAR)
    _check_names(["quarter", "quarters", "q"], TRUNC_QUARTER)
    _check_names(["month", "months", "mo"], TRUNC_MONTH)
    _check_names(["week", "weeks", "w"], TRUNC_WEEK)
    _check_names(["day", "days", "d"], TRUNC_DAY)
    _check_names(["hour", "hours", "hr"], TRUNC_HOUR)
    _check_names(["minute", "minutes", "min"], TRUNC_MINUTE)
    _check_names(["second", "seconds", "sec"], TRUNC_SECOND)
    _check_names(["millisecond", "milliseconds", "ms"], TRUNC_MILLISECOND)
    _check_names(["microsecond", "microseconds", "us"], TRUNC_MICROSECOND)


def test_parse_trunc_unit_codes_are_distinct_and_dense() raises:
    """The ten codes are 0..9 in calendar-to-sub-second order."""
    var u = _all_units()
    for i in range(len(u)):
        assert_equal(Int(u[i]), i)


def test_parse_trunc_unit_refuses_unknown_names() raises:
    with assert_raises(contains="unrecognized unit 'fortnight'"):
        _ = parse_trunc_unit("fortnight")
    with assert_raises(contains="unrecognized unit ''"):
        _ = parse_trunc_unit("")
    # A name with surrounding space is not trimmed into a match.
    with assert_raises(contains="unrecognized unit"):
        _ = parse_trunc_unit(" day")
    # Nanosecond truncation is not offered.
    with assert_raises(contains="unrecognized unit 'ns'"):
        _ = parse_trunc_unit("ns")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

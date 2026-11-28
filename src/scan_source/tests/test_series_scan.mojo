# =============================================================================
# test_series_scan: the `komira.generate_series` spec, binding and values
# =============================================================================
#
# The expected values are DuckDB v1.5.6's for the same `generate_series` /
# `range` call (measured), written here as numbers.
#
#   test_integer_inclusive_and_exclusive_bounds
#       generate_series(1, 5) is 1..5 and range(1, 5) is 1..4; a step of 3
#       lands on the bound for generate_series(1, 10, 3) (1, 4, 7, 10) and
#       stops before it for range (1, 4, 7); generate_series(x, x) is one row
#       and range(x, x) none.
#   test_negative_step_counts_down
#       generate_series(5, 1, -2) is 5, 3, 1; range(3, 1, -1) is 3, 2.
#   test_a_step_away_from_the_bound_is_empty
#       generate_series(5, 1), range(3, 1) and generate_series(-1, 5, -1) give
#       no rows; so does the empty spec a NULL argument binds to.
#   test_int64_extremes_count_without_overflow
#       the three values from the Int64 minimum, range up to the maximum, and
#       a series over the whole Int64 line saturates its count instead of
#       wrapping to zero.
#   test_values_are_read_a_window_at_a_time
#       a window inside, across and past the end of the series; a window far
#       into a series of 2^62 rows costs only its own rows; limit 0 is empty.
#   test_a_month_step_clamps_the_day_and_never_recovers
#       from 31 Jan 2024 by one month: 31 Jan, 29 Feb, 29 Mar, 29 Apr, the
#       time of day kept; the same values read from a window starting at row 2
#       (the clamp is found without walking from the start); a year step from
#       29 Feb 2020 stays on 28 Feb; a negative month step counts down.
#   test_a_month_window_past_the_end_is_empty
#       a window starting after the last row, and a month series that points
#       away from its bound, give no rows.
#   test_a_month_step_beyond_the_timestamp_range_raises
#       a step of a billion months, and one month at a time past the last
#       TIMESTAMP (294247-01-10) or before the first, raise DuckDB's overflow
#       error once the series needs the value beyond the range (DuckDB
#       computes the value after the last row, so the full series raises);
#       the rows before it are read.
#   test_a_fixed_timestamp_step_adds_microseconds
#       an hour step over three hours (range: three values).
#   test_the_binding_carries_the_whole_spec
#       series_spec_of(series_scan_binding(s)) is s field by field; the kind,
#       schema, name and gate are the series kind's; two specs differing in
#       one field have different identities; is_series_binding.
#   test_a_bad_binding_or_spec_is_refused
#       a binding of another kind, one missing a parameter, a spec with no
#       step, with both steps, and a month step on a BIGINT series each raise.
#   test_the_schema_is_one_named_column
#       BIGINT, or TIMESTAMP in microseconds, never NULL.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from arrow.arrow_types import ArrowType
from scan_source.pushdown_gate import PushdownGate
from scan_source.scan_binding import ScanBinding, scan_kind_id
from scan_source.scan_params import ScanParams
from scan_source.series_scan import (
    SERIES_SCAN_KIND_NAME,
    SeriesSpec,
    US_PER_DAY,
    is_series_binding,
    series_scan_binding,
    series_spec_of,
    series_values,
)
from scan_source.source_variant import SourceVariant


def _ints(start: Int64, stop: Int64, step: Int64, inclusive: Bool) -> SeriesSpec:
    return SeriesSpec("generate_series", False, start, stop, step, 0, inclusive)


def _all(spec: SeriesSpec) raises -> List[Int64]:
    return series_values(spec, 0, 1000)


def _assert_values(got: List[Int64], want: List[Int64]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _day(days: Int64) -> Int64:
    return days * US_PER_DAY


comptime _HOUR: Int64 = 3_600_000_000


def test_integer_inclusive_and_exclusive_bounds() raises:
    _assert_values(_all(_ints(1, 5, 1, True)), [1, 2, 3, 4, 5])
    _assert_values(_all(_ints(1, 5, 1, False)), [1, 2, 3, 4])
    _assert_values(_all(_ints(1, 10, 3, True)), [1, 4, 7, 10])
    _assert_values(_all(_ints(1, 10, 3, False)), [1, 4, 7])
    _assert_values(_all(_ints(7, 7, 1, True)), [7])
    _assert_values(_all(_ints(7, 7, 1, False)), List[Int64]())
    assert_equal(_ints(1, 10, 3, True).row_count().value(), 4)
    assert_equal(_ints(1, 10, 3, False).row_count().value(), 3)


def test_negative_step_counts_down() raises:
    _assert_values(_all(_ints(5, 1, -2, True)), [5, 3, 1])
    _assert_values(_all(_ints(3, 1, -1, False)), [3, 2])
    _assert_values(_all(_ints(1, 1, -1, True)), [1])
    _assert_values(_all(_ints(1, 1, -1, False)), List[Int64]())


def test_a_step_away_from_the_bound_is_empty() raises:
    _assert_values(_all(_ints(5, 1, 1, True)), List[Int64]())
    _assert_values(_all(_ints(3, 1, 1, False)), List[Int64]())
    _assert_values(_all(_ints(-1, 5, -1, True)), List[Int64]())
    _assert_values(
        _all(SeriesSpec.empty("generate_series", False)), List[Int64]()
    )
    _assert_values(_all(SeriesSpec.empty("range", True)), List[Int64]())
    assert_equal(_ints(5, 1, 1, True).row_count().value(), 0)


def test_int64_extremes_count_without_overflow() raises:
    _assert_values(
        _all(_ints(Int64.MIN, Int64.MIN + 2, 1, True)),
        [Int64.MIN, Int64.MIN + 1, Int64.MIN + 2],
    )
    _assert_values(
        _all(_ints(Int64.MAX - 1, Int64.MAX, 1, False)), [Int64.MAX - 1]
    )
    _assert_values(
        _all(_ints(Int64.MAX, Int64.MAX - 1, -1, True)),
        [Int64.MAX, Int64.MAX - 1],
    )
    _assert_values(
        _all(_ints(Int64.MAX - 7, Int64.MAX, 5, True)),
        [Int64.MAX - 7, Int64.MAX - 2],
    )
    var whole = _ints(Int64.MIN, Int64.MAX, 1, True)
    assert_equal(whole.row_count().value(), UInt64.MAX)
    var down = _ints(Int64.MAX, Int64.MIN, Int64.MIN, True)
    _assert_values(_all(down), [Int64.MAX, -1])


def test_values_are_read_a_window_at_a_time() raises:
    var s = _ints(10, 19, 1, True)
    _assert_values(series_values(s, 0, 4), [10, 11, 12, 13])
    _assert_values(series_values(s, 8, 4), [18, 19])
    _assert_values(series_values(s, 10, 4), List[Int64]())
    _assert_values(series_values(s, 99, 4), List[Int64]())
    _assert_values(series_values(s, 0, 0), List[Int64]())
    var long = _ints(1, Int64(1) << 62, 1, True)
    var w = series_values(long, UInt64(1) << 61, 3)
    _assert_values(w, [(Int64(1) << 61) + 1, (Int64(1) << 61) + 2, (Int64(1) << 61) + 3])


def _monthly(start: Int64, stop: Int64, months: Int64, inclusive: Bool) -> SeriesSpec:
    return SeriesSpec("generate_series", True, start, stop, 0, months, inclusive)


def test_a_month_step_clamps_the_day_and_never_recovers() raises:
    var tod = 10 * _HOUR + 30 * 60_000_000
    # 2024-01-31 10:30 .. 2024-04-30 10:30 by one month.
    var s = _monthly(_day(19753) + tod, _day(19843) + tod, 1, True)
    var want: List[Int64] = [
        _day(19753) + tod, _day(19782) + tod, _day(19811) + tod,
        _day(19842) + tod,
    ]
    _assert_values(_all(s), want)
    _assert_values(series_values(s, 2, 10), [want[2], want[3]])
    _assert_values(series_values(s, 1, 1), [want[1]])
    # 2024-01-31 .. 2024-05-01 (DATE bounds at midnight): the same days.
    _assert_values(
        _all(_monthly(_day(19753), _day(19844), 1, True)),
        [_day(19753), _day(19782), _day(19811), _day(19842)],
    )
    # range(DATE '2020-02-29', DATE '2024-03-01', INTERVAL 1 YEAR).
    var yearly = _monthly(_day(18321), _day(19783), 12, False)
    var feb = _all(yearly)
    assert_equal(len(feb), 5)
    assert_equal(feb[0], _day(18321))
    assert_equal(feb[1], _day(18686))
    assert_equal(feb[4], _day(19781))
    _assert_values(series_values(yearly, 4, 3), [_day(19781)])
    # 2024-03-31 down to 2024-01-01 by -1 month: 31 Mar, 29 Feb, 29 Jan.
    _assert_values(
        _all(_monthly(_day(19813), _day(19723), -1, True)),
        [_day(19813), _day(19782), _day(19751)],
    )


def test_a_month_window_past_the_end_is_empty() raises:
    var s = _monthly(_day(19753), _day(19844), 1, True)
    _assert_values(series_values(s, 4, 10), List[Int64]())
    _assert_values(series_values(s, 1000000, 10), List[Int64]())
    var away = _monthly(_day(19844), _day(19753), 1, True)
    _assert_values(_all(away), List[Int64]())
    var same_month = _monthly(_day(19753), _day(19723), 1, True)
    _assert_values(_all(same_month), List[Int64]())
    assert_false(Bool(s.row_count()))


def test_a_month_step_beyond_the_timestamp_range_raises() raises:
    # generate_series(TIMESTAMP '2024-01-01', TIMESTAMP '2024-02-01',
    # INTERVAL 1000000000 MONTH): DuckDB raises, as row 1 is out of range.
    var huge = _monthly(_day(19723), _day(19754), 1_000_000_000, True)
    _assert_values(series_values(huge, 0, 1), [_day(19723)])
    with assert_raises(contains="Overflow exception in date/time"):
        _ = _all(huge)
    with assert_raises(contains="beyond the TIMESTAMP range"):
        _ = series_values(huge, 1, 10)
    # 294246-11-30 .. 294247-01-10 (the last TIMESTAMP day) by one month:
    # 11-30 and 12-30, then 294247-01-30 is beyond the range.
    var last = Int64(106751991)
    var up = _monthly(_day(last - 41), _day(last), 1, True)
    _assert_values(
        series_values(up, 0, 2), [_day(last - 41), _day(last - 11)]
    )
    with assert_raises(contains="Overflow exception in date/time"):
        _ = _all(up)
    with assert_raises(contains="Overflow exception in date/time"):
        _ = series_values(up, 2, 1)
    # Down from 40 days after the first TIMESTAMP day by one month.
    var down = _monthly(_day(40 - last), _day(-last), -1, True)
    with assert_raises(contains="Overflow exception in date/time"):
        _ = _all(down)


def test_a_fixed_timestamp_step_adds_microseconds() raises:
    var s = SeriesSpec(
        "range", True, _day(19723), _day(19723) + 3 * _HOUR, _HOUR, 0, False
    )
    _assert_values(
        _all(s), [_day(19723), _day(19723) + _HOUR, _day(19723) + 2 * _HOUR]
    )


def _assert_same_spec(a: SeriesSpec, b: SeriesSpec) raises:
    assert_equal(a.column, b.column)
    assert_equal(a.timestamp, b.timestamp)
    assert_equal(a.start, b.start)
    assert_equal(a.stop, b.stop)
    assert_equal(a.step, b.step)
    assert_equal(a.step_months, b.step_months)
    assert_equal(a.inclusive, b.inclusive)


def test_the_binding_carries_the_whole_spec() raises:
    var spec = _monthly(_day(19753), _day(19844), 1, True)
    spec.column = "d"
    var b = series_scan_binding(spec, "generate_series")
    _assert_same_spec(series_spec_of(b), spec)
    assert_equal(b.kind_name, String(SERIES_SCAN_KIND_NAME))
    assert_equal(b.kind_id, scan_kind_id(String(SERIES_SCAN_KIND_NAME)))
    assert_equal(b.name, "generate_series")
    assert_equal(b.fingerprint, b.structural_id)
    assert_equal(b.schema.field_name(0), "d")
    assert_true(b.schema.field_arrow_type(0) == ArrowType.TIMESTAMP_US)
    var ints = _ints(1, 5, 1, False)
    var bi = series_scan_binding(ints, "range")
    _assert_same_spec(series_spec_of(bi), ints)
    # Each field separates identity.
    var other = _ints(1, 5, 1, True)
    assert_true(series_scan_binding(other, "range").fingerprint != bi.fingerprint)
    other = _ints(1, 6, 1, False)
    assert_true(series_scan_binding(other, "range").fingerprint != bi.fingerprint)
    other = _ints(0, 5, 1, False)
    assert_true(series_scan_binding(other, "range").fingerprint != bi.fingerprint)
    other = _ints(1, 5, 2, False)
    assert_true(series_scan_binding(other, "range").fingerprint != bi.fingerprint)
    other = _ints(1, 5, 1, False)
    other.column = "x"
    assert_true(series_scan_binding(other, "range").fingerprint != bi.fingerprint)
    var ts = SeriesSpec("generate_series", True, 1, 5, 1, 0, False)
    assert_true(series_scan_binding(ts, "range").fingerprint != bi.fingerprint)
    var mo = SeriesSpec("generate_series", True, 1, 5, 0, 1, False)
    assert_true(
        series_scan_binding(mo, "range").fingerprint
        != series_scan_binding(ts, "range").fingerprint
    )
    assert_true(is_series_binding(SourceVariant.from_binding(bi^)))


def test_a_bad_binding_or_spec_is_refused() raises:
    var other = ScanBinding(
        kind_id=scan_kind_id("komira.other"),
        kind_name="komira.other",
        name="x",
        params=ScanParams(),
        schema=_ints(1, 2, 1, True).schema(),
        fingerprint=1,
        structural_id=1,
        gate=PushdownGate.reject_all(),
    )
    with assert_raises(contains="is not a series"):
        _ = series_spec_of(other)
    assert_false(is_series_binding(SourceVariant.from_binding(other^)))
    var b = series_scan_binding(_ints(1, 2, 1, True), "range")
    var partial = ScanParams()
    partial.put_str("column", "range")
    b.params = partial^
    with assert_raises(contains="no 'timestamp' parameter"):
        _ = series_spec_of(b)
    with assert_raises(contains="exactly one non-zero step"):
        _ = series_values(_ints(1, 2, 0, True), 0, 3)
    with assert_raises(contains="exactly one non-zero step"):
        SeriesSpec("g", True, 1, 2, 1, 1, True).check()
    with assert_raises(contains="needs a TIMESTAMP series"):
        SeriesSpec("g", False, 1, 2, 0, 1, True).check()
    var bad = series_scan_binding(SeriesSpec("g", False, 1, 2, 0, 1, True), "g")
    with assert_raises(contains="needs a TIMESTAMP series"):
        _ = series_spec_of(bad)


def test_the_schema_is_one_named_column() raises:
    var s = _ints(1, 2, 1, True).schema()
    assert_equal(s.num_columns(), 1)
    assert_equal(s.field_name(0), "generate_series")
    assert_true(s.field_arrow_type(0) == ArrowType.INT64)
    assert_false(s.field_nullable(0))
    var t = SeriesSpec("range", True, 1, 2, 1, 0, False).schema()
    assert_equal(t.field_name(0), "range")
    assert_true(t.field_arrow_type(0) == ArrowType.TIMESTAMP_US)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

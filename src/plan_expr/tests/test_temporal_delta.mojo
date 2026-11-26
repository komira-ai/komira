# =============================================================================
# temporal_delta: the trees `date_diff_of` and `date_sub_of` build
# =============================================================================
#
# The values these trees answer are held to the pinned DuckDB by the
# scalar_fn cases of src/tests/conformance/komira_sql_conformance (run
# through run_sql); this file holds the shapes, so a formula changed here is
# a changed line in a test, not only a changed answer:
#   * test_boundaries_over_dates_read_the_calendar_fields: over DATEs,
#     year, quarter and month read the fields, day subtracts day numbers,
#     and each unit below the day is the day count times its size.
#   * test_boundaries_over_timestamps_count_truncated_values: over
#     TIMESTAMPs, day divides the difference of the two values truncated to
#     the day by a day's microseconds, a unit below adds its field's
#     difference to the one above times its size, microsecond subtracts the
#     values, and week truncates the day count over 7.
#   * test_complete_units_over_dates_are_the_boundaries_below_a_month: over
#     DATEs, date_sub of a unit up to the day is date_diff's tree, and week
#     is the complete days over 7.
#   * test_complete_units_adjust_the_boundaries_by_one: over TIMESTAMPs,
#     date_sub is a CASE of date_diff's count, one fewer going forward and
#     one more going back; month reads the day of the month and the month's
#     length.
#   * test_a_unit_outside_the_ten_is_refused: a period with no delta (an
#     extract unit, not a period) raises by name in both.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from plan_expr.expr import (
    Expr,
    EXTRACT_YEAR,
    EXTRACT_TRUNC_YEAR, EXTRACT_TRUNC_QUARTER, EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_WEEK, EXTRACT_TRUNC_DAY, EXTRACT_TRUNC_HOUR,
    EXTRACT_TRUNC_MINUTE, EXTRACT_TRUNC_SECOND, EXTRACT_TRUNC_MILLISECOND,
    EXTRACT_TRUNC_MICROSECOND,
)
from plan_expr.temporal_delta import date_diff_of, date_sub_of


def _a() -> Expr:
    return Expr.col_ref("a")


def _b() -> Expr:
    return Expr.col_ref("b")


def _units() -> List[UInt8]:
    return [
        EXTRACT_TRUNC_YEAR, EXTRACT_TRUNC_QUARTER, EXTRACT_TRUNC_MONTH,
        EXTRACT_TRUNC_WEEK, EXTRACT_TRUNC_DAY, EXTRACT_TRUNC_HOUR,
        EXTRACT_TRUNC_MINUTE, EXTRACT_TRUNC_SECOND, EXTRACT_TRUNC_MILLISECOND,
        EXTRACT_TRUNC_MICROSECOND,
    ]


def _diff(unit: UInt8, is_date: Bool) raises -> String:
    return String(date_diff_of(unit, _a(), _b(), is_date))


def _sub(unit: UInt8, is_date: Bool) raises -> String:
    return String(date_sub_of(unit, _a(), _b(), is_date))


comptime _DAYS = "BinaryOp(SUB, Cast(ColRef(b), int64), Cast(ColRef(a), int64))"


def test_boundaries_over_dates_read_the_calendar_fields() raises:
    assert_equal(
        _diff(EXTRACT_TRUNC_YEAR, True),
        "BinaryOp(SUB, Extract(unit=0, ColRef(b)), Extract(unit=0, ColRef(a)))",
    )
    assert_equal(
        _diff(EXTRACT_TRUNC_QUARTER, True),
        "BinaryOp(ADD, BinaryOp(MUL, BinaryOp(SUB, Extract(unit=0, ColRef(b)),"
        " Extract(unit=0, ColRef(a))), Literal(ScalarValue(int64, 4))),"
        " BinaryOp(SUB, Extract(unit=1, ColRef(b)), Extract(unit=1, ColRef(a))))",
    )
    assert_equal(
        _diff(EXTRACT_TRUNC_MONTH, True),
        "BinaryOp(ADD, BinaryOp(MUL, BinaryOp(SUB, Extract(unit=0, ColRef(b)),"
        " Extract(unit=0, ColRef(a))), Literal(ScalarValue(int64, 12))),"
        " BinaryOp(SUB, Extract(unit=2, ColRef(b)), Extract(unit=2, ColRef(a))))",
    )
    assert_equal(_diff(EXTRACT_TRUNC_DAY, True), _DAYS)
    assert_equal(
        _diff(EXTRACT_TRUNC_HOUR, True),
        "BinaryOp(MUL, " + _DAYS + ", Literal(ScalarValue(int64, 24)))",
    )
    assert_equal(
        _diff(EXTRACT_TRUNC_MICROSECOND, True),
        "BinaryOp(MUL, " + _DAYS + ", Literal(ScalarValue(int64, 86400000000)))",
    )
    var ms = _diff(EXTRACT_TRUNC_MILLISECOND, True)
    assert_true(ms.endswith("Literal(ScalarValue(int64, 60000)))"), ms)
    assert_true("Extract(" not in ms, ms)


def test_boundaries_over_timestamps_count_truncated_values() raises:
    var day = _diff(EXTRACT_TRUNC_DAY, False)
    assert_equal(
        day,
        "Cast(BinaryOp(DIV, Cast(BinaryOp(SUB, Cast(Extract(unit=20, ColRef(b)), int64),"
        " Cast(Extract(unit=20, ColRef(a)), int64)), float64),"
        " Literal(ScalarValue(float64, 86400000000.0))), int64)",
    )
    assert_equal(
        _diff(EXTRACT_TRUNC_HOUR, False),
        "BinaryOp(ADD, BinaryOp(MUL, " + day + ", Literal(ScalarValue(int64, 24))),"
        " BinaryOp(SUB, Extract(unit=4, ColRef(b)), Extract(unit=4, ColRef(a))))",
    )
    var second = _diff(EXTRACT_TRUNC_SECOND, False)
    assert_true(
        second.endswith(
            "Literal(ScalarValue(int64, 60))), BinaryOp(SUB, Extract(unit=6,"
            " ColRef(b)), Extract(unit=6, ColRef(a))))"
        ),
        second,
    )
    var ms = _diff(EXTRACT_TRUNC_MILLISECOND, False)
    assert_true(
        ms.endswith(
            "Literal(ScalarValue(int64, 60000))), BinaryOp(SUB, Extract(unit=13,"
            " ColRef(b)), Extract(unit=13, ColRef(a))))"
        ),
        ms,
    )
    assert_equal(_diff(EXTRACT_TRUNC_MICROSECOND, False), _DAYS)
    assert_equal(
        _diff(EXTRACT_TRUNC_WEEK, False),
        "Cast(UnaryOp(TRUNC, BinaryOp(DIV, Cast(" + day + ", float64),"
        " Literal(ScalarValue(float64, 7.0)))), int64)",
    )


def test_complete_units_over_dates_are_the_boundaries_below_a_month() raises:
    for unit in [
        EXTRACT_TRUNC_DAY, EXTRACT_TRUNC_HOUR, EXTRACT_TRUNC_MINUTE,
        EXTRACT_TRUNC_SECOND, EXTRACT_TRUNC_MILLISECOND, EXTRACT_TRUNC_MICROSECOND,
    ]:
        assert_equal(_sub(unit, True), _diff(unit, True))
    assert_equal(_sub(EXTRACT_TRUNC_WEEK, True), _diff(EXTRACT_TRUNC_WEEK, True))
    # A DATE has no time of day: the month's borrow reads the days only.
    var month = _sub(EXTRACT_TRUNC_MONTH, True)
    assert_true(month.startswith("When(WHEN BinaryOp(AND, BinaryOp(GE, "), month)
    assert_true("Extract(unit=20" not in month, month)


def test_complete_units_adjust_the_boundaries_by_one() raises:
    for unit in [
        EXTRACT_TRUNC_DAY, EXTRACT_TRUNC_HOUR, EXTRACT_TRUNC_MINUTE,
        EXTRACT_TRUNC_SECOND, EXTRACT_TRUNC_MILLISECOND,
    ]:
        var diff = _diff(unit, False)
        var sub = _sub(unit, False)
        assert_true(sub.startswith("When(WHEN BinaryOp(AND, BinaryOp(GE, "), sub)
        assert_true(
            sub.endswith(", ELSE " + diff + ")"),
            "date_sub's ELSE is date_diff's count: " + sub,
        )
        assert_true(("THEN BinaryOp(SUB, " + diff + ", Literal(ScalarValue(int64, 1)))") in sub, sub)
        assert_true(("THEN BinaryOp(ADD, " + diff + ", Literal(ScalarValue(int64, 1)))") in sub, sub)
    assert_equal(_sub(EXTRACT_TRUNC_MICROSECOND, False), _diff(EXTRACT_TRUNC_MICROSECOND, False))
    var month = _sub(EXTRACT_TRUNC_MONTH, False)
    assert_true("Extract(unit=20" in month, "the time of day is read: " + month)
    assert_true("Extract(unit=3, ColRef(b))" in month, month)
    assert_true(month.endswith(", ELSE " + _diff(EXTRACT_TRUNC_MONTH, False) + ")"), month)
    var quarter = _sub(EXTRACT_TRUNC_QUARTER, False)
    assert_true(quarter.endswith(", ELSE " + _diff(EXTRACT_TRUNC_QUARTER, False) + ")"), quarter)
    var year = _sub(EXTRACT_TRUNC_YEAR, False)
    assert_true(year.endswith(", ELSE " + _diff(EXTRACT_TRUNC_YEAR, False) + ")"), year)
    var week = _sub(EXTRACT_TRUNC_WEEK, False)
    assert_true(week.startswith("Cast(UnaryOp(TRUNC, BinaryOp(DIV, Cast(When("), week)
    for unit in _units():
        _ = _sub(unit, False)
        _ = _sub(unit, True)


def test_a_unit_outside_the_ten_is_refused() raises:
    with assert_raises(contains="temporal_delta: date_diff has no unit 0"):
        _ = date_diff_of(EXTRACT_YEAR, _a(), _b(), False)
    with assert_raises(contains="temporal_delta: date_sub has no unit 0"):
        _ = date_sub_of(EXTRACT_YEAR, _a(), _b(), False)
    with assert_raises(contains="temporal_delta: date_sub has no unit 0"):
        _ = date_sub_of(EXTRACT_YEAR, _a(), _b(), True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

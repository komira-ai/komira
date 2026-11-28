# =============================================================================
# dayname / monthname: the EXTRACT_DAYNAME and EXTRACT_MONTHNAME units
# =============================================================================
#
# Covers: `_eval_column_expr` of an EXPR_EXTRACT whose unit is a calendar name
# answers a STRING column of DuckDB's English names, over DATE32 and over every
# TIMESTAMP_* unit, and the output field is typed STRING to match. Every
# expected name below was read out of DuckDB (`dayname(x)`, `monthname(x)`),
# not derived from the code under test.
#
# What each test proves:
#   * test_every_weekday_over_a_date_column_is_duckdbs_name: seven consecutive
#     dates, Sunday to Saturday, name their seven days; and the day before the
#     epoch (day -1), day -165 and day -25509 (where floor and truncating
#     modulo give different weekdays) and two leap days name DuckDB's days.
#     Catches a weekday table off by one, a truncating modulo before 1970, and
#     the ISO numbering (Monday = 1) read as DuckDB's dayofweek (Sunday = 0).
#   * test_every_month_over_a_date_column_is_duckdbs_name: the 15th of each
#     month of a year names its twelve months; two leap days are February and
#     the day after one is March; the three days before the epoch above name
#     December, July and February. Catches a month table off by one.
#   * test_a_timestamp_names_the_day_of_its_date_in_every_unit: in seconds,
#     milliseconds, microseconds and nanoseconds, the last instant of a leap
#     day, the first instant after midnight, and the last second before the
#     epoch (a negative tick count) name the day and month of their date.
#     Catches ticks divided by the wrong unit's day and a truncating division
#     of a negative tick count.
#   * test_a_null_value_is_a_null_name: a NULL date or timestamp is a NULL
#     name and the rows beside it keep their names; a column of NULLs only is
#     all NULL.
#   * test_the_names_are_a_string_column_and_typed_string: the field the plan
#     declares and the column the evaluator returns are both STRING, and the
#     other extract families keep their types (INT64 for dayofweek, the
#     child's type for date_trunc).
#   * test_the_name_units_are_not_truncations: `_is_trunc_unit` is the run
#     16..25 and `_is_name_unit` is 26 and 27 only, so neither family claims
#     the other's units.
#   * test_a_unit_that_is_not_a_name_is_refused_by_the_name_kernel and
#     test_a_name_of_a_non_temporal_column_is_refused: the two refusals, each
#     by its full message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from batch_eval.eval_column import _eval_column_expr
from byte_buffer.heap_region import HeapRegion
from batch_eval.temporal_names import calendar_name_column
from column_kernels.compiler_helpers import field_for_expr
from plan_expr.col_expr import date_to_days
from plan_expr.expr import (
    EXTRACT_DAYNAME,
    EXTRACT_DAYOFWEEK,
    EXTRACT_MONTHNAME,
    EXTRACT_TRUNC_MICROSECOND,
    EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_YEAR,
    Expr,
    _is_name_unit,
    _is_trunc_unit,
)


# =============================================================================
# Helpers
# =============================================================================


def _date32_batch(days: List[Int], nulls: List[Bool]) raises -> RecordBatch:
    """One nullable DATE32 column `d` of `days` (days since the epoch)."""
    var n = len(days)
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int32](Int32(days[i])))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    var c = Column.from_primitive[DType.int32](arr^)
    c.arrow_type = ArrowType.DATE32
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DATE32, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _ts_batch(
    ticks: List[Int64], nulls: List[Bool], at: ArrowType
) raises -> RecordBatch:
    """One nullable TIMESTAMP column `t` of type `at` holding `ticks`."""
    var n = len(ticks)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int64](ticks[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    var c = Column.from_primitive[DType.int64](arr^)
    c.arrow_type = at
    var sb = SchemaBuilder()
    sb.add_field(Field("t", at, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _no_nulls(n: Int) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(False)
    return out^


def _names(unit: UInt8, ref batch: RecordBatch, col: String) raises -> Column[HeapRegion]:
    return _eval_column_expr(Expr.extract(unit, Expr.col_ref(col)), batch)


def _assert_names(ref c: Column[HeapRegion], want: List[String], what: String) raises:
    assert_true(c.arrow_type == ArrowType.STRING, what + ": not a STRING column")
    assert_equal(c.length(), len(want), what + ": row count")
    var sa = c.as_string()
    for i in range(len(want)):
        assert_false(c.is_null_at(i), what + " row " + String(i) + " is NULL")
        assert_equal(sa.get(i), want[i], what + " row " + String(i))


# =============================================================================
# DATE32
# =============================================================================


def test_every_weekday_over_a_date_column_is_duckdbs_name() raises:
    """DuckDB: 2026-11-15 is a Sunday and 2026-11-21 a Saturday; day -1 is a
    Wednesday, day -165 a Sunday, day -25509 a Wednesday; 2028-02-29 is a
    Tuesday and 2032-02-29 a Sunday."""
    var days = List[Int]()
    for d in range(15, 22):
        days.append(date_to_days(2026, 11, d))
    days.append(-1)
    days.append(-165)
    # ⚠ THE ROW WHERE THE TWO MODULO CONVENTIONS DISAGREE: `days + 4` is
    # -25505, not a multiple of 7, so a truncating `%` answers -4 here.
    days.append(-25509)
    days.append(date_to_days(2028, 2, 29))
    days.append(date_to_days(2032, 2, 29))
    var rb = _date32_batch(days, _no_nulls(len(days)))
    var want = List[String](
        [
            "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
            "Saturday", "Wednesday", "Sunday", "Wednesday", "Tuesday", "Sunday",
        ]
    )
    _assert_names(_names(EXTRACT_DAYNAME, rb, "d"), want, "dayname(d)")


def test_every_month_over_a_date_column_is_duckdbs_name() raises:
    """DuckDB: the 15th of month m of 2027 is month m; 2028-02-29 and
    2032-02-29 are February and 2028-03-01 March; days -1, -165 and -25509
    are December, July and February."""
    var days = List[Int]()
    for m in range(1, 13):
        days.append(date_to_days(2027, m, 15))
    days.append(date_to_days(2028, 2, 29))
    days.append(date_to_days(2032, 2, 29))
    days.append(date_to_days(2028, 3, 1))
    days.append(-1)
    days.append(-165)
    days.append(-25509)
    var rb = _date32_batch(days, _no_nulls(len(days)))
    var want = List[String](
        [
            "January", "February", "March", "April", "May", "June", "July",
            "August", "September", "October", "November", "December",
            "February", "February", "March", "December", "July", "February",
        ]
    )
    _assert_names(_names(EXTRACT_MONTHNAME, rb, "d"), want, "monthname(d)")


# =============================================================================
# TIMESTAMP_*
# =============================================================================


def _ticks_per_second(at: ArrowType) -> Int64:
    if at == ArrowType.TIMESTAMP_S:
        return 1
    if at == ArrowType.TIMESTAMP_MS:
        return 1_000
    if at == ArrowType.TIMESTAMP_US:
        return 1_000_000
    return 1_000_000_000


def test_a_timestamp_names_the_day_of_its_date_in_every_unit() raises:
    """DuckDB: 2028-02-29 23:59:59 is a Tuesday in February; 2032-02-29
    00:00:00 plus one tick is a Sunday in February; one second before the
    epoch is a Wednesday in December."""
    var units = List[ArrowType]()
    units.append(ArrowType.TIMESTAMP_S)
    units.append(ArrowType.TIMESTAMP_MS)
    units.append(ArrowType.TIMESTAMP_US)
    units.append(ArrowType.TIMESTAMP_NS)
    for u in range(len(units)):
        var at = units[u]
        var tps = _ticks_per_second(at)
        var tpd = tps * 86400
        var ticks = List[Int64]()
        # The last tick of a leap day: one tick before the next midnight.
        ticks.append(Int64(date_to_days(2028, 3, 1)) * tpd - 1)
        # One tick after a midnight.
        ticks.append(Int64(date_to_days(2032, 2, 29)) * tpd + 1)
        # One second before the epoch: a negative tick count whose day is -1.
        ticks.append(-tps)
        var rb = _ts_batch(ticks, _no_nulls(3), at)
        var what = "unit " + String(u)
        _assert_names(
            _names(EXTRACT_DAYNAME, rb, "t"),
            List[String](["Tuesday", "Sunday", "Wednesday"]),
            "dayname(t), " + what,
        )
        _assert_names(
            _names(EXTRACT_MONTHNAME, rb, "t"),
            List[String](["February", "February", "December"]),
            "monthname(t), " + what,
        )


# =============================================================================
# NULL
# =============================================================================


def test_a_null_value_is_a_null_name() raises:
    """DuckDB: `dayname(NULL::DATE)` is NULL; the rows beside it keep their
    names (2026-11-16 is a Monday in November)."""
    var day = date_to_days(2026, 11, 16)
    var rb = _date32_batch(
        List[Int]([day, 0, day]), List[Bool]([False, True, False])
    )
    for which in range(2):
        var unit = EXTRACT_DAYNAME if which == 0 else EXTRACT_MONTHNAME
        var want = String("Monday") if which == 0 else String("November")
        var c = _names(unit, rb, "d")
        assert_true(c.arrow_type == ArrowType.STRING)
        assert_equal(c.length(), 3)
        assert_equal(c.null_count(), 1)
        assert_false(c.is_null_at(0))
        assert_true(c.is_null_at(1))
        assert_false(c.is_null_at(2))
        assert_equal(c.as_string().get(0), want)
        assert_equal(c.as_string().get(2), want)

    var tpd = Int64(86400 * 1_000_000)
    var rb_t = _ts_batch(
        List[Int64]([Int64(day) * tpd + 1, Int64(0)]),
        List[Bool]([False, True]),
        ArrowType.TIMESTAMP_US,
    )
    var c_t = _names(EXTRACT_DAYNAME, rb_t, "t")
    assert_equal(c_t.null_count(), 1)
    assert_equal(c_t.as_string().get(0), "Monday")
    assert_true(c_t.is_null_at(1))

    # A column of NULLs only: every name is NULL.
    var rb_n = _date32_batch(List[Int]([0, 0]), List[Bool]([True, True]))
    var c_n = _names(EXTRACT_MONTHNAME, rb_n, "d")
    assert_equal(c_n.length(), 2)
    assert_equal(c_n.null_count(), 2)
    assert_true(c_n.is_null_at(0))
    assert_true(c_n.is_null_at(1))


# =============================================================================
# Types and unit families
# =============================================================================


def test_the_names_are_a_string_column_and_typed_string() raises:
    """The declared field and the evaluated column agree: STRING, nullable."""
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DATE32, True))
    var schema = sb.build()
    for which in range(2):
        var unit = EXTRACT_DAYNAME if which == 0 else EXTRACT_MONTHNAME
        var f = field_for_expr(Expr.extract(unit, Expr.col_ref("d")), schema)
        assert_true(f.arrow_type == ArrowType.STRING, "the declared type")
        assert_true(f.nullable, "a NULL date is a NULL name")
    # The other families keep their types.
    var f_dow = field_for_expr(
        Expr.extract(EXTRACT_DAYOFWEEK, Expr.col_ref("d")), schema
    )
    assert_true(f_dow.arrow_type == ArrowType.INT64, "dayofweek stays INT64")
    var f_tr = field_for_expr(
        Expr.extract(EXTRACT_TRUNC_MONTH, Expr.col_ref("d")), schema
    )
    assert_true(f_tr.arrow_type == ArrowType.DATE32, "date_trunc keeps DATE32")

    var rb = _date32_batch(List[Int]([date_to_days(2026, 11, 16)]), _no_nulls(1))
    var c = _names(EXTRACT_DAYNAME, rb, "d")
    assert_true(c.arrow_type == ArrowType.STRING, "the evaluated type")
    var c_dow = _eval_column_expr(
        Expr.extract(EXTRACT_DAYOFWEEK, Expr.col_ref("d")), rb
    )
    assert_true(c_dow.arrow_type == ArrowType.INT64)
    assert_equal(Int(c_dow.as_primitive[DType.int64]().get(0)), 1)


def test_the_name_units_are_not_truncations() raises:
    assert_true(_is_trunc_unit(EXTRACT_TRUNC_YEAR))
    assert_true(_is_trunc_unit(EXTRACT_TRUNC_MICROSECOND))
    assert_false(_is_trunc_unit(EXTRACT_DAYNAME))
    assert_false(_is_trunc_unit(EXTRACT_MONTHNAME))
    assert_false(_is_trunc_unit(EXTRACT_DAYOFWEEK))
    assert_true(_is_name_unit(EXTRACT_DAYNAME))
    assert_true(_is_name_unit(EXTRACT_MONTHNAME))
    assert_false(_is_name_unit(EXTRACT_TRUNC_MICROSECOND))
    assert_false(_is_name_unit(EXTRACT_DAYOFWEEK))
    assert_equal(Int(EXTRACT_DAYNAME), 26)
    assert_equal(Int(EXTRACT_MONTHNAME), 27)


# =============================================================================
# Refusals
# =============================================================================


def test_a_unit_that_is_not_a_name_is_refused_by_the_name_kernel() raises:
    var rb = _date32_batch(List[Int]([0]), _no_nulls(1))
    var raised = False
    try:
        _ = calendar_name_column(
            rb.column_at(0), ArrowType.DATE32, EXTRACT_DAYOFWEEK
        )
    except e:
        raised = True
        assert_equal(
            String(e),
            "PipelineCompiler: EXPR_EXTRACT unit 7 is not a calendar name unit",
        )
    assert_true(raised, "dayofweek is not a name unit")


def test_a_name_of_a_non_temporal_column_is_refused() raises:
    var arr = PrimitiveArray[DType.int64].allocate(1)
    arr.set(0, Scalar[DType.int64](3))
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    var rb = rbb.build(sb.build())
    var raised = False
    try:
        _ = _names(EXTRACT_DAYNAME, rb, "x")
    except e:
        raised = True
        assert_equal(
            String(e),
            "PipelineCompiler: EXPR_EXTRACT child must be DATE32 or"
            " TIMESTAMP_*, got type_id="
            + String(Int(ArrowType.INT64.type_id))
            + " and the batch schema does not declare it temporal either",
        )
    assert_true(raised, "an INT64 column has no weekday")


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_weekday_over_a_date_column_is_duckdbs_name]()
    suite.test[test_every_month_over_a_date_column_is_duckdbs_name]()
    suite.test[test_a_timestamp_names_the_day_of_its_date_in_every_unit]()
    suite.test[test_a_null_value_is_a_null_name]()
    suite.test[test_the_names_are_a_string_column_and_typed_string]()
    suite.test[test_the_name_units_are_not_truncations]()
    suite.test[test_a_unit_that_is_not_a_name_is_refused_by_the_name_kernel]()
    suite.test[test_a_name_of_a_non_temporal_column_is_refused]()
    suite^.run()

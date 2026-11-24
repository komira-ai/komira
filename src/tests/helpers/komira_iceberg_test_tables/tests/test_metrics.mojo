# Per-column counts and bounds, and the single-value serialization.
#
#   * test_integer_columns_have_little_endian_bounds: long (8 bytes), int and
#     date (4 bytes) bounds are the two's-complement little-endian minimum and
#     maximum, negative values included; nulls are counted and never a bound.
#   * test_string_bounds_compare_as_unsigned_bytes: "B" < "a" < "ab" < "b" and
#     the serialization is the UTF-8 bytes; a prefix sorts first.
#   * test_double_bounds_leave_out_nan: NaN is counted in nan_count and is no
#     bound; a column of NaN and nulls only has no bounds; the NaN count of a
#     column that is not a double is -1.
#   * test_boolean_bounds: false < true, one byte.
#   * test_an_empty_or_all_null_column_has_no_bounds.
#   * test_single_values_serialize_as_the_spec_says: exact bytes of each type.
#   * test_file_metrics_cover_every_column_in_order.

from std.math import nan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_iceberg_test_tables.metrics import (
    bytes_less,
    column_metrics,
    file_metrics,
    single_value_bytes,
)
from komira_iceberg_test_tables.table_model import (
    TT_BOOLEAN,
    TT_DATE,
    TT_DOUBLE,
    TT_INT,
    TT_LONG,
    TT_STRING,
    TableCell,
    TableColumn,
    TableRow,
    bool_cell,
    double_cell,
    int_cell,
    null_cell,
    string_cell,
)


def _rows(var cells: List[TableCell]) -> List[TableRow]:
    """One single-cell row per cell."""
    var out = List[TableRow]()
    for i in range(len(cells)):
        var one = List[TableCell]()
        one.append(cells[i].copy())
        out.append(TableRow(one^))
    return out^


def _same(got: List[UInt8], want: List[Int]) -> Bool:
    if len(got) != len(want):
        return False
    for i in range(len(want)):
        if Int(got[i]) != want[i]:
            return False
    return True


def test_integer_columns_have_little_endian_bounds() raises:
    var cells = List[TableCell]()
    cells.append(int_cell(5))
    cells.append(null_cell())
    cells.append(int_cell(-2))
    cells.append(int_cell(300))
    var rows = _rows(cells^)
    var long_m = column_metrics(TableColumn(1, "a", TT_LONG, False), rows, 0)
    assert_equal(Int(long_m.value_count), 4)
    assert_equal(Int(long_m.null_count), 1)
    assert_equal(Int(long_m.nan_count), -1)
    assert_true(long_m.has_bounds)
    assert_true(_same(long_m.lower, [254, 255, 255, 255, 255, 255, 255, 255]))
    assert_true(_same(long_m.upper, [44, 1, 0, 0, 0, 0, 0, 0]))
    var int_m = column_metrics(TableColumn(2, "b", TT_INT, False), rows, 0)
    assert_true(_same(int_m.lower, [254, 255, 255, 255]))
    assert_true(_same(int_m.upper, [44, 1, 0, 0]))
    var date_m = column_metrics(TableColumn(3, "c", TT_DATE, False), rows, 0)
    assert_equal(date_m.field_id, 3)
    assert_true(_same(date_m.upper, [44, 1, 0, 0]))


def test_string_bounds_compare_as_unsigned_bytes() raises:
    var cells = List[TableCell]()
    cells.append(string_cell("b"))
    cells.append(string_cell("ab"))
    cells.append(string_cell("B"))
    cells.append(string_cell("a"))
    cells.append(null_cell())
    var m = column_metrics(TableColumn(1, "s", TT_STRING, False), _rows(cells^), 0)
    assert_true(_same(m.lower, [66]))
    assert_true(_same(m.upper, [98]))
    assert_equal(Int(m.null_count), 1)
    assert_true(bytes_less("a", "ab"))
    assert_false(bytes_less("ab", "a"))
    assert_false(bytes_less("ab", "ab"))
    assert_true(bytes_less("B", "a"))
    assert_false(bytes_less("b", "B"))


def test_double_bounds_leave_out_nan() raises:
    var cells = List[TableCell]()
    cells.append(double_cell(2.5))
    cells.append(double_cell(nan[DType.float64]()))
    cells.append(double_cell(-1.0))
    cells.append(null_cell())
    cells.append(double_cell(nan[DType.float64]()))
    var m = column_metrics(TableColumn(1, "d", TT_DOUBLE, False), _rows(cells^), 0)
    assert_equal(Int(m.nan_count), 2)
    assert_equal(Int(m.null_count), 1)
    assert_equal(Int(m.value_count), 5)
    # -1.0 and 2.5 as little-endian IEEE-754 binary64.
    assert_true(_same(m.lower, [0, 0, 0, 0, 0, 0, 240, 191]))
    assert_true(_same(m.upper, [0, 0, 0, 0, 0, 0, 4, 64]))
    var only = List[TableCell]()
    only.append(double_cell(nan[DType.float64]()))
    only.append(null_cell())
    var none = column_metrics(TableColumn(1, "d", TT_DOUBLE, False), _rows(only^), 0)
    assert_false(none.has_bounds)
    assert_equal(Int(none.nan_count), 1)


def test_boolean_bounds() raises:
    var cells = List[TableCell]()
    cells.append(bool_cell(True))
    cells.append(bool_cell(False))
    var m = column_metrics(TableColumn(1, "p", TT_BOOLEAN, False), _rows(cells^), 0)
    assert_true(_same(m.lower, [0]))
    assert_true(_same(m.upper, [1]))


def test_an_empty_or_all_null_column_has_no_bounds() raises:
    var column = TableColumn(1, "a", TT_LONG, False)
    var empty = column_metrics(column, List[TableRow](), 0)
    assert_equal(Int(empty.value_count), 0)
    assert_false(empty.has_bounds)
    assert_equal(len(empty.lower), 0)
    var cells = List[TableCell]()
    cells.append(null_cell())
    cells.append(null_cell())
    var nulls = column_metrics(column, _rows(cells^), 0)
    assert_equal(Int(nulls.null_count), 2)
    assert_false(nulls.has_bounds)


def test_single_values_serialize_as_the_spec_says() raises:
    assert_true(_same(single_value_bytes(TT_LONG, int_cell(1)), [1, 0, 0, 0, 0, 0, 0, 0]))
    assert_true(_same(single_value_bytes(TT_INT, int_cell(-1)), [255, 255, 255, 255]))
    assert_true(_same(single_value_bytes(TT_DATE, int_cell(20819)), [83, 81, 0, 0]))
    assert_true(_same(single_value_bytes(TT_DOUBLE, double_cell(1.0)), [0, 0, 0, 0, 0, 0, 240, 63]))
    assert_true(_same(single_value_bytes(TT_STRING, string_cell("hé")), [104, 195, 169]))
    assert_true(_same(single_value_bytes(TT_BOOLEAN, bool_cell(True)), [1]))
    assert_true(_same(single_value_bytes(TT_BOOLEAN, bool_cell(False)), [0]))


def test_file_metrics_cover_every_column_in_order() raises:
    var columns = List[TableColumn]()
    columns.append(TableColumn(7, "a", TT_LONG, True))
    columns.append(TableColumn(9, "s", TT_STRING, False))
    var rows = List[TableRow]()
    var r0 = List[TableCell]()
    r0.append(int_cell(4))
    r0.append(string_cell("x"))
    rows.append(TableRow(r0^))
    var r1 = List[TableCell]()
    r1.append(int_cell(6))
    r1.append(null_cell())
    rows.append(TableRow(r1^))
    var all = file_metrics(columns, rows)
    assert_equal(len(all), 2)
    assert_equal(all[0].field_id, 7)
    assert_equal(all[1].field_id, 9)
    assert_equal(Int(all[0].null_count), 0)
    assert_equal(Int(all[1].null_count), 1)
    assert_true(_same(all[1].upper, [120]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

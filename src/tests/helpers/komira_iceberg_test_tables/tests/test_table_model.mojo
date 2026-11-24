# The values a test table is described with.
#
#   * test_every_type_has_its_iceberg_spelling: long, int, string, double, date
#     and boolean are the schema's spellings; any other tag is refused by name.
#   * test_cells_keep_their_values: int, boolean, double and string cells hold
#     their value in the field the column type reads, a null holds none.
#   * test_integer_like_types: long, int, date and boolean keep their cells in
#     `i`; string and double do not.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_iceberg_test_tables.table_model import (
    TT_BOOLEAN,
    TT_DATE,
    TT_DOUBLE,
    TT_INT,
    TT_LONG,
    TT_STRING,
    bool_cell,
    double_cell,
    iceberg_type_name,
    int_cell,
    is_int_like,
    null_cell,
    string_cell,
)


def test_every_type_has_its_iceberg_spelling() raises:
    assert_equal(iceberg_type_name(TT_LONG), "long")
    assert_equal(iceberg_type_name(TT_INT), "int")
    assert_equal(iceberg_type_name(TT_STRING), "string")
    assert_equal(iceberg_type_name(TT_DOUBLE), "double")
    assert_equal(iceberg_type_name(TT_DATE), "date")
    assert_equal(iceberg_type_name(TT_BOOLEAN), "boolean")
    var message = String()
    try:
        _ = iceberg_type_name(99)
    except e:
        message = String(e)
    assert_equal(message, "komira_iceberg_test_tables: unknown column type 99")


def test_cells_keep_their_values() raises:
    var n = null_cell()
    assert_true(n.is_null)
    var i = int_cell(-7)
    assert_false(i.is_null)
    assert_equal(Int(i.i), -7)
    assert_equal(Int(bool_cell(True).i), 1)
    assert_equal(Int(bool_cell(False).i), 0)
    assert_equal(double_cell(2.5).f, 2.5)
    assert_equal(string_cell("abc").s, "abc")
    assert_false(string_cell("").is_null)


def test_integer_like_types() raises:
    assert_true(is_int_like(TT_LONG))
    assert_true(is_int_like(TT_INT))
    assert_true(is_int_like(TT_DATE))
    assert_true(is_int_like(TT_BOOLEAN))
    assert_false(is_int_like(TT_STRING))
    assert_false(is_int_like(TT_DOUBLE))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# A CSV read with has_header=False names its columns as DuckDB does
# =============================================================================
#
# DuckDB's read_csv names the columns of a file with no header line column0,
# column1, ...: zero-based, no separator, and the index padded with leading
# zeros to the digit count of the last index (column00 .. column11 for twelve
# columns). Every reader of this package that builds names without a header
# gives those names:
#
#   test_no_header_names_are_column0_column1_column2
#                                   the serial reader, three columns, and
#                                   both lines are rows.
#   test_one_column_is_column0      the smallest file: one column, no padding.
#   test_ten_columns_are_not_padded the last index, 9, has one digit, so
#                                   column0 .. column9.
#   test_eleven_columns_are_padded_to_two_digits
#                                   the last index, 10, has two digits, so
#                                   column00 .. column10.
#   test_schema_sample_gives_the_same_names
#                                   read_csv_bytes_to_schema, the path a
#                                   binder infers a table's schema with.
#   test_parallel_reader_gives_the_same_names
#                                   the parallel reader over a file of over
#                                   2 MiB, split across four workers, with
#                                   every line a row.
#   test_a_header_still_names_the_columns
#                                   has_header=True keeps the header's names.
#   test_header_free_column_name    the naming function at its boundaries:
#                                   index 0 of 1, 9 of 10, 10 of 11, 0 and 99
#                                   of 100, 100 of 101.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.schema import RecordBatch, Schema

from csv import (
    CsvReadOptions,
    Rfc4180,
    header_free_column_name,
    read_csv_bytes_to_batch,
    read_csv_bytes_to_batch_parallel,
)
from csv.reader import read_csv_bytes_to_schema


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _no_header() -> CsvReadOptions:
    var o = CsvReadOptions()
    o.has_header = False
    return o^


def _row(n: Int, first: Int) -> String:
    """One line of `n` integer cells, `first`, `first + 1`, ..."""
    var s = String("")
    for i in range(n):
        if i > 0:
            s += ","
        s += String(first + i)
    s += "\n"
    return s^


def _names(rb: RecordBatch) raises -> String:
    var s = String("")
    for i in range(rb.num_columns()):
        if i > 0:
            s += " "
        s += String(rb.schema.field_at(i).name)
    return s^


def _schema_names(sc: Schema) raises -> String:
    var s = String("")
    for i in range(sc.num_columns()):
        if i > 0:
            s += " "
        s += String(sc.field_at_unchecked(i).name)
    return s^


def test_no_header_names_are_column0_column1_column2() raises:
    var buf = _bytes("1,2,3\n4,5,6\n")
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), _no_header())
    assert_equal(_names(rb), "column0 column1 column2")
    assert_equal(rb.num_rows(), 2)


def test_one_column_is_column0() raises:
    var buf = _bytes("7\n8\n")
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), _no_header())
    assert_equal(_names(rb), "column0")
    assert_equal(rb.num_rows(), 2)


def test_ten_columns_are_not_padded() raises:
    var buf = _bytes(_row(10, 0) + _row(10, 10))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), _no_header())
    assert_equal(
        _names(rb),
        "column0 column1 column2 column3 column4 column5 column6 column7"
        " column8 column9",
    )


def test_eleven_columns_are_padded_to_two_digits() raises:
    var buf = _bytes(_row(11, 0))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), _no_header())
    assert_equal(
        _names(rb),
        "column00 column01 column02 column03 column04 column05 column06"
        " column07 column08 column09 column10",
    )


def test_schema_sample_gives_the_same_names() raises:
    var buf = _bytes("a,1\nb,2\n")
    var sc = read_csv_bytes_to_schema[Rfc4180](Span(buf), _no_header())
    assert_equal(_schema_names(sc), "column0 column1")


def test_parallel_reader_gives_the_same_names() raises:
    # 100,000 lines of about 26 bytes: over 2 MiB, past the parallel
    # reader's 1 MiB threshold, so the read is split across the workers.
    var s = String("")
    for i in range(100_000):
        s += String(i) + "," + String(i * 10) + ",padding-cell\n"
    var buf = _bytes(s)
    assert_true(len(buf) > 2 * 1024 * 1024, String(len(buf)))
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), _no_header(), n_workers=4
    )
    assert_equal(_names(rb), "column0 column1 column2")
    assert_equal(rb.num_rows(), 100_000)


def test_a_header_still_names_the_columns() raises:
    var buf = _bytes("id,name\n1,a\n")
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), CsvReadOptions())
    assert_equal(_names(rb), "id name")
    assert_equal(rb.num_rows(), 1)


def test_header_free_column_name() raises:
    assert_equal(header_free_column_name(0, 1), "column0")
    assert_equal(header_free_column_name(9, 10), "column9")
    assert_equal(header_free_column_name(0, 11), "column00")
    assert_equal(header_free_column_name(10, 11), "column10")
    assert_equal(header_free_column_name(0, 100), "column00")
    assert_equal(header_free_column_name(99, 100), "column99")
    assert_equal(header_free_column_name(5, 101), "column005")
    assert_equal(header_free_column_name(100, 101), "column100")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

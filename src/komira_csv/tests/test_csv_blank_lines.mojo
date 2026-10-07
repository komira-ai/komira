# =============================================================================
# Blank lines in the CSV readers (komira-ai/komira#449 follow-up).
# =============================================================================
#
# Policy (`record_shape.mojo`): a fully blank line -- zero bytes between two
# line terminators -- in a file with two or more columns is SKIPPED, anywhere
# in the file. It carries no data, so nothing is lost, and pandas does the same
# by default. It still counts for the line number in a refusal, but not as a
# record. In a one-column file a blank line stays a record with one empty field
# (a NULL). A line holding `""` is not blank and is refused as a short record
# (`test_csv_record_shape`).
#
# Mutants that turn this red: make `ScannedCells.row_is_blank` return False
# (every multi-column case refuses a 1-field record); drop the
# `drop_blank_rows` call (the batch keeps a NULL row, row counts are off by
# the blank lines); stop subtracting blank rows in `_record_location` (the
# record number after a blank line is too high).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch

from komira_csv import CsvReadOptions, Rfc4180, Excel, read_csv_bytes_to_batch
from komira_csv.reader import read_csv_bytes_to_schema


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _read[V: Int = 2](data: String) raises -> RecordBatch:
    var buf = _bytes(data)
    return read_csv_bytes_to_batch[Rfc4180, V](Span(buf), CsvReadOptions())


def _col_a(rb: RecordBatch) raises -> List[Int]:
    var out = List[Int]()
    ref c = rb.column_at(0)
    var arr = c.as_primitive[DType.int64]()
    for i in range(rb.num_rows()):
        assert_true(not arr.is_null(i), "no NULL row may come from a blank line")
        out.append(Int(arr.get(i)))
    return out^


def _assert_a(rb: RecordBatch, want: List[Int], label: String) raises:
    assert_equal(rb.num_columns(), 2, label)
    var got = _col_a(rb)
    assert_equal(len(got), len(want), label + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ": a[" + String(i) + "]")


def test_blank_line_at_end() raises:
    var want: List[Int] = [1]
    _assert_a(_read(String("a,b\n1,2\n\n")), want, "LF")
    _assert_a(_read(String("a,b\r\n1,2\r\n\r\n")), want, "CRLF")


def test_blank_line_in_middle() raises:
    var want: List[Int] = [1, 3]
    _assert_a(_read[1](String("a,b\n1,2\n\n3,4\n")), want, "phase 1")
    _assert_a(_read[2](String("a,b\n1,2\n\n3,4\n")), want, "phase 2")
    _assert_a(_read[3](String("a,b\n1,2\n\n3,4\n")), want, "phase 3")
    _assert_a(_read(String("a,b\r\n1,2\r\n\r\n3,4\r\n")), want, "CRLF")


def test_several_consecutive_blank_lines() raises:
    var want: List[Int] = [1, 3, 5]
    _assert_a(
        _read(String("a,b\n\n\n1,2\n\n\n\n3,4\n5,6\n\n\n")), want, "LF"
    )
    _assert_a(
        _read(String("a,b\r\n\r\n1,2\r\n\r\n\r\n3,4\r\n5,6\r\n\r\n")),
        want,
        "CRLF",
    )


def test_blank_lines_excel_dialect() raises:
    var buf = _bytes(String("a,b\n1,2\n\n3,4\n\n"))
    var rb = read_csv_bytes_to_batch[Excel](Span(buf), CsvReadOptions())
    var want: List[Int] = [1, 3]
    _assert_a(rb, want, "excel")


def test_blank_lines_with_projection() raises:
    var buf = _bytes(String("a,b\n1,2\n\n3,4\n"))
    var opts = CsvReadOptions()
    opts.with_projection(String("b"))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_rows(), 2)
    ref c = rb.column_at(0)
    var arr = c.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 2)
    assert_equal(Int(arr.get(1)), 4)


def test_schema_entry_skips_blank_lines() raises:
    var buf = _bytes(String("a,b\n1,2\n\n3,4\n\n"))
    var schema = read_csv_bytes_to_schema[Rfc4180](Span(buf), CsvReadOptions())
    assert_equal(schema.num_columns(), 2)
    assert_true(schema.field_at(0).arrow_type == ArrowType.INT64)
    assert_true(schema.field_at(1).arrow_type == ArrowType.INT64)


def test_one_column_blank_line_is_a_null_record() raises:
    var rb = _read(String("t\na\n\nb\n"))
    assert_equal(rb.num_rows(), 3)
    ref c = rb.column_at(0)
    var arr = c.as_string()
    assert_equal(arr.get(0), String("a"))
    assert_true(arr.is_null(1), "the blank line is a NULL record")
    assert_equal(arr.get(2), String("b"))


def _refusal(data: String) raises -> String:
    var buf = _bytes(data)
    try:
        _ = read_csv_bytes_to_batch[Rfc4180](Span(buf), CsvReadOptions())
    except e:
        return String(e)
    assert_true(False, "expected a refusal for " + data)
    return String("")


def test_refusal_after_blank_lines_counts_lines_not_records() raises:
    """Two blank lines then a short record: it is record 3 (blank lines are
    not records) on line 5 (they are lines), at byte 10."""
    var msg = _refusal(String("a,b\n1,2\n\n\n3\n"))
    assert_true(
        msg.find("CSV record 3 (line 5, byte offset 10) has 1 field but the"
                 " header has 2") >= 0,
        msg,
    )
    var crlf = _refusal(String("a,b\r\n1,2\r\n\r\n3,4,5\r\n"))
    assert_true(
        crlf.find("CSV record 3 (line 4, byte offset 12) has 3 fields") >= 0,
        crlf,
    )


def main() raises:
    test_blank_line_at_end()
    test_blank_line_in_middle()
    test_several_consecutive_blank_lines()
    test_blank_lines_excel_dialect()
    test_blank_lines_with_projection()
    test_schema_entry_skips_blank_lines()
    test_one_column_blank_line_is_a_null_record()
    test_refusal_after_blank_lines_counts_lines_not_records()
    print("test_csv_blank_lines: 8/8 PASS")

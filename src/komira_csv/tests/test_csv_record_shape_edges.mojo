# =============================================================================
# Record-shape edge cases (komira-ai/komira#449, second follow-up).
# =============================================================================
#
# A. A closing quote that is the LAST byte of the input (no trailing newline)
#    closes the record. The Posix arm of every scanner used to set the next
#    field's start there and let the end-of-input flush append a phantom empty
#    cell, so `a,b\n1,"x"` read as three fields and was refused. Pinned for
#    Rfc4180, Excel and Posix through the reader (scanner variants 1, 2, 3) and
#    on the scanners directly (the flat-buffer, projected and List[Row] ones).
#    Mutant: restore `cell_start = pos; continue` in a Posix arm.
# B. Blank lines BEFORE the header (or before the first record of a headerless
#    file) are skipped like any other blank line; the header used to become
#    `[""]`. They still count for line numbers. Mutant: drop the
#    `skip_leading_blank_lines` call.
# C. What is NOT blank: a line of spaces is a record with one field (refused
#    in a two-column file); a lone delimiter is a record of two empty fields
#    (NULL, NULL). And a quote violation after skipped blank lines reports
#    the record, line and offset counted correctly.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch

from komira_csv import (
    CsvReadOptions,
    Rfc4180,
    Excel,
    Posix,
    read_csv_bytes_to_batch,
)
from komira_csv.csv_scanner_phase1 import (
    scan_csv_phase1,
    scan_csv_phase2_movemask,
    scan_csv_phase3_pclmulqdq,
    scan_csv_phase1_into_cells,
    scan_csv_phase2_movemask_into_cells,
    scan_csv_phase3_pclmulqdq_into_cells,
    scan_csv_phase2_movemask_projected,
)
from komira_csv.quote_styles import QuoteStyle
from komira_csv.reader import read_csv_bytes_to_schema


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _refusal(data: String) raises -> String:
    var buf = _bytes(data)
    try:
        _ = read_csv_bytes_to_batch[Rfc4180](Span(buf), CsvReadOptions())
    except e:
        return String(e)
    assert_true(False, "expected a refusal for " + data)
    return String("")


def _assert_has(msg: String, part: String) raises:
    assert_true(msg.find(part) >= 0, "want `" + part + "`; got: " + msg)


# -----------------------------------------------------------------------------
# A. Closing quote at end of input.
# -----------------------------------------------------------------------------


def _check_eof_quote[Q: QuoteStyle, V: Int](label: String) raises:
    var buf = _bytes(String('a,b\n1,"x"'))
    var rb = read_csv_bytes_to_batch[Q, V](Span(buf), CsvReadOptions())
    assert_equal(rb.num_rows(), 1, label)
    assert_equal(rb.num_columns(), 2, label)
    ref c = rb.column_at(1)
    assert_equal(c.as_string().get(0), String("x"), label)


def test_closing_quote_at_eof_every_dialect_and_variant() raises:
    _check_eof_quote[Rfc4180, 1]("rfc4180 v1")
    _check_eof_quote[Rfc4180, 2]("rfc4180 v2")
    _check_eof_quote[Rfc4180, 3]("rfc4180 v3")
    _check_eof_quote[Excel, 1]("excel v1")
    _check_eof_quote[Excel, 2]("excel v2")
    _check_eof_quote[Excel, 3]("excel v3")
    _check_eof_quote[Posix, 1]("posix v1")
    _check_eof_quote[Posix, 2]("posix v2")
    _check_eof_quote[Posix, 3]("posix v3")


def _check_flat_cells[Q: QuoteStyle](label: String) raises:
    var buf = _bytes(String('a,b\n1,"x"'))
    var d = UInt8(ord(","))
    var q = UInt8(ord('"'))
    var c1 = scan_csv_phase1_into_cells[Q](Span(buf), d, q)
    var c2 = scan_csv_phase2_movemask_into_cells[Q](Span(buf), d, q)
    var c3 = scan_csv_phase3_pclmulqdq_into_cells[Q](Span(buf), d, q)
    var wanted: List[Bool] = [True, True]
    var cp = scan_csv_phase2_movemask_projected[Q](Span(buf), d, q, wanted, 2)
    assert_equal(c1.num_rows(), 2, label + " phase1 rows")
    assert_equal(c1.num_cells_in_row(1), 2, label + " phase1 cells")
    assert_equal(c2.num_cells_in_row(1), 2, label + " phase2 cells")
    assert_equal(c3.num_cells_in_row(1), 2, label + " phase3 cells")
    assert_equal(cp.num_rows(), 2, label + " projected rows")
    assert_equal(cp.num_cells_in_row(1), 2, label + " projected cells")
    var r1 = scan_csv_phase1[Q](Span(buf), d, q)
    var r2 = scan_csv_phase2_movemask[Q](Span(buf), d, q)
    var r3 = scan_csv_phase3_pclmulqdq[Q](Span(buf), d, q)
    assert_equal(len(r1), 2, label + " legacy phase1 rows")
    assert_equal(len(r1[1].cells), 2, label + " legacy phase1 cells")
    assert_equal(len(r2[1].cells), 2, label + " legacy phase2 cells")
    assert_equal(len(r3[1].cells), 2, label + " legacy phase3 cells")


def test_closing_quote_at_eof_every_scanner() raises:
    _check_flat_cells[Rfc4180]("rfc4180")
    _check_flat_cells[Excel]("excel")
    _check_flat_cells[Posix]("posix")


# -----------------------------------------------------------------------------
# B. Blank lines before the header / first record.
# -----------------------------------------------------------------------------


def _check_ab(rb: RecordBatch, n: Int, label: String) raises:
    assert_equal(rb.num_columns(), 2, label)
    assert_equal(rb.num_rows(), n, label)
    assert_equal(rb.schema.field_name(0), String("a"), label)
    assert_equal(rb.schema.field_name(1), String("b"), label)


def test_leading_blank_lines_before_header() raises:
    var lf = _bytes(String("\na,b\n1,2\n"))
    _check_ab(read_csv_bytes_to_batch[Rfc4180](Span(lf), CsvReadOptions()), 1, "LF")
    var crlf = _bytes(String("\r\n\r\na,b\r\n1,2\r\n3,4\r\n"))
    _check_ab(read_csv_bytes_to_batch[Rfc4180, 1](Span(crlf), CsvReadOptions()), 2, "CRLF v1")
    _check_ab(read_csv_bytes_to_batch[Rfc4180, 3](Span(crlf), CsvReadOptions()), 2, "CRLF v3")
    _check_ab(read_csv_bytes_to_batch[Excel](Span(crlf), CsvReadOptions()), 2, "excel")
    _check_ab(read_csv_bytes_to_batch[Posix](Span(crlf), CsvReadOptions()), 2, "posix")


def test_leading_blank_lines_one_column_header() raises:
    var buf = _bytes(String("\n\nt\nx\n\ny\n"))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), CsvReadOptions())
    assert_equal(rb.schema.field_name(0), String("t"))
    assert_equal(rb.num_rows(), 3, "x, NULL (the inner blank line), y")


def test_leading_blank_lines_headerless() raises:
    var buf = _bytes(String("\n\r\n1,2\n3,4\n"))
    var opts = CsvReadOptions()
    opts.has_header = False
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_columns(), 2)
    assert_equal(rb.num_rows(), 2)
    ref c = rb.column_at(0)
    var arr = c.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 1)
    assert_equal(Int(arr.get(1)), 3)


def test_leading_blank_lines_schema_entry() raises:
    var buf = _bytes(String("\n\na,b\n1,2\n"))
    var schema = read_csv_bytes_to_schema[Rfc4180](Span(buf), CsvReadOptions())
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), String("a"))
    assert_true(schema.field_at(1).arrow_type == ArrowType.INT64)


def test_leading_blank_lines_count_in_later_error() raises:
    var m = _refusal(String("\n\na,b\n1,2\n3\n"))
    _assert_has(m, "CSV record 3 (line 5, byte offset 10) has 1 field")
    var c = _refusal(String("\r\n\r\na,b\r\n1,2,3\r\n"))
    _assert_has(c, "CSV record 2 (line 4, byte offset 9) has 3 fields")
    var q = _refusal(String('\n\na,b\n"x"y,2\n'))
    _assert_has(
        q,
        "CSV record 2 (line 4, byte offset 6), field 1 ('a'): byte 0x79 ('y')"
        " at byte offset 9",
    )


# -----------------------------------------------------------------------------
# C. What is not blank; quote violation after skipped blank lines.
# -----------------------------------------------------------------------------


def test_spaces_only_line_is_not_blank() raises:
    var m = _refusal(String("a,b\n1,2\n  \n3,4\n"))
    _assert_has(m, "CSV record 3 (line 3, byte offset 8) has 1 field but the header has 2")


def test_lone_delimiter_line_is_two_nulls() raises:
    var buf = _bytes(String("a,b\n1,2\n,\n3,4\n"))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), CsvReadOptions())
    assert_equal(rb.num_rows(), 3)
    ref ca = rb.column_at(0)
    var a = ca.as_primitive[DType.int64]()
    ref cb = rb.column_at(1)
    var b = cb.as_primitive[DType.int64]()
    assert_true(a.is_null(1), "a is NULL on the `,` line")
    assert_true(b.is_null(1), "b is NULL on the `,` line")
    assert_equal(Int(a.get(2)), 3)


def test_quote_violation_after_skipped_blank_lines() raises:
    var m = _refusal(String('a,b\n\n1,2\n\n"x"y,2\n'))
    _assert_has(
        m,
        "CSV record 3 (line 5, byte offset 10), field 1 ('a'): byte 0x79 ('y')"
        " at byte offset 13",
    )


def main() raises:
    test_closing_quote_at_eof_every_dialect_and_variant()
    test_closing_quote_at_eof_every_scanner()
    test_leading_blank_lines_before_header()
    test_leading_blank_lines_one_column_header()
    test_leading_blank_lines_headerless()
    test_leading_blank_lines_schema_entry()
    test_leading_blank_lines_count_in_later_error()
    test_spaces_only_line_is_not_blank()
    test_lone_delimiter_line_is_two_nulls()
    test_quote_violation_after_skipped_blank_lines()
    print("test_csv_record_shape_edges: 10/10 PASS")

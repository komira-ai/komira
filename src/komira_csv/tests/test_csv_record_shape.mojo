# =============================================================================
# Record-shape refusals in the single-thread CSV reader (komira-ai/komira#449).
# =============================================================================
#
# Before this test the reader dropped data in silence on two malformed shapes:
#
#   1. a byte after a closing quote that is not the delimiter or a line end:
#      `"Ålesund "Å""` (a writer that forgot to double the inner quotes) read
#      back as `Ålesund `. The scanner closed the field at the second quote,
#      opened a new field at `Å`, and the record grew a cell the header has no
#      column for.
#   2. a record with more fields than the header: the extra cell was never
#      read by any column builder.
#
# A record with FEWER fields than the header was null-padded. RFC 4180 says
# every record has the same number of fields, so all three now raise, naming
# the record number, the line, the field and the problem. These tests feed the
# exact bytes from the issue, with and without a projection (the issue was seen
# with one, and a projection that leaves the bad field out must still refuse:
# the record is malformed, whichever columns are read), across every scanner
# variant the single-thread reader can select, the runtime-dispatch entry, the
# Excel and Posix dialects, and the schema-only entry.
#
# Each case names the mutant that turns it red:
#   * test_issue_input_1_*   -- delete the quote-violation raise in
#     `record_shape.check_csv_record_shape`, or the `note_quote_violation`
#     call in a scanner's QUOTE_IN_QUOTED fallthrough.
#   * test_issue_input_2_* / test_too_many_* -- drop the `n > num_cols` arm.
#   * test_too_few_*       -- drop the `n < num_cols` arm.
#   * test_well_formed_*   -- an over-eager check (e.g. counting a CRLF or a
#     quoted last field at EOF as a violation) turns these red instead.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.schema import RecordBatch

from komira_csv import (
    CsvReadOptions,
    Rfc4180,
    Excel,
    Posix,
    QUOTE_STYLE_TAG_EXCEL,
    QUOTE_STYLE_TAG_POSIX,
    read_csv_bytes_to_batch,
    read_csv_bytes_to_batch_dynamic,
)
from komira_csv.quote_styles import QuoteStyle
from komira_csv.reader import read_csv_bytes_to_schema


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


comptime _HEADER = "id,score,name,flag\n"
# Issue input 1: CsvSink with quote doubling disabled wrote the value
# `Ålesund "Å"` as `"Ålesund "Å""`. Byte offsets: the header is 19 bytes, so
# the record starts at 19; the field's opening quote is at 25, `Å` is the two
# bytes 26-27, `lesund ` is 28-34, the quote that closes the field (as far as
# the scanner can tell) is 35, and the offending byte 0xC3 (first byte of `Å`)
# is at 36.
comptime _BAD_QUOTE = "1,1.5,\"Ålesund \"Å\"\",true\n"
# Issue input 2: CsvSink with delimiter quoting disabled wrote `Grüße, Welt`
# bare, so the record has five fields under a four-field header.
comptime _EXTRA_FIELD = "1,1.5,Grüße, Welt,true\n"
comptime _SHORT = "1,1.5,Oslo\n"
comptime _GOOD = "2,2.5,Bergen,false\n"


def _refusal[
    Q: QuoteStyle, SCANNER_VARIANT: Int = 2
](data: String, opts: CsvReadOptions) raises -> String:
    """Read `data`; return the error text. Fails the test if the read
    succeeds (the silent-drop behaviour this file exists to catch)."""
    var buf = _bytes(data)
    var shape = String("")
    try:
        var rb = read_csv_bytes_to_batch[Q, SCANNER_VARIANT](Span(buf), opts)
        shape = String(rb.num_rows()) + " rows x " + String(rb.num_columns())
    except e:
        return String(e)
    assert_true(
        False,
        "expected a refusal, got a batch of " + shape + " columns from " + data,
    )
    return String("")


def _assert_has(msg: String, part: String) raises:
    assert_true(
        msg.find(part) >= 0,
        "refusal must contain `" + part + "`; got: " + msg,
    )


def _projected(var name: String) raises -> CsvReadOptions:
    var opts = CsvReadOptions()
    opts.with_projection(name^)
    return opts^


# -----------------------------------------------------------------------------
# Issue input 1 -- a byte after the closing quote.
# -----------------------------------------------------------------------------


def _check_bad_quote_msg(msg: String) raises:
    _assert_has(msg, "record 2 (line 2, byte offset 19)")
    _assert_has(msg, "field 3 ('name')")
    _assert_has(msg, "byte 0xC3 at byte offset 36")
    _assert_has(msg, "closing quote")


def test_issue_input_1_no_projection() raises:
    _check_bad_quote_msg(
        _refusal[Rfc4180](String(_HEADER) + _BAD_QUOTE + _GOOD, CsvReadOptions())
    )


def test_issue_input_1_projection_includes_field() raises:
    _check_bad_quote_msg(
        _refusal[Rfc4180](
            String(_HEADER) + _BAD_QUOTE + _GOOD, _projected(String("name"))
        )
    )


def test_issue_input_1_projection_excludes_field() raises:
    """The projection reads only `id`; the record is still malformed."""
    _check_bad_quote_msg(
        _refusal[Rfc4180](
            String(_HEADER) + _BAD_QUOTE + _GOOD, _projected(String("id"))
        )
    )


def test_issue_input_1_every_scanner_variant() raises:
    """Phase 1, 2 and 3 scanners all record the violation."""
    var data = String(_HEADER) + _GOOD + _BAD_QUOTE
    var m1 = _refusal[Rfc4180, 1](data, CsvReadOptions())
    var m2 = _refusal[Rfc4180, 2](data, CsvReadOptions())
    var m3 = _refusal[Rfc4180, 3](data, CsvReadOptions())
    # The bad record is record 3 here; offsets shift by len(_GOOD) = 19.
    _assert_has(m1, "record 3 (line 3, byte offset 38)")
    _assert_has(m1, "byte 0xC3 at byte offset 55")
    assert_equal(m1, m2, "phase 1 and phase 2 must refuse identically")
    assert_equal(m1, m3, "phase 1 and phase 3 must refuse identically")


def test_bad_quote_at_end_of_input_and_last_field() raises:
    """`"ab"c` as the LAST field, no trailing newline: the violation is the
    last byte of the input."""
    var msg = _refusal[Rfc4180](
        String("a,b\n1,\"ab\"c"), CsvReadOptions()
    )
    _assert_has(msg, "record 2 (line 2, byte offset 4)")
    _assert_has(msg, "field 2 ('b')")
    _assert_has(msg, "byte 0x63 ('c') at byte offset 10")


def test_bad_quote_in_header() raises:
    var msg = _refusal[Rfc4180](String("\"a\"x,b\n1,2\n"), CsvReadOptions())
    _assert_has(msg, "record 1 (line 1, byte offset 0)")
    _assert_has(msg, "header field 1")
    _assert_has(msg, "byte 0x78 ('x') at byte offset 3")


def test_bad_quote_line_number_counts_quoted_newlines() raises:
    """A quoted newline makes record 3 start on line 4."""
    var msg = _refusal[Rfc4180](
        String("a,b\n1,\"two\nlines\"\n2,\"x\"y\n"), CsvReadOptions()
    )
    _assert_has(msg, "record 3 (line 4, byte offset 18)")
    _assert_has(msg, "field 2 ('b')")


def test_bad_quote_excel_and_posix() raises:
    """No dialect tolerated this on purpose: Excel split the field in two,
    Posix duplicated its bytes into the next field. Both now refuse."""
    var data = String("a,b\n1,\"x\"y\n")
    var me = _refusal[Excel](data, CsvReadOptions())
    _assert_has(me, "record 2 (line 2, byte offset 4)")
    _assert_has(me, "byte 0x79 ('y') at byte offset 9")
    var mp = _refusal[Posix](data, CsvReadOptions())
    _assert_has(mp, "record 2 (line 2, byte offset 4)")
    _assert_has(mp, "byte 0x79 ('y') at byte offset 9")


# -----------------------------------------------------------------------------
# Issue input 2 -- more fields than the header.
# -----------------------------------------------------------------------------


def _check_extra_msg(msg: String) raises:
    _assert_has(msg, "record 2 (line 2, byte offset 19)")
    _assert_has(msg, "has 5 fields but the header has 4")
    _assert_has(msg, "field 5 has no column")


def test_issue_input_2_no_projection() raises:
    _check_extra_msg(
        _refusal[Rfc4180](String(_HEADER) + _EXTRA_FIELD + _GOOD, CsvReadOptions())
    )


def test_issue_input_2_projection() raises:
    _check_extra_msg(
        _refusal[Rfc4180](
            String(_HEADER) + _EXTRA_FIELD + _GOOD, _projected(String("name"))
        )
    )
    _check_extra_msg(
        _refusal[Rfc4180](
            String(_HEADER) + _EXTRA_FIELD + _GOOD, _projected(String("flag"))
        )
    )


def test_too_many_fields_every_dialect_and_variant() raises:
    var data = String(_HEADER) + _EXTRA_FIELD
    _check_extra_msg(_refusal[Rfc4180, 1](data, CsvReadOptions()))
    _check_extra_msg(_refusal[Rfc4180, 3](data, CsvReadOptions()))
    _check_extra_msg(_refusal[Excel](data, CsvReadOptions()))
    _check_extra_msg(_refusal[Posix](data, CsvReadOptions()))


def test_too_many_fields_without_header() raises:
    """has_header=False: the first record sets the field count."""
    var opts = CsvReadOptions()
    opts.has_header = False
    var msg = _refusal[Rfc4180](String("1,2\n3,4,5\n"), opts)
    _assert_has(msg, "record 2 (line 2, byte offset 4)")
    _assert_has(msg, "has 3 fields but the first record has 2")


# -----------------------------------------------------------------------------
# Fewer fields than the header.
# -----------------------------------------------------------------------------


def _check_short_msg(msg: String) raises:
    _assert_has(msg, "record 3 (line 3, byte offset 38)")
    _assert_has(msg, "has 3 fields but the header has 4")
    _assert_has(msg, "field 4 ('flag') is missing")


def test_too_few_fields() raises:
    var data = String(_HEADER) + _GOOD + _SHORT
    _check_short_msg(_refusal[Rfc4180](data, CsvReadOptions()))
    _check_short_msg(_refusal[Rfc4180](data, _projected(String("id"))))
    _check_short_msg(_refusal[Rfc4180, 1](data, CsvReadOptions()))
    _check_short_msg(_refusal[Rfc4180, 3](data, CsvReadOptions()))
    _check_short_msg(_refusal[Excel](data, CsvReadOptions()))
    _check_short_msg(_refusal[Posix](data, CsvReadOptions()))


def test_quoted_empty_line_is_a_short_record() raises:
    """A line holding `""` is not blank (it has bytes): it is a record with
    one empty field, and in a two-column file that is a short record. Fully
    blank lines are skipped; `test_csv_blank_lines` covers them."""
    var msg = _refusal[Rfc4180](String('a,b\n1,2\n""\n3,4\n'), CsvReadOptions())
    _assert_has(msg, "record 3 (line 3, byte offset 8)")
    _assert_has(msg, "has 1 field but the header has 2")


def test_spaces_after_closing_quote_exact_message() raises:
    """`"ab"  ,x`: padding after the closing quote is a violation too (RFC
    4180 has no optional whitespace). The full message, byte for byte."""
    var msg = _refusal[Rfc4180](String('a,b\n"ab"  ,x\n'), CsvReadOptions())
    assert_equal(
        msg,
        String(
            "CSV record 2 (line 2, byte offset 4), field 1 ('a'): byte 0x20"
            " (' ') at byte offset 8 follows the field's closing quote. After"
            " a closing quote RFC 4180 allows only the delimiter, a line end"
            " or the end of input; a quote inside a quoted field must be"
            " doubled."
        ),
    )


def test_crlf_file_line_numbers() raises:
    """CRLF is ONE line end: record 4 starts on line 4, not line 7. A quoted
    CRLF inside record 2 moves the line, not the record number."""
    var msg = _refusal[Rfc4180](
        String('a,b\r\n1,2\r\n3,"x\r\ny"\r\n4,5,6\r\n'), CsvReadOptions()
    )
    assert_equal(
        msg,
        String(
            "CSV record 4 (line 5, byte offset 20) has 3 fields but the header"
            " has 2: field 3 has no column to go to. RFC 4180 requires every"
            " record to have the same number of fields; the reader refuses"
            " rather than drop or pad cells."
        ),
    )
    var m3 = _refusal[Rfc4180, 3](
        String("a,b\r\n1,2\r\n3\r\n"), CsvReadOptions()
    )
    _assert_has(m3, "record 3 (line 3, byte offset 10)")
    _assert_has(m3, "field 2 ('b') is missing")


# -----------------------------------------------------------------------------
# The other entry points.
# -----------------------------------------------------------------------------


def test_dynamic_dispatch_refuses() raises:
    var buf = _bytes(String(_HEADER) + _EXTRA_FIELD)
    for tag in [0, QUOTE_STYLE_TAG_EXCEL, QUOTE_STYLE_TAG_POSIX]:
        var opts = CsvReadOptions()
        opts.with_quote_style(tag)
        var refused = False
        try:
            _ = read_csv_bytes_to_batch_dynamic(Span(buf), opts)
        except e:
            _check_extra_msg(String(e))
            refused = True
        assert_true(refused, "dynamic tag " + String(tag) + " must refuse")


def test_schema_entry_refuses() raises:
    var buf = _bytes(String(_HEADER) + _BAD_QUOTE)
    var refused = False
    try:
        _ = read_csv_bytes_to_schema[Rfc4180](Span(buf), CsvReadOptions())
    except e:
        _check_bad_quote_msg(String(e))
        refused = True
    assert_true(refused, "read_csv_bytes_to_schema must refuse")
    var buf2 = _bytes(String(_HEADER) + _GOOD + _SHORT)
    refused = False
    try:
        _ = read_csv_bytes_to_schema[Rfc4180](Span(buf2), CsvReadOptions())
    except e:
        _check_short_msg(String(e))
        refused = True
    assert_true(refused, "read_csv_bytes_to_schema must refuse a short record")


def test_bom_shifts_byte_offsets_not_records() raises:
    """With a stripped UTF-8 BOM the byte offsets are file offsets."""
    var buf = List[UInt8]()
    buf.append(0xEF)
    buf.append(0xBB)
    buf.append(0xBF)
    for b in (String(_HEADER) + _EXTRA_FIELD).as_bytes():
        buf.append(b)
    var refused = False
    try:
        _ = read_csv_bytes_to_batch[Rfc4180](Span(buf), CsvReadOptions())
    except e:
        _assert_has(String(e), "record 2 (line 2, byte offset 22)")
        refused = True
    assert_true(refused, "BOM-prefixed input must refuse")


# -----------------------------------------------------------------------------
# Well-formed input is still read.
# -----------------------------------------------------------------------------


def _check_well_formed(rb: RecordBatch, v: Int) raises:
    var label = String("variant ") + String(v)
    assert_equal(rb.num_rows(), 2, label)
    assert_equal(rb.num_columns(), 3, label)
    ref col_a = rb.column_at(0)
    var a = col_a.as_string()
    assert_equal(a.get(0), String("x, y"), label)
    assert_equal(a.get(1), String("line\nbreak"), label)
    ref col_b = rb.column_at(1)
    var b = col_b.as_string()
    assert_equal(b.get(0), String('he said "hi"'), label)
    ref col_c = rb.column_at(2)
    var c = col_c.as_string()
    assert_equal(c.get(1), String("end"), label)


def test_well_formed_quoting_and_line_ends() raises:
    """Quoted fields followed by the delimiter, LF, CRLF and end of input; a
    doubled quote; an empty quoted field; a quoted embedded newline."""
    var data = String(
        "a,b,c\r\n"
        "\"x, y\",\"he said \"\"hi\"\"\",\"\"\r\n"
        "\"line\nbreak\",2,\"end\""
    )
    var buf = _bytes(data)
    _check_well_formed(
        read_csv_bytes_to_batch[Rfc4180, 1](Span(buf), CsvReadOptions()), 1
    )
    _check_well_formed(
        read_csv_bytes_to_batch[Rfc4180, 2](Span(buf), CsvReadOptions()), 2
    )
    _check_well_formed(
        read_csv_bytes_to_batch[Rfc4180, 3](Span(buf), CsvReadOptions()), 3
    )


def test_well_formed_single_column_blank_line() raises:
    """In a one-column file a blank line is a record with one empty field."""
    var buf = _bytes(String("t\na\n\nb\n"))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), CsvReadOptions())
    assert_equal(rb.num_rows(), 3)


def main() raises:
    test_issue_input_1_no_projection()
    test_issue_input_1_projection_includes_field()
    test_issue_input_1_projection_excludes_field()
    test_issue_input_1_every_scanner_variant()
    test_bad_quote_at_end_of_input_and_last_field()
    test_bad_quote_in_header()
    test_bad_quote_line_number_counts_quoted_newlines()
    test_bad_quote_excel_and_posix()
    test_issue_input_2_no_projection()
    test_issue_input_2_projection()
    test_too_many_fields_every_dialect_and_variant()
    test_too_many_fields_without_header()
    test_too_few_fields()
    test_quoted_empty_line_is_a_short_record()
    test_spaces_after_closing_quote_exact_message()
    test_crlf_file_line_numbers()
    test_dynamic_dispatch_refuses()
    test_schema_entry_refuses()
    test_bom_shifts_byte_offsets_not_records()
    test_well_formed_quoting_and_line_ends()
    test_well_formed_single_column_blank_line()
    print("test_csv_record_shape: 21/21 PASS")

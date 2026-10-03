# =============================================================================
# Tests for komira_csv/csv_scanner_phase1.mojo — Phase 1 chassis scanner.
# =============================================================================
#
# Coverage:
#   T1  contains_zero_byte: all-zero / no-zero / mid-zero patterns.
#   T2  contains_any_of_4: positive / negative cases.
#   T3  scan_csv_phase1 (Rfc4180): plain CSV, 2 cols x 3 rows.
#   T4  scan_csv_phase1 (Rfc4180): quoted field with commas inside.
#   T5  scan_csv_phase1 (Rfc4180): quoted field with embedded `""` escape
#       (must mark needs_unescape=True).
#   T6  scan_csv_phase1 (Rfc4180): CRLF line endings.
#   T7  scan_csv_phase1 (Rfc4180): trailing-no-newline file.
#   T8  scan_csv_phase1 (Rfc4180): unterminated quote raises.
#   T9  scan_csv_phase1 (Posix): backslash-escape sets needs_unescape.
#   T10 scan_csv_phase1 (Excel): BOM is swallowed.
#   T11 scan_csv_phase1 (Rfc4180): empty cells (consecutive delimiters).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv import (
    Rfc4180,
    Excel,
    Posix,
    scan_csv_phase1,
    contains_zero_byte,
    contains_any_of_4,
    broadcast_byte,
)


def _bytes(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] for test fixtures."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def test_contains_zero_byte() raises:
    """T1: contains_zero_byte returns True only when a byte is zero."""
    assert_true(contains_zero_byte(UInt64(0)), "all-zero word")
    assert_false(contains_zero_byte(UInt64(0xFFFFFFFFFFFFFFFF)), "all-FF")
    assert_true(contains_zero_byte(UInt64(0x01020300_FFFFFFFF)), "mid-zero byte")
    assert_false(contains_zero_byte(UInt64(0x0101010101010101)), "all-01 (no zero)")


def test_contains_any_of_4() raises:
    """T2: contains_any_of_4 finds at least one of the 4 target bytes."""
    var comma = broadcast_byte(UInt8(0x2C))  # ','
    var quote = broadcast_byte(UInt8(0x22))  # '"'
    var cr = broadcast_byte(UInt8(0x0D))
    var lf = broadcast_byte(UInt8(0x0A))
    # "abcdefgh" — no specials
    var no_match: UInt64 = (
        UInt64(0x61) | (UInt64(0x62) << 8) | (UInt64(0x63) << 16)
        | (UInt64(0x64) << 24) | (UInt64(0x65) << 32) | (UInt64(0x66) << 40)
        | (UInt64(0x67) << 48) | (UInt64(0x68) << 56)
    )
    assert_false(contains_any_of_4(no_match, comma, quote, cr, lf), "ascii letters")
    # "abc,defg" — has comma
    var with_comma: UInt64 = (
        UInt64(0x61) | (UInt64(0x62) << 8) | (UInt64(0x63) << 16)
        | (UInt64(0x2C) << 24) | (UInt64(0x64) << 32) | (UInt64(0x65) << 40)
        | (UInt64(0x66) << 48) | (UInt64(0x67) << 56)
    )
    assert_true(contains_any_of_4(with_comma, comma, quote, cr, lf), "with comma")


def test_scan_plain_csv() raises:
    """T3: 2 cols x 3 rows plain CSV produces 3 rows of 2 cells each."""
    var buf = _bytes(String("a,b\n1,2\n3,4\n"))
    var rows = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(len(rows), 3, "row count")
    assert_equal(len(rows[0].cells), 2, "row 0 cells")
    assert_equal(len(rows[1].cells), 2, "row 1 cells")
    assert_equal(len(rows[2].cells), 2, "row 2 cells")
    # Header row: cells should be (0,1) and (2,3)
    assert_equal(rows[0].cells[0].start, 0)
    assert_equal(rows[0].cells[0].end, 1)
    assert_equal(rows[0].cells[1].start, 2)
    assert_equal(rows[0].cells[1].end, 3)
    # Row 1: ranges into "1,2" starting at offset 4
    assert_equal(rows[1].cells[0].start, 4)
    assert_equal(rows[1].cells[0].end, 5)
    assert_equal(rows[1].cells[1].start, 6)
    assert_equal(rows[1].cells[1].end, 7)


def test_scan_quoted_field_with_comma() raises:
    """T4: A quoted field with a comma inside is ONE cell."""
    var buf = _bytes(String("a,b\n\"hello, world\",y\n"))
    var rows = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(len(rows), 2)
    # Row 1 must have exactly 2 cells (NOT 3 — the comma inside quotes
    # does NOT split the field).
    assert_equal(len(rows[1].cells), 2, "quoted cell with comma is ONE cell")
    # The quoted cell's range excludes the surrounding quotes.
    # Buffer: "a,b\n\"hello, world\",y\n"
    #         01234 5         16   1819
    # The opening quote is at offset 4; cell_start = 5 (after quote);
    # closing quote is at offset 17; cell_end = 17.
    assert_equal(rows[1].cells[0].start, 5)
    assert_equal(rows[1].cells[0].end, 17)
    assert_true(rows[1].cells[0].was_quoted, "quoted flag set")
    assert_false(rows[1].cells[0].needs_unescape, "no escape needed")


def test_scan_quoted_field_with_doubled_quote() raises:
    """T5: `""` inside a quoted field is the doubled-quote escape;
    needs_unescape must be True."""
    var buf = _bytes(String("a\n\"hello \"\"world\"\"\"\n"))
    var rows = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(len(rows), 2)
    assert_equal(len(rows[1].cells), 1)
    assert_true(rows[1].cells[0].was_quoted)
    assert_true(rows[1].cells[0].needs_unescape, "doubled-quote needs unescape")


def test_scan_crlf_line_endings() raises:
    """T6: CRLF line endings produce one row per record."""
    var buf = _bytes(String("a,b\r\n1,2\r\n3,4\r\n"))
    var rows = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(len(rows), 3, "CRLF row count")
    assert_equal(len(rows[1].cells), 2, "CRLF cell count")


def test_scan_trailing_no_newline() raises:
    """T7: File without trailing newline still emits the last row."""
    var buf = _bytes(String("a,b\n1,2"))
    var rows = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(len(rows), 2, "trailing-no-newline emits last row")
    assert_equal(len(rows[1].cells), 2)


def test_scan_unterminated_quote_raises() raises:
    """T8: Unterminated quoted region raises."""
    var buf = _bytes(String("a,b\n\"hello, world\n"))
    var raised = False
    try:
        _ = scan_csv_phase1[Rfc4180](
            Span(buf), UInt8(ord(",")), UInt8(ord('"'))
        )
    except:
        raised = True
    assert_true(raised, "unterminated quote raises")


def test_scan_posix_backslash_escape() raises:
    """T9: Posix dialect handles `\\"` inside quoted region."""
    # `"a\"b"`  -> cell body = a\"b; needs_unescape=True
    var buf = _bytes(String("c\n\"a\\\"b\"\n"))
    var rows = scan_csv_phase1[Posix](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(len(rows), 2)
    assert_equal(len(rows[1].cells), 1)
    assert_true(rows[1].cells[0].needs_unescape, "posix backslash escape flag")


def test_scan_excel_bom_swallow() raises:
    """T10: Excel dialect swallows leading UTF-8 BOM."""
    var buf = List[UInt8]()
    # UTF-8 BOM
    buf.append(UInt8(0xEF))
    buf.append(UInt8(0xBB))
    buf.append(UInt8(0xBF))
    # Then "a,b\n1,2\n"
    var rest = _bytes(String("a,b\n1,2\n"))
    var i = 0
    while i < len(rest):
        buf.append(rest[i])
        i = i + 1
    var rows = scan_csv_phase1[Excel](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(len(rows), 2)
    # Header cells must start at offset 3 (after BOM), not 0.
    assert_equal(rows[0].cells[0].start, 3, "BOM swallowed: header cell starts at offset 3")


def test_scan_empty_cells() raises:
    """T11: Consecutive delimiters produce empty cells."""
    var buf = _bytes(String("a,b,c\n1,,3\n"))
    var rows = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(len(rows), 2)
    assert_equal(len(rows[1].cells), 3, "3 cells incl 1 empty")
    # Empty middle cell: start == end
    assert_equal(rows[1].cells[1].start, rows[1].cells[1].end)


def main() raises:
    test_contains_zero_byte()
    test_contains_any_of_4()
    test_scan_plain_csv()
    test_scan_quoted_field_with_comma()
    test_scan_quoted_field_with_doubled_quote()
    test_scan_crlf_line_endings()
    test_scan_trailing_no_newline()
    test_scan_unterminated_quote_raises()
    test_scan_posix_backslash_escape()
    test_scan_excel_bom_swallow()
    test_scan_empty_cells()
    print("test_csv_scanner_phase1: 11/11 PASS")

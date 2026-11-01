# =============================================================================
# The List[Row] scanners on a byte after a closing quote (komira-ai/komira#1125).
# =============================================================================
#
# Fixture (offsets in brackets):
#   row 0  [0, 82)   40 x 'p' , 40 x 'q' LF   (long, so the SIMD scanners take
#                                             their chunked path before row 1)
#   row 1  [82, 90)  "ab"x,c LF               (quote 82, a 83, b 84, quote 85,
#                                             x 86, comma 87, c 88, LF 89)
#   row 2  [90, 94)  d,e LF
#
# Every scanner, in every dialect, must read row 1 as the three fields the
# ScannedCells scanners read: `ab` [83,85) quoted, `x` [86,87), `c` [88,89),
# and record the stray byte (86) on row 1 and on no other row.
# Before the fix the Posix arm skipped the stray byte without moving the cell
# start, so the second field was [83,87) (`ab"x`, the quoted text again).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv import (
    Rfc4180,
    Posix,
    Row,
    scan_csv_phase1,
    scan_csv_phase2_movemask,
    scan_csv_phase3_pclmulqdq,
)


def _fixture() -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(40):
        out.append(UInt8(ord("p")))
    out.append(UInt8(ord(",")))
    for _ in range(40):
        out.append(UInt8(ord("q")))
    out.append(UInt8(10))
    var tail = String('"ab"x,c\nd,e\n').as_bytes()
    for i in range(len(tail)):
        out.append(tail[i])
    return out^


def _check(rows: List[Row], label: String) raises:
    assert_equal(len(rows), 3, label + ": row count")
    assert_equal(len(rows[0].cells), 2, label + ": row 0 field count")
    assert_equal(len(rows[2].cells), 2, label + ": row 2 field count")
    ref r1 = rows[1]
    assert_equal(len(r1.cells), 3, label + ": row 1 field count")
    assert_equal(r1.cells[0].start, 83, label + ": field 0 start")
    assert_equal(r1.cells[0].end, 85, label + ": field 0 end")
    assert_true(r1.cells[0].was_quoted, label + ": field 0 quoted")
    assert_equal(r1.cells[1].start, 86, label + ": field 1 start (the stray byte)")
    assert_equal(r1.cells[1].end, 87, label + ": field 1 end")
    assert_false(r1.cells[1].was_quoted, label + ": field 1 not quoted")
    assert_equal(r1.cells[2].start, 88, label + ": field 2 start")
    assert_equal(r1.cells[2].end, 89, label + ": field 2 end")
    assert_equal(r1.quote_violation_at, 86, label + ": row 1 records the stray byte")
    assert_equal(rows[0].quote_violation_at, -1, label + ": row 0 clean")
    assert_equal(rows[2].quote_violation_at, -1, label + ": row 2 clean")


def test_stray_byte_after_closing_quote() raises:
    var buf = _fixture()
    var d = UInt8(ord(","))
    var q = UInt8(ord('"'))
    _check(scan_csv_phase1[Rfc4180](Span(buf), d, q), "phase1 rfc4180")
    _check(scan_csv_phase2_movemask[Rfc4180](Span(buf), d, q), "phase2 rfc4180")
    _check(scan_csv_phase3_pclmulqdq[Rfc4180](Span(buf), d, q), "phase3 rfc4180")
    _check(scan_csv_phase1[Posix](Span(buf), d, q), "phase1 posix")
    _check(scan_csv_phase2_movemask[Posix](Span(buf), d, q), "phase2 posix")
    _check(scan_csv_phase3_pclmulqdq[Posix](Span(buf), d, q), "phase3 posix")


def main() raises:
    test_stray_byte_after_closing_quote()
    print("test_csv_scanner_rows_quote_violation: PASS")

# =============================================================================
# Tests for komira_csv/csv_scanner_phase1.mojo — Phase 2 movemask scanner.
# =============================================================================
#
#
# Phase 2 SWAPS the inner-loop STANDARD-state fast-skip in Phase 1
# (8-byte ContainsZeroByte trick over UInt64-aligned reads) for a
# 32-byte SIMD movemask scan. FSA transitions + per-Q dialect cascade
# + quote-state-machine + cell-range emission are UNCHANGED — so the
# definitive correctness test is "variant 1 and variant 2 produce
# byte-identical Row lists for the same input".
#
# Coverage:
#   T1 basic skip — long run of non-special bytes in 1 cell, then newline.
#   T2 dense specials — every other byte is a special (delimiter).
#   T3 mixed quote-state — quoted region spanning 32-byte boundary.
#   T4 exact-32-byte boundary — STANDARD-state cell straddling chunk edge.
#   T5 sub-32-byte tail — file shorter than one SIMD chunk.
#   T6 RFC4180 doubled-quote escape (parity with phase1 T5).
#   T7 CRLF (parity with phase1 T6).
#   T8 BOM-Excel (parity with phase1 T10).
#   T9 Posix backslash (parity with phase1 T9).
#   T10 unterminated quote raises.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv import (
    Rfc4180,
    Excel,
    Posix,
    Row,
    scan_csv_phase1,
    scan_csv_phase2_movemask,
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


def _assert_rows_equal(
    rows1: List[Row], rows2: List[Row], label: String
) raises:
    """Assert that variant-1 and variant-2 emit identical row + cell shapes.

    Compares: row count; per-row cell count; per-cell (start, end,
    was_quoted, needs_unescape).
    """
    assert_equal(len(rows1), len(rows2), label + ": row counts differ")
    var r = 0
    while r < len(rows1):
        ref row1 = rows1[r]
        ref row2 = rows2[r]
        assert_equal(
            len(row1.cells),
            len(row2.cells),
            label + ": row " + String(r) + " cell counts differ",
        )
        var c = 0
        while c < len(row1.cells):
            ref c1 = row1.cells[c]
            ref c2 = row2.cells[c]
            assert_equal(
                c1.start,
                c2.start,
                label + ": row " + String(r) + " cell " + String(c) + " start",
            )
            assert_equal(
                c1.end,
                c2.end,
                label + ": row " + String(r) + " cell " + String(c) + " end",
            )
            assert_equal(
                c1.was_quoted,
                c2.was_quoted,
                label
                + ": row "
                + String(r)
                + " cell "
                + String(c)
                + " was_quoted",
            )
            assert_equal(
                c1.needs_unescape,
                c2.needs_unescape,
                label
                + ": row "
                + String(r)
                + " cell "
                + String(c)
                + " needs_unescape",
            )
            c = c + 1
        r = r + 1


def test_basic_skip() raises:
    """T1: long run of non-special bytes (forces multiple 32-byte fast
    skips), then a delimiter + newline. Variant 1 vs variant 2 parity."""
    # 80-byte cell of letter 'a' + ',b\n' — exercises 2 full 32-byte
    # skips in STANDARD before encountering the comma.
    var s = String("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,b\n")
    var buf = _bytes(s)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows2, "T1 basic_skip")
    # Sanity: 1 row of 2 cells.
    assert_equal(len(rows2), 1)
    assert_equal(len(rows2[0].cells), 2)
    assert_equal(rows2[0].cells[0].start, 0)
    assert_equal(rows2[0].cells[0].end, 80)


def test_dense_specials() raises:
    """T2: every other byte is a special (delimiter). No fast-skip
    benefit; tests that the per-byte FSA tail loop still works correctly
    when the movemask returns nonzero on every chunk."""
    var s = String("a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p\nq,r,s,t,u,v,w,x,y,z\n")
    var buf = _bytes(s)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows2, "T2 dense_specials")
    assert_equal(len(rows2), 2)
    assert_equal(len(rows2[0].cells), 16, "row 0 has 16 cells")
    assert_equal(len(rows2[1].cells), 10, "row 1 has 10 cells")


def test_mixed_quote_state_across_chunk_boundary() raises:
    """T3: a quoted region spanning a 32-byte chunk boundary. Variant 2
    must NOT fast-skip inside QUOTED state — fast skip is STANDARD-state-
    only. State carries naturally across the boundary."""
    # Open quote at offset 2; closes at offset 70 (well beyond 32-byte
    # boundary at 32). Cell body = 67 'x' bytes.
    var s = String("a,\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\",c\n")
    var buf = _bytes(s)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows2, "T3 mixed_quote_state")
    assert_equal(len(rows2), 1)
    assert_equal(len(rows2[0].cells), 3)
    assert_true(rows2[0].cells[1].was_quoted, "middle cell quoted")
    assert_false(rows2[0].cells[1].needs_unescape, "no escape inside")


def test_exact_32_byte_boundary() raises:
    """T4: cell of exactly 31 bytes + newline at offset 31 = chunk
    boundary. The newline at byte 31 must be detected even though it
    sits at the LAST lane of the SIMD chunk."""
    # 31 'a' + '\n' = 32 bytes.
    var s = String("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nb,c\n")
    var buf = _bytes(s)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows2, "T4 exact_32_byte_boundary")
    assert_equal(len(rows2), 2)
    assert_equal(len(rows2[0].cells), 1)
    assert_equal(rows2[0].cells[0].start, 0)
    assert_equal(rows2[0].cells[0].end, 31)
    assert_equal(len(rows2[1].cells), 2)


def test_sub_32_byte_tail() raises:
    """T5: file shorter than one full SIMD chunk. Tail must use the
    per-byte FSA without ever entering the SIMD fast-skip."""
    # 10 bytes total.
    var s = String("a,b,c\n1,2\n")
    var buf = _bytes(s)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows2, "T5 sub_32_byte_tail")
    assert_equal(len(rows2), 2)


def test_rfc4180_doubled_quote_escape() raises:
    """T6: parity with phase1 T5 — RFC-4180 `""` escape."""
    var s = String("a\n\"hello \"\"world\"\"\"\n")
    var buf = _bytes(s)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows2, "T6 doubled_quote")
    assert_true(rows2[1].cells[0].needs_unescape, "doubled-quote sets flag")


def test_crlf_line_endings() raises:
    """T7: parity with phase1 T6 — CRLF line endings."""
    var s = String("a,b\r\n1,2\r\n3,4\r\n")
    var buf = _bytes(s)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows2, "T7 crlf")
    assert_equal(len(rows2), 3)


def test_excel_bom_swallow() raises:
    """T8: parity with phase1 T10 — Excel BOM is swallowed."""
    var buf = List[UInt8]()
    buf.append(UInt8(0xEF))
    buf.append(UInt8(0xBB))
    buf.append(UInt8(0xBF))
    var rest = _bytes(String("a,b\n1,2\n"))
    var i = 0
    while i < len(rest):
        buf.append(rest[i])
        i = i + 1
    var rows1 = scan_csv_phase1[Excel](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Excel](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows2, "T8 bom_excel")
    assert_equal(rows2[0].cells[0].start, 3, "header cell starts at offset 3")


def test_posix_backslash_escape() raises:
    """T9: parity with phase1 T9 — Posix backslash escape sets flag."""
    var s = String("c\n\"a\\\"b\"\n")
    var buf = _bytes(s)
    var rows1 = scan_csv_phase1[Posix](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Posix](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows2, "T9 posix_backslash")
    assert_true(rows2[1].cells[0].needs_unescape, "posix backslash flag")


def test_unterminated_quote_raises() raises:
    """T10: parity with phase1 T8 — unterminated quote raises."""
    var s = String("a,b\n\"hello, world\n")
    var buf = _bytes(s)
    var raised = False
    try:
        _ = scan_csv_phase2_movemask[Rfc4180](
            Span(buf), UInt8(ord(",")), UInt8(ord('"'))
        )
    except:
        raised = True
    assert_true(raised, "unterminated quote raises in variant 2")


def main() raises:
    test_basic_skip()
    test_dense_specials()
    test_mixed_quote_state_across_chunk_boundary()
    test_exact_32_byte_boundary()
    test_sub_32_byte_tail()
    test_rfc4180_doubled_quote_escape()
    test_crlf_line_endings()
    test_excel_bom_swallow()
    test_posix_backslash_escape()
    test_unterminated_quote_raises()
    print("test_csv_scanner_phase2_movemask: 10/10 PASS")

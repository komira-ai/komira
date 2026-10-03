# =============================================================================
# Tests for komira_csv/csv_scanner_phase1.mojo — Phase 3 PCLMULQDQ scanner.
# =============================================================================
#
#
# Phase 3 SWAPS the Phase 2 32-byte movemask-only fast-skip for a 64-byte
# SIMD batch + PCLMULQDQ / PMULL64 quote-region mask.  The optimization
# vs Phase 2: filters delim/nl/cr positions INSIDE quoted regions out of
# the candidate-special bitmask (Phase 2 fast-skip was STANDARD-state
# only, so it didn't accelerate QUOTED-state traversal).  Byte-identity
# with Phase 1/2 is preserved by construction (per-byte FSA step at each
# candidate position is unchanged).
#
# Coverage:
#   T1 basic skip — long run of non-special bytes in 1 cell, then newline.
#   T2 dense specials — every other byte is a delimiter.
#   T3 mixed quote-state — quoted region spanning 32 + 64-byte boundaries.
#   T4 exact-64-byte boundary — STANDARD-state cell straddling chunk edge.
#   T5 sub-64-byte tail — file shorter than one SIMD chunk.
#   T6 RFC4180 doubled-quote — `""` cancellation across multiple chunks.
#   T7 CRLF line endings.
#   T8 Excel BOM swallow.
#   T9 Posix backslash escape.
#   T10 unterminated quote raises.
#   T11 cross-chunk quote carry — quoted region straddling 2+ 64-byte chunks.
#   T12 escaped doubled-quote at chunk boundary — pair straddling chunk edge.
#   T13 escape byte (Posix) inside quoted region inside chunk.
#   T14 quote-heavy data — verify candidate-bitmask filtering pays off.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv import (
    Rfc4180,
    Excel,
    Posix,
    Row,
    scan_csv_phase1,
    scan_csv_phase2_movemask,
    scan_csv_phase3_pclmulqdq,
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
    """Assert that two scanner outputs emit identical row + cell shapes.

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
    """T1: long run of non-special bytes (forces multiple 64-byte fast
    skips), then a delimiter + newline. Variant 2 vs variant 3 parity."""
    # 160-byte cell of letter 'a' + ',b\n' — exercises 2+ full 64-byte
    # skips in STANDARD before encountering the comma.
    var sbuf = String()
    var i = 0
    while i < 160:
        sbuf = sbuf + String("a")
        i = i + 1
    sbuf = sbuf + String(",b\n")
    var buf = _bytes(sbuf)
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows2, rows3, "T1 basic_skip")
    # Sanity: 1 row of 2 cells.
    assert_equal(len(rows3), 1)
    assert_equal(len(rows3[0].cells), 2)
    assert_equal(rows3[0].cells[0].start, 0)
    assert_equal(rows3[0].cells[0].end, 160)


def test_dense_specials() raises:
    """T2: every other byte is a special (delimiter). No fast-skip
    benefit; tests that the per-byte FSA tail loop still works correctly
    when the candidate bitmask is dense."""
    var s = String("a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p\nq,r,s,t,u,v,w,x,y,z\n")
    var buf = _bytes(s)
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows2, rows3, "T2 dense_specials")
    assert_equal(len(rows3), 2)
    assert_equal(len(rows3[0].cells), 16, "row 0 has 16 cells")
    assert_equal(len(rows3[1].cells), 10, "row 1 has 10 cells")


def test_mixed_quote_state_across_chunk_boundary() raises:
    """T3: quoted region spanning 32-byte AND 64-byte boundaries.
    Variant 3's quote-region mask must NOT include delim/nl/cr inside
    the quoted region — verified by byte-identity vs variants 1/2."""
    # Open quote at offset 2; closes at offset 130 (well beyond 64-byte
    # boundary at 64 + 128). Cell body = 127 'x' bytes interspersed
    # with commas inside the quotes (which MUST be ignored — that's
    # the Phase 3 optimization).
    var s = String("a,\"xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,xxxxx,x\",c\n")
    var buf = _bytes(s)
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows2, rows3, "T3 mixed_quote_state")
    assert_equal(len(rows3), 1)
    assert_equal(len(rows3[0].cells), 3, "3 cells (a, quoted-region, c)")
    assert_true(rows3[0].cells[1].was_quoted, "middle cell quoted")
    assert_false(rows3[0].cells[1].needs_unescape, "no escape inside")


def test_exact_64_byte_boundary() raises:
    """T4: cell of exactly 63 bytes + newline at offset 63 = chunk
    boundary. The newline at byte 63 must be detected even though it
    sits at the LAST lane of the 64-byte SIMD chunk."""
    var sbuf = String()
    var i = 0
    while i < 63:
        sbuf = sbuf + String("a")
        i = i + 1
    sbuf = sbuf + String("\nb,c\n")
    var buf = _bytes(sbuf)
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows2, rows3, "T4 exact_64_byte_boundary")
    assert_equal(len(rows3), 2)
    assert_equal(len(rows3[0].cells), 1)
    assert_equal(rows3[0].cells[0].start, 0)
    assert_equal(rows3[0].cells[0].end, 63)
    assert_equal(len(rows3[1].cells), 2)


def test_sub_64_byte_tail() raises:
    """T5: file shorter than one full SIMD chunk. Tail must use the
    per-byte FSA without ever entering the SIMD fast-skip."""
    var s = String("a,b,c\n1,2\n")
    var buf = _bytes(s)
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows2, rows3, "T5 sub_64_byte_tail")
    assert_equal(len(rows3), 2)


def test_rfc4180_doubled_quote_escape() raises:
    """T6: RFC-4180 `""` escape — both bits cleared by
    _cancel_doubled_quotes_u64 pre-PCLMULQDQ pass."""
    var s = String("a\n\"hello \"\"world\"\"\"\n")
    var buf = _bytes(s)
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows2, rows3, "T6 doubled_quote")
    assert_true(rows3[1].cells[0].needs_unescape, "doubled-quote sets flag")


def test_crlf_line_endings() raises:
    """T7: CRLF line endings."""
    var s = String("a,b\r\n1,2\r\n3,4\r\n")
    var buf = _bytes(s)
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows2, rows3, "T7 crlf")
    assert_equal(len(rows3), 3)


def test_excel_bom_swallow() raises:
    """T8: Excel BOM is swallowed (skip 3 bytes at start)."""
    var buf = List[UInt8]()
    buf.append(UInt8(0xEF))
    buf.append(UInt8(0xBB))
    buf.append(UInt8(0xBF))
    var rest = _bytes(String("a,b\n1,2\n"))
    var i = 0
    while i < len(rest):
        buf.append(rest[i])
        i = i + 1
    var rows2 = scan_csv_phase2_movemask[Excel](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Excel](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows2, rows3, "T8 bom_excel")
    assert_equal(rows3[0].cells[0].start, 3, "header cell starts at offset 3")


def test_posix_backslash_escape() raises:
    """T9: Posix backslash escape sets needs_unescape flag."""
    var s = String("c\n\"a\\\"b\"\n")
    var buf = _bytes(s)
    var rows2 = scan_csv_phase2_movemask[Posix](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Posix](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows2, rows3, "T9 posix_backslash")
    assert_true(rows3[1].cells[0].needs_unescape, "posix backslash flag")


def test_unterminated_quote_raises() raises:
    """T10: EOF inside QUOTED state raises."""
    var s = String("a,b\n\"hello, world\n")
    var buf = _bytes(s)
    var raised = False
    try:
        _ = scan_csv_phase3_pclmulqdq[Rfc4180](
            Span(buf), UInt8(ord(",")), UInt8(ord('"'))
        )
    except:
        raised = True
    assert_true(raised, "unterminated quote raises in variant 3")


def test_cross_chunk_quote_carry() raises:
    """T11: quoted region spanning 3+ 64-byte chunks. PCLMULQDQ must
    propagate `quote_region_carry` correctly across chunk boundaries.
    Construction: open-quote near end of chunk 0; 200 bytes of body
    spanning chunks 0+1+2+3; close-quote in chunk 3."""
    var sbuf = String("h\n\"")
    var i = 0
    while i < 200:
        # body bytes including SOME commas (which must be ignored
        # inside the quoted region) — `quote_region_carry` MUST keep
        # them filtered out across chunk transitions.
        if i % 16 == 0:
            sbuf = sbuf + String(",")
        else:
            sbuf = sbuf + String("y")
        i = i + 1
    sbuf = sbuf + String("\",done\n")
    var buf = _bytes(sbuf)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows2 = scan_csv_phase2_movemask[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows3, "T11 cross_chunk_quote_carry vs phase1")
    _assert_rows_equal(rows2, rows3, "T11 cross_chunk_quote_carry vs phase2")
    # Sanity: 2 rows (header + data row of 2 cells).
    assert_equal(len(rows3), 2)
    assert_equal(len(rows3[1].cells), 2, "data row has 2 cells (quoted-big-blob, done)")
    assert_true(rows3[1].cells[0].was_quoted, "first data cell is quoted")


def test_doubled_quote_at_chunk_boundary() raises:
    """T12: a `""` pair straddling a 64-byte chunk boundary. The
    `doubled_quote_tail_carry` field must propagate the prior-chunk's
    trailing-quote info so the cross-boundary pair is correctly
    cancelled before PCLMULQDQ."""
    # Construct: 62 bytes of padding + `""` straddling offset 63|64.
    # Wrap in an enclosing quote so we're actually IN a quoted state
    # when the pair fires.
    # Outer-quote opens at byte 0; body: 62 bytes of 'a' + '""' pair
    # at bytes 63,64 (chunk-boundary straddle); rest 60 bytes of 'b' +
    # outer-quote close + newline.
    var sbuf = String("\"")
    var i = 0
    while i < 62:
        sbuf = sbuf + String("a")
        i = i + 1
    sbuf = sbuf + String("\"\"")  # the straddling pair
    var j = 0
    while j < 60:
        sbuf = sbuf + String("b")
        j = j + 1
    sbuf = sbuf + String("\"\n")
    var buf = _bytes(sbuf)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows3, "T12 doubled_quote_at_chunk_boundary")
    assert_equal(len(rows3), 1)
    assert_equal(len(rows3[0].cells), 1, "1 quoted cell")
    assert_true(rows3[0].cells[0].was_quoted, "outer-quoted")
    assert_true(rows3[0].cells[0].needs_unescape, "doubled-quote pair sets flag")


def test_posix_escape_in_quoted_region() raises:
    """T13: Posix escape byte (`\\`) inside a multi-chunk quoted region.
    Verifies that `escape_bits & quote_region` correctly includes the
    escape position in candidates even though it's INSIDE the quoted
    region."""
    # Long quoted body (>64 bytes) with a backslash escape mid-stream.
    var sbuf = String("\"")
    var i = 0
    while i < 80:
        sbuf = sbuf + String("a")
        i = i + 1
    sbuf = sbuf + String("\\\"")  # escape + literal quote
    var j = 0
    while j < 20:
        sbuf = sbuf + String("b")
        j = j + 1
    sbuf = sbuf + String("\"\n")
    var buf = _bytes(sbuf)
    var rows1 = scan_csv_phase1[Posix](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Posix](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows3, "T13 posix_escape_in_quoted_region")
    assert_equal(len(rows3), 1)
    assert_equal(len(rows3[0].cells), 1)
    assert_true(rows3[0].cells[0].was_quoted)
    assert_true(rows3[0].cells[0].needs_unescape, "backslash escape sets flag")


def test_quote_heavy_data() raises:
    """T14: many short quoted cells (the quote_region mask is the major
    optimization on quote-heavy data). Verifies byte-identity holds
    when the FSA enters and exits QUOTED state many times within a
    single chunk."""
    # 16 quoted cells per row, each containing "ab" — total ~96 bytes
    # per row (16 * 6 = 96). Crosses 1+ 64-byte chunk boundaries.
    var sbuf = String()
    var i = 0
    while i < 15:
        sbuf = sbuf + String("\"ab\",")
        i = i + 1
    sbuf = sbuf + String("\"ab\"\n")
    var buf = _bytes(sbuf)
    var rows1 = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows3 = scan_csv_phase3_pclmulqdq[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    _assert_rows_equal(rows1, rows3, "T14 quote_heavy_data")
    assert_equal(len(rows3), 1)
    assert_equal(len(rows3[0].cells), 16, "16 quoted cells")
    var c = 0
    while c < 16:
        assert_true(rows3[0].cells[c].was_quoted, "cell quoted")
        c = c + 1


def main() raises:
    test_basic_skip()
    test_dense_specials()
    test_mixed_quote_state_across_chunk_boundary()
    test_exact_64_byte_boundary()
    test_sub_64_byte_tail()
    test_rfc4180_doubled_quote_escape()
    test_crlf_line_endings()
    test_excel_bom_swallow()
    test_posix_backslash_escape()
    test_unterminated_quote_raises()
    test_cross_chunk_quote_carry()
    test_doubled_quote_at_chunk_boundary()
    test_posix_escape_in_quoted_region()
    test_quote_heavy_data()
    print("test_csv_scanner_phase3_pclmulqdq: 14/14 PASS")

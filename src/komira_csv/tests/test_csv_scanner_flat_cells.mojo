# =============================================================================
# Tests for komira_csv/scanned_cells.mojo + scan_csv_phaseN_into_cells.
# =============================================================================
#
#
# Coverage:
#   T1  scan_csv_phase1_into_cells (Rfc4180): plain CSV, 2 cols x 3 rows.
#       Assert ScannedCells offsets are byte-identical to List[Row] output.
#   T2  scan_csv_phase2_movemask_into_cells (Rfc4180): plain CSV parity.
#   T3  scan_csv_phase3_pclmulqdq_into_cells (Rfc4180): plain CSV parity.
#   T4  Quoted field with comma — quoted cell is ONE cell + was_quoted flag.
#   T5  Doubled-quote escape sets needs_unescape flag.
#   T6  CRLF row terminator handled correctly.
#   T7  Empty cells (consecutive delimiters) preserve column count.
#   T8  ScannedCells accessors: num_rows / num_cells_in_row / cell / cell_start
#       / cell_end / cell_flags_at / total_cells return consistent values.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv import (
    Rfc4180,
    Excel,
    Posix,
    scan_csv_phase1,
    scan_csv_phase1_into_cells,
    scan_csv_phase2_movemask_into_cells,
    scan_csv_phase3_pclmulqdq_into_cells,
    ScannedCells,
    CELL_FLAG_WAS_QUOTED,
    CELL_FLAG_NEEDS_UNESCAPE,
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


def test_phase1_into_cells_plain() raises:
    """T1: phase1_into_cells produces byte-identical offsets to phase1."""
    var buf = _bytes(String("a,b\n1,2\n3,4\n"))
    var cells = scan_csv_phase1_into_cells[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    # Parity against the legacy List[Row] scanner.
    var rows = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(cells.num_rows(), len(rows), "row count parity")
    assert_equal(cells.num_rows(), 3, "expected 3 rows")
    var r = 0
    while r < cells.num_rows():
        assert_equal(
            cells.num_cells_in_row(r),
            len(rows[r].cells),
            "row cell count parity",
        )
        var c = 0
        while c < cells.num_cells_in_row(r):
            var cr_flat = cells.cell(r, c)
            var cr_legacy = rows[r].cells[c]
            assert_equal(cr_flat.start, cr_legacy.start, "start parity")
            assert_equal(cr_flat.end, cr_legacy.end, "end parity")
            c = c + 1
        r = r + 1


def test_phase2_into_cells_plain() raises:
    """T2: phase2 (movemask) into_cells parity vs phase1 (legacy List[Row])."""
    var buf = _bytes(String("a,b,c\n10,20,30\n40,50,60\n70,80,90\n"))
    var cells = scan_csv_phase2_movemask_into_cells[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(cells.num_rows(), len(rows), "row count parity")
    var r = 0
    while r < cells.num_rows():
        assert_equal(
            cells.num_cells_in_row(r),
            len(rows[r].cells),
            "row cell count parity",
        )
        var c = 0
        while c < cells.num_cells_in_row(r):
            var cr_flat = cells.cell(r, c)
            var cr_legacy = rows[r].cells[c]
            assert_equal(cr_flat.start, cr_legacy.start, "start parity")
            assert_equal(cr_flat.end, cr_legacy.end, "end parity")
            c = c + 1
        r = r + 1


def test_phase3_into_cells_plain() raises:
    """T3: phase3 (PCLMULQDQ) into_cells parity vs phase1 (legacy List[Row])."""
    # Need >= 64 bytes to engage the PCLMULQDQ chunk.
    var buf = _bytes(String(
        "a,b,c,d\n"
        "100,200,300,400\n"
        "500,600,700,800\n"
        "900,1000,1100,1200\n"
        "1300,1400,1500,1600\n"
    ))
    var cells = scan_csv_phase3_pclmulqdq_into_cells[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    var rows = scan_csv_phase1[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(cells.num_rows(), len(rows), "row count parity")
    var r = 0
    while r < cells.num_rows():
        assert_equal(
            cells.num_cells_in_row(r),
            len(rows[r].cells),
            "row cell count parity",
        )
        var c = 0
        while c < cells.num_cells_in_row(r):
            var cr_flat = cells.cell(r, c)
            var cr_legacy = rows[r].cells[c]
            assert_equal(cr_flat.start, cr_legacy.start, "start parity")
            assert_equal(cr_flat.end, cr_legacy.end, "end parity")
            c = c + 1
        r = r + 1


def test_quoted_field_with_comma_sets_was_quoted() raises:
    """T4: A quoted field with a comma inside is ONE cell + was_quoted flag."""
    var buf = _bytes(String("a,b\n\"hello, world\",y\n"))
    var cells = scan_csv_phase1_into_cells[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(cells.num_rows(), 2)
    assert_equal(
        cells.num_cells_in_row(1),
        2,
        "quoted cell with comma is ONE cell",
    )
    var cr = cells.cell(1, 0)
    assert_true(cr.was_quoted, "quoted-field cell must have was_quoted=True")
    # Inspect via the packed-flags accessor too.
    var flags = cells.cell_flags_at(1, 0)
    assert_true(
        (flags & CELL_FLAG_WAS_QUOTED) != 0,
        "packed flag bit for was_quoted",
    )


def test_doubled_quote_escape_sets_needs_unescape() raises:
    """T5: `""` inside a quoted cell sets needs_unescape on the flag bitmap."""
    var buf = _bytes(String("a,b\n\"hi \"\"world\"\"\",y\n"))
    var cells = scan_csv_phase1_into_cells[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(cells.num_rows(), 2)
    var cr = cells.cell(1, 0)
    assert_true(cr.was_quoted, "was_quoted")
    assert_true(cr.needs_unescape, "needs_unescape")
    var flags = cells.cell_flags_at(1, 0)
    assert_true(
        (flags & CELL_FLAG_NEEDS_UNESCAPE) != 0,
        "packed flag bit for needs_unescape",
    )


def test_crlf_row_terminator() raises:
    """T6: CRLF row terminator produces correct row boundaries."""
    var buf = _bytes(String("a,b\r\n1,2\r\n3,4\r\n"))
    var cells = scan_csv_phase1_into_cells[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(cells.num_rows(), 3, "3 rows under CRLF")
    var r = 0
    while r < 3:
        assert_equal(cells.num_cells_in_row(r), 2, "2 cells/row under CRLF")
        r = r + 1


def test_empty_cells_preserve_column_count() raises:
    """T7: Consecutive delimiters produce zero-length cells (not skipped)."""
    var buf = _bytes(String("a,b,c\n1,,3\n,,\n"))
    var cells = scan_csv_phase1_into_cells[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    assert_equal(cells.num_rows(), 3, "3 rows")
    # Row 1: 1,,3 -> three cells: "1", "", "3"
    assert_equal(cells.num_cells_in_row(1), 3, "row 1 has 3 cells")
    var c1_1 = cells.cell(1, 1)
    assert_equal(c1_1.start, c1_1.end, "empty cell start == end (zero-length)")
    # Row 2: ,, -> three cells: "", "", ""
    assert_equal(cells.num_cells_in_row(2), 3, "row 2 has 3 cells")


def test_scanned_cells_accessor_invariants() raises:
    """T8: ScannedCells accessor return values match the underlying buffers."""
    var buf = _bytes(String("a,b\n1,2\n3,4\n"))
    var cells = scan_csv_phase1_into_cells[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord('"'))
    )
    # total_cells = sum of num_cells_in_row over all rows
    var expected_total = 0
    var r = 0
    while r < cells.num_rows():
        expected_total = expected_total + cells.num_cells_in_row(r)
        r = r + 1
    assert_equal(
        cells.total_cells(),
        expected_total,
        "total_cells = sum of per-row counts",
    )
    # cell(r, c) values match cell_start/cell_end accessors
    r = 0
    while r < cells.num_rows():
        var c = 0
        while c < cells.num_cells_in_row(r):
            var cr = cells.cell(r, c)
            assert_equal(
                cr.start,
                cells.cell_start(r, c),
                "cell.start == cell_start accessor",
            )
            assert_equal(
                cr.end,
                cells.cell_end(r, c),
                "cell.end == cell_end accessor",
            )
            c = c + 1
        r = r + 1


def main() raises:
    print("test_csv_scanner_flat_cells: starting")
    test_phase1_into_cells_plain()
    print("  T1 phase1_into_cells_plain GREEN")
    test_phase2_into_cells_plain()
    print("  T2 phase2_into_cells_plain GREEN")
    test_phase3_into_cells_plain()
    print("  T3 phase3_into_cells_plain GREEN")
    test_quoted_field_with_comma_sets_was_quoted()
    print("  T4 quoted_field_with_comma_sets_was_quoted GREEN")
    test_doubled_quote_escape_sets_needs_unescape()
    print("  T5 doubled_quote_escape_sets_needs_unescape GREEN")
    test_crlf_row_terminator()
    print("  T6 crlf_row_terminator GREEN")
    test_empty_cells_preserve_column_count()
    print("  T7 empty_cells_preserve_column_count GREEN")
    test_scanned_cells_accessor_invariants()
    print("  T8 scanned_cells_accessor_invariants GREEN")
    print("test_csv_scanner_flat_cells: ALL GREEN")

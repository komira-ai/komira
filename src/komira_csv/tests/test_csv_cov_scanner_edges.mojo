# =============================================================================
# Every scanner variant against the same edge fixtures.
# =============================================================================
#
# The seven scanners (three `List[Row]` variants, three `ScannedCells`
# variants and the projected scanner) are separate FSA transcriptions, so a
# transition one of them gets wrong is invisible to tests of the others. Each
# fixture here is run through all seven and compared against ONE hand-written
# expectation, serialized as `[cell|cell]/[cell]` with `q:` for a quoted cell
# and `u:` for a cell that needs unescaping. The fixtures exercise what the
# other scanner tests do not: the transitions out of a closing quote (into a
# delimiter, CRLF, a bare CR, LF and end of input) for both quote dialects, a
# bare CR followed by a quote, a final record with no line end, empty input,
# an unterminated quote, and inputs long enough to take the 32- and 64-byte
# SIMD paths with a quote and a Posix escape inside the chunk.
#
# Mutants planted (each turned this file red; the PR body lists the red
# messages): drop the CR arm after a Posix closing quote (phase-1 rows and
# phase-2 cells), make CR_LF_LOOKAHEAD consume the non-LF byte (phase-1 rows),
# drop the end-of-input flush (phase-2 rows), drop the Posix escape bits from
# the phase-3 candidates, skip the unterminated-quote raise (phase-1 cells),
# and the projected-scanner and Row.copy mutants named in the docstrings
# (including the column-index reset after a closing quote in column 1).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_csv import Rfc4180, Posix
from komira_csv.csv_scanner_phase1 import (
    Row,
    scan_csv_phase1,
    scan_csv_phase2_movemask,
    scan_csv_phase3_pclmulqdq,
    scan_csv_phase1_into_cells,
    scan_csv_phase2_movemask_into_cells,
    scan_csv_phase3_pclmulqdq_into_cells,
    scan_csv_phase2_movemask_projected,
)
from komira_csv.quote_styles import QuoteStyle
from komira_csv.scanned_cells import (
    ScannedCells,
    CELL_FLAG_WAS_QUOTED,
    CELL_FLAG_NEEDS_UNESCAPE,
)


comptime _COMMA = UInt8(44)
comptime _QUOTE = UInt8(34)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _text(b: List[UInt8], lo: Int, hi: Int) -> String:
    var s = String("")
    for i in range(lo, hi):
        s += chr(Int(b[i]))
    return s^


def _cell(
    b: List[UInt8], lo: Int, hi: Int, quoted: Bool, unescape: Bool
) -> String:
    var s = String("")
    if quoted:
        s += "q:"
    if unescape:
        s += "u:"
    return s + _text(b, lo, hi)


def _ser_rows(b: List[UInt8], rows: List[Row]) -> String:
    var out = String("")
    for r in range(len(rows)):
        if r > 0:
            out += "/"
        out += "["
        for c in range(len(rows[r].cells)):
            if c > 0:
                out += "|"
            var cr = rows[r].cells[c]
            out += _cell(b, cr.start, cr.end, cr.was_quoted, cr.needs_unescape)
        out += "]"
    return out^


def _ser_cells(b: List[UInt8], cells: ScannedCells) -> String:
    var out = String("")
    for r in range(cells.num_rows()):
        if r > 0:
            out += "/"
        out += "["
        for c in range(cells.num_cells_in_row(r)):
            if c > 0:
                out += "|"
            var f = cells.cell_flags_at(r, c)
            out += _cell(
                b,
                cells.cell_start(r, c),
                cells.cell_end(r, c),
                (f & CELL_FLAG_WAS_QUOTED) != 0,
                (f & CELL_FLAG_NEEDS_UNESCAPE) != 0,
            )
        out += "]"
    return out^


def _all_wanted(n: Int) -> List[Bool]:
    var w = List[Bool]()
    for _ in range(n):
        w.append(True)
    return w^


def _check_all[Q: QuoteStyle](text: String, want: String, label: String) raises:
    """Run `text` through all seven scanners; each must serialize to `want`
    (the projected scanner with every column wanted)."""
    var b = _b(text)
    var s = Span(b)
    assert_equal(
        _ser_rows(b, scan_csv_phase1[Q](s, _COMMA, _QUOTE)), want,
        label + ": phase1 rows",
    )
    assert_equal(
        _ser_rows(b, scan_csv_phase2_movemask[Q](s, _COMMA, _QUOTE)), want,
        label + ": phase2 rows",
    )
    assert_equal(
        _ser_rows(b, scan_csv_phase3_pclmulqdq[Q](s, _COMMA, _QUOTE)), want,
        label + ": phase3 rows",
    )
    assert_equal(
        _ser_cells(b, scan_csv_phase1_into_cells[Q](s, _COMMA, _QUOTE)), want,
        label + ": phase1 cells",
    )
    assert_equal(
        _ser_cells(b, scan_csv_phase2_movemask_into_cells[Q](s, _COMMA, _QUOTE)),
        want,
        label + ": phase2 cells",
    )
    assert_equal(
        _ser_cells(b, scan_csv_phase3_pclmulqdq_into_cells[Q](s, _COMMA, _QUOTE)),
        want,
        label + ": phase3 cells",
    )
    assert_equal(
        _ser_cells(
            b,
            scan_csv_phase2_movemask_projected[Q](
                s, _COMMA, _QUOTE, _all_wanted(8), 8
            ),
        ),
        want,
        label + ": projected cells",
    )


def _raises_all[Q: QuoteStyle](text: String, label: String) raises:
    """Every scanner refuses `text` (EOF inside a quoted region)."""
    var b = _b(text)
    var s = Span(b)
    var refused = 0
    try:
        _ = scan_csv_phase1[Q](s, _COMMA, _QUOTE)
    except:
        refused += 1
    try:
        _ = scan_csv_phase2_movemask[Q](s, _COMMA, _QUOTE)
    except:
        refused += 1
    try:
        _ = scan_csv_phase3_pclmulqdq[Q](s, _COMMA, _QUOTE)
    except:
        refused += 1
    try:
        _ = scan_csv_phase1_into_cells[Q](s, _COMMA, _QUOTE)
    except:
        refused += 1
    try:
        _ = scan_csv_phase2_movemask_into_cells[Q](s, _COMMA, _QUOTE)
    except:
        refused += 1
    try:
        _ = scan_csv_phase3_pclmulqdq_into_cells[Q](s, _COMMA, _QUOTE)
    except:
        refused += 1
    try:
        _ = scan_csv_phase2_movemask_projected[Q](
            s, _COMMA, _QUOTE, _all_wanted(4), 4
        )
    except:
        refused += 1
    assert_equal(refused, 7, label + ": every scanner must refuse")


def _rep(s: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += s
    return out^


def test_doubled_quote_dialect_close_transitions() raises:
    """RFC 4180: a closing quote followed by an escaped quote, the
    delimiter, CRLF, a bare CR (then a quote), LF and end of input."""
    _check_all[Rfc4180](
        '"a""b",c\r\n"d"\r"e"\n"f"',
        "[q:u:a\"\"b|c]/[q:d]/[q:e]/[q:f]",
        "rfc close transitions",
    )


def test_posix_dialect_close_transitions() raises:
    """Posix: the same transitions out of a closing quote, with a `\\"`
    escape inside the first cell."""
    _check_all[Posix](
        '"a\\"b",c\r\n"d"\r"e"\n"f"',
        "[q:u:a\\\"b|c]/[q:d]/[q:e]/[q:f]",
        "posix close transitions",
    )


def test_bare_cr_no_final_newline_and_empty() raises:
    """A bare CR ends a record; a final record without a line end is kept;
    empty input has no record."""
    _check_all[Rfc4180]("a\rb", "[a]/[b]", "bare cr")
    _check_all[Rfc4180]("x,y", "[x|y]", "no final newline")
    _check_all[Posix]("x,y", "[x|y]", "posix no final newline")
    _check_all[Rfc4180]("", "", "empty")
    _check_all[Posix]("", "", "posix empty")


def test_unterminated_quote_refused_by_every_scanner() raises:
    """EOF inside a quoted field (and, for Posix, right after an escape)."""
    _raises_all[Rfc4180]('a,"bc', "rfc unterminated")
    _raises_all[Posix]('a,"bc', "posix unterminated")
    _raises_all[Posix]('a,"b\\', "posix escape at eof")


def test_simd_chunks_with_quotes_and_escapes() raises:
    """Inputs past 64 bytes put a doubled quote (RFC 4180) and a `\\"`
    escape (Posix) inside a SIMD chunk, and a 40-byte unquoted run lets the
    projected scanner take its 32-byte skip."""
    var a = _rep("a", 40)
    var z = _rep("z", 30)
    _check_all[Rfc4180](
        '"' + a + '""' + z + '",c\n',
        "[q:u:" + a + '""' + z + "|c]",
        "rfc long quoted",
    )
    _check_all[Posix](
        '"' + a + '\\"' + z + '",c\n',
        "[q:u:" + a + '\\"' + z + "|c]",
        "posix long quoted",
    )
    _check_all[Rfc4180](
        a + "," + z + "\n" + a + "\n", "[" + a + "|" + z + "]/[" + a + "]",
        "long unquoted",
    )


def _proj_cells[Q: QuoteStyle](text: String, var wanted: List[Bool]) raises -> String:
    var b = _b(text)
    var n = 0
    for w in wanted:
        if w:
            n += 1
    return _ser_cells(
        b, scan_csv_phase2_movemask_projected[Q](Span(b), _COMMA, _QUOTE, wanted, n)
    )


def test_projected_scanner_skips_unwanted_quoted_cells() raises:
    """With column 0 NOT wanted, a quoted column-0 cell closing into each of
    the delimiter, CR and LF still advances the column index and ends the
    row, and emits nothing. Mutant: emit the QUOTE_IN_QUOTED cell whether
    wanted or not (red: extra cell); skip the column increment after a
    closing quote (red: column 1 taken for column 0)."""
    var w = List[Bool]()
    w.append(False)
    w.append(True)
    assert_equal(
        _proj_cells[Rfc4180]('"a""b",c\r\n"d"\r"e"\n"f",g\n', w.copy()),
        "[c]/[]/[]/[g]",
    )
    assert_equal(
        _proj_cells[Posix]('"a\\"b",c\r\n"d"\r"e"\n"f",g\n', w.copy()),
        "[c]/[]/[]/[g]",
    )
    assert_equal(_proj_cells[Rfc4180]("p,q\rr,s", w.copy()), "[q]/[s]")


def test_quoted_cell_after_column_0_ends_the_row() raises:
    """A quoted cell in column 1 ends the row with LF, a bare CR and CRLF.
    With every column wanted all seven scanners agree; with only column 0
    wanted the projected scanner must reset its column index at the row end,
    or the next row's column 0 is read as column 1 and dropped. Mutants:
    replace `col_idx = 0` with `pass` after the projected scanner's
    closing-quote LF exit (red: `[a]/[]/...`) and after its bare-CR exit
    (red: same)."""
    _check_all[Rfc4180](
        'a,"b"\nc,"d"\re,"f"\r\ng,h',
        "[a|q:b]/[c|q:d]/[e|q:f]/[g|h]",
        "rfc quoted last cell",
    )
    _check_all[Posix](
        'a,"b"\nc,"d"\re,"f"\r\ng,h',
        "[a|q:b]/[c|q:d]/[e|q:f]/[g|h]",
        "posix quoted last cell",
    )
    var w = List[Bool]()
    w.append(True)
    w.append(False)
    assert_equal(
        _proj_cells[Rfc4180]('a,"b"\nc,d\n', w.copy()), "[a]/[c]", "rfc lf"
    )
    assert_equal(
        _proj_cells[Rfc4180]('a,"b"\rc,d\n', w.copy()), "[a]/[c]", "rfc cr"
    )
    assert_equal(
        _proj_cells[Posix]('a,"b"\nc,d\n', w.copy()), "[a]/[c]", "posix lf"
    )
    assert_equal(
        _proj_cells[Posix]('a,"b"\rc,d\n', w.copy()), "[a]/[c]", "posix cr"
    )
    assert_equal(
        _proj_cells[Rfc4180]('a,"b"\r\nc,d\n', w.copy()), "[a]/[c]",
        "rfc crlf",
    )


def _violation[Q: QuoteStyle](
    text: String, variant: Int
) raises -> Tuple[String, Int, Int, Int]:
    var b = _b(text)
    var s = Span(b)
    if variant == 1:
        var c = scan_csv_phase1_into_cells[Q](s, _COMMA, _QUOTE)
        return (
            _ser_cells(b, c), c.quote_violation_at, c.quote_violation_row,
            c.quote_violation_field,
        )
    if variant == 2:
        var c = scan_csv_phase2_movemask_into_cells[Q](s, _COMMA, _QUOTE)
        return (
            _ser_cells(b, c), c.quote_violation_at, c.quote_violation_row,
            c.quote_violation_field,
        )
    if variant == 3:
        var c = scan_csv_phase3_pclmulqdq_into_cells[Q](s, _COMMA, _QUOTE)
        return (
            _ser_cells(b, c), c.quote_violation_at, c.quote_violation_row,
            c.quote_violation_field,
        )
    var c = scan_csv_phase2_movemask_projected[Q](
        s, _COMMA, _QUOTE, _all_wanted(4), 4
    )
    return (
        _ser_cells(b, c), c.quote_violation_at, c.quote_violation_row,
        c.quote_violation_field,
    )


def test_byte_after_closing_quote_is_recorded() raises:
    """In every `ScannedCells` scanner and both dialects, a byte after a
    closing quote that is neither the delimiter nor a line end is recorded
    (byte 7, row 1, field 1) and the scan goes on, the stray bytes becoming
    one more field, as the `ScannedCells` contract states. Mutant: drop the
    projected scanner's `note_quote_violation` after QUOTE_IN_QUOTED (red:
    -1). Each scanner's record is asserted the same way."""
    var v = 1
    while v <= 4:
        var tag = String("variant ") + String(v)
        var r = _violation[Rfc4180]('h\n1,"a"x,b\n', v)
        assert_equal(r[0], "[h]/[1|q:a|x|b]", tag + " rfc cells")
        assert_equal(r[1], 7, tag + " rfc byte")
        assert_equal(r[2], 1, tag + " rfc row")
        assert_equal(r[3], 1, tag + " rfc field")
        var p = _violation[Posix]('h\n1,"a"x,b\n', v)
        assert_equal(p[0], "[h]/[1|q:a|x|b]", tag + " posix cells")
        assert_equal(p[1], 7, tag + " posix byte")
        assert_equal(p[3], 1, tag + " posix field")
        v += 1


def test_row_copy_is_deep() raises:
    """`Row.copy` copies every cell, and the copy owns its own list.
    Mutant: stop the copy loop one cell early (red: the copy has 1 cell)."""
    var b = _b("ab,c\n")
    var rows = scan_csv_phase1[Rfc4180](Span(b), _COMMA, _QUOTE)
    var copied = List[Row]()
    copied.append(rows[0].copy())
    assert_equal(_ser_rows(b, copied), "[ab|c]")
    copied[0].cells.clear()
    assert_equal(_ser_rows(b, rows), "[ab|c]")


def main() raises:
    test_doubled_quote_dialect_close_transitions()
    test_posix_dialect_close_transitions()
    test_bare_cr_no_final_newline_and_empty()
    test_unterminated_quote_refused_by_every_scanner()
    test_simd_chunks_with_quotes_and_escapes()
    test_projected_scanner_skips_unwanted_quoted_cells()
    test_quoted_cell_after_column_0_ends_the_row()
    test_byte_after_closing_quote_is_recorded()
    test_row_copy_is_deep()
    print("test_csv_cov_scanner_edges: 9 tests PASS")

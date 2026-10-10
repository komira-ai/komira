# =============================================================================
# Refusal edges of the scalar temporal parsers, the wide inference lattice's
# less-travelled resolutions, and the input-limit / option / cell-index guards.
# =============================================================================
#
# Each test pairs the cells a check must refuse with a near-miss it must
# accept, so dropping the check (accepting) and tightening it (refusing) both
# go red. The planted mutant is named in each docstring.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType

from komira_csv import CsvReadOptions, Rfc4180
from komira_csv.csv_options import check_declared_column_types
from komira_csv.csv_scanner_phase1 import scan_csv_phase1_into_cells
from komira_csv.input_limits import (
    MAX_CSV_COLUMNS,
    MAX_ARROW_STRING_BYTES,
    check_csv_column_count,
    max_csv_rows_for_columns,
    check_csv_cell_budget,
    check_csv_string_column_bytes,
    check_csv_row_bytes,
)
from komira_csv.reader import read_csv_bytes_to_batch
from komira_csv.scanned_cells import ScannedCells
from komira_csv.temporal_parsers import (
    _parse_ymd_at,
    _parse_hms_at,
    _parse_fractional_seconds,
    _try_parse_date64,
    _try_parse_timestamp_s,
    _try_parse_timestamp_ms,
    _try_parse_timestamp_us,
    _try_parse_timestamp_ns,
    _try_parse_time_ms,
    _try_parse_time_us,
    _try_parse_time_ns,
    _try_parse_duration_iso_to_ns,
    _try_parse_duration_ns,
)
from komira_csv.type_inference import infer_column_types, infer_column_types_wide


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _has(msg: String, part: String) raises:
    assert_true(msg.find(part) >= 0, "expected `" + part + "` in: " + msg)


# -----------------------------------------------------------------------------
# temporal_parsers
# -----------------------------------------------------------------------------


def _d64(s: String) -> Optional[Int64]:
    var b = _b(s)
    return _try_parse_date64(Span(b))


def test_date64_each_ymd_and_hms_check() raises:
    """`_parse_ymd_at` and `_parse_hms_at` refusals reached through
    `_try_parse_date64`: each dash, each digit pair, month 13, the time's
    second colon and each time digit pair, and an hour of 25. Mutant: drop
    any one check (red: its cell decodes)."""
    assert_equal(_d64("1970-01-02").value(), Int64(86400000))
    assert_equal(_d64("1970-01-01T00:00:01.5Z").value(), Int64(1500))
    assert_false(Bool(_d64("2024x01-01")), "dash 4")
    assert_false(Bool(_d64("2024-01x01")), "dash 7")
    assert_false(Bool(_d64("20x4-01-01")), "year digit")
    assert_false(Bool(_d64("2024-x1-01")), "month digit")
    assert_false(Bool(_d64("2024-01-x1")), "day digit")
    assert_false(Bool(_d64("2024-13-01")), "month 13")
    assert_false(Bool(_d64("2024-01-01T12:34x56")), "colon 5")
    assert_false(Bool(_d64("2024-01-01Tx2:34:56")), "hour digit")
    assert_false(Bool(_d64("2024-01-01T12:x4:56")), "minute digit")
    assert_false(Bool(_d64("2024-01-01T12:34:x6")), "second digit")
    assert_false(Bool(_d64("2024-01-01T25:00:00")), "hour 25")


def test_component_helpers_short_input_and_no_fraction() raises:
    """Called directly with too few bytes after the offset, the date and
    time helpers refuse; with no `.` at the offset, the fraction helper
    reports (0, 0). The public parsers check lengths first, so only a direct
    call reaches these guards. Mutant: `len(cell) < offset + 10` ->
    `< offset + 9` (red: reads past the end / decodes a short cell)."""
    var b = _b("xx2024-01-0")
    assert_false(Bool(_parse_ymd_at(Span(b), 2)), "9 bytes after offset")
    var ok = _b("xx2024-01-02")
    assert_true(Bool(_parse_ymd_at(Span(ok), 2)), "10 bytes after offset")
    var t = _b("x12:34:5")
    assert_false(Bool(_parse_hms_at(Span(t), 1)), "7 bytes after offset")
    var f = _parse_fractional_seconds(Span(t), 8, 3)
    assert_equal(f.value()[0], 0)
    assert_equal(f.value()[1], 0)


def _ts(s: String, unit: Int) -> Optional[Int64]:
    var b = _b(s)
    if unit == 0:
        return _try_parse_timestamp_s(Span(b))
    if unit == 1:
        return _try_parse_timestamp_ms(Span(b))
    if unit == 2:
        return _try_parse_timestamp_us(Span(b))
    return _try_parse_timestamp_ns(Span(b))


def test_scalar_timestamp_refusals_every_unit() raises:
    """Through each scalar timestamp parser: a bad date, a bad separator, a bad
    time and trailing garbage are refused; ns also refuses a 10-digit
    fraction. Control: `1970-01-02 00:00:01Z` in every unit. Mutant: drop
    the separator check in the shared component parser (red: the `X`
    separator decodes)."""
    var scale = List[Int64]()
    scale.append(1)
    scale.append(1000)
    scale.append(1000000)
    scale.append(1000000000)
    var u = 0
    while u < 4:
        var tag = String("unit ") + String(u)
        assert_equal(
            _ts("1970-01-02 00:00:01Z", u).value(), Int64(86401) * scale[u], tag
        )
        assert_false(Bool(_ts("2024-13-01T00:00:00", u)), tag + ": month 13")
        assert_false(Bool(_ts("2024-01-01X00:00:00", u)), tag + ": separator")
        assert_false(Bool(_ts("2024-01-01T00:61:00", u)), tag + ": minute 61")
        assert_false(Bool(_ts("2024-01-01T00:00:00q", u)), tag + ": trailing")
        u += 1
    assert_false(Bool(_ts("2024-01-01T00:00:00.1234567890", 3)), "ns 10 digits")


def test_scalar_time_refusals() raises:
    """time_ms / time_us / time_ns: trailing garbage after the fraction, a dot
    with no digit, and too many fraction digits. Mutant: drop time_ms's `pos
    != n` check (red: `12:00:00.5X` accepted)."""
    var a = _b("12:00:00.5X")
    assert_false(Bool(_try_parse_time_ms(Span(a))), "ms trailing")
    var a2 = _b("00:00:01.5")
    assert_equal(_try_parse_time_ms(Span(a2)).value(), Int32(1500))
    var c = _b("12:00:00.")
    assert_false(Bool(_try_parse_time_us(Span(c))), "us dot without digit")
    var d = _b("12:00:00.5X")
    assert_false(Bool(_try_parse_time_us(Span(d))), "us trailing")
    var e = _b("12:00:00.1234567890")
    assert_false(Bool(_try_parse_time_ns(Span(e))), "ns 10 digits")
    var g = _b("12:00:00.5X")
    assert_false(Bool(_try_parse_time_ns(Span(g))), "ns trailing")
    var h = _b("00:00:01.000000001")
    assert_equal(_try_parse_time_ns(Span(h)).value(), Int64(1000000001))


def _iso(s: String) -> Optional[Int64]:
    var b = _b(s)
    return _try_parse_duration_iso_to_ns(Span(b))


def _dur(s: String) -> Optional[Int64]:
    var b = _b(s)
    return _try_parse_duration_ns(Span(b))


def test_iso_duration_grammar_refusals() raises:
    """Every refusal of the `P[nD][T[nH][nM][n[.f]S]]` grammar, one cell each,
    against accepted controls. A unit letter with no digits, a unit
    repeated, digits before `T`, a fraction with no digits / no `S` / too
    many digits, an unknown letter, an empty `PT`, and (direct call only) a
    cell that does not start with `P`. Mutant: drop `seen_h` from the H
    repeat check (red: `PT1H2H` sums)."""
    assert_equal(_iso("P1DT1H1M1.5S").value(), Int64(90061500000000))
    assert_equal(_iso("-PT2S").value(), Int64(-2000000000))
    assert_false(Bool(_iso("X1D")), "no P")
    assert_false(Bool(_iso("-X")), "no P after sign")
    assert_false(Bool(_iso("PD")), "D without digits")
    assert_false(Bool(_iso("P1T")), "digits before T")
    assert_false(Bool(_iso("PTH")), "H without digits")
    assert_false(Bool(_iso("PT1H2H")), "H twice")
    assert_false(Bool(_iso("PTM")), "M without digits")
    assert_false(Bool(_iso("PT1M2M")), "M twice")
    assert_false(Bool(_iso("PTS")), "S without digits")
    assert_false(Bool(_iso("PT1S2S")), "S twice")
    assert_false(Bool(_iso("PT.5S")), "fraction without integer")
    assert_false(Bool(_iso("PT1S2.5S")), "fraction after S")
    assert_false(Bool(_iso("PT1.S")), "fraction without digits")
    assert_false(Bool(_iso("PT1.5")), "fraction without S")
    assert_false(Bool(_iso("PT1.5X")), "fraction then X")
    assert_false(Bool(_iso("PT1X")), "unknown time letter")
    assert_false(Bool(_iso("PT")), "no component")


def test_numeric_duration_out_of_int64_ns() raises:
    """A numeric duration whose nanoseconds exceed Int64 is refused; one
    inside the range converts. Mutant: drop the range check (red: 1e10 s
    converts to a wrapped Int64)."""
    assert_equal(_dur("1.5").value(), Int64(1500000000))
    assert_false(Bool(_dur("1e10")), "1e19 ns overflows")
    assert_false(Bool(_dur("-1e10")), "-1e19 ns overflows")


# -----------------------------------------------------------------------------
# type inference
# -----------------------------------------------------------------------------


def _types(text: String, wide: Bool) raises -> List[ArrowType]:
    var b = _b(text)
    var cells = scan_csv_phase1_into_cells[Rfc4180](
        Span(b), UInt8(ord(",")), UInt8(ord('"'))
    )
    var opts = CsvReadOptions()
    var ncols = cells.num_cells_in_row(0)
    if wide:
        return infer_column_types_wide(
            Span(b), cells, 0, cells.num_rows(), ncols, opts
        )
    return infer_column_types(Span(b), cells, 0, cells.num_rows(), ncols, opts)


def _is(t: ArrowType, want: ArrowType, label: String) raises:
    assert_equal(Int(t.type_id), Int(want.type_id), label)


def test_infer_all_null_and_missing_cells() raises:
    """A column whose every cell is null is STRING in both lattices; a cell
    missing from a short row is skipped, not counted as a refusal. Mutant:
    resolve an all-null column to INT64 in the narrow lattice (red)."""
    var narrow = _types("1,\n2,\n", False)
    _is(narrow[0], ArrowType.INT64, "narrow col 0")
    _is(narrow[1], ArrowType.STRING, "narrow all-null col 1")
    var wide = _types("1,\n2,\n", True)
    _is(wide[1], ArrowType.STRING, "wide all-null col 1")
    var short = _types("1,2\n3\n4,5\n", True)
    _is(short[1], ArrowType.INT64, "wide col 1 with a missing cell")


def test_infer_wide_resolutions() raises:
    """Columns that resolve to DATE32, TIME32_MS, TIME64_NS, BOOL, FLOAT64 (a
    numeric too large for a Duration) and STRING. Mutant: resolve the DATE32
    arm to DATE64 (red)."""
    _is(_types("2024-01-01\n2024-02-29\n", True)[0], ArrowType.DATE32, "date32")
    _is(_types("12:00:00.5\n", True)[0], ArrowType.TIME32_MS, "time ms")
    _is(_types("12:00:00.1234567\n", True)[0], ArrowType.TIME64_NS, "time ns")
    _is(_types("yes\nno\n", True)[0], ArrowType.BOOL, "bool")
    _is(_types("1e10\n", True)[0], ArrowType.FLOAT64, "float beyond duration")
    _is(_types("abc\n", True)[0], ArrowType.STRING, "string")


# -----------------------------------------------------------------------------
# input limits, options, cell index
# -----------------------------------------------------------------------------


def _raises_column_count(n: Int) -> String:
    try:
        check_csv_column_count(n)
    except e:
        return String(e)
    return String("")


def test_input_limits_boundaries() raises:
    """Each limit accepts its boundary and refuses one past it. Mutant: `n_cols
    > MAX` -> `>=` in the column check (red: 4096 columns refused)."""
    assert_equal(_raises_column_count(MAX_CSV_COLUMNS), "")
    _has(_raises_column_count(MAX_CSV_COLUMNS + 1), "4097 columns")

    assert_equal(max_csv_rows_for_columns(0, 9), 2560)
    assert_equal(max_csv_rows_for_columns(2, 9), 1280)

    check_csv_cell_budget(2560, 1, 9)
    var msg = String("")
    try:
        check_csv_cell_budget(2561, 1, 9)
    except e:
        msg = String(e)
    _has(msg, "materializing 2561 rows x 1 columns")
    msg = String("")
    try:
        check_csv_cell_budget(-1, 1, 9)
    except e:
        msg = String(e)
    _has(msg, "negative materialization extent (rows=-1")
    msg = String("")
    try:
        check_csv_cell_budget(1, -1, 9)
    except e:
        msg = String(e)
    _has(msg, "cols=-1")

    check_csv_string_column_bytes(MAX_ARROW_STRING_BYTES, 0)
    msg = String("")
    try:
        check_csv_string_column_bytes(MAX_ARROW_STRING_BYTES + 1, 3)
    except e:
        msg = String(e)
    _has(msg, "STRING column at index 3")

    check_csv_row_bytes(10, 10, 0)
    check_csv_row_bytes(11, 0, 0)
    msg = String("")
    try:
        check_csv_row_bytes(11, 10, 7)
    except e:
        msg = String(e)
    _has(msg, "row starting at byte 7 spans 11 bytes")


def test_options_copy_is_deep_and_declared_width_check() raises:
    """`copy()` carries the per-column date formats, the projection and the
    declared types; the declared-width check accepts an empty list and
    refuses a width mismatch. Mutant: copy empty projection names (red: the
    copy no longer projects `a`)."""
    var o = CsvReadOptions()
    o.with_per_column_date_format(String("d"), String("YYYY-MM-DD"))
    o.with_projection(String("a"))
    o.declared_column_types.append(ArrowType.INT64)
    var c = o.copy()
    assert_equal(c.get_per_column_date_format(String("d")), "YYYY-MM-DD")
    assert_true(c.is_projected(String("a")), "projection copied")
    assert_false(c.is_projected(String("b")), "projection still filters")
    assert_equal(len(c.declared_column_types), 1)
    _is(c.declared_column_types[0], ArrowType.INT64, "declared type copied")

    var empty = List[ArrowType]()
    check_declared_column_types(empty, 3, String("w"))
    var msg = String("")
    try:
        check_declared_column_types(o.declared_column_types, 2, String("w"))
    except e:
        msg = String(e)
    _has(msg, "w: the plan declares 1 column(s) but the CSV header has 2")


def test_scanned_cells_first_violation_and_empty_row() raises:
    """The first quote violation wins over a later one; a row-byte check
    with a non-positive limit is off; a row with no cells is skipped by the
    row-byte check. Mutants: drop the `quote_violation_at >= 0` early return
    (red: the second violation overwrites), drop the `hi_i <= lo_i` skip
    (red: indexes a cell the empty row does not have)."""
    var cells = ScannedCells()
    cells.note_quote_violation(5, 1)
    cells.note_quote_violation(9, 2)
    assert_equal(cells.quote_violation_at, 5)
    assert_equal(cells.quote_violation_field, 1)

    var c2 = ScannedCells()
    c2.cell_starts.append(0)
    c2.cell_ends.append(3)
    c2.cell_flags.append(0)
    c2.row_starts.append(1)
    c2.row_starts.append(1)  # row 1 holds no cell
    c2.enforce_max_row_bytes(10)
    c2.enforce_max_row_bytes(0)
    var msg = String("")
    try:
        c2.enforce_max_row_bytes(2)
    except e:
        msg = String(e)
    _has(msg, "row starting at byte 0 spans 3 bytes")


def _refusal(text: String) raises -> String:
    var b = _b(text)
    try:
        _ = read_csv_bytes_to_batch[Rfc4180](Span(b), CsvReadOptions())
    except e:
        return String(e)
    return String("no refusal")


def test_record_location_counts_bare_cr_and_field_past_header() raises:
    """A refusal after bare-CR line ends numbers the line by counting each
    CR; a quote violation in a field beyond the header's width is named by
    position only. Mutants: drop the bare-CR `line + 1` (red: line 1),
    route the past-header field through `header_names[f]` (red: index past
    the header)."""
    var cr = _refusal("a,b\r1,2\r3\r")
    _has(cr, "record 3 (line 3, byte offset 8)")
    var named = _refusal('a,b\n1,"x"y\n')
    _has(named, "field 2 ('b'): byte 0x79 ('y')")
    var past = _refusal('a,b\n1,2,"x"y\n')
    _has(past, "field 3: byte 0x79 ('y')")


def main() raises:
    test_date64_each_ymd_and_hms_check()
    test_component_helpers_short_input_and_no_fraction()
    test_scalar_timestamp_refusals_every_unit()
    test_scalar_time_refusals()
    test_iso_duration_grammar_refusals()
    test_numeric_duration_out_of_int64_ns()
    test_infer_all_null_and_missing_cells()
    test_infer_wide_resolutions()
    test_input_limits_boundaries()
    test_options_copy_is_deep_and_declared_width_check()
    test_scanned_cells_first_violation_and_empty_row()
    test_record_location_counts_bare_cr_and_field_past_header()
    print("test_csv_cov_temporal_inference: 12 tests PASS")

# =============================================================================
# record_shape -- refuse a CSV record whose shape the reader cannot honour.
# =============================================================================
#
# Two malformed shapes used to lose data in silence (komira-ai/komira#449):
#
#   * A byte after a field's closing quote that is not the delimiter or a line
#     end (`"Ålesund "Å""`, a writer that forgot to double the inner quotes).
#     The scanners close the field at the first lone quote and start a new
#     field at the next byte, so the record grows a field.
#   * A record with more fields than the header. No column builder reads a
#     cell past the header's width, so the extra cells were dropped.
#
# A record with FEWER fields was null-padded: the column builders read a
# missing cell as NULL. RFC 4180 (section 2, rule 4) says every record has the
# same number of fields.
#
# All three are refused, under every dialect. Neither Excel nor Posix ever
# tolerated them by design: no option or dialect flag selected the behaviour,
# no test pinned it, and what they produced was wrong data (Excel split the
# field in two, Posix copied the closed field's bytes into the next one). The
# builders' missing-cell NULL branch stays as a bounds guard; after this check
# no reader path reaches it with a short record.
#
# Placement: ONE pass over `row_starts` after the scan and before any column
# builder allocates, like `ScannedCells.enforce_max_row_bytes`: two loads and
# a compare per row, nothing per cell. The quote violation is recorded by the
# scanners on the malformed branch only, so well-formed input pays nothing for
# it. Every reader entry calls this: `read_csv_bytes_to_batch`,
# `read_csv_bytes_to_schema` and each worker of the parallel reader (both
# arms). A parallel worker scans only its slice, so the record NUMBER in a
# refusal is computed on the error path by counting the records before the
# slice; well-formed input never pays for that either.
# =============================================================================

from .csv_scanner_phase1 import scan_csv_phase1_into_cells
from .quote_styles import QuoteStyle
from .scanned_cells import ScannedCells, CELL_FLAG_WAS_QUOTED


def check_csv_record_shape[
    Q: QuoteStyle
](
    input: Span[UInt8, _],
    chunk_lo: Int,
    file_offset: Int,
    cells: ScannedCells,
    data_start: Int,
    header_names: List[String],
    has_header: Bool,
    delimiter: UInt8,
    quote: UInt8,
    check_last_row: Bool = True,
) raises:
    """Raise on the first malformed record in `cells`, in file order.

    Args:
        input: The whole scanned input (after any stripped BOM). `cells`
            indexes `input[chunk_lo:]`; the bytes before `chunk_lo` are read
            only on the error path, to number the record.
        chunk_lo: Offset of the scanned slice within `input` (0 unless this
            is a parallel worker's slice; it is always a record boundary).
        file_offset: Offset of `input[0]` in the caller's buffer (3 after a
            stripped UTF-8 BOM), so byte offsets in a refusal are file offsets.
        cells: The scanner output for `input[chunk_lo:]`.
        data_start: First data row in `cells` (1 when row 0 is the header).
        header_names: One per column; its length is the required field count.
        has_header: Whether the field count comes from a header (wording only).
        delimiter: The field delimiter (to re-scan the prefix on error).
        quote: The quote byte (to re-scan the prefix on error).
        check_last_row: False when the caller cut the input at a byte budget
            and the last scanned row may be incomplete (schema sampling).

    Raises:
        Error naming the record number, its line and byte offset, the field
        and the problem.
    """
    var num_cols = len(header_names)
    var n_rows = cells.num_rows()
    var stop = n_rows
    if not check_last_row and stop > 0:
        stop = stop - 1
    var quote_row = -1
    if cells.quote_violation_at >= 0:
        quote_row = cells.quote_violation_row
        if quote_row < stop:
            stop = quote_row
    var r = data_start
    while r < stop:
        var n = cells.row_starts[r + 1] - cells.row_starts[r]
        if n != num_cols:
            _raise_field_count[Q](
                input, chunk_lo, file_offset, cells, r, n, header_names,
                has_header, delimiter, quote,
            )
        r = r + 1
    if quote_row >= 0:
        _raise_quote_violation[Q](
            input, chunk_lo, file_offset, cells, data_start, header_names,
            delimiter, quote,
        )


# =============================================================================
# Error path only.
# =============================================================================


def _record_location[
    Q: QuoteStyle
](
    input: Span[UInt8, _],
    chunk_lo: Int,
    file_offset: Int,
    cells: ScannedCells,
    r: Int,
    delimiter: UInt8,
    quote: UInt8,
) raises -> String:
    """`record N (line L, byte offset B)` for row `r` of `cells`.

    N counts records from the start of `input` (the header is record 1). L is
    the physical line the record starts on: 1 + the line ends before it (LF,
    CRLF or a bare CR), so a quoted newline in an earlier record moves L but
    not N. B is a file offset.
    """
    var first = cells.row_starts[r]
    var start = chunk_lo
    if first < len(cells.cell_starts):
        start = chunk_lo + cells.cell_starts[first]
        if (cells.cell_flags[first] & CELL_FLAG_WAS_QUOTED) != 0:
            start = start - 1  # the opening quote
    var before = 0
    if chunk_lo > 0:
        # `chunk_lo` is a record boundary, so the prefix scans to whole rows.
        before = scan_csv_phase1_into_cells[Q](
            input[0:chunk_lo], delimiter, quote
        ).num_rows()
    var line = 1
    var i = 0
    while i < start:
        var b = input[i]
        if b == UInt8(0x0A):
            line = line + 1
        elif b == UInt8(0x0D):
            if i + 1 >= len(input) or input[i + 1] != UInt8(0x0A):
                line = line + 1
        i = i + 1
    return (
        String("record ")
        + String(before + r + 1)
        + " (line "
        + String(line)
        + ", byte offset "
        + String(file_offset + start)
        + ")"
    )


def _raise_field_count[
    Q: QuoteStyle
](
    input: Span[UInt8, _],
    chunk_lo: Int,
    file_offset: Int,
    cells: ScannedCells,
    r: Int,
    n: Int,
    header_names: List[String],
    has_header: Bool,
    delimiter: UInt8,
    quote: UInt8,
) raises:
    var num_cols = len(header_names)
    var what: String
    if n > num_cols:
        what = String("field ") + String(num_cols + 1) + " has no column to go to"
    else:
        what = (
            String("field ")
            + String(n + 1)
            + " ('"
            + header_names[n]
            + "') is missing"
        )
    var fields = String(" fields") if n != 1 else String(" field")
    var source = String("the header") if has_header else String(
        "the first record"
    )
    raise Error(
        String("CSV ")
        + _record_location[Q](
            input, chunk_lo, file_offset, cells, r, delimiter, quote
        )
        + " has "
        + String(n)
        + fields
        + " but "
        + source
        + " has "
        + String(num_cols)
        + ": "
        + what
        + ". RFC 4180 requires every record to have the same number of"
        + " fields; the reader refuses rather than drop or pad cells."
    )


def _hex_digit(v: Int) -> String:
    if v < 10:
        return chr(48 + v)
    return chr(55 + v)  # 'A' is 65


def _hex2(b: UInt8) -> String:
    return String("0x") + _hex_digit(Int(b >> 4)) + _hex_digit(Int(b & 0x0F))


def _raise_quote_violation[
    Q: QuoteStyle
](
    input: Span[UInt8, _],
    chunk_lo: Int,
    file_offset: Int,
    cells: ScannedCells,
    data_start: Int,
    header_names: List[String],
    delimiter: UInt8,
    quote: UInt8,
) raises:
    var r = cells.quote_violation_row
    var f = cells.quote_violation_field
    var at = cells.quote_violation_at
    var field: String
    if r < data_start:
        field = String("header field ") + String(f + 1)
    elif f < len(header_names):
        field = String("field ") + String(f + 1) + " ('" + header_names[f] + "')"
    else:
        field = String("field ") + String(f + 1)
    var b = input[chunk_lo + at]
    var shown = _hex2(b)
    if b >= UInt8(0x20) and b <= UInt8(0x7E):
        shown += String(" ('") + chr(Int(b)) + "')"
    raise Error(
        String("CSV ")
        + _record_location[Q](
            input, chunk_lo, file_offset, cells, r, delimiter, quote
        )
        + ", "
        + field
        + ": byte "
        + shown
        + " at byte offset "
        + String(file_offset + chunk_lo + at)
        + " follows the field's closing quote. After a closing quote RFC 4180"
        + " allows only the delimiter, a line end or the end of input; a quote"
        + " inside a quoted field must be doubled."
    )

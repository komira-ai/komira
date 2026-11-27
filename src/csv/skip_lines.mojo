# =============================================================================
# skip_lines -- the byte offset after the first `skip` raw lines of a file.
# =============================================================================
#
# `read_csv(skip = n)` drops the first n lines before the header (or before the
# first record when there is no header). A line here is a RAW line, not a
# record: it ends at LF, CRLF (one end) or a bare CR, and a quote inside a
# skipped line opens no field. A UTF-8 BOM is part of line 1 and goes with it.
# A skip that leaves no line to read is refused by name, so a typo in `skip`
# does not read as an empty table.
# =============================================================================


def _count_lines(bytes: Span[UInt8, _]) -> Int:
    """The number of lines in `bytes`: its line ends, plus one for a last line
    with no line end. An empty input has none."""
    var n = len(bytes)
    var lines = 0
    var i = 0
    while i < n:
        var b = bytes[i]
        i = i + 1
        if b == UInt8(0x0D) and i < n and bytes[i] == UInt8(0x0A):
            i = i + 1
        if b == UInt8(0x0A) or b == UInt8(0x0D):
            lines = lines + 1
        elif i == n:
            lines = lines + 1
    return lines


def csv_skip_lines_end(bytes: Span[UInt8, _], skip: Int) raises -> Int:
    """Byte offset just past the `skip`-th line end of `bytes` (0 for skip 0).

    Lines end at LF, CRLF or a bare CR; quotes are not looked at.

    Raises:
        `CSV_SKIP_NEGATIVE` when `skip` is below 0, and `CSV_SKIP_PAST_END`
        when `skip` lines leave nothing to read (the file has `skip` lines or
        fewer).
    """
    if skip < 0:
        raise Error(
            String("CSV_SKIP_NEGATIVE: skip=")
            + String(skip)
            + " is negative; skip is the number of lines to skip at the start"
            + " of the file and must be 0 or more"
        )
    if skip == 0:
        return 0
    var n = len(bytes)
    var i = 0
    var ends = 0
    while i < n and ends < skip:
        var b = bytes[i]
        i = i + 1
        if b == UInt8(0x0D) and i < n and bytes[i] == UInt8(0x0A):
            i = i + 1
        if b == UInt8(0x0A) or b == UInt8(0x0D):
            ends = ends + 1
    if ends < skip or i >= n:
        var m = _count_lines(bytes)
        raise Error(
            String("CSV_SKIP_PAST_END: skip=")
            + String(skip)
            + " skips every line of the file, which has "
            + String(m)
            + (" line" if m == 1 else " lines")
            + "; no header or record is left to read"
        )
    return i

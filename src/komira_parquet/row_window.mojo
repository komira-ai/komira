# =============================================================================
# ROW WINDOW RESOLUTION: a table-scale (offset, length) slice onto row groups
# =============================================================================
#
# A `slice(offset, length)` over a table of row groups needs only the row
# groups the window overlaps. Given each row group's row count, in the order
# a scan claims them (file by file, row groups in file order), and the
# window, `resolve_row_group_window` builds a one-interval RowSelection
# (skip = offset, select = length) over the table's rows and clips it to each
# row group with `RowSelection.to_column_intervals`. A row group whose clip is
# non-empty is overlapped. The result is a contiguous row-group range
# `[first_rg, last_rg]` plus the trim to apply to the decoded and concatenated
# rows of that range.
#
# A pure function: the caller reads the footers and passes the row counts.
# =============================================================================

from komira_parquet.row_selection import RowSelection, RowInterval


@fieldwise_init
struct ParquetRowWindowResolution(Copyable, Movable, ImplicitlyCopyable):
    """The row groups an `(offset, length)` window overlaps, and the trim.

    Fields:
        first_rg: First row group (flat index) the window overlaps. 0 for an
            empty window over a non-empty table, -1 when there are no row
            groups.
        last_rg: Last row group the window overlaps, inclusive. 0 for an
            empty window (decode row group 0 only and trim it to 0 rows, so
            the result still carries the source schema), -1 when there are
            no row groups.
        local_skip: Rows to drop from the front of the decoded, concatenated
            `[first_rg .. last_rg]` rows to reach the window's first row.
        keep: Rows to keep after `local_skip`: the window length clamped to
            the rows the table has (0 for an empty window).
        is_empty: True iff the window selects no rows.
    """

    var first_rg: Int
    var last_rg: Int
    var local_skip: Int
    var keep: Int
    var is_empty: Bool


def resolve_row_group_window(
    rg_row_counts: List[Int], offset: Int, length: Int
) raises -> ParquetRowWindowResolution:
    """Resolve `(offset, length)` over the ordered `rg_row_counts`.

    `rg_row_counts[i]` is the row count of flat row group i. The cases:
      * no row groups: (-1, -1, 0, 0, empty).
      * offset >= the table's rows, or length <= 0: (0, 0, 0, 0, empty).
        A negative offset is clamped to 0.
      * offset + length past the table's end: `keep` is the rows from
        offset to the end.
      * otherwise: the smallest contiguous run of row groups holding
        `[offset, offset + keep)`, with `local_skip = offset - (rows before
        first_rg)`.
    """
    var n_rgs = len(rg_row_counts)
    if n_rgs == 0:
        return ParquetRowWindowResolution(-1, -1, 0, 0, True)

    var total = 0
    for i in range(n_rgs):
        total += rg_row_counts[i]

    # Clamp the window into [0, total]: a negative or oversized input
    # resolves to a shorter or empty window, never past the table.
    var lo = offset
    if lo < 0:
        lo = 0
    if lo > total:
        lo = total
    var avail = total - lo
    var keep = length
    if keep < 0:
        keep = 0
    if keep > avail:
        keep = avail

    if keep <= 0:
        return ParquetRowWindowResolution(0, 0, 0, 0, True)

    var intervals = List[RowInterval]()
    intervals.append(RowInterval(UInt64(lo), UInt64(keep)))
    var sel = RowSelection.from_intervals(intervals^)

    var first_rg = -1
    var last_rg = -1
    var first_rg_prefix = 0
    var prefix = 0
    for i in range(n_rgs):
        var page_ivls = List[RowInterval]()
        sel.to_column_intervals(UInt64(prefix), UInt64(rg_row_counts[i]), page_ivls)
        if len(page_ivls) > 0:
            if first_rg < 0:
                first_rg = i
                first_rg_prefix = prefix
            last_rg = i
        prefix += rg_row_counts[i]

    # keep > 0, so the window overlaps at least one row group.
    return ParquetRowWindowResolution(first_rg, last_rg, lo - first_rg_prefix, keep, False)

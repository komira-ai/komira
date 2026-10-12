# =============================================================================
# ROW SELECTION: sorted, non-overlapping (skip, select) intervals
# =============================================================================
#
# The page-level predicate-pushdown primitive: which rows of a row group a
# reader decodes, as runs of rows to skip followed by runs to select. It lets
# a reader skip whole pages when page-index statistics prove a predicate can
# never match, and clip a row-group-wide selection to one page.
#
#     RowInterval     (skip, select), UInt64 row counts
#     IntervalCursor  walks a Span of RowIntervals one phase at a time
#     RowSelection    an owned list of intervals, its constructors and the
#                     operations on it
#
# Coordinates: interval i starts where interval i - 1 ends; the first starts
# at row 0 of the row group. Consecutive intervals are kept merged: no
# interval after the first has skip == 0. The list ends at the last selected
# row; rows after it are not recorded, so `total_rows()` is the end of the
# last selected run, not the row group's row count. `selects_all(num_rows)`
# takes the row count for that reason.
# =============================================================================

from komira_arrow.boolean_array import BooleanArray


# ---------------------------------------------------------------------------
# RowInterval
# ---------------------------------------------------------------------------


@fieldwise_init
struct RowInterval(Copyable, Movable, ImplicitlyCopyable):
    """A single (skip, select) interval within a row selection.

    Fields:
        skip:   Number of rows to skip before the selected run.
        select: Number of rows to select (read/decode).
    """

    var skip: UInt64
    var select: UInt64


# ---------------------------------------------------------------------------
# IntervalCursor: the state machine the merge walks share
# ---------------------------------------------------------------------------


struct IntervalCursor[origin: Origin](Movable):
    """Walks a `Span[RowInterval, Self.origin]` through its skip and select
    phases, so the merge walks (`RowSelection.intersect`) need no bitmap.

    Parameters:
        origin: Lifetime of the borrowed interval slice.
    """

    var intervals: Span[RowInterval, Self.origin]
    var idx: Int
    var in_skip: Bool
    var remaining: UInt64

    def __init__(out self, intervals: Span[RowInterval, Self.origin]):
        self.intervals = intervals
        self.idx = 0
        self.in_skip = True
        if len(intervals) == 0:
            self.remaining = 0
        else:
            self.remaining = intervals[0].skip

    @always_inline
    def exhausted(self) -> Bool:
        """Whether the cursor has walked every interval."""
        return self.idx >= len(self.intervals)

    @always_inline
    def is_selecting(self) -> Bool:
        """Whether the cursor is in a select phase."""
        return (not self.in_skip) and (not self.exhausted())

    def consume_phase(
        mut self,
        n: UInt64,
        mut out_consumed: UInt64,
        mut out_was_selecting: Bool,
    ) -> None:
        """Consume up to `n` rows of the current phase without crossing a
        phase boundary, first moving past any empty phases. Writes the rows
        consumed and whether they were selected into the two out arguments;
        both are 0 / False once the cursor is exhausted. `n == 0` only moves
        the cursor onto its next non-empty phase.
        """
        while (not self.exhausted()) and self.remaining == 0:
            if self.in_skip:
                self.in_skip = False
                self.remaining = self.intervals[self.idx].select
            else:
                self.idx += 1
                if self.idx >= len(self.intervals):
                    out_consumed = UInt64(0)
                    out_was_selecting = False
                    return
                self.in_skip = True
                self.remaining = self.intervals[self.idx].skip
        if self.exhausted():
            out_consumed = UInt64(0)
            out_was_selecting = False
            return
        var selecting = not self.in_skip
        var step = n if n < self.remaining else self.remaining
        self.remaining -= step
        out_consumed = step
        out_was_selecting = selecting


# ---------------------------------------------------------------------------
# RowSelection
# ---------------------------------------------------------------------------


struct RowSelection(Movable):
    """Sorted, non-overlapping (skip, select) intervals over one row group.
    See the module header for the coordinates and the merge invariant."""

    var intervals: List[RowInterval]

    def __init__(out self):
        self.intervals = List[RowInterval]()

    @staticmethod
    def from_intervals(var intervals: List[RowInterval]) -> RowSelection:
        """Take ownership of `intervals`, merging each follower whose skip is
        0 into the interval before it."""
        var sel = RowSelection()
        sel.intervals = intervals^
        _merge_intervals(sel.intervals)
        return sel^

    @staticmethod
    def all(num_rows: UInt64) -> RowSelection:
        """Select all `num_rows`: a single interval with skip 0."""
        var sel = RowSelection()
        sel.intervals.append(RowInterval(UInt64(0), num_rows))
        return sel^

    @staticmethod
    def none() -> RowSelection:
        """An empty selection: zero intervals."""
        return RowSelection()

    @staticmethod
    def from_page_mask(
        page_included: Span[Bool, _],
        page_row_counts: Span[UInt64, _],
    ) raises -> RowSelection:
        """Build from per-page include decisions.

        `page_included[i]` is True iff page i is decoded and
        `page_row_counts[i]` is its row count. Runs of skipped pages add up
        into the next interval's skip; skipped pages after the last included
        one produce no interval.

        Raises:
            Error if the two spans differ in length.
        """
        if len(page_included) != len(page_row_counts):
            raise Error(
                "RowSelection.from_page_mask: page_included and"
                " page_row_counts must have same length"
            )

        var sel = RowSelection()
        var pending_skip: UInt64 = 0
        for i in range(len(page_included)):
            var rows = page_row_counts[i]
            if page_included[i]:
                sel.intervals.append(RowInterval(pending_skip, rows))
                pending_skip = 0
            else:
                pending_skip += rows
        _merge_intervals(sel.intervals)
        return sel^

    @staticmethod
    def from_mask(mask: BooleanArray) raises -> RowSelection:
        """Build from a row-group-wide boolean mask.

        Row i is selected iff `mask[i]` is true and not null: a null in a
        filter mask does not select its row (SQL WHERE keeps only TRUE).
        Runs of unselected rows add up into the next interval's skip.
        """
        var sel = RowSelection()
        var pending_skip: UInt64 = 0
        for i in range(mask.length):
            if mask.get(i) and not mask.is_null(i):
                sel.intervals.append(RowInterval(pending_skip, UInt64(1)))
                pending_skip = 0
            else:
                pending_skip += 1
        _merge_intervals(sel.intervals)
        return sel^

    def intersect(self, other: RowSelection) -> RowSelection:
        """The rows selected by both selections, by a merge walk of the two
        interval lists (no bitmap)."""
        var total_a = self.total_rows()
        var total_b = other.total_rows()
        var total = total_a if total_a > total_b else total_b

        if total == 0:
            return RowSelection.none()

        var cur_a = IntervalCursor(Span(self.intervals))
        var cur_b = IntervalCursor(Span(other.intervals))

        var out = RowSelection()
        var pending_skip: UInt64 = 0
        var pos: UInt64 = 0

        while pos < total and (not cur_a.exhausted()) and (not cur_b.exhausted()):
            # Move each cursor onto a non-empty phase first.
            var scratch_n: UInt64 = 0
            var scratch_b: Bool = False
            if cur_a.remaining == 0:
                cur_a.consume_phase(UInt64(0), scratch_n, scratch_b)
                continue
            if cur_b.remaining == 0:
                cur_b.consume_phase(UInt64(0), scratch_n, scratch_b)
                continue

            var both_selecting = cur_a.is_selecting() and cur_b.is_selecting()
            var step = cur_a.remaining if cur_a.remaining < cur_b.remaining else cur_b.remaining

            cur_a.remaining -= step
            cur_b.remaining -= step
            pos += step

            if both_selecting:
                out.intervals.append(RowInterval(pending_skip, step))
                pending_skip = 0
            else:
                pending_skip += step

        _merge_intervals(out.intervals)
        return out^

    def intersect_mask(self, mask: BooleanArray) raises -> RowSelection:
        """Intersect with a mask over the SELECTED rows only.

        `mask[k]` decides the k-th selected row; the result is in the
        row-group frame. A mask shorter than `num_selected()` deselects the
        rows past its end; a null mask entry deselects its row.
        """
        var mask_idx = 0
        var out = RowSelection()
        var pending_skip: UInt64 = 0

        for ivl_i in range(len(self.intervals)):
            var interval = self.intervals[ivl_i]
            pending_skip += interval.skip
            for _ in range(Int(interval.select)):
                var selected = False
                if mask_idx < mask.length:
                    selected = mask.get(mask_idx) and not mask.is_null(mask_idx)
                mask_idx += 1
                if selected:
                    out.intervals.append(RowInterval(pending_skip, UInt64(1)))
                    pending_skip = 0
                else:
                    pending_skip += 1

        _merge_intervals(out.intervals)
        return out^

    def to_column_intervals(
        self,
        page_first_row: UInt64,
        page_row_count: UInt64,
        mut out: List[RowInterval],
    ) -> None:
        """Clip this selection to the page holding rows
        `[page_first_row, page_first_row + page_row_count)` and append the
        page-local (skip, select) intervals to `out`, in the page's own
        coordinates. Nothing is appended for a page no selected row falls in;
        skipped rows after the page's last selected run are not recorded.
        """
        var page_start = page_first_row
        var page_end = page_first_row + page_row_count
        var pos: UInt64 = 0
        var pending_skip: UInt64 = 0

        for i in range(len(self.intervals)):
            var interval = self.intervals[i]
            var skip_end = pos + interval.skip
            var skip_start_in_page = pos if pos > page_start else page_start
            var skip_end_in_page = skip_end if skip_end < page_end else page_end
            if skip_end_in_page > skip_start_in_page:
                pending_skip += skip_end_in_page - skip_start_in_page
            pos = skip_end

            var sel_end = pos + interval.select
            var sel_start_in_page = pos if pos > page_start else page_start
            var sel_end_in_page = sel_end if sel_end < page_end else page_end
            if sel_end_in_page > sel_start_in_page:
                out.append(RowInterval(pending_skip, sel_end_in_page - sel_start_in_page))
                pending_skip = 0
            pos = sel_end

            if pos >= page_end:
                break

    def total_rows(self) -> UInt64:
        """Sum of skip + select over all intervals: the end of the last
        selected run."""
        var total: UInt64 = 0
        for i in range(len(self.intervals)):
            total += self.intervals[i].skip + self.intervals[i].select
        return total

    def num_selected(self) -> UInt64:
        """Total selected rows."""
        var total: UInt64 = 0
        for i in range(len(self.intervals)):
            total += self.intervals[i].select
        return total

    def selects_all(self, num_rows: UInt64) -> Bool:
        """True iff this selection selects every row of a row group of
        `num_rows` rows: one interval, skip 0, select `num_rows`. A
        selection whose trailing rows are unselected is not "all", although
        its single interval starts at row 0."""
        return (
            len(self.intervals) == 1
            and self.intervals[0].skip == 0
            and self.intervals[0].select == num_rows
        )


def _merge_intervals(mut intervals: List[RowInterval]) -> None:
    """Merge each interval whose skip is 0 into the one before it."""
    if len(intervals) <= 1:
        return

    var merged = List[RowInterval]()
    merged.append(intervals[0])

    for i in range(1, len(intervals)):
        var nxt = intervals[i]
        if nxt.skip == 0:
            var last_idx = len(merged) - 1
            merged[last_idx] = RowInterval(
                merged[last_idx].skip,
                merged[last_idx].select + nxt.select,
            )
        else:
            merged.append(nxt)

    intervals = merged^

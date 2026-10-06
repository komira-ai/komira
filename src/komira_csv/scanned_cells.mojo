# =============================================================================
# scanned_cells -- flat-buffer CSV scanner output.
# =============================================================================
#
# Problem: a `List[Row]` + per-Row `List[CellRange]` shape (the
# `csv_scanner_phase1.mojo` row surface) makes one `List.append` per cell
# -- ~96 M on a TPC-H SF1 lineitem file (6 M rows x 16 cells) -- and a
# large share of the single-thread wall goes to `List._reserve_one` /
# `List._realloc` / allocator page-heap traffic.
#
# Solution: replace the per-row + per-cell List allocation cascade with
# 4 pre-sized contiguous buffers, mirroring pyarrow's `RawBlockBuffer`,
# DuckDB's `DataChunk` column vectors, and polars' per-worker partition
# buffers -- the design pattern shared by all 3 of CSV's strongest
# competitors:
#
#   - `cell_starts: List[Int]` -- inclusive byte-offset of each cell start
#   - `cell_ends:   List[Int]` -- exclusive byte-offset of each cell end
#   - `cell_flags:  List[UInt8]` -- bit-packed cell flags (was_quoted,
#                                   needs_unescape)
#   - `row_starts:  List[Int]` -- index into the cell_* arrays where each
#                                 row begins; len = num_rows + 1 (sentinel
#                                 at the end = total cell count, so the
#                                 last row's cell count = row_starts[-1] -
#                                 row_starts[-2] without a branch).
#
# Encapsulation: this module exposes only `ScannedCells` (the flat-buffer
# struct). All cell access flows through `cell(r, c)` / `num_cells_in_row(r)`
# index-math accessors; no UnsafePointer crosses any public boundary; no
# additional view-type or borrowed-pointer indirection is required at
# call sites.
# =============================================================================

from .csv_scanner_phase1 import CellRange
from .input_limits import check_csv_row_bytes


# Flag bits packed into `cell_flags[i]`. UInt8 is intentional: only 2 bits
# are used today (was_quoted + needs_unescape); reserve the upper 6 bits
# for future scanner-side metadata (e.g. cell_is_null, cell_is_all_digits)
# without an ABI break.
comptime CELL_FLAG_WAS_QUOTED: UInt8 = 1
comptime CELL_FLAG_NEEDS_UNESCAPE: UInt8 = 2


@always_inline
def pack_cell_flags(was_quoted: Bool, needs_unescape: Bool) -> UInt8:
    """Pack (was_quoted, needs_unescape) into a single UInt8."""
    var f: UInt8 = 0
    if was_quoted:
        f = f | CELL_FLAG_WAS_QUOTED
    if needs_unescape:
        f = f | CELL_FLAG_NEEDS_UNESCAPE
    return f


# =============================================================================
# ScannedCells -- the flat-buffer output of every scanner variant.
# =============================================================================


struct ScannedCells(Movable, Deinitable):
    """Flat-buffer CSV scanner output.

    Holds 4 contiguous Lists describing every cell in the scanned buffer:
        cell_starts[i]: inclusive byte-offset of cell `i` start
        cell_ends[i]:   exclusive byte-offset of cell `i` end
        cell_flags[i]:  packed UInt8 flags (CELL_FLAG_* bits)
        row_starts[r]:  index into cell_* arrays where row `r` begins
                        (len = num_rows + 1; `row_starts[num_rows]` is a
                        sentinel = total cell count, so the cell count of
                        row r is `row_starts[r+1] - row_starts[r]` without
                        a branch).

    All offsets are relative to the source bytes Span that was passed to
    the scanner. The caller owns the source bytes; `ScannedCells` only
    indexes into them via integer ranges.

    The scanner also records the FIRST quote violation it met: a byte after
    a field's closing quote that is not the delimiter, CR or LF (RFC 4180
    allows nothing else there). The scanners stay lenient past it (the bytes
    up to the next delimiter become one more field), so these fields are the
    only trace of the problem; `record_shape.check_csv_record_shape` turns
    them into a refusal. `quote_violation_at == -1` means none was seen.
        quote_violation_at:    byte offset of the offending byte
        quote_violation_row:   row index (same numbering as `row_starts`)
        quote_violation_field: 0-based field index of the closed field

    NOT Copyable (the backing Lists can be large) -- pass by `^` or `ref`.
    """

    var cell_starts: List[Int]
    var cell_ends: List[Int]
    var cell_flags: List[UInt8]
    var row_starts: List[Int]
    var quote_violation_at: Int
    var quote_violation_row: Int
    var quote_violation_field: Int

    def __init__(out self):
        """Empty ScannedCells (zero rows, zero cells)."""
        self.cell_starts = List[Int]()
        self.cell_ends = List[Int]()
        self.cell_flags = List[UInt8]()
        self.row_starts = List[Int]()
        # Sentinel for the empty-rows case: row_starts has len 1 = [0].
        self.row_starts.append(0)
        self.quote_violation_at = -1
        self.quote_violation_row = -1
        self.quote_violation_field = -1

    def __init__(out self, est_cells: Int, est_rows: Int):
        """Construct with reserved capacity (pre-size hint).

        Reserves space for `est_cells` cells and `est_rows + 1` row
        indices (the +1 is the trailing sentinel). Over-reservation is
        bounded by the actual scanner output; tcmalloc returns committed
        pages back to the OS on drop.

        Pre-size hint: pass `est_cells = est_bytes / 12`, `est_rows =
        est_bytes / 120` for typical TPC-H-shaped CSV. Off-by-2x is fine.
        """
        self.cell_starts = List[Int](capacity=est_cells)
        self.cell_ends = List[Int](capacity=est_cells)
        self.cell_flags = List[UInt8](capacity=est_cells)
        self.row_starts = List[Int](capacity=est_rows + 1)
        self.row_starts.append(0)
        self.quote_violation_at = -1
        self.quote_violation_row = -1
        self.quote_violation_field = -1

    # __moveinit__ + __del__ are compiler-synthesized: the 4 Lists are
    # List[POD] (Movable + Deinitable) and the rest are Ints.

    def note_quote_violation(mut self, byte_pos: Int, field: Int):
        """Record a byte after a closing quote that is not the delimiter or a
        line end, unless an earlier one is already recorded.

        Called by the scanners only on that malformed branch, so well-formed
        input pays nothing. `field` is the 0-based index (within the current
        row) of the field the quote closed; the row is the one in progress,
        `len(row_starts) - 1`.
        """
        if self.quote_violation_at >= 0:
            return
        self.quote_violation_at = byte_pos
        self.quote_violation_row = len(self.row_starts) - 1
        self.quote_violation_field = field

    @always_inline
    def row_is_blank(self, r: Int) -> Bool:
        """True iff row `r` is a fully blank line: one cell, unquoted, with
        zero bytes (so `""` is not blank)."""
        var lo = self.row_starts[r]
        if self.row_starts[r + 1] - lo != 1:
            return False
        return (
            self.cell_starts[lo] == self.cell_ends[lo]
            and (self.cell_flags[lo] & CELL_FLAG_WAS_QUOTED) == 0
        )

    def drop_blank_rows(mut self, from_row: Int):
        """Remove every blank row (`row_is_blank`) at index >= `from_row`,
        compacting the cell arrays in place. O(cells after the first blank
        row); called only when a blank row exists.

        In-place safety: iteration `r` reads `row_starts[r]` and
        `row_starts[r + 1]` before any write, and writes go only to row index
        `out_row <= r` and cell index `w <= row_starts[r]`.
        """
        var n_rows = self.num_rows()
        var out_row = from_row
        var w = self.row_starts[from_row]
        for r in range(from_row, n_rows):
            var lo = self.row_starts[r]
            var hi = self.row_starts[r + 1]
            if (
                hi - lo == 1
                and self.cell_starts[lo] == self.cell_ends[lo]
                and (self.cell_flags[lo] & CELL_FLAG_WAS_QUOTED) == 0
            ):
                continue
            self.row_starts[out_row] = w
            for i in range(lo, hi):
                self.cell_starts[w] = self.cell_starts[i]
                self.cell_ends[w] = self.cell_ends[i]
                self.cell_flags[w] = self.cell_flags[i]
                w = w + 1
            out_row = out_row + 1
        self.row_starts[out_row] = w
        while len(self.row_starts) > out_row + 1:
            _ = self.row_starts.pop()
        while len(self.cell_starts) > w:
            _ = self.cell_starts.pop()
            _ = self.cell_ends.pop()
            _ = self.cell_flags.pop()

    @always_inline
    def cells_in_open_row(self) -> Int:
        """Cells appended to the row in progress (not yet closed by a
        `row_starts` entry)."""
        return len(self.cell_starts) - self.row_starts[len(self.row_starts) - 1]

    @always_inline
    def num_rows(self) -> Int:
        """Number of complete rows scanned. Equal to `len(row_starts) - 1`
        because `row_starts` carries a trailing sentinel."""
        return len(self.row_starts) - 1

    @always_inline
    def num_cells_in_row(self, r: Int) -> Int:
        """Number of cells in row `r`. Branch-free; equals
        `row_starts[r+1] - row_starts[r]`."""
        return self.row_starts[r + 1] - self.row_starts[r]

    @always_inline
    def total_cells(self) -> Int:
        """Total cells across all rows (= len(cell_starts))."""
        return len(self.cell_starts)

    @always_inline
    def cell(self, r: Int, c: Int) -> CellRange:
        """Return the CellRange at (row r, col c). Caller must ensure
        `c < num_cells_in_row(r)`. Cheap: 3 index loads + 2 bit tests.
        """
        var i = self.row_starts[r] + c
        var flags = self.cell_flags[i]
        return CellRange(
            self.cell_starts[i],
            self.cell_ends[i],
            (flags & CELL_FLAG_WAS_QUOTED) != 0,
            (flags & CELL_FLAG_NEEDS_UNESCAPE) != 0,
        )

    @always_inline
    def cell_start(self, r: Int, c: Int) -> Int:
        """Just the start byte-offset (fast path for builders that don't
        need was_quoted/needs_unescape)."""
        return self.cell_starts[self.row_starts[r] + c]

    @always_inline
    def cell_end(self, r: Int, c: Int) -> Int:
        """Just the end byte-offset."""
        return self.cell_ends[self.row_starts[r] + c]

    @always_inline
    def cell_flags_at(self, r: Int, c: Int) -> UInt8:
        """Packed UInt8 flags for the cell at (r, c)."""
        return self.cell_flags[self.row_starts[r] + c]

    def enforce_max_row_bytes(self, max_row_bytes: Int) raises:
        """Enforce `CsvReadOptions.max_row_bytes` over the scanned rows.

        ⚠ THIS IS WHAT MAKES `max_row_bytes` REAL (it holds with assertions
        compiled out). Without this method the option is declared,
        defaulted, copied and accepted by the full ctor, yet read by no
        scanner code. A declared-but-unenforced safety cap is worse than none, because
        it reads as protection during review.

        Placement: ONE pass over `row_starts` after the scan and BEFORE any
        column builder allocates -- two List loads, a subtract and a compare
        per row. It is deliberately NOT inside the SIMD scanner's per-byte
        loop, which is the hot path this whole surface exists to keep fast;
        the scan is O(input) and self-limiting, whereas the allocation it
        feeds is what the cap is protecting.

        A row's byte span is `last_cell_end - first_cell_start`; zero-cell
        rows are skipped.
        """
        if max_row_bytes <= 0:
            return
        var n_rows = self.num_rows()
        for r in range(n_rows):
            var lo_i = self.row_starts[r]
            var hi_i = self.row_starts[r + 1]
            if hi_i <= lo_i:
                continue
            var row_start = self.cell_starts[lo_i]
            var row_end = self.cell_ends[hi_i - 1]
            check_csv_row_bytes(row_end - row_start, max_row_bytes, row_start)

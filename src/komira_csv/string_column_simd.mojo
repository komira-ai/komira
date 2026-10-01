# =============================================================================
# string_column_simd — SIMD-vectorized STRING/BINARY column builder fast path.
# =============================================================================
#
# STRING is 5 of 16 columns on a lineitem-shaped CSV AND every cell on a
# quote-heavy one. The naive `_build_string_column` shape does:
#
#   1. Build a `List[String]` over `num_rows` entries; for each cell,
#      `cell_to_string` does `String("") + chr(Int(b))` per byte (O(N)
#      reallocs per byte -- the worst possible shape).
#   2. `StringArray.from_strings(values)` then does TWO MORE passes
#      (count total bytes, memcpy from each owned String into the data
#      buffer).
#
# Total: ~4 passes + N reallocs per cell. The SIMD fast path here does
# exactly 2 passes total, with a single `memcpy` per cell into the
# pre-sized data buffer, and ZERO intermediate `List[String]`.
#
# Algorithm:
#
#   Pass 1 (sizing): walk rows once. For each row's cell at col_idx:
#     - check null_cell (matches null-token cascade)
#     - if non-null: accumulate `cell.end - cell.start` into total_bytes,
#       record `needs_unescape` flag, mark `null_positions` if null.
#     - For `needs_unescape=True` cells (rare; only Excel/Posix dialects
#       with embedded quotes), pessimistically allocate the unescaped
#       size = cell length (collapse can only SHRINK, never grow).
#     - Track `any_needs_unescape` so the fast path can skip the per-cell
#       collapse loop entirely when no cell needs it.
#
#   Pass 2 (fill): pre-allocate offsets buffer of `(N+1)*4` bytes +
#     data buffer of `total_bytes`. Walk rows:
#     - For null cells: emit offsets[i+1] = offsets[i] (zero-length).
#     - For non-null fast-path cells (no unescape): bulk `memcpy` cell
#       bytes into data buffer at running offset; offsets[i+1] = new offset.
#     - For unescape cells: scalar in-place collapse via
#       `_collapse_doubled_quote_into_buf` (RFC-4180/Excel) or
#       `_collapse_posix_backslash_into_buf` (Posix); both write straight
#       into the data buffer with no intermediate String allocation.
#
#   Pass 3 (validity bitmap, only if any nulls):
#     - Allocate all-valid bitmap; clear the recorded null positions.
#
# Encapsulation: every public function takes
# `Span[UInt8, _]` and returns `StringArray` -- no `UnsafePointer` crosses
# the module boundary. The internal `bytes.unsafe_ptr()` is used to make
# a ByteView for the bulk memcpy, scoped to a `# SAFETY:` block.
#
# Safety properties of this module:
#   * No UnsafePointer in public signatures (only Span / ByteView / StringArray).
#   * No wildcard origins (Span is origin-poly via `_` placeholder).
#   * No `unsafe_from_address=Int(...)`.
#   * No `UnsafePointer(to=struct.field).take_pointee()` partial-moves.
#   * No additive parallel API -- the `_build_string_column[Q]` entry in
#     parallel_reader.mojo + reader.mojo calls into this helper; there is
#     no second public column-builder surface.
# =============================================================================

from std.sys import size_of

from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.collections.byte_view import ByteView

from .csv_options import CsvReadOptions
from .input_limits import check_csv_string_column_bytes
from .scanned_cells import ScannedCells
from .null_detection import is_null_cell


# =============================================================================
# Internal helpers: in-place unescape into a pre-sized destination buffer.
# =============================================================================
#
# The output position is tracked via a mutable Int reference; both helpers
# return the count of bytes written. Empirical equivalence with
# `unescape_cell_double_quote` / `unescape_cell_posix` is verified by the
# parity tests (test_csv_simd_string_column).


def _collapse_doubled_quote_into_buf(
    cell: Span[UInt8, _],
    quote: UInt8,
    mut data_buf: OwnedAlignedBuffer,
    dst_offset: Int,
) -> Int:
    """Collapse `""` -> `"` inside `cell`, writing into `data_buf` starting
    at `dst_offset`. Returns the number of bytes written.

    RFC-4180 / Excel doubled-quote escape mode.

    Caller MUST ensure `data_buf.capacity() >= dst_offset + len(cell)` (the
    cell length is an upper bound on the unescaped length).
    """
    var n = len(cell)
    var i = 0
    var w = 0
    while i < n:
        var b = cell[i]
        if b == quote and i + 1 < n and cell[i + 1] == quote:
            data_buf.write_u8_at(dst_offset + w, quote)
            w = w + 1
            i = i + 2
            continue
        data_buf.write_u8_at(dst_offset + w, b)
        w = w + 1
        i = i + 1
    return w


def _collapse_posix_backslash_into_buf(
    cell: Span[UInt8, _],
    escape: UInt8,
    mut data_buf: OwnedAlignedBuffer,
    dst_offset: Int,
) -> Int:
    """Collapse Posix backslash escapes (`\\X` -> X translated) into
    `data_buf` starting at `dst_offset`. Returns the number of bytes written.

    Posix dialect: `\\n` -> 0x0A, `\\t` -> 0x09, `\\r` -> 0x0D, otherwise
    `\\X` -> X literal.

    Caller MUST ensure `data_buf.capacity() >= dst_offset + len(cell)` (the
    cell length is an upper bound on the unescaped length).
    """
    var n = len(cell)
    var i = 0
    var w = 0
    while i < n:
        var b = cell[i]
        if b == escape and i + 1 < n:
            var nx = cell[i + 1]
            var out_byte: UInt8 = nx
            if nx == UInt8(0x6E):  # 'n'
                out_byte = UInt8(0x0A)
            elif nx == UInt8(0x74):  # 't'
                out_byte = UInt8(0x09)
            elif nx == UInt8(0x72):  # 'r'
                out_byte = UInt8(0x0D)
            data_buf.write_u8_at(dst_offset + w, out_byte)
            w = w + 1
            i = i + 2
            continue
        data_buf.write_u8_at(dst_offset + w, b)
        w = w + 1
        i = i + 1
    return w


# =============================================================================
# Cell -> ByteView helper for bulk memcpy.
# =============================================================================
#
# The bulk `memcpy` from a `Span[UInt8, _]` slice into the data buffer is
# the centerpiece SIMD path: stdlib's `memcpy` is auto-vectorized to AVX2
# / NEON wide-load + wide-store. We need a ByteView over the cell range
# to feed `MmapAlignedBuffer.copy_from_view_at`.


# NOTE: helper inlined into call site below. We construct the ByteView
# directly at the consume site so that origin inference picks up the
# `bytes` lifetime without us needing to spell `__origin_of(bytes)`
# explicitly across a helper boundary. The `unsafe_ptr` access is
# bounded by an inline `# SAFETY:` block.


# =============================================================================
# Public entry: build STRING column with SIMD/bulk-memcpy fast path.
# =============================================================================


def build_string_column_simd(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
    quote: UInt8,
    double_quote_escapes: Bool,
    posix_escape: UInt8,
) raises -> StringArray[HeapRegion]:
    """Build a STRING column directly into Arrow offset+data buffers.

    Instead of a `List[String]` -> `StringArray.from_strings` path,
    a 2-pass `memcpy`-bulk shape. See module header for the full
    algorithm.

    Args:
        bytes: Per-worker byte slice (the source CSV bytes).
        cells: Scanner output (flat-buffer ScannedCells).
        data_start: Index of the first data row (post-header).
        col_idx: Column index to extract.
        num_rows: Number of data rows.
        options: CsvReadOptions (null-token cascade).
        quote: Quote byte (typically 0x22 = `"`).
        double_quote_escapes: True for RFC-4180/Excel; False for Posix.
        posix_escape: Posix backslash byte; consulted only when
            `double_quote_escapes` is False.

    Returns:
        Owned StringArray ready to be wrapped in Column.from_string(...).
    """
    # -----------------------------------------------------------------------
    # Pass 1: size + null detection.
    # -----------------------------------------------------------------------
    # We accumulate the worst-case total bytes (cell-length sum); for
    # unescape cells the unescaped form is <= cell length, so this is a
    # safe over-allocation upper bound. Per-cell bookkeeping is two
    # parallel arrays: cell_byte_len (Int) and cell_was_null (Bool).
    var total_bytes_cap = 0
    var null_positions = List[Int]()
    var any_unescape = False
    # Per-row scratch: store the cell byte range (or -1 if null/missing).
    # NOTE: distinct from `cells.cell_starts` — these are per-DATA-row
    # local copies tagged with -1 to mark null/missing positions.
    var local_cell_starts = List[Int]()
    var local_cell_ends = List[Int]()
    var local_cell_needs_unescape = List[Bool]()
    local_cell_starts.reserve(num_rows)
    local_cell_ends.reserve(num_rows)
    local_cell_needs_unescape.reserve(num_rows)

    var r = 0
    while r < num_rows:
        var row_idx = data_start + r
        if col_idx >= cells.num_cells_in_row(row_idx):
            # Missing cell -> null.
            null_positions.append(r)
            local_cell_starts.append(-1)
            local_cell_ends.append(-1)
            local_cell_needs_unescape.append(False)
            r = r + 1
            continue
        var cr = cells.cell(row_idx, col_idx)
        var cell = bytes[cr.start:cr.end]
        if is_null_cell(cell, options):
            null_positions.append(r)
            local_cell_starts.append(-1)
            local_cell_ends.append(-1)
            local_cell_needs_unescape.append(False)
            r = r + 1
            continue
        var cell_len = cr.end - cr.start
        total_bytes_cap = total_bytes_cap + cell_len
        local_cell_starts.append(cr.start)
        local_cell_ends.append(cr.end)
        local_cell_needs_unescape.append(cr.needs_unescape)
        if cr.needs_unescape:
            any_unescape = True
        r = r + 1

    # -----------------------------------------------------------------------
    # Pass 2: allocate offsets + data, then bulk-fill.
    # -----------------------------------------------------------------------
    # ARROW-32 OFFSET CEILING (holds with assertions compiled out).
    #
    # `running_offset` below is narrowed with a bare `Int32(running_offset)` at
    # every offsets write. `data_buf` is sized from the UN-narrowed
    # `total_bytes_cap`, so past 2 GiB the data buffer is correctly large while
    # the offsets wrap NEGATIVE -- the StringArray then ships with
    # `offsets[i] < 0` and every consumer doing `data[offsets[i]:offsets[i+1]]`
    # reads BEFORE the buffer. No stdlib bounds check is involved in an Int32
    # narrowing, so this is silent at ASSERT=safe and ASSERT=none alike.
    #
    # ONE compare, on the total pass 1 already summed -- the per-cell loop
    # above is untouched.
    check_csv_string_column_bytes(total_bytes_cap, col_idx)

    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer((num_rows + 1) * int32_size)
    offsets_buf.set_typed[Int32](0, Int32(0))

    var data_cap = max(total_bytes_cap, 1)
    var data_buf = OwnedAlignedBuffer(data_cap)

    var running_offset = 0
    var k = 0
    while k < num_rows:
        var s = local_cell_starts[k]
        if s < 0:
            # Null/missing cell -> zero-length.
            offsets_buf.set_typed[Int32](k + 1, Int32(running_offset))
            k = k + 1
            continue
        var e = local_cell_ends[k]
        var cell_len = e - s
        if cell_len > 0:
            if any_unescape and local_cell_needs_unescape[k]:
                # Slow path: per-cell collapse. Common case is rare
                # (only when scanner flagged the cell). Still writes
                # straight into the data buffer with no String alloc.
                var cell_span = bytes[s:e]
                var w: Int
                if double_quote_escapes:
                    w = _collapse_doubled_quote_into_buf(
                        cell_span, quote, data_buf, running_offset
                    )
                else:
                    w = _collapse_posix_backslash_into_buf(
                        cell_span, posix_escape, data_buf, running_offset
                    )
                running_offset = running_offset + w
            else:
                # Fast path: bulk memcpy from worker byte slice into
                # data buffer. memcpy is auto-vectorized to wide
                # SIMD loads/stores by the LLVM lowering (AVX2 / NEON).
                # SAFETY: bounds-checked above; cell_len > 0; the
                # ByteView is alive across the call (Span `bytes` is
                # held by the caller across this entire fn). The
                # `bytes.unsafe_ptr()` escape is bounded to this block;
                # the pointer is immediately wrapped in a ByteView
                # (typed value) before any external use.
                var base = bytes.unsafe_ptr()
                var view = ByteView((base + s), cell_len)
                data_buf.copy_from_view_at(running_offset, view)
                running_offset = running_offset + cell_len
        offsets_buf.set_typed[Int32](k + 1, Int32(running_offset))
        k = k + 1

    offsets_buf.set_length(Int64((num_rows + 1) * int32_size))

    data_buf.set_length(Int64(running_offset))


    # -----------------------------------------------------------------------
    # Pass 3: build StringArray + (conditional) validity bitmap.
    # -----------------------------------------------------------------------
    var validity_opt = Optional[Bitmap[HeapRegion]](None)
    var nc = 0
    if len(null_positions) > 0:
        var bm = Bitmap.create_all_valid(num_rows)
        var i = 0
        while i < len(null_positions):
            bm.clear(null_positions[i])
            i = i + 1
        nc = len(null_positions)
        validity_opt = Optional[Bitmap[HeapRegion]](bm^)

    return StringArray(
        offsets=offsets_buf^,
        data=data_buf^,
        validity=validity_opt^,
        length=num_rows,
        data_length=running_offset,
        null_count=nc,
    )

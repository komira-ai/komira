# =============================================================================
# int_column_simd — fast-path INT64 / FLOAT64 / DATE32 column builders for
# the parallel CSV reader.
# =============================================================================
#
# On a lineitem-shaped CSV, materialize is the dominant stage, and within
# it the Int64 and Float64 builders dominate. They already parse with SIMD
# via `fast_parse_int64_simple`; the cost is NOT the SIMD parse but the
# surrounding per-cell iteration overhead:
#
#   while r < num_rows:
#       if col_idx >= cells.num_cells_in_row(data_start + r): ...
#       var cs = cells.cell_start(data_start + r, col_idx)      # 2 indexed loads
#       var ce = cells.cell_end(data_start + r, col_idx)        # 2 indexed loads
#       var cell = bytes[cs:ce]                                 # Span construction
#       if is_null_cell(cell, options): ...                     # 5-token cascade
#       if cell_is_simple_numeric(cell):
#           var fast = fast_parse_int64_simple(cell)            # SIMD parse OK
#           if fast: arr.set(r, fast.value()); ...              # validity bitmap write!
#       ...
#
# At 6M rows × 11 INT64 cols = 66M cell iterations per pass. The SIMD
# parse is ~5 ns; the iteration overhead is the rest (~10-13 ns each).
#
# This module replaces the inner loop of `_build_int64_column` /
# `_build_float64_column` / `_build_date32_column` with three structural
# wins (PER-DTYPE; same shape across all three):
#
#   1. **Drop the validity-bitmap write from the hot loop.** The prior
#      shape allocated `PrimitiveArray.allocate_nullable` (all-valid
#      bitmap pre-allocated) and called `arr.set(r, val)` per cell.
#      `set` does (a) bounds check + raise, (b) `set_typed` write,
#      (c) bitmap touch: `is_null(r)` (returns False) + `_set_valid(r)`
#      (clears the bit's byte). That bitmap write is a load-from-memory-
#      modify-store-to-memory per cell that the post-loop "no-nulls"
#      fast path (`arr.validity = None`) discards entirely if no nulls
#      show up. Switching to `allocate` (no validity) + `set_typed[Int64]`
#      drops 1 RMW per cell unconditionally; the bitmap is then ONLY
#      constructed at the end IF `null_positions` is non-empty.
#
#   2. **Hoist the row-base cursor.** `cells.cell_start(r, c)` does
#      `cell_starts[row_starts[r] + c]` — two indexed loads. We hoist
#      `row_base = cells.row_starts[data_start + r]` once per row,
#      advance it via `next_row_base = cells.row_starts[data_start + r + 1]`
#      (cells per row = next - row_base, no second lookup), and read
#      `cell_starts[row_base + col_idx]` / `cell_ends[row_base + col_idx]`
#      directly. Removes one row_starts load per cell.
#
#   3. **Skip is_null_cell when no null tokens are configured AND the
#      cell looks numeric.** `is_null_cell` walks `options._n_null_strings`
#      (default 5: "", "NULL", "NA", "NaN", "null") and does
#      length+byte-equal against each. For typical numeric cells
#      (length 2-10 digits), the length-mismatch short-circuits in
#      1-2 ns per token, but that's still 5-10 ns per cell. We
#      consult `is_null_cell` ONLY for cells that fail the SIMD
#      applicability gate OR are empty — the SIMD applicability gate
#      already rejects any cell with non-digit/sign/decimal bytes, so
#      a passing cell cannot match any default null token (none of
#      them are digit-only). The slow path that handles non-numeric
#      cells still consults `is_null_cell` for parity.
#
# **NO additive parallel API.** The `_build_int64_column` entry point in
# `parallel_reader.mojo` delegates to `build_int64_column_simd` here (the
# inner loop lives in this module). Same for float64 and date32. The
# single-thread `reader._build_int64_column` keeps its own loop.
#
# Safety properties of this module:
#   * No UnsafePointer in public signatures (only Span / ScannedCells /
#     CsvReadOptions / Column).
#   * No wildcard origins in any field (this module has no struct).
#   * No `unsafe_from_address=Int(...)`.
#   * No `UnsafePointer(to=struct.field).take_pointee()` partial-moves.
#   * No additive parallel API — `_build_int64_column` calls into this
#     module; there is no second public column-builder surface.
#   * No byte-erased fn-ptr dispatch.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray

from .cell_parsers import (
    _try_parse_int64,
    _try_parse_float64,
    _try_parse_date32,
)
from .cell_parsers_simd import (
    fast_parse_int64_simple,
    fast_parse_float64_simple,
    cell_is_simple_numeric,
    fast_parse_iso_date32,
)
from .csv_options import CsvReadOptions
from .null_detection import is_null_cell
from .scanned_cells import ScannedCells


# =============================================================================
# Int64 fast-path builder.
# =============================================================================


def build_int64_column_simd(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build an Int64 column from per-worker rows; SIMD-iteration fast path.

    Structural reshape; see the module header for the per-cell cost breakdown and
    the three optimization levers (drop-bitmap-RMW, hoist-row-base,
    skip-null-check-on-numeric-fast-path).

    Args:
        bytes: Per-worker byte slice (source CSV bytes).
        cells: Scanner output (flat-buffer ScannedCells).
        data_start: Index of the first data row (post-header).
        col_idx: Column index to extract.
        num_rows: Number of data rows.
        options: CsvReadOptions (null-token cascade).

    Returns:
        Owned Column wrapping a PrimitiveArray[DType.int64].
    """
    # ---------------------------------------------------------------------
    # Allocate WITHOUT the validity bitmap. The bitmap is built post-loop
    # IFF any null cells were observed. This drops one RMW byte-op per
    # successful set unconditionally; ~80-95% of numeric cells in TPC-H
    # are non-null, so the saving is dominant.
    # ---------------------------------------------------------------------
    var arr = PrimitiveArray[DType.int64].allocate(num_rows)
    var null_positions = List[Int]()

    # Take refs to the flat-buffer ScannedCells columns so we can read
    # without going through ScannedCells.cell_start (which re-derives
    # the row-base index per call). The `ref` binding is compiler-
    # checked alive across the loop because `cells` is a function
    # parameter (caller-owned, alive for the call's duration).
    ref row_starts = cells.row_starts
    ref cell_starts = cells.cell_starts
    ref cell_ends = cells.cell_ends

    # Hoist data_start + 0's row_base; advance it row-by-row using
    # row_starts[r+1] (cells-per-row = next_base - row_base).
    var r = 0
    while r < num_rows:
        var row_idx = data_start + r
        var row_base = row_starts[row_idx]
        var next_base = row_starts[row_idx + 1]
        var ncells_in_row = next_base - row_base
        if col_idx >= ncells_in_row:
            # Missing cell -> null. No data write needed (allocate()
            # zero-initialized the buffer, so the slot is already 0).
            null_positions.append(r)
            r = r + 1
            continue
        var cell_pos = row_base + col_idx
        var cs = cell_starts[cell_pos]
        var ce = cell_ends[cell_pos]
        var cell_len = ce - cs
        # -----------------------------------------------------------------
        # SIMD fast path: applicable iff cell is "simple numeric" shape
        # (digits + optional sign + decimal). cell_is_simple_numeric
        # rejects any non-numeric byte, so a passing cell CANNOT match
        # any of the default null tokens ("", "NULL", "NA", "NaN",
        # "null") since none of those are digit-only. We therefore
        # SKIP the is_null_cell check entirely on the fast path.
        # -----------------------------------------------------------------
        if cell_len > 0:
            var cell = bytes[cs:ce]
            if cell_is_simple_numeric(cell):
                var fast = fast_parse_int64_simple(cell)
                if fast:
                    arr.data.set_typed[Int64](r, fast.value())
                    r = r + 1
                    continue
        # -----------------------------------------------------------------
        # Slow path: cell is empty OR non-numeric. is_null_cell is needed
        # here to distinguish typed-null (e.g. "NULL" string) from a
        # legitimate parse-failure null.
        # -----------------------------------------------------------------
        var cell_slow = bytes[cs:ce]
        if is_null_cell(cell_slow, options):
            null_positions.append(r)
            r = r + 1
            continue
        var parsed = _try_parse_int64(cell_slow)
        if parsed:
            arr.data.set_typed[Int64](r, parsed.value())
        else:
            null_positions.append(r)
        r = r + 1

    # ---------------------------------------------------------------------
    # Build the validity bitmap ONLY IF nulls were observed. The all-valid
    # case (which dominates TPC-H numeric columns) ships with `validity =
    # None` and zero bitmap traffic.
    # ---------------------------------------------------------------------
    if len(null_positions) > 0:
        var bm = Bitmap.create_all_valid(num_rows)
        var k = 0
        while k < len(null_positions):
            bm.clear(null_positions[k])
            k = k + 1
        arr.validity = Optional[Bitmap[HeapRegion]](bm^)
        arr.null_count = len(null_positions)
    return Column.from_primitive[DType.int64](arr)


# =============================================================================
# Float64 fast-path builder.
# =============================================================================


def build_float64_column_simd(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a Float64 column from per-worker rows; SIMD-iteration fast path.

    Mirror of `build_int64_column_simd` with `fast_parse_float64_simple`
    for integer-shaped floats; scalar fallback `_try_parse_float64` for
    decimal/exponent/sign-only forms.
    """
    var arr = PrimitiveArray[DType.float64].allocate(num_rows)
    var null_positions = List[Int]()

    ref row_starts = cells.row_starts
    ref cell_starts = cells.cell_starts
    ref cell_ends = cells.cell_ends

    var r = 0
    while r < num_rows:
        var row_idx = data_start + r
        var row_base = row_starts[row_idx]
        var next_base = row_starts[row_idx + 1]
        var ncells_in_row = next_base - row_base
        if col_idx >= ncells_in_row:
            null_positions.append(r)
            r = r + 1
            continue
        var cell_pos = row_base + col_idx
        var cs = cell_starts[cell_pos]
        var ce = cell_ends[cell_pos]
        var cell_len = ce - cs
        if cell_len > 0:
            var cell = bytes[cs:ce]
            if cell_is_simple_numeric(cell):
                var fast = fast_parse_float64_simple(cell)
                if fast:
                    arr.data.set_typed[Float64](r, fast.value())
                    r = r + 1
                    continue
        # Slow path: empty / decimal / exponent / non-numeric.
        var cell_slow = bytes[cs:ce]
        if is_null_cell(cell_slow, options):
            null_positions.append(r)
            r = r + 1
            continue
        var parsed = _try_parse_float64(cell_slow, options.decimal_separator)
        if parsed:
            arr.data.set_typed[Float64](r, parsed.value())
        else:
            null_positions.append(r)
        r = r + 1

    if len(null_positions) > 0:
        var bm = Bitmap.create_all_valid(num_rows)
        var k = 0
        while k < len(null_positions):
            bm.clear(null_positions[k])
            k = k + 1
        arr.validity = Optional[Bitmap[HeapRegion]](bm^)
        arr.null_count = len(null_positions)
    return Column.from_primitive[DType.float64](arr)


# =============================================================================
# Date32 fast-path builder.
# =============================================================================


def build_date32_column_simd(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a Date32 column from per-worker rows; SIMD-iteration fast path.

    Mirror of `build_int64_column_simd` with `fast_parse_iso_date32` for
    the canonical 10-byte ISO `YYYY-MM-DD` form; scalar `_try_parse_date32`
    for non-canonical forms.

    Note: a lineitem fixture that stores dates as INT64 epoch-days (NOT
    ISO strings) never invokes this fn. It IS invoked on ISO-date-string fixtures
    (the CSV test suite covers this path). The structural reshape applies
    identically.
    """
    var arr = PrimitiveArray[DType.int32].allocate(num_rows)
    var null_positions = List[Int]()

    ref row_starts = cells.row_starts
    ref cell_starts = cells.cell_starts
    ref cell_ends = cells.cell_ends

    var r = 0
    while r < num_rows:
        var row_idx = data_start + r
        var row_base = row_starts[row_idx]
        var next_base = row_starts[row_idx + 1]
        var ncells_in_row = next_base - row_base
        if col_idx >= ncells_in_row:
            null_positions.append(r)
            r = r + 1
            continue
        var cell_pos = row_base + col_idx
        var cs = cell_starts[cell_pos]
        var ce = cell_ends[cell_pos]
        var cell_len = ce - cs
        if cell_len > 0:
            var cell = bytes[cs:ce]
            # SIMD fast path: canonical 10-byte ISO date.
            var fast = fast_parse_iso_date32(cell)
            if fast:
                arr.data.set_typed[Int32](r, fast.value())
                r = r + 1
                continue
        # Slow path.
        var cell_slow = bytes[cs:ce]
        if is_null_cell(cell_slow, options):
            null_positions.append(r)
            r = r + 1
            continue
        var parsed = _try_parse_date32(cell_slow)
        if parsed:
            arr.data.set_typed[Int32](r, parsed.value())  # cov: unreachable the SIMD date fast path accepts every cell _try_parse_date32 accepts
        else:
            null_positions.append(r)
        r = r + 1

    if len(null_positions) > 0:
        var bm = Bitmap.create_all_valid(num_rows)
        var k = 0
        while k < len(null_positions):
            bm.clear(null_positions[k])
            k = k + 1
        arr.validity = Optional[Bitmap[HeapRegion]](bm^)
        arr.null_count = len(null_positions)
    return Column.from_primitive_with_arrow_type[DType.int32](
        arr, ArrowType.DATE32
    )

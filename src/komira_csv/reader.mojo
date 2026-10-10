# =============================================================================
# reader — high-level CSV reader: orchestrates scan + infer + materialize.
# =============================================================================
#
#
# Entry points (public):
#   read_csv_to_batch(path, options)  -> RecordBatch
#       Read a CSV file from disk; auto-infer per-column ArrowTypes;
#       return a single materialized RecordBatch covering the whole file.
#
#   read_csv_bytes_to_batch(bytes, options) -> RecordBatch
#       Same, but takes a pre-slurped byte buffer (the engine
#       _compile_csv_scan arm uses this for the slurp+materialize path).
#
# Both functions:
#   1. Phase 1/2/3 scan into a `ScannedCells` flat-buffer (4 contiguous
#      Lists: cell_starts/cell_ends/cell_flags/row_starts).
#   2. Optional header row -> column names.
#   3. Per-column type inference over the first `options.infer_rows` rows.
#   4. Materialize Arrow columns (Int64 / Float64 / Bool / Date32 / String).
#   5. Wrap in a Schema + RecordBatch.
#
# A `List[Row]` where Row carries `List[CellRange]` costs ~96 M
# List.append events on TPC-H SF1 lineitem (6 M rows x 16 cells). The
# `ScannedCells` shape emits into 4 pre-sized contiguous Lists,
# eliminating the per-row/per-cell allocation cascade (a large share of
# the wall). Mirrors pyarrow's `RawBlockBuffer` / DuckDB's
# `DataChunk` / polars' per-worker partition buffers.
# =============================================================================

from std.io import FileHandle

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)

from .csv_options import (
    CsvReadOptions,
    check_declared_column_types,
    QUOTE_STYLE_TAG_RFC4180,
    QUOTE_STYLE_TAG_EXCEL,
    QUOTE_STYLE_TAG_POSIX,
)
from .csv_scanner_phase1 import (
    scan_csv_phase1_into_cells,
    scan_csv_phase2_movemask_into_cells,
    scan_csv_phase3_pclmulqdq_into_cells,
)
from .scanned_cells import ScannedCells, CELL_FLAG_NEEDS_UNESCAPE
from .cell_parsers import (
    _try_parse_int64,
    _try_parse_float64,
    _try_parse_date32,
    _try_parse_bool,
    cell_to_string,
)
# SIMD fast paths for the serial builders (the same ones the parallel
# reader's per-worker builders use); several times faster than scalar-only
# `_try_parse_*` on the per-cell parse pass.
from .cell_parsers_simd import (
    fast_parse_int64_simple,
    fast_parse_float64_simple,
    cell_is_simple_numeric,
    fast_parse_iso_date32,
)
from .input_limits import check_csv_cell_budget, check_csv_column_count
from .record_shape import check_csv_record_shape, skip_leading_blank_lines
from .null_detection import is_null_cell
from .quote_styles import QuoteStyle, Rfc4180, Excel, Posix
from .typed_column_builders import dispatch_typed_builder
from .string_column_simd import build_string_column_simd


# =============================================================================
# Scanner-variant comptime switch.
# =============================================================================
#
# 1 = Phase 1 chassis (FSA + 8-byte ContainsZeroByte UInt64-arithmetic
#     fast skip).
# 2 = Phase 2 movemask (FSA + 32-byte SIMD batch via byte_class).
# 3 = Phase 3 simdcsv-tier (FSA + 64-byte SIMD batch + PCLMULQDQ /
#     PMULL64 quote-region mask).
#
# DEFAULT_SCANNER_VARIANT = 2 (Phase 2).
# =============================================================================

comptime SCANNER_VARIANT_PHASE_1: Int = 1
comptime SCANNER_VARIANT_PHASE_2: Int = 2
comptime SCANNER_VARIANT_PHASE_3: Int = 3
comptime SCANNER_VARIANT_PHASE_4: Int = 4
comptime DEFAULT_SCANNER_VARIANT: Int = 2


@always_inline
def _dispatch_scan[
    Q: QuoteStyle,
    SCANNER_VARIANT: Int,
](
    bytes: Span[UInt8, _],
    delimiter: UInt8,
    quote: UInt8,
) raises -> ScannedCells:
    """Comptime-cascade dispatch between Phase 1 / Phase 2 / Phase 3 scanners.

    All three variants emit into the same `ScannedCells` flat-buffer
    output shape.
    """
    comptime if SCANNER_VARIANT == SCANNER_VARIANT_PHASE_3:
        return scan_csv_phase3_pclmulqdq_into_cells[Q](bytes, delimiter, quote)
    elif SCANNER_VARIANT == SCANNER_VARIANT_PHASE_2:
        return scan_csv_phase2_movemask_into_cells[Q](bytes, delimiter, quote)
    else:
        return scan_csv_phase1_into_cells[Q](bytes, delimiter, quote)


# =============================================================================
# Public entry points.
# =============================================================================


def read_csv_to_batch(path: String) raises -> RecordBatch:
    """Read a CSV file at `path` with default options (Rfc4180, header=True)."""
    var opts = CsvReadOptions()
    return read_csv_to_batch_with_options[Rfc4180](path, opts)


def read_csv_to_batch_with_options[
    Q: QuoteStyle,
    SCANNER_VARIANT: Int = DEFAULT_SCANNER_VARIANT,
](path: String, options: CsvReadOptions) raises -> RecordBatch:
    """Read a CSV file at `path` with explicit Q + options."""
    var f = FileHandle(path, "r")
    var content = f.read()
    f.close()
    var content_bytes = content.as_bytes()
    return read_csv_bytes_to_batch[Q, SCANNER_VARIANT](content_bytes, options)


def read_csv_bytes_to_batch[
    Q: QuoteStyle,
    SCANNER_VARIANT: Int = DEFAULT_SCANNER_VARIANT,
](bytes: Span[UInt8, _], options: CsvReadOptions) raises -> RecordBatch:
    """Read CSV bytes (already in memory) into a RecordBatch.

    adds UTF-8 BOM stripping. If
    `options.strip_utf8_bom == True` AND the first 3 bytes match `0xEF
    0xBB 0xBF`, the scan starts at offset 3.

    scanner emits
    into a `ScannedCells` flat-buffer struct (4 contiguous Lists)
    instead of `List[Row]`. ~5-8x speedup on the TPC-H lineitem fixture
    (was ~19.9 s ST; target ~2.5-4 s ST).

    Raises (among others) on a malformed record, under every dialect: a
    field count other than the header's, or a byte after a closing quote
    that is not the delimiter or a line end. The error names the record
    number, line, byte offset and field (`record_shape`).
    """
    if len(bytes) == 0:
        var sb_empty = SchemaBuilder()
        var schema_empty = sb_empty.build()
        var rbb_empty = RecordBatchBuilder()
        return rbb_empty.build(schema_empty^)

    var scan_start: Int = 0
    if (
        options.strip_utf8_bom
        and len(bytes) >= 3
        and bytes[0] == UInt8(0xEF)
        and bytes[1] == UInt8(0xBB)
        and bytes[2] == UInt8(0xBF)
    ):
        scan_start = 3

    # Step 1: scan all rows via the comptime-selected scanner variant.
    var scan_bytes = bytes[scan_start:]
    var cells = _dispatch_scan[Q, SCANNER_VARIANT](
        scan_bytes,
        options.delimiter,
        options.quote,
    )
    # ROW-BYTE CEILING (holds with assertions compiled out) -- this is where
    # `CsvReadOptions.max_row_bytes` becomes real. See
    # `ScannedCells.enforce_max_row_bytes` for why the check lives here and
    # not in the scanner's per-byte loop.
    cells.enforce_max_row_bytes(options.max_row_bytes)
    # Blank lines before the header / first record (`record_shape`).
    skip_leading_blank_lines(cells)

    var total_rows = cells.num_rows()
    if total_rows == 0:
        var sb0 = SchemaBuilder()
        var schema0 = sb0.build()
        var rbb0 = RecordBatchBuilder()
        return rbb0.build(schema0^)

    # Step 2: pull header row if configured.
    var header_names = List[String]()
    var data_start: Int
    if options.has_header:
        var ncols_header = cells.num_cells_in_row(0)
        var i = 0
        while i < ncols_header:
            var cr = cells.cell(0, i)
            var s = cell_to_string(
                scan_bytes[cr.start:cr.end],
                cr.needs_unescape,
                Q.DOUBLE_QUOTE_ESCAPES,
                options.quote,
                Q.ESCAPE_BYTE,
            )
            header_names.append(s^)
            i = i + 1
        data_start = 1
    else:
        var ncols_first = cells.num_cells_in_row(0)
        var i = 0
        while i < ncols_first:
            header_names.append(String("col_") + String(i))
            i = i + 1
        data_start = 0

    var num_cols = len(header_names)
    # HOSTILE-INPUT CEILING (holds with assertions compiled out). `num_cols` is
    # the header row's cell count -- entirely input-controlled -- and every
    # column builder below allocates the FULL row count up front.
    # Allocation is rows x cols. ONE compare, here, before
    # the first builder allocates. (Second site: the schema-sample path,
    # which feeds the same widths into infer_column_types.)
    check_csv_column_count(num_cols)
    # RECORD SHAPE: refuse a record with a field count other than the
    # header's, or a byte after a closing quote that is not the delimiter or
    # a line end, before any builder reads a cell (komira-ai/komira#449).
    check_csv_record_shape[Q](
        scan_bytes, 0, scan_start, cells, data_start, header_names,
        options.has_header, options.delimiter, options.quote,
    )
    var num_rows = cells.num_rows() - data_start  # after blank-line removal
    if num_rows == 0 or num_cols == 0:
        var sb1 = SchemaBuilder()
        var schema1 = sb1.build()
        var rbb1 = RecordBatchBuilder()
        return rbb1.build(schema1^)
    # CELL BUDGET (holds with assertions compiled out). The column cap above bounds
    # ONE multiplicand; the allocation is rows x cols and `num_rows` had no
    # ceiling at all. See `input_limits.check_csv_cell_budget`. ONE compare,
    # here, before the `_build_column` loop makes the first `allocate(num_rows)`.
    check_csv_cell_budget(num_rows, num_cols, len(scan_bytes))

    # Step 3: per-column type inference.
    # `options.infer_temporal_types` opts into the wider lattice.
    from .type_inference import infer_column_types, infer_column_types_wide
    var col_types: List[ArrowType]
    if len(options.declared_column_types) > 0:
        # DECLARED-SCHEMA DECODE. The caller has ALREADY
        # bound this file at a schema, so inferring a second one here would
        # let the bind and the execution disagree in silence. Parse AT the
        # declared dtypes instead — this is a decode that HONOURS the contract,
        # not a cast that patches it up afterwards (a cast has already lost
        # `0001`).
        check_declared_column_types(
            options.declared_column_types,
            num_cols,
            String("read_csv_bytes_to_batch"),
        )
        col_types = options.declared_column_types.copy()
    elif options.infer_temporal_types:
        col_types = infer_column_types_wide(
            scan_bytes, cells, data_start, num_rows, num_cols, options
        )
    else:
        col_types = infer_column_types(
            scan_bytes, cells, data_start, num_rows, num_cols, options
        )

    # Step 4: materialize each column.
    var rbb = RecordBatchBuilder()
    var sb = SchemaBuilder()

    var c = 0
    while c < num_cols:
        # Projection fast-skip
        if not options.is_projected(header_names[c]):
            c = c + 1
            continue
        var dtype = col_types[c]
        var field = Field(header_names[c], dtype, True)
        sb.add_field(field)
        var col = _build_column[Q](scan_bytes, cells, data_start, c, dtype, num_rows, options)
        rbb.add_column(col^)
        c = c + 1

    var schema = sb.build()
    return rbb.build(schema^)


# =============================================================================
# read_csv_bytes_to_batch_dynamic — runtime QuoteStyle dispatcher.
# =============================================================================


def read_csv_bytes_to_batch_dynamic(
    bytes: Span[UInt8, _],
    options: CsvReadOptions,
) raises -> RecordBatch:
    """Runtime-dispatch wrapper over `read_csv_bytes_to_batch[Q]`."""
    var tag = options.quote_style_tag
    if tag == QUOTE_STYLE_TAG_RFC4180:
        return read_csv_bytes_to_batch[Rfc4180](bytes, options)
    if tag == QUOTE_STYLE_TAG_EXCEL:
        return read_csv_bytes_to_batch[Excel](bytes, options)
    if tag == QUOTE_STYLE_TAG_POSIX:
        return read_csv_bytes_to_batch[Posix](bytes, options)
    raise Error(
        "read_csv_bytes_to_batch_dynamic: unknown options.quote_style_tag "
        + String(tag)
        + " — expected 0 (Rfc4180), 1 (Excel), or 2 (Posix). Use "
        + "CsvReadOptions.with_quote_style(...) to set it."
    )


# =============================================================================
# read_csv_bytes_to_schema — header + bounded-sample SCHEMA inference (no
# column materialization).
# =============================================================================
#
# Produces the SAME `Schema` shape (column names + per-column inferred
# ArrowTypes) that `read_csv_bytes_to_batch` would produce, but WITHOUT
# scanning the whole file or materializing any column data. It scans only a
# bounded byte PREFIX of `bytes` (snapped to the last complete row terminator
# inside the prefix so a truncated final row never reaches inference) and runs
# the SAME `infer_column_types` inference rules over the rows in that prefix.
#
# Inference equivalence: `infer_column_types` already caps its per-column scan
# at `options.infer_rows` rows (default 100). The full-file decode and this
# schema-only path therefore apply the IDENTICAL inference rule set over the
# IDENTICAL leading rows — for any column whose type is stable across the file
# the inferred ArrowType is byte-identical. The only divergence surface is a
# column that "widens" (e.g. INT64 for the first N rows then FLOAT64 / STRING
# deeper in the file): with a bounded sample we infer the NARROWER type the
# full decoder would ALSO infer when its own `infer_rows` cap is in effect.
# For the row fast-path this is sound — the path is fixed-width-numeric ONLY
# and HARD-RAISES downstream on STRING / non-fixed columns (in
# `_arrow_to_row_dtype_tag` at segment-build time and again in the row
# reader), so a mis-inference fails LOUDLY, never silently
# wrong.
#
# The prefix byte-budget is chosen to comfortably cover `infer_rows` rows of a
# wide row (a 21-column lineitem row is ~120 bytes, so 256 KiB covers ~2000
# rows). If the file is smaller than the budget the whole file is scanned
# (correct: there is no "rest of file" to diverge from).
# =============================================================================

# Bytes of file PREFIX to scan for schema inference. Covers >= infer_rows rows
# of a wide CSV row with comfortable headroom (a 21-col lineitem row ~120 B ->
# ~2000 rows at 256 KiB), while bounding the scan to O(prefix) not O(file).
comptime _SCHEMA_SAMPLE_PREFIX_BYTES: Int = 256 * 1024  # 256 KiB


def read_csv_bytes_to_schema[
    Q: QuoteStyle,
    SCANNER_VARIANT: Int = DEFAULT_SCANNER_VARIANT,
](bytes: Span[UInt8, _], options: CsvReadOptions) raises -> Schema:
    """Infer the CSV Schema (names + per-column ArrowType) from a header +
    bounded-sample scan, materializing NO column data. See module section
    header above for the inference-equivalence contract."""
    var sb_out = SchemaBuilder()
    if len(bytes) == 0:
        return sb_out.build()

    var scan_start: Int = 0
    if (
        options.strip_utf8_bom
        and len(bytes) >= 3
        and bytes[0] == UInt8(0xEF)
        and bytes[1] == UInt8(0xBB)
        and bytes[2] == UInt8(0xBF)
    ):
        scan_start = 3

    # Bound the scan to a leading PREFIX. Snap the prefix end to the last row
    # terminator (0x0A) at or before the budget so the scanner never sees a
    # truncated final row that could mis-infer a column type. If the file is
    # smaller than the budget, scan the whole thing (no row to snap off).
    var n = len(bytes)
    var prefix_end = n
    if n - scan_start > _SCHEMA_SAMPLE_PREFIX_BYTES:
        var budget_end = scan_start + _SCHEMA_SAMPLE_PREFIX_BYTES
        # Walk back to the last newline at-or-before budget_end so the prefix
        # ends on a complete row boundary.
        var snap = budget_end
        while snap > scan_start and bytes[snap - 1] != UInt8(0x0A):
            snap = snap - 1
        # If no newline was found in the budget (a single colossal row),
        # fall back to the full budget — inference over one partial row still
        # produces a valid (if conservative) type.
        if snap > scan_start:
            prefix_end = snap
        else:
            prefix_end = budget_end

    var scan_bytes = bytes[scan_start:prefix_end]
    var cells = _dispatch_scan[Q, SCANNER_VARIANT](
        scan_bytes,
        options.delimiter,
        options.quote,
    )
    # ROW-BYTE CEILING (holds with assertions compiled out) — THE TWIN OF
    # `read_csv_bytes_to_batch:194` THAT THE FIRST PASS MISSED.
    #
    # `enforce_max_row_bytes` was added to the full-decode entry and to both
    # parallel-worker arms, and NOT to this one — the same "fixed on the path
    # someone noticed, twin path kept it" shape the round-1 review was refuted
    # on. This entry is reachable on its own: `read_csv_bytes_to_schema` is the
    # public schema-only path the row fast-path and the lazy source use, and it
    # runs the SAME scanner over the SAME hostile bytes. One unbalanced '"'
    # makes the FSA swallow the whole 256 KiB prefix as ONE cell, and every
    # `cell_to_string` below then copies it. ONE pass over the scanned row
    # starts, before the header names are built.
    cells.enforce_max_row_bytes(options.max_row_bytes)
    # Blank lines before the header / first record (`record_shape`).
    skip_leading_blank_lines(cells)
    var total_rows = cells.num_rows()
    if total_rows == 0:
        return sb_out.build()

    # Header row -> column names (mirrors read_csv_bytes_to_batch step 2).
    var header_names = List[String]()
    var data_start: Int
    if options.has_header:
        var ncols_header = cells.num_cells_in_row(0)
        var i = 0
        while i < ncols_header:
            var cr = cells.cell(0, i)
            var s = cell_to_string(
                scan_bytes[cr.start:cr.end],
                cr.needs_unescape,
                Q.DOUBLE_QUOTE_ESCAPES,
                options.quote,
                Q.ESCAPE_BYTE,
            )
            header_names.append(s^)
            i = i + 1
        data_start = 1
    else:
        var ncols_first = cells.num_cells_in_row(0)
        var i = 0
        while i < ncols_first:
            header_names.append(String("col_") + String(i))
            i = i + 1
        data_start = 0

    var num_cols = len(header_names)
    # HOSTILE-INPUT CEILING (holds with assertions compiled out). `num_cols` is
    # the header row's cell count -- entirely input-controlled -- and every
    # column builder below allocates the FULL row count up front.
    # Allocation is rows x cols. ONE compare, here, before
    # the first builder allocates. (Second site: the schema-sample path,
    # which feeds the same widths into infer_column_types.)
    check_csv_column_count(num_cols)
    # RECORD SHAPE, as in `read_csv_bytes_to_batch`. When the prefix was cut
    # at the byte budget the last scanned row may be incomplete, so its field
    # count is not checked; the full decode checks it.
    check_csv_record_shape[Q](
        scan_bytes, 0, scan_start, cells, data_start, header_names,
        options.has_header, options.delimiter, options.quote,
        check_last_row=(prefix_end == n),
    )
    var num_rows = cells.num_rows() - data_start  # after blank-line removal
    if num_rows == 0 or num_cols == 0:
        return sb_out.build()

    # Per-column type inference over the bounded sample. SAME rules + SAME
    # `options.infer_rows` cap as the full decode.
    from .type_inference import infer_column_types, infer_column_types_wide
    var col_types: List[ArrowType]
    if len(options.declared_column_types) > 0:
        # DECLARED-SCHEMA DECODE. The caller has ALREADY
        # bound this file at a schema, so inferring a second one here would
        # let the bind and the execution disagree in silence. Parse AT the
        # declared dtypes instead — this is a decode that HONOURS the contract,
        # not a cast that patches it up afterwards (a cast has already lost
        # `0001`).
        check_declared_column_types(
            options.declared_column_types,
            num_cols,
            String("read_csv_bytes_to_schema"),
        )
        col_types = options.declared_column_types.copy()
    elif options.infer_temporal_types:
        col_types = infer_column_types_wide(
            scan_bytes, cells, data_start, num_rows, num_cols, options
        )
    else:
        col_types = infer_column_types(
            scan_bytes, cells, data_start, num_rows, num_cols, options
        )

    # Build the Schema — names + inferred dtypes, NO column data. Mirrors the
    # full decode's step-4 field construction (read_csv_bytes_to_batch:255),
    # honoring projection fast-skip so the schema matches a projected decode.
    var c = 0
    while c < num_cols:
        if not options.is_projected(header_names[c]):
            c = c + 1
            continue
        var field = Field(header_names[c], col_types[c], True)
        sb_out.add_field(field)
        c = c + 1
    return sb_out.build()


def read_csv_bytes_to_schema_dynamic(
    bytes: Span[UInt8, _],
    options: CsvReadOptions,
) raises -> Schema:
    """Runtime-dispatch wrapper over `read_csv_bytes_to_schema[Q]`.
    """
    var tag = options.quote_style_tag
    if tag == QUOTE_STYLE_TAG_RFC4180:
        return read_csv_bytes_to_schema[Rfc4180](bytes, options)
    if tag == QUOTE_STYLE_TAG_EXCEL:
        return read_csv_bytes_to_schema[Excel](bytes, options)
    if tag == QUOTE_STYLE_TAG_POSIX:
        return read_csv_bytes_to_schema[Posix](bytes, options)
    raise Error(
        "read_csv_bytes_to_schema_dynamic: unknown options.quote_style_tag "
        + String(tag)
        + " — expected 0 (Rfc4180), 1 (Excel), or 2 (Posix)."
    )


# =============================================================================
# Private helpers — column materialization.
# =============================================================================


def _build_column[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    dtype: ArrowType,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Per-DType column materializer."""
    if dtype == ArrowType.INT64:
        return _build_int64_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.FLOAT64:
        return _build_float64_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.DATE32:
        return _build_date32_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.BOOL:
        return _build_bool_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.STRING:
        return _build_string_column[Q](bytes, cells, data_start, col_idx, num_rows, options)
    return dispatch_typed_builder(
        bytes, cells, data_start, col_idx, dtype, num_rows, options
    )


def _build_int64_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build an Int64 column.

    deferred-null + all-valid-bitmap-drop
    pattern (bitmap batch-OR). Per-cell `validity.value().clear(r)`
    is replaced with a `null_positions: List[Int]` accumulator; on
    null-free files (TPC-H lineitem) the validity bitmap is dropped
    entirely via the `validity = None` fast path.

    Note: the parallel_reader's SIMD-fast-path
    (`cell_is_simple_numeric` + `fast_parse_int64_simple`) regresses
    the serial path by a few percent on lineitem-shaped data because the per-cell
    gate walk dominates for short (3-5 digit) cells. The defer-null
    pattern is the load-bearing win here; SIMD is left for parallel
    only (where per-worker cache effects partially absorb the overhead).
    """
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_positions = List[Int]()
    var r = 0
    while r < num_rows:
        var row_idx = data_start + r
        if col_idx >= cells.num_cells_in_row(row_idx):
            null_positions.append(r)
            r = r + 1
            continue
        var cs = cells.cell_start(row_idx, col_idx)
        var ce = cells.cell_end(row_idx, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            null_positions.append(r)
            r = r + 1
            continue
        var parsed = _try_parse_int64(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            null_positions.append(r)
        r = r + 1
    if len(null_positions) == 0:
        arr.validity = None
        arr.null_count = 0
    else:
        var k = 0
        while k < len(null_positions):
            arr.validity.value().clear(null_positions[k])
            k = k + 1
        arr.null_count = len(null_positions)
    return Column.from_primitive[DType.int64](arr)


def _build_float64_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a Float64 column.

    deferred-null + all-valid-bitmap-drop
    pattern. SIMD float fast-path skipped because
    `fast_parse_float64_simple` only handles integer-shaped floats —
    on decimal-shaped lineitem cells (`17.0`, `0.04`) the gate accepts
    but the parser rejects, costing a double walk.
    """
    var arr = PrimitiveArray[DType.float64].allocate_nullable(num_rows)
    var null_positions = List[Int]()
    var r = 0
    while r < num_rows:
        var row_idx = data_start + r
        if col_idx >= cells.num_cells_in_row(row_idx):
            null_positions.append(r)
            r = r + 1
            continue
        var cs = cells.cell_start(row_idx, col_idx)
        var ce = cells.cell_end(row_idx, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            null_positions.append(r)
            r = r + 1
            continue
        var parsed = _try_parse_float64(cell, options.decimal_separator)
        if parsed:
            arr.set(r, parsed.value())
        else:
            null_positions.append(r)
        r = r + 1
    if len(null_positions) == 0:
        arr.validity = None
        arr.null_count = 0
    else:
        var k = 0
        while k < len(null_positions):
            arr.validity.value().clear(null_positions[k])
            k = k + 1
        arr.null_count = len(null_positions)
    return Column.from_primitive[DType.float64](arr)


def _build_date32_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a Date32 column.

    SIMD fast path (canonical 10-byte
    ISO `YYYY-MM-DD` cells) + deferred-null pattern. The Date32 SIMD
    parser has an applicability gate that DOES win on lineitem because
    the canonical-form shape is fixed (single SIMD compare vs the
    digit/separator mask).
    """
    var arr = PrimitiveArray[DType.int32].allocate_nullable(num_rows)
    var null_positions = List[Int]()
    var r = 0
    while r < num_rows:
        var row_idx = data_start + r
        if col_idx >= cells.num_cells_in_row(row_idx):
            null_positions.append(r)
            r = r + 1
            continue
        var cs = cells.cell_start(row_idx, col_idx)
        var ce = cells.cell_end(row_idx, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            null_positions.append(r)
            r = r + 1
            continue
        # SIMD fast path: canonical 10-byte ISO date `YYYY-MM-DD`.
        var fast = fast_parse_iso_date32(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_date32(cell)
        if parsed:
            arr.set(r, parsed.value())  # cov: unreachable the SIMD date fast path accepts every cell _try_parse_date32 accepts
        else:
            null_positions.append(r)
        r = r + 1
    if len(null_positions) == 0:
        arr.validity = None
        arr.null_count = 0
    else:
        var k = 0
        while k < len(null_positions):
            arr.validity.value().clear(null_positions[k])
            k = k + 1
        arr.null_count = len(null_positions)
    return Column.from_primitive_with_arrow_type[DType.int32](arr, ArrowType.DATE32)


def _build_bool_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a Bool column.

    deferred-null pattern (no SIMD fast
    path applicable — bool parser is already cheap string-table lookup).
    """
    var arr = BooleanArray.allocate_nullable(num_rows)
    var null_positions = List[Int]()
    var r = 0
    while r < num_rows:
        var row_idx = data_start + r
        if col_idx >= cells.num_cells_in_row(row_idx):
            null_positions.append(r)
            r = r + 1
            continue
        var cs = cells.cell_start(row_idx, col_idx)
        var ce = cells.cell_end(row_idx, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            null_positions.append(r)
            r = r + 1
            continue
        var parsed = _try_parse_bool(cell, options)
        if parsed:
            arr.set(r, parsed.value())
        else:
            null_positions.append(r)
        r = r + 1
    var k = 0
    while k < len(null_positions):
        arr._set_null(null_positions[k])
        k = k + 1
    arr.null_count = len(null_positions)
    return Column.from_boolean(arr)


def _build_string_column[
    Q: QuoteStyle,
](
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Build a STRING column. Applies the per-cell unescape when the
    scanner flagged `needs_unescape`.

    delegates
    to `string_column_simd.build_string_column_simd` for the bulk-memcpy
    fast path.
    """
    var arr = build_string_column_simd(
        bytes,
        cells,
        data_start,
        col_idx,
        num_rows,
        options,
        options.quote,
        Q.DOUBLE_QUOTE_ESCAPES,
        Q.ESCAPE_BYTE,
    )
    return Column.from_string(arr)

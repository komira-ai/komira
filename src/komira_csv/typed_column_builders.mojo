# =============================================================================
# typed_column_builders — per-DType Arrow column materializers (widened set)
# =============================================================================
#
# The widened set: 22 cell parsers
# (UInt8/16/32/64, Int8/16/32, Float32, Date64, Timestamp_{S,MS,US,NS},
# Time_{S,MS,US,NS}, Duration_{S,MS,US,NS}, Decimal128) + the opt-in
# `infer_column_types_wide` lattice. This module wires those parsers
# into Arrow ColumnBuilders so the parsed values flow into
# RecordBatch output.
#
# Each `_build_<dtype>_column` mirrors the base-type shape:
#   1. allocate a nullable PrimitiveArray (or Decimal128Array) of length N
#   2. iterate rows; on missing cell / null cell / parse failure: clear
#      the validity bit at row r and bump null_count
#   3. on parse success: write parsed value to arr.set(r, value)
#   4. wrap in a Column with the correct ArrowType discriminator (via
#      `Column.from_primitive_with_arrow_type` for the temporal types
#      whose storage DType is shared with another ArrowType).
#
# Storage-DType mapping (matches Arrow IPC):
#   Int8/16/32, Float32, Date32, Time32_*    -> 32-bit storage
#   UInt8/16/32/64, Int64, Float64, Date64,
#     Timestamp_*, Time64_*, Duration_*       -> 64-bit storage
#   Decimal128                                -> 16-byte Decimal128Array
#
# Public surface: 22 `_build_<dtype>_column` functions + 1 router
# `dispatch_typed_builder` consumed by `reader.mojo:_build_column`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion

from .csv_options import CsvReadOptions
from .scanned_cells import ScannedCells
from .cell_parsers import (
    _try_parse_uint8,
    _try_parse_uint16,
    _try_parse_uint32,
    _try_parse_uint64,
    _try_parse_int8,
    _try_parse_int16,
    _try_parse_int32,
    _try_parse_float32,
    _try_parse_decimal128_to_int64,
)
from .temporal_parsers import (
    _try_parse_date64,
    _try_parse_timestamp_s,
    _try_parse_timestamp_ms,
    _try_parse_timestamp_us,
    _try_parse_timestamp_ns,
    _try_parse_time_s,
    _try_parse_time_ms,
    _try_parse_time_us,
    _try_parse_time_ns,
    _try_parse_duration_s,
    _try_parse_duration_ms,
    _try_parse_duration_us,
    _try_parse_duration_ns,
)
# ISO-8601
# SIMD fast paths for Date64 / Timestamp_* / Time_*. Each ships with a
# branch-free byte-position applicability gate; non-canonical cells fall
# back to the scalar parsers above.
from .cell_parsers_simd import (
    fast_parse_iso_date64_date_only,
    fast_parse_iso_timestamp_s,
    fast_parse_iso_timestamp_ms,
    fast_parse_iso_timestamp_us,
    fast_parse_iso_timestamp_ns,
    fast_parse_iso_time_s,
    fast_parse_iso_time_ms,
    fast_parse_iso_time_us,
    fast_parse_iso_time_ns,
)
from .null_detection import is_null_cell


# =============================================================================
# Unsigned integers: UInt8 / UInt16 / UInt32 / UInt64
# =============================================================================


def _build_uint8_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.uint8].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_uint8(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive[DType.uint8](arr)


def _build_uint16_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.uint16].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_uint16(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive[DType.uint16](arr)


def _build_uint32_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.uint32].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_uint32(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive[DType.uint32](arr)


def _build_uint64_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.uint64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_uint64(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive[DType.uint64](arr)


# =============================================================================
# Narrowed signed integers: Int8 / Int16 / Int32
# =============================================================================


def _build_int8_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int8].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_int8(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive[DType.int8](arr)


def _build_int16_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int16].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_int16(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive[DType.int16](arr)


def _build_int32_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_int32(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive[DType.int32](arr)


# =============================================================================
# Narrowed float: Float32
# =============================================================================


def _build_float32_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.float32].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_float32(cell, options.decimal_separator)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive[DType.float32](arr)


# =============================================================================
# Date64 — Int64 storage; ms since epoch
# =============================================================================


def _build_date64_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        # SIMD fast path: 10-byte canonical date-only form.
        var fast = fast_parse_iso_date64_date_only(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_date64(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.DATE64
    )


# =============================================================================
# Timestamp_S / MS / US / NS — Int64 storage
# =============================================================================


def _build_timestamp_s_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        # SIMD fast path: canonical ISO timestamp form.
        var fast = fast_parse_iso_timestamp_s(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_timestamp_s(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.TIMESTAMP_S
    )


def _build_timestamp_ms_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        # SIMD fast path: canonical ISO timestamp form.
        var fast = fast_parse_iso_timestamp_ms(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_timestamp_ms(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.TIMESTAMP_MS
    )


def _build_timestamp_us_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        # SIMD fast path: canonical ISO timestamp form.
        var fast = fast_parse_iso_timestamp_us(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_timestamp_us(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.TIMESTAMP_US
    )


def _build_timestamp_ns_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        # SIMD fast path: canonical ISO timestamp form.
        var fast = fast_parse_iso_timestamp_ns(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_timestamp_ns(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.TIMESTAMP_NS
    )


# =============================================================================
# Time32_S / Time32_MS — Int32 storage
# Time64_US / Time64_NS — Int64 storage
# =============================================================================


def _build_time32_s_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        # SIMD fast path: canonical 8-byte HH:MM:SS form.
        var fast = fast_parse_iso_time_s(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_time_s(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int32](
        arr, ArrowType.TIME32_S
    )


def _build_time32_ms_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        # SIMD fast path: canonical ISO time form.
        var fast = fast_parse_iso_time_ms(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_time_ms(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int32](
        arr, ArrowType.TIME32_MS
    )


def _build_time64_us_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        # SIMD fast path: canonical ISO time form.
        var fast = fast_parse_iso_time_us(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_time_us(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.TIME64_US
    )


def _build_time64_ns_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        # SIMD fast path: canonical ISO time form.
        var fast = fast_parse_iso_time_ns(cell)
        if fast:
            arr.set(r, fast.value())
            r = r + 1
            continue
        var parsed = _try_parse_time_ns(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.TIME64_NS
    )


# =============================================================================
# Duration_S / MS / US / NS — Int64 storage
# =============================================================================


def _build_duration_s_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_duration_s(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.DURATION_S
    )


def _build_duration_ms_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_duration_ms(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.DURATION_MS
    )


def _build_duration_us_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_duration_us(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.DURATION_US
    )


def _build_duration_ns_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.validity.value().clear(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_duration_ns(cell)
        if parsed:
            arr.set(r, parsed.value())
        else:
            arr.validity.value().clear(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.DURATION_NS
    )


# =============================================================================
# Decimal128 — Int64 mantissa (precision <= 18) -> Decimal128Array
# =============================================================================
#
# Wider precision (19-38) is not supported: it needs a two-limb {hi, lo}
# parser. The mantissa is an Int64 stored
# in the (low Int64) word of the Decimal128 16-byte slot, high word = 0
# (positive) or -1 (sign-extend negative).
# =============================================================================


def _build_decimal128_column(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    var precision = options.decimal_precision
    var scale = options.decimal_scale
    var arr = Decimal128Array.allocate_nullable(num_rows, precision, scale)
    var null_count = 0
    var r = 0
    while r < num_rows:
        if col_idx >= cells.num_cells_in_row(data_start + r):
            arr.set_null(r)
            null_count += 1
            r = r + 1
            continue
        var cs = cells.cell_start(data_start + r, col_idx)
        var ce = cells.cell_end(data_start + r, col_idx)
        var cell = bytes[cs:ce]
        if is_null_cell(cell, options):
            arr.set_null(r)
            null_count += 1
            r = r + 1
            continue
        var parsed = _try_parse_decimal128_to_int64(cell, precision, scale)
        if parsed:
            var mantissa = parsed.value()
            # Sign-extend the Int64 mantissa to 128 bits: low = mantissa,
            # high = -1 if negative else 0. This matches Arrow's
            # little-endian two-Int64-word Decimal128 layout.
            var low = mantissa
            var high: Int64 = Int64(0)
            if mantissa < Int64(0):
                high = Int64(-1)
            arr.set_raw(r, low, high)
        else:
            arr.set_null(r)
            null_count += 1
        r = r + 1
    arr.null_count = null_count
    return Column.from_decimal128(arr)


# =============================================================================
# Dispatch entry — called from `reader.mojo:_build_column` after the
# base 5-type cascade falls through. Routes the 22 widened ArrowTypes
# to the right per-DType builder; raises on truly unsupported types so
# the original error message stays informative.
# =============================================================================


def dispatch_typed_builder(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    col_idx: Int,
    dtype: ArrowType,
    num_rows: Int,
    options: CsvReadOptions,
) raises -> Column[HeapRegion]:
    """Per-DType column-builder cascade for the 22 widened ArrowTypes.

    Called by `reader.mojo:_build_column` after the base
    Int64/Float64/Date32/Bool/String cascade does not match. Mirrors the
    base-type shape: allocate -> per-row parse -> set / clear-validity
    -> wrap in Column with correct ArrowType discriminator.

    Raises on truly unsupported `dtype` (lattice / forced type that we
    have no builder for — defensive; in practice the inference lattice
    only emits known DTypes from this set).
    """
    # Unsigned ints
    if dtype == ArrowType.UINT8:
        return _build_uint8_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.UINT16:
        return _build_uint16_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.UINT32:
        return _build_uint32_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.UINT64:
        return _build_uint64_column(bytes, cells, data_start, col_idx, num_rows, options)
    # Narrowed signed ints
    if dtype == ArrowType.INT8:
        return _build_int8_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.INT16:
        return _build_int16_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.INT32:
        return _build_int32_column(bytes, cells, data_start, col_idx, num_rows, options)
    # Narrowed float
    if dtype == ArrowType.FLOAT32:
        return _build_float32_column(bytes, cells, data_start, col_idx, num_rows, options)
    # Date64
    if dtype == ArrowType.DATE64:
        return _build_date64_column(bytes, cells, data_start, col_idx, num_rows, options)
    # Timestamp_*
    if dtype == ArrowType.TIMESTAMP_S:
        return _build_timestamp_s_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.TIMESTAMP_MS:
        return _build_timestamp_ms_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.TIMESTAMP_US:
        return _build_timestamp_us_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.TIMESTAMP_NS:
        return _build_timestamp_ns_column(bytes, cells, data_start, col_idx, num_rows, options)
    # Time32_* / Time64_*
    if dtype == ArrowType.TIME32_S:
        return _build_time32_s_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.TIME32_MS:
        return _build_time32_ms_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.TIME64_US:
        return _build_time64_us_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.TIME64_NS:
        return _build_time64_ns_column(bytes, cells, data_start, col_idx, num_rows, options)
    # Duration_*
    if dtype == ArrowType.DURATION_S:
        return _build_duration_s_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.DURATION_MS:
        return _build_duration_ms_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.DURATION_US:
        return _build_duration_us_column(bytes, cells, data_start, col_idx, num_rows, options)
    if dtype == ArrowType.DURATION_NS:
        return _build_duration_ns_column(bytes, cells, data_start, col_idx, num_rows, options)
    # Decimal128 (Int64 mantissa, precision <= 18)
    if dtype == ArrowType.DECIMAL128:
        return _build_decimal128_column(bytes, cells, data_start, col_idx, num_rows, options)
    raise Error(
        "komira_csv.typed_column_builders: unsupported ArrowType for "
        + "column "
        + String(col_idx)
        + " — got "
        + String(dtype)
        + ". The widened set covers UInt8/16/32/64, Int8/16/32, "
        + "Float32, Date64, Timestamp_{S,MS,US,NS}, Time_{S,MS,US,NS}, "
        + "Duration_{S,MS,US,NS}, Decimal128 (precision <= 18)."
    )

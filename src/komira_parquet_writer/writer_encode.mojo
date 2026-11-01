# =============================================================================
# PLAIN page encoders: definition levels, fixed-width, BYTE_ARRAY, BOOLEAN
# =============================================================================
#
# - Definition levels (max level 1) as the RLE / bit-packed hybrid with a
#   4-byte little-endian length prefix (DataPage V1). One bit-packed run;
#   bit = 1 present, 0 null, which is the Arrow validity layout.
# - PLAIN fixed-width values: little-endian, the Arrow buffer layout.
# - PLAIN BYTE_ARRAY: [4-byte LE length][bytes] per value.
# - PLAIN BOOLEAN: one bit per value, LSB first.
#
# An OPTIONAL column's page holds the definition levels and the non-null
# values only; a REQUIRED column's page holds every value and no levels, and
# a REQUIRED column that holds a null is refused (see `column_page`).
# =============================================================================

from std.memory import memcpy
from std.sys import size_of

from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.offset_overflow import ARROW_INT32_OFFSET_MAX
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.metadata import Statistics
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType

from .column_page import (
    ColumnPage,
    _assemble_data_page,
    _require_no_nulls_when_required,
    dtype_to_parquet_type,
)
from komira_buffer.byte_buffer import write_uleb128
from .stats import compute_statistics_int32, compute_statistics_int64
from .writer_float_stats import float_column_statistics


# =============================================================================
# Definition levels
# =============================================================================


def _def_level_frame(length: Int) raises -> List[UInt8]:
    """[4-byte LE encoded length][bit-packed run header], sized for `length`
    levels; the caller appends the `(length + 7) / 8` packed bytes.

    Raises:
        Error: `length` is negative.
    """
    if length < 0:
        raise Error(
            "_def_level_frame: negative level count " + String(length)
        )
    var result = List[UInt8](capacity=16 + ((length + 7) >> 3))
    if length == 0:
        for _ in range(4):
            result.append(UInt8(0))
        return result^
    var num_groups = (length + 7) >> 3
    var header = List[UInt8]()
    write_uleb128((num_groups << 1) | 1, header)
    var encoded_len = len(header) + num_groups
    result.append(UInt8(encoded_len & 0xFF))
    result.append(UInt8((encoded_len >> 8) & 0xFF))
    result.append(UInt8((encoded_len >> 16) & 0xFF))
    result.append(UInt8((encoded_len >> 24) & 0xFF))
    for i in range(len(header)):
        result.append(header[i])
    return result^


def encode_def_levels_from_bitmap(
    validity: Bitmap[HeapRegion], offset: Int, length: Int
) raises -> List[UInt8]:
    """Definition levels for rows `[offset, offset + length)` of a validity
    bitmap, as the RLE / bit-packed hybrid with its 4-byte length prefix.

    `offset` is the array's own offset into its bitmap (a sliced
    PrimitiveArray's `offset`; 0 for arrays that have none). Bits past the
    last row in the final byte are written as 0.
    """
    var result = _def_level_frame(length)
    if length == 0:
        return result^
    var num_bytes = (length + 7) >> 3
    var base = offset >> 3
    var shift = offset & 7
    var last_byte = (offset + length - 1) >> 3
    for k in range(num_bytes):
        var b = validity.buffer.read_u8_at(base + k)
        if shift != 0:
            b = b >> UInt8(shift)
            if base + k + 1 <= last_byte:
                b = b | (validity.buffer.read_u8_at(base + k + 1) << UInt8(8 - shift))
        result.append(b)
    var tail = length & 7
    if tail != 0:
        var at = len(result) - 1
        result[at] = result[at] & UInt8((1 << tail) - 1)
    return result^


def encode_def_levels_all_valid(length: Int) raises -> List[UInt8]:
    """Definition levels for `length` present values (all 1 bits)."""
    var result = _def_level_frame(length)
    if length == 0:
        return result^
    for _ in range(length >> 3):
        result.append(UInt8(0xFF))
    var tail = length & 7
    if tail > 0:
        result.append(UInt8((1 << tail) - 1))
    return result^


def _def_levels(
    validity: Optional[Bitmap[HeapRegion]], offset: Int, length: Int, null_count: Int
) raises -> List[UInt8]:
    """Levels from the bitmap when the column holds a null, else all present."""
    if null_count > 0 and validity:
        return encode_def_levels_from_bitmap(validity.value(), offset, length)
    return encode_def_levels_all_valid(length)


# =============================================================================
# PLAIN fixed-width values
# =============================================================================


def encode_plain_values[dtype: DType](
    array: PrimitiveArray[dtype], skip_nulls: Bool
) -> List[UInt8]:
    """PLAIN value bytes of `array`: every value, or (with `skip_nulls`) the
    non-null values only. Offset-aware: a sliced array encodes its own rows.

    PERF-CRITICAL: with no null to skip this is one memcpy, because the PLAIN
    layout of a fixed-width type is the Arrow buffer layout (little-endian,
    packed). Do not replace it with a per-element loop.
    """
    comptime elem_size = size_of[Scalar[dtype]]()
    var n = array.length
    var compact = skip_nulls and array.null_count > 0 and Bool(array.validity)
    var count = n - array.null_count if compact else n
    var out = List[UInt8](capacity=max(count * elem_size, 1))
    out.resize(count * elem_size, UInt8(0))
    if count == 0:
        return out^
    var src = array._typed_ptr_ro()
    if not compact:
        # SAFETY: `src` is the array's offset-aware typed pointer over
        # `n` readable elements; `out` holds `n * elem_size` bytes.
        memcpy(
            dest=out.unsafe_ptr(),
            src=src.bitcast[UInt8](),
            count=n * elem_size,
        )
        return out^
    ref bm = array.validity.value()
    var dst = out.unsafe_ptr().bitcast[Scalar[dtype]]()
    var w = 0
    for i in range(n):
        if bm.test(array.offset + i):
            # SAFETY: `w < count` (one write per valid row) and `i < n`.
            (dst + w)[] = src[i]
            w += 1
    return out^


def _plain_statistics[dtype: DType](
    array: PrimitiveArray[dtype], nullable: Bool
) -> Optional[Statistics]:
    """Statistics of a PLAIN numeric chunk: INT32/INT64 (with an HLL
    distinct count) and FLOAT/DOUBLE (parquet.thrift's NaN and signed-zero
    rules). Other dtypes get none: an unsigned or narrow integer's signed
    INT32/INT64 order is not its own."""
    if array.length == 0:
        return None
    comptime if dtype == DType.int64:
        return compute_statistics_int64(rebind[PrimitiveArray[DType.int64]](array))
    elif dtype == DType.int32:
        return compute_statistics_int32(rebind[PrimitiveArray[DType.int32]](array))
    elif dtype == DType.float32 or dtype == DType.float64:
        return float_column_statistics[dtype](
            array, skip_nulls=nullable, null_count=array.null_count if nullable else 0
        )
    else:
        return None


def encode_plain_column[dtype: DType](
    column_index: Int,
    array: PrimitiveArray[dtype],
    column_name: String,
    nullable: Bool = False,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """A fixed-width column as one PLAIN data page, with statistics.

    An OPTIONAL column (`nullable`) always carries definition levels, even
    with no null: a reader of an OPTIONAL column reads levels first.

    Raises:
        Error: a REQUIRED column holding a null, or a page over the i32
            PageHeader ceiling.
    """
    _require_no_nulls_when_required(
        "encode_plain_column", column_name, nullable, array.null_count
    )
    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _def_levels(array.validity, array.offset, array.length, array.null_count)
    var values = encode_plain_values[dtype](array, skip_nulls=nullable)
    return _assemble_data_page(
        column_index,
        array.length,
        def_levels,
        values,
        dtype_to_parquet_type[dtype](),
        column_name,
        Encoding.PLAIN,
        nullable,
        codec,
        _plain_statistics[dtype](array, nullable),
    )


# =============================================================================
# PLAIN BYTE_ARRAY
# =============================================================================


def _append_prefixed(mut out: List[UInt8], value: Span[UInt8, _]):
    """Append [4-byte LE length][bytes]."""
    var n = len(value)
    out.append(UInt8(n & 0xFF))
    out.append(UInt8((n >> 8) & 0xFF))
    out.append(UInt8((n >> 16) & 0xFF))
    out.append(UInt8((n >> 24) & 0xFF))
    if n == 0:
        return
    var cur = len(out)
    out.resize(cur + n, UInt8(0))
    # SAFETY: `out` was just resized to hold `n` more bytes; `value` holds
    # `n` readable bytes and is borrowed for the call.
    memcpy(dest=out.unsafe_ptr() + cur, src=value.unsafe_ptr(), count=n)


def encode_plain_byte_array_data(
    string_array: StringArray[HeapRegion], skip_nulls: Bool = True
) -> List[UInt8]:
    """PLAIN BYTE_ARRAY bytes of a string column: [4-byte LE length][bytes]
    per value, null rows skipped when `skip_nulls`."""
    var n = string_array.length
    var compact = skip_nulls and string_array.null_count > 0
    var count = n - string_array.null_count if compact else n
    var out = List[UInt8](capacity=max(count * 4 + string_array.data_length, 1))
    for i in range(n):
        if compact and string_array.is_null(i):
            continue
        _append_prefixed(out, string_array.get_span(i))
    return out^


def encode_plain_byte_array_data_large(
    string_array: LargeStringArray[HeapRegion], skip_nulls: Bool = True
) raises -> List[UInt8]:
    """The Int64-offset twin of `encode_plain_byte_array_data`; the bytes
    for the same values are identical.

    Raises:
        Error: a value longer than the 4-byte length prefix can state
            (`ARROW_INT32_OFFSET_MAX`). Int64 offsets can describe one; an
            Int32 offset buffer cannot, which is why the narrow twin has no
            such check.
    """
    var n = string_array.length
    var compact = skip_nulls and string_array.null_count > 0
    var out = List[UInt8](capacity=1)
    for i in range(n):
        if compact and string_array.is_null(i):
            continue
        var span = string_array.get_span(i)
        if len(span) > ARROW_INT32_OFFSET_MAX:
            raise Error(
                "encode_plain_byte_array_data_large: row "
                + String(i)
                + " is "
                + String(len(span))
                + " bytes, over the PLAIN BYTE_ARRAY 4-byte length prefix limit of "
                + String(ARROW_INT32_OFFSET_MAX)
            )
        _append_prefixed(out, span)
    return out^


def encode_string_column_page(
    column_index: Int,
    string_array: StringArray[HeapRegion],
    column_name: String,
    nullable: Bool = True,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """A string column as one PLAIN BYTE_ARRAY data page (no statistics:
    `stats.compute_statistics_string` computes them separately)."""
    _require_no_nulls_when_required(
        "encode_string_column_page", column_name, nullable, string_array.null_count
    )
    var values = encode_plain_byte_array_data(string_array, skip_nulls=nullable)
    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _def_levels(
            string_array.validity, 0, string_array.length, string_array.null_count
        )
    return _assemble_data_page(
        column_index,
        string_array.length,
        def_levels,
        values,
        ParquetType.BYTE_ARRAY,
        column_name,
        Encoding.PLAIN,
        nullable,
        codec,
        None,
    )


def encode_large_string_column_page(
    column_index: Int,
    string_array: LargeStringArray[HeapRegion],
    column_name: String,
    nullable: Bool = True,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """The Int64-offset twin of `encode_string_column_page`. Parquet has one
    variable-length type, so the page is byte-identical to the narrow
    twin's for the same values."""
    _require_no_nulls_when_required(
        "encode_large_string_column_page", column_name, nullable, string_array.null_count
    )
    var values = encode_plain_byte_array_data_large(string_array, skip_nulls=nullable)
    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _def_levels(
            string_array.validity, 0, string_array.length, string_array.null_count
        )
    return _assemble_data_page(
        column_index,
        string_array.length,
        def_levels,
        values,
        ParquetType.BYTE_ARRAY,
        column_name,
        Encoding.PLAIN,
        nullable,
        codec,
        None,
    )


# =============================================================================
# PLAIN BOOLEAN
# =============================================================================


def encode_plain_boolean_data(
    boolean_array: BooleanArray, skip_nulls: Bool = True
) -> List[UInt8]:
    """PLAIN BOOLEAN bytes: one bit per value, LSB first, null rows skipped
    when `skip_nulls`. Bits past the last value are 0."""
    var n = boolean_array.length
    var compact = (
        skip_nulls and boolean_array.null_count > 0 and Bool(boolean_array.validity)
    )
    var count = n - boolean_array.null_count if compact else n
    var out = List[UInt8](capacity=max((count + 7) >> 3, 1))
    out.resize((count + 7) >> 3, UInt8(0))
    if not compact:
        # Same bit layout as Arrow: copy the bytes, then clear the tail bits.
        for k in range((n + 7) >> 3):
            out[k] = boolean_array.data.buffer.read_u8_at(k)
        if n & 7 != 0:
            out[len(out) - 1] = out[len(out) - 1] & UInt8((1 << (n & 7)) - 1)
        return out^
    ref bm = boolean_array.validity.value()
    var bit = 0
    for i in range(n):
        if not bm.test(i):
            continue
        if boolean_array.data.test(i):
            out[bit >> 3] = out[bit >> 3] | (UInt8(1) << UInt8(bit & 7))
        bit += 1
    return out^


def encode_boolean_column_page(
    column_index: Int,
    boolean_array: BooleanArray,
    column_name: String,
    nullable: Bool = True,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """A boolean column as one PLAIN data page (no statistics)."""
    _require_no_nulls_when_required(
        "encode_boolean_column_page", column_name, nullable, boolean_array.null_count
    )
    var values = encode_plain_boolean_data(boolean_array, skip_nulls=nullable)
    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _def_levels(
            boolean_array.validity, 0, boolean_array.length, boolean_array.null_count
        )
    return _assemble_data_page(
        column_index,
        boolean_array.length,
        def_levels,
        values,
        ParquetType.BOOLEAN,
        column_name,
        Encoding.PLAIN,
        nullable,
        codec,
        None,
    )

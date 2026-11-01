# =============================================================================
# Multi-array encoding: several arrays as one column chunk, no Arrow concat
# =============================================================================
#
# A writer that holds a column as several morsels would, naively, concatenate
# them into one array and encode that: a second copy of the column just to
# throw it away after the encode. These functions encode the arrays one after
# another into the page buffer instead.
#
#   encode_two_primitives / encode_two_strings / encode_two_to_buffer
#       two arrays, nulls honored (OPTIONAL columns get definition levels
#       covering both arrays), statistics as the single-array encoder gives
#       for the concatenation;
#   encode_n_primitives
#       any number of arrays given as raw element bytes, REQUIRED, no
#       statistics (a caller holding bytes has no validity to consult).
#
# Pages are built by `_assemble_data_page`, so the codec, the i32 page-size
# checks and the chunk's encodings list are the ones every other encoder has.
# =============================================================================

from std.sys import size_of

from komira_arrow.bitmap import Bitmap
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.metadata import Statistics
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType

from .column_page import (
    ColumnPage,
    _append_bytes,
    _assemble_data_page,
    _require_no_nulls_when_required,
    dtype_to_parquet_type,
)
from .encoded_column import EncodedColumn
from .stats import IntStatsAccumulator
from .writer_encode import (
    _def_level_frame,
    encode_def_levels_all_valid,
    encode_plain_byte_array_data,
    encode_plain_values,
)
from .writer_float_stats import (
    FloatMinMax,
    float_minmax_from_array,
    make_float_statistics,
)


def _is_valid(
    validity: Optional[Bitmap[HeapRegion]], offset: Int, null_count: Int, i: Int
) -> Bool:
    if null_count > 0 and validity:
        return validity.value().test(offset + i)
    return True


def _append_validity_bits(
    mut bits: List[UInt8],
    bit_pos: Int,
    validity: Optional[Bitmap[HeapRegion]],
    offset: Int,
    n: Int,
    null_count: Int,
):
    """Append the validity of one array's `n` rows (bit set = present) to
    `bits` at bit position `bit_pos`, growing `bits` to hold them. The
    arrays of a column are appended in order, each at the rows before it."""
    var need = (bit_pos + n + 7) >> 3
    if len(bits) < need:
        bits.resize(need, UInt8(0))
    for j in range(n):
        if _is_valid(validity, offset, null_count, j):
            var i = bit_pos + j
            bits[i >> 3] = bits[i >> 3] | (UInt8(1) << UInt8(i & 7))


def _two_def_levels(
    v1: Optional[Bitmap[HeapRegion]],
    offset1: Int,
    n1: Int,
    nulls1: Int,
    v2: Optional[Bitmap[HeapRegion]],
    offset2: Int,
    n2: Int,
    nulls2: Int,
) raises -> List[UInt8]:
    """The definition levels of two arrays in a row: one frame over `n1 + n2`
    rows, bit i set when row i is present."""
    var total = n1 + n2
    if nulls1 == 0 and nulls2 == 0:
        return encode_def_levels_all_valid(total)
    var out = _def_level_frame(total)
    var bits = List[UInt8]()
    _append_validity_bits(bits, 0, v1, offset1, n1, nulls1)
    _append_validity_bits(bits, n1, v2, offset2, n2, nulls2)
    _append_bytes(out, bits)
    return out^


def _stats_two_primitives[
    dtype: DType
](
    arr1: PrimitiveArray[dtype], arr2: PrimitiveArray[dtype], nullable: Bool
) -> Optional[Statistics]:
    """What `encode_plain_column` computes for the two arrays' concatenation:
    INT32 / INT64 min/max, null_count and HLL; FLOAT / DOUBLE by the spec's
    rules; nothing for other types or an empty column."""
    if arr1.length + arr2.length == 0:
        return None
    comptime if dtype == DType.int32 or dtype == DType.int64:
        var acc = IntStatsAccumulator[dtype]()
        acc.add(arr1)
        acc.add(arr2)
        return Optional[Statistics](acc.finish())
    elif dtype == DType.float32 or dtype == DType.float64:
        var acc = float_minmax_from_array[dtype](arr1, skip_nulls=nullable)
        acc.merge(float_minmax_from_array[dtype](arr2, skip_nulls=nullable))
        var nulls = (arr1.null_count + arr2.null_count) if nullable else 0
        return Optional[Statistics](make_float_statistics[dtype](acc, nulls))
    else:
        return None


def encode_two_primitives[
    dtype: DType
](
    column_index: Int,
    arr1: PrimitiveArray[dtype],
    arr2: PrimitiveArray[dtype],
    column_name: String,
    nullable: Bool = False,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """Two fixed-width arrays as one PLAIN data page, the second after the
    first, with statistics. The result equals `encode_plain_column` over the
    arrays' concatenation, without building the concatenation.

    Raises:
        Error: a REQUIRED column (`nullable` False) holding a null, or a page
            over the i32 PageHeader ceiling.
    """
    _require_no_nulls_when_required(
        "encode_two_primitives",
        column_name,
        nullable,
        arr1.null_count + arr2.null_count,
    )
    var total = arr1.length + arr2.length
    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _two_def_levels(
            arr1.validity,
            arr1.offset,
            arr1.length,
            arr1.null_count,
            arr2.validity,
            arr2.offset,
            arr2.length,
            arr2.null_count,
        )
    var values = encode_plain_values[dtype](arr1, skip_nulls=nullable)
    _append_bytes(values, encode_plain_values[dtype](arr2, skip_nulls=nullable))
    return _assemble_data_page(
        column_index,
        total,
        def_levels,
        values,
        dtype_to_parquet_type[dtype](),
        column_name,
        Encoding.PLAIN,
        nullable,
        codec,
        _stats_two_primitives[dtype](arr1, arr2, nullable),
    )


def encode_n_primitives[
    mut: Bool,
    //,
    dtype: DType,
    data_origin: Origin[mut=mut],
](
    column_index: Int,
    array_views: List[ByteView[data_origin]],
    array_lengths: List[Int],
    column_name: String,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """Any number of REQUIRED fixed-width arrays, given as the raw element
    bytes of each, as one PLAIN data page. No statistics: a caller that holds
    bytes holds no validity or order to consult.

    Args:
        column_index: 0-based leaf column index.
        array_views: One `ByteView` per array over its element bytes;
            `len(array_views[i]) >= array_lengths[i] * size_of[Scalar[dtype]]()`.
        array_lengths: Element counts, one per array.
        column_name: The leaf name.
        codec: The compression codec of the page body.

    Raises:
        Error: the two lists differ in length, a view is shorter than its
            element count needs, or the page is over the i32 ceiling.
    """
    comptime elem_size = size_of[Scalar[dtype]]()
    if len(array_lengths) != len(array_views):
        raise Error(
            "encode_n_primitives: "
            + String(len(array_views))
            + " views but "
            + String(len(array_lengths))
            + " lengths"
        )
    var total_values = 0
    for i in range(len(array_views)):
        if array_lengths[i] < 0 or array_views[i].len() < array_lengths[i] * elem_size:
            raise Error(
                "encode_n_primitives: array "
                + String(i)
                + " has "
                + String(array_views[i].len())
                + " bytes for "
                + String(array_lengths[i])
                + " elements"
            )
        total_values += array_lengths[i]
    var values = List[UInt8](capacity=max(total_values * elem_size, 1))
    for i in range(len(array_views)):
        var nbytes = array_lengths[i] * elem_size
        if nbytes > 0:
            values.extend(array_views[i].sub(0, nbytes).into_span())
    return _assemble_data_page(
        column_index,
        total_values,
        List[UInt8](),
        values,
        dtype_to_parquet_type[dtype](),
        column_name,
        Encoding.PLAIN,
        False,
        codec,
        None,
    )


def encode_two_strings(
    column_index: Int,
    arr1: StringArray[HeapRegion],
    arr2: StringArray[HeapRegion],
    column_name: String,
    nullable: Bool = False,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """Two string arrays as one PLAIN BYTE_ARRAY data page. Equals
    `encode_string_column_page` over the concatenation (which computes no
    statistics).

    Raises:
        Error: a REQUIRED column holding a null, a value over the 4-byte
            length prefix, or a page over the i32 ceiling.
    """
    _require_no_nulls_when_required(
        "encode_two_strings",
        column_name,
        nullable,
        arr1.null_count + arr2.null_count,
    )
    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _two_def_levels(
            arr1.validity,
            0,
            arr1.length,
            arr1.null_count,
            arr2.validity,
            0,
            arr2.length,
            arr2.null_count,
        )
    var values = encode_plain_byte_array_data(arr1, skip_nulls=nullable)
    _append_bytes(
        values, encode_plain_byte_array_data(arr2, skip_nulls=nullable)
    )
    return _assemble_data_page(
        column_index,
        arr1.length + arr2.length,
        def_levels,
        values,
        ParquetType.BYTE_ARRAY,
        column_name,
        Encoding.PLAIN,
        nullable,
        codec,
        None,
    )


def encode_two_to_buffer[
    dtype: DType
](
    column_index: Int,
    arr1: PrimitiveArray[dtype],
    arr2: PrimitiveArray[dtype],
    column_name: String,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> EncodedColumn:
    """Two REQUIRED fixed-width arrays as an `EncodedColumn` (header apart
    from body), for `write_parquet_file_from_encoded`.

    Raises:
        Error: as `encode_two_primitives` for a REQUIRED column.
    """
    var page = encode_two_primitives[dtype](
        column_index, arr1, arr2, column_name, nullable=False, codec=codec
    )
    var header_len = len(page.data) - page.compressed_size
    var header = List[UInt8](capacity=max(header_len, 1))
    var body = List[UInt8](capacity=max(page.compressed_size, 1))
    for i in range(header_len):
        header.append(page.data[i])
    for i in range(header_len, len(page.data)):
        body.append(page.data[i])
    return EncodedColumn(
        header^,
        body^,
        column_index,
        page.num_values,
        page.uncompressed_size,
        page.parquet_type,
        column_name,
        codec=codec,
        compressed_size=page.compressed_size,
        statistics=page.statistics.copy(),
    )

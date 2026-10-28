# =============================================================================
# Dictionary pages: [DICTIONARY_PAGE][DATA_PAGE (RLE_DICTIONARY)]
# =============================================================================
#
# A dictionary-encoded column chunk is two pages:
#   [DICTIONARY_PAGE header][PLAIN dictionary values]
#   [DATA_PAGE header][def levels][bit width byte][RLE / bit-packed indices]
# Each page body is compressed on its own, behind its own header.
#
# The index stream is one bit-packed run of the indices of the non-null
# rows, padded to a group of 8. A one-entry dictionary has bit width 0 and
# is one RLE run: [0x00][varint (count << 1)] with no value bytes; a stream
# of the width byte alone would decode to zero indices.
#
# This module holds the shared page assembly and the string arms; the
# numeric arm is `writer_dict_numeric`.
# =============================================================================

from komira_arrow.bitmap import Bitmap
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.metadata import Statistics
from komira_parquet_api.types import CompressionCodec, Encoding, PageType, ParquetType

from .column_page import ColumnPage, _append_bytes, _require_no_nulls_when_required
from .dict_encoder import (
    DictEncodingResult,
    encode_dict_column,
    encode_dict_column_large,
)
from .page_size_limit import check_parquet_page_size
from .thrift_writer import ThriftCompactWriter
from .writer_bitpack import _pack_count_bytes, _pack_fixed_width_into, min_bit_width
from komira_buffer.byte_buffer import write_uleb128
from .writer_encode import _append_prefixed, _def_levels
from .writer_helpers import _compress_page_body


# A string column is dictionary-encoded only when its distinct values are at
# most this fraction of its rows.
comptime DICT_CARDINALITY_THRESHOLD: Float64 = 0.4


def encode_dict_indices_rle(indices: List[Int32], bit_width: Int) raises -> List[UInt8]:
    """The RLE / bit-packed hybrid index stream with its bit-width byte.

    Raises:
        Error: `bit_width` outside [0, 32].
    """
    if bit_width < 0 or bit_width > 32:
        raise Error(
            "encode_dict_indices_rle: bit_width " + String(bit_width) + " is outside [0, 32]"
        )
    var n = len(indices)
    var result = List[UInt8](capacity=16)
    result.append(UInt8(bit_width))
    if n == 0:
        return result^
    if bit_width == 0:
        # One RLE run of `n` zeros; the value takes ceil(0 / 8) = 0 bytes.
        write_uleb128(n << 1, result)
        return result^

    var num_groups = (n + 7) >> 3
    write_uleb128((num_groups << 1) | 1, result)
    var padded = num_groups * 8
    var values = List[Int64](length=padded, fill=Int64(0))
    for i in range(n):
        values[i] = Int64(indices[i])
    var start = len(result)
    var nbytes = _pack_count_bytes(padded, bit_width)
    result.resize(start + nbytes, UInt8(0))
    # SAFETY: `result` has `nbytes` writable bytes from `start` and `values`
    # holds `padded` Int64s; both alive through the call.
    # PERF-CRITICAL: the SIMD group packer; a scalar carry accumulator here
    # was ~4% of an uncompressed write.
    _pack_fixed_width_into(values.unsafe_ptr(), padded, bit_width, result.unsafe_ptr() + start)
    return result^


def write_dictionary_page_header(
    mut writer: ThriftCompactWriter,
    uncompressed_size: Int,
    compressed_size: Int,
    num_values: Int,
    encoding: Encoding,
) raises:
    """A PageHeader of type DICTIONARY_PAGE (fields 1, 2, 3) with its
    DictionaryPageHeader (field 7: num_values, encoding; is_sorted omitted).

    Raises:
        Error: named `ParquetPageSizeOverflow` when a size does not fit i32.
    """
    check_parquet_page_size(
        "write_dictionary_page_header", "uncompressed_page_size", uncompressed_size
    )
    check_parquet_page_size(
        "write_dictionary_page_header", "compressed_page_size", compressed_size
    )
    writer.push_struct()
    writer.write_i32_field(1, Int(PageType.DICTIONARY_PAGE.value))
    writer.write_i32_field(2, uncompressed_size)
    writer.write_i32_field(3, compressed_size)
    writer.write_struct_begin(7)
    writer.write_i32_field(1, num_values)
    writer.write_i32_field(2, Int(encoding.value))
    writer.write_struct_end()
    writer.pop_struct()


def _dense_indices(
    indices: PrimitiveArray[DType.int32],
    num_values: Int,
    validity: Optional[Bitmap[HeapRegion]],
    offset: Int,
    null_count: Int,
) -> List[Int32]:
    """The indices of the non-null rows (row `i`'s validity is bit
    `offset + i`). A null row's index slot is not a dictionary entry."""
    var out = List[Int32](capacity=max(num_values - null_count, 1))
    if null_count == 0 or not validity:
        for i in range(num_values):
            out.append(indices.load[1](i)[0])
        return out^
    ref bm = validity.value()
    for i in range(num_values):
        if bm.test(offset + i):
            out.append(indices.load[1](i)[0])
    return out^


def _dictionary_chunk(
    column_index: Int,
    var dict_body: List[UInt8],
    cardinality: Int,
    dense_indices: List[Int32],
    num_values: Int,
    def_levels: List[UInt8],
    parquet_type: ParquetType,
    column_name: String,
    nullable: Bool,
    codec: CompressionCodec,
    var statistics: Optional[Statistics],
) raises -> ColumnPage:
    """Assemble [dict header][dict body][data header][data body].

    `uncompressed_size` / `compressed_size` of the result sum the two bodies;
    `dict_page_size` is the dictionary page's header plus body.
    """
    var dict_uncompressed = len(dict_body)
    var dict_compressed_body = _compress_page_body(codec, dict_body^)
    var dict_header = ThriftCompactWriter()
    write_dictionary_page_header(
        dict_header, dict_uncompressed, len(dict_compressed_body), cardinality, Encoding.PLAIN
    )
    var dict_header_bytes = dict_header.take_bytes()

    var bit_width = 0 if cardinality <= 1 else min_bit_width(cardinality - 1)
    var rle = encode_dict_indices_rle(dense_indices, bit_width)
    var data_body = List[UInt8](capacity=len(def_levels) + len(rle))
    if nullable:
        _append_bytes(data_body, def_levels)
    _append_bytes(data_body, rle)
    var data_uncompressed = len(data_body)
    check_parquet_page_size(
        "_dictionary_chunk", column_name, "uncompressed_page_size", data_uncompressed
    )
    var data_compressed_body = _compress_page_body(codec, data_body^)
    var data_header = ThriftCompactWriter()
    data_header.write_data_page_header(
        data_uncompressed, len(data_compressed_body), num_values, Encoding.RLE_DICTIONARY
    )
    var data_header_bytes = data_header.take_bytes()

    var page = List[UInt8](
        capacity=len(dict_header_bytes)
        + len(dict_compressed_body)
        + len(data_header_bytes)
        + len(data_compressed_body)
    )
    _append_bytes(page, dict_header_bytes)
    _append_bytes(page, dict_compressed_body)
    _append_bytes(page, data_header_bytes)
    _append_bytes(page, data_compressed_body)

    var encs: List[Encoding] = [Encoding.PLAIN, Encoding.RLE_DICTIONARY, Encoding.RLE]
    return ColumnPage(
        page^,
        column_index,
        num_values,
        dict_uncompressed + data_uncompressed,
        len(dict_compressed_body) + len(data_compressed_body),
        parquet_type,
        String(column_name),
        encs^,
        codec,
        statistics=statistics^,
        dict_page_size=len(dict_header_bytes) + len(dict_compressed_body),
    )


def encode_dict_values_plain(dictionary: StringArray[HeapRegion]) -> List[UInt8]:
    """The DICTIONARY_PAGE body of a string dictionary: PLAIN BYTE_ARRAY."""
    var out = List[UInt8](capacity=max(dictionary.length * 4 + dictionary.data_length, 1))
    for i in range(dictionary.length):
        _append_prefixed(out, dictionary.get_span(i))
    return out^


def _string_dict_page(
    column_index: Int,
    var result: DictEncodingResult,
    num_values: Int,
    null_count: Int,
    validity: Optional[Bitmap[HeapRegion]],
    column_name: String,
    nullable: Bool,
    cardinality_threshold: Float64,
    codec: CompressionCodec,
) raises -> Optional[ColumnPage]:
    """The width-agnostic half of both string arms: from here on a dictionary
    and per-row indices carry no source offset width."""
    var cardinality = result.dictionary.length
    var threshold = max(Int(Float64(num_values) * cardinality_threshold), 1)
    if cardinality > threshold:
        return None
    var dense = _dense_indices(result.indices, num_values, validity, 0, null_count)
    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _def_levels(validity, 0, num_values, null_count)
    return _dictionary_chunk(
        column_index,
        encode_dict_values_plain(result.dictionary),
        cardinality,
        dense,
        num_values,
        def_levels,
        ParquetType.BYTE_ARRAY,
        column_name,
        nullable,
        codec,
        None,
    )


def encode_dict_string_column_page(
    column_index: Int,
    string_array: StringArray[HeapRegion],
    column_name: String,
    nullable: Bool = True,
    cardinality_threshold: Float64 = DICT_CARDINALITY_THRESHOLD,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> Optional[ColumnPage]:
    """A string column as a dictionary chunk, or None when the column is
    empty or too high-cardinality (the caller writes PLAIN instead).

    Raises:
        Error: a REQUIRED column holding a null, or a page over the i32
            PageHeader ceiling. A failure is never turned into None: None
            means only "write PLAIN".
    """
    _require_no_nulls_when_required(
        "encode_dict_string_column_page", column_name, nullable, string_array.null_count
    )
    if string_array.length == 0:
        return None
    var result = encode_dict_column(string_array)
    if not result.success:
        return None
    return _string_dict_page(
        column_index,
        result^,
        string_array.length,
        string_array.null_count,
        string_array.validity,
        column_name,
        nullable,
        cardinality_threshold,
        codec,
    )


def encode_dict_large_string_column_page(
    column_index: Int,
    string_array: LargeStringArray[HeapRegion],
    column_name: String,
    nullable: Bool = True,
    cardinality_threshold: Float64 = DICT_CARDINALITY_THRESHOLD,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> Optional[ColumnPage]:
    """The Int64-offset twin of `encode_dict_string_column_page`. Also None
    when the payload is over what the dictionary build can address (see
    `encode_dict_column_large`); PLAIN has no such limit."""
    _require_no_nulls_when_required(
        "encode_dict_large_string_column_page", column_name, nullable, string_array.null_count
    )
    if string_array.length == 0:
        return None
    var result = encode_dict_column_large(string_array)
    if not result.success:
        return None
    return _string_dict_page(
        column_index,
        result^,
        string_array.length,
        string_array.null_count,
        string_array.validity,
        column_name,
        nullable,
        cardinality_threshold,
        codec,
    )

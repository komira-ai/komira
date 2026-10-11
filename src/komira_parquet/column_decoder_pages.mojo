# =============================================================================
# column_decoder_pages — one page of a flat column chunk into the chunk's
#                        accumulators
# =============================================================================
#
# `decode_column_pages` (column_decoder) parses each page header, checks the
# page's sizes and CRC, and hands the page here:
#
#   * `_decode_dictionary_page`: the PLAIN dictionary into the chunk's
#     `DictionaryDecoder` (INT32, INT64, FLOAT, DOUBLE, BYTE_ARRAY,
#     FIXED_LEN_BYTE_ARRAY);
#   * `_decode_data_page`: a DATA_PAGE or DATA_PAGE_V2. The body is decoded
#     into the context's scratch; a nullable chunk's definition levels become
#     validity bits (a V1 page's levels carry a 4-byte length prefix, a V2
#     page's level section is bare RLE of the length its header gives); then
#     the values, by the page's own encoding, are appended to the chunk's
#     accumulator (column_decoder_state);
#   * `_decode_single_plain_page`: the one page of a non-nullable,
#     non-dictionary, fixed-width chunk, decoded into a buffer of its own that
#     becomes the column's data with no copy.
#
# Encodings: PLAIN, RLE_DICTIONARY / PLAIN_DICTIONARY, DELTA_BINARY_PACKED
# (INT32, INT64), BYTE_STREAM_SPLIT (FLOAT, DOUBLE), DELTA_LENGTH_BYTE_ARRAY
# and DELTA_BYTE_ARRAY (BYTE_ARRAY). A chunk may switch from dictionary pages
# to other pages once (pyarrow does when a dictionary outgrows its page
# limit): a BYTE_ARRAY chunk then keeps its runs in order as strings, a
# numeric one resolves its codes and appends the rest at assembly. A
# dictionary page after a non-dictionary page in a numeric chunk, and the
# switch in a DECIMAL or FIXED_LEN_BYTE_ARRAY chunk, are refused.
#
# Every count a page declares is checked against the bytes it holds before a
# value is read.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_parquet_api.metadata import PageHeader
from komira_parquet_api.types import (
    CompressionCodec,
    Encoding,
    PageType,
    ParquetType,
)

from .column_decode_context import ColumnDecodeContext
from .column_decoder_state import _ChunkAcc, _page_into_scratch
from .decode_helpers import _set_bits_bulk
from .def_level_bitmap import decode_def_levels_to_bitmap
from .plain import (
    decode_plain_float32_zero_copy,
    decode_plain_float64_zero_copy,
    decode_plain_int32_zero_copy,
    decode_plain_int64_zero_copy,
)
from .rle import RleDecoder


@always_inline
def _is_dict_encoding(enc: Encoding) -> Bool:
    return enc == Encoding.RLE_DICTIONARY or enc == Encoding.PLAIN_DICTIONARY


@always_inline
def _is_fixed_numeric(ptype: ParquetType) -> Bool:
    return (
        ptype == ParquetType.INT32
        or ptype == ParquetType.INT64
        or ptype == ParquetType.FLOAT
        or ptype == ParquetType.DOUBLE
    )


# -----------------------------------------------------------------------------
# Dictionary page
# -----------------------------------------------------------------------------


def _decode_dictionary_page(
    mut acc: _ChunkAcc,
    codec: CompressionCodec,
    hdr: PageHeader,
    page: Span[UInt8, _],
    mut decode_ctx: ColumnDecodeContext,
) raises:
    """Load a dictionary page into the chunk's `DictionaryDecoder`.

    The body is decoded into the context's scratch; the decoder copies the
    entries out, so the scratch is free for the next page.

    Raises:
        Error on a negative entry count, more fixed-width entries than the
        decoded page holds, a FIXED_LEN_BYTE_ARRAY column with no type
        length, or a physical type with no dictionary (BOOLEAN, INT96).
    """
    var nv = hdr.num_values
    if nv < 0:
        raise Error(
            "parquet: corrupt dictionary page: negative num_values "
            + String(nv)
        )
    decode_ctx.ensure_scratch(1)
    var dlen = _page_into_scratch(
        codec, page, 0, hdr.uncompressed_page_size, decode_ctx.scratch_ref()
    )
    var body = decode_ctx.scratch_ref().view_ro().into_span()[0:dlen]
    var ptype = acc.ptype
    var width = 0
    if ptype == ParquetType.INT32 or ptype == ParquetType.FLOAT:
        width = 4
    elif ptype == ParquetType.INT64 or ptype == ParquetType.DOUBLE:
        width = 8
    elif ptype == ParquetType.FIXED_LEN_BYTE_ARRAY and acc.type_length > 0:
        width = acc.type_length
    if width > 0 and nv * width > dlen:
        raise Error(
            "parquet: corrupt dictionary page: num_values "
            + String(nv)
            + " * width "
            + String(width)
            + " exceeds decoded dictionary bytes "
            + String(dlen)
        )
    if ptype == ParquetType.INT32:
        acc.dict_decoder.init_dict_int32(body, nv)
    elif ptype == ParquetType.INT64:
        acc.dict_decoder.init_dict_int64(body, nv)
    elif ptype == ParquetType.FLOAT:
        acc.dict_decoder.init_dict_float32(body, nv)
    elif ptype == ParquetType.DOUBLE:
        acc.dict_decoder.init_dict_float64(body, nv)
    elif ptype == ParquetType.BYTE_ARRAY:
        acc.dict_decoder.init_dict_byte_array(body, nv)
    elif ptype == ParquetType.FIXED_LEN_BYTE_ARRAY:
        if acc.type_length <= 0:
            raise Error(
                "parquet: FIXED_LEN_BYTE_ARRAY column is missing type_length"
                " in its schema"
            )
        acc.dict_decoder.init_dict_fixed_len_byte_array(
            body, nv, acc.type_length
        )
    else:
        raise Error(
            "parquet: no dictionary decoding for physical type " + String(ptype)
        )
    acc.has_dict = True


# -----------------------------------------------------------------------------
# The single PLAIN page of a non-nullable fixed-width chunk
# -----------------------------------------------------------------------------


def _single_plain_page_eligible(acc: _ChunkAcc, hdr: PageHeader) -> Bool:
    """True when this data page is the whole chunk and its bytes are the
    column's data as they stand: a non-nullable, non-DECIMAL INT32 / INT64 /
    FLOAT / DOUBLE chunk with no dictionary, one PLAIN page holding every
    value, and (for V2) no level bytes in front of the values."""
    var levels = 0
    if hdr.type == PageType.DATA_PAGE_V2:
        levels = hdr.rep_levels_byte_length + hdr.def_levels_byte_length
    return (
        not acc.nullable
        and not acc.is_decimal
        and acc.total_decoded == 0
        and hdr.num_values == acc.num_values
        and not acc.has_dict
        and hdr.encoding == Encoding.PLAIN
        and _is_fixed_numeric(acc.ptype)
        and levels == 0
    )


def _decode_single_plain_page(
    acc: _ChunkAcc,
    codec: CompressionCodec,
    hdr: PageHeader,
    page: Span[UInt8, _],
    decode_move: Bool,
) raises -> Column[HeapRegion]:
    """Decode the chunk's one PLAIN page into a buffer of its own and make
    that buffer the column's data (`_single_plain_page_eligible` holds).

    PERF-CRITICAL: with `decode_move` the buffer becomes the column with no
    copy; without it the column is built by `Column.from_primitive`, which
    copies (the reference the move is checked against).

    Raises:
        Error if the decoded page holds fewer than `num_values` values.
    """
    var page_codec = codec
    if hdr.type == PageType.DATA_PAGE_V2 and not hdr.is_compressed:
        page_codec = CompressionCodec.UNCOMPRESSED
    var buf = OwnedAlignedBuffer(1)
    var dlen = _page_into_scratch(
        page_codec, page, 0, hdr.uncompressed_page_size, buf
    )
    var n = hdr.num_values
    var need = n * acc.plain_elem_size
    if need > dlen:
        raise Error(
            "parquet: corrupt data page: PLAIN page declares "
            + String(n)
            + " values of "
            + String(acc.plain_elem_size)
            + " bytes ("
            + String(need)
            + " bytes) but the page body holds only "
            + String(dlen)
            + " bytes"
        )
    buf.set_length(Int64(need))
    var dt = DType.int32
    if acc.ptype == ParquetType.INT64:
        dt = DType.int64
    elif acc.ptype == ParquetType.FLOAT:
        dt = DType.float32
    elif acc.ptype == ParquetType.DOUBLE:
        dt = DType.float64
    if decode_move:
        return Column[HeapRegion](
            ArrowType.from_dtype(dt),
            SharedAlignedBuffer.from_owned(buf^),
            None,
            None,
            n,
            0,
            0,
        )
    var shared = SharedAlignedBuffer.from_owned(buf^)
    if acc.ptype == ParquetType.INT32:
        return Column.from_primitive[DType.int32](
            decode_plain_int32_zero_copy(shared^, n)
        )
    elif acc.ptype == ParquetType.INT64:
        return Column.from_primitive[DType.int64](
            decode_plain_int64_zero_copy(shared^, n)
        )
    elif acc.ptype == ParquetType.FLOAT:
        return Column.from_primitive[DType.float32](
            decode_plain_float32_zero_copy(shared^, n)
        )
    return Column.from_primitive[DType.float64](
        decode_plain_float64_zero_copy(shared^, n)
    )


# -----------------------------------------------------------------------------
# Definition levels
# -----------------------------------------------------------------------------


def _ensure_def_buf(mut acc: _ChunkAcc):
    """Allocate the chunk's validity bits, zeroed, once."""
    if not acc.def_level_buf:
        var buf = OwnedAlignedBuffer(max((acc.num_values + 7) >> 3, 1))
        buf.zero()
        acc.def_level_buf = buf^


def _append_all_valid(mut acc: _ChunkAcc, n: Int):
    """Mark the page's `n` values valid.

    PERF-CRITICAL: an all-valid page (the common case of an OPTIONAL column
    with no null) sets its bits in bulk, never one by one."""
    var dv = acc.def_level_buf.value().view_mut()
    # SAFETY: the buffer holds `num_values` bits and `def_level_count + n`
    # never passes it (a page declares no more than its chunk has left).
    _set_bits_bulk(dv._unsafe_ptr(), acc.def_level_count, n)
    acc.def_level_count += n


def _append_levels(
    mut acc: _ChunkAcc, levels: List[Int32], decoded: Int, n: Int
) -> Int:
    """Append the validity of the page's `n` values from their decoded
    definition levels (0 null, otherwise valid; a level past `decoded` is
    null) and return how many are valid."""
    ref buf = acc.def_level_buf.value()
    var valid = 0
    for i in range(n):
        if i < decoded and Int(levels[i]) != 0:
            var bit = acc.def_level_count + i
            buf.write_u8_at(
                bit >> 3,
                buf.read_u8_at(bit >> 3) | (UInt8(1) << UInt8(bit & 7)),
            )
            valid += 1
    acc.def_level_count += n
    if valid < n:
        acc.all_pages_all_valid = False
    return valid


def _v1_definition_levels(
    mut acc: _ChunkAcc, body: Span[UInt8, _], n: Int
) raises -> Tuple[Int, Int]:
    """A V1 page's definition levels (`[u32 length][RLE]` at the body's
    start) into the chunk's validity. Returns (present values, level bytes
    consumed)."""
    var r = decode_def_levels_to_bitmap(body, n)
    if r.all_valid:
        _append_all_valid(acc, n)
        return (n, r.bytes_consumed)
    ref buf = acc.def_level_buf.value()
    var valid = 0
    for i in range(n):
        if r.bitmap.test(i):
            var bit = acc.def_level_count + i
            buf.write_u8_at(
                bit >> 3,
                buf.read_u8_at(bit >> 3) | (UInt8(1) << UInt8(bit & 7)),
            )
            valid += 1
    acc.def_level_count += n
    if valid < n:
        acc.all_pages_all_valid = False
    return (valid, r.bytes_consumed)


def _v2_definition_levels(
    mut acc: _ChunkAcc, section: Span[UInt8, _], n: Int
) raises -> Int:
    """A V2 page's definition level section (bare RLE / bit-packed hybrid at
    width 1, no length prefix) into the chunk's validity. Returns the number
    of present values.

    Raises:
        Error if the section ends before `n` levels.
    """
    var levels = List[Int32](length=n, fill=Int32(0))
    var dec = RleDecoder(section, 1)
    var decoded = dec.decode_int32(n, Span(levels))
    if decoded < n:
        raise Error(
            "parquet: corrupt DATA_PAGE_V2: its definition level section"
            " holds "
            + String(decoded)
            + " levels, the page declares "
            + String(n)
        )
    return _append_levels(acc, levels, decoded, n)

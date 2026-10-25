# =============================================================================
# column_decoder_values — a data page's values into the chunk's accumulators
# =============================================================================
#
# `_decode_data_page` is the data page step of `decode_column_pages`
# (column_decoder): it decodes the page body into the context's scratch,
# turns a nullable chunk's definition levels into validity bits
# (column_decoder_pages) and appends the page's present values, by the page's
# own encoding, to the accumulator `_ChunkAcc` keeps for that form
# (column_decoder_state). The module header of column_decoder_pages lists the
# encodings and the dictionary-to-PLAIN switch this follows.
# =============================================================================

from std.sys import size_of

from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.metadata import PageHeader
from komira_parquet_api.types import (
    CompressionCodec,
    Encoding,
    PageType,
    ParquetType,
)

from .byte_stream_split import (
    decode_byte_stream_split_float32,
    decode_byte_stream_split_float32_into,
    decode_byte_stream_split_float64,
    decode_byte_stream_split_float64_into,
)
from .column_decode_context import ColumnDecodeContext
from .column_decoder_pages import (
    _append_all_valid,
    _ensure_def_buf,
    _is_dict_encoding,
    _is_fixed_numeric,
    _v1_definition_levels,
    _v2_definition_levels,
)
from .column_decoder_state import _ChunkAcc, _page_into_scratch
from .column_decoder_strings import _resolve_codes_to_strings
from .delta import DeltaDecoder
from .delta_byte_array import (
    decode_delta_byte_array,
    decode_delta_length_byte_array,
)
from .rle import read_uleb128
from .plain import (
    decode_plain_boolean,
    decode_plain_byte_array,
    decode_plain_int96_to_int64,
)
from .scan_copy_trace import (
    bss_decode_into_enabled,
    incr_bss_decode_copy,
    incr_bss_decode_into,
)


def _decode_data_page(
    mut acc: _ChunkAcc,
    codec: CompressionCodec,
    hdr: PageHeader,
    page: Span[UInt8, _],
    mut decode_ctx: ColumnDecodeContext,
) raises:
    """Decode one DATA_PAGE / DATA_PAGE_V2 into the chunk's accumulators.

    The caller has checked that the page lies inside the chunk and declares
    no more values than the chunk has left.

    Raises:
        Error on a V2 level section that does not fit its page, definition
        levels that do not decode, a value section shorter than its declared
        values, an encoding the page's physical type has no decoder for, or
        a dictionary switch this decoder refuses (see column_decoder_pages).
    """
    var n = hdr.num_values
    var is_v2 = hdr.type == PageType.DATA_PAGE_V2
    var rep_len = hdr.rep_levels_byte_length if is_v2 else 0
    var def_len = hdr.def_levels_byte_length if is_v2 else 0
    if rep_len < 0 or def_len < 0 or rep_len + def_len > len(page):
        raise Error(
            "parquet: corrupt DATA_PAGE_V2 header: level sections of "
            + String(rep_len)
            + " + "
            + String(def_len)
            + " bytes in a page of "
            + String(len(page))
        )
    var levels_total = rep_len + def_len
    var page_codec = codec
    if is_v2 and not hdr.is_compressed:
        page_codec = CompressionCodec.UNCOMPRESSED

    var enc = hdr.encoding
    if _is_dict_encoding(enc) and acc.use_recycled_codes:
        # The reused codes buffer is sized for the whole chunk on the
        # chunk's first dictionary page and overwritten: the previous chunk's
        # codes were already copied into its column.
        if acc.dict_idx_count == 0:
            decode_ctx.ensure_codes(max(acc.num_values * size_of[Int32](), 1))

    decode_ctx.ensure_scratch(1)
    var dlen = _page_into_scratch(
        page_codec,
        page,
        levels_total,
        hdr.uncompressed_page_size,
        decode_ctx.scratch_ref(),
    )
    var body = decode_ctx.scratch_ref().view_ro().into_span()[0:dlen]

    # Definition levels -> validity; `actual` becomes the present values.
    var actual = n
    var vstart = levels_total
    if acc.nullable:
        _ensure_def_buf(acc)
        if is_v2:
            if def_len > 0:
                actual = _v2_definition_levels(
                    acc, body[rep_len:levels_total], n
                )
            else:
                _append_all_valid(acc, n)
        else:
            var r = _v1_definition_levels(acc, body, n)
            actual = r[0]
            vstart = r[1]
    # `vstart <= dlen`: a V2 page's level sections fit its page (the header
    # parser checks), and a V1 level section's length prefix is checked
    # against the page by `validate_level_section_length`.
    var values = body[vstart:dlen]

    if _is_dict_encoding(enc):
        _begin_codes(acc)
        if actual > 0:
            # SAFETY: the codes buffer holds the chunk's `num_values` codes
            # and `dict_idx_count + actual` never passes them (a page
            # declares no more values than its chunk has left); each view
            # borrows its buffer for the call. The reused buffer and the
            # scratch `values` lies in are different fields of the context.
            if acc.use_recycled_codes:
                var dv = decode_ctx.codes_ref().view_mut()
                var dest = Span[Int32, dv.origin](
                    unsafe_ptr=dv._unsafe_ptr().bitcast[Int32]()
                    + acc.dict_idx_count,
                    length=actual,
                )
                acc.dict_decoder.decode_indices_into(values, actual, dest)
            else:
                var dv = acc.dict_idx_buf.value().view_mut()
                var dest = Span[Int32, dv.origin](
                    unsafe_ptr=dv._unsafe_ptr().bitcast[Int32]()
                    + acc.dict_idx_count,
                    length=actual,
                )
                acc.dict_decoder.decode_indices_into(values, actual, dest)
            acc.dict_idx_count += actual
        if acc.string_pages_mode:
            _flush_codes_to_strings(acc)
    elif enc == Encoding.PLAIN:
        _append_plain(acc, values, actual)
    elif enc == Encoding.DELTA_BINARY_PACKED:
        _append_delta(acc, values, actual)
    elif enc == Encoding.BYTE_STREAM_SPLIT:
        _append_byte_stream_split(acc, values, actual)
    elif (
        enc == Encoding.DELTA_LENGTH_BYTE_ARRAY
        or enc == Encoding.DELTA_BYTE_ARRAY
    ):
        if acc.ptype != ParquetType.BYTE_ARRAY:
            raise Error(
                "parquet: "
                + String(enc)
                + " is not an encoding of physical type "
                + String(acc.ptype)
            )
        _flush_codes_to_strings(acc)
        acc.string_pages_mode = True
        if enc == Encoding.DELTA_LENGTH_BYTE_ARRAY:
            acc.string_pages.append(decode_delta_length_byte_array(values, actual))
        else:
            acc.string_pages.append(decode_delta_byte_array(values, actual))
    else:
        raise Error("parquet: unsupported data page encoding " + String(enc))
    acc.total_decoded += n


def _flush_codes_to_strings(mut acc: _ChunkAcc) raises:
    """Resolve the BYTE_ARRAY codes not yet in `string_pages` to a string run
    and append it, so the chunk's runs stay in page order."""
    if (
        acc.ptype == ParquetType.BYTE_ARRAY
        and acc.has_dict
        and acc.dict_idx_count > acc.codes_flushed
    ):
        acc.string_pages.append(
            _resolve_codes_to_strings(
                acc.dict_decoder,
                acc.dict_idx_buf.value(),
                acc.codes_flushed,
                acc.dict_idx_count,
            )
        )
        acc.codes_flushed = acc.dict_idx_count


def _begin_codes(mut acc: _ChunkAcc) raises:
    """Check a dictionary-encoded page may follow the chunk's earlier pages
    and allocate the chunk's own codes buffer on first use."""
    if not acc.has_dict:
        raise Error(
            "parquet: a dictionary-encoded data page with no dictionary page"
            " before it"
        )
    if acc.numeric_fallback:
        raise Error(
            "parquet: a dictionary-encoded data page after a PLAIN page in a"
            " numeric chunk (the dictionary-to-PLAIN switch happens once)"
        )
    if not acc.use_recycled_codes and not acc.dict_idx_buf:
        acc.dict_idx_buf = OwnedAlignedBuffer(
            max(acc.num_values * size_of[Int32](), 1)
        )


def _after_codes(mut acc: _ChunkAcc) raises:
    """A non-dictionary page into the fixed-width accumulator: when codes came
    before it, the chunk switched from dictionary pages, which a numeric
    non-DECIMAL chunk resolves at assembly and any other chunk refuses."""
    if acc.has_dict and acc.dict_idx_count > 0:
        if _is_fixed_numeric(acc.ptype) and not acc.is_decimal:
            acc.numeric_fallback = True
        else:
            raise Error(
                "parquet: a "
                + String(acc.ptype)
                + (" DECIMAL" if acc.is_decimal else "")
                + " chunk that switches from dictionary pages to other pages"
                " is not supported"
            )


def _append_plain(
    mut acc: _ChunkAcc, values: Span[UInt8, _], actual: Int
) raises:
    """A PLAIN page's values at the end of the chunk's values."""
    var ptype = acc.ptype
    var width = acc.plain_elem_size
    if width > 0 and ptype != ParquetType.INT96:
        if actual * width > len(values):
            raise Error(
                "parquet: corrupt data page: PLAIN page declares "
                + String(actual)
                + " values of "
                + String(width)
                + " bytes ("
                + String(actual * width)
                + " bytes) but the page body holds only "
                + String(len(values))
                + " bytes"
            )
    if _is_fixed_numeric(ptype) or ptype == ParquetType.FIXED_LEN_BYTE_ARRAY:
        if ptype == ParquetType.FIXED_LEN_BYTE_ARRAY and acc.type_length <= 0:
            raise Error(
                "parquet: FIXED_LEN_BYTE_ARRAY column is missing type_length"
                " in its schema"
            )
        _after_codes(acc)
        acc.ensure_plain_buf()
        var nbytes = actual * width
        if nbytes > 0:
            acc.plain_buf.value().copy_from_span_at(
                acc.plain_write_offset, values[0:nbytes]
            )
        acc.plain_write_offset += nbytes
        acc.plain_elem_count += actual
    elif ptype == ParquetType.INT96:
        # 12 source bytes per value become 8 (Int64 nanoseconds since the
        # epoch); the decoder checks the 12-byte extent.
        acc.ensure_plain_buf()
        if actual > 0:
            var i96 = decode_plain_int96_to_int64(values, actual)
            acc.plain_buf.value().copy_from_view_at(
                acc.plain_write_offset, i96.view_ro()
            )
        acc.plain_write_offset += actual * width
        acc.plain_elem_count += actual
    elif ptype == ParquetType.BOOLEAN:
        var need = (actual + 7) >> 3
        if need > len(values):
            raise Error(
                "parquet: corrupt data page: PLAIN BOOLEAN page declares "
                + String(actual)
                + " values ("
                + String(need)
                + " packed bytes) but the page body holds only "
                + String(len(values))
                + " bytes"
            )
        if not acc.bool_buf:
            var bb = OwnedAlignedBuffer(max((acc.num_values + 7) >> 3, 1))
            bb.zero()
            acc.bool_buf = bb^
            acc.bool_write_offset = 0
        var page_arr = decode_plain_boolean(values, actual)
        ref dst = acc.bool_buf.value()
        # A page need not start on a byte boundary of the chunk's bits.
        for i in range(actual):
            if page_arr.data.test(i):
                var bit = acc.bool_write_offset + i
                dst.write_u8_at(
                    bit >> 3,
                    dst.read_u8_at(bit >> 3) | (UInt8(1) << UInt8(bit & 7)),
                )
        acc.bool_write_offset += actual
    elif ptype == ParquetType.BYTE_ARRAY:
        _flush_codes_to_strings(acc)
        acc.string_pages_mode = True
        acc.string_pages.append(decode_plain_byte_array(values, actual))
    else:
        raise Error("parquet: unsupported physical type " + String(ptype))


def _append_delta(
    mut acc: _ChunkAcc, values: Span[UInt8, _], actual: Int
) raises:
    """A DELTA_BINARY_PACKED page (INT32, INT64) at the end of the chunk's
    values.

    Raises:
        Error for another physical type, or a page that decodes fewer values
        than it declares.
    """
    var ptype = acc.ptype
    if ptype != ParquetType.INT32 and ptype != ParquetType.INT64:
        raise Error(
            "parquet: DELTA_BINARY_PACKED is not an encoding of physical type "
            + String(ptype)
        )
    # The stream's header declares its value count (block size, miniblock
    # count, total count). The decoder pads a stream that ends early with
    # its last value, so a page whose stream declares fewer values than the
    # page is refused here rather than padded.
    var at = read_uleb128(values, 0)[1]
    at += read_uleb128(values, at)[1]
    var declared = read_uleb128(values, at)
    if actual > 0 and (declared[1] == 0 or declared[0] != actual):
        raise Error(
            "parquet: corrupt DELTA_BINARY_PACKED page: its stream declares "
            + String(declared[0])
            + " values, the page "
            + String(actual)
        )
    _after_codes(acc)
    acc.ensure_plain_buf()
    var dec = DeltaDecoder(values)
    var decoded = 0
    if actual > 0:
        var dv = acc.plain_buf.value().view_mut()
        # SAFETY: the buffer holds the chunk's values and this page's
        # `actual` fit after `plain_elem_count` (a page declares no more
        # than its chunk has left); `dv` borrows the buffer for the call.
        if ptype == ParquetType.INT32:
            var dest = Span[Int32, dv.origin](
                unsafe_ptr=dv._unsafe_ptr().bitcast[Int32]() + acc.plain_elem_count,
                length=actual,
            )
            decoded = dec.decode_int32(actual, dest)
        else:
            var dest = Span[Int64, dv.origin](
                unsafe_ptr=dv._unsafe_ptr().bitcast[Int64]() + acc.plain_elem_count,
                length=actual,
            )
            decoded = dec.decode_int64(actual, dest)
    if decoded != actual:
        raise Error(
            "parquet: corrupt DELTA_BINARY_PACKED page: it decodes "
            + String(decoded)
            + " of its "
            + String(actual)
            + " values"
        )
    acc.plain_write_offset += decoded * acc.plain_elem_size
    acc.plain_elem_count += decoded


def _append_byte_stream_split(
    mut acc: _ChunkAcc, values: Span[UInt8, _], actual: Int
) raises:
    """A BYTE_STREAM_SPLIT page (FLOAT, DOUBLE) at the end of the chunk's
    values: transposed straight into the accumulator when
    `bss_decode_into_enabled` (the default), else decoded to an array and
    copied (the reference arm). Each arm adds to its counter."""
    var ptype = acc.ptype
    if ptype != ParquetType.FLOAT and ptype != ParquetType.DOUBLE:
        raise Error(
            "parquet: BYTE_STREAM_SPLIT is not an encoding of physical type "
            + String(ptype)
        )
    _after_codes(acc)
    acc.ensure_plain_buf()
    var nbytes = actual * acc.plain_elem_size
    ref buf = acc.plain_buf.value()
    if acc.plain_write_offset + nbytes > buf.capacity():
        raise Error(
            "parquet: a BYTE_STREAM_SPLIT page would write past the column"
            " chunk's buffer: offset "
            + String(acc.plain_write_offset)
            + " + "
            + String(nbytes)
            + " > "
            + String(buf.capacity())
        )
    if bss_decode_into_enabled():
        var dst = buf.view_range_mut(acc.plain_write_offset, nbytes)
        if ptype == ParquetType.FLOAT:
            decode_byte_stream_split_float32_into(values, actual, dst)
        else:
            decode_byte_stream_split_float64_into(values, actual, dst)
        incr_bss_decode_into()
    else:
        if ptype == ParquetType.FLOAT:
            var arr = decode_byte_stream_split_float32(values, actual)
            if nbytes > 0:
                buf.copy_from_view_at(acc.plain_write_offset, arr.view_ro())
        else:
            var arr = decode_byte_stream_split_float64(values, actual)
            if nbytes > 0:
                buf.copy_from_view_at(acc.plain_write_offset, arr.view_ro())
        incr_bss_decode_copy()
    acc.plain_write_offset += nbytes
    acc.plain_elem_count += actual

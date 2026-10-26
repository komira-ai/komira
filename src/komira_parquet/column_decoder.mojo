# =============================================================================
# column_decoder — a flat column chunk's pages into one Arrow column
# =============================================================================
#
# `decode_column_pages` decodes every page of a column chunk (the bytes from
# its first page header to the end of its last page) into one Column of the
# chunk's declared value count, nulls included. It is the whole-chunk decode
# of the read path: the caller gives the chunk's physical type, codec, value
# count, nullability and schema facts (type length, converted type, DECIMAL
# scale and precision), and a `ColumnDecodeContext` whose buffers are reused
# across the chunks one worker decodes.
#
# The work is split by step:
#
#   | module                    | step                                       |
#   |---------------------------|--------------------------------------------|
#   | column_decoder            | the page walk and its checks (this file)   |
#   | column_decoder_state      | `_ChunkAcc`, the page CRC, page bodies     |
#   | column_decoder_pages      | dictionary pages, definition levels, the   |
#   |                           | single PLAIN page moved into the column    |
#   | column_decoder_values     | a data page's values, by encoding          |
#   | column_decoder_assemble   | the column of a chunk of dictionary codes  |
#   | column_decoder_finish     | the column of any other chunk              |
#   | column_decoder_strings    | the array builders they share              |
#
# Every size and count the file declares is checked before it is used: the
# chunk's value count before any buffer is sized from it, each page header's
# sizes against the bytes left in the chunk, each data page's value count
# against the values the chunk has left (so every accumulator append stays
# inside its buffer), and each page's CRC, when its header carries one,
# against the page bytes (the standard CRC-32 the format specifies).
#
# Choices are arguments, never environment reads: `preserve_dict` (a string
# dictionary chunk stays a dictionary column), `count_fuse_enabled` (an
# INT32 / INT64 dictionary chunk is handed back as codes for the fused
# count), `decode_move` (a fixed-width buffer becomes the column with no copy;
# False selects the copying reference), and the context's
# `numeric_dict_vec_enabled` and `recycle_codes_enabled`.
# =============================================================================

from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.types import (
    CONVERTED_TYPE_DECIMAL,
    CompressionCodec,
    PageType,
    ParquetType,
)

from .column_decode_context import ColumnDecodeContext
from .column_decoder_assemble import (
    NumericDictCodes,
    NumericDictCodesHolder,
    _assemble,
)
from .column_decoder_pages import (
    _decode_dictionary_page,
    _decode_single_plain_page,
    _single_plain_page_eligible,
)
from .column_decoder_state import _ChunkAcc, _check_page_crc
from .column_decoder_values import _decode_data_page
from .page_header_parser import _parse_page_header

# The widest decoded value is 16 bytes (Decimal128), so a value count up to
# this bound sizes every accumulator without overflowing an Int.
comptime _MAX_CHUNK_VALUES: Int = 0x7FFF_FFFF_FFFF_FFFF // 16


def decode_column_pages(
    data: Span[UInt8, _],
    ptype: ParquetType,
    codec: CompressionCodec,
    num_values: Int,
    nullable: Bool,
    count_fuse_enabled: Bool,
    mut count_fuse_out: NumericDictCodesHolder,
    mut decode_ctx: ColumnDecodeContext,
    type_length: Int = 0,
    converted_type: Int = -1,
    scale: Int = 0,
    preserve_dict: Bool = True,
    precision: Int = 0,
    decode_move: Bool = True,
) raises -> Column[HeapRegion]:
    """Decode a flat column chunk's pages into one Column.

    Args:
        data: The column chunk: page headers and page bodies.
        ptype: The column's physical type.
        codec: The chunk's compression codec.
        num_values: The chunk's value count, nulls included
            (ColumnMetaData.num_values).
        nullable: The column is OPTIONAL: its pages carry definition levels.
        count_fuse_enabled: Hand an INT32 / INT64 non-DECIMAL dictionary
            chunk back as `NumericDictCodes` in `count_fuse_out`, with an
            empty INT64 placeholder as the column. A chunk of another shape
            decodes as usual and leaves `count_fuse_out` empty.
        count_fuse_out: Receives the codes when the fused count fires.
        decode_ctx: Reusable decode buffers and two decode choices; a fresh
            `ColumnDecodeContext()` decodes the same column.
        type_length: The byte width of a FIXED_LEN_BYTE_ARRAY column.
        converted_type: The schema's ConvertedType, or -1. DECIMAL (5) on
            INT32, INT64 or FIXED_LEN_BYTE_ARRAY gives a Decimal128 column.
        scale: The DECIMAL scale.
        preserve_dict: A BYTE_ARRAY dictionary chunk becomes a dictionary
            column (else dense strings); with the context's
            `numeric_dict_vec_enabled`, a non-null INT32 / INT64 one becomes
            a numeric dictionary column.
        precision: The DECIMAL precision, or 0 to take the widest the
            physical width holds.
        decode_move: Move a fixed-width chunk's decoded buffer into the
            column; False copies it (the reference the move is checked
            against).

    Returns:
        A Column of `num_values` rows (fewer only for a chunk whose pages
        stop early), nulls in its validity.

    Raises:
        Error on an out-of-range value count, a page header that does not
        parse or claims more bytes or values than the chunk has, a CRC
        mismatch, and anything the page and value decoders refuse.
    """
    if num_values < 0 or num_values > _MAX_CHUNK_VALUES:
        raise Error(
            "parquet: corrupt column metadata: num_values "
            + String(num_values)
            + " is out of range [0, "
            + String(_MAX_CHUNK_VALUES)
            + "]"
        )
    var is_decimal = converted_type == CONVERTED_TYPE_DECIMAL and (
        ptype == ParquetType.FIXED_LEN_BYTE_ARRAY
        or ptype == ParquetType.INT32
        or ptype == ParquetType.INT64
    )
    var use_recycled_codes = (
        decode_ctx.recycle_codes_enabled
        and decode_ctx.numeric_dict_vec_enabled
        and preserve_dict
        and not is_decimal
        and (ptype == ParquetType.INT32 or ptype == ParquetType.INT64)
    )
    var acc = _ChunkAcc(
        ptype, num_values, nullable, type_length, is_decimal, use_recycled_codes
    )
    var data_len = len(data)
    var offset = 0
    while offset < data_len and acc.total_decoded < num_values:
        var hdr_res = _parse_page_header(data[offset:data_len])
        offset += hdr_res.bytes_consumed
        ref hdr = hdr_res.header
        # `_parse_page_header` has refused negative page sizes and value
        # counts, and level sections larger than the page.
        var cps = hdr.compressed_page_size
        if cps > data_len - offset:
            raise Error(
                "parquet: corrupt page header: compressed_page_size "
                + String(cps)
                + " exceeds remaining column-chunk bytes "
                + String(data_len - offset)
            )
        var page = data[offset : offset + cps]
        offset += cps

        if hdr.type == PageType.DICTIONARY_PAGE:
            if hdr.crc:
                _check_page_crc(page, hdr.crc.value())
            _decode_dictionary_page(acc, codec, hdr, page, decode_ctx)
        elif (
            hdr.type == PageType.DATA_PAGE
            or hdr.type == PageType.DATA_PAGE_V2
        ):
            var page_nv = hdr.num_values
            if page_nv > num_values - acc.total_decoded:
                raise Error(
                    "parquet: corrupt data page header: page declares "
                    + String(page_nv)
                    + " values but only "
                    + String(num_values - acc.total_decoded)
                    + " of the column chunk's "
                    + String(num_values)
                    + " remain undecoded"
                )
            if hdr.crc:
                _check_page_crc(page, hdr.crc.value())
            if _single_plain_page_eligible(acc, hdr):
                return _decode_single_plain_page(
                    acc, codec, hdr, page, decode_move
                )
            _decode_data_page(acc, codec, hdr, page, decode_ctx)
        # Any other page (INDEX_PAGE) is skipped.

    return _assemble(
        acc,
        decode_ctx,
        count_fuse_enabled,
        count_fuse_out,
        converted_type,
        scale,
        precision,
        preserve_dict,
        decode_move,
    )

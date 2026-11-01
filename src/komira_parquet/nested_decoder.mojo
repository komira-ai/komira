# =============================================================================
# nested_decoder — decode a leaf column chunk with its definition and
#                  repetition levels
# =============================================================================
#
# A nested column (struct, list, map) stores, for each leaf, its definition
# levels (how many optional ancestors are present), its repetition levels
# (where lists start) and only the leaf values that are present. The flat
# column decoder folds levels 0 / 1 into a validity bitmap; this decoder keeps
# the levels as Int32 lists at any maximum level and returns them with the
# present values (`DecodedLeaf`), for the Dremel rebuild in `nested`
# (`reconstruct_struct_column`, `reconstruct_list_column`,
# `reconstruct_map_column`).
#
# Pages: DICTIONARY_PAGE (INT32, INT64, FLOAT, DOUBLE, BYTE_ARRAY), and V1
# DATA_PAGE / DATA_PAGE_V2 of PLAIN or dictionary-encoded values
# (RLE_DICTIONARY, PLAIN_DICTIONARY), each page decoded by its own encoding.
# A BYTE_ARRAY chunk is a dictionary column when every data page is
# dictionary-encoded, else a string column; one that mixes the two is
# refused. Other pages (INDEX_PAGE) are skipped.
#
# Every count and size the file declares is checked against what the chunk or
# the decoded page holds before it is used.
# =============================================================================


from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import (
    CompressionCodec,
    Encoding,
    PageType,
    ParquetType,
)
from komira_parquet_codec.compression import decompress

from .dictionary import DictionaryDecoder
from .nested import DecodedLeaf
from .page_header_parser import _parse_page_header
from .plain import (
    decode_plain_boolean,
    decode_plain_float32,
    decode_plain_float64,
    decode_plain_int32,
    decode_plain_int64,
)
from .rle import RleDecoder, bit_width_for_max_level, decode_levels


struct _Values(Movable):
    """The present values of a leaf, accumulated across pages."""

    var ints32: List[Int32]
    var ints64: List[Int64]
    var floats32: List[Float32]
    var floats64: List[Float64]
    var bools: List[Bool]
    var str_offsets: List[Int32]
    var str_data: List[UInt8]
    var dict_codes: List[Int32]
    var plain_strings: Bool
    var dict_strings: Bool

    def __init__(out self):
        self.ints32 = List[Int32]()
        self.ints64 = List[Int64]()
        self.floats32 = List[Float32]()
        self.floats64 = List[Float64]()
        self.bools = List[Bool]()
        self.str_offsets = [Int32(0)]
        self.str_data = List[UInt8]()
        self.dict_codes = List[Int32]()
        self.plain_strings = False
        self.dict_strings = False


def decode_column_with_levels(
    data: Span[UInt8, _],
    ptype: ParquetType,
    codec: CompressionCodec,
    num_values: Int,
    max_def_level: Int,
    max_rep_level: Int,
) raises -> DecodedLeaf:
    """Decode a leaf column chunk into its present values and its levels.

    Args:
        data: The column chunk's bytes (page headers and bodies).
        ptype: The leaf's physical type.
        codec: The chunk's compression codec.
        num_values: The chunk's value count (levels, nulls included).
        max_def_level: The leaf's maximum definition level.
        max_rep_level: The leaf's maximum repetition level.

    Returns:
        A `DecodedLeaf`: a column of the values whose definition level is
        `max_def_level`, in order, plus one definition level per value and,
        when `max_rep_level > 0`, one repetition level per value. A chunk
        with no present value gives an empty NULL column.

    Raises:
        Error on a negative `num_values`, a page that runs past the chunk,
        declares more values than the chunk has left or more dictionary
        entries than it holds, a level or value section that does not fit
        its page, an unsupported type, or a BYTE_ARRAY chunk that mixes
        dictionary and PLAIN data pages.
    """
    if num_values < 0:
        raise Error(
            "parquet: corrupt column chunk: negative num_values "
            + String(num_values)
        )
    var data_len = len(data)
    var dict_decoder = DictionaryDecoder()
    var has_dict = False
    var def_bit_width = bit_width_for_max_level(max_def_level)
    var rep_bit_width = bit_width_for_max_level(max_rep_level)
    var all_def = List[Int32](capacity=num_values)
    var all_rep = List[Int32](capacity=num_values)
    var vals = _Values()
    # Level scratch sized at the chunk's count; every page is checked to
    # declare no more than the chunk has left, so a page's levels fit.
    var def_tmp = List[Int32](length=num_values, fill=Int32(0))
    var rep_tmp = List[Int32](length=num_values, fill=Int32(0))
    var total_decoded = 0
    var offset = 0

    while offset < data_len and total_decoded < num_values:
        var hdr_res = _parse_page_header(data[offset:data_len])
        offset += hdr_res.bytes_consumed
        ref hdr = hdr_res.header
        var page_size = hdr.compressed_page_size
        if page_size < 0 or page_size > data_len - offset:
            raise Error(
                "parquet: corrupt page header: compressed_page_size "
                + String(page_size)
                + " exceeds remaining column-chunk bytes "
                + String(data_len - offset)
            )
        var page = data[offset : offset + page_size]
        offset += page_size

        if hdr.type == PageType.DICTIONARY_PAGE:
            var dict_buf = _page_body(codec, page, hdr.uncompressed_page_size, 0)
            _init_dict(dict_decoder, ptype, dict_buf, hdr.num_values)
            has_dict = True
            continue
        if hdr.type != PageType.DATA_PAGE and hdr.type != PageType.DATA_PAGE_V2:
            continue

        var page_nv = hdr.num_values
        if page_nv < 0 or page_nv > num_values - total_decoded:
            raise Error(
                "parquet: corrupt data page header: page declares "
                + String(page_nv)
                + " values but only "
                + String(num_values - total_decoded)
                + " of the column chunk's "
                + String(num_values)
                + " remain undecoded"
            )
        var is_v2 = hdr.type == PageType.DATA_PAGE_V2
        var rep_len = hdr.rep_levels_byte_length if is_v2 else 0
        var def_len = hdr.def_levels_byte_length if is_v2 else 0
        # `_parse_page_header` has checked that the level sections are not
        # negative and fit the page (compressed and decoded).
        var page_codec = codec
        if is_v2 and not hdr.is_compressed:
            page_codec = CompressionCodec.UNCOMPRESSED
        var body = _page_body(
            page_codec, page, hdr.uncompressed_page_size, rep_len + def_len
        )
        var all = body.view_ro().into_span()
        var vstart = 0

        var page_rep = 0
        if max_rep_level > 0:
            var rep_out = Span(rep_tmp)[0:page_nv]
            if is_v2:
                if rep_len > 0:
                    var rd = RleDecoder(all[0:rep_len], rep_bit_width)
                    page_rep = rd.decode_int32(page_nv, rep_out)
            else:
                var r = decode_levels(all, page_nv, rep_bit_width, rep_out)
                page_rep = r[0]
                vstart = r[1]
        var page_def = 0
        if max_def_level > 0:
            var def_out = Span(def_tmp)[0:page_nv]
            if is_v2:
                if def_len > 0:
                    var dd = RleDecoder(
                        all[rep_len : rep_len + def_len], def_bit_width
                    )
                    page_def = dd.decode_int32(page_nv, def_out)
                else:
                    for i in range(page_nv):
                        def_tmp[i] = Int32(max_def_level)
                    page_def = page_nv
            else:
                var r = decode_levels(
                    all[vstart : len(all)], page_nv, def_bit_width, def_out
                )
                page_def = r[0]
                vstart += r[1]
        else:
            for i in range(page_nv):
                def_tmp[i] = Int32(0)
            page_def = page_nv
        if is_v2:
            vstart = rep_len + def_len

        var present = 0
        for i in range(page_def):
            if Int(def_tmp[i]) == max_def_level:
                present += 1
        for i in range(page_nv):
            all_def.append(def_tmp[i] if i < page_def else Int32(0))
            if max_rep_level > 0:
                all_rep.append(rep_tmp[i] if i < page_rep else Int32(0))

        var values = all[vstart : len(all)]
        var dict_page = (
            hdr.encoding == Encoding.RLE_DICTIONARY
            or hdr.encoding == Encoding.PLAIN_DICTIONARY
        )
        if dict_page:
            if not has_dict:
                raise Error(
                    "parquet: a dictionary-encoded data page with no"
                    " dictionary page before it"
                )
            _append_dict_values(dict_decoder, ptype, values, present, vals)
        elif hdr.encoding == Encoding.PLAIN:
            _append_plain_values(ptype, values, present, vals)
        else:
            raise Error(
                "nested_decoder: unsupported data page encoding "
                + String(hdr.encoding)
            )
        if vals.plain_strings and vals.dict_strings:
            raise Error(
                "nested_decoder: a BYTE_ARRAY chunk that mixes dictionary"
                " and PLAIN data pages is not supported"
            )
        total_decoded += page_nv

    return DecodedLeaf(
        column=_build_column(ptype, dict_decoder, vals^),
        def_levels=all_def^,
        rep_levels=all_rep^,
        max_def_level=max_def_level,
        max_rep_level=max_rep_level,
    )


def _page_body(
    codec: CompressionCodec,
    page: Span[UInt8, _],
    uncompressed_size: Int,
    raw_prefix: Int,
) raises -> OwnedAlignedBuffer:
    """A page's decoded body. The first `raw_prefix` bytes (a V2 page's level
    sections) are never compressed and are copied as they are; the rest is
    decompressed to `uncompressed_size - raw_prefix` bytes, or copied when
    `codec` is UNCOMPRESSED."""
    var n = len(page)
    if codec == CompressionCodec.UNCOMPRESSED:
        var buf = OwnedAlignedBuffer(max(n, 1))
        buf.copy_from_span_at(0, page)
        buf.set_length(Int64(n))
        return buf^
    var values_out = uncompressed_size - raw_prefix
    if values_out < 0:
        raise Error(
            "parquet: corrupt page header: uncompressed_page_size "
            + String(uncompressed_size)
            + " is smaller than its level sections"
        )
    var buf = OwnedAlignedBuffer(max(raw_prefix + values_out, 1))
    buf.copy_from_span_at(0, page[0:raw_prefix])
    var written = 0
    if n > raw_prefix:
        var outspan = buf.into_span_capacity()
        written = decompress(
            codec, page[raw_prefix:n], outspan[raw_prefix : raw_prefix + values_out]
        )
    buf.set_length(Int64(raw_prefix + written))
    return buf^


def _init_dict(
    mut dec: DictionaryDecoder,
    ptype: ParquetType,
    buf: OwnedAlignedBuffer,
    dict_nv: Int,
) raises:
    """Load a PLAIN dictionary page, refusing a count the page cannot hold."""
    var page = buf.view_ro().into_span()
    var width = 0
    if ptype == ParquetType.INT32 or ptype == ParquetType.FLOAT:
        width = 4
    elif ptype == ParquetType.INT64 or ptype == ParquetType.DOUBLE:
        width = 8
    if dict_nv < 0 or (width > 0 and dict_nv * width > len(page)):
        raise Error(
            "parquet: corrupt dictionary page: num_values "
            + String(dict_nv)
            + " * width "
            + String(width)
            + " exceeds decoded dictionary bytes "
            + String(len(page))
        )
    if ptype == ParquetType.INT32:
        dec.init_dict_int32(page, dict_nv)
    elif ptype == ParquetType.INT64:
        dec.init_dict_int64(page, dict_nv)
    elif ptype == ParquetType.FLOAT:
        dec.init_dict_float32(page, dict_nv)
    elif ptype == ParquetType.DOUBLE:
        dec.init_dict_float64(page, dict_nv)
    elif ptype == ParquetType.BYTE_ARRAY:
        dec.init_dict_byte_array(page, dict_nv)
    else:
        raise Error("nested_decoder: unsupported dictionary type " + String(ptype))


def _append_dict_values(
    dec: DictionaryDecoder,
    ptype: ParquetType,
    values: Span[UInt8, _],
    present: Int,
    mut vals: _Values,
) raises:
    """Decode a page's `present` dictionary codes (bit-width byte first) and
    append their values; BYTE_ARRAY codes are kept and resolved at the end."""
    if present == 0:
        return
    if len(values) == 0:
        raise Error(
            "parquet: a dictionary-encoded page with "
            + String(present)
            + " present values and no codes"
        )
    var idx = dec.decode_indices(values, present)
    if ptype == ParquetType.INT32:
        var r = dec.resolve_int32(idx)
        for i in range(r.length):
            vals.ints32.append(r.get_typed[Int32](i))
    elif ptype == ParquetType.INT64:
        var r = dec.resolve_int64(idx)
        for i in range(r.length):
            vals.ints64.append(r.get_typed[Int64](i))
    elif ptype == ParquetType.FLOAT:
        var r = dec.resolve_float32(idx)
        for i in range(r.length):
            vals.floats32.append(r.get_typed[Float32](i))
    elif ptype == ParquetType.DOUBLE:
        var r = dec.resolve_float64(idx)
        for i in range(r.length):
            vals.floats64.append(r.get_typed[Float64](i))
    else:
        # BYTE_ARRAY: `_init_dict` admits no other type, so the dictionary
        # page that came first was one of the five above.
        vals.dict_strings = True
        for i in range(idx.length):
            vals.dict_codes.append(idx.get_typed[Int32](i))


def _append_plain_values(
    ptype: ParquetType,
    values: Span[UInt8, _],
    present: Int,
    mut vals: _Values,
) raises:
    """Decode a page's `present` PLAIN values and append them."""
    if ptype == ParquetType.INT32:
        var a = decode_plain_int32(values, present)
        for i in range(a.length):
            vals.ints32.append(a.get_typed[Int32](i))
    elif ptype == ParquetType.INT64:
        var a = decode_plain_int64(values, present)
        for i in range(a.length):
            vals.ints64.append(a.get_typed[Int64](i))
    elif ptype == ParquetType.FLOAT:
        var a = decode_plain_float32(values, present)
        for i in range(a.length):
            vals.floats32.append(a.get_typed[Float32](i))
    elif ptype == ParquetType.DOUBLE:
        var a = decode_plain_float64(values, present)
        for i in range(a.length):
            vals.floats64.append(a.get_typed[Float64](i))
    elif ptype == ParquetType.BOOLEAN:
        var a = decode_plain_boolean(values, present)
        for i in range(a.length):
            vals.bools.append(a.data.test(i))
    elif ptype == ParquetType.BYTE_ARRAY:
        vals.plain_strings = True
        _append_plain_byte_array(values, present, vals.str_offsets, vals.str_data)
    else:
        raise Error("nested_decoder: unsupported plain type " + String(ptype))


def _append_plain_byte_array(
    values: Span[UInt8, _],
    n: Int,
    mut offsets: List[Int32],
    mut data: List[UInt8],
) raises:
    """Append `n` PLAIN BYTE_ARRAY values (`[u32 LE length][bytes]` each)."""
    var pos = 0
    var end = len(values)
    for k in range(n):
        if end - pos < 4:
            raise Error(
                "parquet: PLAIN BYTE_ARRAY value " + String(k)
                + " has no room for its length prefix"
            )
        var slen = (
            Int(values[pos])
            | (Int(values[pos + 1]) << 8)
            | (Int(values[pos + 2]) << 16)
            | (Int(values[pos + 3]) << 24)
        )
        pos += 4
        if slen > end - pos or len(data) + slen > Int(Int32.MAX):
            raise Error(
                "parquet: PLAIN BYTE_ARRAY value " + String(k) + " of "
                + String(slen) + " bytes runs past its page"
            )
        data.extend(values[pos : pos + slen])
        pos += slen
        offsets.append(Int32(len(data)))


def _build_column(
    ptype: ParquetType, dec: DictionaryDecoder, var vals: _Values
) raises -> Column[HeapRegion]:
    """The column of a leaf's present values (an empty NULL column when
    there are none)."""
    if ptype == ParquetType.INT32 and len(vals.ints32) > 0:
        return Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(vals.ints32)
        )
    if ptype == ParquetType.INT64 and len(vals.ints64) > 0:
        return Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(vals.ints64)
        )
    if ptype == ParquetType.FLOAT and len(vals.floats32) > 0:
        return Column.from_primitive[DType.float32](
            PrimitiveArray[DType.float32].from_list(vals.floats32)
        )
    if ptype == ParquetType.DOUBLE and len(vals.floats64) > 0:
        return Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(vals.floats64)
        )
    if ptype == ParquetType.BOOLEAN and len(vals.bools) > 0:
        var bm = Bitmap.create(len(vals.bools))
        for i in range(len(vals.bools)):
            if vals.bools[i]:
                bm.set(i)
        return Column.from_boolean(BooleanArray.from_bitmap(bm^))
    if ptype == ParquetType.BYTE_ARRAY and len(vals.dict_codes) > 0:
        var idx = PrimitiveArray[DType.int32].from_list(vals.dict_codes)
        return Column.from_dictionary(dec.resolve_as_string_dict(idx))
    if ptype == ParquetType.BYTE_ARRAY and len(vals.str_offsets) > 1:
        return Column.from_string(
            StringArray.from_buffers(vals.str_offsets, vals.str_data, None, 0)
        )
    return Column[HeapRegion]()

# Direct tests of the page and value helpers behind `decode_column_pages`
# that the page header parser keeps a whole-chunk decode from reaching: a
# header whose level sections do not fit its page, a dictionary page with a
# negative entry count, a compressed page whose declared decoded size is
# smaller than its level bytes, a BYTE_STREAM_SPLIT page larger than the
# chunk's buffer, and the dense rebuild of a dictionary column whose codes
# carry nulls.
#
# Headers are Thrift Compact page headers (parquet.thrift), parsed with
# `_parse_page_header` and then given the inconsistency under test.
from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import CompressionCodec, ParquetType

from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.column_decoder_pages import _decode_dictionary_page
from komira_parquet.column_decoder_state import _ChunkAcc, _page_into_scratch
from komira_parquet.column_decoder_strings import (
    _dict_to_string_array,
    _resolve_codes_to_strings,
)
from komira_parquet.column_decoder_values import (
    _append_byte_stream_split,
    _decode_data_page,
)
from komira_parquet.dictionary import DictionaryDecoder
from komira_parquet.page_header_parser import _parse_page_header

comptime _PLAIN = 0


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _uleb(mut out: List[UInt8], v: Int):
    var x = v
    while True:
        var b = x & 0x7F
        x >>= 7
        if x != 0:
            out.append(UInt8(b | 0x80))
        else:
            out.append(UInt8(b))
            return


def _i32(mut out: List[UInt8], v: Int):
    out.append(UInt8((1 << 4) | 5))
    _uleb(out, (v << 1) ^ (v >> 63))


def _header(
    page_type: Int,
    uncomp: Int,
    comp: Int,
    nv: Int,
    enc: Int,
    def_len: Int = 0,
    rep_len: Int = 0,
    is_compressed: Bool = True,
) -> List[UInt8]:
    var h = List[UInt8]()
    _i32(h, page_type)
    _i32(h, uncomp)
    _i32(h, comp)
    if page_type == 0:
        h.append(UInt8((2 << 4) | 12))
        _i32(h, nv)
        _i32(h, enc)
        _i32(h, 3)
        _i32(h, 3)
        h.append(UInt8(0))
    elif page_type == 2:
        h.append(UInt8((4 << 4) | 12))
        _i32(h, nv)
        _i32(h, enc)
        h.append(UInt8(0))
    elif page_type == 3:
        h.append(UInt8((5 << 4) | 12))
        _i32(h, nv)
        _i32(h, 0)
        _i32(h, nv)
        _i32(h, enc)
        _i32(h, def_len)
        _i32(h, rep_len)
        h.append(UInt8((1 << 4) | (1 if is_compressed else 2)))
        h.append(UInt8(0))
    h.append(UInt8(0))
    return h^


def _ints(values: List[Int], width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, values[i], width)
    return out^



def _strings(values: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, values[i].byte_length(), 4)
        out.extend(Span(values[i].as_bytes()))
    return out^


def test_v2_level_sections_longer_than_their_page_are_refused() raises:
    # A V2 page of 4 bytes whose header (as parsed, it was consistent) is
    # then given a definition section of 99 bytes, and a negative repetition
    # section.
    var chunk = _header(3, 4, 4, 2, _PLAIN, 1, 0)
    var header_len = len(chunk)
    chunk.extend(List[UInt8](length=4, fill=UInt8(0)))
    var res = _parse_page_header(Span(chunk))
    assert_equal(res.bytes_consumed, header_len)
    var page = Span(chunk)[header_len:]
    var ctx = ColumnDecodeContext()

    var long_defs = res.header.copy()
    long_defs.def_levels_byte_length = 99
    var acc = _ChunkAcc(ParquetType.INT32, 2, True, 0, False, False)
    with assert_raises(contains="level sections of 0 + 99 bytes in a page of 4"):
        _decode_data_page(acc, CompressionCodec.UNCOMPRESSED, long_defs, page, ctx)

    var negative_reps = res.header.copy()
    negative_reps.rep_levels_byte_length = -1
    var acc2 = _ChunkAcc(ParquetType.INT32, 2, True, 0, False, False)
    with assert_raises(contains="level sections of -1 + 1 bytes in a page of 4"):
        _decode_data_page(acc2, CompressionCodec.UNCOMPRESSED, negative_reps, page, ctx)


def test_a_dictionary_page_with_a_negative_entry_count_is_refused() raises:
    var chunk = _header(2, 4, 4, 1, _PLAIN)
    var header_len = len(chunk)
    chunk.extend(_ints([7], 4))
    var res = _parse_page_header(Span(chunk))
    var hdr = res.header.copy()
    hdr.num_values = -1
    var acc = _ChunkAcc(ParquetType.INT32, 1, False, 0, False, False)
    var ctx = ColumnDecodeContext()
    with assert_raises(contains="corrupt dictionary page: negative num_values -1"):
        _decode_dictionary_page(acc, CompressionCodec.UNCOMPRESSED, hdr, Span(chunk)[header_len:], ctx)


def test_a_compressed_page_smaller_than_its_level_bytes_is_refused() raises:
    var page = List[UInt8](length=8, fill=UInt8(1))
    var scratch = OwnedAlignedBuffer(1)
    with assert_raises(contains="uncompressed_page_size 3 is smaller than the page's 5 level bytes"):
        _ = _page_into_scratch(CompressionCodec.SNAPPY, Span(page), 5, 3, scratch)


def test_a_byte_stream_split_page_larger_than_the_chunk_is_refused() raises:
    # The chunk holds 2 doubles; the page declares 1000.
    var acc = _ChunkAcc(ParquetType.DOUBLE, 2, False, 0, False, False)
    var values = List[UInt8](length=16, fill=UInt8(0))
    with assert_raises(contains="would write past the column chunk's buffer: offset 0 + 8000 >"):
        _append_byte_stream_split(acc, Span(values), 1000)


def _dictionary(values: List[String]) raises -> DictionaryDecoder:
    var page = _strings(values)
    var d = DictionaryDecoder()
    d.init_dict_byte_array(Span(page), len(values))
    return d^


def test_a_dictionary_column_with_null_codes_is_rebuilt_dense_with_empty_null_slots() raises:
    var d = _dictionary(["", "a", "hello"])
    var idx = PrimitiveArray[DType.int32].allocate_nullable(4)
    idx.set(0, Int32(2))
    idx.set(1, Int32(0))
    idx.set(2, Int32(1))
    idx.set(3, Int32(0))
    idx.validity.value().clear(1)
    idx.null_count = 1
    var dense = _dict_to_string_array(d.resolve_as_string_dict(idx))
    assert_equal(len(dense), 4)
    assert_equal(dense.null_count, 1)
    assert_true(dense.is_null(1))
    assert_true(not dense.is_null(0))
    assert_equal(dense.get(0), "hello")
    assert_equal(dense.get_length(1), 0)
    assert_equal(dense.get(2), "a")
    assert_equal(dense.get(3), "")


def test_an_empty_code_range_resolves_to_an_empty_string_array() raises:
    var d = _dictionary(["x", "y"])
    var codes = OwnedAlignedBuffer(16)
    var out = _resolve_codes_to_strings(d, codes, 3, 3)
    assert_equal(len(out), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

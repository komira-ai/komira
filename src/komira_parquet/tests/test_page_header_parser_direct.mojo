# =============================================================================
# _parse_page_header: every PageHeader field, the three page header structs,
# and every refusal of the validation at construction.
#
# Headers are written here from parquet.thrift's PageHeader: 1 type, 2
# uncompressed_page_size, 3 compressed_page_size, 4 crc, 5 data_page_header,
# 7 dictionary_page_header, 8 data_page_header_v2. The CRC is checked as the
# unsigned 32-bit value of its i32 (a CRC with the top bit set is a negative
# i32 on the wire).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_parquet_api.types import Encoding, PageType
from komira_parquet.page_header_parser import PageHeaderResult, _parse_page_header


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _i32(mut out: List[UInt8], delta: Int, v: Int):
    out.append(UInt8((delta << 4) | 5))
    _zz(out, v)


def _sizes(mut out: List[UInt8], page_type: Int, uncompressed: Int, compressed: Int):
    _i32(out, 1, page_type)
    _i32(out, 1, uncompressed)
    _i32(out, 1, compressed)


def _v2(
    page_type: Int = 3,
    uncompressed: Int = 100,
    compressed: Int = 80,
    num_values: Int = 10,
    num_nulls: Int = 2,
    num_rows: Int = 10,
    def_len: Int = 4,
    rep_len: Int = 3,
) -> List[UInt8]:
    var out = List[UInt8]()
    _sizes(out, page_type, uncompressed, compressed)
    out.append(UInt8((5 << 4) | 12))  # field 8: DataPageHeaderV2
    _i32(out, 1, num_values)
    _i32(out, 1, num_nulls)
    _i32(out, 1, num_rows)
    _i32(out, 1, 0)  # encoding PLAIN
    _i32(out, 1, def_len)
    _i32(out, 1, rep_len)
    out.append(0x00)
    out.append(0x00)
    return out^


def _refused(data: List[UInt8], needle: String) -> Bool:
    try:
        _ = _parse_page_header(Span(data))
    except e:
        return String(e).find(needle) >= 0
    return False


def test_v1_data_page_with_crc_and_unknown_fields() raises:
    var out = List[UInt8]()
    _sizes(out, 0, 100, 80)
    _i32(out, 1, -2)  # field 4: crc, 0xFFFFFFFE as an i32
    out.append(UInt8((1 << 4) | 12))  # field 5: DataPageHeader
    _i32(out, 1, 42)  # num_values
    _i32(out, 1, 3)  # encoding RLE
    _i32(out, 1, 0)  # field 3 (definition_level_encoding): skipped
    out.append(0x00)
    out.append(UInt8((1 << 4) | 12))  # field 6: index page header, skipped
    out.append(0x00)
    out.append(0x00)
    out.append(0xEE)  # past the STOP: not consumed
    var r = _parse_page_header(Span(out))
    var h = r.header.copy()
    assert_equal(r.bytes_consumed, len(out) - 1)
    assert_equal(Int(h.type.value), Int(PageType.DATA_PAGE.value))
    assert_equal(h.uncompressed_page_size, 100)
    assert_equal(h.compressed_page_size, 80)
    assert_equal(h.num_values, 42)
    assert_equal(Int(h.encoding.value), Int(Encoding.RLE.value))
    assert_true(Bool(h.crc))
    assert_equal(h.crc.value(), UInt32(0xFFFFFFFE))
    assert_equal(h.num_nulls, 0)
    assert_true(h.is_compressed)


def test_a_header_without_crc_has_none() raises:
    var out = List[UInt8]()
    _sizes(out, 0, 10, 10)
    out.append(0x00)
    var h = _parse_page_header(Span(out)).header.copy()
    assert_false(Bool(h.crc))
    assert_equal(h.num_values, 0)


def test_dictionary_page_header() raises:
    var out = List[UInt8]()
    _sizes(out, 2, 64, 64)
    out.append(UInt8((4 << 4) | 12))  # field 7
    _i32(out, 1, 16)  # num_values
    _i32(out, 1, 0)  # encoding PLAIN
    out.append(UInt8((1 << 4) | 1))  # field 3, is_sorted: skipped
    out.append(0x00)
    out.append(0x00)
    var h = _parse_page_header(Span(out)).header.copy()
    assert_equal(Int(h.type.value), Int(PageType.DICTIONARY_PAGE.value))
    assert_equal(h.num_values, 16)
    assert_equal(Int(h.encoding.value), Int(Encoding.PLAIN.value))


def test_v2_page_header_every_field() raises:
    var h = _parse_page_header(Span(_v2())).header.copy()
    assert_equal(Int(h.type.value), Int(PageType.DATA_PAGE_V2.value))
    assert_equal(h.num_values, 10)
    assert_equal(h.num_nulls, 2)
    assert_equal(h.num_rows, 10)
    assert_equal(h.def_levels_byte_length, 4)
    assert_equal(h.rep_levels_byte_length, 3)
    assert_true(h.is_compressed)


def test_v2_is_compressed_true_false_and_unknown_fields() raises:
    for flag in range(2):
        var out = List[UInt8]()
        _sizes(out, 3, 10, 10)
        out.append(UInt8((5 << 4) | 12))
        _i32(out, 1, 1)
        out.append(UInt8((6 << 4) | (2 - flag)))  # field 7: true (1) or false (2)
        _i32(out, 1, 9)  # field 8: unknown, skipped
        out.append(0x00)
        out.append(0x00)
        var h = _parse_page_header(Span(out)).header.copy()
        assert_equal(h.is_compressed, flag == 1)
        assert_equal(h.num_values, 1)


def test_negative_sizes_and_counts_are_refused() raises:
    var neg_u = List[UInt8]()
    _sizes(neg_u, 0, -1, 10)
    neg_u.append(0x00)
    assert_true(_refused(neg_u, "negative page size"))
    var neg_c = List[UInt8]()
    _sizes(neg_c, 0, 10, -1)
    neg_c.append(0x00)
    assert_true(_refused(neg_c, "negative page size"))
    var neg_v = List[UInt8]()
    _sizes(neg_v, 0, 10, 10)
    neg_v.append(UInt8((2 << 4) | 12))
    _i32(neg_v, 1, -5)
    neg_v.append(0x00)
    neg_v.append(0x00)
    assert_true(_refused(neg_v, "negative num_values"))


def test_v2_level_lengths_are_checked_against_both_page_sizes() raises:
    assert_true(_refused(_v2(def_len=-1), "negative level length"))
    assert_true(_refused(_v2(rep_len=-1), "negative level length"))
    # 4 + 3 = 7 levels bytes: one more than the compressed size.
    assert_true(_refused(_v2(compressed=6), "exceed the page body"))
    assert_true(_refused(_v2(uncompressed=6), "exceed the page body"))
    # Exactly the page body is allowed.
    var h = _parse_page_header(Span(_v2(uncompressed=7, compressed=7))).header.copy()
    assert_equal(h.compressed_page_size, 7)


def test_v2_null_and_row_counts_are_checked() raises:
    assert_true(_refused(_v2(num_nulls=-1), "negative num_nulls"))
    assert_true(_refused(_v2(num_rows=-1), "negative num_nulls"))
    assert_true(_refused(_v2(num_nulls=11), "exceeds num_values"))
    # The V2 checks apply to V2 pages only: a V1 page carrying a V2 struct
    # with inconsistent levels is not refused for them.
    var h = _parse_page_header(Span(_v2(page_type=0, compressed=1))).header.copy()
    assert_equal(h.def_levels_byte_length, 4)


def test_headers_cut_after_a_whole_field_end_the_walk() raises:
    # Each nested header struct (and then the PageHeader) runs out of bytes
    # after a complete field, with no STOP: both loops end there.
    var structs: List[Int] = [5, 7, 8]
    var deltas: List[Int] = [2, 4, 5]
    for k in range(3):
        var out = List[UInt8]()
        _sizes(out, 0, 10, 10)
        out.append(UInt8((deltas[k] << 4) | 12))
        _i32(out, 1, 6)  # num_values
        var r = _parse_page_header(Span(out))
        assert_equal(r.header.num_values, 6, "struct " + String(structs[k]))
        assert_equal(r.bytes_consumed, len(out))


def test_a_truncated_header_raises() raises:
    var out = List[UInt8]()
    _sizes(out, 0, 10, 10)
    out.append(UInt8((2 << 4) | 12))
    out.append(UInt8((1 << 4) | 5))  # num_values header, value missing
    assert_true(_refused(out, "thrift"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

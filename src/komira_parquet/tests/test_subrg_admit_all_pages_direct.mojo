# Direct tests of `_admit_all_pages` (subrg_cursor_pages.mojo), the
# whole-chunk page header walk `ResumableColumnCursor.try_open` runs: one test
# per refusal case it names, each against an admitted control so a walk that
# refuses everything fails too.
#
# The walk is a function of (chunk bytes, start, dictionary-or-flat, the flat
# encoding, the value count), so it is driven here on synthesised Thrift
# Compact page headers (parquet.thrift) with zero-filled bodies: it never
# reads a body. In every refusal the offending page is the second or later:
# the cursor checks the first data page on its own, and the walk exists for
# the pages after it.
#
# Two of the cases cannot be reached from a header the parser accepts, and
# their tests pin why:
#   * case 1 (a header that consumes no bytes): the parser raises at the end
#     of input, so a header that returns has consumed at least one byte; 64
#     one-byte headers are walked as 64 pages and the walk ends;
#   * case 3's negative half (a negative `compressed_page_size`): the parser
#     refuses a negative size itself, so the walk refuses through case 6.
from std.testing import TestSuite, assert_false, assert_true

from komira_parquet_api.types import Encoding, PageType

from komira_parquet.subrg_cursor_pages import _admit_all_pages


def _uleb(mut out: List[UInt8], value: Int):
    var x = value
    while True:
        var b = UInt8(x & 0x7F)
        x = x >> 7
        if x != 0:
            out.append(b | UInt8(0x80))
        else:
            out.append(b)
            return


def _zigzag(mut out: List[UInt8], value: Int):
    _uleb(out, (value << 1) ^ (value >> 63))


def _header(
    mut out: List[UInt8],
    page_type: Int,
    uncomp: Int,
    comp: Int,
    num_values: Int,
    enc: Int,
):
    """A PageHeader: fields 1-3 (i32, delta 1: 0x15), then field 5
    DataPageHeader (delta 2, struct: 0x2C) or field 7 DictionaryPageHeader
    (delta 4: 0x4C) holding num_values and encoding. Other page types carry
    no sub-struct: the walk refuses them on `type`."""
    out.append(UInt8(0x15))
    _zigzag(out, page_type)
    out.append(UInt8(0x15))
    _zigzag(out, uncomp)
    out.append(UInt8(0x15))
    _zigzag(out, comp)
    if page_type == 0 or page_type == 2:
        out.append(UInt8(0x2C) if page_type == 0 else UInt8(0x4C))
        out.append(UInt8(0x15))
        _zigzag(out, num_values)
        out.append(UInt8(0x15))
        _zigzag(out, enc)
        out.append(UInt8(0x00))
    out.append(UInt8(0x00))


def _page(mut out: List[UInt8], page_type: Int, comp: Int, num_values: Int, enc: Int):
    _header(out, page_type, comp, comp, num_values, enc)
    for _ in range(comp):
        out.append(UInt8(0))


def _data_page(mut out: List[UInt8], enc: Encoding):
    _page(out, 0, 8, 16, Int(enc.value))


def _dict(chunk: List[UInt8], num_values: Int = 32) -> Bool:
    return _admit_all_pages(Span(chunk), 0, True, Encoding.PLAIN, num_values)


def _flat(chunk: List[UInt8], enc: Encoding, num_values: Int = 32) -> Bool:
    return _admit_all_pages(Span(chunk), 0, False, enc, num_values)


def test_admits_a_dictionary_chunk() raises:
    var chunk = List[UInt8]()
    _data_page(chunk, Encoding.RLE_DICTIONARY)
    _data_page(chunk, Encoding.RLE_DICTIONARY)
    _data_page(chunk, Encoding.PLAIN_DICTIONARY)
    assert_true(_dict(chunk), "RLE_DICTIONARY and PLAIN_DICTIONARY pages are in scope")


def test_admits_a_flat_chunk() raises:
    var chunk = List[UInt8]()
    _data_page(chunk, Encoding.PLAIN)
    _data_page(chunk, Encoding.PLAIN)
    assert_true(_flat(chunk, Encoding.PLAIN), "PLAIN pages in a PLAIN chunk")


def test_starts_where_it_is_told() raises:
    # A dictionary page at the front is past `start`: walking from 0 refuses
    # it (case 2), walking from the first data page admits.
    var chunk = List[UInt8]()
    _page(chunk, 2, 8, 4, Int(Encoding.PLAIN.value))
    var first_data = len(chunk)
    _data_page(chunk, Encoding.RLE_DICTIONARY)
    assert_false(_dict(chunk), "a second DICTIONARY_PAGE is out of scope")
    assert_true(
        _admit_all_pages(Span(chunk), first_data, True, Encoding.PLAIN, 32),
        "the walk starts at `start`",
    )


def test_case1_every_accepted_header_consumes_a_byte() raises:
    # 0x00 is a complete header (a Thrift STOP: every field at its default,
    # a DATA_PAGE of size 0, encoding PLAIN), the shortest one. 64 of them
    # are 64 empty pages, admitted only if the walk advances each time.
    var chunk = List[UInt8](length=64, fill=UInt8(0))
    assert_true(_flat(chunk, Encoding.PLAIN), "64 one-byte pages, walked to the end")


def test_case2_a_page_that_is_not_a_v1_data_page() raises:
    var kinds: List[Int] = [
        Int(PageType.INDEX_PAGE.value),
        Int(PageType.DICTIONARY_PAGE.value),
        Int(PageType.DATA_PAGE_V2.value),
    ]
    for i in range(len(kinds)):
        var chunk = List[UInt8]()
        _data_page(chunk, Encoding.RLE_DICTIONARY)
        _page(chunk, kinds[i], 8, 16, Int(Encoding.RLE_DICTIONARY.value))
        assert_false(_dict(chunk), "page type " + String(kinds[i]) + " admitted")


def test_case3_a_body_past_the_chunk_end() raises:
    var chunk = List[UInt8]()
    _data_page(chunk, Encoding.RLE_DICTIONARY)
    _header(chunk, 0, 4096, 4096, 16, Int(Encoding.RLE_DICTIONARY.value))
    for _ in range(8):
        chunk.append(UInt8(0))
    assert_false(_dict(chunk), "a 4096-byte body followed by 8 bytes")
    # The same page with exactly its body is admitted.
    var ok = List[UInt8]()
    _data_page(ok, Encoding.RLE_DICTIONARY)
    _header(ok, 0, 8, 8, 16, Int(Encoding.RLE_DICTIONARY.value))
    for _ in range(8):
        ok.append(UInt8(0))
    assert_true(_dict(ok), "a body that ends at the chunk end")


def test_case3_a_negative_size_is_refused_by_the_parser() raises:
    var chunk = List[UInt8]()
    _data_page(chunk, Encoding.RLE_DICTIONARY)
    _header(chunk, 0, -1, -1, 16, Int(Encoding.RLE_DICTIONARY.value))
    for _ in range(8):
        chunk.append(UInt8(0))
    assert_false(_dict(chunk), "a negative compressed_page_size")


def test_case4_a_dictionary_chunk_that_spills() raises:
    var fallbacks: List[Encoding] = [
        Encoding.PLAIN,
        Encoding.DELTA_BINARY_PACKED,
        Encoding.BYTE_STREAM_SPLIT,
    ]
    for i in range(len(fallbacks)):
        var chunk = List[UInt8]()
        _data_page(chunk, Encoding.RLE_DICTIONARY)
        _data_page(chunk, Encoding.RLE_DICTIONARY)
        _data_page(chunk, fallbacks[i])
        assert_false(
            _dict(chunk),
            "a dictionary chunk whose third page is encoding "
            + String(fallbacks[i].value),
        )


def test_case5_a_flat_chunk_that_switches_encoding() raises:
    var a = List[UInt8]()
    _data_page(a, Encoding.PLAIN)
    _data_page(a, Encoding.DELTA_BINARY_PACKED)
    assert_false(_flat(a, Encoding.PLAIN), "PLAIN, then DELTA_BINARY_PACKED")
    var b = List[UInt8]()
    _data_page(b, Encoding.DELTA_BINARY_PACKED)
    _data_page(b, Encoding.PLAIN)
    assert_false(
        _flat(b, Encoding.DELTA_BINARY_PACKED), "DELTA_BINARY_PACKED, then PLAIN"
    )
    var c = List[UInt8]()
    _data_page(c, Encoding.DELTA_BINARY_PACKED)
    _data_page(c, Encoding.DELTA_BINARY_PACKED)
    assert_true(
        _flat(c, Encoding.DELTA_BINARY_PACKED),
        "an all-DELTA_BINARY_PACKED chunk: the case compares with the first"
        " page's encoding, not with PLAIN",
    )


def test_case6_a_header_that_does_not_parse_refuses_without_raising() raises:
    # A varint that never ends, then a field header with no value: both make
    # the parser raise, and the walk returns False instead.
    var runaway = List[UInt8]()
    _data_page(runaway, Encoding.RLE_DICTIONARY)
    runaway.append(UInt8(0x15))
    for _ in range(24):
        runaway.append(UInt8(0xFF))
    assert_false(_dict(runaway), "a runaway varint")
    var truncated = List[UInt8]()
    _data_page(truncated, Encoding.RLE_DICTIONARY)
    truncated.append(UInt8(0x15))
    assert_false(_dict(truncated), "a truncated header")


def test_case7_rows_without_a_data_page() raises:
    var empty = List[UInt8]()
    assert_false(_dict(empty, num_values=32), "32 values, no page")
    assert_true(_dict(empty, num_values=0), "0 values, no page")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# ResumableColumnCursor over dictionary-encoded chunks: pages that hold fewer
# rows than the chunk declares, pages that declare no rows, malformed index
# pages, a codes buffer with no headroom, and seeks past the end.
#
# What each test proves:
#   * a dictionary page that runs past the end of the chunk refuses the
#     cursor at open;
#   * a chunk whose pages hold fewer codes than it declares yields the codes
#     the pages hold, then nothing, with the rows short of the declared count;
#   * a page that declares no rows is stepped over to the next page, and the
#     codes after it are the next page's;
#   * an index stream that ends before its page's count yields the codes it
#     holds and refuses the cursor; so does an empty page body, an OPTIONAL
#     page with levels and no codes, and a bit-width-0 page of no rows;
#   * a codes buffer without the documented headroom, asked for fewer codes
#     than a bit-packed group, makes no progress and refuses the cursor
#     instead of spinning;
#   * a request for no rows, and any call on a refused cursor, return nothing
#     and a seek on a refused cursor answers False;
#   * a seek past the last row refuses the cursor and answers False.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.subrg_column_cursor import ResumableColumnCursor, SUBRG_MAX_RUN


comptime _DATA_PAGE = 0
comptime _DICTIONARY_PAGE = 2
comptime _DATA_PAGE_V2 = 3
comptime _PLAIN = 0
comptime _RLE_DICTIONARY = 8


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


def _i32_field(mut out: List[UInt8], v: Int):
    out.append(UInt8((1 << 4) | 5))
    _uleb(out, (v << 1) ^ (v >> 63))


def _page(
    mut chunk: List[UInt8],
    page_type: Int,
    body: List[UInt8],
    num_values: Int,
    encoding: Int,
    codec: CompressionCodec,
) raises:
    """Append a page: header (parquet.thrift PageHeader fields 1-3, then
    DataPageHeader, DictionaryPageHeader or DataPageHeaderV2), then `body`,
    compressed with `codec`."""
    var payload: List[UInt8]
    if codec == CompressionCodec.UNCOMPRESSED:
        payload = body.copy()
    else:
        payload = List[UInt8](length=compress_bound(codec, len(body)), fill=UInt8(0))
        var n = compress(codec, Span(body), Span(payload))
        payload.resize(n, UInt8(0))
    _i32_field(chunk, page_type)
    _i32_field(chunk, len(body))
    _i32_field(chunk, len(payload))
    if page_type == _DATA_PAGE:
        chunk.append(UInt8((2 << 4) | 12))
        _i32_field(chunk, num_values)
        _i32_field(chunk, encoding)
        _i32_field(chunk, 3)
        _i32_field(chunk, 3)
        chunk.append(UInt8(0))
    elif page_type == _DICTIONARY_PAGE:
        chunk.append(UInt8((4 << 4) | 12))
        _i32_field(chunk, num_values)
        _i32_field(chunk, encoding)
        chunk.append(UInt8(0))
    elif page_type == _DATA_PAGE_V2:
        chunk.append(UInt8((5 << 4) | 12))
        _i32_field(chunk, num_values)
        _i32_field(chunk, 0)
        _i32_field(chunk, num_values)
        _i32_field(chunk, encoding)
        _i32_field(chunk, 0)
        _i32_field(chunk, 0)
        chunk.append(UInt8((1 << 4) | 2))
        chunk.append(UInt8(0))
    chunk.append(UInt8(0))
    chunk.extend(payload^)


def _codes(codes: List[Int], bw: Int) -> List[UInt8]:
    """A dictionary-index body: the bit-width byte, then one bit-packed run
    of `codes` (zero-padded to a multiple of 8), LSB first."""
    var page: List[UInt8] = [UInt8(bw)]
    var groups = (len(codes) + 7) // 8
    _uleb(page, (groups << 1) | 1)
    var acc = 0
    var nbits = 0
    for i in range(groups * 8):
        acc |= (codes[i] if i < len(codes) else 0) << nbits
        nbits += bw
        while nbits >= 8:
            page.append(UInt8(acc & 0xFF))
            acc >>= 8
            nbits -= 8
    if nbits > 0:
        page.append(UInt8(acc & 0xFF))
    return page^


def _levels(levels: List[Int]) -> List[UInt8]:
    """V1 definition levels at bit width 1: a 4-byte length, then one
    bit-packed run."""
    var run = List[UInt8]()
    var groups = (len(levels) + 7) // 8
    _uleb(run, (groups << 1) | 1)
    for g in range(groups):
        var byte = 0
        for b in range(8):
            var i = g * 8 + b
            if i < len(levels) and levels[i] != 0:
                byte |= 1 << b
        run.append(UInt8(byte))
    var out = List[UInt8]()
    _le(out, len(run), 4)
    out.extend(run^)
    return out^


def _int_dict(values: List[Int], width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, values[i], width)
    return out^


def _seq(first: Int, n: Int, modulo: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(n):
        out.append((first + i) % modulo)
    return out^



def _buf(slots: Int) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(slots * 4)
    b.set_length(Int64(slots * 4))
    return b^


def _dict_chunk(var data_pages: List[List[UInt8]], var counts: List[Int]) raises -> List[UInt8]:
    """Dictionary [10, 20, 30, 40, 50], then the given data pages."""
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, _int_dict([10, 20, 30, 40, 50], 4), 5, _PLAIN, CompressionCodec.UNCOMPRESSED)
    for i in range(len(data_pages)):
        _page(chunk, _DATA_PAGE, data_pages[i], counts[i], _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    return chunk^


def _open(var chunk: List[UInt8], num_values: Int, nullable: Bool = False) raises -> ResumableColumnCursor:
    return ResumableColumnCursor.try_open(
        chunk^, ParquetType.INT32, CompressionCodec.UNCOMPRESSED, num_values, nullable
    )


def test_a_dictionary_page_past_the_end_of_the_chunk_refuses_at_open() raises:
    var whole = List[UInt8]()
    _page(whole, _DICTIONARY_PAGE, _int_dict([10, 20, 30, 40, 50], 4), 5, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var cut = List[UInt8]()
    for i in range(len(whole) - 6):
        cut.append(whole[i])
    var cur = _open(cut^, 10)
    assert_false(cur.supported())
    assert_equal(cur.rows_emitted(), 0)
    var buf = _buf(10 + SUBRG_MAX_RUN)
    assert_equal(cur.fill_next_codes(buf, 10), 0)


def test_pages_holding_fewer_codes_than_declared_yield_what_they_hold() raises:
    var pages = List[List[UInt8]]()
    pages.append(_codes(_seq(0, 20, 5), 3))
    var counts: List[Int] = [20]
    var cur = _open(_dict_chunk(pages^, counts^), 50)
    assert_true(cur.supported())
    var buf = _buf(50 + SUBRG_MAX_RUN)
    var n = cur.fill_next_codes(buf, 50)
    assert_equal(n, 20)
    for i in range(20):
        assert_equal(Int(buf.get_typed[Int32](i)), i % 5)
    assert_equal(cur.fill_next_codes(buf, 50), 0)
    assert_equal(cur.rows_emitted(), 20)
    assert_true(cur.rows_emitted() != cur.num_values())


def test_a_page_declaring_no_rows_is_stepped_over() raises:
    var pages = List[List[UInt8]]()
    pages.append(_codes(List[Int](), 3))
    pages.append(_codes(_seq(2, 8, 5), 3))
    var counts: List[Int] = [0, 8]
    var cur = _open(_dict_chunk(pages^, counts^), 8)
    var buf = _buf(8 + SUBRG_MAX_RUN)
    assert_equal(cur.fill_next_codes(buf, 8), 8)
    for i in range(8):
        assert_equal(Int(buf.get_typed[Int32](i)), (2 + i) % 5)
    assert_true(cur.supported())
    assert_equal(cur.rows_emitted(), 8)


def test_an_index_stream_shorter_than_its_page_count_refuses_after_its_codes() raises:
    # The page declares 20 codes and its stream holds one group of 8.
    var pages = List[List[UInt8]]()
    pages.append(_codes(_seq(0, 8, 5), 3))
    var counts: List[Int] = [20]
    var cur = _open(_dict_chunk(pages^, counts^), 20)
    var buf = _buf(20 + SUBRG_MAX_RUN)
    assert_equal(cur.fill_next_codes(buf, 20), 8)
    for i in range(8):
        assert_equal(Int(buf.get_typed[Int32](i)), i % 5)
    assert_false(cur.supported())


def test_a_codes_buffer_without_headroom_makes_no_progress_and_refuses() raises:
    var pages = List[List[UInt8]]()
    pages.append(_codes(_seq(0, 16, 5), 3))
    var counts: List[Int] = [16]
    var cur = _open(_dict_chunk(pages^, counts^), 16)
    # 5 slots for 5 codes, fewer than the 8 of one bit-packed group.
    var tight = _buf(5)
    assert_equal(cur.fill_next_codes(tight, 5), 0)
    assert_false(cur.supported())


def test_an_empty_index_page_refuses() raises:
    var pages = List[List[UInt8]]()
    pages.append(List[UInt8]())
    var counts: List[Int] = [5]
    var cur = _open(_dict_chunk(pages^, counts^), 5)
    assert_true(cur.supported(), "the body is read only when the page is opened")
    var buf = _buf(5 + SUBRG_MAX_RUN)
    assert_equal(cur.fill_next_codes(buf, 5), 0)
    assert_false(cur.supported())


def test_an_optional_index_page_with_levels_and_no_codes_refuses() raises:
    var pages = List[List[UInt8]]()
    pages.append(_levels([1, 1, 1, 1, 1]))
    var counts: List[Int] = [5]
    var cur = _open(_dict_chunk(pages^, counts^), 5, True)
    var buf = _buf(5 + SUBRG_MAX_RUN)
    assert_equal(cur.fill_next_codes(buf, 5), 0)
    assert_false(cur.supported())


def test_a_bit_width_zero_page_of_no_rows_refuses() raises:
    var pages = List[List[UInt8]]()
    var body: List[UInt8] = [UInt8(0)]
    pages.append(body^)
    var counts: List[Int] = [0]
    var cur = _open(_dict_chunk(pages^, counts^), 4)
    var buf = _buf(4 + SUBRG_MAX_RUN)
    assert_equal(cur.fill_next_codes(buf, 4), 0)
    assert_false(cur.supported())


def test_a_request_for_no_rows_and_a_refused_cursor_yield_nothing() raises:
    var pages = List[List[UInt8]]()
    pages.append(_codes(_seq(0, 8, 5), 3))
    var counts: List[Int] = [8]
    var cur = _open(_dict_chunk(pages^, counts^), 8)
    var buf = _buf(8 + SUBRG_MAX_RUN)
    assert_equal(cur.fill_next_codes(buf, 0), 0)
    assert_equal(cur.rows_emitted(), 0)
    assert_equal(cur.fill_next_codes(buf, 8), 8, "a zero request moved nothing")
    var refused = _open(List[UInt8](), 8)
    assert_false(refused.supported())
    assert_false(refused.seek_to_row(2, 6))
    assert_equal(refused.fill_next_codes(buf, 8), 0)


def test_a_seek_past_the_last_row_refuses_the_cursor() raises:
    var pages = List[List[UInt8]]()
    pages.append(_codes(_seq(0, 20, 5), 3))
    var counts: List[Int] = [20]
    var cur = _open(_dict_chunk(pages^, counts^), 20)
    assert_false(cur.seek_to_row(30, 40))
    assert_false(cur.supported())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

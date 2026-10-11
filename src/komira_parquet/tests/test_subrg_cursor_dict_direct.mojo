# Direct tests of `ResumableColumnCursor` (subrg_column_cursor.mojo) on
# dictionary-encoded column chunks: the codes it emits a chunk at a time, the
# dictionary it holds, the exact per-call count, the RLE run it splits across
# calls, OPTIONAL pages, the row range of `seek_to_row`, the data-pages-only
# open, and the chunks it refuses (at open, counted, or mid-decode).
#
# Chunks are encoded here from parquet-format: Thrift Compact page headers
# (parquet.thrift), PLAIN dictionary pages, and RLE / Bit-Packing Hybrid codes
# and definition levels (Encodings.md). The expected codes are the ones
# written; every fill is checked against them in order.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from std.memory import bitcast

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.subrg_column_cursor import ResumableColumnCursor, SUBRG_MAX_RUN
from komira_parquet.subrg_scan_route_trace import (
    reset_scan_route_counts,
    scan_open_decline_count,
)

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


def _drain(mut cur: ResumableColumnCursor, step: Int) raises -> List[Int]:
    """Fill `step` codes at a time until drained; each call returns exactly
    min(step, rows left)."""
    var out = List[Int]()
    var buf = _buf(step + SUBRG_MAX_RUN)
    while True:
        var left = cur.num_values() - len(out)
        var n = cur.fill_next_codes(buf, step)
        if n == 0:
            break
        assert_equal(n, min(step, left), "one call returns min(max_rows, rows left)")
        for i in range(n):
            out.append(Int(buf.get_typed[Int32](i)))
    return out^


def _same(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want), "code count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], "code " + String(i))


def _int32_chunk(codec: CompressionCodec) raises -> List[UInt8]:
    """Dictionary [10, 20, 30, 40, 50]; pages of codes 0..19 and 20..32,
    each code `i % 5`."""
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, _int_dict([10, 20, 30, 40, 50], 4), 5, _PLAIN, codec)
    _page(chunk, _DATA_PAGE, _codes(_seq(0, 20, 5), 3), 20, _RLE_DICTIONARY, codec)
    _page(chunk, _DATA_PAGE, _codes(_seq(20, 13, 5), 3), 13, _RLE_DICTIONARY, codec)
    return chunk^


def test_int32_codes_in_small_fills_every_codec() raises:
    var codecs: List[CompressionCodec] = [
        CompressionCodec.UNCOMPRESSED,
        CompressionCodec.SNAPPY,
    ]
    for c in range(len(codecs)):
        var steps: List[Int] = [1, 7, 8, 20, 64]
        for si in range(len(steps)):
            var step = steps[si]
            var cur = ResumableColumnCursor.try_open(
                _int32_chunk(codecs[c]), ParquetType.INT32, codecs[c], 33, False
            )
            assert_true(cur.supported(), "a two-page dictionary chunk is admitted")
            assert_true(cur.is_dict())
            assert_equal(cur.dict_size(), 5)
            var d = cur.dict_values_copy()
            assert_equal(d[0], Int64(10))
            assert_equal(d[4], Int64(50))
            var got = _drain(cur, step)
            assert_equal(len(got), 33, "every row, step " + String(step))
            for i in range(33):
                assert_equal(got[i], i % 5, "code of row " + String(i))
            assert_equal(cur.rows_emitted(), 33)
            assert_true(cur.supported(), "a drained cursor is still supported")
            assert_equal(cur.page_decompress_count(), 3, "one decode per page")


def test_a_long_rle_run_is_split_across_calls() raises:
    # One RLE run of 3000 copies of code 1: the first call writes 2024 (the
    # target plus its headroom), keeps 1024 for later and parks 976.
    var body: List[UInt8] = [UInt8(1)]
    _uleb(body, 3000 << 1)
    body.append(UInt8(1))
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, _int_dict([7, 9], 8), 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _page(chunk, _DATA_PAGE, body, 3000, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var cur = ResumableColumnCursor.try_open(
        chunk^, ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 3000, False
    )
    var buf = _buf(1000 + SUBRG_MAX_RUN)
    for call in range(3):
        assert_equal(cur.fill_next_codes(buf, 1000), 1000, "call " + String(call))
        for i in range(1000):
            assert_equal(buf.get_typed[Int32](i), Int32(1))
    assert_equal(cur.fill_next_codes(buf, 1000), 0, "3000 codes, no more")
    assert_equal(cur.rows_emitted(), 3000)


def test_double_and_float_dictionaries_widen_to_f64() raises:
    var chunk = List[UInt8]()
    var d = List[UInt8]()
    var fv: List[Float64] = [1.5, -2.25]
    for i in range(len(fv)):
        _le(d, Int(bitcast[DType.uint64](fv[i])), 8)
    _page(chunk, _DICTIONARY_PAGE, d, 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _page(chunk, _DATA_PAGE, _codes([1, 0, 1], 1), 3, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var cur = ResumableColumnCursor.try_open(
        chunk^, ParquetType.DOUBLE, CompressionCodec.UNCOMPRESSED, 3, False
    )
    assert_true(cur.value_is_float())
    var f = cur.dict_values_f64_copy()
    assert_equal(len(f), 2)
    assert_equal(f[1], -2.25)
    assert_equal(cur.dict_size(), 0, "no Int64 dictionary for DOUBLE")
    _same(_drain(cur, 8), [1, 0, 1])


def test_string_dictionary_offsets_and_bytes() raises:
    var d = List[UInt8]()
    var strs: List[String] = ["ab", "", "xyz"]
    for i in range(len(strs)):
        _le(d, strs[i].byte_length(), 4)
        d.extend(Span(strs[i].as_bytes()))
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, d, 3, _PLAIN, CompressionCodec.SNAPPY)
    _page(chunk, _DATA_PAGE, _codes([2, 0, 1, 2], 2), 4, _RLE_DICTIONARY, CompressionCodec.SNAPPY)
    var cur = ResumableColumnCursor.try_open(
        chunk^, ParquetType.BYTE_ARRAY, CompressionCodec.SNAPPY, 4, False
    )
    assert_true(cur.supported())
    assert_true(cur.is_string_dict())
    var offs = cur.str_dict_offsets_copy()
    assert_equal(len(offs), 4)
    assert_equal(offs[1], Int32(2))
    assert_equal(offs[2], Int32(2))
    assert_equal(offs[3], Int32(5))
    var b = cur.str_dict_bytes_copy()
    assert_equal(len(b), 5)
    assert_equal(b[0], UInt8(ord("a")))
    assert_equal(b[4], UInt8(ord("z")))
    _same(_drain(cur, 3), [2, 0, 1, 2])


def test_a_string_dictionary_entry_past_its_page_refuses() raises:
    var d = List[UInt8]()
    _le(d, 2, 4)
    d.extend(Span("ab".as_bytes()))
    _le(d, 50, 4)  # the second entry claims 50 bytes; the page ends here
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, d, 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _page(chunk, _DATA_PAGE, _codes([0, 1], 1), 2, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var cur = ResumableColumnCursor.try_open(
        chunk^, ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 2, False
    )
    assert_false(cur.supported(), "a malformed dictionary is refused at open")
    assert_equal(len(cur.str_dict_offsets_copy()), 0)


def test_a_numeric_dictionary_larger_than_its_page_raises() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, _int_dict([1, 2], 4), 100, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _page(chunk, _DATA_PAGE, _codes([0], 1), 1, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    with assert_raises(contains="exceeds the 8 decoded dictionary bytes"):
        _ = ResumableColumnCursor.try_open(
            chunk^, ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 1, False
        )


def test_optional_pages_without_a_null_and_with_one() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, _int_dict([5, 6], 4), 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var p1 = _levels([1, 1, 1, 1])
    p1.extend(_codes([0, 1, 1, 0], 1))
    _page(chunk, _DATA_PAGE, p1, 4, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var p2 = _levels([1, 0, 1])
    p2.extend(_codes([1, 1], 1))
    _page(chunk, _DATA_PAGE, p2, 3, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var cur = ResumableColumnCursor.try_open(
        chunk^, ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 7, True
    )
    assert_true(cur.supported(), "levels are in the body; the header walk admits")
    var buf = _buf(4 + SUBRG_MAX_RUN)
    assert_equal(cur.fill_next_codes(buf, 4), 4, "the page without a null")
    assert_equal(buf.get_typed[Int32](1), Int32(1))
    assert_equal(cur.fill_next_codes(buf, 4), 0, "the page with a null refuses")
    assert_false(cur.supported())
    assert_equal(cur.rows_emitted(), 4, "short of num_values: the caller falls back")


def test_a_bit_width_zero_page_is_all_code_zero() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, _int_dict([42], 4), 1, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _page(chunk, _DATA_PAGE, [UInt8(0)], 300, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var cur = ResumableColumnCursor.try_open(
        chunk^, ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 300, False
    )
    var got = _drain(cur, 64)
    assert_equal(len(got), 300)
    for i in range(300):
        assert_equal(got[i], 0)


def test_seek_to_row_limits_the_codes_to_the_range() raises:
    # [lo, hi) inside page 1, on the page boundary, and across pages.
    var ranges: List[Int] = [5, 12, 20, 26, 18, 31, 0, 33]
    for r in range(0, len(ranges), 2):
        var lo = ranges[r]
        var hi = ranges[r + 1]
        var cur = ResumableColumnCursor.try_open(
            _int32_chunk(CompressionCodec.UNCOMPRESSED),
            ParquetType.INT32,
            CompressionCodec.UNCOMPRESSED,
            33,
            False,
        )
        assert_true(cur.seek_to_row(lo, hi))
        var buf = _buf(64 + SUBRG_MAX_RUN)
        var got = List[Int]()
        while True:
            var n = cur.fill_next_codes(buf, 3)
            if n == 0:
                break
            for i in range(n):
                got.append(Int(buf.get_typed[Int32](i)))
        assert_equal(len(got), hi - lo, "rows of [" + String(lo) + ", " + String(hi) + ")")
        for i in range(len(got)):
            assert_equal(got[i], (lo + i) % 5)


def test_the_data_pages_alone_decode_the_same_codes() raises:
    var whole = ResumableColumnCursor.try_open(
        _int32_chunk(CompressionCodec.SNAPPY), ParquetType.INT32, CompressionCodec.SNAPPY, 33, False
    )
    var start = whole.first_data_page_offset()
    assert_true(start > 0, "the dictionary page precedes the data pages")
    var bytes = _int32_chunk(CompressionCodec.SNAPPY)
    var data = List[UInt8]()
    for i in range(start, len(bytes)):
        data.append(bytes[i])
    var cur = ResumableColumnCursor.try_open_data_only(
        data^, ParquetType.INT32, CompressionCodec.SNAPPY, 33, False, True
    )
    assert_true(cur.supported())
    assert_equal(cur.dict_size(), 0, "no dictionary was decoded")
    _same(_drain(cur, 10), _drain(whole, 10))


def test_a_spilled_dictionary_chunk_is_refused_at_open_and_counted() raises:
    reset_scan_route_counts()
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, _int_dict([1, 2], 4), 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _page(chunk, _DATA_PAGE, _codes([0, 1], 1), 2, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    _page(chunk, _DATA_PAGE, _int_dict([3, 4], 4), 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var cur = ResumableColumnCursor.try_open(
        chunk^, ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 4, False
    )
    assert_false(cur.supported(), "refused before any code is emitted")
    assert_equal(scan_open_decline_count(), 1)
    var buf = _buf(8 + SUBRG_MAX_RUN)
    assert_equal(cur.fill_next_codes(buf, 8), 0)


def test_out_of_scope_types_and_shapes() raises:
    var chunk = _int32_chunk(CompressionCodec.UNCOMPRESSED)
    var b = ResumableColumnCursor.try_open(
        chunk.copy(), ParquetType.BOOLEAN, CompressionCodec.UNCOMPRESSED, 33, False
    )
    assert_false(b.supported(), "BOOLEAN is not in scope")
    var flat_bytes = List[UInt8]()
    _page(flat_bytes, _DATA_PAGE, _int_dict([3], 4), 1, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var s = ResumableColumnCursor.try_open(
        flat_bytes^, ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 1, False
    )
    assert_false(s.supported(), "a flat BYTE_ARRAY chunk is not in scope")
    var e = ResumableColumnCursor.try_open(
        List[UInt8](), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 0, False
    )
    assert_false(e.supported(), "an empty chunk")


def test_a_codes_buffer_too_small_is_refused() raises:
    var cur = ResumableColumnCursor.try_open(
        _int32_chunk(CompressionCodec.UNCOMPRESSED), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 33, False
    )
    var small = _buf(4)
    with assert_raises(contains="fewer than the 10 codes asked for"):
        _ = cur.fill_next_codes(small, 10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

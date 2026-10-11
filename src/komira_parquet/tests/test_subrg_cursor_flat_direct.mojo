# Direct tests of `ResumableColumnCursor` (subrg_column_cursor.mojo) on flat
# column chunks: PLAIN pages copied a chunk at a time (`fill_next_flat`) or
# read in place (`open_next_plain_grain` / `load_grain`, `ensure_plain_page` /
# `commit_plain_grain` / `grain_view_ro`), DELTA_BINARY_PACKED pages decoded
# a chunk at a time with the running value carried across calls, the row
# range of `seek_to_row` (a byte seek in a PLAIN page, a decode-skip in a DBP
# page), and the chunks it refuses with the DBP arm's counters.
#
# Chunks are encoded here from parquet-format: Thrift Compact page headers
# (parquet.thrift), PLAIN values, V1 definition levels and
# DELTA_BINARY_PACKED (Encodings.md). Expected values are the ones written.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true


from std.memory import bitcast

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.subrg_column_cursor import ResumableColumnCursor
from komira_parquet.subrg_dbp_trace import (
    dbp_open_admit_count,
    dbp_open_decline_count,
    dbp_page_count,
    dbp_stall_count,
    dbp_value_count,
    reset_dbp_counts,
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


comptime _DELTA_BINARY_PACKED = 5
comptime _BYTE_STREAM_SPLIT = 9


def _zz(v: Int) -> Int:
    return (v << 1) ^ (v >> 63)


def _width(v: UInt64) -> Int:
    var w = 0
    var x = v
    while x != 0:
        w += 1
        x >>= 1
    return w


def _dbp(values: List[Int]) -> List[UInt8]:
    """DELTA_BINARY_PACKED: blocks of 128 values in 4 miniblocks of 32, every
    miniblock written (zero-padded)."""
    comptime block_size = 128
    comptime mb_count = 4
    var out = List[UInt8]()
    _uleb(out, block_size)
    _uleb(out, mb_count)
    _uleb(out, len(values))
    _uleb(out, _zz(values[0] if len(values) > 0 else 0))
    var mb_size = block_size // mb_count
    var i = 1
    while i < len(values):
        var end = min(i + block_size, len(values))
        var deltas = List[Int]()
        for j in range(i, end):
            deltas.append(values[j] - values[j - 1])
        var md = deltas[0]
        for j in range(len(deltas)):
            md = min(md, deltas[j])
        _uleb(out, _zz(md))
        var widths = List[Int]()
        for m in range(mb_count):
            var w = 0
            for j in range(m * mb_size, min((m + 1) * mb_size, len(deltas))):
                w = max(w, _width(UInt64(deltas[j] - md)))
            widths.append(w)
            out.append(UInt8(w))
        for m in range(mb_count):
            var w = widths[m]
            var start = len(out)
            for _ in range((mb_size * w + 7) // 8):
                out.append(UInt8(0))
            for k in range(mb_size):
                var j = m * mb_size + k
                var u = UInt64(deltas[j] - md) if j < len(deltas) else UInt64(0)
                for b in range(w):
                    if (u >> UInt64(b)) & 1 == 1:
                        var bit = k * w + b
                        out[start + (bit >> 3)] |= UInt8(1 << (bit & 7))
        i = end
    return out^


def _value(r: Int) -> Int:
    """Row r's value: varied deltas, negatives included."""
    return (r * 7919) % 1000 - 300 + r * 3


def _values(first: Int, n: Int) -> List[Int]:
    var out = List[Int]()
    for r in range(first, first + n):
        out.append(_value(r))
    return out^


def _plain_chunk(codec: CompressionCodec, width: Int) raises -> List[UInt8]:
    """PLAIN pages of 40, 25 and 35 values (rows 0..99)."""
    var chunk = List[UInt8]()
    var first = 0
    var sizes: List[Int] = [40, 25, 35]
    for p in range(len(sizes)):
        _page(chunk, _DATA_PAGE, _int_dict(_values(first, sizes[p]), width), sizes[p], _PLAIN, codec)
        first += sizes[p]
    return chunk^


def _dbp_chunk(codec: CompressionCodec) raises -> List[UInt8]:
    """DELTA_BINARY_PACKED pages of 300 and 157 values (rows 0..456)."""
    var chunk = List[UInt8]()
    _page(chunk, _DATA_PAGE, _dbp(_values(0, 300)), 300, _DELTA_BINARY_PACKED, codec)
    _page(chunk, _DATA_PAGE, _dbp(_values(300, 157)), 157, _DELTA_BINARY_PACKED, codec)
    return chunk^


def _vbuf(slots: Int, width: Int) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(slots * width)
    b.set_length(Int64(slots * width))
    return b^


def _read(buf: OwnedAlignedBuffer, i: Int, width: Int) -> Int:
    if width == 8:
        return Int(buf.get_typed[Int64](i))
    return Int(buf.get_typed[Int32](i))


def _drain_flat(
    mut cur: ResumableColumnCursor, step: Int, width: Int
) raises -> List[Int]:
    """Fill `step` values at a time at a moving slot offset of one buffer,
    until drained; each call returns min(step, rows left)."""
    var total = cur.num_values()
    var buf = _vbuf(total + step, width)
    var at = 0
    while True:
        var n = cur.fill_next_flat(buf, step, at)
        if n == 0:
            break
        assert_equal(n, min(step, total - at), "one call returns min(max_rows, rows left)")
        at += n
    var out = List[Int]()
    for i in range(at):
        out.append(_read(buf, i, width))
    return out^


def test_plain_int64_and_int32_in_fills_every_codec() raises:
    var codecs: List[CompressionCodec] = [CompressionCodec.UNCOMPRESSED, CompressionCodec.SNAPPY]
    var widths: List[Int] = [8, 4]
    var steps: List[Int] = [1, 9, 40, 128]
    for c in range(len(codecs)):
        for w in range(len(widths)):
            for s in range(len(steps)):
                var ptype = ParquetType.INT64 if widths[w] == 8 else ParquetType.INT32
                var cur = ResumableColumnCursor.try_open(
                    _plain_chunk(codecs[c], widths[w]), ptype, codecs[c], 100, False
                )
                assert_true(cur.supported(), "a PLAIN chunk is admitted")
                assert_false(cur.is_dict())
                assert_false(cur.is_dbp())
                var got = _drain_flat(cur, steps[s], widths[w])
                assert_equal(len(got), 100)
                for i in range(100):
                    assert_equal(got[i], _value(i), "row " + String(i))
                assert_equal(cur.page_decompress_count(), 3)


def test_plain_grains_are_read_in_place_and_stay_in_one_page() raises:
    var cur = ResumableColumnCursor.try_open(
        _plain_chunk(CompressionCodec.SNAPPY, 8), ParquetType.INT64, CompressionCodec.SNAPPY, 100, False
    )
    var row = 0
    var grains = List[Int]()
    while True:
        var n = cur.open_next_plain_grain(16)
        if n == 0:
            break
        grains.append(n)
        for i in range(n):
            assert_equal(Int(cur.load_grain[DType.int64, 1](i)[0]), _value(row + i))
        if n >= 2:
            var pair = cur.load_grain[DType.int64, 2](0)
            assert_equal(Int(pair[1]), _value(row + 1))
        row += n
    assert_equal(row, 100)
    # Pages of 40, 25, 35 cut grains of 16 at the page ends.
    var want: List[Int] = [16, 16, 8, 16, 9, 16, 16, 3]
    assert_equal(len(grains), len(want))
    for i in range(len(want)):
        assert_equal(grains[i], want[i], "grain " + String(i))
    assert_equal(cur.page_decompress_count(), 3, "one decode per page, not per grain")


def test_ensure_commit_and_the_grain_view() raises:
    var cur = ResumableColumnCursor.try_open(
        _plain_chunk(CompressionCodec.UNCOMPRESSED, 4), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 100, False
    )
    assert_equal(cur.ensure_plain_page(), 40)
    assert_equal(cur.ensure_plain_page(), 40, "ensure does not advance")
    cur.commit_plain_grain(30)
    var view = cur.grain_view_ro(30 * 4)
    var bytes = view.into_span()
    var v1 = Int(Int32(bytes[4]) | (Int32(bytes[5]) << 8) | (Int32(bytes[6]) << 16) | (Int32(bytes[7]) << 24))
    assert_equal(v1, _value(1))
    assert_equal(cur.ensure_plain_page(), 10, "the rest of page 1")
    cur.commit_plain_grain(10)
    assert_equal(cur.ensure_plain_page(), 25, "page 2")
    assert_equal(cur.rows_emitted(), 40)


def test_float_values_land_at_their_slot() raises:
    var chunk = List[UInt8]()
    var body = List[UInt8]()
    var fv: List[Float32] = [1.5, -2.0, 3.25]
    for i in range(len(fv)):
        _le(body, Int(bitcast[DType.uint32](fv[i])), 4)
    _page(chunk, _DATA_PAGE, body, 3, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var cur = ResumableColumnCursor.try_open(
        chunk^, ParquetType.FLOAT, CompressionCodec.UNCOMPRESSED, 3, False
    )
    assert_true(cur.value_is_float())
    var buf = _vbuf(8, 4)
    assert_equal(cur.fill_next_flat(buf, 3, 5), 3)
    assert_equal(buf.get_typed[Float32](5), Float32(1.5))
    assert_equal(buf.get_typed[Float32](7), Float32(3.25))


def test_dbp_int64_and_int32_carry_the_running_value() raises:
    var steps: List[Int] = [1, 7, 32, 100, 457]
    var widths: List[Int] = [8, 4]
    for w in range(len(widths)):
        for s in range(len(steps)):
            reset_dbp_counts()
            var ptype = ParquetType.INT64 if widths[w] == 8 else ParquetType.INT32
            var cur = ResumableColumnCursor.try_open(
                _dbp_chunk(CompressionCodec.SNAPPY), ptype, CompressionCodec.SNAPPY, 457, False
            )
            assert_true(cur.supported(), "a DBP chunk is admitted")
            assert_true(cur.is_dbp())
            var got = _drain_flat(cur, steps[s], widths[w])
            assert_equal(len(got), 457)
            for i in range(457):
                assert_equal(got[i], _value(i), "row " + String(i) + ", step " + String(steps[s]))
            assert_equal(dbp_open_admit_count(), 1)
            assert_equal(dbp_page_count(), 2)
            assert_equal(dbp_value_count(), 457)
            assert_equal(dbp_stall_count(), 0)


def test_a_dbp_chunk_cannot_be_read_in_place() raises:
    var cur = ResumableColumnCursor.try_open(
        _dbp_chunk(CompressionCodec.UNCOMPRESSED), ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 457, False
    )
    assert_equal(cur.open_next_plain_grain(16), 0, "its page bytes are not values")
    assert_false(cur.supported())


def test_seek_to_row_in_plain_and_dbp_chunks() raises:
    var ranges: List[Int] = [0, 10, 5, 39, 40, 65, 33, 90, 70, 100]
    for r in range(0, len(ranges), 2):
        var lo = ranges[r]
        var hi = ranges[r + 1]
        var p = ResumableColumnCursor.try_open(
            _plain_chunk(CompressionCodec.UNCOMPRESSED, 8), ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 100, False
        )
        assert_true(p.seek_to_row(lo, hi))
        var buf = _vbuf(128, 8)
        var n = 0
        while True:
            var k = p.fill_next_flat(buf, 6, n)
            if k == 0:
                break
            n += k
        assert_equal(n, hi - lo, "PLAIN rows of [" + String(lo) + ", " + String(hi) + ")")
        for i in range(n):
            assert_equal(Int(buf.get_typed[Int64](i)), _value(lo + i))
    var dranges: List[Int] = [0, 50, 50, 299, 299, 301, 300, 457, 10, 456]
    for r in range(0, len(dranges), 2):
        var lo = dranges[r]
        var hi = dranges[r + 1]
        var d = ResumableColumnCursor.try_open(
            _dbp_chunk(CompressionCodec.UNCOMPRESSED), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 457, False
        )
        assert_true(d.seek_to_row(lo, hi))
        var buf = _vbuf(512, 4)
        var n = 0
        while True:
            var k = d.fill_next_flat(buf, 11, n)
            if k == 0:
                break
            n += k
        assert_equal(n, hi - lo, "DBP rows of [" + String(lo) + ", " + String(hi) + ")")
        for i in range(n):
            assert_equal(Int(buf.get_typed[Int32](i)), _value(lo + i))


def test_optional_flat_pages() raises:
    var chunk = List[UInt8]()
    var p1 = _levels([1, 1, 1])
    p1.extend(_int_dict(_values(0, 3), 8))
    _page(chunk, _DATA_PAGE, p1, 3, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var p2 = _levels([1, 0])
    p2.extend(_int_dict(_values(3, 1), 8))
    _page(chunk, _DATA_PAGE, p2, 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var cur = ResumableColumnCursor.try_open(
        chunk^, ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 5, True
    )
    var buf = _vbuf(8, 8)
    assert_equal(cur.fill_next_flat(buf, 3, 0), 3, "the page without a null")
    assert_equal(Int(buf.get_typed[Int64](2)), _value(2))
    assert_equal(cur.fill_next_flat(buf, 2, 3), 0, "the page with a null refuses")
    assert_false(cur.supported())


def test_flat_chunks_refused_at_open_are_counted() raises:
    reset_dbp_counts()
    var v2 = List[UInt8]()
    _page(v2, _DATA_PAGE_V2, _int_dict(_values(0, 4), 8), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var a = ResumableColumnCursor.try_open(v2^, ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 4, False)
    assert_false(a.supported(), "a DATA_PAGE_V2 first page")
    var bss = List[UInt8]()
    _page(bss, _DATA_PAGE, _int_dict(_values(0, 4), 8), 4, _BYTE_STREAM_SPLIT, CompressionCodec.UNCOMPRESSED)
    var b = ResumableColumnCursor.try_open(bss^, ParquetType.DOUBLE, CompressionCodec.UNCOMPRESSED, 4, False)
    assert_false(b.supported(), "a BYTE_STREAM_SPLIT first page")
    var dbp_double = List[UInt8]()
    _page(dbp_double, _DATA_PAGE, _dbp(_values(0, 4)), 4, _DELTA_BINARY_PACKED, CompressionCodec.UNCOMPRESSED)
    var c = ResumableColumnCursor.try_open(dbp_double^, ParquetType.DOUBLE, CompressionCodec.UNCOMPRESSED, 4, False)
    assert_false(c.supported(), "DELTA_BINARY_PACKED is an integer encoding")
    assert_equal(dbp_open_decline_count(), 3)
    assert_equal(dbp_open_admit_count(), 0)


def test_a_plain_page_shorter_than_its_count_refuses() raises:
    # The page declares 10 INT64 values and holds 4.
    var chunk = List[UInt8]()
    _page(chunk, _DATA_PAGE, _int_dict(_values(0, 4), 8), 10, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var cur = ResumableColumnCursor.try_open(chunk^, ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 10, False)
    var buf = _vbuf(10, 8)
    assert_equal(cur.fill_next_flat(buf, 10, 0), 0, "nothing is read past the page")
    assert_false(cur.supported())


def test_a_value_buffer_too_small_is_refused() raises:
    var cur = ResumableColumnCursor.try_open(
        _plain_chunk(CompressionCodec.UNCOMPRESSED, 8), ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 100, False
    )
    var small = _vbuf(4, 8)
    with assert_raises(contains="fewer than 5 values of width 8"):
        _ = cur.fill_next_flat(small, 5, 0)


def test_the_data_pages_alone_of_a_flat_chunk() raises:
    var cur = ResumableColumnCursor.try_open_data_only(
        _dbp_chunk(CompressionCodec.UNCOMPRESSED), ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 457, False, False
    )
    assert_true(cur.is_dbp())
    var got = _drain_flat(cur, 50, 8)
    assert_equal(got[456], _value(456))
    var junk: List[UInt8] = [UInt8(0x15), UInt8(0xFF)]
    var bad = ResumableColumnCursor.try_open_data_only(
        junk^, ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 4, False, False
    )
    assert_false(bad.supported(), "a header that does not parse refuses, not raises")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

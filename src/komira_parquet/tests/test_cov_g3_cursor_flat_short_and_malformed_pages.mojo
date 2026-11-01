# =============================================================================
# ResumableColumnCursor over flat chunks: pages that hold fewer values than
# the chunk declares, pages that declare no values, malformed PLAIN, OPTIONAL
# and DELTA_BINARY_PACKED pages, in-place grain refusals and seeks.
#
# What each test proves:
#   * a chunk whose pages hold fewer values than it declares yields the
#     values the pages hold, then nothing, for PLAIN fills, DBP fills and the
#     in-place page walk, with the rows short of the declared count;
#   * a PLAIN page that declares no values is stepped over;
#   * a PLAIN page too short for its count refuses the in-place walk, and an
#     OPTIONAL page with an empty body, or with levels and no values, refuses
#     the fill;
#   * a DBP page with an empty body, or with a degenerate header (block size
#     0), refuses the fill instead of decoding a short page;
#   * a dictionary cursor asked for flat values, and a flat cursor asked for
#     dictionary codes, refuse instead of misreading the page;
#   * a request for no rows, a grain of no rows and any call on a refused
#     cursor yield nothing, and a seek on a refused cursor answers False;
#   * a seek past the last row answers False and refuses the cursor, for
#     PLAIN and DBP chunks;
#   * a seek into an INT64 DBP page decode-skips to the row and the values
#     after it are the written ones.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.subrg_column_cursor import ResumableColumnCursor


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



def _open64(var chunk: List[UInt8], num_values: Int, nullable: Bool = False) raises -> ResumableColumnCursor:
    return ResumableColumnCursor.try_open(
        chunk^, ParquetType.INT64, CompressionCodec.UNCOMPRESSED, num_values, nullable
    )


def test_plain_pages_holding_fewer_values_than_declared_yield_what_they_hold() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA_PAGE, _int_dict(_values(0, 12), 8), 12, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var cur = _open64(chunk^, 30)
    var buf = _vbuf(30, 8)
    assert_equal(cur.fill_next_flat(buf, 30, 0), 12)
    for i in range(12):
        assert_equal(Int(buf.get_typed[Int64](i)), _value(i))
    assert_equal(cur.fill_next_flat(buf, 30, 12), 0)
    assert_equal(cur.rows_emitted(), 12)
    assert_true(cur.rows_emitted() != cur.num_values())


def test_dbp_pages_holding_fewer_values_than_declared_yield_what_they_hold() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA_PAGE, _dbp(_values(0, 40)), 40, _DELTA_BINARY_PACKED, CompressionCodec.UNCOMPRESSED)
    var cur = _open64(chunk^, 100)
    assert_true(cur.is_dbp())
    var buf = _vbuf(100, 8)
    assert_equal(cur.fill_next_flat(buf, 100, 0), 40)
    for i in range(40):
        assert_equal(Int(buf.get_typed[Int64](i)), _value(i))
    assert_equal(cur.fill_next_flat(buf, 100, 40), 0)
    assert_equal(cur.rows_emitted(), 40)


def test_the_in_place_walk_stops_when_the_pages_run_out() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA_PAGE, _int_dict(_values(0, 6), 8), 6, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var cur = _open64(chunk^, 20)
    assert_equal(cur.ensure_plain_page(), 6)
    cur.commit_plain_grain(6)
    assert_equal(cur.ensure_plain_page(), 0)
    assert_true(cur.supported(), "running out of pages is not a refusal")
    assert_equal(cur.rows_emitted(), 6)


def test_a_plain_page_too_short_for_its_count_refuses_the_in_place_walk() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA_PAGE, _int_dict(_values(0, 3), 8), 10, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var cur = _open64(chunk^, 10)
    assert_equal(cur.ensure_plain_page(), 0)
    assert_false(cur.supported())


def test_a_plain_page_declaring_no_values_is_stepped_over() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA_PAGE, List[UInt8](), 0, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _page(chunk, _DATA_PAGE, _int_dict(_values(0, 10), 8), 10, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var cur = _open64(chunk^, 10)
    var buf = _vbuf(10, 8)
    assert_equal(cur.fill_next_flat(buf, 10, 0), 10)
    for i in range(10):
        assert_equal(Int(buf.get_typed[Int64](i)), _value(i))
    assert_true(cur.supported())


def test_optional_flat_pages_with_an_empty_body_or_no_values_refuse() raises:
    var empty = List[UInt8]()
    _page(empty, _DATA_PAGE, List[UInt8](), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var a = _open64(empty^, 4, True)
    var buf = _vbuf(4, 8)
    assert_equal(a.fill_next_flat(buf, 4, 0), 0)
    assert_false(a.supported())
    var levels_only = List[UInt8]()
    _page(levels_only, _DATA_PAGE, _levels([1, 1, 1, 1]), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var b = _open64(levels_only^, 4, True)
    assert_equal(b.fill_next_flat(buf, 4, 0), 0)
    assert_false(b.supported())


def test_dbp_pages_with_an_empty_body_or_a_degenerate_header_refuse() raises:
    var empty = List[UInt8]()
    _page(empty, _DATA_PAGE, List[UInt8](), 5, _DELTA_BINARY_PACKED, CompressionCodec.UNCOMPRESSED)
    var a = _open64(empty^, 5)
    var buf = _vbuf(5, 8)
    assert_equal(a.fill_next_flat(buf, 5, 0), 0)
    assert_false(a.supported())
    # block size 0, 4 miniblocks, 5 values, first value 0.
    var degenerate: List[UInt8] = [UInt8(0), UInt8(4), UInt8(5), UInt8(0)]
    var chunk = List[UInt8]()
    _page(chunk, _DATA_PAGE, degenerate^, 5, _DELTA_BINARY_PACKED, CompressionCodec.UNCOMPRESSED)
    var b = _open64(chunk^, 5)
    assert_equal(b.fill_next_flat(buf, 5, 0), 0)
    assert_false(b.supported())


def test_no_rows_asked_and_a_refused_cursor_yield_nothing() raises:
    var cur = _open64(_plain_chunk(CompressionCodec.UNCOMPRESSED, 8), 100)
    var buf = _vbuf(100, 8)
    assert_equal(cur.fill_next_flat(buf, 0, 0), 0)
    assert_equal(cur.open_next_plain_grain(0), 0)
    assert_equal(cur.rows_emitted(), 0)
    assert_equal(cur.fill_next_flat(buf, 100, 0), 100, "the zero requests moved nothing")
    var refused = _open64(List[UInt8](), 100)
    assert_false(refused.supported())
    assert_equal(refused.fill_next_flat(buf, 10, 0), 0)
    assert_equal(refused.open_next_plain_grain(8), 0)
    assert_false(refused.seek_to_row(5, 10))


def test_a_dictionary_cursor_asked_for_flat_values_refuses() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DICTIONARY_PAGE, _int_dict([10, 20, 30], 8), 3, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _page(chunk, _DATA_PAGE, _codes(_seq(0, 8, 3), 2), 8, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var cur = _open64(chunk^, 8)
    assert_true(cur.is_dict())
    var buf = _vbuf(8, 8)
    assert_equal(cur.fill_next_flat(buf, 8, 0), 0)
    assert_false(cur.supported())


def test_a_flat_cursor_asked_for_dictionary_codes_refuses() raises:
    var cur = _open64(_plain_chunk(CompressionCodec.UNCOMPRESSED, 8), 100)
    assert_false(cur.is_dict())
    var buf = _vbuf(100 + 1024, 4)
    assert_equal(cur.fill_next_codes(buf, 10), 0)
    assert_false(cur.supported())
    assert_equal(cur.rows_emitted(), 0)


def test_a_seek_past_the_last_row_refuses_plain_and_dbp_cursors() raises:
    var p = _open64(_plain_chunk(CompressionCodec.UNCOMPRESSED, 8), 100)
    assert_false(p.seek_to_row(150, 200))
    assert_false(p.supported())
    var d = _open64(_dbp_chunk(CompressionCodec.UNCOMPRESSED), 457)
    assert_false(d.seek_to_row(500, 600))
    assert_false(d.supported())


def test_a_seek_into_an_int64_dbp_page_skips_to_the_row() raises:
    var cur = _open64(_dbp_chunk(CompressionCodec.UNCOMPRESSED), 457)
    assert_true(cur.seek_to_row(40, 70))
    var buf = _vbuf(64, 8)
    var n = 0
    while True:
        var k = cur.fill_next_flat(buf, 7, n)
        if k == 0:
            break
        n += k
    assert_equal(n, 30)
    for i in range(30):
        assert_equal(Int(buf.get_typed[Int64](i)), _value(40 + i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

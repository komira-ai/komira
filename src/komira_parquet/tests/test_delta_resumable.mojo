# =============================================================================
# DELTA_BINARY_PACKED, resumable: `begin_resumable` + `resume_fill_int64/32`.
#
# The contract: a page decoded in chunks of any size equals the same page
# decoded in one shot, value for value, including the tail that pads a short
# stream with its last value; a chunk boundary inside a miniblock stages the
# rest and hands it back first on the next call; `max_values` is a hard cap;
# a destination too small for `dst_elem_offset + max_values` is refused
# before anything is written. Every expected value comes from the one-shot
# decoder (itself checked against encoded values in test_delta_direct).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet.delta import DeltaDecoder


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(v: Int) -> Int:
    return (v << 1) ^ (v >> 63)


def _width(v: UInt64) -> Int:
    var w = 0
    var x = v
    while x != 0:
        w += 1
        x >>= 1
    return w


def _encode(values: List[Int], block_size: Int, mb_count: Int) -> List[UInt8]:
    """DELTA_BINARY_PACKED, every miniblock written (padded with zeros)."""
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


def _rand(n: Int, seed: Int, spread_bits: Int) -> List[Int]:
    var out = List[Int]()
    var x = seed * 7919 + 1
    var mask = (1 << spread_bits) - 1
    for _ in range(n):
        x = (x * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
        out.append(((x >> 3) & mask) - (mask >> 1))
    return out^


def _one_shot(enc: List[UInt8], n: Int) -> List[Int64]:
    var out = List[Int64](capacity=n)
    out.resize(n, Int64(0))
    var dec = DeltaDecoder(Span(enc))
    _ = dec.decode_int64(n, Span(out))
    return out^


def _buf(slots: Int, width: Int) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(slots * width)
    for i in range(slots * width):
        b.set_typed[UInt8](i, UInt8(0xEE))
    return b^


def _chunked64(enc: List[UInt8], n: Int, chunk: Int) raises -> List[Int64]:
    var dec = DeltaDecoder(Span(enc))
    assert_true(dec.begin_resumable(n))
    assert_true(dec.resume_armed())
    var dst = _buf(n + chunk, 8)
    var at = 0
    while True:
        var got = dec.resume_fill_int64(dst, at, chunk)
        assert_true(got <= chunk, "the cap is hard")
        if got == 0:
            break
        at += got
        assert_equal(dec.resume_values_returned(), at)
    assert_equal(at, n)
    var out = List[Int64]()
    for i in range(n):
        out.append(dst.get_typed[Int64](i))
    # The slot after the last value is untouched.
    assert_equal(dst.get_typed[UInt8](n * 8), UInt8(0xEE))
    return out^


def test_chunked_equals_one_shot_for_every_chunk_size() raises:
    var vals = _rand(700, 3, 21)
    var enc = _encode(vals, 128, 4)
    var want = _one_shot(enc, 700)
    var chunks: List[Int] = [1, 2, 7, 31, 32, 33, 100, 128, 129, 700, 4096]
    for c in range(len(chunks)):
        var got = _chunked64(enc, 700, chunks[c])
        for i in range(700):
            assert_equal(got[i], want[i], "chunk=" + String(chunks[c]) + " i=" + String(i))


def test_chunked_int32_equals_one_shot() raises:
    var vals = _rand(301, 8, 25)
    var enc = _encode(vals, 64, 2)
    var want = _one_shot(enc, 301)
    var chunks: List[Int] = [3, 5, 32, 64, 301]
    for c in range(len(chunks)):
        var chunk = chunks[c]
        var dec = DeltaDecoder(Span(enc))
        assert_true(dec.begin_resumable(301))
        var dst = _buf(301 + chunk, 4)
        var at = 0
        while True:
            var got = dec.resume_fill_int32(dst, at, chunk)
            if got == 0:
                break
            at += got
        assert_equal(at, 301)
        for i in range(301):
            assert_equal(Int(dst.get_typed[Int32](i)), Int(want[i]), "chunk=" + String(chunk))
        assert_equal(dst.get_typed[UInt8](301 * 4), UInt8(0xEE))


def test_short_stream_pads_with_the_last_value_like_one_shot() raises:
    """A page declaring more values than it encodes: the values past the
    encoded ones come from the zero-padded miniblock tail, as in one shot."""
    var vals = _rand(40, 4, 9)
    var enc = _encode(vals, 128, 4)
    var want = _one_shot(enc, 60)
    var got = _chunked64(enc, 60, 9)
    for i in range(60):
        assert_equal(got[i], want[i])


def test_header_only_page_pads_from_the_first_value() raises:
    var one: List[Int] = [-5]
    var enc = _encode(one, 128, 4)
    var got = _chunked64(enc, 6, 4)
    for i in range(6):
        assert_equal(Int(got[i]), -5)


def test_width_zero_miniblocks_take_no_bytes() raises:
    var vals = List[Int]()
    for i in range(150):
        vals.append(7 * i)
    var enc = _encode(vals, 128, 4)
    var want = _one_shot(enc, 150)
    var got = _chunked64(enc, 150, 13)
    for i in range(150):
        assert_equal(got[i], want[i])


def test_begin_resumable_refuses_what_one_shot_would_shorten() raises:
    """Empty stream, non-positive count, a torn header, and the degenerate
    geometries leave the decoder disarmed; fills then return 0."""
    var vals = _rand(10, 1, 8)
    var enc = _encode(vals, 128, 4)
    var empty = List[UInt8]()
    var d0 = DeltaDecoder(Span(empty))
    assert_false(d0.begin_resumable(4))
    var d1 = DeltaDecoder(Span(enc))
    assert_false(d1.begin_resumable(0))
    assert_false(d1.begin_resumable(-1))
    var torn: List[UInt8] = [0x80]
    var d2 = DeltaDecoder(Span(torn))
    assert_false(d2.begin_resumable(4))
    var shapes: List[Int] = [0, 4, 128, 0, 3, 4, -1, 4, 128, -1]
    for k in range(5):
        var h = List[UInt8]()
        _uleb(h, shapes[2 * k])
        _uleb(h, shapes[2 * k + 1])
        _uleb(h, 3)
        _uleb(h, 0)
        var d = DeltaDecoder(Span(h))
        assert_false(d.begin_resumable(3), "shape " + String(k))
        assert_false(d.resume_armed())
        var dst = _buf(4, 8)
        assert_equal(d.resume_fill_int64(dst, 0, 4), 0)
        assert_equal(d.resume_fill_int32(dst, 0, 4), 0)


def test_nonpositive_cap_writes_nothing() raises:
    var vals = _rand(20, 2, 8)
    var enc = _encode(vals, 128, 4)
    var dec = DeltaDecoder(Span(enc))
    assert_true(dec.begin_resumable(20))
    var dst = _buf(4, 8)
    assert_equal(dec.resume_fill_int64(dst, 0, 0), 0)
    assert_equal(dec.resume_fill_int32(dst, 0, -2), 0)
    assert_equal(dst.get_typed[UInt8](0), UInt8(0xEE))


def test_a_destination_too_small_is_refused_before_any_write() raises:
    var vals = _rand(20, 2, 8)
    var enc = _encode(vals, 128, 4)
    var dec = DeltaDecoder(Span(enc))
    assert_true(dec.begin_resumable(20))
    var dst = _buf(10, 8)
    var cases: List[Int] = [0, 11, 5, 6, -1, 1]  # (offset, max_values) pairs
    for k in range(3):
        var raised = False
        try:
            _ = dec.resume_fill_int64(dst, cases[2 * k], cases[2 * k + 1])
        except e:
            raised = String(e).find("destination too small") >= 0
        assert_true(raised, "int64 case " + String(k))
    var d32 = _buf(10, 4)
    var raised32 = False
    try:
        _ = dec.resume_fill_int32(d32, 7, 4)
    except:
        raised32 = True
    assert_true(raised32)
    for i in range(80):
        assert_equal(dst.get_typed[UInt8](i), UInt8(0xEE))
    for i in range(40):
        assert_equal(d32.get_typed[UInt8](i), UInt8(0xEE))
    # Nothing was consumed: the decoder still starts at the first value.
    var ok = _buf(20, 8)
    assert_equal(dec.resume_fill_int64(ok, 0, 20), 20)
    assert_equal(Int(ok.get_typed[Int64](0)), vals[0])


def test_a_cap_whose_byte_size_wraps_is_refused() raises:
    """A `max_values` whose byte size wraps Int is refused before any write.
    2^61 Int64s and 2^62 Int32s are 0 bytes after the multiply wraps, so a
    check on `(offset + max_values) * elem_size` passes them and the fill
    writes past the 10-slot destination (Int64), or stages 2^62 values
    (Int32). The check counts slots instead."""
    var vals = _rand(20, 2, 8)
    var enc = _encode(vals, 128, 4)
    var dec = DeltaDecoder(Span(enc))
    assert_true(dec.begin_resumable(20))
    var c64 = 1 << 61
    var c32 = 1 << 62
    assert_equal(c64 * 8, 0)
    assert_equal(c32 * 4, 0)
    var dst = _buf(10, 8)
    var raised64 = False
    try:
        _ = dec.resume_fill_int64(dst, 0, c64)
    except e:
        raised64 = String(e).find("destination too small") >= 0
    assert_true(raised64)
    var d32 = _buf(10, 4)
    var raised32 = False
    try:
        _ = dec.resume_fill_int32(d32, 0, c32)
    except e:
        raised32 = String(e).find("destination too small") >= 0
    assert_true(raised32)
    for i in range(80):
        assert_equal(dst.get_typed[UInt8](i), UInt8(0xEE))
    # An offset past the destination is refused too.
    var raised_off = False
    try:
        _ = dec.resume_fill_int64(dst, 11, 1)
    except e:
        raised_off = String(e).find("destination too small") >= 0
    assert_true(raised_off)
    # Nothing was consumed: the decoder still starts at the first value.
    var ok = _buf(20, 8)
    assert_equal(dec.resume_fill_int64(ok, 0, 20), 20)
    assert_equal(Int(ok.get_typed[Int64](0)), vals[0])


def test_drained_page_returns_zero_and_int32_drained_too() raises:
    var vals = _rand(5, 6, 8)
    var enc = _encode(vals, 128, 4)
    var dec = DeltaDecoder(Span(enc))
    assert_true(dec.begin_resumable(5))
    var dst = _buf(8, 8)
    assert_equal(dec.resume_fill_int64(dst, 0, 8), 5)
    assert_equal(dec.resume_fill_int64(dst, 0, 8), 0)
    assert_equal(dec.resume_fill_int32(dst, 0, 8), 0)
    assert_equal(dec.resume_values_returned(), 5)


def test_a_stream_cut_inside_its_widths_ends_and_pads() raises:
    """The next block's width table is cut short: the walk ends there and
    the rest of the declared count is the last value."""
    var h = List[UInt8]()
    _uleb(h, 128)
    _uleb(h, 4)
    _uleb(h, 9)
    _uleb(h, _zz(3))
    _uleb(h, _zz(2))
    h.append(UInt8(0))  # one width of four
    var got = _chunked64(h, 9, 4)
    for i in range(9):
        assert_equal(Int(got[i]), 3)
    var torn = List[UInt8]()
    _uleb(torn, 128)
    _uleb(torn, 4)
    _uleb(torn, 9)
    _uleb(torn, _zz(3))
    torn.append(UInt8(0x80))  # a min delta that never ends
    var got2 = _chunked64(torn, 9, 4)
    assert_equal(Int(got2[8]), 3)


def test_packed_bytes_cut_short_stop_the_walk_and_pad() raises:
    """The last miniblock's bytes are cut: the values decoded from the bytes
    present match one shot, and the walk then pads."""
    var vals = _rand(60, 12, 14)
    var enc = _encode(vals, 64, 2)
    var cut = List[UInt8]()
    for i in range(len(enc) - 5):
        cut.append(enc[i])
    var want = _one_shot(cut, 80)
    var got = _chunked64(cut, 80, 11)
    for i in range(80):
        assert_equal(got[i], want[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

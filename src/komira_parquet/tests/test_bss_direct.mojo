# =============================================================================
# BYTE_STREAM_SPLIT decode: the four public entry points against the values
# that were encoded, and their refusals.
#
# The encoder here is the format's definition (byte b of value i goes to
# stream b, at index i). Counts on both sides of the SIMD kernel's 16-value
# step check the vector body and the scalar tail; the `_into` variants are
# checked at destination offsets that are not 16-byte aligned, with guard
# bytes either side of the window; a page shorter than `num_values * W`, a
# negative count, a count whose byte size wraps Int, and a window too small
# are refused before any byte moves.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet.byte_stream_split import (
    decode_byte_stream_split_float32,
    decode_byte_stream_split_float32_into,
    decode_byte_stream_split_float64,
    decode_byte_stream_split_float64_into,
)


def _f32(n: Int) -> List[Float32]:
    var out = List[Float32]()
    for i in range(n):
        out.append(Float32(i) * -3.25 + 0.5)
    return out^


def _f64(n: Int) -> List[Float64]:
    var out = List[Float64]()
    for i in range(n):
        out.append(Float64(i) * 1.0e-3 - 7.125e10)
    return out^


def _enc32(v: List[Float32]) -> List[UInt8]:
    var n = len(v)
    var out = List[UInt8](capacity=n * 4)
    out.resize(n * 4, UInt8(0))
    for i in range(n):
        var u = bitcast[DType.uint32](v[i])
        for b in range(4):
            out[b * n + i] = UInt8((u >> UInt32(8 * b)) & 0xFF)
    return out^


def _enc64(v: List[Float64]) -> List[UInt8]:
    var n = len(v)
    var out = List[UInt8](capacity=n * 8)
    out.resize(n * 8, UInt8(0))
    for i in range(n):
        var u = bitcast[DType.uint64](v[i])
        for b in range(8):
            out[b * n + i] = UInt8((u >> UInt64(8 * b)) & 0xFF)
    return out^


comptime _COUNTS: List[Int] = [1, 2, 15, 16, 17, 31, 32, 33, 64, 100, 257]


def test_decode_float32_matches_the_encoded_values() raises:
    var counts = materialize[_COUNTS]()
    for c in range(len(counts)):
        var n = counts[c]
        var v = _f32(n)
        var page = _enc32(v)
        var arr = decode_byte_stream_split_float32(Span(page), n)
        assert_equal(arr.length, n)
        for i in range(n):
            assert_equal(arr.get(i), v[i], "n=" + String(n))


def test_decode_float64_matches_the_encoded_values() raises:
    var counts = materialize[_COUNTS]()
    for c in range(len(counts)):
        var n = counts[c]
        var v = _f64(n)
        var page = _enc64(v)
        var arr = decode_byte_stream_split_float64(Span(page), n)
        assert_equal(arr.length, n)
        for i in range(n):
            assert_equal(arr.get(i), v[i], "n=" + String(n))


def test_zero_values_decode_to_empty() raises:
    var empty = List[UInt8]()
    assert_equal(decode_byte_stream_split_float32(Span(empty), 0).length, 0)
    assert_equal(decode_byte_stream_split_float64(Span(empty), 0).length, 0)
    var buf = OwnedAlignedBuffer(8)
    decode_byte_stream_split_float32_into(Span(empty), 0, buf.view_mut())
    decode_byte_stream_split_float64_into(Span(empty), 0, buf.view_mut())


def _refused(msg: String, e: Error) -> Bool:
    return String(e).find(msg) >= 0


def test_a_short_page_or_a_negative_count_is_refused() raises:
    """The page must hold `num_values * W` bytes: one byte short, and a
    count far past the page, both raise; so does a negative count."""
    var page = _enc32(_f32(16))
    var short = List[UInt8]()
    for i in range(len(page) - 1):
        short.append(page[i])
    var counts: List[Int] = [16, 1000000, -1]
    for k in range(len(counts)):
        var src = short.copy() if k == 0 else page.copy()
        var r32 = False
        try:
            _ = decode_byte_stream_split_float32(Span(src), counts[k])
        except e:
            r32 = _refused("corrupt BYTE_STREAM_SPLIT page", e)
        assert_true(r32, "f32 case " + String(k))
        var r64 = False
        try:
            _ = decode_byte_stream_split_float64(Span(src), counts[k] // 2 if k == 0 else counts[k])
        except e:
            r64 = _refused("corrupt BYTE_STREAM_SPLIT page", e)
        assert_true(r64, "f64 case " + String(k))
        var buf = OwnedAlignedBuffer(1 << 10)
        var i32 = False
        try:
            decode_byte_stream_split_float32_into(Span(src), counts[k], buf.view_mut())
        except e:
            i32 = _refused("corrupt BYTE_STREAM_SPLIT page", e)
        assert_true(i32, "f32 into case " + String(k))
        var i64 = False
        try:
            decode_byte_stream_split_float64_into(Span(src), counts[k] // 2 if k == 0 else counts[k], buf.view_mut())
        except e:
            i64 = _refused("corrupt BYTE_STREAM_SPLIT page", e)
        assert_true(i64, "f64 into case " + String(k))


def test_a_count_whose_byte_size_wraps_is_refused() raises:
    """A count whose byte size wraps Int is refused by all four entries.

    2^62 + 16 Float32s is 64 bytes after `* 4` wraps, and 2^61 + 8 Float64s
    is 64 bytes after `* 8` wraps: exactly the 64-byte page and the 64-byte
    window used here. A gate that checked the wrapped product would pass
    both, and the kernel would then walk 2^62 values past the page (a
    segfault). The gate divides the page by W instead."""
    var page = _enc32(_f32(16))
    assert_equal(len(page), 64)
    var c32 = (1 << 62) + 16
    var c64 = (1 << 61) + 8
    assert_equal(c32 * 4, 64)
    assert_equal(c64 * 8, 64)
    var buf = OwnedAlignedBuffer(64)
    var hits = 0
    try:
        _ = decode_byte_stream_split_float32(Span(page), c32)
    except e:
        hits += 1 if _refused("corrupt BYTE_STREAM_SPLIT page", e) else 0
    try:
        _ = decode_byte_stream_split_float64(Span(page), c64)
    except e:
        hits += 1 if _refused("corrupt BYTE_STREAM_SPLIT page", e) else 0
    try:
        decode_byte_stream_split_float32_into(Span(page), c32, buf.view_range_mut(0, 64))
    except e:
        hits += 1 if _refused("corrupt BYTE_STREAM_SPLIT page", e) else 0
    try:
        decode_byte_stream_split_float64_into(Span(page), c64, buf.view_range_mut(0, 64))
    except e:
        hits += 1 if _refused("corrupt BYTE_STREAM_SPLIT page", e) else 0
    assert_equal(hits, 4)


def test_into_unaligned_windows_with_guards() raises:
    """Decode into a window at byte offsets 4, 8 and 24 of a larger buffer:
    the window holds exactly the values, the bytes either side are intact."""
    var offsets: List[Int] = [4, 8, 24]
    for k in range(len(offsets)):
        var off = offsets[k]
        var n = 37
        var v32 = _f32(n)
        var p32 = _enc32(v32)
        var buf = OwnedAlignedBuffer(off + n * 8 + 16)
        for i in range(off + n * 8 + 16):
            buf.set_typed[UInt8](i, UInt8(0xA5))
        decode_byte_stream_split_float32_into(Span(p32), n, buf.view_range_mut(off, n * 4))
        assert_equal(buf.get_typed[UInt8](off - 1), UInt8(0xA5))
        assert_equal(buf.get_typed[UInt8](off + n * 4), UInt8(0xA5))
        for i in range(n):
            var got = bitcast[DType.float32](
                UInt32(buf.get_typed[UInt8](off + 4 * i))
                | (UInt32(buf.get_typed[UInt8](off + 4 * i + 1)) << 8)
                | (UInt32(buf.get_typed[UInt8](off + 4 * i + 2)) << 16)
                | (UInt32(buf.get_typed[UInt8](off + 4 * i + 3)) << 24)
            )
            assert_equal(got, v32[i])
        var v64 = _f64(n)
        var p64 = _enc64(v64)
        decode_byte_stream_split_float64_into(Span(p64), n, buf.view_range_mut(off, n * 8))
        assert_equal(buf.get_typed[UInt8](off + n * 8), UInt8(0xA5))
        for i in range(n):
            var u = UInt64(0)
            for b in range(8):
                u |= UInt64(buf.get_typed[UInt8](off + 8 * i + b)) << UInt64(8 * b)
            assert_equal(bitcast[DType.float64](u), v64[i])


def test_into_refuses_a_window_too_small() raises:
    var n = 20
    var p32 = _enc32(_f32(n))
    var p64 = _enc64(_f64(n))
    var buf = OwnedAlignedBuffer(256)
    for i in range(256):
        buf.set_typed[UInt8](i, UInt8(0x5A))
    var r32 = False
    try:
        decode_byte_stream_split_float32_into(Span(p32), n, buf.view_range_mut(0, n * 4 - 1))
    except e:
        r32 = _refused("destination too small", e)
    assert_true(r32)
    var r64 = False
    try:
        decode_byte_stream_split_float64_into(Span(p64), n, buf.view_range_mut(0, n * 8 - 8))
    except e:
        r64 = _refused("destination too small", e)
    assert_true(r64)
    for i in range(256):
        assert_equal(buf.get_typed[UInt8](i), UInt8(0x5A))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

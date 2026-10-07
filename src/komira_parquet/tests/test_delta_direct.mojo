# =============================================================================
# DELTA_BINARY_PACKED, one shot: `DeltaDecoder.decode_int64/decode_int32` and
# `delta_binary_packed_byte_count`.
#
# A test-local encoder writes the format as parquet-format's Encodings.md
# defines it (header: block size, miniblocks per block, value count, zigzag
# first value; per block: zigzag min delta, one bit width per miniblock, the
# miniblocks bit-packed LSB first), so every decoded value is checked against
# the values that were encoded. Hand-built headers cover the degenerate and
# hostile geometries: a zero or NEGATIVE block size or miniblock count (a
# ten-byte varint decodes to a negative Int) must stop at the first value,
# never step the reader backwards.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet.decode_arm_trace import (
    delta_page_bytecopy_count,
    delta_page_memcpy_count,
    reset_decode_arm_counts,
    reset_decode_arm_gates,
    set_delta_page_memcpy_enabled,
)
from komira_parquet.delta import DeltaDecoder, delta_binary_packed_byte_count


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
    var mask = (1 << spread_bits) - 1 if spread_bits < 63 else 0x7FFFFFFFFFFFFFFF
    for _ in range(n):
        x = (x * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
        out.append(((x >> 3) & mask) - (mask >> 1))
    return out^


def _filled64(n: Int) -> List[Int64]:
    var out = List[Int64](capacity=n)
    out.resize(n, Int64(-77))
    return out^


def _check_round_trip(
    vals: List[Int], block: Int, mbc: Int, what: String = ""
) raises:
    var enc = _encode(vals, block, mbc)
    var out = _filled64(len(vals) + 3)
    var dec = DeltaDecoder(Span(enc))
    assert_equal(dec.decode_int64(len(vals), Span(out)), len(vals))
    for i in range(len(vals)):
        assert_equal(Int(out[i]), vals[i], what + " i=" + String(i))
    assert_equal(out[len(vals)], Int64(-77))
    assert_equal(delta_binary_packed_byte_count(Span(enc), len(vals)), len(enc))


def test_round_trips_across_sizes_and_geometries() raises:
    var sizes: List[Int] = [1, 2, 31, 32, 33, 128, 129, 300, 1000]
    for s in range(len(sizes)):
        _check_round_trip(_rand(sizes[s], sizes[s], 20), 128, 4)
        _check_round_trip(_rand(sizes[s], sizes[s] + 1, 7), 256, 8)
        _check_round_trip(_rand(sizes[s], sizes[s] + 2, 33), 64, 2)


def test_constant_deltas_take_width_zero_miniblocks() raises:
    var vals = List[Int]()
    for i in range(200):
        vals.append(1000 + 3 * i)
    _check_round_trip(vals, 128, 4)


def test_every_wide_bit_width_round_trips() raises:
    """Miniblock widths 50..63. Each delta is `min_delta + u` with `u` spread
    over exactly `spread` bits (the first two deltas are the extremes, so the
    first miniblock's width is `spread`). A width whose values straddle the
    64 bits of an 8-byte load at some bit offset (59, 61, 62, 63) needs the
    ninth byte. The min delta stays within the range the zigzag reader takes."""
    for spread in range(50, 64):
        var md = -(1 << (spread - 1))
        var top = (1 << spread) - 1
        var vals = List[Int]()
        vals.append(0)
        var x = spread * 104729 + 7
        for k in range(140):
            x = (x * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
            var u = 0 if k == 0 else (top if k == 1 else (x & top))
            vals.append(vals[len(vals) - 1] + md + u)
        _check_round_trip(vals, 128, 4, "spread=" + String(spread))


def test_wide_width_cut_inside_a_straddling_value() raises:
    """A width-61 miniblock cut 9 bytes short: a value that straddles the
    64-bit load window near the end has no ninth byte to read, and its
    missing bits read as zero; the values before the cut are exact."""
    var md = -(1 << 60)
    var top = (1 << 61) - 1
    var vals: List[Int] = [0]
    var x = 99
    for k in range(32):
        x = (x * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
        var u = 0 if k == 0 else (top if k == 1 else (x & top))
        vals.append(vals[len(vals) - 1] + md + u)
    var enc = _encode(vals, 128, 4)
    # 9 bytes off the 244 of the miniblock: value 30 (bit offset 6, at byte
    # 228) straddles, and its window runs past the 235 bytes left.
    var cut = List[UInt8]()
    for i in range(len(enc) - 9):
        cut.append(enc[i])
    var out = _filled64(33)
    var dec = DeltaDecoder(Span(cut))
    assert_equal(dec.decode_int64(33, Span(out)), 33)
    for i in range(29):
        assert_equal(Int(out[i]), vals[i], "i=" + String(i))


def test_width_64_miniblock() raises:
    """Deltas -2^62 and 2^63-1 are 64 bits apart: width 64, mask all ones."""
    var lo = -(1 << 62)
    var vals: List[Int] = [0, lo, lo + 0x7FFFFFFFFFFFFFFF, 5, -9]
    _check_round_trip(vals, 128, 4)


def test_int32_narrowing_and_its_tail() raises:
    var vals = _rand(37, 3, 30)
    var enc = _encode(vals, 128, 4)
    var out = List[Int32](capacity=40)
    out.resize(40, Int32(-5))
    var dec = DeltaDecoder(Span(enc))
    assert_equal(dec.decode_int32(37, Span(out)), 37)
    for i in range(37):
        assert_equal(Int(out[i]), vals[i])
    assert_equal(out[37], Int32(-5))


def test_requests_are_clamped_to_the_output_and_nonpositive_is_nothing() raises:
    var vals = _rand(100, 5, 12)
    var enc = _encode(vals, 128, 4)
    var out = _filled64(30)
    var dec = DeltaDecoder(Span(enc))
    assert_equal(dec.decode_int64(100, Span(out)[0:20]), 20)
    assert_equal(Int(out[19]), vals[19])
    assert_equal(out[20], Int64(-77))
    var dec2 = DeltaDecoder(Span(enc))
    assert_equal(dec2.decode_int64(0, Span(out)), 0)
    assert_equal(dec2.decode_int64(-3, Span(out)), 0)
    var o32 = List[Int32](capacity=4)
    o32.resize(4, Int32(0))
    assert_equal(dec2.decode_int32(0, Span(o32)), 0)
    var none = List[Int32]()
    assert_equal(dec2.decode_int32(5, Span(none)), 0)


def test_empty_and_truncated_streams() raises:
    var empty = List[UInt8]()
    var out = _filled64(4)
    var dec = DeltaDecoder(Span(empty))
    assert_equal(dec.decode_int64(4, Span(out)), 0)
    assert_equal(delta_binary_packed_byte_count(Span(empty), 4), 0)
    # A header cut inside its first varint: nothing, and the byte count is
    # the whole (torn) input.
    var torn: List[UInt8] = [0x80, 0x80]
    var dec2 = DeltaDecoder(Span(torn))
    assert_equal(dec2.decode_int64(4, Span(out)), 0)
    assert_equal(delta_binary_packed_byte_count(Span(torn), 4), 2)


def test_stream_ending_early_pads_with_the_last_value() raises:
    """Fewer encoded values than asked for: the tail repeats the last value.
    A stream cut inside a block's width table stops there too."""
    var one: List[Int] = [17]
    var enc = _encode(one, 128, 4)
    var out = _filled64(15)
    var dec = DeltaDecoder(Span(enc))
    assert_equal(dec.decode_int64(4, Span(out)), 4)
    for i in range(4):
        assert_equal(Int(out[i]), 17)
    assert_equal(out[4], Int64(-77))
    # Header, then a min delta and only two of the four widths.
    var cut = List[UInt8]()
    _uleb(cut, 128)
    _uleb(cut, 4)
    _uleb(cut, 5)
    _uleb(cut, _zz(42))
    _uleb(cut, _zz(1))
    cut.append(UInt8(0))
    cut.append(UInt8(0))
    var dec2 = DeltaDecoder(Span(cut))
    assert_equal(dec2.decode_int64(5, Span(out)), 5)
    assert_equal(Int(out[4]), 42)
    assert_equal(delta_binary_packed_byte_count(Span(cut), 5), len(cut) - 2)


def test_packed_bytes_cut_short_read_zero_high_bits() raises:
    """A miniblock whose packed bytes end early: the near-end byte loop reads
    only the bytes present (missing ones are zero), and never past them."""
    var vals: List[Int] = [0]
    for i in range(1, 33):
        vals.append(vals[i - 1] + (255 if i % 2 == 1 else 0))
    var enc = _encode(vals, 128, 4)
    var cut = List[UInt8]()
    for i in range(len(enc) - 3):
        cut.append(enc[i])
    var out = _filled64(40)
    var dec = DeltaDecoder(Span(cut))
    assert_equal(dec.decode_int64(33, Span(out)), 33)
    for i in range(30):
        assert_equal(Int(out[i]), vals[i])


def _degenerate(block: Int, mbc: Int, first: Int) -> List[UInt8]:
    var d = List[UInt8]()
    _uleb(d, block)
    _uleb(d, mbc)
    _uleb(d, 9)
    _uleb(d, _zz(first))
    # one block of width-0 miniblocks follows
    _uleb(d, _zz(1))
    for _ in range(4):
        d.append(UInt8(0))
    return d^


def test_degenerate_geometry_returns_the_first_value_only() raises:
    """Block size 0, miniblock count 0, or a miniblock size of 0 (a block
    smaller than its miniblock count): the first value, and nothing more."""
    var shapes: List[Int] = [0, 4, 128, 0, 3, 4]
    for k in range(3):
        var d = _degenerate(shapes[2 * k], shapes[2 * k + 1], -6)
        var out = _filled64(9)
        var dec = DeltaDecoder(Span(d))
        assert_equal(dec.decode_int64(9, Span(out)), 1, "shape " + String(k))
        assert_equal(Int(out[0]), -6)
        assert_equal(out[1], Int64(-77))


def test_negative_geometry_is_refused_like_zero() raises:
    """A ten-byte varint decodes to a negative Int. A negative block size or
    miniblock count is the first value only, and the byte count stops at the
    header, as for zero; the decoder never steps backwards."""
    var neg = -1
    for which in range(2):
        var d = _degenerate(neg if which == 0 else 128, 4 if which == 0 else neg, 11)
        var out = _filled64(9)
        var dec = DeltaDecoder(Span(d))
        assert_equal(dec.decode_int64(9, Span(out)), 1, "which " + String(which))
        assert_equal(Int(out[0]), 11)
        var header = len(d) - 5
        assert_equal(delta_binary_packed_byte_count(Span(d), 9), header)


def test_a_block_size_past_the_bound_is_refused() raises:
    """A block size of 2^62 makes a width-4 miniblock 2^63 bits long: its
    byte length overflows to a negative number, and the next miniblock would
    be read from before the page. It is refused like a zero block size."""
    var d = List[UInt8]()
    _uleb(d, 1 << 62)
    _uleb(d, 2)
    _uleb(d, 9)
    _uleb(d, _zz(-8))
    _uleb(d, _zz(1))
    d.append(UInt8(4))
    d.append(UInt8(4))
    for _ in range(64):
        d.append(UInt8(0x33))
    var out = _filled64(9)
    var dec = DeltaDecoder(Span(d))
    assert_equal(dec.decode_int64(9, Span(out)), 1)
    assert_equal(Int(out[0]), -8)
    assert_equal(out[1], Int64(-77))
    var header = len(d) - 64 - 3
    assert_equal(delta_binary_packed_byte_count(Span(d), 9), header)
    var dec2 = DeltaDecoder(Span(d))
    assert_true(not dec2.begin_resumable(9))
    # 2^31 itself is accepted (one 2^31-value miniblock of width 0).
    var ok = List[UInt8]()
    _uleb(ok, 1 << 31)
    _uleb(ok, 1)
    _uleb(ok, 3)
    _uleb(ok, _zz(2))
    _uleb(ok, _zz(5))
    ok.append(UInt8(0))
    var dec3 = DeltaDecoder(Span(ok))
    var o3 = _filled64(3)
    assert_equal(dec3.decode_int64(3, Span(o3)), 3)
    assert_equal(Int(o3[2]), 12)


def test_byte_count_skips_miniblocks_it_does_not_need() raises:
    """With fewer values than one block holds the count stops after the
    miniblocks those values use; a negative count is the header only."""
    var vals = _rand(20, 13, 9)
    var enc = _encode(vals, 128, 4)
    var used = delta_binary_packed_byte_count(Span(enc), 20)
    assert_equal(used, len(enc))
    var head = delta_binary_packed_byte_count(Span(enc), -2)
    assert_true(head > 0 and head < len(enc))


def test_the_byte_loop_arm_matches_the_memcpy_arm() raises:
    """With the gate off the constructor copies byte by byte; the decoded
    values are the same, and each arm counts its own pages."""
    reset_decode_arm_counts()
    var vals = _rand(77, 21, 18)
    var enc = _encode(vals, 128, 4)
    set_delta_page_memcpy_enabled(False)
    var slow = DeltaDecoder(Span(enc))
    set_delta_page_memcpy_enabled(True)
    var fast = DeltaDecoder(Span(enc))
    reset_decode_arm_gates()
    assert_equal(delta_page_bytecopy_count(), 1)
    assert_equal(delta_page_memcpy_count(), 1)
    var a = _filled64(77)
    var b = _filled64(77)
    assert_equal(slow.decode_int64(77, Span(a)), 77)
    assert_equal(fast.decode_int64(77, Span(b)), 77)
    for i in range(77):
        assert_equal(a[i], b[i])
        assert_equal(Int(a[i]), vals[i])
    var empty = List[UInt8]()
    _ = DeltaDecoder(Span(empty))
    assert_equal(delta_page_memcpy_count(), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

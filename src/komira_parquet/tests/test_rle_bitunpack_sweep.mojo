# =============================================================================
# The bit-packed runs of the RLE / Bit-Packing Hybrid, at every bit width.
#
# A test-local encoder packs values least significant bit first in 8-value
# groups (the format's own definition), and every case decodes through the
# public `RleDecoder` into an output whose slots past the requested count hold
# a sentinel, so a kernel that writes too far fails here as surely as one that
# writes a wrong value. Bit widths 1, 2, 4 and 8 reach the dedicated byte
# kernels, the widths {3, 5, 6, 7, 9..16, 20, 24, 32} the comptime-specialized
# SIMD kernel, and every other width up to 32 the runtime kernel.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet.rle import RleDecoder, RleRunResult

comptime _SENTINEL = Int32(-7)


def _uleb(mut out: List[UInt8], v: Int):
    var x = v
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _pack(values: List[Int], bit_width: Int, mut out: List[UInt8]):
    """Append `values` bit-packed at `bit_width`, padded to whole 8-value
    groups with zeros."""
    var groups = (len(values) + 7) // 8
    var start = len(out)
    for _ in range(groups * bit_width):
        out.append(UInt8(0))
    var bit = 0
    for i in range(groups * 8):
        var v = values[i] if i < len(values) else 0
        for k in range(bit_width):
            if (v >> k) & 1 == 1:
                var at = start + ((bit + k) >> 3)
                out[at] = out[at] | UInt8(1 << ((bit + k) & 7))
        bit += bit_width


def _bp_run(values: List[Int], bit_width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    _uleb(out, (((len(values) + 7) // 8) << 1) | 1)
    _pack(values, bit_width, out)
    return out^


def _values(n: Int, bit_width: Int, seed: Int) -> List[Int]:
    var out = List[Int]()
    var x = seed * 2654435761 + 12345
    var mask = (1 << bit_width) - 1
    for _ in range(n):
        x = (x * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
        out.append((x >> 17) & mask)
    return out^


def _filled(n: Int) -> List[Int32]:
    var out = List[Int32](capacity=n)
    out.resize(n, _SENTINEL)
    return out^


def _bits(v: Int32) -> Int:
    return Int(v) & 0xFFFFFFFF


comptime _COUNTS: List[Int] = [
    1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 24, 31, 32, 33, 63, 64, 65, 100,
    127, 128, 129, 256, 257, 1000,
]


def test_every_width_whole_runs() raises:
    """Bit widths 1..32, every count: the whole run decodes to its values and
    nothing is written past the requested count."""
    var counts = materialize[_COUNTS]()
    for bw in range(1, 33):
        for c in range(len(counts)):
            var n = counts[c]
            var vals = _values(n, bw, bw * 1000 + n)
            var enc = _bp_run(vals, bw)
            var out = _filled(n + 24)
            var dec = RleDecoder(Span(enc), bw)
            var got = dec.decode_int32(n, Span(out))
            assert_equal(got, n, "bw=" + String(bw) + " n=" + String(n))
            for i in range(n):
                assert_equal(_bits(out[i]), vals[i], "bw=" + String(bw) + " i=" + String(i))
            for i in range(n, n + 24):
                assert_equal(out[i], _SENTINEL, "overrun bw=" + String(bw))


def test_every_width_partial_decode() raises:
    """Asking for fewer values than the run holds stops every kernel at the
    request (the SIMD loop and the word loop both exit on the count, not on
    the input), and the rest of the run is skipped: `decode_int32` is not
    resumable inside a run."""
    for bw in range(1, 33):
        var n = 256
        var vals = _values(n, bw, bw)
        var enc = _bp_run(vals, bw)
        enc.append(UInt8(2 << 1))  # an RLE run of 2 ...
        for _ in range((bw + 7) // 8):
            enc.append(UInt8(1))  # ... of the value 1 (or 0x0101.. for wide)
        var want = 13
        var out = _filled(want + 16)
        var dec = RleDecoder(Span(enc), bw)
        assert_equal(dec.decode_int32(want, Span(out)), want)
        for i in range(want):
            assert_equal(_bits(out[i]), vals[i], "bw=" + String(bw))
        assert_equal(out[want], _SENTINEL)
        # The next call starts at the RLE run: the 243 values left in the
        # bit-packed run were dropped.
        var out2 = _filled(4)
        assert_equal(dec.decode_int32(4, Span(out2)), 2)
        var one = 0
        for b in range((bw + 7) // 8):
            one |= 1 << (8 * b)
        assert_equal(_bits(out2[0]), one & ((1 << 32) - 1))
        assert_equal(out2[2], _SENTINEL)


def test_every_width_truncated_input() raises:
    """A bit-packed run whose bytes end early: every kernel stops at the end
    of the input. A value whose first bit lies in the input is emitted (its
    missing high bits read as zero), so the count is ceil(bytes * 8 / bw)."""
    for bw in range(1, 33):
        var n = 64
        var vals = _values(n, bw, 7 * bw)
        var enc = _bp_run(vals, bw)
        var header = len(enc) - (n // 8) * bw
        var cuts: List[Int] = [1, 3, 9, 17]
        for k in range(len(cuts)):
            var keep = (n // 8) * bw - cuts[k]
            if keep <= 0:
                continue
            var cut = List[UInt8]()
            for i in range(header + keep):
                cut.append(enc[i])
            var out = _filled(n + 8)
            var dec = RleDecoder(Span(cut), bw)
            var got = dec.decode_int32(n, Span(out))
            var expect = min(n, (keep * 8 + bw - 1) // bw)
            assert_equal(got, expect, "bw=" + String(bw) + " keep=" + String(keep))
            var whole = (keep * 8) // bw
            for i in range(whole):
                assert_equal(_bits(out[i]), vals[i], "bw=" + String(bw))
            if whole < got:
                # The straddling value keeps the bits that are present.
                var have = keep * 8 - whole * bw
                assert_equal(_bits(out[whole]), vals[whole] & ((1 << have) - 1))
            assert_equal(out[got], _SENTINEL)


def test_width_zero_bitpacked_run_decodes_nothing() raises:
    """Pins what the decoder does with a bit-packed run of width 0: it
    occupies no bytes and the kernel emits no value, so the run's 8 values
    are not produced (the format would read them as zeros). Width-0 levels
    arrive as RLE runs, which decode (see test_rle_decoder_direct)."""
    var enc = _bp_run(_values(8, 0, 1), 0)
    var out = _filled(8)
    var dec = RleDecoder(Span(enc), 0)
    assert_equal(dec.decode_int32(8, Span(out)), 0)
    assert_equal(out[0], _SENTINEL)


def test_decode_run_every_width_group_aligned() raises:
    """`decode_run_int32` decodes a bit-packed run group by group: with a cap
    of 16 a 64-value run comes back in four calls of 16, then the stream is
    exhausted. Every kernel class is reached through the resumable path."""
    for bw in range(1, 33):
        var vals = _values(64, bw, 3 * bw)
        var enc = _bp_run(vals, bw)
        var dec = RleDecoder(Span(enc), bw)
        var got = List[Int]()
        for call in range(4):
            var out = _filled(16 + 4)
            var r = dec.decode_run_int32(Span(out), 16)
            assert_equal(r.written, 16, "bw=" + String(bw) + " call=" + String(call))
            assert_equal(r.rle_leftover, 0)
            assert_true(not r.exhausted)
            assert_equal(out[16], _SENTINEL)
            for i in range(16):
                got.append(_bits(out[i]))
        for i in range(64):
            assert_equal(got[i], vals[i], "bw=" + String(bw))
        var end = _filled(16)
        var last = dec.decode_run_int32(Span(end), 16)
        assert_equal(last.written, 0)
        assert_true(last.exhausted)


def test_decode_run_cap_below_a_group_makes_no_progress() raises:
    """A cap under 8 with a run parked: no value, not exhausted, and the run
    stays parked for a later call with room."""
    var vals = _values(16, 5, 11)
    var enc = _bp_run(vals, 5)
    var dec = RleDecoder(Span(enc), 5)
    var out = _filled(16)
    var r = dec.decode_run_int32(Span(out), 7)
    assert_equal(r.written, 0)
    assert_true(not r.exhausted)
    assert_equal(out[0], _SENTINEL)
    var r2 = dec.decode_run_int32(Span(out), 16)
    assert_equal(r2.written, 16)
    for i in range(16):
        assert_equal(_bits(out[i]), vals[i])


def test_decode_run_cap_is_clamped_to_the_output() raises:
    """A cap larger than the output Span is cut to the Span's length: a
    64-value run into an 8-slot Span comes back 8 at a time."""
    var vals = _values(64, 9, 5)
    var enc = _bp_run(vals, 9)
    var dec = RleDecoder(Span(enc), 9)
    var small = _filled(8)
    var r = dec.decode_run_int32(Span(small), 1000)
    assert_equal(r.written, 8)
    for i in range(8):
        assert_equal(_bits(small[i]), vals[i])


def test_decode_int32_is_clamped_to_the_output() raises:
    """Asking for more values than the output Span holds decodes only what
    fits: no slot past the Span is written."""
    var vals = _values(64, 12, 9)
    var enc = _bp_run(vals, 12)
    var dec = RleDecoder(Span(enc), 12)
    var out = _filled(40)
    var sub = Span(out)[0:24]
    assert_equal(dec.decode_int32(64, sub), 24)
    for i in range(24):
        assert_equal(_bits(out[i]), vals[i])
    for i in range(24, 40):
        assert_equal(out[i], _SENTINEL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

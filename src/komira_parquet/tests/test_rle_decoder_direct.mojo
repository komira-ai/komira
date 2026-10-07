# =============================================================================
# RleDecoder's RLE runs, its refusals, and the level-section functions.
#
# Hand-built streams (RLE run = ULEB128(count << 1), then the value in
# ceil(bit_width / 8) little-endian bytes) exercise every arm of the decoder
# that the bit-packed sweep does not: zero and non-zero runs, short and long
# runs (the paired fill and its odd tail), a run whose value bytes are cut
# off, a header cut off mid-varint, and the run-aligned `decode_run_int32`
# with a leftover and with a cap of zero or less. The level functions are held to the V1 layout
# `[i32 LE length][hybrid bytes]`, including the negative and oversized
# length prefixes they must refuse.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet.rle import (
    RleDecoder,
    bit_width_for_max_level,
    decode_def_levels,
    decode_def_levels_u8,
    decode_levels,
    decode_rle_int32,
    read_uleb128,
    validate_level_section_length,
)

comptime _SENTINEL = Int32(-7)


def _uleb(mut out: List[UInt8], v: Int):
    var x = v
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _rle(mut out: List[UInt8], count: Int, value: Int, bit_width: Int):
    _uleb(out, count << 1)
    for b in range((bit_width + 7) // 8):
        out.append(UInt8((value >> (8 * b)) & 0xFF))


def _filled(n: Int) -> List[Int32]:
    var out = List[Int32](capacity=n)
    out.resize(n, _SENTINEL)
    return out^


def _level_section(body: List[UInt8], declared: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for b in range(4):
        out.append(UInt8((declared >> (8 * b)) & 0xFF))
    for i in range(len(body)):
        out.append(body[i])
    return out^


def _raises_with(msg: String, e: Error) -> Bool:
    return String(e).find(msg) >= 0


# -----------------------------------------------------------------------------
# read_uleb128
# -----------------------------------------------------------------------------


def test_read_uleb128_values_and_offsets() raises:
    var d: List[UInt8] = [0x00, 0x7F, 0xE5, 0x8E, 0x26, 0x05]
    var r = read_uleb128(Span(d), 0)
    assert_equal(r[0], 0)
    assert_equal(r[1], 1)
    r = read_uleb128(Span(d), 1)
    assert_equal(r[0], 127)
    r = read_uleb128(Span(d), 2)
    assert_equal(r[0], 624485)
    assert_equal(r[1], 3)


def test_read_uleb128_stops_at_the_end_of_the_input() raises:
    """A varint whose continuation bit runs off the end returns the bits it
    read and the bytes it consumed, never a byte past the Span."""
    var d: List[UInt8] = [0x81, 0x82]
    var r = read_uleb128(Span(d), 0)
    assert_equal(r[0], 1 | (2 << 7))
    assert_equal(r[1], 2)
    # An offset at or past the end, or negative, reads nothing.
    r = read_uleb128(Span(d), 2)
    assert_equal(r[0], 0)
    assert_equal(r[1], 0)
    r = read_uleb128(Span(d), -1)
    assert_equal(r[1], 0)


def test_read_uleb128_stops_after_ten_bytes() raises:
    """Ten continuation bytes stop the read at 64 bits of shift."""
    var d = List[UInt8]()
    for _ in range(12):
        d.append(UInt8(0x80))
    var r = read_uleb128(Span(d), 0)
    assert_equal(r[0], 0)
    assert_equal(r[1], 10)


# -----------------------------------------------------------------------------
# The constructor
# -----------------------------------------------------------------------------


def test_constructor_refuses_bit_widths_outside_0_to_32() raises:
    var d: List[UInt8] = [0x02, 0x01]
    var widths: List[Int] = [-1, 33, 65, 255]
    for i in range(len(widths)):
        var raised = False
        try:
            _ = RleDecoder(Span(d), widths[i])
        except e:
            raised = _raises_with("outside the Parquet-legal range", e)
        assert_true(raised, "bit width " + String(widths[i]))
    # 0 and 32 are legal.
    _ = RleDecoder(Span(d), 0)
    _ = RleDecoder(Span(d), 32)


def test_empty_stream_decodes_nothing() raises:
    var d = List[UInt8]()
    var dec = RleDecoder(Span(d), 3)
    var out = _filled(4)
    assert_equal(dec.decode_int32(4, Span(out)), 0)
    assert_equal(out[0], _SENTINEL)
    var r = dec.decode_run_int32(Span(out), 4)
    assert_true(r.exhausted)
    assert_equal(r.written, 0)


# -----------------------------------------------------------------------------
# RLE runs through decode_int32
# -----------------------------------------------------------------------------


def test_rle_runs_zero_short_long_odd_and_even() raises:
    """A zero run (memset arm), a long odd run (paired fill and its tail), a
    long even run (no tail), and a short run (the per-value loop)."""
    var d = List[UInt8]()
    _rle(d, 5, 0, 3)
    _rle(d, 9, 6, 3)
    _rle(d, 10, 5, 3)
    _rle(d, 3, 7, 3)
    var out = _filled(32)
    var dec = RleDecoder(Span(d), 3)
    assert_equal(dec.decode_int32(27, Span(out)), 27)
    for i in range(5):
        assert_equal(out[i], 0)
    for i in range(5, 14):
        assert_equal(out[i], 6)
    for i in range(14, 24):
        assert_equal(out[i], 5)
    for i in range(24, 27):
        assert_equal(out[i], 7)
    assert_equal(out[27], _SENTINEL)


def test_rle_run_value_is_little_endian_over_ceil_bw_8_bytes() raises:
    """Widths 9..16 take two value bytes, 17..24 three, 25..32 four; width 0
    takes none and decodes zeros."""
    var cases: List[Int] = [0, 1, 8, 9, 16, 17, 24, 25, 32]
    for c in range(len(cases)):
        var bw = cases[c]
        var value = 0 if bw == 0 else ((1 << bw) - 1) & 0x7EDCBA98
        var d = List[UInt8]()
        _rle(d, 3, value, bw)
        var out = _filled(4)
        var dec = RleDecoder(Span(d), bw)
        assert_equal(dec.decode_int32(3, Span(out)), 3, "bw=" + String(bw))
        assert_equal(Int(out[2]) & 0xFFFFFFFF, value, "bw=" + String(bw))
        assert_equal(out[3], _SENTINEL)


def test_rle_run_longer_than_the_request_is_cut_to_it() raises:
    var d = List[UInt8]()
    _rle(d, 100, 4, 4)
    var out = _filled(12)
    var dec = RleDecoder(Span(d), 4)
    assert_equal(dec.decode_int32(10, Span(out)), 10)
    assert_equal(out[9], 4)
    assert_equal(out[10], _SENTINEL)


def test_rle_run_with_its_value_cut_off_stops() raises:
    """A run header whose value bytes are missing ends the decode."""
    var d = List[UInt8]()
    _rle(d, 2, 1, 16)
    _uleb(d, 4 << 1)
    d.append(UInt8(9))  # one of the two value bytes of a width-16 run
    var out = _filled(8)
    var dec = RleDecoder(Span(d), 16)
    assert_equal(dec.decode_int32(8, Span(out)), 2)
    assert_equal(out[2], _SENTINEL)


def test_header_cut_off_mid_varint_stops() raises:
    """A run header whose varint never terminates ends the decode with what
    was decoded before it."""
    var d = List[UInt8]()
    _rle(d, 3, 1, 1)
    d.append(UInt8(0x80))
    var out = _filled(8)
    var dec = RleDecoder(Span(d), 1)
    assert_equal(dec.decode_int32(8, Span(out)), 3)
    assert_equal(out[3], _SENTINEL)


def test_decode_rle_int32_wrapper() raises:
    var d = List[UInt8]()
    _rle(d, 4, 2, 2)
    var out = _filled(6)
    assert_equal(decode_rle_int32(Span(d), 2, 6, Span(out)), 4)
    assert_equal(out[3], 2)
    assert_equal(out[4], _SENTINEL)
    var raised = False
    try:
        _ = decode_rle_int32(Span(d), 40, 6, Span(out))
    except:
        raised = True
    assert_true(raised, "an illegal bit width raises")


# -----------------------------------------------------------------------------
# RLE runs through decode_run_int32
# -----------------------------------------------------------------------------


def test_decode_run_rle_arm_with_leftover() raises:
    """An RLE run longer than the cap returns `cap` values, the value, and the
    count left over; a zero run takes the memset arm; a run whose value bytes
    are missing, or a header cut mid-varint, is exhausted."""
    var d = List[UInt8]()
    _rle(d, 20, 3, 2)
    _rle(d, 5, 0, 2)
    var dec = RleDecoder(Span(d), 2)
    var out = _filled(8)
    var r = dec.decode_run_int32(Span(out), 8)
    assert_equal(r.written, 8)
    assert_equal(Int(r.rle_value), 3)
    assert_equal(r.rle_leftover, 12)
    assert_true(not r.exhausted)
    assert_equal(out[7], 3)
    var z = _filled(8)
    var r2 = dec.decode_run_int32(Span(z), 8)
    assert_equal(r2.written, 5)
    assert_equal(r2.rle_leftover, 0)
    assert_equal(z[4], 0)
    assert_equal(z[5], _SENTINEL)

    var cut = List[UInt8]()
    _uleb(cut, 3 << 1)  # a width-9 run needs two value bytes; none follow
    var dec2 = RleDecoder(Span(cut), 9)
    var r3 = dec2.decode_run_int32(Span(out), 8)
    assert_true(r3.exhausted)

    var torn: List[UInt8] = [0xFF]
    var dec3 = RleDecoder(Span(torn), 2)
    var r4 = dec3.decode_run_int32(Span(out), 8)
    assert_true(r4.exhausted)
    assert_equal(r4.written, 0)


def test_decode_run_a_cap_of_zero_or_less_writes_nothing() raises:
    """A cap of 0 or less writes nothing and reports nothing written: the RLE
    run is parked whole in `rle_leftover`, for a zero run (the memset arm)
    and a non-zero one. Without the lower clamp a cap of -1 reaches the RLE
    arm as a count of -1: `written` comes back -1, `rle_leftover` run_len + 1,
    and the zero run memsets a negative length."""
    var caps: List[Int] = [-1, 0, -1000]
    var values: List[Int] = [0, 3]
    for c in range(len(caps)):
        for v in range(len(values)):
            var d = List[UInt8]()
            _rle(d, 4, values[v], 2)
            var dec = RleDecoder(Span(d), 2)
            var out = _filled(8)
            var r = dec.decode_run_int32(Span(out), caps[c])
            var tag = "cap " + String(caps[c]) + " value " + String(values[v])
            assert_equal(r.written, 0, tag)
            assert_equal(r.rle_leftover, 4, tag)
            assert_equal(Int(r.rle_value), values[v], tag)
            assert_true(not r.exhausted, tag)
            for i in range(8):
                assert_equal(out[i], _SENTINEL, tag)


def _neg_header(low_bit: Int) -> List[UInt8]:
    """A ten-byte varint with bit 63 set: it decodes to a negative Int."""
    var d = List[UInt8]()
    d.append(UInt8(0xFE | low_bit))
    for _ in range(8):
        d.append(UInt8(0xFF))
    d.append(UInt8(0x01))
    return d^


def test_a_negative_run_header_is_corrupt_and_writes_nothing() raises:
    """A negative RLE header would make the run count negative: a zero run
    would then memset a negative length, and `decoded` would move backwards.
    Both decoders stop at it, and the output is untouched."""
    var d = _neg_header(0)
    d.append(UInt8(0))  # the run's (zero) value byte
    var out = _filled(8)
    var dec = RleDecoder(Span(d), 8)
    assert_equal(dec.decode_int32(8, Span(out)), 0)
    assert_equal(out[0], _SENTINEL)
    var dec2 = RleDecoder(Span(d), 8)
    var r = dec2.decode_run_int32(Span(out), 8)
    assert_true(r.exhausted)
    assert_equal(r.written, 0)
    assert_equal(out[0], _SENTINEL)


def test_a_huge_run_header_is_corrupt() raises:
    """A bit-packed header claiming 2^60 groups (past the 2^57 header bound)
    stops both decoders before its byte length overflows; values decoded
    before it are kept."""
    var d = List[UInt8]()
    _rle(d, 2, 3, 4)
    _uleb(d, ((1 << 60) << 1) | 1)
    for _ in range(16):
        d.append(UInt8(0x11))
    var out = _filled(8)
    var dec = RleDecoder(Span(d), 4)
    assert_equal(dec.decode_int32(8, Span(out)), 2)
    assert_equal(out[2], _SENTINEL)
    var dec2 = RleDecoder(Span(d), 4)
    var first = dec2.decode_run_int32(Span(out), 8)
    assert_equal(first.written, 2)
    var r = dec2.decode_run_int32(Span(out), 8)
    assert_true(r.exhausted)
    var neg = _neg_header(1)
    var dec3 = RleDecoder(Span(neg), 4)
    assert_equal(dec3.decode_int32(8, Span(out)), 0)


# -----------------------------------------------------------------------------
# Level sections
# -----------------------------------------------------------------------------


def test_validate_level_section_length() raises:
    validate_level_section_length(0, 4)
    validate_level_section_length(6, 10)
    var bad: List[Int] = [-1, -2147483648, 7]
    for i in range(len(bad)):
        var raised = False
        try:
            validate_level_section_length(bad[i], 10)
        except e:
            raised = _raises_with("corrupt level section", e)
        assert_true(raised, "declared " + String(bad[i]))


def test_decode_levels_reads_the_prefix_and_steps_over_it() raises:
    var body = List[UInt8]()
    _rle(body, 6, 2, 2)
    var sec = _level_section(body, len(body))
    sec.append(UInt8(0xAB))  # the page's values follow the section
    var out = _filled(8)
    var r = decode_levels(Span(sec), 6, 2, Span(out))
    assert_equal(r[0], 6)
    assert_equal(r[1], 4 + len(body))
    assert_equal(out[5], 2)
    assert_equal(out[6], _SENTINEL)


def test_decode_levels_width_zero_writes_zeros_and_consumes_nothing() raises:
    var sec = List[UInt8]()
    var out = _filled(5)
    var r = decode_levels(Span(sec), 4, 0, Span(out))
    assert_equal(r[0], 4)
    assert_equal(r[1], 0)
    assert_equal(out[3], 0)
    assert_equal(out[4], _SENTINEL)


def test_decode_levels_short_section_and_zero_count() raises:
    var three: List[UInt8] = [1, 0, 0]
    var out = _filled(4)
    var r = decode_levels(Span(three), 4, 1, Span(out))
    assert_equal(r[0], 0)
    assert_equal(r[1], 3)
    var body = List[UInt8]()
    _rle(body, 2, 1, 1)
    var sec = _level_section(body, len(body))
    r = decode_levels(Span(sec), 0, 1, Span(out))
    assert_equal(r[0], 0)
    assert_equal(r[1], 4)


def test_decode_levels_refuses_negative_and_oversized_prefixes() raises:
    """A negative length would walk the caller's values pointer before the
    page; an oversized one past it. Both raise before anything is decoded."""
    var body = List[UInt8]()
    _rle(body, 2, 1, 1)
    var lens: List[Int] = [-4, -2147483648, len(body) + 1]
    for i in range(len(lens)):
        var sec = _level_section(body, lens[i])
        var out = _filled(4)
        var raised = False
        try:
            _ = decode_levels(Span(sec), 2, 1, Span(out))
        except e:
            raised = _raises_with("corrupt level section", e)
        assert_true(raised, "declared " + String(lens[i]))
        assert_equal(out[0], _SENTINEL)


def test_decode_levels_refuses_an_output_too_small() raises:
    var body = List[UInt8]()
    _rle(body, 8, 1, 1)
    var sec = _level_section(body, len(body))
    var out = _filled(3)
    var raised = False
    try:
        _ = decode_levels(Span(sec), 8, 1, Span(out))
    except e:
        raised = _raises_with("level output holds 3 values but 8", e)
    assert_true(raised)
    raised = False
    try:
        _ = decode_levels(Span(sec), 8, 0, Span(out))
    except:
        raised = True
    assert_true(raised, "width 0 is checked too")
    assert_equal(out[0], _SENTINEL)


def test_decode_levels_refuses_an_illegal_width() raises:
    var body = List[UInt8]()
    _rle(body, 2, 1, 1)
    var sec = _level_section(body, len(body))
    var out = _filled(4)
    var raised = False
    try:
        _ = decode_levels(Span(sec), 2, 33, Span(out))
    except:
        raised = True
    assert_true(raised)


def test_decode_def_levels_is_width_one() raises:
    var body = List[UInt8]()
    _rle(body, 3, 1, 1)
    _rle(body, 2, 0, 1)
    var sec = _level_section(body, len(body))
    var out = _filled(6)
    var r = decode_def_levels(Span(sec), 5, Span(out))
    assert_equal(r[0], 5)
    assert_equal(r[1], 4 + len(body))
    assert_equal(out[2], 1)
    assert_equal(out[3], 0)
    assert_equal(out[5], _SENTINEL)


def test_decode_def_levels_u8_short_input_and_clamp() raises:
    """Under four bytes nothing is decoded and every row reads null; a level
    above 1 still reads as non-null."""
    var two: List[UInt8] = [1, 2]
    var out = decode_def_levels_u8(Span(two), 3)
    assert_equal(len(out), 3)
    assert_equal(Int(out[0]), 0)
    var body = List[UInt8]()
    _rle(body, 2, 3, 1)  # value byte 3 in a width-1 stream
    var sec = _level_section(body, len(body))
    var vals = decode_def_levels_u8(Span(sec), 2)
    assert_equal(Int(vals[0]), 1)
    assert_equal(Int(vals[1]), 1)
    assert_equal(len(decode_def_levels_u8(Span(sec), -1)), 0)


def test_bit_width_for_max_level() raises:
    assert_equal(bit_width_for_max_level(0), 0)
    assert_equal(bit_width_for_max_level(1), 1)
    assert_equal(bit_width_for_max_level(2), 2)
    assert_equal(bit_width_for_max_level(3), 2)
    assert_equal(bit_width_for_max_level(4), 3)
    assert_equal(bit_width_for_max_level(255), 8)
    assert_equal(bit_width_for_max_level(256), 9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

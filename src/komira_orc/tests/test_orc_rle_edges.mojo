# =============================================================================
# test_orc_rle_edges.mojo — integer RLE run shapes and refusals the
# whole-file tests do not reach.
# =============================================================================
#
# Every stream below is hand-assembled from the ORC v1 spec's run layouts
# (the expected values are worked from the spec, not read back from the
# decoder):
#
#   T1  RLEv1: a final REPEAT run longer than the requested count is cut to
#       the count (the decoder's `len(out) == count` post-condition).
#   T2  count refusals: a negative count, a count no stream of that size can
#       back (and the largest count that passes the bound).
#   T3  RLEv2 run refusals: a run longer than the destination, an encoded
#       width above 31.
#   T4  DIRECT at 32 bits with a run of 3 (the per-value tail of the 32-bit
#       unpack); DIRECT at 5 bits on a truncated stream (the per-byte path).
#   T5  PATCHED_BASE: a 2-byte negative base with no patch list; two patches
#       (cumulative gap); a patch index past the run; patch widths summing to
#       64 (accepted) and 65 (refused).
#   T6  DELTA: runs of 1 and 2 values; a fixed-delta run of 13 values (the
#       per-value tail after the vector body).
#   T7  SHORT_REPEAT on a stream holding fewer value bytes than its width.
#   T8  The span-writing entry points: RLEv2 and RLEv1 destination refusals,
#       and RLEv1 written at an element offset (cut to the count).
#   T9  OrcIntReader: an 11-byte continuation run, a varint cut at the end, a
#       byte read past the end.
#   T10 encode_int_rle_v2: values whose widths map to the non-contiguous
#       encoded widths 24 / 25 / 26 / 29, and a Short Repeat of a value wider
#       than one byte, each round-tripped through decode_rlev2.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_orc import (
    OrcIntReader,
    decode_rlev1,
    decode_rlev2,
    rlev2_decode_bit_width,
    encode_int_rle_v2,
)
from komira_orc.rle_decode import (
    decode_rlev2_into_span,
    decode_int_rle_into_span,
    _unpack_bits,
)
from komira_orc.rle_encode import _encode_bit_width, _pack_bits


def _b(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _i64_at(buf: List[UInt8], slot: Int) -> Int64:
    """Little-endian Int64 at element `slot` of a byte buffer."""
    var v: UInt64 = 0
    for k in range(8):
        v |= UInt64(buf[slot * 8 + k]) << UInt64(8 * k)
    return Int64(v)


# -----------------------------------------------------------------------------
# T1 — RLEv1 surplus.
# -----------------------------------------------------------------------------


def test_rlev1_final_run_cut_to_count() raises:
    # REPEAT run: header 0 (3 values), delta +1, base 5 -> [5, 6, 7].
    var d = _b(0x00, 0x01, 0x05)
    var two = decode_rlev1(Span(d), 2, False)
    assert_equal(len(two), 2)
    assert_equal(two[0], 5)
    assert_equal(two[1], 6)
    var three = decode_rlev1(Span(d), 3, False)
    assert_equal(len(three), 3)
    assert_equal(three[2], 7)
    # A LITERAL run of 2 (header 0xFE) asked for 1 value.
    var lit = _b(0xFE, 0x09, 0x0A)
    var one = decode_rlev1(Span(lit), 1, False)
    assert_equal(len(one), 1)
    assert_equal(one[0], 9)


# -----------------------------------------------------------------------------
# T2 — count refusals.
# -----------------------------------------------------------------------------


def test_count_refusals() raises:
    var d = _b(0x00, 0x01, 0x05)
    with assert_raises(contains="BAD_COUNT: RLEv1 value count is negative (-1)"):
        _ = decode_rlev1(Span(d), -1, False)
    with assert_raises(
        contains="COUNT_EXCEEDS_STREAM: RLEv2 declares 1537 values but the stream holds only 3 bytes (max 512 values/byte)"
    ):
        _ = decode_rlev2(Span(d), 1537, False)
    # 3 * 512 passes the bound; the stream then runs out (a different error).
    with assert_raises(contains="TRUNCATED"):
        _ = decode_rlev1(Span(d), 1536, False)


# -----------------------------------------------------------------------------
# T3 — RLEv2 run refusals.
# -----------------------------------------------------------------------------


def test_rlev2_run_refusals() raises:
    # SHORT_REPEAT W=1 R=5 (header 0x02), value 7, into a 3-value destination.
    var sr = _b(0x02, 0x07)
    with assert_raises(
        contains="RUN_OVERRUN: RLEv2 SHORT_REPEAT run declares 5 values at offset 0 but the destination holds only 3"
    ):
        _ = decode_rlev2(Span(sr), 3, False)
    var ok = decode_rlev2(Span(sr), 5, False)
    assert_equal(len(ok), 5)
    assert_equal(ok[4], 7)

    assert_equal(rlev2_decode_bit_width(31), 64)
    with assert_raises(contains="BAD_WIDTH: encoded width 32 > 31"):
        _ = rlev2_decode_bit_width(32)


# -----------------------------------------------------------------------------
# T4 — DIRECT 32-bit tail; DIRECT on a truncated stream.
# -----------------------------------------------------------------------------


def test_direct_w32_tail_and_truncated() raises:
    # DIRECT, encoded width 27 (32 bits), L=3: 0x40 | 27 << 1 = 0x76, L-1 = 2.
    var d = _b(
        0x76, 0x02,
        0x01, 0x02, 0x03, 0x04,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0x07,
    )
    var v = decode_rlev2(Span(d), 3, False)
    assert_equal(v[0], 0x01020304)
    assert_equal(v[1], 0xFFFFFFFF)
    assert_equal(v[2], 7)
    # Signed: zigzag 0xFFFFFFFF -> -2147483648, zigzag 7 -> -4.
    var s = decode_rlev2(Span(d), 3, True)
    assert_equal(s[1], -2147483648)
    assert_equal(s[2], -4)

    # DIRECT 5 bits (encoded 4: 0x48), L=8 needs 5 bytes; only 2 present.
    var t = _b(0x48, 0x07, 0x08, 0x80)
    with assert_raises(contains="TRUNCATED: stream overrun reading byte"):
        _ = decode_rlev2(Span(t), 8, False)
    # The same run with all 5 bytes: 00001 00010 00000 00011 00000 ... decodes.
    # bits: 00001000 10000000 00110000 00000000 00000000
    var full = _b(0x48, 0x07, 0x08, 0x80, 0x30, 0x00, 0x00)
    var f = decode_rlev2(Span(full), 8, False)
    assert_equal(f[0], 1)
    assert_equal(f[1], 2)
    assert_equal(f[2], 0)
    assert_equal(f[3], 3)
    assert_equal(f[4], 0)


# -----------------------------------------------------------------------------
# T5 — PATCHED_BASE.
# -----------------------------------------------------------------------------


def test_patched_base_shapes() raises:
    # W=4 (enc 3), L=4: byte0 0x86, byte1 3.
    # byte2: BW=2 -> (1 << 5) | enc_pw 3 = 0x23; byte3: PGW=1, PLL=0 -> 0x00.
    # base 0x80 0x0A: sign bit set, magnitude 10 -> -10. data 1,2,3,4.
    var nopatch = _b(0x86, 0x03, 0x23, 0x00, 0x80, 0x0A, 0x12, 0x34)
    var a = decode_rlev2(Span(nopatch), 4, False)
    assert_equal(a[0], -9)
    assert_equal(a[1], -8)
    assert_equal(a[2], -7)
    assert_equal(a[3], -6)

    # Two patches, PW=4, PGW=2 (6-bit entries): (gap 1, patch 1), (gap 2,
    # patch 3) -> indices 1 and 3. base 5.
    # entries 010001 100011 + pad -> 0x46 0x30.
    var two = _b(0x86, 0x03, 0x03, 0x22, 0x05, 0x12, 0x34, 0x46, 0x30)
    var b = decode_rlev2(Span(two), 4, False)
    assert_equal(b[0], 6)  # 1 + 5
    assert_equal(b[1], 23)  # (2 | 1 << 4) + 5
    assert_equal(b[2], 8)  # 3 + 5
    assert_equal(b[3], 57)  # (4 | 3 << 4) + 5

    # Second gap 3: index 1 + 3 = 4 is past the 4-value run.
    var oob = _b(0x86, 0x03, 0x03, 0x22, 0x05, 0x12, 0x34, 0x47, 0x30)
    with assert_raises(
        contains="PATCH_INDEX_OUT_OF_RUN: patch 1 targets index 4 in a run of 4 values"
    ):
        _ = decode_rlev2(Span(oob), 4, False)

    # PGW 8 + PW 56 (enc 30) = 64 bits: accepted (no patches to apply).
    var w64 = _b(0x86, 0x03, 0x1E, 0xE0, 0x00, 0x12, 0x34)
    var c = decode_rlev2(Span(w64), 4, False)
    assert_equal(c[3], 4)
    # PGW 1 + PW 64 (enc 31) = 65 bits: refused.
    var w65 = _b(0x86, 0x03, 0x1F, 0x00, 0x00, 0x12, 0x34)
    with assert_raises(
        contains="BAD_PATCH_WIDTH: PATCHED_BASE gap width 1 + patch width 64 exceeds 64 bits"
    ):
        _ = decode_rlev2(Span(w65), 4, False)


# -----------------------------------------------------------------------------
# T6 — DELTA short runs and fixed-delta tail.
# -----------------------------------------------------------------------------


def test_delta_short_runs_and_tail() raises:
    # L=1: [0xC0, 0x00, base 7, delta zz(3)=6]; L=2: [0xC0, 0x01, 7, 6].
    var d = _b(0xC0, 0x00, 0x07, 0x06, 0xC0, 0x01, 0x07, 0x06)
    var v = decode_rlev2(Span(d), 3, False)
    assert_equal(len(v), 3)
    assert_equal(v[0], 7)
    assert_equal(v[1], 7)
    assert_equal(v[2], 10)

    # Fixed delta (width 0), L=13, base 0, delta zz(5)=10 -> 0, 5, ..., 60.
    var f = _b(0xC0, 0x0C, 0x00, 0x0A)
    var fv = decode_rlev2(Span(f), 13, False)
    for i in range(13):
        assert_equal(fv[i], Int64(5 * i))
    # Signed, fixed delta -1, L=5: base zz(2) = 1, delta zz(1) = -1
    # -> 1, 0, -1, -2, -3.
    var g = _b(0xC0, 0x04, 0x02, 0x01)
    var gv = decode_rlev2(Span(g), 5, True)
    assert_equal(gv[0], 1)  # signed base: zz(2) = 1
    assert_equal(gv[4], -3)


# -----------------------------------------------------------------------------
# T7 — SHORT_REPEAT with too few value bytes.
# -----------------------------------------------------------------------------


def test_short_repeat_truncated() raises:
    # W=4 (3 << 3 = 0x18), R=3; only 2 of the 4 value bytes present.
    var d = _b(0x18, 0x01, 0x02)
    with assert_raises(contains="TRUNCATED: stream overrun reading byte"):
        _ = decode_rlev2(Span(d), 3, False)
    var full = _b(0x18, 0x01, 0x02, 0x03, 0x04)
    var v = decode_rlev2(Span(full), 3, False)
    assert_equal(v[2], 0x01020304)


# -----------------------------------------------------------------------------
# T8 — the span-writing entry points.
# -----------------------------------------------------------------------------


def test_span_entry_points() raises:
    var sr = _b(0x00, 0x07)  # SHORT_REPEAT W=1 R=3, value 7
    var dst = List[UInt8]()
    for _ in range(32):
        dst.append(0xEE)

    with assert_raises(
        contains="BAD_DESTINATION: element start -1 / count 3 must both be non-negative"
    ):
        decode_rlev2_into_span(Span(sr), 3, False, Span(dst), -1)
    with assert_raises(
        contains="DESTINATION_OVERRUN: decoding 3 values at element 2 needs 40 bytes but the output buffer holds 32"
    ):
        decode_rlev2_into_span(Span(sr), 3, False, Span(dst), 2)
    decode_rlev2_into_span(Span(sr), 3, False, Span(dst), 1)
    assert_equal(dst[0], 0xEE)  # slot 0 untouched
    assert_equal(_i64_at(dst, 1), 7)
    assert_equal(_i64_at(dst, 3), 7)

    # RLEv1 through decode_int_rle_into_span: REPEAT 3 values 5,6,7.
    var v1 = _b(0x00, 0x01, 0x05)
    var d1 = List[UInt8]()
    for _ in range(40):
        d1.append(0)
    with assert_raises(
        contains="BAD_DESTINATION: element start 0 / count -2 must both be non-negative"
    ):
        decode_int_rle_into_span(Span(v1), -2, False, False, Span(d1), 0)
    with assert_raises(
        contains="DESTINATION_OVERRUN: decoding 2 RLEv1 values at element 4 needs 6 Int64 slots but the output buffer holds 5"
    ):
        decode_int_rle_into_span(Span(v1), 2, False, False, Span(d1), 4)
    # Two of the run's three values at element 2: slot 2 = 5, slot 3 = 6,
    # and the run's third value is written nowhere (slot 4 stays 0).
    decode_int_rle_into_span(Span(v1), 2, False, False, Span(d1), 2)
    assert_equal(_i64_at(d1, 0), 0)
    assert_equal(_i64_at(d1, 1), 0)
    assert_equal(_i64_at(d1, 2), 5)
    assert_equal(_i64_at(d1, 3), 6)
    assert_equal(_i64_at(d1, 4), 0)
    # The whole run at element 1 (exactly fills slots 1..3).
    decode_int_rle_into_span(Span(v1), 3, False, False, Span(d1), 1)
    assert_equal(_i64_at(d1, 1), 5)
    assert_equal(_i64_at(d1, 3), 7)


# -----------------------------------------------------------------------------
# T9 — OrcIntReader bounds.
# -----------------------------------------------------------------------------


def test_int_reader_bounds() raises:
    var cont = List[UInt8]()
    for _ in range(11):
        cont.append(0x80)
    var r = OrcIntReader(Span(cont))
    with assert_raises(contains="MALFORMED_VARINT: vulong > 10 bytes"):
        _ = r.read_vulong()

    # A 10-byte varint (the longest legal) through the 10+-byte path.
    var ten = List[UInt8]()
    for _ in range(9):
        ten.append(0xFF)
    ten.append(0x01)
    var r10 = OrcIntReader(Span(ten))
    assert_equal(r10.read_vulong(), UInt64.MAX)

    var cut = _b(0x80, 0x80)
    var rc = OrcIntReader(Span(cut))
    with assert_raises(contains="TRUNCATED: vulong overrun"):
        _ = rc.read_vulong()

    # Fewer than 10 bytes left: the per-byte path decodes a short varint.
    var two = _b(0xAC, 0x02)
    var rt = OrcIntReader(Span(two))
    assert_equal(rt.read_vulong(), 300)
    assert_equal(rt.remaining(), 0)

    var one = _b(0x05)
    var ro = OrcIntReader(Span(one))
    assert_equal(ro.read_byte(), 5)
    with assert_raises(contains="TRUNCATED: stream overrun reading byte"):
        _ = ro.read_byte()


# -----------------------------------------------------------------------------
# T10 — encoder widths.
# -----------------------------------------------------------------------------


def _roundtrip(vals: List[Int64], signed: Bool) raises -> List[UInt8]:
    var enc = encode_int_rle_v2(vals, signed)
    var dec = decode_rlev2(Span(enc), len(vals), signed)
    assert_equal(len(dec), len(vals))
    for i in range(len(vals)):
        assert_equal(dec[i], vals[i])
    return enc^


def test_encoder_wide_widths() raises:
    # (max bits, the DIRECT header byte for that encoded width, L=2)
    var cases = List[Tuple[Int, Int]]()
    cases.append((25, 0x40 | (24 << 1)))
    cases.append((27, 0x40 | (25 << 1)))
    cases.append((29, 0x40 | (26 << 1)))
    cases.append((45, 0x40 | (29 << 1)))
    for c in range(len(cases)):
        var bits = cases[c][0]
        var vals = List[Int64]()
        vals.append(Int64(1) << Int64(bits - 1))  # needs exactly `bits`
        vals.append(1)
        var enc = _roundtrip(vals, False)
        assert_equal(Int(enc[0]), cases[c][1])
        assert_equal(Int(enc[1]), 1)  # L - 1

    # Short Repeat of 300 (two bytes): header (1 << 3) | (4 - 3) = 0x09.
    var rep = List[Int64]()
    for _ in range(4):
        rep.append(300)
    var e = _roundtrip(rep, False)
    assert_equal(len(e), 3)
    assert_equal(Int(e[0]), 0x09)
    assert_equal(Int(e[1]), 0x01)
    assert_equal(Int(e[2]), 0x2C)
    # Signed: zigzag(-70000) = 139999 needs three bytes.
    var neg = List[Int64]()
    for _ in range(3):
        neg.append(-70000)
    var en = _roundtrip(neg, True)
    assert_equal(Int(en[0]), (2 << 3) | 0)


# -----------------------------------------------------------------------------
# T11 — width 0 and widths past 64 at the private pack / unpack helpers (no
# run header can carry them; these pin what the helpers do if handed one).
# -----------------------------------------------------------------------------


def test_degenerate_widths() raises:
    var src = _b(0xFF, 0xFF)
    var r = OrcIntReader(Span(src))
    var out = List[Int64]()
    out.append(9)
    _unpack_bits(r, 0, 3, out)
    assert_equal(len(out), 4)
    assert_equal(out[0], 9)
    assert_equal(out[1], 0)
    assert_equal(out[3], 0)
    assert_equal(r.pos, 0)  # width 0 consumes no input

    var packed = List[UInt8]()
    var vals = List[UInt64]()
    vals.append(5)
    vals.append(7)
    _pack_bits(packed, vals, 0)
    assert_equal(len(packed), 0)
    _pack_bits(packed, vals, 4)
    assert_equal(len(packed), 1)
    assert_equal(Int(packed[0]), 0x57)

    assert_equal(_encode_bit_width(64), 31)
    with assert_raises(contains="BAD_WIDTH: bits 65 > 64"):
        _ = _encode_bit_width(65)


def main() raises:
    test_rlev1_final_run_cut_to_count()
    test_count_refusals()
    test_rlev2_run_refusals()
    test_direct_w32_tail_and_truncated()
    test_patched_base_shapes()
    test_delta_short_runs_and_tail()
    test_short_repeat_truncated()
    test_span_entry_points()
    test_int_reader_bounds()
    test_encoder_wide_widths()
    test_degenerate_widths()
    print("test_orc_rle_edges: ALL PASS")

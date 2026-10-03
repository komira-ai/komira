# =============================================================================
# test_orc_rle_families.mojo — the 5 ORC integer RLE families.
# =============================================================================
#
# Acceptance: 5 RLE families decode correctly. Fixtures are hand-emitted —
# the exact inverse of the decoders (no external ORC tool needed), so each test exercises
# BOTH the ORC wire-format spec AND the decode path.
#
# Coverage:
#   RLEv1 repeat run / literal run / signed (zigzag) / unsigned.
#   RLEv2 Short Repeat (W=1, W=4, signed).
#   RLEv2 Direct (W=4, W=12, signed).
#   RLEv2 Patched Base (base + patch list).
#   RLEv2 Delta (W=0 fixed cadence, increasing, decreasing).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    decode_rlev1,
    decode_rlev2,
    zigzag_decode,
)


# -----------------------------------------------------------------------------
# Encoder helpers (the inverse of rle_decode.mojo).
# -----------------------------------------------------------------------------


def _i64s(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(vals)):
        out.append(Int64(vals[i]))
    return out^


def _zigzag_encode(v: Int64) -> UInt64:
    return UInt64((v << 1) ^ (v >> 63))


def _vulong(n: UInt64, mut out: List[UInt8]):
    var v = n
    while True:
        var b = UInt8(v & 0x7F)
        v >>= 7
        if v != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _vslong(v: Int64, mut out: List[UInt8]):
    _vulong(_zigzag_encode(v), out)


def _pack_bits_be(values: List[Int64], bits: Int, mut out: List[UInt8]):
    """MSB-first bit-pack `values` at `bits` width (inverse of _unpack_bits)."""
    var cur: UInt64 = 0
    var filled: Int = 0
    for vi in range(len(values)):
        var v = (
            UInt64(values[vi]) & ((UInt64(1) << UInt64(bits)) - 1)
            if bits < 64
            else UInt64(values[vi])
        )
        var need = bits
        while need > 0:
            var space = 8 - filled
            var take = need if need < space else space
            var shift = need - take
            var chunk = (v >> UInt64(shift)) & ((UInt64(1) << UInt64(take)) - 1)
            cur = (cur << UInt64(take)) | chunk
            filled += take
            need -= take
            if filled == 8:
                out.append(UInt8(cur & 0xFF))
                cur = 0
                filled = 0
    if filled > 0:
        cur = cur << UInt64(8 - filled)
        out.append(UInt8(cur & 0xFF))


# =============================================================================
# RLEv1
# =============================================================================


def test_rlev1_repeat_run() raises:
    # A repeat run: length 5, delta 2, base 10 (unsigned). Values 10,12,14,16,18.
    var data = List[UInt8]()
    data.append(UInt8(5 - 3))  # header = length - 3
    data.append(UInt8(2))  # delta int8
    _vulong(UInt64(10), data)  # base (unsigned)
    var out = decode_rlev1(data, 5, False)
    assert_equal(len(out), 5)
    assert_equal(out[0], Int64(10))
    assert_equal(out[1], Int64(12))
    assert_equal(out[4], Int64(18))


def test_rlev1_literal_run_signed() raises:
    # A literal run of 3 signed values: -5, 100, -1.
    var data = List[UInt8]()
    data.append(UInt8(256 - 3))  # header = 256 - count  -> count 3
    _vslong(Int64(-5), data)
    _vslong(Int64(100), data)
    _vslong(Int64(-1), data)
    var out = decode_rlev1(data, 3, True)
    assert_equal(len(out), 3)
    assert_equal(out[0], Int64(-5))
    assert_equal(out[1], Int64(100))
    assert_equal(out[2], Int64(-1))


def test_rlev1_negative_delta() raises:
    # Repeat run, length 4, delta -1, base 100 (signed). 100,99,98,97.
    var data = List[UInt8]()
    data.append(UInt8(4 - 3))
    data.append(UInt8(256 - 1))  # delta -1 as int8 two's complement
    _vslong(Int64(100), data)
    var out = decode_rlev1(data, 4, True)
    assert_equal(out[0], Int64(100))
    assert_equal(out[3], Int64(97))


# =============================================================================
# RLEv2 Short Repeat (tag 0b00)
# =============================================================================


def test_rlev2_short_repeat_w1() raises:
    # W=1 byte, run 5, value 42 (unsigned).
    var data = List[UInt8]()
    var header = (0 << 6) | ((1 - 1) << 3) | (5 - 3)
    data.append(UInt8(header))
    data.append(UInt8(42))
    var out = decode_rlev2(data, 5, False)
    assert_equal(len(out), 5)
    for i in range(5):
        assert_equal(out[i], Int64(42))


def test_rlev2_short_repeat_signed() raises:
    # W=1, run 3, signed value -7 (zigzag(-7) = 13).
    var data = List[UInt8]()
    var header = (0 << 6) | ((1 - 1) << 3) | (3 - 3)
    data.append(UInt8(header))
    data.append(UInt8(_zigzag_encode(Int64(-7)) & 0xFF))
    var out = decode_rlev2(data, 3, True)
    assert_equal(out[0], Int64(-7))
    assert_equal(out[2], Int64(-7))


def test_rlev2_short_repeat_w4() raises:
    # W=4 bytes, run 4, value 0x01020304 (unsigned).
    var data = List[UInt8]()
    var header = (0 << 6) | ((4 - 1) << 3) | (4 - 3)
    data.append(UInt8(header))
    data.append(UInt8(0x01))
    data.append(UInt8(0x02))
    data.append(UInt8(0x03))
    data.append(UInt8(0x04))
    var out = decode_rlev2(data, 4, False)
    assert_equal(out[0], Int64(0x01020304))
    assert_equal(out[3], Int64(0x01020304))


# =============================================================================
# RLEv2 Direct (tag 0b01)
# =============================================================================


def test_rlev2_direct_w4() raises:
    # Unsigned, W=4 bits, 5 values: 1,2,3,4,15.
    var vals = _i64s(1, 2, 3, 4, 15)
    var data = List[UInt8]()
    var enc_w = 4 - 1  # 4 bits -> encoded width 3
    var run_len = 5
    # byte0: tag=01, bits[5:1]=enc_w, bit0 = (run_len-1) high bit
    var L = run_len - 1
    var b0 = (1 << 6) | (enc_w << 1) | ((L >> 8) & 1)
    data.append(UInt8(b0))
    data.append(UInt8(L & 0xFF))
    _pack_bits_be(vals, 4, data)
    var out = decode_rlev2(data, run_len, False)
    assert_equal(len(out), 5)
    assert_equal(out[0], Int64(1))
    assert_equal(out[3], Int64(4))
    assert_equal(out[4], Int64(15))


def test_rlev2_direct_signed_w12() raises:
    # Signed, 12-bit, values include negatives (zigzag-packed).
    var raw = _i64s(-100, 50, -2000, 2047)
    var zz = List[Int64]()
    for i in range(len(raw)):
        zz.append(Int64(_zigzag_encode(raw[i])))
    var data = List[UInt8]()
    var enc_w = 12 - 1  # 12 bits -> encoded 11
    var run_len = 4
    var L = run_len - 1
    var b0 = (1 << 6) | (enc_w << 1) | ((L >> 8) & 1)
    data.append(UInt8(b0))
    data.append(UInt8(L & 0xFF))
    _pack_bits_be(zz, 12, data)
    var out = decode_rlev2(data, run_len, True)
    assert_equal(out[0], Int64(-100))
    assert_equal(out[1], Int64(50))
    assert_equal(out[2], Int64(-2000))
    assert_equal(out[3], Int64(2047))


# =============================================================================
# RLEv2 Patched Base (tag 0b10)
# =============================================================================


def test_rlev2_patched_base() raises:
    # 5 values: 10, 20, 30, 40, 5000. Base = min = 10. After subtracting base:
    # 0, 10, 20, 30, 4990. W = 5 bits covers 0..31; 4990 needs patching.
    # 4990 = 0b1001101111110. Low 5 bits = 0b11110 = 30. High bits = 4990>>5 = 155.
    # We use W=5, patch_width=8, patch_gap_width=1, PLL=1, base_width=1.
    var data = List[UInt8]()
    var enc_w = 5 - 1  # W=5 -> encoded 4
    var run_len = 5
    var L = run_len - 1
    var b0 = (2 << 6) | (enc_w << 1) | ((L >> 8) & 1)
    data.append(UInt8(b0))
    data.append(UInt8(L & 0xFF))
    # byte2: bits[7:5]=BW-1 (base width 1 -> 0); bits[4:0]=encoded PW (8 -> 7)
    var base_width = 1
    var enc_pw = 8 - 1
    data.append(UInt8(((base_width - 1) << 5) | enc_pw))
    # byte3: bits[7:5]=PGW-1 (gap width 3 -> 2); bits[4:0]=PLL (1)
    var pgw = 3
    var pll = 1
    data.append(UInt8(((pgw - 1) << 5) | pll))
    # base value: signed-magnitude, 1 byte, value 10 (positive).
    data.append(UInt8(10))
    # data values (base subtracted): 0, 10, 20, 30, 30 (low 5 bits of 4990).
    var packed = _i64s(0, 10, 20, 30, 30)
    _pack_bits_be(packed, 5, data)
    # patch list: 1 entry targeting index 4 (the 5000 value). gap=4, patch =
    # (4990>>5) = 155. Each entry = PGW+PW bits: gap(PGW) << PW | patch(PW).
    # NOTE: gap 4 needs PGW>=3, so PGW=3 here.
    var patch_entries = _i64s((4 << 8) | 155)
    _pack_bits_be(patch_entries, pgw + 8, data)
    var out = decode_rlev2(data, run_len, False)
    assert_equal(len(out), 5)
    assert_equal(out[0], Int64(10))
    assert_equal(out[1], Int64(20))
    assert_equal(out[2], Int64(30))
    assert_equal(out[3], Int64(40))
    assert_equal(out[4], Int64(5000))


# =============================================================================
# RLEv2 Delta (tag 0b11)
# =============================================================================


def test_rlev2_delta_fixed_cadence() raises:
    # W=0 fixed delta: base=100, delta_base=5, length 6. 100,105,110,115,120,125.
    var data = List[UInt8]()
    var run_len = 6
    var L = run_len - 1
    var b0 = (3 << 6) | (0 << 1) | ((L >> 8) & 1)  # enc_w = 0 -> fixed
    data.append(UInt8(b0))
    data.append(UInt8(L & 0xFF))
    _vulong(UInt64(100), data)  # base (unsigned column)
    _vslong(Int64(5), data)  # delta_base
    var out = decode_rlev2(data, run_len, False)
    assert_equal(len(out), 6)
    assert_equal(out[0], Int64(100))
    assert_equal(out[1], Int64(105))
    assert_equal(out[5], Int64(125))


def test_rlev2_delta_increasing() raises:
    # Variable deltas, increasing. base=0, delta_base=1, then deltas [2,3,4].
    # Sequence: 0, 1, 3, 6, 10.
    var data = List[UInt8]()
    var run_len = 5
    var L = run_len - 1
    var enc_w = 4 - 1  # 4-bit deltas
    var b0 = (3 << 6) | (enc_w << 1) | ((L >> 8) & 1)
    data.append(UInt8(b0))
    data.append(UInt8(L & 0xFF))
    _vulong(UInt64(0), data)  # base
    _vslong(Int64(1), data)  # delta_base (positive -> increasing)
    var deltas = _i64s(2, 3, 4)
    _pack_bits_be(deltas, 4, data)
    var out = decode_rlev2(data, run_len, False)
    assert_equal(out[0], Int64(0))
    assert_equal(out[1], Int64(1))
    assert_equal(out[2], Int64(3))
    assert_equal(out[3], Int64(6))
    assert_equal(out[4], Int64(10))


def test_rlev2_delta_decreasing() raises:
    # Decreasing. base=100, delta_base=-10, then deltas [5, 5] subtracted.
    # Sequence: 100, 90, 85, 80.
    var data = List[UInt8]()
    var run_len = 4
    var L = run_len - 1
    var enc_w = 4 - 1
    var b0 = (3 << 6) | (enc_w << 1) | ((L >> 8) & 1)
    data.append(UInt8(b0))
    data.append(UInt8(L & 0xFF))
    _vslong(Int64(100), data)  # base (signed)
    _vslong(Int64(-10), data)  # delta_base negative -> decreasing
    var deltas = _i64s(5, 5)
    _pack_bits_be(deltas, 4, data)
    var out = decode_rlev2(data, run_len, True)
    assert_equal(out[0], Int64(100))
    assert_equal(out[1], Int64(90))
    assert_equal(out[2], Int64(85))
    assert_equal(out[3], Int64(80))


def test_zigzag_roundtrip() raises:
    assert_equal(zigzag_decode(UInt64(0)), Int64(0))
    assert_equal(zigzag_decode(UInt64(1)), Int64(-1))
    assert_equal(zigzag_decode(UInt64(2)), Int64(1))
    assert_equal(zigzag_decode(_zigzag_encode(Int64(-12345))), Int64(-12345))
    assert_equal(zigzag_decode(_zigzag_encode(Int64(99999))), Int64(99999))


def main() raises:
    test_rlev1_repeat_run()
    test_rlev1_literal_run_signed()
    test_rlev1_negative_delta()
    test_rlev2_short_repeat_w1()
    test_rlev2_short_repeat_signed()
    test_rlev2_short_repeat_w4()
    test_rlev2_direct_w4()
    test_rlev2_direct_signed_w12()
    test_rlev2_patched_base()
    test_rlev2_delta_fixed_cadence()
    test_rlev2_delta_increasing()
    test_rlev2_delta_decreasing()
    test_zigzag_roundtrip()
    print("test_orc_rle_families: ALL PASS")

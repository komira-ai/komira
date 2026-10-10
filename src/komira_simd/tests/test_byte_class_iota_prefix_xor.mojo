# =============================================================================
# test_byte_class_iota_prefix_xor — byte_class.broadcast_iota and prefix_xor
# =============================================================================
#
# I1  Every constructor of `broadcast_iota` against a lane-by-lane expectation,
#     at two widths. The offset iotas start close enough to the top of their
#     lane type that the run wraps through zero, which is documented.
# P1  `prefix_xor_u16/u32/u64` against a bit-at-a-time oracle (bit k of the
#     result = carry_in XOR parity of input bits 0..k), on a pseudo-random
#     stream plus hand-picked edge words, with both carry-ins, checking the
#     carry-out too. The u16 form takes a UInt32: bits above 15 must be
#     ignored, so every u16 input carries garbage in its high half.
# P2  Carry threading across consecutive words equals one long prefix XOR.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_simd.byte_class.broadcast_iota import (
    broadcast,
    iota_u8,
    iota_u8_offset,
    iota_u32,
    iota_u32_offset,
    broadcast_lane,
    zero,
    ones_u8,
)
from komira_simd.byte_class.prefix_xor import (
    prefix_xor_u16,
    prefix_xor_u32,
    prefix_xor_u64,
)


# =============================================================================
# I1 — broadcast / iota constructors.
# =============================================================================


def _check_iota[W: Int]() raises:
    var b = broadcast[DType.int16, W](Int16(-7))
    var z = zero[DType.uint64, W]()
    var o = ones_u8[W]()
    var i8 = iota_u8[W]()
    var i8o = iota_u8_offset[W](UInt8(250))
    var i32 = iota_u32[W]()
    var i32o = iota_u32_offset[W](UInt32(0xFFFFFFFD))
    var src = SIMD[DType.uint8, W](0)
    for k in range(W):
        src[k] = UInt8(3 * k + 1)
    var lane0 = broadcast_lane[DType.uint8, W, 0](src)
    var lane_last = broadcast_lane[DType.uint8, W, W - 1](src)
    for k in range(W):
        var at = " W=" + String(W) + " lane " + String(k)
        assert_equal(b[k], Int16(-7), "broadcast" + at)
        assert_equal(z[k], UInt64(0), "zero" + at)
        assert_equal(o[k], UInt8(0xFF), "ones_u8" + at)
        assert_equal(i8[k], UInt8(k), "iota_u8" + at)
        assert_equal(Int(i8o[k]), (250 + k) % 256, "iota_u8_offset" + at)
        assert_equal(i32[k], UInt32(k), "iota_u32" + at)
        assert_equal(
            Int(i32o[k]), (0xFFFFFFFD + k) % 0x100000000, "iota_u32_offset" + at
        )
        assert_equal(lane0[k], UInt8(1), "broadcast_lane<0>" + at)
        assert_equal(lane_last[k], UInt8(3 * (W - 1) + 1), "broadcast_lane<W-1>" + at)


def test_broadcast_iota_w8() raises:
    _check_iota[8]()


def test_broadcast_iota_w16() raises:
    _check_iota[16]()


# =============================================================================
# P1 — prefix XOR against a bit-at-a-time oracle.
# =============================================================================


def _oracle(bits: UInt64, n: Int, carry_in: Bool) -> Tuple[UInt64, Bool]:
    """Bit k = carry_in XOR parity(bits[0..k]); carry out = bit n-1."""
    var acc = 1 if carry_in else 0
    var out: UInt64 = 0
    for k in range(n):
        acc ^= Int((bits >> UInt64(k)) & 1)
        if acc == 1:
            out |= UInt64(1) << UInt64(k)
    return (out, acc == 1)


def _words() -> List[UInt64]:
    var w: List[UInt64] = [
        0,
        1,
        0x8000000000000000,
        0xFFFFFFFFFFFFFFFF,
        0x0000000000008000,
        0x0000000080000000,
        0x0000000100000001,
        0xAAAAAAAAAAAAAAAA,
        0x00010000FFFE0001,
    ]
    var s: UInt64 = 0x243F6A8885A308D3
    for _ in range(200):
        s = s * 6364136223846793005 + 1442695040888963407
        w.append(s ^ (s >> 29))
    return w^


def test_prefix_xor_u16_oracle() raises:
    var ws = _words()
    for i in range(len(ws)):
        for c in range(2):
            var carry_in = c == 1
            var x = (ws[i] & 0xFFFF).cast[DType.uint32]() | UInt32(0xC3A50000)
            var want = _oracle(x.cast[DType.uint64](), 16, carry_in)
            var carry = carry_in
            var got = prefix_xor_u16(x, carry)
            var at = " in=" + String(x) + " carry_in=" + String(carry_in)
            assert_equal(got.cast[DType.uint64](), want[0], "u16 value" + at)
            assert_equal(carry, want[1], "u16 carry" + at)


def test_prefix_xor_u32_oracle() raises:
    var ws = _words()
    for i in range(len(ws)):
        for c in range(2):
            var carry_in = c == 1
            var x = ((ws[i] >> 17) & 0xFFFFFFFF).cast[DType.uint32]()
            var want = _oracle(x.cast[DType.uint64](), 32, carry_in)
            var carry = carry_in
            var got = prefix_xor_u32(x, carry)
            var at = " in=" + String(x) + " carry_in=" + String(carry_in)
            assert_equal(got.cast[DType.uint64](), want[0], "u32 value" + at)
            assert_equal(carry, want[1], "u32 carry" + at)


def test_prefix_xor_u64_oracle() raises:
    var ws = _words()
    for i in range(len(ws)):
        for c in range(2):
            var carry_in = c == 1
            var want = _oracle(ws[i], 64, carry_in)
            var carry = carry_in
            var got = prefix_xor_u64(ws[i], carry)
            var at = " in=" + String(ws[i]) + " carry_in=" + String(carry_in)
            assert_equal(got, want[0], "u64 value" + at)
            assert_equal(carry, want[1], "u64 carry" + at)


# =============================================================================
# P2 — carry threading: four u16 words == one u64 word.
# =============================================================================


def test_prefix_xor_carry_threads() raises:
    var ws = _words()
    for i in range(len(ws)):
        var whole_carry = False
        var whole = prefix_xor_u64(ws[i], whole_carry)
        var c16 = False
        var c32 = False
        for q in range(4):
            var part = prefix_xor_u16(
                ((ws[i] >> UInt64(16 * q)) & 0xFFFF).cast[DType.uint32](), c16
            )
            assert_equal(
                part.cast[DType.uint64](), (whole >> UInt64(16 * q)) & 0xFFFF,
                "u16 quarter " + String(q) + " of " + String(ws[i]),
            )
        for h in range(2):
            var part = prefix_xor_u32(
                ((ws[i] >> UInt64(32 * h)) & 0xFFFFFFFF).cast[DType.uint32](), c32
            )
            assert_equal(
                part.cast[DType.uint64](), (whole >> UInt64(32 * h)) & 0xFFFFFFFF,
                "u32 half " + String(h) + " of " + String(ws[i]),
            )
        assert_equal(c16, whole_carry, "u16 chain carry")
        assert_equal(c32, whole_carry, "u32 chain carry")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

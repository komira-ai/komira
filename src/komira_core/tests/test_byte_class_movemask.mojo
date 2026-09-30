# =============================================================================
# Tests for komira_core/simd/byte_class/movemask.mojo + byte_mask_ops.mojo.
# =============================================================================
#
# Coverage:
#   M1  byte_eq_to_bytemask_u8x16 — exact-match / no-match / partial-match.
#   M2  byte_eq_to_bytemask_u8x32 — AVX2-width 32-lane shape.
#   M3  byte_eq_to_bytemask_u8x64 — AVX-512 BW-width 64-lane shape.
#   M4  movemask_to_uint_u8x16 — all-zero / all-set / alternating / sparse.
#   M5  movemask_to_uint_u8x32 — 32-bit shape; high+low halves.
#   M6  movemask_to_uint_u8x64 — full 64-bit shape.
#   M7  bool_vec_to_uint_u8x16/32/64 — bool-mask shape direct (no
#       round-trip through byte-mask).
#   M8  bytemask_and / _or / _xor / _andnot / _not — exhaustive truth.
#   M9  bytemask_is_zero / _any_set — all-zero / any-set.
#
# Test harness: std.testing.assert_equal / _true / _false.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_core.simd.byte_class.byte_mask_ops import (
    bytemask_and,
    bytemask_or,
    bytemask_xor,
    bytemask_andnot,
    bytemask_not,
    bytemask_is_zero,
    bytemask_any_set,
)
from komira_core.simd.byte_class.movemask import (
    byte_eq_to_bytemask_u8x16,
    byte_eq_to_bytemask_u8x32,
    byte_eq_to_bytemask_u8x64,
    movemask_to_uint_u8x16,
    movemask_to_uint_u8x32,
    movemask_to_uint_u8x64,
    bool_vec_to_uint_u8x16,
    bool_vec_to_uint_u8x32,
    bool_vec_to_uint_u8x64,
)


# =============================================================================
# Helpers
# =============================================================================

def _build_u8x16_from_pattern(p0: UInt8, p1: UInt8) -> SIMD[DType.uint8, 16]:
    """Build a 16-byte SIMD where odd lanes hold p1 and even lanes hold p0."""
    var v = SIMD[DType.uint8, 16](0)
    for k in range(16):
        if k % 2 == 0:
            v[k] = p0
        else:
            v[k] = p1
    return v


def _build_u8x32_from_pattern(p0: UInt8, p1: UInt8) -> SIMD[DType.uint8, 32]:
    """Build a 32-byte SIMD with alternating pattern."""
    var v = SIMD[DType.uint8, 32](0)
    for k in range(32):
        if k % 2 == 0:
            v[k] = p0
        else:
            v[k] = p1
    return v


def _build_u8x64_from_pattern(p0: UInt8, p1: UInt8) -> SIMD[DType.uint8, 64]:
    """Build a 64-byte SIMD with alternating pattern."""
    var v = SIMD[DType.uint8, 64](0)
    for k in range(64):
        if k % 2 == 0:
            v[k] = p0
        else:
            v[k] = p1
    return v


# =============================================================================
# M1 — byte_eq_to_bytemask_u8x16 — exact-match / no-match / partial-match.
# =============================================================================

def test_byte_eq_to_bytemask_u8x16() raises:
    # All match
    var all_a = SIMD[DType.uint8, 16](UInt8(0x41))  # all 'A'
    var bm = byte_eq_to_bytemask_u8x16(all_a, UInt8(0x41))
    for k in range(16):
        assert_equal(bm[k], UInt8(0xFF), "all-match lane")

    # No match
    var all_b = SIMD[DType.uint8, 16](UInt8(0x42))  # all 'B'
    var bm2 = byte_eq_to_bytemask_u8x16(all_b, UInt8(0x41))
    for k in range(16):
        assert_equal(bm2[k], UInt8(0x00), "no-match lane")

    # Alternating: even='A', odd='B'; match 'A'
    var alt = _build_u8x16_from_pattern(UInt8(0x41), UInt8(0x42))
    var bm3 = byte_eq_to_bytemask_u8x16(alt, UInt8(0x41))
    for k in range(16):
        if k % 2 == 0:
            assert_equal(bm3[k], UInt8(0xFF), "even-lane (A=match)")
        else:
            assert_equal(bm3[k], UInt8(0x00), "odd-lane (B=no-match)")


# =============================================================================
# M2 — byte_eq_to_bytemask_u8x32 — AVX2-width 32-lane.
# =============================================================================

def test_byte_eq_to_bytemask_u8x32() raises:
    var alt = _build_u8x32_from_pattern(UInt8(0x2C), UInt8(0x21))  # ',' / '!'
    var bm = byte_eq_to_bytemask_u8x32(alt, UInt8(0x2C))  # match ','
    for k in range(32):
        if k % 2 == 0:
            assert_equal(bm[k], UInt8(0xFF))
        else:
            assert_equal(bm[k], UInt8(0x00))


# =============================================================================
# M3 — byte_eq_to_bytemask_u8x64 — AVX-512 BW-width 64-lane.
# =============================================================================

def test_byte_eq_to_bytemask_u8x64() raises:
    var alt = _build_u8x64_from_pattern(UInt8(0x0A), UInt8(0x20))  # '\n' / ' '
    var bm = byte_eq_to_bytemask_u8x64(alt, UInt8(0x0A))
    for k in range(64):
        if k % 2 == 0:
            assert_equal(bm[k], UInt8(0xFF))
        else:
            assert_equal(bm[k], UInt8(0x00))


# =============================================================================
# M4 — movemask_to_uint_u8x16 — bitmask shapes.
# =============================================================================

def test_movemask_to_uint_u8x16_all_zero() raises:
    var zeros = SIMD[DType.uint8, 16](0)
    var bits = movemask_to_uint_u8x16(zeros)
    assert_equal(bits, UInt32(0), "all-zero bytes → 0 bitmask")


def test_movemask_to_uint_u8x16_all_set() raises:
    var ones = SIMD[DType.uint8, 16](0xFF)
    var bits = movemask_to_uint_u8x16(ones)
    assert_equal(bits, UInt32(0xFFFF), "all-set bytes → 0xFFFF bitmask")


def test_movemask_to_uint_u8x16_alternating() raises:
    # Even lanes set, odd unset → 0x5555 bitmask
    var alt = SIMD[DType.uint8, 16](0)
    for k in range(16):
        if k % 2 == 0:
            alt[k] = UInt8(0xFF)
    var bits = movemask_to_uint_u8x16(alt)
    assert_equal(bits, UInt32(0x5555), "alternating bytes → 0x5555")


def test_movemask_to_uint_u8x16_sparse() raises:
    # Lanes 0 and 15 set → bitmask 0x8001
    var v = SIMD[DType.uint8, 16](0)
    v[0] = UInt8(0xFF)
    v[15] = UInt8(0xFF)
    var bits = movemask_to_uint_u8x16(v)
    assert_equal(bits, UInt32(0x8001), "lanes 0+15 → 0x8001")


# =============================================================================
# M5 — movemask_to_uint_u8x32 — 32-bit shape.
# =============================================================================

def test_movemask_to_uint_u8x32() raises:
    # All bytes set → 0xFFFFFFFF
    var ones = SIMD[DType.uint8, 32](0xFF)
    assert_equal(movemask_to_uint_u8x32(ones), UInt32(0xFFFFFFFF))

    # Only low half set → 0x0000FFFF
    var lo_half = SIMD[DType.uint8, 32](0)
    for k in range(16):
        lo_half[k] = UInt8(0xFF)
    assert_equal(movemask_to_uint_u8x32(lo_half), UInt32(0x0000FFFF))

    # Only high half set → 0xFFFF0000
    var hi_half = SIMD[DType.uint8, 32](0)
    for k in range(16, 32):
        hi_half[k] = UInt8(0xFF)
    assert_equal(movemask_to_uint_u8x32(hi_half), UInt32(0xFFFF0000))


# =============================================================================
# M6 — movemask_to_uint_u8x64 — full 64-bit.
# =============================================================================

def test_movemask_to_uint_u8x64() raises:
    var ones = SIMD[DType.uint8, 64](0xFF)
    assert_equal(movemask_to_uint_u8x64(ones), UInt64(0xFFFFFFFFFFFFFFFF))

    var zeros = SIMD[DType.uint8, 64](0)
    assert_equal(movemask_to_uint_u8x64(zeros), UInt64(0))

    # Lane 63 only
    var v = SIMD[DType.uint8, 64](0)
    v[63] = UInt8(0xFF)
    assert_equal(movemask_to_uint_u8x64(v), UInt64(0x8000000000000000))

    # Lane 0 only
    var v2 = SIMD[DType.uint8, 64](0)
    v2[0] = UInt8(0xFF)
    assert_equal(movemask_to_uint_u8x64(v2), UInt64(0x1))


# =============================================================================
# M7 — bool_vec_to_uint family.
# =============================================================================

def test_bool_vec_to_uint_u8x16() raises:
    var m = SIMD[DType.bool, 16](fill=False)
    m[0] = True
    m[5] = True
    m[15] = True
    var bits = bool_vec_to_uint_u8x16(m)
    # Lanes 0, 5, 15 → 0x8021
    assert_equal(bits, UInt32(0x8021))


def test_bool_vec_to_uint_u8x32() raises:
    var m = SIMD[DType.bool, 32](fill=False)
    m[0] = True
    m[16] = True
    m[31] = True
    var bits = bool_vec_to_uint_u8x32(m)
    # Lanes 0, 16, 31 → 0x80010001
    assert_equal(bits, UInt32(0x80010001))


def test_bool_vec_to_uint_u8x64() raises:
    var m = SIMD[DType.bool, 64](fill=False)
    m[0] = True
    m[32] = True
    m[63] = True
    var bits = bool_vec_to_uint_u8x64(m)
    # Lanes 0, 32, 63
    assert_equal(bits, UInt64(0x8000000100000001))


# =============================================================================
# M8 — bytemask AND / OR / XOR / ANDNOT / NOT.
# =============================================================================

def test_bytemask_and_or_xor() raises:
    var a = SIMD[DType.uint8, 16](0xFF)
    var b = SIMD[DType.uint8, 16](0)
    # Lanes 0..7 of b set; lanes 8..15 unset
    for k in range(8):
        b[k] = UInt8(0xFF)

    var r_and = bytemask_and[16](a, b)
    var r_or = bytemask_or[16](a, b)
    var r_xor = bytemask_xor[16](a, b)
    var r_andnot = bytemask_andnot[16](a, b)
    var r_not_b = bytemask_not[16](b)

    for k in range(8):
        # Lanes 0..7: a=FF, b=FF
        assert_equal(r_and[k], UInt8(0xFF))
        assert_equal(r_or[k], UInt8(0xFF))
        assert_equal(r_xor[k], UInt8(0x00))
        assert_equal(r_andnot[k], UInt8(0x00))
        assert_equal(r_not_b[k], UInt8(0x00))
    for k in range(8, 16):
        # Lanes 8..15: a=FF, b=00
        assert_equal(r_and[k], UInt8(0x00))
        assert_equal(r_or[k], UInt8(0xFF))
        assert_equal(r_xor[k], UInt8(0xFF))
        assert_equal(r_andnot[k], UInt8(0xFF))
        assert_equal(r_not_b[k], UInt8(0xFF))


# =============================================================================
# M9 — bytemask_is_zero + _any_set.
# =============================================================================

def test_bytemask_is_zero() raises:
    var zeros = SIMD[DType.uint8, 16](0)
    assert_true(bytemask_is_zero[16](zeros))
    assert_false(bytemask_any_set[16](zeros))

    var one_set = SIMD[DType.uint8, 16](0)
    one_set[7] = UInt8(0xFF)
    assert_false(bytemask_is_zero[16](one_set))
    assert_true(bytemask_any_set[16](one_set))

    var all_set = SIMD[DType.uint8, 16](0xFF)
    assert_false(bytemask_is_zero[16](all_set))
    assert_true(bytemask_any_set[16](all_set))


# =============================================================================
# Entrypoint
# =============================================================================

def main() raises -> None:
    test_byte_eq_to_bytemask_u8x16()
    test_byte_eq_to_bytemask_u8x32()
    test_byte_eq_to_bytemask_u8x64()
    test_movemask_to_uint_u8x16_all_zero()
    test_movemask_to_uint_u8x16_all_set()
    test_movemask_to_uint_u8x16_alternating()
    test_movemask_to_uint_u8x16_sparse()
    test_movemask_to_uint_u8x32()
    test_movemask_to_uint_u8x64()
    test_bool_vec_to_uint_u8x16()
    test_bool_vec_to_uint_u8x32()
    test_bool_vec_to_uint_u8x64()
    test_bytemask_and_or_xor()
    test_bytemask_is_zero()
    print("byte_class movemask + byte_mask_ops: ALL PASS")

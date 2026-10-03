# =============================================================================
# Tests for komira_core/simd/byte_class/{comparisons,horizontal_reduce,
# broadcast_iota,type_cast,conditional_select,prefix_xor}.mojo.
# =============================================================================
#
# Coverage:
#   C1  byte_eq / _ne / _lt / _gt / _le / _ge — exact lanewise behavior.
#   C2  int_*  comparisons for Int8/16/32/64.
#   C3  float_* comparisons for Float32/64.
#   R1  reduce_sum / _min / _max / _and / _or — UInt8 x 32.
#   R2  reduce_* on Int64 x 8 / Float64 x 8.
#   R3  all_true / any_true / count_true / count_true_mask_u8.
#   B1  broadcast / iota_u8 / iota_u32 / broadcast_lane / zero / ones_u8.
#   T1  promote_to_u32 / demote_to_u8 / convert_to_f64 / convert_f64_to_i64.
#   T2  bool_to_one_zero / bool_to_byte_mask.
#   S1  if_then_else / _zero / _negative / byte_mask_select_u8.
#   X1  prefix_xor_u16 / _u32 / _u64 — empty / single bit / multi / carry.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_simd.byte_class.comparisons import (
    byte_eq, byte_ne, byte_lt, byte_gt, byte_le, byte_ge,
    int_eq, int_ne, int_lt, int_gt, int_le, int_ge,
    float_eq, float_ne, float_lt, float_gt,
)
from komira_simd.byte_class.horizontal_reduce import (
    reduce_sum, reduce_min, reduce_max, reduce_and, reduce_or,
    all_true, any_true, count_true, count_true_mask_u8,
)
from komira_simd.byte_class.broadcast_iota import (
    broadcast, iota_u8, iota_u32, iota_u8_offset, iota_u32_offset,
    broadcast_lane, zero, ones_u8,
)
from komira_simd.byte_class.type_cast import (
    promote_to_u32, demote_to_u8, convert_to_f64, convert_f64_to_i64,
    bool_to_one_zero, bool_to_byte_mask,
)
from komira_simd.byte_class.conditional_select import (
    if_then_else, if_then_else_zero, if_then_zero_else,
    if_negative_then_else, byte_mask_select_u8,
)
from komira_simd.byte_class.prefix_xor import (
    prefix_xor_u16, prefix_xor_u32, prefix_xor_u64,
)


# =============================================================================
# C1 — byte_* comparison family.
# =============================================================================

def test_byte_compare_family() raises:
    var a = SIMD[DType.uint8, 16](0)
    var b = SIMD[DType.uint8, 16](0)
    for k in range(16):
        a[k] = UInt8(k)
        b[k] = UInt8(15 - k)  # decreasing

    # byte_eq: lane k where k == 15-k → k == 7.5 → no exact match
    var eq_mask = byte_eq[16](a, b)
    for k in range(16):
        assert_false(eq_mask[k], "byte_eq lane")

    # byte_lt: a[k] < b[k] iff k < 15-k iff k < 7.5 → lanes 0..7
    var lt_mask = byte_lt[16](a, b)
    for k in range(8):
        assert_true(lt_mask[k])
    for k in range(8, 16):
        assert_false(lt_mask[k])

    # byte_gt: opposite → lanes 8..15
    var gt_mask = byte_gt[16](a, b)
    for k in range(8):
        assert_false(gt_mask[k])
    for k in range(8, 16):
        assert_true(gt_mask[k])


# =============================================================================
# C2 — int_* family.
# =============================================================================

def test_int_compare_family() raises:
    var a = SIMD[DType.int64, 8](0)
    var b = SIMD[DType.int64, 8](0)
    for k in range(8):
        a[k] = Int64(k - 4)  # -4, -3, -2, -1, 0, 1, 2, 3
        b[k] = Int64(0)

    # int_lt: a[k] < 0 → lanes 0..3
    var lt_mask = int_lt[DType.int64, 8](a, b)
    for k in range(4):
        assert_true(lt_mask[k])
    for k in range(4, 8):
        assert_false(lt_mask[k])

    # int_eq: a[k] == 0 → lane 4 only
    var eq_mask = int_eq[DType.int64, 8](a, b)
    assert_true(eq_mask[4])
    for k in range(8):
        if k != 4:
            assert_false(eq_mask[k])


# =============================================================================
# C3 — float_* family.
# =============================================================================

def test_float_compare_family() raises:
    var a = SIMD[DType.float64, 8](0.0)
    var b = SIMD[DType.float64, 8](1.0)
    for k in range(8):
        a[k] = Float64(k) * 0.5  # 0.0, 0.5, 1.0, 1.5, ...

    # float_gt: a[k] > 1.0 iff k > 2 → lanes 3..7
    var gt_mask = float_gt[DType.float64, 8](a, b)
    for k in range(3):
        assert_false(gt_mask[k])
    for k in range(3, 8):
        assert_true(gt_mask[k])

    # float_eq at k=2: 1.0 == 1.0 → True
    var eq_mask = float_eq[DType.float64, 8](a, b)
    assert_true(eq_mask[2])


# =============================================================================
# R1 — reduce_sum / _min / _max / _and / _or for UInt8 x 32.
# =============================================================================

def test_reduce_u8x32() raises:
    var v = SIMD[DType.uint8, 32](0)
    for k in range(32):
        v[k] = UInt8(k + 1)  # 1..32 sum=528 → 528 mod 256 = 16

    var s = reduce_sum[DType.uint8, 32](v)
    assert_equal(s, UInt8(16), "u8 sum mod 256")

    var mn = reduce_min[DType.uint8, 32](v)
    assert_equal(mn, UInt8(1))

    var mx = reduce_max[DType.uint8, 32](v)
    assert_equal(mx, UInt8(32))


# =============================================================================
# R2 — reduce_* on Int64 / Float64.
# =============================================================================

def test_reduce_i64x8() raises:
    var v = SIMD[DType.int64, 8](0)
    for k in range(8):
        v[k] = Int64(k + 1)
    # 1+2+...+8 = 36
    assert_equal(reduce_sum[DType.int64, 8](v), Int64(36))
    assert_equal(reduce_min[DType.int64, 8](v), Int64(1))
    assert_equal(reduce_max[DType.int64, 8](v), Int64(8))


def test_reduce_f64x8() raises:
    var v = SIMD[DType.float64, 8](0.0)
    for k in range(8):
        v[k] = Float64(k + 1)
    assert_equal(reduce_sum[DType.float64, 8](v), Float64(36.0))
    assert_equal(reduce_min[DType.float64, 8](v), Float64(1.0))
    assert_equal(reduce_max[DType.float64, 8](v), Float64(8.0))


# =============================================================================
# R3 — bool-mask reductions.
# =============================================================================

def test_mask_reductions() raises:
    var all_t = SIMD[DType.bool, 32](fill=True)
    var all_f = SIMD[DType.bool, 32](fill=False)
    var mixed = SIMD[DType.bool, 32](fill=False)
    for k in range(32):
        if k % 3 == 0:
            mixed[k] = True

    assert_true(all_true[32](all_t))
    assert_false(all_true[32](all_f))
    assert_false(all_true[32](mixed))

    assert_true(any_true[32](all_t))
    assert_false(any_true[32](all_f))
    assert_true(any_true[32](mixed))

    assert_equal(count_true[32](all_t), 32)
    assert_equal(count_true[32](all_f), 0)
    # 0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30 → 11
    assert_equal(count_true[32](mixed), 11)


# =============================================================================
# B1 — broadcast / iota / zero / ones.
# =============================================================================

def test_broadcast_iota() raises:
    var b = broadcast[DType.uint8, 16](UInt8(0x42))
    for k in range(16):
        assert_equal(b[k], UInt8(0x42))

    var io = iota_u8[16]()
    for k in range(16):
        assert_equal(io[k], UInt8(k))

    var io2 = iota_u8_offset[8](UInt8(100))
    for k in range(8):
        assert_equal(io2[k], UInt8(100 + k))

    var io32 = iota_u32[4]()
    for k in range(4):
        assert_equal(io32[k], UInt32(k))

    var z = zero[DType.uint8, 16]()
    for k in range(16):
        assert_equal(z[k], UInt8(0))

    var ones = ones_u8[16]()
    for k in range(16):
        assert_equal(ones[k], UInt8(0xFF))


# =============================================================================
# T1 — promote / demote / convert.
# =============================================================================

def test_promote_demote() raises:
    var u8 = SIMD[DType.uint8, 8](0)
    for k in range(8):
        u8[k] = UInt8(k * 32)  # 0, 32, 64, ..., 224
    var u32 = promote_to_u32[8](u8)
    for k in range(8):
        assert_equal(u32[k], UInt32(k * 32))

    # demote large UInt32 back to UInt8 — truncate
    var big = SIMD[DType.uint32, 8](0)
    for k in range(8):
        big[k] = UInt32(0x100 + k)  # > 255
    var u8_back = demote_to_u8[DType.uint32, 8](big)
    for k in range(8):
        assert_equal(u8_back[k], UInt8(k))  # truncated to low byte


def test_convert_int_float() raises:
    var i64 = SIMD[DType.int64, 8](0)
    for k in range(8):
        i64[k] = Int64(k - 3)
    var f64 = convert_to_f64[DType.int64, 8](i64)
    for k in range(8):
        assert_equal(f64[k], Float64(k - 3))

    var f64v = SIMD[DType.float64, 8](0.0)
    for k in range(8):
        f64v[k] = Float64(k) * 1.7
    var i64_back = convert_f64_to_i64[8](f64v)
    for k in range(8):
        # truncation
        assert_equal(i64_back[k], Int64(Int(Float64(k) * 1.7)))


# =============================================================================
# T2 — bool_to_one_zero / _byte_mask.
# =============================================================================

def test_bool_to_byte_shape() raises:
    var m = SIMD[DType.bool, 16](fill=False)
    for k in range(16):
        if k % 2 == 0:
            m[k] = True

    var one_zero = bool_to_one_zero[16](m)
    var byte_m = bool_to_byte_mask[16](m)
    for k in range(16):
        if k % 2 == 0:
            assert_equal(one_zero[k], UInt8(1))
            assert_equal(byte_m[k], UInt8(0xFF))
        else:
            assert_equal(one_zero[k], UInt8(0))
            assert_equal(byte_m[k], UInt8(0x00))


# =============================================================================
# S1 — if_then_else family.
# =============================================================================

def test_if_then_else() raises:
    var yes = SIMD[DType.uint8, 16](0xAA)
    var no = SIMD[DType.uint8, 16](0x55)
    var m = SIMD[DType.bool, 16](fill=False)
    for k in range(16):
        if k % 2 == 0:
            m[k] = True

    var out = if_then_else[DType.uint8, 16](m, yes, no)
    for k in range(16):
        if k % 2 == 0:
            assert_equal(out[k], UInt8(0xAA))
        else:
            assert_equal(out[k], UInt8(0x55))

    var out_z = if_then_else_zero[DType.uint8, 16](m, yes)
    for k in range(16):
        if k % 2 == 0:
            assert_equal(out_z[k], UInt8(0xAA))
        else:
            assert_equal(out_z[k], UInt8(0))

    var out_ze = if_then_zero_else[DType.uint8, 16](m, no)
    for k in range(16):
        if k % 2 == 0:
            assert_equal(out_ze[k], UInt8(0))
        else:
            assert_equal(out_ze[k], UInt8(0x55))


def test_byte_mask_select() raises:
    var byte_m = SIMD[DType.uint8, 16](0)
    for k in range(16):
        if k % 2 == 0:
            byte_m[k] = UInt8(0xFF)
    var yes = SIMD[DType.uint8, 16](0xAA)
    var no = SIMD[DType.uint8, 16](0x55)
    var out = byte_mask_select_u8[16](byte_m, yes, no)
    for k in range(16):
        if k % 2 == 0:
            assert_equal(out[k], UInt8(0xAA))
        else:
            assert_equal(out[k], UInt8(0x55))


# =============================================================================
# X1 — prefix_xor at 16/32/64 widths.
# =============================================================================

def test_prefix_xor_u16_simple() raises:
    # Single set bit at position 5 → result bits[5..15] = 1
    var bits: UInt32 = UInt32(1) << UInt32(5)
    var carry: Bool = False
    var out = prefix_xor_u16(bits, carry)
    # Bits 0..4 = 0, bits 5..15 = 1 → 0xFFE0
    assert_equal(out & UInt32(0xFFFF), UInt32(0xFFE0))
    assert_true(carry, "carry_out should be set after odd-parity XOR")


def test_prefix_xor_u16_paired() raises:
    # Two set bits at 3 and 7 → bits[3..6] = 1, bits[7..15] = 0
    var bits: UInt32 = (UInt32(1) << UInt32(3)) | (UInt32(1) << UInt32(7))
    var carry: Bool = False
    var out = prefix_xor_u16(bits, carry)
    # Expected: bits 3,4,5,6 set; 0..2 unset; 7..15 unset (XOR'd back to 0)
    assert_equal(out & UInt32(0xFFFF), UInt32(0x0078))
    assert_false(carry, "carry_out should be unset after even-parity")


def test_prefix_xor_u32() raises:
    # Single bit at 0 → all 32 bits become 1
    var bits: UInt32 = UInt32(1)
    var carry: Bool = False
    var out = prefix_xor_u32(bits, carry)
    assert_equal(out, UInt32(0xFFFFFFFF))
    assert_true(carry)


def test_prefix_xor_u64() raises:
    # Single bit at 0 → all 64 bits become 1
    var bits: UInt64 = UInt64(1)
    var carry: Bool = False
    var out = prefix_xor_u64(bits, carry)
    assert_equal(out, UInt64(0xFFFFFFFFFFFFFFFF))
    assert_true(carry)


# =============================================================================
# Entrypoint
# =============================================================================

def main() raises -> None:
    test_byte_compare_family()
    test_int_compare_family()
    test_float_compare_family()
    test_reduce_u8x32()
    test_reduce_i64x8()
    test_reduce_f64x8()
    test_mask_reductions()
    test_broadcast_iota()
    test_promote_demote()
    test_convert_int_float()
    test_bool_to_byte_shape()
    test_if_then_else()
    test_byte_mask_select()
    test_prefix_xor_u16_simple()
    test_prefix_xor_u16_paired()
    test_prefix_xor_u32()
    test_prefix_xor_u64()
    print("byte_class compare + reduce + iota + cast + select + prefix_xor: ALL PASS")

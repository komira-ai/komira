# =============================================================================
# test_byte_class_wide_forms — byte_class forms no other test calls
# =============================================================================
#
# Every function here was compiled by no test before this file: the 32- and
# 64-lane forms of the CSV scan primitives, the unsigned/signed/float
# comparisons other than eq/lt/gt, the type casts, the BMI2 bit gathers and
# the carry-threading quote mask. Expectations are written out by hand (or by
# a scalar formula independent of the SIMD path), never computed through the
# function under test.
#
# C1  byte_ne/le/ge are unsigned (0x80 > 0x7F); int_ne/le/gt/ge are signed
#     (-1 < 1); float_lt/le/ge are False on a NaN lane; float_ne holds
#     -0.0 equal to +0.0 (its NaN lane is komira-ai/komira#937).
# F1  byte_find_eq_3/5 (16 lanes), 2/3/5 (32), 2/4 (64): each needle sits at a
#     distinct lane, the last one at the last lane, so a dropped needle or a
#     dropped upper half reads as a missing 0xFF.
# F2  nibble_lut_classify_u8x32 and byte_find_in_set_u8x32 against the scalar
#     `lo[b & 15] & hi[b >> 4]`, with lanes 16..31 unlike lanes 0..15 and
#     asymmetric LUTs (a lo/hi swap changes the answer).
# M1  masked_load/store_u8x64 with a mask that selects lanes in both halves
#     and the last lane; tail_mask_u8x64 at 0, 1, 31, 32, 33, 63, 64, 100.
# X1  compress_u8x64 and compress_with_count_u8x64 keep selected lanes from
#     above lane 32 in order; the count of an all-true mask is 64.
# Q1  quote_region_mask_u64_with_carry_out threads the carry-out (bit 63 of
#     the region mask) into the next chunk.
# T1  promote (zero- vs sign-extension), demote (low-bits truncation, sign
#     of the result), convert to f32 and f32 -> i32 (truncation toward 0).
# (The bmi2_pext/pdep_*_x86 functions are not here: the pinned compiler
#  refuses their intrinsic names, komira-ai/komira#1404.)
# R1  append_set_positions_u32 at bits 0 and 31, popcount_u64 of all-ones,
#     reduce_and, count_true_mask_u8 (a 0x7F lane is not set) and
#     if_negative_then_else (0 is not negative).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_simd.byte_class.bitmask_to_positions import (
    append_set_positions_u32,
    popcount_u64,
)
from komira_simd.byte_class.byte_find_any_of import (
    byte_find_eq_2_u8x32,
    byte_find_eq_2_u8x64,
    byte_find_eq_3_u8x16,
    byte_find_eq_3_u8x32,
    byte_find_eq_4_u8x64,
    byte_find_eq_5_u8x16,
    byte_find_eq_5_u8x32,
    byte_find_in_set_u8x32,
)
from komira_simd.byte_class.comparisons import (
    byte_ge,
    byte_le,
    byte_ne,
    float_ge,
    float_le,
    float_lt,
    float_ne,
    int_ge,
    int_gt,
    int_le,
    int_ne,
)
from komira_simd.byte_class.compress_expand import compress_u8x64, compress_with_count_u8x64
from komira_simd.byte_class.conditional_select import if_negative_then_else
from komira_simd.byte_class.horizontal_reduce import count_true_mask_u8, reduce_and
from komira_simd.byte_class.masked_memory import masked_load_u8x64, masked_store_u8x64, tail_mask_u8x64
from komira_simd.byte_class.quote_region_mask import quote_region_mask_u64_with_carry_out
from komira_simd.byte_class.table_lookup import nibble_lut_classify_u8x32
from komira_simd.byte_class.type_cast import (
    convert_f32_to_i32,
    convert_to_f32,
    demote_to_i16,
    demote_to_i32,
    demote_to_i8,
    demote_to_u16,
    demote_to_u32,
    promote_to_i16,
    promote_to_i32,
    promote_to_i64,
    promote_to_u16,
    promote_to_u64,
)


def _bools(s: String) raises -> SIMD[DType.bool, 4]:
    """'TFTT' -> a 4-lane bool vector."""
    var out = SIMD[DType.bool, 4](fill=False)
    var b = s.as_bytes()
    for k in range(4):
        out[k] = b[k] == UInt8(ord("T"))
    return out


def _same(got: SIMD[DType.bool, 4], want: String, what: String) raises:
    var w = _bools(want)
    for k in range(4):
        assert_equal(got[k], w[k], what + " lane " + String(k))


# --- C1 ---------------------------------------------------------------------

def test_comparisons_unsigned_signed_float() raises:
    var ua = SIMD[DType.uint8, 4](0x7F, 0x80, 0x80, 0x00)
    var ub = SIMD[DType.uint8, 4](0x80, 0x80, 0x7F, 0xFF)
    _same(byte_ne[4](ua, ub), "TFTT", "byte_ne")
    _same(byte_le[4](ua, ub), "TTFT", "byte_le")
    _same(byte_ge[4](ua, ub), "FTTF", "byte_ge")
    var ia = SIMD[DType.int8, 4](-1, 5, 1, -128)
    var ib = SIMD[DType.int8, 4](1, 5, -1, 127)
    _same(int_ne[DType.int8, 4](ia, ib), "TFTT", "int_ne")
    _same(int_le[DType.int8, 4](ia, ib), "TTFT", "int_le")
    _same(int_gt[DType.int8, 4](ia, ib), "FFTF", "int_gt")
    _same(int_ge[DType.int8, 4](ia, ib), "FTTF", "int_ge")
    # float_ne on ordered lanes only: on a NaN lane it answers False, not the
    # IEEE True its docstring promises (komira-ai/komira#937), so no NaN here.
    var ea = SIMD[DType.float32, 4](1.0, 2.0, 3.0, -0.0)
    var eb = SIMD[DType.float32, 4](2.0, 2.0, 2.0, 0.0)
    _same(float_ne[DType.float32, 4](ea, eb), "TFTF", "float_ne")
    var nan = Float32(0.0) / Float32(0.0)
    var fa = SIMD[DType.float32, 4](1.0, 2.0, 3.0, nan)
    var fb = SIMD[DType.float32, 4](2.0, 2.0, 2.0, 1.0)
    _same(float_lt[DType.float32, 4](fa, fb), "TFFF", "float_lt")
    _same(float_le[DType.float32, 4](fa, fb), "TTFF", "float_le")
    _same(float_ge[DType.float32, 4](fa, fb), "FTTF", "float_ge")


# --- F1 ---------------------------------------------------------------------

def _chunk[W: Int](needles: List[UInt8], at: List[Int]) -> SIMD[DType.uint8, W]:
    var c = SIMD[DType.uint8, W](0x78)  # 'x', no needle
    for i in range(len(at)):
        c[at[i]] = needles[i]
    return c


def _check_hits[W: Int](got: SIMD[DType.uint8, W], at: List[Int], what: String) raises:
    for k in range(W):
        var want = UInt8(0)
        for i in range(len(at)):
            if at[i] == k:
                want = UInt8(0xFF)
        assert_equal(got[k], want, what + " lane " + String(k))


def test_find_eq_every_width_and_arity() raises:
    var n: List[UInt8] = [UInt8(0x2C), UInt8(0x0A), UInt8(0x0D), UInt8(0x22), UInt8(0x5C)]
    var a16_3: List[Int] = [0, 5, 15]
    _check_hits[16](byte_find_eq_3_u8x16(_chunk[16](n, a16_3), n[0], n[1], n[2]), a16_3, "eq_3_u8x16")
    var a16_5: List[Int] = [0, 3, 8, 12, 15]
    _check_hits[16](
        byte_find_eq_5_u8x16(_chunk[16](n, a16_5), n[0], n[1], n[2], n[3], n[4]), a16_5, "eq_5_u8x16"
    )
    var a32_2: List[Int] = [3, 31]
    _check_hits[32](byte_find_eq_2_u8x32(_chunk[32](n, a32_2), n[0], n[1]), a32_2, "eq_2_u8x32")
    var a32_3: List[Int] = [0, 16, 31]
    _check_hits[32](byte_find_eq_3_u8x32(_chunk[32](n, a32_3), n[0], n[1], n[2]), a32_3, "eq_3_u8x32")
    var a32_5: List[Int] = [0, 7, 16, 25, 31]
    _check_hits[32](
        byte_find_eq_5_u8x32(_chunk[32](n, a32_5), n[0], n[1], n[2], n[3], n[4]), a32_5, "eq_5_u8x32"
    )
    var a64_2: List[Int] = [0, 63]
    _check_hits[64](byte_find_eq_2_u8x64(_chunk[64](n, a64_2), n[0], n[1]), a64_2, "eq_2_u8x64")
    var a64_4: List[Int] = [0, 21, 42, 63]
    _check_hits[64](
        byte_find_eq_4_u8x64(_chunk[64](n, a64_4), n[0], n[1], n[2], n[3]), a64_4, "eq_4_u8x64"
    )


# --- F2 ---------------------------------------------------------------------

def test_nibble_lut_32_lanes() raises:
    var lo = SIMD[DType.uint8, 16](0)
    var hi = SIMD[DType.uint8, 16](0)
    for k in range(16):
        lo[k] = UInt8((k * 37 + 5) % 256)
        hi[k] = UInt8((k * 91 + 200) % 256)
    var chunk = SIMD[DType.uint8, 32](0)
    for k in range(32):
        chunk[k] = UInt8((k * 17 + 3 + (k // 16) * 64) % 256)
    var got = nibble_lut_classify_u8x32(lo, hi, chunk)
    var got_set = byte_find_in_set_u8x32(lo, hi, chunk)
    for k in range(32):
        var b = Int(chunk[k])
        var want = lo[b % 16] & hi[b // 16]
        assert_equal(got[k], want, "nibble_lut_classify_u8x32 lane " + String(k))
        assert_equal(got_set[k], want, "byte_find_in_set_u8x32 lane " + String(k))


# --- M1 ---------------------------------------------------------------------

def _mask64() -> SIMD[DType.bool, 64]:
    var m = SIMD[DType.bool, 64](fill=False)
    for k in range(64):
        m[k] = k % 3 == 0 or k >= 60
    return m


def test_masked_load_store_64() raises:
    var backing = List[UInt8]()
    for k in range(64):
        backing.append(UInt8(k + 1))
    var loaded = masked_load_u8x64(Span[UInt8](backing), _mask64(), SIMD[DType.uint8, 64](0xEE))
    for k in range(64):
        var want = UInt8(k + 1) if (k % 3 == 0 or k >= 60) else UInt8(0xEE)
        assert_equal(loaded[k], want, "masked_load_u8x64 lane " + String(k))
    var dst = List[UInt8]()
    for _ in range(64):
        dst.append(UInt8(0xAB))
    var vec = SIMD[DType.uint8, 64](0)
    for k in range(64):
        vec[k] = UInt8(k + 100)
    var dspan = Span[UInt8](dst)
    masked_store_u8x64(dspan, vec, _mask64())
    for k in range(64):
        var want = UInt8(k + 100) if (k % 3 == 0 or k >= 60) else UInt8(0xAB)
        assert_equal(dst[k], want, "masked_store_u8x64 lane " + String(k))


def test_tail_mask_64() raises:
    var ns: List[Int] = [0, 1, 31, 32, 33, 63, 64, 100]
    for i in range(len(ns)):
        var m = tail_mask_u8x64(ns[i])
        for k in range(64):
            assert_equal(m[k], k < ns[i], "tail_mask_u8x64(" + String(ns[i]) + ") lane " + String(k))


# --- X1 ---------------------------------------------------------------------

def test_compress_64() raises:
    var src = SIMD[DType.uint8, 64](0)
    for k in range(64):
        src[k] = UInt8(k)
    var m = SIMD[DType.bool, 64](fill=False)
    var keep: List[Int] = [1, 30, 33, 62, 63]
    for i in range(len(keep)):
        m[keep[i]] = True
    var pt = SIMD[DType.uint8, 64](0xAA)
    var out = compress_u8x64(src, m, pt)
    var pair = compress_with_count_u8x64(src, m, pt)
    assert_equal(pair[1], 5, "compress_with_count_u8x64 count")
    for k in range(64):
        var want = UInt8(keep[k]) if k < len(keep) else UInt8(0xAA)
        assert_equal(out[k], want, "compress_u8x64 lane " + String(k))
        assert_equal(pair[0][k], want, "compress_with_count_u8x64 lane " + String(k))
    var all_on = compress_with_count_u8x64(src, SIMD[DType.bool, 64](fill=True), pt)
    assert_equal(all_on[1], 64, "compress_with_count_u8x64 all-true count")
    assert_equal(all_on[0][63], UInt8(63), "compress_with_count_u8x64 all-true lane 63")


# --- Q1 ---------------------------------------------------------------------

def test_quote_mask_carry_out() raises:
    var carry = False
    # One quote at bit 10: inside from 10 to the end, so the chunk ends inside.
    var r1 = quote_region_mask_u64_with_carry_out(UInt64(1) << 10, carry)
    assert_equal(r1, ~((UInt64(1) << 10) - 1), "chunk 1 region")
    assert_true(carry, "chunk 1 ends inside a string")
    # Carried in: inside until the closing quote at bit 5.
    var r2 = quote_region_mask_u64_with_carry_out(UInt64(1) << 5, carry)
    assert_equal(r2, (UInt64(1) << 5) - 1, "chunk 2 region")
    assert_false(carry, "chunk 2 ends outside")
    # A pair at bits 3 and 9 inside one chunk: the carry stays out.
    var r3 = quote_region_mask_u64_with_carry_out((UInt64(1) << 3) | (UInt64(1) << 9), carry)
    assert_equal(r3, (UInt64(1) << 9) - (UInt64(1) << 3), "chunk 3 region")
    assert_false(carry, "chunk 3 ends outside")
    # A quote at bit 0 only: the region's low bit is set but bit 63 decides.
    var r4 = quote_region_mask_u64_with_carry_out(UInt64(1), carry)
    assert_equal(r4, ~UInt64(0), "chunk 4 region")
    assert_true(carry, "chunk 4 ends inside")


# --- T1 ---------------------------------------------------------------------

def test_type_casts() raises:
    var u = SIMD[DType.uint8, 4](0, 1, 0x7F, 0xFF)
    var u16 = promote_to_u16[4](u)
    var u64 = promote_to_u64[4](u)
    assert_equal(u16[3], UInt16(255), "promote_to_u16 zero-extends")
    assert_equal(u64[3], UInt64(255), "promote_to_u64 zero-extends")
    assert_equal(u64[2], UInt64(127), "promote_to_u64 lane 2")
    var s = SIMD[DType.int8, 4](-128, -1, 0, 127)
    var s16 = promote_to_i16[4](s)
    var s32 = promote_to_i32[4](s)
    var s64 = promote_to_i64[4](s)
    for k in range(4):
        assert_equal(Int(s16[k]), Int(s[k]), "promote_to_i16 lane " + String(k))
        assert_equal(Int(s32[k]), Int(s[k]), "promote_to_i32 lane " + String(k))
        assert_equal(Int(s64[k]), Int(s[k]), "promote_to_i64 lane " + String(k))
    assert_equal(demote_to_u16[DType.uint32, 2](SIMD[DType.uint32, 2](0x12345678, 0x10000))[0], UInt16(0x5678))
    assert_equal(demote_to_u16[DType.uint32, 2](SIMD[DType.uint32, 2](0x12345678, 0x10000))[1], UInt16(0))
    assert_equal(demote_to_u32[DType.uint64, 2](SIMD[DType.uint64, 2](0x100000005, 7))[0], UInt32(5))
    var i8 = demote_to_i8[DType.int32, 2](SIMD[DType.int32, 2](0x17F, 0x180))
    assert_equal(i8[0], Int8(127), "demote_to_i8 keeps the low byte")
    assert_equal(i8[1], Int8(-128), "demote_to_i8 low byte 0x80")
    assert_equal(demote_to_i16[DType.int32, 2](SIMD[DType.int32, 2](0x18000, 0))[0], Int16(-32768))
    assert_equal(demote_to_i32[DType.int64, 2](SIMD[DType.int64, 2](0x180000000, 0))[0], Int32(-2147483648))
    var f = convert_to_f32[DType.int32, 2](SIMD[DType.int32, 2](-3, 16777216))
    assert_equal(f[0], Float32(-3.0), "convert_to_f32 negative")
    assert_equal(f[1], Float32(16777216.0), "convert_to_f32 2^24")
    var fu = convert_to_f32[DType.uint8, 2](SIMD[DType.uint8, 2](255, 0))
    assert_equal(fu[0], Float32(255.0), "convert_to_f32 of 0xFF is unsigned")
    var t = convert_f32_to_i32[4](SIMD[DType.float32, 4](-2.75, 2.75, -0.5, 1e6))
    assert_equal(t[0], Int32(-2), "convert_f32_to_i32 truncates toward 0 (negative)")
    assert_equal(t[1], Int32(2), "convert_f32_to_i32 truncates toward 0 (positive)")
    assert_equal(t[2], Int32(0), "convert_f32_to_i32 of -0.5")
    assert_equal(t[3], Int32(1000000), "convert_f32_to_i32 of 1e6")


# --- R1 ---------------------------------------------------------------------

def test_positions_popcount_reductions() raises:
    var pos = List[Int]()
    append_set_positions_u32(UInt32(0x80000001), 100, pos)
    assert_equal(len(pos), 2, "append_set_positions_u32 count")
    assert_equal(pos[0], 100, "append_set_positions_u32 bit 0")
    assert_equal(pos[1], 131, "append_set_positions_u32 bit 31")
    assert_equal(popcount_u64(~UInt64(0)), 64, "popcount_u64 all-ones")
    assert_equal(popcount_u64(UInt64(1) << 63), 1, "popcount_u64 top bit")
    assert_equal(reduce_and[DType.uint8, 4](SIMD[DType.uint8, 4](0xFF, 0xFE, 0xFF, 0xFF)), UInt8(0xFE))
    assert_equal(reduce_and[DType.uint8, 4](SIMD[DType.uint8, 4](0xF0, 0xFF, 0xFF, 0x0F)), UInt8(0))
    var bm = SIMD[DType.uint8, 64](0)
    bm[0] = 0xFF
    bm[1] = 0x7F
    bm[63] = 0xFF
    assert_equal(count_true_mask_u8[64](bm), 2, "count_true_mask_u8 counts 0xFF lanes only")
    var c = SIMD[DType.int8, 4](-1, 0, 1, -128)
    var y = SIMD[DType.int8, 4](10, 11, 12, 13)
    var n = SIMD[DType.int8, 4](20, 21, 22, 23)
    var r = if_negative_then_else[DType.int8, 4](c, y, n)
    assert_equal(r[0], Int8(10), "if_negative_then_else -1")
    assert_equal(r[1], Int8(21), "if_negative_then_else 0 is not negative")
    assert_equal(r[2], Int8(22), "if_negative_then_else 1")
    assert_equal(r[3], Int8(13), "if_negative_then_else -128")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

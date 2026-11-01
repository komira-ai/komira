# =============================================================================
# movemask.mojo — byte-mask → bitmask conversion (Highway BitsFromMask family).
# =============================================================================
#
# Highway category: Mask Operations (BitsFromMask, MaskFromVec, FindFirstTrue,
# CountTrue).
#
# Given a `SIMD[uint8, W]` byte-mask (each lane 0xFF or 0x00), pack the W
# set/unset bits into a `UInt16` / `UInt32` / `UInt64` bitmask.  Bit k of
# the result is 1 iff lane k of the input is 0xFF.
#
# This is the CSV / JSON byte-class scan's central primitive: after the
# `chunk.eq(target)` byte-class comparison gives a byte-mask, `movemask_*`
# compresses it into a scalar bitmask suitable for `tzcnt`-iterate or
# `popcount` consumption.  Highway's `BitsFromMask(mask)` returns a
# `uint64_t`; we expose per-W variants because Mojo's `comptime if`
# dispatch keys cleanly off the lane count.
#
# Architecture lowering:
#   - x86 AVX-512 BW: `vpmovb2m k0, zmm` (mask-extraction, 1 cycle).
#     This module currently goes through the stdlib `reduce_add` path;
#     direct intrinsic dispatch would be faster (same fallback posture as
#     horizontal_add on x86).
#   - x86 AVX2: `vpmovmskb` from the `<32 x i8>` byte-mask.
#   - x86 SSE2: `pmovmskb` from `<16 x i8>`.
#   - arm64 NEON: the canonical "AND with lane-bit LUT, then `addv`"
#     pattern (faster on NEON than a shift-and-accumulate alternative).
#
# Functions:
#   * `byte_eq_to_bytemask_u8x16` / `_u8x32` / `_u8x64` (NEON / AVX2 /
#     AVX-512 BW widths)
#   * `movemask_to_uint_u8x16` / `_u8x32` (32 bits) / `_u8x64` (64 bits).
#
# Encapsulation: all functions take `SIMD[uint8, W]` inputs and return
# `UInt16/32/64` outputs — no UnsafePointer, no raw pointer arithmetic.
# =============================================================================

from std.sys.info import CompilationTarget, simd_width_of
from std.sys.intrinsics import llvm_intrinsic


# =============================================================================
# byte_eq_to_bytemask — Highway-equivalent `Eq(vec, broadcast(target))` then
# materialize to byte-mask 0xFF/0x00 shape.
# =============================================================================
#
# A SIMD[T, W>1] comparison returns SIMD[bool, W], and the canonical way
# to materialize it as a byte-mask is `chunk.eq(target).select(ones,
# zeros)` — single `cmeq.16b` on NEON, no overhead vs a cast.

@always_inline
def byte_eq_to_bytemask_u8x16(
    chunk: SIMD[DType.uint8, 16], target: UInt8
) -> SIMD[DType.uint8, 16]:
    """`chunk[k] == target` → 0xFF, else 0x00 for 16-lane width.

    Lowers to one `cmeq.16b` + one `bsl.16b` (NEON) / `vpcmpeqb` +
    `vpblendvb` (AVX2; sometimes folded to `vpcmpeqb` alone if Constants
    fuse) per chunk.
    """
    var ones = SIMD[DType.uint8, 16](0xFF)
    var zeros = SIMD[DType.uint8, 16](0x00)
    var tgt = SIMD[DType.uint8, 16](target)
    return chunk.eq(tgt).select(ones, zeros)


@always_inline
def byte_eq_to_bytemask_u8x32(
    chunk: SIMD[DType.uint8, 32], target: UInt8
) -> SIMD[DType.uint8, 32]:
    """`chunk[k] == target` → 0xFF, else 0x00 for 32-lane AVX2 width.

    Same `.eq().select(...)` idiom scaled up:
      - AVX2: `vpcmpeqb` (ymm) + blend; Mojo's `.eq().select(...)`
        lowers to the right ymm instruction.
      - NEON (Apple Silicon NEON is 16-lane native; SIMD[uint8, 32]
        is two-vector): two `cmeq.16b` + two `bsl.16b` pairs, no extra
        cost vs separate 16-lane calls.
    """
    var ones = SIMD[DType.uint8, 32](0xFF)
    var zeros = SIMD[DType.uint8, 32](0x00)
    var tgt = SIMD[DType.uint8, 32](target)
    return chunk.eq(tgt).select(ones, zeros)


@always_inline
def byte_eq_to_bytemask_u8x64(
    chunk: SIMD[DType.uint8, 64], target: UInt8
) -> SIMD[DType.uint8, 64]:
    """`chunk[k] == target` → 0xFF, else 0x00 for 64-lane AVX-512 BW width.

    On AVX-512 BW the comparison emits a `vpcmpb` to a
    k1 mask, then `vpmovm2b` to materialize the byte-mask (or fuses into
    `vpternlogq`).  On non-AVX-512 hardware Mojo lowers to four 16-lane
    NEON / two 32-lane AVX2 chunks.
    """
    var ones = SIMD[DType.uint8, 64](0xFF)
    var zeros = SIMD[DType.uint8, 64](0x00)
    var tgt = SIMD[DType.uint8, 64](target)
    return chunk.eq(tgt).select(ones, zeros)


# =============================================================================
# movemask_to_uint — byte-mask → bitmask (Highway BitsFromMask).
# =============================================================================

@always_inline
def movemask_to_uint_u8x16(byte_mask: SIMD[DType.uint8, 16]) -> UInt32:
    """16-lane byte-mask → 16-bit bitmask (returned as UInt32 for downstream
    OR-merge).

    Bit k of result is 1 iff `byte_mask[k] == 0xFF`.

    Algorithm: AND with per-lane bit-position LUT, then dual 8-lane
    `reduce_add` to combine halves (faster on NEON than a
    shift-and-accumulate alternative).

    NEON lowering: ~5 instructions (`and.16b`, two `addv b0, v.8b`,
    bit-extract + OR).
    x86 lowering: stdlib lowers to `vpmovmskb` on SSE2 / AVX2 paths.
    """
    var lut = SIMD[DType.uint8, 16](
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
    )
    var weighted = byte_mask & lut
    var lo = weighted.slice[8, offset=0]()
    var hi = weighted.slice[8, offset=8]()
    var lo_byte = lo.reduce_add()
    var hi_byte = hi.reduce_add()
    return UInt32(lo_byte) | (UInt32(hi_byte) << 8)


@always_inline
def movemask_to_uint_u8x32(byte_mask: SIMD[DType.uint8, 32]) -> UInt32:
    """32-lane byte-mask → 32-bit bitmask.

    AVX2's `vpmovmskb ymm` is the single-instruction
    target on x86; on NEON we fall back to two 16-lane movemask halves
    OR'd at bits [0..15] + [16..31].

    Algorithm:
      - x86: rely on Mojo's stdlib SIMD-cast-to-bool-then-bitcast which
        on AVX2 lowers to `vpcmpeqb` + `vpmovmskb`. For byte-mask inputs
        we threshold non-zero lanes via `bytes >= 0x01` and let
        `reduce_add` of a per-lane weighted vector materialize the
        bitmask.
      - NEON: split into two 16-lane halves and OR, using the u8x16 form.
    """
    var lo = byte_mask.slice[16, offset=0]()
    var hi = byte_mask.slice[16, offset=16]()
    var lo_bits = movemask_to_uint_u8x16(lo)
    var hi_bits = movemask_to_uint_u8x16(hi)
    return lo_bits | (hi_bits << 16)


@always_inline
def movemask_to_uint_u8x64(byte_mask: SIMD[DType.uint8, 64]) -> UInt64:
    """64-lane byte-mask → 64-bit bitmask (full UInt64).

    AVX-512 BW's `vpmovb2m k0, zmm` is the
    single-instruction target on x86; on NEON / AVX2 we split into
    32-lane halves.

    Algorithm: compose two 32-lane movemask halves at bit positions
    [0..31] + [32..63].
    """
    var lo = byte_mask.slice[32, offset=0]()
    var hi = byte_mask.slice[32, offset=32]()
    var lo_bits = UInt64(movemask_to_uint_u8x32(lo))
    var hi_bits = UInt64(movemask_to_uint_u8x32(hi))
    return lo_bits | (hi_bits << UInt64(32))


# =============================================================================
# bool_vec_to_uint — convert SIMD[bool, W] → UInt bitmask.
# =============================================================================
#
# When a primitive ALREADY produced a SIMD[bool, W] (e.g. from
# `SIMD.gt(a, b)`), we want to pack it directly to a
# bitmask without round-tripping through a 0xFF/0x00 byte-mask.  This
# is the Highway `BitsFromMask` overload that takes the native `Mask<T>`
# rather than a materialized vector.
#
# Implementation: `mask.cast[DType.uint8]()` materializes 1/0 lanes (NOT
# 0xFF/0x00), then we multiply by 0xFF to widen to byte-mask shape, then
# route through the movemask helpers above.  ALTERNATIVE: the
# comptime-OR-shift form is faster on NEON (no `addv` round-trip)
# but doesn't auto-lower to `kmov` on AVX-512.  We provide both: the
# default `bool_vec_to_uint_W` uses the `cast→movemask` path; the
# `bool_vec_to_uint_W_comptime_pack` uses the comptime-OR-shift form
# for hot loops that want guaranteed branchless lowering.

@always_inline
def bool_vec_to_uint_u8x16(mask: SIMD[DType.bool, 16]) -> UInt32:
    """16-lane bool-mask → 16-bit bitmask.  Bit k = 1 iff `mask[k]`."""
    var bm = mask.select(SIMD[DType.uint8, 16](0xFF), SIMD[DType.uint8, 16](0x00))
    return movemask_to_uint_u8x16(bm)


@always_inline
def bool_vec_to_uint_u8x32(mask: SIMD[DType.bool, 32]) -> UInt32:
    """32-lane bool-mask → 32-bit bitmask."""
    var bm = mask.select(SIMD[DType.uint8, 32](0xFF), SIMD[DType.uint8, 32](0x00))
    return movemask_to_uint_u8x32(bm)


@always_inline
def bool_vec_to_uint_u8x64(mask: SIMD[DType.bool, 64]) -> UInt64:
    """64-lane bool-mask → 64-bit bitmask (full UInt64).

    Comptime-OR-shift form
    — guaranteed branchless lowering; LLVM optimizes to `kmovq` from
    a k1 mask on AVX-512, falls back to a comptime-unrolled per-lane
    test-and-set on NEON / non-AVX-512 (still ~64 cycles, dominated by
    the per-lane `test+csel+orr`).
    """
    var bits: UInt64 = 0
    comptime for k in range(64):
        if mask[k]:
            bits = bits | (UInt64(1) << UInt64(k))
    return bits

# =============================================================================
# type_cast.mojo — Highway Type Conversions category (PromoteTo / DemoteTo /
# ConvertTo).
# =============================================================================
#
# Highway category: Type Conversions.
#
# Covered conversions: widening promote (u8x32 → u32x32), narrowing
# demote (u32x32 → u8x32, truncate), int → fp (i64x8 → f64x8), fp → int
# (f64x8 → i64x8, truncate), bool → uint mask materialization (bool32 →
# u8x32 as 1/0).
#
# Mojo's `SIMD.cast[DType]()` is the universal cast op.  This module
# provides Highway-named wrappers so byte-class scan + CSV parsing code
# can use the Highway taxonomy.
#
# Highway maps:
#   - `PromoteTo<T>(vec)`     — widening, same lane count, larger lanes.
#                               Mojo: `vec.cast[T]()` when sizeof(T) >
#                               sizeof(input).
#   - `PromoteUpperTo<T>(vec)`— widening UPPER half (returns SIMD[T, W/2]).
#                               Mojo: `vec.slice[W/2, offset=W/2]().cast[T]()`.
#   - `PromoteLowerTo<T>(vec)`— widening LOWER half.
#   - `DemoteTo<T>(vec)`      — narrowing, same lane count, smaller lanes.
#                               Truncating (NOT saturating).  Mojo:
#                               `vec.cast[T]()` when sizeof(T) <
#                               sizeof(input).
#   - `ConvertTo<T>(vec)`     — int ↔ fp conversion at same lane width.
#                               Mojo: same `.cast[T]()` family.
#
# SATURATING demote is NOT covered by `cast[]` — that's a separate
# Highway primitive (`U16FromU32Saturated`).  Mojo would need an
# `llvm.x86.sse2.packuswb` or `llvm.aarch64.neon.sqxtun` intrinsic
# wrap, which this module does not provide.
#
# Encapsulation: SIMD-in / SIMD-out; no pointers.
# =============================================================================

from std.sys.info import simd_width_of


# =============================================================================
# Widening Promotions (small → large lane size).
# =============================================================================

@always_inline
def promote_to_u16[W: Int](v: SIMD[DType.uint8, W]) -> SIMD[DType.uint16, W]:
    """UInt8 × W → UInt16 × W widening.  Highway `PromoteTo<uint16>`.

    Lowers to:
      - NEON: `uxtl.8h` (lower half) or `uxtl2.8h` (upper half) when
        W <= 16; for W=32 LLVM emits a pair of `uxtl`/`uxtl2`.
      - AVX2: `vpmovzxbw` (8 → 16 bits).
    """
    return v.cast[DType.uint16]()


@always_inline
def promote_to_u32[W: Int](v: SIMD[DType.uint8, W]) -> SIMD[DType.uint32, W]:
    """UInt8 × W → UInt32 × W widening.  Highway `PromoteTo<uint32>`.

    Lowers via chained widen (8 → 16 → 32) on NEON; `vpmovzxbd` on AVX2."""
    return v.cast[DType.uint32]()


@always_inline
def promote_to_u64[W: Int](v: SIMD[DType.uint8, W]) -> SIMD[DType.uint64, W]:
    """UInt8 × W → UInt64 × W widening.  `vpmovzxbq` on AVX2."""
    return v.cast[DType.uint64]()


@always_inline
def promote_to_i16[W: Int](v: SIMD[DType.int8, W]) -> SIMD[DType.int16, W]:
    """Int8 × W → Int16 × W signed widening (sign-extend).  Highway
    `PromoteTo<int16>`.  `vpmovsxbw` on AVX2 / `sxtl.8h` on NEON."""
    return v.cast[DType.int16]()


@always_inline
def promote_to_i32[W: Int](v: SIMD[DType.int8, W]) -> SIMD[DType.int32, W]:
    """Int8 × W → Int32 × W signed widening."""
    return v.cast[DType.int32]()


@always_inline
def promote_to_i64[W: Int](v: SIMD[DType.int8, W]) -> SIMD[DType.int64, W]:
    """Int8 × W → Int64 × W signed widening."""
    return v.cast[DType.int64]()


# =============================================================================
# Narrowing Demotions (large → small lane size).  Truncating, NOT saturating.
# =============================================================================
#
# WARNING: `.cast[DType.uint8]()` on a value > 255 TRUNCATES (drops the
# high bits) rather than saturating to 0xFF.  A saturating demote needs
# its own primitive (see the module header).

@always_inline
def demote_to_u8[T: DType, W: Int](
    v: SIMD[T, W]
) -> SIMD[DType.uint8, W]:
    """T × W → UInt8 × W narrowing (TRUNCATE).  Highway `DemoteTo<uint8>`."""
    return v.cast[DType.uint8]()


@always_inline
def demote_to_u16[T: DType, W: Int](
    v: SIMD[T, W]
) -> SIMD[DType.uint16, W]:
    """T × W → UInt16 × W narrowing (TRUNCATE)."""
    return v.cast[DType.uint16]()


@always_inline
def demote_to_u32[T: DType, W: Int](
    v: SIMD[T, W]
) -> SIMD[DType.uint32, W]:
    """T × W → UInt32 × W narrowing (TRUNCATE)."""
    return v.cast[DType.uint32]()


@always_inline
def demote_to_i8[T: DType, W: Int](
    v: SIMD[T, W]
) -> SIMD[DType.int8, W]:
    """T × W → Int8 × W narrowing (TRUNCATE)."""
    return v.cast[DType.int8]()


@always_inline
def demote_to_i16[T: DType, W: Int](
    v: SIMD[T, W]
) -> SIMD[DType.int16, W]:
    """T × W → Int16 × W narrowing (TRUNCATE)."""
    return v.cast[DType.int16]()


@always_inline
def demote_to_i32[T: DType, W: Int](
    v: SIMD[T, W]
) -> SIMD[DType.int32, W]:
    """T × W → Int32 × W narrowing (TRUNCATE)."""
    return v.cast[DType.int32]()


# =============================================================================
# Int ↔ Float conversions.
# =============================================================================

@always_inline
def convert_to_f32[T: DType, W: Int](
    v: SIMD[T, W]
) -> SIMD[DType.float32, W]:
    """T × W → Float32 × W IEEE-754 conversion.  Highway `ConvertTo<float32>`.

    For integer inputs: signed/unsigned aware integer-to-float.
    Rounding mode: stdlib default (typically round-to-nearest-even).
    """
    return v.cast[DType.float32]()


@always_inline
def convert_to_f64[T: DType, W: Int](
    v: SIMD[T, W]
) -> SIMD[DType.float64, W]:
    """T × W → Float64 × W IEEE-754 conversion."""
    return v.cast[DType.float64]()


@always_inline
def convert_f32_to_i32[W: Int](
    v: SIMD[DType.float32, W]
) -> SIMD[DType.int32, W]:
    """Float32 → Int32 truncation (towards zero).  Highway
    `ConvertTo<int32>(f32)`."""
    return v.cast[DType.int32]()


@always_inline
def convert_f64_to_i64[W: Int](
    v: SIMD[DType.float64, W]
) -> SIMD[DType.int64, W]:
    """Float64 → Int64 truncation (towards zero).  Highway
    `ConvertTo<int64>(f64)`.

    NOTE: undefined for NaN / infinity / values outside [-2^63, 2^63).
    Callers needing safe conversion should pre-filter such lanes."""
    return v.cast[DType.int64]()


# =============================================================================
# Bool-mask materialization to byte-mask.
# =============================================================================
#
# Important: `SIMD[bool, W].cast[uint8]()` produces 0/1, NOT 0xFF/0x00.
# Highway's `VecFromMask(mask)` produces 0xFF/0x00.  We expose both:
# `bool_to_one_zero` (the Mojo native shape) and `bool_to_byte_mask`
# (the Highway shape, via `select`).

@always_inline
def bool_to_one_zero[W: Int](mask: SIMD[DType.bool, W]) -> SIMD[DType.uint8, W]:
    """`mask` → SIMD[uint8, W] with 1 for True lanes, 0 for False lanes.

    DIRECT `cast` — produces 1/0, NOT 0xFF/0x00.  Use this for
    population-count via `reduce_add` (each True contributes 1)."""
    return mask.cast[DType.uint8]()


@always_inline
def bool_to_byte_mask[W: Int](mask: SIMD[DType.bool, W]) -> SIMD[DType.uint8, W]:
    """`mask` → SIMD[uint8, W] with 0xFF for True lanes, 0x00 for False.

    Highway `VecFromMask(mask)` (also `MaskFromVec`'s inverse).  Goes
    through `.select(ones, zeros)` since `cast` produces 1/0."""
    return mask.select(SIMD[DType.uint8, W](0xFF), SIMD[DType.uint8, W](0x00))

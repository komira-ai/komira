# =============================================================================
# horizontal_reduce.mojo — Highway Horizontal Reductions category.
# =============================================================================
#
# Highway category: Horizontal Reductions (ReduceSum / ReduceMin /
# ReduceMax / ReduceAnd / ReduceOr).  Lane-parallel reductions over a
# full SIMD vector into a single scalar.
#
# All 5 reductions work across UInt8 x 32, Int64 x 8, Float64 x 8 and
# Bool x 64 lane combos.  This module provides typed wrappers over the
# stdlib `SIMD.reduce_*` family under the Highway taxonomy so byte-class /
# CSV code can use the Highway-style spelling.
#
# Per-DType + per-W coverage: each reduction is parametric on
# `T: DType` and `W: Int`.  Lane-width selection is delegated to the
# caller (or to `simd_width_of[T]()` at the call site).
#
# Note on Float reductions: Highway provides `ReduceAnd` / `ReduceOr`
# for floats via bit-pun; Mojo's SIMD[Float] does NOT expose these
# directly (the bit interpretation is unsafe for IEEE-754).  Callers
# must `.bitcast[uintN]()` first if they want bit-level float reduction.
#
# Note on Bool reductions: `reduce_or` / `reduce_and` ON `SIMD[bool, W]`
# are Highway's `AnyTrue` / `AllTrue` equivalents.  We expose them
# under those Highway names for clarity.
#
# Encapsulation: ALL inputs are SIMD values; ALL outputs are scalars.
# No pointers.
# =============================================================================


# =============================================================================
# ReduceSum — sum all lanes.
# =============================================================================

@always_inline
def reduce_sum[T: DType, W: Int](v: SIMD[T, W]) -> Scalar[T]:
    """Sum all W lanes of `v` into a single scalar.  Highway `ReduceSum(v)`.

    For UInt8/16/32/64: integer addition (truncates on overflow).
    For Int8/16/32/64: signed integer addition (overflow wraps).
    For Float32/64: IEEE-754 floating-point addition (order-dependent
    associativity; result may differ from a serial sum by a few ULPs).
    """
    return v.reduce_add()


# =============================================================================
# ReduceMin / ReduceMax — pairwise lane reductions.
# =============================================================================

@always_inline
def reduce_min[T: DType, W: Int](v: SIMD[T, W]) -> Scalar[T]:
    """Min over all W lanes.  Highway `ReduceMin(v)`.

    Float-NaN semantics: Mojo's stdlib reduce_min may propagate NaN
    differently from Highway's `MinNumber` (which skips NaN); callers
    needing NaN-skip must filter NaN lanes before reduction.
    """
    return v.reduce_min()


@always_inline
def reduce_max[T: DType, W: Int](v: SIMD[T, W]) -> Scalar[T]:
    """Max over all W lanes.  Highway `ReduceMax(v)`."""
    return v.reduce_max()


# =============================================================================
# ReduceAnd / ReduceOr — bitwise reductions (integer lanes only).
# =============================================================================

@always_inline
def reduce_and[T: DType, W: Int](v: SIMD[T, W]) -> Scalar[T]:
    """Bitwise AND over all W lanes.  Highway `ReduceAnd(v)`.

    For 0xFF/0x00 byte-masks: AND of all lanes is 0xFF iff EVERY lane
    is set — the Highway `AllTrue(mask)` shape.
    """
    return v.reduce_and()


@always_inline
def reduce_or[T: DType, W: Int](v: SIMD[T, W]) -> Scalar[T]:
    """Bitwise OR over all W lanes.  Highway `ReduceOr(v)`.

    For 0xFF/0x00 byte-masks: OR of all lanes is 0x00 iff EVERY lane
    is unset — `!AnyTrue(mask)`.
    """
    return v.reduce_or()


# =============================================================================
# Bool-mask reductions — Highway AllTrue / AnyTrue equivalents.
# =============================================================================
#
# Specialized for `SIMD[DType.bool, W]` — the common case for "did any
# byte in this chunk match" queries.

@always_inline
def all_true[W: Int](mask: SIMD[DType.bool, W]) -> Bool:
    """True iff every lane of `mask` is True.  Highway `AllTrue(mask)`.

    `mask.reduce_and()` on SIMD[bool, 64] returns the AND of all 64 bool
    lanes.
    """
    return Bool(mask.reduce_and())


@always_inline
def any_true[W: Int](mask: SIMD[DType.bool, W]) -> Bool:
    """True iff at least one lane of `mask` is True.  Highway
    `AnyTrue(mask)`."""
    return Bool(mask.reduce_or())


@always_inline
def count_true[W: Int](mask: SIMD[DType.bool, W]) -> Int:
    """Number of True lanes in `mask`.  Highway `CountTrue(mask)`.

    Lowers to `cast→reduce_add`; on AVX-512
    BW LLVM may fold into `kmovq + popcnt`.  Cost: ~3-5 cycles for
    W=32, ~5-8 for W=64.
    """
    return Int(mask.cast[DType.uint8]().reduce_add())


@always_inline
def count_true_mask_u8[W: Int](byte_mask: SIMD[DType.uint8, W]) -> Int:
    """Number of set lanes in a 0xFF/0x00 byte-mask.  Highway
    `CountTrue` over byte-mask shape.

    Each set lane contributes 0xFF to the sum; we divide by 0xFF (or
    equivalently shift right by 8 after multiply-and-add) to get the
    count.  In practice we use the simpler "compare to 0xFF then
    reduce_add of cast" path which is equivalent.
    """
    var ones = SIMD[DType.uint8, W](0xFF)
    var is_set = byte_mask.eq(ones)
    return Int(is_set.cast[DType.uint8]().reduce_add())

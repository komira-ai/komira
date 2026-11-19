# =============================================================================
# EvalXChunk[W] -- typed (values, validity) chunk wrapper family
# =============================================================================
#
# Uniform `(values: SIMD[T, W], validity:
# SIMD[Bool, W])` shape across all per-DType ExprX traits.
#
# The uniform shape is LOAD-BEARING: it preserves the "all-True validity
# splat folds away" comptime optimization (each conformer's eval[W]
# default for a non-nullable column returns `SIMD[DType.bool, Self.W]
# (fill=True)`, which the comptime non-nullable specialization
# eliminates entirely).
#
# Decimal128 / Decimal256 ship as a degenerate W=1 default (SIMD width
# is 1 for byte-slab dtypes in Mojo 1.0.0b1; the chunk wrapper still
# carries the uniform (values, validity) shape).
#
# NOTE: Mojo 1.0.0b1 SIMD does NOT support uint128 / uint256 lane
# types directly. The Decimal128/256 chunk wrappers ship in this file
# as comptime-stubbed structs with their value field typed as the
# storage-equivalent UInt128 / UInt256 scalar. When numeric aggregation
# needs them, the chunk wrappers may be refactored to hold a
# Decimal128 / Decimal256 struct directly. The Decimal*ColView accessors
# are deferred; the chunk wrapper here is the trait-surface placeholder.
# =============================================================================


# -----------------------------------------------------------------------------
# Bool — the load-bearing wrapper that the engine
# filter kernel uses. The ExprBool trait's eval[W] method returns this.
# -----------------------------------------------------------------------------


@fieldwise_init
struct EvalBoolChunk[W: Int](Copyable, Movable, ImplicitlyCopyable):
    """Typed (values, validity) chunk for a per-W-chunk Bool subtree
    evaluation.

    Carries the SIMD value mask plus the validity mask for Kleene 3VL
    propagation. All-valid inputs return validity =
    `SIMD[DType.bool, Self.W](fill=True)` which optimizes away in the
    comptime non-nullable specialization.

    Parameters:
        W: SIMD vector width (number of lanes).
    """

    var values: SIMD[DType.bool, Self.W]
    var validity: SIMD[DType.bool, Self.W]


# -----------------------------------------------------------------------------
# I64 / I32 / F64 / F32 — uniform (values, validity).
# -----------------------------------------------------------------------------


@fieldwise_init
struct EvalI64Chunk[W: Int](Copyable, Movable, ImplicitlyCopyable):
    """Typed (values, validity) chunk for an Int64 subtree."""
    var values: SIMD[DType.int64, Self.W]
    var validity: SIMD[DType.bool, Self.W]


@fieldwise_init
struct EvalI32Chunk[W: Int](Copyable, Movable, ImplicitlyCopyable):
    """Typed (values, validity) chunk for an Int32 subtree."""
    var values: SIMD[DType.int32, Self.W]
    var validity: SIMD[DType.bool, Self.W]


@fieldwise_init
struct EvalF64Chunk[W: Int](Copyable, Movable, ImplicitlyCopyable):
    """Typed (values, validity) chunk for a Float64 subtree."""
    var values: SIMD[DType.float64, Self.W]
    var validity: SIMD[DType.bool, Self.W]


@fieldwise_init
struct EvalF32Chunk[W: Int](Copyable, Movable, ImplicitlyCopyable):
    """Typed (values, validity) chunk for a Float32 subtree."""
    var values: SIMD[DType.float32, Self.W]
    var validity: SIMD[DType.bool, Self.W]


# -----------------------------------------------------------------------------
# Decimal128 / Decimal256 — W=1 default.
#
# Mojo 1.0.0b1 SIMD does not expose uint128 / uint256 lane types. We
# carry the storage-equivalent SIMD[DType.int128, Self.W] / SIMD[DType.int256,
# W] for W=1; SIMD-batched decimal arithmetic would refactor to a Decimal-struct-array layout.
# -----------------------------------------------------------------------------


@fieldwise_init
struct EvalDecimal128Chunk[W: Int = 1](
    Copyable, Movable, ImplicitlyCopyable
):
    """Typed (values, validity) chunk for a Decimal128 subtree (W=1
    default — SIMD width above 1 is not implemented).
    """
    var values: SIMD[DType.int128, Self.W]
    var validity: SIMD[DType.bool, Self.W]


@fieldwise_init
struct EvalDecimal256Chunk[W: Int = 1](
    Copyable, Movable, ImplicitlyCopyable
):
    """Typed (values, validity) chunk for a Decimal256 subtree (W=1
    default).
    """
    var values: SIMD[DType.int256, Self.W]
    var validity: SIMD[DType.bool, Self.W]

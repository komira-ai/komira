# =============================================================================
# agg_op_traits.mojo — HashAggOp per-DType trait declarations
# =============================================================================
#
# Per-bucket aggregate primitive traits. Conformers (`SumF64` / `CountF64`
# / `MinF64` / `MaxF64` / `AvgF64` and Int64 mirrors) land in
# `komira_engine_operators.agg.agg_state_slab` alongside the
# `AggStateSlab` / `KeyHashFn` / `KeyEqFn` container traits.
#
# Why declare at the eval-package level (not operators):
#   - The HashAggOp* traits are CONSUMED by both `HashAggTable` (single-key)
#     and `CompositeHashTable` (multi-key) stage primitives, both of which
#     live in `komira_engine_operators/stage_primitives/`.
#   - The same traits are consumed by shape-classified dispatch (the
#     LogicalPlan compiler emits trait-conformer names per shape).
#   - Sitting the trait declarations one level down (in `komira_eval`)
#     avoids an operators-vs-compiler dep cycle: komira_compiler does
#     not depend on komira_engine_operators, so trait-from-operators
#     would force a cycle through the SDK's compile-stage emission.
#   - Mirror precedent: the typed expression AST's `ExprI64` / `ExprF64` /
#     `ExprBool` trait declarations also live at the eval
#     level so that compiler-side code can reason about them without
#     pulling in operator implementations.
#
# Architectural property:
#   Per-bucket agg state is a TRAIT METHOD on the stage container, NOT
#   an Expr-tree node. The Expr trait family (ExprXBool / ExprXI64 /
#   ExprXF64 / ExprXString in `expr_x.mojo`) handles pure value
#   computation; HashAggOp* handles side-effecting state mutation. This
#   separation is what enables Mojo's monomorphizer to inline the
#   HashAggOp.update_scalar / update_chunk through the trait surface
#   into the fused-stage inner loop.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - `StateTy` is an associated AnyType; conformers
#     pick the concrete state representation (scalar Float64 for SumF64,
#     paired `(Float64, Float64)` for AvgF64, etc.).
#
# Conformers are one per agg-fn kind (NOT one big multi-agg slab), with a
# per-bucket single-state shape.
# =============================================================================


# =============================================================================
# §1 — HashAggOpF64 — per-bucket aggregate over Float64 input
# =============================================================================
#
# StateTy: each conformer picks its own state representation. Examples:
#   - SumF64: StateTy = Float64 (running sum)
#   - CountF64: StateTy = Float64 (running count)
#   - MinF64: StateTy = Float64 (running min; init = +Inf)
#   - MaxF64: StateTy = Float64 (running max; init = -Inf)
#   - AvgF64: StateTy = SIMD[DType.float64, 2] (paired sum + count)
#
# update_scalar runs per-row in the scalar tail; update_chunk[W] runs
# per-SIMD-chunk. Conformers MUST carry @always_inline on both so Mojo
# inlines them into the fused-stage loop body.
#
# `update_chunk` takes the SIMD lane vector
# plus a mask (boolean SIMD) for predicate-gated updates. For scatter-
# style (multi-bucket) aggregation the chunk is consumed per-lane
# (necessarily scalar — two lanes can map to the
# same bucket); for scalar-state (single-bucket) aggregation the chunk
# is reduced via `mask.select(...).reduce_add()` etc.
# =============================================================================


trait HashAggOpF64(Copyable, Movable, ImplicitlyCopyable):
    """Per-bucket aggregate trait over Float64 input.

    The `StateTy` associated type lets each conformer pick its own
    state representation (Float64 for Sum/Count/Min/Max; paired
    (Float64, Float64) for Avg; etc.). All three methods (`init`,
    `update_scalar`, `finalize`) are @staticmethod so conformers
    can be field-less marker structs (the SumF64 pattern).

    The `update_chunk[W]` SIMD method takes a value SIMD lane vector
    plus a Boolean mask (lane j is True iff the row should update);
    conformers either reduce the masked vector for scalar-state aggs
    (`mask.select(values, init).reduce_add()`) or loop per-lane for
    multi-bucket aggs (`for j in range(W): if mask[j]: ...`).

    StateTy bound: `Copyable & Movable` — required so HashAggTable's
    `InlineArray[AggOp.StateTy, MAX_GROUPS]` slab storage compiles
    (`InlineArray` requires `ElementType: Copyable`). All
    conformers (Float64 for Sum/Count/Min/Max; SIMD[float64, 2] for
    Avg) satisfy both bounds trivially.
    """

    comptime StateTy: Copyable & Movable & Deinitable

    @staticmethod
    def init() -> Self.StateTy:
        ...

    @staticmethod
    def update_scalar(mut state: Self.StateTy, value: Float64):
        ...

    @staticmethod
    def finalize(state: Self.StateTy) -> Float64:
        ...

    @staticmethod
    def combine(mut state: Self.StateTy, partial: Self.StateTy):
        """Merge a partial per-bucket
        state into `state` (the parallel-partial cross-worker merge). Bridges
        to the unified `Aggregator.combine` surface via the
        `HashAggOp*ToAggregator` adapter."""
        ...


# =============================================================================
# §2 — HashAggOpI64 — per-bucket aggregate over Int64 input
# =============================================================================


trait HashAggOpI64(Copyable, Movable, ImplicitlyCopyable):
    """Per-bucket aggregate trait over Int64 input.

    Mirror of `HashAggOpF64` with `Int64` value type. Conformers:
    `SumI64`, `CountI64`, `MinI64`, `MaxI64` (no AvgI64 — average
    output is Float64; use AvgF64 with an Int64-to-F64 cast Expr).

    StateTy bound: `Copyable & Movable` — see HashAggOpF64.
    """

    comptime StateTy: Copyable & Movable & Deinitable

    @staticmethod
    def init() -> Self.StateTy:
        ...

    @staticmethod
    def update_scalar(mut state: Self.StateTy, value: Int64):
        ...

    @staticmethod
    def finalize(state: Self.StateTy) -> Int64:
        ...

    @staticmethod
    def combine(mut state: Self.StateTy, partial: Self.StateTy):
        """Merge a partial per-bucket
        state into `state` (the parallel-partial cross-worker merge). Bridges
        to the unified `Aggregator.combine` surface via the
        `HashAggOp*ToAggregator` adapter."""
        ...


# =============================================================================
# §3 — HashAggOpI32 — per-bucket aggregate over Int32 input
#
# =============================================================================
#
# Mirror of HashAggOpI64 with Int32 value type. Conformers:
# `SumI32`, `CountI32`, `MinI32`, `MaxI32`.
#
# Sum overflow semantics: per-bucket state is Int32 with two's-complement
# wrap (matches SumI64 semantics — explicit widening cast is the SDK's
# responsibility, not the agg op's). Callers needing widened sum must
# emit Int32-to-I64 cast Expr and route through HashAggOpI64.
# =============================================================================


trait HashAggOpI32(Copyable, Movable, ImplicitlyCopyable):
    """Per-bucket aggregate trait over Int32 input.

    Mirror of `HashAggOpI64` with `Int32` value type. Conformers:
    `SumI32`, `CountI32`, `MinI32`, `MaxI32`.

    Sum overflow: two's-complement wrap on Int32 state (no implicit
    widening). For SUM-without-overflow on wide-domain Int32 columns,
    SDK must insert Int32-to-I64 cast Expr and route through HashAggOpI64.

    StateTy bound: `Copyable & Movable` — see HashAggOpF64.
    """

    comptime StateTy: Copyable & Movable & Deinitable

    @staticmethod
    def init() -> Self.StateTy:
        ...

    @staticmethod
    def update_scalar(mut state: Self.StateTy, value: Int32):
        ...

    @staticmethod
    def finalize(state: Self.StateTy) -> Int32:
        ...

    @staticmethod
    def combine(mut state: Self.StateTy, partial: Self.StateTy):
        """Merge a partial per-bucket
        state into `state` (the parallel-partial cross-worker merge). Bridges
        to the unified `Aggregator.combine` surface via the
        `HashAggOp*ToAggregator` adapter."""
        ...


# =============================================================================
# §4 — HashAggOpF32 — per-bucket aggregate over Float32 input
#
# =============================================================================
#
# Mirror of HashAggOpF64 with Float32 value type. Conformers:
# `SumF32`, `CountF32`, `MinF32`, `MaxF32`.
#
# There is no AvgF32 — it would need paired (sum, count) F32 state; only the
# 4 core aggs are provided.
# =============================================================================


trait HashAggOpF32(Copyable, Movable, ImplicitlyCopyable):
    """Per-bucket aggregate trait over Float32 input.

    Mirror of `HashAggOpF64` with `Float32` value type. Conformers:
    `SumF32`, `CountF32`, `MinF32`, `MaxF32`. AvgF32 not implemented
    (paired SIMD[float32, 2] state).

    StateTy bound: `Copyable & Movable` — see HashAggOpF64.
    """

    comptime StateTy: Copyable & Movable & Deinitable

    @staticmethod
    def init() -> Self.StateTy:
        ...

    @staticmethod
    def update_scalar(mut state: Self.StateTy, value: Float32):
        ...

    @staticmethod
    def finalize(state: Self.StateTy) -> Float32:
        ...

    @staticmethod
    def combine(mut state: Self.StateTy, partial: Self.StateTy):
        """Merge a partial per-bucket
        state into `state` (the parallel-partial cross-worker merge). Bridges
        to the unified `Aggregator.combine` surface via the
        `HashAggOp*ToAggregator` adapter."""
        ...

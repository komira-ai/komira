# =============================================================================
# builtin_agg_fns_sum_product.mojo — multi-column SUM(A*B) Aggregator
# =============================================================================
#
# The 2-column `SUM(col_a * col_b)` aggregator. Q6 needs this shape:
#
#   SUM(l_extendedprice * l_discount) AS revenue
#
# A typed Stage can stamp Q6's shape end-to-end through `SumOfProductF64[a_name, b_name]` marker +
# `SumProductF64Agg[col_a_idx, col_b_idx]` Aggregator with no harness sidecar.
#
# WHY NOT AggFn / AggFnAgg
# ------------------------
# `AggFnAgg[F: AggFn, col: Int]` is the adapter for SINGLE-column
# `AggFn` conformers. `SumProductF64` reads TWO columns per row (the A * B
# multiplication has no single InputRow shape that the `AggFn` trait surface
# admits with the arity=1 INPUT constraint). There is no multi-input-column
# AggFn adapter (see `agg_fn_agg.mojo`). Conforming
# directly to `Aggregator` is the canonical path for multi-column reducers —
# the precedent is `HashAggOpF64Agg[Op, col]` (single-col) extended naturally
# to a 2-col surface.
#
# Encapsulation invariants:
#   - NO UnsafePointer in any signature.
#   - NO wildcard origins.
#   - NO partial-move-via-take_pointee.
#   - POD `Float64` state (no heap; slab-safe in `InlineArray[Float64,
#     MAX_GROUPS]`).
#
# Cross-references:
#   - `aggregator.mojo` — the unified `Aggregator` trait surface.
#   - `agg_fn_agg.mojo` — the single-input AggFn adapter.
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_agg.aggregator import Aggregator


# =============================================================================
# SumProductF64Agg[col_a, col_b] — production 2-column SUM(A*B) aggregator
# =============================================================================


@fieldwise_init
struct SumProductF64Agg[col_a: Int, col_b: Int](Aggregator):
    """`Aggregator` conformer summing the PRODUCT of two Float64 columns.

    Per-group state: `Float64` (the running revenue/sum). Output DType:
    `DType.float64`. No `update_chunk` override — the default per-lane
    fan-out preserves bit-exact accumulation order vs the runtime arm
    (a masked-SIMD reduce-add would reassociate the sum; see the
    NOTE in the body).

    Typical usage from a typed marker:

        @fieldwise_init
        struct SumOfProductF64[a: StringLiteral, b: StringLiteral](AggSpecMarker):
            comptime BOUND[S: SchemaDescriptor] = (
                AggSlot[SumProductF64Agg[
                    S.index_of(String(Self.a)),
                    S.index_of(String(Self.b))
                ]]
            )
    """

    comptime StateTy = Float64
    comptime OUT_DT: DType = DType.float64

    @staticmethod
    @always_inline
    def make() -> Self:
        """`Aggregator.make` — field-less default-construct (VARIADIC-FACTORY).
        `@fieldwise_init` synthesizes the no-arg ctor for this field-less
        struct, so `Self()` is the trivial default-construct."""
        return Self()

    @staticmethod
    @always_inline
    def init() -> Float64:
        return Float64(0.0)

    @always_inline
    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Float64, batch: BatchView[bo], i: Int):
        var a = batch.col_f64(Self.col_a).load[1](i)[0]
        var b = batch.col_f64(Self.col_b).load[1](i)[0]
        state = state + a * b

    # NOTE: NO `update_chunk` override. A masked-SIMD reduce_add over
    # the chunk reassociates the float64 sum vs the untyped arm's scalar
    # per-row accumulate. The diff-gate is BIT-EXACT, so the default per-lane
    # `@parameter for` body keeps the typed/untyped revenue values byte-
    # identical. Vectorizing the SUM itself requires the untyped arm to
    # reassociate identically (a deeper, separate change) — surfaced as the
    # remaining perf headroom.

    @always_inline
    def combine(mut self, mut into: Float64, var partial: Float64):
        into = into + partial

    @staticmethod
    @always_inline
    def finalize(state: Float64) -> Scalar[DType.float64]:
        return state

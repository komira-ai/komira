# =============================================================================
# builtin_agg_fns_sum_expr.mojo — generic SUM(<ExprXF64>) Aggregator
# =============================================================================
#
# The GENERIC column-
# path computed-aggregand aggregator: SUM over an ARBITRARY Float64 expression
# tree, not just the fixed `col_a * col_b` of `SumProductF64Agg`.
#
#   SUM(price * (1 - discount))   AS revenue
#   SUM(a - b)  /  SUM(a + b)  /  SUM(a / b)  /  SUM(c * x)  ...
#
# `SumOfExprF64Agg[E: ExprXF64]` generalizes `SumProductF64Agg[col_a, col_b]`
# (`builtin_agg_fns_sum_product.mojo`) from the hardcoded 2-column product to
# any `ExprXF64` aggregand. The expression `E` is built from the comptime-
# resolved leaves `ColAtXF64[idx]` + `LitXF64[v]` + the F64 arith binops
# (`MulXF64` / `AddXF64` / `SubXF64` / `DivXF64`), so the whole tree resolves
# at construction — `make()` is the trivial field-less default-construct (no
# runtime bind pass), exactly like `SumProductF64Agg`.
#
# WHY a comptime-index expr tree (not name-bind)
# -----------------------------------------------------------------------------
# The `Aggregator` trait surface has no `bind` hook; the column-grouped Stage
# materializes aggregators field-less via `Aggregator.make()`. The proven
# `SumProductF64Agg` precedent sidesteps this by baking its two column indices
# as comptime params (resolved at the marker's `BOUND[S] = ...[S.index_of(
# name)]` site). `SumOfExprF64Agg` extends that mechanism: the marker's
# `BOUND[S]` substitutes schema indices into the expr template's `ColAtXF64`
# leaves, producing a fully-comptime-resolved `E` the Stage drives with no
# bind. This keeps the generic kernel slotted into the EXISTING `BOUND[S]` ->
# field-less-`make()` column-agg dispatch with zero Stage-surface change.
#
# DType + op matrix coverage
# -----------------------------------------------------------------------------
# The aggregand is evaluated in Float64 (`E.eval_scalar_s`), so:
#   - op axis: + - * / (the four F64 binops) + scalar-folded `1 - x` etc.
#   - leaf axis: F64 column reads (ColAtXF64) + F64 literals (LitXF64).
#   - I64 / I32 / F32 column aggregands are served by widening at the leaf
#     (a CastX*ToF64 leaf, deferred follow-on) — the SUM accumulates in F64
#     uniformly, matching the column oracle for float-family computed aggs.
#
# Encapsulation invariants:
#   - NO UnsafePointer in any signature.
#   - NO wildcard origins — `bo: Origin[mut=False]` threads the batch lifetime.
#   - NO partial-move-via-take_pointee.
#   - POD `Float64` state (no heap; slab-safe in InlineArray[Float64, N]).
#   - `E` is a comptime TYPE param (zero-field for ColAtXF64/Lit/binop trees),
#     so `var expr: E` is a POD value — no heap, Movable + Copyable.
#
# Cross-references:
#   - builtin_agg_fns_sum_product.mojo — the fixed 2-column `a*b` precedent.
#   - expr_x_conformers.mojo — ColAtXF64 / LitXF64 / Mul/Add/Sub/DivXF64.
#   - aggregator.mojo — the unified `Aggregator` trait surface.
# =============================================================================

from komira_core.collections.batch_view import BatchView
from komira_eval.aggregator import Aggregator
from komira_eval.expr_x import ExprXF64


# =============================================================================
# SumOfExprF64Agg[E] — generic SUM(<F64 expression>) aggregator
# =============================================================================


struct SumOfExprF64Agg[E: ExprXF64](Aggregator):
    """`Aggregator` conformer summing the per-row value of an arbitrary
    Float64 expression `E`.

    Per-group state: `Float64` (the running sum). Output DType:
    `DType.float64`. The aggregand is evaluated via `self.expr.eval_scalar_s`
    — the same per-row evaluator the typed-filter / typed-projection paths
    use, so arithmetic (`*`, `-`, `+`, `/`) and scalar-folding (`1 - x`) are
    served by the existing `ExprXF64` conformer surface.

    `E` is expected to be a comptime-resolved tree (`ColAtXF64` leaves +
    `LitXF64` + F64 binops); its `bind` is the inherited no-op, so the stored
    `var expr: E` is fully resolved at construction. `make()` is therefore the
    trivial field-less default-construct (VARIADIC-FACTORY contract).
    """

    var expr: Self.E

    comptime StateTy = Float64
    comptime OUT_DT: DType = DType.float64

    def __init__(out self):
        self.expr = Self.E()

    @staticmethod
    @always_inline
    def make() -> Self:
        """`Aggregator.make` — field-less default-construct (VARIADIC-FACTORY).
        `E()` default-constructs the comptime-resolved expr tree (ColAtXF64 /
        Lit / binop leaves carry comptime params, so `E()` is trivial)."""
        return Self()

    @staticmethod
    @always_inline
    def init() -> Float64:
        return Float64(0.0)

    @always_inline
    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Float64, batch: BatchView[bo], i: Int):
        state = state + self.expr.eval_scalar_s[bo](batch, i)

    # NOTE: NO `update_chunk` override (matches SumProductF64Agg's documented
    # rationale): a masked-SIMD reduce_add over the chunk reassociates the
    # float64 sum vs the scalar per-row accumulate. The default per-lane
    # `@parameter for` body keeps the typed/untyped revenue values byte-
    # identical to the scalar oracle.

    @always_inline
    def combine(mut self, mut into: Float64, var partial: Float64):
        into = into + partial

    @staticmethod
    @always_inline
    def finalize(state: Float64) -> Scalar[DType.float64]:
        return state

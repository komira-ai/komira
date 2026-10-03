# =============================================================================
# predicate.mojo — the unified `Predicate` trait surface
# =============================================================================
#
# `Predicate` is one of three unified trait surfaces (with `RowTransform`
# and `Aggregator`) that bridge:
#   - the comptime SIMD-fused ExprX trees (`ExprXBool` etc.),
#   - the user-facing per-row UDF traits (`FilterFn`),
#   - the catalog primitives.
#
# It is the broad "row -> Bool" slot type the variadic Stage substrate
# (`Stage_FilterProject[Pred: Predicate, *Outs: RowTransform]`) is
# parameterized on. The expression tree keeps composing `ExprXBool`
# internally; `ExprXBool` refines `Predicate` via trait inheritance, so the
# Stage sees only the `Predicate` view while the composition machinery is
# unchanged.
#
# Pattern B — trait default-method body.
# -----------------------------------------------------------------------------
# A conformer MUST provide `eval_scalar` at minimum. `eval[W]` carries a
# canonical default body: a per-lane `comptime for` fan-out that direct-
# calls `self.eval_scalar` for each of the W lanes. This default body
# monomorphizes to ZERO `bl` (indirect branch) to any predicate method in the
# hot loop — the trait abstraction is fully erased; LLVM auto-fuses the
# per-lane compares into vector compares for cheap scalar bodies. Conformers
# override `eval[W]` ONLY when hand-SIMD provides a real algorithmic win
# (wide-vector contains, hash-fingerprint broadcast); trivial conformers ship
# `eval_scalar` only and pick up the default with no perf loss.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any method signature.
#   - NO wildcard origins — the `bo: Origin[mut=False]` per-batch lifetime
#     witness threads through every method so the compiler tracks the
#     BatchView's parent RecordBatch liveness end-to-end.
#
# Idioms:
#   - `SIMD[DType.bool, W](fill=False)` — bool SIMD splat takes `fill=`.
#   - `comptime for lane in range(W)` for the comptime per-lane fan-out.
#
# Cross-references:
#   - expr_x.mojo — `ExprXBool` (refines `Predicate`).
#   - filter_fn.mojo — `FilterFn` (refines `Predicate`).
# =============================================================================

from komira_core.collections.batch_view import BatchView
from komira_udf.purity import Purity


trait Predicate(Movable, Copyable, Deinitable):
    """Unified "row -> Bool" trait — bridges `ExprXBool` and `FilterFn`.

    Conformers MUST provide `eval_scalar` at minimum; `eval[W]` has a
    canonical Pattern B default body (per-lane `@parameter for` fan-out over
    `eval_scalar`) that the monomorphizer inlines into vector compares with
    zero perf loss on cheap predicates. Conformers
    override `eval[W]` only when hand-SIMD provides a real algorithmic win.

    The `PURITY` member is the optimizer pushdown / fold marker. It defaults to `STATELESS`; PURE predicates (no observable state)
    declare `comptime PURITY = Purity.PURE`.
    """

    comptime PURITY: Purity = Purity.STATELESS

    def eval_scalar[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) raises -> Bool:
        """REQUIRED — evaluate the predicate for the single row at logical
        index `i` of `batch`. Returns True iff the row is kept.

        `raises`: a `FilterFn` conformer satisfies this by delegating
        to its own `keep_row`, which may now fail. A non-raising conformer
        still conforms (non-variadic; FACT 1)."""
        ...

    def eval[
        W: Int, bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) raises -> SIMD[DType.bool, W]:
        """Batch SIMD half — DEFAULT BODY.

        `raises` is FORCED, not chosen: the default body below calls
        `eval_scalar`, which raises. An overriding conformer that also calls
        `eval_scalar` must declare `raises` for the same reason.

        Per-lane `@parameter for` fan-out over `eval_scalar`. The lane is
        only evaluated when `i + lane` is in-bounds; out-of-bounds lanes
        stay `False`. The monomorphizer inlines `eval_scalar` at each lane
        — zero `bl` to a predicate method in the hot loop.

        Conformers override this only when hand-SIMD provides an
        algorithmic win; trivial conformers rely on this default body.
        """
        var mask = SIMD[DType.bool, W](fill=False)
        var n = batch.n_rows()

        comptime for lane in range(W):
            if i + lane < n:
                mask[lane] = self.eval_scalar[bo](batch, i + lane)
        return mask

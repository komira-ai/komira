# =============================================================================
# aggregator.mojo — the unified `Aggregator` trait surface
# =============================================================================
#
# `Aggregator` is one of three unified trait surfaces (with `Predicate` and
# `RowTransform`) that bridge:
#   - the comptime per-bucket `HashAggOp*` family (`HashAggOpF64` etc.),
#   - the user-facing aggregate UDF trait (`AggFn`),
#   - the catalog primitives.
#
# It is the broad "N rows per group -> 1 value" slot type the variadic Stage
# substrate's aggregate pack (`Stage_GroupAgg[Pred, *Keys, *Aggs]`) is
# parameterized on. State storage is owned by the Stage's BreakerState; this
# trait describes per-group update + finalize + COMBINE for parallel
# partials.
#
# Why `combine` + `STATE_SIZE`.
# -----------------------------------------------------------------------------
# The existing `HashAggOpF64` family has `init` / `update_scalar` / `finalize`
# but no parallel-partial `combine` (the parallel merge was a separate
# accumulator-framework concern). The unified `Aggregator` surface makes
# `combine` a first-class trait method: the morsel-driven parallel-
# aggregation pipeline merges per-worker partial states cross-worker via
# `combine`. `STATE_SIZE` (a comptime `sizeof` of the state type) lets the
# Stage's BreakerState size its per-group state slab at comptime.
#
# Pattern B — trait default-method body.
# -----------------------------------------------------------------------------
# `update_chunk[W]` carries a Pattern B default body: a per-lane
# `@parameter for` fan-out over `update_scalar`, gated by the per-lane
# `valid` mask. The monomorphizer inlines `update_scalar` at each lane
# (zero `bl` to a predicate method). Conformers override `update_chunk`
# only when a scalar-state aggregate can reduce the masked SIMD vector in
# one step (`mask.select(values, init).reduce_add()`).
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any method signature.
#   - NO wildcard origins — `bo: Origin[mut=False]` threads the per-batch
#     lifetime witness.
#   - `StateTy` bound is `Movable & Copyable & Deinitable` — the
#     unified surface keeps the existing HashAggOp `StateTy` bound; the AggFn
#     `PodState` gate (no heap-owning fields) is a STRICTER per-conformer
#     contract that AggFn conformers continue to satisfy independently.
#
# Cross-references:
#   - agg_op_traits.mojo — `HashAggOpF64` etc. (bridged to `Aggregator` via
#     adapters).
#   - agg_fn.mojo — `AggFn` (refines `Aggregator`).
# =============================================================================

from std.sys import size_of
from std.collections import List
from std.os import abort

from komira_core.collections.batch_view import BatchView
from komira_core.collections.band_view import BandView
from komira_core.collections.morsel_view import MorselView
from komira_udf.purity import Purity


trait Aggregator(Movable, Copyable, Deinitable):
    """Unified "N rows per group -> 1 value" trait — bridges `HashAggOp*`
    and `AggFn`.

    State storage is owned by the Stage's BreakerState; this trait
    describes per-group `update` + `finalize` + parallel-partial `combine`.

    Members:
      - `PURITY`     : optimizer marker. Default `PURE` — a pure
                       aggregate over deterministic input is foldable.
      - `StateTy`    : the per-group running-state type. `Movable & Copyable
                       & Deinitable` (the existing HashAggOp
                       bound). AggFn conformers additionally satisfy the
                       stricter `PodState` no-heap gate.
      - `OUT_DT`     : the output column DType.
      - `STATE_SIZE` : `sizeof[StateTy]()` — lets the Stage's BreakerState
                       size its per-group state slab at comptime.
    """

    comptime PURITY: Purity = Purity.PURE
    comptime StateTy: AnyType & Movable & Copyable & Deinitable
    comptime OUT_DT: DType
    comptime STATE_SIZE: Int = size_of[Self.StateTy]()

    @staticmethod
    def init() -> Self.StateTy:
        """The identity / zero state for a fresh group."""
        ...

    @staticmethod
    def make() -> Self:
        """Field-less default-construct. Lets
        `AggSlot[A].make()` build a slot WITHOUT a caller-supplied `A` value, so
        the ONE variadic `VariadicAggFactory[KB, *AggTypes]` can materialize its
        `*AggTypes` value pack from the type pack in a `@parameter for` — collapsing the 7 per-arity `HashAggOpMultiMarkerFactory{2..8}`
        structs to ONE.

        The HashAggOp adapter family (`HashAggOpAgg`, `HashAggOp{F64,I64,I32,
        F32}Agg`, `SumProductF64Agg`) is field-less + no-arg-constructible
        (its `Op` / `col` are comptime params), so `make()` is `return Self()`.
        `AggFnAgg` (whose UDF `F` carries a per-worker capture that cannot be
        default-constructed) `constrained[False]`s this — UDF aggregates route
        through the untyped UDF segment path, never the field-less factory
        (mirrors `AggFnAgg.init()`'s `constrained[False]`)."""
        ...

    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Self.StateTy, batch: BatchView[bo], i: Int):
        """REQUIRED — fold the single row at logical index `i` into
        `state`."""
        ...

    def update_band[
        o: Origin[mut=False]
    ](mut self, mut state: Self.StateTy, band: BandView[o], row: Int):
        """The BAND sibling of `update_scalar`. Fold the aggregand at `row` read
        DIRECTLY from the band's reused per-column scratch span (NO RecordBatch,
        NO fresh Arrow column) into `state`. The read stays INSIDE the conformer
        (where the input col + DType are comptime-known), so it forwards the
        band-read value to the SAME value-level fold `update_scalar` uses — hence
        byte-identical to the batch path on identical data.

        DEFAULT = DECLINE (abort). Only `HashAggOpAgg[Op, col]` (q1's live typed
        grouped-agg conformer) overrides it with a real body over int64 / int32 /
        float64 aggregands; every other `Aggregator` conformer inherits this
        loud decline (the `_band_eligible` gate never routes them, so it
        is never reached — but a mis-routed off-shape aggregate faults loudly
        rather than silent-wrong). The general build widens the override set."""
        abort(
            "Aggregator.update_band: this aggregator does not support the"
            " band-view fold path; only"
            " HashAggOpAgg over int64/int32/float64 aggregands is band-eligible."
        )

    def update_chunk[
        W: Int, bo: Origin[mut=False]
    ](
        mut self,
        mut state: Self.StateTy,
        batch: BatchView[bo],
        i: Int,
        valid: SIMD[DType.bool, W],
    ):
        """Batch SIMD half — DEFAULT BODY.

        Per-lane `@parameter for` fan-out over `update_scalar`, gated by
        the per-lane `valid` mask AND the in-bounds check. The
        monomorphizer inlines `update_scalar` at each lane (zero `bl` to a
        predicate method). Conformers override this only when a
        scalar-state aggregate can reduce the masked SIMD vector in one
        step.
        """
        var n = batch.n_rows()

        comptime for lane in range(W):
            if i + lane < n and valid[lane]:
                self.update_scalar[bo](state, batch, i + lane)

    # -------------------------------------------------------------------------
    # ENGINE-V2 MorselView seam. The FORMAT-BLIND fold siblings of
    # `update_scalar` / `update_chunk`: read the aggregand through the generic
    # `V: MorselView` view TYPE (comptime-monomorphized) instead of a concrete
    # `BatchView`, so the SAME arithmetic folds a RecordBatch (V == BatchView)
    # and an arena-resident Chunk (V == ChunkView) -- the container feed. The
    # `BatchView` monomorph is byte-identical to `update_scalar` (same
    # `col_scalar_nonraising` value); the existing `update_scalar` /
    # `update_chunk` are UNTOUCHED (moat pristine). Mirrors the `update_band`
    # sibling's default-DECLINE pattern -- only the conformers a MorselView fold
    # routes (HashAggOp adapters) override `update_scalar_mv`; the rest inherit
    # the loud decline (never reached -- the seam gates them out).
    # -------------------------------------------------------------------------

    def update_scalar_mv[
        V: MorselView
    ](mut self, mut state: Self.StateTy, view: V, i: Int):
        """MorselView sibling of `update_scalar` -- fold the row at logical index
        `i`, read through the generic view `V`, into `state`. DEFAULT = DECLINE
        (abort): only the HashAggOp adapters (+ AggFn adapter) override it; every
        other conformer inherits this loud decline (the seam's eligibility gate
        never routes them). Byte-identical to `update_scalar` for V == BatchView
        (same `col_scalar_nonraising` value + same `Op.update_scalar` fold)."""
        abort(
            "Aggregator.update_scalar_mv: this aggregator does not support the"
            " MorselView container fold seam (ENGINE-V2); only the HashAggOp"
            " adapters over int64/int32/float64/float32 aggregands are eligible."
        )

    def update_chunk_mv[
        W: Int, V: MorselView
    ](
        mut self,
        mut state: Self.StateTy,
        view: V,
        i: Int,
        valid: SIMD[DType.bool, W],
    ):
        """MorselView sibling of `update_chunk` -- Pattern B DEFAULT: per-lane
        `@parameter for` fan-out over `update_scalar_mv`, gated by the per-lane
        `valid` mask AND the in-bounds check. Byte-identical to `update_chunk`
        for V == BatchView. No conformer overrides it today (the container path
        is per-lane scalar; the vectorized override lands with the fill kernels
        that need it)."""
        var n = view.n_rows()

        comptime for lane in range(W):
            if i + lane < n and valid[lane]:
                self.update_scalar_mv[V](state, view, i + lane)

    def combine(mut self, mut into: Self.StateTy, var partial: Self.StateTy):
        """REQUIRED — merge a partial `partial` state into `into`. The
        parallel-aggregation pipeline merges per-worker partials cross-
        worker via this method (the morsel-driven parallel-agg path).

        `partial` is taken by `var` (owned) — `combine` consumes the
        per-worker partial state into `into`. The natural name `from` is a
        reserved keyword in Mojo, hence `partial`.
        """
        ...

    @staticmethod
    def finalize(state: Self.StateTy) -> Scalar[Self.OUT_DT]:
        """Produce the group's output value from its final state."""
        ...

    # -- The EXACT INTEGER SUM hooks.
    comptime EXACT_INT_SUM: Bool = False
    """True iff this aggregator is an INTEGER `sum()` whose state is the EXACT
    128-bit total and whose `finalize` NARROWS it to the INT64 output column.
    A total outside INT64 has no value to emit, so the engine asks
    `total_fits_i64` for every group BEFORE `finalize` and REFUSES with
    `int_sum_overflow_message` (`AggSlot.refuse_unrepresentable`). Default False
    -- every other aggregator's emit is unchanged (the check is comptime-severed).
    ⛔ `finalize` itself stays NON-RAISING (a trait method every conformer and
    caller shares), so a caller that skips this check TRUNCATES: every
    `HashAggTable` drain calls it; `AggSlot.finalize_f64` (tests only) does
    not."""

    @staticmethod
    def total_fits_i64(state: Self.StateTy) -> Bool:
        """Consulted ONLY when `EXACT_INT_SUM`: does this group's exact total fit
        the INT64 output column? DEFAULT True (never called otherwise)."""
        _ = state
        return True

    # -- radix-parallel COUNT_DISTINCT hooks.
    comptime IS_DISTINCT: Bool = False
    """True iff this aggregator is an INTEGER-input COUNT_DISTINCT whose per-group
    state is a value BUFFER that can be radix-per-value-partition deduped in
    PARALLEL at drain time (the `emit_column_parallel` engine-layer path). Default
    False — every non-CD op inherits the serial `emit_column`/`finalize` with ZERO
    change. Set True ONLY on the integer-input CountDistinct adapter. MEDIAN's
    value buffer is DELIBERATELY NOT set (its finalize is a global-order percentile
    select — a per-value-partition union would break the median; see MedianOp)."""

    def distinct_values(self, state: Self.StateTy) -> List[Int64]:
        """The group's raw fed values, widened to Int64, for the ENGINE-LAYER
        radix-parallel COUNT_DISTINCT dedup (consulted ONLY when `IS_DISTINCT`).
        The eval layer stays dispatcher-free — it just exposes the value buffer;
        the parallel dedup + `run_with_state` live in `AggSlot.emit_column_parallel`
        (engine_operators). DEFAULT returns an EMPTY list (never called for a
        non-distinct op). The integer CountDistinct adapter overrides it."""
        _ = state
        return List[Int64]()

    # -- concat-free move-combine hooks.
    def take_distinct_into(self, mut dst: Self.StateTy, mut src: Self.StateTy):
        """MOVE `src`'s per-group distinct value buffer(s) into `dst`'s per-group
        run accumulator — the CONCAT-FREE cross-worker merge (consulted ONLY when
        `IS_DISTINCT`, via `AggColumn.combine_at_move`). O(1) per buffer (a `List`
        move) instead of the O(values) serial `combine` concat. The eval layer
        stays dispatcher-free. DEFAULT = no-op (never called for a non-distinct op
        — `combine_at_move` comptime-severs this branch). The integer CountDistinct
        adapter overrides it."""
        _ = dst
        _ = src

    def distinct_runs(self, state: Self.StateTy) -> List[List[Int64]]:
        """The group's distinct value buffer(s) widened to Int64 as a LIST of runs
        (per-row buffer plus every move-combined worker buffer), for the ENGINE-
        LAYER radix-parallel MULTI-BUFFER dedup (consulted ONLY when `IS_DISTINCT`).
        NO flatten/concat — the engine scatters all runs together. DEFAULT returns
        an EMPTY list. The integer CountDistinct adapter overrides it."""
        _ = state
        return List[List[Int64]]()

    # -- parallel PER-GROUP finalize.
    comptime PARALLEL_SORT_FINALIZE: Bool = False
    """True iff this aggregator's per-group `finalize` is an EXPENSIVE independent
    per-group computation (a full sort + interpolated percentile select — MEDIAN)
    whose drain the engine layer parallelizes by PARTITIONING GROUPS across workers
    (each group's buffer sorts + interpolates ALONE at finalize, so the groups are
    independent → the parallel drain is BYTE-IDENTICAL to the serial one, just
    partitioned by group). Default False — every cheap-finalize op (SUM/COUNT/AVG/
    MIN/MAX/STDDEV) inherits the serial `emit_column` per-group loop with ZERO
    change. Set True ONLY on the MEDIAN adapter, whose serial per-group sort is the
    ~84% post-collect wall of an exact grouped-median query (h6). UNLIKE
    `IS_DISTINCT` (which parallelizes WITHIN a group by value-hash partition), this
    parallelizes ACROSS groups — no cross-group interaction, so the result is
    order-for-order identical to the serial drain. The engine-layer `run_with_state`
    fan-out lives in `AggSlot.emit_column_parallel` (engine_operators); the eval
    layer stays dispatcher-free (it just carries the flag + the exact `finalize`)."""

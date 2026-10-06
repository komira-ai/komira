# =============================================================================
# agg_fn_acc.mojo — AggFnAcc[F: AggFn], the Accumulator adapter for a typed UDF agg
# =============================================================================
#
# UDF-DESIGN Deliverable 3, Phase 1.c (design doc rev 6 =,
# §1.4, §4.3, §7.3). `AggFnAcc[F: AggFn]` *implements* the engine's
# `Accumulator` trait by wrapping the user's typed `AggFn` — same pattern as
# `UdfOp[T: ScalarUdf]` wrapping `ScalarUdf` into a `MorselOperatorImpl`. The
# adapter owns the gid-keyed per-group `F.State` bookkeeping and routes typed
# `F.InRow` values into `F.update`; the user's `F` only ever sees typed rows.
#
# Bookkeeping: `List[F.State]` keyed by dense gid (spike Probe 3b proved
# `List[F.State]` GREEN — `ref slot = states[gid]; self._udf.update(slot, row)`
# compiles + is correct). `init()` on first touch of a gid (via
# `ensure_capacity`'s monotonic grow — same invariant as the engine's own
# `SumI64Acc`/etc.), `update(ref slot, row)` per row, `merge(a, b)` for the
# parallel partial-merge (`merge_aligned`), `finalize(s) -> Scalar[F.OutType]`
# at emit. `F.State` conforms to `PodState` (Copyable + Movable +
# Deinitable — the gap6 gate; the trait elaboration rejects a
# `State` with a heap-owning field) — so `flush_partial_to_column`'s
# Arrow-columnar dump is sound by construction.
#
# ---------------------------------------------------------------------------
# THE MULTI-INPUT-COLUMN GAP (design note for P1.d — see closure memo)
# ---------------------------------------------------------------------------
# The `Accumulator` trait's `update_batch(gids, col_data, col_offset,
# n)` passes exactly ONE column span — it was designed for the engine's
# single-column SUM/COUNT/MIN/MAX accumulators. A multi-input UDF agg (e.g.
# `weighted_avg(value, weight)` reads two columns) cannot be driven through
# that single-column entrypoint. So `AggFnAcc[F]` conforms to `Accumulator`
# (so it can slot into the accumulator_set for the 1-input case + share the
# ensure_capacity / finalize / flush / num_groups lifecycle), AND provides a
# typed N-column entrypoint `update_record_batch(mut self, gids, batch)` that
# resolves the `F.InputSchema` columns by name and loops `F.update`. This is
# NOT an `Accumulator` trait change — it's an additive typed method on the
# adapter. P1.d's accumulator_set wiring will call `update_record_batch` for a
# multi-input UDF agg (a real-but-bounded change to the agg-compile path —
# flagged in the P1.c closure memo for the maintainer's review of the P1.d dispatch).
# The trait-conforming `update_batch` here handles the 1-input case (extract
# the single column, loop `F.update_scalar(slot, v)`); a >1-input UDF agg
# routed through it raises a clear error.
#
# Mojo gotchas: `F.merge`/`F.finalize` are NON-pack methods (`self` is fine —
# the het-pack-`mut self` rule from P1.a applies only to het-pack methods);
# `F.update_scalar[*Ts]` IS a het-pack method but takes `self` (the conformer
# may declare `self` against a `self` trait requirement — the het-pack rule is
# about NOT widening to a `self`-conformer-of-a-`mut self`-requirement; here
# both are `self`); the adapter routes through `F.update_scalar` (positional
# het-pack) NOT `F.update(s, F.InRow(...))` — `F.InRow` is only `Copyable &
# Movable`-bound, which exposes NO fieldwise constructor (`F.InRow(v0, v1)` →
# `error: no matching function ... missing keyword-only argument 'copy'/'take'`),
# so the engine cannot construct the opaque `InRow` generically — exactly the
# reason `MapFn`/`FilterFn` have `run_scalar`/`keep_scalar`; `AggFn` grew
# `update_scalar` (P1.a amendment — see the closure memo); comptime-bound
# schema struct reads via parametric helpers; the per-arity body references
# `cols[3]` only inside a `comptime if N_IN == 4` arm.
# =============================================================================

from std.memory import UnsafePointer

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_op_agg_state.accumulator_trait import Accumulator
from komira_buffer.heap_region import HeapRegion
from komira_udf.agg_fn import AggFn
from komira_agg.pod_state_gate import assert_pod_state
from komira_kernels.simd_of import SimdOf
from komira_op_agg_state.agg_fn_fused_kernel import (
    _AggFnFusedKernel,
)
from komira_udf.schema_descriptor import (
    dtag_to_dtype,
    dtag_to_arrow_type_id,
    dtag_name,
)


# --- comptime schema-reflection helpers (P1.a gotcha #3 — `cols[i].name` is a
#     `String` inside a non-`ImplicitlyCopyable` struct; the dtag is a plain
#     `Int` so it can be read directly in a `comptime` binding) ---

def _in_name[F: AggFn, i: Int]() -> String:
    return comptime(F.InputSchema.cols[i].name)


# =============================================================================
# UDF-PHASE-B3-7-PREREQ — _AggFnFusedKernel typed-bridge fns
# =============================================================================
#
# RFC §6.4 prerequisite primitive. Two parametric free functions
# (`_invoke_update_chunk[G: _AggFnFusedKernel, W]` + `_invoke_finalize_simd[G:
# _AggFnFusedKernel]`) form the typed bridge from `AggFnAcc[F]`'s parent-trait-
# typed state slot (`F.State`) to the sub-trait-typed SimdOf hot path
# (`F.STATE`).
#
# THE WIDENING ISSUE (historical; the user-facing SIMD opt-in
# sub-trait was deleted by WAVE-11-UDF-F. The widening
# pattern recurs against any sub-trait — the same shape applies to
# `_AggFnFusedKernel` if/when the engine driver routes through the
# `comptime if conforms_to(F, _AggFnFusedKernel)` branch for the
# SIMD-typed hot path):
#
#   Mojo limitation: a `comptime if` body widens `F` to
#   include the sub-trait, but `F.State` does NOT widen in lockstep
#   — call sites on `self._udf.update_scalar` see a type mismatch
#   ("l-value of type 'F.State' cannot be converted to reference of
#   type 'F(... & <sub-trait>).State'"). The parametric-bridge fn
#   workaround used elsewhere (e.g. UDF-A's bridge over filter
#   conformers) doesn't help here because `F.State` is a comptime-
#   bound associated type that the bridge would also need to thread.
#
# RESOLUTION: the bridge fn takes `G: _AggFnFusedKernel` (NOT `G: AggFn`),
# which means inside the bridge body `G.STATE` is in scope as the
# sub-trait's state type. The caller calls `_invoke_update_chunk[F, W]`
# from a site where `comptime if conforms_to(F, _AggFnFusedKernel)` has
# established `F: _AggFnFusedKernel` — Mojo binds `G = F` at that comptime
# site. The bridge then calls `G.update_chunk[W](state, input)` against
# the typed `G.STATE` view.
#
# The `rebind[G.STATE]` at the bridge entry is the load-bearing piece.
# It works because of the conformer's contract: a conformer that
# implements BOTH `AggFn` AND `_AggFnFusedKernel` MUST declare
# `comptime State = X` AND `comptime STATE = X` for the SAME `X`
# (see `tests/test_udf_simd_traits.mojo:Sum` fixture lines 156, 162
# for the canonical example: `comptime State = SumState` and
# `comptime STATE = SumState`). The rebind is a comptime size-equality
# check; for properly-conforming `F` (State == STATE) it is zero-cost.
# If a misbehaving conformer declares `State != STATE`, the rebind
# raises a comptime error.
#
# SAFETY: see the `# SAFETY:` block on `_invoke_update_chunk` below.
#
# Bridge usage pattern (for documentation; live wiring is the v0.5
# slot's job — this primitive is the leaf-helper):
#
#   def update_chunk_typed(mut self, gid: Int, input_chunk: SimdOf[Self.F.T_IN, W]) raises:
#       comptime if conforms_to(Self.F, _AggFnFusedKernel):
#           ref slot = self._states[gid]
#           _invoke_update_chunk[Self.F, W](slot, input_chunk)
#       else:
#           # Per-lane scalar fallback via update_scalar.
#           ...


@always_inline
def _invoke_update_chunk[
    G: _AggFnFusedKernel, W: Int
](
    mut state: G.STATE,
    input: SimdOf[G.T_IN, W],
):
    """Typed-bridge for `_AggFnFusedKernel.update_chunk[W]`.

    Folds a `SimdOf[G.T_IN, W]` chunk into the running state in-place,
    invoking the comptime-`G`-monomorphized `G.update_chunk[W]` body.

    The state is passed by `mut` ref `state: G.STATE` (the sub-trait
    STATE alias for the underlying state type). The caller is
    responsible for the `G.State -> G.STATE` rebind at the call site
    via `_simd_state_ref[G]` (the companion helper below); this
    bridge body just dispatches the typed update.

    See `_simd_state_ref` for the rebind plumbing and the SAFETY block
    documenting the State == STATE conformer contract.
    """
    G.update_chunk[W](state, input)


@always_inline
def _invoke_finalize_simd[G: _AggFnFusedKernel](var state: G.STATE) -> G.T_OUT:
    """Typed-bridge for `_AggFnFusedKernel.finalize`.

    Produces the typed output row from a finalized state. Mirrors
    the `_invoke_update_chunk` widening pattern: takes `G.STATE`
    (the sub-trait alias); the caller is responsible for the
    `G.State -> G.STATE` rebind at the call site. Takes
    `var state` (consuming move) since `G.finalize` takes
    `Self.STATE` by value.
    """
    return G.finalize(state^)


# NOTE on the State -> STATE rebind helper:
#
# Originally this slot's design called for two helpers
# `_rebind_state_to_simd[G: _AggFnFusedKernel]` / `_rebind_state_from_simd[G:
# _AggFnFusedKernel]` that would let `AggFnAcc[F]` (typed on parent trait
# `AggFn`) bridge into `_AggFnFusedKernel.update_chunk[W]` via
# `rebind[G.STATE](parent_state)`. The actual Mojo behavior:
# `rebind[T]` requires the source type to be `ImplicitlyCopyable`, but
# `G.State: PodState` is `(Copyable, Movable, Deinitable)`
# WITHOUT the `ImplicitlyCopyable` super-trait. The rebind body fails
# to parse:
#
#   error: value of type 'G.State' cannot be implicitly copied, it
#   does not conform to 'ImplicitlyCopyable'
#
# Adding `var parent_state: G.State` + `parent_state^` does NOT help --
# `rebind` reads the value, it does not move it. This is the SAME
# limitation `_update_arity1`'s file-internal comment documents from a
# different angle: a `comptime if conforms_to(F, <sub-trait>)` body
# widens F but does not widen F.State; a parametric bridge would have
# to thread BOTH `G: _AggFnFusedKernel` AND a size-equality-asserted
# G.STATE bridge somehow that the type system rejects today.
#
# RESOLUTION (v0.5 or future Mojo release): one of
#   - The conformer model adds an `IdentityRebind[T]` capability
#     marker on PodState (a no-cost identity rebind that doesn't
#     require ImplicitlyCopyable).
#   - Mojo adds `rebind_move[T]` that consumes the source by `^`.
#   - The _AggFnFusedKernel trait drops `State` from `AggFn` and inherits
#     `STATE` as the sub-trait's canonical state type (with a
#     compat shim for legacy callers).
#
# What ships in this slot: the `_invoke_update_chunk[G: _AggFnFusedKernel, W]`
# and `_invoke_finalize_simd[G: _AggFnFusedKernel]` bridges that operate
# directly on `G.STATE`. The State <-> STATE rebind plumbing is
# DEFERRED to the v0.5 slot. The bridges remain useful for any
# caller that ALREADY has a `G.STATE` view (e.g. a future engine
# dispatch path that stores `AggFnAcc[F]._states: List[F.STATE]`
# directly when F conforms to _AggFnFusedKernel).


# =============================================================================
# AggFnAcc[F: AggFn]
# =============================================================================

struct AggFnAcc[F: AggFn](Accumulator):
    """The `Accumulator` adapter for a typed UDF aggregate (`AggFn`).

    Fields
    ------
    _udf: The user's `F` instance (per-worker copy — the accumulator
        lifecycle; the cold-path `merge_aligned` combines per-worker slabs).
    _states: `List[F.State]` keyed by dense gid (the per-group running state).
        Monotonic-grow via `ensure_capacity` (same invariant as `SumI64Acc`).
    """

    var _udf: Self.F
    var _states: List[Self.F.State]

    def __init__(out self, var udf: Self.F):
        """Construct an `AggFnAcc` wrapping the given `F` instance.

        Args:
            udf: The user's `F` instance. Ownership is transferred.
        """
        # THE gap6 gate forcing site (). `AggFnAcc[F].__init__`
        # is monomorphized per-conformer `F`, so this `assert_pod_state` fires
        # the per-field `constrained[]` checks for THIS `F.State` — an `F`
        # whose `State` carries a heap-owning field (String/List/...) FAILS TO
        # COMPILE here (PodState is a no-op marker trait; this is the real
        # gate). Pure comptime, zero runtime cost. Mirrors how `simd_of.mojo`'s
        # typed accessors force `comptime_field_validation` per-`F`.
        assert_pod_state[Self.F.State]()
        self._udf = udf^
        self._states = List[Self.F.State]()

    # __moveinit__ / __del__ auto-synthesized (F is Movable; F.State is
    # Movable + Deinitable; List[F.State] is Movable).

    # -------------------------------------------------------------------------
    # Accumulator lifecycle.
    # -------------------------------------------------------------------------
    def ensure_capacity(mut self, n_groups: Int) raises:
        # Monotonic grow — caller MUST ensure n_groups >= current len. New
        # slots are seeded with F.init() (the identity element).
        while len(self._states) < n_groups:
            self._states.append(self._udf.init())

    def num_groups(self) -> Int:
        return len(self._states)

    def finalize_to_column(mut self) raises -> Column[HeapRegion]:
        comptime out_dt = Self.F.OutType
        var n = len(self._states)
        var arr = PrimitiveArray[out_dt].allocate(n)
        for g in range(n):
            var v = self._udf.finalize(self._states[g])
            arr.set(g, rebind[Scalar[out_dt]](v))
        return Column.from_primitive[out_dt](arr^)

    def flush_partial_to_column(mut self) raises -> Column[HeapRegion]:
        # For an AggFn the partial flush == finalize (no pending computation
        # beyond the running State; F.State conforms to PodState so the raw
        # slab is Arrow-dumpable, but we route through finalize for v0.4 —
        # the partition-flush re-merge path is a P3/P4 concern).
        return self.finalize_to_column()

    # The aligned-gid full-column merge for the combine fast path. Called
    # directly by the cold-path thunk (`merge` is not on the Accumulator trait
    # — Mojo forbids `Self`-typed trait params — so the plan compiler
    # monomorphizes `_thunk_merge[AggFnAcc[F]]` calling this). Contract: the
    # caller guarantees `self.num_groups() == src.num_groups()` and gid i in
    # `self` is the same logical group as gid i in `src` (the same-schema
    # cross-worker S3 case).
    def merge_aligned(mut self, imm src: Self) raises:
        var n = len(src._states)
        if len(self._states) != n:
            raise Error(
                String("AggFnAcc.merge_aligned: length mismatch (self=")
                + String(len(self._states)) + ", src=" + String(n) + ")"
            )
        for g in range(n):
            var merged = self._udf.merge(self._states[g], src._states[g])
            self._states[g] = merged^

    # -------------------------------------------------------------------------
    # update_batch — the Accumulator trait's single-column hot-path entrypoint.
    # Handles the 1-input-column UDF agg only; a >1-input agg raises (use
    # update_record_batch). See the file header's "multi-input-column gap" note.
    # -------------------------------------------------------------------------
    def update_batch[og: Origin, oc: Origin](
        mut self,
        gids: Span[Int, og],
        col_data: Span[UInt8, oc],
        col_offset: Int,
        n: Int,
    ) raises:
        # SAFETY: the pointers are formed from the borrowed spans and live only for
        # this call; the untracked origin and the nominal mutable cast keep the body's
        # pointer type unchanged (the kernels only read both buffers).
        var gids_ptr = (
            gids.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        var col_data_ptr = (
            col_data.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        comptime N_IN = Self.F.InputSchema.num_cols()
        comptime if N_IN != 1:
            comptime assert False, ( "AggFnAcc.update_batch: this single-column entrypoint supports" " a 1-input UDF agg only; a multi-input agg must be driven via" " update_record_batch (P1.d wires the accumulator_set call)" )
        else:
            comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
            # SAFETY: col_data_ptr + col_offset points into the caller's Arrow
            # column buffer (the Accumulator contract — the caller keeps the
            # backing RecordBatch alive for the call's duration; we do not
            # stash the pointer). `n` valid `Scalar[dt0]` elements follow.
            var data_ptr = col_data_ptr.bitcast[Scalar[dt0]]()
            for i in range(n):
                var g = gids_ptr[i]
                if g >= len(self._states):
                    raise Error("AggFnAcc.update_batch: gid out of range —"
                                " caller must ensure_capacity first")
                var v0 = (data_ptr + col_offset + i)[]
                ref slot = self._states[g]
                self._udf.update_scalar(slot, v0)

    # -------------------------------------------------------------------------
    # update_record_batch — the typed N-column entrypoint (1..4 input columns).
    # Resolves the `F.InputSchema` columns by name against `batch`, asserts the
    # Arrow type codes, loops `F.update_scalar(slot, v0, …)` keyed by gid.
    # P1.d's accumulator_set wiring calls this for a multi-input UDF agg.
    # -------------------------------------------------------------------------
    def update_record_batch(
        mut self, gids: List[Int], batch: RecordBatch
    ) raises:
        var n = len(gids)
        if n == 0:
            return
        if batch.num_rows() < n:
            raise Error(
                String("AggFnAcc.update_record_batch: gids has ") + String(n)
                + " entries but the batch has only " + String(batch.num_rows())
                + " rows"
            )
        comptime N_IN = Self.F.InputSchema.num_cols()
        comptime if N_IN == 1:
            self._update_arity1(gids, batch, n)
        elif N_IN == 2:
            self._update_arity2(gids, batch, n)
        elif N_IN == 3:
            self._update_arity3(gids, batch, n)
        elif N_IN == 4:
            self._update_arity4(gids, batch, n)
        else:
            comptime assert False, ( "AggFnAcc.update_record_batch: this adapter supports 1..4 input" " columns (5..8 is a mechanical extension of the comptime fan)" )

    def _resolve[i: Int](self, batch: RecordBatch) raises -> Int:
        var want_name = _in_name[Self.F, i]()
        comptime want_tag = Self.F.InputSchema.cols[i].dtype
        var idx = batch.column_by_name(want_name)
        var want_tid = dtag_to_arrow_type_id(want_tag)
        var got_tid = batch.column_arrow_type(idx).type_id
        if got_tid != want_tid:
            raise Error(
                String("AggFnAcc: input column '") + want_name
                + "' has Arrow type code " + String(Int(got_tid))
                + " but the UDF declared dtype " + dtag_name(want_tag)
                + " (code " + String(Int(want_tid)) + ")"
            )
        return idx

    @always_inline
    def _check_gid(self, g: Int) raises:
        if g < 0 or g >= len(self._states):
            raise Error("AggFnAcc.update_record_batch: gid out of range —"
                        " caller must ensure_capacity first")

    def _update_arity1(
        mut self, gids: List[Int], batch: RecordBatch, n: Int
    ) raises:
        comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
        var c0 = batch.column_at(self._resolve[0](batch)).as_primitive[dt0]()
        # WAVE-11-UDF-E M3: dropped the vestigial
        # vectorized-conformance probe — the probe was informational only
        # (`_ = has_vec`) and the body was always the scalar path. The
        # (now-deleted, per WAVE-11-UDF-F) user-facing SIMD
        # sub-trait contract required `update_chunk[W=1]` to produce
        # lane-for-lane identical results to `update_scalar`, so the
        # scalar path IS the byte-identical reference even when the
        # vectorized branch fires. Same precedent UDF-A applied to
        # `filter_fn_op._build_mask` (commit ``) and UDF-E M2
        # applied to `MapFnOp._compute_output` (commit ``).
        #
        # v0.4 P2 (deferred): the SimdOf-typed hot path lands via
        # `comptime if conforms_to(Self.F, _AggFnFusedKernel)` (the engine-internal
        # fused-kernel signal), routed through the `_invoke_update_chunk[G:
        # _AggFnFusedKernel, W]` typed-bridge fn declared earlier in this file
        # (lines 137-158). The State -> STATE rebind plumbing
        # (`_rebind_state_to_simd` and friends) is the gating item for
        # that path; see the v0.5 slot for the typed-bridge design.
        for i in range(n):
            var g = gids[i]
            self._check_gid(g)
            if c0.is_null(i):
                continue   # PROPAGATE: a NULL input row contributes nothing
            ref slot = self._states[g]
            self._udf.update_scalar(slot, c0.get(i))

    def _update_arity2(
        mut self, gids: List[Int], batch: RecordBatch, n: Int
    ) raises:
        comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
        comptime dt1 = dtag_to_dtype(Self.F.InputSchema.cols[1].dtype)
        var c0 = batch.column_at(self._resolve[0](batch)).as_primitive[dt0]()
        var c1 = batch.column_at(self._resolve[1](batch)).as_primitive[dt1]()
        for i in range(n):
            var g = gids[i]
            self._check_gid(g)
            if c0.is_null(i) or c1.is_null(i):
                continue
            ref slot = self._states[g]
            self._udf.update_scalar(slot, c0.get(i), c1.get(i))

    def _update_arity3(
        mut self, gids: List[Int], batch: RecordBatch, n: Int
    ) raises:
        comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
        comptime dt1 = dtag_to_dtype(Self.F.InputSchema.cols[1].dtype)
        comptime dt2 = dtag_to_dtype(Self.F.InputSchema.cols[2].dtype)
        var c0 = batch.column_at(self._resolve[0](batch)).as_primitive[dt0]()
        var c1 = batch.column_at(self._resolve[1](batch)).as_primitive[dt1]()
        var c2 = batch.column_at(self._resolve[2](batch)).as_primitive[dt2]()
        for i in range(n):
            var g = gids[i]
            self._check_gid(g)
            if c0.is_null(i) or c1.is_null(i) or c2.is_null(i):
                continue
            ref slot = self._states[g]
            self._udf.update_scalar(slot, c0.get(i), c1.get(i), c2.get(i))

    def _update_arity4(
        mut self, gids: List[Int], batch: RecordBatch, n: Int
    ) raises:
        comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
        comptime dt1 = dtag_to_dtype(Self.F.InputSchema.cols[1].dtype)
        comptime dt2 = dtag_to_dtype(Self.F.InputSchema.cols[2].dtype)
        comptime dt3 = dtag_to_dtype(Self.F.InputSchema.cols[3].dtype)
        var c0 = batch.column_at(self._resolve[0](batch)).as_primitive[dt0]()
        var c1 = batch.column_at(self._resolve[1](batch)).as_primitive[dt1]()
        var c2 = batch.column_at(self._resolve[2](batch)).as_primitive[dt2]()
        var c3 = batch.column_at(self._resolve[3](batch)).as_primitive[dt3]()
        for i in range(n):
            var g = gids[i]
            self._check_gid(g)
            if c0.is_null(i) or c1.is_null(i) or c2.is_null(i) or c3.is_null(i):
                continue
            ref slot = self._states[g]
            self._udf.update_scalar(
                slot, c0.get(i), c1.get(i), c2.get(i), c3.get(i)
            )

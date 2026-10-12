# =============================================================================
# breaker_state_trait.mojo — the BreakerState trait + NoState (leaf module)
# =============================================================================
#
# UNIFIED-STAGE `U-D.1` deliverable (the FOUNDATION of `U-D`) per
# an internal doc §1.1 / §1.1a / §1.3 and the
# `U-A.1` spike closure
# (an internal agent note).
#
# # Why this is a SEPARATE leaf module (not folded into breaker_state.mojo)
#
# The `BreakerState` trait is the bound for `Stage`'s 4th parameter `BState`,
# and the real in-tree variadic tables (`HashAggTable`, `SortBuffer`,
# `JoinBuildTable`) conform to it directly (the additive `state_tag()` method in
# each table's own module — faithful to the `U-A.1` Q2c spike, where
# `HashAggTableStub` etc. conformed to `BreakerState` directly, not via a
# wrapper). The arity-bridge (`breaker_state.mojo`) imports BOTH the trait AND
# the concrete table types. If the trait lived next to the bridge, the tables'
# `import` of the trait + the bridge's `import` of the tables would form a
# cycle. Splitting the trait into THIS leaf module — which imports only the
# `BREAKER_*` discriminator constants from `stage_program.mojo` — breaks the
# cycle: tables -> breaker_state_trait (leaf); breaker_state (bridge) -> tables
# + breaker_state_trait. No cycle.
#
# # Encapsulation invariants (the internal development notes hard bans)
#   - NO UnsafePointer / wildcard origins / unsafe_from_address / partial-move /
#     ArcPointer. Trait + POD only.
# =============================================================================

from std.collections import Optional

from komira_arrow.schema import RecordBatch
from komira_arrow.batch_view import BatchView
from komira_arrow.band_view import BandView
from komira_arrow.morsel_view import MorselView

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_expr.stage_program import BREAKER_NONE
from komira_operator_api.emit_at_offset_target import (
    _EmitColDesc,
    _EmitColTarget,
)
from komira_udf.column_resolver import ColumnResolver


# =============================================================================
# §1 — The BreakerState trait
# =============================================================================
#
# Trait bound `(Movable, Deinitable)` — NOT `(Copyable,
# ImplicitlyCopyable)`. The real variadic tables are ALL `Movable`-only (their
# `Tuple[*pack]` fields are not `Copyable`). The breaker state is OWNED and
# MOVED by the `Stage`, never copied. `Deinitable` lets the `Stage`
# synthesize its destructor over `var state: Self.BState` (the state types own
# heap resources — `List` / `OwnedPointer`).
#
# # The executable surface — `feed_row` + `drain_to_record_batch` (U-D.2)
#
# The marker-trait-vs-executable-trait bridge (design-review Issue 1; §1.1a)
# resolves for the BREAKER slot via OPTION (A): the `BreakerState` trait carries
# the breaker's executable feed/drain surface directly, so the generic `Stage`
# body can call `self.state.feed_row[bo](batch, row)` /
# `self.state.drain_to_record_batch()` UNIFORMLY across all 6 arms — without ever
# naming a concrete table type (the abstract `Self.BState: BreakerState` bound is
# all the generic `Stage` body sees; free functions over a concrete
# `HashAggTable[KB, *Aggs]` are unreachable from there because `BState` is opaque
# at the `Stage` definition). Each conformer's `feed_row` / `drain` body does its
# OWN per-arity comptime dispatch internally (where `self` IS concrete). U-D.2
# fills `HashAggTable`'s bodies; `SortBuffer` / `JoinBuildTable` / `NoState` get
# the conformance with U-D.3/U-D.4-deferred bodies (raise / no-op) until their
# `Stage` arms land.
# =============================================================================


trait BreakerState(Movable, Deinitable):
    """Common bound for `Stage`'s explicit 4th parameter `BState`.

    `state_tag()` is the comptime discriminator that lets `Stage.__init__`
    assert `Self.Breaker.tag() == Self.BState.state_tag()` — so a caller (the
    lowerer / `materialize_typed`) cannot pass a mismatched `(Breaker, BState)`
    pair (`U-A.1` Q2c consistency-guard scheme). The tag values mirror
    `stage_program.mojo`'s `BREAKER_*` constants exactly.

    `feed_row` / `drain_to_record_batch` are the breaker EXECUTABLE surface
    (U-D.2, option A) — the generic `Stage` body calls them uniformly; each
    conformer implements its own per-shape body.
    """

    @staticmethod
    def state_tag() -> Int:
        """The breaker-kind discriminator this state type belongs to.

        Returns one of `BREAKER_NONE` / `BREAKER_HASH_AGG` / `BREAKER_SORT` /
        `BREAKER_TOPN` / `BREAKER_WINDOW` / `BREAKER_JOIN_PROBE`.
        """
        ...

    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        """Accumulate one input row at logical index `row` into the breaker
        state. The breaker-accumulation hot path: HashAgg folds the row into
        its group bucket; Sort/TopN buffer the row; JoinProbe probes. Called
        by the generic `Stage` HASH_AGG/SORT/... arm per row. Origin-parametric
        `bo` threads the per-batch borrow witness (no wildcard)."""
        ...

    def feed_survivors[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], survivors: List[Int]
    ) raises:
        """BULK per-consume accumulate (P-PL.3 Part 1). Buffer the WHOLE survivor
        set for THIS incoming batch chunk in one call, instead of one `feed_row`
        per survivor.

        DEFAULT BODY: loop `feed_row` over `survivors` (correct for any
        accumulate breaker — byte-identical to the per-row drive). Only
        `PartitionUdfState` overrides this with a single bulk `gather_batch` per
        consume (its survivor buffering is allocation-heavy at per-row
        granularity: one 1-row gather + RecordBatch per surviving row). The
        generic `Stage` calls it ONLY under `comptime if Self.Breaker.tag() ==
        BREAKER_PARTITION_UDF`, so every other conformer inherits this default
        and is unaffected."""
        for si in range(len(survivors)):
            self.feed_row[bo](batch, survivors[si])

    def feed_chunk_global[
        W: Int, bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int, valid: SIMD[DType.bool, W]) raises:
        """0-KEY-FUSED vectorized accumulate. Fold a W-wide masked
        chunk at logical index `i` into the breaker's SINGLE implicit group —
        the zero-key (whole-table / scalar) aggregate hot path.

        DEFAULT BODY: raise. Only `HashAggTable` (the HASH_AGG arm's state)
        overrides this with the real masked-SIMD multiply-accumulate; the
        generic `Stage` calls it ONLY under `comptime if Self.Breaker.tag() ==
        BREAKER_HASH_AGG and Self.Breaker.n_keys_static() == 0`, so the
        `comptime if` dead-arm-elides the call on every other conformer and this
        default is never reached. A raising default keeps a mis-wiring loud
        (mirrors `probe_batch` / `probe_asof_batch`) WITHOUT forcing all 9
        non-HashAgg conformers to carry a hand-written stub."""
        raise Error(
            "BreakerState.feed_chunk_global: not a 0-key HASH_AGG state"
            " (only HashAggTable overrides this — 0-KEY-FUSED fast-path)"
        )

    def feed_batch_contiguous[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], n: Int
    ) raises:
        """TOP-N SIMD reject-path batch feed (INLINE-AUDIT-TOPN-WIN).
        Feed the CONTIGUOUS row range `[0, n)` (the NoFilter survivor set) through
        the breaker with a vectorized reject scan: load W contiguous candidate
        keys per chunk + one W-wide compare vs the broadcast heap root, skipping
        all-loser chunks with zero per-row work (the typed path's comptime-known
        DType edge over the untyped scalar Int64-direct heap).

        DEFAULT BODY: feed each row scalar via `feed_row` (correct for any
        accumulate breaker). Only `TopNFullFrameState` overrides this with the
        real SIMD reject scan; the generic `Stage` calls it ONLY under
        `comptime if Self.Breaker.tag() == BREAKER_TOPN and NoFilter`, so the
        `comptime if` dead-arm-elides the call on every other conformer. A
        correct (non-raising) default keeps any future NoFilter wiring safe
        without forcing the other conformers to carry a hand-written override."""
        for r in range(n):
            self.feed_row[bo](batch, r)

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """Drain the accumulated breaker state at end-of-input into the output
        `RecordBatch` (or `None` for a breaker that emits per-batch, e.g.
        JoinProbe). BORROWS `self` — the owning `Stage.finalize(var self)` drops
        the state afterward (a consume-via-`self.state^` partial-move out of
        `var self` is rejected as "destroyed out of the middle"). Called by the
        generic `Stage.finalize`."""
        ...

    def drain_to_record_batch_parallel[disp_o: Origin[mut=True]](
        self,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        cancel_token: CancellationToken,
    ) raises -> Optional[RecordBatch]:
        """PARALLEL drain (P-PL.3 Part 2). Same contract as
        `drain_to_record_batch`, but with a `dispatcher_ptr` the drain can use to
        fan the per-partition scan across workers via whole-partition bucketing.

        DEFAULT BODY: ignore the dispatcher and call `drain_to_record_batch()`
        (the serial drain — correct + byte-identical for every conformer). Only
        `PartitionUdfState` overrides this with the whole-partition parallel
        drain (`partition_udf_parallel.run_partition_udf_drain_parallel`); every
        other accumulate conformer (HashAgg / Sort / TopN / Window / JoinBuild)
        inherits this serial default unchanged. The generic `StageMorselSinkAdapter`
        calls this from `finalize` (where the dispatcher is available) instead of
        `drain_to_record_batch`, so the partition-UDF path picks up the parallel
        drain while all other paths see no behavior change."""
        return self.drain_to_record_batch()

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        """The JOIN_PROBE arm's per-batch MID-BATCH emit (U-D.4). Probe the
        (pre-built) build table with every probe row's key and EMIT the joined
        rows as one output `RecordBatch` (or `None` if the probe produced zero
        rows). This is the `have_output` shape — UNLIKE the accumulate arms
        (`feed_row` + finalize-`drain_to_record_batch`), JoinProbe emits per
        batch and `finalize` returns None.

        `join_t` is the comptime join-type discriminator (`JOIN_INNER` /
        `JOIN_LEFT` from `stage_program.mojo`), threaded by the `Stage`
        JOIN_PROBE arm from `Self.Breaker.join_t_static()` — keeping
        `JoinProbeSpec` (the IR) the single source of truth for the join type
        (U-D.4b part 1). INNER drops unmatched probe rows; LEFT emits exactly one
        nullable sentinel row per unmatched probe row.

        Called ONLY by the generic `Stage` JOIN_PROBE arm; the 5 non-JoinProbe
        conformers (`NoState` / `HashAggTable` / `SortBuffer` / `TopNState` /
        `WindowState`) implement it as a raise-stub — `comptime if` skips
        dead-arm type-checking so it is never invoked on them, but the
        conformance requires the method to exist on every conformer."""
        ...

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        """The ASOF_JOIN arm's per-batch MID-BATCH emit (U-D.5). Forward-search
        the (pre-built) asof build table with every probe row's temporal key and
        EMIT the joined rows as one output `RecordBatch` (or `None` if the probe
        produced zero rows). This is the `have_output` shape — like JOIN_PROBE
        (`probe_batch`) and UNLIKE the accumulate arms; `finalize` returns None.

        UNLIKE `probe_batch`, asof carries NO `join_t` discriminator: the match
        is always a forward temporal INNER match (each probe row matches the
        most-recent build row with temporal key `<=` the probe key; an unmatched
        probe row emits nothing) — mirroring the live runtime
        `feed_asof_join_single_i64_temporal_key`.

        Called ONLY by the generic `Stage` ASOF_JOIN arm; the non-asof
        conformers implement it as a raise-stub — `comptime if` skips dead-arm
        type-checking so it is never invoked on them, but the conformance
        requires the method to exist on every conformer."""
        ...

    # --- TEC-C-3c bind: state-internal Expr leaf binding -----------------------
    def bind(mut self, resolver: ColumnResolver) raises:
        """The breaker state owns the per-shape Expr instances
        (HashAggTable's group-key Expr + agg-value Expr leaves, SortBuffer's
        key Expr leaves, JoinBuildTable's key Expr leaves). These are the
        ACTUAL leaves that need runtime _idx populated for typed dispatch.

        Default body is no-op so existing breaker-state conformers
        (NoState / HashAggTable / SortBuffer / JoinBuildTable / etc.)
        satisfy the trait without per-conformer edits — they pick up the
        no-op default. Conformers that NEED real bind (typed HashAggTable
        when typed-Stage dispatch is wired) override.

        Today's state conformers manage their own col-idx resolution at
        construction time via comptime params, so no-op bind is correct."""
        pass


# =============================================================================
# §1b — BreakerStateCombinable — the cross-instance merge sub-trait (S1)
# =============================================================================
#
# an internal doc Part 7 §7.1 S1 + §6.3 deliverable.
# Closes the D3a HALT "load-bearing gap": today no `BreakerState` conformer
# exposes a cross-instance combine/merge — only per-bucket `combine_into`
# (one table) + a one-off `GrowableHashSetI64.combine` exist. The multi-worker
# driver (S2 `StageMorselSinkAdapter`) needs `combine` to merge per-worker
# breaker states into a global, then call `drain_to_record_batch` once.
#
# # Single-source-of-truth placement (OQ-5)
#
# The sub-trait is DECLARED here (co-located with its parent `BreakerState`),
# NOT in a new `breaker_state_combinable.mojo` file. `breaker_state_trait.mojo`
# is a LEAF module (imports only `RecordBatch` / `BatchView` / `BREAKER_NONE` /
# `ColumnResolver`); adding the sub-trait here introduces NO new import and no
# cycle (the 13 conformer files already import FROM this module). Each
# conformer's real / raise-stub `combine` BODY lives in that conformer's own
# primitive file (`hash_agg.mojo`, `sort_buffer.mojo`, `topn_state.mojo`,
# `window_state.mojo`, `join_build.mojo`, etc.) — the SAME split as the parent
# trait's `feed_row` / `drain_to_record_batch` bodies.
#
# # Sub-trait inheritance (Mojo — POC `poc_breakerstate_combinable`)
#
# `trait BreakerStateCombinable(BreakerState)` compiles verbatim; in-tree
# precedent `trait ColumnarReader(FileFormat)` at
# `komira_async/fs/file_format.mojo:161`. A conformer of the sub-trait
# satisfies BOTH `BreakerState`'s surface AND `combine`; a generic body over
# `BSC: BreakerStateCombinable` reaches the parent's methods for free (the
# S2 adapter does `global.combine(partial^)` then `global.drain_*()`).
#
# # combine semantics (the byte-identical-to-single-worker contract)
#
# `combine(mut self, var other: Self)` MUST be byte-identical to feeding all
# rows to ONE instance: folding worker-A's rows into state A, worker-B's into
# state B, then `A.combine(B^)`, yields the EXACT result a single-worker feed
# of (A-rows ++ B-rows) would. The body shape mirrors the legacy cross-worker
# fold `FlatHashAggregator.merge` (`flat_hash_agg.mojo:1170`): re-insert /
# re-fold every live entry of `other` into `self` BY KEY (not by raw slot —
# the two states hash independently, so a per-slot fold would corrupt buckets).
# `var other` is owned + consumed (partial-move-safe; `self` carries the merged
# state afterward).
# =============================================================================


trait BreakerStateCombinable(BreakerState):
    """Cross-instance combine for parallel workers' per-worker `BreakerState`
    slabs — the S2 multi-worker barrier-merge surface.

    Called once at the parallel barrier in the (forthcoming) multi-worker
    `StageMorselSinkAdapter`: each worker's per-worker `BreakerState` is merged
    into ONE global state via repeated `global.combine(worker_local^)`, then
    `drain_to_record_batch` / the per-shape finalize runs once on the global.

    Inherits the full `BreakerState` executable surface (`state_tag` /
    `feed_row` / `drain_to_record_batch` / `probe_batch` / `probe_asof_batch` /
    `bind`); the sub-trait adds ONLY `combine`. The 5 ACCUMULATE breaker shapes
    (HashAgg / Sort / TopN / Window / JoinBuild) carry a real byte-identical
    fold; the 4 MID-BATCH-EMIT / probe shapes (JoinProbe / AsofJoinBuild /
    AsofJoinProbe / PartitionTopN) carry a raise-stub — they never participate
    in a cross-worker accumulate fold by design, and the S2 adapter's
    per-`state_tag` dispatch never routes a combine to them (the raise is a
    defensive loud-on-misuse guard)."""

    def combine(mut self, var other: Self) raises:
        """Merge `other`'s accumulated state into `self`. After this call,
        `other` is consumed (`var`-bound → owned, partial-move-safe) and `self`
        carries the combined state.

        CONTRACT (the byte-identical-to-single-worker invariant): for any input
        partitioned into row-sets R_a, R_b, building state A over R_a and state
        B over R_b then `A.combine(B^)` MUST produce the EXACT same accumulated
        state (hence the EXACT same `drain_to_record_batch` output, modulo the
        breaker's documented ordering contract) as building one state over the
        concatenation (R_a ++ R_b). The fold is BY KEY / BY ENTRY, never by raw
        bucket slot (independent states hash independently)."""
        ...

    def combine_move_distinct(mut self, var other: Self) raises:
        """CONCAT-FREE cross-instance merge (PERF-CD-PARALLEL-COMBINE).
        The S2 adapter calls THIS instead of `combine` (kill-switch on): a state
        whose per-group accumulator is a COUNT_DISTINCT value buffer moves each
        worker's buffer in (O(1), no serial concat) and defers the radix dedup to
        the parallel drain.

        DEFAULT BODY = the serial `combine` — EVERY non-CD-capable state (Sort /
        TopN / Window / JoinBuild) inherits this with ZERO change. ONLY
        `HashAggTable` overrides it (its CD aggregate arm moves buffers; every
        non-CD aggregate in the table folds via the `combine_at_move` default =
        `combine_at`, so a HashAggTable with no CD agg is byte-identical to
        `combine`). Byte-identical RESULT to `combine` for every state — this is a
        performance-only merge shape, not a semantic change (the established
        default-decline pattern)."""
        self.combine(other^)

    # --- ENGINE-V2 S2 process_chunk seam (dark KOMIRA_CHUNK_V2_AGG) -----------
    #
    # The MorselView fold entry, type-erased onto the combinable state for the
    # SAME reason `consume_band` is: the container route's gate lives in
    # `materialize_parquet_typed_stage[FS, F, P, B, SF]`, where the concrete
    # scalar-agg monomorph arrives ONLY as the opaque `SF: StageFactory` (its
    # `State: BreakerStateCombinable` is all that seam sees), and Mojo
    # cannot comptime-destructure an associated type's parameters to recover
    # `HashAggTable[KB, *Aggs]`.
    #
    # `HashAggTable.fold_scalar_view[V]` (landed ) has this EXACT
    # signature, so it IS the override — this declaration adds no new method,
    # it only makes the existing one reachable through the trait. DEFAULT =
    # DECLINE (raise): every other combinable state (Sort / TopN / Window /
    # JoinBuild / the probe stubs) inherits the loud decline, and the gate only
    # routes a 0-key BREAKER_HASH_AGG breaker here, so a mis-routed off-shape
    # faults LOUDLY, never silent-wrong.
    def fold_scalar_view[V: MorselView](mut self, view: V) raises:
        """`process_chunk` — fold ONE morsel into this accumulator through the
        format-blind `MorselView` seam (RecordBatch, arena Chunk, or a zero-copy
        decode page window; a future CSV/JSON/Arrow/ORC/Avro conformer feeds the
        SAME kernel). DEFAULT DECLINE — only `HashAggTable` overrides, and only
        for the 0-key scalar aggregate."""
        raise Error(
            "BreakerStateCombinable.fold_scalar_view: this state does not"
            " support the MorselView scalar fold (ENGINE-V2 S2"
            " KOMIRA_CHUNK_V2_AGG); only HashAggTable's 0-key scalar aggregate"
            " is container-eligible (the gate routes only a 0-key"
            " BREAKER_HASH_AGG breaker)."
        )

    # --- q1 decode vertical spike (, dark KOMIRA_PAGE_PIPE) ------
    #
    # The BAND-view fold entry, type-erased onto the combinable state so the
    # factory-parameterized `HashAggBandSinkFromFactory[SF]` (whose `WorkerLocal`
    # is the opaque `SF.State: BreakerStateCombinable`) can drive the per-page band
    # producer's `sink.consume_band(local, band)` without naming a concrete
    # `HashAggTable[KB, *Aggs]` — the SAME trait-erasure wall the band fold's
    # `DistinctKeyColumn` / `Aggregator` / `AggColumn` siblings resolve. DEFAULT =
    # DECLINE (raise): ONLY `HashAggTable` (q1's grouped-agg breaker state) has a
    # real `consume_band` override; every other combinable state (Sort / TopN /
    # Window / JoinBuild / the probe stubs) inherits this loud decline — the
    # KOMIRA_PAGE_PIPE gate (`materialize_parquet_typed_stage`) only routes a
    # BREAKER_HASH_AGG breaker onto the band producer, so a mis-routed off-shape
    # faults LOUDLY, never silent-wrong.
    def consume_band[o: Origin[mut=False]](
        mut self, band: BandView[o]
    ) raises:
        """Fold ONE decoded row-band DIRECTLY into this accumulator state off the
        band's reused decode-scratch spans (NO RecordBatch). DEFAULT DECLINE —
        only `HashAggTable` overrides (contract §3.2). The band producer's
        `HashAggBandSinkFromFactory[SF]` calls this on `SF.State`; the gate never
        routes a non-HashAgg state here (BREAKER_HASH_AGG comptime gate)."""
        raise Error(
            "BreakerStateCombinable.consume_band: this state does not support"
            " the band-view fold (q1 spike KOMIRA_PAGE_PIPE); only HashAggTable"
            " is band-eligible (the gate routes only a BREAKER_HASH_AGG breaker)."
        )

    # --- REST-TYPED-RADIX-SPIKE — per-partition combine (default-decline) ------
    #
    # The typed-stage high-card COMBINE lever (option f). The serial `combine`
    # folds every worker into ONE global on one core (74-87% of h5/h7/h10 wall).
    # This sub-surface lets the S2 adapter fan a partition-parallel combine over
    # the EXISTING `_drive_combine_partition` driver: N disjoint partition
    # accumulators (`List[Self]` in the sink Global), task p folds every worker's
    # partition-p groups into accumulator p (disjoint by construction — hash % N).
    #
    # DEFAULT-DECLINE (mirrors `combine_move_distinct` / `feed_chunk_global`):
    #   * `SUPPORTS_RADIX_COMBINE = False` — the adapter's partition arm is
    #     `@parameter if Self.SUPPORTS_RADIX_COMBINE`, so for EVERY non-agg state
    #     (Sort / TopN / Window / JoinBuild) the whole partition machinery is
    #     COMPTIME-DEAD — never elaborated, ZERO symbols (the laziness gate).
    #   * `combine_partition_from` default RAISES — never reached when
    #     `SUPPORTS_RADIX_COMBINE` is False (the arm is elided). ONLY
    #     `HashAggTable[KB, *Aggs]` overrides both; its override monomorphizes
    #     per-agg-pack ONLY for packs a binary actually reaches (per-symbol lazy).
    comptime SUPPORTS_RADIX_COMBINE: Bool = False

    def n_combine_partitions(self) -> Int:
        """Partition count for the parallel combine (REST-TYPED-RADIX-SPIKE). The
        S2 adapter peeks ONE worker's state via this to size the
        `_drive_combine_partition` fan. DEFAULT = 1 (serial whole-segment
        combine). ONLY `HashAggTable` overrides it (returns 64 for a high-card
        keyed table, 1 for low-card / 0-key). Resolvable on the abstract `BState`
        so the adapter's generic peek type-checks; monomorphized only inside the
        `@parameter if SUPPORTS_RADIX_COMBINE` arm (HashAggTable only)."""
        return 1

    def combine_partition_from[o: Origin[mut=False]](
        mut self, ref [o] src: Self, partition: Int, n_partitions: Int
    ) raises:
        """Fold ONLY `src`'s groups whose key-hash maps to `partition` (of
        `n_partitions`) into `self` — `self` is partition `partition`'s PRIVATE
        accumulator, so partition-p writes are disjoint from partition-q (the
        `_drive_combine_partition` range-claim is race-free). BORROWS `src` (one
        `src` is scanned by all N partition tasks before it drops). The
        byte-identical-to-serial invariant: a group's per-worker partials fold in
        worker order (the same order the serial `combine` folds), so f64 sums are
        BIT-identical, not merely epsilon-close.

        DEFAULT BODY = raise. `SUPPORTS_RADIX_COMBINE` is False for every state
        but `HashAggTable`, so the adapter's `@parameter if` elides this call
        everywhere else (never monomorphized off the agg path)."""
        raise Error(
            "BreakerStateCombinable.combine_partition_from: this state does not"
            " support radix combine (SUPPORTS_RADIX_COMBINE is False)"
        )

    # --- PERF-AGG-DRAIN-EMIT-AT-OFFSET — fused drain-into-final-offset surface --
    #
    # The finalize arm's `parallel_partition_drain_emit_at_offset` orchestrator
    # (opt-in behind `KOMIRA_AGG_DRAIN_EMIT_AT_OFFSET`) drains each radix
    # partition DIRECTLY into the shared FINAL output columns at prefix-sum
    # offsets, fusing the drain + the N-way concat into one write pass. These four
    # methods are the type-erased surface the generic orchestrator drives. They
    # DEFAULT-DECLINE (mirror the radix combine surface): only `HashAggTable`
    # overrides them; every other state produces an EMPTY plan, so the orchestrator
    # returns None and the finalize arm falls back to the parallel-drain + concat
    # path. Off the agg path the orchestrator is `@parameter if`-elided (never
    # instantiated), so these defaults are pure conformance stubs.

    def n_drain_rows(self) -> Int:
        """Output rows THIS partition contributes to the fused drain. DEFAULT 0."""
        return 0

    def emit_at_offset_plan(self, mut descs: List[_EmitColDesc]) raises:
        """Append one `_EmitColDesc` per output column. DEFAULT no-op — an empty
        plan marks the shape NOT emit-at-offset-eligible (orchestrator falls back).
        `raises` so the HashAggTable override can fail loud on an `_out_names`
        arity mismatch (mirrors the serial drain)."""
        pass

    def emit_at_offset_data_bytes(self, mut out: List[Int]):
        """Append THIS partition's per-column variable data-byte contribution.
        DEFAULT no-op."""
        pass

    def emit_at_offset_write[do: Origin[mut=False]](
        self,
        mut targets: List[_EmitColTarget],
        row_offset: Int,
        ref [do] data_offsets: List[Int],
        data_base: Int,
    ) raises:
        """Scatter THIS partition's groups into the shared FINAL columns at
        `row_offset`. DEFAULT raise — never reached (the orchestrator gates on a
        non-empty, all-eligible plan before any write)."""
        raise Error(
            "BreakerStateCombinable.emit_at_offset_write: this state is not"
            " emit-at-offset-eligible"
        )


# =============================================================================
# §2 — NoState — the NoBreaker arm's state
# =============================================================================


@fieldwise_init
struct NoState(BreakerState):
    """The breaker-state for the `NoBreaker` arm.

    Filter+project / pass-through stages accumulate no breaker state, so the
    `NoBreaker` arm pairs with `NoState` (`state_tag() == BREAKER_NONE`). A POD
    `Int` sentinel — the `@fieldwise_init` derived ctor gives `Stage`'s `state`
    field a stable shape for the `NoBreaker` instantiation.
    """

    var sentinel: Int

    @staticmethod
    def state_tag() -> Int:
        return BREAKER_NONE

    def feed_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], row: Int
    ) raises:
        """No-op — the `NoBreaker` arm accumulates no breaker state (its
        per-batch filter+project emit is the stream; the `Stage` NoBreaker arm
        never calls this)."""
        pass

    def drain_to_record_batch(self) raises -> Optional[RecordBatch]:
        """`None` — non-breaker stages have no terminal drain."""
        return None

    def probe_batch[bo: Origin[mut=False], join_t: Int](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        """Raise-stub — `NoState` is never the JOIN_PROBE arm's state (the
        `comptime if` JOIN_PROBE arm is the only caller; `NoState` backs
        `NoBreaker`). Raising keeps a wrong wiring loud."""
        raise Error("NoState.probe_batch: not a JOIN_PROBE state")

    def probe_asof_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo]
    ) raises -> Optional[RecordBatch]:
        """Raise-stub — `NoState` is never the ASOF_JOIN arm's state (U-D.5)."""
        raise Error("NoState.probe_asof_batch: not an ASOF_JOIN state")

# =============================================================================
# komira_broker/sublineage_rollout_metrics.mojo
#   Sub-lineage rollout monitoring — the LIVE rollout signals for a
#   forward-only sub-lineage canary.
# =============================================================================
#
# The LIVE, CHEAP rollout-watch signals for the disjoint-keyspace per-generation
# `<part>/_lineage/<shard>` model. Emitted into the existing `komira_metrics`
# `MetricsSet` so a live canary is observable on the broker's metrics surface.
# The signal definitions here are the same ones an offline go/no-go evaluation
# over a sampled snapshot should use, so the live L/F values an operator
# watches equal the values such an evaluation computes.
#
# WHY FORWARD-ONLY (the design constraint that shapes this module). There is NO
# clean backward revert once a partition takes live sub-lineage writes: a
# flag-off legacy read is EMPTY post-write, and `migrate_partition` retires the
# legacy manifest. The operator therefore CANNOT revert — they must WATCH the
# canary closely and FORWARD-FIX. These signals are that watch surface.
# THE SIGNALS (priority order):
#   1. LIVE-LINEAGE WIDTH L (gauge `sublin_live_lineage_width`) — the live shard
#      count / un-folded-tail width from `SegmentBaseFold.bound_stats()`,
#      reported as MAX(live_tail_shards, live_shard_count) (the component that
#      breaches first). Updated on every
#      fold + every sub-lineage consume. PLUS the warn counter
#      `sublin_l_exceeds_bound` (the #1 forward-only failure mode = UNBOUNDED
#      growth: the fold not keeping up, the cross-shard resolution state
#      growing with rounds). The warn fires on exactly
#      `live_tail_shards > bound OR live_shard_count > bound`.
#   2. FOLD CADENCE F (gauge `sublin_fold_interval_ms`) — milliseconds between
#      successive folds (the last-interval gauge), from the fold. A cadence that
#      stretches means the fold is falling behind (and L will grow). PLUS the
#      fold-count counter `sublin_fold_count` (total folds this canary).
#   3. OFFSET-CONTIGUITY AUDIT (counters `sublin_contiguity_violations` /
#      `sublin_contiguity_clean`) — the LIVE correctness canary. Incremented by
#      the EXISTING retention walk (RetentionPass.run already walks chunk
#      metadata) when a gap/overlap is found across surviving segments
#      (violation), or clean (zero violations). The audit checks gap / overlap /
#      per-segment tear.
#   4. EOS / read_committed + consume-record health (counters
#      `sublin_consume_eos` / `sublin_consume_records`) — cheap consume-path
#      health. Incremented on a sub-lineage consume drain.
#
# HARD CONSTRAINTS (the load-bearing part):
#   (i)  GATED to sub-lineage-ENABLED partitions ONLY. Every `record_*` call site
#        is reached ONLY from a sub-lineage-enabled code path (the fold runs only
#        for an enabled partition; the consume audit fires only behind the
#        `_sublineage_consume[pid]` gate; the contiguity audit fires only when a
#        rollout-metrics holder is THREADED IN, which the legacy path does not
#        do). A default-OFF partition constructs NO holder, calls NO `record_*`,
#        and emits NOTHING new — the legacy path is byte-identical.
#   (ii) CHEAP on the hot path. Every emission is a `Counter.inc_out_of_pipeline`
#        (one Relaxed atomic fetch_add) or a `Gauge.set_out_of_pipeline` (one
#        Relaxed atomic store) — NO new object-store round-trip on the
#        produce/consume path. The contiguity audit rides the EXISTING retention
#        chunk-metadata walk; it adds ZERO new LIST/GET. The fold L/F read uses
#        the `bound_stats()` the fold path already computes for its own
#        observability (no extra enumeration on the metric account).
#   (iii) Mojo encapsulation / slab safety:
#        * ZERO UnsafePointer in any signature; the surface is value / scalar /
#          `BoundStatsView` POD / `OwnedPointer[MetricsSet]` held internally.
#        * ZERO wildcard-origin FIELD: the ONLY field is
#          `OwnedPointer[MetricsSet]` (the canonical indirection; `MetricsSet`
#          is non-Movable so it MUST live behind an OwnedPointer — built via the
#          `new_owned_metrics_set()` factory).
#        * ZERO `unsafe_from_address` / `take_pointee`.
#        * This struct is NEVER a byte-slab element; it is a
#          long-lived holder behind an OwnedPointer, and its sole field is
#          itself an OwnedPointer (no Movable-struct-in-byte-slab-with-heap-field
#          shape). The metric primitives' own slab safety (InlineArray per-worker
#          slabs + Atomic) is established in `komira_metrics`.
# =============================================================================

from komira_metrics.metrics_set import MetricsSet, MetricsSnapshot, new_owned_metrics_set
from std.memory import OwnedPointer


# =============================================================================
# Metric NAMES — the registry's name_id source.
# =============================================================================
# The `MetricsSet.register_*` / `gauge` / `counter` parametric methods take a
# `[name: StringLiteral]` parameter that must be bound to a BARE string literal
# at the call site (a `comptime X: StringLiteral = "..."` constant is a singleton
# literal TYPE that does not implicitly re-bind to the open `[name: StringLiteral]`
# parameter in Mojo 1.0.0b1 — verified at compile time). So the names appear as
# bare literals at every register / gauge / counter site below. The canonical
# list (keep in sync with the call sites + the test readers):
#
#   "sublin_live_lineage_width"     — L gauge.
#   "sublin_l_exceeds_bound"        — L-over-bound warn counter.
#   "sublin_fold_interval_ms"       — F last-interval gauge.
#   "sublin_fold_count"             — fold-count counter.
#   "sublin_contiguity_violations"  — contiguity-violation counter.
#   "sublin_contiguity_clean"       — contiguity clean-walk counter.
#   "sublin_consume_eos"            — clean-EOS counter.
#   "sublin_consume_records"        — consume-record counter.


# =============================================================================
# BoundStatsView — the POD by-value width snapshot the fold feeds the metrics.
# =============================================================================
#
# A FORMAT-DECOUPLED mirror of the production `SegmentBoundStats`
# (`sublineage_segment_fold.mojo`, returned by `SegmentBaseFold.bound_stats()`).
# Taking a small POD view keeps THIS module dependency-free of the fold type (no
# cross-module import for a 2-int read) and keeps the surface a pure by-value
# scalar struct — the caller maps its `bound_stats()` into this view (plus the
# separately-passed `grower_width` cadence bound) at the one fold/consume site.


@fieldwise_init
struct BoundStatsView(Copyable, Movable, Deinitable):
    """The live-lineage width snapshot the L signal reports over. POD.

    The two width fields mirror the production `SegmentBoundStats`
    (`sublineage_segment_fold.mojo`, returned by `SegmentBaseFold.bound_stats()`).
    `SegmentBoundStats` has THREE fields — `live_base_chunks`, `live_tail_shards`,
    `live_shard_count` — and NO `grower_width`. We carry only the two width
    components L is computed from (`live_base_chunks` is not part of the L width),
    plus `grower_width`, which is NOT a `SegmentBoundStats` field: it is the
    separately-passed cadence bound (the O(shards) ceiling = concurrent growers +
    any txn shards) the caller threads in alongside the stats, matching the gate's
    `RolloutGateInputs.grower_width`.

    Field layout:
      var live_tail_shards: Int   — shards with an un-folded tail at this instant
                                    (mirrors `SegmentBoundStats.live_tail_shards`).
      var live_shard_count: Int   — total live source shards enumerated
                                    (mirrors `SegmentBoundStats.live_shard_count`).
      var grower_width: Int       — the O(shards) cadence ceiling (the bound L is
                                    checked against — the number of concurrent
                                    growers + any txn shards); passed in separately,
                                    NOT a `SegmentBoundStats` field.
    """

    var live_tail_shards: Int
    var live_shard_count: Int
    var grower_width: Int

    @always_inline
    def width(self) -> Int:
        """The reported L value: MAX(live_tail_shards, live_shard_count) — the
        SAME `width_val` the offline gate evaluator reports (the component that
        would breach the bound first). Matches `sublineage_rollout_gate.mojo`'s
        `width_val` computation EXACTLY."""
        return (
            self.live_tail_shards if self.live_tail_shards
            > self.live_shard_count
            else self.live_shard_count
        )

    @always_inline
    def exceeds_bound(self) -> Bool:
        """True iff L is OVER the cadence bound — the warn condition:
        `live_tail_shards > grower_width OR live_shard_count > grower_width`
        (unbounded growth)."""
        return (
            self.live_tail_shards > self.grower_width
            or self.live_shard_count > self.grower_width
        )


# =============================================================================
# SubLineageRolloutMetrics — the LIVE forward-only rollout-watch metrics holder.
# =============================================================================


struct SubLineageRolloutMetrics(Movable, Deinitable):
    """The LIVE rollout-watch signal emitter for ONE sub-lineage-enabled
    partition's canary. Constructed ONLY for an enabled partition; a default-OFF
    partition never builds one (gating constraint (i)). Every `record_*` is a
    single Relaxed atomic into the registered `MetricsSet` primitive (constraint
    (ii) — cheap, no I/O). The `MetricsSet` is non-Movable, so it is held behind
    the canonical `OwnedPointer[MetricsSet]` indirection (constraint (iii)).

    Lifetime: the holder is OWNED by the canary driver (the fold/consume loop)
    for the canary's duration. `snapshot()` reduces the live primitives to a POD
    `MetricsSnapshot` an advertised-metrics reader / test reads off the broker's
    metrics surface.

    Cadence state: `_last_fold_ns` is the monotone-ns timestamp of the previous
    fold (0 == no prior fold). `record_fold` computes the interval against it and
    advances it. POD Int64 — no heap, no pointer.
    """

    var _metrics: OwnedPointer[MetricsSet]
    var _last_fold_ns: Int64

    def __init__(out self) raises:
        """Allocate the `MetricsSet` behind an OwnedPointer (the non-Movable
        factory shape) and register every rollout signal. Registration is at
        construction time so the lookup hot path is a plain linear scan (no
        register-on-first-emit branch). Registers 6 counters within the
        MAX_COUNTERS=8 budget + 2 gauges (L width, fold interval) within the
        MAX_GAUGES=4 budget."""
        self._metrics = new_owned_metrics_set()
        # L-WIDTH gauge + the L-exceeds-bound warn counter (signal 1).
        _ = self._metrics[].register_gauge["sublin_live_lineage_width"]()
        _ = self._metrics[].register_counter["sublin_l_exceeds_bound"]()
        # FOLD-CADENCE F gauge (last interval ms) + the fold-count counter (2).
        _ = self._metrics[].register_gauge["sublin_fold_interval_ms"]()
        _ = self._metrics[].register_counter["sublin_fold_count"]()
        # OFFSET-CONTIGUITY audit counters (signal 3).
        _ = self._metrics[].register_counter["sublin_contiguity_violations"]()
        _ = self._metrics[].register_counter["sublin_contiguity_clean"]()
        # EOS / consume-record health counters (signal 4).
        _ = self._metrics[].register_counter["sublin_consume_eos"]()
        _ = self._metrics[].register_counter["sublin_consume_records"]()
        self._last_fold_ns = Int64(0)

    # -------------------------------------------------------------------------
    # Signal 1 + 2 — record a fold: L width + L-exceeds-bound warn + F cadence.
    # -------------------------------------------------------------------------

    def record_fold(mut self, bound: BoundStatsView, now_ns: Int64):
        """Emit the post-fold rollout signals (constraint (ii): all out-of-
        pipeline Relaxed atomics, no I/O — `bound` is the `bound_stats()` the
        fold path already computed). Called ONCE per fold round of an enabled
        partition.

          * L-WIDTH gauge ← `bound.width()` (== the gate's `width_val`).
          * L-EXCEEDS-BOUND warn counter += 1 IFF `bound.exceeds_bound()`
            (== the gate's `validate_l_bound` NO-GO condition).
          * FOLD-INTERVAL-MS gauge ← (now_ns - last_fold_ns) / 1e6 when a prior
            fold exists (0 on the first fold; the cadence is undefined for one
            sample). `_last_fold_ns` is advanced to `now_ns`.
          * FOLD-COUNT counter += 1.
        """
        # L-WIDTH gauge (last-write-wins).
        self._metrics[].gauge["sublin_live_lineage_width"]().set_out_of_pipeline(
            Int64(bound.width())
        )
        # L-EXCEEDS-BOUND warn — the #1 forward-only failure mode.
        if bound.exceeds_bound():
            self._metrics[].counter[
                "sublin_l_exceeds_bound"
            ]().inc_out_of_pipeline(Int64(1))
        # FOLD-CADENCE F — last-interval gauge (ms). Undefined on the first fold.
        if self._last_fold_ns > Int64(0) and now_ns >= self._last_fold_ns:
            var interval_ms = (now_ns - self._last_fold_ns) // Int64(1_000_000)
            self._metrics[].gauge[
                "sublin_fold_interval_ms"
            ]().set_out_of_pipeline(interval_ms)
        self._last_fold_ns = now_ns
        # FOLD-COUNT.
        self._metrics[].counter["sublin_fold_count"]().inc_out_of_pipeline(
            Int64(1)
        )

    # -------------------------------------------------------------------------
    # Signal 1 (consume side) — update L on a consume (without the F cadence).
    # -------------------------------------------------------------------------

    def record_consume_width(mut self, bound: BoundStatsView):
        """Update the L-WIDTH gauge (+ the L-exceeds-bound warn) from a CONSUME
        observation of `bound_stats()`. The dispatch's "updated on fold/consume"
        — a consumer that resolves the serve-merged tail observes the live width
        too; reporting it keeps L fresh between folds (a fold-behind canary's L
        growth shows on the consume path BEFORE the next fold). Does NOT touch
        the F cadence (consume is not a fold)."""
        self._metrics[].gauge["sublin_live_lineage_width"]().set_out_of_pipeline(
            Int64(bound.width())
        )
        if bound.exceeds_bound():
            self._metrics[].counter[
                "sublin_l_exceeds_bound"
            ]().inc_out_of_pipeline(Int64(1))

    # -------------------------------------------------------------------------
    # Signal 3 — the offset-contiguity audit (rides the retention walk).
    # -------------------------------------------------------------------------

    def record_contiguity_audit(mut self, violations_found: Int):
        """Record the result of the offset-contiguity audit that rode the
        EXISTING retention chunk-metadata walk (constraint (ii): ZERO new walk,
        ZERO new I/O). `violations_found` is the count of gap/overlap/per-segment
        tears the audit found across the surviving segments (the
        `validate_dense_contiguity` shape). On a clean walk (0), the CLEAN
        counter advances (a positive liveness signal — the audit ran and found
        nothing); on >0 the VIOLATIONS counter advances by that count (the LIVE
        correctness NO-GO — the #1 thing the operator aborts the canary on)."""
        if violations_found > 0:
            self._metrics[].counter[
                "sublin_contiguity_violations"
            ]().inc_out_of_pipeline(Int64(violations_found))
        else:
            self._metrics[].counter[
                "sublin_contiguity_clean"
            ]().inc_out_of_pipeline(Int64(1))

    # -------------------------------------------------------------------------
    # Signal 4 — EOS / consume-record health.
    # -------------------------------------------------------------------------

    def record_consume(mut self, records_drained: Int, reached_eos: Bool):
        """Cheap consume-path health: `records_drained` rows served on this
        sub-lineage drain (+= the records counter), and the EOS counter += 1 iff
        the drain reached a clean end-of-stream. Both out-of-pipeline atomics."""
        if records_drained > 0:
            self._metrics[].counter[
                "sublin_consume_records"
            ]().inc_out_of_pipeline(Int64(records_drained))
        if reached_eos:
            self._metrics[].counter[
                "sublin_consume_eos"
            ]().inc_out_of_pipeline(Int64(1))

    # -------------------------------------------------------------------------
    # Read-back — for advertised metrics + tests.
    # -------------------------------------------------------------------------

    def snapshot(self) -> MetricsSnapshot:
        """Reduce the live primitives to a POD `MetricsSnapshot` (off the hot
        path). An advertised-metrics reader / test reads each signal out of this
        by its `fnv1a_hash[NAME]()` name_id (see the typed helper readers
        below)."""
        return self._metrics[].reduce()

    # ---- typed scalar readers (the canary harness / advertised metrics use) ----

    @always_inline
    def live_lineage_width(self) -> Int64:
        """The current L gauge value (MAX live width)."""
        return self._read_gauge["sublin_live_lineage_width"]()

    @always_inline
    def l_exceeds_bound_count(self) -> Int64:
        """How many times L breached the cadence bound (the forward-only warn)."""
        return self._read_counter["sublin_l_exceeds_bound"]()

    @always_inline
    def last_fold_interval_ms(self) -> Int64:
        """The most recent fold-to-fold interval in ms (0 if <2 folds)."""
        return self._read_gauge["sublin_fold_interval_ms"]()

    @always_inline
    def fold_count(self) -> Int64:
        return self._read_counter["sublin_fold_count"]()

    @always_inline
    def contiguity_violations(self) -> Int64:
        """The LIVE-correctness canary: total contiguity violations observed
        (gap/overlap/tear). MUST be 0 for a GO."""
        return self._read_counter["sublin_contiguity_violations"]()

    @always_inline
    def contiguity_clean_runs(self) -> Int64:
        """How many retention walks ran clean (no contiguity violation)."""
        return self._read_counter["sublin_contiguity_clean"]()

    @always_inline
    def consume_eos_count(self) -> Int64:
        return self._read_counter["sublin_consume_eos"]()

    @always_inline
    def consume_records_count(self) -> Int64:
        return self._read_counter["sublin_consume_records"]()

    @always_inline
    def _read_gauge[name: StringLiteral](self) -> Int64:
        return self._metrics[].gauge[name]().reduce()

    @always_inline
    def _read_counter[name: StringLiteral](self) -> Int64:
        return self._metrics[].counter[name]().reduce()


# =============================================================================
# audit_segment_contiguity — the PURE per-walk contiguity audit (rides the
#   retention chunk-metadata walk; no store, no I/O).
# =============================================================================
#
# The LIVE-correctness audit kernel. Takes the per-chunk `(base_offset,
# record_count)` pairs the retention walk ALREADY built (one entry per surviving
# live chunk, in seq order) and returns the count of contiguity violations
# across them — a GAP (a chunk whose base != the prior chunk's base+count), an
# OVERLAP (base < prior base+count), or a per-chunk TEAR (non-positive count).
# This is the same gap/overlap/tear definition as the gate's
# `validate_dense_contiguity`, restricted to the offset axis the retention walk
# exposes (base_offset + record_count per chunk).
#
# PURE + by-value: takes two parallel `List[Int64]` (the retention walk's
# `_ChunkMeta.base_offset` + `.record_count` columns) so it does NOT import the
# private `_ChunkMeta` type — the caller passes the two columns it already has.
# No store I/O, no clock — so the SAME kernel is unit-testable offline with an
# injected gap, AND rides the live retention walk with zero new round-trips.


def audit_segment_contiguity(
    base_offsets: List[Int64], record_counts: List[Int64]
) -> Int:
    """Count contiguity violations across the surviving segments. `base_offsets`
    and `record_counts` are the parallel per-chunk columns the retention walk
    built (seq order; `len` equal). Returns 0 on a clean walk, else the number of
    violations found (a gap, an overlap, or a per-chunk tear each count once).

    The contiguity invariant (matching `validate_dense_contiguity`): segment[i]'s
    base_offset == segment[i-1].base_offset + segment[i-1].record_count (no gap,
    no overlap), and each segment's record_count > 0 (no tear). We anchor on
    segment[0]'s base (a retention-reaped survivor range may start > 0 — a
    compacted start is still CONTIGUOUS), exactly as the validator does."""
    var n = len(base_offsets)
    if n != len(record_counts):
        # A malformed walk (parallel columns out of sync) is itself a violation
        # — surface it rather than silently audit a truncated prefix.
        return 1
    if n == 0:
        return 0  # an empty survivor set is vacuously contiguous.
    var violations = 0
    # Per-segment tear: non-positive record_count.
    for i in range(n):
        if record_counts[i] <= Int64(0):
            violations += 1
    # Gapless + non-overlapping in seq order (anchored on segment[0].base).
    var expected_base = base_offsets[0]
    for i in range(n):
        if base_offsets[i] != expected_base:
            # base > expected == a GAP (an unfilled offset); base < expected ==
            # an OVERLAP (two segments share an offset). Either is one violation.
            violations += 1
            # Re-anchor so a single misplacement does not cascade into a
            # violation at every subsequent segment (count distinct breaks).
            expected_base = base_offsets[i] + record_counts[i]
        else:
            expected_base = base_offsets[i] + record_counts[i]
    return violations

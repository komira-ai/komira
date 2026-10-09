# =============================================================================
# komira_broker/sublineage_segment_fold.mojo
#   The PRODUCTION broker SEGMENT `_base` fold: the abstract fold model
#   (komira_objectstore.sublineage_base_fold) instantiated on the broker's REAL
#   per-shard SEGMENT sub-lineages (what sub-lineage write mode produces).
# =============================================================================
#
# THE ABSTRACT MODEL vs WHAT THIS BUILDS.
# ---------------------------------------------------------------------------
# `SubLineageBaseFold` in komira_objectstore implements the fold ALGORITHM on
# an ABSTRACT i64 `_base`: each `_base` chunk re-records i64 record PAYLOADS so a
# dense offset resolves to a stand-in record id, self-contained from `_base`. That
# is the algorithm + the SERVE==FOLD contract surface (the SHARED `_sort_snapshot`
# + `plan_assignment` + `serve_assign_tail_explicit`), but its `_base` chunk body
# is the i64-payload format — NOT what a broker partition stores.
#
# THIS (`SegmentBaseFold`) builds the REAL broker fold that persists the SEGMENT
# `_base` the `SubLineageConsumeResolver` reads by offset. A broker
# partition's records live in `.seg` objects; the manifest chunk body is a
# `ManifestBody` (segment object_key + record_count + crc32 + trailers). So the
# SEGMENT `_base` is a broker manifest of SEGMENTS, and the fold MATERIALIZES
# folded chunk-entries by REUSING the EXISTING segment objects — it records each
# source chunk's `ManifestBody` (its `object_key` / `record_count` / `crc32`) into
# the `_base` manifest in DENSE order, with ZERO byte copy of the `.seg` payload.
# `_base`'s own gapless manifest offset IS the dense Kafka offset (the offset
# allocator invariant: a chunk seq `k` occupies `[base_k, base_k + count_k - 1]`).
#
# THE SERVE==FOLD CONTRACT (load-bearing).
# ---------------------------------------------------------------------------
# The production fold and the consume resolver's serve path MUST assign
# IDENTICAL dense offsets for
# the same tail. This module does NOT introduce a second assignment path: it
# drives the SHARED `SubLineageBaseFold.snapshot_explicit()` (the SAME
# authoritative boundary the serve path pins) + the SHARED
# `SubLineageBaseFold.serve_assign_tail_explicit()` (-> `plan_assignment`, the
# SOLE assignment authority), fed the IDENTICAL inputs the resolver feeds it:
#   (a) the SAME authoritative snapshot of live source sub-lineages,
#   (b) per-shard `folded_counts` from each source shard's durable `_LOG_START`
#       (the retire-advanced fold cursor — read by `_folded_counts`),
#   (c) the `dense_hw_start` from the `_base` broker manifest's `next_offset`.
# Same sort + same `plan_assignment` + same inputs -> serve == fold byte-for-byte.
# When this fold persists the planned blocks into `_base`, a tail dense offset O
# that the serve path resolved pre-fold resolves to the SAME record post-fold (no
# torn offset). `SubLineageConsumeResolver._folded_counts` / `._base_next_dense`
# /`._fold_view().snapshot_explicit()` are the consume-side mirror of this fold's
# (a)/(b)/(c); this module's `_folded_counts` / `_base_next_dense` /
# `_snapshot` are the IDENTICAL reads, so the two stay in lock-step.
#
# MATERIALIZE + RETIRE (bounded steady state).
# ---------------------------------------------------------------------------
#   * MATERIALIZE: each planned block's intersecting source chunks are recorded
#     as `_base` manifest chunks (reusing the source `.seg` object_keys), appended
#     in dense order via single-writer If-None-Match CAS. The `_base` append
#     ASSERTS base==dense (the running fold high-water) AND last==base+count-1
#     (contiguity); a divergence is a torn fold and RAISES.
#   * RETIRE: after a shard's `[already .. snap_total)` tail is materialized, the
#     now-fully-folded SOURCE chunks get MOVED markers (the
#     `.seg` objects are `_base`'s now: a `ReapWorker` over the shard reclaims
#     the chunk keys only) AND the source shard's durable `_LOG_START` is
#     advanced to the folded watermark (the monotone-forward cursor the serve path
#     reads for `folded_counts`). The ONLY cross-shard resolution state is the
#     live un-folded tail — BOUNDED by the fold cadence (live-shard width x
#     records-since-fold), NEVER by total rounds/records.
#
# COMPACTION = RETENTION of `_base` below a folded watermark (the existing
# log-start advance + reaper machinery, NOT clear+reappend — `_base` stays ALWAYS
# readable). The broker `_base` is a plain `CasManifestStore`, so the
# broker's existing retention pass reaps below the partition log-start exactly as
# a single-manifest partition does.
#
# DEFAULT-OFF. The production fold runs ONLY in sub-lineage mode (the
# sub-lineage write flag). Legacy / flag-off partitions are SINGLE-MANIFEST (no
# `<part>/_lineage/`) so `enumerate_live_shards` returns empty and `run_once` is
# a no-op. No `CasManifestStore` change.
#
# -----------------------------------------------------------------------------
# Encapsulation / slab safety.
#   * ZERO UnsafePointer in any signature; surface is value / List / POD / the
#     Movable substrate structs held by value. ZERO wildcard origins. ZERO
#     unsafe_from_address. ZERO take_pointee.
#   * The substrate (`Store` + the per-shard / `_base` `CasManifestStore`s) is
#     held / built by value; each manifest is a `clone()` of the shared store
#     reaching the SAME logical bucket. Raw key
#     arithmetic stays INSIDE this module + the substrate.
#   * Every struct here is a stack value, NOT a byte-slab element. POD
#     fields + owned `String`s + plain `List[...]` value structs only — no
#     Movable-struct-in-byte-slab-with-heap-field shape. The persisted `_base`
#     chunk bodies are `ManifestBody` (the broker manifest opaque-body contract).
# =============================================================================

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.sublineage_base_fold import (
    FoldBlockAssignment,
    ShardFoldedWatermark,
    ShardSnapshot,
    SubLineageBaseFold,
)

from .manifest_body import ManifestBody, encode_manifest_body
from .sublineage_base_inputs import SegmentBaseInputs


# =============================================================================
# SegmentFoldStats — what one production fold round did (cadence + observability).
# =============================================================================


@fieldwise_init
struct SegmentFoldStats(Copyable, Movable, Deinitable):
    """What ONE production fold round did.

    Field layout:
      var dense_high_water: Int64  — next dense offset a future fold will assign
                                     (== `_base.next_offset` after this round).
      var records_folded: Int64    — records folded by THIS round (0 = no-op).
      var live_shard_count: Int    — source sub-lineages enumerated at the boundary.
      var base_chunks_appended: Int — `_base` manifest chunks this round appended
                                      (one per intersecting source chunk).
      var source_chunks_retired: Int — source chunks newly tombstoned this round.
    """

    var dense_high_water: Int64
    var records_folded: Int64
    var live_shard_count: Int
    var base_chunks_appended: Int
    var source_chunks_retired: Int


# =============================================================================
# SegmentBoundStats — the persistent-resolution-state bound (the bound probes).
# =============================================================================
#
# The materialize+retire model's bound has TWO bounded components:
#   * `live_base_chunks`   — `_base` manifest chunks above `_base`'s log-start
#     (folded blocks not yet retention-reaped). Retention-managed exactly like a
#     single-manifest partition; NOT N x rounds.
#   * `live_tail_shards`   — distinct source shards with an un-folded tail
#     (`snap_total > folded_count`). Bounded by the live-shard width (cadence).
# A sustained multi-grower test asserts BOTH stay bounded across many rounds — the
# watermark/`_base` state does NOT grow with total rounds/records.
# -----------------------------------------------------------------------------


@fieldwise_init
struct SegmentBoundStats(Copyable, Movable, Deinitable):
    var live_base_chunks: Int  # _base manifest chunks above _base log-start
    var live_tail_shards: Int  # source shards with un-folded tail at this instant
    var live_shard_count: Int  # total live source shards enumerated


# =============================================================================
# SegmentBaseFold[Store] — the PRODUCTION broker segment `_base` fold.
# =============================================================================


struct SegmentBaseFold[Store: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """The PRODUCTION broker fold: MATERIALIZE the live un-folded tail of every
    source sub-lineage into the SEGMENT `_base` broker manifest (reusing the
    source `.seg` objects), then RETIRE the folded source chunks + advance each
    source shard's durable `_LOG_START` fold cursor.

    Generic over `[Store: CloneableConditionalWriteStore]`: one store handle is
    `clone()`d per sub-lineage + per `_base` access,
    so they all reach the SAME logical bucket (one bucket, N prefixes).

    The dense-offset assignment is NOT computed here — it is the SOLE product of
    the SHARED `SubLineageBaseFold.serve_assign_tail_explicit` (-> the SHARED
    `plan_assignment`), the IDENTICAL code `SubLineageConsumeResolver` calls.
    This module only DRIVES that shared plan over the broker's real segment
    manifests and PERSISTS the planned blocks into the broker `_base`.

    The three serve==fold inputs (a)/(b)/(c) AND the substrate construction (the
    `_base` / per-shard `CasManifestStore`s + the SHARED `SubLineageBaseFold` fold
    view) are owned by ONE shared `SegmentBaseInputs`: this fold
    and the consume resolver delegate to the SAME `SegmentBaseInputs` code, so
    serve==fold is STRUCTURAL (single source) — not byte-identical mirrors guarded
    by tests. A divergence between fold-input and serve-input is impossible by
    construction (there is exactly one code path computing (a)/(b)/(c)).

    Ownership (by value):
      var _inputs: SegmentBaseInputs[Store] — the SINGLE source of the serve==fold
                                 (a)/(b)/(c) reads + the substrate construction,
                                 shared verbatim with `SubLineageConsumeResolver`.
                                 Owns the shared backend (cloned per shard/`_base`)
                                 and the partition base prefix
                                 (`<cluster>/_meta/topics/<topic>/<partition>`).
                                 Sub-lineages live under `<base>/_lineage/<shard>`;
                                 `_base` is `<base>/_lineage/_base`.
    """

    var _inputs: SegmentBaseInputs[Self.Store]

    def __init__(out self, var store: Self.Store, var base_prefix: String):
        self._inputs = SegmentBaseInputs[Self.Store](store^, base_prefix^)

    # -------------------------------------------------------------------------
    # substrate construction — delegate to the SHARED `SegmentBaseInputs` source.
    # -------------------------------------------------------------------------

    def _base_manifest(self) raises -> CasManifestStore[Self.Store]:
        """The SEGMENT `_base` manifest — the SHARED `SegmentBaseInputs` source
        (the SAME `_base` the consume resolver reads + this fold appends to)."""
        return self._inputs.base_manifest()

    def _shard_manifest(
        self, shard_id: String
    ) raises -> CasManifestStore[Self.Store]:
        """A writer sub-lineage's manifest — the SHARED `SegmentBaseInputs`
        source (identical key shape to the consume resolver's)."""
        return self._inputs.shard_manifest(shard_id)

    def _fold_view(self) raises -> SubLineageBaseFold[Self.Store]:
        """The SHARED `SubLineageBaseFold` canonical-merge view — the SHARED
        `SegmentBaseInputs` source (`enumerate_live_shards` / `snapshot_explicit`
        / `serve_assign_tail_explicit`, the SAME the consume resolver drives)."""
        return self._inputs.fold_view()

    # -------------------------------------------------------------------------
    # SHARED-INPUT reads — the (a)/(b)/(c) the SHARED plan consumes (SINGLE source).
    # -------------------------------------------------------------------------

    def _snapshot(self) raises -> List[ShardSnapshot]:
        """(a) The authoritative snapshot of every live source sub-lineage — the
        SHARED `SegmentBaseInputs.snapshot()` source. The IDENTICAL boundary the consume
        resolver pins (single source — serve==fold is structural)."""
        return self._inputs.snapshot()

    def _folded_counts(
        self, snap: List[ShardSnapshot]
    ) raises -> List[ShardFoldedWatermark]:
        """(b) The per-shard already-folded record counts — the SHARED
        `SegmentBaseInputs.folded_counts()` source (each source shard's durable
        `_LOG_START.log_start_offset`, the retire-advanced fold cursor THIS fold
        persists in `_retire_folded_source`). The SAME read the consume resolver uses
        (single source — the `[folded_count .. snap_total)` tail is identical)."""
        return self._inputs.folded_counts(snap)

    def _base_next_dense(self) raises -> Int64:
        """(c) The dense high-water where the un-folded tail begins — the SHARED
        `SegmentBaseInputs.base_next_dense()` source (the SEGMENT `_base` manifest's
        `next_offset`). The SAME read the consume resolver uses (single source)."""
        return self._inputs.base_next_dense()

    # -------------------------------------------------------------------------
    # serve_plan — the SHARED plan, for direct serve==fold assertion (tests).
    # -------------------------------------------------------------------------

    def serve_plan(self) raises -> List[FoldBlockAssignment]:
        """The dense-offset assignment plan for the live un-folded tail — the SOLE
        product of the SHARED `serve_assign_tail_explicit` (-> `plan_assignment`),
        fed the IDENTICAL (a)/(b)/(c) the serve path feeds it. This is the EXACT
        plan `fold()` materializes AND the EXACT plan
        `SubLineageConsumeResolver.resolve_index` uses for its tail — they call the
        IDENTICAL code. Exposed so a test can assert serve == fold directly (the
        plan this fold persists == the plan the resolver serves)."""
        var snap = self._snapshot()
        var folded = self._folded_counts(snap)
        var dense_hw = self._base_next_dense()
        var fold = self._fold_view()
        var plan = fold.serve_assign_tail_explicit(
            snap.copy(), folded^, dense_hw
        )
        _ = fold^
        return plan^

    # -------------------------------------------------------------------------
    # run_once — the production fold entry point a cadence trigger calls.
    # -------------------------------------------------------------------------

    def run_once(mut self, now_ms: Int64) raises -> SegmentFoldStats:
        """Snapshot the live source sub-lineages at a boundary, run the SHARED
        plan, MATERIALIZE each planned block into the SEGMENT `_base` (reusing the
        source `.seg` objects in dense order), then RETIRE the folded source
        chunks + advance each source `_LOG_START` fold cursor.

        `now_ms` is the caller's wall clock (ms) — passed in (not read here) so the
        fold stays clock-source-agnostic and deterministically testable (it is the
        tombstone schedule timestamp the existing grace-gated reaper reads).

        DETERMINISM: the only ordering input is the SHARED `plan_assignment`
        over the canonical-sorted snapshot. ADDITIVITY: the plan folds
        ONLY `[folded_count .. snap_total)` per shard; a record already in `_base`
        keeps its dense offset — the fold APPENDS new `_base` chunks, NEVER
        renumbers. SERVE==FOLD: the plan is the IDENTICAL bytes the serve path
        assigns (same shared inputs + same shared code)."""
        var snap = self._snapshot()
        var folded = self._folded_counts(snap)
        var dense_hw = self._base_next_dense()
        var fold_view = self._fold_view()
        # SHARED ASSIGNMENT — the SOLE assignment authority (no second path).
        var plan = fold_view.serve_assign_tail_explicit(
            snap.copy(), folded.copy(), dense_hw
        )
        _ = fold_view^

        var records_folded = Int64(0)
        var chunks_appended = 0
        var source_retired = 0
        # MATERIALIZE the plan into `_base` in dense order. One `_base` manifest
        # chunk per intersecting source chunk (reusing the source `.seg` object).
        var base = self._base_manifest()
        var expected_dense = dense_hw
        for i in range(len(plan)):
            ref blk = plan[i]
            chunks_appended += self._materialize_block(
                base, blk, expected_dense
            )
            expected_dense += blk.count
            records_folded += blk.count
        _ = base^

        # RETIRE the now-folded source chunks + advance each source `_LOG_START`,
        # for EVERY snapshot shard, not only the shards in this round's plan: a
        # shard whose earlier retire advance failed (it is swallowed) is fully
        # folded by `_base`'s anchor, so it is in no plan again, and only this
        # loop moves its cursor. Its watermark is the folded count, raised by
        # any block this round folded from it. A shard already at its watermark
        # costs one `_LOG_START` read.
        for i in range(len(snap)):
            var watermark = folded[i].folded_count
            for j in range(len(plan)):
                ref blk = plan[j]
                if blk.shard_id == snap[i].shard_id:
                    var hi = blk.source_local_base + blk.count
                    if hi > watermark:
                        watermark = hi
            source_retired += self._retire_folded_source(
                snap[i].shard_id, watermark, now_ms
            )

        return SegmentFoldStats(
            dense_high_water=dense_hw + records_folded,
            records_folded=records_folded,
            live_shard_count=len(snap),
            base_chunks_appended=chunks_appended,
            source_chunks_retired=source_retired,
        )

    # -------------------------------------------------------------------------
    # MATERIALIZE — record ONE planned block's source chunks into `_base`.
    # -------------------------------------------------------------------------

    def _materialize_block(
        self,
        mut base: CasManifestStore[Self.Store],
        blk: FoldBlockAssignment,
        block_dense_base: Int64,
    ) raises -> Int:
        """MATERIALIZE ONE planned tail block into the SEGMENT `_base` manifest by
        REUSING the EXISTING source `.seg` objects — NO byte copy. The block covers
        source shard `blk.shard_id`'s local offsets `[blk.source_local_base ..
        blk.source_local_base + blk.count)`, assigned dense offsets
        `[block_dense_base .. block_dense_base + blk.count)`. Walk the source
        sub-lineage's chunks intersecting the block's source-local range; for each,
        re-record its `ManifestBody` (the SAME `object_key` / `record_count` /
        `crc32` — pointing at the SAME `.seg` object that already holds the
        records) as a `_base` manifest chunk, appended in dense order via
        single-writer If-None-Match CAS.

        A block's source-local range ALWAYS starts at a CHUNK BOUNDARY (the fold's
        `folded_count` advances to a snapshot's `next_offset` == the sum of
        whole-chunk `record_count`s — the offset allocator commits whole chunks),
        so `blk.source_local_base` coincides with a chunk's `chunk_lo` and each
        intersecting chunk is materialized WHOLE. This mirrors
        `SubLineageConsumeResolver._append_block_segments` EXACTLY (same walk, same
        whole-chunk emission) — the fold PERSISTS what the serve path SERVES.

        Each `_base` append ASSERTS `base_offset == running dense high-water` AND
        `last_offset == base + count - 1` (contiguity) — a divergence is a torn
        fold and RAISES rather than persisting a wrong dense binding. The `_base`
        manifest body carries the SOURCE chunk's `crc32`, so a `_base`-read CRC
        cross-check (the existing `ConsumeCore.read_segment` footer check) still
        fail-louds on a corrupt reused segment. Returns the number of `_base`
        chunks appended for this block."""
        var shard = self._shard_manifest(blk.shard_id)
        var head = shard.read_head_authoritative()
        var n_chunks = head.chunk_seq + Int64(1)
        var ls = shard.read_log_start()
        var blk_lo = blk.source_local_base
        var blk_hi = blk.source_local_base + blk.count  # exclusive
        var running = ls.log_start_offset  # source-local base of the first chunk
        var seq = ls.log_start_seq if ls.log_start_seq >= Int64(0) else Int64(0)
        var appended = 0
        var dense_cursor = block_dense_base
        while seq < n_chunks:
            try:
                var body_bytes = shard.read_chunk(seq)
                var body = ManifestBody.decode(body_bytes)
                # A chunk without a segment object (a marker, 0 records) is
                # skipped. One that still carries records cannot be re-recorded
                # (its key is empty) nor dropped (the dense offsets of every
                # later chunk would shift), so the fold refuses it.
                if not body.has_segment():
                    if body.record_count > Int64(0):
                        _ = shard^
                        raise Error(
                            "SegmentBaseFold._materialize_block: source chunk "
                            + String(seq)
                            + " has "
                            + String(body.record_count)
                            + " records but no segment object (empty"
                            " object_key); refusing to fold it"
                        )
                    seq += Int64(1)
                    continue
                var rc = body.record_count
                var chunk_lo = running
                var chunk_hi = running + rc  # exclusive source-local end
                # Does this chunk intersect the block's source-local range?
                if chunk_hi > blk_lo and chunk_lo < blk_hi:
                    # The in-block portion (whole chunk in the common case;
                    # `blk_lo`/`blk_hi` fall on chunk boundaries — the clamp is the
                    # defensive straddle guard, mirroring the consume resolver).
                    var in_lo = chunk_lo if chunk_lo > blk_lo else blk_lo
                    var in_hi = chunk_hi if chunk_hi < blk_hi else blk_hi
                    var in_count = in_hi - in_lo
                    # Re-record the SOURCE chunk's segment metadata into `_base`,
                    # REUSING the source `.seg` object_key (NO byte copy). Copy the
                    # heap-owning `object_key` (Mojo 1.0.0b1 rejects a single-field
                    # `^`-move out of `body`).
                    var key = String(body.object_key)
                    var crc = body.crc32
                    var seg_bytes = body.segment_bytes
                    var created = body.creation_ts_ms
                    # CARRY THE PRODUCER + TXN TRAILERS
                    # into `_base`. The fold MATERIALIZES a folded source chunk by
                    # re-recording its `ManifestBody` in dense order; it MUST
                    # preserve the producer-sequence trailer (`producer_id` /
                    # `producer_epoch` / `first_seq` / `last_seq`) AND the
                    # transaction trailer (`marker_type` / `txn_id`) so that AFTER
                    # the fold the `_base` chunk is still self-describing for:
                    #   * read_committed — `marker_type` / `txn_id` /
                    #     `producer_epoch` are exactly the chunk_txn_tags
                    #     `fetch_read_committed` reads to decide a folded chunk's
                    #     visibility + the epoch-equality fence. Dropping
                    #     them would make every folded txn-open / aborted chunk look
                    #     non-transactional -> read_committed would EXPOSE aborted
                    #     rows ACROSS a fold.
                    #   * idempotent-producer recovery — `producer_id` / `last_seq`
                    #     are what `recover_last_committed_seq`
                    #     scans in the folded `_base` to recover a producer's last
                    #     committed sequence after its source tail folds away.
                    # The clamp NEVER straddles a chunk (a block starts on a chunk
                    # boundary — see the docstring), so `in_count == rc` and the
                    # whole chunk's trailer applies verbatim; the defensive partial
                    # case re-records the SAME trailer for the in-block prefix
                    # (correct: a sub-chunk of a txn-open / idempotent chunk shares
                    # the parent chunk's producer + txn identity).
                    var producer_id = body.producer_id
                    var producer_epoch = body.producer_epoch
                    var first_seq = body.first_seq
                    var last_seq = body.last_seq
                    var marker_type = body.marker_type
                    var txn_id = String(body.txn_id)
                    var base_body = encode_manifest_body(
                        object_key=key^,
                        record_count=in_count,
                        crc32=crc,
                        segment_bytes=seg_bytes,
                        creation_ts_ms=created,
                        producer_id=producer_id,
                        producer_epoch=producer_epoch,
                        first_seq=first_seq,
                        last_seq=last_seq,
                        marker_type=marker_type,
                        txn_id=txn_id^,
                    )
                    var r = base.append(base_body^, in_count)
                    if r.base_offset != dense_cursor:
                        _ = shard^
                        raise Error(
                            "SegmentBaseFold._materialize_block: `_base`"
                            " base_offset "
                            + String(r.base_offset)
                            + " != fold high-water "
                            + String(dense_cursor)
                            + " (torn fold)"
                        )
                    if r.last_offset != r.base_offset + in_count - Int64(1):
                        _ = shard^
                        raise Error(  # cov: unreachable CasManifestStore.append returns last_offset = base_offset + record_count - 1
                            "SegmentBaseFold._materialize_block: `_base`"  # cov: unreachable see the line above
                            " last_offset "
                            + String(r.last_offset)  # cov: unreachable see the line above
                            + " != base+count-1 "  # cov: unreachable see the line above
                            + String(r.base_offset + in_count - Int64(1))  # cov: unreachable see the line above
                            + " (manifest non-contiguity)"  # cov: unreachable see the line above
                        )
                    dense_cursor += in_count
                    appended += 1
                running = chunk_hi
                seq += Int64(1)
            except e:
                if _is_not_found_msg(String(e)):
                    seq += Int64(1)
                    continue  # reaped mid-walk (benign race) — skip
                raise e^
        _ = shard^
        return appended

    # -------------------------------------------------------------------------
    # RETIRE — tombstone the folded source chunks + advance the durable cursor.
    # -------------------------------------------------------------------------

    def _retire_folded_source(
        mut self,
        shard_id: String,
        folded_through_total: Int64,
        now_ms: Int64,
    ) raises -> Int:
        """RETIRE the source-shard chunks whose records are now FULLY folded into
        `_base` (every chunk whose entire local range is below
        `folded_through_total`) with MOVED markers
        (`schedule_moved_for_delete_at`): `_base`
        re-recorded their `.seg` objects, so a grace-gated `ReapWorker` over the
        shard reclaims the chunk keys and never the segments (a partially-folded
        chunk past the snapshot boundary is left live). Then advance the source
        shard's `_LOG_START` to `folded_through_total` (the first still-UN-folded
        local offset). No in-tree caller runs a reaper over a shard prefix
        today; the MOVED markers keep one that does off `_base`'s data.

        Every chunk the walk retires gets its MOVED marker (re)written at
        `now_ms`, including one that already carries a marker (left by a
        failed advance, or a plain retention tombstone), so the grace window
        counts from this retire. The return value counts only chunks that
        carried no marker of either kind.

        Nothing to do when `folded_through_total` is at or below the shard's
        `_LOG_START` offset (the steady state of a shard this round did not
        fold): returns 0 after one `_LOG_START` read, writing nothing.

        That `_LOG_START` pointer IS the durable per-shard fold cursor — the
        monotone-forward cursor the serve path reads for `folded_counts` (via
        `SubLineageConsumeResolver._folded_counts` -> `read_log_start`). It
        survives `_base` retention reaping, so a fold-process restart recovers
        `folded_count` from the SOURCE shard's `_LOG_START`, not from the
        (possibly-reaped) `_base` blocks. The retire-then-advance is the SAME
        retention semantics a single-manifest partition uses. Raw retention-key
        arithmetic stays INSIDE the substrate. Returns the number of source chunks
        newly tombstoned this call. `now_ms` is recorded as the tombstone
        schedule ts (the grace-gated reaper reads it)."""
        var s = self._shard_manifest(shard_id)
        var cur = s.read_log_start()
        if folded_through_total <= cur.log_start_offset:
            _ = s^
            return 0  # the cursor is already there: nothing to retire
        var head: ManifestHead
        try:
            head = s.read_head_authoritative()
        except e:
            _ = s^
            if not _is_not_found_msg(String(e)):
                raise e^
            return 0  # the shard manifest is gone: nothing to retire
        var already_tomb = s.tombstone_seqs()
        var running = cur.log_start_offset
        var seq = cur.log_start_seq if cur.log_start_seq >= Int64(0) else Int64(0)
        var first_unfolded_seq = head.chunk_seq + Int64(1)
        var found_unfolded = False
        var retired = 0
        var to_tomb = List[Int64]()
        while seq <= head.chunk_seq:
            # The walk starts AT the log start, so every chunk it reads is
            # live: ANY read error (not_found included) is raised. Taking it
            # for a reaped chunk would skip a live chunk's records and
            # renumber the log. The whole walk runs before any tombstone or
            # advance, so a failed read changes nothing.
            var body = ManifestBody.decode(s.read_chunk(seq))
            var rc = body.record_count
            var chunk_hi = running + rc  # exclusive local end
            # Fully folded iff the chunk's entire range is <= the folded watermark.
            if chunk_hi <= folded_through_total:
                to_tomb.append(seq)
            elif not found_unfolded:
                first_unfolded_seq = seq
                found_unfolded = True
            running = chunk_hi
            seq += Int64(1)
        for t in range(len(to_tomb)):
            s.schedule_moved_for_delete_at(to_tomb[t], now_ms)
            if not _i64_in(already_tomb, to_tomb[t]):
                retired += 1
        # Advance the durable source `_LOG_START` to the folded watermark (the
        # first un-folded local offset == `folded_through_total`, at the first
        # surviving chunk seq). Monotone-forward; a stale 412 is a harmless lose
        # (a concurrent advance won — the pointer is monotone-forward).
        # A swallowed failure deletes nothing live: the tombstones above then
        # sit on chunks at or above `_LOG_START`, which `CasManifestStore.reap`
        # refuses and the broker `ReapWorker` skips (chunk_reclaim_guard.mojo),
        # and the next call re-reads `_LOG_START`, re-stamps them and
        # re-advances. Once the advance lands a reaper reclaims their chunk
        # keys; the MOVED markers keep it off the `.seg` objects `_base` reads.
        if folded_through_total > cur.log_start_offset:
            try:
                _ = s.advance_log_start(
                    first_unfolded_seq, folded_through_total, cur.etag
                )
            except e3:
                _ = e3
        _ = s^
        return retired

    # -------------------------------------------------------------------------
    # demand-driven cadence — bound the live-lineage width L (`should_fold`).
    # -------------------------------------------------------------------------

    def should_fold(
        self,
        live_shard_threshold: Int,
        ms_since_last_fold: Int64,
        timer_interval_ms: Int64,
    ) raises -> Bool:
        """Cadence trigger: fold when the live source-lineage count exceeds
        `live_shard_threshold` (a few tens per hot partition) OR the timer elapsed
        (`ms_since_last_fold >= timer_interval_ms` AND there is live work). Bounds
        the live-lineage width so consume-side fan-out stays small. Delegates
        to the SHARED `SubLineageBaseFold.should_fold` (the SAME enumeration +
        threshold logic the abstract model uses) — no second cadence path."""
        var fold = self._fold_view()
        var trip = fold.should_fold(
            live_shard_threshold, ms_since_last_fold, timer_interval_ms
        )
        _ = fold^
        return trip

    # -------------------------------------------------------------------------
    # bound observability — the bound / sustained-interleave probes.
    # -------------------------------------------------------------------------

    def bound_stats(self) raises -> SegmentBoundStats:
        """The persistent-resolution-state bound: live `_base` manifest chunks
        (above `_base` log-start) + distinct source shards with a live un-folded
        tail + total live source shards. A sustained-interleave test asserts BOTH
        bounded components stay O(live-shard-width) / retention-managed — NOT N x
        rounds (the old growing-map NO-GO)."""
        # live `_base` chunks above log-start.
        var base = self._base_manifest()
        var live_base = 0
        try:
            var head = base.read_head_authoritative()
            var ls = base.read_log_start()
            live_base = Int(head.chunk_seq + Int64(1) - ls.log_start_seq)
            if live_base < 0:
                live_base = 0
        except e:
            _ = e  # no `_base` yet -> 0 live folded chunks
        _ = base^
        # live source shards + those with an un-folded tail.
        var snap = self._snapshot()
        var folded = self._folded_counts(snap)
        var live_tail = 0
        for i in range(len(snap)):
            ref ss = snap[i]
            var already = _folded_count_in(folded, ss.shard_id)
            if ss.snap_record_total > already:
                live_tail += 1
        return SegmentBoundStats(
            live_base_chunks=live_base,
            live_tail_shards=live_tail,
            live_shard_count=len(snap),
        )


# =============================================================================
# Free-function helpers (mirror the abstract-model and resolver helpers — same key/list semantics).
# =============================================================================


@always_inline
def _folded_count_in(
    folded_counts: List[ShardFoldedWatermark], shard_id: String
) -> Int64:
    """How many of `shard_id`'s source locals are already folded, from the BOUNDED
    watermark list (O(distinct shards)). 0 if absent."""
    for i in range(len(folded_counts)):
        ref w = folded_counts[i]
        if w.shard_id == shard_id:
            return w.folded_count
    return Int64(0)


def _i64_in(xs: List[Int64], v: Int64) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


@always_inline
def _is_not_found_msg(msg: String) -> Bool:
    """Classify a not-found / 404 store error (the reaped-chunk race in a walk).
    Mirrors `consume_core._is_not_found_msg` + `sublineage_consume._is_not_found_msg`."""
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )

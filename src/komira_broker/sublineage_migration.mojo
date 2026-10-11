# =============================================================================
# komira_broker/sublineage_migration.mojo
#   The MIGRATION / GENERATION-BOUNDARY HANDOFF: flips one partition from the
#   LEGACY single-manifest write path (gen N) onto the sub-lineage write path
#   (gen N+1).
# =============================================================================
#
# THE PIECES THIS BUILDS ON.
# ---------------------------------------------------------------------------
#   * broker_core / partition_assignment: the flag-gated per-shard segment
#     sub-lineage WRITE path (`<part>/_lineage/<shard>`), with a
#     generation-tagged shard_id minted under the lease fence. DEFAULT OFF.
#   * sublineage_consume: `SubLineageConsumeResolver` reads the segment
#     `_base` BY OFFSET + serve-merges the live sub-lineage tail into ONE
#     contiguous dense index.
#   * sublineage_segment_fold: `SegmentBaseFold` MATERIALIZES the live
#     un-folded tail of the source sub-lineages into the segment `_base` (reusing
#     the `.seg` objects), retires the source, advances the durable `_LOG_START`
#     fold cursor.
#   * THIS FILE: the MIGRATION HANDOFF — establish `_base` FROM the EXISTING
#     legacy single manifest (so a consumer reads the old content uniformly under
#     the sub-lineage model), under the lease-generation fence so the old gen and
#     the new gen NEVER interleave their appends (interleaving == torn offsets,
#     the #1 hazard). OPT-IN: a partition migrates ONLY on an explicit trigger.
# THE MIGRATION HANDOFF (correctness core). A partition migrating from single-
# manifest (lease generation N, written at the partition base prefix `<part>`) to
# sub-lineage (lease generation N+1, written under `<part>/_lineage/<shard>`):
#
#   1. OLD gen=N QUIESCES. The control plane bumps the partition's lease
#      generation N -> N+1 (the assignment pass's generation). The bump
#      INVALIDATES the old owner's further single-manifest
#      appends: `CasManifestStore.append(writer_lease_epoch=N, current_lease_
#      epoch=N+1)` RAISES the classified `lease_fenced` error (`writer_lease_epoch
#      < current_lease_epoch -> FENCED`, with NO write). So there is AT MOST ONE
#      active generation and NO interleaving of old-gen single-manifest appends
#      with new-gen sub-lineage appends. THIS MODULE does NOT re-implement the
#      fence — it REUSES the `append` lease-fence parameters; the gen bump
#      is the control plane's, and the tests drive the fence directly to
#      prove the no-interleaving guarantee.
#
#   2. ESTABLISH `_base` FROM THE OLD SINGLE MANIFEST. The existing single
#      manifest at `<part>` is ALREADY a dense lineage (its gapless manifest
#      offset IS the dense Kafka offset — the offset-allocator invariant). We
#      MATERIALIZE its offset-bearing chunk-entries into the segment `_base`
#      (`<part>/_lineage/_base`) in EXACT EXISTING ORDER, REUSING the SAME `.seg`
#      objects (NO byte copy — same `SegmentBaseFold` materialize discipline:
#      re-record each chunk's `ManifestBody` object_key / record_count / crc32 /
#      trailers into `_base` in dense order). OFFSET-PRESERVING by construction:
#      `_base` is gapless one-block-per-chunk, and we seed the `_base` append at
#      the old manifest's `log_start_offset` and append the source chunks in
#      source seq order, so `_base.base_offset == old log_start` and every old
#      record keeps its EXACT original dense offset. The migrate ASSERTS each
#      `_base` append's base_offset == the running expected dense (== the old
#      record's original offset) AND last == base+count-1 (contiguity) — a
#      divergence is a torn migration and RAISES rather than persisting a wrong
#      dense binding. AFTER materializing, the migrate ADVANCES the OLD single
#      manifest's `_LOG_START` past the migrated range (so the legacy resolver no
#      longer serves the now-migrated prefix) AND tombstones the migrated source
#      chunks with MOVED markers (`schedule_moved_for_delete_at`: the `.seg`
#      objects stay referenced by `_base`, so the broker `ReapWorker` reclaims
#      only the legacy chunk keys; `_base`'s own retention reclaims the `.seg`
#      objects later). The MOVED marker of each chunk is written during
#      materialize, BEFORE the `_base` append that references its `.seg`. So
#      for every chunk the migration has already marked (that is, every chunk
#      `_base` references at the time of its append), no ordering of
#      retention, reaping and migration deletes its `.seg`. Retention that
#      expires a legacy chunk AHEAD of the migration cursor is not handled
#      here (komira-ai/komira#560). The retire re-stamps the markers when it
#      advances. Trade-off: a migration abandoned after marking leaves those
#      `.seg` objects unreclaimed (a leak).
#
#   3. NEW gen=N+1 mints shard_ids + appends to `<part>/_lineage/<shard>` (the
#      sub-lineage write path). Consume reads `_base` (the old content, dense,
#      persisted) + serve-merges the new sub-lineage tail — continuing DENSELY from the
#      old `next_offset` (the serve path's `dense_hw_start` == `_base.next_offset`
#      == old next_offset). A consumer reading STRAIGHT THROUGH the transition
#      sees a CONTIGUOUS, gap-free, NEVER-renumbered dense offset sequence.
#
# OPT-IN (zero default impact). Migration is OPERATOR/flag-triggered (the
# `migrate_partition` call here, driven by a `migrate_partition` control
# operation or a config), NOT auto-migrate-all. A NON-triggered partition NEVER
# calls this code -> its write path stays byte-for-byte the legacy
# single-manifest path (the sub-lineage flag is OFF for it), and its consume
# path stays `ConsumeCore.resolve_index` UNCHANGED.
#
# IDEMPOTENT / RESUMABLE. The migrate is re-runnable: it uses the `_base` head as
# its progress cursor (the next dense offset to establish), so a crash mid-migrate
# is resumed by re-calling `migrate_partition` — it re-materializes only the
# source chunks above the already-established `_base` range, and an already-
# established offset keeps its dense binding (additive, never renumbers). A fully-
# migrated partition's `migrate_partition` is a clean no-op.
#
# COMPACTION-ACROSS-SHARDS (post-migration). The CompactionWorker reads
# `_base`+live via the dual_tier / resolve_index path (
# `SubLineageConsumeResolver.resolve_index`); when compacting the `_base` range it
# tombstones the subsumed `_base` chunks; retention/reap stays `_lineage`-agnostic
# (the `_base` is a PLAIN `CasManifestStore`, so the existing retention pass reaps
# below the `_base` log-start exactly as a single-manifest partition does, and the
# per-shard sub-lineages reap below their own `_LOG_START` fold cursors). No new
# compaction machinery is needed; `SegmentBaseFold` already owns the steady-state
# fold-of-tail + retire, and `_base` retention is the existing reaper.
#
# -----------------------------------------------------------------------------
# Encapsulation / slab safety.
#   * ZERO UnsafePointer in any signature; surface is value / List / POD / the
#     Movable substrate structs held by value. ZERO wildcard origins. ZERO
#     unsafe_from_address. ZERO take_pointee.
#   * The substrate (`Store` + the `<part>` single-manifest + the `_base` /
#     per-shard `CasManifestStore`s) is held / built by value; each manifest is a
#     `clone()` of the shared store reaching the SAME logical bucket. Raw key
#     arithmetic stays INSIDE this module + the substrate.
#   * Every struct here is a stack value, NOT a byte-slab element. POD
#     fields + owned `String`s only — no Movable-struct-in-byte-slab-with-heap-
#     field shape. The persisted `_base` chunk bodies are `ManifestBody` (the
#     broker manifest opaque-body contract).
# =============================================================================

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
    RetryPolicy,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.sublineage_base_fold import BASE_SHARD_ID

from .chunk_walk import is_not_found_msg
from .manifest_body import ManifestBody, encode_manifest_body
from .partition_assignment import sublineage_prefix


# =============================================================================
# MigrationStats — what one migration handoff did (observability + assertions).
# =============================================================================


@fieldwise_init
struct MigrationStats(Copyable, Movable, Deinitable):
    """What ONE `migrate_partition` handoff did.

    Field layout:
      var base_offset_start: Int64  — the dense offset the established `_base`
                                      prefix begins at (== the old single
                                      manifest's `log_start_offset`). The
                                      offset-preservation anchor.
      var records_migrated: Int64   — old single-manifest records materialized
                                      into `_base` by THIS call (0 = no-op /
                                      already migrated).
      var base_chunks_appended: Int — `_base` manifest chunks this call appended
                                      (one per migrated source chunk, REUSING the
                                      source `.seg` object).
      var source_chunks_retired: Int — old single-manifest chunks newly
                                      tombstoned this call, with a MOVED
                                      marker (the manifest chunks; the `.seg`
                                      objects stay referenced by `_base`).
      var dense_high_water: Int64   — the dense offset the un-folded NEW-gen tail
                                      will begin at (== `_base.next_offset` after
                                      this call == old single manifest's
                                      `next_offset`). The new sub-lineage writes
                                      continue DENSELY from here.
      var already_migrated: Bool    — True when the partition was ALREADY fully
                                      migrated (a clean idempotent no-op).
    """

    var base_offset_start: Int64
    var records_migrated: Int64
    var base_chunks_appended: Int
    var source_chunks_retired: Int
    var dense_high_water: Int64
    var already_migrated: Bool


# =============================================================================
# SubLineageMigration[Store] — the single-manifest -> sub-lineage handoff.
# =============================================================================


struct SubLineageMigration[Store: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """The migration handoff: establish the segment `_base`
    (`<part>/_lineage/_base`) FROM the EXISTING legacy single manifest at `<part>`,
    OFFSET-PRESERVING, under the lease-generation fence (so old gen N and new gen
    N+1 never interleave), then leave the partition ready for the sub-lineage
    write path + the consume resolver.

    Generic over `[Store: CloneableConditionalWriteStore]`: one store handle is
    `clone()`d per manifest access, so they all
    reach the SAME logical bucket (one bucket, N prefixes).

    Ownership (by value):
      var _store: Store        — the shared backend; cloned per manifest access.
      var _base_prefix: String — the partition's base manifest prefix
                                 (`<cluster>/_meta/topics/<topic>/<partition>`),
                                 the SAME prefix the LEGACY producer + the legacy
                                 consume use as the single manifest. Sub-lineages
                                 live under `<base>/_lineage/<shard>`; `_base` is
                                 `<base>/_lineage/_base`.

    The legacy single manifest lives AT `_base_prefix` itself (a plain
    `CasManifestStore[Store]` bound there) — distinct from `_base`
    (`<base>/_lineage/_base`) and from the per-shard sub-lineages
    (`<base>/_lineage/<shard>`). The migrate reads the legacy single manifest +
    materializes its chunk-entries into `_base`.
    """

    var _store: Self.Store
    var _base_prefix: String

    def __init__(out self, var store: Self.Store, var base_prefix: String):
        self._store = store^
        self._base_prefix = base_prefix^

    # -------------------------------------------------------------------------
    # substrate construction — the legacy single manifest + the `_base` manifest.
    # -------------------------------------------------------------------------

    def _legacy_manifest(self) raises -> CasManifestStore[Self.Store]:
        """A `CasManifestStore` bound to the LEGACY single-manifest prefix (the
        partition base prefix `<base_prefix>` itself — where the pre-migration
        producer + the legacy `ConsumeCore` read/write). This is the dense source
        lineage the migrate establishes `_base` from. Not opted in to the
        reaped-slot guard: the migration only reads, retires and advances the
        legacy manifest, never appends to it (the producer's `BrokerCore`
        handle, which appends, is opted in)."""
        return CasManifestStore[Self.Store](
            self._store.clone(),
            String(self._base_prefix),
            RetryPolicy.fast_test(),
        )

    def _base_manifest(self) raises -> CasManifestStore[Self.Store]:
        """A `CasManifestStore` bound to the SEGMENT `_base` fold lineage prefix
        (`<base_prefix>/_lineage/_base`), backed by a clone of the shared store.
        Identical key shape to `SubLineageConsumeResolver._base_manifest` +
        `SegmentBaseFold._base_manifest` — the SAME `_base` the consume resolver
        reads + the segment fold appends to. Opted in to the reaped-slot
        guard (#486)."""
        var m = CasManifestStore[Self.Store](
            self._store.clone(),
            sublineage_prefix(self._base_prefix, BASE_SHARD_ID),
            RetryPolicy.fast_test(),
        )
        m.enable_reaped_slot_guard()
        return m^

    # -------------------------------------------------------------------------
    # is_migrated — has this partition been flipped onto sub-lineage already?
    # -------------------------------------------------------------------------

    def has_base(self) raises -> Bool:
        """True iff a segment `_base` exists for this partition (the migration has
        established at least the first dense chunk). Mirrors
        `SubLineageConsumeResolver.has_base` — the routing layer uses this to
        decide between the legacy resolve and the sub-lineage resolve. A partition
        with no `_base` (never migrated, never folded) takes the legacy path
        UNCHANGED (backward-compat). An absent `_base` reads as chunk_seq -1;
        an error reading its head raises."""
        var base = self._base_manifest()
        var head = base.read_head_authoritative()
        _ = base^
        return head.chunk_seq >= Int64(0)

    def _base_next_dense(self) raises -> Int64:
        """The dense high-water the established `_base` reaches (== `_base`'s
        `next_offset`; the offset allocator invariant: the manifest's next base
        offset == the cumulative committed record count == the dense high-water).
        The migrate resumes materializing source chunks starting at HERE (so a
        crash mid-migrate is resumed additively). Empty `_base` -> 0.

        OFFSET-PRESERVATION ANCHOR: when `_base` is empty, the FIRST `_base`
        append seeds at the OLD manifest's `log_start_offset` (see
        `migrate_partition`), so `_base.base_offset == old log_start`. Once
        established, this returns the running dense high-water the next source
        chunk must continue from. An error reading `_base`'s head raises: it
        is not an empty `_base`, and reading it as one would re-record legacy
        chunks over the dense offsets `_base` already holds."""
        var base = self._base_manifest()
        var head = base.read_head_authoritative()
        _ = base^
        return head.next_offset

    # -------------------------------------------------------------------------
    # migrate_partition — the OPT-IN handoff entry point a trigger calls.
    # -------------------------------------------------------------------------

    def migrate_partition(mut self, now_ms: Int64) raises -> MigrationStats:
        """Establish the segment `_base` FROM the legacy single manifest at
        `<part>`, OFFSET-PRESERVING + idempotent, then retire the migrated legacy
        chunks. THE OPT-IN trigger: a partition migrates ONLY when this is called
        (an operator `migrate_partition` operation or a config flip). A NON-
        triggered partition never reaches this code -> stays the legacy path.

        PRE-CONDITION (the no-interleaving guarantee, enforced by the CALLER via
        the lease fence): the control plane MUST bump the partition's lease
        generation N -> N+1 BEFORE migrate_partition runs, so the old owner's
        further single-manifest appends are FENCED (`writer_lease_epoch=N <
        current_lease_epoch=N+1 -> lease_fenced`, NO write). This module does NOT
        bump the generation (that is the control-plane assignment pass's job);
        it ESTABLISHES `_base` from the now-quiesced legacy manifest. A
        migrate that ran while the old owner was STILL appending (no gen bump)
        could race the legacy tail — which is exactly why the gen bump is the
        pre-condition and the fence is the enforcement (the tests drive the
        fence directly to prove an old-gen append after the bump is rejected).

        `now_ms` is the caller's wall clock (ms) — passed in (not read here) so the
        migrate stays clock-source-agnostic + deterministically testable (it is the
        tombstone schedule ts the existing grace-gated reaper reads).

        Steps:
          1. Read the legacy single manifest's authoritative head + log-start.
             An ABSENT / empty legacy manifest (nothing ever produced) is a clean
             no-op (records_migrated 0) — the partition is ready for new-gen writes
             with an empty `_base` (the whole partition is then the serve-merged
             new-gen tail, dense from 0).
          2. Resume from the established `_base` head: `expected_dense` ==
             `_base.next_offset` (0 for a fresh `_base`, anchored to the old
             log_start by the first append). Walk the legacy chunks whose dense
             range is AT OR ABOVE `expected_dense`, from the legacy log start
             (skip already-migrated; a chunk that cannot be read raises); for
             each offset-bearing chunk, re-record its `ManifestBody`
             (REUSING the source `.seg` object_key / record_count / crc32 /
             trailers) into `_base` in dense order via single-writer If-None-Match
             CAS, writing the chunk's MOVED marker on the legacy manifest just
             before its `_base` append. ASSERT `_base` base_offset == `expected_dense` (== the old
             record's ORIGINAL dense offset) AND last == base+count-1 — a
             divergence is a torn migration and RAISES.
          3. RETIRE: advance the OLD single manifest's `_LOG_START` past the
             migrated range (the legacy resolver no longer serves the migrated
             prefix) AND retire the migrated source MANIFEST chunks with MOVED
             markers (the `.seg` objects stay referenced by `_base`; the
             `ReapWorker` reclaims only the chunk keys, under grace). The
             `_LOG_START` advance is the durable migration cursor.

        OFFSET-PRESERVING (the production-flip correctness): `_base` is gapless
        one-block-per-chunk; the first established chunk seeds at the old
        `log_start_offset`; each subsequent chunk continues from the running dense
        high-water == the old record's original offset. So a consumer reads the
        SAME record at the SAME dense offset before + after migration; the new-gen
        tail then continues densely from `_base.next_offset` == old `next_offset`."""
        var legacy = self._legacy_manifest()
        # No legacy manifest at all (never produced) reads as chunk_seq -1, and
        # the walk below migrates nothing. An error reading the head raises.
        var legacy_head = legacy.read_head_authoritative()
        var n_legacy_chunks = legacy_head.chunk_seq + Int64(1)  # -1 = empty
        var legacy_ls = legacy.read_log_start()
        var legacy_log_start_off = legacy_ls.log_start_offset
        var legacy_next = legacy_head.next_offset

        # The dense high-water the established `_base` already reaches (the resume
        # cursor). Empty `_base` -> 0; the FIRST append then seeds at the old
        # log_start (the offset-preservation anchor — see below).
        var base_next = self._base_next_dense()

        # Where the established `_base` BEGINS (the offset-preservation anchor):
        # the old single manifest's `log_start_offset`. When `_base` is empty we
        # MUST seed the first `_base` append at THIS offset so the survivor range
        # keeps its CORRECT absolute dense offsets (post-retention, the old
        # log_start can be > 0 — never re-base to 0).
        var base_offset_start = (
            base_next if base_next > Int64(0) else legacy_log_start_off
        )

        # ALREADY FULLY MIGRATED (idempotent no-op): the established `_base`
        # already reaches the legacy `next_offset` (every legacy record is in
        # `_base`). Re-running is a clean no-op (no double-append, no renumber).
        # It still runs the RETIRE walk up to the legacy `next_offset`: a
        # previous call whose legacy `_LOG_START` advance failed (it is
        # swallowed) left the legacy cursor behind, and only this walk moves
        # it, re-stamping the MOVED markers on the way (idempotent and
        # monotone). `_base` may already hold new-gen records past
        # `legacy_next`, so the walk stops at `legacy_next`, never `base_next`.
        if base_next >= legacy_next and base_next > Int64(0):
            var restamped = self._retire_migrated_legacy(
                legacy, legacy_next, now_ms
            )
            _ = legacy^
            return MigrationStats(
                base_offset_start=base_offset_start,
                records_migrated=Int64(0),
                base_chunks_appended=0,
                source_chunks_retired=restamped,
                dense_high_water=base_next,
                already_migrated=True,
            )

        # The dense offset the NEXT `_base` chunk must occupy (== the old record's
        # original dense offset). For a fresh `_base` this is the old log_start;
        # for a resumed migrate it is the running `_base` high-water.
        var expected_dense = base_offset_start

        var base = self._base_manifest()

        # OFFSET-PRESERVATION ANCHOR (the production-flip correctness). A FRESH
        # `_base` manifest's offset allocator begins at 0 (its `read_head`
        # next_offset is 0). When the old single manifest's `log_start_offset` is
        # > 0 (the head was retention-reaped before the migration), we MUST seed
        # `_base`'s offset allocator at THAT old log_start so the FIRST `_base`
        # append's base_offset == the old record's ORIGINAL absolute dense offset
        # (NOT re-based to 0 — re-basing is the torn-offset bug the migrate
        # forbids). We seed by writing `_base`'s `_LOG_START` to `(seq=0,
        # offset=base_offset_start)` BEFORE the first append; `read_head` then
        # recovers next_offset == base_offset_start (the offset allocator
        # invariant, `_recover_head_by_list` seeds from `_LOG_START`). Only for a
        # fresh `_base` (`base_next == 0`) with a non-zero anchor — a resumed
        # migrate already has the allocator at its running high-water.
        if base_next == Int64(0) and base_offset_start > Int64(0):
            var bls = base.read_log_start()
            try:
                _ = base.advance_log_start(
                    Int64(0), base_offset_start, bls.etag
                )
            except e_seed:
                _ = e_seed  # a concurrent migrate seeded it — monotone-forward

        # The legacy chunks marked BEFORE this call: the materialize below
        # marks every chunk it appends, so the retire counts "newly retired"
        # against this list, not against its own marks.
        var marked_before = legacy.tombstone_seqs()
        var records_migrated = Int64(0)
        var chunks_appended = 0
        # Walk the legacy chunks in seq order, seeding the running source dense
        # offset from the legacy log_start (the offset allocator invariant: live
        # chunk seq `k` occupies `[running, running + count - 1]`).
        var running = legacy_log_start_off
        var seq = (
            legacy_ls.log_start_seq if legacy_ls.log_start_seq >= Int64(0)
            else Int64(0)
        )
        while seq < n_legacy_chunks:
            # The walk starts AT the legacy log start, so every chunk it reads
            # is live: ANY read error (not_found included) is raised and
            # nothing further is migrated. Skipping a chunk would record every
            # later chunk at a dense offset too low by its record_count; the
            # chunks already in `_base` stay, and a re-run resumes after them.
            var body_bytes = legacy.read_chunk(seq)
            var body = ManifestBody.decode(body_bytes)
            # A chunk without a segment object (a COMMIT/ABORT marker, 0
            # records) is skipped (it is NOT offset-bearing; the legacy
            # resolver skips it too). One that still carries records cannot
            # be re-recorded (its key is empty) nor dropped (every later
            # dense offset would shift), so the migration refuses it.
            if not body.has_segment():
                if body.record_count > Int64(0):
                    _ = base^
                    _ = legacy^
                    raise Error(
                        "SubLineageMigration.migrate_partition: legacy chunk "
                        + String(seq)
                        + " has "
                        + String(body.record_count)
                        + " records but no segment object (empty"
                        " object_key); refusing to migrate it"
                    )
                seq += Int64(1)
                continue
            var rc = body.record_count
            var chunk_lo = running  # this chunk's first dense offset
            # Skip chunks ENTIRELY below the resume cursor (already migrated):
            # the offset allocator commits whole chunks, so `expected_dense`
            # always coincides with a chunk boundary; a chunk wholly below it
            # is already in `_base`.
            if chunk_lo + rc <= expected_dense:
                running = chunk_lo + rc
                seq += Int64(1)
                continue
            # This chunk's first dense offset MUST equal the running expected
            # dense (whole-chunk migration, chunk-boundary aligned). A mismatch
            # is a torn / non-contiguous migration -> RAISE.
            if chunk_lo != expected_dense:
                _ = base^
                _ = legacy^
                raise Error(
                    "SubLineageMigration.migrate_partition: source chunk dense"
                    " base "
                    + String(chunk_lo)
                    + " != expected dense "
                    + String(expected_dense)
                    + " (non-contiguous migration — torn offsets)"
                )
            # Re-record the SOURCE chunk's segment metadata into `_base`,
            # REUSING the source `.seg` object_key (NO byte copy). Copy the
            # heap-owning `object_key` (Mojo 1.0.0b1 rejects a single-field
            # `^`-move out of `body`).
            var key = String(body.object_key)
            var crc = body.crc32
            var seg_bytes = body.segment_bytes
            var created = body.creation_ts_ms
            var base_body = encode_manifest_body(
                object_key=key^,
                record_count=rc,
                crc32=crc,
                segment_bytes=seg_bytes,
                creation_ts_ms=created,
            )
            # MOVED marker FIRST, then the `_base` append that makes `_base`
            # reference this `.seg` (komira-ai/komira#494). For every chunk
            # the migration has already marked (that is, every chunk `_base`
            # references at the time of its append), no ordering of
            # retention, reaping and migration deletes its `.seg`: the
            # reaper checks MOVED first, and never touches a chunk at or
            # above the legacy floor. Retention that expires a legacy chunk
            # AHEAD of the migration cursor is not handled here
            # (komira-ai/komira#560). If the migration stops after this
            # mark and never appends, the `.seg` is kept (a leak).
            legacy.schedule_moved_for_delete_at(seq, now_ms)
            var r = base.append(base_body^, rc)
            if r.base_offset != expected_dense:
                _ = base^
                _ = legacy^
                raise Error(
                    "SubLineageMigration.migrate_partition: `_base` base_offset "
                    + String(r.base_offset)
                    + " != expected dense "
                    + String(expected_dense)
                    + " (torn migration — offset not preserved)"
                )
            if r.last_offset != r.base_offset + rc - Int64(1):
                _ = base^
                _ = legacy^
                raise Error(  # cov: unreachable CasManifestStore.append returns last_offset = base_offset + record_count - 1
                    "SubLineageMigration.migrate_partition: `_base` last_offset "  # cov: unreachable see the line above
                    + String(r.last_offset)  # cov: unreachable see the line above
                    + " != base+count-1 "  # cov: unreachable see the line above
                    + String(r.base_offset + rc - Int64(1))  # cov: unreachable see the line above
                    + " (manifest non-contiguity)"  # cov: unreachable see the line above
                )
            expected_dense += rc
            records_migrated += rc
            chunks_appended += 1
            running = chunk_lo + rc
            seq += Int64(1)
        _ = base^

        # RETIRE the migrated legacy chunks: MOVED markers on the migrated MANIFEST
        # chunks (the `.seg` objects stay referenced by `_base`, so the reaper
        # keeps them) + advance the OLD single
        # manifest's `_LOG_START` past the migrated range (so the legacy resolver
        # serves nothing below `expected_dense`). The `_LOG_START` advance is the
        # durable migration cursor (a fold-process restart resumes from it).
        var source_retired = self._retire_migrated_legacy(
            legacy, expected_dense, now_ms, Optional[List[Int64]](marked_before^)
        )
        _ = legacy^

        return MigrationStats(
            base_offset_start=base_offset_start,
            records_migrated=records_migrated,
            base_chunks_appended=chunks_appended,
            source_chunks_retired=source_retired,
            dense_high_water=expected_dense,
            already_migrated=False,
        )

    # -------------------------------------------------------------------------
    # RETIRE — tombstone the migrated legacy chunks + advance the durable cursor.
    # -------------------------------------------------------------------------

    def _retire_migrated_legacy(
        self,
        mut legacy: CasManifestStore[Self.Store],
        migrated_through_dense: Int64,
        now_ms: Int64,
        var marked_before: Optional[List[Int64]] = None,
    ) raises -> Int:
        """RETIRE the legacy single-manifest chunks whose records are now FULLY
        established in `_base` (every chunk whose entire dense range is below
        `migrated_through_dense`) with MOVED markers
        (`schedule_moved_for_delete_at`): the
        `.seg` objects stay referenced by `_base` (which reuses the SAME
        object_keys), so the grace-gated `ReapWorker` reclaims the legacy
        MANIFEST chunk keys and never the segment payloads (a partially-migrated
        chunk past the boundary is left live). Then advance the legacy
        `_LOG_START` to `migrated_through_dense` (the first still-UN-migrated
        dense offset).

        Every chunk the walk retires gets its MOVED marker (re)written at
        `now_ms`, including one that already carries a tombstone: a plain
        RetentionPass tombstone left on a live chunk by a failed advance is
        not enough on its own (the reaper would delete a `.seg` that `_base`
        reads), and the rewrite makes the grace window count from this
        advance. The return value counts only chunks that carried no marker
        of either kind before this `migrate_partition` call (`marked_before`,
        listed before materialize; when absent, the markers present now).

        The walk starts at the CURRENT legacy log start. A RetentionPass may
        have advanced it past chunks this migration materialized; those
        already carry the MOVED marker `migrate_partition` wrote before each
        `_base` append, so the reaper keeps their `.seg` whether or not this
        walk reaches them. (That covers only chunks the migration had marked;
        retention that expires a legacy chunk AHEAD of the migration cursor is
        not handled here, komira-ai/komira#560.)

        That `_LOG_START` pointer IS the durable migration cursor: the legacy
        resolver reads it for `running_base` (so it serves NOTHING below the
        migrated range — the migrated prefix is now served by `_base`), and a
        migrate-process restart resumes from it. The advance is monotone-forward;
        a stale 412 is a harmless lose (a concurrent advance won). Raw retention-key
        arithmetic stays INSIDE the substrate. Returns the number of legacy chunks
        newly tombstoned this call. `now_ms` is recorded as the tombstone schedule
        ts."""
        var head: ManifestHead
        try:
            head = legacy.read_head_authoritative()
        except e:
            if not is_not_found_msg(String(e)):
                raise e^
            return 0  # the legacy manifest is gone: nothing to retire
        # Count against the markers that predate this migration call when the
        # caller listed them (its materialize marked the rest).
        var already_tomb: List[Int64]
        if marked_before:
            already_tomb = marked_before.take()
        else:
            already_tomb = legacy.tombstone_seqs()
        var cur = legacy.read_log_start()
        var running = cur.log_start_offset
        var seq = (
            cur.log_start_seq if cur.log_start_seq >= Int64(0) else Int64(0)
        )
        var first_unmigrated_seq = head.chunk_seq + Int64(1)
        var found_unmigrated = False
        var retired = 0
        var to_tomb = List[Int64]()
        while seq <= head.chunk_seq:
            # The walk starts AT the log start, so every chunk it reads is
            # live: ANY read error (not_found included) is raised. Taking it
            # for a reaped chunk would skip a live chunk's records and
            # renumber the log. The whole walk runs before any tombstone or
            # advance, so a failed read changes nothing.
            var body = ManifestBody.decode(legacy.read_chunk(seq))
            var rc = body.record_count
            var chunk_hi = running + rc  # exclusive dense end
            # Fully migrated iff the chunk's entire dense range is <= the migrated
            # watermark.
            if chunk_hi <= migrated_through_dense:
                to_tomb.append(seq)
            elif not found_unmigrated:
                first_unmigrated_seq = seq
                found_unmigrated = True
            running = chunk_hi
            seq += Int64(1)
        for t in range(len(to_tomb)):
            legacy.schedule_moved_for_delete_at(to_tomb[t], now_ms)
            if not _i64_in(already_tomb, to_tomb[t]):
                retired += 1
        # Advance the durable legacy `_LOG_START` to the migrated watermark (the
        # first un-migrated dense offset, at the first surviving chunk seq).
        # Monotone-forward; a stale 412 is a harmless lose.
        # A swallowed failure deletes nothing live: the tombstones above then
        # sit on chunks at or above `_LOG_START`, which `CasManifestStore.reap`
        # refuses and the broker `ReapWorker` skips (chunk_reclaim_guard.mojo),
        # and the next `migrate_partition` (its `already_migrated` branch
        # included) re-reads `_LOG_START`, re-stamps them and re-advances. Once
        # the advance lands the reaper reclaims their chunk keys; the MOVED
        # markers keep it off the `.seg` objects `_base` reads.
        if migrated_through_dense > cur.log_start_offset:
            try:
                _ = legacy.advance_log_start(
                    first_unmigrated_seq, migrated_through_dense, cur.etag
                )
            except e3:
                _ = e3
        return retired


# =============================================================================
# Free-function helpers (mirror the resolver / segment-fold helpers — same list semantics).
# =============================================================================


def _i64_in(xs: List[Int64], v: Int64) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False

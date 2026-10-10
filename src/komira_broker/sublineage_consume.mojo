# =============================================================================
# komira_broker/sublineage_consume.mojo
#   The CONSUME-side dense-offset resolution under the sub-lineage model.
# =============================================================================
#
# THE MODEL (materialize+retire — the `_base` fold).
# A partition in sub-lineage mode has TWO regions of the dense Kafka offset space:
#
#   * The FOLDED region `[_base.log_start .. _base.head]`. FOLDED records live in
#     `_base` — a plain broker `CasManifestStore` over `<partition>/_lineage/_base`
#     whose gapless manifest offset IS the dense Kafka offset. Resolved by reading
#     `_base` BY OFFSET, exactly like a single-manifest partition (the existing
#     `ConsumeCore.resolve_index` offset-index logic, applied to the `_base`
#     manifest). This is the dense, PERSISTED, offset-preserving prefix.
#
#   * The LIVE UN-FOLDED TAIL `(_base.head .. tail)`. The live tail lives in the
#     per-shard write sub-lineages `<partition>/_lineage/<shard_id>` (local
#     offsets, NOT yet folded → no persisted dense offset). Its dense offsets are
#     assigned at SERVE time by the SAME canonical merge the fold uses
#     (`SubLineageBaseFold.serve_assign_tail` -> `plan_assignment`), starting at
#     `_base.head + 1`.
#
# "Merge-assigns-at-serve, fold-persists". The serve path REPRODUCES the
# fold's EXACT dense assignment for the tail because it calls the IDENTICAL
# canonical-merge code (`plan_assignment`, the SOLE assignment authority, shared
# by both `SubLineageBaseFold.fold` and `serve_assign_tail`). When the fold later
# runs over the SAME snapshot it persists the IDENTICAL assignment (determinism →
# offset-preserving → resumable). So a consumer that commits a dense offset O in
# the served tail resolves O to the SAME record after the tail folds into `_base`
# — NO TORN OFFSET.
#
# DEFAULT-OFF / backward-compat. The whole sub-lineage consume path engages ONLY
# when the caller routes through this resolver (i.e. sub-lineage mode is on AND
# `_base` exists). Legacy / flag-off partitions use `ConsumeCore.resolve_index`
# UNCHANGED — byte-for-byte. This resolver NEVER touches the legacy single-
# manifest path.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature (surface is value / List / POD / the
#     Movable substrate structs held by value).
#   * ZERO wildcard origins. ZERO unsafe_from_address. ZERO take_pointee.
#   * The substrate (`Store` + the per-shard / `_base` `CasManifestStore`s) is
#     held / built by value; each shard manifest is a `clone()` of the shared
#     store reaching the same logical bucket. Raw key arithmetic stays INSIDE
#     this module + the substrate.
#   * Every struct here is a stack value, NOT a byte-slab element. POD
#     fields + owned `String`s only — no Movable-struct-in-byte-slab shape.
# =============================================================================

from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.sublineage_base_fold import (
    FoldBlockAssignment,
    ShardFoldedWatermark,
    ShardSnapshot,
    SubLineageBaseFold,
)

from .chunk_walk import restart_point_after_failed_read
from .consume_core import SegmentRef
from .manifest_body import ManifestBody, MARKER_NONE
from .read_committed import ChunkTxnTag
from .sublineage_base_inputs import (
    FoldedCountsCache,
    SegmentBaseInputs,
    _CachedShard,
    _CachedShardChunk,
)


# =============================================================================
# SubLineageTaggedSegment — one dense SegmentRef + its transaction tag.
# =============================================================================
#
# The single-manifest
# read_committed path correlates a `ConsumeSegment` to its chunk's txn tag by
# `chunk_seq` (`KafkaDataBroker.fetch_read_committed` builds a `chunk_seq -> tag`
# map via `chunk_txn_tags`). That correlation does NOT work across the sub-lineage
# model: a dense `SegmentRef` from `_resolve_base_index` carries the `_base`
# manifest seq, while one from `_append_block_segments` carries the SOURCE shard's
# seq — the two number spaces collide. So the sub-lineage resolver carries the txn
# tag DIRECTLY on each dense segment (read from the SAME `ManifestBody` it decodes
# to build the `SegmentRef`), and the wired read_committed path filters per-segment
# by `chunk_is_visible(tag, snapshot)` — NO chunk_seq correlation.
#
# CRITICAL for the trailer-carrying fold: a FOLDED `_base` chunk's tag is read
# from the `_base` `ManifestBody`, which PRESERVES the producer + txn trailers
# (`SegmentBaseFold._materialize_block`). So a folded txn-open / aborted data
# chunk's `txn_id` + `producer_epoch` survive the fold and `chunk_is_visible`
# correctly hides it (state Abort / epoch-fence) ACROSS the fold — without the
# trailers this tag would read `txn_id == ""` (non-txn) and the row would
# wrongly become visible.
# -----------------------------------------------------------------------------


@fieldwise_init
struct SubLineageTaggedSegment(Copyable, Movable, Deinitable):
    """One dense `SegmentRef` (folded `_base` or serve-merged tail) paired with
    its transaction tag, read from the SAME `ManifestBody`. The read_committed
    consume path admits a segment's records iff `chunk_is_visible(tag, snapshot)`.

    Field layout:
      var seg: SegmentRef    — the dense offset->segment entry.
      var tag: ChunkTxnTag   — marker_type / txn_id / producer_epoch for the
                               chunk this segment came from. A non-transactional
                               data chunk has `txn_id == ""` (always visible)."""

    var seg: SegmentRef
    var tag: ChunkTxnTag


# =============================================================================
# SubLineageConsumeResolver[Store] — the dense offset->segment index for a
# sub-lineage partition (folded `_base` + serve-merged live tail).
# =============================================================================


struct SubLineageConsumeResolver[Store: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """Resolves the dense Kafka offset index for a partition under the sub-lineage
    model: the folded `_base` prefix + the serve-merged live un-folded tail.

    Generic over `[Store: CloneableConditionalWriteStore]`: one store handle is
    `clone()`d per sub-lineage + per `_base` access,
    so they all reach the SAME logical bucket (one bucket, N prefixes).

    The three serve==fold inputs (a)/(b)/(c) AND the substrate construction (the
    `_base` / per-shard `CasManifestStore`s + the SHARED `SubLineageBaseFold` fold
    view) are owned by ONE shared `SegmentBaseInputs`: this
    resolver and `SegmentBaseFold` delegate to the SAME `SegmentBaseInputs`
    code, so serve==fold is STRUCTURAL (single source) — a divergence between the
    serve-side and fold-side inputs is impossible by construction.

    Ownership (by value):
      var _inputs: SegmentBaseInputs[Store] — the SINGLE source of the serve==fold
                                 (a)/(b)/(c) reads + the substrate construction,
                                 shared verbatim with `SegmentBaseFold`. Owns the
                                 shared backend (cloned per shard/`_base`) + the
                                 partition base prefix
                                 (`<cluster>/_meta/topics/<topic>/<partition>`).
                                 Sub-lineages live under `<base>/_lineage/<shard>`;
                                 `_base` is `<base>/_lineage/_base`.
    """

    var _inputs: SegmentBaseInputs[Self.Store]

    def __init__(out self, var store: Self.Store, var base_prefix: String):
        self._inputs = SegmentBaseInputs[Self.Store](store^, base_prefix^)

    # -------------------------------------------------------------------------
    # mode detection — is this partition in sub-lineage mode with a live `_base`?
    # -------------------------------------------------------------------------

    def has_base(self) raises -> Bool:
        """True iff a `_base` fold lineage exists for this partition (sub-lineage
        mode is engaged AND at least one fold has materialized into `_base`). The
        caller uses this to decide between the sub-lineage resolve (this resolver)
        and the legacy single-manifest `ConsumeCore.resolve_index`: a partition
        with no `_base` MUST take the legacy path unchanged (backward-compat)."""
        var base = self._base_manifest()
        # An absent `_base` reads as chunk_seq -1; a read error raises.
        var head = base.read_head_authoritative()
        _ = base^
        return head.chunk_seq >= Int64(0)

    # -------------------------------------------------------------------------
    # resolve_index — the combined dense offset->segment index.
    # -------------------------------------------------------------------------

    def resolve_index(self) raises -> List[SegmentRef]:
        """The authoritative dense offset->segment index for the partition:
        the folded `_base` prefix (dense, persisted) followed by the serve-merged
        live un-folded tail (dense offsets assigned by the SHARED canonical merge,
        NOT persisted). One CONTIGUOUS dense `List[SegmentRef]` a consumer reads
        like a single manifest.

        Step 1 — FOLDED `_base` range. Read the `_base` broker manifest BY OFFSET
        (the EXACT offset-index logic `ConsumeCore.resolve_index` uses, applied to
        the `_base` prefix): walk live `_base` chunks `[log_start_seq, num_chunks)`,
        seed `running_base` from `_base`'s persisted `log_start_offset` (so the
        surviving range keeps its CORRECT absolute dense offsets after retention),
        and produce a dense `SegmentRef` per offset-bearing chunk. `_base`'s own
        gapless manifest offset IS the dense Kafka offset.

        Step 2 — SERVE-MERGED TAIL. Pin the SAME authoritative snapshot the fold
        pins (per live shard `read_head_authoritative`), run the SHARED canonical
        merge (`SubLineageBaseFold.serve_assign_tail_explicit` — the format-
        decoupled entry that reuses the IDENTICAL `_sort_snapshot` +
        `plan_assignment` the fold's `fold()` runs) to assign the tail's dense
        offsets starting at `_base.head + 1`, then map each planned block to its
        source sub-lineage's segments — each source chunk becomes a dense
        `SegmentRef` whose `base_offset` is the block's `dense_base` plus the
        chunk's position within the block. The dense assignment is BYTE-IDENTICAL
        to what the fold will persist (same snapshot, same canonical order, same
        `plan_assignment`, same `dense_hw` start), so a committed tail offset O
        resolves to the SAME record pre- and post-fold (no torn offset).

        Step 3 — combine: the `_base` index (dense `[log_start .. base_head]`)
        followed by the tail index (dense `(base_head .. tail]`) is contiguous and
        gapless by construction (the tail's dense bases START at `_base.head + 1`).
        """
        # ---- Step 1: the folded `_base` dense range (read like a manifest). ----
        # This `_base` walk ALSO captures the `_base` object_key set
        # (`base_keys`), so (b) `folded_counts` does NOT re-LIST + re-GET `_base`.
        var base_keys = List[String]()
        var index = self._resolve_base_index_capturing(base_keys)

        # ---- Step 2: the serve-merged live un-folded tail (shared merge). ------
        # The broker's `_base` is a broker manifest of SEGMENTS (not the i64
        # `_base` format), so we DRIVE the SHARED canonical merge via the format-
        # decoupled entry point `serve_assign_tail_explicit`: it reuses the
        # IDENTICAL `_sort_snapshot` + `plan_assignment` the fold runs, fed the
        # broker's own (a) authoritative snapshot of live source sub-lineages,
        # (b) per-shard folded_counts (each source shard's durable `_LOG_START` =
        # the retire-advanced fold cursor the fold persists), (c) the dense
        # high-water from the `_base` broker manifest's next dense offset. ALL
        # THREE inputs come from the SHARED `SegmentBaseInputs` source the fold
        # also uses, so serve == fold is STRUCTURAL (single source).
        var snap = self._snapshot()  # (a) the SAME boundary the fold pins
        # Walk each snapshot shard ONCE up front into a per-resolve cache,
        # reused for BOTH (b) `folded_counts_cached` AND the Step-2 block->
        # segment mapping, so each shard chunk is read once rather than twice
        # (by `folded_counts` and again by `_append_block_segments`). The
        # cached (b) is BYTE-IDENTICAL to the un-cached (b) the fold uses, so
        # serve==fold stays structural.
        var cache = self._build_folded_counts_cache(snap, base_keys^)
        var folded_counts = self._inputs.folded_counts_cached(snap, cache)  # (b)
        var dense_hw = self._base_next_dense()  # (c)
        var fold = self._fold_view()
        var plan = fold.serve_assign_tail_explicit(
            snap.copy(), folded_counts^, dense_hw
        )
        # Map each planned block to its source sub-lineage segments — FROM the
        # cached shard chunks (no re-read).
        for i in range(len(plan)):
            ref blk = plan[i]
            self._append_block_segments_cached(index, blk, cache)
        _ = fold^
        return index^

    def resolve_index_tagged(self) raises -> List[SubLineageTaggedSegment]:
        """The dense offset->segment index WITH each segment's transaction tag
        (the read_committed wiring). Identical resolution to
        `resolve_index` (folded `_base` prefix + serve-merged tail, contiguous
        dense), but each dense segment carries the `ChunkTxnTag` read from the SAME
        `ManifestBody`, so the wired `fetch_read_committed` can filter per-segment
        by `chunk_is_visible(tag, snapshot)` without any chunk_seq correlation
        (the `_base` seq + source-shard seq number spaces collide — see
        `SubLineageTaggedSegment`).

        For a FOLDED `_base` chunk the tag is read from the `_base` body, which
        PRESERVES the producer + txn trailers — so a txn-open /
        aborted chunk that folded into `_base` stays correctly tagged and
        read_committed hides it ACROSS the fold."""
        # Capture `_base` object_keys from the Step-1 walk (no re-read
        # for (b)).
        var base_keys = List[String]()
        var index = self._resolve_base_index_tagged_capturing(base_keys)
        var snap = self._snapshot()  # (a) — the SHARED `SegmentBaseInputs` source
        # One walk per snapshot shard, reused for (b) + the tagged
        # block->segment mapping (byte-identical (b) to the fold's standalone).
        var cache = self._build_folded_counts_cache(snap, base_keys^)
        var folded_counts = self._inputs.folded_counts_cached(snap, cache)  # (b)
        var dense_hw = self._base_next_dense()  # (c)
        var fold = self._fold_view()
        var plan = fold.serve_assign_tail_explicit(
            snap.copy(), folded_counts^, dense_hw
        )
        for i in range(len(plan)):
            ref blk = plan[i]
            self._append_block_segments_tagged_cached(index, blk, cache)
        _ = fold^
        return index^

    def resolve_index_uncached(self) raises -> List[SegmentRef]:
        """TEST-ONLY — the un-cached resolve path, kept as the
        explicit op-count + value baseline the win-proof test compares against.
        Byte-identical result to `resolve_index`, but it issues the REDUNDANT
        reads the cache eliminates: the un-cached `_folded_counts` (which re-LISTs
        + re-GETs `_base` via `_base_object_keys` AND re-walks every shard via
        `_base_folded_prefix`) + the un-cached `_append_block_segments` (which
        re-walks every shard a SECOND time). NOT on any production path — the
        production entry points are `resolve_index` / `resolve_index_tagged`,
        which take the cached path. This method exists so a test can measure the
        EXACT object-store op delta the cache buys and assert the value is
        identical (correctness-preserving perf)."""
        var index = self._resolve_base_index()
        var snap = self._snapshot()
        var folded_counts = self._folded_counts(snap)  # standalone (re-reads)
        var dense_hw = self._base_next_dense()
        var fold = self._fold_view()
        var plan = fold.serve_assign_tail_explicit(
            snap.copy(), folded_counts^, dense_hw
        )
        for i in range(len(plan)):
            ref blk = plan[i]
            self._append_block_segments(index, blk)  # un-cached (re-reads)
        _ = fold^
        return index^

    def _snapshot(self) raises -> List[ShardSnapshot]:
        """(a) The authoritative snapshot of every live source sub-lineage — the
        SHARED `SegmentBaseInputs.snapshot()` source. The IDENTICAL boundary the
        segment fold pins (single source — serve==fold is structural)."""
        return self._inputs.snapshot()

    def _base_next_dense(self) raises -> Int64:
        """(c) The dense high-water where the un-folded tail begins — the SHARED
        `SegmentBaseInputs.base_next_dense()` source (the `_base` broker manifest's
        `next_offset`). The serve path assigns the tail's dense offsets starting
        HERE, exactly as the next fold will (`_base.head + 1`); the SAME read the
        segment fold uses (single source)."""
        return self._inputs.base_next_dense()

    def _folded_counts(
        self, snap: List[ShardSnapshot]
    ) raises -> List[ShardFoldedWatermark]:
        """(b) The per-shard already-folded record counts — the SHARED
        `SegmentBaseInputs.folded_counts()` source (each source shard's durable
        `_LOG_START.log_start_offset`, the retire-advanced fold cursor the fold
        persists in `_retire_folded_source`). The SAME read the segment fold uses
        (single source — the `[folded_count .. snap_total)` tail is identical)."""
        return self._inputs.folded_counts(snap)

    # -------------------------------------------------------------------------
    # Step 1 internal — read `_base` like a single broker manifest (by offset).
    # -------------------------------------------------------------------------

    def _resolve_base_index(self) raises -> List[SegmentRef]:
        """Walk the live `_base` manifest chunks and produce dense `SegmentRef`s.
        Byte-for-byte the SAME logic `ConsumeCore.resolve_index` runs (log_start-
        aware running-base, marker-chunk skip, reaped-chunk restart) — applied to
        the `_base` prefix. `_base`'s gapless manifest offset IS the dense Kafka
        offset, so no re-basing is needed for this region. An ABSENT `_base`
        (sub-lineage mode engaged but no fold has run yet) yields an EMPTY folded
        prefix — the whole partition is then the serve-merged tail (dense from 0).

        Thin wrapper over `_resolve_base_index_capturing` with a throwaway
        object_key sink (used where the `_base` object_key set is not needed)."""
        var sink = List[String]()
        return self._resolve_base_index_capturing(sink)

    def _resolve_base_index_capturing(
        self, mut base_keys: List[String]
    ) raises -> List[SegmentRef]:
        """`_resolve_base_index` that ALSO captures the `_base`
        object_key set into `base_keys` in the SAME single `_base` walk. The
        captured set is BYTE-IDENTICAL to `SegmentBaseInputs._base_object_keys`
        (same `log_start`-seeded `[log_start_seq .. head]` walk, same `has_segment`
        filter, same reaped-skip), so threading it into
        `folded_counts_cached` produces the EXACT same watermark the un-cached
        `folded_counts` would — while eliminating the duplicate `_base` LIST + GET
        traffic of a second walk."""
        var base = self._base_manifest()
        # No `_base` yet reads as chunk_seq -1 (an empty folded prefix); a
        # read error raises.
        var head = base.read_head_authoritative()
        var n_chunks = head.chunk_seq + Int64(1)
        var ls = base.read_log_start()
        var keys_at_entry = len(base_keys)
        var index = List[SegmentRef]()
        var running_base = ls.log_start_offset
        var seq = ls.log_start_seq
        while seq < n_chunks:
            try:
                var body_bytes = base.read_chunk(seq)
                var body = ManifestBody.decode(body_bytes)
                if not body.has_segment():
                    # No segment object (`has_segment` False: a marker, 0
                    # records): skip it. Its record_count still advances the
                    # running offset, so later chunks keep their offsets.
                    running_base += body.record_count
                    seq += Int64(1)
                    continue
                var rc = body.record_count
                var crc = body.crc32
                var key = String(body.object_key)
                # Capture the `_base`-present object_key (the SAME set
                # `_base_object_keys` collects) BEFORE the key is moved into the
                # SegmentRef — non-marker chunks only, identical to the un-cached
                # `_base_object_keys` filter.
                base_keys.append(String(key))
                var base_off = running_base
                var last = base_off + rc - Int64(1)
                index.append(
                    SegmentRef(
                        chunk_seq=seq,
                        base_offset=base_off,
                        last_offset=last,
                        record_count=rc,
                        object_key=key^,
                        crc32=crc,
                    )
                )
                running_base += rc
                seq += Int64(1)
            except e:
                # Restart past a reaped chunk or raise (chunk_walk.mojo).
                ls = restart_point_after_failed_read(
                    base, seq, e^, "SubLineageConsumeResolver._base walk"
                )
                index = List[SegmentRef]()
                _truncate(base_keys, keys_at_entry)
                running_base = ls.log_start_offset
                seq = ls.log_start_seq
        _ = base^
        return index^

    # -------------------------------------------------------------------------
    # Per-resolve cache build + cache-backed block mapping.
    # -------------------------------------------------------------------------

    def _build_folded_counts_cache(
        self, snap: List[ShardSnapshot], var base_keys: List[String]
    ) raises -> FoldedCountsCache:
        """Build the per-resolve read cache: the `_base` object_key set (captured
        from the Step-1 `_base` walk) + a single-walk capture of every snapshot
        shard (its `_LOG_START` + decoded chunk list). Each snapshot shard is
        walked EXACTLY ONCE here; both (b) `folded_counts_cached` and the Step-2
        block->segment mapping consume the capture, so the resolve walks each
        shard once total (vs. the un-cached path's twice). The capture verbs are
        IDENTICAL to the un-cached walks (`read_head_authoritative` +
        `read_log_start` + per-chunk `read_chunk`)."""
        var shards = List[_CachedShard]()
        for i in range(len(snap)):
            shards.append(self._inputs.walk_shard_chunks(snap[i].shard_id))
        return FoldedCountsCache(base_keys^, shards^)

    # -------------------------------------------------------------------------
    # Step 2 internal — map ONE planned tail block to its source segments.
    # -------------------------------------------------------------------------

    def _append_block_segments(
        self, mut index: List[SegmentRef], blk: FoldBlockAssignment
    ) raises:
        """Append the dense `SegmentRef`s for ONE planned tail block. The block
        covers source shard `blk.shard_id`'s local offsets
        `[blk.source_local_base .. blk.source_local_base + blk.count)`, assigned
        dense offsets `[blk.dense_base .. blk.dense_base + blk.count)`. Walk the
        source sub-lineage's chunks that intersect the block's source-local range;
        each intersecting chunk becomes a dense `SegmentRef` whose `base_offset` is
        `blk.dense_base + (chunk_source_local_base - blk.source_local_base)`.

        A block's source-local range ALWAYS starts at a CHUNK BOUNDARY: the fold's
        `folded_count` advances to a snapshot's `next_offset`, which is the sum of
        whole-chunk `record_count`s (the offset allocator commits records in whole
        chunks), so `blk.source_local_base` (== `folded_count`) coincides with a
        chunk's `chunk_lo`. Each intersecting chunk is therefore emitted WHOLE.
        The clamp below is defensive only: if a chunk ever straddled the block's
        lower bound, it skips the already-folded prefix so the in-block rows still
        get correct dense offsets (and never a dense offset below `blk.dense_base`)."""
        var shard = self._shard_manifest(blk.shard_id)
        var head = shard.read_head_authoritative()
        var n_chunks = head.chunk_seq + Int64(1)
        var ls = shard.read_log_start()
        var blk_lo = blk.source_local_base
        var blk_hi = blk.source_local_base + blk.count  # exclusive
        var running = ls.log_start_offset  # source-local base of the first chunk
        var seq = ls.log_start_seq
        var index_at_entry = len(index)
        while seq < n_chunks:
            try:
                var body_bytes = shard.read_chunk(seq)
                var body = ManifestBody.decode(body_bytes)
                if not body.has_segment():
                    # No segment object (`has_segment` False: a marker, 0
                    # records): skip it. Its record_count still advances the
                    # running offset, so later chunks keep their offsets.
                    running += body.record_count
                    seq += Int64(1)
                    continue
                var rc = body.record_count
                var chunk_lo = running
                var chunk_hi = running + rc  # exclusive source-local end
                # Does this chunk intersect the block's source-local range?
                if chunk_hi > blk_lo and chunk_lo < blk_hi:
                    var crc = body.crc32
                    var key = String(body.object_key)
                    # The in-block portion of this chunk's source-local range
                    # (whole chunk in the common case — `blk_lo`/`blk_hi` fall on
                    # chunk boundaries; the clamp is the defensive straddle guard).
                    var in_lo = chunk_lo if chunk_lo > blk_lo else blk_lo
                    var in_hi = chunk_hi if chunk_hi < blk_hi else blk_hi
                    var in_count = in_hi - in_lo
                    var dense_base = blk.dense_base + (in_lo - blk_lo)
                    index.append(
                        SegmentRef(
                            chunk_seq=seq,
                            base_offset=dense_base,
                            last_offset=dense_base + in_count - Int64(1),
                            record_count=in_count,
                            object_key=key^,
                            crc32=crc,
                        )
                    )
                running = chunk_hi
                seq += Int64(1)
            except e:
                # Restart past a reaped chunk or raise (chunk_walk.mojo).
                ls = restart_point_after_failed_read(
                    shard, seq, e^, "SubLineageConsumeResolver block walk"
                )
                while len(index) > index_at_entry:
                    _ = index.pop()
                running = ls.log_start_offset
                seq = ls.log_start_seq
        _ = shard^

    def _append_block_segments_cached(
        self,
        mut index: List[SegmentRef],
        blk: FoldBlockAssignment,
        cache: FoldedCountsCache,
    ) raises:
        """The CACHE-BACKED twin of `_append_block_segments`: maps
        ONE planned tail block to its dense `SegmentRef`s by replaying the
        IDENTICAL intersection logic over the block's source shard's CACHED chunk
        list (no store read). BYTE-IDENTICAL by construction: seed `running` from
        the cached `log_start_offset`, visit the cached chunks in source-local
        (seq) order, skip markers, and for each chunk intersecting `[blk_lo ..
        blk_hi)` emit a `SegmentRef` with the SAME clamp + dense_base arithmetic.
        The cached chunk list was captured from `log_start_seq` up with the same
        marker / reaped-skip handling, so the replay produces the same dense
        segments the un-cached double-read would."""
        var cs = self._cached_shard_index(cache, blk.shard_id)
        if cs < 0:
            return  # no capture (shard reaped pre-walk) — block contributes none
        ref sh = cache.shards[cs]
        var blk_lo = blk.source_local_base
        var blk_hi = blk.source_local_base + blk.count  # exclusive
        var running = sh.log_start_offset  # source-local base of the first chunk
        for i in range(len(sh.chunks)):
            ref c = sh.chunks[i]
            if not c.has_segment():
                # No segment object (a marker, 0 records): skip it; its
                # record_count still advances the running offset.
                running += c.record_count
                continue
            var rc = c.record_count
            var chunk_lo = running
            var chunk_hi = running + rc  # exclusive source-local end
            if chunk_hi > blk_lo and chunk_lo < blk_hi:
                var key = String(c.object_key)
                var in_lo = chunk_lo if chunk_lo > blk_lo else blk_lo
                var in_hi = chunk_hi if chunk_hi < blk_hi else blk_hi
                var in_count = in_hi - in_lo
                var dense_base = blk.dense_base + (in_lo - blk_lo)
                index.append(
                    SegmentRef(
                        chunk_seq=c.chunk_seq,
                        base_offset=dense_base,
                        last_offset=dense_base + in_count - Int64(1),
                        record_count=in_count,
                        object_key=key^,
                        crc32=c.crc32,
                    )
                )
            running = chunk_hi

    @always_inline
    def _cached_shard_index(
        self, cache: FoldedCountsCache, shard_id: String
    ) -> Int:
        """Index of `shard_id` in the per-resolve cache (O(snapshot shards),
        bounded), or -1 if absent."""
        for i in range(len(cache.shards)):
            if cache.shards[i].shard_id == shard_id:
                return i
        return -1

    # -------------------------------------------------------------------------
    # Tagged twins — identical walks, carrying the txn tag.
    # -------------------------------------------------------------------------

    def _resolve_base_index_tagged_capturing(
        self, mut base_keys: List[String]
    ) raises -> List[SubLineageTaggedSegment]:
        """`_resolve_base_index_tagged` that ALSO captures the
        `_base` object_key set into `base_keys` in the SAME `_base` walk (same
        non-marker filter, byte-identical to `_base_object_keys`), so the tagged
        resolve's (b) `folded_counts_cached` reuses it with no `_base` re-read.

        Carries each folded `_base` chunk's txn tag (read from the SAME
        `ManifestBody`). For a FOLDED chunk the `_base` body PRESERVES the
        producer + txn trailers, so a folded txn-open / aborted
        chunk's `txn_id` + `producer_epoch` are correct here. Marker chunks are
        skipped (they carry no records)."""
        var base = self._base_manifest()
        # No `_base` yet reads as chunk_seq -1; a read error raises.
        var head = base.read_head_authoritative()
        var n_chunks = head.chunk_seq + Int64(1)
        var ls = base.read_log_start()
        var keys_at_entry = len(base_keys)
        var index = List[SubLineageTaggedSegment]()
        var running_base = ls.log_start_offset
        var seq = ls.log_start_seq
        while seq < n_chunks:
            try:
                var body_bytes = base.read_chunk(seq)
                var body = ManifestBody.decode(body_bytes)
                if not body.has_segment():
                    # No segment object (`has_segment` False: a marker, 0
                    # records): skip it. Its record_count still advances the
                    # running offset, so later chunks keep their offsets.
                    running_base += body.record_count
                    seq += Int64(1)
                    continue
                var rc = body.record_count
                var crc = body.crc32
                var key = String(body.object_key)
                var txn_id = String(body.txn_id)
                var epoch = body.producer_epoch
                # Capture the `_base`-present object_key (non-marker,
                # identical to `_base_object_keys`) for the cached (b).
                base_keys.append(String(key))
                var base_off = running_base
                var last = base_off + rc - Int64(1)
                index.append(
                    SubLineageTaggedSegment(
                        seg=SegmentRef(
                            chunk_seq=seq,
                            base_offset=base_off,
                            last_offset=last,
                            record_count=rc,
                            object_key=key^,
                            crc32=crc,
                        ),
                        tag=ChunkTxnTag(MARKER_NONE, txn_id^, epoch),
                    )
                )
                running_base += rc
                seq += Int64(1)
            except e:
                # Restart past a reaped chunk or raise (chunk_walk.mojo).
                ls = restart_point_after_failed_read(
                    base, seq, e^, "SubLineageConsumeResolver._base walk"
                )
                index = List[SubLineageTaggedSegment]()
                _truncate(base_keys, keys_at_entry)
                running_base = ls.log_start_offset
                seq = ls.log_start_seq
        _ = base^
        return index^

    def _append_block_segments_tagged_cached(
        self,
        mut index: List[SubLineageTaggedSegment],
        blk: FoldBlockAssignment,
        cache: FoldedCountsCache,
    ) raises:
        """The CACHE-BACKED twin of `_append_block_segments_tagged`:
        maps ONE planned tail block to its dense tagged `SegmentRef`s from the
        block's source shard's CACHED chunk list (no store read). BYTE-IDENTICAL
        intersection + clamp + dense_base arithmetic, plus the per-chunk txn tag
        (`txn_id` + `producer_epoch`) captured in the SAME walk — so a live
        txn-open data chunk stays correctly tagged for read_committed."""
        var cs = self._cached_shard_index(cache, blk.shard_id)
        if cs < 0:
            return
        ref sh = cache.shards[cs]
        var blk_lo = blk.source_local_base
        var blk_hi = blk.source_local_base + blk.count  # exclusive
        var running = sh.log_start_offset
        for i in range(len(sh.chunks)):
            ref c = sh.chunks[i]
            if not c.has_segment():
                # No segment object (a marker, 0 records): skip it; its
                # record_count still advances the running offset.
                running += c.record_count
                continue
            var rc = c.record_count
            var chunk_lo = running
            var chunk_hi = running + rc
            if chunk_hi > blk_lo and chunk_lo < blk_hi:
                var key = String(c.object_key)
                var txn_id = String(c.txn_id)
                var epoch = c.producer_epoch
                var in_lo = chunk_lo if chunk_lo > blk_lo else blk_lo
                var in_hi = chunk_hi if chunk_hi < blk_hi else blk_hi
                var in_count = in_hi - in_lo
                var dense_base = blk.dense_base + (in_lo - blk_lo)
                index.append(
                    SubLineageTaggedSegment(
                        seg=SegmentRef(
                            chunk_seq=c.chunk_seq,
                            base_offset=dense_base,
                            last_offset=dense_base + in_count - Int64(1),
                            record_count=in_count,
                            object_key=key^,
                            crc32=c.crc32,
                        ),
                        tag=ChunkTxnTag(MARKER_NONE, txn_id^, epoch),
                    )
                )
            running = chunk_hi

    def _append_block_segments_tagged(
        self,
        mut index: List[SubLineageTaggedSegment],
        blk: FoldBlockAssignment,
    ) raises:
        """`_append_block_segments` carrying each serve-tail source chunk's
        txn tag (read from the SAME source `ManifestBody`). A live (un-folded)
        txn-open data chunk in a source sub-lineage carries its `txn_id` +
        `producer_epoch` so read_committed hides it until its txn completes —
        BYTE-IDENTICAL tagging to the single-manifest path."""
        var shard = self._shard_manifest(blk.shard_id)
        var head = shard.read_head_authoritative()
        var n_chunks = head.chunk_seq + Int64(1)
        var ls = shard.read_log_start()
        var blk_lo = blk.source_local_base
        var blk_hi = blk.source_local_base + blk.count  # exclusive
        var running = ls.log_start_offset
        var seq = ls.log_start_seq
        var index_at_entry = len(index)
        while seq < n_chunks:
            try:
                var body_bytes = shard.read_chunk(seq)
                var body = ManifestBody.decode(body_bytes)
                if not body.has_segment():
                    # No segment object (`has_segment` False: a marker, 0
                    # records): skip it. Its record_count still advances the
                    # running offset, so later chunks keep their offsets.
                    running += body.record_count
                    seq += Int64(1)
                    continue
                var rc = body.record_count
                var chunk_lo = running
                var chunk_hi = running + rc
                if chunk_hi > blk_lo and chunk_lo < blk_hi:
                    var crc = body.crc32
                    var key = String(body.object_key)
                    var txn_id = String(body.txn_id)
                    var epoch = body.producer_epoch
                    var in_lo = chunk_lo if chunk_lo > blk_lo else blk_lo
                    var in_hi = chunk_hi if chunk_hi < blk_hi else blk_hi
                    var in_count = in_hi - in_lo
                    var dense_base = blk.dense_base + (in_lo - blk_lo)
                    index.append(
                        SubLineageTaggedSegment(
                            seg=SegmentRef(
                                chunk_seq=seq,
                                base_offset=dense_base,
                                last_offset=dense_base + in_count - Int64(1),
                                record_count=in_count,
                                object_key=key^,
                                crc32=crc,
                            ),
                            tag=ChunkTxnTag(MARKER_NONE, txn_id^, epoch),
                        )
                    )
                running = chunk_hi
                seq += Int64(1)
            except e:
                # Restart past a reaped chunk or raise (chunk_walk.mojo).
                ls = restart_point_after_failed_read(
                    shard, seq, e^, "SubLineageConsumeResolver block walk"
                )
                while len(index) > index_at_entry:
                    _ = index.pop()
                running = ls.log_start_offset
                seq = ls.log_start_seq
        _ = shard^

    # -------------------------------------------------------------------------
    # substrate construction — per-shard / `_base` manifests + the fold view.
    # -------------------------------------------------------------------------

    def _base_manifest(self) raises -> CasManifestStore[Self.Store]:
        """The `_base` fold-lineage manifest — the SHARED `SegmentBaseInputs`
        source (the SAME `_base` the segment fold appends to + this resolver reads)."""
        return self._inputs.base_manifest()

    def _shard_manifest(self, shard_id: String) raises -> CasManifestStore[Self.Store]:
        """A writer sub-lineage's manifest — the SHARED `SegmentBaseInputs` source
        (identical key shape to the segment fold's)."""
        return self._inputs.shard_manifest(shard_id)

    def _fold_view(self) raises -> SubLineageBaseFold[Self.Store]:
        """The SHARED `SubLineageBaseFold` canonical-merge view — the SHARED
        `SegmentBaseInputs` source. Used ONLY for the SHARED canonical-merge code
        (`snapshot_explicit()` + `serve_assign_tail_explicit()`, the IDENTICAL
        `_sort_snapshot` + `plan_assignment` the fold runs). The broker `_base` is a
        SEGMENT manifest (not the i64 `_base` format), so this view does NOT
        decode `_base` (no `reload_from_base`); the dense high-water + per-shard
        folded counts are supplied explicitly from the broker `_base` manifest +
        the source `_LOG_START`s — all via the SAME `SegmentBaseInputs` the fold
        uses, so serve == fold is structural (single source)."""
        return self._inputs.fold_view()


def _truncate(mut xs: List[String], n: Int):
    """Drop `xs`'s entries past the first `n` (a restarted walk's capture)."""
    while len(xs) > n:
        _ = xs.pop()

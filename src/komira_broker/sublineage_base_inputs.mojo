# =============================================================================
# komira_broker/sublineage_base_inputs.mojo
#   The SINGLE SOURCE of the serve==fold inputs. Makes serve==fold
#   STRUCTURAL: the consume resolver (`SubLineageConsumeResolver`) and the
#   production fold (`SegmentBaseFold`) do not MIRROR three byte-identical input
#   helpers — they BOTH call ONE shared source (this module).
# =============================================================================
#
# WHY THIS EXISTS — serve==fold is SINGLE-SOURCE, not guarded duplication.
# ---------------------------------------------------------------------------
# The SERVE==FOLD contract (merge-assigns-at-serve, fold-persists — see the
# `sublineage_segment_fold.mojo` header) requires the production fold and the
# resolver's serve path to assign IDENTICAL dense offsets for the SAME tail.
# That rests on:
#   * the SHARED canonical-merge code being the SOLE assignment authority
#     (`SubLineageBaseFold.serve_assign_tail_explicit` -> `plan_assignment`), and
#   * BOTH callers feeding it the IDENTICAL three inputs:
#       (a) the SAME authoritative snapshot of live source sub-lineages,
#       (b) per-shard `folded_counts` from each source shard's durable `_LOG_START`,
#       (c) the `dense_hw_start` from the `_base` broker manifest's `next_offset`.
#
# Two copies of (a)/(b)/(c) that MUST stay byte-identical forever would be a
# latent DRIFT hazard: an edit to one (a read of a different durable cursor, a
# different prefix construction, a different empty-`_base` fallback) would
# silently break serve==fold with NO compile error and only a subtle
# torn-offset symptom.
#
# So the three input reads + the substrate construction (the `_base` / per-shard
# `CasManifestStore`s + the SHARED `SubLineageBaseFold` fold view) live HERE, in
# ONE struct both callers hold by value and delegate to. serve==fold is
# STRUCTURAL (single source): there is literally one code path that computes
# (a)/(b)/(c) and one substrate-construction site, so the two callers CANNOT
# diverge.
#
# CRASH-DURABILITY — the folded watermark (b) is `_base`-ANCHORED, not
# source-`_LOG_START`-anchored (no torn offset across a crash between loops).
# ---------------------------------------------------------------------------
# The fold's `run_once` MATERIALIZEs the planned blocks into `_base` and THEN
# RETIREs each source `_LOG_START` to the folded watermark in TWO sequential
# loops over INDEPENDENT durable objects (`_base._HEAD` vs the source
# `_LOG_START`s). A crash BETWEEN the loops leaves `_base` advanced (recoverable
# bucket-is-truth) but the source `_LOG_START`s stale-low. If (b) read ONLY the
# source `_LOG_START`, BOTH the fold (re-folding `[stale .. snap_total)` ->
# content-blind `_base` DOUBLE-APPEND) and the serve resolver (re-serving the
# folded prefix as a live tail) would tear the dense stream. So (b)
# (`folded_counts`) takes the MAX of the source `_LOG_START` (steady-state /
# reaped-prefix cursor) and the `_base`-materialized prefix (the crash-window
# anchor, derived by correlating source `.seg` object_keys against the set
# already in `_base`) — "the watermark is REBUILT purely from `_base`". Because
# (b) is the SINGLE shared source, this lives in ONE place and serve==fold
# stays structural. In the non-crash steady state the two are EQUAL. See
# `folded_counts` / `_base_folded_prefix`.
#
# -----------------------------------------------------------------------------
# Encapsulation / slab safety.
#   * ZERO UnsafePointer in any signature; the surface is value / List / POD / the
#     Movable substrate structs (`CasManifestStore`, `SubLineageBaseFold`) returned
#     BY VALUE. ZERO wildcard origins. ZERO unsafe_from_address. ZERO take_pointee.
#   * The substrate (`Store` + the per-shard / `_base` `CasManifestStore`s + the
#     fold view) is held / built by value; each manifest is a `clone()` of the
#     shared store reaching the SAME logical bucket. Raw key arithmetic stays
#     INSIDE this module + the substrate.
#   * This struct is a stack value, NOT a byte-slab element. POD fields + an
#     owned `String` only — no Movable-struct-in-byte-slab-with-heap-field shape.
# =============================================================================

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.sublineage_base_fold import (
    BASE_SHARD_ID,
    ShardFoldedWatermark,
    ShardSnapshot,
    SubLineageBaseFold,
)

from .chunk_walk import restart_point_after_failed_read
from .manifest_body import ManifestBody, chunk_has_segment
from .partition_assignment import sublineage_prefix


# =============================================================================
# Per-resolve read cache — the ONE-walk cache the resolver threads
# into `folded_counts_cached` so it does NOT re-LIST / re-GET `_base` + shards.
# =============================================================================
#
# `folded_counts` anchors the watermark in `_base`, so it reads the SAME
# durable state the consume resolver ALREADY walks:
#   * `_base_object_keys()` re-LISTs `_base` + re-GETs every live `_base` chunk —
#     a byte-for-byte DUP of the resolver's Step-1 `_resolve_base_index` `_base`
#     walk;
#   * per shard, `_base_folded_prefix` + `read_log_start` re-LIST + re-GET every
#     shard chunk — a byte-for-byte DUP of the resolver's Step-2
#     `_append_block_segments` shard walk.
#
# Without a cache the resolver would read each `_base` chunk + each shard chunk
# TWICE and pay (1 + S) extra authoritative LISTs per consume resolve; on an
# object store each LIST + GET is a round-trip.
#
# The cache eliminates the duplication WITHOUT changing the computed value: the
# resolver reads `_base` (object_keys) + each snapshot shard (chunks +
# `_LOG_START`) ONCE, stashes them in this cache by value, and threads the cache
# into `folded_counts_cached` (which replays the IDENTICAL derivation over the
# cached bytes — the exact same MAX(source `_LOG_START`, `_base`-prefix)). The
# resolver ALSO maps the plan blocks to segments FROM the same cached shard
# chunks, so each shard is walked ONCE total. The fold keeps its STANDALONE
# `folded_counts(snap)` (it materializes BEFORE any resolve walk, so it has no
# walk to reuse) — the standalone path is byte-unchanged, so serve==fold stays
# STRUCTURAL (both compute the identical watermark; the cache is a pure read
# de-dup, not a second derivation).
#
# Slab safety / encapsulation: these caches are STACK values held by the resolver for
# the span of ONE resolve, threaded by `ref`/value across the in-module call.
# They carry POD Int64s + owned `String`/`List` only — no UnsafePointer, no
# wildcard origin, no byte-slab element. Bounded: O(live `_base` chunks) +
# O(snapshot shards x live shard chunks), the SAME bound the un-cached path
# walked (the cache stores what was already read, it does not widen the scan).
# -----------------------------------------------------------------------------


@fieldwise_init
struct _CachedShardChunk(Copyable, Movable, Deinitable):
    """ONE decoded source-shard chunk, captured during the resolver's single
    shard walk. Carries exactly the fields BOTH consumers need: `_base_folded_
    prefix` reads `record_count` + `object_key` + `marker_type`; the block->
    segment mapping reads `chunk_seq` + `record_count` + `crc32` + `object_key`
    + `marker_type`. Chunks without a segment object (markers) are kept in
    the list so the replay skips them at the IDENTICAL points the live walk did."""

    var chunk_seq: Int64
    var record_count: Int64
    var crc32: UInt32
    var object_key: String
    var txn_id: String
    var producer_epoch: Int64
    var marker_type: Int64

    def has_segment(self) -> Bool:
        """`ManifestBody.has_segment` over the captured fields (the same
        `chunk_has_segment` predicate)."""
        return chunk_has_segment(self.marker_type, self.object_key)


@fieldwise_init
struct _CachedShard(Copyable, Movable, Deinitable):
    """ONE source shard's single-walk capture: its `_LOG_START` cursor (seq +
    offset — the running base + seed both replays use) plus the decoded chunk
    list `[log_start_seq .. head]` in source-local order. The cursor is the
    one the chunk list starts at: a walk that restarted past a reaped chunk
    captures the `_LOG_START` it restarted from. A shard with no manifest
    captures its `_LOG_START` (zero when absent) and no chunks."""

    var shard_id: String
    var log_start_offset: Int64
    var log_start_seq: Int64
    var chunks: List[_CachedShardChunk]


@fieldwise_init
struct FoldedCountsCache(Copyable, Movable, Deinitable):
    """The per-resolve read cache threaded into `folded_counts_cached`: the
    `_base` object_key set (captured during Step-1 `_resolve_base_index`) + the
    per-snapshot-shard single-walk captures (captured up front, reused for BOTH
    the folded-prefix derivation AND the block->segment mapping). Built ONCE per
    consume resolve; held by value for the span of that resolve. POD/owned only —
    no pointer crosses any boundary."""

    var base_keys: List[String]
    var shards: List[_CachedShard]


# =============================================================================
# SegmentBaseInputs[Store] — the SINGLE source of the serve==fold (a)/(b)/(c).
# =============================================================================


struct SegmentBaseInputs[Store: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """The SINGLE source of the three serve==fold inputs + the substrate
    construction shared by the production fold (`SegmentBaseFold`) and the
    consume resolver (`SubLineageConsumeResolver`). Both hold one of these by
    value and delegate to it, so the two CANNOT compute (a)/(b)/(c)
    differently — serve==fold is STRUCTURAL (single source), not
    byte-identical-mirrors guarded by tests.

    Generic over `[Store: CloneableConditionalWriteStore]`: one store handle
    is `clone()`d per sub-lineage + per `_base`
    access, so they all reach the SAME logical bucket (one bucket, N prefixes).

    Ownership (by value):
      var _store: Store        — the shared backend; cloned per shard/`_base` access.
      var _base_prefix: String — the partition's base manifest prefix
                                 (`<cluster>/_meta/topics/<topic>/<partition>`),
                                 the SAME prefix the producer + legacy/resolver consume
                                 use. Sub-lineages live under `<base>/_lineage/
                                 <shard>`; `_base` is `<base>/_lineage/_base`.
    """

    var _store: Self.Store
    var _base_prefix: String

    def __init__(out self, var store: Self.Store, var base_prefix: String):
        self._store = store^
        self._base_prefix = base_prefix^

    @always_inline
    def base_prefix(self) -> String:
        """The partition base manifest prefix this inputs view is bound to (so a
        caller can build a sibling substrate at the same bucket without re-passing
        the prefix)."""
        return String(self._base_prefix)

    # -------------------------------------------------------------------------
    # substrate construction — per-shard / `_base` manifests + the SHARED fold view.
    # -------------------------------------------------------------------------

    def base_manifest(self) raises -> CasManifestStore[Self.Store]:
        """A `CasManifestStore` bound to the SEGMENT `_base` fold lineage prefix
        (`<base_prefix>/_lineage/_base`), backed by a clone of the shared store.
        The SINGLE construction site both callers use — identical key shape.
        Opted in to the reaped-slot guard: `_base` chunks are retired and
        reaped below its `_LOG_START` (#486)."""
        var m = CasManifestStore[Self.Store](
            self._store.clone(),
            sublineage_prefix(self._base_prefix, BASE_SHARD_ID),
            RetryPolicy.fast_test(),
        )
        m.enable_reaped_slot_guard()
        return m^

    def shard_manifest(
        self, shard_id: String
    ) raises -> CasManifestStore[Self.Store]:
        """A `CasManifestStore` bound to a writer sub-lineage's prefix
        (`<base_prefix>/_lineage/<shard_id>`), backed by a clone of the store.
        The SINGLE construction site both callers use — identical key shape.
        Not opted in to the reaped-slot guard: the fold and the consume
        resolver only read, retire and reap a shard through it; the shard's
        writer appends through its own `BrokerCore` sub-lineage handle, which
        is opted in."""
        return CasManifestStore[Self.Store](
            self._store.clone(),
            sublineage_prefix(self._base_prefix, shard_id),
            RetryPolicy.fast_test(),
        )

    def fold_view(self) raises -> SubLineageBaseFold[Self.Store]:
        """A `SubLineageBaseFold` view over the SAME partition bucket, used for the
        SHARED canonical-merge code: `enumerate_live_shards()`,
        `snapshot_explicit()` (pins the SAME authoritative boundary the serve path
        pins — reads ONLY the source sub-lineage manifests, format-agnostic) +
        `serve_assign_tail_explicit()` (the IDENTICAL `_sort_snapshot` +
        `plan_assignment`). The broker `_base` is a SEGMENT manifest (not the
        i64 `_base` format), so this view does NOT decode `_base` — the dense
        high-water + per-shard folded counts are supplied explicitly from the
        broker `_base` manifest + the source `_LOG_START`s.

        The fold view's prefix matches the `sublineage_prefix` layout
        (`<base>/_lineage/<shard>`), so it discovers + snapshots the SAME
        live shards both callers read. The SINGLE construction site both
        callers use."""
        return SubLineageBaseFold[Self.Store](
            self._store.clone(), String(self._base_prefix)
        )

    # -------------------------------------------------------------------------
    # The serve==fold inputs (a)/(b)/(c) — the SINGLE source of all three.
    # -------------------------------------------------------------------------

    def snapshot(self) raises -> List[ShardSnapshot]:
        """(a) Pin the authoritative snapshot of every live source sub-lineage at a
        commit boundary — the SHARED `SubLineageBaseFold.snapshot_explicit()`
        (`read_head_authoritative` per live shard, canonical-sorted, `_base`
        EXCLUDED). This is the IDENTICAL boundary BOTH the fold and the resolver
        pin — now computed ONCE, here."""
        var fold = self.fold_view()
        var snap = fold.snapshot_explicit()
        _ = fold^
        return snap^

    def folded_counts(
        self, snap: List[ShardSnapshot]
    ) raises -> List[ShardFoldedWatermark]:
        """(b) The per-shard already-folded record count for every live source
        shard in `snap` — the `_base`-ANCHORED fold watermark, the SINGLE source
        for BOTH the serve plan's `[folded_count .. snap_total)` tail and the
        fold's.

        CRASH-DURABILITY (the torn-offset crash-between-loops fix). The fold's
        `run_once` is TWO sequential loops — MATERIALIZE the planned blocks into
        `_base`, THEN RETIRE each source `_LOG_START` to the folded watermark.
        `_base._HEAD` and the source `_LOG_START`s are INDEPENDENT durable objects;
        a crash BETWEEN the loops leaves `_base` advanced (recoverable
        bucket-is-truth via `read_head_authoritative`) but every source
        `_LOG_START` stale at its pre-fold value. Reading the folded watermark
        SOLELY from the source `_LOG_START` would then UNDER-report (stale-low),
        so `plan_assignment` would re-fold the already-materialized prefix
        `[stale .. snap_total)` and the content-blind `_base` append would
        DOUBLE-APPEND it (the contiguity guards only check the new chunk is
        contiguous, NOT that the records are already folded) -> a torn / duplicated
        dense stream. The SAME stale read on the serve side re-serves the folded
        prefix as a LIVE TAIL, so the crashed state is torn at serve time too.

        The fix anchors the watermark in `_base` — the design's single durable
        source of truth ("the watermark is REBUILT purely from `_base`"). For each
        shard we take the MAX of:
          * the source `_LOG_START.log_start_offset` (the steady-state cursor —
            authoritative for a RETIRED+REAPED prefix whose source chunks are
            gone), and
          * the `_base`-derived folded prefix (`_base_folded_prefix`): how many of
            the shard's source-local records are already MATERIALIZED in `_base`,
            derived by correlating the shard's source chunk `object_key`s against
            the set already present in `_base`.
        In the NORMAL (non-crash) steady state the two are EQUAL (the retire
        advances the source `_LOG_START` to exactly the materialized prefix), so
        the plan is UNCHANGED. In the crash-between-loops window the source
        `_LOG_START` is stale-low but `_base` reflects the materialized prefix, so
        the MAX is the TRUE folded watermark -> the re-fold folds nothing (clean
        no-op) and the serve path serves no duplicate. Because BOTH the fold and
        the serve resolver read this SINGLE source, serve==fold is preserved
        STRUCTURALLY (no second path).

        KNOWN-BENIGN RESIDUAL (retention-race offset shift, NOT duplication). On
        the FIRST-EVER fold of a partition, a crash-between-loops concurrent with a
        `_base` retention reap of the just-materialized prefix (while the source
        `_LOG_START` is still stale-low) can leave both the `_base`-prefix anchor
        AND the source cursor below the true folded watermark, so the records are
        re-materialized ONCE at the new high-water — a benign offset SHIFT,
        indistinguishable from retention legitimately racing ahead of the fold
        cursor; there is NO record duplication (each record still appears exactly
        once in the served dense stream)."""
        # The set of `.seg` object_keys already MATERIALIZED in `_base` (read ONCE
        # per `folded_counts` call — O(live `_base` chunks), retention-bounded, NOT
        # N x rounds). A source chunk's `.seg` key is structurally unique, and the
        # fold materializes whole source chunks in source-local order, so a shard's
        # `_base`-present object_keys form a CONTIGUOUS source-local prefix.
        var base_keys = self._base_object_keys()
        var out = List[ShardFoldedWatermark]()
        for i in range(len(snap)):
            ref ss = snap[i]
            var shard = self.shard_manifest(ss.shard_id)
            # No `_LOG_START` yet (never folded) reads as 0; an error raises.
            var ls_folded = shard.read_log_start().log_start_offset
            # `_base`-derived materialized prefix for this shard (crash-window
            # anchor): walk the shard's chunks in source-local order, summing
            # record_count while the chunk's `.seg` object_key is present in
            # `_base`; STOP at the first absent key (the prefix boundary).
            var base_folded = self._base_folded_prefix(shard, base_keys)
            _ = shard^
            # The watermark NEVER regresses: MAX of the steady-state source cursor
            # and the `_base`-materialized prefix.
            var folded = ls_folded if ls_folded >= base_folded else base_folded
            out.append(ShardFoldedWatermark(ss.shard_id, folded))
        return out^

    # -------------------------------------------------------------------------
    # The cache-backed (b) twin (byte-identical value, ZERO re-read).
    # -------------------------------------------------------------------------

    def folded_counts_cached(
        self,
        snap: List[ShardSnapshot],
        cache: FoldedCountsCache,
    ) raises -> List[ShardFoldedWatermark]:
        """(b) — the CACHE-BACKED twin of `folded_counts`, for the SERVE path.
        Computes the BYTE-IDENTICAL per-shard watermark (the MAX of the source
        `_LOG_START` and the `_base`-materialized prefix) but reads NOTHING from
        the store: the `_base` object_key set + every snapshot shard's
        `_LOG_START` + chunk list come from `cache`, which the consume resolver
        populated from the SAME `_base` + shard walks it ALREADY does (Step-1
        `_resolve_base_index` for `_base`, the up-front per-shard walk for the
        shards). This eliminates the crash-fix's redundant `_base` re-walk + the
        per-shard re-walk (1 + S authoritative LISTs + 1 + B + C GETs per consume
        resolve) WITHOUT changing the value: the derivation below is the same
        `_base_folded_prefix` logic, replayed over the cached chunk bytes.

        Correctness: the cache captures each shard in ONE consistent read (head +
        `_LOG_START` + chunks at that boundary), so the derived watermark equals
        what the un-cached double-read would compute in the absence of concurrent
        reaping; a shard chunk reaped during the capture restarts the capture from
        the new `_LOG_START`, exactly as the live walks restart. The fold's STANDALONE `folded_counts`
        is untouched — serve==fold stays structural (both derive the identical
        watermark; this is a read de-dup, not a second formula)."""
        var out = List[ShardFoldedWatermark]()
        for i in range(len(snap)):
            ref ss = snap[i]
            var ls_folded = Int64(0)
            var base_folded = Int64(0)
            var cs = _cached_shard_for(cache.shards, ss.shard_id)
            if cs >= 0:
                ref sh = cache.shards[cs]
                # The captured `_LOG_START.log_start_offset` (the live
                # `folded_counts` reads it before the head walk).
                ls_folded = sh.log_start_offset
                base_folded = _base_folded_prefix_cached(sh, cache.base_keys)
            # The watermark NEVER regresses: MAX of the steady-state source cursor
            # and the `_base`-materialized prefix — IDENTICAL to `folded_counts`.
            var folded = ls_folded if ls_folded >= base_folded else base_folded
            out.append(ShardFoldedWatermark(ss.shard_id, folded))
        return out^

    def walk_base_object_keys(self) raises -> List[String]:
        """PUBLIC walk of the `_base` object_key set — the SAME read
        `_base_object_keys` does, exposed so the resolver can capture it from its
        Step-1 `_resolve_base_index` `_base` walk INSTEAD of a second walk. (The
        resolver inlines the capture into its own `_base` walk; this is the
        fallback / single-source spelling)."""
        return self._base_object_keys()

    def walk_shard_chunks(
        self, shard_id: String
    ) raises -> _CachedShard:
        """Walk ONE source shard's manifest ONCE -> a `_CachedShard` capture
        (its `_LOG_START` cursor + decoded chunk list `[log_start_seq .. head]`
        in source-local order). The resolver calls this per snapshot shard to
        build the cache, then reuses the capture for BOTH the cached folded-prefix
        AND the block->segment mapping — so each shard is walked exactly ONCE per
        consume resolve. Reads are the IDENTICAL verbs the un-cached
        `_base_folded_prefix` / `_append_block_segments` issued
        (`read_head_authoritative` + `read_log_start` + per-chunk `read_chunk`),
        just done ONCE. A shard with no manifest reads as an empty chunk list
        (head chunk_seq -1); an error reading its head or `_LOG_START` raises.
        A chunk that cannot be read restarts the walk from a `_LOG_START` that
        moved past it, or raises (chunk_walk.mojo)."""
        var shard = self.shard_manifest(shard_id)
        var chunks = List[_CachedShardChunk]()
        var head = shard.read_head_authoritative()
        var n_chunks = head.chunk_seq + Int64(1)
        var ls = shard.read_log_start()
        var seq = ls.log_start_seq if ls.log_start_seq >= Int64(0) else Int64(0)
        while seq < n_chunks:
            try:
                var body = ManifestBody.decode(shard.read_chunk(seq))
                chunks.append(
                    _CachedShardChunk(
                        seq,
                        body.record_count,
                        body.crc32,
                        String(body.object_key),
                        String(body.txn_id),
                        body.producer_epoch,
                        body.marker_type,
                    )
                )
                seq += Int64(1)
            except e:
                ls = restart_point_after_failed_read(
                    shard, seq, e^, "SegmentBaseInputs.walk_shard_chunks"
                )
                chunks = List[_CachedShardChunk]()
                seq = ls.log_start_seq
        _ = shard^
        return _CachedShard(
            String(shard_id),
            ls.log_start_offset,
            ls.log_start_seq,
            chunks^,
        )

    # -------------------------------------------------------------------------
    # `_base`-anchored folded-watermark derivation (the crash-durability anchor).
    # -------------------------------------------------------------------------

    def _base_object_keys(self) raises -> List[String]:
        """The set of source `.seg` object_keys already MATERIALIZED in `_base`
        (the live `_base` chunks above `_base`'s log-start). Read ONCE per
        `folded_counts` call. The fold re-records each folded source chunk's
        `ManifestBody` into `_base` REUSING the SAME `.seg` object_key (NO byte
        copy), so a source chunk is materialized in `_base` IFF its object_key
        appears here. O(live `_base` chunks) — retention-bounded (the existing
        log-start advance reaps below the folded watermark), NOT N x rounds.

        A chunk that cannot be read restarts the walk from a `_LOG_START` that
        moved past it (reaped mid-walk; the set restarts too, so it is the set
        the resolver's `_base` capture restarts to), or raises when the chunk
        is missing at or above `_LOG_START` (a torn `_base`: dropping its key
        would lower the folded prefix and the fold would re-append chunks
        already in `_base`) (chunk_walk.mojo). An ABSENT `_base` (no fold yet)
        yields an empty set -> every shard's `_base`-derived prefix is 0 (the
        source `_LOG_START` then carries the watermark); an error reading the
        head raises."""
        var keys = List[String]()
        var base = self.base_manifest()
        var head = base.read_head_authoritative()  # no `_base`: chunk_seq -1
        var n_chunks = head.chunk_seq + Int64(1)
        var ls = base.read_log_start()
        var seq = ls.log_start_seq if ls.log_start_seq >= Int64(0) else Int64(0)
        while seq < n_chunks:
            try:
                var body = ManifestBody.decode(base.read_chunk(seq))
                if body.has_segment():
                    keys.append(String(body.object_key))
                seq += Int64(1)
            except e:
                ls = restart_point_after_failed_read(
                    base, seq, e^, "SegmentBaseInputs._base_object_keys"
                )
                keys = List[String]()
                seq = ls.log_start_seq
        _ = base^
        return keys^

    def _base_folded_prefix(
        self, shard: CasManifestStore[Self.Store], base_keys: List[String]
    ) raises -> Int64:
        """How many of `shard`'s source-local records are already MATERIALIZED in
        `_base`, derived by correlating the shard's source chunk `object_key`s
        against `base_keys` (the `_base`-present set). Walk the shard's chunks in
        source-local order (from its `_LOG_START` cursor up); sum `record_count`
        while the chunk's `.seg` object_key is in `base_keys`; STOP at the FIRST
        absent key — that is the contiguous folded-prefix boundary (the fold
        materializes whole chunks in source-local order, so the folded set is
        always a prefix).

        Returns the source-local OFFSET (not chunk count) of the first un-folded
        record == the `_base`-anchored folded watermark for this shard. Seeded at
        the shard's `_LOG_START.log_start_offset` so a RETIRED+REAPED prefix (its
        source chunks gone) is already accounted for and this walk only extends it
        with the still-live materialized chunks. A chunk that cannot be read
        restarts the walk from a `_LOG_START` that moved past it, or raises
        (chunk_walk.mojo). O(live shard chunks) — within the plan/materialize's
        existing per-shard walk bound."""
        var head = shard.read_head_authoritative()  # absent: chunk_seq -1
        var n_chunks = head.chunk_seq + Int64(1)
        var ls = shard.read_log_start()
        var running = ls.log_start_offset  # source-local base of the first chunk
        var folded = ls.log_start_offset  # seed: the retired/reaped prefix
        var seq = ls.log_start_seq if ls.log_start_seq >= Int64(0) else Int64(0)
        while seq < n_chunks:
            try:
                var body = ManifestBody.decode(shard.read_chunk(seq))
                if not body.has_segment():
                    # No segment object (a marker, 0 records): skip, do not
                    # break. Its record_count still advances `running`; it is
                    # not counted as folded (the fold never re-records it).
                    running += body.record_count
                    seq += Int64(1)
                    continue
                var rc = body.record_count
                if not _str_in(base_keys, body.object_key):
                    break  # first un-materialized chunk — the prefix boundary
                running += rc
                folded = running
                seq += Int64(1)
            except e:
                ls = restart_point_after_failed_read(
                    shard, seq, e^, "SegmentBaseInputs._base_folded_prefix"
                )
                running = ls.log_start_offset
                folded = ls.log_start_offset
                seq = ls.log_start_seq
        return folded

    def base_next_dense(self) raises -> Int64:
        """(c) The dense high-water where the un-folded tail begins == the SEGMENT
        `_base` broker manifest's `next_offset` (the offset allocator invariant:
        the manifest's next base offset == the cumulative committed record count ==
        the dense high-water, retention-stable). The plan assigns the tail's dense
        offsets starting HERE. Empty `_base` -> 0 (the whole partition is tail).
        Now computed ONCE, here — for BOTH the fold and the resolver. An absent
        `_base` reads as next_offset 0; an error reading its head raises."""
        var base = self.base_manifest()
        var head = base.read_head_authoritative()
        _ = base^
        return head.next_offset


# =============================================================================
# Free-function helpers (the `_base`-anchored folded-watermark derivation).
# =============================================================================


@always_inline
def _str_in(xs: List[String], v: String) -> Bool:
    """Membership test against the BOUNDED `_base` object_key set (O(live `_base`
    chunks)). A source chunk's `.seg` object_key is structurally unique, so an
    exact-string match decides whether the chunk is materialized in `_base`."""
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


# =============================================================================
# Cache-backed free helpers — the replays of the `_base`-folded-prefix
# derivation (BYTE-IDENTICAL to the store-reading `_base_folded_prefix`).
# =============================================================================


@always_inline
def _cached_shard_for(shards: List[_CachedShard], shard_id: String) -> Int:
    """Index of `shard_id` in the per-resolve shard cache, or -1 if absent
    (O(snapshot shards), bounded). A snapshot shard is always cached by the
    resolver before `folded_counts_cached`, so -1 means "no capture" (the
    watermark then contributes 0 — the same as the live no-`_LOG_START` path)."""
    for i in range(len(shards)):
        if shards[i].shard_id == shard_id:
            return i
    return -1


def _base_folded_prefix_cached(
    shard: _CachedShard, base_keys: List[String]
) -> Int64:
    """The CACHE-BACKED twin of `SegmentBaseInputs._base_folded_prefix`: replays
    the IDENTICAL derivation over the shard's CACHED chunk list instead of
    re-reading the store. BYTE-IDENTICAL by construction:
      * seed `running = folded = log_start_offset`, walk the cached chunks in
        the SAME source-local (seq) order, skip markers, BREAK at the first chunk
        whose `.seg` object_key is NOT in `base_keys`, else `running += rc;
        folded = running`.
    The cached chunk list was captured from `log_start_seq` up (the same start the
    live walk used) with the same marker / restart handling, so the replay visits
    the same chunks in the same order and computes the same prefix offset."""
    var running = shard.log_start_offset  # source-local base of the first chunk
    var folded = shard.log_start_offset  # seed: the retired/reaped prefix
    for i in range(len(shard.chunks)):
        ref c = shard.chunks[i]
        if not c.has_segment():
            # No segment object (a marker, 0 records): skip, do not break —
            # IDENTICAL to the live walk (`running` advances, `folded` not).
            running += c.record_count
            continue
        if not _str_in(base_keys, c.object_key):
            break  # first un-materialized chunk — the prefix boundary
        running += c.record_count
        folded = running
    return folded

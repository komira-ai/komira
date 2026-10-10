# =============================================================================
# komira_objectstore/sublineage_base_fold.mojo
#   The Kafka-face `_base` FOLD orchestrator: the keystone of sub-lineage
#   torn-offset correctness.
# =============================================================================
#
# THE MODEL — MATERIALIZE + RETIRE (design scheme B), NOT a growing map.
# ---------------------------------------------------------------------------
# The fold MATERIALIZES folded chunk-entries into `_base` as a NORMAL dense-
# ordered manifest lineage (`_base` is itself a plain `CasManifestStore`). Each
# `_base` chunk records ONE folded block — a contiguous run of a source shard's
# local offsets — in DENSE order, so `_base`'s own gapless manifest offset IS
# the dense Kafka offset. A folded dense offset O is resolved by reading `_base`
# BY OFFSET (exactly like a single-manifest partition: walk the chunk
# record_counts to the chunk whose `[base, base+count)` spans O — amortized O(1)
# for a sequential consumer, retention-managed). There is NO per-(shard, local)
# mapping for folded records — that growing map (the prior impl) was UNBOUNDED
# under multi-grower steady state (each fold round strided a shard's dense
# offsets, so the entries were local-contiguous but dense-non-contiguous, the
# collapse merged nothing, and the persisted state grew N x rounds).
# MATERIALIZE+RETIRE eliminates that map entirely.
#
# After folding a shard's `[already .. snap_total)` records into `_base`, the
# fold RETIRES (tombstones) the now-folded SOURCE-shard chunks, so the source-
# shard storage is reclaimable by the existing reaper and the live un-folded
# tail is just the sub-lineage chunks NOT yet folded. The ONLY cross-shard
# resolution state is that live tail, BOUNDED by the fold cadence (live-shard
# width x records-since-fold = a few tens), NEVER by total rounds/records.
#
# The reaped-shard resolution is then trivially satisfied: folded
# offsets live in `_base`; `_base` itself is retention-managed, so a folded O
# whose `_base` chunk has fallen below `_base`'s log-start surfaces the REAPED
# sentinel via the normal retention path; no growing mapping to GC. The `_base`
# chunk also retains the (source_shard_id, source_local) BINDING + the source
# payloads, so even after the SOURCE shard's chunks are reaped, `_base` still
# resolves O to its stable record (the binding survives; only a `_base`-reaped O
# is REAPED).
#
# THE FOLD (the frozen fold contract). Dense offsets are assigned by walking the
# snapshot's shards in shard_id BYTE-WISE LEXICOGRAPHIC order; WITHIN a shard in
# (chunk_seq asc, intra-chunk record-index asc) order — the shard's own gapless
# local-offset order. NO floating point, NO hash, NO process/thread/wall-clock
# input anywhere in the ordering. `_canonical_shard_less` is the SOLE comparator;
# `_sort_shard_ids` the SOLE sort. The same snapshot fed to two independent folds
# produces byte-identical assignments (DETERMINISM). A later fold APPENDS new `_base`
# chunks; it NEVER renumbers, so a dense offset O keeps its record forever
# (ADDITIVITY). Resumability across the un-folded-tail <-> `_base` boundary survives a
# fold-process restart because `_base` is durable (RESUMABILITY).
#
# SNAPSHOT BOUNDARY. A fold first pins each live shard's AUTHORITATIVE
# HEAD (`read_head_authoritative` — bypasses the best-effort `_HEAD` cache and
# LIST-recovers the TRUE tail, the recent stale-low-cache fix) at a commit
# boundary. Records appended after the boundary fold in a later fold (ADDITIVITY).
#
# `_base` SINGLE-WRITER CAS. The fold publishes each `_base` chunk via
# the SAME If-None-Match CAS append the writer shards use. Each append ASSERTS
# `_base.base_offset == computed dense base` (the fold lineage is gapless, so its
# own manifest offset IS the dense offset) AND `_base.last_offset == base+count-1`
# (contiguity). Each `_base` chunk carries a CRC over its binding tuple so a
# corrupt chunk fail-louds on reload rather than serving a wrong binding.
#
# DURABLE compaction = RETENTION, not clear+reappend. Compaction here means
# RETENTION of `_base` below a folded watermark (the existing log-start advance +
# reaper machinery), NOT an in-place clear+reappend of `_base` (a concurrent
# reader could see an empty `_base`). `_base` is ALWAYS
# readable. The bound on persistent resolution state is therefore the SAME as a
# single-manifest partition: O(live `_base` chunks above log-start) + O(live
# un-folded tail) — both retention/cadence bounded, NOT N x rounds.
#
# DEFAULT-OFF. The fold + `_base` are part of the sub-lineage mode, which is OFF
# by default (a broker flag). The fold WRITES `_base`; the consume side does
# NOT read it yet.
#
# -----------------------------------------------------------------------------
# Encapsulation / heap-reuse.
#   * ZERO UnsafePointer in any signature; everything is value / List[UInt8] /
#     POD. ZERO wildcard origins. ZERO unsafe_from_address.
#   * The fold's in-memory tables are plain `List[...]` value structs — NOT
# byte-slab elements, so heap-reuse is N/A (no Movable struct with a heap-owning
#     field stored in a byte-backed slab under a wildcard cast). The PERSISTED
#     `_base` chunk bodies are plain `List[UInt8]` (the CAS-manifest opaque-body
#     contract).
#   * No CasManifestStore change — each sub-lineage + `_base` is a PLAIN
#     CasManifestStore; the sharding + fold logic lives entirely above it. All
#     raw key arithmetic stays INSIDE this module.
# =============================================================================

from komira_objectstore.cas_manifest import (
    AppendResult,
    CasManifestStore,
    LogStart,
    RetryPolicy,
    is_not_found,
    _get_i64_le,
    _put_i64_le,
)
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.types import ListResult


# =============================================================================
# Key layout — disjoint sub-lineage prefixes under ONE partition.
# =============================================================================
#
#   <part>/_lineage/<shard_id>/manifest/<seq>.chunk    ← a writer shard
#   <part>/_lineage/_base/manifest/<seq>.chunk         ← the fold lineage
#
# `_base` is the reserved shard_id the fold materializes into. The fold's LIST
# enumeration of `<part>/_lineage/` EXCLUDES `_base` (it is the fold's own
# output, not an input shard). This mirrors the broker's `sublineage_prefix`.
# -----------------------------------------------------------------------------

comptime BASE_SHARD_ID: String = "_base"
comptime _LINEAGE_SEGMENT: String = "/_lineage/"


@always_inline
def sublineage_prefix(part: String, shard_id: String) -> String:
    """The CAS-manifest lineage prefix for `shard_id` under partition `part`.
    A writer shard and `_base` differ only by the shard_id segment — both are
    plain `CasManifestStore` prefixes (disjoint keyspaces, no shared slot).
    Matches the broker's `partition_assignment.sublineage_prefix` exactly."""
    return part + _LINEAGE_SEGMENT + shard_id


@always_inline
def _lineage_enum_prefix(part: String) -> String:
    """The LIST-enumeration prefix for a partition's live sub-lineages:
    `<part>/_lineage/`. A LIST of this prefix yields every shard's keys; the
    fold folds them on the first `/` after this prefix to recover the distinct
    `<shard_id>` set (backend-agnostic — does NOT rely on store-side
    common_prefixes, which some conformers leave empty)."""
    return part + _LINEAGE_SEGMENT


# =============================================================================
# Record body codec — a writer-shard chunk body is a flat list of i64 record
# payloads. `record_count` (manifest envelope) + body recover each record's
# identity. A "record" here is one i64 payload (a stand-in for a Kafka record's
# bytes). The fold needs payloads to PROVE offset->record stability.
# =============================================================================


def encode_record_body(records: List[Int64]) -> List[UInt8]:
    """Encode a batch of i64 record payloads as a chunk body."""
    var out = List[UInt8]()
    for i in range(len(records)):
        _put_i64_le(out, records[i])
    return out^


def decode_record_body(body: List[UInt8], record_count: Int64) raises -> List[Int64]:
    """Decode `record_count` i64 payloads from a chunk body."""
    var out = List[Int64]()
    var n = Int(record_count)
    if 8 * n > len(body):
        raise Error("sublineage_base_fold: record body truncated")
    for i in range(n):
        out.append(_get_i64_le(body, 8 * i))
    return out^


# =============================================================================
# CANONICAL ORDER. The SOLE comparator + the SOLE sort.
# =============================================================================


@always_inline
def _canonical_shard_less(a: String, b: String) -> Bool:
    """The ONE canonical ordering rule: shard_id byte-wise lexicographic `<`.
    No FP, no hash, no PID/thread/wall-clock. This is the entire determinism
    contract for DETERMINISM."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab) if len(ab) < len(bb) else len(bb)
    for i in range(n):
        if ab[i] != bb[i]:
            return ab[i] < bb[i]
    return len(ab) < len(bb)


def _sort_shard_ids(var ids: List[String]) -> List[String]:
    """Insertion sort by `_canonical_shard_less` — deterministic, no PRNG, no
    hash bucketing. Insertion sort is O(n^2) but the live-shard count is tiny
    (a few tens per hot partition by the cadence bound) and the point is
    DETERMINISM, not speed."""
    var n = len(ids)
    for i in range(1, n):
        var j = i
        while j > 0 and _canonical_shard_less(ids[j], ids[j - 1]):
            var tmp = ids[j].copy()
            ids[j] = ids[j - 1].copy()
            ids[j - 1] = tmp^
            j -= 1
    return ids^


# =============================================================================
# ShardSnapshot — one shard's PINNED commit boundary.
# =============================================================================
#
# `(shard_id, snap_chunk_seq, snap_record_total)`. `snap_record_total` is the
# total record count across `[0 .. snap_chunk_seq]` (= head.next_offset; the
# manifest's next base offset IS the cumulative record count, allocator
# invariant). Records appended AFTER the boundary are NOT folded by THIS fold.
# -----------------------------------------------------------------------------


@fieldwise_init
struct ShardSnapshot(Copyable, Movable, Deinitable):
    var shard_id: String
    var snap_chunk_seq: Int64  # highest committed chunk_seq at the boundary (-1 = empty)
    var snap_record_total: Int64  # total records across [0 .. snap_chunk_seq]


# =============================================================================
# FoldBlockAssignment — ONE canonical dense-offset block (the SHARED merge unit).
# =============================================================================
#
# The SOLE shared product of the canonical merge. Both the FOLD
# (fold-persist) and the consume SERVE path (serve-assign) compute their dense
# offsets from the SAME `plan_assignment` (below), which emits a list of these
# blocks. A block says: source-shard `shard_id`'s local offsets
# `[source_local_base .. source_local_base+count)` map to dense offsets
# `[dense_base .. dense_base+count)`. The fold MATERIALIZES each block into a
# `_base` chunk (persist); the serve path RESOLVES each block's dense offsets to
# records WITHOUT persisting (virtual fold). Because both consume the IDENTICAL
# plan, serve == fold byte-for-byte ("merge-assigns-at-serve, fold-persists"):
# when the fold later runs over the SAME snapshot it persists the IDENTICAL
# assignment, so a committed tail dense offset O resolves to the SAME record pre-
# and post-fold (no torn offset).
#
# POD-ish value (one owned String + three Int64s). NOT a byte-slab element —
# heap-reuse N/A (a stack/transient `List[FoldBlockAssignment]`, never an OwnedSlab /
# AtomicSlab element under a wildcard cast).
# -----------------------------------------------------------------------------


@fieldwise_init
struct FoldBlockAssignment(Copyable, Movable, Deinitable):
    var shard_id: String  # the source sub-lineage shard this block came from
    var source_local_base: Int64  # first un-folded source-local offset
    var dense_base: Int64  # first dense offset assigned to this block
    var count: Int64  # records in this block

    @always_inline
    def dense_last(self) -> Int64:
        return self.dense_base + self.count - Int64(1)

    @always_inline
    def contains_dense(self, o: Int64) -> Bool:
        return o >= self.dense_base and o < self.dense_base + self.count


def plan_assignment(
    sorted_snap: List[ShardSnapshot],
    folded_counts: List[ShardFoldedWatermark],
    dense_hw_start: Int64,
) -> List[FoldBlockAssignment]:
    """The SOLE canonical dense-offset assignment (shared by both
    fold-persist and serve-assign). Walk `sorted_snap` (already canonical-sorted
    by shard_id) in order; for each shard, fold ONLY its un-folded tail
    `[already .. snap_record_total)` (`already` = the shard's `folded_count`, or 0
    if absent), and assign dense offsets CONTIGUOUSLY starting at `dense_hw_start`.

    This is a PURE function of (canonical-sorted snapshot, per-shard already-
    folded counts, dense_hw start) — NO FP, NO hash, NO process/thread/wall-clock,
    NO source-record content. The dense layout therefore depends ONLY on the
    snapshot boundary + the canonical order, so:
      * the FOLD calls this to decide which blocks to MATERIALIZE into `_base`;
      * the consume SERVE path calls this (with the SAME snapshot + the SAME
        folded_counts derived from `_base.head`) to assign the un-folded tail's
        dense offsets WITHOUT persisting.
    Identical inputs -> identical output -> serve == fold. A later fold over
    the same snapshot persists the identical blocks (additive; never renumbers).
    The caller is responsible for canonical-sorting `sorted_snap` first
    (`_sort_snapshot` / `_sort_shard_ids`)."""
    var out = List[FoldBlockAssignment]()
    var dense_hw = dense_hw_start
    for i in range(len(sorted_snap)):
        ref ss = sorted_snap[i]
        var already = _folded_count_in(folded_counts, ss.shard_id)
        var to_fold = ss.snap_record_total - already
        if to_fold <= Int64(0):
            continue
        out.append(
            FoldBlockAssignment(ss.shard_id, already, dense_hw, to_fold)
        )
        dense_hw += to_fold
    return out^


@always_inline
def _folded_count_in(
    folded_counts: List[ShardFoldedWatermark], shard_id: String
) -> Int64:
    """How many of `shard_id`'s source locals are already folded, from the
    BOUNDED watermark list (O(distinct shards)). 0 if absent."""
    for i in range(len(folded_counts)):
        ref w = folded_counts[i]
        if w.shard_id == shard_id:
            return w.folded_count
    return Int64(0)


# =============================================================================
# ShardFoldedWatermark — the BOUNDED per-shard fold-progress cursor.
# =============================================================================
#
# `(shard_id, folded_count)`: "this shard's local offsets [0 .. folded_count)
# have been materialized into `_base`". The fold folds ONLY
# `[folded_count .. snap_record_total)` for a shard (ADDITIVITY). There
# is EXACTLY ONE row per distinct shard EVER folded — O(distinct shards), NOT
# O(rounds). This is the WHOLE persistent cross-shard state; the per-(shard,
# local)->dense map is GONE. The watermark is REBUILT purely from `_base` on a
# restart (each `_base` chunk's binding carries its source shard + the
# running-max local makes the watermark), so it is not separately persisted —
# `_base` is the single durable source of truth.
# -----------------------------------------------------------------------------


@fieldwise_init
struct ShardFoldedWatermark(Copyable, Movable, Deinitable):
    var shard_id: String
    var folded_count: Int64  # source-local offsets [0..folded_count) are in _base


# =============================================================================
# BaseChunkEntry — the decoded view of ONE `_base` chunk (a folded block).
# =============================================================================
#
# `(source_shard_id, source_local_base, dense_base, count, payloads)`. `_base`
# chunk `k` materialized source-shard `source_shard_id`'s local offsets
# `[source_local_base .. source_local_base+count)` at dense offsets
# `[dense_base .. dense_base+count)` (dense_base = `_base`'s own gapless manifest
# base offset for chunk `k`). `payloads` are the source records re-recorded in
# `_base` so resolution is SELF-CONTAINED from `_base` (survives source reaping).
# -----------------------------------------------------------------------------


@fieldwise_init
struct BaseChunkEntry(Copyable, Movable, Deinitable):
    var source_shard_id: String
    var source_local_base: Int64
    var dense_base: Int64
    var count: Int64
    var payloads: List[Int64]

    @always_inline
    def dense_last(self) -> Int64:
        return self.dense_base + self.count - Int64(1)

    @always_inline
    def contains_dense(self, o: Int64) -> Bool:
        return o >= self.dense_base and o < self.dense_base + self.count


# =============================================================================
# ResolvedRecord — the answer to "what record is at dense offset O?"
# =============================================================================


@fieldwise_init
struct ResolvedRecord(Copyable, Movable, Deinitable):
    var found: Bool
    var shard_id: String
    var local_offset: Int64
    var payload: Int64  # the record's stable identity payload; -2 = REAPED sentinel


comptime REAPED_PAYLOAD_SENTINEL: Int64 = -2


# =============================================================================
# FoldStats — what one fold round did (for the cadence + observability).
# =============================================================================


@fieldwise_init
struct FoldStats(Copyable, Movable, Deinitable):
    var dense_high_water: Int64  # next dense offset a future fold will assign
    var records_folded: Int64  # records folded by THIS round (0 = no-op)
    var live_shard_count: Int  # shards enumerated at this fold's boundary
    var base_chunks_appended: Int  # _base chunks this round appended


# =============================================================================
# BoundStats — the persistent-resolution-state bound (the reaped-source probe knobs).
# =============================================================================
#
# The materialize+retire model's bound has TWO components, BOTH bounded:
#   * `live_base_chunks`  — `_base` chunks ABOVE `_base`'s log-start (folded
#     blocks not yet retention-reaped). Retention-managed exactly like a single-
#     manifest partition; NOT N x rounds. Compaction = advancing the `_base`
#     log-start, which shrinks this.
#   * `live_tail_watermarks` — distinct shards with un-folded tail records, i.e.
#     `snap_total > folded_count`. Bounded by the live-shard width (cadence).
# The test asserts BOTH stay bounded under a sustained multi-grower interleave —
# they do NOT grow with total rounds/records (the old growing-map NO-GO).
# -----------------------------------------------------------------------------


@fieldwise_init
struct BoundStats(Copyable, Movable, Deinitable):
    var live_base_chunks: Int  # _base chunks above _base log-start
    var distinct_folded_shards: Int  # watermark rows (== distinct shards folded)
    var live_tail_shards: Int  # shards with un-folded tail at this instant


# =============================================================================
# `_base` chunk-body codec for a single folded block. Versioned envelope:
#   [ version i64 LE ][ source_local_base i64 LE ][ crc32 i64 LE ]
#   [ source_shard_id_len i64 LE ][ source_shard_id bytes... ]
#   [ payload_0 i64 LE ][ payload_1 ]...[ payload_{count-1} ]
# (count comes from the manifest envelope's record_count; the dense_base comes
# from `_base`'s own manifest base offset — neither is re-stored here.)
# The CRC is over (source_local_base, count, source_shard_id, payloads) so a
# corrupt `_base` chunk fail-louds on reload rather than serving a wrong record.
# =============================================================================

comptime _BASE_CHUNK_VERSION: Int64 = 2


@always_inline
def _crc32_update(crc: UInt32, b: UInt8) -> UInt32:
    var c = crc ^ UInt32(Int(b))
    for _ in range(8):
        if (c & UInt32(1)) != UInt32(0):
            c = (c >> UInt32(1)) ^ UInt32(0xEDB88320)
        else:
            c = c >> UInt32(1)
    return c


def _block_crc(
    source_shard_id: String, source_local_base: Int64, payloads: List[Int64]
) -> UInt32:
    """CRC-32 over (source_local_base, count)[LE i64] ++ payloads[LE i64] ++
    source_shard_id bytes. Deterministic — no hash-with-seed, no address."""
    var crc = UInt32(0xFFFFFFFF)
    var buf = List[UInt8]()
    _put_i64_le(buf, source_local_base)
    _put_i64_le(buf, Int64(len(payloads)))
    for i in range(len(payloads)):
        _put_i64_le(buf, payloads[i])
    var sb = source_shard_id.as_bytes()
    for i in range(len(sb)):
        buf.append(sb[i])
    for i in range(len(buf)):
        crc = _crc32_update(crc, buf[i])
    return crc ^ UInt32(0xFFFFFFFF)


def _encode_base_chunk(
    source_shard_id: String, source_local_base: Int64, payloads: List[Int64]
) -> List[UInt8]:
    var out = List[UInt8]()
    _put_i64_le(out, _BASE_CHUNK_VERSION)
    _put_i64_le(out, source_local_base)
    _put_i64_le(
        out,
        Int64(Int(_block_crc(source_shard_id, source_local_base, payloads))),
    )
    var sb = source_shard_id.as_bytes()
    _put_i64_le(out, Int64(len(sb)))
    for i in range(len(sb)):
        out.append(sb[i])
    for i in range(len(payloads)):
        _put_i64_le(out, payloads[i])
    return out^


def _decode_base_chunk(
    body: List[UInt8], record_count: Int64, dense_base: Int64
) raises -> BaseChunkEntry:
    var version = _get_i64_le(body, 0)
    if version != _BASE_CHUNK_VERSION:
        raise Error(
            "sublineage_base_fold: unknown _base chunk version "
            + String(version)
        )
    var source_local_base = _get_i64_le(body, 8)
    var stored_crc = UInt32(Int(_get_i64_le(body, 16)))
    var sid_len = Int(_get_i64_le(body, 24))
    # BYTE-EXACT decode of the shard-id run. ⛔ NOT `sid += chr(Int(body[...]))`:
    # `_encode_base_chunk` writes `source_shard_id`'s bytes RAW, and the decoded
    # `sid` is fed straight back into `_block_crc(sid, ...)` and compared against
    # the CRC computed over the ORIGINAL. A `chr` decode re-encodes every byte
    # >= 0x80 into two, so a non-ASCII shard id made a PERFECTLY GOOD block
    # report itself CORRUPT ("_base chunk CRC mismatch").
    var sid_bytes = List[UInt8]()
    for i in range(sid_len):
        sid_bytes.append(body[32 + i])
    var sid = String(StringSlice(unsafe_from_utf8=Span(sid_bytes)))
    var count = Int(record_count)
    var payloads = List[Int64]()
    var off = 32 + sid_len
    for i in range(count):
        payloads.append(_get_i64_le(body, off + 8 * i))
    var got_crc = _block_crc(sid, source_local_base, payloads)
    if got_crc != stored_crc:
        raise Error(
            "sublineage_base_fold: _base chunk CRC mismatch (corrupt block):"
            " stored="
            + String(Int(stored_crc))
            + " computed="
            + String(Int(got_crc))
        )
    return BaseChunkEntry(
        sid^, source_local_base, dense_base, record_count, payloads^
    )


# =============================================================================
# SubLineageBaseFold — the PRODUCTION fold orchestrator (materialize + retire).
# =============================================================================
#
# Generic over `[Store: CloneableConditionalWriteStore]` (the broker sub-lineage pattern):
# one store handle is `clone()`d per sub-lineage + per `_base` access, so they all
# reach the SAME logical bucket (one S3 bucket, N prefixes). The fold's only
# persistent state is `_base` (durable) + the rebuildable in-memory
# `_watermarks` cursor + a cached `_base` chunk index (the live-resolution
# state); `reload_from_base` rebuilds BOTH purely from the persisted `_base`
# (fold-process restart durability).
# -----------------------------------------------------------------------------


struct SubLineageBaseFold[Store: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    var _store: Self.Store
    var _part: String
    # The BOUNDED per-shard fold cursor (one row per distinct shard ever folded).
    var _watermarks: List[ShardFoldedWatermark]
    # The in-memory index of LIVE `_base` chunks (above `_base` log-start) — the
    # folded-offset resolution state. Bounded by retention, NOT by total rounds.
    var _base_chunks: List[BaseChunkEntry]
    # The dense offset below which `_base` chunks have been retention-reaped
    # (compaction). A folded O < `_base_log_start_offset` resolves REAPED.
    var _base_log_start_offset: Int64
    # The `_base` manifest chunk_seq of the FIRST live block (reaped blocks below
    # advance this). `_base` is gapless one-block-per-chunk, so a live block's
    # absolute chunk_seq == `_base_log_start_seq` + its ordinal in `_base_chunks`.
    var _base_log_start_seq: Int64
    # The dense high-water EVER assigned (incl. reaped-below blocks) — lets a
    # `_base`-reaped O be recognized as folded (REAPED sentinel, not not-found).
    var _dense_hw_ever: Int64

    def __init__(out self, var store: Self.Store, var part: String):
        self._store = store^
        self._part = part^
        self._watermarks = List[ShardFoldedWatermark]()
        self._base_chunks = List[BaseChunkEntry]()
        self._base_log_start_offset = Int64(0)
        self._base_log_start_seq = Int64(0)
        self._dense_hw_ever = Int64(0)

    # ---- shard handle construction (one CasManifestStore per sub-lineage) ----

    def _shard_store(
        self, shard_id: String
    ) raises -> CasManifestStore[Self.Store]:
        """A fresh `CasManifestStore` bound to `shard_id`'s sub-lineage prefix,
        backed by a clone() of the shared store (same logical bucket)."""
        return CasManifestStore[Self.Store](
            self._store.clone(),
            sublineage_prefix(self._part, shard_id),
            RetryPolicy.fast_test(),
        )

    # ---- a writer appends a batch to ITS shard (sole-writer, no contention) ----
    # (Test convenience; production writers use the broker sub-lineage write path.)

    def append_batch(
        mut self, shard_id: String, records: List[Int64]
    ) raises -> AppendResult:
        """Append a batch of records to `shard_id`'s sub-lineage — a plain
        `CasManifestStore.append`. The shard's LOCAL offset is the manifest's
        gapless base/last offset (UNAFFECTED by the fold)."""
        var s = self._shard_store(shard_id)
        var body = encode_record_body(records)
        var r = s.append(body, Int64(len(records)))
        _ = s^
        return r^

    # ---- NET-NEW: LIST-enumerate live sub-lineages under <part>/_lineage/* ----

    def enumerate_live_shards(self) raises -> List[String]:
        """DISCOVER the live sub-lineage shard_ids by LISTing `<part>/_lineage/`
        and folding each key on the first `/` after the prefix. Backend-agnostic:
        does NOT rely on store-side `common_prefixes` (some conformers leave it
        empty); it derives the distinct shard segment from the OBJECT keys. The
        reserved `_base` shard is EXCLUDED (it is the fold's own output). The
        result is canonical-sorted so the snapshot + fold are order-stable."""
        var enum_prefix = _lineage_enum_prefix(self._part)
        var listing = self._store.list_with_delimiter(Path.parse(enum_prefix))
        var seen = List[String]()
        # Prefer store-provided common_prefixes when present (S3 fast path), but
        # ALWAYS also fold the object keys (the authoritative, backend-agnostic
        # source). Dedup by membership.
        for i in range(len(listing.common_prefixes)):
            var seg = _shard_from_common_prefix(
                listing.common_prefixes[i], enum_prefix
            )
            if seg.byte_length() > 0 and seg != BASE_SHARD_ID:
                _append_unique(seen, seg)
        for i in range(len(listing.objects)):
            var seg = _shard_from_object_key(
                listing.objects[i].location, enum_prefix
            )
            if seg.byte_length() > 0 and seg != BASE_SHARD_ID:
                _append_unique(seen, seg)
        return _sort_shard_ids(seen^)

    # ---- snapshot all LIVE shards at a PINNED commit boundary ----

    def snapshot(self) raises -> List[ShardSnapshot]:
        """Pin every LIVE shard's AUTHORITATIVE head into a snapshot set. Uses
        `read_head_authoritative` (LIST-recovers the TRUE tail, bypassing the
        best-effort `_HEAD` cache — the stale-low-cache fix), so the boundary is
        the true highest-committed chunk. Iterates in CANONICAL order so the
        snapshot itself is order-stable (two snapshots of the same committed
        universe are identical lists). A shard whose chunks are ALL already
        folded+reaped pins an empty tail; an error reading a shard's head
        raises."""
        var ids = self.enumerate_live_shards()
        var out = List[ShardSnapshot]()
        for i in range(len(ids)):
            var sid = ids[i]
            var s = self._shard_store(sid)
            # An absent or fully reaped shard reads as an empty tail (it does
            # not raise); a read error raises rather than drop a live shard.
            var head = s.read_head_authoritative()
            out.append(ShardSnapshot(sid, head.chunk_seq, head.next_offset))
            _ = s^
        return out^

    # ---- DETERMINISM + ADDITIVITY: the deterministic, offset-preserving fold ----

    def fold(mut self, snap: List[ShardSnapshot]) raises -> FoldStats:
        """MATERIALIZE every record in `snap` NOT yet folded into `_base` in
        CANONICAL order, then RETIRE the now-folded source chunks. Each folded
        block is published as ONE `_base` chunk via single-writer If-None-Match
        CAS with the base==dense + contiguity assertions + the block CRC.
        Returns FoldStats.

        DETERMINISM (DETERMINISM): the only ordering input is `_canonical_shard_less`
        over the snapshot's shard_ids + each shard's local-offset order.

        ADDITIVITY (ADDITIVITY): for each shard `already` = `folded_count` from the
        watermark; fold ONLY `[already .. snap_record_total)`. A record that
        already has a dense offset (already materialized in `_base`) KEEPS it —
        the fold APPENDS new `_base` chunks, NEVER renumbers."""
        var dense_hw = self._dense_high_water()
        var sorted_snap = self._sort_snapshot(snap)
        # SHARED CANONICAL MERGE: the dense-offset assignment is the
        # SOLE product of `plan_assignment` — the IDENTICAL function the consume
        # SERVE path calls. The fold MATERIALIZES each planned block; the serve
        # path RESOLVES the same plan WITHOUT persisting. Same code -> serve ==
        # fold (no torn offset). `serve_assign_tail` exposes this plan to consume.
        var plan = plan_assignment(sorted_snap, self._watermarks, dense_hw)
        var records_folded = Int64(0)
        var chunks_appended = 0
        for i in range(len(plan)):
            ref blk = plan[i]
            # MATERIALIZE: read this block's source records and publish them as
            # ONE dense `_base` chunk at the plan's dense_base.
            var payloads = self._read_source_range(
                blk.shard_id, blk.source_local_base, blk.count
            )
            self._materialize_block(
                blk.shard_id, blk.source_local_base, blk.dense_base, payloads
            )
            # RETIRE: tombstone the now-fully-folded source chunks (reclaimable).
            self._retire_folded_source(
                blk.shard_id, blk.source_local_base + blk.count
            )
            self._advance_watermark(
                blk.shard_id, blk.source_local_base + blk.count
            )
            records_folded += blk.count
            chunks_appended += 1
        return FoldStats(
            dense_hw + records_folded,
            records_folded,
            len(sorted_snap),
            chunks_appended,
        )

    # ---- run-once orchestration: snapshot + fold in one call ----

    def run_once(mut self) raises -> FoldStats:
        """Snapshot the live sub-lineages at a boundary and fold them. The
        production entry point a cadence trigger calls."""
        var snap = self.snapshot()
        return self.fold(snap^)

    # ---- serve-assign — the un-folded tail's dense plan, NO persist --

    def base_head_next_dense(self) -> Int64:
        """The dense offset where the un-folded tail begins (== `_base`'s next
        dense offset, the running fold high-water). The serve path assigns the
        tail's dense offsets starting HERE, exactly as the next fold will."""
        return self._dense_high_water()

    def serve_assign_tail(self) raises -> List[FoldBlockAssignment]:
        """SERVE-ASSIGN (the SHARED canonical merge, fold-free). Pin the
        SAME authoritative snapshot the fold pins (`snapshot()` ->
        `read_head_authoritative` per live shard, canonical-sorted), then run the
        SAME `plan_assignment` the `fold` runs — starting at `_base.head + 1`
        (`base_head_next_dense`) — but WITHOUT materializing/retiring anything.

        This is the "virtual fold" / "merge-assigns-at-serve, fold-persists" half
        of the fold contract: the dense->record assignment for the live un-folded tail is the
        BYTE-IDENTICAL assignment the fold WILL persist (same snapshot boundary,
        same canonical order, same `plan_assignment`, same `dense_hw` start), so a
        consumer that commits a dense offset O in the served tail resolves O to
        the SAME record after the tail folds into `_base` (no torn offset). The
        consume core maps each returned block's `[source_local_base ..
        source_local_base+count)` to the source sub-lineage's segments to build
        the dense `SegmentRef`s for the tail."""
        var snap = self.snapshot()
        var sorted_snap = self._sort_snapshot(snap)
        return plan_assignment(
            sorted_snap, self._watermarks, self._dense_high_water()
        )

    def serve_assign_tail_for(
        self, snap: List[ShardSnapshot]
    ) raises -> List[FoldBlockAssignment]:
        """Like `serve_assign_tail` but over a CALLER-PINNED snapshot (so the
        consume core can pin the snapshot boundary ONCE and use it both for the
        plan and for the per-segment mapping — a single consistent boundary).
        Canonical-sorts then runs the SAME `plan_assignment`."""
        var sorted_snap = self._sort_snapshot(snap)
        return plan_assignment(
            sorted_snap, self._watermarks, self._dense_high_water()
        )

    def serve_assign_tail_explicit(
        self,
        snap: List[ShardSnapshot],
        folded_counts: List[ShardFoldedWatermark],
        dense_hw_start: Int64,
    ) -> List[FoldBlockAssignment]:
        """Serve-assign with CALLER-SUPPLIED `folded_counts` +
        `dense_hw_start` (the format-decoupled entry point). Reuses the SAME
        `_sort_snapshot` (the SOLE canonical sort) + the SAME `plan_assignment`
        (the SOLE assignment authority) the fold uses — only the two scalars
        (per-shard already-folded counts + the dense high-water) are sourced by
        the caller instead of read from the i64-format `_base` index.

        This is the entry point a SEGMENT-level consumer (the broker, whose `_base`
        is a broker manifest of segments, NOT i64 payloads) uses: it supplies the
        per-shard `folded_count` from each source shard's durable `_LOG_START`
        (the retire-advanced fold cursor the fold persists) + the `dense_hw_start`
        from its own `_base` manifest's next dense offset. The RESULTING plan is
        BYTE-IDENTICAL to what `serve_assign_tail` (and the fold) produce when fed
        the SAME inputs — because it is the IDENTICAL sort + `plan_assignment`
        code. This is how serve == fold for a segment-granular `_base`."""
        var sorted_snap = self._sort_snapshot(snap)
        return plan_assignment(sorted_snap, folded_counts, dense_hw_start)

    def snapshot_explicit(self) raises -> List[ShardSnapshot]:
        """Pin the authoritative snapshot of every live source sub-lineage (the
        SAME `snapshot()` the fold pins) WITHOUT requiring the i64-`_base` state to
        be loaded — `snapshot()` reads ONLY the SOURCE sub-lineage manifests
        (`read_head_authoritative` per live shard), which are format-agnostic
        (broker or i64). Re-exposed under an explicit name so a segment-level
        caller (the broker) can pin the boundary, then call
        `serve_assign_tail_explicit` with its own folded_counts + dense_hw."""
        return self.snapshot()

    # ---- demand-driven cadence (bound live-lineage width L <= B*(1/F + grace)) ----

    def should_fold(
        self,
        live_shard_threshold: Int,
        ms_since_last_fold: Int64,
        timer_interval_ms: Int64,
    ) raises -> Bool:
        """Cadence trigger: fold when the live-lineage count exceeds
        `live_shard_threshold` (target a few tens per hot partition) OR the timer
        elapsed (`ms_since_last_fold >= timer_interval_ms`). Bounds the live-
        lineage width so consume-side fan-out stays small. Threshold-OR-timer
        keeps a low-traffic partition's tail folded too (the timer floor)."""
        var live = len(self.enumerate_live_shards())
        if live > live_shard_threshold:
            return True
        if timer_interval_ms > Int64(0) and ms_since_last_fold >= timer_interval_ms:
            return live > 0
        return False

    # ---- COMPACTION = RETENTION of `_base` below a folded watermark ----

    def compact(mut self, retain_from_dense: Int64 = Int64(0)) raises -> Int:
        """RETENTION-compact `_base`: advance the `_base` log-start to
        `retain_from_dense` and tombstone+reap every `_base` chunk fully BELOW
        it. This is the materialize+retire model's compaction — it is the SAME
        retention machinery a single-manifest partition uses, NOT a clear+
        reappend (which is non-durable: a concurrent reader
        could observe an empty `_base`). `_base` stays ALWAYS readable; only
        chunks below the retained watermark are reclaimed. Returns the number of
        LIVE `_base` chunks remaining (the persistent folded-resolution state —
        retention-bounded, NOT N x rounds).

        A folded dense offset O < the retained watermark thereafter resolves to
        the REAPED sentinel (the normal retention path), exactly as a reaped
        prefix in a single-manifest partition does. A `retain_from_dense` at or
        below the current floor (the default 0 included) retires nothing new; it
        reaps only `_base` tombstones left below the log start by an earlier
        compaction that failed or was interrupted (one GET + one LIST), then
        reports the live count."""
        if retain_from_dense > self._base_log_start_offset:
            self._retire_base_below(retain_from_dense)
        else:
            # Nothing new to retire: still reclaim what an earlier compaction
            # retired but did not finish reaping (`_reap_retired_base`).
            var base = self._shard_store(BASE_SHARD_ID)
            self._reap_retired_base(base)
            _ = base^
        return len(self._base_chunks)

    # ---- RESUMABILITY + reaped-shard resolution: resolve a dense offset O to its record ----

    def resolve_offset(self, o: Int64) raises -> ResolvedRecord:
        """Resolve dense offset O -> the record at O by reading `_base` BY OFFSET
        (the materialize+retire model — NO per-(shard, local) map). For a folded
        O above `_base`'s log-start, the live `_base` chunk index gives the
        (source_shard, source_local) binding + the materialized payload in O(1)
        amortized (sequential consumer). A folded O BELOW `_base`'s log-start
        (retention-reaped) surfaces the REAPED sentinel — never a wrong record,
        never unresolvable. REAPED-SOURCE: even after the SOURCE shard is reaped, the
        `_base` chunk retains the binding + payload, so a live-`_base` O still
        resolves its stable record; only a `_base`-reaped O is REAPED."""
        # Below the retained `_base` log-start: a folded-then-reaped offset.
        if o < self._base_log_start_offset and self._offset_was_folded(o):
            return ResolvedRecord(
                True, self._reaped_binding_shard(o), Int64(-1),
                REAPED_PAYLOAD_SENTINEL,
            )
        for i in range(len(self._base_chunks)):
            ref e = self._base_chunks[i]
            if e.contains_dense(o):
                var idx = Int(o - e.dense_base)
                var local = e.source_local_base + (o - e.dense_base)
                return ResolvedRecord(
                    True, e.source_shard_id, local, e.payloads[idx]
                )
        return ResolvedRecord(False, String(""), Int64(-1), Int64(-1))

    # ---- SINGLE-WRITER: rebuild ALL in-memory state PURELY from persisted `_base` ----

    def reload_from_base(mut self) raises:
        """Discard the in-memory `_base` index + watermarks and rebuild them
        PURELY from the DURABLE bucket state (a fold-process restart). Each
        `_base` chunk's CRC is verified on decode — a corrupt block fail-louds.

        WATERMARK DURABILITY: the per-shard fold watermark is recovered from the
        SOURCE shard's durable `_LOG_START.log_start_offset` (the retire-advanced
        fold cursor), which SURVIVES `_base` retention reaping — so a shard whose
        `_base` blocks have been reaped still recovers its true `folded_count`.
        A surviving-`_base`-block's max source-local is taken as a LOWER bound
        (covers a fully-reaped source shard whose blocks still live in `_base`).
        The `_base` log-start (the dense floor) is read from `_base`'s own
        `_LOG_START`."""
        var base = self._shard_store(BASE_SHARD_ID)
        var ls = base.read_log_start()
        self._base_log_start_offset = ls.log_start_offset
        # Any error recovering the tail is raised. An absent `_base` does
        # not raise (the LIST finds no chunk); an error used to rebuild an
        # EMPTY index, and a compact over it then advanced the floor's
        # offset past live blocks.
        var head = base.read_head_authoritative()
        var rebuilt = List[BaseChunkEntry]()
        var wms = List[ShardFoldedWatermark]()
        var dense_base = ls.log_start_offset
        var start_seq = ls.log_start_seq
        if start_seq < Int64(0):
            start_seq = Int64(0)
        var seq = start_seq
        var first_live_seq = Int64(-1)
        while seq <= head.chunk_seq:
            # Every block from the log start up is live: ANY read error
            # (not_found included; the tail recovery above already refuses a
            # missing one) is raised. Skipping a block would shift every
            # later dense base, and a compact over that index would retire
            # the wrong blocks.
            var raw = base.read_chunk(seq)
            if first_live_seq < Int64(0):
                first_live_seq = seq
            var rc = _base_chunk_record_count(raw)
            var entry = _decode_base_chunk(raw, rc, dense_base)
            # watermark = running max source-local end per shard.
            _bump_watermark(
                wms,
                entry.source_shard_id,
                entry.source_local_base + entry.count,
            )
            dense_base += entry.count
            rebuilt.append(entry^)
            seq += Int64(1)
        self._base_chunks = rebuilt^
        self._base_log_start_seq = (
            first_live_seq if first_live_seq >= Int64(0) else start_seq
        )
        self._dense_hw_ever = dense_base
        _ = base^
        # DURABLE watermark recovery: for every LIVE source shard, the durable
        # `_LOG_START.log_start_offset` is the authoritative fold cursor (it
        # survives `_base` reaping). Take the MAX of the source log-start and the
        # `_base`-derived lower bound. A fully-reaped source shard contributes
        # only the `_base`-derived bound (already in `wms`). An absent
        # `_LOG_START` reads as zero; a read error raises (the bound alone can
        # be too low, and the next fold would fold records again).
        var live_ids = self.enumerate_live_shards()
        for i in range(len(live_ids)):
            var sid = live_ids[i]
            var src = self._shard_store(sid)
            var src_ls = src.read_log_start()
            if src_ls.log_start_offset > Int64(0):
                _bump_watermark(wms, sid, src_ls.log_start_offset)
            _ = src^
        self._watermarks = wms^

    # =========================================================================
    # internal helpers — materialize / retire / read-source.
    # =========================================================================

    def _read_source_range(
        self, shard_id: String, local_base: Int64, count: Int64
    ) raises -> List[Int64]:
        """Read `count` source records starting at the shard's LOCAL offset
        `local_base` by walking its chunks via the shard `CasManifestStore`'s
        OWN read_chunk (no raw key arithmetic crosses out). Used at fold time to
        materialize the records into `_base` (so `_base` is self-contained)."""
        var s = self._shard_store(shard_id)
        var head = s.read_head_authoritative()
        # LOG_START-AWARE walk: a reaped folded prefix means chunks below
        # `log_start_seq` are GONE; start the running-sum from the retention
        # pointer (its `log_start_offset` is the absolute base of the first
        # surviving chunk) so the walk never 404s on a reaped prefix.
        var ls = s.read_log_start()
        var out = List[Int64]()
        var running = ls.log_start_offset
        var seq = ls.log_start_seq if ls.log_start_seq >= Int64(0) else Int64(0)
        var want_end = local_base + count
        while seq <= head.chunk_seq and Int64(len(out)) < count:
            var body = s.read_chunk(seq)
            var rc = Int64(len(body) // 8)
            var chunk_lo = running
            var chunk_hi = running + rc  # exclusive
            if chunk_hi > local_base and chunk_lo < want_end:
                var recs = decode_record_body(body, rc)
                var lo = Int(local_base - chunk_lo) if local_base > chunk_lo else 0
                var hi = (
                    Int(want_end - chunk_lo) if want_end < chunk_hi else Int(rc)
                )
                for k in range(lo, hi):
                    out.append(recs[k])
            running += rc
            seq += Int64(1)
        _ = s^
        if Int64(len(out)) != count:
            raise Error(
                "sublineage_base_fold: source range ["
                + String(local_base)
                + ".."
                + String(local_base + count)
                + ") on shard "
                + shard_id
                + " yielded "
                + String(len(out))
                + " records (torn source)"
            )
        return out^

    def _materialize_block(
        mut self,
        source_shard_id: String,
        source_local_base: Int64,
        expected_dense: Int64,
        payloads: List[Int64],
    ) raises:
        """Publish ONE folded block as a `_base` chunk via single-writer
        If-None-Match CAS. `record_count = len(payloads)` so `_base`'s
        own gapless dense space matches the assignment (the fold lineage's
        manifest offset IS the dense offset). ASSERTS:
          * `_base.base_offset == expected_dense` (the running fold high-water), AND
          * `_base.last_offset == base + count - 1` (manifest contiguity).
        A divergence is a torn fold — raise rather than serve a wrong binding.
        On success, appends the decoded block to the in-memory `_base` index."""
        var base = self._shard_store(BASE_SHARD_ID)
        var count = Int64(len(payloads))
        var body = _encode_base_chunk(source_shard_id, source_local_base, payloads)
        var r = base.append(body, count)
        if r.base_offset != expected_dense:
            _ = base^
            raise Error(
                "sublineage_base_fold: _base base_offset "
                + String(r.base_offset)
                + " != fold high-water "
                + String(expected_dense)
            )
        if r.last_offset != r.base_offset + count - Int64(1):
            _ = base^
            raise Error(
                "sublineage_base_fold: _base last_offset "
                + String(r.last_offset)
                + " != base+count-1 "
                + String(r.base_offset + count - Int64(1))
            )
        _ = base^
        self._base_chunks.append(
            BaseChunkEntry(
                source_shard_id, source_local_base, r.base_offset, count,
                payloads.copy(),
            )
        )
        var hw = r.base_offset + count
        if hw > self._dense_hw_ever:
            self._dense_hw_ever = hw

    def _retire_folded_source(
        mut self, shard_id: String, folded_through_total: Int64
    ) raises:
        """RETIRE the source-shard chunks whose records are now FULLY folded into
        `_base` — i.e. every chunk whose entire local range is below
        `folded_through_total`. Tombstoning (not deleting) lets the EXISTING
        grace-gated reaper reclaim them; a partially-folded chunk (its tail past
        the snapshot boundary) is left live.

        DURABLE FOLD-WATERMARK: this also advances the source shard's `_LOG_START`
        to `folded_through_total` (the first still-UN-folded local offset). That
        pointer IS the durable per-shard fold cursor — it survives `_base`
        retention reaping (which drops the materialized blocks), so a fold-process
        restart recovers `folded_count` from the SOURCE shard's log-start, NOT
        from the (possibly-reaped) `_base` blocks. The retire-then-advance is
        exactly the retention semantics a single-manifest partition uses: the
        prefix `[0..folded_count)` is reclaimable, and `_LOG_START` records that.
        Raw retention-key arithmetic stays INSIDE this module."""
        var s = self._shard_store(shard_id)
        # A fully reaped shard reads as an empty head (the walk below then
        # retires nothing); a read error raises.
        var head = s.read_head_authoritative()
        var already_tomb = s.tombstone_seqs()
        var cur = s.read_log_start()
        var running = cur.log_start_offset
        var seq = cur.log_start_seq if cur.log_start_seq >= Int64(0) else Int64(0)
        var first_unfolded_seq = head.chunk_seq + Int64(1)
        var found_unfolded = False
        var to_tomb = List[Int64]()
        while seq <= head.chunk_seq:
            # The walk starts AT the log start, so every chunk it reads is
            # live: ANY read error (not_found included) is raised. Taking it
            # for a reaped chunk would skip a live chunk's records and
            # renumber the log. The whole walk runs before any tombstone or
            # advance, so a failed read changes nothing.
            var body = s.read_chunk(seq)
            var rc = Int64(len(body) // 8)
            var chunk_hi = running + rc  # exclusive local end
            # Fully folded iff the chunk's entire range is <= folded watermark.
            if chunk_hi <= folded_through_total:
                if not _i64_in(already_tomb, seq):
                    to_tomb.append(seq)
            elif not found_unfolded:
                first_unfolded_seq = seq
                found_unfolded = True
            running = chunk_hi
            seq += Int64(1)
        for t in range(len(to_tomb)):
            s.schedule_for_delete(to_tomb[t])
        # Advance the durable source `_LOG_START` to the folded watermark (the
        # first un-folded local offset = `folded_through_total`, at the first
        # surviving chunk seq). Monotone-forward; a stale 412 is a harmless lose.
        # A swallowed failure deletes nothing live: the tombstones above then
        # sit on chunks at or above `_LOG_START`, which `CasManifestStore.reap`
        # refuses and the broker `ReapWorker` skips (chunk_reclaim_guard.mojo),
        # and the next call re-reads `_LOG_START` and re-advances. Once the
        # advance lands, reaping these chunks loses nothing: this model's
        # `_base` chunks carry their own copy of the source payload, so a shard
        # chunk names no object `_base` reads. (The broker's segment fold shares
        # `.seg` objects with `_base` instead, and retires with MOVED markers;
        # cas_manifest.mojo, `schedule_moved_for_delete_at`.)
        if folded_through_total > cur.log_start_offset:
            try:
                _ = s.advance_log_start(
                    first_unfolded_seq, folded_through_total, cur.etag
                )
            except e3:
                _ = e3  # concurrent advance won — pointer is monotone-forward
        _ = s^

    def _retire_base_below(mut self, retain_from_dense: Int64) raises:
        """Advance `_base`'s log-start to `retain_from_dense` and tombstone+reap
        every `_base` chunk fully below it. The retention path — `_base` stays
        readable; only the reclaimed prefix is gone. Updates the in-memory index
        + the log-start (offset + seq) watermark. Raw retention-key arithmetic
        stays inside (the manifest's `schedule_for_delete`/`reap` verbs).

        `_base` is gapless one-block-per-chunk, so the absolute chunk_seq of the
        live block at ordinal `i` (in `_base_chunks`) is `_base_log_start_seq + i`.
        Reaping the first K live blocks advances `_base_log_start_seq` by K.

        ORDER (RetentionPass's): tombstone the retired prefix, THEN advance the
        durable `_LOG_START`, THEN reap every tombstone below it
        (`_reap_retired_base`).
          * A failure before the advance leaves tombstones on chunks at or
            above the log start: harmless (`reap` refuses them,
            chunk_reclaim_guard.mojo), and the retry re-tombstones and advances.
          * A failure after the advance leaves tombstoned chunks below it, and
            the index already at the new floor (as a restart would rebuild
            it). Every `compact` sweeps tombstones below the log start, so
            they are reclaimed.
          * Advancing BEFORE tombstoning would strand untombstoned chunks below
            the log start on such a failure: nothing would ever reap them.
        Any failure RAISES. Before the advance the in-memory index is
        unchanged; after it, the index is at the new floor."""
        var base = self._shard_store(BASE_SHARD_ID)
        var keep = List[BaseChunkEntry]()
        var first_keep_off = retain_from_dense
        var retire_n = Int64(0)
        var saw_keep = False
        for i in range(len(self._base_chunks)):
            ref e = self._base_chunks[i]
            if e.dense_base + e.count <= retain_from_dense and not saw_keep:
                retire_n += Int64(1)  # fully below the watermark — retired
            else:
                if not saw_keep:
                    first_keep_off = e.dense_base
                    saw_keep = True
                keep.append(e.copy())
        var new_log_start_seq = self._base_log_start_seq + retire_n
        # 1. Tombstone the retired prefix.
        var j = Int64(0)
        while j < retire_n:
            var abs_seq = self._base_log_start_seq + j
            j += Int64(1)
            try:
                base.schedule_for_delete(abs_seq)
            except e3:
                if not is_not_found(String(e3)):
                    raise e3^
                # The chunk is gone: an earlier attempt reaped it. A marker it
                # left behind is below the log start, so step 3 reaps it.
        # 2. Advance the durable `_LOG_START` past the retired prefix.
        var ls = base.read_log_start()
        _ = base.advance_log_start(new_log_start_seq, first_keep_off, ls.etag)
        # 3. The index follows the durable floor at once, exactly as a restart
        #    would rebuild it. Updating it only after the reaps left it stale
        #    when a reap failed, and a later compact with a lower watermark
        #    then aimed `_LOG_START` backwards.
        self._base_chunks = keep^
        self._base_log_start_offset = first_keep_off
        self._base_log_start_seq = new_log_start_seq
        # 4. Reap every tombstone below the log start. A failure here leaves
        #    tombstones below the floor; the next `compact` sweeps them.
        self._reap_retired_base(base)
        _ = base^

    def _reap_retired_base(
        self, mut base: CasManifestStore[Self.Store]
    ) raises:
        """Reap every `_base` tombstone below the durable log start: the
        retired prefix of this compaction, and any chunk an earlier compaction
        tombstoned (or half reaped) before it failed or the process stopped.
        A tombstone at or above the log start sits on a live block and is left
        alone. Raises on the first failed reap."""
        var floor = base.read_log_start_seq()
        var tombs = base.tombstone_seqs()
        for i in range(len(tombs)):
            if tombs[i] < floor:
                base.reap(tombs[i])

    def _offset_was_folded(self, o: Int64) -> Bool:
        """Whether dense offset O was ever folded (below the high-water-ever).
        Distinguishes a reaped-but-folded O (REAPED sentinel) from a never-
        assigned O (not found)."""
        return o >= Int64(0) and o < self._dense_hw_ever

    def _reaped_binding_shard(self, o: Int64) -> String:
        """Best-effort source-shard binding for a `_base`-reaped O. The binding
        block is gone (retention), so the exact shard cannot be recovered from
        `_base`; return the empty string. Resolution still reports found=True +
        the REAPED sentinel (never a wrong record, never unresolvable)."""
        _ = o
        return String("")

    def _dense_high_water(self) -> Int64:
        """The next dense offset a future fold assigns = the dense end of the
        highest LIVE `_base` chunk (or the retained log-start when `_base` is
        empty-above-log-start)."""
        var hw = self._base_log_start_offset
        for i in range(len(self._base_chunks)):
            ref e = self._base_chunks[i]
            var last_plus_1 = e.dense_base + e.count
            if last_plus_1 > hw:
                hw = last_plus_1
        return hw

    def _folded_count_for_shard(self, shard_id: String) -> Int64:
        """How many of `shard_id`'s source locals are already materialized in
        `_base` — read from the BOUNDED watermark (O(distinct shards))."""
        for i in range(len(self._watermarks)):
            ref w = self._watermarks[i]
            if w.shard_id == shard_id:
                return w.folded_count
        return Int64(0)

    def _advance_watermark(mut self, shard_id: String, new_count: Int64):
        """Set `shard_id`'s folded watermark to `new_count` (monotone forward).
        One row per distinct shard — O(distinct shards), NOT O(rounds)."""
        for i in range(len(self._watermarks)):
            if self._watermarks[i].shard_id == shard_id:
                if new_count > self._watermarks[i].folded_count:
                    self._watermarks[i].folded_count = new_count
                return
        self._watermarks.append(ShardFoldedWatermark(shard_id, new_count))

    def _sort_snapshot(self, snap: List[ShardSnapshot]) -> List[ShardSnapshot]:
        var out = snap.copy()
        var n = len(out)
        for i in range(1, n):
            var j = i
            while j > 0 and _canonical_shard_less(
                out[j].shard_id, out[j - 1].shard_id
            ):
                var tmp = out[j].copy()
                out[j] = out[j - 1].copy()
                out[j - 1] = tmp^
                j -= 1
        return out^

    def reap_shard_data(mut self, shard_id: String) raises:
        """TEST ONLY: simulate retention reaping of a FULLY-FOLDED shard — delete
        the shard's manifest chunk objects + its `_HEAD`, leaving the `_base`
        materialized blocks intact (REAPED-SOURCE: `_base` resolves the binding +
        payload, the SOURCE data does not need to survive). Raw chunk-key
        arithmetic stays INSIDE this module (encapsulation)."""
        var prefix = sublineage_prefix(self._part, shard_id)
        var s = self._shard_store(shard_id)
        var head = s.read_head_authoritative()
        var seq = Int64(0)
        while seq <= head.chunk_seq:
            self._store.delete(_chunk_path(prefix, seq))
            seq += Int64(1)
        self._store.delete(Path.parse(prefix + "/_HEAD"))
        _ = s^

    # ---- bound observability (the reaped-source / sustained-interleave probes) ----

    def bound_stats(self) raises -> BoundStats:
        """The persistent-resolution-state bound: live `_base` chunks (above
        log-start), distinct folded shards (watermark rows), and shards with a
        live un-folded tail. A sustained-interleave test asserts ALL THREE stay
        bounded (O(folded-chunks) retention-managed + O(distinct shards) +
        O(live-shard-width)) — NOT N x rounds (the old growing-map NO-GO)."""
        var live_tail = 0
        var ids = self.enumerate_live_shards()
        for i in range(len(ids)):
            var s = self._shard_store(ids[i])
            # An absent shard reads as an empty head; a read error raises.
            var head = s.read_head_authoritative()
            if head.next_offset > self._folded_count_for_shard(ids[i]):
                live_tail += 1
            _ = s^
        return BoundStats(
            len(self._base_chunks), len(self._watermarks), live_tail
        )

    @always_inline
    def live_base_chunk_count(self) -> Int:
        """Number of LIVE `_base` chunks (the folded-offset resolution state).
        Retention-bounded; tests assert this does NOT grow with total rounds."""
        return len(self._base_chunks)

    @always_inline
    def watermark_count(self) -> Int:
        """Number of per-shard fold watermarks (== distinct shards ever folded).
        O(distinct shards), NOT O(rounds) — the bounded cross-shard state."""
        return len(self._watermarks)


# =============================================================================
# Free-function helpers — key folding, list dedup, sorting, codec.
# =============================================================================


def _base_chunk_record_count(raw_chunk_body: List[UInt8]) raises -> Int64:
    """Recover the folded block's record count from a decoded `_base` chunk body.
    The body is `[version][source_local_base][crc][sid_len][sid][payloads...]`;
    count = (len - header - sid) / 8."""
    var sid_len = Int(_get_i64_le(raw_chunk_body, 24))
    var payload_bytes = len(raw_chunk_body) - (32 + sid_len)
    return Int64(payload_bytes // 8)


def _bump_watermark(
    mut wms: List[ShardFoldedWatermark], shard_id: String, new_count: Int64
):
    for i in range(len(wms)):
        if wms[i].shard_id == shard_id:
            if new_count > wms[i].folded_count:
                wms[i].folded_count = new_count
            return
    wms.append(ShardFoldedWatermark(shard_id, new_count))


def _i64_in(xs: List[Int64], v: Int64) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


@always_inline
def _chunk_path(prefix: String, chunk_seq: Int64) raises -> Path:
    """The manifest chunk object path for `chunk_seq` under `prefix`. Mirrors
    cas_manifest.chunk_key's 20-digit zero-pad (lexically sortable)."""
    var s = String(chunk_seq)
    var pad = 20 - s.byte_length()
    var z = String("")
    for _ in range(pad):
        z += "0"
    return Path.parse(prefix + "/manifest/" + z + s + ".chunk")


def _append_unique(mut xs: List[String], v: String):
    for i in range(len(xs)):
        if xs[i] == v:
            return
    xs.append(v)


def _shard_from_object_key(key: String, enum_prefix: String) -> String:
    """Given an object key `<part>/_lineage/<shard>/...` and the enum prefix
    `<part>/_lineage/`, return `<shard>` (the segment up to the next `/`). Empty
    if the key does not start with the prefix or has no shard segment."""
    if not _str_starts_with(key, enum_prefix):
        return String("")
    return _first_segment_after(key, enum_prefix.byte_length())


def _shard_from_common_prefix(cp: String, enum_prefix: String) -> String:
    """Given a store-provided common-prefix `<part>/_lineage/<shard>/` and the
    enum prefix, return `<shard>` (strip the trailing `/`)."""
    if not _str_starts_with(cp, enum_prefix):
        return String("")
    return _first_segment_after(cp, enum_prefix.byte_length())


@always_inline
def _first_segment_after(s: String, start: Int) -> String:
    """The substring of `s` from byte `start` up to (not incl.) the next `/`,
    or to end-of-string. Built byte-wise to avoid String-slice gaps."""
    var sb = s.as_bytes()
    # BYTE-EXACT. ⛔ NOT `out += chr(Int(c))` — an object key's `<shard>` segment
    # is customer-named and was never ASCII-only; `chr` re-encodes every byte
    # >= 0x80 into two, so the extracted shard id would not equal the one the
    # writer used. The correct twins are
    # `sublineage_shard_keys._shard_id_from_key` / `_shard_id_from_common_prefix`
    # and `sharded_lineage`, all three already byte-exact — this copy was the
    # one left behind.
    var out_bytes = List[UInt8]()
    var i = start
    while i < len(sb):
        var c = sb[i]
        if c == UInt8(47):  # '/'
            break
        out_bytes.append(c)
        i += 1
    return String(StringSlice(unsafe_from_utf8=Span(out_bytes)))


@always_inline
def _str_starts_with(s: String, prefix: String) -> Bool:
    if prefix.byte_length() == 0:
        return True
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(sb) < len(pb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True

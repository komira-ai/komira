# =============================================================================
# komira_broker/compacted_index.mojo
#   Tier compaction (leaf side) — the compaction index + dual-tier resolve
# =============================================================================
#
# The COMPACTED tier's offset->object index, the dual-tier (compacted + live)
# offset resolution, the SLO back-pressure decision, and GC of superseded live
# segments. All objectstore-only — NO dep on komira_sdk or komira_parquet
# (those would invert the broker's LEAF position in the build DAG). The concat /
# transcode / CompactionWorker that DO need the SDK + parquet live in the
# `komira_broker_compaction` adapter package ABOVE this leaf.
#
# -----------------------------------------------------------------------------
# THE TWO-TIER MODEL
# -----------------------------------------------------------------------------
#
# A topic-partition has TWO storage tiers:
#   * LIVE tier: the Arrow-IPC `.seg` segments + their CAS manifest (the core
#     substrate — `broker_core` / `consume_core` / the partition's manifest
#     prefix). The hot append path; low-latency, append-optimized.
#   * COMPACTED tier: Parquet objects + a SEPARATE, append-only CAS lineage
#     (this module) under `<partition-prefix>/compacted`. The cold,
#     query-optimized tier (topic-as-queryable-table — the marquee Komira
#     differentiator).
#
# THE LAZY MANIFEST-SWAP (a baked-in architecture decision). Compaction does
# NOT mutate the live manifest in place. It (a) writes a Parquet object, then
# (b) APPENDS a `CompactedEntry` to this separate compaction-index lineage.
# Both are immutable creates — there is NO half-committed torn state. A consumer
# observes the compacted entry only once the append has landed; until then it
# reads the live tier. The "swap" is the consumer-side flip: consult the
# compaction-index FIRST, fall back to the live manifest.
#
# OFFSET CONTIGUITY. A `CompactedEntry` preserves the EXACT
# `[base_offset, last_offset]` the superseded live segments covered. Offsets
# NEVER renumber across the live->compacted transition. `append_compacted`
# fail-LOUD asserts the new entry's base == the running tail of the prior
# compacted entries (gapless, contiguous).
#
# DUAL-TIER RESOLVE. `dual_tier_resolve` builds a single ordered
# list of `TierRef`s covering `[start_offset, tail)`: compacted entries for the
# already-compacted prefix, then live `SegmentRef`s for the still-live suffix.
# A range straddling the boundary [A,X] compacted + [X+1,B] live yields both,
# IN OFFSET ORDER. READ-REPAIR handles a live-segment 404 (a
# segment compacted + reaped underneath a slow reader): the adapter re-queries
# and falls back to the compacted tier. The grace window (ReapWorker reaps only
# post-grace) is the PRIMARY race-avoidance; read-repair handles the residual.
#
# GC. A compacted live segment is superseded: it is tombstoned in
# the LIVE manifest (the existing persisted-tombstone FSM) and reaped by the
# grace-gated ReapWorker — REUSED, not reimplemented. A separate, less-frequent
# compacted-orphan sweep (Parquet objects not in the compaction-index) lives in
# the adapter.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any public signature (surface is value / List /
#     POD / the Movable substrate structs held by value).
#   * ZERO wildcard origins. ZERO unsafe_from_address. ZERO take_pointee.
#   * The compaction-index reuses `CasManifestStore[Storage]` (held by value)
#     for the append/read/tombstone/reap CAS protocol — no hand-rolled CAS.
#   * Every struct here is a stack value, NOT a byte-slab element. POD
#     fields + owned `String`s only.
# =============================================================================

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    AppendResult,
)
from komira_objectstore.store import ConditionalWriteStore

from .consume_core import SegmentRef


# =============================================================================
# CompactedEntry — one entry in the compaction-index lineage (POD + codec).
# =============================================================================
#
# Body layout (little-endian) inside the opaque CAS-manifest chunk body:
#   [ record_count: i64 ][ base_offset: i64 ][ last_offset: i64 ]
#   [ supersedes_lo: i64 ][ supersedes_hi: i64 ]
#   [ key_len: i64 ][ parquet_key bytes... ]
#
# `base_offset`/`last_offset` are the EXACT absolute offset range the compacted
# Parquet object covers (== the range the superseded live segments covered).
# `supersedes_lo..hi` (inclusive) are the LIVE manifest chunk_seqs this entry
# replaced — the GC reads these to tombstone the right live segments.


@always_inline
def _ci_put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


@always_inline
def _ci_get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("compacted index: truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


@fieldwise_init
struct CompactedEntry(Copyable, Movable, Deinitable):
    """A resolved compaction-index entry: which Parquet object holds which
    absolute offset range, and which live chunks it superseded.

    Field layout:
      var chunk_seq: Int64       — the compaction-index lineage slot (0-based).
      var base_offset: Int64     — first ABSOLUTE offset this object holds.
      var last_offset: Int64     — last ABSOLUTE offset this object holds.
      var record_count: Int64    — records in this compacted object
                                   (== last - base + 1).
      var supersedes_lo: Int64   — first LIVE chunk_seq this entry replaced.
      var supersedes_hi: Int64   — last LIVE chunk_seq this entry replaced
                                   (inclusive range [lo, hi]).
      var parquet_key: String    — the S3 key the Parquet object was PUT at.
    """

    var chunk_seq: Int64
    var base_offset: Int64
    var last_offset: Int64
    var record_count: Int64
    var supersedes_lo: Int64
    var supersedes_hi: Int64
    var parquet_key: String

    def encode_body(self) -> List[UInt8]:
        """Serialize the domain payload that rides inside the CAS-manifest
        chunk body (the `chunk_seq` is the slot identity, assigned by the
        append; it is NOT stored in the body)."""
        var out = List[UInt8]()
        _ci_put_i64_le(out, self.record_count)
        _ci_put_i64_le(out, self.base_offset)
        _ci_put_i64_le(out, self.last_offset)
        _ci_put_i64_le(out, self.supersedes_lo)
        _ci_put_i64_le(out, self.supersedes_hi)
        var kb = self.parquet_key.as_bytes()
        _ci_put_i64_le(out, Int64(len(kb)))
        for i in range(len(kb)):
            out.append(kb[i])
        return out^

    @staticmethod
    def decode_body(chunk_seq: Int64, bytes: List[UInt8]) raises -> CompactedEntry:
        var record_count = _ci_get_i64_le(bytes, 0)
        var base = _ci_get_i64_le(bytes, 8)
        var last = _ci_get_i64_le(bytes, 16)
        var lo = _ci_get_i64_le(bytes, 24)
        var hi = _ci_get_i64_le(bytes, 32)
        var key_len = Int(_ci_get_i64_le(bytes, 40))
        if 48 + key_len > len(bytes):
            raise Error("CompactedEntry.decode_body: truncated parquet_key")
        var key = String("")
        for i in range(key_len):
            key += chr(Int(bytes[48 + i]))
        return CompactedEntry(
            chunk_seq=chunk_seq,
            base_offset=base,
            last_offset=last,
            record_count=record_count,
            supersedes_lo=lo,
            supersedes_hi=hi,
            parquet_key=key^,
        )


# =============================================================================
# TierRef — one element of a dual-tier resolution (compacted OR live).
# =============================================================================


@fieldwise_init
struct TierRef(Copyable, Movable, Deinitable):
    """One element of a dual-tier resolution covering an absolute offset range.

    `is_compacted == True`  → read `object_key` as a PARQUET object (decode
                              with the parquet reader on the adapter side).
    `is_compacted == False` → read `object_key` as a LIVE Arrow-IPC `.seg`
                              segment (decode with `decode_arrow_ipc_stream`).

    Either way the leaf hands back the key + the AUTHORITATIVE offset range;
    the adapter does the format-specific decode (the "hand back bytes, caller
    decodes" seam preserved from `consume_core`).

    Field layout:
      var is_compacted: Bool     — which tier this ref belongs to.
      var base_offset: Int64     — first absolute offset this object holds.
      var last_offset: Int64     — last absolute offset this object holds.
      var record_count: Int64    — records in this object.
      var object_key: String     — the S3 key (Parquet or `.seg`).
      var live_chunk_seq: Int64  — for live refs, the manifest chunk seq
                                   (read-repair re-query key); -1 for compacted.
    """

    var is_compacted: Bool
    var base_offset: Int64
    var last_offset: Int64
    var record_count: Int64
    var object_key: String
    var live_chunk_seq: Int64


# =============================================================================
# SloDecision — the flush back-pressure decision (pure POD).
# =============================================================================


@fieldwise_init
struct SloDecision(Copyable, Movable, Deinitable):
    """The compaction-SLO back-pressure decision.

    `should_backpressure == True` when `uncompacted_segment_count` exceeds
    `threshold` — the live tier has outrun compaction and the producer should
    slow down (raise threshold / fail-loud retryable). A token-bucket refinement
    is noted but not required for retention.

    Field layout:
      var should_backpressure: Bool
      var uncompacted_segment_count: Int64
      var threshold: Int64
    """

    var should_backpressure: Bool
    var uncompacted_segment_count: Int64
    var threshold: Int64


@always_inline
def evaluate_slo_backpressure(
    uncompacted_segment_count: Int64, threshold: Int64 = Int64(1000)
) -> SloDecision:
    """Pure decision: signal flush back-pressure when the uncompacted live
    segment count exceeds `threshold` (default ~1000, tunable). The
    uncompacted count == live `num_chunks` minus the live chunks already
    superseded by the compaction-index (the adapter computes this delta and
    passes it in)."""
    return SloDecision(
        should_backpressure=uncompacted_segment_count > threshold,
        uncompacted_segment_count=uncompacted_segment_count,
        threshold=threshold,
    )


# =============================================================================
# compacted_prefix — the SEPARATE compaction-index lineage prefix.
# =============================================================================


@always_inline
def compacted_prefix(partition_prefix: String) -> String:
    """The compaction-index CAS lineage prefix — a CHILD of the partition's
    manifest prefix, so it has its own `/manifest/<seq>` + `/_HEAD` +
    `/tombstones/` layout, fully isolated from the live manifest. The live
    manifest prefix is `<cluster>/_meta/topics/<topic>/<partition>`; the
    compacted lineage is `<that>/compacted`."""
    return partition_prefix + "/compacted"


# =============================================================================
# CompactionIndex[Storage] — the compacted tier's offset->object index.
# =============================================================================


struct CompactionIndex[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """The compacted tier's append-only offset->Parquet-object index (a
    SEPARATE CAS lineage; the lazy manifest-swap is the consumer-side
    flip, never an in-place mutation of the live manifest).

    Wraps a `CasManifestStore[Storage]` bound to the `compacted/` prefix — so
    the append CAS loop, read-back, restart-safe LIST recovery, and the
    persisted-tombstone FSM all come for free (no hand-rolled CAS). The DOMAIN
    payload (`CompactedEntry`) rides inside the opaque chunk body, above the
    trait, exactly as the live `ManifestBody` does.

    Ownership:
      * `_index: CasManifestStore[Storage]` — owned by value; the compacted
        lineage's append/read/tombstone substrate.

    Fields:
      var _index: CasManifestStore[Storage]
    """

    var _index: CasManifestStore[Self.Storage]

    def __init__(out self, var index: CasManifestStore[Self.Storage]):
        """Construct from a `CasManifestStore` ALREADY bound to the
        `compacted/` prefix (use `compacted_prefix(...)` to derive it)."""
        self._index = index^

    @staticmethod
    def build(
        var store: Self.Storage,
        partition_prefix: String,
        retry: RetryPolicy = RetryPolicy.default(),
    ) -> CompactionIndex[Self.Storage]:
        """Build a compaction index over `store`, binding its CAS lineage to
        the `compacted/` child of the partition's manifest prefix."""
        var index = CasManifestStore[Self.Storage](
            store=store^,
            prefix=compacted_prefix(partition_prefix),
            retry=retry,
        )
        return CompactionIndex[Self.Storage](index^)

    # -------------------------------------------------------------------------
    # append_compacted — commit a Parquet object into the compacted lineage.
    # -------------------------------------------------------------------------

    def append_compacted(
        mut self,
        parquet_key: String,
        base_offset: Int64,
        last_offset: Int64,
        record_count: Int64,
        supersedes_lo: Int64,
        supersedes_hi: Int64,
    ) raises -> AppendResult:
        """Append a `CompactedEntry` to the compaction lineage (the lazy swap's
        commit step).

        OFFSET CONTIGUITY (fail-LOUD): the new entry's
        `base_offset` MUST equal the running tail of the prior compacted
        entries (`prior_last + 1`, or `0` for the first entry) — offsets never
        renumber across live->compacted. Also asserts
        `last == base + record_count - 1` (the entry is internally consistent).
        Raises if either invariant is violated (no silent gap/overlap).
        """
        if last_offset != base_offset + record_count - Int64(1):
            raise Error(
                "CompactionIndex.append_compacted: inconsistent entry — last "
                + String(last_offset)
                + " != base "
                + String(base_offset)
                + " + count "
                + String(record_count)
                + " - 1"
            )
        # Contiguity check against the existing compacted tail.
        var existing = self.resolve_compacted()
        var expected_base = Int64(0)
        if len(existing) > 0:
            expected_base = existing[len(existing) - 1].last_offset + Int64(1)
        if base_offset != expected_base:
            raise Error(
                "CompactionIndex.append_compacted: NON-CONTIGUOUS compacted"
                " base — got "
                + String(base_offset)
                + ", expected "
                + String(expected_base)
                + " (offsets must never renumber/gap across live->compacted)"
            )
        var entry = CompactedEntry(
            chunk_seq=Int64(-1),  # assigned by the append
            base_offset=base_offset,
            last_offset=last_offset,
            record_count=record_count,
            supersedes_lo=supersedes_lo,
            supersedes_hi=supersedes_hi,
            parquet_key=parquet_key,
        )
        var body = entry.encode_body()
        return self._index.append(body^, record_count)

    # -------------------------------------------------------------------------
    # resolve_compacted — rebuild the ordered compacted-entry list.
    # -------------------------------------------------------------------------

    def resolve_compacted(mut self) raises -> List[CompactedEntry]:
        """Walk the compaction lineage chunks and decode each `CompactedEntry`,
        in append order. Returns the ordered compacted index (cheap: the
        compacted lineage is small). Empty if nothing has been compacted yet.

        Fail-SOFT skips a chunk that 404s mid-walk (tombstoned + reaped
        compacted entry — the grace window makes this benign; the next live
        chunk's offsets are still authoritative from its own body)."""
        # A correctness consumer of the tail: read_head() prefers the
        # stale-low local cache, so this must LIST the
        # authoritative tail. A maintenance/cold-cache instance holds a freshly
        # constructed `_index` (empty local `_HEAD` cache), so `read_head()` would
        # read the DURABLE `_HEAD` of the compaction lineage whose advance is
        # deferred off the warm-append ack path (lags by up to
        # `_HEAD_ADVANCE_DEFER_CADENCE` chunks). A stale-low `chunk_seq` would MISS
        # the most-recently-appended `CompactedEntry`s -> the resolved compacted
        # boundary (`compacted_tail_offset`) lands too low -> the dual-tier resolve
        # mis-splits live vs. compacted (and re-compaction mis-selects segments).
        # LIST-recover the true compacted-lineage tail.
        var head = self._index.read_head_authoritative()
        var n_chunks = head.chunk_seq + Int64(1)  # chunk_seq is highest; -1 = empty
        var out = List[CompactedEntry]()
        var seq = Int64(0)
        while seq < n_chunks:
            try:
                var body = self._index.read_chunk(seq)
                out.append(CompactedEntry.decode_body(seq, body))
            except e:
                if _ci_is_not_found(String(e)):
                    seq += Int64(1)
                    continue
                raise e^
            seq += Int64(1)
        return out^

    @always_inline
    def compacted_tail_offset(mut self) raises -> Int64:
        """The first NOT-YET-compacted absolute offset (== the exclusive upper
        bound of the compacted tier == `last_compacted + 1`, or 0 if nothing is
        compacted). The boundary the dual-tier resolve splits on."""
        var existing = self.resolve_compacted()
        if len(existing) == 0:
            return Int64(0)
        return existing[len(existing) - 1].last_offset + Int64(1)

    @always_inline
    def index_store(ref self) -> ref [self._index] CasManifestStore[Self.Storage]:
        """Borrow the underlying CAS-manifest store (for tombstone/reap of
        compacted entries during the orphan sweep). `ref [self._index]` per
        the inner-OwnedPointer ref-return rule (mojo_0263 Repro 5)."""
        return self._index

    # -------------------------------------------------------------------------
    # Compaction reverse-guard: never reap the SOLE copy of a still-
    # readable range.
    # -------------------------------------------------------------------------

    def compacted_entry_is_reapable(
        self,
        entry: CompactedEntry,
        earliest_readable_offset: Int64,
        live_log_start_offset: Int64,
    ) raises -> Bool:
        """Reverse-guard. Decide whether the compacted `entry` (Parquet
        object covering `[base_offset, last_offset]`) may be REAPED.

        The compaction commit-then-supersede protocol advances the LIVE log_start
        PAST a superseded range (CompactionWorker.run_once step 8) — so once that
        lands, the LIVE tier no longer holds the range and the compacted object
        is the SOLE copy. Read-repair is ONE-direction only (live-miss falls back
        to compacted; there is NO compacted-miss -> live fallback). Therefore
        reaping a compacted object whose range is STILL SERVABLE — at/above the
        partition's earliest-readable floor — would make that range readable from
        NEITHER tier (a silent hole).

        A compacted entry is reapable IFF its WHOLE range has aged out below the
        earliest-readable floor (`last_offset < earliest_readable_offset`): only
        then has retention GC'd the range out of every consumer's window, so
        dropping the compacted copy loses nothing.

        Two precise refusal cases:
          * the range straddles / sits at/above the readable floor — a consumer
            resuming at `earliest_readable_offset` would touch it -> REFUSE.
          * the live tier has superseded the range (`live_log_start_offset >
            entry.base_offset`, the normal post-compaction state) AND the range
            is still readable -> the compacted object is the SOLE copy -> REFUSE.

        `live_log_start_offset` is read by the CALLER off the LIVE manifest's
        `_LOG_START` (this index is bound to the COMPACTED prefix, so it cannot
        read the live pointer itself)."""
        # The range is fully GC'd out of the readable window -> safe to reap.
        if entry.last_offset < earliest_readable_offset:
            return True
        # Otherwise the range is still servable. If the live tier has already
        # superseded it (the normal post-compaction state), the compacted object
        # is the sole copy of a still-readable range -> NOT reapable. Even if the
        # live tier still overlaps, a range at/above the readable floor must not
        # be dropped (read-repair cannot recover a missing compacted object).
        _ = live_log_start_offset  # documented input; refusal is range-driven.
        return False

    def assert_compacted_entry_reapable(
        self,
        entry: CompactedEntry,
        earliest_readable_offset: Int64,
        live_log_start_offset: Int64,
    ) raises:
        """Fail-LOUD form of `compacted_entry_is_reapable` for a reaper that
        intends to DELETE the compacted object: raises (refuses) if the entry is
        still the sole copy of a servable range. A reaper calls this
        BEFORE deleting a compacted Parquet object + dropping its index entry."""
        if not self.compacted_entry_is_reapable(
            entry, earliest_readable_offset, live_log_start_offset
        ):
            raise Error(
                "CompactionIndex: REFUSING to reap compacted entry covering ["
                + String(entry.base_offset)
                + ", "
                + String(entry.last_offset)
                + "] — it is the SOLE copy of a still-readable range"
                " (earliest_readable_offset="
                + String(earliest_readable_offset)
                + ", live_log_start_offset="
                + String(live_log_start_offset)
                + "); reaping it would make the range readable from NEITHER tier"
            )


# =============================================================================
# dual_tier_resolve — the unified compacted+live offset resolution
# =============================================================================


def dual_tier_resolve(
    mut compaction_index: CompactionIndex,
    live_index: List[SegmentRef],
    start_offset: Int64,
) raises -> List[TierRef]:
    """Build a single ORDERED list of `TierRef`s covering `[start_offset, tail)`
    across BOTH tiers — compaction-index FIRST, live-manifest fallback.

    Resolution:
      1. Compacted entries whose range includes/follows `start_offset` come
         first (they cover the already-compacted prefix).
      2. Live `SegmentRef`s whose range includes/follows
         `max(start_offset, compacted_tail)` come next (the still-live suffix).
    A range STRADDLING the boundary yields refs from BOTH tiers, in OFFSET
    ORDER (the compacted suffix then the live suffix). The live suffix starts
    at `compacted_tail` so the two tiers never double-cover an offset.

    `live_index` is the LIVE manifest's resolved index (from
    `ConsumeCore.resolve_index`). The leaf takes it as a value so this function
    has NO live-store dependency beyond the already-resolved refs.
    """
    var out = List[TierRef]()

    # ---- Tier 1: compacted entries covering [start_offset, tail) ----
    var compacted = compaction_index.resolve_compacted()
    var compacted_tail = Int64(0)
    for i in range(len(compacted)):
        ref c = compacted[i]
        if c.last_offset >= compacted_tail:
            compacted_tail = c.last_offset + Int64(1)
        if c.last_offset >= start_offset:
            out.append(
                TierRef(
                    is_compacted=True,
                    base_offset=c.base_offset,
                    last_offset=c.last_offset,
                    record_count=c.record_count,
                    object_key=String(c.parquet_key),
                    live_chunk_seq=Int64(-1),
                )
            )

    # ---- Tier 2: live segments covering [max(start, compacted_tail), tail) --
    # Live refs below `compacted_tail` are already represented by the compacted
    # tier — skip them (no double-cover). Live refs whose last_offset is below
    # the effective live start are entirely compacted/consumed — skip.
    var live_start = start_offset if start_offset >= compacted_tail else compacted_tail
    for i in range(len(live_index)):
        ref s = live_index[i]
        if s.last_offset < live_start:
            continue
        if s.last_offset < compacted_tail:
            # Fully within the compacted range — superseded, skip.
            continue  # cov: unreachable live_start >= compacted_tail, so the check above already skipped every such segment
        out.append(
            TierRef(
                is_compacted=False,
                base_offset=s.base_offset,
                last_offset=s.last_offset,
                record_count=s.record_count,
                object_key=String(s.object_key),
                live_chunk_seq=s.chunk_seq,
            )
        )

    return out^


@always_inline
def _ci_is_not_found(msg: String) -> Bool:
    """Classify a not-found / 404 store error (the reaped-compacted-entry race
    in `resolve_compacted`)."""
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )

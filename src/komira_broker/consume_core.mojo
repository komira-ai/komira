# =============================================================================
# komira_broker/consume_core.mojo
#   ConsumeCore: the read-side dual of BrokerCore
# =============================================================================
#
# Komira message broker — the CONSUME path (the read-side keystone). This is
# the concrete, NON-`Format` core: the dual of `BrokerCore`. It reads the
# manifest + segments DIRECTLY from the object store (no broker server in the
# read path) and yields `RecordBatch`es + their committed offsets.
#
# -----------------------------------------------------------------------------
# The [Format] firewall (normative).
# -----------------------------------------------------------------------------
#
# `ConsumeCore` MUST NOT take `Format`/`Protocol` as a type parameter — exactly
# like `BrokerCore`. It operates ONLY on the concrete internal types
# (`RecordBatch` + the broker-assigned offset). The `Format` record-convention
# codec rides ABOVE this core, in the `MessageBrokerConsumer[Format]` edge.
#   * `Format` is NOT a parameter here.
#   * `Storage: ConditionalWriteStore` IS a parameter — but it is a BACKEND
#     SELECTOR (one backend per deployment), the same discipline as
#     `BrokerCore[Storage]` / `CasManifestStore[Store]`. No per-request
#     multiplication.
#
# -----------------------------------------------------------------------------
# THE CONSUME PATH (the read-side dual of the produce path).
# -----------------------------------------------------------------------------
#
#   Given (topic, partition, start_offset):
#   1. Read the manifest HEAD (`CasManifestStore.read_head`) → the tail
#      cursor + `next_offset` (the count of committed offsets).
#   2. Iterate chunks 0..num_chunks-1 (`read_chunk(seq)` →
#      `ManifestBody.decode`), accumulating each chunk's base_offset (the
#      running sum of prior `record_count`s — the manifest append IS the
#      offset allocator, so chunk seq `k` occupies
#      `[base_k, base_k + record_count_k - 1]`). This rebuilds the
#      offset → (segment_key, base, count) index.
#   3. Find the chunk(s) covering `start_offset` (skip chunks whose range
#      ends before `start_offset`).
#   4. For each covering chunk: `get_range` the `.seg`
#      object (whole object — we need the trailing footer too), decode the
#      `SegmentFooter` (gives the Arrow-IPC stream length), slice off the
#      40-byte footer, and `decode_arrow_ipc_stream` the leading stream →
#      a `RecordBatch`.
#   5. Yield the RecordBatch + its base offset. Rows before `start_offset`
#      within the FIRST covering segment are the caller's to skip (the core
#      yields whole segments + their base; row-level offset slicing within a
#      segment is the edge's concern — segments are the natural read unit).
#
# CONSUME IS READ-ONLY: no manifest APPEND, so NO CAS contention → the
# `CAS gate` does NOT bind the consume path's correctness (the gate
# still wraps `read_head`/`read_chunk` internally for the bundled-tcmalloc
# safety, but consume never contends a shared prefix the way produce does).
# Consume is fully concurrent-safe.
#
# NOTE on the footer's offset fields: the footer's `base_offset`/`last_offset`
# are PRE-COMMIT estimates (broker_core.mojo module header). The AUTHORITATIVE
# offset of a segment is the running sum the MANIFEST yields (step 2). This
# core reads offsets from the manifest, NOT the footer — the footer is used
# ONLY for `arrow_stream_len` + the CRC integrity check.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any public signature (surface is value /
#     RecordBatch / List / POD).
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * The owned substrate (`Storage` + `CasManifestStore[Storage]`) is held BY
#     VALUE — both are Movable structs that encapsulate their own internals.
#   * ConsumeCore is a stack value, NOT a byte-slab element. Its fields
#     are owned `String`s + the two Movable substrate structs. The
#     `SegmentRef`/`ConsumeResult` POD records hold an owned `String` key +
#     Int64 offsets — none stored in an OwnedSlab/AtomicSlab with a wildcard
#     cast. No Movable-struct-in-byte-slab-with-heap-field shape.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import CasManifestStore, LogStart
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from .broker_core import SegmentFooter
from .chunk_walk import restart_point_after_failed_read
from .manifest_body import ManifestBody
# decode_arrow_ipc_stream lives in komira_sdk (the self-describing stream
# decoder). The broker LIBRARY does NOT depend on the SDK — that would invert
# the build DAG (broker -> {core, objectstore, async, obs} only). So the
# consume core takes the decoder as a FUNCTION-POINTER-FREE seam: the segment
# bytes are sliced + handed back as `List[UInt8]` (the Arrow-IPC stream), and
# the CALLER (the SDK-side MessageBrokerConsumer edge, or the test) decodes
# them with `decode_arrow_ipc_stream`. This keeps the build DAG cycle-free and
# the core SDK-agnostic — segment decode is an Arrow concern, not a
# broker-core concern.


# =============================================================================
# SegmentRef — one entry in the resolved offset→segment index (POD-ish).
# =============================================================================


@fieldwise_init
struct SegmentRef(Copyable, Movable, Deinitable):
    """A resolved manifest entry: which segment object holds which offset
    range. Built by `ConsumeCore.resolve_index` from the manifest chunks.

    Field layout:
      var chunk_seq: Int64     — the manifest chunk slot (0-based monotone).
      var base_offset: Int64   — first offset this segment holds (manifest-
                                 authoritative: running sum of prior counts).
      var last_offset: Int64   — last offset this segment holds
                                 (= base_offset + record_count - 1).
      var record_count: Int64  — records in this segment.
      var object_key: String   — the S3 key the `.seg` was PUT at.
      var crc32: UInt32        — the segment's CRC (footer integrity check).
    """

    var chunk_seq: Int64
    var base_offset: Int64
    var last_offset: Int64
    var record_count: Int64
    var object_key: String
    var crc32: UInt32


# =============================================================================
# ChunkTagAt — one live manifest chunk's transaction tag + its chunk_seq.
# =============================================================================


@fieldwise_init
struct ChunkTagAt(Copyable, Movable, Deinitable):
    """A live manifest chunk's transaction tag, paired with its chunk_seq, for
    the read_committed filter (which correlates a ConsumeSegment to its tag
    by chunk_seq). POD-ish (Int64s + one owned String). Not a byte-slab
    element.

    Field layout:
      var chunk_seq: Int64      — the manifest chunk slot.
      var marker_type: Int64    — MARKER_NONE / MARKER_COMMIT / MARKER_ABORT.
      var txn_id: String        — the transactional-id ("" == non-transactional).
      var producer_epoch: Int64 — the epoch the chunk was written under (the
                                  epoch-equality fence input).
    """

    var chunk_seq: Int64
    var marker_type: Int64
    var txn_id: String
    var producer_epoch: Int64


# =============================================================================
# ConsumeSegment — a read + decoded-stream-bytes result for one segment.
# =============================================================================


@fieldwise_init
struct ConsumeSegment(Movable, Deinitable):
    """The result of reading ONE segment object from S3: the Arrow-IPC
    STREAM BYTES (footer already sliced off) + the segment's authoritative
    offset range. The caller decodes `stream_bytes` with
    `decode_arrow_ipc_stream` (the broker core stays SDK-agnostic — see the
    module header).

    Field layout:
      var stream_bytes: List[UInt8] — the leading Arrow-IPC stream (Schema +
                                      RecordBatch* + EOS), footer sliced off.
                                      Decode with `decode_arrow_ipc_stream`.
      var base_offset: Int64        — first offset in this segment (manifest).
      var last_offset: Int64        — last offset in this segment (manifest).
      var record_count: Int64       — records in this segment.
      var chunk_seq: Int64          — the manifest chunk slot.
    """

    var stream_bytes: List[UInt8]
    var base_offset: Int64
    var last_offset: Int64
    var record_count: Int64
    var chunk_seq: Int64

    def take_stream_bytes(deinit self) -> List[UInt8]:
        """Consume the segment and return its Arrow-IPC stream bytes.

        Mojo rejects a single-field `^`-move out of the middle of a
        struct (the rest of the struct can no longer be destroyed). This
        whole-value consume (`deinit self`) is the encapsulation-preferred way
        to extract the heap-owning `stream_bytes` field without a copy and
        without a partial-move: the caller hands ownership of the WHOLE segment
        in, and gets the stream bytes out (the scalar offset fields are read
        BEFORE this call when needed). Used by the tier-compaction transcode."""
        return self.stream_bytes^


# =============================================================================
# ConsumeReadResult — segments + the EFFECTIVE start (retention).
# =============================================================================


@fieldwise_init
struct ConsumeReadResult(Movable, Deinitable):
    """The result of a log_start-aware read: the surviving segments + the
    EFFECTIVE start offset (the first offset actually readable).

    `effective_start_offset` == the partition's persisted `log_start_offset`.
    When a caller requested `start_offset < log_start_offset`, the returned
    `segments` begin at `effective_start_offset` (the surviving range), and
    `truncated` is True — the caller MUST detect this (NO silent
    clamp-and-pretend; the Kafka Fetch path maps `requested < log_start →
    OFFSET_OUT_OF_RANGE`; a native consumer may serve the surviving
    range BECAUSE effective_start is explicit here). Never renumbers: surviving
    segments keep their CORRECT ABSOLUTE offsets.

    Field layout:
      var segments: Slab[ConsumeSegment] — surviving segments, in produce order.
      var effective_start_offset: Int64  — first readable offset (== log_start).
      var requested_start_offset: Int64  — what the caller asked for.
      var truncated: Bool                — requested < effective (the caller's
                                           start was below the retained range).
    """

    var segments: Slab[ConsumeSegment]
    var effective_start_offset: Int64
    var requested_start_offset: Int64
    var truncated: Bool


# =============================================================================
# ConsumeCore[Storage] — the concrete, NON-[Format] read-side core.
# =============================================================================


struct ConsumeCore[Storage: ConditionalWriteStore](Movable, Deinitable):
    """The Komira broker's concrete read-side core (the dual of `BrokerCore`).

    NON-GENERIC over wire protocol/format — operates ONLY on offsets +
    Arrow-IPC stream bytes. Parametrized solely over the storage backend
    `Storage` (a backend selector). Reads the manifest + segments directly
    from S3; READ-ONLY (no append → no CAS contention).

    Ownership:
      * `_segment_store: Storage` — owned by value; GETs the `.seg` objects.
      * `_manifest: CasManifestStore[Storage]` — owned by value; the offset
        index (read_head / read_chunk / num_chunks).

    Fields:
      var _segment_store: Storage
      var _manifest: CasManifestStore[Storage]
      var _cluster: String
      var _topic: String
      var _partition: Int64
    """

    var _segment_store: Self.Storage
    var _manifest: CasManifestStore[Self.Storage]
    var _cluster: String
    var _topic: String
    var _partition: Int64

    def __init__(
        out self,
        var segment_store: Self.Storage,
        var manifest: CasManifestStore[Self.Storage],
        var cluster: String,
        var topic: String,
        partition: Int64,
    ):
        """Construct a single-partition consume core. `segment_store` GETs the
        `.seg` objects; `manifest` is the partition's offset index (already
        bound to the partition's manifest prefix by the caller — same prefix
        the producer's `BrokerCore` used)."""
        self._segment_store = segment_store^
        self._manifest = manifest^
        self._cluster = cluster^
        self._topic = topic^
        self._partition = partition

    @always_inline
    def topic(self) -> String:
        return self._topic

    @always_inline
    def partition(self) -> Int64:
        return self._partition

    # -------------------------------------------------------------------------
    # tail metadata — cheap manifest-head reads (for estimate_rows / tail poll).
    # -------------------------------------------------------------------------

    def next_offset(mut self) raises -> Int64:
        """The manifest HEAD's `next_offset` == the count of committed offsets
        (== the offset the NEXT produce will claim). The exclusive upper bound
        of the readable range.

        Reads the AUTHORITATIVE tail
        (LIST), NOT the cached `_HEAD`. The cached `_HEAD` advance is
        best-effort and lags the true tail under sustained cross-process produce
        contention; a consumer reading the stale cache would report a SHORT
        high-watermark and miss committed records (a node that never wrote the
        partition reads its stale `_HEAD` and sees fewer records than were
        committed). Consume is far
        rarer than produce, so the per-poll LIST is an acceptable cost for read
        correctness."""
        var head = self._manifest.read_head_authoritative()
        return head.next_offset

    def num_chunks(mut self) raises -> Int64:
        """The number of committed manifest chunks (== segments). For tail
        polling: a consumer that has drained `k` chunks re-reads this; if it
        grew, new segments are available. AUTHORITATIVE (LIST) tail read — see
        `next_offset`: a stale `_HEAD`
        would under-report the chunk count and drop committed records."""
        var head = self._manifest.read_head_authoritative()
        return head.chunk_seq + Int64(1)

    def num_chunks_cached(mut self) raises -> Int64:
        """The number of committed manifest chunks, read from the CACHED `_HEAD`
        (a cheap `_HEAD` GET) rather than the AUTHORITATIVE LIST that
        `num_chunks()` does. ADVISORY ONLY — the cached `_HEAD` advances
        best-effort and can lag the true tail under cross-process produce
        contention, so this MUST NOT be used on any CORRECTNESS path (where a
        stale-low chunk count would DROP committed records — that is exactly why
        `num_chunks()` is authoritative). It exists for ADVISORY signals that
        tolerate a slightly-stale estimate — e.g. the micro-batch governor's
        backlog/lag reading ("lag is free"): a slightly-stale lag is
        a fine controller input, and reading the cache adds ZERO authoritative
        (LIST) reads to a governed step. A stale-low cache only ever
        UNDER-reports the backlog (the governor then holds rather than grows —
        the safe direction). NOTE: `_recover_head_by_list` is the cache's miss
        fallback, so an ABSENT `_HEAD` still costs one LIST; once the cache
        exists (the steady state after the first poll), this is a pure GET."""
        var head = self._manifest.read_head()
        return head.chunk_seq + Int64(1)

    def log_start_offset(mut self) raises -> Int64:
        """The first still-readable ABSOLUTE offset (retention). Reads the
        persisted `_LOG_START` pointer; 0 if the partition was never
        truncated. The Kafka ListOffsets 'earliest' offset == this (NOT 0
        once retention has reaped the head)."""
        return self._manifest.read_log_start().log_start_offset

    # -------------------------------------------------------------------------
    # resolve_index — rebuild the offset → segment map from the manifest.
    # -------------------------------------------------------------------------

    def resolve_index(mut self) raises -> List[SegmentRef]:
        """Walk the LIVE manifest chunks `[log_start_seq, num_chunks)`, decode
        each `ManifestBody`, and accumulate the running base offset to produce
        the authoritative offset→segment index for the SURVIVING range.

        The LEGACY single-manifest path. A partition NOT in sub-lineage mode
        (sub-lineage write off, or no `_base` fold lineage yet) resolves its
        dense offset index here. A partition IN sub-lineage mode WITH a live
        `_base` resolves its
        CONTIGUOUS dense index (folded `_base` + serve-merged un-folded tail) via
        `komira_broker.sublineage_consume.SubLineageConsumeResolver.resolve_index`
        instead (it needs a CLONEABLE store to reach the N disjoint sub-lineage
        prefixes, so it lives off this concrete `ConsumeCore[Storage:
        ConditionalWriteStore]` rather than widening this struct's bound). The
        routing layer chooses between the two on `SubLineageConsumeResolver.
        has_base()`; this legacy path is never altered by the sub-lineage code.

        Retention (log_start-aware): once chunks `0..k` are
        reaped, `read_chunk(0)` raises not_found and a `running_base = 0`
        running sum from chunk 0 BREAKS / renumbers the survivors. So this:
          * starts `seq` at the persisted `log_start_seq` (skips reaped/retired
            chunks — never reads chunk 0 after it's gone);
          * SEEDS `running_base` from the persisted `log_start_offset` so
            survivors keep their CORRECT ABSOLUTE offsets (never renumber);
          * on a chunk that cannot be read, restarts from a `_LOG_START`
            that has moved past it (the chunk was reaped between the
            log_start read and the chunk read) and raises otherwise
            (`chunk_walk.restart_point_after_failed_read`): it never keeps
            the running sum past a chunk whose record_count it did not read.

        The manifest append IS the offset allocator: live chunk seq
        `k` occupies `[base_k, base_k + record_count_k - 1]`. Returns the
        surviving index (cheap: manifests are small; cold resolve path). For a
        partial read from `start_offset` the caller filters via
        `segments_covering`.

        AUTHORITATIVE (LIST) tail — the
        cached `_HEAD` lags the true tail under produce contention, which would
        truncate the resolved index and DROP committed records on consume.
        """
        var head = self._manifest.read_head_authoritative()
        var n_chunks = head.chunk_seq + Int64(1)  # chunk_seq is highest; -1 = empty
        var ls = self._manifest.read_log_start()
        var index = List[SegmentRef]()
        var running_base = ls.log_start_offset
        var seq = ls.log_start_seq
        while seq < n_chunks:
            try:
                var body_bytes = self._manifest.read_chunk(seq)
                var body = ManifestBody.decode(body_bytes)
                # A chunk that owns no segment object (a COMMIT/ABORT MARKER:
                # record_count 0, empty object_key) has no entry in the offset
                # index (do NOT GET its empty key). Its record_count still
                # feeds the running base (0 for a marker), so offsets match
                # `read_chunk_segment`'s prior-chunk sum. The read_committed
                # filter reads markers via `chunk_txn_tags`, not here.
                if not body.has_segment():
                    running_base += body.record_count
                    seq += Int64(1)
                    continue
                # Read scalars BEFORE moving the heap-owning object_key out
                # (Mojo 1.0.0b1: a field `^`-move makes the rest of `body`
                # unreadable — extract scalars first, move object_key last).
                var rc = body.record_count
                var crc = body.crc32
                # Copy (not move) the String so `body` destroys whole — Mojo
                # 1.0.0b1 rejects a single-field `^`-move out of `body`. Cheap
                # (one key per chunk, cold resolve path).
                var key = String(body.object_key)
                var base = running_base
                var last = base + rc - Int64(1)
                index.append(
                    SegmentRef(
                        chunk_seq=seq,
                        base_offset=base,
                        last_offset=last,
                        record_count=rc,
                        object_key=key^,
                        crc32=crc,
                    )
                )
                running_base += rc
                seq += Int64(1)
            except e:
                # The chunk's record_count is unknown, so the running base
                # cannot pass it: restart from a `_LOG_START` that moved past
                # it (reaped after our `_LOG_START` read), or raise.
                ls = restart_point_after_failed_read(
                    self._manifest, seq, e^, "ConsumeCore.resolve_index"
                )
                index = List[SegmentRef]()
                running_base = ls.log_start_offset
                seq = ls.log_start_seq
        return index^

    # -------------------------------------------------------------------------
    # chunk_txn_tags — the transaction tag of EVERY live manifest chunk.
    # -------------------------------------------------------------------------

    def chunk_txn_tags(mut self) raises -> List[ChunkTagAt]:
        """Read EVERY live manifest chunk's transaction tag, paired with its
        chunk_seq (the read_committed filter reads `marker_type` / `txn_id` /
        `producer_epoch` off each, and correlates a `ConsumeSegment` to its tag
        by `chunk_seq`). Unlike `resolve_index`, this INCLUDES marker chunks
        (degenerate offset range, dropped by the offset resolver) — the
        read_committed filter needs them too. Walks `[log_start_seq,
        num_chunks)`; fail-soft skips a chunk reaped mid-walk. Cold path.

        AUTHORITATIVE (LIST) tail (the
        cached `_HEAD` lags under produce contention)."""
        var head = self._manifest.read_head_authoritative()
        var n_chunks = head.chunk_seq + Int64(1)
        var ls = self._manifest.read_log_start()
        var out = List[ChunkTagAt]()
        var seq = ls.log_start_seq
        while seq < n_chunks:
            try:
                var body_bytes = self._manifest.read_chunk(seq)
                var body = ManifestBody.decode(body_bytes)
                # Copy (not ^-move) the txn_id so `body` destroys whole — Mojo
                # 1.0.0b1 rejects a single-field `^`-move out of `body`. Cheap
                # (one short id per chunk, cold path).
                out.append(
                    ChunkTagAt(
                        chunk_seq=seq,
                        marker_type=body.marker_type,
                        txn_id=String(body.txn_id),
                        producer_epoch=body.producer_epoch,
                    )
                )
            except e:
                if _is_not_found_msg(String(e)):
                    seq += Int64(1)
                    continue
                raise e^
            seq += Int64(1)
        return out^

    @staticmethod
    def segments_covering(
        index: List[SegmentRef], start_offset: Int64
    ) -> List[SegmentRef]:
        """Filter `index` to the segments whose range includes or follows
        `start_offset` (i.e. drop segments that end strictly before
        `start_offset`). The result is the contiguous suffix to read for a
        consume-from-offset request; the FIRST returned segment may straddle
        `start_offset` (the caller skips the leading rows < start_offset).
        Read-from-offset 0 returns the whole index (sequential drain).
        """
        var out = List[SegmentRef]()
        for i in range(len(index)):
            ref s = index[i]
            if s.last_offset >= start_offset:
                out.append(s.copy())
        return out^

    # -------------------------------------------------------------------------
    # read_segment — GET one .seg object, decode the footer, slice the stream.
    # -------------------------------------------------------------------------

    def read_segment(mut self, seg: SegmentRef) raises -> ConsumeSegment:
        """Read ONE segment object from the store and return its Arrow-IPC stream
        bytes (footer sliced off) + its manifest-authoritative offset range.

        Steps:
          1. GET the whole `.seg` object (we need the trailing footer).
          2. `SegmentFooter.decode` → the Arrow-stream length + the CRC.
          3. Cross-check the footer's record_count against the manifest's (a
             corruption / wrong-segment guard).
          4. Slice off the 40-byte footer → the leading Arrow-IPC stream.

        Log-compaction accommodation: a COMPACTED chunk's manifest
        `record_count` is PRESERVED at its ORIGINAL value (the offset allocator
        invariant — changing it would renumber every downstream chunk), but its
        rewritten `.seg` physically holds only the SURVIVOR rows (a sparse chunk
        — the survivor-offset sidecar carries the preserved offsets). So the
        footer's physical count is `<= seg.record_count` after compaction. The
        cross-check therefore rejects only `footer.record_count >
        seg.record_count` (a genuine corruption signal — a segment can never
        physically hold MORE rows than its manifest offset span); a sparse
        `<=` is the legitimate post-compaction shape. The returned
        `ConsumeSegment.record_count` reflects the PHYSICAL footer count (how
        many rows the decoded batch yields), while the offset span stays
        manifest-authoritative.

        The CALLER decodes `stream_bytes` with `decode_arrow_ipc_stream` (the
        broker core stays SDK-agnostic — module header).
        """
        var obj = self._segment_store.get(Path.parse(seg.object_key))
        var footer = SegmentFooter.decode(obj)
        if footer.record_count > seg.record_count:
            raise Error(
                "ConsumeCore.read_segment: footer record_count "
                + String(footer.record_count)
                + " > manifest record_count "
                + String(seg.record_count)
                + " for chunk "
                + String(seg.chunk_seq)
                + " (corruption / wrong segment — a segment can never hold more"
                " physical rows than its manifest offset span)"
            )
        var stream_len = footer.arrow_stream_len(len(obj))
        var stream_bytes = List[UInt8]()
        for i in range(stream_len):
            stream_bytes.append(obj[i])
        return ConsumeSegment(
            stream_bytes=stream_bytes^,
            base_offset=seg.base_offset,
            last_offset=seg.last_offset,
            # PHYSICAL footer count (sparse after compaction; == manifest count
            # for an un-compacted chunk). The decoded batch yields exactly this
            # many rows; the offset span (base/last) stays manifest-authoritative.
            record_count=footer.record_count,
            chunk_seq=seg.chunk_seq,
        )

    # -------------------------------------------------------------------------
    # read_from — the consume driver: resolve + read all segments from offset.
    # -------------------------------------------------------------------------

    def read_from(mut self, start_offset: Int64) raises -> Slab[ConsumeSegment]:
        """Resolve the offset index, find the segments covering
        `[start_offset, tail)`, and read each one (GET + footer-slice).
        Returns the ordered `Slab[ConsumeSegment]` (stream bytes + offset
        range), in produce order.

        `ConsumeSegment` is Movable-only (it owns a `List[UInt8]` stream),
        so the container is `Slab[ConsumeSegment]` (the Movable-only
        container), NOT `List[ConsumeSegment]` (Mojo's `List[T]`
        requires `T: Copyable`) — same discipline as `BrokerCore`'s
        `Slab[RecordBatch]` write buffer.

        `start_offset == 0` is a full sequential drain. A mid-offset read
        returns the covering suffix; the FIRST returned segment's `base_offset`
        may be < `start_offset` (it straddles) — the caller skips the leading
        rows. EOF is the empty slab (nothing committed at/after start_offset).

        Retention: `resolve_index` is log_start-aware, so this serves the
        SURVIVING range with CORRECT absolute offsets after reaping. A request
        BELOW log_start silently serves from log_start here — callers needing
        truncation detection (Kafka Fetch → OFFSET_OUT_OF_RANGE) MUST use
        `read_from_checked`, which exposes `effective_start_offset`.
        """
        var index = self.resolve_index()
        var covering = ConsumeCore[Self.Storage].segments_covering(
            index, start_offset
        )
        var out = Slab[ConsumeSegment]()
        for i in range(len(covering)):
            out.append(self.read_segment(covering[i].copy()))
        return out^

    def read_from_checked(
        mut self, start_offset: Int64
    ) raises -> ConsumeReadResult:
        """Log_start-aware read that EXPOSES the effective start. Like
        `read_from`, but returns a `ConsumeReadResult` carrying
        `effective_start_offset` (== the partition's persisted log_start) +
        `truncated` (True iff `start_offset < effective_start_offset` — the
        caller asked for a reaped offset).

        NO SILENT CLAMP: surviving segments keep their CORRECT
        ABSOLUTE offsets (never renumber); the caller DETECTS truncation via
        the result. The Kafka Fetch path maps `truncated → OFFSET_OUT_OF_RANGE`
        (clients have auto.offset.reset); a native consumer may serve
        the surviving range BECAUSE effective_start is explicit here.
        """
        var ls = self._manifest.read_log_start()
        var effective = ls.log_start_offset
        var truncated = start_offset < effective
        # Serve from max(requested, effective) — never below the retained range.
        var eff_start = start_offset if start_offset >= effective else effective
        var index = self.resolve_index()
        var covering = ConsumeCore[Self.Storage].segments_covering(
            index, eff_start
        )
        var out = Slab[ConsumeSegment]()
        for i in range(len(covering)):
            out.append(self.read_segment(covering[i].copy()))
        return ConsumeReadResult(
            segments=out^,
            effective_start_offset=effective,
            requested_start_offset=start_offset,
            truncated=truncated,
        )

    # -------------------------------------------------------------------------
    # read_chunk_body — the raw manifest chunk body (compaction sidecar reader).
    # -------------------------------------------------------------------------

    def read_chunk_body(mut self, chunk_seq: Int64) raises -> List[UInt8]:
        """The manifest chunk body at `chunk_seq`, undecoded. A caller that
        must map a LOG-COMPACTED chunk's rows back to their preserved absolute
        offsets reads the survivor sidecar off it
        (`log_compaction.decode_compacted_survivor_offsets`); the core itself
        stays free of the compaction codec."""
        return self._manifest.read_chunk(chunk_seq)

    # -------------------------------------------------------------------------
    # read_chunk_segment — read ONE segment by its manifest chunk seq (tail).
    # -------------------------------------------------------------------------

    def read_chunk_segment(
        mut self, chunk_seq: Int64
    ) raises -> Optional[ConsumeSegment]:
        """Read the segment at a specific manifest chunk seq, computing its
        base offset from the running sum of LIVE prior chunks. Used by the
        TAIL/live-consume mode: a consumer tracking `_next_chunk` re-polls
        `num_chunks`, and for each newly-appeared chunk calls this to read it.

        Returns None for a chunk that owns no segment object
        (`ManifestBody.has_segment` is False: a txn COMMIT/ABORT marker); the
        chunk still occupies its manifest slot, so the caller advances past it.

        Retention: seeds the running base from the persisted
        log_start (NOT 0) and sums only LIVE prior chunks `[log_start_seq,
        chunk_seq)` — so a tail read after reaping keeps the CORRECT absolute
        base offset instead of breaking on the reaped chunk 0.
        """
        # Seed from log_start; sum LIVE prior record_counts for the base offset.
        var ls = self._manifest.read_log_start()
        var running_base = ls.log_start_offset
        var seq = ls.log_start_seq
        while seq < chunk_seq:
            var prior = self._manifest.read_chunk(seq)
            var pbody = ManifestBody.decode(prior)
            running_base += pbody.record_count
            seq += Int64(1)
        var body_bytes = self._manifest.read_chunk(chunk_seq)
        var body = ManifestBody.decode(body_bytes)
        if not body.has_segment():
            # A marker: no `.seg` to GET (its object_key is empty).
            return None
        var rc = body.record_count
        var crc = body.crc32
        var key = String(body.object_key)  # copy so `body` destroys whole.
        var seg = SegmentRef(
            chunk_seq=chunk_seq,
            base_offset=running_base,
            last_offset=running_base + rc - Int64(1),
            record_count=rc,
            object_key=key^,
            crc32=crc,
        )
        return Optional[ConsumeSegment](self.read_segment(seg^))


@always_inline
def _is_not_found_msg(msg: String) -> Bool:
    """Classify a not-found / 404 store error (the reaped-chunk race in
    `resolve_index`)."""
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )

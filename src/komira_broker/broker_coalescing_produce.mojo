# =============================================================================
# komira_broker/broker_coalescing_produce.mojo
#   The BROKER produce path on the CoalescingWindow primitive (the
#   ASYNC/parkable path).
# =============================================================================
#
# This file plugs the broker's DOMAIN encode/decode/write into the GENERAL
# coalescing-window spine (komira_objectstore's coalescing_window) — so the
# broker inherits the durable, PARKABLE commit loop unchanged, and the four
# flush variants (flush / flush_with_producer /
# flush_with_producer_exactly_once / flush_with_producer_txn) COLLAPSE into
# producer/txn/lease STATE on ONE codec + a mode-correct appender (one driver,
# not four near-identical methods).
#
# ── WHY (the burst-stall fix) ────────────────────────────────────────────────
# BrokerCore's `flush*` methods are SYNCHRONOUS: the produce serve thread BLOCKS
# across the segment PUT RTT + the manifest create-CAS RTT. Under a produce burst
# (one connection streaming, or a rolling restart's re-produce) the serve loop
# cannot make progress on OTHER connections while one produce's object-store round-trips
# are in flight. The CoalescingWindow spine drives the write as a POLL-SHAPED op
# on the per-worker reactor: the produce PARKS across the create-CAS RTT, so the
# serve loop multiplexes other connections WHILE one produce is parked (the
# AsyncReassignOp / AsyncManifestAppendOp shape, applied to produce).
#
# ── THE 3 BROKER CONFORMERS (the consumer's pluggable surface) ────────────────
#   1. BrokerHeadReader[Storage]  (SEAM 2: AuthHeadReader) — the parkable READ of
#      the partition manifest HEAD + the PARKABLE STAGE-BLOB (the <=8MiB segment
#      object PUT, content-addressed, If-None-Match create). Owns its own store
#      clone; the in-flight read / stage-blob op lives INSIDE the conformer.
#   2. BrokerSegCodec  (SEAM 3: BatchCodec) — estimate_bytes (the size
#      band's input) + encode (Arrow-IPC + TSG1 SegmentFooter -> the segment blob
#      staged via staged_blob; the manifest-pointer body via encode_manifest_body).
#      IDENTITY arbitration (every produce a winner; loser_outcomes empty). The
#      producer / txn / lease STATE the four flush variants differed by lives on
#      THIS codec (one codec, configured per produce — not four methods).
#   3. BrokerBatchAppender[Storage]  (SEAM 5: BatchAppender) — the PARKABLE,
#      MODE-CORRECT durable write. Two consumer-selected modes:
#        * ESCALATING (at-least-once): the parkable exact-slot create-CAS at
#          auth_head+1; a 412 (LOST_SLOT) drives the spine's LIVE 412-loop
#          (re-read authoritative head + re-encode + re-append at the new
#          auth_head+1 — which IS escalation past the contended slot, at the spine
#          level). The broker's at-least-once `append`/`_append_inner` semantics.
#        * IDEMPOTENT-SINGLETON (EOS): `append_idempotent` keyed by (producer_id,
#          first_seq) — the exactly-once sentinel protocol. VALID ONLY N==1 per
#          the SINGLETON INVARIANT (the coalesced N>1 body cannot be
#          replayed idempotently against a single dedup key). So EOS flushes one
#          producer batch per spine (the acks=all singleton path).
#
# ── THE OUTCOME (the broker's per-produce result) ────────────────────────────
# BrokerProduceOutcome carries the Kafka-facing ack: the manifest-assigned offset
# range + the segment key + the chunk_seq + an EOS discriminant (COMMITTED /
# DUPLICATE) so the terminal handler maps it to the Kafka response. The window's
# (orig_idx, Outcome) pairs come back in buffered order; for the broker the
# coalesced batch is one append, so all winners share one chunk_seq.
#
# ── THE SLAB-SAFETY CONTRACT (GATES, not guidelines) ─────────────────────────
#   * The buffered unit is `BrokerProduceItem` — a Movable-NOT-Copyable value
#     owning ONE RecordBatch + POD per-item bookkeeping. Stored in the window's
#     RamAccumulator's Slab[BrokerProduceItem] by typed init_pointee_move (a
#     CONCRETE origin) + drained by value MOVE. NEVER laundered through a wildcard
#     origin. (RecordBatch is itself Movable-only — already the Slab[RecordBatch]
#     contract BrokerCore honored.)
#   * The in-flight store op (read / stage-blob / append) stays INSIDE its
#     conformer across the park (the conformer's own concrete-origin store clone;
#     for S3 an ArcPointer transport handle — NEVER a byte-Slab + MutExternalOrigin
#     wildcard). Only typed CasOpProgress / CasReadResult / AppendOutcome cross
#     any seam boundary.
#   * The suspended spine lives behind the window's SINGLE OwnedPointer[SM] frame
#     (CoalescingWindow._frame) — never a Movable struct in a byte-slab.
#   * The encoded segment blob (<=8MiB) is staged via the PARKABLE stage-blob
#     phase (the spine never blocks on the PUT).
#
# ── ENCAPSULATION ─────────────────────────────────────────────────
# ZERO UnsafePointer in any signature; ZERO wildcard origin; ZERO
# unsafe_from_address. The reactor is threaded into every poll method per-call
# (never a field). The owned substrate (the store clone + CasManifestStore) is
# held BY VALUE (both Movable structs encapsulating their Arc/Slab internals —
# no pointer crosses this module boundary).
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor

from komira_objectstore.cas_manifest import (
    AppendResult,
    AsyncManifestAppendOp,
    CasManifestStore,
    IdempotentAppendResult,
    IDEMPOTENT_COMMITTED,
    IDEMPOTENT_DUPLICATE,
    IDEMPOTENT_FENCED,
    IDEMPOTENT_LEASE_FENCED,
    IDEMPOTENT_RETRYABLE,
)
from komira_objectstore.manifest_slot_guard import (
    is_log_start_unread,
    is_slot_reaped,
)
from komira_objectstore.coalescing_window import (
    APPEND_ERR,
    APPEND_LOST_SLOT,
    AppendOutcome,
    AuthHeadReader,
    BatchAppender,
    BatchCodec,
    CoalescingWindow,
    EncodedBatch,
    FlushPolicy,
    FLUSH_REASON_EXPLICIT,
    FLUSH_REASON_NONE,
    FLUSH_REASON_SHUTDOWN,
    RamAccumulator,
    READ_ERR_CONFLICT,
    READ_ERR_FATAL,
    READ_ERR_TORN,
    SpineFactory,
    STAGE_BLOB_ERR_FATAL,
    STAGE_BLOB_ERR_REKEY,
    _CoalesceSpine,
)
from komira_objectstore.path import Path
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    CasReadResult,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
)

from .broker_core import (
    SegmentFooter,
    assemble_segment_from_frames,
    encode_record_batch_frame_bytes,
    FLUSH_BYTES,
    FLUSH_MS,
    _manifest_prefix,
    _segment_key,
    _is_precondition_seg,
    _broker_proc_nonce,
)
from .manifest_body import encode_manifest_body, MARKER_NONE


# =============================================================================
# §0 — appender MODE discriminants (consumer-selected; see the file header).
# =============================================================================
# ESCALATING is the broker at-least-once mode (the parkable exact-slot create-CAS
# whose spine 412-loop escalates past the contended slot). IDEMPOTENT_SINGLETON
# is the broker-EOS mode (append_idempotent keyed by (producer_id, first_seq),
# N==1 only). A consumer picks ONE per produce via BrokerSegCodec's config.
comptime BROKER_APPEND_MODE_ESCALATING: UInt8 = 0
comptime BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON: UInt8 = 1


# =============================================================================
# §0.0 — BROKER_FLUSH_SEG_KEY_STRIDE — the per-flush segment-key counter stride.
# =============================================================================
# The silent data-loss hazard: the segment key is `<flush_ts>-<broker_id>-
# <proc_nonce>-<uniq>` where `<uniq>` is a monotone per-codec counter. The codec
# is built FRESH per flush, so a per-codec counter that RESET to 0 each flush
# would make two flushes sharing a flush_ts (== items[0].ts_ms) + the same
# proc_nonce mint the SAME key — flush 2's create-CAS would 412 on flush 1's
# object + (if that 412 were treated as a win) reference flush 1's bytes ->
# flush 2's records SILENTLY LOST.
#
# The fix hoists the counter onto the LONG-LIVED factory (one per partition) and
# RESERVES a disjoint STRIDE per flush: `make_spine` seeds the fresh codec with
# the factory's current counter and advances the factory counter by STRIDE, so
# flush N draws keys from [N*STRIDE+1 .. (N+1)*STRIDE] and flush N+1 from the NEXT
# disjoint range — two flushes in a process can NEVER mint a colliding key.
#
# STRIDE must cover the MAX re-keys ONE flush can mint within its range: a flush
# re-mints a key on every re-encode (each LOST_SLOT append 412 AND each colliding
# stage-blob 412 routes through the spine's re-encode, which calls
# `_next_segment_key` once). The spine bounds the re-encode loop at
# MAX_COMMIT_ATTEMPTS (256); STRIDE = 512 covers that bound with headroom (a flush
# that exhausts its stride is already failing the 256-attempt convergence bound
# loud, long before it could cross into the next flush's range).
comptime BROKER_FLUSH_SEG_KEY_STRIDE: Int64 = 512


# The EOS per-produce result discriminant (mirrors broker_core's EO_* but lives
# on the coalescing Outcome — the terminal handler maps it to the Kafka code).
comptime BPO_AT_LEAST_ONCE: UInt8 = 0  # the at-least-once (ESCALATING) ack
comptime BPO_EOS_COMMITTED: UInt8 = 1  # EOS won + appended exactly once
comptime BPO_EOS_DUPLICATE: UInt8 = 2  # EOS already committed (idempotent ack)
comptime BPO_EOS_FENCED: UInt8 = 3  # EOS stale producer-epoch zombie
comptime BPO_EOS_LEASE_FENCED: UInt8 = 4  # EOS stale partition-ownership writer
comptime BPO_EOS_RETRYABLE: UInt8 = 5  # EOS in-flight winner / genuine no-commit


# =============================================================================
# §0.1 — _EosResultCell — the EOS-discriminant side channel.
# =============================================================================
# The IDEMPOTENT-SINGLETON (EOS) append produces a discriminant (COMMITTED /
# DUPLICATE / FENCED / LEASE_FENCED / RETRYABLE) the terminal Kafka handler maps
# to a wire code — but that discriminant is NOT in the shared AppendResult the
# spine threads through `winner_outcome`. Rather than widen the shared
# AppendResult / the `winner_outcome` seam (which every consumer shares), the EOS
# appender writes the discriminant into a SHARED cell the driver also holds, and
# the driver reads it after the flush. A small POD cell behind an ArcPointer
# (concrete origin, no wildcard); the appender (owned by the spine,
# consumed on done) and the driver share the SAME cell, so the discriminant
# survives the spine's teardown. At most one EOS flush is in flight per partition
# (the single-in-flight-op constraint), so one cell per driver is race-free in the
# single-threaded prefork worker.
#
# The cell is RESET at the start of EVERY flush (in make_spine), not just the
# EOS ones — a cell latched `engaged` on the first EOS stamp and never cleared
# would, after an EOS-then-at-least-once sequence, make the driver's
# last_eos_engaged() / last_eos_kind() return STALE prior-EOS state. Resetting
# per flush makes the cell describe ONLY the most recent flush: an at-least-once
# flush leaves engaged=False (it never stamps), an EOS flush stamps the fresh cell.


struct _EosResultCell(Movable, Deinitable):
    """The EOS-append discriminant + the committed offsets, written by the EOS
    appender + read by the driver after the flush. POD."""

    var eos_kind: UInt8
    var base_offset: Int64
    var last_offset: Int64
    var chunk_seq: Int64
    var engaged: Bool

    def __init__(out self):
        self.eos_kind = BPO_AT_LEAST_ONCE
        self.base_offset = Int64(-1)
        self.last_offset = Int64(-1)
        self.chunk_seq = Int64(-1)
        self.engaged = False


# =============================================================================
# §1 — BrokerProduceItem — the buffered unit (one producer batch).
# =============================================================================
# A Movable value carrying the PRE-ENCODED Arrow-IPC RecordBatch FRAME BYTES of
# one producer batch (encoded ONCE at buffer time, when the caller owns the
# RecordBatch by value) + its schema (Copyable) + row count + the POD per-item
# bookkeeping (the enqueue wall-ts for the linger band; the producer identity for
# the IDEMPOTENT-SINGLETON dedup key).
#
# WHY PRE-ENCODED FRAME BYTES (not the RecordBatch). The coalescing-window codec's
# `encode` BORROWS the buffered items by ref + must NOT consume them (the spine
# RETAINS them for the LIVE 412-loop re-encode). But RecordBatch is Movable-only
# (no `copy()`), and the Arrow-IPC frame encode (encode_record_batch_message)
# CONSUMES its columns — so the codec could neither move nor copy a retained
# RecordBatch to re-encode it. Encoding each batch to its (Copyable) frame bytes
# at buffer time makes `encode` a pure assembly over the retained frame bytes +
# the schema (byte-identical to encode_segment), with ZERO RecordBatch move on
# the re-encode path. That is the slab-safe shape: the heap-owning RecordBatch is
# consumed at buffer time (a CONCRETE owned move), and only Copyable bytes survive
# in the Slab[BrokerProduceItem] across the parks + re-encodes.
#
# Stored in the window's RamAccumulator Slab by typed init_pointee_move
# (concrete origin) + drained by value MOVE — the inner List[UInt8] frame bytes +
# String schema state are NEVER laundered through a wildcard origin.


struct BrokerProduceItem(Movable, Deinitable):
    """One buffered producer batch awaiting a coalesced flush, carrying its
    PRE-ENCODED Arrow-IPC RecordBatch frame bytes (see the §1 header for why the
    frame bytes, not the RecordBatch).

    Field layout:
      var frame_bytes: List[UInt8] — the pre-encoded Arrow-IPC RecordBatch message
                                  frame (Copyable; survives the LIVE 412-loop
                                  re-encode without a RecordBatch move).
      var schema: Schema        — the batch's schema (Copyable; the first item's
                                  schema seeds the segment's Schema frame).
      var num_rows: Int64       — the batch's row count (the segment's record
                                  total + the offset-range width).
      var ts_ms: Int64          — the enqueue wall clock (the linger band input).
      var producer_id: Int64    — the idempotent-producer id (-1 == non-idempotent
                                  / at-least-once).
      var producer_epoch: Int64 — the producer epoch (the EOS fence input).
      var first_seq: Int64      — the producer batch's first sequence (the EOS
                                  dedup key's second half).
      var last_seq: Int64       — the producer batch's last sequence.
    """

    var frame_bytes: List[UInt8]
    var schema: Schema
    var num_rows: Int64
    var ts_ms: Int64
    var producer_id: Int64
    var producer_epoch: Int64
    var first_seq: Int64
    var last_seq: Int64

    def __init__(
        out self,
        var rb: RecordBatch,
        ts_ms: Int64,
        producer_id: Int64 = Int64(-1),
        producer_epoch: Int64 = Int64(0),
        first_seq: Int64 = Int64(-1),
        last_seq: Int64 = Int64(-1),
    ) raises:
        # Encode the RecordBatch to its Arrow-IPC frame bytes ONCE here (when we
        # own `rb` by value). The schema is captured (Copyable) BEFORE the columns
        # are consumed by the frame encode.
        self.schema = rb.schema.copy()
        self.num_rows = Int64(rb.num_rows())
        self.frame_bytes = encode_record_batch_frame_bytes(rb^)
        self.ts_ms = ts_ms
        self.producer_id = producer_id
        self.producer_epoch = producer_epoch
        self.first_seq = first_seq
        self.last_seq = last_seq


# =============================================================================
# §2 — BrokerHead — the decoded authoritative manifest HEAD.
# =============================================================================
# The codec-owned Head value the encode conditions on. POD: the current chunk seq
# + the next offset the append will claim (read authoritatively at flush time).
# The codec projects head_slot = chunk_seq + 1 (the exact-slot create-CAS target).


@fieldwise_init
struct BrokerHead(Copyable, Movable, Deinitable):
    """The decoded partition manifest HEAD (codec-owned). POD.

    Field layout:
      var chunk_seq: Int64   — the highest committed chunk seq (-1 == empty).
      var next_offset: Int64 — the base offset the next append claims.
    """

    var chunk_seq: Int64
    var next_offset: Int64


# =============================================================================
# §3 — BrokerProduceOutcome — the per-produce Kafka-facing ack.
# =============================================================================
# Copyable (the spine collects outcomes in a List[Tuple[Int, Outcome]] — List[T]
# requires T: Copyable). A small per-item RESULT value (the manifest-assigned
# offset range + segment key + chunk_seq + the EOS discriminant) handed back to
# each produce caller. The terminal handler maps `eos_kind` to the Kafka code.


@fieldwise_init
struct BrokerProduceOutcome(Copyable, Movable, Deinitable):
    """The durable ack for one coalesced produce.

    Field layout:
      var base_offset: Int64   — first committed offset (manifest-assigned).
      var last_offset: Int64   — last committed offset (manifest-assigned).
      var chunk_seq: Int64     — the manifest chunk slot this commit won.
      var intra_batch_seq: Int — this winner's position within the committed
                                  chunk (0 for the singleton EOS path).
      var eos_kind: UInt8      — BPO_* : the EOS discriminant (BPO_AT_LEAST_ONCE
                                  for the ESCALATING mode; COMMITTED / DUPLICATE
                                  for the IDEMPOTENT-SINGLETON mode).
    """

    var base_offset: Int64
    var last_offset: Int64
    var chunk_seq: Int64
    var intra_batch_seq: Int
    var eos_kind: UInt8


# =============================================================================
# §4 — BrokerHeadReader[Storage] — SEAM 2 (AuthHeadReader).
# =============================================================================
# The parkable READ of the partition manifest HEAD + the PARKABLE STAGE-BLOB. The
# reader OWNS a CasManifestStore[Storage] (built over a store clone) for the HEAD
# read, and a SEPARATE store clone for the content-addressed segment-blob PUT.
#
# The HEAD read: the reader drives the store's parkable read_start/read_poll over
# the manifest `_HEAD` key. The decode (BatchCodec.decode_head) turns the
# CasReadResult into a BrokerHead — but the broker reads the AUTHORITATIVE head at
# the appender (read_head_authoritative bypasses the cached `_HEAD`), so the
# reader's HEAD read is for the encode's offset-base estimate (the footer's debug
# fields are NOT load-bearing; the offset is assigned by the append). To
# preserve the elision (one fewer object-store round-trip per ack), the
# reader returns an ABSENT CasReadResult WITHOUT a store read — the codec decodes
# that to BrokerHead{chunk_seq=-1, next_offset=0} (pre-commit base 0, exactly the
# `flush*` variants' `pre_commit_base = Int64(0)`). The AUTHORITATIVE slot is
# derived at the appender. This keeps the produce hot path at the same round-trip
# count as the bespoke flush (stage-blob PUT + append create-CAS) PLUS the
# parkability.
#
# THE REAL-S3 LIST-DELIMITER TRAP: the
# broker reader's decode does NOT fall back to a LIST replay (the appender's
# read_head_authoritative owns the LIST recovery, and CasManifestStore already
# unions common_prefixes + objects there). So this reader is trap-free by
# construction.


struct BrokerHeadReader[
    Storage: CloneableConditionalWriteStore & AsyncCasStore
](AuthHeadReader, Movable, Deinitable):
    """SEAM 2 for the broker: a HEAD read with no
    pre-flush HEAD GET — the offset base is 0, the authoritative slot is derived
    at the appender) + the PARKABLE content-addressed segment-blob PUT.

    Owns a `Storage` clone for the blob PUT (the in-flight PUT op lives INSIDE the
    clone across the park). The reactor is threaded per-call.
    """

    # The segment-blob store clone (the parkable If-None-Match create PUT).
    var _blob_store: Self.Storage

    def __init__(out self, var blob_store: Self.Storage):
        self._blob_store = blob_store^

    # ---- the HEAD read (ELIDED — returns absent without a store read) ----

    def read_head_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        # No pre-flush HEAD GET. The offset base is 0 (the
        # footer's debug fields are not load-bearing; the AUTHORITATIVE offset is
        # assigned by the append). Return READY immediately — the decode produces
        # BrokerHead{chunk_seq=-1, next_offset=0}, and the appender derives the
        # true slot via read_head_authoritative.
        return CasOpProgress.ready()

    def read_head_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        # The HEAD read is elided (always READY at start), so poll is never the
        # in-flight path; return READY defensively.
        return CasOpProgress.ready()

    def take_read(mut self) raises -> CasReadResult:
        # The elided HEAD read yields an ABSENT result (the codec decodes it to
        # BrokerHead{chunk_seq=-1, next_offset=0} == pre_commit_base 0).
        return CasReadResult(absent=True, body=List[UInt8](), etag=String(""))

    def classify_read_error(self, msg: String) -> UInt8:
        # The HEAD read is elided so this never fires; classify defensively the
        # same way the broker's _is_precondition_seg / consume paths do.
        if msg.find("connect failed") >= 0 or msg.find("errno") >= 0:
            return READ_ERR_FATAL
        if _is_precondition_seg(msg):
            return READ_ERR_CONFLICT
        return READ_ERR_TORN

    # ---- the PARKABLE content-addressed segment-blob PUT ----

    def stage_blob_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, key: String, var bytes: List[UInt8], mut reactor: Reactor[S]
    ) raises -> CasOpProgress:
        # The segment blob is content-addressed (the codec mints a structurally
        # unique key per flush — drawn from the factory-hoisted, per-flush-DISJOINT
        # counter range, so two flushes in a process NEVER mint a colliding key).
        # An If-None-Match create PUT. A 412 here means an object ALREADY EXISTS at
        # the minted key — and because the per-flush key ranges are disjoint, that
        # is NOT "identical bytes from my own re-produce" but a genuine COLLISION
        # (a stale prior object under a colliding key — e.g. a residual cross-
        # process race the per-process proc_nonce would normally diverge). Treating it as
        # a WIN would make the manifest body reference FOREIGN bytes -> this flush's
        # records SILENTLY LOST (the gap BrokerCore._stage_segment closes too).
        # So a 412 is surfaced as an ERROR the spine classifies STAGE_BLOB_ERR_REKEY
        # -> the LIVE re-encode loop re-mints a FRESH key (next in this flush's
        # disjoint range) + rebuilds the body, NEVER referencing the foreign object.
        # The in-flight PUT op lives INSIDE the blob_store clone across the park.
        return self._blob_store.cas_put_start[S](
            Path.parse(key), bytes^, String(""), reactor
        )

    def stage_blob_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._blob_store.cas_put_poll[S](reactor)

    def stage_blob_take(mut self) raises -> None:
        # Harvest the committed PUT. A deferred-412 (the slow-CAS slow_ticks>0 path
        # surfaces the 412 at take) RAISES a precondition here — which the spine's
        # stage-blob ERR path routes through classify_stage_blob_error ->
        # STAGE_BLOB_ERR_REKEY -> the re-encode loop (a fresh key), so the take-path
        # 412 re-keys exactly like the start/poll-path 412. NEVER swallowed as a win
        # (a swallow here is the silent-data-loss BLOCKER). Any other raise
        # propagates (the spine's ERR phase classifies it FATAL).
        _ = self._blob_store.cas_put_take()

    def classify_stage_blob_error(self, msg: String) -> UInt8:
        """A stage-blob create-PUT 412 is a colliding-key COLLISION (the per-flush
        key ranges are disjoint, so it is never my own re-produce). Re-key via the
        spine's re-encode loop (STAGE_BLOB_ERR_REKEY) — a fresh, disjoint key + a
        rebuilt body — so the manifest never references the foreign object. Any
        non-412 store error is terminal (STAGE_BLOB_ERR_FATAL)."""
        if _is_precondition_seg(msg):
            return STAGE_BLOB_ERR_REKEY
        return STAGE_BLOB_ERR_FATAL


# =============================================================================
# §5 — BrokerSegCodec — SEAM 3 (BatchCodec).
# =============================================================================
# The broker DOMAIN encode: the buffered BrokerProduceItems -> ONE Arrow-IPC
# segment (Schema + N RecordBatch frames + EOS) + the TSG1 SegmentFooter, staged
# as a content-addressed blob; the manifest-pointer body via encode_manifest_body
# (the producer / txn trailer folded IN). IDENTITY arbitration — every produce a
# winner (the broker does not arbitrate at encode; the manifest create-CAS does).
#
# THE FOUR-VARIANT COLLAPSE. The four bespoke flush methods differed ONLY by what
# trailer the manifest body carried + which append verb committed it:
#   * flush                          -> producer_id=-1, no trailer (at-least-once).
#   * flush_with_producer            -> producer trailer (at-least-once).
#   * flush_with_producer_exactly_once -> producer trailer + append_idempotent.
#   * flush_with_producer_txn        -> producer trailer + MARKER_NONE + txn_id.
# Here that is STATE on this codec (the producer fields + txn_id + the
# marker_type), set per produce. The appender MODE (ESCALATING vs
# IDEMPOTENT-SINGLETON) selects the verb. ONE codec, configured per flush — not
# four near-identical methods.
#
# THE STAGE-BLOB KEY. Content-addressed (the segment key shape:
# <cluster>/topics/<topic>/<part>/segments/<flush_ts>-<broker_id>-<nonce>-<uniq>
# .seg). The codec mints it deterministically from the cluster/topic/partition +
# a monotone per-codec counter + the proc nonce, so two flushes never collide and
# a content-identical re-flush (a 412 on the If-None-Match create) is an
# idempotent win. The key carries NO offset — offsets are assigned at
# the manifest append).


struct BrokerSegCodec(BatchCodec, Movable, Deinitable):
    """SEAM 3 for the broker: encode the buffered producer batches into one
    Arrow-IPC segment (staged as a content-addressed blob) + the manifest-pointer
    body, with the producer / txn trailer folded in (the four-variant collapse).
    IDENTITY arbitration — every produce a winner."""

    comptime Item = BrokerProduceItem
    comptime Head = BrokerHead
    comptime Outcome = BrokerProduceOutcome

    # The per-flush key-minting inputs (the segment key).
    var _cluster: String
    var _topic: String
    var _partition: Int64
    var _broker_id: String
    var _proc_nonce: Int64
    var _seg_counter: Int64
    var _flush_ts: Int64
    # The producer / txn trailer STATE (the four-variant collapse). A
    # producer_id of -1 produces a non-idempotent body (== the bare `flush`).
    var _producer_id: Int64
    var _producer_epoch: Int64
    var _first_seq: Int64
    var _last_seq: Int64
    var _txn_id: String
    var _append_mode: UInt8

    def __init__(
        out self,
        var cluster: String,
        var topic: String,
        partition: Int64,
        var broker_id: String,
        proc_nonce: Int64,
        flush_ts: Int64,
        producer_id: Int64 = Int64(-1),
        producer_epoch: Int64 = Int64(0),
        first_seq: Int64 = Int64(-1),
        last_seq: Int64 = Int64(-1),
        var txn_id: String = String(""),
        append_mode: UInt8 = BROKER_APPEND_MODE_ESCALATING,
        seg_counter_seed: Int64 = Int64(0),
    ):
        self._cluster = cluster^
        self._topic = topic^
        self._partition = partition
        self._broker_id = broker_id^
        self._proc_nonce = proc_nonce
        # Seed from the factory's globally-unique counter so this flush
        # draws keys from its OWN disjoint stride range — _next_segment_key bumps
        # BEFORE use, so the first key minted is `seg_counter_seed + 1`.
        self._seg_counter = seg_counter_seed
        self._flush_ts = flush_ts
        self._producer_id = producer_id
        self._producer_epoch = producer_epoch
        self._first_seq = first_seq
        self._last_seq = last_seq
        self._txn_id = txn_id^
        self._append_mode = append_mode

    def decode_head(mut self, var rr: CasReadResult) raises -> BrokerHead:
        # The reader ALWAYS elides the HEAD GET (take_read returns an ABSENT
        # CasReadResult unconditionally), so the decoded head is the pre-commit
        # estimate (chunk_seq=-1, next_offset=0) — exactly the bespoke flush's
        # pre_commit_base=0. The AUTHORITATIVE slot is derived at the appender
        # via read_head_authoritative.
        _ = rr^
        return BrokerHead(chunk_seq=Int64(-1), next_offset=Int64(0))

    def head_slot(self, ref auth: BrokerHead) -> Int64:
        # The exact-slot HINT (= auth_head + 1). The broker appender re-derives the
        # AUTHORITATIVE slot from the WAL (read_head_authoritative), so this hint
        # is advisory (auth.chunk_seq is -1 under the elision -> hint 0); the
        # appender's authoritative read is the load-bearing slot.
        return auth.chunk_seq + Int64(1)

    def estimate_bytes(self, ref it: BrokerProduceItem) -> Int:
        # The size band's input. The batch is ALREADY encoded to its
        # frame bytes at buffer time, so the EXACT encoded frame size is free here
        # (more accurate than BrokerCore.produce's _estimate_batch_bytes guess) —
        # no encode-to-measure, no raise.
        return len(it.frame_bytes)

    def _next_segment_key(mut self) -> String:
        # Mint a structurally-unique content-addressed segment key. The
        # monotone per-codec counter + the proc nonce make two flushes diverge; a
        # content-identical re-flush 412s the If-None-Match create (idempotent
        # win). NO offset in the key (assigned at the manifest append).
        self._seg_counter += Int64(1)
        return _segment_key(
            self._cluster,
            self._topic,
            self._partition,
            self._flush_ts,
            self._broker_id,
            self._seg_counter,
            self._proc_nonce,
        )

    def encode(
        mut self, ref items: Slab[BrokerProduceItem], var auth: BrokerHead
    ) raises -> EncodedBatch[BrokerProduceOutcome]:
        # ---- Step 1: assemble the segment from the RETAINED items' PRE-ENCODED
        # frame bytes (BORROW the items by ref — RETAINED for a LOST_SLOT
        # re-encode; the frame bytes are Copyable so the re-encode re-reads them
        # without consuming any RecordBatch — the slab-safe shape). The schema
        # comes from the first item (one producer stream per partition shares one
        # schema). ----
        var frames = List[List[UInt8]]()
        var winners = List[Int]()
        var total_records = Int64(0)
        for i in range(items.len()):
            ref it = items[i]
            frames.append(it.frame_bytes.copy())  # Copyable bytes; no RB move.
            total_records += it.num_rows
            winners.append(i)
        var schema = items[0].schema.copy()

        # ---- Step 2: assemble the segment (Arrow-IPC stream + TSG1 footer) from
        # the borrowed frame bytes — byte-identical to encode_segment. The
        # pre_commit_base is 0 (the footer's offset fields
        # are debug-only; the authoritative offset is the append's). ----
        var seg_bytes = assemble_segment_from_frames(
            schema, frames, total_records, auth.next_offset
        )
        var footer = SegmentFooter.decode(seg_bytes)
        var record_count = footer.record_count
        var crc = footer.crc32
        var segment_bytes = Int64(len(seg_bytes))

        # ---- Step 3: the content-addressed segment key (staged as the blob). ----
        var seg_key = self._next_segment_key()

        # ---- Step 4: the manifest-pointer body (the producer / txn trailer folded
        # in — the four-variant collapse). A producer_id of -1 produces a
        # non-idempotent body (== the bare `flush`); a non-empty txn_id tags the
        # chunk txn-open (MARKER_NONE) (== flush_with_producer_txn). ----
        var body: List[UInt8]
        if self._txn_id.byte_length() > 0:
            body = encode_manifest_body(
                seg_key,
                record_count,
                crc,
                segment_bytes,
                self._flush_ts,
                self._producer_id,
                self._producer_epoch,
                self._first_seq,
                self._last_seq,
                MARKER_NONE,
                self._txn_id,
            )
        elif self._producer_id >= Int64(0):
            body = encode_manifest_body(
                seg_key,
                record_count,
                crc,
                segment_bytes,
                self._flush_ts,
                self._producer_id,
                self._producer_epoch,
                self._first_seq,
                self._last_seq,
            )
        else:
            body = encode_manifest_body(
                seg_key, record_count, crc, segment_bytes, self._flush_ts
            )

        # ---- Emit the EncodedBatch: the manifest-pointer body + the staged
        # segment blob (content-addressed) + IDENTITY arbitration (every winner).
        # No lease fence carried here (the appender threads the lease epochs from
        # the factory). ----
        return EncodedBatch[BrokerProduceOutcome](
            body^,
            record_count,
            Optional[List[UInt8]](seg_bytes^),
            seg_key^,
            Int64(0),  # lease_epoch (threaded at the appender, not the codec)
            Int64(0),  # current_lease_epoch
            List[Tuple[Int, BrokerProduceOutcome]](),  # no losers (identity)
            winners^,
        )

    def winner_outcome(
        self, orig_idx: Int, intra_batch_seq: Int, append: AppendResult
    ) -> BrokerProduceOutcome:
        # The per-item winner ack. eos_kind is ALWAYS BPO_AT_LEAST_ONCE on this
        # per-item outcome: the spine builds the outcome from this codec method,
        # which has no access to the IDEMPOTENT-SINGLETON discriminant (COMMITTED /
        # DUPLICATE / FENCED / ...). By design the EOS discriminant is NOT carried
        # on the per-item outcome — it rides the SHARED _EosResultCell side channel,
        # which the EOS appender stamps and the driver reads via
        # last_eos_kind() after the flush (the terminal Kafka handler maps THAT to
        # the wire code). So the per-item eos_kind here is a no-op placeholder for
        # the EOS path (the singleton's one outcome's offsets still come from the
        # cell) and the genuine discriminant for the ESCALATING path.
        return BrokerProduceOutcome(
            base_offset=append.base_offset,
            last_offset=append.last_offset,
            chunk_seq=append.chunk_seq,
            intra_batch_seq=intra_batch_seq,
            eos_kind=BPO_AT_LEAST_ONCE,
        )


# =============================================================================
# §6 — BrokerBatchAppender[Storage] — SEAM 5 (BatchAppender).
# =============================================================================
# The PARKABLE, MODE-CORRECT durable write. ESCALATING drives the parkable
# exact-slot create-CAS (AsyncManifestAppendOp); the spine's LIVE 412-loop
# re-reads authoritative head + re-encodes + re-appends at the new auth_head+1
# (escalation past the contended slot). IDEMPOTENT-SINGLETON drives the
# exactly-once sentinel (append_idempotent keyed by (producer_id, first_seq));
# valid ONLY N==1 (the singleton invariant — enforced here).
#
# THE EOS APPEND IS NOT YET POLL-SHAPED. CasManifestStore.append_idempotent is a
# BLOCKING verb (the sentinel claim + chunk append run the store's own reactor to
# completion). The ESCALATING parkable path uses AsyncManifestAppendOp (genuinely
# parkable). The EOS path completes in one synchronous burst at append_start
# (READY immediately) — the singleton acks=all path is latency-bounded by the
# sentinel claim + chunk append, and a poll-shaped append_idempotent is the
# explicit follow-on (the at-least-once ESCALATING path is the dominant
# produce hot path and IS parkable). This is faithful: the BatchAppender ABI is
# start/poll/take, and the EOS conformer satisfies it completing-in-burst (the
# same way an immediate-completion fast path returns READY).


struct BrokerBatchAppender[
    Storage: ConditionalWriteStore & AsyncCasStore
](BatchAppender, Movable, Deinitable):
    """SEAM 5 for the broker: the PARKABLE, MODE-CORRECT durable write.

    ESCALATING (at-least-once): the parkable exact-slot create-CAS via
    AsyncManifestAppendOp over the partition WAL — the spine's LIVE 412-loop
    escalates past a contended slot. IDEMPOTENT-SINGLETON (EOS): the exactly-once
    sentinel via append_idempotent (N==1 only — the singleton invariant)."""

    var _wal: CasManifestStore[Self.Storage]
    var _mode: UInt8
    # The parkable exact-slot op (ESCALATING). A fresh op per attempt (a LOST_SLOT
    # re-encode re-drives append_start).
    var _op: AsyncManifestAppendOp[Self.Storage]
    var _inflight: Bool
    # The EOS dedup key + fence inputs (IDEMPOTENT-SINGLETON), carried from the
    # factory (one producer batch per spine — the singleton invariant).
    var _producer_id: Int64
    var _producer_epoch: Int64
    var _first_seq: Int64
    var _last_seq: Int64
    var _registered_epoch: Int64
    var _writer_lease_epoch: Int64
    var _current_lease_epoch: Int64
    # The EOS outcome, harvested at append_take (the singleton burst completes at
    # append_start). None until the EOS append has run.
    var _eos_outcome: Optional[AppendOutcome]
    # The SHARED EOS-discriminant side channel (written here, read by the driver
    # after the flush — see §0.1). The appender (owned by the spine, consumed on
    # done) + the driver share the SAME cell, so the discriminant survives the
    # spine teardown.
    var _eos_cell: ArcPointer[_EosResultCell]

    def __init__(
        out self,
        var wal: CasManifestStore[Self.Storage],
        mode: UInt8,
        eos_cell: ArcPointer[_EosResultCell],
        producer_id: Int64 = Int64(-1),
        producer_epoch: Int64 = Int64(0),
        first_seq: Int64 = Int64(-1),
        last_seq: Int64 = Int64(-1),
        registered_epoch: Int64 = Int64(0),
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ):
        self._wal = wal^
        self._mode = mode
        self._op = AsyncManifestAppendOp[Self.Storage]()
        self._inflight = False
        self._producer_id = producer_id
        self._producer_epoch = producer_epoch
        self._first_seq = first_seq
        self._last_seq = last_seq
        self._registered_epoch = registered_epoch
        self._writer_lease_epoch = writer_lease_epoch
        self._current_lease_epoch = current_lease_epoch
        self._eos_outcome = Optional[AppendOutcome]()
        self._eos_cell = eos_cell

    def append_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        var body: List[UInt8],
        record_count: Int64,
        slot: Int64,
        lease_epoch: Int64,
        current_lease_epoch: Int64,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        if self._mode == BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON:
            return self._eos_append_start(body^, record_count)
        # ESCALATING — the parkable exact-slot create-CAS. Derive the AUTHORITATIVE
        # slot from the WAL (the spine's hint is advisory under the HEAD-elision);
        # a 412 -> the spine's LIVE 412-loop re-reads authoritative head + re-encodes
        # + re-appends (escalation past the contended slot).
        var head = self._wal.read_head_authoritative()
        var candidate = head.chunk_seq + Int64(1)
        var base = head.next_offset
        self._inflight = True
        return self._op.start[S](
            self._wal, candidate, base, body^, record_count, reactor
        )

    def append_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        if self._mode == BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON:
            # The EOS singleton append completes in one burst at append_start; poll
            # is never the in-flight path. Return READY defensively.
            return CasOpProgress.ready()
        return self._op.poll[S](self._wal, reactor)

    def append_take(mut self) raises -> AppendOutcome:
        if self._mode == BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON:
            # Harvest the EOS outcome computed at append_start.
            return self._eos_outcome.take()
        var r = self._op.take(self._wal)
        # A fresh op for the next attempt (a LOST_SLOT re-encode re-drives start).
        self._op = AsyncManifestAppendOp[Self.Storage]()
        self._inflight = False
        if r:
            return AppendOutcome.won(r.take())
        # take->None is the defense-in-depth 412 path (a deferred 412).
        return AppendOutcome.lost_slot()

    def classify_append_error(self, msg: String) -> UInt8:
        # The reaped-slot refusals (manifest_slot_guard.mojo) come FIRST, and
        # `log_start_unread` before `slot_reaped`: its cause may spell anything
        # (`412`, `slot_reaped`), and an outcome-unknown win must never be
        # re-appended. Both match only their leading sentinel.
        #   * `slot_reaped`: the win was below `_LOG_START` and NOT committed
        #     (the EOS sentinel was released). A lost slot in both modes: the
        #     spine's 412-loop re-reads the authoritative head (LIST, log-start
        #     aware) and re-appends at the live tail.
        #   * `log_start_unread`: the outcome is unknown (the chunk may be
        #     live), so a re-append could duplicate it. Terminal for the flush.
        if is_log_start_unread(msg):
            return APPEND_ERR
        if is_slot_reaped(msg):
            return APPEND_LOST_SLOT
        # ESCALATING: a 412/precondition is a real lost slot -> the spine's LIVE
        # 412-loop (which IS the escalation past the contended slot). The
        # IDEMPOTENT-SINGLETON path never surfaces a bare 412 (the sentinel's own
        # outcome carries the result), so any take-path raise there is terminal.
        if self._mode == BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON:
            return APPEND_ERR
        if (
            msg.find("412") >= 0
            or msg.find("precondition") >= 0
            or msg.find("If-None-Match") >= 0
            or msg.find("If-Match") >= 0
        ):
            return APPEND_LOST_SLOT
        return APPEND_ERR

    def _eos_append_start(
        mut self, var body: List[UInt8], record_count: Int64
    ) raises -> CasOpProgress:
        # THE SINGLETON INVARIANT (a HARD seam contract): the EOS sentinel
        # keys exactly ONE (producer_id, first_seq) per append, so the body MUST
        # carry exactly one producer batch. The factory enforces N==1 by only ever
        # building an EOS spine for a single buffered producer batch (the acks=all
        # path), but we GUARD here too (defense-in-depth): a record_count that does
        # not match the singleton batch's record count, or a missing producer
        # identity, is a contract violation.
        if self._producer_id < Int64(0) or self._first_seq < Int64(0):
            raise Error(
                "BrokerBatchAppender (IDEMPOTENT-SINGLETON): a producer identity"
                " (producer_id, first_seq) is REQUIRED for the EOS append (the"
                " singleton invariant)"
            )
        # Drive the exactly-once sentinel (append_idempotent). It reads HEAD
        # authoritatively inside _append_inner + assigns the offset range. Maps the
        # IDEMPOTENT_* outcome to the AppendOutcome + the EOS discriminant.
        var ir: IdempotentAppendResult
        try:
            ir = self._wal.append_idempotent(
                body^,
                record_count,
                self._producer_id,
                self._producer_epoch,
                self._first_seq,
                self._last_seq,
                self._registered_epoch,
                self._writer_lease_epoch,
                self._current_lease_epoch,
            )
        except e:
            # A win in a reaped slot (#486): not committed and the sentinel was
            # released. Surface it on the ERR channel so the spine classifies
            # it as a lost slot and re-drives the append at the live tail. An
            # outcome-unknown `log_start_unread` is excluded first and raised.
            # (append_idempotent rarely surfaces it: its phantom scan resolves
            # a live win as COMMITTED.)
            var msg = String(e)
            if not is_log_start_unread(msg) and is_slot_reaped(msg):
                return CasOpProgress.error(msg)
            raise e^
        if ir.outcome == IDEMPOTENT_COMMITTED:
            self._stamp_eos_cell(
                BPO_EOS_COMMITTED, ir.base_offset, ir.last_offset, ir.chunk_seq
            )
            self._eos_outcome = Optional[AppendOutcome](
                AppendOutcome.won(
                    AppendResult(
                        ir.chunk_seq,
                        ir.base_offset,
                        ir.last_offset,
                        String(""),
                        ir.attempts,
                    )
                )
            )
            return CasOpProgress.ready()
        if ir.outcome == IDEMPOTENT_DUPLICATE:
            # Already committed (idempotent ack) — return the recorded offset, NO
            # re-write. WON (the producer is acked with the recorded location).
            self._stamp_eos_cell(
                BPO_EOS_DUPLICATE, ir.base_offset, ir.last_offset, ir.chunk_seq
            )
            self._eos_outcome = Optional[AppendOutcome](
                AppendOutcome.won(
                    AppendResult(
                        ir.chunk_seq,
                        ir.base_offset,
                        ir.last_offset,
                        String(""),
                        0,
                    )
                )
            )
            return CasOpProgress.ready()
        if ir.outcome == IDEMPOTENT_FENCED:
            self._stamp_eos_cell(
                BPO_EOS_FENCED, Int64(-1), Int64(-1), Int64(-1)
            )
            self._eos_outcome = Optional[AppendOutcome](
                AppendOutcome.error(
                    String("EOS produce FENCED (stale producer-epoch zombie)")
                )
            )
            return CasOpProgress.ready()
        if ir.outcome == IDEMPOTENT_LEASE_FENCED:
            self._stamp_eos_cell(
                BPO_EOS_LEASE_FENCED, Int64(-1), Int64(-1), Int64(-1)
            )
            self._eos_outcome = Optional[AppendOutcome](
                AppendOutcome.error(
                    String(
                        "EOS produce LEASE_FENCED (stale partition-ownership"
                        " writer)"
                    )
                )
            )
            return CasOpProgress.ready()
        # IDEMPOTENT_RETRYABLE — in-flight winner / genuine no-commit.
        self._stamp_eos_cell(
            BPO_EOS_RETRYABLE, Int64(-1), Int64(-1), Int64(-1)
        )
        self._eos_outcome = Optional[AppendOutcome](
            AppendOutcome.error(
                String("EOS produce RETRYABLE (in-flight winner / no commit)")
            )
        )
        return CasOpProgress.ready()

    @always_inline
    def _stamp_eos_cell(
        mut self,
        kind: UInt8,
        base_offset: Int64,
        last_offset: Int64,
        chunk_seq: Int64,
    ):
        """Write the EOS discriminant + committed offsets into the SHARED cell the
        driver reads after the flush (the EOS side channel — §0.1)."""
        self._eos_cell[].eos_kind = kind
        self._eos_cell[].base_offset = base_offset
        self._eos_cell[].last_offset = last_offset
        self._eos_cell[].chunk_seq = chunk_seq
        self._eos_cell[].engaged = True


# =============================================================================
# §7 — BrokerProduceSpineFactory[Storage] — the SpineFactory.
# =============================================================================
# Mints a fresh _CoalesceSpine per flush over fresh store clones + the broker
# conformers, configured for the produce's mode (ESCALATING vs
# IDEMPOTENT-SINGLETON) + the producer / txn / lease state. The factory holds the
# SHARED store (CloneableConditionalWriteStore) + the cluster/topic/partition +
# the broker_id + the per-flush producer config, and builds a fresh
# CasManifestStore (over a fresh store clone sharing the Arc-backed core) per
# flush — so it never needs CasManifestStore.clone() (which does not exist).
#
# THE SINGLETON INVARIANT ENFORCEMENT. For the IDEMPOTENT-SINGLETON mode the
# factory carries the single producer batch's (producer_id, epoch, first_seq,
# last_seq) — set per flush. The driver (BrokerCoalescingProduce.produce_eos)
# only ever offers ONE producer batch per EOS flush (the acks=all path), so the
# coalesced body always carries exactly one batch. The appender GUARDS N==1
# defensively (a producer identity is required).


struct BrokerProduceSpineFactory[
    Store_: CloneableConditionalWriteStore & AsyncCasStore
](SpineFactory, Movable, Deinitable):
    """Mints a fresh broker produce spine per flush over fresh store clones + the
    broker conformers, configured for the produce mode + producer/txn/lease
    state.

    The struct's storage type-param is `Store_` (NOT `Storage`) so it does not
    shadow the `SpineFactory.Storage` ASSOCIATED type the struct must define —
    Mojo 1.0.0b1 rejects a generic param + an associated comptime sharing one
    name."""

    comptime Storage = Self.Store_
    comptime H = BrokerHeadReader[Self.Store_]
    comptime C = BrokerSegCodec
    comptime A = BrokerBatchAppender[Self.Store_]
    comptime Item = BrokerProduceItem

    var _store: Self.Store_
    var _cluster: String
    var _topic: String
    var _partition: Int64
    var _broker_id: String
    var _prefix: String
    var _proc_nonce: Int64
    # The GLOBALLY-UNIQUE-ACROSS-FLUSHES segment-key counter. Hoisted
    # onto this LONG-LIVED factory (one per partition, constructed once) + seeded
    # into each fresh codec in make_spine with a per-flush DISJOINT stride, so two
    # flushes sharing a flush_ts + proc_nonce can never mint a colliding segment
    # key (the silent-data-loss gap). See §0.0.
    var _seg_counter: Int64
    # The per-flush produce config (the four-variant collapse + the mode).
    var _append_mode: UInt8
    var _producer_id: Int64
    var _producer_epoch: Int64
    var _first_seq: Int64
    var _last_seq: Int64
    var _registered_epoch: Int64
    var _txn_id: String
    var _writer_lease_epoch: Int64
    var _current_lease_epoch: Int64
    # The SHARED EOS-discriminant side channel (passed to each EOS appender;
    # read by the driver after the flush — §0.1).
    var _eos_cell: ArcPointer[_EosResultCell]

    def __init__(
        out self,
        var store: Self.Store_,
        var cluster: String,
        var topic: String,
        partition: Int64,
        var broker_id: String,
        eos_cell: ArcPointer[_EosResultCell],
    ) raises:
        self._store = store^
        self._cluster = cluster^
        self._topic = topic^
        self._partition = partition
        self._broker_id = broker_id^
        self._prefix = _manifest_prefix(
            self._cluster, self._topic, self._partition
        )
        self._proc_nonce = _broker_proc_nonce()
        self._seg_counter = Int64(0)
        self._eos_cell = eos_cell
        # Default: at-least-once (the bare `flush` equivalent).
        self._append_mode = BROKER_APPEND_MODE_ESCALATING
        self._producer_id = Int64(-1)
        self._producer_epoch = Int64(0)
        self._first_seq = Int64(-1)
        self._last_seq = Int64(-1)
        self._registered_epoch = Int64(0)
        self._txn_id = String("")
        self._writer_lease_epoch = Int64(0)
        self._current_lease_epoch = Int64(0)

    def configure_at_least_once(
        mut self,
        producer_id: Int64 = Int64(-1),
        producer_epoch: Int64 = Int64(0),
        first_seq: Int64 = Int64(-1),
        last_seq: Int64 = Int64(-1),
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ):
        """Configure the next flush for the ESCALATING (at-least-once) mode. A
        producer_id of -1 is the bare `flush`; a non-negative producer_id folds
        the producer trailer (== flush_with_producer)."""
        self._append_mode = BROKER_APPEND_MODE_ESCALATING
        self._producer_id = producer_id
        self._producer_epoch = producer_epoch
        self._first_seq = first_seq
        self._last_seq = last_seq
        self._txn_id = String("")
        self._writer_lease_epoch = writer_lease_epoch
        self._current_lease_epoch = current_lease_epoch

    def configure_txn(
        mut self,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        var txn_id: String,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ):
        """Configure the next flush for the txn-open ESCALATING mode (==
        flush_with_producer_txn — the chunk is tagged MARKER_NONE + txn_id)."""
        self._append_mode = BROKER_APPEND_MODE_ESCALATING
        self._producer_id = producer_id
        self._producer_epoch = producer_epoch
        self._first_seq = first_seq
        self._last_seq = last_seq
        self._txn_id = txn_id^
        self._writer_lease_epoch = writer_lease_epoch
        self._current_lease_epoch = current_lease_epoch

    def configure_eos_singleton(
        mut self,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        registered_epoch: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ):
        """Configure the next flush for the IDEMPOTENT-SINGLETON (EOS) mode (==
        flush_with_producer_exactly_once). N==1 ONLY — the driver offers exactly
        one producer batch per EOS flush (the singleton invariant)."""
        self._append_mode = BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON
        self._producer_id = producer_id
        self._producer_epoch = producer_epoch
        self._first_seq = first_seq
        self._last_seq = last_seq
        self._registered_epoch = registered_epoch
        self._txn_id = String("")
        self._writer_lease_epoch = writer_lease_epoch
        self._current_lease_epoch = current_lease_epoch

    def make_spine(
        mut self, var items: Slab[BrokerProduceItem], reason: UInt8
    ) raises -> _CoalesceSpine[
        Self.Store_,
        BrokerHeadReader[Self.Store_],
        BrokerSegCodec,
        BrokerBatchAppender[Self.Store_],
    ]:
        # RESET the shared EOS side-channel cell at the START of every flush,
        # so last_eos_engaged() / last_eos_kind() never return STALE prior-EOS
        # state after an EOS-then-at-least-once sequence. A fresh flush starts
        # with engaged=False + the fields reset; only an IDEMPOTENT-SINGLETON
        # appender re-stamps it, so an at-least-once flush correctly leaves the
        # cell disengaged.
        self._eos_cell[] = _EosResultCell()
        var now_flush_ts = self._flush_ts_for(items)
        var reader = BrokerHeadReader[Self.Store_](self._store.clone())
        # Reserve this flush's DISJOINT segment-key counter range. Seed
        # the fresh codec with the factory's current counter, then advance the
        # factory by STRIDE so the NEXT flush starts past this flush's whole range
        # (covering every re-key this flush can mint via the spine's re-encode
        # loop). Two flushes sharing flush_ts + proc_nonce now mint keys from
        # disjoint `<uniq>` ranges -> never a colliding key (the silent-data-loss
        # gap). See §0.0.
        var seg_seed = self._seg_counter
        self._seg_counter += BROKER_FLUSH_SEG_KEY_STRIDE
        var codec = BrokerSegCodec(
            self._cluster.copy(),
            self._topic.copy(),
            self._partition,
            self._broker_id.copy(),
            self._proc_nonce,
            now_flush_ts,
            self._producer_id,
            self._producer_epoch,
            self._first_seq,
            self._last_seq,
            self._txn_id.copy(),
            self._append_mode,
            seg_seed,
        )
        var wal = CasManifestStore[Self.Store_](
            self._store.clone(), self._prefix.copy()
        )
        # The partition's chunks are reaped below `_LOG_START`: never ack a win
        # in a reaped slot (#486; the op's check is its own parked phase).
        wal.enable_reaped_slot_guard()
        var appender = BrokerBatchAppender[Self.Store_](
            wal^,
            self._append_mode,
            self._eos_cell,
            self._producer_id,
            self._producer_epoch,
            self._first_seq,
            self._last_seq,
            self._registered_epoch,
            self._writer_lease_epoch,
            self._current_lease_epoch,
        )
        return _CoalesceSpine[
            Self.Store_,
            BrokerHeadReader[Self.Store_],
            BrokerSegCodec,
            BrokerBatchAppender[Self.Store_],
        ](reader^, codec^, appender^, items^, reason)

    @always_inline
    def _flush_ts_for(self, ref items: Slab[BrokerProduceItem]) -> Int64:
        # The segment key's flush_ts. Use the OLDEST buffered
        # item's enqueue ts (the linger band's basis) when present; else 0.
        if items.len() == 0:
            return Int64(0)
        return items[0].ts_ms


# =============================================================================
# §8 — BrokerCoalescingProduce[Storage] — the per-partition produce driver.
# =============================================================================
# The CONSUMER-FACING per-partition handle: ONE CoalescingWindow over the broker
# conformers, configured with 8MiB / 250ms FlushPolicy. The four
# bespoke flush variants collapse into:
#   * produce(rb)               -> configure_at_least_once + offer (auto-flush at
#                                  the size/linger band).
#   * produce_with_producer(rb) -> configure_at_least_once(producer) + offer.
#   * produce_eos(rb)           -> configure_eos_singleton + buffer ONE + force
#                                  EXPLICIT (the acks=all singleton path, N==1).
#   * produce_txn(rb)           -> configure_txn + force EXPLICIT.
#   * flush_if_buffered()       -> force EXPLICIT/SHUTDOWN.
# The ASYNC path: each produce's spine PARKS across the create-CAS RTT on the
# per-worker reactor (the window's poll/op_id demux); other connections progress
# while one produce is parked.
#
# ONE-IN-FLIGHT-OP-PER-PARTITION. The window drives ONE flush at a time (the
# single-store-one-in-flight-op constraint — the reason coalescing is N->1). The
# kafka_server wire handler routes produce to the partition via FNV-1a
# partition routing; each partition owns its own BrokerCoalescingProduce.


struct BrokerCoalescingProduce[
    Storage: CloneableConditionalWriteStore & AsyncCasStore
](Movable, Deinitable):
    """The per-partition broker produce driver over a CoalescingWindow. Collapses
    the four bespoke BrokerCore flush variants into producer/txn/lease STATE on
    one codec + a mode-correct parkable appender — one driver, not four
    near-identical methods. Each produce PARKS across the create-CAS RTT."""

    comptime Factory = BrokerProduceSpineFactory[Self.Storage]
    comptime Window = CoalescingWindow[Self.Factory]

    var _window: Self.Window
    # A handle to reconfigure the next flush's mode/producer state. The window
    # owns the factory; we reach it through the window's reconfigure surface.
    var _cluster: String
    var _topic: String
    var _partition: Int64
    # The SHARED EOS-discriminant side channel (the driver + every EOS appender
    # share this; the driver reads it after an EOS flush — §0.1).
    var _eos_cell: ArcPointer[_EosResultCell]

    def __init__(
        out self,
        var store: Self.Storage,
        var cluster: String,
        var topic: String,
        partition: Int64,
        var broker_id: String,
    ) raises:
        var eos_cell = ArcPointer[_EosResultCell](_EosResultCell())
        var factory = BrokerProduceSpineFactory[Self.Storage](
            store^, cluster.copy(), topic.copy(), partition, broker_id^, eos_cell
        )
        # The flush policy: 8 MiB size band OR 250 ms linger band. The
        # count band is disabled (the broker triggers on bytes/time, not count).
        var policy = FlushPolicy(
            max_bytes=FLUSH_BYTES, max_ms=FLUSH_MS, max_count=0
        )
        self._window = CoalescingWindow[Self.Factory](
            RamAccumulator[BrokerProduceItem](), policy, factory^
        )
        self._cluster = cluster^
        self._topic = topic^
        self._partition = partition
        self._eos_cell = eos_cell

    @always_inline
    def last_eos_kind(self) -> UInt8:
        """The EOS discriminant (BPO_EOS_*) of the LAST IDEMPOTENT-SINGLETON flush
        (the EOS side channel — §0.1). BPO_AT_LEAST_ONCE before any EOS flush /
        after an at-least-once flush. The terminal Kafka handler maps it to the
        wire code (COMMITTED -> the offset; DUPLICATE -> idempotent ack; FENCED ->
        INVALID_PRODUCER_EPOCH; LEASE_FENCED -> NOT_LEADER_OR_FOLLOWER; RETRYABLE
        -> a retriable code)."""
        return self._eos_cell[].eos_kind

    @always_inline
    def last_eos_engaged(self) -> Bool:
        """True iff an EOS append has stamped the cell since construction."""
        return self._eos_cell[].engaged

    @always_inline
    def last_eos_base_offset(self) -> Int64:
        return self._eos_cell[].base_offset

    @always_inline
    def last_eos_last_offset(self) -> Int64:
        return self._eos_cell[].last_offset

    @always_inline
    def partition(self) -> Int64:
        return self._partition

    @always_inline
    def is_inflight(self) -> Bool:
        return self._window.is_inflight()

    @always_inline
    def pending_count(self) -> Int:
        return self._window.pending_count()

    @always_inline
    def pending_bytes(self) -> Int:
        return self._window.pending_bytes()

    @always_inline
    def parked_op_id(self) -> Int64:
        return self._window.parked_op_id()

    @always_inline
    def timer_op_id(self) -> Int64:
        return self._window.timer_op_id()

    @always_inline
    def has_error(self) -> Bool:
        return self._window.has_error()

    @always_inline
    def err_text(self) -> String:
        return self._window.err_text()

    @always_inline
    def last_flush_reason(self) -> UInt8:
        return self._window.last_flush_reason()

    def reconfigure_at_least_once(
        mut self,
        producer_id: Int64 = Int64(-1),
        producer_epoch: Int64 = Int64(0),
        first_seq: Int64 = Int64(-1),
        last_seq: Int64 = Int64(-1),
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ):
        """Configure the NEXT flush for the at-least-once (ESCALATING) mode."""
        self._window.factory_mut().configure_at_least_once(
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
            writer_lease_epoch,
            current_lease_epoch,
        )

    def reconfigure_eos_singleton(
        mut self,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        registered_epoch: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ):
        """Configure the NEXT flush for the IDEMPOTENT-SINGLETON (EOS) mode."""
        self._window.factory_mut().configure_eos_singleton(
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
            registered_epoch,
            writer_lease_epoch,
            current_lease_epoch,
        )

    def reconfigure_txn(
        mut self,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        var txn_id: String,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ):
        """Configure the NEXT flush for the txn-open ESCALATING mode."""
        self._window.factory_mut().configure_txn(
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
            txn_id^,
            writer_lease_epoch,
            current_lease_epoch,
        )

    def produce[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, var rb: RecordBatch, now_ms: Int64, mut reactor: Reactor[S]
    ) raises -> Int64:
        """Buffer `rb` (at-least-once) and evaluate flush trigger
        (8 MiB / 250 ms). Returns the biased op_id the started flush parked on
        (0 == buffered, not flushed, OR finished in one burst). The auto-flush
        PARKS across the create-CAS RTT. Mirrors BrokerCore.produce's
        buffer-then-trigger shape, but parkable + coalesced."""
        var it = BrokerProduceItem(rb^, now_ms)
        var est = len(it.frame_bytes)  # EXACT encoded frame size (the size band).
        return self._window.offer[S](it^, est, now_ms, now_ms, reactor)

    def buffer[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, var rb: RecordBatch, now_ms: Int64, mut reactor: Reactor[S]
    ) raises:
        """Buffer `rb` WITHOUT evaluating the flush trigger (== BrokerCore.
        buffer_batch — the producer-aware path that decides the flush itself)."""
        var it = BrokerProduceItem(rb^, now_ms)
        var est = len(it.frame_bytes)  # EXACT encoded frame size (the size band).
        self._window.buffer(it^, est, now_ms)

    def force[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, now_ms: Int64, mut reactor: Reactor[S]
    ) raises -> Int64:
        """Force an EXPLICIT flush of any buffered records (== flush_if_buffered /
        the txn / producer-aware explicit commit). No-op (returns 0) if the buffer
        is empty or a flush is in flight. Parks across the create-CAS RTT."""
        return self._window.force[S](FLUSH_REASON_EXPLICIT, reactor)

    def force_shutdown[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Force a SHUTDOWN drain of any buffered records (teardown)."""
        return self._window.force[S](FLUSH_REASON_SHUTDOWN, reactor)

    def on_deadline[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, fired_op_id: Int64, now_ms: Int64, mut reactor: Reactor[S]
    ) raises -> Int64:
        """The linger-timer SELF-FIRE (the 250 ms band). Routes through the
        window's on_deadline demux (the identical biased-op_id demux a store read
        completion uses)."""
        return self._window.on_deadline[S](fired_op_id, now_ms, reactor)

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Resume the in-flight produce flush after its parked op_id completed.
        Advances one non-blocking step; returns the next biased op_id to park on,
        or 0 when the flush finished (the caller then calls take_outcomes)."""
        return self._window.poll[S](reactor)

    def take_outcomes(
        mut self,
    ) -> List[Tuple[Int, BrokerProduceOutcome]]:
        """MOVE the committed (orig_idx, BrokerProduceOutcome) pairs of the LAST
        finished flush out. For a coalesced produce all winners share one
        chunk_seq; for the EOS singleton path there is exactly one outcome carrying
        the EOS discriminant."""
        return self._window.take_outcomes()

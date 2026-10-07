# =============================================================================
# komira_objectstore/coalescing_window.mojo
# The unified batching substrate
#   The GENERAL coalescing-window primitive: buffer N items, flush as ONE
#   durable CAS-manifest append.
# =============================================================================
#
# This file is the GENERAL primitive — the spine + 4 seams + a front-end —
# with no consumer-specific code (it is tested standalone via an in-mem rig).
#
# ── THE PROBLEM IT SOLVES ────────────────────────────────────────────────────
# Five+ subsystems independently re-implement the same shape: accumulate small
# writes in RAM, then periodically fold them into ONE object-store round-trip
# (the broker's producer flush; the table store's group-commit; the comms Tier-2 index
# delta-log; mail flags; calendar sync). Each open-codes a buffer + a
# size/linger/count flush policy + a read-HEAD -> encode -> append -> 412-retry
# loop. This primitive factors that shape ONCE, behind a typed trait surface, so
# a consumer plugs in only its DOMAIN encode/decode (the 4 seams) and inherits
# the durable, parkable, heap-reuse-safe commit loop unchanged.
#
# ── THE 5 SEAMS (the consumer's pluggable surface) ───────────────────────────
#   1. FlushPolicy   — PURE decision (size / linger / count; clock injected).
#                      No store access (the same shape as a pure partition trigger).
#   2. AuthHeadReader — read + decode the authoritative manifest HEAD the encode
#                      conditions on (the read half of the commit loop) + the
#                      PARKABLE STAGE-BLOB (the optional big content-addressed
#                      object PUT, also driven on the reactor).
#   3. BatchCodec    — estimate_bytes / encode (arbitration folded IN) /
#                      winner_outcome (the consumer's DOMAIN encoding).
#   4. BatchAccumulator — push / pending_* / drain (the RAM buffer; stock
#                      RamAccumulator over a Slab[Item]).
#   5. BatchAppender — the PARKABLE, MODE-CORRECT durable write (the write half
#                      of the commit loop). The consumer's conformer chooses the
#                      MODE: EXACT-SLOT create-CAS at auth_head+1 (table-store OCC —
#                      a 412 surfaces a real lost-slot the spine's 412-loop
#                      handles), ESCALATING append (broker at-least-once —
#                      escalation past auth_head+1 is OK), or IDEMPOTENT append
#                      (broker EOS — append_idempotent keyed by producer_id/seq).
#                      The spine drives append_start/poll/take and NEVER calls a
#                      blocking, internally-retrying, escalating store verb.
#
# ── WHY THE PARKABLE APPENDER ────────────────────────────────────────────────
# Wiring the write to `MetadataStore.append` (= CasManifestStore's
# `_append_inner`), a BLOCKING, internally-412-retrying, ESCALATING-past-
# auth_head+1 verb, is WRONG on four counts:
#   (1) it STRUCTURALLY BLOCKS table-store group-commit, which needs an EXACT-slot
#       create-CAS at auth_head+1 (an escalated slot is a silent lost-update);
#   (2) it CANNOT express broker-EOS append_idempotent (not on MetadataStore);
#   (3) it makes the spine's OUTER 412-loop DEAD CODE (the inner verb retries
#       internally, so a 412 never surfaces to the spine);
#   (4) it NEVER PARKS the write (the serve thread blocks across the write RTT —
#       a burst-stall, the very thing AsyncReassignOp / AsyncManifestAppendOp
#       were built to avoid).
# The BatchAppender seam fixes all four: the consumer's conformer drives the
# MODE-correct parkable write (exact-slot AsyncManifestAppendOp for the table store,
# an escalating/idempotent op for the broker), so the write PARKS, the 412-loop
# is LIVE (the exact-slot create-CAS surfaces a real 412 the spine re-reads +
# re-encodes against), and each consumer gets its correct durability semantics.
#
# ── THE SPINE (the parkable commit op — mirrors AsyncReassignOp) ─────────────
# `_CoalesceSpine` is a poll-shaped state machine (NOT a SuspendableHandler — it
# stays in komira_objectstore with ZERO HTTP dependency; the consumer's serve
# loop drives it via CoalescingWindow.poll, exactly as the broker coordinator
# drives AsyncReassignOp). Phases (ALL I/O phases PARK):
#   READ       — read_head_start/poll the authoritative HEAD (parks on its biased
#                op_id), then decode_head.
#   ENCODE     — (synchronous, CPU-only) run BatchCodec.encode over the buffered
#                items + the decoded auth HEAD. Arbitration is folded INTO encode.
#   STAGE_BLOB — (optional, PARKS) stage a big content-addressed blob FIRST via
#                the reader's parkable conditional_put-shaped op (If-None-Match;
#                bounded re-key; idempotent on identical bytes), so the manifest
#                append references an already-durable object. Skipped when the
#                encode emits no staged blob (the dominant identity case).
#   APPEND     — (PARKS) the MODE-CORRECT durable write via BatchAppender.
#                For the EXACT-SLOT mode a 412 (a competitor landed in our slot)
#                loops back to READ + re-encode over the RETAINED items, bounded
#                by MAX_COMMIT_ATTEMPTS = 256 (the LIVE 412-loop). For the
#                escalating/idempotent modes the seam's own semantics apply (no
#                exact-slot OCC; the seam converges internally OR signals a
#                terminal error).
#   DONE/ERR   — outcomes available via take_outcomes.
# The spine NEVER sees a key / offset / OCC-window / 40001 / connection — only
# opaque Item / Head / Outcome flow across its boundary.
#
# ── THE heap-reuse CONTRACT (these are GATES, not guidelines) ────────────────
#   * The suspended spine lives behind a SINGLE OwnedPointer[SM] frame
#     (CoalescingWindow._frame) — NEVER a Movable struct in a byte-slab.
#   * The batch buffer is a plain Slab[Item] — Item stored by typed
#     init_pointee_move (a concrete origin) and drained by value MOVE; NEVER an
#     element-heap-field laundered through a wildcard origin.
#   * The in-flight store op stays INSIDE the conformer (the AsyncCasStore /
#     BatchAppender surface is typed values only: CasReadResult / AppendOutcome /
#     CasOpProgress / op_id:Int64 — ZERO UnsafePointer / wildcard origin crosses
#     ANY module boundary). This holds for the REWORK's new carried-across-park
#     state too: the in-flight STAGE-BLOB op and the in-flight APPEND op both
#     live INSIDE their conformer (the reader's / the appender's own
#     concrete-origin store handle) across the park — only the typed
#     CasOpProgress / AppendOutcome cross the seam. AT MOST ONE op (read OR
#     stage-blob OR append) is in flight at a time (the spine is a single-flush
#     state machine), so no two in-flight transport buffers ever coexist.
#   * The store is held by-value via clone() (the Arc-shared core; the in-flight
#     poll-shaped op's heap buffers live INSIDE the clone).
#   * The buffered items are RETAINED in the spine across the parks AND across a
#     412 re-encode (encode borrows them by `ref`; they are dropped only on a WON
#     append). All hand-offs (drain -> spine; spine -> outcomes) are owned MOVES;
#     an accidental Item COPY would double-free its inner body on resume, so Item
#     is Movable-not-accidentally-Copyable and every transfer uses `^`. Partial
#     moves go via Optional.take() / OwnedPointer.into_inner() / Slab.pop() — NEVER
#     take_pointee.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# ZERO UnsafePointer in any signature; ZERO wildcard origin; ZERO
# unsafe_from_address. The reactor is threaded into every poll method per-call
# (never a struct field); the op_id is a plain biased Int64 from the store's poll
# ops / reactor.register_timer (>= 1<<40). Mojo 1.0.0b1.
# =============================================================================

from std.memory import OwnedPointer

from komira_collections.slab import Slab

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor

from komira_objectstore.cas_manifest import AppendResult
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    CasReadResult,
    CloneableConditionalWriteStore,
)


# The commit-loop convergence bound — mirrors AsyncReassignOp's
# _ASYNC_CAS_RETRY_LIMIT and CasManifestStore's internal create-CAS bound. A
# batch that loses the append CAS this many times in a row RAISES (livelock-free).
comptime MAX_COMMIT_ATTEMPTS: Int = 256


# =============================================================================
# SEAM 1: FlushPolicy — the PURE flush decision (clock injected).
# =============================================================================
# The pure-trigger precedent: PURE DECISION LOGIC, no store access. It
# takes the buffer's accumulated state (count / bytes / oldest-item timestamp) +
# the injected clock (now_ms) and returns a verdict. Trivially unit-testable
# offline (every branch) with no I/O and no clock dependency.

# FlushVerdict.reason discriminants — WHY a flush fired (observability + the
# singleton fast-path predicate). EXPLICIT / SHUTDOWN are caller-asserted via
# force(reason); they are NEVER computed by evaluate.
comptime FLUSH_REASON_NONE: UInt8 = 0  # below every threshold; do not flush
comptime FLUSH_REASON_SIZE: UInt8 = 1  # pending_bytes >= max_bytes
comptime FLUSH_REASON_LINGER: UInt8 = 2  # now_ms - oldest_ts_ms >= max_ms
comptime FLUSH_REASON_COUNT: UInt8 = 3  # pending_count >= max_count
comptime FLUSH_REASON_EXPLICIT: UInt8 = 4  # caller-forced (e.g. txn commit)
comptime FLUSH_REASON_SHUTDOWN: UInt8 = 5  # caller-forced drain at teardown


@fieldwise_init
struct FlushPolicy(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """The coalescing-window flush thresholds. POD.

    Field layout:
      var max_bytes: Int  — flush when pending_bytes reaches this (size band).
                            `0` disables the size trigger.
      var max_ms: Int64   — flush when the OLDEST buffered item has lingered
                            this many ms (the linger / latency band; the timer
                            self-fire deadline arms at max_ms relative).
                            `0` disables the linger trigger.
      var max_count: Int  — flush when pending_count reaches this (count band).
                            `0` disables the count trigger.
    """

    var max_bytes: Int
    var max_ms: Int64
    var max_count: Int

    @staticmethod
    def size_only(max_bytes: Int) -> FlushPolicy:
        return FlushPolicy(max_bytes=max_bytes, max_ms=Int64(0), max_count=0)

    @staticmethod
    def count_only(max_count: Int) -> FlushPolicy:
        return FlushPolicy(max_bytes=0, max_ms=Int64(0), max_count=max_count)

    @staticmethod
    def linger_only(max_ms: Int64) -> FlushPolicy:
        return FlushPolicy(max_bytes=0, max_ms=max_ms, max_count=0)


@fieldwise_init
struct FlushVerdict(Copyable, Movable, Deinitable):
    """The decision a FlushPolicy evaluation returns. POD.

    Field layout:
      var should_flush: Bool — True iff a flush should fire now.
      var reason: UInt8      — one of FLUSH_REASON_* (NONE when not flushing).
    """

    var should_flush: Bool
    var reason: UInt8

    @staticmethod
    def no() -> FlushVerdict:
        return FlushVerdict(should_flush=False, reason=FLUSH_REASON_NONE)

    @staticmethod
    def yes(reason: UInt8) -> FlushVerdict:
        return FlushVerdict(should_flush=True, reason=reason)

    @always_inline
    def flushes(self) -> Bool:
        return self.should_flush


def evaluate(
    policy: FlushPolicy,
    count: Int,
    bytes: Int,
    oldest_ts_ms: Int64,
    now_ms: Int64,
) -> FlushVerdict:
    """The PURE flush decision. Empty buffer -> NONE. Otherwise the SIZE,
    LINGER, and COUNT bands are checked in that order; the FIRST to fire wins
    (its reason is reported). `now_ms` is the injected clock (no time call here
    — the caller supplies it, so the decision is deterministic in tests).

    EXPLICIT / SHUTDOWN are NOT computed here — a caller asserts those via
    `force(reason)` (a commit, a teardown drain). evaluate only models the
    automatic size/linger/count bands.
    """
    if count <= 0:
        return FlushVerdict.no()
    # SIZE — pending bytes crossed the size band.
    if policy.max_bytes > 0 and bytes >= policy.max_bytes:
        return FlushVerdict.yes(FLUSH_REASON_SIZE)
    # LINGER — the oldest buffered item has aged past the latency band.
    if policy.max_ms > Int64(0) and (now_ms - oldest_ts_ms) >= policy.max_ms:
        return FlushVerdict.yes(FLUSH_REASON_LINGER)
    # COUNT — the buffered item count crossed the count band.
    if policy.max_count > 0 and count >= policy.max_count:
        return FlushVerdict.yes(FLUSH_REASON_COUNT)
    return FlushVerdict.no()


# =============================================================================
# SEAM 2: AuthHeadReader — read + decode the authoritative manifest HEAD.
# =============================================================================
# The READ half of the commit loop. The spine drives `read_head_start` (parks on
# the returned biased op_id), then on completion calls `decode_head` over the
# typed CasReadResult to produce the consumer's `Head` value. The decoded Head
# is what BatchCodec.encode conditions on (the OCC snapshot / the offset base /
# the index high-water — whatever the consumer needs, opaque to the spine).
#
# THE READER OWNS THE STORE-CLONE IT READS THROUGH. The reader holds its own
# AsyncCasStore handle (a clone of the window's store); `read_head_start` /
# `read_head_poll` drive the parkable read ON THAT HANDLE, and `take_read`
# harvests the typed CasReadResult. So the in-flight read op stays INSIDE the
# reader conformer (the heap-reuse contract); the spine sees only CasOpProgress (park)
# and the decoded Head.
#
# THE REAL-S3 LIST-DELIMITER TRAP (feedback_real_s3_list_delimiter_trap): any
# conformer whose decode falls back to a LIST replay to reconstruct the HEAD
# MUST union common_prefixes AND objects — a fold over only `listed.objects`
# silently returns EMPTY on real S3/GCS while passing on the in-mem store. This
# is documented on the trait so every conformer honors it.


# AuthHeadReader.classify_read_error discriminants.
comptime READ_ERR_TORN: UInt8 = 0  # a torn / transient read; retry the read
comptime READ_ERR_CONFLICT: UInt8 = 1  # a 412-shaped lost-CAS; re-read+re-encode
comptime READ_ERR_FATAL: UInt8 = 2  # terminal (auth / transport); raise


# AuthHeadReader.classify_stage_blob_error discriminants. A staged-blob
# create-PUT (If-None-Match) that 412s means an object ALREADY exists at the
# minted key. For a CONTENT-ADDRESSED key whose bytes are deterministic across
# retries, that 412 is an idempotent WIN (identical bytes already durable). But a
# COLLISION (a DIFFERENT object already at the key — a stale prior flush's bytes
# under a colliding key-mint) MUST NOT be treated as a win: the manifest body
# would reference foreign bytes and this flush's records would be SILENTLY LOST
# (the gap BrokerCore closes via `_stage_segment`'s re-key). So the reader
# classifies a stage-blob 412 and the spine re-keys (re-encode -> a fresh,
# disjoint key + a rebuilt body) instead of referencing the foreign object.
comptime STAGE_BLOB_ERR_FATAL: UInt8 = 0  # terminal (transport / auth); raise
comptime STAGE_BLOB_ERR_REKEY: UInt8 = 1  # a colliding-key 412; re-encode w/ a
#                                          # fresh key (the spine's re-encode loop)


trait AuthHeadReader(Movable, Deinitable):
    """SEAM 2: the parkable READ of the authoritative manifest HEAD the encode
    conditions on. The conformer owns the read mechanics (its own AsyncCasStore
    clone, a LIST replay); the spine sees only the typed `read_head_start` ->
    CasOpProgress (park), `read_head_poll` -> CasOpProgress, and `take_read` ->
    CasReadResult.

    DECODING lives on the BatchCodec (SEAM 3), NOT here — `BatchCodec.decode_head`
    turns the raw CasReadResult into the codec's `Head` value. This keeps the
    Head type owned by ONE seam (the codec), so the spine never has to equate
    `H.Head` with `C.Head` (Mojo 1.0.0b1 does not support cross-trait
    associated-type equality constraints). The reader is Head-agnostic.

    Pointer discipline: ZERO UnsafePointer / wildcard origin in any signature.
    The reactor is threaded per-call; the in-flight read op stays INSIDE the
    conformer (only CasReadResult / CasOpProgress cross the boundary)."""

    def read_head_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        """Kick off the authoritative-HEAD read on the reader's own store clone.
        READY (immediate) / PENDING(op_id) (park) / ERR."""
        ...

    def read_head_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        """Advance the in-flight HEAD read one non-blocking step."""
        ...

    def take_read(mut self) raises -> CasReadResult:
        """Move the completed READ result out (caller checks READY)."""
        ...

    def classify_read_error(self, msg: String) -> UInt8:
        """Classify a read error: READ_ERR_TORN (retry) / READ_ERR_CONFLICT
        (a 412-shaped lost CAS) / READ_ERR_FATAL (terminal)."""
        ...

    # ---- the PARKABLE stage-blob (the broker stages <=8MiB segment blobs) ----
    # The broker stages a content-addressed segment blob BEFORE the manifest
    # append references it. A synchronous conditional_put would BLOCK the serve
    # thread across the (up to 8 MiB) PUT RTT — the burst-stall the whole rework
    # removes. So the stage-blob is a POLL-SHAPED phase the spine drives on the
    # reactor (start/poll/take), exactly like the read + the append. The blob is
    # content-addressed (the key is a hash of `bytes`), so a 412 on a create-if-
    # absent PUT means identical bytes are ALREADY durable — an idempotent WIN,
    # handled INSIDE the conformer (it bounds a re-key + treats the 412 as
    # success). A conformer that does not stage blobs (the dominant identity
    # case) is NEVER driven (the encode emits no staged_blob, so the spine skips
    # the phase) — its stub may return READY immediately.

    def stage_blob_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, key: String, var bytes: List[UInt8], mut reactor: Reactor[S]
    ) raises -> CasOpProgress:
        """Kick off the parkable content-addressed blob PUT (If-None-Match
        create) on the reader's OWN store clone. READY (immediate) /
        PENDING(op_id) (park) / ERR. The in-flight PUT op lives INSIDE the
        conformer across the park (the heap-reuse contract). Confining the staging
        store-handle inside the reader keeps the spine at 5 generic params (no
        separate blob-stager seam)."""
        ...

    def stage_blob_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        """Advance the in-flight blob PUT one non-blocking step. A 412 (identical
        bytes already durable, content-addressed) is an idempotent WIN the
        conformer reports as READY, NOT an ERR."""
        ...

    def stage_blob_take(mut self) raises -> None:
        """Finalize the completed blob PUT (caller checks READY). The committed
        object metadata is not needed by the spine (the encode already embedded
        the content-addressed key into the body)."""
        ...

    def classify_stage_blob_error(self, msg: String) -> UInt8:
        """Classify a stage-blob create-PUT error: STAGE_BLOB_ERR_REKEY (a
        colliding-key 412 — the spine re-encodes with a fresh, disjoint key so
        the manifest body never references a FOREIGN object) / STAGE_BLOB_ERR_FATAL
        (terminal transport / auth — raise). DEFAULT FATAL: a conformer that does
        not stage blobs (the dominant identity case) is never driven through the
        stage-blob phase, and the test conformers stage CONTENT-ADDRESSED blobs
        whose 412 they map to READY INSIDE start/poll (an idempotent win) — so the
        spine never reaches this classifier for them. They inherit FATAL. The
        broker reader OVERRIDES this to re-key a colliding 412."""
        return STAGE_BLOB_ERR_FATAL


# =============================================================================
# SEAM 3: BatchCodec — the consumer's DOMAIN encode (arbitration folded in).
# =============================================================================
# The CPU-only ENCODE phase. `encode` BORROWS the buffered items by `ref` (it
# serializes their bytes into the body — it does NOT consume them, so a 412
# re-encode re-runs over the SAME retained items) + the decoded auth HEAD, and
# produces an `EncodedBatch`: the opaque manifest body to append, the
# record_count, an optional staged blob to PUT first, the lease epochs to fence
# on, and the per-item OUTCOMES split into winners + losers.
#
# ARBITRATION FOLDED INTO ENCODE: the dominant 5-of-6 consumers ship the
# IDENTITY arbitration — every item is a winner, loser_outcomes is empty, zero
# extra alloc. The 6th (table-store OCC) folds first-committer-wins arbitration into
# encode (losers get their conflict Outcome there). The spine NEVER arbitrates —
# it just routes winner_idxs / loser_outcomes back out via take_outcomes.


struct EncodedBatch[Outcome: Copyable & Movable & Deinitable](
    Movable, Deinitable
):
    """The product of BatchCodec.encode: the durable append payload + the
    arbitration result. Movable, NOT Copyable — it owns Lists (the body, the
    staged blob, the loser outcomes). Single-ownership; the spine moves it.

    Field layout:
      var body: List[UInt8]            — the opaque manifest chunk body to
                                         append (BatchAppender.append_start's
                                         `body`).
      var record_count: Int64          — the chunk's record count (the manifest
                                         offset-range width).
      var staged_blob: Optional[List[UInt8]] — an optional large blob to PUT
                                         (content-addressed, If-None-Match)
                                         BEFORE the manifest append references
                                         it. None == no staged blob.
      var staged_blob_key: String      — the content-addressed key for the
                                         staged blob (empty when no blob).
      var lease_epoch: Int64           — this writer's lease epoch (the append
                                         fence; 0 == no lease tracking).
      var current_lease_epoch: Int64   — the observed current lease epoch (the
                                         fence comparand; 0 == no fence).
      var loser_outcomes: List[(Int, Outcome)] — (orig_idx, outcome) for every
                                         arbitration LOSER (empty for the
                                         identity codec). orig_idx indexes the
                                         buffered-items order.
      var winner_idxs: List[Int]       — the orig_idx of every WINNER, in
                                         intra-batch sequence order (the spine
                                         pairs winner i with intra_batch_seq i
                                         when building the won outcome).
    """

    var body: List[UInt8]
    var record_count: Int64
    var staged_blob: Optional[List[UInt8]]
    var staged_blob_key: String
    var lease_epoch: Int64
    var current_lease_epoch: Int64
    var loser_outcomes: List[Tuple[Int, Self.Outcome]]
    var winner_idxs: List[Int]

    def __init__(
        out self,
        var body: List[UInt8],
        record_count: Int64,
        var winner_idxs: List[Int],
    ):
        """The IDENTITY-codec convenience ctor: no staged blob, no lease fence,
        no losers — every winner_idx is a winner. Zero extra alloc beyond the
        body + winner_idxs the caller already built."""
        self.body = body^
        self.record_count = record_count
        self.staged_blob = Optional[List[UInt8]]()
        self.staged_blob_key = String("")
        self.lease_epoch = Int64(0)
        self.current_lease_epoch = Int64(0)
        self.loser_outcomes = List[Tuple[Int, Self.Outcome]]()
        self.winner_idxs = winner_idxs^

    def __init__(
        out self,
        var body: List[UInt8],
        record_count: Int64,
        var staged_blob: Optional[List[UInt8]],
        var staged_blob_key: String,
        lease_epoch: Int64,
        current_lease_epoch: Int64,
        var loser_outcomes: List[Tuple[Int, Self.Outcome]],
        var winner_idxs: List[Int],
    ):
        """The FULL ctor — the OCC / lease-fenced / staged-blob path."""
        self.body = body^
        self.record_count = record_count
        self.staged_blob = staged_blob^
        self.staged_blob_key = staged_blob_key^
        self.lease_epoch = lease_epoch
        self.current_lease_epoch = current_lease_epoch
        self.loser_outcomes = loser_outcomes^
        self.winner_idxs = winner_idxs^

    @always_inline
    def has_staged_blob(self) -> Bool:
        return Bool(self.staged_blob)


trait BatchCodec(Movable, Deinitable):
    """SEAM 3: the consumer's DOMAIN decode + encode of the buffered batch into a
    durable manifest append + the arbitration outcome. The codec OWNS the Head
    type (decode_head + encode both live here), so the spine never equates a Head
    across two traits. Three associated types:
      Item    — the buffered unit (MUST equal the BatchAccumulator's Item).
      Head    — the authoritative HEAD (codec-owned; decode_head produces it).
      Outcome — the per-item result the consumer hands back to each caller.

    `decode_head` turns the raw CasReadResult (from the AuthHeadReader's parkable
    read) into the codec's `Head`. `encode` BORROWS the buffered items by `ref`
    (it does NOT consume them) so a 412 re-encode re-runs over the SAME retained
    items. Arbitration is folded into encode: winners go into the appended body +
    winner_idxs; losers get a (orig_idx, Outcome) pair (empty for the identity
    codec — every item a winner, zero extra alloc).

    Pointer discipline: ZERO UnsafePointer / wildcard origin in any signature.
    `estimate_bytes` borrows an item by `ref` (no move) for the size band."""

    comptime Item: Movable & Deinitable
    comptime Head: Movable & Deinitable
    # Outcome is Copyable: it is a small per-item RESULT value (an offset+etag, a
    # commit seq+status) handed back to each caller — never heap-owning movable
    # state. Copyable lets the spine collect outcomes in a List[Tuple[Int,
    # Outcome]] (List[T] requires T: Copyable).
    comptime Outcome: Copyable & Movable & Deinitable

    def decode_head(mut self, var rr: CasReadResult) raises -> Self.Head:
        """Decode the AuthHeadReader's completed READ into the authoritative HEAD
        value the encode conditions on. On a LIST replay path MUST union
        common_prefixes AND objects (the real-S3 LIST-delimiter trap)."""
        ...

    def head_slot(self, ref auth: Self.Head) -> Int64:
        """The EXACT-slot target the appender create-CASes at, derived from the
        decoded HEAD (= auth_head_seq + 1). The codec owns the Head type, so it
        (not the spine) projects the slot — the spine stays Head-agnostic. The
        EXACT-slot appender mode create-CASes at exactly this slot (a 412 ->
        LOST_SLOT -> the spine re-reads + re-encodes against the new head, so the
        recomputed slot is always exactly `occ_validated_head + 1`). The
        escalating / idempotent modes treat it as a hint (they may escalate /
        dedup). An identity codec over a sequence-counter head returns
        `auth.seq + 1`."""
        ...

    def estimate_bytes(self, ref it: Self.Item) -> Int:
        """The size contribution of `it` to the buffer's pending byte total
        (the size band's input). Borrows by ref — no move, no alloc."""
        ...

    def encode(
        mut self, ref items: Slab[Self.Item], var auth: Self.Head
    ) raises -> EncodedBatch[Self.Outcome]:
        """Encode the buffered `items` (borrowed by ref over the spine's retained
        Slab — RETAINED for a 412 re-encode) + the authoritative `auth` HEAD into
        an `EncodedBatch`. Folds arbitration: winners -> body + winner_idxs;
        losers -> loser_outcomes."""
        ...

    def winner_outcome(
        self, orig_idx: Int, intra_batch_seq: Int, append: AppendResult
    ) -> Self.Outcome:
        """Build the WON outcome for the winner at `orig_idx` (buffered-items
        order), assigned `intra_batch_seq` within this committed chunk, given the
        committed `append` result (chunk_seq / base_offset / etag). POD-in,
        Outcome-out — no move of any item."""
        ...


# =============================================================================
# SEAM 4: BatchAccumulator — the RAM buffer (stock RamAccumulator).
# =============================================================================
# push / pending_count / pending_bytes / oldest_ts_ms / drain. The stock
# RamAccumulator[Item] backs the buffer with a Slab[Item] (Slab handles
# Movable-not-Copyable Item — List[T] requires T: Copyable). A consumer can
# supply its own conformer (e.g. one that pre-sizes, or carries a side index).


trait BatchAccumulator(Movable, Deinitable):
    """SEAM 4: the RAM buffer holding items between flushes. `Item` MUST equal
    the BatchCodec's Item (the window pins A.Item == C.Item).

    `push` MOVES an item in (`var it`); `drain` MOVES every item OUT into a Slab
    and RESETS the buffer to empty (single atomic handoff to the spine, which
    RETAINS them across the parks + a 412 re-encode). All transfers are owned
    moves — no Item is ever copied."""

    comptime Item: Movable & Deinitable

    def push(mut self, var it: Self.Item, est_bytes: Int, ts_ms: Int64):
        """Append `it` (MOVED in). `est_bytes` (from BatchCodec.estimate_bytes)
        feeds pending_bytes; `ts_ms` is the item's enqueue timestamp (the oldest
        of which feeds the linger band)."""
        ...

    def pending_count(self) -> Int:
        ...

    def pending_bytes(self) -> Int:
        ...

    def oldest_ts_ms(self) -> Int64:
        """The enqueue timestamp of the OLDEST buffered item (the linger band's
        input). Undefined when empty (the caller guards on pending_count)."""
        ...

    def drain(mut self) -> Slab[Self.Item]:
        """MOVE every buffered item out into a Slab (buffered-items order) and
        RESET the buffer to empty. The single handoff to the spine."""
        ...


struct RamAccumulator[Item_: Movable & Deinitable](
    BatchAccumulator, Movable, Deinitable
):
    """The stock BatchAccumulator: a Slab[Item] buffer + a running byte total +
    the oldest enqueue timestamp. Slab (not List) so a Movable-not-Copyable
    Item is storable (List[T] needs T: Copyable). heap-reuse: Slab[Item] is a
    byte-backed slab, but Item is the consumer's plain value type stored by
    typed init_pointee_move (a CONCRETE origin) and drained by value MOVE — the
    heap-reuse GATE is that no wildcard origin ever touches an Item's inner heap
    buffer; here none does."""

    comptime Item = Self.Item_

    var _buf: Slab[Self.Item_]
    var _bytes: Int
    var _oldest_ts_ms: Int64

    def __init__(out self):
        self._buf = Slab[Self.Item_]()
        self._bytes = 0
        self._oldest_ts_ms = Int64(0)

    def push(mut self, var it: Self.Item_, est_bytes: Int, ts_ms: Int64):
        if self._buf.len() == 0:
            self._oldest_ts_ms = ts_ms
        self._buf.append(it^)
        self._bytes += est_bytes

    @always_inline
    def pending_count(self) -> Int:
        return self._buf.len()

    @always_inline
    def pending_bytes(self) -> Int:
        return self._bytes

    @always_inline
    def oldest_ts_ms(self) -> Int64:
        return self._oldest_ts_ms

    def drain(mut self) -> Slab[Self.Item_]:
        """MOVE the whole Slab out (single O(1) handoff — no per-item copy) and
        reset to a fresh empty Slab. The popped Slab preserves insertion order;
        the byte/timestamp counters reset."""
        var out = self._buf^
        self._buf = Slab[Self.Item_]()
        self._bytes = 0
        self._oldest_ts_ms = Int64(0)
        return out^


# =============================================================================
# SEAM 5: BatchAppender — the PARKABLE, MODE-CORRECT durable write.
# =============================================================================
# The WRITE half of the commit loop, made parkable + mode-selectable (the
# write-side rework). The spine drives `append_start` (parks on the returned
# biased op_id), then `append_poll` until READY, then `append_take` to harvest
# the typed `AppendOutcome`. The conformer owns the write mechanics (its own
# AsyncCasStore clone + the in-flight create-CAS op); the spine sees only the
# typed CasOpProgress (park) + the AppendOutcome (WON / LOST_SLOT / ERR).
#
# THE THREE MODES (consumer-selected by which conformer plugs in):
#   * EXACT-SLOT create-CAS at auth_head+1 (table-store group-commit / OCC). The
#     conformer create-CASes at EXACTLY `slot` (= auth_head+1; the
#     AsyncManifestAppendOp shape). A 412 is a REAL lost slot, returned as
#     LOST_SLOT — the spine's 412-loop re-reads the authoritative head +
#     re-encodes the SAME retained items against the new head + re-appends at the
#     new auth_head+1. This makes the spine's 412-loop LIVE (unlike the old
#     blocking-internally-retrying append). REQUIRED for OCC: an escalated slot
#     would be a silent lost-update.
#   * ESCALATING append (broker at-least-once). The conformer may escalate past
#     `slot` internally (the hot `append` path's cached_head+1 + escalate
#     shape); it converges on its own + returns WON, OR a terminal ERR. The
#     spine's 412-loop is not the arbiter here (the seam's own retry is).
#   * IDEMPOTENT append (broker EOS). The conformer drives `append_idempotent`
#     keyed by (producer_id, first_seq); a duplicate is reported WON (idempotent
#     ack) with the recorded offset. Exactly-once is the seam's contract.
#
# THE SEAM TAKES the encoded body + record_count + the fence epochs + the slot
# (auth_head+1, the exact-slot target) — all POD/owned-value — and the per-call
# reactor. It returns CasOpProgress (start/poll) and the AppendOutcome (take).
# NO key arithmetic, NO offset vocabulary, NO pointer crosses the seam.
#
# Pointer discipline: ZERO UnsafePointer / wildcard origin in any signature. The
# reactor is threaded per-call; the in-flight create-CAS op stays INSIDE the
# conformer (only CasOpProgress / AppendOutcome cross the boundary).

# AppendOutcome.kind discriminants.
comptime APPEND_WON: UInt8 = 0  # the durable write committed (AppendResult set)
comptime APPEND_LOST_SLOT: UInt8 = 1  # exact-slot 412 — spine re-reads+re-encodes
comptime APPEND_ERR: UInt8 = 2  # terminal write error (raise out of the spine)


struct AppendOutcome(Movable, Deinitable):
    """The typed result a `BatchAppender.append_take` returns: the discriminated
    outcome of the mode-correct durable write. Movable (owns the AppendResult's
    String etag + the err String); the spine moves it.

    Field layout:
      var kind: UInt8           — APPEND_WON / APPEND_LOST_SLOT / APPEND_ERR.
      var result: AppendResult  — the committed chunk (valid only on WON).
      var err: String           — the diagnostic (valid only on ERR).
    """

    var kind: UInt8
    var result: AppendResult
    var err: String

    def __init__(out self, kind: UInt8, var result: AppendResult, var err: String):
        self.kind = kind
        self.result = result^
        self.err = err^

    @staticmethod
    def won(var result: AppendResult) -> AppendOutcome:
        """The durable write committed — `result` carries the won chunk."""
        return AppendOutcome(APPEND_WON, result^, String(""))

    @staticmethod
    def lost_slot() -> AppendOutcome:
        """An EXACT-SLOT 412 — the spine re-reads authoritative head + re-encodes
        the retained items + re-appends at the new auth_head+1 (the LIVE
        412-loop)."""
        return AppendOutcome(
            APPEND_LOST_SLOT, AppendResult(Int64(0), Int64(0), Int64(0), String(""), 0), String("")
        )

    @staticmethod
    def error(var msg: String) -> AppendOutcome:
        """A terminal write error — the spine raises it out (ERR phase)."""
        return AppendOutcome(
            APPEND_ERR, AppendResult(Int64(0), Int64(0), Int64(0), String(""), 0), msg^
        )

    @always_inline
    def is_won(self) -> Bool:
        return self.kind == APPEND_WON

    @always_inline
    def is_lost_slot(self) -> Bool:
        return self.kind == APPEND_LOST_SLOT

    @always_inline
    def is_error(self) -> Bool:
        return self.kind == APPEND_ERR


trait BatchAppender(Movable, Deinitable):
    """SEAM 5: the PARKABLE, MODE-CORRECT durable write of the encoded batch. The
    conformer owns the write mechanics (its own AsyncCasStore clone + the
    in-flight create-CAS op); the spine drives `append_start` (parks on the
    returned biased op_id), `append_poll` until READY, then `append_take` ->
    AppendOutcome.

    The MODE is the conformer's choice (see header): EXACT-SLOT create-CAS
    at `slot` (a 412 -> LOST_SLOT, the spine's LIVE 412-loop), ESCALATING
    append (converges internally -> WON/ERR), or IDEMPOTENT append (exactly-once
    -> WON with the recorded offset, even for a duplicate).

    ── THE IDEMPOTENT-MODE SINGLETON INVARIANT (a HARD seam contract) ──────────
    IDEMPOTENT mode requires N == 1: the coalesced flush concatenates MANY
    producer batches into one body, but `append_idempotent` keys exactly ONE
    (producer_id, first_seq) per append. The per-batch idempotency identity (the
    dedup key the broker-EOS conformer carries) is conformer-state-VALID ONLY
    when the spine's body carries exactly one producer batch — i.e. the broker
    acks=all SINGLETON path (one producer batch per flush). A coalesced N>1 body
    cannot be replayed idempotently against a single dedup key (a partial replay
    would re-append the whole concatenated body under one key, losing per-batch
    exactly-once). So an IDEMPOTENT-mode conformer is SINGLETON-ONLY: the window
    that plugs it in MUST force/flush at most one producer batch per append (the
    acks=all path), NOT coalesce. EXACT-SLOT and ESCALATING modes are N-ary
    (they coalesce freely); the singleton restriction is IDEMPOTENT-mode-specific.

    IDEMPOTENT-MODE GATE: the first IDEMPOTENT-mode consumer (the broker's
    exactly-once path) MUST add an IDEMPOTENT-mode conformer test that asserts the
    N==1 singleton invariant (a coalesced N>1 IDEMPOTENT flush is rejected /
    never constructed). This package's rig exercises only EXACT-SLOT (the
    in-mem AsyncManifestAppendOp), so this invariant is documented but not
    test-covered here.

    Pointer discipline: ZERO UnsafePointer / wildcard origin in any signature.
    The reactor is threaded per-call; the in-flight op stays INSIDE the conformer
    (only CasReadResult / CasOpProgress / AppendOutcome cross the boundary)."""

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
        """Kick off the mode-correct durable write of `body` (MOVED in). `slot`
        is the EXACT-slot target (= auth_head+1; the exact-slot mode create-CASes
        there, the escalating/idempotent modes may treat it as a hint). The fence
        epochs default to 0 (no fence) for callers that do not track leases.
        READY (immediate completion — call `append_take`) / PENDING(op_id) (park)
        / ERR."""
        ...

    def append_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        """Advance the in-flight durable write one non-blocking step. READY /
        PENDING(op_id) / ERR. An EXACT-slot 412 may surface here as a
        CasOpProgress.error (classified by the conformer) OR be deferred to
        `append_take`'s LOST_SLOT — the spine handles both."""
        ...

    def append_take(mut self) raises -> AppendOutcome:
        """Move the completed write outcome out (caller checks READY). Returns
        WON (the committed chunk) / LOST_SLOT (exact-slot 412 — re-read +
        re-encode) / ERR (terminal)."""
        ...

    def classify_append_error(self, msg: String) -> UInt8:
        """Classify an append-phase ERR returned from `append_start` /
        `append_poll`: APPEND_LOST_SLOT (an exact-slot 412 — the spine re-reads +
        re-encodes), APPEND_ERR (terminal). The exact-slot conformer maps a
        412/precondition msg to LOST_SLOT; the escalating/idempotent conformers
        (which never surface a bare 412) map everything to ERR."""
        ...


# =============================================================================
# _CoalesceSpine — the parkable commit op (mirrors AsyncReassignOp).
# =============================================================================
# Drives ONE flush as a poll-shaped state machine over the H reader (which owns
# an AsyncCasStore clone + drives the parkable stage-blob) + the A appender
# (which owns its own AsyncCasStore clone + the in-flight, mode-correct durable
# write). The buffered items are RETAINED in the spine (a Slab[Item]) across the
# parks AND across a 412 re-encode (encode borrows them by ref). The spine
# itself lives behind the window's single OwnedPointer[SM] frame.

comptime _SP_PHASE_READ: UInt8 = 0  # read_head_start/poll in flight
comptime _SP_PHASE_STAGE_BLOB: UInt8 = 1  # the parkable content-addressed PUT
comptime _SP_PHASE_APPEND: UInt8 = 2  # the parkable mode-correct durable write
comptime _SP_PHASE_DONE: UInt8 = 3  # outcomes ready in take_outcomes
comptime _SP_PHASE_ERR: UInt8 = 4  # terminal error in err_text


struct _CoalesceSpine[
    Storage: CloneableConditionalWriteStore & AsyncCasStore,
    H: AuthHeadReader,
    C: BatchCodec,
    A: BatchAppender,
](Movable, Deinitable):
    """The parkable flush op: read auth HEAD -> encode -> (optional, PARKS) stage
    blob -> (PARKS) mode-correct durable write, with the LIVE 412 re-read/
    re-encode loop, driven one non-blocking step at a time on a CALLER-supplied
    reactor.

    Pins `H.Head == C.Head` (the decoded HEAD feeds encode). Owns the `H` reader
    (which owns the parkable read store-clone + drives the parkable stage-blob),
    the `C` codec, the `A` appender (which owns its own append store-clone + the
    in-flight mode-correct durable write), and RETAINS the buffered `_items` Slab
    across the parks + a 412 re-encode (dropped only on a WON append / teardown).

    THE REWORK'S CARRIED-ACROSS-PARK STATE: the write side now PARKS (it no
    longer calls a blocking append). So between ENCODE and the WON/LOST append,
    the spine must retain (a) the encoded `_pending_batch` across the STAGE_BLOB
    park and the APPEND park (the body is MOVED into append_start, but the
    winner/loser idxs + the AppendOutcome-build inputs survive on the batch), and
    (b) the `_slot` (= auth_head+1) the exact-slot appender create-CASes at. Both
    are owned-value fields behind the single spine frame (NO byte-slab, NO
    wildcard) — the in-flight stage-blob / append op itself lives INSIDE the
    reader / appender conformer (only typed CasOpProgress / AppendOutcome cross
    the seam).

    Movable, NOT Copyable: owns the Slab + Strings + the seam conformers. The
    reactor is threaded into start()/poll() per-call (never a field) —
    migration-clean."""

    comptime Head = Self.C.Head
    comptime Outcome = Self.C.Outcome
    comptime Item = Self.C.Item

    var _head: Self.H
    var _codec: Self.C
    var _appender: Self.A

    var _phase: UInt8
    var _attempt: Int
    var _err: String
    var _reason: UInt8  # the flush reason (carried into the outcomes, observ.)

    # RETAINED across the parks + a 412 re-encode (encode borrows by ref).
    var _items: Slab[Self.Item]
    # The committed outcomes, ready on DONE (winner + loser outcomes, each tagged
    # by orig_idx so take_outcomes returns them in buffered order).
    var _out: List[Tuple[Int, Self.Outcome]]
    # The REWORK's carried-across-park encoded batch (retained across STAGE_BLOB +
    # APPEND parks; the body is moved into append_start, the idxs survive for the
    # WON finish). None outside an in-flight encode->append window.
    var _pending: Optional[EncodedBatch[Self.Outcome]]
    # The exact-slot target (= decoded auth_head + 1) the exact-slot appender
    # create-CASes at; carried across the STAGE_BLOB + APPEND parks. The encode
    # already conditioned the body on the same head, so a LOST_SLOT re-read +
    # re-encode recomputes both consistently.
    var _slot: Int64

    def __init__(
        out self,
        var head: Self.H,
        var codec: Self.C,
        var appender: Self.A,
        var items: Slab[Self.Item],
        reason: UInt8,
    ):
        self._head = head^
        self._codec = codec^
        self._appender = appender^
        self._phase = _SP_PHASE_READ
        self._attempt = 0
        self._err = String("")
        self._reason = reason
        self._items = items^
        self._out = List[Tuple[Int, Self.Outcome]]()
        self._pending = Optional[EncodedBatch[Self.Outcome]]()
        self._slot = Int64(0)

    @always_inline
    def is_done(self) -> Bool:
        return self._phase == _SP_PHASE_DONE

    @always_inline
    def is_error(self) -> Bool:
        return self._phase == _SP_PHASE_ERR

    @always_inline
    def err_text(self) -> String:
        return self._err

    @always_inline
    def flush_reason(self) -> UInt8:
        return self._reason

    @always_inline
    def item_count(self) -> Int:
        return self._items.len()

    @always_inline
    def debug_phase(self) -> UInt8:
        """TEST-ONLY: the current spine phase (_SP_PHASE_*). Used by the
        crash-drop-on-write soak to assert the drop landed mid-WRITE (STAGE_BLOB
        / APPEND) — the new carried-across-park teardown surface — NOT mid-READ
        (which the parked-read soak already covers)."""
        return self._phase

    @always_inline
    def debug_has_pending(self) -> Bool:
        """TEST-ONLY: True iff the carried-across-park encoded batch (_pending,
        a heap-owning EncodedBatch) is engaged. The soak asserts this is
        True at the crash-drop so the teardown of _pending (its body + staged
        blob) is exercised alongside the retained _items Slab."""
        return Bool(self._pending)

    def take_outcomes(mut self) raises -> List[Tuple[Int, Self.Outcome]]:
        """MOVE the committed (orig_idx, Outcome) pairs out (caller checks
        is_done()). Buffered-items order is recoverable via the orig_idx tags."""
        if self._phase != _SP_PHASE_DONE:
            raise Error("_CoalesceSpine.take_outcomes: not done")
        var out = self._out^
        self._out = List[Tuple[Int, Self.Outcome]]()
        return out^

    # ---- the read phase ----

    def _begin_read[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Start a commit attempt by kicking off the auth-HEAD read. Returns the
        biased op_id to park on, or drives straight into APPEND when READY."""
        self._attempt += 1
        self._phase = _SP_PHASE_READ
        var prog = self._head.read_head_start[S](reactor)
        if prog.is_error():
            return self._on_read_err[S](prog.err_text(), reactor)
        if prog.is_pending():
            return prog.op_id
        return self._after_read_ready[S](reactor)

    def _on_read_err[
        S: WakerSink & Movable & Deinitable,
    ](mut self, msg: String, mut reactor: Reactor[S]) raises -> Int64:
        """A read error: FATAL is terminal; TORN / CONFLICT retry the read
        (bounded)."""
        var cls = self._head.classify_read_error(msg)
        if cls == READ_ERR_FATAL or self._attempt >= MAX_COMMIT_ATTEMPTS:
            self._phase = _SP_PHASE_ERR
            self._err = String("_CoalesceSpine read: ") + msg
            return Int64(0)
        # Retry — re-issue the read on a fresh attempt.
        return self._begin_read[S](reactor)

    def _after_read_ready[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """The auth-HEAD read completed: decode it, project the exact slot, run
        ENCODE (CPU, borrowing the retained items), then drive the PARKABLE
        STAGE_BLOB (if Some) or PARKABLE APPEND. The encoded batch + the slot are
        STASHED on the spine so they survive the upcoming park(s)."""
        var rr = self._head.take_read()
        # DECODE + ENCODE both run on the codec (it owns the Head type), so the
        # spine never equates a Head across two traits.
        var auth = self._codec.decode_head(rr^)
        # The EXACT-slot target = auth_head + 1 (the codec projects it; the spine
        # stays Head-agnostic). Carried across the upcoming parks.
        self._slot = self._codec.head_slot(auth)
        # ENCODE — the CPU-only domain pass. Borrows the retained items by ref
        # (RETAINED for a LOST_SLOT re-encode).
        var batch = self._codec.encode(self._items, auth^)
        # STASH the encoded batch behind the spine frame so it survives the
        # STAGE_BLOB + APPEND parks (the body is moved out at append_start time;
        # the winner/loser idxs survive for the WON finish).
        self._pending = Optional[EncodedBatch[Self.Outcome]](batch^)
        # STAGE_BLOB (PARKS, if the encode emitted a staged blob) -> else APPEND.
        if self._pending.value().has_staged_blob():
            return self._begin_stage_blob[S](reactor)
        return self._begin_append[S](reactor)

    # ---- the parkable STAGE_BLOB phase ----

    def _begin_stage_blob[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Kick off the PARKABLE content-addressed blob PUT via the reader's own
        store clone. The blob bytes are copied out of the stashed batch (the
        batch's staged_blob survives a LOST_SLOT re-encode; a copy here keeps the
        batch intact). The in-flight PUT op lives INSIDE the reader conformer
        across the park."""
        self._phase = _SP_PHASE_STAGE_BLOB
        var key = self._pending.value().staged_blob_key.copy()
        var blob = self._pending.value().staged_blob.value().copy()
        var prog = self._head.stage_blob_start[S](key, blob^, reactor)
        if prog.is_error():
            return self._on_stage_blob_err[S](prog.err_text(), reactor)
        if prog.is_pending():
            return prog.op_id
        return self._after_stage_blob_ready[S](reactor)

    def _after_stage_blob_ready[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """The blob PUT completed READY (or was an idempotent 412 WIN the
        conformer reported as READY). Finalize it, then drive the APPEND."""
        try:
            self._head.stage_blob_take()
        except e:
            return self._on_stage_blob_err[S](String(e), reactor)
        return self._begin_append[S](reactor)

    def _on_stage_blob_err[
        S: WakerSink & Movable & Deinitable,
    ](mut self, msg: String, mut reactor: Reactor[S]) raises -> Int64:
        """A stage-blob-phase ERR (returned from stage_blob_start / stage_blob_poll
        / stage_blob_take): the reader classifies it. STAGE_BLOB_ERR_REKEY (a
        colliding-key 412) routes to the LIVE re-encode loop — re-read auth + re-
        encode the SAME retained items, which re-mints a FRESH, disjoint segment
        key + rebuilds the body, so the manifest never references the FOREIGN
        object already at the colliding key (the silent-data-loss gap BrokerCore
        also closes). STAGE_BLOB_ERR_FATAL is terminal. The re-encode is bounded
        by MAX_COMMIT_ATTEMPTS (the SAME convergence bound + fail-loud the append
        412-loop uses) — an unconverged re-key fails LOUD, never silently."""
        var cls = self._head.classify_stage_blob_error(msg)
        if cls == STAGE_BLOB_ERR_REKEY:
            return self._on_lost_slot[S](reactor)
        self._phase = _SP_PHASE_ERR
        self._err = String("_CoalesceSpine stage_blob: ") + msg
        return Int64(0)

    # ---- the parkable APPEND phase (the mode-correct durable write) ----

    def _begin_append[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Kick off the PARKABLE mode-correct durable write via the appender. The
        body is MOVED out of the stashed batch into append_start; the batch's
        winner/loser idxs survive (a LOST_SLOT re-encode rebuilds the body). The
        in-flight create-CAS op lives INSIDE the appender conformer across the
        park."""
        self._phase = _SP_PHASE_APPEND
        # TAKE the whole stashed batch into a LOCAL owned value, move its body out
        # (a clean owned-field move out of a local — no borrow conflict, no
        # partial-move-via-ref, no byte copy of the up-to-8MiB body), then
        # re-stash the batch with an empty body. The winner_idxs / loser_outcomes
        # / record_count remain on the re-stashed batch for the WON finish. The
        # body's bytes are owned by the in-flight op inside the appender conformer
        # across the park (heap-reuse: never laundered through a wildcard).
        var batch = self._pending.take()
        var body = batch.body^
        batch.body = List[UInt8]()
        var rc = batch.record_count
        var le = batch.lease_epoch
        var cle = batch.current_lease_epoch
        var slot = self._slot
        self._pending = Optional[EncodedBatch[Self.Outcome]](batch^)
        var prog = self._appender.append_start[S](
            body^, rc, slot, le, cle, reactor
        )
        if prog.is_error():
            return self._on_append_err[S](prog.err_text(), reactor)
        if prog.is_pending():
            return prog.op_id
        return self._after_append_ready[S](reactor)

    def _after_append_ready[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """The durable write completed READY: harvest the AppendOutcome.
        WON -> build the per-item outcomes + finish DONE. LOST_SLOT -> the LIVE
        412-loop (re-read auth + re-encode over the RETAINED items, bounded).
        ERR -> terminal."""
        var outcome = self._appender.append_take()
        # AppendResult is Copyable (a POD + one String etag); copying it out
        # avoids a partial-move out of the middle of `outcome` (which would block
        # outcome's own destruction). Same for the err String.
        if outcome.is_won():
            var ar = outcome.result.copy()
            return self._finish_append(ar^)
        if outcome.is_lost_slot():
            return self._on_lost_slot[S](reactor)
        # NIT-1 defense-in-depth: a take-path ERR is RE-CLASSIFIED through the
        # SAME classify_append_error contract the start/poll ERR path uses
        # (_on_append_err), so a take-path 412 (an exact-slot conformer that
        # surfaces a precondition as a take->error rather than take->LOST_SLOT)
        # maps to LOST_SLOT (the LIVE 412-loop), NOT a terminal raise. Today
        # both in-tree conformers map a take-path 412 to lost_slot() so this
        # never fires — but the SPINE enforcing the contract (rather than relying
        # on every conformer to pre-map) is the safer invariant. A genuinely
        # terminal err still classifies APPEND_ERR -> terminal.
        return self._on_append_err[S](outcome.err.copy(), reactor)

    def _on_append_err[
        S: WakerSink & Movable & Deinitable,
    ](mut self, msg: String, mut reactor: Reactor[S]) raises -> Int64:
        """An append-phase ERR returned from append_start / append_poll: the
        appender classifies it. APPEND_LOST_SLOT -> the LIVE 412-loop; APPEND_ERR
        -> terminal. (Some conformers surface a 412 as a CasOpProgress.error on
        the immediate-completion / final-tick path rather than as a take->
        LOST_SLOT; this routes both to the same loop.)"""
        var cls = self._appender.classify_append_error(msg)
        if cls == APPEND_LOST_SLOT:
            return self._on_lost_slot[S](reactor)
        self._phase = _SP_PHASE_ERR
        self._err = String("_CoalesceSpine append: ") + msg
        return Int64(0)

    def _on_lost_slot[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """The EXACT-slot create-CAS lost its slot (a real 412). The LIVE
        412-loop: drop the stale stashed batch (its body was already moved into
        the now-lost op; the winner idxs are recomputed by re-encode), re-read the
        authoritative head + re-encode the SAME RETAINED items against the new
        head + re-append at the new auth_head+1. Bounded by MAX_COMMIT_ATTEMPTS."""
        if self._attempt >= MAX_COMMIT_ATTEMPTS:
            self._phase = _SP_PHASE_ERR
            self._err = (
                String("_CoalesceSpine: append CAS did not converge within ")
                + String(MAX_COMMIT_ATTEMPTS)
                + String(" attempts")
            )
            return Int64(0)
        # Drop the stale batch; _items survive for the re-encode.
        self._pending = Optional[EncodedBatch[Self.Outcome]]()
        return self._begin_read[S](reactor)

    def _finish_append(mut self, var ar: AppendResult) raises -> Int64:
        """A WON append: build the (orig_idx, Outcome) pairs for every winner +
        every loser from the stashed batch, then finish DONE."""
        var batch = self._pending.take()
        # Winners — pair winner i (in winner_idxs order) with intra_batch_seq i.
        for i in range(len(batch.winner_idxs)):
            var orig_idx = batch.winner_idxs[i]
            var oc = self._codec.winner_outcome(orig_idx, i, ar)
            self._out.append((orig_idx, oc^))
        # Losers — already-arbitrated by encode; copy them straight out (Outcome
        # is Copyable — a small result value).
        for j in range(len(batch.loser_outcomes)):
            ref pair = batch.loser_outcomes[j]
            self._out.append((pair[0], pair[1].copy()))
        _ = batch^
        _ = ar^
        self._phase = _SP_PHASE_DONE
        return Int64(0)

    # ---- the driver surface ----

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Kick off the flush. Returns the biased op_id to park on (0 == finished
        in one synchronous burst — the caller checks is_done()/is_error())."""
        return self._begin_read[S](reactor)

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Resume after the parked op_id completed. Demux on the in-flight phase
        (READ / STAGE_BLOB / APPEND all park). Returns the next biased op_id to
        park on, or 0 when finished."""
        if self._phase == _SP_PHASE_READ:
            var prog = self._head.read_head_poll[S](reactor)
            if prog.is_error():
                return self._on_read_err[S](prog.err_text(), reactor)
            if prog.is_pending():
                return prog.op_id
            return self._after_read_ready[S](reactor)
        elif self._phase == _SP_PHASE_STAGE_BLOB:
            var prog = self._head.stage_blob_poll[S](reactor)
            if prog.is_error():
                return self._on_stage_blob_err[S](prog.err_text(), reactor)
            if prog.is_pending():
                return prog.op_id
            return self._after_stage_blob_ready[S](reactor)
        elif self._phase == _SP_PHASE_APPEND:
            var prog = self._appender.append_poll[S](reactor)
            if prog.is_error():
                return self._on_append_err[S](prog.err_text(), reactor)
            if prog.is_pending():
                return prog.op_id
            return self._after_append_ready[S](reactor)
        return Int64(0)


# =============================================================================
# CoalescingWindow — the FRONT-END (offer / force / on_deadline / poll).
# =============================================================================
# The consumer-facing handle. Holds the BatchAccumulator buffer, the FlushPolicy,
# and the single in-flight spine behind an OwnedPointer frame. `offer` pushes an
# item, evaluates the policy, and starts a flush when a band fires (if no flush
# is already in flight). `force(reason)` asserts an EXPLICIT/SHUTDOWN flush. A
# non-empty buffer with max_ms>0 arms a reactor timer; `on_deadline` is the
# self-fire that routes through the identical poll demux. `poll` advances the
# in-flight spine. `take_outcomes` returns the committed outcomes.
#
# THE SEAM FACTORY. Because the spine OWNS the H reader + C codec + A appender
# (each holding a store clone), and at-most-one flush is in flight, the window
# delegates spine construction to a caller-supplied `SpineFactory` conformer that
# mints a FRESH spine (fresh store clones) per flush. This keeps the window
# itself free of the Cloneable-template requirement while honoring the
# store-by-value-clone heap-reuse contract.


trait SpineFactory(Movable, Deinitable):
    """Mints a fresh `_CoalesceSpine` per flush over fresh store clones. The
    consumer wires its store + key prefix + seam conformers here ONCE; the
    window calls `make_spine(items^, reason)` on each flush.

    Associated types pin the spine's parameters. `Item` MUST equal the
    accumulator's Item."""

    comptime Storage: CloneableConditionalWriteStore & AsyncCasStore
    comptime H: AuthHeadReader
    comptime C: BatchCodec
    comptime A: BatchAppender
    comptime Item: Movable & Deinitable

    def make_spine(
        mut self, var items: Slab[Self.Item], reason: UInt8
    ) raises -> _CoalesceSpine[Self.Storage, Self.H, Self.C, Self.A]:
        """Build a fresh spine over fresh store clones + the consumer's seam
        conformers (including the mode-correct parkable appender), taking
        ownership of the drained `items`."""
        ...


struct CoalescingWindow[
    F: SpineFactory,
](Movable, Deinitable):
    """The general coalescing-window front-end. The buffered item type flows from
    the factory (`F.Item`); the window owns the stock `RamAccumulator[F.Item]`
    buffer directly (a consumer-custom accumulator would be an extension —
    the window standardizes on the stock buffer so it references ONE Item
    type, avoiding Mojo 1.0.0b1's cross-trait associated-type-equality gap).
    Drives ONE in-flight flush at a time (the single-store-one-in-flight-op hard
    constraint — the REASON coalescing is N->1): a flush starts only when none is
    in flight; offers during a flush accumulate into the buffer for the NEXT
    flush.

    The suspended spine lives behind a SINGLE OwnedPointer[SM] frame (`_frame`) —
    never a Movable in a byte-slab (the heap-reuse GATE).

    Pointer discipline: ZERO UnsafePointer / wildcard origin in any signature.
    The reactor is threaded into offer/force/on_deadline/poll per-call (never a
    field). The op_id is a plain biased Int64 from the store's poll ops /
    reactor.register_timer."""

    comptime Item = Self.F.Item
    comptime Spine = _CoalesceSpine[
        Self.F.Storage, Self.F.H, Self.F.C, Self.F.A
    ]
    # The committed-outcome type is exactly what the spine returns (== F.C.Outcome
    # reached via the spine alias so the field type and take_outcomes() agree).
    comptime Outcome = Self.Spine.Outcome
    comptime Buf = RamAccumulator[Self.F.Item]

    var _buf: Self.Buf
    var _policy: FlushPolicy
    var _factory: Self.F

    # The in-flight flush — at most one. Behind a SINGLE OwnedPointer (heap-reuse).
    var _frame: Optional[OwnedPointer[Self.Spine]]
    var _inflight: Bool
    var _parked_op_id: Int64
    # The committed outcomes of the LAST finished flush (drained by the caller
    # via take_outcomes after poll reports done).
    var _ready_outcomes: List[Tuple[Int, Self.Outcome]]
    var _last_err: String
    var _had_err: Bool
    # The armed linger timer's biased op_id (0 == no timer armed).
    var _timer_op_id: Int64
    # The reason of the LAST started flush (observability).
    var _last_reason: UInt8

    def __init__(
        out self,
        var buf: Self.Buf,
        policy: FlushPolicy,
        var factory: Self.F,
    ):
        self._buf = buf^
        self._policy = policy
        self._factory = factory^
        self._frame = Optional[OwnedPointer[Self.Spine]]()
        self._inflight = False
        self._parked_op_id = Int64(0)
        self._ready_outcomes = List[Tuple[Int, Self.Outcome]]()
        self._last_err = String("")
        self._had_err = False
        self._timer_op_id = Int64(0)
        self._last_reason = FLUSH_REASON_NONE

    @always_inline
    def is_inflight(self) -> Bool:
        return self._inflight

    def factory_mut(mut self) -> ref [self._factory] Self.F:
        """Borrow the owned SpineFactory mutably so the consumer can RECONFIGURE
        the NEXT flush's per-flush state (e.g. the broker's produce mode +
        producer/txn/lease trailer — the four-variant collapse). The factory is
        consulted only at `_start_flush` (make_spine), so a reconfigure between
        flushes is safe; reconfiguring WHILE a flush is in flight affects only the
        NEXT flush (the in-flight spine already captured its config). The returned
        ref is bound to `self._factory` (NOT `self`) per the Mojo 1.0.0b1
        inner-OwnedPointer/field ref-origin rule."""
        return self._factory

    def debug_inflight_item_count(self) -> Int:
        if not self._frame:
            return -1
        return self._frame.value()[].item_count()

    def debug_inflight_phase(self) -> Int:
        """TEST-ONLY: the in-flight spine's current phase (_SP_PHASE_* as Int),
        or -1 if no flush is in flight. The crash-drop-on-write soak uses
        this to assert the drop landed on the STAGE_BLOB / APPEND park (the new
        carried-across-park teardown surface), not the READ park."""
        if not self._frame:
            return -1
        return Int(self._frame.value()[].debug_phase())

    def debug_inflight_has_pending(self) -> Bool:
        """TEST-ONLY: True iff the in-flight spine holds the carried-across-park
        encoded batch (_pending). The soak asserts this at the crash-drop."""
        if not self._frame:
            return False
        return self._frame.value()[].debug_has_pending()

    @always_inline
    def pending_count(self) -> Int:
        return self._buf.pending_count()

    @always_inline
    def pending_bytes(self) -> Int:
        return self._buf.pending_bytes()

    @always_inline
    def parked_op_id(self) -> Int64:
        return self._parked_op_id

    @always_inline
    def timer_op_id(self) -> Int64:
        return self._timer_op_id

    @always_inline
    def has_error(self) -> Bool:
        return self._had_err

    @always_inline
    def err_text(self) -> String:
        return self._last_err

    @always_inline
    def last_flush_reason(self) -> UInt8:
        return self._last_reason

    # ---- buffer / offer / force ----

    def buffer(mut self, var it: Self.Item, est_bytes: Int, ts_ms: Int64):
        """Buffer `it` WITHOUT evaluating the policy (pure accumulate). MOVES it
        in. `est_bytes` is the caller's pre-computed size estimate (the caller
        owns the codec's estimate_bytes — the window stays codec-free)."""
        self._buf.push(it^, est_bytes, ts_ms)

    def offer[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        var it: Self.Item,
        est_bytes: Int,
        ts_ms: Int64,
        now_ms: Int64,
        mut reactor: Reactor[S],
    ) raises -> Int64:
        """Buffer `it` (MOVED in), evaluate the policy, and if a band fires AND
        no flush is in flight start one. Returns the biased op_id the started
        flush parks on (0 == no flush started OR it finished in one burst). Also
        arms the linger timer when the buffer is non-empty + max_ms>0 + no timer.
        """
        self.buffer(it^, est_bytes, ts_ms)
        _ = self._maybe_arm_timer[S](reactor)
        var v = evaluate(
            self._policy,
            self._buf.pending_count(),
            self._buf.pending_bytes(),
            self._buf.oldest_ts_ms(),
            now_ms,
        )
        if v.flushes() and not self._inflight:
            return self._start_flush[S](v.reason, reactor)
        return Int64(0)

    def force[
        S: WakerSink & Movable & Deinitable,
    ](mut self, reason: UInt8, mut reactor: Reactor[S]) raises -> Int64:
        """Assert an EXPLICIT / SHUTDOWN flush of the buffered items (a commit, a
        teardown drain). No-op (returns 0) if the buffer is empty or a flush is
        already in flight. Returns the biased op_id the started flush parks on.

        COMMITTED SINGLETON FAST-PATH: reason==EXPLICIT with exactly one buffered
        item is the broker / table-store single-record commit hot path; the drain is
        an O(1) whole-Slab move (no per-item realloc), so a 1-item EXPLICIT flush
        compiles to ~ a direct flush (no policy re-eval, no List realloc)."""
        if self._buf.pending_count() == 0 or self._inflight:
            return Int64(0)
        return self._start_flush[S](reason, reactor)

    def on_deadline[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, fired_op_id: Int64, now_ms: Int64, mut reactor: Reactor[S]
    ) raises -> Int64:
        """The linger-timer SELF-FIRE. Called when the armed timer op_id
        completes (routed through the IDENTICAL biased-op_id demux a store read
        completion uses). If the fired op_id is the armed timer AND the buffer is
        non-empty AND no flush is in flight, start a LINGER flush. Returns the
        flush's biased op_id (0 == nothing started)."""
        if fired_op_id != self._timer_op_id or self._timer_op_id == Int64(0):
            return Int64(0)
        # Consume the timer (one-shot).
        self._timer_op_id = Int64(0)
        if self._buf.pending_count() == 0 or self._inflight:
            return Int64(0)
        # Re-confirm the band (defensive — the buffer may have been flushed by a
        # size/count band between arming and firing; if the linger band no longer
        # holds we still flush on the deadline by intent).
        return self._start_flush[S](FLUSH_REASON_LINGER, reactor)

    def _maybe_arm_timer[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Bool:
        """Arm a one-shot linger deadline (max_ms relative) if the buffer is
        non-empty, max_ms>0, and no timer is currently armed. Returns True iff a
        timer was armed this call. The reactor arms a kernel timer; when it fires
        the serve loop routes the biased op_id to on_deadline (the identical
        demux a store read uses)."""
        if self._policy.max_ms <= Int64(0):
            return False
        if self._buf.pending_count() == 0:
            return False
        if self._timer_op_id != Int64(0):
            return False
        var deadline_ns = self._policy.max_ms * Int64(1_000_000)
        self._timer_op_id = reactor.register_timer(deadline_ns)
        return True

    def _start_flush[
        S: WakerSink & Movable & Deinitable,
    ](mut self, reason: UInt8, mut reactor: Reactor[S]) raises -> Int64:
        """Drain the buffer (O(1) whole-Slab move), build a fresh spine via the
        factory, kick it off, and (if it parks) stash it behind the single
        OwnedPointer frame."""
        var items = self._buf.drain()
        var spine = self._factory.make_spine(items^, reason)
        self._inflight = True
        self._last_reason = reason
        # A new flush supersedes the linger timer (the buffered items are gone).
        self._timer_op_id = Int64(0)
        var op = spine.start[S](reactor)
        if spine.is_error():
            self._inflight = False
            self._had_err = True
            self._last_err = spine.err_text()
            return Int64(0)
        if spine.is_done():
            # Finished in one synchronous burst — harvest the outcomes now.
            self._ready_outcomes = spine.take_outcomes()
            self._inflight = False
            self._parked_op_id = Int64(0)
            return Int64(0)
        # Parked — stash behind the single OwnedPointer frame.
        self._parked_op_id = op
        self._frame = Optional[OwnedPointer[Self.Spine]](
            OwnedPointer[Self.Spine](value=spine^)
        )
        return op

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Resume the in-flight flush after its parked op_id completed. Advances
        one non-blocking step. Returns the next biased op_id to park on, or 0
        when the flush finished (the caller then calls take_outcomes). A no-op
        (returns 0) when no flush is in flight."""
        if not self._inflight or not self._frame:
            return Int64(0)
        # Each `self._frame.value()[]` is a short borrow that ends at the
        # statement — never a ref held across a `self._frame.take()` (which would
        # be a borrow conflict). This mirrors the broker template's
        # `self._op.value().poll[S](...)` direct-call discipline.
        var op = self._frame.value()[].poll[S](reactor)
        if self._frame.value()[].is_error():
            self._last_err = self._frame.value()[].err_text()
            self._had_err = True
            self._inflight = False
            self._parked_op_id = Int64(0)
            _ = self._frame.take()
            return Int64(0)
        if self._frame.value()[].is_done():
            self._ready_outcomes = self._frame.value()[].take_outcomes()
            self._inflight = False
            self._parked_op_id = Int64(0)
            _ = self._frame.take()
            return Int64(0)
        self._parked_op_id = op
        return op

    def take_outcomes(mut self) -> List[Tuple[Int, Self.Outcome]]:
        """MOVE the committed (orig_idx, Outcome) pairs of the LAST finished
        flush out. Empty if no flush has finished since the last drain."""
        var out = self._ready_outcomes^
        self._ready_outcomes = List[Tuple[Int, Self.Outcome]]()
        return out^


# =============================================================================
# multi_snapshot_occ_check — the table-store group-commit OCC helper.
# =============================================================================
# For table-store group-commit OCC. Given a list of (member_idx,
# snapshot_seq) pairs and the authoritative HEAD seq, returns the member_idxs
# whose snapshot is STALE (snapshot_seq < auth_seq) — the OCC conflicts. The
# encode-side arbitration uses this to split winners (fresh snapshot) from losers
# (stale -> 40001-shaped conflict outcome). PURE — no store access, no clock.


def multi_snapshot_occ_check(
    members_with_snapshots: List[Tuple[Int, Int64]], auth_seq: Int64
) -> List[Int]:
    """Return the member_idx of every member whose snapshot_seq is STALE relative
    to `auth_seq` (snapshot_seq < auth_seq == a write landed under it since the
    snapshot was taken == an OCC conflict). Members with snapshot_seq >= auth_seq
    are fresh (winners). PURE decision — the encode folds the result into
    winner_idxs / loser_outcomes."""
    var conflicts = List[Int]()
    for i in range(len(members_with_snapshots)):
        ref pair = members_with_snapshots[i]
        if pair[1] < auth_seq:
            conflicts.append(pair[0])
    return conflicts^

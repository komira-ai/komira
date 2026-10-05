# =============================================================================
# tests/test_coalescing_window.mojo
# The unified batching substrate
#   The standalone test rig + GATE for the GENERAL coalescing-window primitive.
# =============================================================================
#
# The primitive (komira_objectstore/coalescing_window.mojo) is
# tested STANDALONE here via an in-mem rig: an identity AuthHeadReader + identity
# BatchCodec (every item a winner) + an EXACT-SLOT parkable BatchAppender (the
# in-tree AsyncManifestAppendOp over the in-mem CAS store) over
# SharedInMemoryConditionalStore / SharedInMemorySlowCasStore (for park
# testing). NO consumer code is involved. The WRITE side now drives the
# PARKABLE, MODE-CORRECT BatchAppender seam (exact-slot create-CAS at auth_head+1
# the table-store OCC mode), NOT a blocking MetadataStore.append, so the spine
# PARKS the write + the 412-loop is LIVE around the real create-CAS.
#
# Tests:
#   (a) unit per FlushPolicy.evaluate branch (SIZE / LINGER / COUNT / NONE /
#       first-fires-wins / empty).
#   (b) parked-resume CORRECTNESS: offer N -> park on slow-CAS read + parkable
#       append -> poll to done -> all N get outcomes, the chunk lands ONCE.
#   (c) 412-retry: a flaky EXACT-SLOT appender returns LOST_SLOT K times -> the
#       spine's LIVE 412-loop re-reads / re-encodes / re-appends (bounded) and
#       converges, the chunk lands ONCE.
#   (d) timer-deadline SELF-FIRES: a lone buffered item with max_ms flushes on
#       the reactor timer with NO further offer.
#   (e) the singleton fast-path (1-item EXPLICIT force).
#   (e2) PARKABLE STAGE-BLOB: the encode emits a content-addressed staged blob;
#       the spine PARKS on the blob PUT BEFORE the parkable append.
# (f) heap-reuse SOAK: an N-item batch (Items owning inner List[UInt8] +
#       String) parked across a SIMULATED crash/drop, asserted freed EXACTLY
#       ONCE (no double-free, no leak) — discriminating via a process-global
#       alloc/free counter on the Item's heap-owning payload.
# (g) heap-reuse SOAK — 412-RETRY-WITH-HEAP-ITEMS: heap items RE-ENCODED across >=3
#       simulated 412s (the LIVE 412-loop re-borrows the retained Slab), WON,
# freed exactly once. THE highest-value heap-reuse surface.
# (h) heap-reuse SOAK — DONE-PATH-WITH-HEAP-ITEMS: heap items flushed to a clean WON
#       append, freed exactly once on the success path.
# =============================================================================

from std.sys.info import CompilationTarget

from std.testing import assert_equal, assert_true, assert_false

from komira_core.collections.slab import Slab

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.cas_manifest import (
    AppendResult,
    AsyncManifestAppendOp,
    CasManifestStore,
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
    FLUSH_REASON_COUNT,
    FLUSH_REASON_EXPLICIT,
    FLUSH_REASON_LINGER,
    FLUSH_REASON_NONE,
    FLUSH_REASON_SIZE,
    READ_ERR_CONFLICT,
    READ_ERR_FATAL,
    READ_ERR_TORN,
    RamAccumulator,
    SpineFactory,
    _CoalesceSpine,
    _SP_PHASE_APPEND,
    _SP_PHASE_READ,
    _SP_PHASE_STAGE_BLOB,
    evaluate,
    multi_snapshot_occ_check,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import (
    CasOpProgress,
    CasReadResult,
)


comptime _Slow = SharedInMemorySlowCasStore
comptime _Shared = SharedInMemoryConditionalStore
comptime _Meta = CasManifestStore[_Shared]
# The EXACT-SLOT parkable appender drives AsyncManifestAppendOp[_Slow] over a
# CasManifestStore[_Slow] — _Slow (not _Shared) conforms to AsyncCasStore (the
# cas_put_* poll-shaped verbs the parkable create-CAS needs). The _Slow WAL
# shares the SAME inner Arc-backed map as the reader (built over slow.clone()),
# so the reader's parkable reads + the appender's create-CAS see the SAME data.
comptime _SlowMeta = CasManifestStore[_Slow]


# =============================================================================
# A process-global alloc/free ledger for the heap-reuse SOAK (discriminating).
# =============================================================================
# _PayloadLedger tracks live allocations of the heap-reuse Item's heap-owning payload.
# A double-free decrements past the value seen at construction; a leak leaves a
# nonzero live count at scope exit. Because Mojo 1.0.0b1 has no globals, the
# ledger is a heap singleton reached via a module-level accessor over an
# ArcPointer (one shared atomic-ish counter; the rig is single-threaded so plain
# Int suffices).

from std.memory import ArcPointer


struct _Ledger(Movable, Deinitable):
    var live: Int
    var total_constructed: Int
    var total_destructed: Int
    var double_free_detected: Bool

    def __init__(out self):
        self.live = 0
        self.total_constructed = 0
        self.total_destructed = 0
        self.double_free_detected = False


# The rig threads ONE _Ledger handle explicitly into the heap-reuse _HeapItem (no
# global — Mojo 1.0.0b1 has none). See test_heap_reuse_soak_parked_batch_freed_exactly_once.


# =============================================================================
# Test reactor — a real (epoll/kqueue) reactor so register_timer FIRES.
# =============================================================================
def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


# =============================================================================
# The identity SEAM conformers — every item a winner, trivial head.
# =============================================================================

# IdHead — a trivial authoritative HEAD (the chunk count the read observed).
@fieldwise_init
struct IdHead(Copyable, Movable, Deinitable):
    var seq: Int64


# IdItem — a plain Copyable item: a byte payload. Used by the unit / parked /
# 412 / timer / singleton tests (the heap-reuse soak uses _HeapItem instead).
@fieldwise_init
struct IdItem(Copyable, Movable, Deinitable):
    var byte: UInt8


# IdOutcome — the per-item result: the committed (chunk_seq, intra_batch_seq).
@fieldwise_init
struct IdOutcome(Copyable, Movable, Deinitable):
    var chunk_seq: Int64
    var intra_batch_seq: Int


# IdReader — reads a sentinel _HEAD key on a slow-CAS clone (parkable), returns
# IdHead{seq=0} (the identity codec does not condition on the head). Drives the
# park so the parked-resume + timer tests exercise the demux.
struct IdReader(AuthHeadReader, Movable, Deinitable):
    var _store: _Slow
    var _head_key: String

    def __init__(out self, var store: _Slow, var head_key: String):
        self._store = store^
        self._head_key = head_key^

    def read_head_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._store.read_start[S](Path.parse(self._head_key), reactor)

    def read_head_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._store.read_poll[S](reactor)

    def take_read(mut self) raises -> CasReadResult:
        return self._store.read_take()

    def classify_read_error(self, msg: String) -> UInt8:
        if msg.find("connect failed") >= 0 or msg.find("errno") >= 0:
            return READ_ERR_FATAL
        if (
            msg.find("412") >= 0
            or msg.find("precondition") >= 0
        ):
            return READ_ERR_CONFLICT
        return READ_ERR_TORN

    # The PARKABLE stage-blob: drive the slow-CAS clone's cas_put (If-None-Match
    # create) so the spine parks across the content-addressed PUT. The identity
    # codec never emits a staged blob (so the spine never calls these for the
    # identity tests); the BlobCodec test below DOES exercise them.
    def stage_blob_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, key: String, var bytes: List[UInt8], mut reactor: Reactor[S]
    ) raises -> CasOpProgress:
        return self._store.cas_put_start[S](
            Path.parse(key), bytes^, String(""), reactor
        )

    def stage_blob_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._store.cas_put_poll[S](reactor)

    def stage_blob_take(mut self) raises -> None:
        _ = self._store.cas_put_take()


# IdCodec — concatenates the item bytes into the body; every item a winner.
struct IdCodec(BatchCodec, Movable, Deinitable):
    comptime Item = IdItem
    comptime Head = IdHead
    comptime Outcome = IdOutcome

    def __init__(out self):
        pass

    def decode_head(mut self, var rr: CasReadResult) raises -> IdHead:
        # Identity: the head seq is irrelevant to the identity codec; report 0
        # (absent) or 1 (present sentinel) — either is fine.
        if rr.absent:
            return IdHead(seq=Int64(0))
        return IdHead(seq=Int64(1))

    def head_slot(self, ref auth: IdHead) -> Int64:
        # The exact-slot HINT (= auth_head + 1). The in-mem exact-slot appender
        # re-derives the AUTHORITATIVE slot from the WAL (read_head_authoritative)
        # so the identity codec's placeholder is fine; a real codec returns the
        # decoded head's next slot.
        return auth.seq + Int64(1)

    def estimate_bytes(self, ref it: IdItem) -> Int:
        return 1

    def encode(
        mut self, ref items: Slab[IdItem], var auth: IdHead
    ) raises -> EncodedBatch[IdOutcome]:
        var body = List[UInt8]()
        var winners = List[Int]()
        for i in range(items.len()):
            body.append(items[i].byte)
            winners.append(i)
        return EncodedBatch[IdOutcome](
            body^, Int64(items.len()), winners^
        )

    def winner_outcome(
        self, orig_idx: Int, intra_batch_seq: Int, append: AppendResult
    ) -> IdOutcome:
        return IdOutcome(
            chunk_seq=append.chunk_seq, intra_batch_seq=intra_batch_seq
        )


# =============================================================================
# SEAM 5 conformer — the in-mem EXACT-SLOT parkable appender (BatchAppender).
# =============================================================================
# The exact-slot create-CAS at auth_head+1 (the table-store OCC mode), driven over
# the REAL CasManifestStore via the in-tree parkable AsyncManifestAppendOp. At
# `append_start` it reads the WAL's AUTHORITATIVE head (read_head_authoritative —
# the chunk count + next offset) to derive the EXACT candidate slot
# (head.chunk_seq + 1) + base offset, then drives AsyncManifestAppendOp.start at
# that slot. The spine's `slot` HINT is received but the appender re-derives the
# authoritative slot itself (exactly as a real exact-slot appender couples its
# own OCC-validate-against-authoritative-head with the create-CAS — the spine's
# hint is from a Head the test reader does not track to the true count). A 412
# surfaces as a CasOpProgress.error the spine classifies LOST_SLOT -> the LIVE
# 412-loop. The in-flight create-CAS op lives INSIDE the WAL's store conformer
# across the park (the heap-reuse contract); only typed CasOpProgress / AppendOutcome
# cross the seam.
struct _ExactSlotAppender(BatchAppender, Movable, Deinitable):
    var _wal: _SlowMeta
    var _op: AsyncManifestAppendOp[_Slow]
    # Carried across the parks: the slot/base/rc the op is create-CASing at.
    var _candidate: Int64
    var _base: Int64
    var _rc: Int64
    var _inflight: Bool

    def __init__(out self, var wal: _SlowMeta):
        self._wal = wal^
        self._op = AsyncManifestAppendOp[_Slow]()
        self._candidate = Int64(0)
        self._base = Int64(0)
        self._rc = Int64(0)
        self._inflight = False

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
        # Derive the AUTHORITATIVE exact slot from the WAL (bypassing the spine's
        # hint, which the identity reader does not track to the true count).
        var head = self._wal.read_head_authoritative()
        self._candidate = head.chunk_seq + Int64(1)
        self._base = head.next_offset
        self._rc = record_count
        self._inflight = True
        return self._op.start[S](
            self._wal, self._candidate, self._base, body^, record_count, reactor
        )

    def append_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._op.poll[S](self._wal, reactor)

    def append_take(mut self) raises -> AppendOutcome:
        var r = self._op.take(self._wal)
        # A fresh op for the next attempt (a LOST_SLOT re-encode re-drives start).
        self._op = AsyncManifestAppendOp[_Slow]()
        self._inflight = False
        if r:
            return AppendOutcome.won(r.take())
        # take->None is the defense-in-depth 412 path (a deferred 412).
        return AppendOutcome.lost_slot()

    def classify_append_error(self, msg: String) -> UInt8:
        # The exact-slot mode: a 412/precondition is a real lost slot.
        if (
            msg.find("412") >= 0
            or msg.find("precondition") >= 0
            or msg.find("If-None-Match") >= 0
            or msg.find("If-Match") >= 0
        ):
            # A fresh op for the re-encode re-drive (the in-flight op is dropped).
            return APPEND_LOST_SLOT
        return APPEND_ERR


# IdFactory — mints a fresh spine over fresh clones + the identity conformers,
# over the REAL CasManifestStore via the EXACT-SLOT parkable appender (the
# happy-path / parked / timer / singleton tests). The factory holds the SHARED
# store + prefix and builds a fresh CasManifestStore (over a fresh shared-store
# clone that shares the Arc-backed map) per flush — so it never needs
# CasManifestStore.clone() (which does not exist). The 412 test uses
# FlakyFactory below.
struct IdFactory(SpineFactory, Movable, Deinitable):
    comptime Storage = _Slow
    comptime H = IdReader
    comptime C = IdCodec
    comptime A = _ExactSlotAppender
    comptime Item = IdItem

    var _slow: _Slow
    var _shared: _Shared
    var _prefix: String
    var _head_key: String

    def __init__(
        out self,
        var slow: _Slow,
        var shared: _Shared,
        var prefix: String,
        var head_key: String,
    ):
        self._slow = slow^
        self._shared = shared^
        self._prefix = prefix^
        self._head_key = head_key^

    def make_spine(
        mut self, var items: Slab[IdItem], reason: UInt8
    ) raises -> _CoalesceSpine[_Slow, IdReader, IdCodec, _ExactSlotAppender]:
        var reader = IdReader(self._slow.clone(), self._head_key.copy())
        var appender = _ExactSlotAppender(
            _SlowMeta(self._slow.clone(), self._prefix.copy())
        )
        return _CoalesceSpine[_Slow, IdReader, IdCodec, _ExactSlotAppender](
            reader^, IdCodec(), appender^, items^, reason
        )


# =============================================================================
# A flaky EXACT-SLOT appender for the 412-retry test (the LIVE 412-loop).
# =============================================================================
# Returns a simulated lost-slot 412 (a CasOpProgress.error the spine classifies
# LOST_SLOT) on the first `_fail_n` `append_start` calls — WITHOUT touching the
# store, so the slot stays free for the retry — then delegates to a real
# EXACT-SLOT create-CAS. This drives the spine's LIVE 412-loop (re-read auth +
# re-encode the SAME retained items + re-append at the new auth_head+1)
# deterministically. The factory makes ONE flaky appender per flush; the spine
# owns it across ALL its 412 re-reads (the SAME appender instance is re-driven
# per attempt), so the fail-counter persists across the retry loop. This is the
# parkable appender's key surface: the 412-loop is LIVE around the REAL
# create-CAS (a blocking append that retried INTERNALLY would never fire the
# spine's loop).
struct _FlakyAppender(BatchAppender, Movable, Deinitable):
    var _wal: _SlowMeta
    var _op: AsyncManifestAppendOp[_Slow]
    var _fail_n: Int
    var _calls: Int
    var _candidate: Int64
    var _base: Int64

    def __init__(out self, var wal: _SlowMeta, fail_n: Int):
        self._wal = wal^
        self._op = AsyncManifestAppendOp[_Slow]()
        self._fail_n = fail_n
        self._calls = 0
        self._candidate = Int64(0)
        self._base = Int64(0)

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
        self._calls += 1
        if self._calls <= self._fail_n:
            # Simulated lost-slot 412 — return ERR WITHOUT touching the store (so
            # the slot stays free for the retry). The body is dropped (a re-encode
            # rebuilds it). The spine classifies this LOST_SLOT -> the LIVE loop.
            _ = body^
            return CasOpProgress.error(
                String("precondition failed (412): simulated competitor")
            )
        var head = self._wal.read_head_authoritative()
        self._candidate = head.chunk_seq + Int64(1)
        self._base = head.next_offset
        return self._op.start[S](
            self._wal, self._candidate, self._base, body^, record_count, reactor
        )

    def append_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._op.poll[S](self._wal, reactor)

    def append_take(mut self) raises -> AppendOutcome:
        var r = self._op.take(self._wal)
        self._op = AsyncManifestAppendOp[_Slow]()
        if r:
            return AppendOutcome.won(r.take())
        return AppendOutcome.lost_slot()

    def classify_append_error(self, msg: String) -> UInt8:
        if (
            msg.find("412") >= 0
            or msg.find("precondition") >= 0
            or msg.find("If-None-Match") >= 0
            or msg.find("If-Match") >= 0
        ):
            return APPEND_LOST_SLOT
        return APPEND_ERR


# A flaky factory: holds the shared store + prefix + fail-count; builds a fresh
# _FlakyAppender (over a fresh CasManifestStore on a shared-store clone) per
# flush.
struct FlakyFactory(SpineFactory, Movable, Deinitable):
    comptime Storage = _Slow
    comptime H = IdReader
    comptime C = IdCodec
    comptime A = _FlakyAppender
    comptime Item = IdItem

    var _slow: _Slow
    var _shared: _Shared
    var _prefix: String
    var _head_key: String
    var _fail_n: Int

    def __init__(
        out self,
        var slow: _Slow,
        var shared: _Shared,
        var prefix: String,
        var head_key: String,
        fail_n: Int,
    ):
        self._slow = slow^
        self._shared = shared^
        self._prefix = prefix^
        self._head_key = head_key^
        self._fail_n = fail_n

    def make_spine(
        mut self, var items: Slab[IdItem], reason: UInt8
    ) raises -> _CoalesceSpine[_Slow, IdReader, IdCodec, _FlakyAppender]:
        var reader = IdReader(self._slow.clone(), self._head_key.copy())
        var appender = _FlakyAppender(
            _SlowMeta(self._slow.clone(), self._prefix.copy()), self._fail_n
        )
        return _CoalesceSpine[_Slow, IdReader, IdCodec, _FlakyAppender](
            reader^, IdCodec(), appender^, items^, reason
        )


# =============================================================================
# rig builders
# =============================================================================
def _new_meta(slow: _Slow, prefix: String) raises -> _Meta:
    """Build a CasManifestStore over the slow store's shared inner map (so the
    reader's parkable reads + the meta's appends see the SAME data)."""
    return _Meta(slow.inner_ref().clone(), prefix)


def _new_window(
    var slow: _Slow, prefix: String, policy: FlushPolicy, head_key: String
) raises -> CoalescingWindow[IdFactory]:
    # The factory holds the shared store (a clone of the slow store's inner map,
    # so the reader + meta share data) + the prefix; it builds a fresh meta per
    # flush.
    var shared = slow.inner_ref().clone()
    var factory = IdFactory(slow.clone(), shared^, prefix, head_key)
    return CoalescingWindow[IdFactory](
        RamAccumulator[IdItem](), policy, factory^
    )


def _new_flaky_window(
    var slow: _Slow,
    prefix: String,
    fail_n: Int,
    policy: FlushPolicy,
    head_key: String,
) raises -> CoalescingWindow[FlakyFactory]:
    var shared = slow.inner_ref().clone()
    var factory = FlakyFactory(slow.clone(), shared^, prefix, head_key, fail_n)
    return CoalescingWindow[FlakyFactory](
        RamAccumulator[IdItem](), policy, factory^
    )


# =============================================================================
# A STAGE-BLOB codec + factory — exercises the PARKABLE stage-blob phase.
# =============================================================================
# BlobCodec emits a content-addressed staged blob (the FULL EncodedBatch ctor),
# so the spine drives the PARKABLE STAGE_BLOB phase (the reader's
# stage_blob_start/poll/take over the slow-CAS clone) BEFORE the append. The blob
# key is content-addressed (a fixed test key); a 2nd flush of the SAME bytes
# would 412 on the If-None-Match (idempotent WIN the conformer reports READY).
struct BlobCodec(BatchCodec, Movable, Deinitable):
    comptime Item = IdItem
    comptime Head = IdHead
    comptime Outcome = IdOutcome

    var _blob_key: String

    def __init__(out self, var blob_key: String):
        self._blob_key = blob_key^

    def decode_head(mut self, var rr: CasReadResult) raises -> IdHead:
        if rr.absent:
            return IdHead(seq=Int64(0))
        return IdHead(seq=Int64(1))

    def head_slot(self, ref auth: IdHead) -> Int64:
        return auth.seq + Int64(1)

    def estimate_bytes(self, ref it: IdItem) -> Int:
        return 1

    def encode(
        mut self, ref items: Slab[IdItem], var auth: IdHead
    ) raises -> EncodedBatch[IdOutcome]:
        # The manifest body just references the blob (here: the item bytes); the
        # staged blob carries the bulk payload. Emit BOTH via the FULL ctor.
        var body = List[UInt8]()
        var blob = List[UInt8]()
        var winners = List[Int]()
        for i in range(items.len()):
            body.append(items[i].byte)
            blob.append(items[i].byte)
            blob.append(items[i].byte)  # the blob is "bigger" than the body.
            winners.append(i)
        return EncodedBatch[IdOutcome](
            body^,
            Int64(items.len()),
            Optional[List[UInt8]](blob^),
            self._blob_key.copy(),
            Int64(0),
            Int64(0),
            List[Tuple[Int, IdOutcome]](),
            winners^,
        )

    def winner_outcome(
        self, orig_idx: Int, intra_batch_seq: Int, append: AppendResult
    ) -> IdOutcome:
        return IdOutcome(
            chunk_seq=append.chunk_seq, intra_batch_seq=intra_batch_seq
        )


struct BlobFactory(SpineFactory, Movable, Deinitable):
    comptime Storage = _Slow
    comptime H = IdReader
    comptime C = BlobCodec
    comptime A = _ExactSlotAppender
    comptime Item = IdItem

    var _slow: _Slow
    var _shared: _Shared
    var _prefix: String
    var _head_key: String
    var _blob_key: String

    def __init__(
        out self,
        var slow: _Slow,
        var shared: _Shared,
        var prefix: String,
        var head_key: String,
        var blob_key: String,
    ):
        self._slow = slow^
        self._shared = shared^
        self._prefix = prefix^
        self._head_key = head_key^
        self._blob_key = blob_key^

    def make_spine(
        mut self, var items: Slab[IdItem], reason: UInt8
    ) raises -> _CoalesceSpine[_Slow, IdReader, BlobCodec, _ExactSlotAppender]:
        var reader = IdReader(self._slow.clone(), self._head_key.copy())
        var appender = _ExactSlotAppender(
            _SlowMeta(self._slow.clone(), self._prefix.copy())
        )
        return _CoalesceSpine[_Slow, IdReader, BlobCodec, _ExactSlotAppender](
            reader^, BlobCodec(self._blob_key.copy()), appender^, items^, reason
        )


# =============================================================================
# (a) UNIT — FlushPolicy.evaluate per branch.
# =============================================================================
def test_evaluate_empty_is_none() raises:
    var p = FlushPolicy(max_bytes=10, max_ms=Int64(5), max_count=3)
    var v = evaluate(p, 0, 0, Int64(0), Int64(100))
    assert_false(v.flushes(), "empty buffer never flushes")
    assert_equal(Int(v.reason), Int(FLUSH_REASON_NONE), "empty -> NONE")
    print("  test_evaluate_empty_is_none: PASS")


def test_evaluate_size_band() raises:
    var p = FlushPolicy.size_only(max_bytes=8)
    var below = evaluate(p, 3, 7, Int64(0), Int64(0))
    assert_false(below.flushes(), "7 < 8 below size band")
    var at = evaluate(p, 3, 8, Int64(0), Int64(0))
    assert_true(at.flushes(), "8 >= 8 crosses size band")
    assert_equal(Int(at.reason), Int(FLUSH_REASON_SIZE), "SIZE reason")
    print("  test_evaluate_size_band: PASS")


def test_evaluate_count_band() raises:
    var p = FlushPolicy.count_only(max_count=4)
    var below = evaluate(p, 3, 0, Int64(0), Int64(0))
    assert_false(below.flushes(), "3 < 4 below count band")
    var at = evaluate(p, 4, 0, Int64(0), Int64(0))
    assert_true(at.flushes(), "4 >= 4 crosses count band")
    assert_equal(Int(at.reason), Int(FLUSH_REASON_COUNT), "COUNT reason")
    print("  test_evaluate_count_band: PASS")


def test_evaluate_linger_band() raises:
    var p = FlushPolicy.linger_only(max_ms=Int64(50))
    # oldest at t=100, now t=140 -> aged 40 < 50: no flush.
    var below = evaluate(p, 2, 0, Int64(100), Int64(140))
    assert_false(below.flushes(), "aged 40 < 50 below linger band")
    # now t=150 -> aged 50 >= 50: flush.
    var at = evaluate(p, 2, 0, Int64(100), Int64(150))
    assert_true(at.flushes(), "aged 50 >= 50 crosses linger band")
    assert_equal(Int(at.reason), Int(FLUSH_REASON_LINGER), "LINGER reason")
    print("  test_evaluate_linger_band: PASS")


def test_evaluate_first_fires_wins() raises:
    # Size AND count both crossable; SIZE is checked first so it wins.
    var p = FlushPolicy(max_bytes=2, max_ms=Int64(0), max_count=2)
    var v = evaluate(p, 5, 5, Int64(0), Int64(0))
    assert_true(v.flushes(), "both bands crossed -> flush")
    assert_equal(
        Int(v.reason), Int(FLUSH_REASON_SIZE), "SIZE checked first wins"
    )
    print("  test_evaluate_first_fires_wins: PASS")


def test_evaluate_disabled_bands() raises:
    # All thresholds 0 -> every band disabled -> never flushes (even non-empty).
    var p = FlushPolicy(max_bytes=0, max_ms=Int64(0), max_count=0)
    var v = evaluate(p, 100, 1_000_000, Int64(0), Int64(999_999))
    assert_false(v.flushes(), "all bands disabled -> never flushes")
    print("  test_evaluate_disabled_bands: PASS")


# =============================================================================
# (b) parked-resume CORRECTNESS — offer N, park on slow-CAS, poll to done, all
#     N get outcomes, the chunk lands ONCE.
# =============================================================================
def test_parked_resume_all_outcomes_one_chunk() raises:
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=2)  # the read parks twice before completing.
    var policy = FlushPolicy.count_only(max_count=4)
    var win = _new_window(
        slow.clone(), String("cw-parked"), policy, String("cw-parked/_HEAD")
    )

    # Offer 4 items (the 4th crosses the count band -> a flush starts + parks).
    var op = Int64(0)
    for i in range(4):
        op = win.offer[NoopSink](
            IdItem(byte=UInt8(i)), 1, Int64(0), Int64(0), reactor
        )
    assert_true(win.is_inflight(), "the 4th offer started a flush")
    assert_true(op != Int64(0), "the flush parked on a biased op_id")

    # Drive the parked flush to completion (the reactor fires the read timers).
    var guard = 0
    while win.is_inflight() and guard < 64:
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        guard += 1
    assert_false(win.is_inflight(), "the parked flush completed")
    assert_false(win.has_error(), "no error: " + win.err_text())

    var outcomes = win.take_outcomes()
    assert_equal(len(outcomes), 4, "all 4 items got an outcome")
    # All 4 outcomes share ONE chunk_seq (they landed in ONE append).
    var seq0 = outcomes[0][1].chunk_seq
    for i in range(4):
        assert_equal(
            outcomes[i][1].chunk_seq, seq0, "all items share one chunk_seq"
        )
        assert_equal(
            Int(outcomes[i][1].intra_batch_seq), i, "intra-batch seq preserved"
        )

    # The chunk landed EXACTLY ONCE.
    var meta_check = _new_meta(slow, String("cw-parked"))
    assert_equal(
        Int(meta_check.num_chunks()), 1, "exactly one chunk committed"
    )
    print("  test_parked_resume_all_outcomes_one_chunk: PASS")


# =============================================================================
# (c) 412-retry — a flaky meta raises 412 K times -> the spine re-reads /
#     re-encodes / retries (bounded) and converges.
# =============================================================================
def test_412_retry_converges() raises:
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)  # instant reads so the focus is the append.
    var policy = FlushPolicy.count_only(max_count=2)
    var win = _new_flaky_window(
        slow.clone(), String("cw-412"), 3, policy, String("cw-412/_HEAD")
    )  # 3 x 412 then succeed.

    var op = Int64(0)
    for i in range(2):
        op = win.offer[NoopSink](
            IdItem(byte=UInt8(i)), 1, Int64(0), Int64(0), reactor
        )

    # With instant reads the spine's 412 re-read loop runs synchronously within
    # the offer's start burst (each re-read is READY immediately), so the flush
    # converges in the start burst -> not in flight, no error.
    var guard = 0
    while win.is_inflight() and guard < 512:
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        guard += 1
    assert_false(win.is_inflight(), "the flush converged")
    assert_false(
        win.has_error(),
        "the 412 retry converged within the bound: " + win.err_text(),
    )
    var outcomes = win.take_outcomes()
    assert_equal(len(outcomes), 2, "both items got an outcome after retries")

    var meta_check = _new_meta(slow, String("cw-412"))
    assert_equal(
        Int(meta_check.num_chunks()), 1, "exactly one chunk despite 3 x 412"
    )
    print("  test_412_retry_converges: PASS")


# =============================================================================
# (d) timer-deadline SELF-FIRES — a lone buffered item with max_ms flushes on
#     the reactor timer with NO further offer.
# =============================================================================
def test_timer_self_fires() raises:
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)
    # max_ms small; no size/count band -> ONLY the linger timer can flush.
    var policy = FlushPolicy.linger_only(max_ms=Int64(1))
    var win = _new_window(
        slow.clone(), String("cw-timer"), policy, String("cw-timer/_HEAD")
    )

    # ONE offer; the count/size bands are disabled so it does NOT flush now, but
    # the offer ARMS the linger timer.
    var op = win.offer[NoopSink](
        IdItem(byte=UInt8(7)), 1, Int64(0), Int64(0), reactor
    )
    assert_false(win.is_inflight(), "no immediate flush (only linger armed)")
    assert_true(win.timer_op_id() != Int64(0), "the linger timer is armed")
    assert_equal(win.pending_count(), 1, "the lone item is buffered")

    # NO further offer. Drive the reactor; the timer fires -> on_deadline ->
    # a LINGER flush. now_ms is past the deadline.
    var armed = win.timer_op_id()
    var guard = 0
    var flushed = False
    while not flushed and guard < 64:
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == armed:
                # The timer fired: route it to on_deadline (the self-fire).
                _ = win.on_deadline[NoopSink](armed, Int64(1000), reactor)
                flushed = True
        guard += 1
    assert_true(flushed, "the linger timer self-fired")
    # Drive any park from the flush to completion.
    var g2 = 0
    while win.is_inflight() and g2 < 64:
        var ready2 = reactor.poll_completions(-1)
        for k in range(len(ready2)):
            if ready2[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        g2 += 1
    assert_false(win.is_inflight(), "the timer-fired flush completed")
    assert_false(win.has_error(), "no error: " + win.err_text())
    var outcomes = win.take_outcomes()
    assert_equal(len(outcomes), 1, "the lone item flushed on the timer")
    assert_equal(
        Int(win.last_flush_reason()),
        Int(FLUSH_REASON_LINGER),
        "the flush reason is LINGER (timer self-fire)",
    )
    print("  test_timer_self_fires: PASS")


# =============================================================================
# (e) the singleton fast-path — 1-item EXPLICIT force.
# =============================================================================
def test_singleton_explicit_fast_path() raises:
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)
    var policy = FlushPolicy.count_only(max_count=1000)  # never auto-flushes.
    var win = _new_window(
        slow.clone(),
        String("cw-singleton"),
        policy,
        String("cw-singleton/_HEAD"),
    )

    # Buffer exactly one item; the count band is far from firing.
    _ = win.offer[NoopSink](
        IdItem(byte=UInt8(42)), 1, Int64(0), Int64(0), reactor
    )
    assert_false(win.is_inflight(), "no auto-flush (count band far off)")
    assert_equal(win.pending_count(), 1, "exactly one buffered (singleton)")

    # EXPLICIT force -> the singleton fast path.
    var op = win.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    var guard = 0
    while win.is_inflight() and guard < 64:
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        guard += 1
    assert_false(win.is_inflight(), "the singleton flush completed")
    assert_false(win.has_error(), "no error: " + win.err_text())
    var outcomes = win.take_outcomes()
    assert_equal(len(outcomes), 1, "the singleton committed")
    assert_equal(
        Int(win.last_flush_reason()),
        Int(FLUSH_REASON_EXPLICIT),
        "the flush reason is EXPLICIT (forced)",
    )
    assert_equal(Int(outcomes[0][1].intra_batch_seq), 0, "singleton seq 0")
    print("  test_singleton_explicit_fast_path: PASS")


# =============================================================================
# (e2) PARKABLE STAGE-BLOB — the encode emits a staged blob; the spine PARKS on
#      the content-addressed blob PUT (slow-CAS) BEFORE the append.
# =============================================================================
def test_parkable_stage_blob_then_append() raises:
    """The BlobCodec emits a content-addressed staged blob, so the spine drives
    the PARKABLE STAGE_BLOB phase (the reader's stage_blob_start/poll over the
    slow-CAS clone) BEFORE the PARKABLE append. With slow_ticks=2 BOTH the read
    AND the stage-blob AND the append park; the flush converges over multiple
    poll cycles, the blob lands durably, and the chunk lands once."""
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=2)  # read + stage-blob + append all park.
    var policy = FlushPolicy.count_only(max_count=3)
    var shared = slow.inner_ref().clone()
    var factory = BlobFactory(
        slow.clone(),
        shared^,
        String("cw-blob"),
        String("cw-blob/_HEAD"),
        String("cw-blob/blobs/content-addressed-key"),
    )
    var win = CoalescingWindow[BlobFactory](
        RamAccumulator[IdItem](), policy, factory^
    )
    var op = Int64(0)
    for i in range(3):
        op = win.offer[NoopSink](
            IdItem(byte=UInt8(i + 1)), 1, Int64(0), Int64(0), reactor
        )
    assert_true(win.is_inflight(), "the 3rd offer started a flush")
    assert_true(op != Int64(0), "the flush parked (read -> stage-blob -> append)")

    var guard = 0
    while win.is_inflight() and guard < 128:
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        guard += 1
    assert_false(win.is_inflight(), "the stage-blob+append flush completed")
    assert_false(win.has_error(), "no error: " + win.err_text())
    var outcomes = win.take_outcomes()
    assert_equal(len(outcomes), 3, "all 3 items got an outcome")

    # The staged blob landed durably (content-addressed key present).
    var probe = slow.inner_ref().clone()
    var blob = probe.get(Path.parse("cw-blob/blobs/content-addressed-key"))
    assert_equal(len(blob), 6, "the staged blob (2 bytes/item x 3 items) is durable")

    # The chunk landed EXACTLY once.
    var meta_check = _new_meta(slow, String("cw-blob"))
    assert_equal(Int(meta_check.num_chunks()), 1, "exactly one chunk committed")
    print("  test_parkable_stage_blob_then_append: PASS")


# =============================================================================
# (f) heap-reuse SOAK — an N-item batch (Items owning inner List[UInt8] +
#     String) parked across a SIMULATED crash/drop, freed EXACTLY ONCE.
# =============================================================================
# _HeapItem owns a heap List[UInt8] + a String + a ledger handle. Its __init__
# bumps total_constructed + live; its __del__ bumps total_destructed + decrements
# live and FLAGS a double-free if live would go negative. After the batch is
# parked then DROPPED (the window destructed mid-flight, the crash sim), the
# ledger MUST show live==0 (every constructed item freed) and NO double-free.


struct _HeapItem(Movable, Deinitable):
    var payload: List[UInt8]  # heap-owning inner field (heap-reuse shape).
    var label: String  # second heap-owning inner field.
    var _ledger: ArcPointer[_Ledger]

    def __init__(out self, n: Int, var label: String, ledger: ArcPointer[_Ledger]):
        var p = List[UInt8]()
        for i in range(n):
            p.append(UInt8(i & 0xFF))
        self.payload = p^
        self.label = label^
        self._ledger = ledger
        self._ledger[].total_constructed += 1
        self._ledger[].live += 1

    # NOTE: NO custom __moveinit__ — the COMPILER-SYNTHESIZED fieldwise move
    # transfers the heap fields WITHOUT running __init__ or __del__, so a move
    # (buffer -> spine -> retained Slab) does NOT touch the ledger. The ledger is
    # bumped exactly once at __init__ (construction) and decremented exactly once
    # at __del__ (the value's true end-of-life). That is precisely the
    # exactly-once-free property the soak asserts. A custom __moveinit__ would be
    # a hazard (and Mojo 1.0.0b1 rejects accessing `deinit other`'s fields).

    def __deinit__(deinit self):
        # The heap fields drop here exactly once. Decrement live; flag a
        # double-free if it would go negative (it never should).
        self._ledger[].total_destructed += 1
        if self._ledger[].live <= 0:
            self._ledger[].double_free_detected = True
        else:
            self._ledger[].live -= 1


# A heap-reuse codec over _HeapItem: every item a winner; the body concatenates each
# item's payload. _HeapItem is Movable-NOT-Copyable (it owns Lists) so it can
# only live in a Slab (not a List) — the heap-reuse storage contract.
struct HeapCodec(BatchCodec, Movable, Deinitable):
    comptime Item = _HeapItem
    comptime Head = IdHead
    comptime Outcome = IdOutcome

    def __init__(out self):
        pass

    def decode_head(mut self, var rr: CasReadResult) raises -> IdHead:
        if rr.absent:
            return IdHead(seq=Int64(0))
        return IdHead(seq=Int64(1))

    def head_slot(self, ref auth: IdHead) -> Int64:
        return auth.seq + Int64(1)

    def estimate_bytes(self, ref it: _HeapItem) -> Int:
        return len(it.payload)

    def encode(
        mut self, ref items: Slab[_HeapItem], var auth: IdHead
    ) raises -> EncodedBatch[IdOutcome]:
        var body = List[UInt8]()
        var winners = List[Int]()
        for i in range(items.len()):
            ref it = items[i]
            for j in range(len(it.payload)):
                body.append(it.payload[j])
            winners.append(i)
        return EncodedBatch[IdOutcome](body^, Int64(items.len()), winners^)

    def winner_outcome(
        self, orig_idx: Int, intra_batch_seq: Int, append: AppendResult
    ) -> IdOutcome:
        return IdOutcome(
            chunk_seq=append.chunk_seq, intra_batch_seq=intra_batch_seq
        )


struct HeapFactory(SpineFactory, Movable, Deinitable):
    comptime Storage = _Slow
    comptime H = IdReader
    comptime C = HeapCodec
    comptime A = _ExactSlotAppender
    comptime Item = _HeapItem

    var _slow: _Slow
    var _shared: _Shared
    var _prefix: String
    var _head_key: String

    def __init__(
        out self,
        var slow: _Slow,
        var shared: _Shared,
        var prefix: String,
        var head_key: String,
    ):
        self._slow = slow^
        self._shared = shared^
        self._prefix = prefix^
        self._head_key = head_key^

    def make_spine(
        mut self, var items: Slab[_HeapItem], reason: UInt8
    ) raises -> _CoalesceSpine[_Slow, IdReader, HeapCodec, _ExactSlotAppender]:
        var reader = IdReader(self._slow.clone(), self._head_key.copy())
        var appender = _ExactSlotAppender(
            _SlowMeta(self._slow.clone(), self._prefix.copy())
        )
        return _CoalesceSpine[_Slow, IdReader, HeapCodec, _ExactSlotAppender](
            reader^, HeapCodec(), appender^, items^, reason
        )


# HeapFlakyFactory — HeapCodec (heap-owning Items) + the FLAKY exact-slot
# appender (N simulated 412s then a real win). The 412-retry-with-heap-items
# heap-reuse soak: the spine RE-ENCODES the SAME retained heap items across each 412,
# re-borrowing the retained Slab — the highest-value heap-reuse surface now that the
# append parks + the 412-loop is live around the REAL create-CAS.
struct HeapFlakyFactory(SpineFactory, Movable, Deinitable):
    comptime Storage = _Slow
    comptime H = IdReader
    comptime C = HeapCodec
    comptime A = _FlakyAppender
    comptime Item = _HeapItem

    var _slow: _Slow
    var _shared: _Shared
    var _prefix: String
    var _head_key: String
    var _fail_n: Int

    def __init__(
        out self,
        var slow: _Slow,
        var shared: _Shared,
        var prefix: String,
        var head_key: String,
        fail_n: Int,
    ):
        self._slow = slow^
        self._shared = shared^
        self._prefix = prefix^
        self._head_key = head_key^
        self._fail_n = fail_n

    def make_spine(
        mut self, var items: Slab[_HeapItem], reason: UInt8
    ) raises -> _CoalesceSpine[_Slow, IdReader, HeapCodec, _FlakyAppender]:
        var reader = IdReader(self._slow.clone(), self._head_key.copy())
        var appender = _FlakyAppender(
            _SlowMeta(self._slow.clone(), self._prefix.copy()), self._fail_n
        )
        return _CoalesceSpine[_Slow, IdReader, HeapCodec, _FlakyAppender](
            reader^, HeapCodec(), appender^, items^, reason
        )


def _build_offer_force_and_assert_retained(
    n: Int, ledger: ArcPointer[_Ledger]
) raises -> Int:
    """Build a window over the slow store, offer `n` heap items, FORCE a flush
    that PARKS on the slow read, assert the parked batch RETAINS all `n` items
    (live >= n) WHILE `win` is provably alive (this function's scope holds it),
    then RETURN — at which point `win` (owning the parked spine behind the single
    OwnedPointer frame) is dropped: the SIMULATED CRASH mid-flight. The
    parked-spine teardown frees every retained item exactly once.

    The retained-count assertion MUST live here (not at the caller) because Mojo
    ASAP-destruction drops `win` right after its last in-line use; keeping the
    assertion inside this scope guarantees `win` is alive at the measurement."""
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=4)  # the read parks 4 times (stays parked).
    var shared = slow.inner_ref().clone()
    var policy = FlushPolicy.count_only(max_count=n + 5)  # no auto-flush.
    var factory = HeapFactory(
        slow.clone(), shared^, String("cw-soak"), String("cw-soak/_HEAD")
    )
    var win = CoalescingWindow[HeapFactory](
        RamAccumulator[_HeapItem](), policy, factory^
    )
    var op = Int64(0)
    for i in range(n):
        op = win.offer[NoopSink](
            _HeapItem(16, String("item-") + String(i), ledger),
            16,
            Int64(0),
            Int64(0),
            reactor,
        )
    # FORCE the flush (parks on the slow read; the batch is retained in the spine).
    op = win.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    _ = op
    assert_true(win.is_inflight(), "the flush is parked mid-flight")
    # Measure the retained-item count WHILE win is alive (it survives to the
    # function's end-of-scope drop = the simulated crash).
    var live = ledger[].live
    assert_true(
        live >= n,
        "the parked batch retains all n items (live >= n) before the crash",
    )
    assert_equal(
        win.debug_inflight_item_count(),
        n,
        "the parked spine holds all n items in its retained Slab",
    )
    return live
    # `win` drops HERE (function return) — the crash; the parked spine's teardown
    # frees every retained _HeapItem exactly once.


def test_heap_reuse_soak_parked_batch_freed_exactly_once() raises:
    """heap-reuse SOAK. An N-item batch of heap-owning Items is parked on a
    slow-CAS read, then the whole window is DROPPED mid-flight (the simulated
    crash / cross-thread drop). The ledger must show every constructed item
    freed EXACTLY ONCE — no leak (live != 0), and the ledger's own balance check
    (constructed == destructed) holds.

    THE DOUBLE-FREE SIGNAL — read this carefully: the `double_free_detected`
    ledger flag catches a double-RUN of `_HeapItem.__del__` (live would go
    negative). But the canonical heap-reuse UAF is an EARLY-DROP of the inner
    `List[UInt8]` buffer (the wildcard-origin ASAP-destruction firing on the
    INNER heap field while the outer _HeapItem value is still live), which frees
    the inner buffer's bytes WITHOUT re-running _HeapItem.__del__ — that surfaces
    as a tcmalloc PROCESS CRASH (double-free / heap corruption at the allocator),
    NOT as a flip of this Mojo-level flag. So the flag + the live==0 +
    constructed==destructed checks are the in-process DISCRIMINATORS for the
    re-run double-free + the leak, and the process completing without a tcmalloc
    abort is the discriminator for the inner-buffer early-drop. A wildcard-origin
    byte-slab regression (storing _HeapItem behind a wildcard cast) would either
    crash the process (inner early-drop) or flip the flag (re-run)."""
    var N = 32
    var ledger = ArcPointer[_Ledger](_Ledger())

    # Build the window, offer N heap items, FORCE a flush that PARKS on the slow
    # read, assert the batch is retained (live >= N) WHILE win is alive, then
    # CRASH-DROP win mid-flight via `_crash_drop_heap_window` (which consumes win
    # -> its destructor runs the parked-spine teardown). Because Mojo
    # ASAP-destruction would otherwise drop `win` right after its last in-line
    # use, the retained-count assertion lives INSIDE the build helper (which
    # returns the live count while win is provably still alive), and the explicit
    # consume makes the crash deterministic.
    var live_after_park = _build_offer_force_and_assert_retained(
        N, ledger
    )
    # The build helper consumed (dropped) the window mid-flight inside itself, so
    # by here the parked spine's teardown has run.
    _ = live_after_park

    # After the window dropped mid-flight: every constructed item is freed
    # EXACTLY once (live == 0), and NO double-free was detected.
    assert_false(
        ledger[].double_free_detected,
        "NO double-free of any _HeapItem inner heap field (the heap-reuse signature)",
    )
    assert_equal(
        ledger[].live,
        0,
        "every constructed _HeapItem freed exactly once (no leak): live==0",
    )
    assert_equal(
        ledger[].total_constructed,
        ledger[].total_destructed,
        "constructed == destructed (balanced — exactly-once free)",
    )
    assert_true(
        ledger[].total_constructed >= N,
        "at least N items were constructed before the crash",
    )
    print("  test_heap_reuse_soak_parked_batch_freed_exactly_once: PASS")


# =============================================================================
# (g) heap-reuse SOAK — 412-RETRY-WITH-HEAP-ITEMS (the highest-value surface).
# =============================================================================
# An N-item batch of heap-owning Items is RE-ENCODED across >=3 simulated 412s
# (the LIVE 412-loop re-borrows the SAME retained Slab each attempt), then WON.
# The ledger MUST show every constructed item freed EXACTLY once at the end —
# the re-encode must NOT move-out / double-free any retained item (encode borrows
# by ref; a regression that consumed the items on the FIRST encode would leave
# the 2nd re-encode reading freed memory -> the heap-reuse UAF, surfacing as a tcmalloc
# crash OR — for a re-run __del__ — the double_free flag). This is THE highest-
# value heap-reuse surface: the parkable append makes the 412-loop live around
# the real create-CAS, so the re-encode-re-borrow path actually fires under test.
def test_heap_reuse_412_retry_heap_items_freed_exactly_once() raises:
    """heap-reuse SOAK — 412 RE-ENCODE with heap items. An N-item heap batch is
    re-encoded across `fail_n` simulated 412s (the LIVE 412-loop re-borrows the
    retained Slab each time) and finally WON. Every constructed item is freed
    EXACTLY once on the WON path; no double-free, no leak, no tcmalloc crash.

    DISCRIMINATING: the spine's encode BORROWS the retained items by ref (never
    moves them out), so the retained Slab survives every re-encode. A regression
    that consumed the items on encode would, on the 2nd re-encode, read freed
    memory (the inner List[UInt8] already dropped) -> a tcmalloc heap-corruption
    crash; a regression that re-ran __del__ per re-encode would flip the
    double-free flag and leave constructed != destructed."""
    var N = 24
    var fail_n = 3
    var ledger = ArcPointer[_Ledger](_Ledger())

    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)  # instant reads -> the 412-loop runs in burst.
    var shared = slow.inner_ref().clone()
    var policy = FlushPolicy.count_only(max_count=N + 5)  # no auto-flush.
    var factory = HeapFlakyFactory(
        slow.clone(),
        shared^,
        String("cw-soak-412"),
        String("cw-soak-412/_HEAD"),
        fail_n,
    )
    var win = CoalescingWindow[HeapFlakyFactory](
        RamAccumulator[_HeapItem](), policy, factory^
    )
    for i in range(N):
        _ = win.offer[NoopSink](
            _HeapItem(16, String("item-") + String(i), ledger),
            16,
            Int64(0),
            Int64(0),
            reactor,
        )
    # FORCE the flush. With instant reads + the simulated-412 appender, the spine
    # re-reads + RE-ENCODES the retained heap Slab `fail_n` times within the start
    # burst, then the real create-CAS wins.
    _ = win.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    var guard = 0
    while win.is_inflight() and guard < 512:
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        guard += 1
    assert_false(win.is_inflight(), "the 412-retry flush converged")
    assert_false(
        win.has_error(),
        "the 412-retry-with-heap-items converged: " + win.err_text(),
    )
    var outcomes = win.take_outcomes()
    assert_equal(
        len(outcomes), N, "all N heap items got an outcome after the 412 retries"
    )
    # The chunk landed EXACTLY once (the 412s did not double-commit).
    var meta_check = _new_meta(slow, String("cw-soak-412"))
    assert_equal(
        Int(meta_check.num_chunks()),
        1,
        "exactly one chunk despite the 412 re-encodes",
    )
    # Drop the window (drains the outcomes' lifetime); then assert the ledger.
    _ = win^
    _ = outcomes^

    # Every constructed item freed EXACTLY once (the re-encodes did not
    # double-free / leak any retained heap item).
    assert_false(
        ledger[].double_free_detected,
        "NO double-free across the 412 re-encodes (the heap-reuse signature)",
    )
    assert_equal(
        ledger[].live, 0, "every _HeapItem freed exactly once after the WON path"
    )
    assert_equal(
        ledger[].total_constructed,
        ledger[].total_destructed,
        "constructed == destructed across the 412 re-encodes",
    )
    assert_true(
        ledger[].total_constructed >= N, "at least N items constructed"
    )
    print("  test_heap_reuse_412_retry_heap_items_freed_exactly_once: PASS")


# =============================================================================
# (h) heap-reuse SOAK — DONE-PATH-WITH-HEAP-ITEMS (the success-path free).
# =============================================================================
# An N-item heap batch is flushed to a clean WON append (no 412, no crash) and
# the items are asserted freed EXACTLY once on the SUCCESS path. The
# complement of the parked-then-dropped soak (f) and the 412-re-encode soak (g):
# this exercises the WON _finish_append path, where the spine builds the per-item
# outcomes from the stashed batch's winner_idxs (the items themselves are dropped
# when the retained _items Slab drops at the spine's end-of-life).
def test_heap_reuse_done_path_heap_items_freed_exactly_once() raises:
    """heap-reuse SOAK — the WON / DONE path. An N-item heap batch flushes cleanly to a
    won append; every constructed item is freed EXACTLY once on the success path.

    DISCRIMINATING: on the WON path the spine builds outcomes from the stashed
    batch's winner_idxs (a copy of small POD idxs), and the retained _HeapItem
    Slab drops once when the spine ends. A regression that double-dropped the
    retained Slab (e.g. taking the batch's body AND the items) would flip the
    flag / crash; a leak (forgetting to drop the retained Slab on DONE) leaves
    live != 0."""
    var N = 20
    var ledger = ArcPointer[_Ledger](_Ledger())

    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)  # instant reads + instant append -> burst WON.
    var shared = slow.inner_ref().clone()
    var policy = FlushPolicy.count_only(max_count=N + 5)  # no auto-flush.
    var factory = HeapFactory(
        slow.clone(),
        shared^,
        String("cw-soak-done"),
        String("cw-soak-done/_HEAD"),
    )
    var win = CoalescingWindow[HeapFactory](
        RamAccumulator[_HeapItem](), policy, factory^
    )
    for i in range(N):
        _ = win.offer[NoopSink](
            _HeapItem(16, String("item-") + String(i), ledger),
            16,
            Int64(0),
            Int64(0),
            reactor,
        )
    # FORCE the flush — instant reads + instant append -> WON in the start burst.
    _ = win.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    var guard = 0
    while win.is_inflight() and guard < 64:
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        guard += 1
    assert_false(win.is_inflight(), "the DONE-path flush completed")
    assert_false(win.has_error(), "no error on the DONE path: " + win.err_text())
    var outcomes = win.take_outcomes()
    assert_equal(len(outcomes), N, "all N heap items got an outcome on DONE")
    var meta_check = _new_meta(slow, String("cw-soak-done"))
    assert_equal(Int(meta_check.num_chunks()), 1, "exactly one chunk on DONE")
    # Drop the window + outcomes; then assert the ledger.
    _ = win^
    _ = outcomes^

    assert_false(
        ledger[].double_free_detected,
        "NO double-free on the WON / DONE path (the heap-reuse signature)",
    )
    assert_equal(
        ledger[].live, 0, "every _HeapItem freed exactly once on the DONE path"
    )
    assert_equal(
        ledger[].total_constructed,
        ledger[].total_destructed,
        "constructed == destructed on the DONE path",
    )
    assert_true(
        ledger[].total_constructed >= N, "at least N items constructed"
    )
    print("  test_heap_reuse_done_path_heap_items_freed_exactly_once: PASS")


# =============================================================================
# (i) heap-reuse SOAK — CRASH-DROP PARKED-ON-WRITE (the carried-across-park teardown surface).
# =============================================================================
# THE CARRIED-ACROSS-PARK TEARDOWN SURFACE: the write side PARKS, so between ENCODE
# and the WON/LOST append the spine retains the carried-across-park `_pending`
# (a heap-owning EncodedBatch — its body + its staged blob) AND the `_items`
# Slab of heap-owning Items, BOTH behind the single OwnedPointer frame. Soak (f)
# crash-drops while parked on the READ (where `_pending` is still None). This
# soak crash-drops while parked MID-WRITE (STAGE_BLOB and/or APPEND) with
# `_pending = Some`, so the teardown of the carried `_pending` (heap body +
# staged blob) is exercised ALONGSIDE the retained `_items` Slab — the surface
# the parkable append creates. Asserts freed-exactly-once via the
# ledger (live==0, constructed==destructed, no double-free).
#
# To land the drop mid-WRITE we use a STAGE-BLOB-emitting codec over heap Items
# (HeapBlobCodec) so the spine drives READ -> STAGE_BLOB -> APPEND, and a
# slow-CAS store tuned so the READ parks; the helper drives exactly enough poll
# cycles to complete the READ + start the STAGE_BLOB park (`_pending` now Some),
# asserts the spine is parked on STAGE_BLOB (or APPEND) with `_pending` engaged
# WHILE win is provably alive, then RETURNS — dropping `win` (the parked spine
# behind the frame) mid-WRITE: the simulated crash.


# HeapBlobCodec — heap-owning _HeapItem + emits a content-addressed staged blob
# (the FULL EncodedBatch ctor) so the spine drives the PARKABLE STAGE_BLOB phase.
# The combination soak f (heap items) + e2 (staged blob) exercises here.
struct HeapBlobCodec(BatchCodec, Movable, Deinitable):
    comptime Item = _HeapItem
    comptime Head = IdHead
    comptime Outcome = IdOutcome

    var _blob_key: String

    def __init__(out self, var blob_key: String):
        self._blob_key = blob_key^

    def decode_head(mut self, var rr: CasReadResult) raises -> IdHead:
        if rr.absent:
            return IdHead(seq=Int64(0))
        return IdHead(seq=Int64(1))

    def head_slot(self, ref auth: IdHead) -> Int64:
        return auth.seq + Int64(1)

    def estimate_bytes(self, ref it: _HeapItem) -> Int:
        return len(it.payload)

    def encode(
        mut self, ref items: Slab[_HeapItem], var auth: IdHead
    ) raises -> EncodedBatch[IdOutcome]:
        # The manifest body references the blob; the staged blob carries the bulk
        # payload (here: each item's heap payload, doubled so it is "bigger").
        var body = List[UInt8]()
        var blob = List[UInt8]()
        var winners = List[Int]()
        for i in range(items.len()):
            ref it = items[i]
            for j in range(len(it.payload)):
                body.append(it.payload[j])
                blob.append(it.payload[j])
                blob.append(it.payload[j])
            winners.append(i)
        return EncodedBatch[IdOutcome](
            body^,
            Int64(items.len()),
            Optional[List[UInt8]](blob^),
            self._blob_key.copy(),
            Int64(0),
            Int64(0),
            List[Tuple[Int, IdOutcome]](),
            winners^,
        )

    def winner_outcome(
        self, orig_idx: Int, intra_batch_seq: Int, append: AppendResult
    ) -> IdOutcome:
        return IdOutcome(
            chunk_seq=append.chunk_seq, intra_batch_seq=intra_batch_seq
        )


struct HeapBlobFactory(SpineFactory, Movable, Deinitable):
    comptime Storage = _Slow
    comptime H = IdReader
    comptime C = HeapBlobCodec
    comptime A = _ExactSlotAppender
    comptime Item = _HeapItem

    var _slow: _Slow
    var _shared: _Shared
    var _prefix: String
    var _head_key: String
    var _blob_key: String

    def __init__(
        out self,
        var slow: _Slow,
        var shared: _Shared,
        var prefix: String,
        var head_key: String,
        var blob_key: String,
    ):
        self._slow = slow^
        self._shared = shared^
        self._prefix = prefix^
        self._head_key = head_key^
        self._blob_key = blob_key^

    def make_spine(
        mut self, var items: Slab[_HeapItem], reason: UInt8
    ) raises -> _CoalesceSpine[_Slow, IdReader, HeapBlobCodec, _ExactSlotAppender]:
        var reader = IdReader(self._slow.clone(), self._head_key.copy())
        var appender = _ExactSlotAppender(
            _SlowMeta(self._slow.clone(), self._prefix.copy())
        )
        return _CoalesceSpine[
            _Slow, IdReader, HeapBlobCodec, _ExactSlotAppender
        ](
            reader^,
            HeapBlobCodec(self._blob_key.copy()),
            appender^,
            items^,
            reason,
        )


def _build_offer_force_and_drop_parked_on_write(
    n: Int, ledger: ArcPointer[_Ledger]
) raises -> Int:
    """Build a STAGE-BLOB window over heap Items, offer `n`, FORCE a flush, then
    drive exactly enough poll cycles to complete the READ park + START the
    STAGE_BLOB (or APPEND) park — so the spine carries `_pending` (a heap-owning
    EncodedBatch) ACROSS the write park. Assert the spine is parked MID-WRITE
    with `_pending` engaged + all `n` heap items retained WHILE win is provably
    alive, then RETURN — dropping `win` (and its parked spine) mid-WRITE: the
    SIMULATED CRASH on the STAGE_BLOB/APPEND park edge. The parked-spine teardown
    must free the retained `_items` Slab AND the carried `_pending` (body +
    staged blob) each exactly once.

    The assertion lives HERE (not at the caller) for the same ASAP-destruction
    reason as `_build_offer_force_and_assert_retained`: keeping it in this scope
    guarantees `win` is alive at the measurement."""
    var reactor = _new_reactor()
    # slow_ticks=2: the READ parks (start + 2 polls), and the STAGE_BLOB +
    # APPEND each park too — so after completing the READ the spine STARTS the
    # STAGE_BLOB park and STAYS parked (the helper stops driving there).
    var slow = _Slow(slow_ticks=2)
    var shared = slow.inner_ref().clone()
    var policy = FlushPolicy.count_only(max_count=n + 5)  # no auto-flush.
    var factory = HeapBlobFactory(
        slow.clone(),
        shared^,
        String("cw-soak-write"),
        String("cw-soak-write/_HEAD"),
        String("cw-soak-write/blobs/content-addressed-key"),
    )
    var win = CoalescingWindow[HeapBlobFactory](
        RamAccumulator[_HeapItem](), policy, factory^
    )
    for i in range(n):
        _ = win.offer[NoopSink](
            _HeapItem(16, String("witem-") + String(i), ledger),
            16,
            Int64(0),
            Int64(0),
            reactor,
        )
    # FORCE the flush — parks on the slow READ (phase READ, _pending None).
    var op = win.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    _ = op
    assert_true(win.is_inflight(), "the flush parked on the READ")
    assert_equal(
        win.debug_inflight_phase(),
        Int(_SP_PHASE_READ),
        "the initial park is on the READ phase",
    )
    assert_false(
        win.debug_inflight_has_pending(),
        "no carried _pending yet (still on the READ park)",
    )

    # Drive the poll loop until the spine ADVANCES PAST the READ into a write
    # park (STAGE_BLOB or APPEND), i.e. `_pending` is engaged. With slow_ticks=2
    # the READ completes, the spine encodes (-> _pending Some) + starts the
    # STAGE_BLOB park, where it STAYS (STAGE_BLOB itself parks). Bounded guard.
    # Drive the loop until the spine advances PAST the READ into a write park
    # (STAGE_BLOB / APPEND), where `_pending` is engaged. The crux assertions
    # (phase, _pending engaged, items retained) are evaluated INSIDE the loop at
    # the write-park detection point — where `win` is PROVABLY ALIVE (the loop
    # body still references it), so ASAP-destruction cannot have dropped the
    # parked spine's retained items yet. (Measuring `ledger[].live` at the
    # function tail is racy: Mojo ASAP-destruction drops `win` right after its
    # last in-line use, which could fall BEFORE a tail measurement — the same
    # reason _build_offer_force_and_assert_retained takes its measurement while
    # win is provably alive.)
    var guard = 0
    var live_at_write_park = -1
    while win.is_inflight() and guard < 64:
        var ph = win.debug_inflight_phase()
        if (
            ph == Int(_SP_PHASE_STAGE_BLOB) or ph == Int(_SP_PHASE_APPEND)
        ) and win.debug_inflight_has_pending():
            # On a WRITE park with `_pending` engaged: take ALL measurements HERE
            # while win is provably alive (the loop body holds it). The retained
            # heap items + the carried _pending must all be intact at the crash.
            assert_true(
                ph == Int(_SP_PHASE_STAGE_BLOB)
                or ph == Int(_SP_PHASE_APPEND),
                "parked on STAGE_BLOB or APPEND at the crash (new write surface)",
            )
            assert_true(
                win.debug_inflight_has_pending(),
                "the carried-across-park _pending (heap EncodedBatch) engaged",
            )
            assert_equal(
                win.debug_inflight_item_count(),
                n,
                "all n heap items still retained across the write park",
            )
            assert_true(
                ledger[].live >= n,
                "the parked batch retains all n heap items before the crash",
            )
            live_at_write_park = ledger[].live
            break
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        guard += 1

    assert_true(
        win.is_inflight(),
        "the flush is STILL parked mid-write (not converged)",
    )
    assert_true(
        live_at_write_park >= n,
        "the spine reached a WRITE park (STAGE_BLOB / APPEND) with all n items"
        " retained before the crash",
    )
    return live_at_write_park
    # `win` drops HERE — the crash on the STAGE_BLOB/APPEND park edge; the
    # parked spine's teardown frees the retained _items Slab AND the carried
    # _pending (its heap body + staged blob) each exactly once.


def test_heap_reuse_crash_drop_parked_on_write_freed_exactly_once() raises:
    """heap-reuse SOAK — CRASH-DROP PARKED MID-WRITE. An N-item batch of
    heap-owning Items is parked on the STAGE_BLOB (or APPEND) park with the
    carried-across-park `_pending` (a heap-owning EncodedBatch: body + staged
    blob) engaged, then the whole window is DROPPED mid-flight (the simulated
    crash on the write-park teardown edge the parkable append creates).
    The ledger must show every constructed item freed EXACTLY ONCE
    (live==0, constructed==destructed, no double-free).

    DISCRIMINATING vs. soak (f): soak (f) drops while parked on the READ, where
    `_pending` is None — so it does NOT exercise the carried-across-park
    `_pending` teardown. THIS soak proves the drop landed mid-WRITE (asserts the
    phase is STAGE_BLOB/APPEND and `_pending` is engaged) BEFORE the crash, so
    the EncodedBatch teardown (its heap body + staged blob) AND the retained
    `_items` Slab are BOTH dropped on the same teardown. A regression that
    double-dropped or leaked either the retained Slab or the carried `_pending`
    on the write-park teardown would flip the double-free flag, crash tcmalloc
    (inner early-drop), or leave live != 0."""
    var N = 28
    var ledger = ArcPointer[_Ledger](_Ledger())

    var live_after_park = _build_offer_force_and_drop_parked_on_write(N, ledger)
    _ = live_after_park

    assert_false(
        ledger[].double_free_detected,
        "NO double-free of any _HeapItem / _pending heap field on the write-park"
        " crash teardown (the heap-reuse signature)",
    )
    assert_equal(
        ledger[].live,
        0,
        "every constructed _HeapItem freed exactly once on the mid-write crash:"
        " live==0",
    )
    assert_equal(
        ledger[].total_constructed,
        ledger[].total_destructed,
        "constructed == destructed (balanced — exactly-once free across the"
        " carried _pending + retained Slab teardown)",
    )
    assert_true(
        ledger[].total_constructed >= N,
        "at least N items were constructed before the mid-write crash",
    )
    print("  test_heap_reuse_crash_drop_parked_on_write_freed_exactly_once: PASS")


# =============================================================================
# multi_snapshot_occ_check — the Postgres store's multi-snapshot OCC helper.
# =============================================================================
def test_multi_snapshot_occ_check() raises:
    var members = List[Tuple[Int, Int64]]()
    members.append((0, Int64(10)))  # snapshot 10 vs auth 10 -> fresh (winner)
    members.append((1, Int64(9)))  # snapshot 9 < 10 -> stale (conflict)
    members.append((2, Int64(11)))  # snapshot 11 >= 10 -> fresh (winner)
    members.append((3, Int64(5)))  # snapshot 5 < 10 -> stale (conflict)
    var conflicts = multi_snapshot_occ_check(members, Int64(10))
    assert_equal(len(conflicts), 2, "two stale members conflict")
    assert_equal(conflicts[0], 1, "member 1 conflicts")
    assert_equal(conflicts[1], 3, "member 3 conflicts")
    print("  test_multi_snapshot_occ_check: PASS")


def main() raises:
    print(
        "test_coalescing_window — the GENERAL coalescing-window primitive GATE"
    )
    # (a) FlushPolicy.evaluate unit branches
    test_evaluate_empty_is_none()
    test_evaluate_size_band()
    test_evaluate_count_band()
    test_evaluate_linger_band()
    test_evaluate_first_fires_wins()
    test_evaluate_disabled_bands()
    # (b) parked-resume correctness
    test_parked_resume_all_outcomes_one_chunk()
    # (c) 412-retry
    test_412_retry_converges()
    # (d) timer self-fires
    test_timer_self_fires()
    # (e) singleton fast-path
    test_singleton_explicit_fast_path()
    # (e2) parkable stage-blob
    test_parkable_stage_blob_then_append()
    # (f) heap-reuse SOAK
    test_heap_reuse_soak_parked_batch_freed_exactly_once()
    # (g) heap-reuse SOAK — 412-retry-with-heap-items (highest-value surface)
    test_heap_reuse_412_retry_heap_items_freed_exactly_once()
    # (h) heap-reuse SOAK — DONE-path-with-heap-items
    test_heap_reuse_done_path_heap_items_freed_exactly_once()
    # (i) heap-reuse SOAK — crash-drop parked MID-WRITE (the carried-across-park teardown surface)
    test_heap_reuse_crash_drop_parked_on_write_freed_exactly_once()
    # substrate helper
    test_multi_snapshot_occ_check()
    print("ALL test_coalescing_window tests PASS")

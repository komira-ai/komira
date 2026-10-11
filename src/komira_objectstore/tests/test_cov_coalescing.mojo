# =============================================================================
# tests/test_cov_coalescing.mojo
#   The coalescing window's flush spine under scripted seam conformers: every
#   error, retry and park arm of READ -> STAGE_BLOB -> APPEND, and the
#   window's no-op and teardown arms.
# =============================================================================
#
# The conformers follow a script (one code per call; past its end every step
# is a plain success):
#   * `_Head`: each READ is READY, PARK (pending, then READY or ERR on poll)
#     or ERR at start ("torn" retries, "fatal" ends); the head it returns is
#     the number of reads so far, so the append slot (head + 1) shows how
#     many times the spine re-read. Each blob stage is READY, PARK, ERR, or a
#     take that raises. `_Head` keeps the trait's DEFAULT stage-blob
#     classifier (FATAL); `_RekeyHead` overrides it ("rekey" -> REKEY).
#   * `_Codec`: items are Ints; a negative item is an arbitration loser (its
#     outcome is fixed at encode); `stage` adds a content-addressed blob.
#   * `_Appender`: WON / PARK then WON / LOST_SLOT at take / ERR at take /
#     a "412" ERR at start (classified LOST_SLOT) / a fatal ERR at start or
#     poll / LOST_SLOT forever.
#
# What each case catches: a torn read not retried or a fatal one retried; a
# stage-blob or append error swallowed (outcomes acked for an unwritten
# batch) or the REKEY / LOST_SLOT loop not re-reading the head (an append at
# a stale slot); the attempt bound not enforced (an unbounded 412 loop);
# loser outcomes dropped; a spine error left as an in-flight flush; the
# window starting a flush on an empty buffer or a stale timer, or arming a
# linger timer with nothing buffered.
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.cas_manifest import AppendResult
from komira_objectstore.coalescing_window import (
    APPEND_ERR,
    APPEND_LOST_SLOT,
    AppendOutcome,
    AuthHeadReader,
    BatchAppender,
    BatchCodec,
    CoalescingWindow,
    EncodedBatch,
    FLUSH_REASON_EXPLICIT,
    FlushPolicy,
    MAX_COMMIT_ATTEMPTS,
    READ_ERR_FATAL,
    READ_ERR_TORN,
    RamAccumulator,
    STAGE_BLOB_ERR_FATAL,
    STAGE_BLOB_ERR_REKEY,
    SpineFactory,
    _CoalesceSpine,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import CasOpProgress, CasReadResult

comptime _Slow = SharedInMemorySlowCasStore

comptime OP = Int64(4242)  # the op id a parked step reports

# READ codes
comptime R_READY = 0
comptime R_PARK = 1
comptime R_TORN = 2
comptime R_FATAL = 3
comptime R_PARK_FATAL = 4
# STAGE codes
comptime S_READY = 0
comptime S_PARK = 1
comptime S_ERR = 2
comptime S_PARK_ERR = 3
comptime S_TAKE_RAISE = 4
comptime S_REKEY = 5
# APPEND codes
comptime A_WON = 0
comptime A_PARK = 1
comptime A_TAKE_LOST = 2
comptime A_TAKE_ERR = 3
comptime A_START_LOST = 4
comptime A_START_FATAL = 5
comptime A_PARK_FATAL = 6
comptime A_LOST_FOREVER = 7


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


@fieldwise_init
struct _Script(Copyable, Movable):
    var codes: List[Int]
    var at: Int

    def next(mut self) -> Int:
        if self.at >= len(self.codes):
            return 0
        var c = self.codes[self.at]
        if c != A_LOST_FOREVER:
            self.at += 1
        return c


def _script(var codes: List[Int]) -> _Script:
    return _Script(codes^, 0)


# ---- SEAM 2: the head reader --------------------------------------------------


struct _Head(AuthHeadReader, Movable, Deinitable):
    var reads: _Script
    var stages: _Script
    var n_reads: Int
    var read_code: Int
    var stage_code: Int

    def __init__(out self, var reads: _Script, var stages: _Script):
        self.reads = reads^
        self.stages = stages^
        self.n_reads = 0
        self.read_code = 0
        self.stage_code = 0

    def read_head_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        self.read_code = self.reads.next()
        if self.read_code == R_TORN:
            return CasOpProgress.error(String("torn read"))
        if self.read_code == R_FATAL:
            return CasOpProgress.error(String("fatal read"))
        if self.read_code == R_PARK or self.read_code == R_PARK_FATAL:
            return CasOpProgress.pending(OP)
        self.n_reads += 1
        return CasOpProgress.ready()

    def read_head_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        if self.read_code == R_PARK_FATAL:
            return CasOpProgress.error(String("fatal read on poll"))
        self.n_reads += 1
        return CasOpProgress.ready()

    def take_read(mut self) raises -> CasReadResult:
        var b = List[UInt8]()
        b.append(UInt8(self.n_reads))
        return CasReadResult(absent=False, body=b^, etag=String("e"))

    def classify_read_error(self, msg: String) -> UInt8:
        if msg.find("torn") >= 0:
            return READ_ERR_TORN
        return READ_ERR_FATAL

    def stage_blob_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, key: String, var bytes: List[UInt8], mut reactor: Reactor[S]
    ) raises -> CasOpProgress:
        self.stage_code = self.stages.next()
        if self.stage_code == S_ERR:
            return CasOpProgress.error(String("blob fatal"))
        if self.stage_code == S_REKEY:
            return CasOpProgress.error(String("blob rekey: 412 at ") + key)
        if self.stage_code == S_PARK or self.stage_code == S_PARK_ERR:
            return CasOpProgress.pending(OP)
        return CasOpProgress.ready()

    def stage_blob_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        if self.stage_code == S_PARK_ERR:
            return CasOpProgress.error(String("blob fatal on poll"))
        return CasOpProgress.ready()

    def stage_blob_take(mut self) raises -> None:
        if self.stage_code == S_TAKE_RAISE:
            raise Error("blob take failed")


struct _RekeyHead(AuthHeadReader, Movable, Deinitable):
    """`_Head` plus the override a re-keying reader has."""

    var inner: _Head

    def __init__(out self, var inner: _Head):
        self.inner = inner^

    def read_head_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.read_head_start[S](reactor)

    def read_head_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.read_head_poll[S](reactor)

    def take_read(mut self) raises -> CasReadResult:
        return self.inner.take_read()

    def classify_read_error(self, msg: String) -> UInt8:
        return self.inner.classify_read_error(msg)

    def stage_blob_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, key: String, var bytes: List[UInt8], mut reactor: Reactor[S]
    ) raises -> CasOpProgress:
        return self.inner.stage_blob_start[S](key, bytes^, reactor)

    def stage_blob_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.stage_blob_poll[S](reactor)

    def stage_blob_take(mut self) raises -> None:
        self.inner.stage_blob_take()

    def classify_stage_blob_error(self, msg: String) -> UInt8:
        if msg.find("rekey") >= 0:
            return STAGE_BLOB_ERR_REKEY
        return STAGE_BLOB_ERR_FATAL


# ---- SEAM 3: the codec ----------------------------------------------------------


struct _Codec(BatchCodec, Movable, Deinitable):
    comptime Item = Int
    comptime Head = Int64
    comptime Outcome = Int64

    var stage: Bool

    def __init__(out self, stage: Bool):
        self.stage = stage

    def decode_head(mut self, var rr: CasReadResult) raises -> Int64:
        return Int64(Int(rr.body[0]))

    def head_slot(self, ref auth: Int64) -> Int64:
        return auth + Int64(1)

    def estimate_bytes(self, ref it: Int) -> Int:
        return 1

    def encode(
        mut self, ref items: Slab[Int], var auth: Int64
    ) raises -> EncodedBatch[Int64]:
        var body = List[UInt8]()
        var winners = List[Int]()
        var losers = List[Tuple[Int, Int64]]()
        for i in range(items.len()):
            if items[i] < 0:
                losers.append((i, Int64(-100 + items[i])))
            else:
                body.append(UInt8(items[i] & 0xFF))
                winners.append(i)
        var blob = Optional[List[UInt8]]()
        var key = String("")
        if self.stage:
            var bb = List[UInt8]()
            bb.append(UInt8(1))
            blob = Optional[List[UInt8]](bb^)
            key = String("blob/") + String(auth)
        return EncodedBatch[Int64](
            body^, Int64(len(winners)), blob^, key^, Int64(0), Int64(0),
            losers^, winners^,
        )

    def winner_outcome(
        self, orig_idx: Int, intra_batch_seq: Int, append: AppendResult
    ) -> Int64:
        return append.chunk_seq * Int64(1000) + Int64(orig_idx * 10 + intra_batch_seq)


# ---- SEAM 5: the appender -------------------------------------------------------


struct _Appender(BatchAppender, Movable, Deinitable):
    var script: _Script
    var code: Int
    var slot: Int64
    var starts: ArcPointer[Int]

    def __init__(out self, var script: _Script, var starts: ArcPointer[Int]):
        self.script = script^
        self.code = 0
        self.slot = Int64(-1)
        self.starts = starts^

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
        self.code = self.script.next()
        self.slot = slot
        self.starts[] += 1
        if self.code == A_START_LOST:
            return CasOpProgress.error(String("precondition (412) slot taken"))
        if self.code == A_START_FATAL:
            return CasOpProgress.error(String("append fatal"))
        if self.code == A_PARK or self.code == A_PARK_FATAL:
            return CasOpProgress.pending(OP)
        return CasOpProgress.ready()

    def append_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        if self.code == A_PARK_FATAL:
            return CasOpProgress.error(String("append fatal on poll"))
        return CasOpProgress.ready()

    def append_take(mut self) raises -> AppendOutcome:
        if self.code == A_TAKE_LOST or self.code == A_LOST_FOREVER:
            return AppendOutcome.lost_slot()
        if self.code == A_TAKE_ERR:
            return AppendOutcome.error(String("append terminal at take"))
        return AppendOutcome.won(
            AppendResult(self.slot, self.slot * Int64(10), self.slot * Int64(10), String("w"), 1)
        )

    def classify_append_error(self, msg: String) -> UInt8:
        if msg.find("412") >= 0:
            return APPEND_LOST_SLOT
        return APPEND_ERR


# ---- factories --------------------------------------------------------------------


struct _Factory(SpineFactory, Movable, Deinitable):
    comptime Storage = _Slow
    comptime H = _Head
    comptime C = _Codec
    comptime A = _Appender
    comptime Item = Int

    var reads: List[Int]
    var stages: List[Int]
    var appends: List[Int]
    var stage: Bool
    var starts: ArcPointer[Int]

    def __init__(out self, stage: Bool = False):
        self.reads = List[Int]()
        self.stages = List[Int]()
        self.appends = List[Int]()
        self.stage = stage
        self.starts = ArcPointer[Int](0)

    def make_spine(
        mut self, var items: Slab[Int], reason: UInt8
    ) raises -> _CoalesceSpine[_Slow, _Head, _Codec, _Appender]:
        return _CoalesceSpine[_Slow, _Head, _Codec, _Appender](
            _Head(_script(self.reads.copy()), _script(self.stages.copy())),
            _Codec(self.stage),
            _Appender(_script(self.appends.copy()), self.starts.copy()),
            items^,
            reason,
        )


struct _RekeyFactory(SpineFactory, Movable, Deinitable):
    comptime Storage = _Slow
    comptime H = _RekeyHead
    comptime C = _Codec
    comptime A = _Appender
    comptime Item = Int

    var stages: List[Int]

    def __init__(out self, var stages: List[Int]):
        self.stages = stages^

    def make_spine(
        mut self, var items: Slab[Int], reason: UInt8
    ) raises -> _CoalesceSpine[_Slow, _RekeyHead, _Codec, _Appender]:
        return _CoalesceSpine[_Slow, _RekeyHead, _Codec, _Appender](
            _RekeyHead(_Head(_script(List[Int]()), _script(self.stages.copy()))),
            _Codec(True),
            _Appender(_script(List[Int]()), ArcPointer[Int](0)),
            items^,
            reason,
        )


comptime _Win = CoalescingWindow[_Factory]


def _codes(a: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    return out^


def _codes(a: Int, b: Int) -> List[Int]:
    var out = _codes(a)
    out.append(b)
    return out^


def _window(var f: _Factory) -> _Win:
    return _Win(RamAccumulator[Int](), FlushPolicy.count_only(1), f^)


def _flush_one(mut w: _Win, item: Int, mut reactor: Reactor[NoopSink]) raises -> Int64:
    return w.offer[NoopSink](item, 1, Int64(0), Int64(0), reactor)


def _only_outcome(mut w: _Win) raises -> Int64:
    var outs = w.take_outcomes()
    assert_equal(len(outs), 1)
    return outs[0][1]


# ---- READ phase ---------------------------------------------------------------------


def test_read_errors() raises:
    var reactor = _new_reactor()
    # A torn read is retried: the second read wins, slot = 2 reads + 1... the
    # torn attempt does not count as a read, so the head is 1 and the slot 2.
    var f = _Factory()
    f.reads = _codes(R_TORN)
    var w = _window(f^)
    assert_equal(_flush_one(w, 5, reactor), Int64(0))
    assert_false(w.has_error())
    assert_equal(_only_outcome(w), Int64(2000))
    # A fatal read at start ends the flush synchronously: no outcomes, the
    # window records the error and is not left in flight.
    w.factory_mut().reads = _codes(R_FATAL)
    assert_equal(_flush_one(w, 6, reactor), Int64(0))
    assert_true(w.has_error())
    assert_equal(w.err_text(), String("_CoalesceSpine read: fatal read"))
    assert_false(w.is_inflight())
    assert_equal(len(w.take_outcomes()), 0)
    # A fatal read surfacing on poll after a park.
    w.factory_mut().reads = _codes(R_PARK_FATAL)
    assert_equal(_flush_one(w, 7, reactor), OP)
    assert_true(w.is_inflight())
    assert_equal(w.debug_inflight_item_count(), 1)
    assert_equal(w.debug_inflight_phase(), 0)
    assert_false(w.debug_inflight_has_pending())
    assert_equal(w.poll[NoopSink](reactor), Int64(0))
    assert_false(w.is_inflight())
    assert_equal(w.err_text(), String("_CoalesceSpine read: fatal read on poll"))
    assert_equal(w.parked_op_id(), Int64(0))
    # With nothing in flight the debug views say so, and poll is a no-op.
    assert_equal(w.debug_inflight_item_count(), -1)
    assert_equal(w.debug_inflight_phase(), -1)
    assert_false(w.debug_inflight_has_pending())
    assert_equal(w.poll[NoopSink](reactor), Int64(0))


def test_read_retry_is_bounded() raises:
    var reactor = _new_reactor()
    var f = _Factory()
    # Exactly MAX_COMMIT_ATTEMPTS torn reads: the last allowed attempt is
    # torn too, so the flush fails (one more attempt would have succeeded).
    var torn = List[Int]()
    for _ in range(MAX_COMMIT_ATTEMPTS):
        torn.append(R_TORN)
    f.reads = torn^
    var w = _window(f^)
    _ = _flush_one(w, 1, reactor)
    assert_true(w.has_error())
    assert_equal(w.err_text(), String("_CoalesceSpine read: torn read"))


# ---- STAGE_BLOB phase -------------------------------------------------------------


def test_stage_blob_arms() raises:
    var reactor = _new_reactor()
    # Staged READY at start, then the append: the outcome lands.
    var w = _window(_Factory(stage=True))
    assert_equal(_flush_one(w, 1, reactor), Int64(0))
    assert_equal(_only_outcome(w), Int64(2000))
    # A stage error at start: the trait's default classifier says FATAL.
    w.factory_mut().stages = _codes(S_ERR)
    _ = _flush_one(w, 2, reactor)
    assert_equal(w.err_text(), String("_CoalesceSpine stage_blob: blob fatal"))
    assert_equal(len(w.take_outcomes()), 0)
    # A parked stage that fails on poll.
    w.factory_mut().stages = _codes(S_PARK_ERR)
    assert_equal(_flush_one(w, 3, reactor), OP)
    assert_equal(w.debug_inflight_phase(), 1)
    assert_true(w.debug_inflight_has_pending())
    assert_equal(w.poll[NoopSink](reactor), Int64(0))
    assert_equal(w.err_text(), String("_CoalesceSpine stage_blob: blob fatal on poll"))
    # A stage whose take raises.
    w.factory_mut().stages = _codes(S_TAKE_RAISE)
    _ = _flush_one(w, 4, reactor)
    assert_equal(w.err_text(), String("_CoalesceSpine stage_blob: blob take failed"))
    # A parked stage that completes.
    w.factory_mut().stages = _codes(S_PARK)
    assert_equal(_flush_one(w, 5, reactor), OP)
    assert_equal(w.poll[NoopSink](reactor), Int64(0))
    assert_equal(_only_outcome(w), Int64(2000))


def test_stage_blob_rekey_rereads() raises:
    var reactor = _new_reactor()
    # A colliding-key 412: re-read the head (slot moves from 2 to 3) and
    # re-encode under a fresh key, then append.
    var w = CoalescingWindow[_RekeyFactory](
        RamAccumulator[Int](), FlushPolicy.count_only(1), _RekeyFactory(_codes(S_REKEY))
    )
    _ = w.offer[NoopSink](9, 1, Int64(0), Int64(0), reactor)
    assert_false(w.has_error())
    var outs = w.take_outcomes()
    assert_equal(len(outs), 1)
    assert_equal(outs[0][1], Int64(3000))
    # Any other stage error stays fatal under the override.
    w.factory_mut().stages = _codes(S_ERR)
    _ = w.offer[NoopSink](9, 1, Int64(0), Int64(0), reactor)
    assert_equal(w.err_text(), String("_CoalesceSpine stage_blob: blob fatal"))


# ---- APPEND phase -----------------------------------------------------------------


def test_append_arms() raises:
    var reactor = _new_reactor()
    var f = _Factory()
    # LOST_SLOT at take: re-read, append at the next slot.
    f.appends = _codes(A_TAKE_LOST)
    var w = _window(f^)
    _ = _flush_one(w, 1, reactor)
    assert_equal(_only_outcome(w), Int64(3000))
    # A 412 ERR at start is classified LOST_SLOT: the same loop.
    w.factory_mut().appends = _codes(A_START_LOST)
    _ = _flush_one(w, 1, reactor)
    assert_equal(_only_outcome(w), Int64(3000))
    # An ERR outcome at take is terminal.
    w.factory_mut().appends = _codes(A_TAKE_ERR)
    _ = _flush_one(w, 1, reactor)
    assert_equal(w.err_text(), String("_CoalesceSpine append: append terminal at take"))
    assert_equal(len(w.take_outcomes()), 0)
    # A fatal ERR at start.
    w.factory_mut().appends = _codes(A_START_FATAL)
    _ = _flush_one(w, 1, reactor)
    assert_equal(w.err_text(), String("_CoalesceSpine append: append fatal"))
    # A parked append failing on poll.
    w.factory_mut().appends = _codes(A_PARK_FATAL)
    assert_equal(_flush_one(w, 1, reactor), OP)
    assert_equal(w.debug_inflight_phase(), 2)
    assert_equal(w.poll[NoopSink](reactor), Int64(0))
    assert_equal(w.err_text(), String("_CoalesceSpine append: append fatal on poll"))
    # A parked append completing.
    w.factory_mut().appends = _codes(A_PARK)
    assert_equal(_flush_one(w, 1, reactor), OP)
    assert_equal(w.poll[NoopSink](reactor), Int64(0))
    assert_equal(_only_outcome(w), Int64(2000))


def test_lost_slot_loop_is_bounded() raises:
    var reactor = _new_reactor()
    var f = _Factory()
    f.appends = _codes(A_LOST_FOREVER)
    var starts = f.starts.copy()
    var w = _window(f^)
    _ = _flush_one(w, 1, reactor)
    assert_true(w.has_error())
    # Exactly MAX_COMMIT_ATTEMPTS appends were tried, not one more.
    assert_equal(starts[], MAX_COMMIT_ATTEMPTS)
    assert_equal(
        w.err_text(),
        String("_CoalesceSpine: append CAS did not converge within ")
        + String(MAX_COMMIT_ATTEMPTS) + String(" attempts"),
    )


def test_losers_are_reported() raises:
    var reactor = _new_reactor()
    var w = _Win(RamAccumulator[Int](), FlushPolicy.count_only(3), _Factory())
    _ = w.offer[NoopSink](5, 1, Int64(0), Int64(0), reactor)
    _ = w.offer[NoopSink](-3, 1, Int64(0), Int64(0), reactor)
    _ = w.offer[NoopSink](7, 1, Int64(0), Int64(0), reactor)
    var outs = w.take_outcomes()
    assert_equal(len(outs), 3)
    # Winners (orig 0 and 2, intra 0 and 1) at slot 2, then the loser.
    assert_equal(outs[0][0], 0)
    assert_equal(outs[0][1], Int64(2000))
    assert_equal(outs[1][0], 2)
    assert_equal(outs[1][1], Int64(2021))
    assert_equal(outs[2][0], 1)
    assert_equal(outs[2][1], Int64(-103))


# ---- window no-op arms --------------------------------------------------------------


def test_window_noop_arms() raises:
    var reactor = _new_reactor()
    var w = _Win(RamAccumulator[Int](), FlushPolicy.linger_only(Int64(50)), _Factory())
    # Nothing buffered: force starts nothing.
    assert_equal(w.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor), Int64(0))
    # Two offers inside the linger: the second does not re-arm the timer.
    _ = w.offer[NoopSink](1, 1, Int64(0), Int64(0), reactor)
    var t1 = w.timer_op_id()
    assert_true(t1 != Int64(0))
    _ = w.offer[NoopSink](2, 1, Int64(1), Int64(1), reactor)
    assert_equal(w.timer_op_id(), t1)
    assert_equal(w.pending_count(), 2)
    # A deadline for another op id starts nothing.
    assert_equal(w.on_deadline[NoopSink](t1 + Int64(1), Int64(100), reactor), Int64(0))
    assert_equal(w.pending_count(), 2)
    # A flush that parks (the read parks), then a new offer arms a new timer
    # while it is in flight: that deadline and a force both start nothing.
    w.factory_mut().reads = _codes(R_PARK)
    assert_equal(w.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor), OP)
    _ = w.offer[NoopSink](3, 1, Int64(2), Int64(2), reactor)
    var t2 = w.timer_op_id()
    assert_true(t2 != Int64(0))
    assert_equal(w.on_deadline[NoopSink](t2, Int64(100), reactor), Int64(0))
    assert_equal(w.timer_op_id(), Int64(0))
    assert_equal(w.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor), Int64(0))
    assert_equal(w.pending_count(), 1)
    assert_equal(w.poll[NoopSink](reactor), Int64(0))
    assert_equal(len(w.take_outcomes()), 2)


def test_empty_window_arms_no_timer() raises:
    var reactor = _new_reactor()
    var w = _Win(RamAccumulator[Int](), FlushPolicy.linger_only(Int64(50)), _Factory())
    # A linger policy but nothing buffered: no deadline to arm.
    assert_false(w._maybe_arm_timer[NoopSink](reactor))
    assert_equal(w.timer_op_id(), Int64(0))


def test_spine_take_before_done() raises:
    var items = Slab[Int]()
    items.append(1)
    var sp = _CoalesceSpine[_Slow, _Head, _Codec, _Appender](
        _Head(_script(List[Int]()), _script(List[Int]())),
        _Codec(False),
        _Appender(_script(List[Int]()), ArcPointer[Int](0)),
        items^,
        FLUSH_REASON_EXPLICIT,
    )
    var msg = String("")
    try:
        _ = sp.take_outcomes()
    except e:
        msg = String(e)
    assert_equal(msg, String("_CoalesceSpine.take_outcomes: not done"))
    assert_equal(sp.flush_reason(), FLUSH_REASON_EXPLICIT)


def main() raises:
    test_read_errors()
    test_read_retry_is_bounded()
    test_stage_blob_arms()
    test_stage_blob_rekey_rereads()
    test_append_arms()
    test_lost_slot_loop_is_bounded()
    test_losers_are_reported()
    test_window_noop_arms()
    test_empty_window_arms_no_timer()
    test_spine_take_before_done()
    print("[test_cov_coalescing] PASS")

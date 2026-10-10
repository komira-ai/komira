# =============================================================================
# test_local_dispatcher_cold_paths.mojo
# =============================================================================
# The arms of `runtime/local_dispatcher.mojo` that no other test reaches: the
# out-of-range shard marks, a shard that stops because another shard failed or
# the token was cancelled (both split modes), a second error losing to the
# first, a zero-size Segment, a worker queue that stays full, the IO lane with
# every queue full, a dispatch entered with a charge left over,
# `for_each_morsel` with no workers and with a failing static body, and the
# scheduler-trace brackets. The stuck-barrier dump has its own file
# (`test_local_dispatcher_stall_dump.mojo`): it waits ten seconds and owns fd 2.
#
# How the tests order work across shards without sleeping: one real worker
# plus a PSEUDO worker, a queue this test registers with
# `_register_worker_handle` and reads itself. The real worker's shard runs task
# 0, which pulls the pseudo worker's shard out of that queue and runs it inline,
# on the same thread. So "shard 1 ran and failed before shard 0 looked at its
# next task" is a fact of program order, not of timing.
#
# Tasks record themselves in a bitmask (`ran`, bit `tid`), so each test states
# exactly which tasks ran and which a stop arm kept from running.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, alloc
from std.sys import size_of
from std.time import perf_counter_ns
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.channel.mpsc import (
    MpscReceiver,
    TRY_SEND_OK,
    channel as mpsc_channel,
)
from komira_async.channel.spsc import TRY_RECV_OK
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.for_each_morsel import MorselBody
from komira_async.runtime.local_dispatcher import (
    LocalDispatcher,
    _ShardMarkTable,
)
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async.runtime.sched_trace import (
    SchedSiteScope,
    sched_trace_force_enable,
    sched_trace_global,
    sched_trace_reset,
    sched_trace_site,
)
from komira_async.runtime.shared_erasure import (
    ErasableWork,
    ErasedHandle,
    STEP_DONE,
    make_erased,
)
from komira_async.runtime.wake_primitives import WorkerWakeHandle, cpu_pause
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_collections.slab import Slab


# How long a task waits for the pseudo worker's shard to be posted before it
# gives up and records the miss. The driver posts it right after shard 0, so
# the wait is microseconds; the bound only keeps a regression from hanging.
comptime _GIVE_UP_NS: Int64 = 120_000_000_000


def _new_counter() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    # SAFETY: a fresh allocation we own; ownership moves to the OwnedPointer.
    raw[] = AtomicI64(Int64(0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime(n_workers: Int) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _disconnected_wake() -> WorkerWakeHandle:
    return WorkerWakeHandle.make_disconnected(Int32(-1), UInt64(0))


# -----------------------------------------------------------------------------
# The State and Segment of the shard-arm tests.
# -----------------------------------------------------------------------------


struct _ArmState(KeepAlive, Movable, Deinitable):
    # Bit `tid` set when task `tid` entered `execute`.
    var ran: OwnedPointer[AtomicI64]
    # 1 when a rescuing task gave up waiting for the pseudo worker's shard.
    var missed: OwnedPointer[AtomicI64]
    # The pseudo workers' receivers; index k is dispatcher wid k + 1.
    var pseudo: Slab[MpscReceiver[ErasedHandle]]
    # A handle on the dispatch's token, for the cancelling task.
    var cancel: CancellationToken
    var rescue_tid: Int64
    var cancel_tid: Int64
    # Bit `tid` set: task `tid` raises (after any rescue it does).
    var raise_mask: Int64

    def __init__(out self):
        self.ran = _new_counter()
        self.missed = _new_counter()
        self.pseudo = Slab[MpscReceiver[ErasedHandle]]()
        self.cancel = CancellationToken.never()
        self.rescue_tid = Int64(-1)
        self.cancel_tid = Int64(-1)
        self.raise_mask = Int64(0)

    def ran_mask(self) -> Int64:
        return self.ran[].load()

    def __keep_alive(mut self):
        pass


def _pull(mut recv: MpscReceiver[ErasedHandle]) -> Optional[ErasedHandle]:
    """The next handle of `recv`, waiting for it to be posted (bounded)."""
    var deadline = Int64(perf_counter_ns()) + _GIVE_UP_NS
    while Int64(perf_counter_ns()) < deadline:
        var oc = recv.try_recv()
        if oc.status == TRY_RECV_OK:
            return Optional[ErasedHandle](oc.take_value())
        cpu_pause()
    return Optional[ErasedHandle](None)


@fieldwise_init
struct _ArmSegment(Segment, Deinitable):
    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: every dispatch of this Segment passes an `_ArmState`; the
        # pointer is used only inside this call, while the state is borrowed.
        var sp = UnsafePointer(to=state).bitcast[_ArmState]()
        _ = sp[].ran[].fetch_add(Int64(1) << task_id)
        _ = worker_id
        if task_id == sp[].rescue_tid:
            # Run the pseudo worker's shard here, before this task returns.
            var h = _pull(sp[].pseudo[0])
            if h:
                var handle = h.take()
                handle.run()
                _ = handle^
            else:
                _ = sp[].missed[].fetch_add(Int64(1))
        if task_id == sp[].cancel_tid:
            sp[].cancel.cancel(String("stop-now"))
        if (sp[].raise_mask >> task_id) & Int64(1) != Int64(0):
            raise Error("boom@" + String(task_id))

    def __keep_alive(mut self):
        pass


def _add_pseudo_worker(
    mut d: LocalDispatcher[NoopSink], mut st: _ArmState
) raises:
    var pair = mpsc_channel[ErasedHandle](UInt(4))
    st.pseudo.append(pair.take_receiver())
    d._register_worker_handle(pair.take_sender(), _disconnected_wake())


def _dispatch(
    mut d: LocalDispatcher[NoopSink],
    mut st: _ArmState,
    n: Int,
    var token: CancellationToken,
) -> String:
    """Run `n` tasks of `_ArmSegment`; the error text, or "" on success."""
    try:
        var back = d.run_with_state[_ArmState, _ArmSegment](
            st, _ArmSegment(_pad=0), n, token^,
        )
        _ = back^
    except e:
        return String(e)
    return String("")


# -----------------------------------------------------------------------------
# _ShardMarkTable: the bounds of the two masks.
# -----------------------------------------------------------------------------


def _wids(a: Int, b: Int) -> List[Int]:
    """The wids to mark, from memory: `mark_delivered`/`mark_entered` are
    `@always_inline`, and a literal wid would let the compiler fold their bound
    check away in this copy."""
    var out = List[Int]()
    out.append(a)
    out.append(b)
    return out^


def _deliver_all(mut t: _ShardMarkTable, wids: List[Int]):
    for w in wids:
        t.mark_delivered(Int32(w))


def _enter_all(mut t: _ShardMarkTable, wids: List[Int]):
    for w in wids:
        t.mark_entered(Int32(w))


def test_mark_table_refuses_wids_outside_capacity() raises:
    """A wid outside [0, CAPACITY) is counted in the overflow, never folded onto
    a valid wid's bit. The bounds are checked at both ends: wid 1024 (one past
    the end) would index word 16, past the array, and a negative wid would
    index word -1. The neighbouring words are set first, so a mark that went
    out of bounds shows up as a changed neighbour."""
    var t = _ShardMarkTable()
    assert_equal(_ShardMarkTable.CAPACITY, 1024)
    _enter_all(t, _wids(0, 0))
    _deliver_all(t, _wids(1023, 1023))
    # Marked twice: the carry is the documented double-mark signal (bit 1).
    assert_equal(t.entered_word(0), Int64(2))
    # Wid 1023 twice: bit 63 twice carries out of the word, leaving 0.
    assert_equal(t.delivered_word(15), Int64(0))
    _deliver_all(t, _wids(1023, 63))
    # Wid 1023 is bit 63 of word 15: the sign bit.
    assert_equal(t.delivered_word(15), Int64(1) << Int64(63))
    assert_equal(t.overflow_marks(), Int64(0))

    _deliver_all(t, _wids(1024, -1))
    assert_equal(t.overflow_marks(), Int64(2))
    _enter_all(t, _wids(1024, -1))
    assert_equal(t.overflow_marks(), Int64(4))
    # No valid bit moved.
    assert_equal(t.entered_word(0), Int64(2))
    assert_equal(t.entered_word(15), Int64(0))
    assert_equal(t.delivered_word(0), Int64(1) << Int64(63))
    assert_equal(t.delivered_word(15), Int64(1) << Int64(63))
    assert_true(t.delivered_bit(1023))
    assert_true(t.delivered_bit(63))
    assert_false(t.entered_bit(1023))
    assert_true(t.entered_bit(1))
    assert_false(t.entered_bit(0))
    assert_false(t.delivered_bit(0))


def test_mark_table_reads_outside_range_are_zero() raises:
    """Word index 16 is one past each array; the word just past `_delivered` is
    `_entered[0]` and the word just past `_entered` is the overflow count, both
    non-zero here, so a read that missed its bound would return them."""
    var t = _ShardMarkTable()
    t.mark_entered(Int32(0))
    t.mark_delivered(Int32(0))
    t.mark_delivered(Int32(-5))
    assert_equal(t.delivered_word(16), Int64(0))
    assert_equal(t.entered_word(16), Int64(0))
    assert_equal(t.delivered_word(-1), Int64(0))
    assert_equal(t.entered_word(-1), Int64(0))
    assert_false(t.delivered_bit(1024))
    assert_false(t.entered_bit(1024))
    assert_false(t.delivered_bit(-1))
    assert_false(t.entered_bit(-1))
    assert_true(t.delivered_bit(0))
    assert_true(t.entered_bit(0))
    # reset() clears both masks and the overflow count.
    t.reset()
    assert_equal(t.overflow_marks(), Int64(0))
    assert_false(t.delivered_bit(0))
    assert_false(t.entered_bit(0))


# -----------------------------------------------------------------------------
# _DispatchShard.run: the stop arms.
# -----------------------------------------------------------------------------


def test_static_split_stops_after_another_shard_failed() raises:
    """Static split, n = 4 over two workers: shard 0 owns tasks 0..1 (real
    worker), shard 1 owns tasks 2..3 (pseudo worker). Task 0 runs shard 1
    inline; task 2 raises, so shard 1 records the error and stops (task 3 never
    runs). Back in shard 0, task 1 sees the error and is not run.
    Ran = {0, 2}."""
    var rt = _runtime(1)
    ref d = rt.dispatcher()
    d.set_claim_enabled(False)
    var st = _ArmState()
    _add_pseudo_worker(d, st)
    assert_equal(d.worker_count(), 2)
    st.rescue_tid = Int64(0)
    st.raise_mask = Int64(1) << Int64(2)
    var msg = _dispatch(d, st, 4, CancellationToken.never())
    assert_equal(st.missed[].load(), Int64(0))
    assert_equal(msg, String("LocalDispatcher.run_with_state: boom@2"))
    assert_equal(st.ran_mask(), Int64(0b0101))
    assert_equal(d.in_flight_snapshot(), Int64(0))
    assert_equal(d.task_cursor_value(), Int64(0))
    _ = st^
    rt.shutdown()


def test_first_error_wins() raises:
    """Static split, n = 4 over two workers, tasks 0 and 2 raise. Task 0 runs
    shard 1 inline first, so task 2's error is recorded; task 0's own error
    comes second, loses the slot, and does not overwrite it."""
    var rt = _runtime(1)
    ref d = rt.dispatcher()
    d.set_claim_enabled(False)
    var st = _ArmState()
    _add_pseudo_worker(d, st)
    st.rescue_tid = Int64(0)
    st.raise_mask = (Int64(1) << Int64(0)) | (Int64(1) << Int64(2))
    var msg = _dispatch(d, st, 4, CancellationToken.never())
    assert_equal(st.missed[].load(), Int64(0))
    assert_equal(msg, String("LocalDispatcher.run_with_state: boom@2"))
    assert_equal(st.ran_mask(), Int64(0b0101))
    assert_equal(d.in_flight_snapshot(), Int64(0))
    _ = st^
    rt.shutdown()


def test_claiming_stops_after_another_shard_failed() raises:
    """Claiming, n = 3 over two workers. Shard 0 claims task 0, which runs
    shard 1 inline; shard 1 claims task 1, which raises. Shard 0 then claims
    task 2, sees the error and does not run it. Ran = {0, 1}; the cursor was
    advanced three times (0, 1, 2), so it reads 3."""
    var rt = _runtime(1)
    ref d = rt.dispatcher()
    assert_true(d.claim_enabled())
    var st = _ArmState()
    _add_pseudo_worker(d, st)
    st.rescue_tid = Int64(0)
    st.raise_mask = Int64(1) << Int64(1)
    var msg = _dispatch(d, st, 3, CancellationToken.never())
    assert_equal(st.missed[].load(), Int64(0))
    assert_equal(msg, String("LocalDispatcher.run_with_state: boom@1"))
    assert_equal(st.ran_mask(), Int64(0b011))
    assert_equal(d.task_cursor_value(), Int64(3))
    assert_equal(d.in_flight_snapshot(), Int64(0))
    _ = st^
    rt.shutdown()


def test_static_split_stops_on_cancel_between_tasks() raises:
    """Static split, one worker, n = 3: task 0 cancels the dispatch's token.
    Task 1 sees it before running, records `CancelledError: <reason>` and the
    shard stops. Ran = {0}."""
    var rt = _runtime(1)
    ref d = rt.dispatcher()
    d.set_claim_enabled(False)
    var st = _ArmState()
    var token = CancellationToken.new()
    st.cancel = token.clone()
    st.cancel_tid = Int64(0)
    var msg = _dispatch(d, st, 3, token^)
    assert_equal(
        msg, String("LocalDispatcher.run_with_state: CancelledError: stop-now")
    )
    assert_equal(st.ran_mask(), Int64(1))
    assert_equal(d.in_flight_snapshot(), Int64(0))
    _ = st^
    rt.shutdown()


def test_claiming_stops_on_cancel_between_tasks() raises:
    """Claiming, one worker, n = 3: task 0 cancels; the shard claims task 1,
    sees the cancel and stops. Ran = {0}; cursor = 2 (claims of 0 and 1)."""
    var rt = _runtime(1)
    ref d = rt.dispatcher()
    var st = _ArmState()
    var token = CancellationToken.new()
    st.cancel = token.clone()
    st.cancel_tid = Int64(0)
    var msg = _dispatch(d, st, 3, token^)
    assert_equal(
        msg, String("LocalDispatcher.run_with_state: CancelledError: stop-now")
    )
    assert_equal(st.ran_mask(), Int64(1))
    assert_equal(d.task_cursor_value(), Int64(2))
    _ = st^
    rt.shutdown()


struct _EmptySegment(Segment, Deinitable):
    """A Segment with no fields: zero bytes to park in the dispatcher's slab."""

    def __init__(out self):
        pass

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: every dispatch of this Segment passes an `_ArmState`; the
        # pointer is used only inside this call, while the state is borrowed.
        var sp = UnsafePointer(to=state).bitcast[_ArmState]()
        _ = sp[].ran[].fetch_add(Int64(1) << task_id)
        _ = worker_id

    def __keep_alive(mut self):
        pass


def test_zero_size_segment_needs_no_slab_bytes() raises:
    """A stateless Segment is zero bytes: the slab is neither grown nor
    lengthened for it (both size checks false), and every task still runs, on a
    fresh dispatcher and again after a dispatch that used the slab."""
    assert_equal(size_of[_EmptySegment](), 0)
    var rt = _runtime(2)
    ref d = rt.dispatcher()
    var st = _ArmState()
    var back = d.run_with_state[_ArmState, _EmptySegment](
        st, _EmptySegment(), 3, CancellationToken.never(),
    )
    _ = back^
    assert_equal(st.ran_mask(), Int64(0b111))
    assert_equal(d._seg_buf.capacity(), 0)
    assert_equal(_dispatch(d, st, 1, CancellationToken.never()), String(""))
    var back2 = d.run_with_state[_ArmState, _EmptySegment](
        st, _EmptySegment(), 2, CancellationToken.never(),
    )
    _ = back2^
    # Task 0 three times, task 1 twice, task 2 once.
    assert_equal(st.ran_mask(), Int64(3 + 2 * 2 + 4))
    assert_equal(d._seg_buf.len(), 0)
    _ = st^
    rt.shutdown()


# -----------------------------------------------------------------------------
# Full queues: the compute lane and the IO lane.
# -----------------------------------------------------------------------------


struct _Cell(Movable, Deinitable):
    var v: OwnedPointer[AtomicI64]

    def __init__(out self):
        self.v = _new_counter()

    def get(self) -> Int64:
        return self.v[].load()


struct _Work(ErasableWork, Movable, Deinitable):
    """Counts its runs and its destruction in cells the test holds."""

    var _ran: ArcPointer[_Cell]
    var _dropped: ArcPointer[_Cell]

    def __init__(out self, ran: ArcPointer[_Cell], dropped: ArcPointer[_Cell]):
        self._ran = ArcPointer[_Cell](copy=ran)
        self._dropped = ArcPointer[_Cell](copy=dropped)

    def run(mut self) raises -> None:
        _ = self._ran[].v[].fetch_add(Int64(1))

    def step(mut self) raises -> Int:
        return STEP_DONE

    def __deinit__(deinit self):
        _ = self._dropped[].v[].fetch_add(Int64(1))


def _filler() -> ErasedHandle:
    return make_erased[_Work](
        _Work(ArcPointer[_Cell](_Cell()), ArcPointer[_Cell](_Cell()))
    )


def test_compute_queue_persistently_full_raises_after_barrier() raises:
    """A dispatcher whose only worker queue is full and never drained: the
    enqueue retries, gives up, settles the barrier and raises naming the
    worker. The re-entrance guard is released (a second dispatch runs), the
    Segment slab is emptied, and the generation was closed (two bumps)."""
    var d = LocalDispatcher[NoopSink]()
    var pair = mpsc_channel[ErasedHandle](UInt(2))
    var recv = pair.take_receiver()
    var send = pair.take_sender()
    var fill = send.clone()
    assert_true(fill.try_send(_filler()) == TRY_SEND_OK)
    assert_true(fill.try_send(_filler()) == TRY_SEND_OK)
    d._register_worker_handle(send^, _disconnected_wake())
    var st = _ArmState()
    var msg = _dispatch(d, st, 1, CancellationToken.never())
    assert_true(
        msg.startswith(
            "LocalDispatcher.run_with_state: worker0 queue persistently FULL"
        ),
        msg,
    )
    assert_equal(st.ran_mask(), Int64(0))
    assert_equal(d.in_flight_snapshot(), Int64(0))
    assert_equal(d.dispatch_gen_snapshot(), Int64(2))
    assert_equal(d._seg_buf.len(), 0)
    # The guard was released: an n = 0 dispatch is not "nested".
    assert_equal(_dispatch(d, st, 0, CancellationToken.never()), String(""))
    # The two fillers are still the queue's whole content.
    assert_equal(fill.approx_depth(), Int64(2))
    _ = recv^
    _ = fill^
    _ = st^
    _ = d^


def test_io_lane_full_drops_the_work_and_round_robin_moves_on() raises:
    """Two IO queues of capacity 2. Queue 0 holds one filler, queue 1 two.
    A is accepted by queue 0 and the round robin moves to 1. B finds both full:
    it is refused and destroyed here, unrun, and the round robin stays. After
    one slot of queue 0 is freed, C starts at queue 1 (full), moves on to queue
    0 and is accepted. Queue 0 then yields A, then C."""
    var d = LocalDispatcher[NoopSink]()
    var p0 = mpsc_channel[ErasedHandle](UInt(2))
    var p1 = mpsc_channel[ErasedHandle](UInt(2))
    var r0 = p0.take_receiver()
    var r1 = p1.take_receiver()
    var s0 = p0.take_sender()
    var s1 = p1.take_sender()
    assert_true(s0.try_send(_filler()) == TRY_SEND_OK)
    assert_true(s1.try_send(_filler()) == TRY_SEND_OK)
    assert_true(s1.try_send(_filler()) == TRY_SEND_OK)
    d._register_io_worker_handle(s0^, _disconnected_wake())
    d._register_io_worker_handle(s1^, _disconnected_wake())
    assert_equal(d.io_lane_count(), 2)
    assert_true(d.io_lane_active())

    var a_ran = ArcPointer[_Cell](_Cell())
    var b_ran = ArcPointer[_Cell](_Cell())
    var c_ran = ArcPointer[_Cell](_Cell())
    var a_drop = ArcPointer[_Cell](_Cell())
    var b_drop = ArcPointer[_Cell](_Cell())
    var c_drop = ArcPointer[_Cell](_Cell())

    assert_true(d.post_to_io_lane[_Work](_Work(a_ran, a_drop)))
    assert_equal(d._io_rr, 1)
    assert_false(d.post_to_io_lane[_Work](_Work(b_ran, b_drop)))
    assert_equal(b_drop[].get(), Int64(1))
    assert_equal(b_ran[].get(), Int64(0))
    assert_equal(d._io_rr, 1)

    var freed = r0.try_recv()
    assert_true(freed.status == TRY_RECV_OK)
    _ = freed.take_value()
    assert_true(d.post_to_io_lane[_Work](_Work(c_ran, c_drop)))
    assert_equal(d._io_rr, 1)

    var first = r0.try_recv()
    assert_true(first.status == TRY_RECV_OK)
    var hf = first.take_value()
    hf.run()
    _ = hf^
    assert_equal(a_ran[].get(), Int64(1))
    assert_equal(c_ran[].get(), Int64(0))
    var second = r0.try_recv()
    assert_true(second.status == TRY_RECV_OK)
    var hs = second.take_value()
    hs.run()
    _ = hs^
    assert_equal(c_ran[].get(), Int64(1))
    assert_false(r0.try_recv().status == TRY_RECV_OK)
    _ = r1^
    _ = d^


# -----------------------------------------------------------------------------
# A dispatch entered with a charge left over.
# -----------------------------------------------------------------------------


def test_entry_with_leftover_charge_is_counted() raises:
    """White-box: a non-zero in-flight count at entry is what a barrier that
    returned early leaves behind. Planted directly (no healthy path leaves it),
    it is counted once as an entry leftover, not as a stale shard, and the
    dispatch still runs every task and ends at zero."""
    var rt = _runtime(1)
    ref d = rt.dispatcher()
    _ = d._in_flight[].fetch_add(Int64(7))
    var st = _ArmState()
    assert_equal(_dispatch(d, st, 2, CancellationToken.never()), String(""))
    assert_equal(st.ran_mask(), Int64(0b11))
    assert_equal(d.entry_leftover_snapshot(), Int64(1))
    assert_equal(d.stale_shard_refusals_snapshot(), Int64(0))
    assert_equal(d.barrier_violations_snapshot(), Int64(1))
    assert_equal(d.in_flight_snapshot(), Int64(0))
    _ = st^
    rt.shutdown()


# -----------------------------------------------------------------------------
# for_each_morsel: no workers, and a failing static body.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _FailOnBody(MorselBody, Deinitable):
    var bad: Int

    def process[
        State: KeepAlive,
        MorselT: Copyable & ImplicitlyCopyable & Movable & Deinitable,
    ](
        mut self, mut state: State, wid: Int, var morsel: MorselT,
    ) raises:
        # SAFETY: the tests dispatch this body over an `_ArmState` and `Int`
        # morsels (`for_each_index`); both pointers are used only inside this
        # call, while the state and the morsel are alive.
        var sp = UnsafePointer(to=state).bitcast[_ArmState]()
        var idx = UnsafePointer(to=morsel).bitcast[Int]()[]
        _ = sp[].ran[].fetch_add(Int64(1) << Int64(idx))
        _ = wid
        _ = morsel^
        if idx == self.bad:
            raise Error("bad morsel " + String(idx))


def test_for_each_morsel_without_workers_raises() raises:
    var d = LocalDispatcher[NoopSink]()
    var st = _ArmState()
    var msg = String("")
    try:
        var b = d.for_each_index[_ArmState, _FailOnBody](
            st, 3, _FailOnBody(bad=-1), CancellationToken.never(),
        )
        _ = b^
    except e:
        msg = String(e)
    assert_true(
        msg.startswith("LocalDispatcher.for_each_morsel: no workers attached."),
        msg,
    )
    assert_equal(st.ran_mask(), Int64(0))
    _ = st^
    _ = d^


def test_for_each_morsel_static_body_error_is_raised() raises:
    """One morsel over one worker is the static mode (one task per morsel).
    Its body raises; the error reaches the caller with the dispatcher's prefix.
    One worker keeps it deterministic: with two, the shard that claimed the
    other morsel could see the error first and skip its morsel."""
    var rt = _runtime(1)
    ref d = rt.dispatcher()
    var st = _ArmState()
    var msg = String("")
    try:
        var b = d.for_each_index[_ArmState, _FailOnBody](
            st, 1, _FailOnBody(bad=0), CancellationToken.never(),
        )
        _ = b^
    except e:
        msg = String(e)
    assert_equal(msg, String("LocalDispatcher.run_with_state: bad morsel 0"))
    assert_equal(st.ran_mask(), Int64(1))
    _ = st^
    rt.shutdown()


# -----------------------------------------------------------------------------
# Scheduler trace: the brackets recorded when tracing is on.
# -----------------------------------------------------------------------------


def test_sched_trace_records_dispatch_and_segment_sites() raises:
    """With tracing on before the runtime is built, every dispatch adds its
    shard count to the erasure total and one segment to a site: the ambient
    site when `site_id` is 0, the given `site_id` otherwise. Dispatch 1 is
    n = 1 (one shard) under ambient site 101; dispatch 2 is n = 5 (two shards)
    with `site_id` 102 under the same ambient site."""
    sched_trace_force_enable(True)
    sched_trace_reset()
    var rt = _runtime(2)
    ref d = rt.dispatcher()
    var erasures0 = sched_trace_global(Int32(1))
    var segs0 = sched_trace_global(Int32(2))
    var st = _ArmState()

    var scope = SchedSiteScope(UInt32(101))
    var back = d.run_with_state[_ArmState, _ArmSegment](
        st, _ArmSegment(_pad=0), 1, CancellationToken.never(),
    )
    _ = back^
    scope.keep()
    assert_equal(sched_trace_site(UInt32(101), Int32(2)), UInt64(1))
    assert_equal(sched_trace_site(UInt32(101), Int32(3)), UInt64(1))
    assert_equal(sched_trace_site(UInt32(0), Int32(2)), UInt64(0))
    assert_equal(st.ran_mask(), Int64(1))

    var back2 = d.run_with_state[_ArmState, _ArmSegment](
        st, _ArmSegment(_pad=0), 5, CancellationToken.never(),
        site_id=UInt32(102),
    )
    _ = back2^
    scope.keep()
    _ = scope^
    assert_equal(sched_trace_site(UInt32(102), Int32(2)), UInt64(1))
    assert_equal(sched_trace_site(UInt32(102), Int32(3)), UInt64(2))
    assert_equal(sched_trace_site(UInt32(101), Int32(2)), UInt64(1))
    assert_equal(sched_trace_global(Int32(1)) - erasures0, UInt64(3))
    assert_equal(sched_trace_global(Int32(2)) - segs0, UInt64(2))
    # Task 0 of the first dispatch, then tasks 0..4 of the second.
    assert_equal(st.ran_mask(), Int64(1) + Int64(0b11111))
    _ = st^
    rt.shutdown()
    sched_trace_force_enable(False)


def main() raises:
    test_mark_table_refuses_wids_outside_capacity()
    test_mark_table_reads_outside_range_are_zero()
    test_static_split_stops_after_another_shard_failed()
    test_first_error_wins()
    test_claiming_stops_after_another_shard_failed()
    test_static_split_stops_on_cancel_between_tasks()
    test_claiming_stops_on_cancel_between_tasks()
    test_zero_size_segment_needs_no_slab_bytes()
    test_compute_queue_persistently_full_raises_after_barrier()
    test_io_lane_full_drops_the_work_and_round_robin_moves_on()
    test_entry_with_leftover_charge_is_counted()
    test_for_each_morsel_without_workers_raises()
    test_for_each_morsel_static_body_error_is_raised()
    # Last: tracing is process-wide.
    test_sched_trace_records_dispatch_and_segment_sites()
    print("OK test_local_dispatcher_cold_paths")

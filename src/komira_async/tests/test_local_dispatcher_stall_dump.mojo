# =============================================================================
# test_local_dispatcher_stall_dump.mojo
# =============================================================================
# The stuck-barrier path of `LocalDispatcher._drain_in_flight_barrier`: the
# one-time `[BARRIER-STALL]` dump to stderr after ten seconds of waiting, and
# the stranded-charge settlement that lets a barrier holding refused shards
# return (and makes `run_with_state` raise that their tasks did not run).
#
# The scene is the field defect the generation guard was built for: a shard of
# the CURRENT dispatch is lost, and a shard of the PREVIOUS dispatch runs in
# its place and is refused. Built deterministically:
#
#   * 1 real worker + P PSEUDO workers (queues this test reads); static split,
#     n = P + 1, so shard `w` owns task `w`. P = 127 gives one further 64-wid
#     band in the dump (128 workers, a band boundary); P = 1024 gives the 15 the mark table holds, and wid
#     1024, past the table, is counted as overflow.
#   * Dispatch 1 (setup): task 0 runs on the real worker and runs every pseudo
#     shard inline. It keeps the handles of wid 1 and wid P after running them.
#   * Dispatch 2 (the stall), with fd 2 pointed at a socket this test reads.
#     Task 0 takes wid 1's new shard out of its queue and drops it (lost), and
#     re-runs dispatch 1's wid-1 handle: refused by the guard (delivered, not
#     entered). The barrier now waits on P + 1 charges with 1 refusal; nothing
#     else moves, so after 10 000 one-millisecond waits it prints the dump.
#     Task 0 reads the dump off the socket, runs wids 2..P-1, drops wid P's
#     new shard, and posts dispatch 1's wid-P handle to the REAL worker's queue,
#     where it runs (and is refused) only after shard 0 has finished. That
#     refusal is the last event, after the driver is known (from the dump) to
#     be inside its wait loop: in-flight 2 = refusals 2, the barrier returns,
#     settles the 2 stranded charges and the dispatch raises.
#   * Dispatch 3 is healthy and finds no leftover charge.
#
# Each scenario takes about ten seconds: the dump's threshold. Nothing sleeps;
# every wait is on a condition. The test's own waits are bounded (task 0's wait
# for a pseudo shard to be posted: 120 s; its read of the dump: 300 s; the read
# to end of stream after the dispatch: 300 s), so a dump that never comes fails
# the test. The driver's barrier wait inside `run_with_state` has no bound: a
# regression that leaves a charge unreleased and unrefused hangs this test.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, alloc
from std.time import perf_counter_ns
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.channel.mpsc import (
    MpscReceiver,
    MpscSender,
    TRY_SEND_OK,
    channel as mpsc_channel,
)
from komira_async.channel.spsc import TRY_RECV_OK
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.reactor.socket_io import try_recv
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
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


# Bounds that only turn a regression into a failure instead of a hang.
comptime _PULL_GIVE_UP_NS: Int64 = 120_000_000_000
comptime _DUMP_GIVE_UP_NS: Int64 = 300_000_000_000
comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1


def _new_counter() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    # SAFETY: a fresh allocation we own; ownership moves to the OwnedPointer.
    raw[] = AtomicI64(Int64(0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _socketpair() -> SIMD[DType.int32, 2]:
    """An AF_UNIX stream pair, or (-1, -1)."""
    var fds = SIMD[DType.int32, 2](-1, -1)
    # SAFETY: socketpair(2) writes two int32 into this local; the pointer does
    # not outlive the call.
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0),
        UnsafePointer(to=fds).bitcast[UInt8](),
    )
    if rc < 0:
        return SIMD[DType.int32, 2](-1, -1)
    return fds


def _poll_readable(fd: Int32, timeout_ms: Int32) -> Bool:
    """poll(2) one fd for POLLIN. `struct pollfd` is {int fd; short events;
    short revents}: two int32 on a little-endian host, `revents` the high half
    of the second."""
    # SAFETY: poll(2) reads and writes this local list's two int32 during the
    # call only.
    var pfd = List[Int32]()
    pfd.append(fd)
    pfd.append(Int32(1))
    var rc = external_call["poll", Int32](
        pfd.unsafe_ptr(), UInt64(1), timeout_ms
    )
    if rc <= Int32(0):
        return False
    return ((pfd[1] >> 16) & Int32(1)) != Int32(0)


# The dump's last line: the queue of the highest pseudo worker.
def _last_dump_line(n_pseudo: Int) -> String:
    return "[BARRIER-STALL]   worker " + String(n_pseudo) + " queue_depth= 1\n"


def _read_to_eof(fd: Int32, mut buf: List[UInt8]) -> Bool:
    """Append the socket's remaining bytes until end of stream (bounded)."""
    var chunk = List[UInt8](capacity=4096)
    for _ in range(4096):
        chunk.append(UInt8(0))
    var deadline = Int64(perf_counter_ns()) + _DUMP_GIVE_UP_NS
    while Int64(perf_counter_ns()) < deadline:
        if not _poll_readable(fd, Int32(1000)):
            continue
        var n = try_recv(fd, Span(chunk))
        if n == Int64(0):
            return True
        for i in range(Int(n)):
            buf.append(chunk[i])
    return False


def _read_dump(fd: Int32, n_pseudo: Int, mut buf: List[UInt8]) -> Bool:
    """Read the socket until the dump's last line has arrived (bounded)."""
    var chunk = List[UInt8](capacity=4096)
    for _ in range(4096):
        chunk.append(UInt8(0))
    var deadline = Int64(perf_counter_ns()) + _DUMP_GIVE_UP_NS
    var last = _last_dump_line(n_pseudo)
    while Int64(perf_counter_ns()) < deadline:
        if not _poll_readable(fd, Int32(1000)):
            continue
        var n = try_recv(fd, Span(chunk))
        for i in range(Int(n)):
            buf.append(chunk[i])
        if String(unsafe_from_utf8=Span(buf)).find(last) >= 0:
            return True
    return False


struct _Replay(ErasableWork, Movable, Deinitable):
    """Runs a kept shard handle again, on whichever worker drains it."""

    var inner: ErasedHandle

    def __init__(out self, var inner: ErasedHandle):
        self.inner = inner^

    def run(mut self) raises -> None:
        self.inner.run()

    def step(mut self) raises -> Int:
        return STEP_DONE


struct _StallState(KeepAlive, Movable, Deinitable):
    var ran: OwnedPointer[AtomicI64]
    var missed: OwnedPointer[AtomicI64]
    # Index k is dispatcher wid k + 1.
    var pseudo: Slab[MpscReceiver[ErasedHandle]]
    var kept_first: Optional[ErasedHandle]
    var kept_last: Optional[ErasedHandle]
    var to_worker0: Optional[MpscSender[ErasedHandle]]
    var wake0: Optional[WorkerWakeHandle]
    var n_pseudo: Int
    var phase: Int
    var dump_fd: Int32
    var dump: List[UInt8]
    var dump_ok: Bool

    def __init__(out self):
        self.ran = _new_counter()
        self.missed = _new_counter()
        self.pseudo = Slab[MpscReceiver[ErasedHandle]]()
        self.kept_first = None
        self.kept_last = None
        self.to_worker0 = None
        self.wake0 = None
        self.n_pseudo = 0
        self.phase = 0
        self.dump_fd = Int32(-1)
        self.dump = List[UInt8]()
        self.dump_ok = False

    def __keep_alive(mut self):
        pass


def _pull(mut st: _StallState, k: Int) -> Optional[ErasedHandle]:
    var deadline = Int64(perf_counter_ns()) + _PULL_GIVE_UP_NS
    while Int64(perf_counter_ns()) < deadline:
        var oc = st.pseudo[k].try_recv()
        if oc.status == TRY_RECV_OK:
            return Optional[ErasedHandle](oc.take_value())
        cpu_pause()
    _ = st.missed[].fetch_add(Int64(1))
    return Optional[ErasedHandle](None)


def _setup_consumer(mut st: _StallState) raises:
    """Dispatch 1: run every pseudo shard; keep wid 1's and the last wid's."""
    for k in range(st.n_pseudo):
        var h = _pull(st, k)
        if not h:
            continue
        var handle = h.take()
        handle.run()
        if k == 0:
            st.kept_first = Optional[ErasedHandle](handle^)
        elif k == st.n_pseudo - 1:
            st.kept_last = Optional[ErasedHandle](handle^)
        else:
            _ = handle^


def _stall_consumer(mut st: _StallState) raises:
    """Dispatch 2, see the header."""
    # wid 1's shard of this dispatch is lost; dispatch 1's runs in its place.
    var lost_first = _pull(st, 0)
    _ = lost_first^
    var old_first = st.kept_first.take()
    old_first.run()
    _ = old_first^
    st.dump_ok = _read_dump(st.dump_fd, st.n_pseudo, st.dump)
    for k in range(1, st.n_pseudo - 1):
        var h = _pull(st, k)
        if h:
            var handle = h.take()
            handle.run()
            _ = handle^
    # The last wid's shard is lost too; dispatch 1's runs on the real worker once
    # this shard has finished, as the dispatch's last event.
    var lost_last = _pull(st, st.n_pseudo - 1)
    _ = lost_last^
    var replay = make_erased[_Replay](_Replay(st.kept_last.take()))
    var out = st.to_worker0.value().try_send_back(replay^)
    if out.status != TRY_SEND_OK:
        _ = st.missed[].fetch_add(Int64(1))
    _ = out^
    _ = st.wake0.value().wake_with_elision()


@fieldwise_init
struct _StallSegment(Segment, Deinitable):
    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: every dispatch of this Segment passes a `_StallState`; the
        # pointer is used only inside this call, while the state is borrowed.
        var sp = UnsafePointer(to=state).bitcast[_StallState]()
        _ = sp[].ran[].fetch_add(Int64(1))
        _ = worker_id
        if task_id != Int64(0):
            return
        if sp[].phase == 1:
            _setup_consumer(sp[])
        elif sp[].phase == 2:
            _stall_consumer(sp[])

    def __keep_alive(mut self):
        pass


def _dispatch(
    mut d: LocalDispatcher[NoopSink], mut st: _StallState, n: Int
) -> String:
    try:
        var back = d.run_with_state[_StallState, _StallSegment](
            st, _StallSegment(_pad=0), n, CancellationToken.never(),
        )
        _ = back^
    except e:
        return String(e)
    return String("")


def _expect_line(dump: String, line: String) raises:
    assert_true(dump.find(line) >= 0, "missing dump line: " + line)


def _stall_scenario(n_pseudo: Int, bands: Int) raises:
    """The scene of the header with `n_pseudo` pseudo workers (at least 2);
    `bands` is how many further 64-wid band lines the dump must print."""
    var n = n_pseudo + 1
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()
    d.set_claim_enabled(False)
    var st = _StallState()
    st.n_pseudo = n_pseudo
    for _ in range(n_pseudo):
        var pair = mpsc_channel[ErasedHandle](UInt(4))
        st.pseudo.append(pair.take_receiver())
        d._register_worker_handle(
            pair.take_sender(),
            WorkerWakeHandle.make_disconnected(Int32(-1), UInt64(0)),
        )
    assert_equal(d.worker_count(), n)
    st.to_worker0 = Optional[MpscSender[ErasedHandle]](
        d._worker_senders[0][].clone()
    )
    st.wake0 = Optional[WorkerWakeHandle](d._worker_wake_handles[0].copy())
    var g0 = d.dispatch_gen_snapshot()
    var g1 = g0 + 1
    var g2 = g0 + 3
    assert_equal(d.last_refusal_detail_snapshot(), Int64(-1))

    # Dispatch 1: healthy, every task runs.
    st.phase = 1
    assert_equal(_dispatch(d, st, n), String(""))
    assert_equal(st.ran[].load(), Int64(n))
    assert_equal(st.missed[].load(), Int64(0))
    assert_true(Bool(st.kept_first) and Bool(st.kept_last))
    assert_equal(d.stale_shard_refusals_snapshot(), Int64(0))
    assert_equal(d.dispatch_gen_snapshot(), g0 + 2)

    # Dispatch 2: the stall, with fd 2 captured.
    var sv = _socketpair()
    assert_true(sv[0] >= 0, "socketpair failed")
    st.dump_fd = sv[0]
    st.phase = 2
    var saved = external_call["dup", Int32](Int32(2))
    if saved < Int32(0):
        _ = external_call["close", Int32](sv[1])
        _ = external_call["close", Int32](sv[0])
        raise Error("dup(2) failed: cannot capture stderr")
    _ = external_call["dup2", Int32](sv[1], Int32(2))
    var msg = _dispatch(d, st, n)
    _ = external_call["dup2", Int32](saved, Int32(2))
    _ = external_call["close", Int32](saved)
    _ = external_call["close", Int32](sv[1])
    # Every write end is closed now, so what is left on the socket is all the
    # dispatch printed after the dump's last line; read it to end of stream.
    var eof = _read_to_eof(sv[0], st.dump)
    _ = external_call["close", Int32](sv[0])
    assert_true(eof, "the captured stderr did not reach end of stream")

    assert_equal(st.missed[].load(), Int64(0))
    assert_true(st.dump_ok, "no [BARRIER-STALL] dump arrived")
    assert_true(
        msg.startswith(
            "LocalDispatcher.run_with_state: 2 shard(s) refused by the"
            " stale-generation guard"
        ),
        msg,
    )
    # Every task but 1 and n_pseudo (the lost shards) ran.
    assert_equal(st.ran[].load(), Int64(n + n - 2))
    assert_equal(d.stale_shard_refusals_snapshot(), Int64(2))
    assert_equal(d.entry_leftover_snapshot(), Int64(0))
    assert_equal(d.barrier_violations_snapshot(), Int64(2))
    # The stranded charges were settled: the counter is back at zero.
    assert_equal(d.in_flight_snapshot(), Int64(0))
    assert_equal(d.dispatch_gen_snapshot(), g0 + 4)
    assert_equal(
        d.last_refusal_detail_snapshot(),
        (g2 << 40) | (g1 << 16) | Int64(n_pseudo),
    )
    # Marks: every wid up to n_pseudo was delivered (the last by its refused
    # replay); every wid below n_pseudo but 1 entered. A wid past the table's
    # 1024 is counted as overflow, never folded onto a bit.
    for i in range(16):
        var exp_d = Int64(0)
        var exp_e = Int64(0)
        for b in range(64):
            var w = i * 64 + b
            if w <= n_pseudo:
                exp_d |= Int64(1) << Int64(b)
            if w < n_pseudo and w != 1:
                exp_e |= Int64(1) << Int64(b)
        assert_equal(d.shard_delivered_word(i), exp_d)
        assert_equal(d.shard_entered_word(i), exp_e)
    assert_true(d.shard_delivered_bit(1))
    assert_false(d.shard_entered_bit(1))
    assert_equal(d.shard_delivered_bit(n_pseudo), n_pseudo < 1024)
    assert_false(d.shard_entered_bit(n_pseudo))
    assert_equal(
        d.shard_mark_overflow_snapshot(),
        Int64(1) if n_pseudo >= 1024 else Int64(0),
    )
    assert_equal(d.shard_mark_capacity(), 1024)

    # The dump, line by line.
    var dump = String(unsafe_from_utf8=Span(st.dump))
    _expect_line(
        dump,
        "[BARRIER-STALL] LocalDispatcher._drain_in_flight_barrier stuck >10s:"
        + " in_flight= " + String(n) + " posted= " + String(n)
        + " entered_mask= 1 delivered_mask= 3 gen= " + String(g2)
        + " stale_refusals= 1 entry_leftovers= 0 workers= " + String(n)
        + " mark_overflow= 0 | last_refusal wid= 1 stamped_gen= "
        + String(g1) + " observed_gen= " + String(g2) + "\n",
    )
    # Bands 1..bands, each all zero at dump time (no wid above 1 has run).
    for mw in range(1, bands + 1):
        _expect_line(
            dump,
            "\n[BARRIER-STALL]   wids " + String(mw * 64) + " .. "
            + String(mw * 64 + 63) + " entered_mask= 0 delivered_mask= 0\n",
        )
    assert_equal(dump.count("[BARRIER-STALL]   wids "), bands)
    var never = String("")
    for w in range(2, n):
        never += String(w) + " "
    _expect_line(
        dump,
        "\n[BARRIER-STALL]   never_delivered=[ " + never
        + " ] delivered_but_never_entered=[ 1  ]\n",
    )
    _expect_line(
        dump,
        "\n[BARRIER-STALL]   refusing_wid= 1  n= " + String(n)
        + "  n_workers= " + String(n) + "  expect_lo= 1  expect_hi= 2\n",
    )
    for w in range(2, n):
        _expect_line(
            dump,
            "\n[BARRIER-STALL]   worker " + String(w) + " queue_depth= 1\n",
        )
    # Workers whose queue is empty print no depth line. The capture holds
    # everything written to fd 2 during the dispatch: the dump came once.
    assert_equal(dump.count("queue_depth="), n - 2)
    assert_equal(dump.count("stuck >10s"), 1)

    # Dispatch 3: healthy, and no charge was left behind.
    st.phase = 3
    assert_equal(_dispatch(d, st, 1), String(""))
    assert_equal(d.entry_leftover_snapshot(), Int64(0))
    assert_equal(d.stale_shard_refusals_snapshot(), Int64(2))
    assert_equal(d.in_flight_snapshot(), Int64(0))
    _ = st^
    rt.shutdown()


def test_stall_dump_one_extra_band() raises:
    """128 workers: one band past the first word; the band loop stops on the
    worker count, exactly at a band boundary (128 = 2 * 64), so a `<=` there
    would print a second band."""
    _stall_scenario(127, 1)


def test_stall_dump_wider_than_the_mark_table() raises:
    """1025 workers: the 15 further bands the table holds (wids 64..1023); the
    band loop stops on the table's size, and wid 1024 overflows the table."""
    _stall_scenario(1024, 15)


def main() raises:
    test_stall_dump_one_extra_band()
    test_stall_dump_wider_than_the_mark_table()
    print("OK test_local_dispatcher_stall_dump")

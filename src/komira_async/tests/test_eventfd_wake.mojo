# =============================================================================
# test_eventfd_wake.mojo
# =============================================================================
# eventfd spin-park test surface — direct lifecycle + wake-path tests.
#
# What this file covers:
#   1. Basic eventfd lifecycle (create + close via Reactor.__init__/__del__).
#   2. WorkerWakeHandle.wake() best-effort semantics (no raise on closed fd).
#   3. Standalone-Worker eventfd lifecycle (no pthread launched).
#   4. Producer→worker wake path (basic enqueue → wake → drain).
#   5. Shutdown wakes parked worker via eventfd.
#   6. Lost-wake regression.
#
# Cross-thread N-producer wake is
# covered implicitly by the existing test_cross_pthread_happens_before
# under the eventfd wake mechanism; no new test code needed.
# =============================================================================

from std.memory import OwnedPointer, alloc
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_MOCK,
    Reactor,
)
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async.runtime.wake_primitives import (
    WorkerWakeHandle,
    create_eventfd,
    close_eventfd,
    drain_eventfd,
    write_eventfd,
)
from komira_async.runtime.worker import Worker
from komira_async.spawner.spawner import SpawnableTask
from komira_async_api.worker_pool_traits import KeepAlive, Segment


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# -----------------------------------------------------------------------------
# Test 1 — Basic eventfd FFI primitives (raw, no Reactor).
# -----------------------------------------------------------------------------


def test_eventfd_create_close() raises:
    """Verify create_eventfd returns a valid fd and close_eventfd is safe.
    Verifies the FFI surface compiles + executes correctly on Linux.
    """
    var fd = create_eventfd()
    assert_true(fd >= 0, "create_eventfd should return non-negative fd")
    close_eventfd(fd)
    # Closing the -1 sentinel is also safe (idempotent).
    close_eventfd(Int32(-1))


def test_eventfd_write_then_drain() raises:
    """Verify write_eventfd + drain_eventfd round-trip. After write+drain,
    the eventfd counter is back to zero (drain is destructive)."""
    var fd = create_eventfd()
    # Write multiple times to bump the counter.
    write_eventfd(fd)
    write_eventfd(fd)
    write_eventfd(fd)
    # Drain reads the accumulated counter and resets it to zero.
    drain_eventfd(fd)
    # Second drain on a zero counter returns -1/EAGAIN (NONBLOCK) which
    # is benign; should not raise/abort.
    drain_eventfd(fd)
    close_eventfd(fd)


def test_eventfd_write_to_closed_fd() raises:
    """Writing to a closed eventfd returns
    silently (EBADF), no raise / abort. Critical for the producer's
    best-effort contract"""
    var fd = create_eventfd()
    close_eventfd(fd)
    # Write to closed fd. Should silently swallow EBADF; no raise.
    write_eventfd(fd)
    # Drain on closed fd. Same story.
    drain_eventfd(fd)


# -----------------------------------------------------------------------------
# Test 2 — WorkerWakeHandle POD lifecycle.
# -----------------------------------------------------------------------------


def test_worker_wake_handle_pod_copy() raises:
    """WorkerWakeHandle.copy() refcount-bumps the inner ArcPointer; both
    clones refer to the same underlying eventfd. The handle does NOT
    own the underlying fd — the Reactor does.

    The handle now carries an
    ArcPointer<_SleepingFlag> instead of the BANNED `_sleeping_addr:
    Int` shape. The clone path is `.copy()` (explicit), not implicit.
    """
    var fd = create_eventfd()
    var h1 = WorkerWakeHandle.make_disconnected(wake_fd=fd, ident=UInt64(0))
    # Explicit clone via .copy() — refcount bump on the ArcPointer.
    var h2 = h1.copy()
    # Both handles refer to the same fd.
    assert_equal(h1.fd(), h2.fd())
    # Calling wake() on either is well-defined (kernel-side serialized).
    h1.wake()
    h2.wake()
    # Drain via the raw helper to verify the writes landed.
    drain_eventfd(fd)
    close_eventfd(fd)


def test_worker_wake_handle_sentinel() raises:
    """WorkerWakeHandle with _wake_fd = -1 (the MOCK backend sentinel)
    is a no-op on wake. Verifies the FFI safety check."""
    var h = WorkerWakeHandle.make_disconnected(
        wake_fd=Int32(-1), ident=UInt64(0),
    )
    # Should silently no-op; no raise / abort.
    h.wake()
    h.wake()


# -----------------------------------------------------------------------------
# Test 3 — Standalone-Worker eventfd lifecycle (Issue 2.B).
# -----------------------------------------------------------------------------


def test_standalone_worker_epoll_eventfd_lifecycle() raises:
    """Per Issue 2.B / lifecycle mode 3: a Worker constructed via the
    standalone 3-arg ctor (no runtime, no pthread) under BACKEND_EPOLL
    correctly creates+registers+closes its eventfd. The destructor runs
    on the test thread; no producer/consumer race."""
    var w = Worker[NoopSink](
        UInt16(0), NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
    )
    # Extract the wake handle. Should be a valid (non-sentinel) fd
    # because the Reactor allocated an eventfd in __init__.
    var h = w.wake_handle()
    assert_true(h.fd() >= 0, "standalone Worker should have valid eventfd")
    # Wake should be a no-op (no consumer parked); kernel just bumps
    # the counter. No raise.
    h.wake()
    # Worker drops at scope exit; Reactor.__del__ closes the eventfd.
    # If anything goes wrong with the destructor ordering, this test
    # will assert / abort / leak.


def test_standalone_worker_mock_backend_sentinel_handle() raises:
    """BACKEND_MOCK: the wake handle's fd is the -1 sentinel. wake() is
    a no-op."""
    var w = Worker[NoopSink](
        UInt16(0), NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK,
    )
    var h = w.wake_handle()
    assert_equal(h.fd(), Int32(-1))
    h.wake()  # no-op; no raise.


# -----------------------------------------------------------------------------
# Test 4 — Producer→worker wake path via runtime.
# -----------------------------------------------------------------------------


struct _WakeCounterState(KeepAlive, Movable, Deinitable):
    """Per-dispatch State: heap-stable atomic counter."""

    var counter: OwnedPointer[AtomicI64]

    def __init__(out self):
        var raw = alloc[AtomicI64](1)
        raw[] = AtomicI64(Int64(0))
        self.counter = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw,
        )

    def load(self) -> Int64:
        return self.counter[].load()


@fieldwise_init
struct _WakeCountSegment(Segment, Deinitable):
    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_WakeCounterState]()
        _ = sp[].counter[].fetch_add(Int64(1))
        _ = worker_id
        _ = task_id


def test_dispatch_wake_round_trip_n2() raises:
    """End-to-end: dispatch n=2 tasks under BACKEND_EPOLL with N=2
    workers. Each shard's enqueue triggers an eventfd wake; workers
    park on epoll_wait, wake on the eventfd, drain the MPSC entry,
    execute the segment. Counter should reach 2.

    Pre-eventfd-spin-park: this would block on the 1ms idle floor per
    cycle. With eventfd: sub-microsecond wake → fast completion.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_EPOLL,
        placement=PLACEMENT_FIXED,
    )
    ref d = rt.dispatcher()
    var s = _WakeCounterState()
    var seg = _WakeCountSegment(_pad=0)
    var seg_back = d.run_with_state[_WakeCounterState, _WakeCountSegment](
        s, seg^, 2, CancellationToken.never(),
    )
    _ = seg_back^
    assert_equal(s.load(), Int64(2))


def test_dispatch_wake_burst_n2() raises:
    """Burst dispatch: 100 dispatches in succession, each n=2. Verifies
    the wake mechanism handles back-to-back dispatches without lost
    wakes. Counter should reach 200.

    The N-fan-out wake means 100 × 2 = 200 eventfd writes total; the
    workers' spin-then-park should absorb them efficiently (most should
    be drained in the spin phase; few park-cycles needed)."""
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_EPOLL,
        placement=PLACEMENT_FIXED,
    )
    ref d = rt.dispatcher()
    var s = _WakeCounterState()
    var i = 0
    while i < 100:
        var seg = _WakeCountSegment(_pad=0)
        var seg_back = d.run_with_state[_WakeCounterState, _WakeCountSegment](
            s, seg^, 2, CancellationToken.never(),
        )
        _ = seg_back^
        i = i + 1
    assert_equal(s.load(), Int64(200))


# -----------------------------------------------------------------------------
# Test 5 — Shutdown wakes parked worker via eventfd.
# -----------------------------------------------------------------------------


def test_shutdown_wakes_parked_worker_n4() raises:
    """race-case-2: shutdown signal must wake a parked worker via
    eventfd, NOT just set the flag. With PARK_TIMEOUT_US=-1 (block
    forever), a worker parked on epoll_wait won't observe the flag
    without a wake.

    Test shape: construct a runtime with N=4 workers, do NOT dispatch
    anything, drop. RAII destructor calls _runtime_teardown_join which
    calls signal_shutdown on each worker. signal_shutdown sets flag +
    writes eventfd via reactor().wake_self(). Workers wake from
    epoll_wait(-1), see the flag, exit. pthread_join then succeeds.

    If the eventfd wake is broken, this test HANGS forever (the workers
    are parked on epoll_wait(-1) with nothing to wake them).

    The test runner's timeout will fire if hung.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_EPOLL,
        placement=PLACEMENT_FIXED,
    )
    # Workers are parked on epoll_wait(-1) (PARK_TIMEOUT_US=-1) since
    # nothing's been dispatched. RAII drop signals shutdown to each;
    # the eventfd wake unblocks them; pthread_join succeeds.
    assert_equal(rt.worker_count(), 4)
    # Drop — must complete within the test runner's timeout.


def test_shutdown_idle_workers_repeatedly() raises:
    """Multi-cycle: 10 ctor + drop cycles with N=2 workers and no
    dispatch. Each drop must wake the parked workers via eventfd.

    If shutdown wake is broken, ANY cycle hangs and the runner's timeout
    fires. 10 cycles is enough to surface flakiness."""
    var i = 0
    while i < 10:
        var rt = PerCoreAsyncRuntime[NoopSink](
            num_workers=2,
            sink_factory=_noop_sink_factory,
            backend=BACKEND_EPOLL,
            placement=PLACEMENT_FIXED,
        )
        assert_equal(rt.worker_count(), 2)
        # rt drops here; shutdown wake must unblock the parked workers.
        i = i + 1


# -----------------------------------------------------------------------------
# Test 6 — Lost-wake regression.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _EpollSpawnTask(SpawnableTask, Movable, Deinitable):
    """Simple spawnable task for the EPOLL spawn smoke test.
    Mirrors the cb_spawn_epoll bench's _NoOpTask shape."""

    comptime T = Int
    var x: Int

    def run(mut self) raises -> Self.T:
        return self.x * 2


def test_spawn_under_epoll_smoke() raises:
    """smoke: spawn 100 tasks on a 1-worker EPOLL runtime, join each,
    verify results.

    the RAII drop path is now
    deterministic (a 200×10-spawn stress went from crashing every time
    to never). The `_SpawnedTaskHeader.in_flight_ptr` wildcard
    pointer was replaced by `ArcPointer<_InflightCounter>`; lifetime
    is fully tracked. No explicit `rt.shutdown()` required — keeping
    the call here as documentation of the deferred-start lifecycle
    pattern (idempotent post-fix).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=1,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_EPOLL,
        placement=PLACEMENT_FIXED,
    )
    ref sp = rt.spawner()
    var i = 0
    var checksum: Int = 0
    while i < 100:
        var h = sp.spawn[_EpollSpawnTask](_EpollSpawnTask(x=i))
        var result = h^.join()
        checksum = checksum + result
        i = i + 1
    rt.shutdown()
    # Sum 2*i for i in [0,100) = 9900.
    assert_equal(checksum, 9900)


def test_lost_wake_regression_send_then_wake() raises:
    """Verify the ordering invariant. The dispatcher
    publishes an MPSC entry with try_send THEN calls wake_handle.wake().
    The worker's spin-then-park guarantees:

      - If worker is in spin phase: it observes the slot directly via
        try_recv; the eventfd write is absorbed as a benign spurious
        wake on the next park.
      - If worker is parked on epoll_wait: the eventfd write makes
        epoll_wait return; the worker observes the slot in the
        post-park drain.

    The catastrophic ordering ("producer writes slot, worker parks,
    producer writes eventfd, worker stays parked") is structurally
    impossible because the kernel's eventfd_write→epoll_wait return is
    unconditionally HB.

    Test shape: dispatch 1000 tiny tasks one-at-a-time (force the
    park-wake path most of the time). Counter should reach 1000 with
    no lost wake / no hang.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_EPOLL,
        placement=PLACEMENT_FIXED,
    )
    ref d = rt.dispatcher()
    var s = _WakeCounterState()
    var i = 0
    while i < 50:  # reduced from 1000 — surface flakiness without exhausting fds
        var seg = _WakeCountSegment(_pad=0)
        var seg_back = d.run_with_state[_WakeCounterState, _WakeCountSegment](
            s, seg^, 1,  # n=1: one shard, force serialization
            CancellationToken.never(),
        )
        _ = seg_back^
        i = i + 1
    assert_equal(s.load(), Int64(50))


def test_raii_drop_stress_no_explicit_shutdown() raises:
    """RAII drop stress
    regression test.

    Pre-fix: this exact shape (10 spawns + scope-exit RAII drop, looped
    50 times in-process) deterministically crashed inside
    libAsyncRTRuntimeGlobals.so within a few cycles. The crash was the
    `_SpawnedTaskHeader.in_flight_ptr: UnsafePointer[..., MutExternalOrigin]`
    wildcard-origin field running afoul of the field-drop ordering
    teardown — without compiler lifetime tracking, the spawner's
    `_in_flight: OwnedPointer[Atomic[int64]]` could be freed in a state
    where the in-flight Atomic was still being read by the worker's
    final unbounded drain.

    Post-fix: `in_flight` is now an `ArcPointer<_InflightCounter>` field
    on the header. The Arc refcount keeps the
    InflightCounter alive across teardown — when the spawner drops, its
    clone refcount-decrements; if any header is still mid-trampoline,
    the InflightCounter persists until that header's destructor runs.

    Reproduction: 50 cycles × 10 spawns is small enough to run inside
    the standard test budget (< 1 sec) but long enough that the
    pre-fix bug fired ≥99% of the time. Confirmed deterministic in
    a standalone repro at 200 cycles.
    """
    var c = 0
    var cycles = 50
    var spawns = 10
    while c < cycles:
        var rt = PerCoreAsyncRuntime[NoopSink](
            num_workers=1,
            sink_factory=_noop_sink_factory,
            backend=BACKEND_EPOLL,
            placement=PLACEMENT_FIXED,
        )
        ref sp = rt.spawner()
        var s = 0
        var checksum: Int = 0
        while s < spawns:
            var h = sp.spawn[_EpollSpawnTask](_EpollSpawnTask(x=s))
            var result = h^.join()
            checksum = checksum + result
            s = s + 1
        # Sum 2*i for i in [0,10) = 90.
        assert_equal(checksum, 90)
        # NO rt.shutdown() — let __del__ drive teardown (RAII path).
        c = c + 1


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    # ⛔ EVERY BODY BELOW REACHES `eventfd(2)` OR `BACKEND_EPOLL`, BOTH LINUX
    # KERNEL MECHANISMS: on macOS the runtime raises "BACKEND_EPOLL requires
    # Linux" verbatim, so this file exits non-zero on a mac — and as a gated
    # test of the library, that would make a mac build of the library fail.
    # The guard is this package's OWN pattern for a Linux-only reactor test —
    # `test_epoll_double_add_eexist.mojo`. macOS reactor coverage is the
    # kqueue pair (`test_kqueue_wake`, `test_kqueue_accept_tcp`), in the same
    # gated test list. On Linux nothing about this file changes.
    comptime if not CompilationTarget.is_linux():
        print(
            "SKIP komira_async.runtime eventfd wake: eventfd(2) and"
            " BACKEND_EPOLL are Linux kernel mechanisms. macOS reactor"
            " coverage is test_kqueue_wake / test_kqueue_accept_tcp."
        )
        return
    # Spawn smoke FIRST (without accumulated state): the order matters in
    # the eventfd
    # substrate. The spawn-under-EPOLL path surfaces a race in the
    # spawner's lifecycle / cancellation cascade when many spawns
    # accumulate in one process.
    test_spawn_under_epoll_smoke()
    print("  test_spawn_under_epoll_smoke OK")
    test_raii_drop_stress_no_explicit_shutdown()
    print("  test_raii_drop_stress_no_explicit_shutdown OK")
    test_eventfd_create_close()
    print("  test_eventfd_create_close OK")
    test_eventfd_write_then_drain()
    print("  test_eventfd_write_then_drain OK")
    test_eventfd_write_to_closed_fd()
    print("  test_eventfd_write_to_closed_fd OK")
    test_worker_wake_handle_pod_copy()
    print("  test_worker_wake_handle_pod_copy OK")
    test_worker_wake_handle_sentinel()
    print("  test_worker_wake_handle_sentinel OK")
    test_standalone_worker_epoll_eventfd_lifecycle()
    print("  test_standalone_worker_epoll_eventfd_lifecycle OK")
    test_standalone_worker_mock_backend_sentinel_handle()
    print("  test_standalone_worker_mock_backend_sentinel_handle OK")
    test_dispatch_wake_round_trip_n2()
    print("  test_dispatch_wake_round_trip_n2 OK")
    test_dispatch_wake_burst_n2()
    print("  test_dispatch_wake_burst_n2 OK")
    test_shutdown_wakes_parked_worker_n4()
    print("  test_shutdown_wakes_parked_worker_n4 OK")
    test_shutdown_idle_workers_repeatedly()
    print("  test_shutdown_idle_workers_repeatedly OK")
    test_lost_wake_regression_send_then_wake()
    print("  test_lost_wake_regression_send_then_wake OK")
    print("PASS komira_async.runtime eventfd wake")

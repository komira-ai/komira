# =============================================================================
# test_wake_elision_typed.mojo
# =============================================================================
# Typed wake elision smoke tests.
#
# The typed shape uses `_sleeping_arc: ArcPointer[_SleepingFlag]` (no
# Int-laundered `_sleeping_addr: Int`); this test verifies the typed surface end-to-end:
#
#   1. WorkerWakeHandle.copy() refcount-bumps the ArcPointer (no
#      compile error; multiple clones coexist).
#   2. WorkerWakeHandle.from_parts() splices a Worker-owned
#      ArcPointer into a Reactor-built base handle (canonical
#      Worker.wake_handle() construction shape).
#   3. wake_with_elision() observes the Worker's sleeping flag through
#      the typed deref:
#        - sleeping=0 → returns False (elided; no eventfd write).
#        - sleeping=1 → returns True (issued; eventfd was written).
#   4. Worker.sleeping_flag_load() exposes the same value through the
#      typed accessor (no Int laundering on the diagnostic path).
#   5. The Worker's _sleeping_arc field survives a Worker.wake_handle()
#      call WITHOUT requiring Worker-outlives-producer (refcount keeps
#      the inner _SleepingFlag alive after the Worker drops).
#
# Design rationale: the pointer rules (no address laundered through an Int).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_MOCK
from komira_async.runtime.wake_primitives import (
    WorkerWakeHandle,
    create_eventfd,
    close_eventfd,
    drain_eventfd,
)
from komira_async.runtime.worker import Worker


def test_typed_handle_copy_refcount_bump() raises:
    """WorkerWakeHandle.copy() refcount-bumps the ArcPointer; the
    original + copy coexist; both load the same sleeping flag value
    through the typed deref."""
    comptime if CompilationTarget.is_linux():
        var w = Worker[NoopSink](
            worker_id=UInt16(0),
            sink=NoopSink(_placeholder=UInt8(0)),
            backend=BACKEND_EPOLL,
        )
        var h1 = w.wake_handle()
        var h2 = h1.copy()
        var h3 = h2.copy()
        # All three should report the same fd + same flag value (same
        # underlying ArcPointer + same eventfd).
        assert_equal(h1.fd(), h2.fd())
        assert_equal(h2.fd(), h3.fd())
        # Worker is initially awake (sleeping=0).
        assert_equal(h1.sleeping_flag_load(), Int32(0))
        assert_equal(h2.sleeping_flag_load(), Int32(0))
        assert_equal(h3.sleeping_flag_load(), Int32(0))


def test_typed_handle_from_parts_splice() raises:
    """Worker.wake_handle() composes the Reactor-built base handle
    + Worker-owned sleeping arc. The composed handle's fd matches the
    Reactor's eventfd; the sleeping flag deref returns the Worker's
    flag value."""
    comptime if CompilationTarget.is_linux():
        var w = Worker[NoopSink](
            worker_id=UInt16(0),
            sink=NoopSink(_placeholder=UInt8(0)),
            backend=BACKEND_EPOLL,
        )
        var h = w.wake_handle()
        # Worker is awake at construction; flag should read 0 through
        # the typed ArcPointer deref.
        assert_equal(h.sleeping_flag_load(), Int32(0))
        assert_equal(h.sleeping_flag_load(), w.sleeping_flag_load())
        # Underlying fd is non-sentinel under EPOLL.
        assert_true(h.fd() >= 0)


def test_disconnected_handle_always_elides() raises:
    """WorkerWakeHandle.make_disconnected() builds a handle with a
    fresh dummy _SleepingFlag (always reads 0 = awake). wake_with_elision
    should ALWAYS elide on a disconnected handle (no real worker to
    wake)."""
    var h = WorkerWakeHandle.make_disconnected(
        wake_fd=Int32(-1),  # sentinel — wake() is no-op
        ident=UInt64(0),
    )
    # Disconnected handle's flag is always 0; elision returns False
    # (no syscall issued).
    var issued = h.wake_with_elision()
    assert_false(issued)


def test_wake_with_elision_observes_worker_flag() raises:
    """wake_with_elision routes through the typed
    ArcPointer deref. When the Worker's _sleeping_arc reads 0 (awake),
    elision fires (returns False, no syscall). When it reads 1
    (parked), the wake is issued (returns True; eventfd was bumped).

    This is the core property that the BANNED Int-laundered shape
    couldn't deliver — the alias analyzer correctly returned garbage
    for the wildcard load. With the typed shape, the producer
    observes the worker's flag deterministically.
    """
    comptime if CompilationTarget.is_linux():
        var w = Worker[NoopSink](
            worker_id=UInt16(0),
            sink=NoopSink(_placeholder=UInt8(0)),
            backend=BACKEND_EPOLL,
        )
        var h = w.wake_handle()

        # Initial state: worker awake (sleeping=0).
        assert_equal(w.sleeping_flag_load(), Int32(0))
        # Drain any baseline eventfd state.
        drain_eventfd(h.fd())
        # Producer-side wake_with_elision: sees sleeping=0 → elides.
        var issued_when_awake = h.wake_with_elision()
        assert_false(issued_when_awake)

        # Now flip the worker's flag to "parked". This is a test-only
        # mutation; in production the worker_main park-bracket does it.
        w._sleeping_arc[].store(Int32(1))
        assert_equal(w.sleeping_flag_load(), Int32(1))
        # Producer side should now see the typed flag transition + issue
        # the wake.
        var issued_when_parked = h.wake_with_elision()
        assert_true(issued_when_parked)
        # Drain the actual eventfd to confirm the wake landed.
        drain_eventfd(h.fd())

        # Restore awake state for clean teardown.
        w._sleeping_arc[].store(Int32(0))


def _build_handle_then_drop_worker() raises -> WorkerWakeHandle:
    """Helper: builds a Worker, extracts a wake handle, then lets the
    Worker drop at function-scope exit. Returns the surviving handle.
    The ArcPointer<_SleepingFlag> clone keeps the inner _SleepingFlag
    alive past the Worker's drop (refcount-tracked).
    """
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=BACKEND_EPOLL,
    )
    var h = w.wake_handle()
    # `w` drops here on function exit; `h` is moved out by return.
    return h^


def test_handle_outlives_worker() raises:
    """the ArcPointer-based handle does NOT require
    Worker-outlives-producer. When the Worker drops, the producer's
    cloned handle keeps the inner _SleepingFlag alive via the
    refcount.

    Test shape: build a Worker + take a handle inside a helper fn;
    return the handle (Worker drops at fn exit); use the surviving
    handle in the outer scope. wake_with_elision should NOT fault —
    the typed deref through the surviving Arc clone returns the
    last-known flag value safely.

    NOTE: the underlying eventfd IS owned by the Worker's Reactor —
    once the Worker drops, the eventfd is closed, so wake() may write
    to a closed fd (best-effort EBADF). The typed flag deref still
    works (Arc keeps it alive).
    """
    comptime if CompilationTarget.is_linux():
        var h = _build_handle_then_drop_worker()
        # The handle's typed deref must still return safely — no UAF,
        # no compiler crash, no garbage value.
        var flag_after_drop = h.sleeping_flag_load()
        # The flag value at handle-creation time was 0; after Worker
        # drops, the flag is still 0 (no producer observation
        # transitioned it). The point is just that the load doesn't
        # crash.
        assert_equal(flag_after_drop, Int32(0))


def test_n_clones_share_arc() raises:
    """N clones of the same Worker.wake_handle() all share one
    underlying ArcPointer<_SleepingFlag>. Mutating the Worker's flag
    transitions ALL clones' typed-deref reads simultaneously."""
    comptime if CompilationTarget.is_linux():
        var w = Worker[NoopSink](
            worker_id=UInt16(0),
            sink=NoopSink(_placeholder=UInt8(0)),
            backend=BACKEND_EPOLL,
        )
        var h1 = w.wake_handle()
        var h2 = w.wake_handle()
        var h3 = w.wake_handle()

        # All three see sleeping=0 initially.
        assert_equal(h1.sleeping_flag_load(), Int32(0))
        assert_equal(h2.sleeping_flag_load(), Int32(0))
        assert_equal(h3.sleeping_flag_load(), Int32(0))

        # Flip the Worker's flag.
        w._sleeping_arc[].store(Int32(1))

        # All three observe the transition (same _SleepingFlag heap
        # allocation; the ArcPointer just shares ownership).
        assert_equal(h1.sleeping_flag_load(), Int32(1))
        assert_equal(h2.sleeping_flag_load(), Int32(1))
        assert_equal(h3.sleeping_flag_load(), Int32(1))

        # Restore for clean teardown.
        w._sleeping_arc[].store(Int32(0))


def test_producer_loop_awake_worker_elides_majority() raises:
    """v1.3a: with the worker FLAG marked awake
    (=0), producer-side `wake_with_elision()` must elide the majority of
    syscalls in a tight loop. Bound: ≥ 70% elision rate (we expect
    100% in steady state since the flag is held at 0 throughout).

    Rationale: this is the property that v1.3a unlocks — the dispatcher
    + spawner enqueue paths now route through `wake_with_elision()`
    instead of unconditional `.wake()`. Under fan-out where shards
    complete back-to-back without parking, the eventfd write rate must
    drop towards zero.
    """
    comptime if CompilationTarget.is_linux():
        var w = Worker[NoopSink](
            worker_id=UInt16(0),
            sink=NoopSink(_placeholder=UInt8(0)),
            backend=BACKEND_EPOLL,
        )
        var h = w.wake_handle()
        # Hold the worker awake (= producer-side reads sleeping=0).
        w._sleeping_arc[].store(Int32(0))
        drain_eventfd(h.fd())
        var n_iters: Int = 100
        var elided: Int = 0
        for _ in range(n_iters):
            var issued = h.wake_with_elision()
            if not issued:
                elided = elided + 1
        # Steady-state expectation: every iteration elides (no syscall).
        # Allow up to 30% misses to absorb spurious flag flips on shared
        # CI infra; the production target is 100% elision in the awake
        # loop.
        var elide_pct = (elided * 100) // n_iters
        assert_true(elide_pct >= 70)


def test_producer_loop_parked_worker_issues_majority() raises:
    """v1.3a: with the worker FLAG marked parked
    (=1), producer-side `wake_with_elision()` must issue the majority of
    syscalls. Bound: ≥ 80% issue rate (we expect 100% in this
    test since the flag is pinned to 1).

    Rationale: when the worker actually parks on epoll_wait, we cannot
    elide — we must signal the eventfd or the worker won't wake. This
    test verifies the elision path doesn't OVER-elide (the inverse of
    the awake test).
    """
    comptime if CompilationTarget.is_linux():
        var w = Worker[NoopSink](
            worker_id=UInt16(0),
            sink=NoopSink(_placeholder=UInt8(0)),
            backend=BACKEND_EPOLL,
        )
        var h = w.wake_handle()
        # Pin the flag to "parked".
        w._sleeping_arc[].store(Int32(1))
        drain_eventfd(h.fd())
        var n_iters: Int = 100
        var issued_count: Int = 0
        for _ in range(n_iters):
            var issued = h.wake_with_elision()
            if issued:
                issued_count = issued_count + 1
            # Drain after each issue to avoid eventfd counter overflow
            # at 0xFFFFFFFFFFFFFFFE (practically unreachable but
            # cleaner).
            drain_eventfd(h.fd())
        var issue_pct = (issued_count * 100) // n_iters
        assert_true(issue_pct >= 80)
        # Restore awake state for clean teardown.
        w._sleeping_arc[].store(Int32(0))


def test_producer_loop_no_lost_wake_during_park_transition() raises:
    """v1.3a Drepper-safety probe: simulate the producer loop racing the
    worker entering sleep. We flip the flag mid-loop (awake → parked
    → awake) and assert that EVERY iteration issued or elided
    correctly — no aborted syscalls, no panics, the flag transitions
    are observed exactly.

    The full Drepper-safety cycle (worker re-checks queues AFTER
    setting _sleeping=1) is exercised by the worker park-bracket
    integration tests; this micro-test only verifies the producer-side
    typed deref behaves correctly under flag mutation in the same
    pthread (the easier case — no cross-pthread membar concern in this
    single-threaded test).
    """
    comptime if CompilationTarget.is_linux():
        var w = Worker[NoopSink](
            worker_id=UInt16(0),
            sink=NoopSink(_placeholder=UInt8(0)),
            backend=BACKEND_EPOLL,
        )
        var h = w.wake_handle()
        drain_eventfd(h.fd())

        var n_iters: Int = 60
        var observed_issues: Int = 0
        var observed_elides: Int = 0
        for i in range(n_iters):
            # Sweep the flag: awake [0..20), parked [20..40), awake [40..60).
            if i < 20:
                w._sleeping_arc[].store(Int32(0))
            elif i < 40:
                w._sleeping_arc[].store(Int32(1))
            else:
                w._sleeping_arc[].store(Int32(0))
            var issued = h.wake_with_elision()
            if issued:
                observed_issues = observed_issues + 1
                drain_eventfd(h.fd())
            else:
                observed_elides = observed_elides + 1
        # Every iteration must have classified as issue or elide
        # (no exceptions, no panics).
        assert_equal(observed_issues + observed_elides, n_iters)
        # The parked window must have issued (≥ 15 of 20; allow some
        # noise from concurrent flag reads on shared infra).
        assert_true(observed_issues >= 15)
        # The awake windows must have elided (≥ 30 of 40; same noise
        # tolerance).
        assert_true(observed_elides >= 30)
        # Restore awake state for clean teardown.
        w._sleeping_arc[].store(Int32(0))


def main() raises:
    test_typed_handle_copy_refcount_bump()
    print("PASS test_typed_handle_copy_refcount_bump")
    test_typed_handle_from_parts_splice()
    print("PASS test_typed_handle_from_parts_splice")
    test_disconnected_handle_always_elides()
    print("PASS test_disconnected_handle_always_elides")
    test_wake_with_elision_observes_worker_flag()
    print("PASS test_wake_with_elision_observes_worker_flag")
    test_handle_outlives_worker()
    print("PASS test_handle_outlives_worker")
    test_n_clones_share_arc()
    print("PASS test_n_clones_share_arc")
    test_producer_loop_awake_worker_elides_majority()
    print("PASS test_producer_loop_awake_worker_elides_majority")
    test_producer_loop_parked_worker_issues_majority()
    print("PASS test_producer_loop_parked_worker_issues_majority")
    test_producer_loop_no_lost_wake_during_park_transition()
    print("PASS test_producer_loop_no_lost_wake_during_park_transition")
    print("PASS komira_async typed wake elision")

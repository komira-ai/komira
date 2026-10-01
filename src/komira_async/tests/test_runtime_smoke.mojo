# =============================================================================
# test_runtime_smoke.mojo
# =============================================================================
# Worker[S] + PerCoreAsyncRuntime[S] + KqueueSubsystem
# functional tests.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.kqueue_subsystem import KqueueSubsystem
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_MOCK,
)
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PLACEMENT_MAX_PACK,
    PLACEMENT_MAX_SPREAD,
    PerCoreAsyncRuntime,
)
from komira_async.runtime.worker import Worker


def test_placement_constants() raises:
    """Placement sentinels are stable UInt8 values."""
    assert_equal(Int(PLACEMENT_FIXED), 0)
    assert_equal(Int(PLACEMENT_MAX_SPREAD), 1)
    assert_equal(Int(PLACEMENT_MAX_PACK), 2)


def test_kqueue_subsystem_raises_on_linux() raises:
    """KqueueSubsystem.create raises on Linux per the wrong-OS
    branch discipline. On Darwin, this would construct successfully."""
    comptime if CompilationTarget.is_linux():
        var raised = False
        try:
            var _k = KqueueSubsystem.create()
        except:
            raised = True
        assert_true(raised)


def test_worker_construct_mock() raises:
    """Worker[NoopSink] with BACKEND_MOCK constructs cleanly."""
    var w = Worker[NoopSink](
        worker_id=UInt16(7),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=BACKEND_MOCK,
    )
    assert_equal(Int(w.worker_id()), 7)
    assert_false(w.is_shutdown_signaled())


def test_worker_signal_shutdown() raises:
    """signal_shutdown sets the flag; is_shutdown_signaled
    reflects it."""
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=BACKEND_MOCK,
    )
    assert_false(w.is_shutdown_signaled())
    w.signal_shutdown()
    assert_true(w.is_shutdown_signaled())


def test_worker_run_one_iteration_mock_returns_zero() raises:
    """with BACKEND_MOCK + no registered ops, run_one_iteration
    returns 0 immediately."""
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=BACKEND_MOCK,
    )
    var n = w.run_one_iteration(timeout_us=Int32(0))
    assert_equal(n, 0)


def test_worker_run_until_shutdown_exits_when_signaled() raises:
    """run_until_shutdown returns once signal_shutdown is set.

    Synchronous test: signal first, then call run_until_shutdown — the
    flag-check at the top of the loop fires immediately and the loop
    exits without doing any work.
    """
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=BACKEND_MOCK,
    )
    w.signal_shutdown()
    # Should exit on the first iteration check.
    w.run_until_shutdown()
    assert_true(w.is_shutdown_signaled())


def test_per_core_runtime_construct_empty() raises:
    """empty runtime starts with 0
    workers."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_MAX_SPREAD)
    assert_equal(Int(rt.worker_count()), 0)


def test_per_core_runtime_attach_worker() raises:
    """attach_worker installs a worker;
    worker_count becomes 1; back-compat shim for the n=1 case.

    Multi-worker semantics: attach_worker can be called repeatedly,
    each call appends a fresh Worker. The "second attach
    raises" rule is removed (was a single-worker policy not a structural
    invariant).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_MAX_SPREAD)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    assert_equal(Int(rt.worker_count()), 1)
    assert_equal(Int(rt.worker().worker_id()), 0)
    # Multi-worker semantics: a second attach appends, does not raise.
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    assert_equal(Int(rt.worker_count()), 2)
    assert_equal(Int(rt.worker_at(1).worker_id()), 1)


def test_per_core_runtime_signal_shutdown_all() raises:
    """signal_shutdown_all broadcasts to the single
    attached worker."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_MAX_SPREAD)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    assert_false(rt.worker().is_shutdown_signaled())
    rt.signal_shutdown_all()
    assert_true(rt.worker().is_shutdown_signaled())


def test_per_core_runtime_start_shutdown_pthread() raises:
    """PerCoreAsyncRuntime.start() launches a pthread; the
    pthread runs Worker.run_until_shutdown(); shutdown() signals + joins.

    BACKEND_MOCK so the pthread doesn't open an epoll fd; the worker's
    run_until_shutdown loop polls the shutdown flag every 1ms and exits
    cleanly.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    # Launch the pthread.
    rt.start()
    # Brief sleep is unnecessary — shutdown signals the worker which exits
    # on the next 1ms iteration.
    rt.shutdown()
    # Verify the worker is still accessible (it's still attached; just
    # not running).
    assert_equal(Int(rt.worker_count()), 1)


def test_per_core_runtime_start_without_worker_raises() raises:
    """start() before attach_worker raises."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    var raised = False
    try:
        rt.start()
    except:
        raised = True
    assert_true(raised)


def test_per_core_runtime_double_start_raises() raises:
    """double-start raises (idempotent shutdown still allows
    fresh start after shutdown — but back-to-back start without shutdown is
    rejected)."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    rt.start()
    var raised = False
    try:
        rt.start()
    except:
        raised = True
    assert_true(raised)
    rt.shutdown()


def test_worker_epoll_socketpair_e2e() raises:
    """full Worker → IoSubsystem → Reactor → epoll
    pipeline. Register a read on a socketpair; signal it; run one
    iteration; verify the op is reported ready.

    This is the load-bearing integration test for the whole
    foundational layer — it touches all 7 components except the
    Darwin-only KqueueSubsystem and the testonly MockSubsystem.
    """
    comptime if CompilationTarget.is_linux():
        # Construct a worker with EPOLL backend.
        var w = Worker[NoopSink](
            worker_id=UInt16(0),
            sink=NoopSink(_placeholder=UInt8(0)),
            backend=BACKEND_EPOLL,
        )
        # Set up a socketpair.
        var sv = Array[Int32, 2](fill=Int32(-1))
        var rc = external_call["socketpair", Int32](
            Int32(1),  # AF_UNIX
            Int32(1),  # SOCK_STREAM
            Int32(0),
            sv.unsafe_ptr(),
        )
        if rc < 0:
            raise Error("socketpair() failed")
        # Register read on sv[0] via the worker's reactor.
        var op_id = w.io_subsystem().alloc_op_id()
        w.io_subsystem().reactor().register_read(sv[0], op_id, UInt16(0))
        # Send 1 byte to signal.
        var byte = Array[UInt8, 1](fill=UInt8(0xFF))
        var written = external_call["send", Int](
            sv[1], byte.unsafe_ptr(), UInt(1), Int32(0)
        )
        if written != Int(1):
            raise Error("send() failed in test")
        # Drive one iteration.
        var n = w.run_one_iteration(timeout_us=Int32(10_000))
        assert_true(n >= 1)
        assert_true(w.io_subsystem().reactor().is_ready(op_id))
        # Cleanup.
        w.io_subsystem().reactor().deregister(op_id)
        _ = external_call["close", Int32](sv[0])
        _ = external_call["close", Int32](sv[1])


def main() raises:
    test_placement_constants()
    test_kqueue_subsystem_raises_on_linux()
    test_worker_construct_mock()
    test_worker_signal_shutdown()
    test_worker_run_one_iteration_mock_returns_zero()
    test_worker_run_until_shutdown_exits_when_signaled()
    test_per_core_runtime_construct_empty()
    test_per_core_runtime_attach_worker()
    test_per_core_runtime_signal_shutdown_all()
    test_per_core_runtime_start_shutdown_pthread()
    test_per_core_runtime_start_without_worker_raises()
    test_per_core_runtime_double_start_raises()
    test_worker_epoll_socketpair_e2e()
    print("PASS komira_async.runtime smoke")

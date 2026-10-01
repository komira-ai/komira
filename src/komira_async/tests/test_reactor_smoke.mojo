# =============================================================================
# test_reactor_smoke.mojo
# =============================================================================
# Reactor[S] + EpollSubsystem + MockSubsystem functional tests.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.epoll_subsystem import EpollSubsystem
from komira_async.reactor.kqueue_subsystem import KqueueSubsystem
from komira_async.reactor.mock_subsystem import MockSubsystem
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    BACKEND_MOCK,
    IoSubsystem,
    Reactor,
    WakerSlot,
)


def test_backend_kind_constants() raises:
    """BackendKind sentinels are stable UInt8 values."""
    assert_equal(Int(BACKEND_MOCK), 0)
    assert_equal(Int(BACKEND_EPOLL), 1)
    assert_equal(Int(BACKEND_KQUEUE), 2)


def test_mock_subsystem_inject_drain() raises:
    """MockSubsystem deterministic readiness injection."""
    var s = MockSubsystem()
    var op1 = s.alloc_op_id()
    var op2 = s.alloc_op_id()
    var op3 = s.alloc_op_id()
    s.register_read(Int32(99), op1, UInt16(0))
    s.register_read(Int32(99), op2, UInt16(0))
    s.register_read(Int32(99), op3, UInt16(0))
    assert_equal(s.registered_count(), 3)
    # Inject in non-monotone order; drain must preserve insertion order.
    s.inject_ready(op2)
    s.inject_ready(op1)
    s.inject_ready(op3)
    assert_equal(s.ready_count(), 3)
    var drained = s.poll_ready_drain()
    assert_equal(len(drained), 3)
    assert_equal(drained[0], op2)
    assert_equal(drained[1], op1)
    assert_equal(drained[2], op3)
    # After drain, queue is empty.
    assert_equal(s.ready_count(), 3 - 3)


def test_mock_subsystem_deregister_blocks_injection() raises:
    """deregistered ops cannot be injected ready."""
    var s = MockSubsystem()
    var op1 = s.alloc_op_id()
    s.register_read(Int32(0), op1, UInt16(0))
    s.deregister(op1)
    s.inject_ready(op1)
    # The op was deregistered before inject; inject is a no-op for
    # unregistered op_ids.
    assert_equal(s.ready_count(), 0)


def test_mock_alloc_op_id_monotone() raises:
    """op_id allocator is monotone."""
    var s = MockSubsystem()
    var a = s.alloc_op_id()
    var b = s.alloc_op_id()
    var c = s.alloc_op_id()
    assert_true(b > a)
    assert_true(c > b)


def test_kqueue_subsystem_raises_on_linux() raises:
    """KqueueSubsystem.create
    raises on Linux per the wrong-OS branch discipline."""
    comptime if CompilationTarget.is_linux():
        var raised = False
        try:
            var _k = KqueueSubsystem.create()
        except:
            raised = True
        assert_true(raised)


def test_reactor_mock_backend_construct_destroy() raises:
    """Reactor[NoopSink] with BACKEND_MOCK constructs without
    an epoll fd; run_once returns 0; destruction is clean."""
    var r = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK
    )
    var n = r.run_once(timeout_us=Int32(0))
    assert_equal(n, 0)
    assert_false(r.is_ready(Int64(1)))


def test_reactor_alloc_op_id_monotone() raises:
    """Reactor.alloc_op_id is monotone."""
    var r = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK
    )
    var a = r.alloc_op_id()
    var b = r.alloc_op_id()
    var c = r.alloc_op_id()
    assert_true(b > a)
    assert_true(c > b)


def test_iosubsystem_mock_alloc_run() raises:
    """IoSubsystem[NoopSink](BACKEND_MOCK) wraps a Reactor
    correctly; alloc_op_id forwards; run_once returns 0."""
    var sub = IoSubsystem[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK
    )
    var op = sub.alloc_op_id()
    assert_true(op > Int64(0))
    var n = sub.run_once(timeout_us=Int32(0))
    assert_equal(n, 0)


def test_epoll_subsystem_create_close() raises:
    """EpollSubsystem.create returns a valid fd; __del__
    closes it. On macOS, create raises."""
    comptime if CompilationTarget.is_linux():
        var e = EpollSubsystem.create()
        assert_true(e.fd() >= Int32(0))
        # Drop e; __del__ closes the fd. No way to assert close from
        # userspace without reaching for /proc/self/fd; the smoke test
        # is "no leak panics".
    else:
        var raised = False
        try:
            var _e = EpollSubsystem.create()
        except:
            raised = True
        assert_true(raised)


# Linux socket constants — for socketpair() helper used by epoll readiness
# tests (we use socketpair instead of pipe because Mojo 0.26.3 stdlib
# already binds a `write` symbol; `send` is the test-friendly alternative
# finding).
comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)


def _socketpair_unix_stream() raises -> Array[Int32, 2]:
    """SAFETY: pair is stack-local; the kernel writes 2 fds into it and
    does not retain the pointer. Confined to this test helper."""
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), pair.unsafe_ptr()
    )
    if rc < 0:
        raise Error("socketpair() failed")
    return pair^


def _send_one_byte(fd: Int32, b: UInt8) raises:
    var buf = Array[UInt8, 1](fill=b)
    # SAFETY: buf stack-local; kernel reads only.
    var w = external_call["send", Int](
        fd, buf.unsafe_ptr(), UInt(1), Int32(0)
    )
    if w != Int(1):
        raise Error("send() failed")


def test_reactor_epoll_socketpair_register_readiness() raises:
    """real epoll wiring against a socketpair.

    Steps:
      1. Create a socketpair (sv[0], sv[1]).
      2. Construct Reactor[NoopSink] with BACKEND_EPOLL.
      3. register_read on sv[0] with op_id.
      4. send() 1 byte to sv[1] from this thread.
      5. run_once(timeout_us=10_000) — expect n >= 1.
      6. Assert is_ready(op_id) == True.
      7. deregister(op_id); close fds.

    Uses socketpair instead of pipe because Mojo 0.26.3 stdlib binds the
    libc `write` symbol; `send` (over an AF_UNIX SOCK_STREAM socketpair)
    is byte-equivalent for our test purposes.
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL
        )
        var op_id = r.alloc_op_id()
        r.register_read(sv[0], op_id, UInt16(0))

        _send_one_byte(sv[1], UInt8(0xAB))

        var n = r.run_once(timeout_us=Int32(10_000))
        assert_true(n >= 1)
        assert_true(r.is_ready(op_id))

        r.deregister(op_id)
        _ = external_call["close", Int32](sv[0])
        _ = external_call["close", Int32](sv[1])


def test_reactor_epoll_multiple_concurrent_ops() raises:
    """multiple registered ops; only signaled ones
    are reported ready."""
    comptime if CompilationTarget.is_linux():
        var sv1 = _socketpair_unix_stream()
        var sv2 = _socketpair_unix_stream()
        var sv3 = _socketpair_unix_stream()

        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL
        )
        var op1 = r.alloc_op_id()
        var op2 = r.alloc_op_id()
        var op3 = r.alloc_op_id()
        r.register_read(sv1[0], op1, UInt16(0))
        r.register_read(sv2[0], op2, UInt16(0))
        r.register_read(sv3[0], op3, UInt16(0))

        # Signal only sv2.
        _send_one_byte(sv2[1], UInt8(1))

        var n = r.run_once(timeout_us=Int32(10_000))
        assert_true(n >= 1)
        assert_false(r.is_ready(op1))
        assert_true(r.is_ready(op2))
        assert_false(r.is_ready(op3))

        # Cleanup.
        r.deregister(op1)
        r.deregister(op2)
        r.deregister(op3)
        for sv in [sv1^, sv2^, sv3^]:
            _ = external_call["close", Int32](sv[0])
            _ = external_call["close", Int32](sv[1])


def main() raises:
    test_backend_kind_constants()
    test_mock_subsystem_inject_drain()
    test_mock_subsystem_deregister_blocks_injection()
    test_mock_alloc_op_id_monotone()
    test_kqueue_subsystem_raises_on_linux()
    test_reactor_mock_backend_construct_destroy()
    test_reactor_alloc_op_id_monotone()
    test_iosubsystem_mock_alloc_run()
    test_epoll_subsystem_create_close()
    test_reactor_epoll_socketpair_register_readiness()
    test_reactor_epoll_multiple_concurrent_ops()
    print("PASS komira_async.reactor smoke")

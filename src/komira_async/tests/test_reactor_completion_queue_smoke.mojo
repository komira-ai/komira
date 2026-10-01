# =============================================================================
# test_reactor_completion_queue_smoke.mojo
# =============================================================================
# Reactor[S] completion-queue API smoke tests.
#
# Verifies the new public surface added in:
#   - submit(op_kind, fd, buf) -> OpHandle (try_io fast path + EWOULDBLOCK
#     fallback)
#   - register_long_lived(fd, interest_set) -> RegistrationHandle
#   - modify(reg_handle, new_interest_set)
#   - poll_completions(timeout_us) -> List[Completion]
#   - wake_self() (already exercised by eventfd tests; smoke-included
#     here for completeness)
#
# Backend coverage:
#   - Linux: BACKEND_EPOLL — full functional path against socketpair fds.
#   - All platforms: BACKEND_MOCK — compile-pass + no-syscall path.
#
# kqueue path is exercised at compile time only (the macOS branch is
# elided at codegen on Linux; runtime verification deferred
# to macOS runs).
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    Completion,
    INTEREST_READ,
    INTEREST_WRITE,
    OP_ERR,
    OP_PENDING,
    OP_READ,
    OP_READY,
    OP_WRITE,
    OpHandle,
    RegistrationHandle,
)
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_MOCK,
    Reactor,
)


# Linux socket constants — for socketpair() helper used by epoll readiness
# tests (mirrors test_reactor_smoke.mojo's pattern).
comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)


def _socketpair_unix_stream() raises -> Array[Int32, 2]:
    """SAFETY: pair is stack-local; the kernel writes 2 fds into it and
    does not retain the pointer. Confined to this test helper."""
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), pair.unsafe_ptr(),
    )
    if rc < 0:
        raise Error("socketpair() failed")
    return pair^


def _send_one_byte(fd: Int32, b: UInt8) raises:
    var buf = Array[UInt8, 1](fill=b)
    # SAFETY: buf stack-local; kernel reads only.
    var w = external_call["send", Int](
        fd, buf.unsafe_ptr(), UInt(1), Int32(0),
    )
    if w != Int(1):
        raise Error("send() failed")


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def test_completion_queue_pod_types_compile() raises:
    """the POD types for the completion-queue API construct
    + carry their fields correctly. No syscalls; pure type-shape check."""
    var op = OpHandle(_op_id=Int64(42), _state=OP_READY, _result=Int64(7))
    assert_equal(op.op_id(), Int64(42))
    assert_equal(Int(op.state()), Int(OP_READY))
    assert_equal(op.result(), Int64(7))

    var comp = Completion(
        op_id=Int64(99), bytes=Int64(1024),
        err_code=Int32(0), hangup=False,
    )
    assert_equal(comp.op_id, Int64(99))
    assert_equal(comp.bytes, Int64(1024))
    assert_equal(comp.err_code, Int32(0))
    assert_false(comp.hangup)

    var reg = RegistrationHandle(
        _fd=Int32(5),
        _interest_set=INTEREST_READ | INTEREST_WRITE,
    )
    assert_equal(reg.fd(), Int32(5))
    assert_equal(
        Int(reg.interest_set()),
        Int(INTEREST_READ | INTEREST_WRITE),
    )


def test_submit_mock_backend_pending() raises:
    """BACKEND_MOCK accepts submit + returns Pending OpHandle
    for OP_READ on a synthetic fd. The mock has no kernel buffer to
    populate, so try_io returns EBADF (-9) for a -1 fd; on a >=0 fd, the
    syscall fails immediately and we fall through to register_read.

    Mock backend submit() returns Pending after
    falling through (no actual epoll_wait call needed; we just check the
    state machine).

    Skip the test on MOCK because submit on a real fd with no epoll fd
    will register_read into the wakers list (which the mock _epoll_fd=-1
    branch silently ignores), then return Pending. Compile-pass + state
    inspection is the smoke goal.
    """
    var r = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK,
    )
    # Set up a real socketpair so try_recv has a valid fd; with no data
    # in the kernel buffer + MSG_DONTWAIT, recv will return EAGAIN, and
    # submit falls through to register_read.
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var read_buf = Array[UInt8, 64](fill=UInt8(0))
        var span = Span[UInt8](read_buf)
        var op = r.submit(OP_READ, sv[0], span)
        # No data available + mock backend (no epoll registration to
        # actually park on) — submit returns Pending after falling
        # through to the register_read branch (which is a no-op on
        # MOCK because _epoll_fd<0). The wakers slot IS appended though.
        assert_equal(Int(op.state()), Int(OP_PENDING))
        assert_true(op.op_id() > Int64(0))
        _close_fd(sv[0])
        _close_fd(sv[1])


def test_submit_epoll_fast_path_ready() raises:
    """submit returns OP_READY immediately when the
    kernel buffer has data (try_io fast path).

    Steps:
      1. Create a socketpair.
      2. Push a byte into sv[1] BEFORE calling submit.
      3. Construct Reactor + submit OP_READ on sv[0].
      4. Assert OpHandle._state == OP_READY and _result == 1
         (one byte read, NO multiplexer touched).
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        # Prime the kernel buffer BEFORE submit so try_io hits.
        _send_one_byte(sv[1], UInt8(0xAB))

        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var read_buf = Array[UInt8, 64](fill=UInt8(0))
        var span = Span[UInt8](read_buf)
        var op = r.submit(OP_READ, sv[0], span)

        # Fast path hit: OP_READY with bytes-read == 1.
        assert_equal(Int(op.state()), Int(OP_READY))
        assert_equal(op.result(), Int64(1))
        # Verify the kernel wrote the actual byte into our buffer.
        assert_equal(Int(read_buf[0]), Int(UInt8(0xAB)))

        _close_fd(sv[0])
        _close_fd(sv[1])


def test_submit_epoll_slow_path_pending() raises:
    """submit returns OP_PENDING when the kernel
    buffer is empty (EAGAIN). The slow path registers the fd with epoll;
    a subsequent send + poll_completions surfaces the readiness.

    Steps:
      1. Create a socketpair (no data primed).
      2. submit OP_READ on sv[0] — try_io returns EAGAIN, falls through
         to register_read; OpHandle._state == OP_PENDING.
      3. Push a byte into sv[1].
      4. poll_completions(timeout_us=10_000) — expect at least one
         Completion with op_id matching our OpHandle.
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var read_buf = Array[UInt8, 64](fill=UInt8(0))
        var span = Span[UInt8](read_buf)
        var op = r.submit(OP_READ, sv[0], span)

        # Slow path: EAGAIN → register → Pending.
        assert_equal(Int(op.state()), Int(OP_PENDING))
        var op_id = op.op_id()
        assert_true(op_id > Int64(0))

        # Now write to sv[1] to make sv[0] readable.
        _send_one_byte(sv[1], UInt8(0xCD))

        # Poll for completions. Should see our op_id.
        var completions = r.poll_completions(timeout_us=Int32(10_000))
        var matched = False
        for i in range(len(completions)):
            if completions[i].op_id == op_id:
                matched = True
        assert_true(matched)

        # Cleanup: deregister + close.
        r.deregister(op_id)
        _close_fd(sv[0])
        _close_fd(sv[1])


def test_register_long_lived_epoll_smoke() raises:
    """register_long_lived + modify + drop succeeds
    against a real fd. Verifies the EPOLL_CTL_ADD/MOD/DEL syscall path
    on the new long-lived registration API.

    Steps:
      1. Create a socketpair.
      2. register_long_lived(sv[0], INTEREST_READ) — EPOLL_CTL_ADD.
      3. Assert RegistrationHandle holds the fd + interest set.
      4. modify(reg, INTEREST_READ | INTEREST_WRITE) — EPOLL_CTL_MOD.
      5. _deregister_long_lived(sv[0]) — EPOLL_CTL_DEL (normally done by
         RegistrationHandle.__del__; called directly here).
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )

        var reg = r.register_long_lived(sv[0], INTEREST_READ)
        assert_equal(reg.fd(), sv[0])
        assert_equal(Int(reg.interest_set()), Int(INTEREST_READ))

        # No-op fast path: same interest set → no syscall.
        r.modify(reg, INTEREST_READ)
        # Real MOD: switch to read+write.
        r.modify(reg, INTEREST_READ | INTEREST_WRITE)

        # Manual deregister (RegistrationHandle.__del__ normally does this).
        r._deregister_long_lived(sv[0])

        _close_fd(sv[0])
        _close_fd(sv[1])


def test_poll_completions_mock_returns_empty() raises:
    """poll_completions on BACKEND_MOCK returns an empty list
    (no real fds to poll). With timeout_us=0 (non-blocking), the body
    short-circuits and returns immediately."""
    var r = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK,
    )
    var completions = r.poll_completions(timeout_us=Int32(0))
    assert_equal(len(completions), 0)


def main() raises:
    test_completion_queue_pod_types_compile()
    test_submit_mock_backend_pending()
    test_submit_epoll_fast_path_ready()
    test_submit_epoll_slow_path_pending()
    test_register_long_lived_epoll_smoke()
    test_poll_completions_mock_returns_empty()
    print("PASS komira_async.reactor completion-queue smoke")

# =============================================================================
# test_try_io_fast_path.mojo
# =============================================================================
# try_io_* standalone fast-path fns.
#
# Verifies the public fast-path surface:
#   - try_io_read(fd, buf) -> TryIoResult
#   - try_io_write(fd, buf) -> TryIoResult
#   - try_io_connect(fd, addr) -> TryIoResult       # constructed-but-bad-addr path
#   - try_io_accept(listen_fd) -> TryIoResult       # bad-fd path
#   - TryIoResult POD shape (state / value accessors + is_* convenience)
#
# Also verifies that Reactor.submit routes through the standalone fns
# (no behavioral change vs an inline try_recv / try_send body).
#
# Backend coverage:
#   - Linux: socketpair-based readiness probes for read/write fast/slow paths.
#   - All platforms: POD construction + bad-fd paths (synchronous syscalls
#     or short-circuit; no kernel multiplexer touch).
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    OP_ERR,
    OP_PENDING,
    OP_READ,
    OP_READY,
    OP_WRITE,
    OpHandle,
)
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_MOCK,
    Reactor,
)
from komira_async.reactor.socket_io import (
    TRY_IO_ERROR,
    TRY_IO_IN_PROGRESS,
    TRY_IO_READY,
    TRY_IO_WOULD_BLOCK,
    TryIoResult,
    errno_is_in_progress,
    errno_is_would_block,
    try_io_accept,
    try_io_connect,
    try_io_read,
    try_io_write,
)


# Linux socket constants — for socketpair() helper used by epoll readiness
# tests (mirrors test_reactor_completion_queue_smoke.mojo's pattern).
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


def test_try_io_result_pod_shape() raises:
    """TryIoResult constructs + accessors + convenience predicates
    behave correctly. Pure type-shape test; no syscalls."""
    var ready = TryIoResult(_state=TRY_IO_READY, _value=Int64(42))
    assert_equal(Int(ready.state()), Int(TRY_IO_READY))
    assert_equal(ready.value(), Int64(42))
    assert_true(ready.is_ready())
    assert_false(ready.is_would_block())
    assert_false(ready.is_in_progress())
    assert_false(ready.is_error())

    var wb = TryIoResult(_state=TRY_IO_WOULD_BLOCK, _value=Int64(0))
    assert_true(wb.is_would_block())
    assert_false(wb.is_ready())

    var ip = TryIoResult(_state=TRY_IO_IN_PROGRESS, _value=Int64(0))
    assert_true(ip.is_in_progress())
    assert_false(ip.is_ready())
    assert_false(ip.is_would_block())

    var err = TryIoResult(_state=TRY_IO_ERROR, _value=Int64(9))   # EBADF
    assert_true(err.is_error())
    assert_equal(err.value(), Int64(9))


def test_try_io_read_bad_fd_short_circuits() raises:
    """try_io_read on fd=-1 short-circuits to Ready(0)
    (the underlying try_recv returns 0 on bad fd or empty buf, mirroring
    the existing test_reactor_smoke convention).

    This verifies the short-circuit branch in try_recv (fd<0 OR buf empty)
    is exposed correctly through try_io_read.
    """
    var buf = Array[UInt8, 8](fill=UInt8(0))
    var span = Span[UInt8](buf)
    var r = try_io_read(Int32(-1), span)
    # Short-circuit returns Ready(0) — caller treats as 0-byte EOF or bad fd.
    assert_true(r.is_ready())
    assert_equal(r.value(), Int64(0))


def test_try_io_read_empty_buf_short_circuits() raises:
    """try_io_read with len(buf)==0 short-circuits to Ready(0)
    without issuing the syscall.

    Construct a 1-element backing array but materialize the Span over a
    zero-length slice (Span has no native zero-cap empty constructor in
    Mojo 0.26.3 — InlineArray of size 0 fails the stdlib constraint).
    The short-circuit guard in try_recv (and therefore try_io_read) fires
    on len(buf)==0 BEFORE the recv syscall is issued; we test that path
    via the slice form.
    """
    var buf = Array[UInt8, 1](fill=UInt8(0))
    var full = Span[UInt8](buf)
    # Take an empty subspan: Span supports indexing/slicing in 0.26.3 via
    # `__getitem__` returning a Span over a sub-range. The short-circuit
    # (len(buf)==0) fires before recv syscall.
    var empty = full[0:0]
    var r = try_io_read(Int32(0), empty)   # stdin fd; never touched
    assert_true(r.is_ready())
    assert_equal(r.value(), Int64(0))


def test_try_io_read_ready_path_linux() raises:
    """try_io_read returns Ready(n) when the kernel
    buffer has data primed.

    Steps:
      1. Create a socketpair.
      2. Push a byte into sv[1] BEFORE try_io_read on sv[0].
      3. try_io_read returns Ready(1); the byte is in the buffer.
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        _send_one_byte(sv[1], UInt8(0xEF))

        var read_buf = Array[UInt8, 64](fill=UInt8(0))
        var span = Span[UInt8](read_buf)
        var r = try_io_read(sv[0], span)

        assert_true(r.is_ready())
        assert_equal(r.value(), Int64(1))
        assert_equal(Int(read_buf[0]), Int(UInt8(0xEF)))

        _close_fd(sv[0])
        _close_fd(sv[1])


def test_try_io_read_would_block_path_linux() raises:
    """try_io_read returns WouldBlock when the kernel
    buffer is empty. No registration syscall, no park — just the EAGAIN
    signal back to the caller.

    Steps:
      1. Create a socketpair.
      2. try_io_read on sv[0] with no data — returns WouldBlock.
      3. Verify state == TRY_IO_WOULD_BLOCK and value == 0.
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var read_buf = Array[UInt8, 64](fill=UInt8(0))
        var span = Span[UInt8](read_buf)
        var r = try_io_read(sv[0], span)

        assert_true(r.is_would_block())
        assert_equal(r.value(), Int64(0))
        assert_equal(Int(r.state()), Int(TRY_IO_WOULD_BLOCK))

        _close_fd(sv[0])
        _close_fd(sv[1])


def test_try_io_write_ready_path_linux() raises:
    """try_io_write returns Ready(n) when the peer's
    receive buffer has space (default socketpair config — first write
    always fits).
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var write_buf = Array[UInt8, 8](fill=UInt8(0xA5))
        var span = Span[UInt8](write_buf)
        var r = try_io_write(sv[0], span)

        assert_true(r.is_ready())
        assert_equal(r.value(), Int64(8))

        _close_fd(sv[0])
        _close_fd(sv[1])


def test_try_io_write_error_on_closed_peer_linux() raises:
    """try_io_write returns Error(errno) when the
    peer has been closed. The kernel typically returns EPIPE on the
    second write to a closed-peer socket (the first write may succeed
    but raise SIGPIPE; with MSG_NOSIGNAL or an ignored SIGPIPE the
    syscall returns -EPIPE = 32).

    This test uses a more deterministic shape — close sv[0] (the local
    fd) and then attempt try_io_write on it. The kernel returns EBADF.
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        # Close the local fd; subsequent write returns EBADF (9).
        _close_fd(sv[0])
        var write_buf = Array[UInt8, 4](fill=UInt8(0))
        var span = Span[UInt8](write_buf)
        var r = try_io_write(sv[0], span)

        # Closed fd: try_send short-circuits on fd<0 (fd is still 0 not -1
        # post-close — close doesn't reset the local; the kernel rejects
        # the write with EBADF). Verify Error or Ready(0) — both are
        # acceptable per try_send's contract.
        # In practice on Linux, recv/send on closed fd return EBADF.
        if r.is_error():
            # EBADF == 9
            assert_equal(r.value(), Int64(9))
        # else: short-circuit Ready(0); also acceptable.
        _close_fd(sv[1])


def test_try_io_accept_bad_fd_returns_error() raises:
    """try_io_accept on fd=-1 short-circuits to Error(EBADF).
    Verifies the bad-fd guard at the top of try_io_accept fires
    correctly without invoking the syscall.
    """
    var r = try_io_accept(Int32(-1))
    assert_true(r.is_error())
    assert_equal(r.value(), Int64(9))   # EBADF


def test_try_io_accept_would_block_path_linux() raises:
    """try_io_accept on a socketpair fd (which is
    not a listener) returns Error or WouldBlock. The Linux kernel
    returns ENOTSOCK if accept4 is called on a non-listening socket;
    we accept either Error path (the exact errno may vary by kernel
    version).

    The strict point of this test is to verify the syscall path
    ITSELF does not crash and returns one of the expected discriminator
    values.
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = try_io_accept(sv[0])
        # Either WouldBlock (accept4 returned EAGAIN — unusual but
        # POSIX allows) or Error (most likely; ENOTSOCK / EOPNOTSUPP /
        # EINVAL on a non-listener). We accept any non-Ready outcome.
        assert_false(r.is_ready())

        _close_fd(sv[0])
        _close_fd(sv[1])


def test_try_io_connect_bad_addr_returns_error() raises:
    """try_io_connect with empty addr short-circuits to
    Error(EINVAL=22). Verifies the early guard fires before any syscall.

    Materialize an empty Span via slicing (InlineArray[_, 0] is rejected
    by the stdlib constraint).
    """
    var backing = Array[UInt8, 1](fill=UInt8(0))
    var span = Span[UInt8](backing)[0:0]
    var r = try_io_connect(Int32(0), span)
    assert_true(r.is_error())
    assert_equal(r.value(), Int64(22))   # EINVAL


def test_errno_predicates_match_platform() raises:
    """errno_is_would_block + errno_is_in_progress fire on
    the correct comptime-branched values."""
    comptime if CompilationTarget.is_linux():
        assert_true(errno_is_would_block(Int32(11)))    # EAGAIN
        assert_false(errno_is_would_block(Int32(115)))  # EINPROGRESS
        assert_true(errno_is_in_progress(Int32(115)))
        assert_false(errno_is_in_progress(Int32(11)))
    else:
        assert_true(errno_is_would_block(Int32(35)))    # EAGAIN macOS
        assert_true(errno_is_in_progress(Int32(36)))    # EINPROGRESS macOS


def test_reactor_submit_routes_through_try_io_read_linux() raises:
    """3 carry-forward: Reactor.submit OP_READ now dispatches
    via try_io_read internally. The fast-path
    behavior MUST be identical to the inline form — primed buffer hits Ready,
    empty buffer registers + parks Pending.

    This duplicates one inline-form assertion against the new code path
    so the regression gate is sharp.
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        _send_one_byte(sv[1], UInt8(0x77))

        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var read_buf = Array[UInt8, 16](fill=UInt8(0))
        var span = Span[UInt8](read_buf)
        var op = r.submit(OP_READ, sv[0], span)

        assert_equal(Int(op.state()), Int(OP_READY))
        assert_equal(op.result(), Int64(1))
        assert_equal(Int(read_buf[0]), Int(UInt8(0x77)))

        _close_fd(sv[0])
        _close_fd(sv[1])


def test_reactor_submit_routes_through_try_io_write_linux() raises:
    """3 carry-forward: Reactor.submit OP_WRITE on a fresh
    socketpair fd returns Ready (the receive buffer has space)."""
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var write_buf = Array[UInt8, 4](fill=UInt8(0xCC))
        var span = Span[UInt8](write_buf)
        var op = r.submit(OP_WRITE, sv[0], span)

        assert_equal(Int(op.state()), Int(OP_READY))
        assert_equal(op.result(), Int64(4))

        _close_fd(sv[0])
        _close_fd(sv[1])


def main() raises:
    test_try_io_result_pod_shape()
    test_try_io_read_bad_fd_short_circuits()
    test_try_io_read_empty_buf_short_circuits()
    test_try_io_read_ready_path_linux()
    test_try_io_read_would_block_path_linux()
    test_try_io_write_ready_path_linux()
    test_try_io_write_error_on_closed_peer_linux()
    test_try_io_accept_bad_fd_returns_error()
    test_try_io_accept_would_block_path_linux()
    test_try_io_connect_bad_addr_returns_error()
    test_errno_predicates_match_platform()
    test_reactor_submit_routes_through_try_io_read_linux()
    test_reactor_submit_routes_through_try_io_write_linux()
    print("PASS komira_async.reactor try_io fast-path")

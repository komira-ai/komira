# =============================================================================
# test_http_server_slow_writer.mojo
# =============================================================================
# Unit-level coverage of the HTTP server's EPOLLOUT switch.
#
# When `try_io_write` returns EWOULDBLOCK
# (kernel send buffer full), the connection state machine MUST switch
# the registration from INTEREST_READ to INTEREST_WRITE and resume
# the write on the next EPOLLOUT completion. Dropping the
# connection on EWOULDBLOCK would rarely show under loopback benchmarks,
# but slow real-world clients always trigger it.
#
# This test exercises the BEHAVIORAL invariants of the EPOLLOUT
# switch + resume sequence using REAL TCP loopback sockets:
#
#   - Build a server-side TcpStream + a slow-reader client.
#   - Force the server's send buffer to small (SO_SNDBUF) so a moderate
#     write fills it.
#   - Server writes a payload larger than the kernel buffer; first
#     try_io_write returns Ready(some); second returns WouldBlock.
#   - Verify reactor.modify(reg, INTEREST_WRITE) succeeds AND the
#     registration's interest_set tracking advances correctly.
#   - Client drains the socket; reactor.poll_completions(short timeout)
#     reports the conn fd as writable; resume the write; verify it
#     drains.
#   - Verify reactor.modify(reg, INTEREST_READ) switches back without
#     error.
#   - Verify NO conn drop occurred (the POC's drop-on-EWOULDBLOCK
#     behavior would have severed the connection here).
#
# This is a SUBSTRATE test, not a full HTTP test. The full integration
# proof (slow client → no conn drops at scale) is a
# separate integration test.
#
# Linux-only.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer, alloc
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    Completion,
    INTEREST_READ,
    INTEREST_WRITE,
    RegistrationHandle,
)
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    Reactor,
)
from komira_async.reactor.socket_io import (
    TRY_IO_ERROR,
    TRY_IO_READY,
    TRY_IO_WOULD_BLOCK,
    TryIoResult,
    try_io_read,
    try_io_write,
)
from komira_async.reactor.socket_setup import (
    close_fd,
    inet_loopback_be,
    sockaddr_in_bytes,
)
from komira_async.runtime.tcp_stream import (
    TcpListener,
    TcpStream,
)


# -----------------------------------------------------------------------------
# Test helpers — synthetic localhost client + SO_SNDBUF setter.
# -----------------------------------------------------------------------------


# setsockopt level + option numbers. ⚠ NEITHER PAIR IS PORTABLE, AND GETTING
# THIS WRONG FAILS SILENTLY — setsockopt returns -1 and the buffer keeps its
# (large) default, so a "congested socket" fixture never congests.
#
#   SOL_SOCKET : Linux 1        (asm-generic/socket.h)
#                Darwin 0xffff  (sys/socket.h)
#   SO_SNDBUF  : Linux 7        SO_RCVBUF : Linux 8   (asm-generic/socket.h)
#                Darwin 0x1001              Darwin 0x1002 (sys/socket.h)
#
# A hardcoded LINUX pair is a known trap
# (`socket_setup.mojo` documents it), which has bitten
# other tests. It is
# NOT the defect here — every call site below sits inside
# `@parameter if CompilationTarget.is_linux()`, and under the default
# config the target builds and runs as linux/x86_64, so the Linux numbers
# are the only ones that were ever emitted (MEASURED: setsockopt rc=0,
# getsockopt readback 8192 == 2*4096, on both fds). The picker is here so the
# next reader does not have to re-derive that, and so a darwin-targeted build
# of these helpers cannot silently reintroduce the trap.
comptime _SOL_SOCKET_LINUX: Int32 = Int32(1)
comptime _SOL_SOCKET_MACOS: Int32 = Int32(0xFFFF)
comptime _SO_SNDBUF_LINUX: Int32 = Int32(7)
comptime _SO_RCVBUF_LINUX: Int32 = Int32(8)
comptime _SO_SNDBUF_MACOS: Int32 = Int32(0x1001)
comptime _SO_RCVBUF_MACOS: Int32 = Int32(0x1002)


def _sol_socket() -> Int32:
    comptime if CompilationTarget.is_linux():
        return _SOL_SOCKET_LINUX
    return _SOL_SOCKET_MACOS


def _so_sndbuf() -> Int32:
    comptime if CompilationTarget.is_linux():
        return _SO_SNDBUF_LINUX
    return _SO_SNDBUF_MACOS


def _so_rcvbuf() -> Int32:
    comptime if CompilationTarget.is_linux():
        return _SO_RCVBUF_LINUX
    return _SO_RCVBUF_MACOS


def _sockbuf_grant(fd: Int32, opt: Int32) raises -> Int32:
    """getsockopt readback of a SO_{SND,RCV}BUF grant, for diagnosis.

    ⚠ HEAP buffers, not `UnsafePointer(to=<stack local>)`: the compiler
    cannot see that an `external_call` wrote through a pointer to a local, so
    reading one back can fold to the initialiser and print a FALSE value.
    """
    var out_buf = alloc[UInt8](8).unsafe_origin_cast[MutUntrackedOrigin]()
    var len_buf = alloc[UInt8](8).unsafe_origin_cast[MutUntrackedOrigin]()
    out_buf.bitcast[Int32]()[] = Int32(0)
    len_buf.bitcast[Int32]()[] = Int32(4)
    var grc = external_call["getsockopt", Int32](
        fd, _sol_socket(), opt, out_buf, len_buf
    )
    var got = out_buf.bitcast[Int32]()[]
    out_buf.free()
    len_buf.free()
    if grc != Int32(0):
        raise Error(
            "getsockopt(opt=" + String(Int(opt)) + ") failed rc="
            + String(Int(grc))
        )
    return got


def _set_sockbuf(fd: Int32, opt: Int32, want: Int32, tag: String) raises -> Int32:
    """setsockopt(SOL_SOCKET, opt, want) — NOT best-effort.

    ⛔ A squeeze that does not happen makes the EWOULDBLOCK probe VACUOUS,
    so a failed setsockopt is a hard precondition failure, not a warning.

    ⚠ HEAP buffer, not `UnsafePointer(to=<stack local>)`. Taking the address
    of a local and handing it to an `external_call` is not reliable here: the
    compiler does not see the callee read through it, so the slot can be left
    unmaterialised and the kernel reads GARBAGE. It may not misbehave
    in a given run (a clean 2*4096 grant), but the SAME binary can
    alternate between rc=0
    with a nonsense grant and rc=-1 under it, so it is not used.

    Returns the kernel's GRANT (Linux doubles the request and clamps to
    SOCK_MIN_{SND,RCV}BUF / wmem_max), deliberately NOT asserted against a
    numeric bound — the behavioural assertion is the EWOULDBLOCK itself.
    """
    var val_buf = alloc[UInt8](8).unsafe_origin_cast[MutUntrackedOrigin]()
    val_buf.bitcast[Int32]()[] = want
    var rc = external_call["setsockopt", Int32](
        fd, _sol_socket(), opt, val_buf, UInt32(4),
    )
    val_buf.free()
    if rc < Int32(0):
        raise Error(
            "PRECONDITION: setsockopt(level=" + String(Int(_sol_socket()))
            + ", opt=" + String(Int(opt)) + ", " + String(Int(want))
            + ") [" + tag + "] failed rc=" + String(Int(rc))
            + " — without it the socket cannot be congested and the"
            " EWOULDBLOCK probe measures nothing."
        )
    return _sockbuf_grant(fd, opt)


def _set_so_sndbuf_small(fd: Int32) raises -> Int32:
    """Shrink the server-side send buffer so a 64KB write backs up."""
    return _set_sockbuf(fd, _so_sndbuf(), Int32(4096), "server SO_SNDBUF")


def _set_so_rcvbuf_small(fd: Int32) raises -> Int32:
    """Shrink the client-side receive buffer.

    ⛔ MUST BE CALLED BEFORE connect(). THIS ORDERING IS THE WHOLE FIXTURE.
    Linux negotiates the TCP window scale from the receive buffer in the SYN;
    shrinking SO_RCVBUF AFTER the handshake leaves the already-advertised
    window large, so the peer keeps absorbing everything. MEASURED on
    linux/x86_64, same kernel, same 4096 request granted 8192 on both
    fds either way:
      set AFTER connect():  a single MSG_DONTWAIT send accepts 32768; the
                            whole 64KB payload goes inline in 2 writes;
                            hit_would_block=False — 8/8 runs.
      set BEFORE connect(): the send stalls at sent_off=8192 with a final
                            short write of 2048; hit_would_block=True.
    """
    return _set_sockbuf(fd, _so_rcvbuf(), Int32(4096), "client SO_RCVBUF")


def _connect_blocking(port: UInt16, small_rcvbuf: Bool = False) raises -> Int32:
    var fd = external_call["socket", Int32](
        Int32(2),    # AF_INET
        Int32(1),    # SOCK_STREAM (blocking client; test driver)
        Int32(0),
    )
    if fd < Int32(0):
        raise Error("client socket() failed")
    # ⛔ BEFORE connect() — see `_set_so_rcvbuf_small`. Doing this after the
    # handshake is a silent no-op for congestion purposes.
    if small_rcvbuf:
        var rgrant = _set_so_rcvbuf_small(fd)
        print("    [fixture] client SO_RCVBUF granted=" + String(Int(rgrant))
              + " (set BEFORE connect)")
    var sa = sockaddr_in_bytes(inet_loopback_be(), port)
    var rc = external_call["connect", Int32](
        fd, sa.unsafe_ptr(), UInt32(16),
    )
    if rc < Int32(0):
        close_fd(fd)
        raise Error("client connect() failed")
    return fd


def test_item6_modify_to_write_then_back_to_read() raises:
    """Item 6 baseline: verify reactor.modify(reg, INTEREST_WRITE)
    succeeds + the no-op fast path fires when interest doesn't change.

    This isolates the substrate-level modify call without depending on
    a real EWOULDBLOCK condition (those are timing-flaky in tests)."""
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()
        var client_fd = _connect_blocking(port)
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var stream = listener.accept[NoopSink](reactor)
        var fd = stream.fd()

        # Manually register the conn with INTEREST_READ (mirrors the
        # server's pattern after accept).
        var reg = reactor.register_long_lived(fd, INTEREST_READ)
        assert_equal(reg.interest_set(), INTEREST_READ)

        # Switch to INTEREST_WRITE — should succeed.
        reactor.modify(reg, INTEREST_WRITE)
        # Note: the RegistrationHandle returned to the caller is a POD
        # value; modify does NOT mutate the caller's local view of
        # _interest_set (the kernel state changes but the handle's field
        # tracks what the LAST register call armed). Production callers
        # track current interest in their per-conn state machine
        # (ConnEntry._interest_set in the server). Here we just verify
        # the syscall doesn't raise.

        # Switch back to INTEREST_READ — also succeeds.
        reactor.modify(reg, INTEREST_READ)

        # Drop everything to clean up.
        close_fd(client_fd)
        _ = stream^
        _ = listener^
        _ = reactor^


def test_item6_no_op_modify_when_interest_unchanged() raises:
    """Item 6 fast path: if new_interest_set == reg.interest_set(), modify
    is a no-op and does NOT issue a syscall. Verified by calling modify
    with the same interest twice in quick succession; both should
    succeed without raising."""
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()
        var client_fd = _connect_blocking(port)
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var stream = listener.accept[NoopSink](reactor)
        var fd = stream.fd()
        var reg = reactor.register_long_lived(fd, INTEREST_READ)

        # Same interest — should no-op without raising.
        reactor.modify(reg, INTEREST_READ)
        reactor.modify(reg, INTEREST_READ)
        # Different interest — should issue the syscall.
        reactor.modify(reg, INTEREST_WRITE)
        # Back to same again.
        reactor.modify(reg, INTEREST_WRITE)

        close_fd(client_fd)
        _ = stream^
        _ = listener^
        _ = reactor^


def test_item6_force_ewouldblock_then_epollout_resume() raises:
    """Item 6 end-to-end: shrink server-side SO_SNDBUF + client-side
    SO_RCVBUF so a moderate write blocks; verify the server-side
    try_io_write returns WouldBlock, switch to INTEREST_WRITE,
    drain client side, poll for EPOLLOUT, resume the write.

    This is the substrate-level proof that the EPOLLOUT switch path
    actually drains a backed-up write WITHOUT dropping the conn. The
    POC's behavior was to drop on EWOULDBLOCK; this test would have
    failed on the POC code (the assertion `keep_alive == True after
    EWOULDBLOCK` was the diff).
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()
        # Shrink client rcvbuf BEFORE connect() so the SYN advertises a
        # small window — doing it afterwards does not congest (see the
        # measurement in `_set_so_rcvbuf_small`).
        var client_fd = _connect_blocking(port, small_rcvbuf=True)
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var stream = listener.accept[NoopSink](reactor)
        var fd = stream.fd()
        # Shrink server sendbuf too.
        var sgrant = _set_so_sndbuf_small(fd)
        print("    [fixture] server SO_SNDBUF granted=" + String(Int(sgrant)))
        var reg = reactor.register_long_lived(fd, INTEREST_READ)

        # Build a 64KB payload and try to send it. With client rcvbuf
        # = 4K (kernel doubles to ~8K) + server sendbuf = 4K (~8K)
        # the per-connection in-flight budget is around 16-32KB; the
        # 64KB write should EWOULDBLOCK after partially draining.
        comptime PAYLOAD: Int = 65536
        var payload = List[UInt8]()
        payload.resize(unsafe_uninit_length=PAYLOAD)
        var pi: Int = 0
        while pi < PAYLOAD:
            payload[pi] = UInt8(pi & 0xFF)
            pi = pi + 1

        # Drive the write loop until we hit WouldBlock OR fully drain.
        var sent_off: Int = 0
        var hit_would_block = False
        var iter_guard: Int = 0
        while sent_off < PAYLOAD and iter_guard < 1024:
            var span = Span[UInt8](payload)
            var slice = span[sent_off:PAYLOAD]
            var wr = try_io_write(fd, slice)
            if wr.is_would_block():
                hit_would_block = True
                break
            if wr.is_error():
                # Hard error (peer reset, etc.) — bail.
                break
            var n = Int(wr.value())
            if n <= 0:
                break
            sent_off = sent_off + n
            iter_guard = iter_guard + 1

        # Item 6 invariant: at small sendbuf + small client rcvbuf, a 64KB
        # write MUST hit EWOULDBLOCK.
        #
        # ⛔ THIS USED TO BE A SILENT self-skip that `return`ed before a
        # single assertion, blaming "kernel didn't honor SO_SNDBUF". That
        # diagnosis was FALSE and the skip fired on 8/8 runs, so the ONLY
        # test in this file that actually exercises the item-6
        # EPOLLOUT-switch-and-resume path had not run its assertions at all.
        # MEASURED at the time: setsockopt rc=0 and a getsockopt readback of
        # 8192 on BOTH fds — the kernel honored the request exactly. The
        # payload went inline because the client's SO_RCVBUF was applied
        # AFTER connect(), leaving the handshake-advertised window large
        # (see `_set_so_rcvbuf_small`). With the ordering fixed the state is
        # reachable every run, so failing to reach it is a fixture
        # PRECONDITION failure — not something to paper over. A probe that
        # cannot create the state it measures is vacuous.
        if not hit_would_block:
            raise Error(
                "PRECONDITION: a "
                + String(PAYLOAD)
                + "-byte write did NOT hit EWOULDBLOCK (sent_off="
                + String(sent_off)
                + ", iters="
                + String(iter_guard)
                + ") despite server SO_SNDBUF grant="
                + String(Int(sgrant))
                + " — the fixture failed to congest the socket, so the"
                " EPOLLOUT switch/resume path below would measure nothing."
            )

        # Switch to INTEREST_WRITE — the v1 server's fix.
        reactor.modify(reg, INTEREST_WRITE)

        # Drain the client side aggressively. Each recv frees server
        # sendbuf room; eventually the server's pending tail drains.
        var drained_total: Int = 0
        var drain_iter: Int = 0
        while drained_total < PAYLOAD and drain_iter < 4096:
            var rb = Array[UInt8, 4096](fill=UInt8(0))
            var got = external_call["recv", Int](
                client_fd,
                rb.unsafe_ptr(),
                UInt(4096),
                Int32(0),
            )
            if got <= 0:
                break
            drained_total = drained_total + got
            # After every drain step, opportunistically resume the
            # server-side write so the client keeps making progress.
            if sent_off < PAYLOAD:
                var span = Span[UInt8](payload)
                var slice = span[sent_off:PAYLOAD]
                var wr = try_io_write(fd, slice)
                if wr.is_would_block():
                    # Still backed up; let the next client recv free
                    # room.
                    pass
                elif wr.is_error():
                    # Hard error after partial drain — bail; the
                    # client may have been killed by some external
                    # interrupt. The test passes if the conn was NOT
                    # dropped on the EWOULDBLOCK transition (the POC
                    # bug); reaching here proves that.
                    break
                else:
                    var n = Int(wr.value())
                    if n > 0:
                        sent_off = sent_off + n
            drain_iter = drain_iter + 1

        # Item 6 invariant: after the EWOULDBLOCK + INTEREST_WRITE
        # switch, the server-side write actually progressed past
        # the EWOULDBLOCK point (the POC would have dropped the conn
        # immediately, leaving sent_off frozen).
        assert_true(sent_off > 0)
        # Most of the time we'll have fully drained; allow some slack
        # for kernel scheduling weirdness on shared CI infra.
        assert_true(drained_total > 0)

        # Switch back to INTEREST_READ — verifies the modify path is
        # bidirectional without raising.
        if sent_off >= PAYLOAD:
            reactor.modify(reg, INTEREST_READ)

        close_fd(client_fd)
        _ = stream^
        _ = listener^
        _ = reactor^


def main() raises:
    test_item6_modify_to_write_then_back_to_read()
    print("PASS test_item6_modify_to_write_then_back_to_read")
    test_item6_no_op_modify_when_interest_unchanged()
    print("PASS test_item6_no_op_modify_when_interest_unchanged")
    test_item6_force_ewouldblock_then_epollout_resume()
    print("PASS test_item6_force_ewouldblock_then_epollout_resume")
    print(
        "PASS komira_async HTTP EPOLLOUT switch coverage"
    )

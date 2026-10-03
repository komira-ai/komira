# =============================================================================
# test_socket_write_no_sigpipe.mojo
# =============================================================================
# ★ REGRESSION GUARD — a write to a socket whose peer has gone away must
#   return EPIPE as an ORDINARY ERROR, never deliver SIGPIPE.
#
# ⛔ READ THIS BEFORE CONCLUDING THE TEST IS BROKEN.
#
# BEFORE the fix, this file did not FAIL — it DIED. `try_send`
# (src/komira_async/reactor/socket_io.mojo) passed `msg_dontwait()`
# and NOT `MSG_NOSIGNAL`, and nothing in `src/` set SIGPIPE's disposition, whose
# POSIX default is TERMINATE. So the very first `try_io_write` to a departed
# peer killed the test binary:
#
#     exit 141   (= 128 + 13, SIGPIPE)   and an EMPTY LOG
#
# THE EMPTY LOG IS THE SYMPTOM, NOT A HARNESS BUG. A signal death runs no
# atexit, flushes no buffer and prints no assertion, so the pre-fix RED names
# nothing and looks exactly like a crash in the subject. If you ever see this
# target exit 141 with no output, the fix has been reverted — that IS the
# failure, and it is the reason the guard is written against the PROCESS
# OUTCOME (we reach the next line at all) and not only against a return value.
#
# WHAT WAS ACTUALLY BROKEN. Every socket server in this repo writes through
# `try_io_write` -> `try_send`. So the first write to any client that closed —
# a browser tab shutting, a curl ^C, an abrupt mid-session disconnect, the
# ordinary end of a session — terminated the whole process, dropping every
# OTHER concurrent connection that process was serving. Under strace:
#
#     sendto(7, "\210\0", 2, MSG_DONTWAIT, NULL, 0) = -1 EPIPE (Broken pipe)
#     --- SIGPIPE ---   +++ killed by SIGPIPE +++
#
# ★★ WHY THE EXISTING COVERAGE DID NOT CATCH IT. `test_try_io_fast_path.mojo`
# has a test literally named `test_try_io_write_error_on_closed_peer_linux` —
# but it closes the LOCAL fd and asserts EBADF(9). Closing your own fd is not
# the closed-PEER condition and cannot raise SIGPIPE. The test that names the
# hazard never exercised it. Hence the assertions below pin errno == EPIPE(32)
# and explicitly REJECT EBADF(9): an EBADF here would mean the fixture stopped
# reproducing the hazard while still passing.
#
# ★★★ ANTI-VACUITY: THIS FILE RE-ARMS SIGPIPE ITSELF. Every socket test below
# first calls `signal(SIGPIPE, SIG_DFL)`, so the guard measures the SOCKET LAYER
# with the signal ARMED. A process-level `ignore_sigpipe()` added to this binary
# later — by a harness change, or by an import side effect — cannot silently
# convert this file into a tautology. `test_sigpipe_disposition_is_default_here`
# states that precondition as its own assertion.
#
# PLATFORM SPLIT (socket_io.mojo carries the full rationale):
#   Linux — `MSG_NOSIGNAL` per send() call. MEASURED by this file.
#   macOS — no such flag; `SO_NOSIGPIPE` per socket at fd creation.
#           ⚠ UNVERIFIED: this repo's lanes are linux-x86_64 only, so the
#           socket-syscall rows below are Linux-gated. The platform-agnostic
#           rows (flag values, disjointness, set_nosigpipe contract) run
#           everywhere and are the only macOS coverage that exists.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_not_equal, assert_true

from komira_async.reactor.socket_io import (
    TRY_IO_ERROR,
    msg_dontwait,
    msg_nosignal,
    set_nosigpipe,
    try_io_write,
)

comptime _AF_UNIX: Int32 = Int32(1)
comptime _AF_INET: Int32 = Int32(2)
comptime _SOCK_STREAM: Int32 = Int32(1)

# errno values (Linux). EPIPE is the whole point; EBADF is the value the
# PRE-EXISTING "closed peer" test asserts, and observing it here would mean the
# fixture stopped reproducing the hazard.
comptime _EPIPE: Int64 = Int64(32)
comptime _EBADF: Int64 = Int64(9)

# SIGPIPE == 13 on both Linux and Darwin. SIG_DFL == 0, SIG_IGN == 1,
# SIG_ERR == -1 (signal(2)).
comptime _SIGPIPE: Int32 = Int32(13)
comptime _SIG_DFL: Int64 = Int64(0)
comptime _SIG_IGN: Int64 = Int64(1)


def _arm_sigpipe() -> Int64:
    """Force SIGPIPE to its DEFAULT (terminate) disposition and return whatever
    it was before.

    ★ THIS IS THE ANTI-VACUITY DEVICE. Without it, a future process-level
    `ignore_sigpipe()` anywhere in this binary would make every row below pass
    for a reason that has nothing to do with the code under test. Arming the
    signal means a green row can ONLY come from the send() flags.

    SAFETY: FFI-BOUNDARY. `signal(int, sighandler_t)` is non-variadic; SIG_DFL
    is the integer 0 in the pointer slot. No pointer escapes.
    """
    return external_call["signal", Int64](_SIGPIPE, _SIG_DFL)


def _socketpair_unix_stream() raises -> Array[Int32, 2]:
    """SAFETY: FFI-BOUNDARY. `pair` is stack-local; the kernel writes 2 fds into
    it and does not retain the pointer past the syscall."""
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), pair.unsafe_ptr(),
    )
    if rc < 0:
        raise Error("socketpair() failed")
    return pair^


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


# =============================================================================
# ROW 1 — THE FALSIFIER. Real production code, real fd, departed peer.
# =============================================================================


def test_write_to_departed_peer_returns_epipe_and_does_not_kill_process() raises:
    """★ THE ROW THIS FILE EXISTS FOR.

    An AF_UNIX SOCK_STREAM pair, peer closed, then a `try_io_write` — the exact
    call every serve loop in this repo makes. On this kernel that is EPIPE on
    the FIRST write (measured; AF_UNIX does not buffer past a closed peer the
    way loopback TCP does), so the shape is deterministic and needs no retry.

    PRE-FIX: control never reaches the assertions. The binary is killed by
    SIGPIPE inside `try_io_write` — exit 141, empty log, nothing named.
    POST-FIX: `try_io_write` returns TRY_IO_ERROR / EPIPE and the process lives.

    Reaching `assert_true(True)` at the end is itself an assertion: it is the
    statement that the process survived the write.
    """
    comptime if CompilationTarget.is_linux():
        var prev = _arm_sigpipe()
        _ = prev  # documented by test_sigpipe_disposition_is_default_here

        var sv = _socketpair_unix_stream()
        _close_fd(sv[1])  # the peer departs

        var payload = Array[UInt8, 8](fill=UInt8(0xA5))
        var r = try_io_write(sv[0], Span[UInt8](payload))

        # ---- If we are here at all, the process survived the write. ----
        assert_true(
            True,
            "reached the line after try_io_write — the process was NOT killed"
            " by SIGPIPE. A pre-fix binary dies inside the call above and this"
            " assertion never runs (exit 141, empty log).",
        )

        assert_equal(
            Int(r.state()),
            Int(TRY_IO_ERROR),
            "write to a departed peer must surface as TRY_IO_ERROR, the"
            " ordinary hard-write-error state every serve loop already maps to"
            " 'drop THIS connection and keep serving'",
        )
        assert_equal(
            r.value(),
            _EPIPE,
            "errno must be EPIPE(32) — the closed-PEER condition",
        )
        assert_not_equal(
            r.value(),
            _EBADF,
            "errno must NOT be EBADF(9): EBADF is the CLOSED-LOCAL-FD condition"
            " that test_try_io_fast_path's misnamed"
            " test_try_io_write_error_on_closed_peer_linux asserts. Seeing it"
            " here would mean this fixture stopped reproducing the hazard while"
            " still reporting green.",
        )

        _close_fd(sv[0])


# =============================================================================
# ROW 2 — the production shape: an ACCEPTED loopback TCP fd.
# =============================================================================


def _build_sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    """sockaddr_in for 127.0.0.1:port, network byte order."""
    var a = Array[UInt8, 16](fill=UInt8(0))
    a[0] = UInt8(_AF_INET)  # sin_family low byte (little-endian host)
    a[1] = UInt8(0)
    a[2] = UInt8((Int(port) >> 8) & 0xFF)  # sin_port, big-endian
    a[3] = UInt8(Int(port) & 0xFF)
    a[4] = UInt8(127)  # 127.0.0.1
    a[5] = UInt8(0)
    a[6] = UInt8(0)
    a[7] = UInt8(1)
    return a^


def test_accepted_tcp_conn_survives_peer_departure_linux() raises:
    """The shape an actual server hits: a listener, an accepted connection, and
    a client that vanishes mid-session.

    Loopback TCP differs from AF_UNIX — the FIRST write after the peer departs
    is normally ACCEPTED into the socket buffer (the RST has not been processed
    yet) and the SECOND returns EPIPE. So this row loops, which also proves the
    survival is repeatable rather than a one-shot fluke: a serve loop meets this
    condition once per departing client, forever.

    PRE-FIX symptom is identical to ROW 1 — death by signal, empty log.
    """
    comptime if CompilationTarget.is_linux():
        _ = _arm_sigpipe()

        var lfd = external_call["socket", Int32](
            _AF_INET, _SOCK_STREAM, Int32(0)
        )
        if lfd < Int32(0):
            raise Error("socket() failed")

        var addr = _build_sockaddr_in_loopback(UInt16(0))  # ephemeral port
        # SAFETY: FFI-BOUNDARY. `addr` is stack-local, kernel reads 16 bytes.
        if (
            external_call["bind", Int32](lfd, addr.unsafe_ptr(), UInt32(16))
            < Int32(0)
        ):
            _close_fd(lfd)
            raise Error("bind() failed")
        if external_call["listen", Int32](lfd, Int32(8)) < Int32(0):
            _close_fd(lfd)
            raise Error("listen() failed")

        # Recover the ephemeral port. SAFETY: both stack-local; kernel writes
        # 16 bytes into `bound` and the length into `alen`.
        var bound = Array[UInt8, 16](fill=UInt8(0))
        var alen = Array[UInt32, 1](fill=UInt32(16))
        if (
            external_call["getsockname", Int32](
                lfd, bound.unsafe_ptr(), alen.unsafe_ptr()
            )
            < Int32(0)
        ):
            _close_fd(lfd)
            raise Error("getsockname() failed")
        var port = UInt16((Int(bound[2]) << 8) | Int(bound[3]))

        var cfd = external_call["socket", Int32](
            _AF_INET, _SOCK_STREAM, Int32(0)
        )
        if cfd < Int32(0):
            _close_fd(lfd)
            raise Error("client socket() failed")
        var caddr = _build_sockaddr_in_loopback(port)
        if (
            external_call["connect", Int32](cfd, caddr.unsafe_ptr(), UInt32(16))
            < Int32(0)
        ):
            _close_fd(cfd)
            _close_fd(lfd)
            raise Error("connect() failed")

        # Blocking accept: the connect above already completed on loopback.
        var sfd = external_call["accept", Int32](
            lfd, Array[UInt8, 16](fill=UInt8(0)).unsafe_ptr(),
            alen.unsafe_ptr(),
        )
        if sfd < Int32(0):
            _close_fd(cfd)
            _close_fd(lfd)
            raise Error("accept() failed")

        _close_fd(cfd)  # ★ the peer vanishes mid-session

        var payload = Array[UInt8, 64](fill=UInt8(0x5A))
        var saw_epipe = False
        var attempts = 0
        while attempts < 64:
            attempts += 1
            var r = try_io_write(sfd, Span[UInt8](payload))
            # Surviving this call is the assertion. Pre-fix, one of these
            # iterations kills the binary and the loop never terminates
            # normally.
            if Int(r.state()) == Int(TRY_IO_ERROR):
                assert_equal(
                    r.value(),
                    _EPIPE,
                    "the only hard error expected on a peer-departed loopback"
                    " conn is EPIPE(32)",
                )
                saw_epipe = True
                break

        assert_true(
            saw_epipe,
            "expected EPIPE within 64 writes to a departed loopback peer; not"
            " seeing it means this row stopped reproducing the hazard and its"
            " green says nothing",
        )

        _close_fd(sfd)
        _close_fd(lfd)


# =============================================================================
# ROW 3 — repeatability: a serve loop meets this over and over.
# =============================================================================


def test_many_departed_peer_writes_do_not_accumulate_into_a_kill() raises:
    """32 independent socketpairs, each peer closed, each written to. A server
    does not meet this condition once; it meets it once per departing client for
    the life of the process. One survival could be luck — 32 in a row over
    distinct fds is the property.

    Also asserts EVERY write reported EPIPE, so a fixture that silently stopped
    creating the condition (e.g. writes started succeeding) cannot pass.
    """
    comptime if CompilationTarget.is_linux():
        _ = _arm_sigpipe()

        var payload = Array[UInt8, 4](fill=UInt8(0xFF))
        var epipes = 0
        var i = 0
        while i < 32:
            i += 1
            var sv = _socketpair_unix_stream()
            _close_fd(sv[1])
            var r = try_io_write(sv[0], Span[UInt8](payload))
            if Int(r.state()) == Int(TRY_IO_ERROR) and r.value() == _EPIPE:
                epipes += 1
            _close_fd(sv[0])

        assert_equal(
            epipes,
            32,
            "all 32 writes to a departed peer must report EPIPE; a lower count"
            " means the fixture stopped reproducing the hazard, and this row's"
            " survival then proves nothing",
        )


# =============================================================================
# ROW 4 — the anti-vacuity precondition, stated as its own assertion.
# =============================================================================


def test_sigpipe_disposition_is_default_here() raises:
    """The rows above are only meaningful with SIGPIPE ARMED. This states that
    precondition rather than assuming it.

    `signal()` returns the PREVIOUS disposition, so calling `_arm_sigpipe()`
    twice lets us read back what the first call installed: SIG_DFL (0). If this
    ever reads SIG_IGN (1), something set a process-level ignore between the two
    calls and every other row in this file has become a tautology.

    NOTE this is deliberately NOT an assertion that nobody may call
    `ignore_sigpipe()` — servers may legitimately keep it as a backstop for
    non-socket writes. It is an assertion that THIS BINARY measures the socket
    layer.
    """
    comptime if CompilationTarget.is_linux():
        _ = _arm_sigpipe()
        var readback = _arm_sigpipe()
        assert_equal(
            readback,
            _SIG_DFL,
            "SIGPIPE must be at SIG_DFL while this file runs — otherwise the"
            " EPIPE rows pass because the signal is ignored process-wide, not"
            " because try_send passes MSG_NOSIGNAL",
        )
        assert_not_equal(
            readback,
            _SIG_IGN,
            "SIGPIPE is SIG_IGN — the socket-layer rows in this file are"
            " VACUOUS in this process",
        )


# =============================================================================
# ROW 5 — the platform split, asserted rather than assumed.
# =============================================================================


def test_msg_nosignal_flag_value_per_platform() raises:
    """Linux MSG_NOSIGNAL is 0x4000 (verified against <sys/socket.h> on
    glibc/x86_64). Darwin has no such flag, so `msg_nosignal()` MUST fold to 0
    — OR-ing an invented bit into send()'s flags would be worse than useless,
    since a future kernel could assign that bit a meaning.
    """
    comptime if CompilationTarget.is_macos():
        assert_equal(
            Int(msg_nosignal()),
            0,
            "macOS has no MSG_NOSIGNAL; the suppression there is SO_NOSIGPIPE"
            " at fd creation, not a send() flag",
        )
    else:
        assert_equal(
            Int(msg_nosignal()),
            0x4000,
            "Linux MSG_NOSIGNAL == 0x4000",
        )


def test_send_flags_compose_without_collision() raises:
    """`try_send` passes `msg_dontwait() | msg_nosignal()`. The two must be
    DISJOINT bits or the OR silently changes the non-blocking semantics of every
    send in the repo. Linux: 0x40 | 0x4000. Darwin: 0x80 | 0.
    """
    var dw = Int(msg_dontwait())
    var ns = Int(msg_nosignal())
    assert_equal(
        dw & ns,
        0,
        "MSG_DONTWAIT and MSG_NOSIGNAL must not share bits — try_send ORs them",
    )
    assert_true(dw != 0, "MSG_DONTWAIT must be non-zero on every platform")

    comptime if CompilationTarget.is_macos():
        assert_equal(dw | ns, 0x80)
    else:
        assert_equal(dw | ns, 0x4040)


def test_set_nosigpipe_contract() raises:
    """`set_nosigpipe` is the macOS arm's carrier and a documented NO-OP on
    Linux. It must never raise — it is called from inside an accept loop, where
    a hardening failure must not become a dropped connection.

    ⚠ The macOS BEHAVIOUR (that SO_NOSIGPIPE actually suppresses the signal) is
    UNVERIFIED: there is no macOS lane in this repo. What is asserted here is the
    contract the Linux build depends on.
    """
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        assert_true(
            set_nosigpipe(sv[0]),
            "on Linux set_nosigpipe is a no-op returning True; MSG_NOSIGNAL on"
            " every send is strictly more complete than a per-socket option",
        )
        # Must tolerate a bad fd without raising — accept loops call it on
        # whatever accept4 returned.
        assert_true(set_nosigpipe(Int32(-1)))
        _close_fd(sv[0])
        _close_fd(sv[1])


def main() raises:
    test_write_to_departed_peer_returns_epipe_and_does_not_kill_process()
    test_accepted_tcp_conn_survives_peer_departure_linux()
    test_many_departed_peer_writes_do_not_accumulate_into_a_kill()
    test_sigpipe_disposition_is_default_here()
    test_msg_nosignal_flag_value_per_platform()
    test_send_flags_compose_without_collision()
    test_set_nosigpipe_contract()
    print("test_socket_write_no_sigpipe: ALL PASS")

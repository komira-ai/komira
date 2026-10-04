# =============================================================================
# komira_job_supervisor/tests/test_heartbeat_no_credential_in_clear.mojo
#   A CREDENTIAL NEVER RIDES A PLAINTEXT HEARTBEAT: nothing minted, nothing sent.
# =============================================================================
#
# ⛔⛔ THE DEFECT. `send_heartbeat_blocking` minted a token
# whenever the declared posture was not `none` -- REGARDLESS OF `use_tls` --
# and then dialled. `PodLoaderSupervisorConfig.from_env` and
# `JobSupervisorConfig.from_env` both accepted (plaintext, gcp-metadata). So a
# Google-signed OIDC ID token could go out in the CLEAR, readable on every hop,
# for an `http://` audience Cloud Run does not even serve.
#
# ⚠ HOW THE PAIR ARISES, EVEN THOUGH PLACEMENT REFUSES IT. `GcpCloudProvider`
# refuses (http, gcp-metadata) before any cloud call. But the startup script
# fetches the scheme and the posture with the OPTIONAL `curl -sf … || true`
# form, so a transient metadata failure on the SCHEME alone exports it EMPTY (=
# http) on the VM while the posture arrives intact -- after placement, where no
# placement check can see it. `pod_boot_contract.mojo` said that downgrade
# "carries no credential ... never a leak". It carried one.
#
# ★ WHAT THIS TEST IS. It sends one beat through the REAL
# `send_heartbeat_blocking` body (the one place the transport, the scheme and
# the posture are chosen together) at a 127.0.0.1 listener, and reads BOTH
# ends: the minter's call count, the client's outcome, and whether the listener
# was dialled and what it was sent.
#
# ⚠ WHY THE MINTER IS SCRIPTED, AND WHY THAT IS NOT A SHORTCUT. The production
# `GcpMetadataMinter` dials `metadata.google.internal`, which does not resolve
# on a build box: driven through it, the unfixed code ALSO sends nothing (the
# mint fails first), so "no connection" would pass vacuously on exactly the
# code it exists to catch. `send_heartbeat_blocking_with_minter` is the seam;
# `send_heartbeat_blocking` is it with the production minter, and nothing else.
#
# ⚠ EVERY CASE HAS A CONTROL: the same listener SEES a legal plaintext dial,
# and the legal credential posture (TLS, gcp-metadata) still mints and still
# dials. Without them, "zero connections" is satisfied by a listener that sees
# nothing, and "zero mints" by a guard that refuses every credentialed beat.
#
# ENCAPSULATION: the raw-socket SERVER and the pthread are this test's own FFI
# boundary; the code under test
# never exposes a pointer. The thread's box holds only fixed-size fields.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase, FailureReport
from komira_job_supervisor.heartbeat_client import (
    HEARTBEAT_STATUS_AUTH_REFUSED,
    HEARTBEAT_STATUS_AUTH_UNAVAILABLE,
    SupervisorHeartbeat,
    send_heartbeat_blocking_with_minter,
)
from komira_job_supervisor.jm_auth import JmAuthMode, JmTokenMinter, jm_audience


comptime _CANNED_JWT: String = (
    "eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJodHRwczovL2ptLmV4YW1wbGUifQ.c2lnbmF0dXJl"
)


struct ScriptedMinter(JmTokenMinter):
    """Returns a canned, real-looking JWT and COUNTS its calls, so "nothing was
    minted" is an assertion rather than an inference."""

    var token: String
    var calls: Int

    def __init__(out self, var token: String):
        self.token = token^
        self.calls = 0

    def mint(mut self, audience: String) raises -> String:
        self.calls += 1
        return self.token


def _contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1
# setsockopt(2) level/optname are NOT portable: the Linux pair returns EINVAL
# on darwin.
comptime _SOL_SOCKET_LINUX: Int32 = Int32(1)
comptime _SOL_SOCKET_MACOS: Int32 = Int32(0xFFFF)
comptime _SO_REUSEADDR_LINUX: Int32 = Int32(2)
comptime _SO_REUSEADDR_MACOS: Int32 = Int32(0x0004)
# A heartbeat POST head (request line + 4 headers incl. a ~70-byte bearer) and a
# ClientHello both fit well inside this; the arm reads the FIRST bytes only.
comptime _HEAD_CAP: Int = 1024


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin, for the C NULL arguments of
    `accept(2)` / `pthread_create(3)` and the thread's return value.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the
    # all-zero (NULL) bit pattern. The NULL is never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


def _build_sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
        addr[1] = UInt8(0)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[5] = UInt8(0)
    addr[6] = UInt8(0)
    addr[7] = UInt8(1)
    return addr^


@always_inline
def _sol_socket() -> Int32:
    comptime if CompilationTarget.is_macos():
        return _SOL_SOCKET_MACOS
    else:
        return _SOL_SOCKET_LINUX


@always_inline
def _so_reuseaddr() -> Int32:
    comptime if CompilationTarget.is_macos():
        return _SO_REUSEADDR_MACOS
    else:
        return _SO_REUSEADDR_LINUX


def _server_listen() raises -> Int32:
    """socket + SO_REUSEADDR + bind(127.0.0.1:0) + listen. Port 0, always: the
    kernel picks a free port, so concurrent copies of this test (a gated build
    runs many at once) cannot collide."""
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0)
    )
    if fd < Int32(0):
        raise Error("test: socket() failed")
    # SAFETY: `optval` is a stack local; setsockopt(2) reads 4 bytes out of it
    # synchronously and retains nothing.
    var optval = Array[Int32, 1](fill=Int32(1))
    var src = external_call["setsockopt", Int32](
        fd, _sol_socket(), _so_reuseaddr(), optval.unsafe_ptr(), UInt32(4)
    )
    if src < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: setsockopt(SO_REUSEADDR) failed on this platform")
    var addr = _build_sockaddr_in_loopback(UInt16(0))
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["bind", Int32](fd, addr_ptr, UInt32(16))
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: bind() failed")
    rc = external_call["listen", Int32](fd, Int32(8))
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: listen() failed")
    return fd


def _bound_port(fd: Int32) raises -> UInt16:
    """`getsockname(fd)` -> the port the kernel actually bound.

    # SAFETY: FFI boundary — `sa`/`len_buf` are stack locals; the kernel writes
    # up to 16 bytes of sockaddr + 4 bytes of length and retains neither.
    """
    var sa = Array[UInt8, 16](fill=UInt8(0))
    var len_buf = Array[UInt32, 1](fill=UInt32(16))
    var rc = external_call["getsockname", Int32](
        fd, sa.unsafe_ptr(), len_buf.unsafe_ptr()
    )
    if rc < Int32(0):
        raise Error("test: getsockname() failed")
    return UInt16(Int(sa[2]) << 8 | Int(sa[3]))


def _poll_readable(fd: Int32, timeout_ms: Int32) -> Bool:
    """`poll(2)` one fd for POLLIN, bounded. `struct pollfd` is `{int fd; short
    events; short revents}`, packed here as two Int32 on a little-endian host:
    `events` is the low half of the second word, `revents` the high half."""
    var pfd = List[Int32]()
    pfd.append(fd)
    pfd.append(Int32(1))  # events = POLLIN
    var rc = external_call["poll", Int32](
        pfd.unsafe_ptr(), UInt64(1), timeout_ms
    )
    if rc <= Int32(0):
        return False
    var revents = (pfd[1] >> 16) & Int32(0xFFFF)
    return (revents & Int32(1)) != Int32(0)


struct _OneShotListener(Movable):
    """The listener thread's box: the bound fd and its wait bound in; whether a
    client connected and the FIRST bytes it sent, out.

    Fixed-size byte buffer on purpose — a `List` field would be a heap-owning
    field crossing a thread boundary through a raw box (the gap6 shape)."""

    var listen_fd: Int32
    var wait_ms: Int32
    var connections: Int32
    var head: Array[UInt8, _HEAD_CAP]
    var head_len: Int32

    def __init__(out self, listen_fd: Int32, wait_ms: Int32):
        self.listen_fd = listen_fd
        self.wait_ms = wait_ms
        self.connections = Int32(0)
        self.head = Array[UInt8, _HEAD_CAP](fill=UInt8(0))
        self.head_len = Int32(0)


def _listener_thread_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    """pthread start_routine: wait up to `wait_ms` for ONE connection; if one
    comes, keep the first bytes it sends and hang up. The hang-up is what ends
    the client's wait (EOF on a plaintext POST, a failed TLS handshake), so the
    client under test never sits on the 600s default request budget.

    SAFETY (FFI carve-out): `arg` is the `_OneShotListener*` the spawner
    heap-allocated;
    the spawner owns the box and joins before reclaiming it, and pthread_join is
    a full barrier for every write below."""
    var job = arg.bitcast[_OneShotListener]()
    if _poll_readable(job[].listen_fd, job[].wait_ms):
        var conn = external_call["accept", Int32](
            job[].listen_fd,
            _null_ptr[UInt8, MutUntrackedOrigin](),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        if conn >= Int32(0):
            job[].connections = Int32(1)
            if _poll_readable(conn, Int32(10000)):
                var buf = List[UInt8]()
                buf.resize(unsafe_uninit_length=_HEAD_CAP)
                var n = external_call["recv", Int64](
                    conn, buf.unsafe_ptr(), UInt64(_HEAD_CAP), Int32(0)
                )
                var k = Int(n) if n > Int64(0) else 0
                for i in range(k):
                    job[].head[i] = buf[i]
                job[].head_len = Int32(k)
            _ = external_call["close", Int32](conn)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


struct _LoopbackBeat(Movable):
    """What one beat did, as seen from BOTH ends: the client's outcome, and the
    listener's count of connections plus the first bytes of the one it got."""

    var ok: Bool
    var status: Int
    var connections: Int
    var head: List[UInt8]

    def __init__(
        out self, ok: Bool, status: Int, connections: Int, var head: List[UInt8]
    ):
        self.ok = ok
        self.status = status
        self.connections = connections
        self.head = head^


def _beat_through_loopback(
    use_tls: Bool, mode: JmAuthMode, mut minter: ScriptedMinter, wait_ms: Int32
) raises -> _LoopbackBeat:
    """Send ONE heartbeat to a 127.0.0.1 listener through the REAL
    `send_heartbeat_blocking` body (transport + scheme + posture chosen there),
    with the scripted minter, and report both ends."""
    var listen_fd = _server_listen()
    var port = _bound_port(listen_fd)

    var raw = alloc[_OneShotListener](1)
    UnsafePointer(to=raw[]).unsafe_write(_OneShotListener(listen_fd, wait_ms))
    var entry = _listener_thread_entry
    var tid: UInt64 = UInt64(0)
    var raw_arg = raw.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var rc = external_call["pthread_create", Int32](
        UnsafePointer(to=tid).bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        entry,
        raw_arg,
    )
    if rc != Int32(0):
        var fallback = OwnedPointer[_OneShotListener](
            unsafe_from_raw_pointer=raw
        )
        _ = fallback^
        _ = external_call["close", Int32](listen_fd)
        raise Error("test: pthread_create failed for the loopback listener")

    var hb = SupervisorHeartbeat(
        String("11111111-2222-3333-4444-555555555555"),
        JobSupervisorPhase.running(),
        String("pod-cleartext-guard"),
        Optional[Int32](),
        Optional[String](),
        Optional[FailureReport](),
    )
    var scheme = String("https") if use_tls else String("http")
    var outcome = send_heartbeat_blocking_with_minter[ScriptedMinter](
        String("127.0.0.1"),
        port,
        hb,
        use_tls,
        mode,
        jm_audience(scheme, String("127.0.0.1"), port),
        minter,
    )

    var retval: UInt64 = UInt64(0)
    _ = external_call["pthread_join", Int32](
        tid, UnsafePointer(to=retval).bitcast[UInt8]()
    )
    _ = external_call["close", Int32](listen_fd)
    var head = List[UInt8]()
    for i in range(Int(raw[].head_len)):
        head.append(raw[].head[i])
    var connections = Int(raw[].connections)
    var owned = OwnedPointer[_OneShotListener](unsafe_from_raw_pointer=raw)
    _ = owned^
    return _LoopbackBeat(outcome.ok, outcome.status, connections, head^)


def _request_head_lower(raw: List[UInt8]) -> String:
    """The captured bytes up to the end of the HTTP head (`\\r\\n\\r\\n`),
    LOWERCASED, with any non-ASCII byte rendered as `?`. The capture can run on
    into the protobuf body, which is binary; only the head is text."""
    var out = String("")
    var n = len(raw)
    for i in range(n):
        if (
            i + 3 < n
            and raw[i] == UInt8(0x0D)
            and raw[i + 1] == UInt8(0x0A)
            and raw[i + 2] == UInt8(0x0D)
            and raw[i + 3] == UInt8(0x0A)
        ):
            break
        var b = raw[i]
        out += chr(Int(b)) if b < UInt8(0x80) else String("?")
    return out.lower()


def _bytes_contain(hay: List[UInt8], needle: String) -> Bool:
    """Byte-wise, case-SENSITIVE search. Used on the TLS control's bytes, which
    are a binary ClientHello and must not be decoded as text."""
    var n = needle.as_bytes()
    var nl = len(n)
    if nl == 0 or nl > len(hay):
        return False
    for i in range(len(hay) - nl + 1):
        var hit = True
        for j in range(nl):
            if hay[i + j] != n[j]:
                hit = False
                break
        if hit:
            return True
    return False


def test_no_credential_is_minted_or_sent_over_a_plaintext_dial() raises:
    """⛔⛔ (plaintext, gcp-metadata) IS REFUSED BEFORE THE MINT AND BEFORE THE
    DIAL: zero mints, zero connections, and its own status.

    RED before the fix: the scripted minter was called once, the listener got a
    connection, and that connection's head carried `authorization: bearer
    <token>` in the clear."""
    var minter = ScriptedMinter(_CANNED_JWT)
    var r = _beat_through_loopback(
        False, JmAuthMode.gcp_metadata(), minter, Int32(3000)
    )
    var leaked = _bytes_contain(r.head, _CANNED_JWT)
    assert_equal(
        r.connections,
        0,
        "⛔ a (plaintext, gcp-metadata) heartbeat DIALLED the job manager"
        " (bearer token readable on that plaintext connection: "
        + String(leaked)
        + "). A posture that attaches a credential must never ride a plaintext"
        " dial; it is refused before the dial",
    )
    assert_equal(
        minter.calls,
        0,
        "⛔ a (plaintext, gcp-metadata) heartbeat MINTED an ID token it could"
        " only have sent in the clear. The refusal comes before the mint",
    )
    assert_false(r.ok, "a refused beat is not ok")
    assert_equal(
        r.status,
        HEARTBEAT_STATUS_AUTH_REFUSED,
        "the refusal is its own status: not AUTH_UNAVAILABLE (-1, the mint"
        " failed) and not 0 (never connected, a network blip)",
    )
    # Asked of the OUTCOME, not of the constants (a constant-vs-constant check
    # folds at compile time and only warns): the status this beat came back
    # with is not a real HTTP status, not "never connected", and not "the mint
    # failed".
    assert_true(
        r.status < 0
        and r.status != 0
        and r.status != HEARTBEAT_STATUS_AUTH_UNAVAILABLE,
        "the refused beat's status is negative, and distinct from both 0 and"
        " AUTH_UNAVAILABLE",
    )

    # CONTROL 1: the SAME listener DOES see a plaintext dial when one is legal.
    # Without this, `connections == 0` above is satisfied by a listener that
    # cannot see anything.
    var none_minter = ScriptedMinter(_CANNED_JWT)
    var p = _beat_through_loopback(
        False, JmAuthMode.none(), none_minter, Int32(20000)
    )
    assert_equal(
        p.connections,
        1,
        "CONTROL: (plaintext, none) is a legal posture and DOES dial -- the"
        " listener sees it",
    )
    var p_head = _request_head_lower(p.head)
    assert_true(
        p_head.startswith(String("post /internal/heartbeat")),
        "CONTROL: what it sent is the plaintext heartbeat POST: " + p_head,
    )
    assert_false(
        _contains(p_head, String("authorization")),
        "CONTROL: (plaintext, none) carries no credential",
    )
    assert_equal(none_minter.calls, 0, "CONTROL: posture `none` never mints")

    # CONTROL 2: the LEGAL credential posture -- (TLS, gcp-metadata) -- still
    # mints and still dials, and its first bytes are a TLS handshake record, not
    # a plaintext POST. Without this, the case above is satisfied by a guard
    # that refuses every credentialed beat.
    var tls_minter = ScriptedMinter(_CANNED_JWT)
    var t = _beat_through_loopback(
        True, JmAuthMode.gcp_metadata(), tls_minter, Int32(20000)
    )
    assert_equal(
        tls_minter.calls, 1, "CONTROL: (TLS, gcp-metadata) still mints"
    )
    assert_equal(t.connections, 1, "CONTROL: (TLS, gcp-metadata) still dials")
    assert_true(
        len(t.head) >= 2
        and Int(t.head[0]) == 0x16
        and Int(t.head[1]) == 0x03,
        "CONTROL: (TLS, gcp-metadata) opens with a TLS HANDSHAKE record (0x16"
        " 0x03), not a plaintext POST",
    )
    assert_false(
        _bytes_contain(t.head, _CANNED_JWT),
        "CONTROL: the token is not readable in the TLS connection's first bytes",
    )
    print(
        "  test_no_credential_is_minted_or_sent_over_a_plaintext_dial: PASS"
    )


def main() raises:
    print("test_heartbeat_no_credential_in_clear:")
    test_no_credential_is_minted_or_sent_over_a_plaintext_dial()
    print("test_heartbeat_no_credential_in_clear: ALL PASS")

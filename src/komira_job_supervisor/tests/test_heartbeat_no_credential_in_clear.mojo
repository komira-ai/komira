# =============================================================================
# komira_job_supervisor/tests/test_heartbeat_no_credential_in_clear.mojo
#   A CREDENTIAL NEVER RIDES A PLAINTEXT HEARTBEAT: nothing produced, nothing
#   sent.
# =============================================================================
#
# `HttpHeartbeatReporter[A]` delivers each beat as an HTTP POST, authenticated
# by the operator's `HeartbeatAuth` conformer `A`. When `A` attaches a
# credential, an http:// URL would put that credential on every hop in the
# clear, so the pair is refused: when the reporter is built, and again before
# every beat, before `A` is asked and before anything is dialled.
#
# WHAT THIS TEST IS. Beats through the REAL reporter at a 127.0.0.1 listener,
# reading BOTH ends: the auth conformer's call count, the reporter's outcome,
# and whether the listener was dialled and what it was sent.
#
# EVERY CASE HAS A CONTROL: the same listener SEES a legal plaintext dial (no
# credential), and the legal credential pair (TLS, a credential-attaching
# auth) still asks the conformer and still dials. Without them, "zero
# connections" is satisfied by a listener that sees nothing, and "zero calls"
# by a guard that refuses every credentialed beat. A conformer that RAISES
# yields AUTH_UNAVAILABLE and no dial: a failed credential never falls through
# to an unauthenticated POST.
#
# ENCAPSULATION: the raw-socket SERVER and the pthread are this test's own FFI
# boundary; the code under test never exposes a pointer. The thread's box
# holds only fixed-size fields.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_http_client.header_map import HeaderEntry

from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase, FailureReport
from komira_job_supervisor.heartbeat_auth import HeartbeatAuth, NoHeartbeatAuth
from komira_job_supervisor.heartbeat_client import (
    HEARTBEAT_STATUS_AUTH_UNAVAILABLE,
    HttpHeartbeatReporter,
    SupervisorHeartbeat,
)


comptime _CANNED_TOKEN: String = (
    "eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJodHRwczovL2hiLmV4YW1wbGUifQ.c2lnbmF0dXJl"
)
comptime _PATH: String = "/hb/v1"


struct ScriptedAuth(HeartbeatAuth):
    """A credential-attaching conformer: a canned bearer token, and a COUNT
    of its calls, so "nothing was produced" is an assertion rather than an
    inference."""

    var token: String
    var calls: Int

    def __init__(out self, var token: String):
        self.token = token^
        self.calls = 0

    def name(self) -> String:
        return String("scripted-bearer")

    def attaches_credential(self) -> Bool:
        return True

    def headers(
        mut self, method: String, url: String, body: List[UInt8]
    ) raises -> List[HeaderEntry]:
        self.calls += 1
        var out = List[HeaderEntry]()
        out.append(
            HeaderEntry(
                name=String("Authorization"),
                value=String("Bearer ") + self.token,
            )
        )
        return out^


struct FailingAuth(HeartbeatAuth):
    """A credential-attaching conformer whose every call raises."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def name(self) -> String:
        return String("failing-bearer")

    def attaches_credential(self) -> Bool:
        return True

    def headers(
        mut self, method: String, url: String, body: List[UInt8]
    ) raises -> List[HeaderEntry]:
        self.calls += 1
        raise Error("scripted: the credential source answered 404")


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


def _beat_through_loopback[
    A: HeartbeatAuth
](use_tls: Bool, mut reporter_out: Optional[HttpHeartbeatReporter[A]], var auth: A, wait_ms: Int32) raises -> _LoopbackBeat:
    """Build a REAL `HttpHeartbeatReporter[A]` for a 127.0.0.1 listener, send
    ONE beat through it, and report both ends. The reporter is handed back
    through `reporter_out` so the caller can read its auth's call count."""
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
        String("job-cleartext-guard"),
        JobSupervisorPhase.running(),
        String("instance-cleartext-guard"),
        Optional[Int32](),
        Optional[String](),
        Optional[FailureReport](),
    )
    var scheme = String("https") if use_tls else String("http")
    var url = scheme + String("://127.0.0.1:") + String(port) + _PATH
    var reporter = HttpHeartbeatReporter[A](url, auth^)
    var outcome = reporter.report(hb)
    reporter_out = Optional[HttpHeartbeatReporter[A]](reporter^)

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


def test_a_credential_over_plaintext_is_refused_at_construction() raises:
    """(http, credential-attaching auth) is REFUSED when the reporter is
    built: the conformer is never asked, and the refusal names the auth, not
    the credential."""
    var auth = ScriptedAuth(_CANNED_TOKEN)
    var refused = False
    var msg = String("")
    try:
        var r = HttpHeartbeatReporter[ScriptedAuth](
            String("http://127.0.0.1:9/hb/v1"), auth^
        )
        _ = r^
    except e:
        refused = True
        msg = String(e)
    assert_true(
        refused,
        "a credential-attaching auth over an http:// URL must be refused when"
        " the reporter is built",
    )
    assert_true(_contains(msg, String("scripted-bearer")), "names the auth: " + msg)
    assert_false(
        _contains(msg, String("eyJ")), "the refusal carries no credential"
    )

    # CONTROL: the same auth over https:// is accepted (nothing is dialled by
    # construction), and has not been asked for a credential yet.
    var ok = HttpHeartbeatReporter[ScriptedAuth](
        String("https://hb.example.com/hb/v1"), ScriptedAuth(_CANNED_TOKEN)
    )
    assert_true(ok.uses_tls(), "CONTROL: an https URL selects TLS")
    assert_equal(ok.auth().calls, 0, "CONTROL: construction asks for nothing")
    print("  test_a_credential_over_plaintext_is_refused_at_construction: PASS")


def test_the_loopback_sees_exactly_the_legal_beats() raises:
    # CONTROL 1: the listener DOES see a plaintext dial when one is legal (no
    # credential). Without this, `connections == 0` below is satisfied by a
    # listener that cannot see anything.
    var none_rep = Optional[HttpHeartbeatReporter[NoHeartbeatAuth]]()
    var p = _beat_through_loopback[NoHeartbeatAuth](
        False, none_rep, NoHeartbeatAuth(), Int32(20000)
    )
    assert_equal(
        p.connections, 1, "CONTROL: (plaintext, none) dials; the listener sees it"
    )
    var p_head = _request_head_lower(p.head)
    assert_true(
        p_head.startswith(String("post ") + _PATH),
        "CONTROL: it sent the heartbeat POST to the URL's path: " + p_head,
    )
    assert_true(
        _contains(p_head, String("content-type: application/protobuf")),
        "CONTROL: the body is protobuf",
    )
    assert_false(
        _contains(p_head, String("authorization")),
        "CONTROL: (plaintext, none) carries no credential",
    )

    # CONTROL 2: the LEGAL credential pair (TLS, credential-attaching auth)
    # still asks the conformer and still dials, and its first bytes are a TLS
    # handshake record, not a plaintext POST.
    var tls_rep = Optional[HttpHeartbeatReporter[ScriptedAuth]]()
    var t = _beat_through_loopback[ScriptedAuth](
        True, tls_rep, ScriptedAuth(_CANNED_TOKEN), Int32(20000)
    )
    assert_equal(
        tls_rep.value().auth().calls, 1, "CONTROL: (TLS, credential) asks once"
    )
    assert_equal(t.connections, 1, "CONTROL: (TLS, credential) dials")
    assert_true(
        len(t.head) >= 2 and Int(t.head[0]) == 0x16 and Int(t.head[1]) == 0x03,
        "CONTROL: (TLS, credential) opens with a TLS HANDSHAKE record (0x16"
        " 0x03), not a plaintext POST",
    )
    assert_false(
        _bytes_contain(t.head, _CANNED_TOKEN),
        "CONTROL: the token is not readable in the TLS connection's first bytes",
    )

    # FAIL CLOSED: a conformer that raises yields AUTH_UNAVAILABLE and NO
    # dial, never an unauthenticated POST.
    var fail_rep = Optional[HttpHeartbeatReporter[FailingAuth]]()
    var f = _beat_through_loopback[FailingAuth](
        True, fail_rep, FailingAuth(), Int32(3000)
    )
    assert_equal(fail_rep.value().auth().calls, 1, "the conformer was asked")
    assert_equal(
        f.connections, 0, "a failed credential must not fall through to a dial"
    )
    assert_false(f.ok, "a beat with no credential is not ok")
    assert_equal(
        f.status,
        HEARTBEAT_STATUS_AUTH_UNAVAILABLE,
        "its own status: not 0 (never connected, a network blip)",
    )
    print("  test_the_loopback_sees_exactly_the_legal_beats: PASS")


def main() raises:
    print("test_heartbeat_no_credential_in_clear:")
    test_a_credential_over_plaintext_is_refused_at_construction()
    test_the_loopback_sees_exactly_the_legal_beats()
    print("test_heartbeat_no_credential_in_clear: ALL PASS")

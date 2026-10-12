# =============================================================================
# komira_job_supervisor/tests/test_s3_transport_first_byte.mojo
#   An https:// URL is dialled over TLS and an http:// URL in the clear, read
#   from the first byte a 127.0.0.1 listener receives.
# =============================================================================
#
#   test_the_credential_transport_speaks_tls_for_https
#       S3CredentialTransport sends an https request as a TLS handshake (first
#       byte 0x16, a TLS handshake record) and an http request as plain HTTP
#       (first byte 'G' of "GET"). Catches an https arm that dials plain TCP:
#       a closed port refuses both alike, so only a listener that reads the
#       bytes can tell the transports apart.
#   test_the_s3_entry_point_speaks_tls_for_an_https_endpoint
#       `run_job_supervisor_on_s3` with a log bucket on an https:// endpoint
#       writes logs.txt over TLS (first byte 0x16); the CONTROL, the same log
#       bucket on an http:// endpoint, writes it in the clear (first byte 'P'
#       of "PUT"). Catches an entry point that ignores `uses_tls()` and dials
#       plain TCP for every endpoint, which would fetch the job binary from
#       AWS in the clear. Each run still ends COMPLETED: a failed log write
#       changes nothing.
#
# The listener accepts ONE connection on a kernel-chosen port (port 0, so
# concurrent runs cannot collide), closes its listening socket at once so a
# client's retry is refused rather than left waiting, keeps the first bytes
# and hangs up; the hang-up ends the client's wait. The AWS keys are the
# documented example values, read by the default chain's environment arm, so
# no credential provider is dialled.
#
# ENCAPSULATION: the raw-socket server and the pthread are this test's own FFI
# boundary; the code under test never exposes a pointer. The thread's box
# holds only fixed-size fields.
#
# FFI-BOUNDARY: the socket, pthread_create and pthread_join FFI of the
# listener. `_first_bytes` allocates the thread's box, joins the thread and
# then frees the box; the thread owns and closes the listening socket and the
# accepted one. The C NULLs (MutUntrackedOrigin) are never dereferenced.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc
from std.os import setenv
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_aws_core.credential_transport import CredentialHttpRequest

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisorConfig,
    JobSupervisorPhase,
    S3StoreFlags,
    SupervisorHeartbeat,
    run_job_supervisor_on_s3,
)
from komira_job_supervisor.s3_store import S3CredentialTransport


comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1
comptime _SOL_SOCKET_LINUX: Int32 = Int32(1)
comptime _SOL_SOCKET_MACOS: Int32 = Int32(0xFFFF)
comptime _SO_REUSEADDR_LINUX: Int32 = Int32(2)
comptime _SO_REUSEADDR_MACOS: Int32 = Int32(0x0004)
comptime _HEAD_CAP: Int = 64
comptime _TLS_HANDSHAKE: UInt8 = UInt8(0x16)

# What the listener's client does (see `_first_bytes`).
comptime _CRED_HTTPS: Int = 0
comptime _CRED_HTTP: Int = 1
comptime _ENTRY_HTTPS: Int = 2
comptime _ENTRY_HTTP: Int = 3


struct Recorder(HeartbeatReporter):
    var beats: ArcPointer[List[String]]

    def __init__(out self, beats: ArcPointer[List[String]]):
        self.beats = beats

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        self.beats[].append(String(hb.phase.wire_str()))
        return HeartbeatOutcome(True, False, 200)


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin, for the C NULL arguments of
    `accept(2)` / `pthread_create(3)` and the thread's return value.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. Never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


def _sockaddr_loopback(port: UInt16) -> Array[UInt8, 16]:
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[7] = UInt8(1)
    return addr^


def _server_listen() raises -> Int32:
    """socket + SO_REUSEADDR + bind(127.0.0.1:0) + listen."""
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0)
    )
    if fd < Int32(0):
        raise Error("test: socket() failed")
    var level = _SOL_SOCKET_LINUX
    var opt = _SO_REUSEADDR_LINUX
    comptime if CompilationTarget.is_macos():
        level = _SOL_SOCKET_MACOS
        opt = _SO_REUSEADDR_MACOS
    # SAFETY: `optval` is a stack local; setsockopt(2) reads 4 bytes of it
    # synchronously and retains nothing.
    var optval = Array[Int32, 1](fill=Int32(1))
    if external_call["setsockopt", Int32](
        fd, level, opt, optval.unsafe_ptr(), UInt32(4)
    ) < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: setsockopt(SO_REUSEADDR) failed")
    var addr = _sockaddr_loopback(UInt16(0))
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    if external_call["bind", Int32](fd, addr_ptr, UInt32(16)) < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: bind() failed")
    if external_call["listen", Int32](fd, Int32(8)) < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: listen() failed")
    return fd


def _bound_port(fd: Int32) raises -> Int:
    """`getsockname(fd)`: the port the kernel bound.

    # SAFETY: `sa`/`len_buf` are stack locals; the kernel writes up to 16
    # bytes of sockaddr and 4 of length and retains neither.
    """
    var sa = Array[UInt8, 16](fill=UInt8(0))
    var len_buf = Array[UInt32, 1](fill=UInt32(16))
    if external_call["getsockname", Int32](
        fd, sa.unsafe_ptr(), len_buf.unsafe_ptr()
    ) < Int32(0):
        raise Error("test: getsockname() failed")
    return Int(sa[2]) << 8 | Int(sa[3])


def _poll_readable(fd: Int32, timeout_ms: Int32) -> Bool:
    """`poll(2)` one fd for POLLIN, bounded. `struct pollfd` is `{int fd; short
    events; short revents}`, packed as two Int32 on a little-endian host."""
    var pfd = List[Int32]()
    pfd.append(fd)
    pfd.append(Int32(1))  # events = POLLIN
    var rc = external_call["poll", Int32](pfd.unsafe_ptr(), UInt64(1), timeout_ms)
    if rc <= Int32(0):
        return False
    return ((pfd[1] >> 16) & Int32(1)) != Int32(0)


struct _OneShotListener(Movable):
    """The listener thread's box: the bound fd and its wait bound in; whether
    a client connected and the first bytes it sent, out. Fixed-size fields
    only, since the box crosses a thread boundary."""

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
    """pthread start_routine: wait up to `wait_ms` for ONE connection, close
    the listening socket (a retry is then refused), keep the first bytes the
    client sends and hang up. The thread owns and closes `listen_fd`.

    SAFETY (FFI carve-out): `arg` is the `_OneShotListener*` the spawner
    heap-allocated; the spawner owns the box and joins before reading or
    freeing it, and pthread_join is a full barrier for every write below."""
    var job = arg.bitcast[_OneShotListener]()
    if _poll_readable(job[].listen_fd, job[].wait_ms):
        var conn = external_call["accept", Int32](
            job[].listen_fd,
            _null_ptr[UInt8, MutUntrackedOrigin](),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        _ = external_call["close", Int32](job[].listen_fd)
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
    else:
        _ = external_call["close", Int32](job[].listen_fd)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


struct _Seen(Movable):
    """Both ends of one dial: what the client returned (or raised), and the
    listener's connection count and first bytes."""

    var outcome: String
    var connections: Int
    var head: List[UInt8]

    def __init__(out self, var outcome: String, connections: Int, var head: List[UInt8]):
        self.outcome = outcome^
        self.connections = connections
        self.head = head^


def _set_example_keys():
    # The documented example key pair: worthless, read by the environment arm.
    _ = setenv(String("AWS_ACCESS_KEY_ID"), String("AKIAIOSFODNN7EXAMPLE"), True)
    _ = setenv(
        String("AWS_SECRET_ACCESS_KEY"),
        String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        True,
    )


def _credential_dial(scheme: String, port: Int) -> String:
    var t = S3CredentialTransport()
    var req = CredentialHttpRequest(
        String("GET"), scheme, String("127.0.0.1"), port, String("/credentials")
    )
    try:
        var res = t.send(req)
        return String("answered ") + String(res.status)
    except e:
        return String("raised: ") + String(e)


def _entry_run(scheme: String, port: Int) -> String:
    var beats = ArcPointer[List[String]](List[String]())
    var config = JobSupervisorConfig(
        String("s3-first-byte-") + scheme,
        String("instance-1"),
        String("/bin/true"),
        List[String](),
        String("http://127.0.0.1:1/beat"),
        heartbeat_interval_secs=1,
    )
    var flags = S3StoreFlags(
        None,
        Optional[String](String("logs")),
        Optional[String](scheme + String("://127.0.0.1:") + String(port)),
        String("us-east-1"),
    )
    try:
        var phase = run_job_supervisor_on_s3[Recorder](config^, Recorder(beats), flags)
        return String("phase ") + String(phase.wire_str())
    except e:
        return String("raised: ") + String(e)


def _first_bytes(kind: Int) raises -> _Seen:
    """Arm a one-shot 127.0.0.1 listener, run the client `kind` names against
    its port, join, and report both ends."""
    var listen_fd = _server_listen()
    var port = _bound_port(listen_fd)
    var raw = alloc[_OneShotListener](1)
    UnsafePointer(to=raw[]).unsafe_write(_OneShotListener(listen_fd, Int32(20000)))
    var entry = _listener_thread_entry
    var tid: UInt64 = UInt64(0)
    var raw_arg = raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
    var rc = external_call["pthread_create", Int32](
        UnsafePointer(to=tid).bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        entry,
        raw_arg,
    )
    if rc != Int32(0):
        var fallback = OwnedPointer[_OneShotListener](unsafe_from_raw_pointer=raw)
        _ = fallback^
        _ = external_call["close", Int32](listen_fd)
        raise Error("test: pthread_create failed for the loopback listener")

    var outcome: String
    if kind == _CRED_HTTPS:
        outcome = _credential_dial(String("https"), port)
    elif kind == _CRED_HTTP:
        outcome = _credential_dial(String("http"), port)
    elif kind == _ENTRY_HTTPS:
        outcome = _entry_run(String("https"), port)
    else:
        outcome = _entry_run(String("http"), port)

    var retval: UInt64 = UInt64(0)
    _ = external_call["pthread_join", Int32](
        tid, UnsafePointer(to=retval).bitcast[UInt8]()
    )
    var head = List[UInt8]()
    for i in range(Int(raw[].head_len)):
        head.append(raw[].head[i])
    var connections = Int(raw[].connections)
    var owned = OwnedPointer[_OneShotListener](unsafe_from_raw_pointer=raw)
    _ = owned^
    return _Seen(outcome^, connections, head^)


def _first(seen: _Seen) -> Int:
    return Int(seen.head[0]) if len(seen.head) > 0 else -1


def test_the_credential_transport_speaks_tls_for_https() raises:
    var tls = _first_bytes(_CRED_HTTPS)
    assert_equal(tls.connections, 1, "https is dialled: " + tls.outcome)
    assert_equal(
        _first(tls), Int(_TLS_HANDSHAKE),
        "https opens with a TLS handshake record: " + tls.outcome,
    )
    assert_true(tls.outcome.startswith(String("raised: ")), tls.outcome)

    var plain = _first_bytes(_CRED_HTTP)
    assert_equal(plain.connections, 1, "http is dialled: " + plain.outcome)
    assert_true(len(plain.head) >= 4, "http sent a request line")
    assert_equal(_first(plain), Int(ord("G")), "http opens with GET: " + plain.outcome)
    assert_equal(Int(plain.head[3]), Int(ord(" ")))
    print("  test_the_credential_transport_speaks_tls_for_https: PASS")


def test_the_s3_entry_point_speaks_tls_for_an_https_endpoint() raises:
    _set_example_keys()
    var tls = _first_bytes(_ENTRY_HTTPS)
    assert_equal(tls.outcome, String("phase COMPLETED"), "a failed log write changes nothing")
    assert_equal(tls.connections, 1, "the logs.txt write is dialled")
    assert_equal(
        _first(tls), Int(_TLS_HANDSHAKE),
        "an https:// endpoint is written over TLS",
    )

    var plain = _first_bytes(_ENTRY_HTTP)
    assert_equal(plain.outcome, String("phase COMPLETED"))
    assert_equal(plain.connections, 1, "the logs.txt write is dialled")
    assert_true(len(plain.head) >= 4, "http sent a request line")
    assert_equal(_first(plain), Int(ord("P")), "an http:// endpoint is written in the clear")
    assert_equal(Int(plain.head[3]), Int(ord(" ")), "PUT, then a space")
    print("  test_the_s3_entry_point_speaks_tls_for_an_https_endpoint: PASS")


def main() raises:
    print("test_s3_transport_first_byte:")
    test_the_credential_transport_speaks_tls_for_https()
    test_the_s3_entry_point_speaks_tls_for_an_https_endpoint()
    print("test_s3_transport_first_byte: ALL PASS")

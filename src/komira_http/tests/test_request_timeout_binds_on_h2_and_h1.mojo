# =============================================================================
# komira_http/tests/test_request_timeout_binds_on_h2_and_h1.mojo
# =============================================================================
#
# ⛔ THE FINDING IS THE ASYMMETRY, NOT ONE SLOW REQUEST.
#
# `HttpClientConfig.request_timeout_us` is the ONE knob a caller has for "this
# request must not outlive N microseconds". If its only consumer is
# `OutboundDriver.set_request_timeout_us`, which only the BUFFERED h1 arms
# call, every h2 arm drops the authored value on the floor and takes
# `_H2_DRIVE_DEFAULT_WALL_US` (120s), and the STREAMING h1 arm drops it too and
# takes `_HEAD_DRIVE_DEFAULT_TIMEOUT_US` (600s). One number then means three
# different walls depending on which protocol the peer happens to negotiate,
# and NOTHING says so at the call site.
#
# THE SHAPE THAT HITS IT. A 20s budget threaded into a GCS gRPC client so a
# read cannot outrun one unit of work: that read is
# `read_range` -> `stub.read_object` -> SERVER-STREAMING -> `send_grpc_pooled`,
# and production is TLS, so it takes the POOLED-h2 arm — where an h1-only
# budget reaches nothing. A test asserting the value reached
# `HttpClientConfig` passes while the request stays bounded by 120s.
#
# WHY A CANCELLATION TOKEN IS NOT THE FIX ON THIS PATH (evaluated, refuted).
# `komira_grpc`'s client names the token as "the ONE client-side deadline
# trip": the runtime's clock trips `token.cancel()`, `RecvRingBody.poll_frame`
# reads `token.is_cancelled()`. Three things make it unable to bind here:
#   (1) `CancellationToken` has no deadline-arming API at all (`cancel()` is
#       called by somebody); this client owns no runtime clock to arm one with,
#       which is why every verb passes `CancellationToken.never()`.
#   (2) `drive_h2_streams_to_completion` — where the stall actually happens —
#       takes NO token and reads none.
#   (3) By the time a `RecvRingBody` exists on the pooled-h2 path the response
#       body is ALREADY fully materialized (`RecvRingBody.from_buffered_bytes`),
#       so `poll_frame`'s token check runs over finished bytes. It sits
#       downstream of the wait it would have to interrupt.
# The drive loop's own `max_wall_us` — which its constant's doc already invited
# ("Callers (e.g. a deadline-carrying RPC) may pass a tighter bound") — is the
# mechanism that already exists. `h2_drive_wall_us` is the single place the
# authored budget becomes it.
#
# WHAT THIS FILE ASSERTS — BEHAVIOUR, NOT PLUMBING. A field-read-back assertion
# is exactly what let the asymmetry land: a parameter can reach a config and
# still bound nothing. Every case here drives a REAL socket against a peer that
# accepts the connection and then goes SILENT, and asserts on the WALL CLOCK.
#
# HERMETIC: `socketpair(2)` only — no listen, no connect, no DNS, no
# credentials. The peer is this process.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.testing import assert_true

from komira_obs.clock import now_ns

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.tcp_stream import TcpStream

from komira_http.client.body import BytesBody, EmptyBody
from komira_http.client.client import (
    HttpClient,
    build_get_request,
    build_request_with_body,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.request_writer import method_post
from komira_http.client.url import Url
from komira_http.codec.h2.frame import SettingsEntry, encode_settings_frame
from komira_http.transport.io_stream import (
    Connector,
    NEGOTIATED_HTTP_1_1,
    NEGOTIATED_HTTP_2,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http.transport.kernel_tcp import TcpIoStream


comptime _RT = PerCoreAsyncRuntime[NoopSink]

# socketpair(2) constants (Linux + Darwin agree on these values).
comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)

# ★ THE AUTHORED BUDGET UNDER TEST. Small enough that the two defaults it must
# displace (120s h2 / 600s h1-streaming) are 60x and 300x away — no amount of
# scheduling noise can confuse "the budget bound it" with "a default did".
comptime _AUTHORED_BUDGET_US: Int = 2_000_000  # 2s

# The window a bound request must terminate inside. 30s is 15x the authored
# budget (so a slow, loaded box cannot red this) and 4x BELOW the nearest
# default it displaces (so a run that fell back to a default cannot pass).
comptime _MUST_TERMINATE_WITHIN_US: Int = 30_000_000  # 30s

# ⛔ AND A FLOOR, WHICH IS THE HALF A TIMEOUT TEST USUALLY FORGETS. Terminating
# INSTANTLY is not evidence the budget bound anything — it is what a connector
# bug, a scheme-check refusal or an immediate EOF looks like, and every one of
# those would make this file green while proving nothing. A bound drive must
# have actually WAITED most of its budget.
comptime _MUST_HAVE_WAITED_AT_LEAST_US: Int = 1_000_000  # 1s


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _socketpair() -> SIMD[DType.int32, 2]:
    """libc socketpair(2): connected AF_UNIX SOCK_STREAM pair, (a_fd, b_fd).
    SAFETY: stack-local SIMD pair; libc writes 2 int32 into it; never escapes —
    the UnsafePointer is confined to this FFI thunk per the encapsulation
    rule."""
    var fds = SIMD[DType.int32, 2](-1, -1)
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0),
        UnsafePointer(to=fds).bitcast[UInt8](),
    )
    if rc < 0:
        return SIMD[DType.int32, 2](-1, -1)
    return fds


def _set_nonblocking(fd: Int32):
    """fcntl(fd, F_SETFL, O_NONBLOCK). F_GETFL=3, F_SETFL=4, O_NONBLOCK=0x4 —
    Linux and Darwin agree. The client end must be non-blocking so `try_read`
    returns Pending: that is the branch that parks, and parking is the state
    the wall-clock bound exists to terminate."""
    var flags = external_call["fcntl", Int32](fd, Int32(3), Int32(0))
    _ = external_call["fcntl", Int32](fd, Int32(4), flags | Int32(0x4))


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _send_all(fd: Int32, data: List[UInt8]) -> Int64:
    """send(2) the whole buffer. SAFETY: borrows `data`'s storage via a
    confined FFI thunk; the pointer never escapes the call."""
    if len(data) == 0:
        return 0
    return external_call["send", Int64](
        fd, data.unsafe_ptr(), UInt(len(data)), Int32(0),
    )


def _h2_settings_only() raises -> List[UInt8]:
    """The server's initial SETTINGS frame and NOTHING ELSE — a HEALTHY h2
    handshake followed by silence. This is the peer class a `Grpc-Timeout`
    header cannot help with: it ACCEPTED the stream, so there is no transport
    error to surface, and it will never answer."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    return out^


# =============================================================================
# The silent-peer Connector — one pre-made socketpair fd, one stated ALPN.
# =============================================================================


struct _SilentPeerConnector(Connector, Movable, Deinitable):
    """Hands out ONE `TcpIoStream` over a caller-supplied, already-connected
    socketpair fd, reporting a caller-stated ALPN.

    Why not `ScriptedConnector`: a `ScriptedStream` has `fd() == -1`, so
    `park_on_pending` early-returns and the drive loop never parks. A
    never-parking loop burns its iteration cap (or trips the LIVELOCK detector)
    in milliseconds — it can never exercise a WALL-CLOCK bound, which is the
    only thing this file is about. A real kernel fd whose peer is silent is the
    one substrate on which "the drive waited" and "the drive gave up at N" are
    distinguishable.

    Why not `KernelTcpConnector`: it dials. A test that dials is not hermetic.
    """

    comptime Stream = TcpIoStream

    var _fd: Int32
    var _alpn: UInt8
    var _claim_tls: Bool
    var _connects: Int

    def __init__(out self, fd: Int32, alpn: UInt8, claim_tls: Bool):
        self._fd = fd
        self._alpn = alpn
        self._claim_tls = claim_tls
        self._connects = 0

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> TcpIoStream:
        _ = reactor
        _ = ip_be
        _ = port
        self._connects = self._connects + 1
        if self._connects > 1:
            # A second dial would mean the test is measuring a RE-dial, not the
            # drive it armed. Refuse rather than hand out a closed fd.
            raise Error(
                "_SilentPeerConnector: dial #"
                + String(self._connects)
                + " — this fixture arms exactly ONE connection"
            )
        return TcpIoStream(TcpStream(self._fd), self._alpn)

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return self._claim_tls

    def set_dial_host(mut self, var host: String):
        _ = host^


def _elapsed_us(start_ns: UInt64) -> Int:
    return Int((now_ns() - start_ns) // UInt64(1000))


def _assert_bound(arm: String, raised: Bool, elapsed_us: Int) raises:
    """The shared verdict both arms are held to — ONE window, so the two arms
    cannot drift apart by being asserted differently."""
    assert_true(
        raised,
        arm
        + ": a silent peer must make the request TERMINATE, not return a"
        " response",
    )
    assert_true(
        elapsed_us < _MUST_TERMINATE_WITHIN_US,
        arm
        + ": authored request_timeout_us="
        + String(_AUTHORED_BUDGET_US)
        + "us, but the request ran "
        + String(elapsed_us)
        + "us (> "
        + String(_MUST_TERMINATE_WITHIN_US)
        + "us). The authored budget did NOT reach this arm's drive loop — it"
        " fell back to the transport default.",
    )
    assert_true(
        elapsed_us >= _MUST_HAVE_WAITED_AT_LEAST_US,
        arm
        + ": the request terminated after only "
        + String(elapsed_us)
        + "us, well inside its "
        + String(_AUTHORED_BUDGET_US)
        + "us budget. That is a fail-fast error, NOT a bound wait — this"
        " assertion would otherwise pass without the budget binding anything.",
    )
    print(
        "    [OK] "
        + arm
        + " — terminated at "
        + String(elapsed_us)
        + "us against a "
        + String(_AUTHORED_BUDGET_US)
        + "us authored budget"
    )


# =============================================================================
# ARM 1 — POOLED h2, the gRPC send. The reported defect.
# =============================================================================


def test_pooled_h2_grpc_send_is_bound_by_the_authored_budget() raises:
    """THE FALSIFIER. `HttpClient.send_grpc_pooled` over https+ALPN-h2 — the
    arm `GrpcClient.server_stream` -> `_send_server_stream_bounded_goaway_retry`
    funnels the GCS `ReadObject` through — against a peer that completes the h2
    handshake and then never answers.

    RED BEFORE: `_drive_one_h2_streaming_on_pool` carried no budget at all; its
    `drive_request_on_pooled_conn` call forwarded only `max_iterations`, so the
    drive took `_H2_DRIVE_DEFAULT_WALL_US` and this request ran ~120s against a
    2s authored budget.

    GREEN AFTER: the config's `request_timeout_us` reaches
    `drive_h2_streams_to_completion` as `max_wall_us` (via `h2_drive_wall_us`)
    and the drive raises `HttpError[TIMEOUT]` at the budget.
    """
    print("  test_pooled_h2_grpc_send_is_bound_by_the_authored_budget...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= 0, "socketpair(2) should succeed")
    var client_fd = fds[0]
    var server_fd = fds[1]
    _set_nonblocking(client_fd)

    # The peer completes the h2 handshake, then goes silent forever.
    var settings = _h2_settings_only()
    _ = _send_all(server_fd, settings)

    var connector = _SilentPeerConnector(
        client_fd, NEGOTIATED_HTTP_2, claim_tls=True,
    )
    var client = HttpClient[_SilentPeerConnector].with_request_timeout_us(
        connector^, _AUTHORED_BUDGET_US,
    )
    var reactor = _make_reactor()

    # An IP-LITERAL authority: `_ip_be_from_host` takes the literal fast path,
    # so nothing in this test reaches getaddrinfo.
    var url = Url.parse(String("https://127.0.0.1:443/pkg.Svc/Method"))
    var hdrs = HeaderMap()
    var payload = List[UInt8]()
    payload.append(UInt8(0))
    var req = build_request_with_body[BytesBody](
        method_post(), url^, hdrs^, BytesBody.from_bytes(payload^),
    )

    var t0 = now_ns()
    var raised = False
    try:
        var resp = client.send_grpc_pooled[_RT, BytesBody](req^, reactor)
        _ = resp^
    except e:
        _ = e
        raised = True
    var elapsed = _elapsed_us(t0)

    _close_fd(server_fd)
    _ = client^
    _ = reactor^
    _assert_bound(String("pooled-h2 gRPC"), raised, elapsed)


# =============================================================================
# ARM 2 — the SAME knob, the h1 STREAMING arm. THE ASYMMETRY GUARD.
# =============================================================================


def test_h1_streaming_send_is_bound_by_the_same_authored_budget() raises:
    """THE ANTI-DRIFT ASSERTION. `HttpClient.send` over plaintext h1 — the arm
    `send_grpc_pooled` itself falls back to for a non-https URL — carrying the
    SAME `request_timeout_us` and judged by the SAME `_assert_bound` window.

    ⛔ THIS IS THE POINT OF THE FILE. The defect was never "one path is slow";
    it was that ONE authored number silently meant a different wall per
    protocol, with no assertion anywhere that could notice. Two arms, one knob,
    one verdict function: a future arm that forgets to forward the budget reds
    HERE, naming itself, instead of being found in production by a peer that
    goes quiet.

    RED BEFORE: `_run_one_request_streaming` built its own `OutboundDriver` and
    never called `set_request_timeout_us`, so this ran to
    `_HEAD_DRIVE_DEFAULT_TIMEOUT_US` (600s) — it does not terminate inside any
    reasonable test timeout at all.
    """
    print("  test_h1_streaming_send_is_bound_by_the_same_authored_budget...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= 0, "socketpair(2) should succeed")
    var client_fd = fds[0]
    var server_fd = fds[1]
    _set_nonblocking(client_fd)

    # h1 has no handshake: the peer simply never sends a response head.
    var connector = _SilentPeerConnector(
        client_fd, NEGOTIATED_HTTP_1_1, claim_tls=False,
    )
    var client = HttpClient[_SilentPeerConnector].with_request_timeout_us(
        connector^, _AUTHORED_BUDGET_US,
    )
    var reactor = _make_reactor()

    var url = Url.parse(String("http://127.0.0.1:80/anything"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var t0 = now_ns()
    var raised = False
    try:
        var resp = client.send[_RT, EmptyBody](req^, reactor)
        _ = resp^
    except e:
        _ = e
        raised = True
    var elapsed = _elapsed_us(t0)

    _close_fd(server_fd)
    _ = client^
    _ = reactor^
    _assert_bound(String("h1-streaming"), raised, elapsed)


def main() raises:
    print("test_request_timeout_binds_on_h2_and_h1")
    test_pooled_h2_grpc_send_is_bound_by_the_authored_budget()
    test_h1_streaming_send_is_bound_by_the_same_authored_budget()
    print("ALL PASS")

# =============================================================================
# test_firestore_send_honours_its_request_deadline.mojo — the falsifier for the
#   PER-REQUEST DRIVE-LOOP DEADLINE a caller authors on the `HttpClient` a
#   `FirestoreClient` sends through, on both of its kinds of request.
# =============================================================================
#
# ⛔ WHAT IT IS ABOUT, AND IT HAPPENED TWICE. A Cloud Run service that runs a
# reconcile sweep over Firestore at boot crash-looped, was "fixed", and
# crash-looped again on a later revision with the SAME signature and with both
# halves of that fix present and correct:
#
#     service: Firestore -> FULL service serving (...)
#     service: boot reconcile sweep BEGIN (...)
#     metadata-token: OK elapsed_ms=1 expires_in_s=1799        <- LAST LINE
#     (nothing. 18 x 10s on /healthz, ERROR_TIMEOUT. Killed at 180s. Repeat.)
#
# That token is the Firestore client's bearer, and the sweep's first scan is the
# first outbound call it makes. ⇒ the instance died INSIDE ONE FIRESTORE REQUEST,
# every time, and logged nothing, because the drive loop never returned to
# print anything.
#
# ⭐ AND THE SWEEP'S OWN BUDGET STRUCTURALLY COULD NOT SEE IT. A per-pass wall
# budget is checked BETWEEN UNITS, inside the loops over rows. The queries that
# FEED those loops sit OUTSIDE every loop. A wall budget on the rows cannot
# bound the query that fetches the rows — so the ONLY bound those scans will
# ever have is the one this file asserts.
#
# ⭐⭐ AND `with_defaults` IS NOT "NO OPINION". On a Cloud Run SERVICE it
# resolves to the containing REQUEST's ceiling — `CLOUD_RUN_REQUEST_CEILING_US`
# (300s) less `OUTBOUND_CEILING_RESERVE_US` (5s) = 295s
# (`komira_http_client/outbound_budget.mojo`). That is the right ceiling for a
# request handler and the WRONG one for a serve loop doing background work
# BETWEEN polls: 295s is 1.64x the startup probe's ENTIRE 180s. Off a deployed
# platform it is `OUTBOUND_BUDGET_DEFAULT_US` (600s). Either way it is longer
# than the probe the caller has to answer.
#
# ── WHAT THIS FILE ASSERTS: BEHAVIOUR, NOT PLUMBING ──────────────────────────
# A field-read-back is what let an h2/h1 asymmetry land (see
# `komira_http_client/tests/test_request_timeout_binds_on_h2_and_h1.mojo`, whose
# silent-peer fixture this file reuses deliberately rather than re-inventing):
# a parameter can reach a config and still bound nothing. Both arms here drive a
# REAL socket against a peer that accepts the connection and then goes SILENT,
# through `FirestoreClient`'s own operations (a read, BatchGetDocuments, and a
# write, Commit), and assert on the WALL CLOCK.
#
# The caller authors the deadline on the `HttpClient` it builds the client
# with (`HttpClient.with_request_timeout_us`); the generated client applies no
# ceiling of its own, so the one it is given must bind every method.
#
# MUTATION PROBE: pass `0` for `request_timeout_us` (which IS `with_defaults` —
# `HttpClient.with_request_timeout_us` documents the equivalence) and both arms
# stop terminating. The file cannot be satisfied by a client that merely
# ACCEPTS a budget.
#
# HERMETIC: `socketpair(2)` only — no listen, no connect, no DNS, no
# credentials, no Firestore. The peer is this process.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.testing import assert_true

from komira_clock import now_ns

from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.tcp_stream import TcpStream
from komira_async.reactor.reactor import Reactor

from komira_http_client.client import HttpClient
from komira_http_core.transport.io_stream import (
    Connector,
    NEGOTIATED_HTTP_1_1,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.kernel_tcp import TcpIoStream

from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore.firestore_endpoint import FirestoreEndpoint
from komira_gcp_firestore.firestore_value import FsValue


# socketpair(2) constants (Linux + Darwin agree on these values).
comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)

# ★ THE AUTHORED BUDGET UNDER TEST. Small enough that the default it must
# displace (600s off a deployed platform, 295s on Cloud Run) is 300x / 147x
# away — no amount of scheduling noise can confuse "the budget bound it" with
# "a default did".
comptime _AUTHORED_BUDGET_US: Int = 2_000_000  # 2s

# The window a bound request must terminate inside. 30s is 15x the authored
# budget (so a loaded box cannot red this) and 9.8x BELOW the nearest default it
# displaces (so a run that fell back to a default cannot pass).
comptime _MUST_TERMINATE_WITHIN_US: Int = 30_000_000  # 30s

# ⛔ AND A FLOOR, WHICH IS THE HALF A TIMEOUT TEST USUALLY FORGETS. Terminating
# INSTANTLY is not evidence the budget bound anything — it is what a connector
# bug, a scheme refusal or an immediate EOF looks like, and every one of those
# would make this file green while proving nothing. A bound drive must have
# actually WAITED most of its budget.
comptime _MUST_HAVE_WAITED_AT_LEAST_US: Int = 1_000_000  # 1s


def _socketpair() -> SIMD[DType.int32, 2]:
    """libc socketpair(2): connected AF_UNIX SOCK_STREAM pair, (a_fd, b_fd).
    SAFETY: stack-local SIMD pair; libc writes 2 int32 into it; never escapes —
    the UnsafePointer is confined to this FFI thunk per the encapsulation
    rule."""
    var fds = SIMD[DType.int32, 2](-1, -1)
    var rc = external_call["socketpair", Int32](
        _AF_UNIX,
        _SOCK_STREAM,
        Int32(0),
        UnsafePointer(to=fds).bitcast[UInt8](),
    )
    if rc < 0:
        return SIMD[DType.int32, 2](-1, -1)
    return fds


def _set_nonblocking(fd: Int32):
    """fcntl(fd, F_SETFL, O_NONBLOCK). F_GETFL=3, F_SETFL=4, O_NONBLOCK=0x4 —
    Linux and Darwin agree. The client end must be non-blocking so `try_read`
    returns Pending: that is the branch that parks, and parking is the state the
    wall-clock bound exists to terminate."""
    var flags = external_call["fcntl", Int32](fd, Int32(3), Int32(0))
    _ = external_call["fcntl", Int32](fd, Int32(4), flags | Int32(0x4))


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


struct _SilentPeerConnector(Connector, Movable, Deinitable):
    """Hands out ONE `TcpIoStream` over a caller-supplied, already-connected
    socketpair fd, reporting HTTP/1.1 and plaintext.

    ⚠ A `ScriptedStream` CANNOT STAND IN HERE: its `fd()` is -1, so
    `park_on_pending` early-returns and the drive loop never parks. A
    never-parking loop burns its iteration cap in milliseconds and can never
    exercise a WALL-CLOCK bound, which is the only thing this file is about. A
    real kernel fd whose peer is silent is the one substrate on which "the drive
    waited" and "the drive gave up at N" are distinguishable. (Same reasoning,
    same fixture shape, as `test_request_timeout_binds_on_h2_and_h1.mojo`.)"""

    comptime Stream = TcpIoStream

    var _fd: Int32
    var _connects: Int

    def __init__(out self, fd: Int32):
        self._fd = fd
        self._connects = 0

    def connect[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], ip_be: UInt32, port: UInt16
    ) raises -> TcpIoStream:
        _ = reactor
        _ = ip_be
        _ = port
        self._connects = self._connects + 1
        if self._connects > 1:
            # A second dial would mean this measured a RE-dial, not the drive it
            # armed. Refuse rather than hand out a closed fd.
            raise Error(
                "_SilentPeerConnector: dial #"
                + String(self._connects)
                + " — this fixture arms exactly ONE connection"
            )
        return TcpIoStream(TcpStream(self._fd), NEGOTIATED_HTTP_1_1)

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^


def _elapsed_us(start_ns: UInt64) -> Int:
    return Int((now_ns() - start_ns) // UInt64(1000))


def _assert_bound(arm: String, raised: Bool, elapsed_us: Int) raises:
    """The shared verdict BOTH arms are held to — ONE window, so the two send
    primitives cannot drift apart by being asserted differently. That drift is
    exactly what happened one layer down (h2 vs h1), and it is why there is one
    verdict function rather than two copies."""
    assert_true(
        raised,
        arm
        + ": a silent peer must make the Firestore send TERMINATE, not return a"
        " response",
    )
    assert_true(
        elapsed_us < _MUST_TERMINATE_WITHIN_US,
        arm
        + ": authored request_timeout_us="
        + String(_AUTHORED_BUDGET_US)
        + "us, but the send ran "
        + String(elapsed_us)
        + "us (> "
        + String(_MUST_TERMINATE_WITHIN_US)
        + "us). The authored budget did NOT reach this primitive's drive loop —"
        " it fell back to `with_defaults`, i.e. 295s inside Cloud Run and 600s"
        " off it. That is the boot-sweep wedge, reproduced.",
    )
    assert_true(
        elapsed_us >= _MUST_HAVE_WAITED_AT_LEAST_US,
        arm
        + ": the send terminated after only "
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


def _client(client_fd: Int32) raises -> FirestoreClient[_SilentPeerConnector]:
    """A client over the silent peer, its deadline authored on the HttpClient,
    pointed at a plaintext IP-literal endpoint (nothing reaches getaddrinfo)."""
    var c = FirestoreClient[_SilentPeerConnector](
        HttpClient[_SilentPeerConnector].with_request_timeout_us(
            _SilentPeerConnector(client_fd), _AUTHORED_BUDGET_US
        ),
        String("p"),
        String("d"),
        String("t"),
    )
    c.set_endpoint(FirestoreEndpoint(String("127.0.0.1"), UInt16(8080), True))
    return c^


def test_a_read_is_bound_by_its_authored_deadline() raises:
    """ARM 1 — a read (BatchGetDocuments): the one a sweep's scans reach,
    which no per-pass budget can observe."""
    print("  test_a_read_is_bound_by_its_authored_deadline...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= 0, "socketpair(2) should succeed")
    var client_fd = fds[0]
    var server_fd = fds[1]
    _set_nonblocking(client_fd)
    # h1 has no handshake: the peer simply never sends a response head.
    var client = _client(client_fd)

    var t0 = now_ns()
    var raised = False
    try:
        _ = client.get_document(String("c"), String("d"))
    except e:
        _ = e
        raised = True
    var elapsed = _elapsed_us(t0)
    _close_fd(server_fd)
    _assert_bound(String("get_document"), raised, elapsed)


def test_a_write_is_bound_by_the_same_authored_deadline() raises:
    """ARM 2 — a write (Commit), THE ANTI-DRIFT ASSERTION. Every
    version-checked write is a commit, so a fix that bounded only the read
    half would leave every WRITE the sweep performs unbounded. One knob, two
    kinds of request, ONE verdict function."""
    print("  test_a_write_is_bound_by_the_same_authored_deadline...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= 0, "socketpair(2) should succeed")
    var client_fd = fds[0]
    var server_fd = fds[1]
    _set_nonblocking(client_fd)
    var client = _client(client_fd)

    var t0 = now_ns()
    var raised = False
    try:
        _ = client.create_if_absent(
            String("c"), String("d"), FsValue.map_of(List[String](), List[FsValue]())
        )
    except e:
        _ = e
        raised = True
    var elapsed = _elapsed_us(t0)
    _close_fd(server_fd)
    _assert_bound(String("create_if_absent"), raised, elapsed)


def main() raises:
    print("test_firestore_send_honours_its_request_deadline")
    test_a_read_is_bound_by_its_authored_deadline()
    test_a_write_is_bound_by_the_same_authored_deadline()
    print("test_firestore_send_honours_its_request_deadline: ALL PASS")

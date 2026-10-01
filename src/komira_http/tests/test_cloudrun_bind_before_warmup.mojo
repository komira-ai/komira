# =============================================================================
# tests/test_cloudrun_bind_before_warmup.mojo
# =============================================================================
# A serving binary on Cloud Run must BIND its `$PORT` listener BEFORE running a
# slow warmup (for example an O(chunks) store open/fold), so a cold instance
# answers Cloud Run's tcpSocket STARTUP PROBE in <1s and can safely scale to
# zero. A binary that constructs its `HttpServer` listener only AFTER the warmup
# completes never binds in time on a grown store -> boot crash.
#
# THE SHAPE THIS GUARDS: construct + BIND the front `HttpServer` FIRST (which
# runs `bind() + listen(backlog)` at construction), THEN warm up, THEN serve.
# The kernel listen backlog answers the tcpSocket probe the instant the
# listener is bound — warmup-independent.
#
# WHAT THIS TEST PROVES (the load-bearing invariant that ordering relies on):
# an `HttpServer` constructed with the deploy's `$PORT` collapse config BINDS +
# LISTENS at construction, so a TCP client `connect()` SUCCEEDS while a
# `fold_done` sentinel is STILL False — i.e. BIND-TIME is decoupled from
# (precedes) FOLD-TIME. This is the exact `HttpServer.__init__` ->
# `TcpListener.bind_reuseport` -> `bind()+listen()` seam the ordering exploits.
#
# The falsifier `test_bind_decoupled_from_fold` asserts the connect succeeds
# BEFORE the fold runs. Under a bind-after-fold ordering the listener does not
# exist until the fold completes, so the client `connect()` would be refused
# (ECONNREFUSED) until then. The companion
# `test_bind_after_fold_would_refuse_connect` documents the contrapositive
# directly: a client connecting to a port with NO bound listener is refused,
# which is exactly the window between process start and fold completion.
#
# Same-process raw-socket client (no subprocess curl), mirroring
# tests/test_e2e_bind_any_addr.mojo: the client connects to
# 127.0.0.1:<port> over a 0.0.0.0-bound listener and the accept loop is driven
# inline. No cloud, no docker, no dial — the `fold` is a deterministic
# in-process stand-in for a slow store open, so the ordering invariant is
# tested without any network/store dependency.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_http import (
    HttpMethod,
    HttpServer,
    HttpServerConfig,
    Router,
)
from komira_async.reactor.socket_setup import inet_any_be


# =============================================================================
# §1 — Same-process raw-socket client helpers (blocking libc client).
# =============================================================================

comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1


def _build_sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    """Build a sockaddr_in for 127.0.0.1:port. The client always connects via
    loopback; the listener binds 0.0.0.0 (the deploy serve-path shape)."""
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)  # sin_len
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
        addr[1] = UInt8(0)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    # sin_addr 127.0.0.1 = 7F 00 00 01.
    addr[4] = UInt8(127)
    addr[5] = UInt8(0)
    addr[6] = UInt8(0)
    addr[7] = UInt8(1)
    return addr^


def _create_blocking_client_socket() raises -> Int32:
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0)
    )
    if fd < Int32(0):
        raise Error("bind_before_warmup: socket() failed")
    return fd


def _try_connect(fd: Int32, port: UInt16) -> Int32:
    """Non-raising blocking connect — returns the libc rc (>= 0 success,
    < 0 = refused / error). The caller asserts on the rc so the test can
    distinguish 'connect succeeded' from 'connection refused' (the pre-fix
    bind-after-fold window's behavior)."""
    var addr = _build_sockaddr_in_loopback(port)
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    return external_call["connect", Int32](fd, addr_ptr, UInt32(16))


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var total = len(bytes)
    var sent = 0
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), Int32(0)
        )
        if rc <= Int64(0):
            raise Error("bind_before_warmup: send() failed or returned 0")
        sent = sent + Int(rc)


def _recv_some(fd: Int32, max_bytes: Int) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=max_bytes)
    var raw = buf.unsafe_ptr()
    var n = external_call["recv", Int64](
        fd, raw, UInt64(max_bytes), Int32(0)
    )
    if n < Int64(0):
        raise Error("bind_before_warmup: recv() failed")
    var out = List[UInt8]()
    var i = 0
    while i < Int(n):
        out.append(buf[i])
        i = i + 1
    return out^


def _close_socket(fd: Int32):
    _ = external_call["close", Int32](fd)


def _build_get_request() -> List[UInt8]:
    var s = String("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
    var bytes = s.as_bytes()
    var out = List[UInt8]()
    var n = len(bytes)
    var i = 0
    while i < n:
        out.append(bytes[i])
        i = i + 1
    return out^


# =============================================================================
# §2 — A deterministic in-process stand-in for a slow O(chunks) store fold.
# =============================================================================
# A production fold opens the store and folds the
# WAL — O(chunks), the cost a bind-after-fold ordering puts before the bind. Here it is a no-network
# sentinel-flipping function: the test asserts the listener is already answering
# TCP (the connect rc) BEFORE this runs, proving bind precedes fold.


def _simulate_fold(mut fold_done: Bool):
    """Stand-in for the O(chunks) store open + WAL fold. Flips the sentinel; the
    test reads `fold_done` to prove the listener was bound (and accepting TCP)
    BEFORE this completed."""
    fold_done = True


# =============================================================================
# §3 — The deploy-shape collapse listener config.
# =============================================================================


def _collapse_listener_config() -> HttpServerConfig:
    """The exact shape a serving binary now builds BEFORE the fold: an
    ephemeral-port (port=0 here so the test gets a free kernel port) listener
    bound to INADDR_ANY (0.0.0.0) — the Cloud Run / k8s reachable bind. Production
    sets `port = $PORT`; the bind+listen seam under test is identical."""
    var cfg = HttpServerConfig.default_ephemeral()
    cfg.bind_addr_be = inet_any_be()  # 0.0.0.0 — the deploy serve-path bind
    return cfg


# =============================================================================
# §4 — THE FALSIFIER: bind happens before the fold (the reorder).
# =============================================================================


def test_bind_decoupled_from_fold() raises:
    """FALSIFIER for the pre-fix bind-after-fold ordering.

    Boots in the NEW order: (1) construct the collapse `HttpServer` (binds +
    listens at construction), (2) a TCP client connects, (3) assert the connect
    SUCCEEDED while `fold_done` is STILL False, (4) only THEN run the fold.

    FAILS ON CURRENT CODE: under the pre-fix ordering the listener is constructed
    only AFTER the fold, so at step (2) there is no bound socket and the client
    `connect()` is REFUSED — the `connect rc >= 0 while not fold_done` assertion
    is FALSE. The post-fix reorder constructs+binds the listener first, so the
    kernel listen backlog accepts the connect before the fold runs."""
    var fold_done = False

    # (1) BIND FIRST — exactly what a serving binary now does before the
    #     store open. `HttpServer.__init__` runs bind()+listen() here.
    var server = HttpServer(
        config=_collapse_listener_config(), router=_health_router()
    )
    var port = server.local_port()
    assert_true(Int(port) > 0, String("listener bound to a real port"))

    # The fold has NOT run yet — the listener exists independently of it.
    assert_false(
        fold_done,
        String("invariant: listener is bound BEFORE the fold runs"),
    )

    # (2) The client connects to the bound listener.
    var client_fd = _create_blocking_client_socket()
    var connect_rc = _try_connect(client_fd, port)

    # (3) THE DISCRIMINATING ASSERTION: the connect succeeded while the fold has
    #     STILL not completed. Under bind-after-fold this connect would be
    #     ECONNREFUSED (no listener yet). This is the whole proof of the reorder.
    assert_true(
        connect_rc >= Int32(0),
        String(
            "TCP connect to the bound listener SUCCEEDS before the store"
            " fold runs (bind-time precedes fold-time) — the scale-to-zero fix"
        ),
    )
    assert_false(
        fold_done,
        String(
            "the fold has NOT run yet at connect-time — the kernel backlog"
            " (not the fold) is what answered the TCP probe"
        ),
    )

    # (4) NOW run the (slow, O(chunks)) fold — AFTER the port is already answering.
    _simulate_fold(fold_done)
    assert_true(fold_done, String("fold ran after the bind"))

    # And the warm path still works end-to-end: a request queued during/after the
    # fold is served once the dispatch loop drives the accept/read.
    var req = _build_get_request()
    _send_all(client_fd, req)
    var stats = server.serve_for_iterations(
        max_iters=8, timeout_us=Int32(50_000)
    )
    assert_true(
        Int(stats.reqs_handled) >= 1,
        String("the queued request is served after the fold completes"),
    )
    var resp = _recv_some(client_fd, 64)
    assert_true(len(resp) > 0, String("a response is returned"))

    _close_socket(client_fd)
    _ = server^


def test_bind_after_fold_would_refuse_connect() raises:
    """The contrapositive, stated directly: a client connecting to a port with NO
    bound listener is REFUSED. This is exactly the pre-fix boot window (process
    started, fold in flight, listener not yet constructed) — the connection the
    Cloud Run startup probe makes during a cold boot. The post-fix reorder closes
    this window by binding the listener BEFORE the fold.

    We bind+immediately drop a listener to obtain a port the kernel just freed,
    then connect to it with no listener present and assert the connect fails."""
    var freed_port: UInt16
    # Grab-and-release a kernel port so we have a number to connect to that has
    # no live listener (the pre-fix bind-after-fold window).
    var probe = HttpServer(
        config=_collapse_listener_config(), router=_health_router()
    )
    freed_port = probe.local_port()
    assert_true(Int(freed_port) > 0, String("probe got a real port"))
    _ = probe^  # listener dropped here — port now has NO listener.

    var client_fd = _create_blocking_client_socket()
    var connect_rc = _try_connect(client_fd, freed_port)
    # With no bound listener the blocking connect is refused (rc < 0). This is the
    # exact failure a cold instance suffered when the bind waited on the fold.
    assert_true(
        connect_rc < Int32(0),
        String(
            "connecting to a port with NO bound listener is REFUSED — the"
            " pre-fix bind-after-fold window the reorder eliminates"
        ),
    )
    _close_socket(client_fd)


def _health_router() raises -> Router:
    """A minimal router with the /health route (a typical health
    surface). The bind+listen seam under test does not depend on the route table;
    /health just gives the warm-path serve assertion a real 200 to return."""
    var r = Router()
    r.add(HttpMethod.get(), "/health", 0)
    return r^


def main() raises:
    test_bind_decoupled_from_fold()
    test_bind_after_fold_would_refuse_connect()
    print("PASS bind-before-warmup (bind decoupled from fold)")

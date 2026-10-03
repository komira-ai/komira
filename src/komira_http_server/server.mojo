# =============================================================================
# src/komira_http_server/server.mojo — public HttpServer surface
# =============================================================================
#
# The public HTTP server: ties the L0 transport
# (accept loop / connection state machine / reactor) to L4 routing
# (Router). This version is single-threaded; a multi-pthread SO_REUSEPORT
# variant is a separate concern.
#
# Single-threaded design:
#   * Functional bring-up test only needs ONE pthread + ONE listener +
#     ONE accept loop. Multi-pthread parity is a perf concern, not a
#     correctness concern.
#   * A macOS listener-fd born-blocking issue with several pthreads
#     accepting on one port is sidestepped by single-threaded operation;
#     multi-pthread SO_REUSEPORT testing belongs to that variant.
#   * The reactor + accept_loop primitives in transport/ are MULTI-pthread
#     ready — `HttpServerMultiWorker` (a follow-on shape) just spawns N
#     of these in pthreads. Not adding parallel API; the single-pthread
#     shape composes into multi-pthread via the same primitives.
# =============================================================================

from std.collections.dict import Dict
from std.sys.info import CompilationTarget

from komira_async.reactor.completion_queue import (
    Completion,
    INTEREST_READ,
    INTEREST_WRITE,
)
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.reactor.socket_setup import inet_any_be, inet_loopback_be
from komira_async.runtime.tcp_stream import TcpListener
from komira_async.runtime.runtime_trait import Runtime
from komira_async.ops.waker_sink import NoopSink
from komira_core.collections.slab import Slab

from komira_http_core.codec import (
    HttpMethod,
    HttpRequest,
    HttpResponse,
    status_text,
)
from komira_http_core.codec.h1.limits import (
    DEFAULT_MAX_BODY_BYTES,
    DEFAULT_MAX_HEADERS,
    DEFAULT_MAX_HEADER_BYTES,
    DEFAULT_MAX_REQUEST_LINE_BYTES,
    DEFAULT_MAX_TOTAL_HEADER_BYTES,
    ParseLimits,
)
from komira_http_core.codec.h2 import H2ConnectionState
from komira_http_server.middleware.chain import MiddlewareChain
from komira_http_server.routing import Router
from komira_http_core.tls.conn import (
    CONN_STATE_CLOSED as TLS_CONN_STATE_CLOSED,
    TlsStream,
)
from komira_http_core.tls.handshake_state import (
    CONN_STATE_TLS_HANDSHAKE_IN,
    CONN_STATE_TLS_HANDSHAKE_OUT,
    is_tls_handshake_state,
)
from komira_http_core.tls.s2n_shim import (
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
)
from komira_http_server.accept_loop import (
    accept_one_and_register,
    accept_one_and_register_tls,
    close_and_remove,
    drive_tls_handshake,
    resume_pending_write,
    serve_read_round,
    serve_read_round_chained,
    serve_read_round_tls,
)
from komira_http_server.connection import (
    CONN_STATE_H2_ACTIVE,
    CONN_STATE_H2_PREFACE_WAIT,
    CONN_STATE_READING,
    CONN_STATE_WAITING_FOR_WRITABLE,
    ConnEntry,
    REQ_BUF_BYTES,
    RESP_BUF_CAP,
    is_h2_state,
)
from komira_http_server.middleware.middleware import Middleware
from komira_http_server.dispatch import (
    CtxRequestDispatcher,
    ErasedDispatcher,
    RequestDispatcher,
    SuspendableDispatcher,
    serve_read_round_dispatch,
    serve_read_round_dispatch_chained,
    serve_read_round_erased,
    serve_read_round_suspendable,
    write_delivered_to_conn,
)

from komira_async.runtime.shared_erasure import ErasedHandlerDriver
from komira_async.runtime.suspendable_handler import (
    HANDLER_OP_ID_BIAS,
    SuspendableHandlerDriver,
)
from komira_http_server.serve_h2 import serve_read_round_h2
from komira_http_core.transport.grpc_emit import (
    GrpcDispatch,
    GrpcStreamDispatch,
    NoopGrpcDispatch,
)


# =============================================================================
# §1 — Server config.
# =============================================================================


@fieldwise_init
struct HttpServerStats(Copyable, Movable, Deinitable):
    """Cumulative request + byte counters from a `serve_for_iterations`
    invocation. Used by tests to assert progress."""
    var reqs_handled: Int64
    var bytes_sent: Int64


@fieldwise_init
struct HttpServerConfig(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Server config.

    Fields:
      port    — listen port; 0 == ephemeral (kernel picks).
      backlog — listen() backlog. 4096.

    Fields (bind address):
      bind_addr_be — IPv4 bind address in network byte order. Defaults
                     to `inet_loopback_be()` (127.0.0.1) so all existing
                     test/bench behavior is preserved. A container/k8s
                     deployment must set this to `inet_any_be()` (0.0.0.0)
                     so the listener is reachable from outside the pod's
                     own netns (readiness probe + Service/NodePort).

    Fields (parser hardening — defaults match
    `ParseLimits.defaults()`):
      max_headers              — max # of header lines per request.
      max_header_bytes         — max bytes per header line.
      max_total_header_bytes   — max aggregate header section size.
      max_body_bytes           — max body bytes (Content-Length cap +
                                  chunked decoder accumulator cap).
      max_request_line_bytes   — max request-line bytes; overflow → 414.
      enable_expect_continue   — accept Expect: 100-continue.
                                  When False, all Expect headers are
                                  rejected with 417.

    Fields (logging):
      trace_project — the cloud project id that fault and error-response log
                      lines on the dispatch path qualify their trace with
                      (`projects/<id>/traces/<trace>`). Empty (the default)
                      omits that field; the plain `trace_id` is still written.
                      The chained path takes it from the chain instead
                      (`MiddlewareChain.with_trace_project`).
    """
    var port: UInt16
    var backlog: Int32
    # IPv4 bind address in network byte order. Default loopback (set in the
    # factories below) preserves existing behavior; servers facing a
    # container network set this to inet_any_be() (0.0.0.0).
    var bind_addr_be: UInt32
    var max_headers: Int
    var max_header_bytes: Int
    var max_total_header_bytes: Int
    var max_body_bytes: Int
    var max_request_line_bytes: Int
    var enable_expect_continue: Bool
    var trace_project: String

    @staticmethod
    def default_ephemeral() -> HttpServerConfig:
        return HttpServerConfig(
            port=UInt16(0),
            backlog=Int32(4096),
            bind_addr_be=inet_loopback_be(),
            max_headers=DEFAULT_MAX_HEADERS,
            max_header_bytes=DEFAULT_MAX_HEADER_BYTES,
            max_total_header_bytes=DEFAULT_MAX_TOTAL_HEADER_BYTES,
            max_body_bytes=DEFAULT_MAX_BODY_BYTES,
            max_request_line_bytes=DEFAULT_MAX_REQUEST_LINE_BYTES,
            enable_expect_continue=True,
            trace_project=String(""),
        )

    @staticmethod
    def with_port(port: UInt16) -> HttpServerConfig:
        var c = HttpServerConfig.default_ephemeral()
        c.port = port
        return c^

    @staticmethod
    def with_port_bind_any(port: UInt16) -> HttpServerConfig:
        """Like `with_port`, but binds the listener on INADDR_ANY (0.0.0.0) so it
        is reachable from OUTSIDE the pod's own container netns. Container / k8s /
        Cloud Run serving paths MUST use this (a 127.0.0.1-bound listener is
        unreachable by a Service / NodePort / Cloud Run startup-probe — the
        loopback default exists only to preserve test/bench behavior). The
        deployment serve path is the one site that opts into the all-interfaces
        bind explicitly."""
        var c = HttpServerConfig.default_ephemeral()
        c.port = port
        c.bind_addr_be = inet_any_be()
        return c^

    def to_parse_limits(self) -> ParseLimits:
        """Materialize a ParseLimits view of the parser-relevant fields.

        The transport layer threads this into `parse_request_head` per
        request. Pure read-only projection.
        """
        return ParseLimits(
            max_headers=self.max_headers,
            max_header_bytes=self.max_header_bytes,
            max_total_header_bytes=self.max_total_header_bytes,
            max_body_bytes=self.max_body_bytes,
            max_request_line_bytes=self.max_request_line_bytes,
        )


# =============================================================================
# §2 — Comptime-selected reactor backend.
# =============================================================================


def _build_reactor() raises -> Reactor[NoopSink]:
    """Build a Reactor[NoopSink] with the platform's native backend."""
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
        )
    else:
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )


# =============================================================================
# §3 — Pre-built canned response (the default dispatch is "always 200
#       hello" through serve_read_round; the real handler invocation
#       runs through Router).
# =============================================================================
# This response is the baseline that lets `serve_read_round` plumb
# bytes end-to-end. The functional e2e test asserts 200 status. Real
# Router/Handler dispatch (request-parse + route-match + handler-invoke +
# response-build) goes through `serve_read_round_dispatch`.


def _build_default_health_response_bytes(
    mut out: Array[UInt8, RESP_BUF_CAP],
) -> Int:
    """Fill `out` with a canned 200 OK response. Returns response length.

    RESP_BUF_CAP-SITE AUDIT: this is the FIXED canned health
    response (~92 bytes). It is NOT the large-handler path — real handler
    responses go through `serve_read_round_dispatch` which serializes its
    own growable `List[UInt8]` and writes via `_write_all_or_buffer` (no
    cap). The `i < RESP_BUF_CAP` guard below only bounds this small static
    string into its fixed `_resp_buf` InlineArray; the canned string is
    a compile-time constant well under 1024 bytes, so no truncation can
    occur. If this canned response ever grows past RESP_BUF_CAP, the
    constant string would need to grow `_resp_buf` too — but that path is
    unrelated to the large dynamic-response flush this module otherwise
    handles via the pending-write List.
    """
    var body = String(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
        "Content-Length: 13\r\nConnection: keep-alive\r\n\r\n"
        "Hello, World!"
    )
    var body_bytes = body.as_bytes()
    var n = len(body_bytes)
    var i = 0
    while i < n and i < RESP_BUF_CAP:
        out[i] = body_bytes[i]
        i = i + 1
    return n


# =============================================================================
# §4 — HttpServer.
# =============================================================================


struct HttpServer[
    G: GrpcDispatch & GrpcStreamDispatch = NoopGrpcDispatch
](
    Movable, Deinitable
):
    """HTTP/1.1 plaintext server. Single-threaded accept loop.

    parameterized over `G: GrpcDispatch`
    (default `NoopGrpcDispatch`). The default keeps ALL existing
    non-gRPC call sites unchanged: `HttpServer(config, router)` /
    `HttpServer(config, router, tls_config)` resolve to
    `HttpServer[NoopGrpcDispatch]`, whose gRPC requests answer
    `grpc-status: 12` (UNIMPLEMENTED) — the server still speaks valid
    gRPC even with no service wired. To serve a real gRPC service
    (e.g. `komira_connect.ConnectService`, which conforms to
    `GrpcDispatch`), use the `(config, router, tls_config, grpc)`
    constructor; the live h2 serve loop then routes gRPC requests to
    `grpc.dispatch_grpc(...)` and emits HEADERS+DATA+grpc-status-trailer.

    Movable but NOT Copyable — owns the listener fd + reactor + the
    per-pthread connection state (conn slab + fd→idx Dict + IO buffers).

    Lifecycle:
      1. `HttpServer(config, router)` — binds listener, builds reactor,
         initializes per-pthread conn state. Does NOT start accepting
         yet; caller queries `local_port()` if port==0 was requested.
      2. `serve_for_iterations(...)` — drives a bounded number of poll
         cycles. State (conn slab, fd→idx, accumulators) persists
         across calls so a test can step the loop in slices.
      3. `__del__` — closes the listener + reactor; outstanding conns
         are RAII-closed by the slab teardown.

    Failure modes:
      - `bind()` raises on bind/listen errors (port in use, etc.).
      - Per-conn errors are isolated to the conn (close + remove).
    """

    var _reactor: Reactor[NoopSink]
    var _listener: TcpListener
    var _router: Router
    var _config: HttpServerConfig
    var _listen_fd: Int32
    # Per-pthread state. Lives on the server so it survives across
    # multiple `serve_for_iterations` calls in a test — dropping it
    # between iterations would close all accepted conn fds.
    var _conns: Slab[ConnEntry]
    var _fd_to_idx: Dict[Int, Int]
    var _io_buf: Array[UInt8, REQ_BUF_BYTES]
    var _resp_buf: Array[UInt8, RESP_BUF_CAP]
    var _resp_len: Int
    var _reqs_handled: Int64
    var _bytes_sent: Int64
    # optional middleware chain. When None, the canned-bytes
    # path runs (serve_read_round). When Some, the chain-integration
    # path runs (serve_read_round_chained) which threads parsed requests
    # through the chain + serializes the response back to bytes.
    var _chain: Optional[MiddlewareChain]
    # Optional TLS config. When Some, the accept
    # loop wraps each accepted fd in a TlsStream and drives the s2n-tls
    # handshake before the HTTP/1.1 parser sees any bytes. When None
    # (the default), the plaintext path runs unchanged.
    #
    # Stored on HttpServer (not on the Copyable HttpServerConfig)
    # because TlsConfig is Movable-not-Copyable: it owns an
    # OwnedPointer-of-handle that would double-free on copy. The slot
    # brief said "HttpServerConfig gains tls_config" but TlsConfig's
    # non-copyability forces this minor variance — the practical UX
    # (one new field on the server-builder) is identical.
    var _tls_config: Optional[TlsConfig]
    # the gRPC dispatch seam. For the default
    # `G = NoopGrpcDispatch` this answers every gRPC request with
    # UNIMPLEMENTED; a gRPC service (ConnectService) is installed via the
    # `(config, router, tls_config, grpc)` constructor.
    var _grpc: Self.G

    def __init__(
        out self: HttpServer[NoopGrpcDispatch],
        config: HttpServerConfig,
        var router: Router,
    ) raises:
        """Construct a plaintext HTTP/1.1 server.

        Resolves to `HttpServer[NoopGrpcDispatch]` — gRPC requests answer
        UNIMPLEMENTED. Use the 4-arg constructor to wire a real gRPC
        service."""
        self._reactor = _build_reactor()
        self._listener = TcpListener.bind_reuseport(
            config.bind_addr_be, config.port, config.backlog,
        )
        self._listen_fd = self._listener.fd()
        self._router = router^
        self._config = config
        # Pre-register the listener for READ (accept-ready) so the
        # reactor surfaces it in poll_completions.
        var _reg = self._reactor.register_long_lived(
            self._listen_fd, INTEREST_READ,
        )
        # Note: _reg is intentionally dropped here. For long-lived
        # registrations on a fd we control until the server drops, the
        # registration's lifetime is bounded by the multiplexer fd's
        # lifetime — the reactor's __del__ closes the multiplexer fd
        # which atomically tears down all registrations. The usual
        # `_ = listen_reg` pattern.
        _ = _reg
        # Per-pthread state.
        self._conns = Slab[ConnEntry]()
        self._fd_to_idx = Dict[Int, Int]()
        self._io_buf = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
        self._resp_buf = Array[UInt8, RESP_BUF_CAP](fill=UInt8(0))
        self._resp_len = _build_default_health_response_bytes(self._resp_buf)
        self._reqs_handled = Int64(0)
        self._bytes_sent = Int64(0)
        self._chain = Optional[MiddlewareChain]()
        self._tls_config = Optional[TlsConfig]()
        self._grpc = NoopGrpcDispatch()

    @staticmethod
    def from_listening_fd(
        config: HttpServerConfig,
        var router: Router,
        listen_fd: Int32,
    ) raises -> HttpServer[NoopGrpcDispatch]:
        """Construct a plaintext HTTP/1.1 server over a PRE-BOUND, externally
        owned shared listening fd — the macOS shared-accept (prefork) path.

        Call as `HttpServer.from_listening_fd(config=..., router=...,
        listen_fd=...)`. Delegates to the `(config, router, listen_fd: Int32)`
        `__init__` overload below (Int32 vs TlsConfig disambiguates it from the
        3-arg TLS constructor). It is byte-identical to the 2-arg `__init__`
        EXCEPT it wraps the supplied `listen_fd` (already
        `socket`+`bind`+`listen`-ed by the prefork master) via
        `TcpListener.from_listening_fd(listen_fd, owns_fd=False)` instead of
        `TcpListener.bind_reuseport(...)`. Each of N workers calls this with the
        SAME shared fd; each registers it for READ on its OWN reactor and
        `try_accept()`s on it, so the kernel's single accept queue load-balances
        new connections across whichever worker is ready (the classic POSIX
        prefork model, which works on macOS where SO_REUSEPORT does NOT
        load-balance).

        The listener does NOT own the fd (`owns_fd=False`) — the master closes
        it exactly once after joining all workers (search_server_main.main()).
        The serve loop (`serve_one_iteration_dispatch[D, RT]`) is fully
        fd-agnostic — it polls `self._reactor`, sees the shared `self._listen_fd`
        become READ-ready, and calls `accept_one_and_register(self._listener,
        ...)` (non-blocking accept) — no assumption that the listener bound its
        own socket.

        A shared listener lets several servers in one process accept from
        one socket.
        """
        return HttpServer[NoopGrpcDispatch](config, router^, listen_fd)

    def __init__(
        out self: HttpServer[NoopGrpcDispatch],
        config: HttpServerConfig,
        var router: Router,
        listen_fd: Int32,
    ) raises:
        """MacOS shared-accept out-init body (see `from_listening_fd`).
        Byte-identical to the 2-arg `__init__` EXCEPT the `_listener` line wraps
        the borrowed shared fd (owns_fd=False) instead of binding a new socket.
        Disambiguated from the 3-arg TLS `__init__` by `listen_fd: Int32` vs
        `tls_config: TlsConfig`."""
        self._reactor = _build_reactor()
        self._listener = TcpListener.from_listening_fd(listen_fd, owns_fd=False)
        self._listen_fd = self._listener.fd()
        self._router = router^
        self._config = config
        # Pre-register the SHARED listener fd for READ (accept-ready) on THIS
        # worker's OWN reactor. Each worker has its own registration on its own
        # kqueue/epoll fd; that registration is owned by this server and torn
        # down by its reactor's __del__ (and deregistered by the borrowed
        # listener's __del__ on drop). Identical to the 2-arg __init__ except
        # the fd was bound by the master, not by this server.
        var _reg = self._reactor.register_long_lived(
            self._listen_fd, INTEREST_READ,
        )
        _ = _reg
        # Per-pthread state (identical to the 2-arg __init__).
        self._conns = Slab[ConnEntry]()
        self._fd_to_idx = Dict[Int, Int]()
        self._io_buf = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
        self._resp_buf = Array[UInt8, RESP_BUF_CAP](fill=UInt8(0))
        self._resp_len = _build_default_health_response_bytes(self._resp_buf)
        self._reqs_handled = Int64(0)
        self._bytes_sent = Int64(0)
        self._chain = Optional[MiddlewareChain]()
        self._tls_config = Optional[TlsConfig]()
        self._grpc = NoopGrpcDispatch()

    def __init__(
        out self: HttpServer[NoopGrpcDispatch],
        config: HttpServerConfig,
        var router: Router,
        var tls_config: TlsConfig,
    ) raises:
        """Construct a TLS-enabled HTTPS/1.1 server.

        The TlsConfig is owned by the server for its entire lifetime
        (each accepted TlsStream holds a non-owning ref into it; per
        the config's stable address inside the server's
        Optional[TlsConfig] satisfies the lifetime contract).

        Accepted conns drive the s2n handshake before the HTTP/1.1
        parser sees any bytes; once the handshake completes the
        conn-level state machine transitions to CONN_STATE_READING and
        the parser runs against decrypted plaintext.

        The accept path sets each
        new fd non-blocking before the TlsStream wraps it.
        """
        self._reactor = _build_reactor()
        self._listener = TcpListener.bind_reuseport(
            config.bind_addr_be, config.port, config.backlog,
        )
        self._listen_fd = self._listener.fd()
        self._router = router^
        self._config = config
        var _reg = self._reactor.register_long_lived(
            self._listen_fd, INTEREST_READ,
        )
        _ = _reg
        self._conns = Slab[ConnEntry]()
        self._fd_to_idx = Dict[Int, Int]()
        self._io_buf = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
        self._resp_buf = Array[UInt8, RESP_BUF_CAP](fill=UInt8(0))
        self._resp_len = _build_default_health_response_bytes(self._resp_buf)
        self._reqs_handled = Int64(0)
        self._bytes_sent = Int64(0)
        self._chain = Optional[MiddlewareChain]()
        self._tls_config = Optional[TlsConfig](tls_config^)
        self._grpc = NoopGrpcDispatch()

    def __init__(
        out self,
        config: HttpServerConfig,
        var router: Router,
        var tls_config: TlsConfig,
        var grpc: Self.G,
    ) raises:
        """Construct a TLS-enabled HTTPS server with a gRPC
        service wired into the h2 serve loop.

        Identical to the 3-arg TLS constructor, but installs `grpc` (a
        `GrpcDispatch` conformer — canonically a
        `komira_connect.ConnectService`) as the live gRPC dispatch seam.
        gRPC requests over the h2/ALPN path are routed to
        `grpc.dispatch_grpc(path, content_type, body)` and answered with a
        HEADERS+DATA+grpc-status-trailer response. The service is owned by
        the server for its entire lifetime; the per-connection serve loop
        borrows it by `mut` ref each round (`serve_read_round_h2[G]`), so
        there is NO lifetime hazard between the registry and the loop — the
        registry outlives every per-connection dispatch by construction.
        """
        self._reactor = _build_reactor()
        self._listener = TcpListener.bind_reuseport(
            config.bind_addr_be, config.port, config.backlog,
        )
        self._listen_fd = self._listener.fd()
        self._router = router^
        self._config = config
        var _reg = self._reactor.register_long_lived(
            self._listen_fd, INTEREST_READ,
        )
        _ = _reg
        self._conns = Slab[ConnEntry]()
        self._fd_to_idx = Dict[Int, Int]()
        self._io_buf = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
        self._resp_buf = Array[UInt8, RESP_BUF_CAP](fill=UInt8(0))
        self._resp_len = _build_default_health_response_bytes(self._resp_buf)
        self._reqs_handled = Int64(0)
        self._bytes_sent = Int64(0)
        self._chain = Optional[MiddlewareChain]()
        self._tls_config = Optional[TlsConfig](tls_config^)
        self._grpc = grpc^

    def install_middleware(mut self, var chain: MiddlewareChain):
        """Install a MiddlewareChain. Once installed, the server's
        serve_one_iteration routes requests through the chain instead
        of the canned-bytes shortcut.

        The chain is owned by the server for the rest of its life.
        Subsequent calls REPLACE the chain (the old one is dropped).
        """
        self._chain = Optional[MiddlewareChain](chain^)

    def has_middleware(self) -> Bool:
        """True iff a MiddlewareChain has been installed."""
        return Bool(self._chain)

    def middleware_chain_ref(
        ref self,
    ) -> ref [self._chain] Optional[MiddlewareChain]:
        """Borrow the optional middleware chain (test diagnostic)."""
        return self._chain

    def local_port(self) raises -> UInt16:
        """Return the kernel-assigned ephemeral port (when port=0 was
        passed). For non-zero ports, returns the configured value."""
        return self._listener.local_port()

    def listen_fd(self) -> Int32:
        """Return the listener fd (test diagnostic)."""
        return self._listen_fd

    def live_conn_count(self) -> Int:
        """Return the number of live (accepted, not-yet-closed) connections in
        the conn slab (diagnostic — an fd-leak / conn-leak shows up here as a
        monotonically growing count)."""
        return self._conns.len()

    def router(ref self) -> ref [self._router] Router:
        """Borrow the router (test diagnostic)."""
        return self._router

    def is_tls_enabled(self) -> Bool:
        """True iff this server was constructed with a TlsConfig (the
        `with_tls` ctor variant). Surfaced for tests + diagnostics."""
        return Bool(self._tls_config)

    def serve_one_iteration(
        mut self,
        timeout_us: Int32,
    ) raises -> Int:
        """Drive ONE poll_completions cycle. Returns the number of events
        processed (accept events + read/write events combined).

        Operates on the server's persistent state (`self._conns`,
        `self._fd_to_idx`, etc.) so multiple invocations compose
        cleanly — the test driver can step the loop in slices without
        losing accepted conns between calls.

        TLS-enabled servers (when self._tls_config is Some) route accept
        and per-conn events through the TLS path: handshake-driver while
        mid-handshake, plaintext-codec via TlsStream.read_app/write_app
        once the handshake completes.
        """
        var completions = self._reactor.poll_completions(timeout_us)
        var n_events = len(completions)
        var i = 0
        while i < n_events:
            var c = completions[i]
            var ev_fd = Int32(c.op_id)
            if ev_fd == self._listen_fd:
                # New conn(s) waiting in the accept queue.
                if self._tls_config:
                    # TLS-aware accept path. Borrow
                    # the TlsConfig non-owning ref from the Optional.
                    ref tls_cfg = self._tls_config.value()
                    try:
                        _ = accept_one_and_register_tls(
                            self._listener,
                            self._reactor,
                            self._conns,
                            self._fd_to_idx,
                            tls_cfg,
                        )
                    except e:
                        _ = e
                else:
                    try:
                        _ = accept_one_and_register(
                            self._listener,
                            self._reactor,
                            self._conns,
                            self._fd_to_idx,
                        )
                    except e:
                        _ = e
                i = i + 1
                continue

            var maybe_idx = self._fd_to_idx.find(Int(ev_fd))
            if not maybe_idx:
                # Stale event for a conn we already dropped. Benign.
                i = i + 1
                continue
            var idx = maybe_idx.value()

            # TLS-aware dispatch.
            # If this conn is mid-handshake, drive one handshake step.
            # If handshake completed this step, fall through to the
            # plaintext-equivalent read round via serve_read_round_tls.
            if self._conns[idx].is_tls():
                if is_tls_handshake_state(self._conns[idx]._state):
                    var hs = drive_tls_handshake(self._conns[idx])
                    var hs_outcome = hs[0]
                    var hs_mask = hs[1]
                    var hs_next_state = hs[2]
                    self._conns[idx]._state = hs_next_state
                    if hs_outcome == TLS_OUTCOME_ERROR:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                        i = i + 1
                        continue
                    # Update reactor interest if needed.
                    if hs_mask != 0 and (
                        hs_mask != self._conns[idx]._interest_set
                    ):
                        try:
                            self._reactor.modify(
                                self._conns[idx]._reg, hs_mask,
                            )
                            self._conns[idx]._interest_set = hs_mask
                        except e:
                            _ = e
                            try:
                                close_and_remove(
                                    self._conns, self._fd_to_idx, idx,
                                )
                            except e2:
                                _ = e2
                            i = i + 1
                            continue
                    # If still mid-handshake (outcome was BLOCKED_*),
                    # return to the event loop and wait.
                    if hs_outcome != TLS_OUTCOME_DONE:
                        i = i + 1
                        continue
                    # handshake just completed.
                    # Read back the ALPN-negotiated protocol and pivot.
                    var alpn_opt = self._conns[idx].tls_stream_ref(
                    ).value().negotiated_protocol()
                    if alpn_opt:
                        if alpn_opt.value() == String("h2"):
                            # ALPN selected h2 → install H2ConnectionState
                            # and transition to CONN_STATE_H2_PREFACE_WAIT.
                            # Subsequent read events drive serve_read_round_h2.
                            self._conns[idx].install_h2_state(
                                H2ConnectionState()
                            )
                            self._conns[idx]._state = (
                                CONN_STATE_H2_PREFACE_WAIT
                            )
                    # "http/1.1" / None → h1 path unchanged (state was
                    # set to CONN_STATE_READING by drive_handshake DONE).

                # h2 dispatch branch.
                if self._conns[idx].is_h2():
                    var keep_alive_h2 = serve_read_round_h2(
                        self._conns[idx],
                        self._router,
                        self._grpc,
                        self._reqs_handled,
                        self._bytes_sent,
                    )
                    if not keep_alive_h2:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                    i = i + 1
                    continue

                # Post-handshake or already-handshaked: TLS read round (h1).
                var keep_alive = serve_read_round_tls(
                    self._conns[idx],
                    self._io_buf,
                    self._resp_buf,
                    self._resp_len,
                    self._config.to_parse_limits(),
                    self._config.enable_expect_continue,
                    self._reqs_handled,
                    self._bytes_sent,
                )
                if not keep_alive:
                    try:
                        close_and_remove(
                            self._conns, self._fd_to_idx, idx,
                        )
                    except e:
                        _ = e
                i = i + 1
                continue

            # Plaintext path — unchanged from the shape.
            if self._conns[idx]._state == CONN_STATE_WAITING_FOR_WRITABLE:
                var drained = resume_pending_write(
                    self._conns[idx], self._bytes_sent,
                )
                if drained:
                    if self._conns[idx]._interest_set != INTEREST_READ:
                        try:
                            self._reactor.modify(
                                self._conns[idx]._reg, INTEREST_READ,
                            )
                            self._conns[idx]._interest_set = INTEREST_READ
                        except e:
                            _ = e
                            try:
                                close_and_remove(
                                    self._conns, self._fd_to_idx, idx,
                                )
                            except e2:
                                _ = e2
                            i = i + 1
                            continue
                    # After draining the pending write, try one more
                    # read round to absorb any pipelined follow-up
                    # requests buffered by the kernel.
                    var keep_alive: Bool
                    if self._chain:
                        ref chain_ref = self._chain.value()
                        keep_alive = serve_read_round_chained(
                            self._conns[idx],
                            self._io_buf,
                            self._config.to_parse_limits(),
                            self._config.enable_expect_continue,
                            chain_ref,
                            self._reqs_handled,
                            self._bytes_sent,
                        )
                    else:
                        keep_alive = serve_read_round(
                            self._conns[idx],
                            self._io_buf,
                            self._resp_buf,
                            self._resp_len,
                            self._config.to_parse_limits(),
                            self._config.enable_expect_continue,
                            self._reqs_handled,
                            self._bytes_sent,
                        )
                    if self._conns[idx]._state == CONN_STATE_WAITING_FOR_WRITABLE:
                        if self._conns[idx]._interest_set != INTEREST_WRITE:
                            try:
                                self._reactor.modify(
                                    self._conns[idx]._reg, INTEREST_WRITE,
                                )
                                self._conns[idx]._interest_set = INTEREST_WRITE
                            except e:
                                _ = e
                                keep_alive = False
                    if not keep_alive:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                else:
                    # Still backed up OR hard error.
                    if self._conns[idx]._pending_len < 0:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                i = i + 1
                continue

            # READING state.
            var keep_alive: Bool
            if self._chain:
                ref chain_ref = self._chain.value()
                keep_alive = serve_read_round_chained(
                    self._conns[idx],
                    self._io_buf,
                    self._config.to_parse_limits(),
                    self._config.enable_expect_continue,
                    chain_ref,
                    self._reqs_handled,
                    self._bytes_sent,
                )
            else:
                keep_alive = serve_read_round(
                    self._conns[idx],
                    self._io_buf,
                    self._resp_buf,
                    self._resp_len,
                    self._config.to_parse_limits(),
                    self._config.enable_expect_continue,
                    self._reqs_handled,
                    self._bytes_sent,
                )
            if self._conns[idx]._state == CONN_STATE_WAITING_FOR_WRITABLE:
                if self._conns[idx]._interest_set != INTEREST_WRITE:
                    try:
                        self._reactor.modify(
                            self._conns[idx]._reg, INTEREST_WRITE,
                        )
                        self._conns[idx]._interest_set = INTEREST_WRITE
                    except e:
                        _ = e
                        keep_alive = False
            if not keep_alive:
                try:
                    close_and_remove(self._conns, self._fd_to_idx, idx)
                except e:
                    _ = e
            i = i + 1

        return n_events

    def serve_for_iterations(
        mut self,
        max_iters: Int,
        timeout_us: Int32,
    ) raises -> HttpServerStats:
        """Drive up to `max_iters` poll cycles. State persists across
        calls; the returned stats are CUMULATIVE counters since server
        construction.

        For test orchestration: the test interleaves client send/recv
        with this method to step the server forward. The per-iteration
        timeout bounds the wall time so a hung client doesn't hang the
        test forever.
        """
        var iter_count = 0
        while iter_count < max_iters:
            _ = self.serve_one_iteration(timeout_us)
            iter_count = iter_count + 1
        return HttpServerStats(
            reqs_handled=self._reqs_handled,
            bytes_sent=self._bytes_sent,
        )

    def serve_one_iteration_dispatch[
        D: RequestDispatcher,
        RT: Runtime,
    ](
        mut self,
        mut dispatcher: D,
        timeout_us: Int32,
    ) raises -> Int:
        """Drive ONE poll cycle, routing parser-success through a
        `RequestDispatcher` conformer (the route→handler leaf the
        canned / chained paths lack).

        This is the runnable-service variant of `serve_one_iteration`: it
        reuses the SAME reactor accept loop, RFC-7230 parser, per-conn state
        machine, and EWOULDBLOCK-buffer machinery, replacing only the canned
        write with `dispatcher.dispatch[RT](reactor, parsed_request)`.

        The dispatcher is passed PER iteration (not owned by the server) so a
        stateful service (e.g. one mutating a DB through the handler) keeps
        the server transport-only.

        the server threads its OWN reactor
        (`self._reactor` — the one it just polled `poll_completions` on) into
        each `serve_read_round_dispatch[D, RT]` call, which forwards it to
        `dispatcher.dispatch[RT](reactor, req)`. So a handler that performs
        async I/O (the heartbeat handler's `[RT]` DB reads) PARKS on the SAME
        reactor that serves HTTP — one event loop, fully unified serving + DB.
        The `[RT]` is supplied by the caller; `RT.Sink` MUST equal the server
        reactor's sink (today `NoopSink`), enforced by the type of
        `self._reactor` at the `serve_read_round_dispatch` call below (a
        mismatched `RT.Sink` is a compile error there). No reactor is stored —
        it is threaded per-call as a `mut` borrow (no wildcard
        field, no borrow held across the poll).

        Plaintext only: TLS / H2 conns (which never appear on a plaintext
        listener) are dropped. The heartbeat listener is plaintext (TLS on
        the internal :8081 endpoint is a follow-on).

        Returns the number of reactor events processed this cycle.
        """
        # the server's reactor is `Reactor[NoopSink]`; the
        # dispatch seam wants `Reactor[RT.Sink]`. We constrain `RT.Sink ==
        # NoopSink` so the two are the SAME type, then `rebind` the field-typed
        # reactor reference to the trait-expected `Reactor[RT.Sink]` at each
        # dispatch call. The constraint makes this a compile-time-proven
        # no-op narrowing (a mismatched `RT.Sink` is a clean comptime error
        # here, not a confusing converter failure deeper in).
        comptime assert (RT.Sink == NoopSink), ("serve_one_iteration_dispatch[D, RT]: RT.Sink must be NoopSink " "(the HttpServer pins Reactor[NoopSink]).")
        var completions = self._reactor.poll_completions(timeout_us)
        var n_events = len(completions)
        var i = 0
        while i < n_events:
            var c = completions[i]
            var ev_fd = Int32(c.op_id)
            if ev_fd == self._listen_fd:
                try:
                    _ = accept_one_and_register(
                        self._listener,
                        self._reactor,
                        self._conns,
                        self._fd_to_idx,
                    )
                except e:
                    _ = e
                i = i + 1
                continue

            var maybe_idx = self._fd_to_idx.find(Int(ev_fd))
            if not maybe_idx:
                i = i + 1
                continue
            var idx = maybe_idx.value()

            # Defensive: a TLS/H2 conn cannot occur on a plaintext listener,
            # but if one ever does, drop it rather than mis-dispatch.
            if self._conns[idx].is_tls() or self._conns[idx].is_h2():
                try:
                    close_and_remove(self._conns, self._fd_to_idx, idx)
                except e:
                    _ = e
                i = i + 1
                continue

            if self._conns[idx]._state == CONN_STATE_WAITING_FOR_WRITABLE:
                var drained = resume_pending_write(
                    self._conns[idx], self._bytes_sent,
                )
                if drained:
                    if self._conns[idx]._interest_set != INTEREST_READ:
                        try:
                            self._reactor.modify(
                                self._conns[idx]._reg, INTEREST_READ,
                            )
                            self._conns[idx]._interest_set = INTEREST_READ
                        except e:
                            _ = e
                            try:
                                close_and_remove(
                                    self._conns, self._fd_to_idx, idx,
                                )
                            except e2:
                                _ = e2
                            i = i + 1
                            continue
                    var keep_alive_w = serve_read_round_dispatch[D, RT](
                        self._conns[idx],
                        rebind[Reactor[RT.Sink]](self._reactor),
                        self._io_buf,
                        self._config.to_parse_limits(),
                        self._config.enable_expect_continue,
                        dispatcher,
                        self._reqs_handled,
                        self._bytes_sent,
                        self._config.trace_project,
                    )
                    if self._conns[idx]._state == (
                        CONN_STATE_WAITING_FOR_WRITABLE
                    ):
                        if self._conns[idx]._interest_set != INTEREST_WRITE:
                            try:
                                self._reactor.modify(
                                    self._conns[idx]._reg, INTEREST_WRITE,
                                )
                                self._conns[idx]._interest_set = INTEREST_WRITE
                            except e:
                                _ = e
                                keep_alive_w = False
                    if not keep_alive_w:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                else:
                    if self._conns[idx]._pending_len < 0:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                i = i + 1
                continue

            # READING state — dispatch.
            var keep_alive = serve_read_round_dispatch[D, RT](
                self._conns[idx],
                rebind[Reactor[RT.Sink]](self._reactor),
                self._io_buf,
                self._config.to_parse_limits(),
                self._config.enable_expect_continue,
                dispatcher,
                self._reqs_handled,
                self._bytes_sent,
                self._config.trace_project,
            )
            if self._conns[idx]._state == CONN_STATE_WAITING_FOR_WRITABLE:
                if self._conns[idx]._interest_set != INTEREST_WRITE:
                    try:
                        self._reactor.modify(
                            self._conns[idx]._reg, INTEREST_WRITE,
                        )
                        self._conns[idx]._interest_set = INTEREST_WRITE
                    except e:
                        _ = e
                        keep_alive = False
            if not keep_alive:
                try:
                    close_and_remove(self._conns, self._fd_to_idx, idx)
                except e:
                    _ = e
            i = i + 1

        return n_events

    def serve_one_iteration_dispatch_chained[
        D: CtxRequestDispatcher,
        M: Middleware,
        RT: Runtime,
    ](
        mut self,
        mut chain: MiddlewareChain,
        mut auth_mw: M,
        mut dispatcher: D,
        timeout_us: Int32,
    ) raises -> Int:
        """Drive ONE poll cycle, routing parser-success through the MIDDLEWARE
        CHAIN and THEN a `CtxRequestDispatcher`.

        This is the middleware-in-path variant of `serve_one_iteration_dispatch`:
        identical reactor accept loop / parser / per-conn state machine /
        EWOULDBLOCK-buffer machinery, but the per-request leaf runs
        `serve_read_round_dispatch_chained[D, M, RT]` — the chain's `before`
        legs (CORS / Tracing / Logging, then `auth_mw` which resolves
        `ctx.authed_user` or short-circuits 401) run BEFORE the dispatcher, and
        a 401 short-circuit means the dispatcher / handler is never reached.

        Backward-compat: this is ADDITIVE. Chain-less callers (JobDispatcher,
        McpHttpDispatcher) keep using `serve_one_iteration_dispatch[D, RT]` and
        are completely untouched. The chain + auth middleware are passed PER
        iteration (not owned by the server) so the caller owns their lifetime.

        the server threads its OWN reactor into the
        chained dispatch, so the dispatcher's handler async I/O parks on the
        SAME reactor that serves HTTP. `RT.Sink` MUST equal the server reactor's
        sink (`NoopSink`) — enforced by the constraint below.

        Plaintext only (TLS / H2 conns are dropped — they never appear on a
        plaintext listener). Returns the number of reactor events processed.
        """
        comptime assert (RT.Sink == NoopSink), ("serve_one_iteration_dispatch_chained[D, M, RT]: RT.Sink must be " "NoopSink (the HttpServer pins Reactor[NoopSink]).")
        var completions = self._reactor.poll_completions(timeout_us)
        var n_events = len(completions)
        var i = 0
        while i < n_events:
            var c = completions[i]
            var ev_fd = Int32(c.op_id)
            if ev_fd == self._listen_fd:
                try:
                    _ = accept_one_and_register(
                        self._listener,
                        self._reactor,
                        self._conns,
                        self._fd_to_idx,
                    )
                except e:
                    _ = e
                i = i + 1
                continue

            var maybe_idx = self._fd_to_idx.find(Int(ev_fd))
            if not maybe_idx:
                i = i + 1
                continue
            var idx = maybe_idx.value()

            if self._conns[idx].is_tls() or self._conns[idx].is_h2():
                try:
                    close_and_remove(self._conns, self._fd_to_idx, idx)
                except e:
                    _ = e
                i = i + 1
                continue

            if self._conns[idx]._state == CONN_STATE_WAITING_FOR_WRITABLE:
                var drained = resume_pending_write(
                    self._conns[idx], self._bytes_sent,
                )
                if drained:
                    if self._conns[idx]._interest_set != INTEREST_READ:
                        try:
                            self._reactor.modify(
                                self._conns[idx]._reg, INTEREST_READ,
                            )
                            self._conns[idx]._interest_set = INTEREST_READ
                        except e:
                            _ = e
                            try:
                                close_and_remove(
                                    self._conns, self._fd_to_idx, idx,
                                )
                            except e2:
                                _ = e2
                            i = i + 1
                            continue
                    var keep_alive_w = serve_read_round_dispatch_chained[
                        D, M, RT
                    ](
                        self._conns[idx],
                        rebind[Reactor[RT.Sink]](self._reactor),
                        self._io_buf,
                        self._config.to_parse_limits(),
                        self._config.enable_expect_continue,
                        chain,
                        auth_mw,
                        dispatcher,
                        self._reqs_handled,
                        self._bytes_sent,
                    )
                    if self._conns[idx]._state == (
                        CONN_STATE_WAITING_FOR_WRITABLE
                    ):
                        if self._conns[idx]._interest_set != INTEREST_WRITE:
                            try:
                                self._reactor.modify(
                                    self._conns[idx]._reg, INTEREST_WRITE,
                                )
                                self._conns[idx]._interest_set = INTEREST_WRITE
                            except e:
                                _ = e
                                keep_alive_w = False
                    if not keep_alive_w:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                else:
                    if self._conns[idx]._pending_len < 0:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                i = i + 1
                continue

            # READING state — chained dispatch (middleware-in-path).
            var keep_alive = serve_read_round_dispatch_chained[D, M, RT](
                self._conns[idx],
                rebind[Reactor[RT.Sink]](self._reactor),
                self._io_buf,
                self._config.to_parse_limits(),
                self._config.enable_expect_continue,
                chain,
                auth_mw,
                dispatcher,
                self._reqs_handled,
                self._bytes_sent,
            )
            if self._conns[idx]._state == CONN_STATE_WAITING_FOR_WRITABLE:
                if self._conns[idx]._interest_set != INTEREST_WRITE:
                    try:
                        self._reactor.modify(
                            self._conns[idx]._reg, INTEREST_WRITE,
                        )
                        self._conns[idx]._interest_set = INTEREST_WRITE
                    except e:
                        _ = e
                        keep_alive = False
            if not keep_alive:
                try:
                    close_and_remove(self._conns, self._fd_to_idx, idx)
                except e:
                    _ = e
            i = i + 1

        return n_events

    def _deliver_suspended_responses[
        SD: SuspendableDispatcher,
    ](
        mut self,
        mut driver: SuspendableHandlerDriver[NoopSink, SD.Handler],
    ) raises:
        """Drain the driver's DELIVERED responses (finished suspendable frames)
        and write each one back to its originating connection (the conn whose fd
        == the frame's request_id). A delivered response may belong to a
        DIFFERENT conn than the one whose event triggered this cycle (a resume
        completes a frame that parked on an EARLIER cycle), which is exactly why
        the frame carries its conn fd as the routing key.

        For each delivered (request_id, response): look the fd up in
        `_fd_to_idx`; if the conn is still live, write the response (EWOULDBLOCK
        buffers + arms EPOLLOUT); a partial write leaves the conn in
        WAITING_FOR_WRITABLE (the normal write path drains it); a hard write
        error or a since-closed conn drops the conn. A response whose conn
        already vanished is discarded (benign — the client went away).

        The handler's response type `SD.Handler.Resp` MUST be `HttpResponse`
        (the seam serializes HTTP) — enforced by the constraint below; the
        `rebind` is the compile-time-proven no-op narrowing of the generic
        `SD.Handler.Resp` to the concrete `HttpResponse` the writer wants."""
        comptime assert (SD.Handler.Resp == HttpResponse), ("serve_one_iteration_dispatch_suspendable: the handler's response " "type (SD.Handler.Resp) must be HttpResponse.")
        var delivered = driver.take_delivered()
        var n = len(delivered)
        var k = 0
        while k < n:
            # Always take index 0 — take_at shifts the tail down, keeping the
            # drain dense across the n iterations.
            var rec = delivered.take_at(0)
            var rid = rec.request_id
            var maybe_idx = self._fd_to_idx.find(Int(rid))
            if maybe_idx:
                var idx = maybe_idx.value()
                # `rec.response` is statically typed `SD.Handler.Resp`, which the
                # constraint above proves is `HttpResponse`. `write_delivered_to_
                # conn[SD.Handler.Resp]` BORROWS it (no copy/move) and serializes
                # it via the proven generic→concrete reinterpret.
                var rw = write_delivered_to_conn[SD.Handler.Resp](
                    self._conns[idx],
                    rec.response,
                    self._reqs_handled,
                    self._bytes_sent,
                )
                if rw == 1:
                    # Partial write — arm EPOLLOUT so the pending tail drains via
                    # the normal WAITING_FOR_WRITABLE path on the next cycle.
                    if self._conns[idx]._interest_set != INTEREST_WRITE:
                        try:
                            self._reactor.modify(
                                self._conns[idx]._reg, INTEREST_WRITE,
                            )
                            self._conns[idx]._interest_set = INTEREST_WRITE
                        except e:
                            _ = e
                            try:
                                close_and_remove(
                                    self._conns, self._fd_to_idx, idx,
                                )
                            except e2:
                                _ = e2
                elif rw < 0:
                    try:
                        close_and_remove(self._conns, self._fd_to_idx, idx)
                    except e:
                        _ = e
            # else: conn vanished before the response could be delivered — `rec`
            # (and its response) is dropped at end-of-iteration; benign.
            _ = rec^
            k = k + 1
        _ = delivered^

    def serve_one_iteration_dispatch_suspendable[
        SD: SuspendableDispatcher,
        RT: Runtime,
    ](
        mut self,
        mut dispatcher: SD,
        mut driver: SuspendableHandlerDriver[NoopSink, SD.Handler],
        timeout_us: Int32,
    ) raises -> Int:
        """Drive ONE poll cycle in the SUSPENDABLE serve loop (RUNTIME-STEP1
        Stage 3). ADDITIVE: this runs BESIDE `serve_one_iteration_dispatch[D,
        RT]`; it does NOT change any existing serve path.

        THE OP_ID DEMUX (the genuinely new piece) — a THIRD bucket beside the
        listener-fd and conn-fd buckets. `Completion.op_id` is a shared Int64
        namespace; the three buckets are checked in this strict order:
          1. `ev_op == self._listen_fd`           -> accept new conn(s).
          2. `op >= HANDLER_OP_ID_BIAS` AND the driver is parked on it
             (`driver.is_parked_op_id(op)`)        -> RESUME the parked handler
                                                       frame (NOT the conn read
                                                       path). The completion is
                                                       the handler's awaited I/O
                                                       (e.g. its PG read fd) — it
                                                       MUST NOT be demuxed to the
                                                       conn that happens to share
                                                       the fd value, which the
                                                       allocation-time op_id bias
                                                       (`Reactor.alloc_op_id`)
                                                       makes structurally
                                                       impossible (a parked op_id
                                                       is >= 2^40; an fd-cookie is
                                                       small).
          3. `self._fd_to_idx.find(op)`            -> a connection READ event:
                                                       run a suspendable read
                                                       round (parse -> make_frame
                                                       -> admit to driver).
        A mis-route in either direction corrupts the handler state machine (a
        conn-read completion stepping a parked frame) or mis-parses PG bytes as
        an HTTP request (a handler-resume completion entering the conn path); the
        bias + the strict ordering make both impossible.

        After processing each completion, the driver's DELIVERED responses
        (frames that finished this cycle — a one-step un-migrated handler, or a
        resumed migrated handler reaching DONE) are written back to their conns
        via `_deliver_suspended_responses`.

        UN-MIGRATED ZERO-CHANGE: with a dispatcher whose `make_frame` wraps every
        route in `SyncToSuspendable` (the Stage-3/4 default for un-converted
        routes), each request finishes in ONE admit step and is delivered the
        same cycle — byte-identical to `serve_one_iteration_dispatch`.

        `RT.Sink` MUST equal `NoopSink` (the HttpServer pins `Reactor[NoopSink]`,
        and the driver is `SuspendableHandlerDriver[NoopSink, ...]`) — enforced
        by the constraint below. Plaintext only (TLS/H2 conns are dropped).
        Returns the number of reactor events processed."""
        comptime assert (RT.Sink == NoopSink), ("serve_one_iteration_dispatch_suspendable[SD, RT]: RT.Sink must be " "NoopSink (the HttpServer pins Reactor[NoopSink]).")
        var completions = self._reactor.poll_completions(timeout_us)
        var n_events = len(completions)
        var i = 0
        while i < n_events:
            var c = completions[i]
            var ev_op = c.op_id

            # BUCKET 1 — listener fd: accept new conn(s).
            if ev_op == Int64(self._listen_fd):
                try:
                    _ = accept_one_and_register(
                        self._listener,
                        self._reactor,
                        self._conns,
                        self._fd_to_idx,
                    )
                except e:
                    _ = e
                i = i + 1
                continue

            # BUCKET 2 — a parked handler frame's awaited op_id (in the biased
            # space). Resume the frame; the conn path is NEVER reached for this
            # completion.
            if driver.is_parked_op_id(ev_op):
                # `driver` is SuspendableHandlerDriver[NoopSink, ...]; its
                # `resume` wants Reactor[NoopSink] — pass the server reactor
                # directly (no rebind; it IS Reactor[NoopSink]).
                driver.resume(ev_op, self._reactor)
                self._deliver_suspended_responses[SD](driver)
                i = i + 1
                continue

            # BUCKET 3 — a connection event (fd-cookie). Below
            # HANDLER_OP_ID_BIAS, so it is unambiguously a conn/listener fd.
            var ev_fd = Int32(ev_op)
            var maybe_idx = self._fd_to_idx.find(Int(ev_fd))
            if not maybe_idx:
                i = i + 1
                continue
            var idx = maybe_idx.value()

            if self._conns[idx].is_tls() or self._conns[idx].is_h2():
                try:
                    close_and_remove(self._conns, self._fd_to_idx, idx)
                except e:
                    _ = e
                i = i + 1
                continue

            # A conn mid pending-write: drain it (a delivered response that
            # partial-wrote on an earlier cycle).
            if self._conns[idx]._state == CONN_STATE_WAITING_FOR_WRITABLE:
                var drained = resume_pending_write(
                    self._conns[idx], self._bytes_sent,
                )
                if drained:
                    if self._conns[idx]._interest_set != INTEREST_READ:
                        try:
                            self._reactor.modify(
                                self._conns[idx]._reg, INTEREST_READ,
                            )
                            self._conns[idx]._interest_set = INTEREST_READ
                        except e:
                            _ = e
                            try:
                                close_and_remove(
                                    self._conns, self._fd_to_idx, idx,
                                )
                            except e2:
                                _ = e2
                else:
                    if self._conns[idx]._pending_len < 0:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                i = i + 1
                continue

            # READING state — suspendable read round: parse -> make_frame ->
            # admit. The request_id is this conn's fd (the response routing key).
            var keep_alive = serve_read_round_suspendable[SD, RT](
                self._conns[idx],
                rebind[Reactor[RT.Sink]](self._reactor),
                self._io_buf,
                self._config.to_parse_limits(),
                self._config.enable_expect_continue,
                dispatcher,
                rebind[SuspendableHandlerDriver[RT.Sink, SD.Handler]](driver),
                Int64(ev_fd),
                self._reqs_handled,
                self._bytes_sent,
            )
            # Write back any responses delivered this cycle (one-step handlers).
            # A conn whose request PARKED is written nothing now (its response
            # lands on a later resume cycle).
            self._deliver_suspended_responses[SD](driver)
            if not keep_alive:
                try:
                    close_and_remove(self._conns, self._fd_to_idx, idx)
                except e:
                    _ = e
            i = i + 1

        return n_events

    def _deliver_erased_responses[
        ED: ErasedDispatcher,
    ](
        mut self,
        mut driver: ErasedHandlerDriver[NoopSink, ED.Resp],
    ) raises:
        """The TYPE-ERASED counterpart of `_deliver_suspended_responses`: drain the
        erased driver's DELIVERED responses (finished erased frames) and write each
        back to its originating connection (the conn whose fd == the frame's
        request_id). Identical delivery semantics — only the driver type differs
        (`ErasedHandlerDriver[NoopSink, ED.Resp]` instead of
        `SuspendableHandlerDriver[NoopSink, SD.Handler]`). `ED.Resp` MUST be
        `HttpResponse` (the seam serializes HTTP)."""
        comptime assert (ED.Resp == HttpResponse), ("serve_one_iteration_dispatch_erased: the dispatcher's response type " "(ED.Resp) must be HttpResponse.")
        var delivered = driver.take_delivered()
        var n = len(delivered)
        var k = 0
        while k < n:
            var rec = delivered.take_at(0)
            var rid = rec.request_id
            var maybe_idx = self._fd_to_idx.find(Int(rid))
            if maybe_idx:
                var idx = maybe_idx.value()
                var rw = write_delivered_to_conn[ED.Resp](
                    self._conns[idx],
                    rec.response,
                    self._reqs_handled,
                    self._bytes_sent,
                )
                if rw == 1:
                    if self._conns[idx]._interest_set != INTEREST_WRITE:
                        try:
                            self._reactor.modify(
                                self._conns[idx]._reg, INTEREST_WRITE,
                            )
                            self._conns[idx]._interest_set = INTEREST_WRITE
                        except e:
                            _ = e
                            try:
                                close_and_remove(
                                    self._conns, self._fd_to_idx, idx,
                                )
                            except e2:
                                _ = e2
                elif rw < 0:
                    try:
                        close_and_remove(self._conns, self._fd_to_idx, idx)
                    except e:
                        _ = e
            _ = rec^
            k = k + 1
        _ = delivered^

    def serve_one_iteration_dispatch_erased[
        ED: ErasedDispatcher,
        RT: Runtime,
    ](
        mut self,
        mut dispatcher: ED,
        mut driver: ErasedHandlerDriver[NoopSink, ED.Resp],
        timeout_us: Int32,
    ) raises -> Int:
        """Drive ONE poll cycle in the TYPE-ERASED suspendable serve loop
        The scalable counterpart of
        `serve_one_iteration_dispatch_suspendable[SD, RT]`: identical OP_ID DEMUX
        (the three buckets — listener fd, biased parked-frame op_id, conn fd — in
        the SAME strict order), identical delivery, but the driver is
        `ErasedHandlerDriver[NoopSink, ED.Resp]` (NOT monomorphized on a handler
        type) and the read round is `serve_read_round_erased`. The dispatcher's
        `make_erased_frame` route-demuxes each request to its concrete handler and
        erases it into ONE `ErasedFrame` shape; the driver multiplexes N distinct
        handler types through one parked slab — no `KomiraSuspendableHandler` sum,
        no per-route serve-loop arm.

        `RT.Sink` AND `ED.Sink` MUST equal `NoopSink` (the HttpServer pins
        `Reactor[NoopSink]` + the erased driver is `ErasedHandlerDriver[NoopSink,
        ...]`). Plaintext only (TLS/H2 conns are dropped). Returns the number of
        reactor events processed."""
        comptime assert (RT.Sink == NoopSink) and (ED.Sink == NoopSink), ("serve_one_iteration_dispatch_erased[ED, RT]: RT.Sink AND ED.Sink " "must be NoopSink (the HttpServer pins Reactor[NoopSink]).")
        var completions = self._reactor.poll_completions(timeout_us)
        var n_events = len(completions)
        var i = 0
        while i < n_events:
            var c = completions[i]
            var ev_op = c.op_id

            # BUCKET 1 — listener fd: accept new conn(s).
            if ev_op == Int64(self._listen_fd):
                try:
                    _ = accept_one_and_register(
                        self._listener,
                        self._reactor,
                        self._conns,
                        self._fd_to_idx,
                    )
                except e:
                    _ = e
                i = i + 1
                continue

            # BUCKET 2 — a parked erased-handler frame's awaited op_id (biased).
            if driver.is_parked_op_id(ev_op):
                driver.resume(ev_op, self._reactor)
                self._deliver_erased_responses[ED](driver)
                i = i + 1
                continue

            # BUCKET 3 — a connection event (fd-cookie, below HANDLER_OP_ID_BIAS).
            var ev_fd = Int32(ev_op)
            var maybe_idx = self._fd_to_idx.find(Int(ev_fd))
            if not maybe_idx:
                i = i + 1
                continue
            var idx = maybe_idx.value()

            if self._conns[idx].is_tls() or self._conns[idx].is_h2():
                try:
                    close_and_remove(self._conns, self._fd_to_idx, idx)
                except e:
                    _ = e
                i = i + 1
                continue

            if self._conns[idx]._state == CONN_STATE_WAITING_FOR_WRITABLE:
                var drained = resume_pending_write(
                    self._conns[idx], self._bytes_sent,
                )
                if drained:
                    if self._conns[idx]._interest_set != INTEREST_READ:
                        try:
                            self._reactor.modify(
                                self._conns[idx]._reg, INTEREST_READ,
                            )
                            self._conns[idx]._interest_set = INTEREST_READ
                        except e:
                            _ = e
                            try:
                                close_and_remove(
                                    self._conns, self._fd_to_idx, idx,
                                )
                            except e2:
                                _ = e2
                else:
                    if self._conns[idx]._pending_len < 0:
                        try:
                            close_and_remove(
                                self._conns, self._fd_to_idx, idx,
                            )
                        except e:
                            _ = e
                i = i + 1
                continue

            # READING state — erased read round: parse -> make_erased_frame ->
            # admit. The request_id is this conn's fd (the response routing key).
            var keep_alive = serve_read_round_erased[ED, RT](
                self._conns[idx],
                rebind[Reactor[RT.Sink]](self._reactor),
                self._io_buf,
                self._config.to_parse_limits(),
                self._config.enable_expect_continue,
                dispatcher,
                rebind[ErasedHandlerDriver[ED.Sink, ED.Resp]](driver),
                Int64(ev_fd),
                self._reqs_handled,
                self._bytes_sent,
            )
            self._deliver_erased_responses[ED](driver)
            if not keep_alive:
                try:
                    close_and_remove(self._conns, self._fd_to_idx, idx)
                except e:
                    _ = e
            i = i + 1

        return n_events

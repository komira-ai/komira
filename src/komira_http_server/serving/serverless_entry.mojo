# =============================================================================
# src/komira_http_server/serving/serverless_entry.mojo
#   — the ServerlessEntry per-cloud serving seam (MULTICLOUD PHASE 1 FOUNDATION).
# =============================================================================
#
# THE SHAPE. A per-cloud serving DRIVER, generic over ANY
# dispatcher, where each cloud PACKAGES its own `Runtime` — so a per-app binary
# `main` becomes trivial:
#
#     def main() raises:
#         GcpServerlessEntry(port=parse_serve_port(port_flag)).serve(
#             build_app_router()
#         )
#
# The trait `ServerlessEntry` names ONE cloud's serving driver. A conformer
# binds its runtime TYPE as a comptime associated member (`comptime RT:
# Runtime`) and implements `serve[R: RequestDispatcher]` — the loop that
# receives requests (however that cloud delivers them) and routes each through
# `router.dispatch[Self.RT](reactor, req)`. The RUNTIME is supplied by the
# Entry (the cloud's identity); the ROUTER is RT-agnostic (its `dispatch[RT]` is
# a method-level comptime param), so ONE app router serves on ANY cloud.
#
# WHY THIS SHAPE (per-cloud driver, not a per-cloud config)
# ----------------------------------------------------------------------------
# The three clouds deliver requests by DIFFERENT mechanisms, and the trait
# abstracts exactly that difference — NOT reactor/park machinery:
#
#   * GCP Cloud Run  — an inbound TCP accept-loop. The container is a normal
#     HTTP server; the platform routes requests to the listener. `serve` binds
#     an `HttpServer` on its configured port and drives its accept/parse/dispatch loop. The
#     runtime is `GcpCloudRunRuntime[NoopSink]` — used as a COMPTIME TYPE
#     threaded into `serve_one_iteration_dispatch[D, RT]`; the HttpServer owns
#     the live reactor (the runtime stores NO reactor of its own on this path).
#     This is the ONE conformer built in this file.
#
#   * AWS Lambda     — NO inbound TCP. The Lambda container uses the Runtime
#     Interface Client model: a small SYNCHRONOUS loop (or the RIC) owns
#     `GET /next -> handle -> POST /response` against the local
#     AWS_LAMBDA_RUNTIME_API endpoint. OUR handler is PLAIN SYNCHRONOUS —
#     event JSON -> HttpRequest -> `router.dispatch[Self.RT](reactor, req)` ->
#     proxy response. There is NO async long-poll park through a non-blocking
#     stack. So `LambdaRuntime` is basically `BlockingRuntime` + a MODEL_LAMBDA
#     sentinel (for a flush-before-freeze gate), and `AwsServerlessEntry.serve`
#     is a simple synchronous handler-run — NOT an event-poll loop that parks on
#     our reactor. (Docstring sketch on `ServerlessEntry` below; NOT built here.)
#
#   * Azure Container Apps / Functions — an inbound accept-loop like Cloud Run
#     (Azure Functions custom handlers front the container with an HTTP server).
#     `AzureServerlessEntry` would mirror the GCP shape with an Azure runtime
#     sentinel. (Not built here.)
#
# The trait's `serve[R]` gives the conformer FULL freedom over HOW it drives
# requests (accept-loop vs. synchronous RIC poll) — the reactor lives INSIDE
# the conformer's chosen serving mechanism, NOT on the trait surface. That is
# why the simpler synchronous AWS conformer drops in with zero trait change:
# the trait never assumed an async/park model.
#
# ENCAPSULATION
# ----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature on this file.
#   * ZERO wildcard origins; ZERO `unsafe_from_address=Int(...)`; ZERO
#     `take_pointee`; ZERO ArcPointer.
#   * The runtime is a COMPTIME TYPE (`Self.RT`), never a stored owning field —
#     the HttpServer owns the live reactor. The Entry structs hold plain
#     values only (the listen port); nothing here is stored in a byte-slab.
#
# def-based, Mojo 1.0.0b2. `def` carries implicit `raises`.
# =============================================================================

from komira_async.runtime.gcp_cloud_run_runtime import GcpCloudRunRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_async.ops.waker_sink import NoopSink

from komira_http_server.middleware.chain import MiddlewareChain
from komira_http_server.middleware.middleware import Middleware
from komira_http_server.routing.router import Router
from komira_http_server.server import HttpServer, HttpServerConfig
from komira_http_core.tls import tls_init
from komira_http_server.dispatch import CtxRequestDispatcher, RequestDispatcher
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch


# =============================================================================
# §0 — serve-loop constants.
# =============================================================================

# The default listen port when the deployer states none — 8080, Cloud Run's
# default container port.
comptime DEFAULT_SERVE_PORT: UInt16 = 8080

# The idle-poll period (µs) of the single-threaded serve loop. A cycle with no
# ready fd parks the calling thread on the reactor's ONE fd for up to this long
# before returning 0 events, so the loop does not busy-spin.
comptime _POLL_US: Int32 = 50_000


# =============================================================================
# §1 — trait ServerlessEntry — one cloud's serving driver.
# =============================================================================


trait ServerlessEntry(Movable, Deinitable):
    """A per-cloud serving driver, generic over ANY `RequestDispatcher`.

    Each cloud's conformer PACKAGES its runtime TYPE as the comptime associated
    member `RT` and implements `serve[R]` — the loop that receives requests
    (however that cloud delivers them: an inbound accept-loop for Cloud Run /
    Azure, a synchronous RIC poll for Lambda) and routes each through
    `router.dispatch[Self.RT](reactor, req)`. A per-app binary `main` reduces to
    `GcpServerlessEntry().serve(build_my_app_router())`.

    Associated member
    ------------------------------------------------------------------
    `RT: Runtime`
        The runtime TYPE this cloud runs on. For Cloud Run this is
        `GcpCloudRunRuntime[NoopSink]` (request-driven CPU, MODEL_CLOUD_RUN);
        for Lambda it would be a `LambdaRuntime` (synchronous, MODEL_LAMBDA).
        The conformer threads it into the server's
        `serve_one_iteration_dispatch[D, RT]` (or into the synchronous
        `router.dispatch[Self.RT]` on the Lambda path). `Runtime` already
        requires `Movable & Deinitable`, so the bound carries those.

    Method
    ------------------------------------------------------------------
    `serve[R: RequestDispatcher](var self, var router: R) raises`
        Run the serve loop for THIS cloud, routing every request through
        `router`. `router` is moved in (the Entry owns it for the serve
        lifetime). The generic `R` keeps the driver dispatcher-agnostic — the
        hello-world's `AppRouter[*Routes]` pack, a hand-rolled dispatcher, or any
        other `RequestDispatcher` all drop in. `serve` normally NEVER RETURNS
        (the platform tears the process down); it `raises` only on a fatal
        bind/setup error.

        `var self` (CONSUMING) — the Entry is consumed by serving forever, and
        `var self` lets a per-app `main` spell the trivial one-liner directly on
        an rvalue: `GcpServerlessEntry().serve(build_my_app_router())` (Mojo
        1.0.0b2 rejects a `mut self` method call on a temporary rvalue).

    Future conformers (NOT built in this file)
    ------------------------------------------------------------------
    `AwsServerlessEntry` (Lambda, RT = LambdaRuntime, MODEL_LAMBDA). Its `serve`
    is a SIMPLE SYNCHRONOUS handler-run — Lambda has NO inbound TCP, so there is
    no `HttpServer` accept-loop. Instead a ~20-line blocking loop (or the AWS
    Runtime Interface Client) owns the event lifecycle against the local
    AWS_LAMBDA_RUNTIME_API endpoint:

        def serve[R: RequestDispatcher](mut self, var router: R) raises:
            var rt = LambdaRuntime.new(...)   # BlockingRuntime + MODEL_LAMBDA
            ref reactor = rt.reactor()
            while True:
                var ev = _lambda_get_next()             # blocking GET /next
                var req = _event_to_request(ev)         # event JSON -> HttpRequest
                var resp = router.dispatch[Self.RT](reactor, req^)  # SYNCHRONOUS
                _lambda_post_response(ev.request_id, _response_to_proxy(resp))
                # (a flush-before-freeze gate reads Self.RT.RUNTIME_MODEL ==
                #  MODEL_LAMBDA here, mirroring the Cloud Run freeze gate.)

    Note the handler line is IDENTICAL to the Cloud Run per-request leaf:
    `router.dispatch[Self.RT](reactor, req)`. Only the request SOURCE differs
    (an inbound accept-loop vs. an outbound RIC poll). The trait admits this
    conformer with NO change — `serve[R]` never assumed an inbound listener or
    an async/park reactor model; the reactor is threaded synchronously and only
    a no-I/O handler ever touches it on the Lambda path. `AzureServerlessEntry`
    (Azure Container Apps / Functions custom handler) mirrors the Cloud Run
    accept-loop shape with an Azure runtime sentinel.
    """

    comptime RT: Runtime

    def serve[
        R: RequestDispatcher,
    ](var self, var router: R) raises:
        ...


# =============================================================================
# §2 — port resolution (shared by inbound-listener conformers).
# =============================================================================


def parse_serve_port(value: String) -> UInt16:
    """The listen port for an inbound-listener cloud (Cloud Run / Azure) from
    the value the deployer hands the process (its port flag): an integer in
    [0, 65535], where an explicit `0` means "kernel picks an ephemeral port".
    An empty or unparseable value yields `DEFAULT_SERVE_PORT` (8080).

    The library reads no environment: a binary parses its own port flag and
    passes the result to `GcpServerlessEntry(port)`."""
    if value.byte_length() > 0:
        try:
            var p = atol(value)
            if p >= 0 and p <= 65535:
                return UInt16(p)
        except e:
            _ = e
    return DEFAULT_SERVE_PORT


# =============================================================================
# §3 — the one-iteration serve seam (factored out of the infinite loop so it
#      is unit-testable).
# =============================================================================


def serve_one_iteration_over[
    R: RequestDispatcher,
    RT: Runtime,
](
    mut server: HttpServer[NoopGrpcDispatch],
    mut dispatcher: R,
    timeout_us: Int32,
) raises -> Int:
    """Drive ONE poll cycle of `server`, routing parser-success through
    `dispatcher.dispatch[RT](reactor, req)`. Returns the number of reactor
    events processed this cycle.

    This IS the body of `GcpServerlessEntry.serve`'s infinite loop, extracted so
    a unit test can step it deterministically (the loop itself never returns).
    It forwards to the server's `serve_one_iteration_dispatch[R, RT]` — the SAME
    seam a serving binary drives — threading the Entry's runtime TYPE `RT` (a
    comptime type; the HttpServer owns the live reactor). `RT.Sink` must be
    `NoopSink` (asserted inside `serve_one_iteration_dispatch`)."""
    return server.serve_one_iteration_dispatch[R, RT](dispatcher, timeout_us)


def serve_one_iteration_chained_over[
    R: CtxRequestDispatcher,
    M: Middleware,
    RT: Runtime,
](
    mut server: HttpServer[NoopGrpcDispatch],
    mut chain: MiddlewareChain,
    mut auth_mw: M,
    mut dispatcher: R,
    timeout_us: Int32,
) raises -> Int:
    """Drive ONE poll cycle of `server` through the MIDDLEWARE CHAIN and THEN
    `dispatcher.dispatch_with_ctx[RT]`. Returns the number of reactor events
    processed this cycle.

    The CHAINED twin of `serve_one_iteration_over` — this IS the body of
    `GcpServerlessEntry.serve_chained`'s infinite loop, extracted so a unit test
    can step it deterministically. It forwards to the server's
    `serve_one_iteration_dispatch_chained[R, M, RT]`, the same seam an embedding
    binary can drive directly."""
    return server.serve_one_iteration_dispatch_chained[R, M, RT](
        chain, auth_mw, dispatcher, timeout_us
    )


# =============================================================================
# §4 — GcpServerlessEntry — the Cloud Run conformer (inbound accept-loop).
# =============================================================================


struct GcpServerlessEntry(ServerlessEntry, Movable, Deinitable):
    """The `ServerlessEntry` conformer for Google Cloud Run.

    Cloud Run fronts the container with an inbound HTTP listener, so `serve`
    binds an `HttpServer` on its `port` (default 8080) on 0.0.0.0 (reachable from
    outside the container netns) and drives its accept/parse/dispatch loop
    forever. Each request routes through `router.dispatch[Self.RT](reactor,
    req)`.

    Runtime binding (the Cloud-Run identity):
      `RT = GcpCloudRunRuntime[NoopSink]` — request-driven CPU (MODEL_CLOUD_RUN),
      used as a COMPTIME TYPE only. The HttpServer owns the live reactor; the
      runtime type is threaded into `serve_one_iteration_dispatch[D, RT]` so any
      handler's `[RT]`-generic async I/O parks on the SAME reactor that serves
      HTTP.

    A plain value type holding only the listen port — the Entry owns/pins its
    runtime as a comptime TYPE, so there is no runtime FIELD. The port comes
    from the deployer through the binary's own flag (`parse_serve_port`); the
    library reads no environment.
    """

    comptime RT = GcpCloudRunRuntime[NoopSink]

    var port: UInt16

    def __init__(out self, port: UInt16 = DEFAULT_SERVE_PORT):
        self.port = port

    def serve[
        R: RequestDispatcher,
    ](var self, var router: R) raises:
        """Bind an HTTP listener on `self.port` (0.0.0.0) and serve forever,
        routing every request through `router.dispatch[Self.RT]`.

        Cloud Run = accept-loop; the HttpServer owns the live reactor, and
        `Self.RT` (GcpCloudRunRuntime) is a comptime TYPE threaded into
        `serve_one_iteration_dispatch[R, Self.RT]`. This loop never terminates
        on its own — the platform tears the process down (SIGTERM / container
        stop); the reconciler treats an exit as a restart (the served-app
        contract).

        The `router` is moved in and owned for the serve lifetime. TLS is
        one-time-initialized (the HttpServer teardown references s2n symbols
        even on a plaintext listener), matching a typical app boot.
        """
        # One-time global TLS init (the HttpServer's plaintext-listener teardown
        # references s2n symbols at link — the binary links libs2n + libcrypto
        # and initializes s2n once). `tls_init` is idempotent, so a caller that
        # has already called it (e.g. the app main) double-inits harmlessly.
        tls_init()

        var port = self.port

        # Bind on 0.0.0.0 (`with_port_bind_any`) so the platform Service /
        # Cloud Run startup-probe can reach the listener from OUTSIDE the
        # container netns (a 127.0.0.1-bound listener is unreachable).
        var cfg = HttpServerConfig.with_port_bind_any(port)
        var server = HttpServer(config=cfg, router=Router())
        var bound = server.local_port()

        # The announce line for boot diagnostics + smoke-test probes.
        print(
            String("SERVERLESS_LISTENING port=")
            + String(Int(bound))
            + String(" bind=0.0.0.0 runtime=GcpCloudRunRuntime")
        )

        # The single-threaded serve loop. `serve_one_iteration_over[R, Self.RT]`
        # drives ONE poll cycle, routing each parsed request through `router`
        # (via `serve_one_iteration_dispatch[R, Self.RT]`). INFINITE — never
        # exits on its own.
        while True:
            _ = serve_one_iteration_over[R, Self.RT](
                server, router, _POLL_US
            )

    def serve_chained[
        R: CtxRequestDispatcher,
        M: Middleware,
    ](
        var self, var chain: MiddlewareChain, var auth_mw: M, var router: R
    ) raises:
        """Bind an HTTP listener on `self.port` (0.0.0.0) and serve forever,
        routing every request through `chain` and THEN `router.dispatch_with_ctx[Self.RT]`.

        ★ THE CHAINED SIBLING OF `serve`, AND THE REASON IT EXISTS: `serve` runs
        NO middleware, so an app on it stamps no `Access-Control-Allow-Origin` and
        answers no browser preflight — it cannot be dialled by a browser at all.
        An app that wants CORS (any app a browser page talks to) serves here
        instead. Nothing else differs: same port, same 0.0.0.0
        bind, same `SERVERLESS_LISTENING` announce token (with one extra field
        naming the chain), same infinite loop.

        ⚠ `M` IS NOT NECESSARILY AN AUTH MIDDLEWARE. It is the chain's innermost
        slot. An app whose authentication lives in a middleware passes its own
        `Middleware` conformer; an app that checks access INSIDE its dispatcher
        passes `PassthroughMiddleware` and keeps gating itself. Naming the type
        at the call site is what keeps which of the two it is visible in the
        app's own source.

        `chain`, `auth_mw` and `router` are all moved in and owned for the serve
        lifetime. `serve_chained` normally NEVER RETURNS (the platform tears the
        process down); it `raises` only on a fatal bind/setup error."""
        # Same one-time global TLS init as `serve` — the HttpServer's
        # plaintext-listener teardown references s2n symbols at link.
        tls_init()

        var port = self.port

        # Bind on 0.0.0.0 so the platform Service / Cloud Run startup probe can
        # reach the listener from OUTSIDE the container netns.
        var cfg = HttpServerConfig.with_port_bind_any(port)
        var server = HttpServer(config=cfg, router=Router())
        var bound = server.local_port()

        # The SAME announce line `serve` prints, plus the one fact that differs —
        # boot diagnostics and smoke probes grep for `SERVERLESS_LISTENING`, and a
        # second spelling would make the chained arm invisible to them.
        print(
            String("SERVERLESS_LISTENING port=")
            + String(Int(bound))
            + String(" bind=0.0.0.0 runtime=GcpCloudRunRuntime chain=middleware")
        )

        while True:
            _ = serve_one_iteration_chained_over[R, M, Self.RT](
                server, chain, auth_mw, router, _POLL_US
            )

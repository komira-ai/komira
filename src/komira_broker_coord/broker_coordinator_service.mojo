# =============================================================================
# komira_broker_coord/broker_coordinator_service.mojo
#   BROKER COORDINATOR: the runnable broker-node coordinator service (no DB).
# =============================================================================
#
# Serves the broker-heartbeat endpoint (`POST /internal/heartbeat`) and folds
# each broker-node heartbeat into the `BrokerHeartbeatCoordinator[Storage]`
# (the object-store CAS handler), persisting the assignment through the
# ClusterAssignmentStore etag CAS and replying with the responding node's
# `assigned_partitions[]` + ClusterConfig.
#
# The `json_response` / `proto_response` HTTP helpers are defined here so this
# package depends on no job-management code: the coordinator binary carries no
# database, Kubernetes client or job store.
#
# THE SINGLE EVENT LOOP: reuses the SAME `HttpServer.serve_one_iteration_
# dispatch[D, RT]` accept loop, routing parsed requests through the
# `BrokerCoordinatorDispatcher`. No periodic ticks: the assignment recomputes
# per-heartbeat (coalesced); liveness is the stale-scan inside the handler.
#
# ENCAPSULATION: the service owns its HttpServer + dispatcher by value; the
# dispatcher owns the BrokerHeartbeatCoordinator[Storage] (which owns the
# ClusterAssignmentStore). No UnsafePointer crosses any boundary and no field
# holds a wildcard-origin pointer; the per-request reactor is a `mut` borrow
# threaded per-call. The `[Storage]` generic is comptime-monomorphized.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.suspendable_handler import SuspendableHandlerDriver

from komira_http import (
    HttpMethod,
    HttpRequest,
    HttpResponse,
    HttpServer,
    HttpServerConfig,
    NoopGrpcDispatch,
    RequestDispatcher,
    Router,
)

from komira_uuid.clock import now_unix_ms

from komira_objectstore.store import (
    AsyncCasStore,
    CloneableConditionalWriteStore,
)

from engine_rpc.engine import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    HeartbeatResponse as PbHeartbeatResponse,
)
from komira_serde import encode_proto, decode_proto

from .broker_heartbeat_handler import BrokerHeartbeatCoordinator
from .broker_heartbeat_suspendable import (
    BrokerCoordSuspendableDispatcher,
    BrokerHeartbeatSM,
)


# The runtime the coordinator threads through the serve loop (its `.Sink ==
# NoopSink` matches the server's `Reactor[NoopSink]`). The S3-CAS store verbs are
# SYNC, so this runtime is only the server's serve-loop runtime; the store
# never parks I/O on it.
comptime _CoordRt = BlockingRuntime[NoopSink]


# =============================================================================
# §1 — HTTP response helpers.
# =============================================================================
def json_response(status: Int32, var body_json: String) -> HttpResponse:
    """Build an `application/json` HttpResponse with `body_json` as the body and
    the matching Content-Length."""
    var r = HttpResponse(status=status)
    r.headers[String("content-type")] = String("application/json")
    var bytes_ref = body_json.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        r.body.append(bytes_ref[i])
        i = i + 1
    r.headers[String("content-length")] = String(n)
    return r^


def proto_response(status: Int32, var body_bytes: List[UInt8]) -> HttpResponse:
    """Build an `application/protobuf` HttpResponse with `body_bytes` (the
    protobuf-binary `HeartbeatResponse`) as the RAW body + the matching
    Content-Length. The body is binary — written verbatim."""
    var r = HttpResponse(status=status)
    r.headers[String("content-type")] = String("application/protobuf")
    var n = len(body_bytes)
    r.body = body_bytes^
    r.headers[String("content-length")] = String(n)
    return r^


# =============================================================================
# §2 — BrokerCoordinatorDispatcher[Storage] — the RequestDispatcher conformer.
# =============================================================================
struct BrokerCoordinatorDispatcher[Storage: CloneableConditionalWriteStore](
    Movable, RequestDispatcher
):
    """Owns the `BrokerHeartbeatCoordinator[Storage]` and routes a parsed
    `HttpRequest` to the broker-heartbeat handler.

    Routing:
      POST /internal/heartbeat -> handle_broker_heartbeat (the S3-CAS handler)
      GET  /health             -> 200 {"status":"ok"}
      else                     -> 404 / 405

    A heartbeat WITHOUT `node_id` is a plain JOB heartbeat — this coordinator
    serves ONLY the broker leg, so a node_id-absent heartbeat is rejected 400."""

    var _coord: BrokerHeartbeatCoordinator[Self.Storage]

    def __init__(out self, var coord: BrokerHeartbeatCoordinator[Self.Storage]):
        self._coord = coord^

    def coordinator(
        ref self,
    ) -> ref [self._coord] BrokerHeartbeatCoordinator[Self.Storage]:
        """Borrow the owned coordinator (test inspection)."""
        return self._coord

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        """Route a parsed request. NEVER raises out (the server's round maps a
        raise to a 500); every domain error is caught here and mapped to a
        status. The store verbs are SYNC, so the reactor is not parked on store
        I/O."""
        if req.method == HttpMethod.get() and req.path == String("/health"):
            return json_response(Int32(200), String('{"status":"ok"}'))

        if req.method == HttpMethod.post() and req.path == String(
            "/internal/heartbeat"
        ):
            return self._handle_broker_heartbeat_route[RT](reactor, req^)

        if req.path == String("/health") or req.path == String(
            "/internal/heartbeat"
        ):
            return HttpResponse.method_not_allowed()
        return HttpResponse.not_found()

    def _handle_broker_heartbeat_route[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        """Decode the protobuf-binary `SupervisorHeartbeat`, route the broker leg
        (node_id present) to `handle_broker_heartbeat`, and reply with the
        protobuf-binary `HeartbeatResponse`. A decode error / a node_id-absent
        (misrouted job) heartbeat -> 400."""
        var body = List[UInt8]()
        swap(body, req.body)

        var parsed = Optional[PbSupervisorHeartbeat]()
        try:
            parsed = Optional[PbSupervisorHeartbeat](
                decode_proto[PbSupervisorHeartbeat](body^)
            )
        except pe:
            return json_response(
                Int32(400),
                String('{"error":"bad_request","message":"')
                + _sanitize(String(pe))
                + String('"}'),
            )

        var hb = parsed.take()
        if not hb.node_id:
            return json_response(
                Int32(400),
                String(
                    '{"error":"bad_request","message":"broker coordinator:'
                    ' node_id required (this is the broker-heartbeat leg)"}'
                ),
            )

        # CORRECTNESS GUARD (broker peer routing): cross-leg contamination
        # defense — a request carrying node_id AND a MEANINGFUL job_id is
        # malformed (reject 400 rather than fold a job identity into the broker
        # registry / run an assignment off a job heartbeat).
        if _is_meaningful_job_id(hb.job_id):
            return json_response(
                Int32(400),
                String(
                    '{"error":"bad_request","message":"broker coordinator:'
                    " cross-leg contamination — a request carries BOTH a"
                    " broker node_id AND a meaningful job_id; a broker"
                    ' heartbeat must carry the nil job_id"}'
                ),
            )

        var now_us = now_unix_ms() * Int64(1000)
        try:
            var resp = self._coord.handle_broker_heartbeat(hb, now_us)
            return proto_response(
                Int32(200), encode_proto[PbHeartbeatResponse](resp)
            )
        except he:
            return json_response(
                Int32(500),
                String('{"error":"assignment_failed","message":"')
                + _sanitize(String(he))
                + String('"}'),
            )


# =============================================================================
# §3 — BrokerCoordinatorService[Storage] — owns the server + dispatcher + loop.
# =============================================================================
struct BrokerCoordinatorService[
    Storage: CloneableConditionalWriteStore & AsyncCasStore
](Movable, Deinitable):
    """The runnable broker-node coordinator service: owns the `HttpServer`
    (reactor accept loop, bound to the broker-heartbeat listener) + the
    `BrokerCoordSuspendableDispatcher[Storage]` (which owns the coordinator) +
    the per-worker `SuspendableHandlerDriver` that multiplexes parked reassigns.

    PARKABLE SERVE: `serve_step` drives
    `serve_one_iteration_dispatch_suspendable`, whose 3-bucket demux fires
    accept (bucket 1) WHILE a rebalance's object-store CAS reassign is parked
    (bucket 2), so a burst of heartbeats cannot stall behind one reassign, and
    the serve thread never blocks on an object-store round trip. The coalesce HIT (the dominant
    heartbeat) is a one-step DONE that never parks. `_CoordRt =
    BlockingRuntime[NoopSink]` STAYS: the driver multiplexes at the
    serve-loop/reactor level regardless of Runtime."""

    var _server: HttpServer[NoopGrpcDispatch]
    var _dispatcher: BrokerCoordSuspendableDispatcher[Self.Storage]
    var _driver: SuspendableHandlerDriver[
        NoopSink, BrokerHeartbeatSM[Self.Storage]
    ]
    var _serve_poll_timeout_us: Int32

    def __init__(
        out self,
        var coord: BrokerHeartbeatCoordinator[Self.Storage],
        config: HttpServerConfig,
        trace: Bool = False,
    ) raises:
        """Construct + bind. Builds the Router with the coordinator's two routes,
        constructs the HttpServer on `config`'s port (0 == ephemeral), wraps the
        coordinator in the suspendable dispatcher, and builds the per-worker
        suspendable driver.

        Args:
            coord: The heartbeat coordinator (moved in).
            config: The HTTP listener configuration.
            trace: Diagnostic switch, supplied by the caller (a binary sets it
                from a command-line flag). When True the serve loop, the
                dispatcher and each parkable frame print `[coord-trace]` lines.
                Default False.
        """
        var router = Router()
        router.add(HttpMethod.post(), "/internal/heartbeat", 0)
        router.add(HttpMethod.get(), "/health", 1)
        self._server = HttpServer(config=config, router=router^)
        self._dispatcher = BrokerCoordSuspendableDispatcher[Self.Storage](
            coord^, trace
        )
        self._driver = SuspendableHandlerDriver[
            NoopSink, BrokerHeartbeatSM[Self.Storage]
        ]()
        self._serve_poll_timeout_us = Int32(50_000)

    def local_port(self) raises -> UInt16:
        """The kernel-assigned ephemeral port (when config.port == 0)."""
        return self._server.local_port()

    def dispatcher(
        ref self,
    ) -> ref [self._dispatcher] BrokerCoordSuspendableDispatcher[Self.Storage]:
        """Borrow the dispatcher (test inspection — reach the coordinator)."""
        return self._dispatcher

    def driver_ref(
        ref self,
    ) -> ref [self._driver] SuspendableHandlerDriver[
        NoopSink, BrokerHeartbeatSM[Self.Storage]
    ]:
        """Borrow the suspendable driver (test inspection — inflight/park/resume
        counters)."""
        return self._driver

    def live_conn_count(self) -> Int:
        """Number of live connections in the server's conn slab (diagnostic —
        an fd/conn leak shows up here as a monotonically growing count)."""
        return self._server.live_conn_count()

    def serve_step(mut self) raises -> Int:
        """ONE iteration of the PARKABLE serve loop: drive one poll cycle through
        the suspendable dispatcher + driver. Accept fires while a reassign is
        parked (the 3-bucket demux). Returns the number of reactor events
        processed."""
        return self._server.serve_one_iteration_dispatch_suspendable[
            BrokerCoordSuspendableDispatcher[Self.Storage], _CoordRt
        ](self._dispatcher, self._driver, self._serve_poll_timeout_us)

    def run_for(mut self, max_iters: Int, serve_timeout_us: Int32) raises:
        """TEST SEAM: drive the parkable serve loop for up to `max_iters`
        iterations with an explicit per-iteration serve timeout."""
        var i = 0
        while i < max_iters:
            _ = self._server.serve_one_iteration_dispatch_suspendable[
                BrokerCoordSuspendableDispatcher[Self.Storage], _CoordRt
            ](self._dispatcher, self._driver, serve_timeout_us)
            i = i + 1


def run_coordinator_forever[
    Storage: CloneableConditionalWriteStore & AsyncCasStore
](mut service: BrokerCoordinatorService[Storage]) raises:
    """The production loop: drive the serve loop FOREVER. The process is ended
    by SIGTERM; the assignment is persisted in the ClusterAssignmentStore (object
    store), so an abrupt exit is safe: a fresh coordinator recovers the
    assignment on the next heartbeat.

    When the service was built with `trace=True`, print one trace line every
    20000 iterations and on any iteration that processed >0 events, so a
    serve-loop stall is directly observable in the log: a frozen loop count is
    a blocked step, a growing inflight count is a parked-frame leak, events>0
    with no accept is a demux mis-route.
    """
    var trace = service.dispatcher().trace_enabled()
    var iters = Int64(0)
    while True:
        var n = service.serve_step()
        if trace:
            iters += 1
            if n > 0 or (iters % Int64(20000)) == Int64(0):
                print(
                    "[coord-trace] iter="
                    + String(iters)
                    + " events="
                    + String(n)
                    + " inflight="
                    + String(service.driver_ref().inflight_count())
                    + " admit="
                    + String(service.driver_ref().admit_count())
                    + " park="
                    + String(service.driver_ref().park_count())
                    + " resume="
                    + String(service.driver_ref().resume_count())
                    + " delivered="
                    + String(service.driver_ref().delivered_count())
                    + " conns="
                    + String(service.live_conn_count())
                )


# =============================================================================
# §4 — cross-leg contamination guard helper.
# =============================================================================
comptime _NIL_JOB_ID: String = String("00000000-0000-0000-0000-000000000000")


def _is_meaningful_job_id(job_id: String) -> Bool:
    """True iff `job_id` is a MEANINGFUL job identity (NOT empty and NOT the nil
    UUID a broker heartbeat stamps)."""
    if job_id.byte_length() == 0:
        return False
    if job_id == _NIL_JOB_ID:
        return False
    return True


# =============================================================================
# §5 — small JSON-sanitizer (local — the dispatch error bodies are diagnostic).
# =============================================================================
def _sanitize(s: String) -> String:
    """Strip double-quotes / backslashes / newlines from an error string so it
    can be embedded in a JSON string literal (diagnostic, not machine-parsed)."""
    var out = String("")
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == UInt8(0x22) or c == UInt8(0x5C):  # '"' or '\'
            out += String(" ")
        elif c == UInt8(0x0A) or c == UInt8(0x0D):  # newline
            out += String(" ")
        else:
            out += chr(Int(c))
    return out^

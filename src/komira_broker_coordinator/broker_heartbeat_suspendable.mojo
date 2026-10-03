# =============================================================================
# komira_broker_coordinator/broker_heartbeat_suspendable.mojo
#   BROKER COORDINATOR PARKABLE CAS SERVE: the heartbeat handler as a
#   SuspendableHandler whose reassign parks on the SERVE reactor.
# =============================================================================
#
# The coordinator persists through the object store, and an object-store
# request is a SOCKET the serve reactor can park on. This file makes the RARE
# reassign's object-store round trip PARKABLE so the single-threaded serve loop
# multiplexes accept (bucket 1) WHILE a reassign is parked (bucket 2): a
# rebalance burst cannot stall the loop, and the serve thread never blocks on
# an object-store round trip.
#
# ── THE DECOMPOSITION (coalesce-HIT one-step; membership-change parks) ────────
# The dispatcher's `make_frame` runs the SYNCHRONOUS prelude EAGERLY on the
# coordinator (register the node + the store-free coalesce check), EXACTLY as
# `SyncToSuspendable` runs a synchronous handler's dispatch eagerly:
#   * COALESCE HIT (the dominant path): the reply is built FROM CACHE
#     synchronously; the SM is a one-step DONE frame — it NEVER parks.
#   * MEMBERSHIP CHANGE (the rare rebalance): the SM owns a parkable
#     `AsyncReassignOp` (a store CLONE + the eagerly-computed live-set inputs +
#     an eager registry endpoint snapshot). `step()` drives read -> pure pass ->
#     CAS-put, parking on each object-store round trip's biased op_id. On
#     completion it builds the HeartbeatResponse + refreshes the coordinator's
#     coalesce cache.
#
# ── THE POINTER-LIFETIME CONTRACT ─────────────────────────────────────────────
# The in-flight CAS op holds an in-flight `PendingStreamingGet` (which owns the
# dialed stream + the HttpClient pool's heap buffers) ACROSS the park. That op
# is held INSIDE the conformer (reached via the conformer's concrete-origin
# `ArcPointer[Optional[transport]]` handle — NEVER a byte-`Slab` +
# `MutExternalOrigin` wildcard, a shape that crashes when a process reuses the
# freed bytes). The `AsyncReassignOp` owns a STORE CLONE (the
# `CloneableConditionalWriteStore` clone shares the Arc-backed core/map; for S3
# the clone mints a fresh per-handle transport Arc), so the parkable op reaches
# the transport via that clone's OWN concrete-origin handle. The poll-shaped op
# NEVER crosses the trait boundary — only typed values (CasReadResult /
# ObjectMeta / op_id) do. The SM is a single heap value reached via the
# substrate's `OwnedPointer` frame, NOT a Movable struct in a byte-slab. So no
# transport-pool buffer is laundered through a wildcard origin.
#
# ── ENCAPSULATION ─────────────────────────────────────────────────────────────
# ZERO UnsafePointer in any signature; ZERO wildcard origin; ZERO
# unsafe_from_address. The reactor is threaded into `step()` per-call (never a
# field). Every SM field is a value type (the store clone is a Movable value;
# the inputs are Strings / Lists / PODs).
# =============================================================================


from std.memory import ArcPointer

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.suspendable_handler import (
    HandlerStepResult,
    SuspendableHandler,
    SuspendedFrame as _SuspendedFrame,
    SuspendableHandlerDriver as _SuspendableHandlerDriver,
    DeliveredResponse as _DeliveredResponse,
)

from komira_broker import (
    Assignment,
    LiveNode,
    assign_partitions,
    rebalance_reason_for,
)
from komira_objectstore.path import Path
from komira_objectstore.store import (
    AsyncCasStore,
    CasReadResult,
    CloneableConditionalWriteStore,
)

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import SuspendableDispatcher

from komira_supervisor_proto.supervisor import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    HeartbeatResponse as PbHeartbeatResponse,
)
from komira_broker_proto.broker import (
    ClusterConfig as PbClusterConfig,
    BrokerClusterMap as PbBrokerClusterMap,
    NodeEndpoint as PbNodeEndpoint,
    PartitionLeader as PbPartitionLeader,
)
from komira_proto_codec import encode_proto, decode_proto

from .broker_heartbeat_handler import (
    BrokerHeartbeatCoordinator,
    HeartbeatPrelude,
    NO_LEADER_NODE_ID,
    NodeEndpointSnapshot,
    _CoalesceCacheState,
    _parse_node_id,
)
from .broker_coordinator_service import (
    json_response,
    _is_meaningful_job_id,
    _sanitize,
)


# The CAS-retry bound — mirrors the synchronous reassign loop's _CAS_RETRY_LIMIT.
comptime _ASYNC_CAS_RETRY_LIMIT: Int = 256


# =============================================================================
# §1 — AsyncReassignOp[Storage] — the parkable read -> pure pass -> CAS-put op.
# =============================================================================
# Drives ONE reassign as a poll-shaped state machine over an `AsyncCasStore`
# clone. Phases:
#   READ      — read_start/read_poll the prior assignment (parks on its op_id).
#   COMPUTE   — (synchronous, CPU-only) run the pure assign_partitions pass.
#   CAS_PUT   — cas_put_start/cas_put_poll the new body (parks on its op_id).
#               on a 412 (lost CAS) loop back to READ (re-read + recompute).
#   DONE      — the committed Assignment is available via take_result().
#
# The store CLONE is owned by-value (the concrete-origin handle); the
# poll-shaped op's in-flight `PendingStreamingGet` lives INSIDE the clone, never
# crossing this struct's boundary.

comptime _RA_PHASE_READ: UInt8 = 0
comptime _RA_PHASE_CAS_PUT: UInt8 = 1
comptime _RA_PHASE_DONE: UInt8 = 2
comptime _RA_PHASE_ERR: UInt8 = 3


struct AsyncReassignOp[
    Storage: CloneableConditionalWriteStore & AsyncCasStore
](Movable, Deinitable):
    """The parkable reassign op: read prior -> pure pass -> CAS-put, with the
    412-retry loop, driven one non-blocking step at a time on the serve reactor.

    Owns a `Storage` CLONE (the Arc-shared store; the in-flight poll-shaped op's
    `PendingStreamingGet` lives INSIDE the clone, never in a wildcard field). The pure-pass
    inputs (`sorted_ids` / `effective_p`) are captured eagerly so the COMPUTE
    phase is purely CPU-bound between the two parks."""

    var _store: Self.Storage
    var _key: String
    var _sorted_ids: List[String]
    var _effective_p: Int
    var _phase: UInt8
    var _attempt: Int
    # Carried across the READ park: the prior body/etag the COMPUTE phase reads.
    var _prior: Optional[Assignment]
    var _expected_etag: String
    # The body being CAS-written (carried across the CAS_PUT park) + the result.
    var _result: Optional[Assignment]
    var _err: String

    def __init__(
        out self,
        var store: Self.Storage,
        var key: String,
        var sorted_ids: List[String],
        effective_p: Int,
    ):
        self._store = store^
        self._key = key^
        self._sorted_ids = sorted_ids^
        self._effective_p = effective_p
        self._phase = _RA_PHASE_READ
        self._attempt = 0
        self._prior = Optional[Assignment]()
        self._expected_etag = String("")
        self._result = Optional[Assignment]()
        self._err = String("")

    @always_inline
    def is_done(self) -> Bool:
        return self._phase == _RA_PHASE_DONE

    @always_inline
    def is_error(self) -> Bool:
        return self._phase == _RA_PHASE_ERR

    @always_inline
    def err_text(self) -> String:
        return self._err

    def take_result(mut self) raises -> Assignment:
        """Move the committed Assignment out (caller checks is_done())."""
        if not self._result:
            raise Error("AsyncReassignOp.take_result: not done")
        return self._result.take()

    def _begin_read[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Start a CAS attempt by kicking off the prior-assignment read. Returns
        the op_id to park on, or 0 if the read completed immediately (the caller
        then drives the next phase in the same step)."""
        self._attempt += 1
        var path = Path.parse(self._key)
        var prog = self._store.read_start[S](path, reactor)
        if prog.is_error():
            self._phase = _RA_PHASE_ERR
            self._err = String("AsyncReassignOp read: ") + prog.err_text()
            return Int64(0)
        if prog.is_pending():
            return prog.op_id
        # READY immediately — consume the read + advance to CAS_PUT.
        return self._after_read_ready[S](reactor)

    def _after_read_ready[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Consume the completed read, run the pure pass (COMPUTE), and kick off
        the CAS-put. Returns the CAS-put op_id to park on (or 0 on immediate
        completion / error)."""
        var rr = self._store.read_take()
        self._expected_etag = String("")
        self._prior = Optional[Assignment]()
        if not rr.absent:
            self._prior = Optional[Assignment](Assignment.decode_binary(rr.body))
            self._expected_etag = rr.etag.copy()
        # COMPUTE — the pure assign_partitions pass (CPU-only, no I/O).
        var reason = rebalance_reason_for(
            self._prior, self._sorted_ids, self._effective_p,
            operator_forced=False,
        )
        var assignment = assign_partitions(
            self._sorted_ids.copy(), self._effective_p, self._prior^, reason
        )
        self._prior = Optional[Assignment]()
        # Stash the computed assignment so take_result can return it on a won CAS.
        var body = assignment.encode_binary()
        self._result = Optional[Assignment](assignment^)
        # CAS_PUT — kick off the parkable write.
        self._phase = _RA_PHASE_CAS_PUT
        var path = Path.parse(self._key)
        var prog = self._store.cas_put_start[S](
            path, body^, self._expected_etag, reactor
        )
        if prog.is_error():
            return self._handle_cas_error[S](prog.err_text(), reactor)
        if prog.is_pending():
            return prog.op_id
        return self._after_cas_ready[S](reactor)

    def _after_cas_ready[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """The CAS-put completed READY — the write won. Finalize."""
        _ = self._store.cas_put_take()
        self._phase = _RA_PHASE_DONE
        return Int64(0)

    @staticmethod
    def _is_precondition_failure(msg: String) -> Bool:
        """A lost CAS surfaces as a 412 / precondition error from the store.
        Cloned from ClusterAssignmentStore.is_precondition_failure (kept local so
        the op needs only the AsyncCasStore bound, not the ClusterAssignmentStore
        wrapper)."""
        return (
            msg.find("412") >= 0
            or msg.find("precondition") >= 0
            or msg.find("If-Match") >= 0
            or msg.find("If-None-Match") >= 0
        )

    def _handle_cas_error[
        S: WakerSink & Movable & Deinitable,
    ](mut self, msg: String, mut reactor: Reactor[S]) raises -> Int64:
        """A CAS error: a 412 (lost CAS) loops back to READ + retry; any other
        error is terminal."""
        if Self._is_precondition_failure(msg):
            if self._attempt >= _ASYNC_CAS_RETRY_LIMIT:
                self._phase = _RA_PHASE_ERR
                self._err = String(
                    "AsyncReassignOp: CAS contention did not converge within "
                ) + String(_ASYNC_CAS_RETRY_LIMIT) + String(" attempts")
                return Int64(0)
            # Re-read + recompute + retry.
            self._result = Optional[Assignment]()
            self._phase = _RA_PHASE_READ
            return self._begin_read[S](reactor)
        self._phase = _RA_PHASE_ERR
        self._err = String("AsyncReassignOp CAS: ") + msg
        return Int64(0)

    def start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Kick off the op. Returns the op_id to park on (0 == finished in one
        synchronous burst — the caller checks is_done()/is_error())."""
        return self._begin_read[S](reactor)

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Resume the op after the op_id it parked on completed. Advances the
        in-flight phase one non-blocking step. Returns the next op_id to park on,
        or 0 when finished (is_done()/is_error())."""
        if self._phase == _RA_PHASE_READ:
            var prog = self._store.read_poll[S](reactor)
            if prog.is_error():
                self._phase = _RA_PHASE_ERR
                self._err = String("AsyncReassignOp read: ") + prog.err_text()
                return Int64(0)
            if prog.is_pending():
                return prog.op_id
            return self._after_read_ready[S](reactor)
        elif self._phase == _RA_PHASE_CAS_PUT:
            var prog = self._store.cas_put_poll[S](reactor)
            if prog.is_error():
                return self._handle_cas_error[S](prog.err_text(), reactor)
            if prog.is_pending():
                return prog.op_id
            return self._after_cas_ready[S](reactor)
        else:
            return Int64(0)


# =============================================================================
# §3 — build_heartbeat_response — assemble the reply from an assignment.
# =============================================================================
def build_heartbeat_response(
    assignment: Assignment,
    node_id: String,
    endpoints: List[NodeEndpointSnapshot],
) raises -> PbHeartbeatResponse:
    """Build the broker HeartbeatResponse for `node_id` from the freshly-computed
    `assignment` + the eager registry endpoint snapshot. Mirrors the synchronous
    `BrokerHeartbeatCoordinator.handle_broker_heartbeat` reply tail +
    `_build_broker_cluster_map`, but over a SNAPSHOT (so it runs AFTER the park
    without re-borrowing the live registry)."""
    var assigned = assignment.partitions_for(node_id)
    # The per-partition lease generations for `node_id`'s
    # assigned partitions, POSITIONALLY PARALLEL to `assigned`.
    var assigned_gens = assignment.generations_for(node_id)
    var cluster = PbClusterConfig(
        UInt32(assignment.num_partitions),
        UInt32(assignment.node_count()),
    )
    # Cluster routing map: nodes from the snapshot, leaders from the assignment.
    var nodes = List[PbNodeEndpoint]()
    for i in range(len(endpoints)):
        ref e = endpoints[i]
        nodes.append(
            PbNodeEndpoint(
                _parse_node_id(e.node_id),
                e.advertised_host.copy(),
                UInt32(Int(e.advertised_port)),
            )
        )
    var leaders = List[PbPartitionLeader]()
    for pid in range(assignment.num_partitions):
        var owner = assignment.owner_of(pid)
        var leader_id = NO_LEADER_NODE_ID
        if owner.byte_length() > 0:
            leader_id = _parse_node_id(owner)
        leaders.append(PbPartitionLeader(UInt32(pid), leader_id))
    var broker_cluster = PbBrokerClusterMap(nodes^, leaders^)
    return PbHeartbeatResponse(
        False,  # cancel (a broker node is never job-cancelled here)
        assigned^,
        Optional[PbClusterConfig](cluster^),
        Optional[PbBrokerClusterMap](broker_cluster^),
        assigned_gens^,  # assigned_generations (the lease per assigned pid)
    )


def proto_heartbeat_http_response(
    var resp: PbHeartbeatResponse,
) raises -> HttpResponse:
    """Encode `resp` to a protobuf-binary `application/protobuf` HttpResponse
    (the same shape `proto_response` builds in broker_coordinator_service)."""
    var body_bytes = encode_proto[PbHeartbeatResponse](resp)
    var r = HttpResponse(status=Int32(200))
    r.headers[String("content-type")] = String("application/protobuf")
    var n = len(body_bytes)
    r.body = body_bytes^
    r.headers[String("content-length")] = String(n)
    return r^


# =============================================================================
# §4 — BrokerHeartbeatSM[Storage] — the SuspendableHandler.
# =============================================================================
# Two shapes, chosen by `make_frame`:
#   * ONE-STEP (coalesce HIT / a 4xx / an error): owns an already-built
#     HttpResponse; step() returns DONE in one step — NEVER parks.
#   * PARKABLE (membership change): owns the AsyncReassignOp + the inputs needed
#     to build the reply (node_id + the endpoint snapshot). step() drives the op,
#     parking on each S3 round-trip's biased op_id, and on completion builds the
#     HeartbeatResponse + returns DONE.

comptime _SM_STEP_START: UInt8 = 0
comptime _SM_STEP_AWAITING: UInt8 = 1
comptime _SM_STEP_DONE: UInt8 = 2


@fieldwise_init
struct BrokerHeartbeatSM[
    Storage: CloneableConditionalWriteStore & AsyncCasStore
](Movable, Deinitable, SuspendableHandler):
    """The broker-heartbeat handler state machine. Conforms to
    `SuspendableHandler` with `Resp = HttpResponse`.

    `_one_step` (Optional[HttpResponse]) is the coalesce-HIT / error fast path —
    when present, step() delivers it in ONE step and never parks. Otherwise the
    SM owns the parkable `AsyncReassignOp` + the reply-building inputs.

    Movable, NOT Copyable: owns the op (a store clone + Lists) + Strings.
    Migration-clean: every field is a value type; the reactor is threaded into
    step() per-call, never stored."""

    comptime Resp = HttpResponse

    var _step: UInt8
    var _one_step: Optional[HttpResponse]
    var _op: Optional[AsyncReassignOp[Self.Storage]]
    var _node_id: String
    var _endpoints: List[NodeEndpointSnapshot]
    # Coalesce-cache writeback: on a won CAS the SM refreshes
    # the coordinator's Arc-shared coalesce cache with the freshly-computed
    # assignment + its membership key, so a subsequent no-membership-change
    # heartbeat is a one-step cached reply (preserving the coalesce invariant).
    var _cache: Optional[ArcPointer[_CoalesceCacheState]]
    var _membership: List[String]
    var _effective_p: Int
    # Diagnostic trace switch (the dispatcher's, copied in): print one line per
    # park / resume / completion.
    var _trace: Bool

    @staticmethod
    def one_step(var response: HttpResponse) -> BrokerHeartbeatSM[Self.Storage]:
        """A coalesce-HIT / 4xx / error fast-path frame: already-computed
        response, never parks."""
        return BrokerHeartbeatSM[Self.Storage](
            _step=_SM_STEP_START,
            _one_step=Optional[HttpResponse](response^),
            _op=Optional[AsyncReassignOp[Self.Storage]](),
            _node_id=String(""),
            _endpoints=List[NodeEndpointSnapshot](),
            _cache=Optional[ArcPointer[_CoalesceCacheState]](),
            _membership=List[String](),
            _effective_p=0,
            _trace=False,
        )

    @staticmethod
    def parkable(
        var op: AsyncReassignOp[Self.Storage],
        var node_id: String,
        var endpoints: List[NodeEndpointSnapshot],
        var cache: ArcPointer[_CoalesceCacheState],
        var membership: List[String],
        effective_p: Int,
        trace: Bool = False,
    ) -> BrokerHeartbeatSM[Self.Storage]:
        """A membership-change frame: drives the parkable reassign, then builds
        the reply from the result + the snapshot, and refreshes the coalesce
        cache (`cache` / `membership` / `effective_p` are the writeback key).
        `trace` turns on the per-step diagnostic lines."""
        return BrokerHeartbeatSM[Self.Storage](
            _step=_SM_STEP_START,
            _one_step=Optional[HttpResponse](),
            _op=Optional[AsyncReassignOp[Self.Storage]](op^),
            _node_id=node_id^,
            _endpoints=endpoints^,
            _cache=Optional[ArcPointer[_CoalesceCacheState]](cache^),
            _membership=membership^,
            _effective_p=effective_p,
            _trace=trace,
        )

    def _finish(mut self) raises -> HandlerStepResult[HttpResponse]:
        """Consume the completed op, refresh the coalesce cache, build the reply,
        return DONE (or ERR)."""
        self._step = _SM_STEP_DONE
        ref op = self._op.value()
        if op.is_error():
            return HandlerStepResult[HttpResponse].error(op.err_text())
        var assignment = op.take_result()
        # Refresh the coordinator's coalesce cache (won CAS) so the next
        # no-membership-change heartbeat is a one-step cached reply.
        if self._cache:
            self._cache.value()[].refresh(
                assignment.copy(), self._membership.copy(), self._effective_p
            )
        var resp = build_heartbeat_response(
            assignment, self._node_id, self._endpoints
        )
        return HandlerStepResult[HttpResponse].done(
            proto_heartbeat_http_response(resp^)
        )

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[HttpResponse]:
        """Resume the handler. The coalesce-HIT path delivers in ONE step; the
        membership-change path drives the parkable reassign."""
        if self._step == _SM_STEP_DONE:
            return HandlerStepResult[HttpResponse].error(
                String("BrokerHeartbeatSM: step() after DONE")
            )

        # ── ONE-STEP fast path (coalesce HIT / 4xx / error). ─────────────────
        if self._one_step:
            self._step = _SM_STEP_DONE
            return HandlerStepResult[HttpResponse].done(self._one_step.take())

        var trace = self._trace

        # ── PARKABLE reassign. ───────────────────────────────────────────────
        if self._step == _SM_STEP_START:
            var op_id = self._op.value().start[S](reactor)
            if self._op.value().is_done() or self._op.value().is_error():
                if trace:
                    print("[coord-trace] SM.step START -> DONE/ERR (one burst)")
                return self._finish()
            self._step = _SM_STEP_AWAITING
            if trace:
                print(
                    "[coord-trace] SM.step START -> PARK op_id=" + String(op_id)
                )
            return HandlerStepResult[HttpResponse].parked(op_id)

        # _SM_STEP_AWAITING — resumed; advance the op one step.
        var op_id = self._op.value().poll[S](reactor)
        if self._op.value().is_done() or self._op.value().is_error():
            if trace:
                print("[coord-trace] SM.step RESUME -> DONE/ERR")
            return self._finish()
        if trace:
            print("[coord-trace] SM.step RESUME -> RE-PARK op_id=" + String(op_id))
        return HandlerStepResult[HttpResponse].parked(op_id)


# =============================================================================
# §5 — BrokerCoordSuspendableDispatcher[Storage] — the SuspendableDispatcher.
# =============================================================================
# Owns the `BrokerHeartbeatCoordinator[Storage]` and turns one parsed request
# into a `BrokerHeartbeatSM`. `make_frame`:
#   * GET /health                -> one-step 200 frame.
#   * POST /internal/heartbeat   -> decode the protobuf SupervisorHeartbeat;
#       run the EAGER prelude (register + coalesce). Coalesce HIT -> a one-step
#       cached reply frame (never parks); membership change -> a parkable frame
#       wrapping an AsyncReassignOp.
#   * a decode error / node_id-absent / cross-leg contamination -> one-step 400.
#   * else -> one-step 404 / 405.


struct BrokerCoordSuspendableDispatcher[
    Storage: CloneableConditionalWriteStore & AsyncCasStore
](Movable, Deinitable, SuspendableDispatcher):
    """The suspendable counterpart of `BrokerCoordinatorDispatcher`. Owns the
    coordinator; `make_frame` runs the eager prelude + builds a one-step or
    parkable `BrokerHeartbeatSM`. Associated `Handler = BrokerHeartbeatSM`.

    `trace` (default False, supplied by the caller) prints one diagnostic line
    per coalesce hit / membership change here, and per park / resume in each
    parkable frame."""

    comptime Handler = BrokerHeartbeatSM[Self.Storage]

    var _coord: BrokerHeartbeatCoordinator[Self.Storage]
    var _trace: Bool

    def __init__(
        out self,
        var coord: BrokerHeartbeatCoordinator[Self.Storage],
        trace: Bool = False,
    ):
        self._coord = coord^
        self._trace = trace

    def trace_enabled(self) -> Bool:
        """Whether the diagnostic trace lines are on."""
        return self._trace

    def coordinator(
        ref self,
    ) -> ref [self._coord] BrokerHeartbeatCoordinator[Self.Storage]:
        """Borrow the owned coordinator (test inspection)."""
        return self._coord

    def _one_step_frame(
        self, var response: HttpResponse, request_id: Int64
    ) -> _SuspendedFrame[BrokerHeartbeatSM[Self.Storage]]:
        """Wrap a one-step (already-computed) response in a SuspendedFrame."""
        return _SuspendedFrame[BrokerHeartbeatSM[Self.Storage]](
            BrokerHeartbeatSM[Self.Storage].one_step(response^), request_id
        )

    def _one_step_json_frame(
        self, status: Int32, var body: String, request_id: Int64
    ) raises -> _SuspendedFrame[BrokerHeartbeatSM[Self.Storage]]:
        """A one-step frame carrying a JSON HttpResponse (4xx / health)."""
        return self._one_step_frame(json_response(status, body^), request_id)

    def make_frame[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var req: HttpRequest,
        request_id: Int64,
    ) raises -> _SuspendedFrame[BrokerHeartbeatSM[Self.Storage]]:
        """Build the heartbeat frame for `req` (the eager prelude runs here; the
        store round-trips are deferred to the parkable SM's step())."""
        if req.method == HttpMethod.get() and req.path == String("/health"):
            return self._one_step_json_frame(
                Int32(200), String('{"status":"ok"}'), request_id
            )

        if not (
            req.method == HttpMethod.post()
            and req.path == String("/internal/heartbeat")
        ):
            if req.path == String("/health") or req.path == String(
                "/internal/heartbeat"
            ):
                return self._one_step_frame(
                    HttpResponse.method_not_allowed(), request_id
                )
            return self._one_step_frame(HttpResponse.not_found(), request_id)

        # POST /internal/heartbeat — decode the protobuf SupervisorHeartbeat.
        var body = List[UInt8]()
        swap(body, req.body)
        var parsed = Optional[PbSupervisorHeartbeat]()
        try:
            parsed = Optional[PbSupervisorHeartbeat](
                decode_proto[PbSupervisorHeartbeat](body^)
            )
        except pe:
            return self._one_step_json_frame(
                Int32(400),
                String('{"error":"bad_request","message":"')
                + _sanitize(String(pe))
                + String('"}'),
                request_id,
            )
        var hb = parsed.take()
        if not hb.node_id:
            return self._one_step_json_frame(
                Int32(400),
                String(
                    '{"error":"bad_request","message":"broker coordinator:'
                    ' node_id required (this is the broker-heartbeat leg)"}'
                ),
                request_id,
            )
        if _is_meaningful_job_id(hb.job_id):
            return self._one_step_json_frame(
                Int32(400),
                String(
                    '{"error":"bad_request","message":"broker coordinator:'
                    " cross-leg contamination — a request carries BOTH a"
                    " broker node_id AND a meaningful job_id; a broker"
                    ' heartbeat must carry the nil job_id"}'
                ),
                request_id,
            )

        # The EAGER prelude (register + coalesce; store-free).
        from komira_clock import now_unix_ms

        var now_us = now_unix_ms() * Int64(1000)
        var prelude: HeartbeatPrelude
        try:
            prelude = self._coord.prepare_async_heartbeat(hb, now_us)
        except he:
            return self._one_step_json_frame(
                Int32(500),
                String('{"error":"assignment_failed","message":"')
                + _sanitize(String(he))
                + String('"}'),
                request_id,
            )

        if not prelude.parked:
            # Coalesce HIT — build the cached reply (one-step DONE).
            if self._trace:
                print(
                    "[coord-trace] make_frame: COALESCE-HIT node="
                    + prelude.node_id
                )
            var resp = build_heartbeat_response(
                prelude.cached_assignment.value(),
                prelude.node_id,
                prelude.endpoints,
            )
            return self._one_step_frame(
                proto_heartbeat_http_response(resp^), request_id
            )

        # MEMBERSHIP CHANGE — build the parkable reassign op + frame.
        if self._trace:
            print(
                "[coord-trace] make_frame: MEMBERSHIP-CHANGE node="
                + prelude.node_id
                + " effective_p="
                + String(prelude.effective_p)
                + " n_live="
                + String(len(prelude.sorted_ids))
            )
        var op = AsyncReassignOp[Self.Storage](
            self._coord.clone_underlying_store(),
            self._coord.assignment_key(),
            prelude.sorted_ids.copy(),
            prelude.effective_p,
        )
        return _SuspendedFrame[BrokerHeartbeatSM[Self.Storage]](
            BrokerHeartbeatSM[Self.Storage].parkable(
                op^,
                prelude.node_id,
                prelude.endpoints.copy(),
                self._coord.cache_handle(),
                prelude.sorted_ids.copy(),
                prelude.effective_p,
                self._trace,
            ),
            request_id,
        )

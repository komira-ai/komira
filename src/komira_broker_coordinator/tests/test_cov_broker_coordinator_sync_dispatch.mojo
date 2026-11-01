# =============================================================================
# komira_broker_coordinator/tests/test_cov_broker_coordinator_sync_dispatch.mojo
#   The synchronous `BrokerCoordinatorDispatcher` (routing, the 400 / 404 /
#   405 / 500 replies and the protobuf 200), the JSON and protobuf response
#   helpers, the error-text sanitizer, the job-id guard, and the service's
#   serve step and accessors.
# =============================================================================
#
# The dispatcher runs over `_FaultStore` (a shared in-memory store whose
# conditional writes consult fault rules; see the handler test), so a write
# error reaches the 500 path. The service runs over the in-memory slow CAS
# store on an ephemeral loopback port.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_broker import (
    Assignment,
    ClusterAssignmentStore,
    REBALANCE_INITIAL,
    assign_partitions,
)
from komira_broker_coordinator import (
    BrokerCoordinatorDispatcher,
    BrokerCoordinatorService,
    BrokerHeartbeatCoordinator,
    json_response,
    proto_response,
)
from komira_broker_coordinator.broker_coordinator_service import (
    _is_meaningful_job_id,
    _sanitize,
)
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.server import HttpServerConfig
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)
from komira_proto_codec import decode_proto, encode_proto

from komira_supervisor_proto.supervisor import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    HeartbeatResponse as PbHeartbeatResponse,
    JobPhase as PbJobPhase,
)
from komira_broker_proto.broker import NodeLoad as PbNodeLoad


comptime _Rt = BlockingRuntime[NoopSink]
comptime _NIL = "00000000-0000-0000-0000-000000000000"


# =============================================================================
# §1 — the fault-injecting store (as in the handler test).
# =============================================================================
comptime _MODE_412 = 1
comptime _MODE_TRANSPORT = 2
comptime _MODE_RACE = 3
comptime _TOPIC = "example-data"
comptime _CLUSTER = "cl-cov"


def _fault_msg(mode: Int) -> String:
    if mode == _MODE_412:
        return String("HTTP 412 precondition failed (injected)")
    return String('injected "transport"\nfailure')


def _mk(name: String) raises -> Path:
    return Path.parse(String("faults/") + name)


def _u16(b: List[UInt8], at: Int) -> Int:
    return Int(b[at]) + 256 * Int(b[at + 1])


def _calls(m: SharedInMemoryConditionalStore, verb: String) raises -> Int:
    """How many times `verb` was called (0 when never)."""
    try:
        return _u16(m.get(_mk(String("n/") + verb)), 0)
    except e:
        _ = e
        return 0


def _arm(
    m: SharedInMemoryConditionalStore,
    verb: String,
    rule: Int,
    lo: Int,
    hi: Int,
    mode: Int,
) raises:
    """Fail calls `lo..hi` (1-based, inclusive) of `verb` with `mode`."""
    var spec = List[UInt8]()
    spec.append(UInt8(lo & 0xFF))
    spec.append(UInt8((lo >> 8) & 0xFF))
    spec.append(UInt8(hi & 0xFF))
    spec.append(UInt8((hi >> 8) & 0xFF))
    spec.append(UInt8(mode))
    _ = m.put(_mk(String("rule/") + verb + String("/") + String(rule)), spec)


def _next_mode(m: SharedInMemoryConditionalStore, verb: String) raises -> Int:
    """Count one call of `verb`; the mode of the first rule whose window
    holds it, or -1."""
    var n = _calls(m, verb) + 1
    var c = List[UInt8]()
    c.append(UInt8(n & 0xFF))
    c.append(UInt8((n >> 8) & 0xFF))
    _ = m.put(_mk(String("n/") + verb), c)
    for r in range(2):
        var spec: List[UInt8]
        try:
            spec = m.get(_mk(String("rule/") + verb + String("/") + String(r)))
        except e:
            _ = e
            continue
        if n >= _u16(spec, 0) and n <= _u16(spec, 2):
            return Int(spec[4])
    return -1


def _racer_body() raises -> List[UInt8]:
    """A valid assignment a concurrent coordinator wrote: node 9 owns all."""
    var ids = List[String]()
    ids.append(String("9"))
    return assign_partitions(
        ids^, 6, Optional[Assignment](), REBALANCE_INITIAL
    ).encode_binary()


struct _FaultStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemoryConditionalStore
    var _m: SharedInMemoryConditionalStore

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var markers: SharedInMemoryConditionalStore,
    ):
        self._inner = inner^
        self._m = markers^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._m.clone())

    def _write_fault(self, path: Path) raises:
        var mode = _next_mode(self._m, String("put"))
        if mode == _MODE_412 or mode == _MODE_TRANSPORT:
            raise Error(_fault_msg(mode))
        if mode == _MODE_RACE:
            _ = self._inner.put(path, _racer_body())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._write_fault(path)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._write_fault(path)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


# =============================================================================
# §2 — builders.
# =============================================================================
def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _dispatcher(
    faults: SharedInMemoryConditionalStore,
) raises -> BrokerCoordinatorDispatcher[_FaultStore]:
    var store = ClusterAssignmentStore[_FaultStore](
        _FaultStore(SharedInMemoryConditionalStore(), faults.clone()),
        String(_CLUSTER),
    )
    var coord = BrokerHeartbeatCoordinator[_FaultStore](
        store^, String(_CLUSTER), String(_TOPIC), 6
    )
    return BrokerCoordinatorDispatcher[_FaultStore](coord^)


def _hb(job_id: String, node_id: Optional[String]) -> PbSupervisorHeartbeat:
    var load = PbNodeLoad(UInt64(0), UInt32(0), Optional[UInt32]())
    return PbSupervisorHeartbeat(
        job_id,
        PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING),
        String("pod"),
        None,
        None,
        None,
        node_id,
        Optional[PbNodeLoad](load^),
        List[UInt32](),
        Optional[String](String("broker.example.test")),
        Optional[UInt32](UInt32(9092)),
    )


def _req(method: HttpMethod, path: String) -> HttpRequest:
    var req = HttpRequest()
    req.method = method
    req.path = path
    return req^


def _hb_req(job_id: String, node_id: Optional[String]) raises -> HttpRequest:
    var req = _req(HttpMethod.post(), String("/internal/heartbeat"))
    req.body = encode_proto[PbSupervisorHeartbeat](_hb(job_id, node_id))
    return req^


def _text(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


def _send(
    mut d: BrokerCoordinatorDispatcher[_FaultStore],
    mut reactor: Reactor[NoopSink],
    var req: HttpRequest,
) raises -> HttpResponse:
    return d.dispatch[_Rt](reactor, req^)


# =============================================================================
# §3 — routing of the synchronous dispatcher.
# =============================================================================
def test_health_and_route_misses() raises:
    """GET /health is 200 JSON; the two known paths under another method are
    405; any other path is 404."""
    var reactor = _new_reactor()
    var d = _dispatcher(SharedInMemoryConditionalStore())
    var h = _send(d, reactor, _req(HttpMethod.get(), String("/health")))
    assert_equal(h.status, Int32(200), "health 200")
    assert_equal(_text(h.body), String('{"status":"ok"}'), "health body")
    assert_equal(h.headers[String("content-type")], String("application/json"))
    assert_equal(h.headers[String("content-length")], String("15"))

    var r1 = _send(d, reactor, _req(HttpMethod.post(), String("/health")))
    assert_equal(r1.status, Int32(405), "POST /health is 405")
    var r2 = _send(
        d, reactor, _req(HttpMethod.get(), String("/internal/heartbeat"))
    )
    assert_equal(r2.status, Int32(405), "GET /internal/heartbeat is 405")
    var r3 = _send(d, reactor, _req(HttpMethod.get(), String("/nope")))
    assert_equal(r3.status, Int32(404), "unknown path is 404")
    var r4 = _send(d, reactor, _req(HttpMethod.post(), String("/healthz")))
    assert_equal(r4.status, Int32(404), "a longer path is no match")
    print("  test_health_and_route_misses: PASS")


def test_heartbeat_rejections() raises:
    """A body that is no protobuf, a heartbeat without node_id, and one with
    both a node_id and a real job_id are 400; with no node_id AND a real
    job_id the node_id reason (checked first) is the one reported."""
    var reactor = _new_reactor()
    var d = _dispatcher(SharedInMemoryConditionalStore())
    var bad = _req(HttpMethod.post(), String("/internal/heartbeat"))
    for _ in range(3):
        bad.body.append(UInt8(0xFF))
    var r0 = _send(d, reactor, bad^)
    assert_equal(r0.status, Int32(400), "undecodable body is 400")
    assert_true(
        _text(r0.body).startswith('{"error":"bad_request","message":"'),
        "bad_request body: " + _text(r0.body),
    )

    var r1 = _send(d, reactor, _hb_req(String(_NIL), Optional[String]()))
    assert_equal(r1.status, Int32(400), "no node_id is 400")
    assert_true(_text(r1.body).find("node_id required") >= 0, "node reason")

    var r2 = _send(
        d, reactor, _hb_req(String("job-17"), Optional[String](String("1")))
    )
    assert_equal(r2.status, Int32(400), "node_id + job_id is 400")
    assert_true(_text(r2.body).find("cross-leg") >= 0, "cross-leg reason")

    var r3 = _send(d, reactor, _hb_req(String("job-17"), Optional[String]()))
    assert_equal(r3.status, Int32(400), "both faults: 400")
    assert_true(
        _text(r3.body).find("node_id required") >= 0,
        "the node_id check runs before the job_id check",
    )
    assert_equal(
        d.coordinator().store_recompute_count(), 0, "no rejection reassigned"
    )
    print("  test_heartbeat_rejections: PASS")


def test_heartbeat_200_protobuf_reply() raises:
    """A broker heartbeat with the nil job_id, or an empty one, is served:
    200, application/protobuf, the body is the encoded HeartbeatResponse."""
    var reactor = _new_reactor()
    var d = _dispatcher(SharedInMemoryConditionalStore())
    var r = _send(
        d, reactor, _hb_req(String(_NIL), Optional[String](String("1")))
    )
    assert_equal(r.status, Int32(200), "served")
    assert_equal(
        r.headers[String("content-type")], String("application/protobuf")
    )
    assert_equal(r.headers[String("content-length")], String(len(r.body)))
    var resp = decode_proto[PbHeartbeatResponse](r.body.copy())
    assert_equal(len(resp.assigned_partitions), 6, "lone node owns all six")
    assert_false(resp.cancel, "never cancelled")

    var e = _send(d, reactor, _hb_req(String(""), Optional[String](String("2"))))
    assert_equal(e.status, Int32(200), "an empty job_id is no job identity")
    var resp2 = decode_proto[PbHeartbeatResponse](e.body.copy())
    assert_equal(len(resp2.assigned_partitions), 3, "node 2 gets half")
    print("  test_heartbeat_200_protobuf_reply: PASS")


def test_store_error_is_500_with_sanitized_text() raises:
    """A write error from the store is a 500 whose message is the error text
    with its quotes and newline replaced by spaces."""
    var reactor = _new_reactor()
    var faults = SharedInMemoryConditionalStore()
    _arm(faults, String("put"), 0, 1, 1, _MODE_TRANSPORT)
    var d = _dispatcher(faults)
    var r = _send(
        d, reactor, _hb_req(String(_NIL), Optional[String](String("1")))
    )
    assert_equal(r.status, Int32(500), "store error is 500")
    assert_equal(
        _text(r.body),
        String(
            '{"error":"assignment_failed","message":"injected  transport '
            ' failure"}'
        ),
        "sanitized message",
    )
    assert_equal(r.headers[String("content-type")], String("application/json"))
    print("  test_store_error_is_500_with_sanitized_text: PASS")


# =============================================================================
# §4 — the helpers.
# =============================================================================
def test_sanitize_and_job_id_guard() raises:
    assert_equal(
        _sanitize(String('a"b\\c\nd\re')), String("a b c d e"), "each replaced"
    )
    assert_equal(
        _sanitize(String("plain ASCII: 0-9 {x} 'y'")),
        String("plain ASCII: 0-9 {x} 'y'"),
        "other bytes kept",
    )
    assert_equal(_sanitize(String("")), String(""), "empty")
    assert_false(_is_meaningful_job_id(String("")), "empty job_id")
    assert_false(_is_meaningful_job_id(String(_NIL)), "nil UUID")
    assert_true(_is_meaningful_job_id(String("j")), "any other text")
    assert_true(
        _is_meaningful_job_id(String("00000000-0000-0000-0000-000000000001")),
        "one digit off the nil UUID",
    )
    print("  test_sanitize_and_job_id_guard: PASS")


def test_response_helpers() raises:
    var body = List[UInt8]()
    body.append(UInt8(0x08))
    body.append(UInt8(0x00))
    body.append(UInt8(0xFF))
    var p = proto_response(Int32(201), body.copy())
    assert_equal(p.status, Int32(201), "status kept")
    assert_equal(p.headers[String("content-type")], String("application/protobuf"))
    assert_equal(p.headers[String("content-length")], String("3"))
    assert_equal(len(p.body), 3, "body verbatim")
    assert_equal(p.body[2], UInt8(0xFF), "binary byte kept")
    var j = json_response(Int32(418), String("{}"))
    assert_equal(j.status, Int32(418), "status kept")
    assert_equal(j.headers[String("content-length")], String("2"))
    assert_equal(_text(j.body), String("{}"), "body")
    print("  test_response_helpers: PASS")


# =============================================================================
# §5 — the service's serve step and accessors.
# =============================================================================
comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1


def _connect_loopback(port: UInt16) raises -> Int32:
    var fd = external_call["socket", Int32](_AF_INET, _SOCK_STREAM, Int32(0))
    if fd < Int32(0):
        raise Error("test: socket() failed")
    var addr = InlineArray[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[7] = UInt8(1)
    # SAFETY: connect(2) reads the 16-byte local during the call only.
    var rc = external_call["connect", Int32](
        fd, UnsafePointer(to=addr).bitcast[UInt8](), UInt32(16)
    )
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: connect() failed")
    return fd


def _service(trace: Bool) raises -> BrokerCoordinatorService[
    SharedInMemorySlowCasStore
]:
    var store = ClusterAssignmentStore[SharedInMemorySlowCasStore](
        SharedInMemorySlowCasStore(), String(_CLUSTER)
    )
    var coord = BrokerHeartbeatCoordinator[SharedInMemorySlowCasStore](
        store^, String(_CLUSTER), String(_TOPIC), 6
    )
    return BrokerCoordinatorService[SharedInMemorySlowCasStore](
        coord^, HttpServerConfig.default_ephemeral(), trace
    )


def test_service_serve_step_accepts() raises:
    """`serve_step` drives the accept loop: a connected client becomes one
    live connection; the accessors reach the dispatcher and the driver."""
    var s = _service(False)
    assert_false(s.dispatcher().trace_enabled(), "trace off by default")
    assert_equal(s.live_conn_count(), 0, "no connection yet")
    var fd = _connect_loopback(s.local_port())
    var events = 0
    for _ in range(50):
        events += s.serve_step()
        if s.live_conn_count() == 1:
            break
    _ = external_call["close", Int32](fd)
    assert_equal(s.live_conn_count(), 1, "serve_step accepted the client")
    assert_true(events > 0, "the accept was an event")
    assert_equal(s.driver_ref().inflight_count(), 0, "nothing parked")
    assert_equal(
        s.dispatcher().coordinator().store_recompute_count(), 0, "no heartbeat"
    )
    var t = _service(True)
    assert_true(t.dispatcher().trace_enabled(), "trace switch carried")
    print("  test_service_serve_step_accepts: PASS")


def main() raises:
    print("test_cov_broker_coordinator_sync_dispatch")
    test_health_and_route_misses()
    test_heartbeat_rejections()
    test_heartbeat_200_protobuf_reply()
    test_store_error_is_500_with_sanitized_text()
    test_sanitize_and_job_id_guard()
    test_response_helpers()
    test_service_serve_step_accepts()
    print("ALL test_cov_broker_coordinator_sync_dispatch tests PASS")

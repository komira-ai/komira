# =============================================================================
# komira_broker_coord/tests/test_broker_coord_serve_stays_responsive.mojo
#   BROKER COORDINATOR serve responsiveness: the coordinator's parkable
#   suspendable serve loop stays responsive to a FRESH connect under SUSTAINED
#   heartbeat load; it does NOT wedge.
# =============================================================================
#
# WHY: a refused connect to the coordinator port is ambiguous. It can be a
# serve-loop stall, or it can be the CLIENT host running out of ephemeral ports
# (`EADDRNOTAVAIL`) because an S3 data plane that dials a fresh short-lived TCP
# connection per object-store op leaves thousands of sockets in TIME_WAIT. With
# every ephemeral port in TIME_WAIT, any new outbound connect() on the host
# fails, including heartbeats and client bootstraps, while the coordinator
# itself is healthy.
#
# THIS TEST separates the two: it drives a real `BrokerCoordinatorService`
# (over an in-memory CAS store, so there is NO host port exhaustion to confound
# the result) through MANY heartbeats and asserts that AFTER EACH BATCH a FRESH
# connection + `GET /health` is accepted and answered 200. If a change ever
# wedges the serve loop (a parked frame that never resumes, a synchronous
# blocking step on the heartbeat hot path, an accept starved by the poll loop,
# a conn/fd leak), the fresh `/health` connect hangs or is refused and this
# test fails.
#
# DETERMINISTIC (no object store, no network beyond same-host loopback): the
# serve loop is driven by `service.run_for(...)`; the libc client REUSES one
# connection per health check and closes it, so no TIME_WAIT storm builds up
# within the test.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget

from std.testing import assert_true

from komira_broker import ClusterAssignmentStore
from komira_broker_coord import BrokerHeartbeatCoordinator
from komira_broker_coord import BrokerCoordinatorService
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)

from komira_http import HttpServerConfig

from engine_rpc.engine import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    NodeLoad as PbNodeLoad,
    JobPhase as PbJobPhase,
)
from komira_proto_codec import encode_proto


comptime _Store = SharedInMemorySlowCasStore


# =============================================================================
# §1 — raw-socket libc client (the same-process harness shape, shared with
# test_broker_coord_store_raise_survives.mojo).
# =============================================================================
comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1


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


def _create_blocking_client_socket() raises -> Int32:
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0)
    )
    if fd < Int32(0):
        raise Error("test: socket() failed")
    return fd


def _connect_blocking(fd: Int32, port: UInt16) raises:
    var addr = _build_sockaddr_in_loopback(port)
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["connect", Int32](fd, addr_ptr, UInt32(16))
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: connect() failed")


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var total = len(bytes)
    var sent = 0
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), Int32(0)
        )
        if rc <= Int64(0):
            raise Error("test: send() failed")
        sent = sent + Int(rc)


def _recv_some(fd: Int32, max_bytes: Int) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=max_bytes)
    var raw = buf.unsafe_ptr()
    var n = external_call["recv", Int64](
        fd, raw, UInt64(max_bytes), Int32(0)
    )
    if n < Int64(0):
        raise Error("test: recv() failed")
    var out = List[UInt8]()
    var i = 0
    while i < Int(n):
        out.append(buf[i])
        i = i + 1
    return out^


def _close_socket(fd: Int32):
    _ = external_call["close", Int32](fd)


def _bytes_contain(haystack: List[UInt8], needle: String) -> Bool:
    var nbytes = needle.as_bytes()
    var hn = len(haystack)
    var nn = len(nbytes)
    if nn == 0 or nn > hn:
        return nn == 0
    var i = 0
    while i + nn <= hn:
        var matched = True
        var j = 0
        while j < nn:
            if haystack[i + j] != nbytes[j]:
                matched = False
                break
            j = j + 1
        if matched:
            return True
        i = i + 1
    return False


# =============================================================================
# §2 — request builders (a protobuf heartbeat + a GET /health).
# =============================================================================
def _hb(node_id: String) -> PbSupervisorHeartbeat:
    var load = PbNodeLoad(UInt64(0), UInt32(0), Optional[UInt32]())
    return PbSupervisorHeartbeat(
        String("00000000-0000-0000-0000-000000000000"),  # job_id (nil)
        PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING),
        String("broker-node-") + node_id,
        None,
        None,
        None,
        Optional[String](String(node_id)),  # node_id
        Optional[PbNodeLoad](load^),
        List[UInt32](),
        Optional[String](String("127.0.0.1")),
        Optional[UInt32](UInt32(9092)),
    )


def _heartbeat_request(node_id: String) raises -> List[UInt8]:
    var body = encode_proto[PbSupervisorHeartbeat](_hb(node_id))
    var head = String("POST /internal/heartbeat HTTP/1.1\r\n")
    head += String("Host: localhost\r\n")
    head += String("Content-Type: application/protobuf\r\n")
    head += String("Content-Length: ") + String(len(body)) + String("\r\n")
    head += String("\r\n")
    var out = List[UInt8]()
    var hb = head.as_bytes()
    for i in range(len(hb)):
        out.append(hb[i])
    for i in range(len(body)):
        out.append(body[i])
    return out^


def _health_request() -> List[UInt8]:
    var s = String("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
    var bytes = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


# =============================================================================
# §3 — build the coordinator service over a FAST, non-raising in-memory store.
# =============================================================================
def _service() raises -> BrokerCoordinatorService[_Store]:
    var store = ClusterAssignmentStore[_Store](
        _Store(slow_ticks=0, raise_on_read_start=False),
        String("cl-responsive"),
    )
    var coord = BrokerHeartbeatCoordinator[_Store](
        store^, String("cl-responsive"), String("example-data"), 6
    )
    return BrokerCoordinatorService[_Store](
        coord^, HttpServerConfig.default_ephemeral()
    )


def _one_heartbeat(mut service: BrokerCoordinatorService[_Store], node: String) raises:
    """Drive ONE broker heartbeat (POST /internal/heartbeat) through the real
    serve loop: connect, drive accept, send, drive the round-trip (the first per
    membership change parks on the in-mem CAS; subsequent same-set heartbeats are
    coalesce HITS), then close."""
    var c = _create_blocking_client_socket()
    _connect_blocking(c, service.local_port())
    service.run_for(6, Int32(300_000))
    _send_all(c, _heartbeat_request(node))
    service.run_for(12, Int32(50_000))
    # Drain whatever response landed (best-effort; the assertion target is the
    # FRESH-CONNECT health check below, not this heartbeat's body).
    _ = _recv_some(c, 1024)
    _close_socket(c)


def _assert_fresh_health_ok(
    mut service: BrokerCoordinatorService[_Store], round: Int
) raises:
    """The CORE liveness assertion: a BRAND-NEW connection + GET /health is
    ACCEPTED and answered 200. This is the deterministic analog of an
    external liveness probe — if the serve loop ever wedged (a parked frame that never
    resumes, a blocking step, accept starvation, a conn/fd leak), this fresh
    connect would hang or fail to be served."""
    var c = _create_blocking_client_socket()
    _connect_blocking(c, service.local_port())
    service.run_for(6, Int32(300_000))
    _send_all(c, _health_request())
    service.run_for(10, Int32(50_000))
    var resp = _recv_some(c, 512)
    _close_socket(c)
    assert_true(
        _bytes_contain(resp, String("HTTP/1.1 200")),
        String(
            "round "
        )
        + String(round)
        + String(
            ": a FRESH connect + GET /health returned 200 — the coordinator"
            " serve loop is STILL responsive after sustained heartbeat load"
            " (it did NOT wedge)"
        ),
    )


# =============================================================================
# TEST — the serve loop stays responsive to a fresh connect across MANY
# heartbeats (the dominant steady-state path is coalesce HITS that never park).
# =============================================================================
def test_serve_stays_responsive_under_sustained_heartbeats() raises:
    var service = _service()
    var port = service.local_port()
    assert_true(Int(port) > 0, "coordinator bound an ephemeral port")

    # Establish the membership (node 1) — the FIRST heartbeat is a membership
    # change that drives the parkable reassign; it must complete + leave the
    # serve loop responsive.
    _one_heartbeat(service, String("1"))
    _assert_fresh_health_ok(service, 0)

    # SUSTAINED LOAD: 30 steady-state heartbeats from the SAME node (each a
    # store-free coalesce HIT — the dominant production path). After every 5th
    # heartbeat, assert a FRESH connect + /health is still accepted + 200. A
    # serve-loop wedge would surface as a hung/failed fresh connect here.
    var r = 1
    var i = 0
    while i < 30:
        _one_heartbeat(service, String("1"))
        i = i + 1
        if (i % 5) == 0:
            _assert_fresh_health_ok(service, r)
            r = r + 1

    # MEMBERSHIP CHURN: add + drop nodes to drive several genuine reassigns
    # (the parkable path) interleaved with the responsiveness check — the
    # rebalance-burst boundary. Each reassign must leave the
    # serve loop responsive.
    _one_heartbeat(service, String("2"))  # membership change -> reassign
    _assert_fresh_health_ok(service, r)
    r = r + 1
    _one_heartbeat(service, String("3"))  # membership change -> reassign
    _assert_fresh_health_ok(service, r)
    r = r + 1
    _one_heartbeat(service, String("2"))  # coalesce hit (set {1,2,3} unchanged)
    _one_heartbeat(service, String("3"))
    _assert_fresh_health_ok(service, r)

    _ = service^
    print(
        "  test_serve_stays_responsive_under_sustained_heartbeats: PASS"
        " (fresh /health 200 after every batch — no coordinator serve-loop"
        " stall)"
    )


def main() raises:
    print(
        "test_broker_coord_serve_stays_responsive — the coordinator serve loop"
        " stays responsive to a fresh connect under sustained heartbeat load"
        " (no serve-loop stall)"
    )
    test_serve_stays_responsive_under_sustained_heartbeats()
    print("ALL test_broker_coord_serve_stays_responsive tests PASS")

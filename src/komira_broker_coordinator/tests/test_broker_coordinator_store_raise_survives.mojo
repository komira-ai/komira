# =============================================================================
# komira_broker_coordinator/tests/test_broker_coordinator_store_raise_survives.mojo
#   BROKER COORDINATOR process survival: a store verb that RAISES during a
#   parkable reassign must NOT crash the coordinator process.
# =============================================================================
#
# THE HAZARD: in the parkable path the first reassign heartbeat issues a
# non-blocking object-store GET via the handler's `step()`, which runs inside
# `SuspendableHandlerDriver.admit`. When the object store is transiently
# unreachable, the S3 conformer RAISES (`TcpStream.connect: connect failed`)
# rather than returning a `CasOpProgress.error`. Unless the serve loop catches
# it, that raise propagates out of `serve_step`, out of
# `run_coordinator_forever`, out of `main()`, and kills the whole coordinator.
#
# THE CONTRACT: `serve_read_round_suspendable` wraps `driver.admit` in
# try/except — a handler-step raise drops THIS conn defensively (the peer
# retries next heartbeat tick) and the serve loop SURVIVES to serve every other
# connection. A transient store blip must never be fatal.
#
# THE TEST (deterministic — no object store; the raise is FORCED by a store
# knob): build a real `BrokerCoordinatorService` over a
# `SharedInMemorySlowCasStore` whose `read_start` RAISES (the in-memory analog
# of a refused S3 connect), bind it on an ephemeral port, and drive a REAL libc
# client heartbeat through the actual serve loop. The first heartbeat is a
# membership change -> a parkable reassign -> `read_start` raises inside
# `admit`.
#   Without the catch: `service.run_for(...)` re-raises and the test's `main()`
#                   aborts.
#   With it:        `run_for` returns normally (the conn was dropped); the
#                   listener is STILL ALIVE — a fresh `GET /health` returns 200.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget

from std.testing import assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink

from komira_broker import ClusterAssignmentStore
from komira_broker_coordinator import BrokerHeartbeatCoordinator
from komira_broker_coordinator import BrokerCoordinatorService
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)

from komira_http_server.server import HttpServerConfig

from komira_supervisor_proto.supervisor import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    JobPhase as PbJobPhase,
)
from komira_broker_proto.broker import (
    NodeLoad as PbNodeLoad,
)
from komira_proto_codec import encode_proto


comptime _Store = SharedInMemorySlowCasStore


# =============================================================================
# §1 — raw-socket libc client (the proven same-process harness shape).
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
    """A POST /internal/heartbeat HTTP/1.1 request carrying the protobuf-binary
    SupervisorHeartbeat body (the wire shape the coordinator decodes)."""
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
# §3 — build the coordinator service over the RAISING store.
# =============================================================================
def _service(raise_on_read_start: Bool) raises -> BrokerCoordinatorService[
    _Store
]:
    var store = ClusterAssignmentStore[_Store](
        _Store(slow_ticks=0, raise_on_read_start=raise_on_read_start),
        String("cl-raise-survive"),
    )
    var coord = BrokerHeartbeatCoordinator[_Store](
        store^, String("cl-raise-survive"), String("example-data"), 6
    )
    return BrokerCoordinatorService[_Store](
        coord^, HttpServerConfig.default_ephemeral()
    )


# =============================================================================
# TEST — a store-verb RAISE during a parkable reassign does NOT crash the serve.
# =============================================================================
def test_store_raise_does_not_crash_serve() raises:
    var service = _service(raise_on_read_start=True)
    var port = service.local_port()
    assert_true(Int(port) > 0, "coordinator bound an ephemeral port")

    # ── Send the FIRST heartbeat (a membership change -> a parkable reassign ->
    # the store's read_start RAISES inside driver.admit). Without the catch,
    # run_for re-raises and this test's main() aborts (the process crash).
    # With it, serve_read_round_suspendable catches the raise, drops the conn, and
    # run_for returns normally.
    var c1 = _create_blocking_client_socket()
    _connect_blocking(c1, port)
    service.run_for(6, Int32(300_000))  # drive accept
    _send_all(c1, _heartbeat_request(String("1")))
    # THE PROCESS-SURVIVAL ASSERTION: this call must NOT propagate a raise. If
    # the catch is absent the store's connect-refused raise escapes here and the
    # test crashes, exactly as the coordinator process would.
    service.run_for(10, Int32(50_000))
    _close_socket(c1)

    # ── THE LISTENER IS STILL ALIVE: a FRESH connection + GET /health gets a
    # 200. (A health request never touches the store, so it is served even with
    # the store wedged-raising — proving the serve loop survived the prior raise
    # rather than the process having died.)
    var c2 = _create_blocking_client_socket()
    _connect_blocking(c2, port)
    service.run_for(6, Int32(300_000))
    _send_all(c2, _health_request())
    service.run_for(10, Int32(50_000))
    var resp = _recv_some(c2, 512)
    _close_socket(c2)

    assert_true(
        len(resp) > 0,
        "the coordinator is STILL serving after a store-verb raise (it did NOT"
        " crash) — a fresh /health returned bytes",
    )
    assert_true(
        _bytes_contain(resp, String("HTTP/1.1 200")),
        "the post-raise /health returned 200 — the serve loop survived the"
        " transient store-verb raise",
    )
    _ = service^
    print("  test_store_raise_does_not_crash_serve: PASS")


def main() raises:
    print(
        "test_broker_coordinator_store_raise_survives — a parkable"
        " store-verb raise"
        " must NOT crash the coordinator"
    )
    test_store_raise_does_not_crash_serve()
    print("ALL test_broker_coordinator_store_raise_survives tests PASS")

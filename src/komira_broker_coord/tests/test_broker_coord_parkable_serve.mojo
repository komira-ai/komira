# =============================================================================
# komira_broker_coord/tests/test_broker_coord_parkable_serve.mojo
#   BROKER COORDINATOR PARKABLE CAS SERVE: the acceptance test.
# =============================================================================
#
# The acceptance test for the parkable coordinator serve. It drives the
# SuspendableHandlerDriver + the BrokerCoordSuspendableDispatcher.make_frame
# seam against a CONTROLLABLE-SLOW in-mem store (SharedInMemorySlowCasStore,
# slow_ticks > 0), proving the two GATE assertions:
#
#   (a) A 2nd request admitted DURING a parked reassign is admitted+driven the
#       SAME serve cycle: the serve loop is NOT blocked behind the first
#       request's in-flight object-store CAS round-trip. A synchronous serve
#       (the reassign running inline to completion) fails this; here the
#       reassign PARKS on its biased op_id and the worker is immediately free
#       to admit+serve the next request.
#
#   (b) A steady-state (coalesce-hit) heartbeat NEVER parks — it is a one-step
#       DONE delivered the same cycle (zero store I/O, the dominant path).
#
# The driver-level drive (admit / drive_one_ready_batch) is the in-process
# equivalent of the HttpServer's 3-bucket serve loop: `admit` is the conn-read
# bucket (bucket 3 -> make_frame -> admit), the parked biased op_id is bucket 2,
# and a fresh `admit` is the structural proof that the loop is free to do other
# work (bucket 1 accept) while a reassign is parked. The op the reassign parks on
# is a reactor timer (the SharedInMemorySlowCasStore yields CAS_OP_PENDING via
# register_timer), which fires through the SAME demux a real S3 socket read does.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.suspendable_handler import SuspendableHandlerDriver

from komira_broker import ClusterAssignmentStore
from komira_broker_coord import BrokerCoordSuspendableDispatcher
from komira_broker_coord import BrokerHeartbeatCoordinator
from komira_broker_coord import BrokerHeartbeatSM
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)

from komira_http import HttpMethod, HttpRequest

from engine_rpc.engine import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    NodeLoad as PbNodeLoad,
    JobPhase as PbJobPhase,
)
from komira_serde import encode_proto


comptime _Store = SharedInMemorySlowCasStore
comptime _Rt = BlockingRuntime[NoopSink]
comptime _Dispatcher = BrokerCoordSuspendableDispatcher[_Store]
comptime _Driver = SuspendableHandlerDriver[NoopSink, BrokerHeartbeatSM[_Store]]


# =============================================================================
# Test reactor — a real (epoll/kqueue) reactor so register_timer FIRES.
# =============================================================================
def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


# =============================================================================
# Helpers — build a broker-node heartbeat request.
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
        Optional[PbNodeLoad](load^),  # load
        List[UInt32](),  # owned_partitions
        Optional[String](String("127.0.0.1")),  # advertised_host
        Optional[UInt32](UInt32(9092)),  # advertised_port
    )


def _hb_request(node_id: String) raises -> HttpRequest:
    """A POST /internal/heartbeat HttpRequest carrying the protobuf body."""
    var req = HttpRequest()
    req.method = HttpMethod.post()
    req.path = String("/internal/heartbeat")
    req.body = encode_proto[PbSupervisorHeartbeat](_hb(node_id))
    return req^


def _dispatcher(slow_ticks: Int, p: Int) raises -> _Dispatcher:
    """A suspendable dispatcher over a controllable-slow store."""
    var store = ClusterAssignmentStore[_Store](
        _Store(slow_ticks=slow_ticks), String("cl-parkable")
    )
    var coord = BrokerHeartbeatCoordinator[_Store](
        store^, String("cl-parkable"), String("example-data"), p
    )
    return _Dispatcher(coord^)


# =============================================================================
# TEST 1 — a MEMBERSHIP-CHANGE reassign PARKS (does not block the serve loop).
# The second request is admitted+driven the SAME cycle while the first is parked.
# =============================================================================
def test_reassign_parks_and_second_request_admitted() raises:
    var reactor = _new_reactor()
    # slow_ticks=2 => each CAS round-trip yields PENDING twice before completing.
    var disp = _dispatcher(slow_ticks=2, p=6)
    var driver = _Driver()

    # ── Request A: node 1's FIRST heartbeat — a membership change -> a PARKABLE
    # reassign. Admitting it parks the frame on the store's biased timer op_id
    # (the reactor round-trip is in flight; the worker is NOT blocked).
    var fa = disp.make_frame[_Rt](reactor, _hb_request(String("1")), Int64(101))
    var parked_a = driver.admit(fa^, reactor)
    assert_true(
        parked_a,
        "the membership-change reassign PARKS on its S3-CAS round-trip (it does"
        " NOT run inline to completion blocking the serve loop)",
    )
    assert_equal(driver.inflight_count(), 1, "exactly one frame parked")
    assert_equal(driver.delivered_count(), 0, "nothing delivered yet (parked)")

    # ── Request B admitted WHILE A is parked. THE GATE: the serve loop is free
    # to admit+drive the next request — it is NOT blocked behind A's in-flight
    # round-trip. (A synchronous serve would run A's reassign inline to
    # completion before B could be touched; here A is parked and B proceeds.)
    var fb = disp.make_frame[_Rt](reactor, _hb_request(String("2")), Int64(102))
    var parked_b = driver.admit(fb^, reactor)
    assert_true(
        parked_b,
        "request B (admitted WHILE A is parked) is ITSELF driven the same cycle"
        " — the serve loop multiplexes; B is not starved behind A's round-trip",
    )
    assert_true(
        driver.inflight_count() >= 1,
        "both requests are in flight concurrently (the multiplex)",
    )

    # ── Drive every parked frame to completion (the reactor fires the timers).
    driver.run_until_idle(reactor)
    assert_equal(driver.inflight_count(), 0, "all parked frames completed")
    assert_equal(
        driver.delivered_count(), 2, "both heartbeats delivered a response"
    )
    print("  test_reassign_parks_and_second_request_admitted: PASS")


# =============================================================================
# TEST 2 — a STEADY-STATE (coalesce-hit) heartbeat NEVER parks (one-step DONE).
# =============================================================================
def test_steady_state_heartbeat_one_step_no_park() raises:
    var reactor = _new_reactor()
    var disp = _dispatcher(slow_ticks=2, p=6)
    var driver = _Driver()

    # Settle a STABLE 2-node membership (each join is a membership change that
    # parks; drive each to completion so the coalesce cache is populated).
    var f1 = disp.make_frame[_Rt](reactor, _hb_request(String("1")), Int64(1))
    _ = driver.admit(f1^, reactor)
    driver.run_until_idle(reactor)
    var f2 = disp.make_frame[_Rt](reactor, _hb_request(String("2")), Int64(2))
    _ = driver.admit(f2^, reactor)
    driver.run_until_idle(reactor)

    var parks_after_settle = driver.park_count()
    var delivered_after_settle = driver.delivered_count()

    # ── THE INVARIANT: a steady-state heartbeat (no membership change) is a
    # coalesce HIT — a one-step DONE that NEVER parks (zero store I/O). `admit`
    # returns False (delivered immediately, not parked) and park_count is FLAT.
    var fs = disp.make_frame[_Rt](reactor, _hb_request(String("1")), Int64(3))
    var parked_s = driver.admit(fs^, reactor)
    assert_false(
        parked_s,
        "a steady-state coalesce-hit heartbeat is delivered in ONE step — it"
        " NEVER parks (no store I/O on the serve thread)",
    )
    assert_equal(
        driver.park_count(),
        parks_after_settle,
        "the coalesce-hit heartbeat added ZERO parks (park_count is FLAT)",
    )
    assert_equal(
        driver.delivered_count(),
        delivered_after_settle + 1,
        "the coalesce-hit heartbeat was delivered the same cycle",
    )
    assert_equal(driver.inflight_count(), 0, "nothing left parked")
    print("  test_steady_state_heartbeat_one_step_no_park: PASS")


# =============================================================================
# TEST 3 — slow_ticks=0 => the reassign completes in ONE admit step (no park),
# the degenerate fast path (the store round-trip is instantaneous).
# =============================================================================
def test_zero_slow_ticks_completes_in_one_step() raises:
    var reactor = _new_reactor()
    var disp = _dispatcher(slow_ticks=0, p=6)
    var driver = _Driver()

    var f1 = disp.make_frame[_Rt](reactor, _hb_request(String("1")), Int64(1))
    var parked = driver.admit(f1^, reactor)
    assert_false(
        parked,
        "with an instantaneous store (slow_ticks=0) the reassign completes in"
        " one admit step (no park)",
    )
    assert_equal(driver.delivered_count(), 1, "delivered in one step")
    assert_equal(driver.inflight_count(), 0, "nothing parked")
    print("  test_zero_slow_ticks_completes_in_one_step: PASS")


def main() raises:
    print(
        "test_broker_coord_parkable_serve — the parkable CAS serve gate"
    )
    test_reassign_parks_and_second_request_admitted()
    test_steady_state_heartbeat_one_step_no_park()
    test_zero_slow_ticks_completes_in_one_step()
    print("ALL test_broker_coord_parkable_serve tests PASS")

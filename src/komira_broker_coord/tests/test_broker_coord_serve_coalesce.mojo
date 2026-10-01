# =============================================================================
# komira_broker_coord/tests/test_broker_coord_serve_coalesce.mojo
#   BROKER COORDINATOR serve-loop coalesce: the unit test.
# =============================================================================
#
# The in-memory store (SharedInMemoryConditionalStore) stands in for S3, and
# `store_recompute_count()` is the observability counter that must stay FLAT
# in steady state.
#
# THE HAZARD: `run_coordinator_forever` is a single-threaded BLOCKING reactor.
# The store I/O (read_assignment + the CAS write) runs INLINE on the serve
# thread. Recomputing on EVERY heartbeat would, under a rebalance burst, block
# the listener long enough that heartbeats are refused -> the stale window
# evicts "missing" nodes -> the cluster map flaps.
#
# THE DESIGN (cache + coalesce): cache the last computed Assignment + the
# membership it was computed for. A no-membership-change heartbeat replies FROM
# CACHE with ZERO store I/O; the recompute (`reassign`) runs ONLY on a real
# membership change, so there is no per-heartbeat object-store round trip.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_broker import ClusterAssignmentStore
from komira_broker_coord import BrokerHeartbeatCoordinator
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from engine_rpc.engine import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    HeartbeatResponse as PbHeartbeatResponse,
    NodeLoad as PbNodeLoad,
    JobPhase as PbJobPhase,
)


comptime _Store = SharedInMemoryConditionalStore


def _coord(
    cluster: String, topic: String, p: Int, stale_us: Int64 = Int64(15_000_000)
) raises -> BrokerHeartbeatCoordinator[_Store]:
    var store = ClusterAssignmentStore[_Store](_Store(), cluster)
    return BrokerHeartbeatCoordinator[_Store](
        store^, cluster, topic, p, stale_threshold_us=stale_us
    )


# =============================================================================
# _hb — build a minimal broker-node heartbeat for `node_id` (the broker fields).
# =============================================================================
def _hb(node_id: String) -> PbSupervisorHeartbeat:
    var load = PbNodeLoad(
        UInt64(0),  # records_served (soft-advisory)
        UInt32(0),  # partition_count
        Optional[UInt32](),  # reported_partition_total (NOT reported)
    )
    return PbSupervisorHeartbeat(
        String("00000000-0000-0000-0000-000000000000"),  # job_id (nil)
        PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING),  # phase
        String("broker-node-") + node_id,  # pod_name (nominal)
        None,  # progress
        None,  # message
        None,  # failure
        Optional[String](String(node_id)),  # node_id (field 7)
        Optional[PbNodeLoad](load^),  # load (field 8)
        List[UInt32](),  # owned_partitions (field 9) — none
        Optional[String](String("127.0.0.1")),  # advertised_host (#10)
        Optional[UInt32](UInt32(9092)),  # advertised_port (#11)
    )


def _assigned_count(resp: PbHeartbeatResponse) -> Int:
    """How many partitions the reply assigned to the responding node."""
    return len(resp.assigned_partitions)


# =============================================================================
# TEST 1 — a STEADY-STATE heartbeat performs ZERO store recomputes.
# =============================================================================
def test_steady_state_heartbeat_zero_store() raises:
    var coord = _coord(String("cl-coalesce"), String("example-data"), 6)

    var now = Int64(1_000_000_000)

    # Bring the cluster to a STABLE 2-node membership.
    _ = coord.handle_broker_heartbeat(_hb(String("1")), now)
    now += Int64(100_000)
    _ = coord.handle_broker_heartbeat(_hb(String("2")), now)

    var recomputes_after_join = coord.store_recompute_count()
    assert_true(
        recomputes_after_join >= 1,
        "a node join must have triggered at least one store recompute",
    )

    # ── THE INVARIANT ── steady-state heartbeats (no membership change) -> ZERO
    # new store recomputes -> the serve thread does no store I/O -> the reactor
    # stays responsive to accept() (accept-not-starved).
    var steady_rounds = 8
    for _ in range(steady_rounds):
        now += Int64(100_000)
        _ = coord.handle_broker_heartbeat(_hb(String("1")), now)
        now += Int64(100_000)
        _ = coord.handle_broker_heartbeat(_hb(String("2")), now)

    assert_equal(
        coord.store_recompute_count(),
        recomputes_after_join,
        (
            "STEADY-STATE heartbeats must perform ZERO additional store"
            " recomputes (the serve thread must not block the reactor on a"
            " no-membership-change heartbeat) — count must be FLAT"
        ),
    )

    # The steady-state reply is still CORRECT: 2 nodes over 6 partitions -> each
    # owns 3 (served from cache, with no store I/O).
    now += Int64(100_000)
    var r1 = coord.handle_broker_heartbeat(_hb(String("1")), now)
    assert_equal(
        _assigned_count(r1), 3, "cached reply: node 1 owns 3 of 6 partitions"
    )
    assert_equal(
        coord.store_recompute_count(),
        recomputes_after_join,
        "the correctness-check heartbeat is also cache-served (still flat)",
    )
    print("  test_steady_state_heartbeat_zero_store: PASS")


# =============================================================================
# TEST 2 — a MEMBERSHIP CHANGE still recomputes (the cache must not break
# correctness): a 3rd node joining and a node going stale-evicted each trigger
# exactly one recompute, and the assignment reflows.
# =============================================================================
def test_membership_change_recomputes() raises:
    var coord = _coord(
        String("cl-change"),
        String("example-data"),
        6,
        stale_us=Int64(1_000_000),
    )

    var now = Int64(2_000_000_000)

    # Settle a stable 2-node membership.
    _ = coord.handle_broker_heartbeat(_hb(String("1")), now)
    now += Int64(100_000)
    _ = coord.handle_broker_heartbeat(_hb(String("2")), now)
    now += Int64(100_000)
    _ = coord.handle_broker_heartbeat(_hb(String("1")), now)
    var before_join = coord.store_recompute_count()

    # ── NEW NODE joins -> exactly one recompute, spread reflows to 2-per-node.
    now += Int64(100_000)
    var rj = coord.handle_broker_heartbeat(_hb(String("3")), now)
    assert_equal(
        coord.store_recompute_count(),
        before_join + 1,
        "a NEW node joining must trigger exactly one store recompute",
    )
    assert_equal(
        _assigned_count(rj), 2, "after join: node 3 owns 2 of 6 partitions"
    )
    assert_true(
        Bool(rj.cluster) and rj.cluster.value().node_count == UInt32(3),
        "after join: 3 live nodes",
    )

    # A steady-state round at the new 3-node membership (no change -> no recompute).
    now += Int64(100_000)
    _ = coord.handle_broker_heartbeat(_hb(String("1")), now)
    now += Int64(100_000)
    _ = coord.handle_broker_heartbeat(_hb(String("2")), now)
    var before_evict = coord.store_recompute_count()
    assert_equal(
        before_evict,
        before_join + 1,
        "steady 3-node heartbeats add no recompute (still cached)",
    )

    # ── STALE-EVICT: nodes 1 and 2 stop heartbeating; the clock advances past
    # the 1s stale window so {1,2} go stale. Membership shrinks -> exactly one
    # recompute, and node 3 now owns ALL 6 partitions.
    now += Int64(2_000_000)  # +2s — past the 1s stale window for nodes 1 & 2.
    var re = coord.handle_broker_heartbeat(_hb(String("3")), now)
    assert_equal(
        coord.store_recompute_count(),
        before_evict + 1,
        "a STALE-EVICT (membership shrank) must trigger exactly one recompute",
    )
    assert_equal(
        _assigned_count(re),
        6,
        "after stale-evict of nodes 1 & 2: node 3 is the sole owner of all 6",
    )
    assert_true(
        Bool(re.cluster) and re.cluster.value().node_count == UInt32(1),
        "after stale-evict: 1 live node",
    )
    print("  test_membership_change_recomputes: PASS")


# =============================================================================
# TEST 3 — coordinator RESTART recovers the persisted assignment from the store
# (the S3-CAS recovery path): a fresh coordinator over the SAME shared store
# reads the prior assignment on its first heartbeat (no placement lost).
# =============================================================================
def test_restart_recovers_from_store() raises:
    var base = SharedInMemoryConditionalStore()

    # Coordinator A settles a 2-node assignment, persisting it to the store.
    var store_a = ClusterAssignmentStore[_Store](base.clone(), String("cl-rec"))
    var coord_a = BrokerHeartbeatCoordinator[_Store](
        store_a^, String("cl-rec"), String("example-data"), 6
    )
    var now = Int64(3_000_000_000)
    _ = coord_a.handle_broker_heartbeat(_hb(String("1")), now)
    now += Int64(100_000)
    _ = coord_a.handle_broker_heartbeat(_hb(String("2")), now)

    # Record node 1's prior owned partitions (from coordinator A's assignment).
    var ra = coord_a.handle_broker_heartbeat(_hb(String("1")), now)
    var prior_node1 = List[UInt32]()
    for i in range(len(ra.assigned_partitions)):
        prior_node1.append(ra.assigned_partitions[i])
    assert_equal(len(prior_node1), 3, "node 1 owns 3 of 6 under coordinator A")

    # A FRESH coordinator B over the SAME shared store (a "restart" — empty
    # registry, cold cache). Both nodes re-heartbeat to B; B reads the persisted
    # prior on the first heartbeat, and the STICKY pass keeps each live node on
    # its prior partitions (recovery: node 1 keeps EXACTLY its prior 3, not a
    # from-scratch reshuffle).
    var store_b = ClusterAssignmentStore[_Store](base.clone(), String("cl-rec"))
    var coord_b = BrokerHeartbeatCoordinator[_Store](
        store_b^, String("cl-rec"), String("example-data"), 6
    )
    now += Int64(100_000)
    _ = coord_b.handle_broker_heartbeat(_hb(String("1")), now)
    now += Int64(100_000)
    var rb = coord_b.handle_broker_heartbeat(_hb(String("2")), now)
    # Node 2's heartbeat brings the membership back to {1,2}; node 1's prior
    # partitions are recovered from the store + kept by the sticky pass.
    now += Int64(100_000)
    var rb1 = coord_b.handle_broker_heartbeat(_hb(String("1")), now)
    var recovered_node1 = List[UInt32]()
    for i in range(len(rb1.assigned_partitions)):
        recovered_node1.append(rb1.assigned_partitions[i])
    assert_equal(
        len(recovered_node1),
        3,
        "after restart with both nodes live: node 1 recovers a 3-of-6 share",
    )
    # The recovered partitions are EXACTLY node 1's prior set (sticky recovery,
    # not a reshuffle) — order-sensitive equality of the ascending pid lists.
    for i in range(len(prior_node1)):
        assert_equal(
            recovered_node1[i],
            prior_node1[i],
            "node 1's recovered pid[" + String(i) + "] == its prior pid (sticky)",
        )
    print("  test_restart_recovers_from_store: PASS")


def main() raises:
    test_steady_state_heartbeat_zero_store()
    test_membership_change_recomputes()
    test_restart_recovers_from_store()
    print("ALL test_broker_coord_serve_coalesce tests PASS")

# =============================================================================
# komira_broker_coordinator/tests/test_broker_coordinator_heartbeat_relay_e2e.mojo
#   BROKER heartbeat-relay end-to-end, over the object-store CAS coordinator.
# =============================================================================
#
# The handler is synchronous (no [RT] parameter). The in-memory store
# (SharedInMemoryConditionalStore) stands in for S3; the restart phase uses a
# CLONED handle (shared map) to model recovery from the persisted store.
#
# Proves the heartbeat-relay control plane drives the assignment over the
# HEARTBEAT round-trip + the in-process BrokerNodeState relay, ENTIRELY in-process:
#   PHASE 1+2  EVEN-ASSIGN over the heartbeat round-trip + in-process apply.
#   PHASE 3    STALE-REASSIGN-NO-COPY (sticky/minimal-move; survivors keep theirs).
#   PHASE 4    COORDINATOR-RESTART-RECOVERS (store recovery: a fresh
#              coordinator over the SAME shared store reads the persisted prior).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_broker import ClusterAssignmentStore, BrokerNodeState
from komira_broker_coordinator import BrokerHeartbeatCoordinator
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_supervisor_proto.supervisor import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    HeartbeatResponse as PbHeartbeatResponse,
    JobPhase as PbJobPhase,
)
from komira_broker_proto.broker import (
    NodeLoad as PbNodeLoad,
)

comptime _Store = SharedInMemoryConditionalStore


def _coord(
    var cluster: String, p: Int, stale_us: Int64 = Int64(15_000_000)
) raises -> BrokerHeartbeatCoordinator[_Store]:
    var store = ClusterAssignmentStore[_Store](_Store(), cluster.copy())
    return BrokerHeartbeatCoordinator[_Store](
        store^, cluster^, String("example-data"), p, stale_threshold_us=stale_us
    )


# =============================================================================
# Helpers — build a broker-node heartbeat from a BrokerNodeState.
# =============================================================================
def _broker_heartbeat(
    node_id: String, node: BrokerNodeState
) -> PbSupervisorHeartbeat:
    var owned = node.owned_partitions()
    var load = PbNodeLoad(
        UInt64(0),
        UInt32(node.partition_count()),
        Optional[UInt32](),
    )
    return PbSupervisorHeartbeat(
        String("00000000-0000-0000-0000-000000000000"),  # job_id (nil)
        PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING),
        String("broker-node-") + node_id,
        None,
        None,
        None,
        Optional[String](String(node_id)),  # node_id (field 7)
        Optional[PbNodeLoad](load^),  # load (field 8)
        owned^,  # owned_partitions (field 9)
        Optional[String](String("127.0.0.1")),  # advertised_host (#10)
        Optional[UInt32](
            UInt32(9090 + Int(node_id.as_bytes()[node_id.byte_length() - 1] - UInt8(0x30)))
        ),
    )


def _mark_owned(mut covered: List[Bool], owned: List[UInt32]) raises:
    for i in range(len(owned)):
        var pid = Int(owned[i])
        assert_false(covered[pid], "partition owned by exactly one node")
        covered[pid] = True


def _apply_response(mut node: BrokerNodeState, resp: PbHeartbeatResponse) -> Int:
    var assigned = List[UInt32]()
    for i in range(len(resp.assigned_partitions)):
        assigned.append(resp.assigned_partitions[i])
    var delta = node.apply_assignment(assigned^)
    return len(delta.started)


# =============================================================================
# PHASE 1+2 — even-assign over the heartbeat round-trip + in-process apply.
# =============================================================================
def test_even_assign_and_inprocess_apply() raises:
    var coord = _coord(String("cl-even"), 6)

    var n1 = BrokerNodeState(String("1"))
    var n2 = BrokerNodeState(String("2"))
    var n3 = BrokerNodeState(String("3"))

    var now = Int64(1_000_000_000)

    var r1 = coord.handle_broker_heartbeat(_broker_heartbeat(String("1"), n1), now)
    _ = _apply_response(n1, r1)
    now += Int64(100_000)
    var r2 = coord.handle_broker_heartbeat(_broker_heartbeat(String("2"), n2), now)
    _ = _apply_response(n2, r2)
    now += Int64(100_000)
    var r3 = coord.handle_broker_heartbeat(_broker_heartbeat(String("3"), n3), now)
    _ = _apply_response(n3, r3)

    # Steady-state round so every node's reply reflects the full even spread.
    now += Int64(100_000)
    var s1 = coord.handle_broker_heartbeat(_broker_heartbeat(String("1"), n1), now)
    var started1 = _apply_response(n1, s1)
    now += Int64(100_000)
    var s2 = coord.handle_broker_heartbeat(_broker_heartbeat(String("2"), n2), now)
    var started2 = _apply_response(n2, s2)
    now += Int64(100_000)
    var s3 = coord.handle_broker_heartbeat(_broker_heartbeat(String("3"), n3), now)
    _ = _apply_response(n3, s3)

    assert_equal(len(s1.assigned_partitions), 2, "node 1 assigned 2 partitions")
    assert_equal(len(s2.assigned_partitions), 2, "node 2 assigned 2 partitions")
    assert_equal(len(s3.assigned_partitions), 2, "node 3 assigned 2 partitions")
    assert_true(Bool(s3.cluster), "cluster present in reply")
    assert_equal(s3.cluster.value().total_partitions, UInt32(6), "total P=6")
    assert_equal(s3.cluster.value().node_count, UInt32(3), "3 live nodes")

    var covered = List[Bool]()
    for _ in range(6):
        covered.append(False)
    _mark_owned(covered, n1.owned_partitions())
    _mark_owned(covered, n2.owned_partitions())
    _mark_owned(covered, n3.owned_partitions())
    for pid in range(6):
        assert_true(covered[pid], "partition " + String(pid) + " covered")
    assert_equal(n1.partition_count(), 2, "node 1 owns 2 after apply")
    assert_equal(n2.partition_count(), 2, "node 2 owns 2 after apply")
    assert_equal(n3.partition_count(), 2, "node 3 owns 2 after apply")

    assert_equal(started1, 0, "steady-state apply: node 1 starts nothing new")
    assert_equal(started2, 0, "steady-state apply: node 2 starts nothing new")

    # PHASE 1 (persistence) — the assignment is in the S3-CAS store.
    var persisted = coord.reassign(now + Int64(100_000))
    assert_equal(persisted.num_partitions, 6, "persisted P=6")
    assert_equal(persisted.count_for(String("1")), 2, "persisted node1=2")
    assert_equal(persisted.count_for(String("2")), 2, "persisted node2=2")
    assert_equal(persisted.count_for(String("3")), 2, "persisted node3=2")
    print("  test_even_assign_and_inprocess_apply: PASS")


# =============================================================================
# PHASE 3 — stale-reassign-NO-COPY over the heartbeat channel.
# =============================================================================
def test_stale_node_reassigns_sticky() raises:
    var coord = _coord(String("cl-stale"), 6, stale_us=Int64(1_000_000))

    var n1 = BrokerNodeState(String("1"))
    var n2 = BrokerNodeState(String("2"))
    var n3 = BrokerNodeState(String("3"))

    var now = Int64(2_000_000_000)
    for _round in range(2):
        var a = coord.handle_broker_heartbeat(_broker_heartbeat(String("1"), n1), now)
        _ = _apply_response(n1, a)
        now += Int64(50_000)
        var b = coord.handle_broker_heartbeat(_broker_heartbeat(String("2"), n2), now)
        _ = _apply_response(n2, b)
        now += Int64(50_000)
        var c = coord.handle_broker_heartbeat(_broker_heartbeat(String("3"), n3), now)
        _ = _apply_response(n3, c)
        now += Int64(50_000)

    var n1_before = n1.owned_partitions()
    var n2_before = n2.owned_partitions()
    var n3_before = n3.owned_partitions()
    assert_equal(len(n3_before), 2, "node 3 owned 2 before kill")

    # *** KILL node 3 *** — advance past the 1s stale window.
    now += Int64(2_000_000)

    var refresh1 = coord.handle_broker_heartbeat(_broker_heartbeat(String("1"), n1), now)
    _ = _apply_response(n1, refresh1)
    now += Int64(50_000)
    var refresh2 = coord.handle_broker_heartbeat(_broker_heartbeat(String("2"), n2), now)
    _ = _apply_response(n2, refresh2)
    now += Int64(50_000)

    var settled = coord.reassign(now)
    for i in range(len(n1_before)):
        assert_equal(
            settled.owner_of(Int(n1_before[i])),
            String("1"),
            "node 1 kept its prior 3-node partition (sticky/no-copy)",
        )
    for i in range(len(n2_before)):
        assert_equal(
            settled.owner_of(Int(n2_before[i])),
            String("2"),
            "node 2 kept its prior 3-node partition (sticky/no-copy)",
        )
    for i in range(len(n3_before)):
        var owner = settled.owner_of(Int(n3_before[i]))
        assert_true(
            owner == String("1") or owner == String("2"),
            "node 3's partition reassigned to a survivor (the only moves)",
        )
    now += Int64(50_000)

    var sticky1 = coord.handle_broker_heartbeat(_broker_heartbeat(String("1"), n1), now)
    var started1 = _apply_response(n1, sticky1)
    now += Int64(50_000)
    var sticky2 = coord.handle_broker_heartbeat(_broker_heartbeat(String("2"), n2), now)
    var started2 = _apply_response(n2, sticky2)

    assert_equal(coord.live_node_count(now), 2, "node 3 pruned -> 2 live")
    assert_true(Bool(sticky2.cluster), "cluster present")
    assert_equal(sticky2.cluster.value().node_count, UInt32(2), "2 live nodes")

    assert_equal(len(sticky1.assigned_partitions), 3, "node 1 assigned 3")
    assert_equal(len(sticky2.assigned_partitions), 3, "node 2 assigned 3")
    assert_equal(n1.partition_count(), 3, "node 1 owns 3 after apply")
    assert_equal(n2.partition_count(), 3, "node 2 owns 3 after apply")

    var covered = List[Bool]()
    for _ in range(6):
        covered.append(False)
    _mark_owned(covered, n1.owned_partitions())
    _mark_owned(covered, n2.owned_partitions())
    for pid in range(6):
        assert_true(covered[pid], "partition " + String(pid) + " still served")

    assert_equal(started1, 0, "settled round: node 1 starts nothing new")
    assert_equal(started2, 0, "settled round: node 2 starts nothing new")
    print("  test_stale_node_reassigns_sticky: PASS")


# =============================================================================
# PHASE 4 — coordinator-restart-recovers (the S3-CAS store recovery).
# =============================================================================
def test_coordinator_restart_recovers() raises:
    # A SHARED underlying store (the in-mem store's clone shares the map, the
    # analogue of a persisted object store surviving a coordinator restart).
    var base = SharedInMemoryConditionalStore()

    # --- coordinator instance 1: assign over the heartbeat channel + persist ---
    var store1 = ClusterAssignmentStore[_Store](base.clone(), String("cl-restart"))
    var coord1 = BrokerHeartbeatCoordinator[_Store](
        store1^, String("cl-restart"), String("example-data"), 6
    )

    var n1 = BrokerNodeState(String("1"))
    var n2 = BrokerNodeState(String("2"))
    var now = Int64(3_000_000_000)
    for _round in range(2):
        var a = coord1.handle_broker_heartbeat(_broker_heartbeat(String("1"), n1), now)
        _ = _apply_response(n1, a)
        now += Int64(50_000)
        var b = coord1.handle_broker_heartbeat(_broker_heartbeat(String("2"), n2), now)
        _ = _apply_response(n2, b)
        now += Int64(50_000)
    var n1_before_restart = n1.owned_partitions()
    assert_equal(len(n1_before_restart), 3, "node 1 owned 3 (2 nodes, 6 parts)")

    # --- "restart": drop coordinator-1, open coordinator-2 over the SAME store ---
    _ = coord1^  # drop instance 1.

    var store2 = ClusterAssignmentStore[_Store](base.clone(), String("cl-restart"))
    var coord2 = BrokerHeartbeatCoordinator[_Store](
        store2^, String("cl-restart"), String("example-data"), 6
    )
    # NO bootstrap needed (the object persisted). coord2's registry is EMPTY.

    var resp = coord2.handle_broker_heartbeat(_broker_heartbeat(String("1"), n1), now)
    assert_equal(
        len(resp.assigned_partitions), 6, "lone live node gets all 6 after restart"
    )
    var started = _apply_response(n1, resp)
    assert_equal(
        started, 3, "restart kept node 1's prior 3; started only node 2's 3"
    )
    for i in range(len(n1_before_restart)):
        assert_true(
            n1.owns(n1_before_restart[i]),
            "node 1 kept its prior partition across the restart",
        )
    print("  test_coordinator_restart_recovers: PASS")


def main() raises:
    print(
        "test_broker_coordinator_heartbeat_relay_e2e — heartbeat relay"
        " (DB-free object-store CAS coordinator)"
    )
    test_even_assign_and_inprocess_apply()
    test_stale_node_reassigns_sticky()
    test_coordinator_restart_recovers()
    print("ALL HEARTBEAT-RELAY E2E TESTS PASSED")

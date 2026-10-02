# =============================================================================
# tests/test_partition_assignment.mojo
#   Multi-node — the PURE assignment-pass unit gate (offline, no DB)
# =============================================================================
#
# The unit gate for the store-agnostic partition->node assignment ALGORITHM.
# Runs ENTIRELY offline (no DB / no object store / no heartbeat) — the whole
# point of keeping the algorithm pure. Covers:
#
#   * EVEN SPREAD (6 partitions / 3 nodes -> exactly 2 each).
#   * EVEN SPREAD uneven (7/3 -> 3,2,2; the first lexicographic node gets the
#     extra).
#   * STICKY / MINIMAL-MOVE (re-running with the same nodes keeps every partition
#     put; adding a node moves only the minimum).
#   * NODE-KILL-REASSIGN (a node dies -> only its partitions move, survivors keep
#     theirs; result is even over the survivors).
#   * SOFT-ADVISORY-IS-NOT-A-LOCK (a node reporting huge load still gets only its
#     fair share; load never grants/revokes a partition).
#   * EMPTY live set (no broker -> every owner "").
#   * REBALANCE-REASON decision (initial / new-node / stale-node / partition-count
#     / operator / none).
#   * encode/decode round-trip (the persisted form).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_broker import (
    LiveNode,
    Assignment,
    assign_partitions,
    rebalance_reason_for,
    is_node_live,
    live_node_ids,
    REBALANCE_NONE,
    REBALANCE_NEW_NODE,
    REBALANCE_STALE_NODE,
    REBALANCE_PARTITION_COUNT,
    REBALANCE_OPERATOR,
    REBALANCE_INITIAL,
)


def _ids(*names: String) -> List[String]:
    """Build a sorted-as-given List[String] of node ids."""
    var out = List[String]()
    for n in names:
        out.append(n)
    return out^


def _count_for(a: Assignment, node: String) -> Int:
    return a.count_for(node)


def test_even_spread_6_over_3() raises:
    """6 partitions / 3 nodes -> exactly 2 each (the canonical even split)."""
    var nodes = _ids("a", "b", "c")
    var asg = assign_partitions(nodes, 6, None, REBALANCE_INITIAL)
    assert_equal(asg.num_partitions, 6, "P=6")
    assert_equal(asg.node_count(), 3, "N=3")
    assert_equal(_count_for(asg, "a"), 2, "a serves 2")
    assert_equal(_count_for(asg, "b"), 2, "b serves 2")
    assert_equal(_count_for(asg, "c"), 2, "c serves 2")
    assert_true(asg.is_even(), "spread is even")
    # Every partition is owned by exactly one live node.
    for pid in range(6):
        var owner = asg.owner_of(pid)
        assert_true(owner.byte_length() > 0, "pid owned")
    print("  test_even_spread_6_over_3: PASS")


def test_even_spread_uneven_7_over_3() raises:
    """7/3 -> 3,2,2; the FIRST lexicographic node ('a') gets the extra
    (deterministic tie-break)."""
    var nodes = _ids("a", "b", "c")
    var asg = assign_partitions(nodes, 7, None, REBALANCE_INITIAL)
    assert_equal(_count_for(asg, "a"), 3, "a serves 3 (the extra)")
    assert_equal(_count_for(asg, "b"), 2, "b serves 2")
    assert_equal(_count_for(asg, "c"), 2, "c serves 2")
    assert_true(asg.is_even(), "spread is even (ceil/floor only)")
    print("  test_even_spread_uneven_7_over_3: PASS")


def test_sticky_idempotent_rerun() raises:
    """Re-running the pass with the SAME nodes + P keeps every partition exactly
    where it was (zero churn)."""
    var nodes = _ids("a", "b", "c")
    var first = assign_partitions(nodes, 6, None, REBALANCE_INITIAL)
    var second = assign_partitions(
        nodes, 6, Optional[Assignment](first.copy()), REBALANCE_NONE
    )
    for pid in range(6):
        assert_equal(
            second.owner_of(pid), first.owner_of(pid), "pid stayed put"
        )
    print("  test_sticky_idempotent_rerun: PASS")


def test_sticky_minimal_move_on_new_node() raises:
    """Adding a 4th node to a 6/3 assignment moves the MINIMUM: the new node
    takes its fair share (1 or 2), and the survivors shed only enough to reach
    even-spread — no partition moves between two surviving nodes gratuitously."""
    var nodes3 = _ids("a", "b", "c")
    var prior = assign_partitions(nodes3, 6, None, REBALANCE_INITIAL)
    var nodes4 = _ids("a", "b", "c", "d")
    var after = assign_partitions(
        nodes4, 6, Optional[Assignment](prior.copy()), REBALANCE_NEW_NODE
    )
    # 6/4 even split = 2,2,1,1. New node 'd' must own >=1.
    assert_true(after.is_even(), "even over 4 nodes")
    assert_true(_count_for(after, "d") >= 1, "new node took share")
    # Count how many partitions MOVED. Even-spread 6/4 requires shedding exactly
    # 2 partitions onto 'd' (6/3=2 each -> 6/4 means two nodes drop to 1). So at
    # most 2 partitions move (the minimum to reach the new even split).
    var moved = 0
    for pid in range(6):
        if after.owner_of(pid) != prior.owner_of(pid):
            moved += 1
    assert_true(moved <= 2, "minimal move (<=2 partitions relocated)")
    assert_true(moved >= 1, "at least one moved (d got work)")
    print("  test_sticky_minimal_move_on_new_node: PASS")


def test_node_kill_reassign() raises:
    """A node dies: only ITS partitions move; the survivors keep theirs; the
    result is even over the survivors."""
    var nodes3 = _ids("a", "b", "c")
    var prior = assign_partitions(nodes3, 6, None, REBALANCE_INITIAL)
    # 'b' dies — live set is now {a, c}.
    var survivors = _ids("a", "c")
    var after = assign_partitions(
        survivors, 6, Optional[Assignment](prior.copy()), REBALANCE_STALE_NODE
    )
    # 6/2 even = 3,3.
    assert_equal(_count_for(after, "a"), 3, "a serves 3")
    assert_equal(_count_for(after, "c"), 3, "c serves 3")
    assert_equal(_count_for(after, "b"), 0, "dead node serves 0")
    assert_true(after.is_even(), "even over survivors")
    # Survivors' ORIGINAL partitions must NOT have moved off them: every pid that
    # 'a' or 'c' owned before still belongs to the SAME survivor.
    for pid in range(6):
        var was = prior.owner_of(pid)
        if was == String("a") or was == String("c"):
            assert_equal(
                after.owner_of(pid), was, "survivor kept its partition"
            )
    print("  test_node_kill_reassign: PASS")


def test_soft_advisory_is_not_a_lock() raises:
    """A node reporting a HUGE records_served load still gets only its fair share
    — load is observability/licensing, NEVER a lock. The live_node_ids + assign
    path ignores load entirely for ownership."""
    var nodes = List[LiveNode]()
    # 'a' claims it served a billion records; 'b' and 'c' served nothing.
    nodes.append(LiveNode(node_id="a", last_heartbeat_us=Int64(1000),
                          records_served=UInt64(1_000_000_000)))
    nodes.append(LiveNode.at("b", Int64(1000)))
    nodes.append(LiveNode.at("c", Int64(1000)))
    var now = Int64(1000)
    var stale = Int64(60_000_000)  # 60s
    var live = live_node_ids(nodes, now, stale)
    assert_equal(len(live), 3, "all 3 live")
    var asg = assign_partitions(live, 6, None, REBALANCE_INITIAL)
    # The heavily-loaded 'a' gets EXACTLY its fair share (2), not less, not more.
    assert_equal(_count_for(asg, "a"), 2, "heavy node still gets fair 2")
    assert_equal(_count_for(asg, "b"), 2, "b gets 2")
    assert_equal(_count_for(asg, "c"), 2, "c gets 2")
    print("  test_soft_advisory_is_not_a_lock: PASS")


def test_empty_live_set() raises:
    """No live nodes -> every owner "" (the no-broker state; a producer's
    Metadata refresh sees no leader)."""
    var empty = List[String]()
    var asg = assign_partitions(empty, 4, None, REBALANCE_STALE_NODE)
    assert_equal(asg.num_partitions, 4, "P=4")
    assert_equal(asg.node_count(), 0, "no nodes")
    for pid in range(4):
        assert_equal(asg.owner_of(pid), String(""), "owner empty")
    print("  test_empty_live_set: PASS")


def test_liveness_stale_detection() raises:
    """A node that hasn't heartbeated since `now - stale` is dropped from the
    live set."""
    var nodes = List[LiveNode]()
    nodes.append(LiveNode.at("a", Int64(100_000_000)))  # fresh
    nodes.append(LiveNode.at("b", Int64(1_000)))  # very old -> stale
    nodes.append(LiveNode.at("c", Int64(100_000_000)))  # fresh
    var now = Int64(100_000_000)
    var stale = Int64(60_000_000)  # 60s window
    assert_true(is_node_live(Int64(100_000_000), now, stale), "a live")
    assert_false(is_node_live(Int64(1_000), now, stale), "b stale")
    var live = live_node_ids(nodes, now, stale)
    assert_equal(len(live), 2, "two live (a, c)")
    assert_equal(live[0], String("a"), "sorted: a first")
    assert_equal(live[1], String("c"), "sorted: c second")
    print("  test_liveness_stale_detection: PASS")


def test_rebalance_reason_decision() raises:
    """The rebalance-trigger decision returns the right REBALANCE_* reason for
    each input shape, with operator-forced taking precedence."""
    var nodes3 = _ids("a", "b", "c")
    var prior = assign_partitions(nodes3, 6, None, REBALANCE_INITIAL)
    var prior_opt = Optional[Assignment](prior.copy())

    # No prior -> INITIAL.
    assert_equal(
        rebalance_reason_for(None, nodes3, 6, False),
        REBALANCE_INITIAL,
        "no prior -> initial",
    )
    # Same inputs -> NONE.
    assert_equal(
        rebalance_reason_for(prior_opt.copy(), nodes3, 6, False),
        REBALANCE_NONE,
        "steady state -> none",
    )
    # P changed -> PARTITION_COUNT.
    assert_equal(
        rebalance_reason_for(prior_opt.copy(), nodes3, 8, False),
        REBALANCE_PARTITION_COUNT,
        "P changed -> partition_count",
    )
    # A node left -> STALE_NODE.
    assert_equal(
        rebalance_reason_for(prior_opt.copy(), _ids("a", "b"), 6, False),
        REBALANCE_STALE_NODE,
        "node left -> stale_node",
    )
    # A node joined -> NEW_NODE.
    assert_equal(
        rebalance_reason_for(prior_opt.copy(), _ids("a", "b", "c", "d"), 6, False),
        REBALANCE_NEW_NODE,
        "node joined -> new_node",
    )
    # Operator-forced takes precedence even when nothing else changed.
    assert_equal(
        rebalance_reason_for(prior_opt.copy(), nodes3, 6, True),
        REBALANCE_OPERATOR,
        "operator-forced -> operator",
    )
    print("  test_rebalance_reason_decision: PASS")


def test_encode_decode_roundtrip() raises:
    """The persisted assignment form round-trips encode->decode field-for-field
    (this is the body a store CAS's)."""
    var nodes = _ids("node-1", "node-2", "node-3")
    var asg = assign_partitions(nodes, 6, None, REBALANCE_NEW_NODE)
    var body = asg.encode()
    var back = Assignment.decode(body)
    assert_equal(back.num_partitions, asg.num_partitions, "P round-trips")
    assert_equal(back.reason, REBALANCE_NEW_NODE, "reason round-trips")
    assert_equal(back.node_count(), 3, "3 nodes round-trip")
    for pid in range(6):
        assert_equal(
            back.owner_of(pid), asg.owner_of(pid), "owner round-trips"
        )
    # partitions_for + the UInt32 list the coordinator pushes back.
    var p1 = back.partitions_for(String("node-1"))
    assert_equal(len(p1), 2, "node-1 owns 2 partitions")
    print("  test_encode_decode_roundtrip: PASS")


def test_encode_decode_empty_owners() raises:
    """An empty-live-set assignment ('' owners) round-trips: every owner decodes
    back to ""."""
    var empty = List[String]()
    var asg = assign_partitions(empty, 3, None, REBALANCE_STALE_NODE)
    var body = asg.encode()
    var back = Assignment.decode(body)
    assert_equal(back.num_partitions, 3, "P=3")
    assert_equal(back.node_count(), 0, "no nodes")
    for pid in range(3):
        assert_equal(back.owner_of(pid), String(""), "empty owner round-trips")
    print("  test_encode_decode_empty_owners: PASS")


def main() raises:
    print("test_partition_assignment — pure assignment-pass gate")
    test_even_spread_6_over_3()
    test_even_spread_uneven_7_over_3()
    test_sticky_idempotent_rerun()
    test_sticky_minimal_move_on_new_node()
    test_node_kill_reassign()
    test_soft_advisory_is_not_a_lock()
    test_empty_live_set()
    test_liveness_stale_detection()
    test_rebalance_reason_decision()
    test_encode_decode_roundtrip()
    test_encode_decode_empty_owners()
    print("ALL PARTITION-ASSIGNMENT UNIT TESTS PASSED")

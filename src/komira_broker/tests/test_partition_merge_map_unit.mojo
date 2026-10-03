# =============================================================================
# tests/test_partition_merge_map_unit.mojo
#   Dynamic partition scaling — PartitionMap merge/collapse unit tests +
#   multi-node reassignment-on-decrease (OFFLINE, fast — pure metadata)
# =============================================================================
#
# Pins the PURE map-level merge/collapse/codec:
#   1. merge() / merge_at() — folds two adjacent ranges into one child, keeps the
#      map gap-free + full-space, records the merge lineage (both predecessors
#      retired with merged_into_pid == child; child carries both pred back-edges).
#   2. range_containing_pid round-trips correctly over a merged map (the merged
#      child owns the union range).
#   3. merge rejects: a fixed-mode map, non-adjacent pids, and the
#      reverse-order pair (B before A).
#   4. collapse_lineage() — drops a split parent tombstone + clears the children's
#      back-edges, keeps the map valid.
#   5. encode -> decode round-trip identity for a merged + a collapsed map.
#   6. multi-node integration: a merge (P decreases) triggers REBALANCE_PARTITION_COUNT
#      and reassigns the merged partition set onto the live nodes.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_broker.partition_map import (
    HashRange,
    PartitionMap,
    RetiredRange,
    PARTITION_MODE_FIXED,
    PARTITION_MODE_AUTO,
    NO_PARENT_PID,
    NO_PARENT_BASE,
    NO_MERGE_PID,
)
from komira_broker.partition_split import build_lineage_read_order
from komira_broker.partition_assignment import (
    LiveNode,
    Assignment,
    assign_partitions,
    rebalance_reason_for,
    REBALANCE_PARTITION_COUNT,
    REBALANCE_INITIAL,
)


# =============================================================================
# (1) merge — folds two adjacent ranges into one child; map stays valid.
# =============================================================================


def test_merge_basic() raises:
    print("[test_merge_basic] starting...")
    # Auto seed (1 range pid 0). Split into {1, 2}, then merge them back into 3.
    var m0 = PartitionMap.auto_seed()
    var m1 = m0.split(0)  # -> ranges {1, 2}, retired {0}
    assert_equal(m1.num_partitions(), 2, "after split: 2 live ranges")

    var m2 = m1.merge_at(1, 2, Int64(10), Int64(20))
    m2.validate()  # the merge must keep the map gap-free + full-space.
    assert_equal(m2.num_partitions(), 1, "after merge: 1 live range")
    assert_equal(m2.version, m1.version + 1, "merge bumps the version")

    # The single live range is the merged child C, covering the FULL space.
    ref c = m2.ranges[0]
    assert_equal(c.hash_lo, UInt64(0), "merged child lo == 0 (full space)")
    assert_equal(c.hash_hi, UInt64.MAX, "merged child hi == MAX (full space)")
    assert_equal(c.pid, 3, "merged child pid 3 (fresh, monotone after 0,1,2)")
    assert_equal(c.merge_pred_a_pid, 1, "merged child carries pred A == 1")
    assert_equal(c.merge_pred_b_pid, 2, "merged child carries pred B == 2")
    assert_equal(c.parent_pid, NO_PARENT_PID, "merged child has no split parent")

    # Both predecessors (1, 2) are retired as MERGE tombstones (merged_into 3).
    var found_a = False
    var found_b = False
    for i in range(len(m2.retired)):
        ref t = m2.retired[i]
        if t.pid == 1 and t.is_merge():
            found_a = True
            assert_equal(t.merged_into_pid, 3, "pred 1 merged_into 3")
            assert_equal(t.frozen_at_offset, Int64(10), "pred 1 freeze Xa=10")
        if t.pid == 2 and t.is_merge():
            found_b = True
            assert_equal(t.merged_into_pid, 3, "pred 2 merged_into 3")
            assert_equal(t.frozen_at_offset, Int64(20), "pred 2 freeze Xb=20")
    assert_true(found_a, "pred 1 retired as a merge tombstone")
    assert_true(found_b, "pred 2 retired as a merge tombstone")

    # Routing: any hash now resolves to the merged child 3.
    assert_equal(
        m2.range_containing_pid(UInt64(0)), 3, "hash 0 -> merged child 3"
    )
    assert_equal(
        m2.range_containing_pid(UInt64.MAX), 3, "hash MAX -> merged child 3"
    )
    var midpoint = UInt64(0x8000000000000000)
    assert_equal(
        m2.range_containing_pid(midpoint), 3, "hash midpoint -> merged child 3"
    )
    print("  merge folds {1,2} -> 3 over the full space, lineage recorded OK")
    print("[test_merge_basic] PASS")


# =============================================================================
# (2) merge over a 3-way map — fold the middle pair, keep the outer range.
# =============================================================================


def test_merge_middle_pair() raises:
    print("[test_merge_middle_pair] starting...")
    # Build a 3-range auto map by splitting twice: 0 -> {1,2}; split 1 -> {3,4}.
    # Live ranges (ascending lo): 3 [0, q), 4 [q, mid), 2 [mid, MAX).
    var m = PartitionMap.auto_seed()
    m = m.split(0)  # {1, 2}
    m = m.split(1)  # {3, 4, 2}  (1 -> 3,4)
    assert_equal(m.num_partitions(), 3, "3 live ranges before merge")

    # Merge the adjacent pair {3, 4} (the two halves of old 1) back into one.
    # 3 and 4 are at indices 0,1 (ascending). Merge them.
    var merged = m.merge_at(3, 4, Int64(5), Int64(7))
    merged.validate()
    assert_equal(merged.num_partitions(), 2, "merge 3+4 -> 2 live ranges")
    # The merged child owns [0, mid) (== old 1's range); pid 2 still owns the top.
    var lo0 = merged.ranges[0].hash_lo
    assert_equal(lo0, UInt64(0), "merged child starts at 0")
    # pid 2 unchanged.
    var has2 = False
    for i in range(len(merged.ranges)):
        if merged.ranges[i].pid == 2:
            has2 = True
    assert_true(has2, "the non-merged neighbor (pid 2) survives")
    print("  merge middle adjacent pair keeps the outer range OK")
    print("[test_merge_middle_pair] PASS")


# =============================================================================
# (3) merge rejects: fixed-mode, non-adjacent, reverse-order.
# =============================================================================


def test_merge_rejects() raises:
    print("[test_merge_rejects] starting...")
    # Fixed-mode never merges.
    var fixed = PartitionMap.fixed(4)
    var fixed_raised = False
    try:
        _ = fixed.merge_at(0, 1, Int64(0), Int64(0))
    except e:
        fixed_raised = True
        assert_true(
            String(e).find("fixed") >= 0 or String(e).find("AUTO") >= 0,
            "fixed-mode merge error mentions fixed/AUTO",
        )
    assert_true(fixed_raised, "fixed-mode merge must raise")

    # Non-adjacent: a 3-range auto map; pid 3 and pid 2 are NOT adjacent (4 is
    # between them).
    var m = PartitionMap.auto_seed()
    m = m.split(0)  # {1, 2}
    m = m.split(1)  # live ascending: 3, 4, 2
    var nonadj_raised = False
    try:
        _ = m.merge_at(3, 2, Int64(0), Int64(0))  # 3 and 2 are not adjacent
    except e:
        nonadj_raised = True
        assert_true(
            String(e).find("ADJACENT") >= 0 or String(e).find("adjacent") >= 0,
            "non-adjacent merge error mentions adjacency",
        )
    assert_true(nonadj_raised, "non-adjacent merge must raise")

    # Reverse order: merge_at(B, A) where B is the UPPER neighbor must raise
    # (A must be the lower neighbor of B).
    var rev_raised = False
    try:
        _ = m.merge_at(4, 3, Int64(0), Int64(0))  # 4 is upper of 3
    except e:
        rev_raised = True
    assert_true(rev_raised, "reverse-order (B, A) merge must raise")
    print("  merge rejects fixed-mode / non-adjacent / reverse-order OK")
    print("[test_merge_rejects] PASS")


# =============================================================================
# (4) collapse_lineage — drops a split parent + clears children back-edges.
# =============================================================================


def test_collapse_lineage() raises:
    print("[test_collapse_lineage] starting...")
    var m = PartitionMap.auto_seed()
    m = m.split_at(0, Int64(33))  # 0 -> {1, 2}, parent 0 frozen at 33
    # Pre-collapse: parent 0 is in retired; children carry the back-edge.
    var has_parent = False
    for i in range(len(m.retired)):
        if m.retired[i].pid == 0 and not m.retired[i].is_merge():
            has_parent = True
    assert_true(has_parent, "pre-collapse: split parent 0 in retired")
    var idx1 = m._range_index_for_pid(1)
    assert_equal(m.ranges[idx1].parent_pid, 0, "child 1 back-edge -> 0")

    var collapsed = m.collapse_lineage(0)
    collapsed.validate()
    assert_equal(collapsed.version, m.version + 1, "collapse bumps version")
    # Parent 0 dropped from retired.
    var still_parent = False
    for i in range(len(collapsed.retired)):
        if collapsed.retired[i].pid == 0:
            still_parent = True
    assert_false(still_parent, "post-collapse: parent 0 dropped from retired")
    # Children back-edges cleared.
    var ci1 = collapsed._range_index_for_pid(1)
    var ci2 = collapsed._range_index_for_pid(2)
    assert_equal(collapsed.ranges[ci1].parent_pid, NO_PARENT_PID,
                 "child 1 back-edge cleared")
    assert_equal(collapsed.ranges[ci2].parent_pid, NO_PARENT_PID,
                 "child 2 back-edge cleared")
    assert_equal(collapsed.ranges[ci1].parent_split_offset, NO_PARENT_BASE,
                 "child 1 split offset cleared")
    # The read order no longer includes pid 0.
    var order = build_lineage_read_order(collapsed)
    var has0 = False
    for i in range(len(order)):
        if order[i].pid == 0:
            has0 = True
    assert_false(has0, "post-collapse: read order excludes the parent")

    # collapse rejects a non-split-parent pid.
    var rej = False
    try:
        _ = collapsed.collapse_lineage(0)  # already dropped
    except:
        rej = True
    assert_true(rej, "collapse on an already-dropped parent raises")
    print("  collapse_lineage drops the parent + clears children back-edges OK")
    print("[test_collapse_lineage] PASS")


# =============================================================================
# (5) encode -> decode round-trip for a merged + a collapsed map.
# =============================================================================


def test_merge_codec_round_trip() raises:
    print("[test_merge_codec_round_trip] starting...")
    var m = PartitionMap.auto_seed()
    m = m.split(0)
    m = m.merge_at(1, 2, Int64(11), Int64(22))
    var bytes = m.encode()
    var back = PartitionMap.decode(bytes)
    assert_equal(back.version, m.version, "version round-trips")
    assert_equal(back.num_partitions(), m.num_partitions(), "ranges round-trip")
    assert_equal(back.next_pid, m.next_pid, "next_pid round-trips")
    # The merged child's lineage round-trips.
    ref c = back.ranges[0]
    assert_equal(c.pid, 3, "merged child pid round-trips")
    assert_equal(c.merge_pred_a_pid, 1, "merge pred A round-trips")
    assert_equal(c.merge_pred_b_pid, 2, "merge pred B round-trips")
    # The merge tombstones round-trip (merged_into_pid preserved).
    var pred_ok = 0
    for i in range(len(back.retired)):
        ref t = back.retired[i]
        if t.is_merge() and t.merged_into_pid == 3:
            pred_ok += 1
    assert_equal(pred_ok, 2, "both merge tombstones round-trip with merged_into 3")
    back.validate()

    # Collapsed map round-trips too.
    var m2 = PartitionMap.auto_seed()
    m2 = m2.split(0)
    m2 = m2.collapse_lineage(0)
    var b2 = m2.encode()
    var back2 = PartitionMap.decode(b2)
    assert_equal(len(back2.retired), 0, "collapsed map has no retired tombstones")
    back2.validate()
    print("  merged + collapsed map encode/decode round-trip OK")
    print("[test_merge_codec_round_trip] PASS")


# =============================================================================
# (6) multi-node integration — a merge (P decreases) triggers REBALANCE_PARTITION_COUNT.
# =============================================================================


def test_m6_reassign_on_merge_decrease() raises:
    print("[test_m6_reassign_on_merge_decrease] starting...")
    # 3 live nodes. A prior assignment for P=4 (the post-split count).
    var node_ids = List[String]()
    node_ids.append(String("node-a"))
    node_ids.append(String("node-b"))
    node_ids.append(String("node-c"))
    var prior = assign_partitions(
        node_ids.copy(), 4, Optional[Assignment](None), REBALANCE_INITIAL
    )
    assert_equal(prior.num_partitions, 4, "prior assignment for P=4")
    assert_true(prior.is_even(), "prior is even-spread")

    # A merge drops P from 4 -> 3 (one merge folds two ranges into one). The multi-node
    # rebalance reason MUST be REBALANCE_PARTITION_COUNT (P changed — the SAME
    # branch that handles a split increase, now exercised for a DECREASE).
    var reason = rebalance_reason_for(
        Optional[Assignment](prior.copy()),
        node_ids.copy(),
        3,  # the post-merge partition count
        False,
    )
    assert_equal(
        reason,
        REBALANCE_PARTITION_COUNT,
        "a merge (P 4 -> 3) triggers REBALANCE_PARTITION_COUNT (decrease case)",
    )

    # Reassign the merged set: P=3 over the 3 live nodes -> even spread (1 each).
    var after = assign_partitions(
        node_ids.copy(), 3, Optional[Assignment](prior^), reason
    )
    assert_equal(after.num_partitions, 3, "post-merge assignment for P=3")
    assert_true(after.is_even(), "post-merge assignment is even-spread")
    # Every merged partition has a non-empty owner.
    for pid in range(3):
        assert_true(
            after.owner_of(pid).byte_length() > 0,
            "merged partition " + String(pid) + " has a live owner",
        )
    print("  merge (P 4->3) -> REBALANCE_PARTITION_COUNT -> even reassignment OK")
    print("[test_m6_reassign_on_merge_decrease] PASS")


def main() raises:
    test_merge_basic()
    test_merge_middle_pair()
    test_merge_rejects()
    test_collapse_lineage()
    test_merge_codec_round_trip()
    test_m6_reassign_on_merge_decrease()
    print(
        "[OK] test_partition_merge_map_unit — merge folds adjacent ranges (full"
        " + middle), rejects fixed/non-adjacent/reverse, collapse_lineage drops"
        " the split parent, merged+collapsed codec round-trips, and a merge"
        " (P decrease) triggers multi-node REBALANCE_PARTITION_COUNT reassignment"
    )

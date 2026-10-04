# =============================================================================
# tests/test_partition_merge_trigger_unit.mojo
#   Dynamic partition scaling — MERGE trigger + hysteresis/anti-flap +
#   lineage-depth cap unit tests (OFFLINE, fast — pure decision logic + map CAS)
# =============================================================================
#
# Merge + conservative hysteresis, the lineage-depth cap, and cooldown /
# anti-flap. Pins:
#   1. evaluate_merge — COLD gate (both ranges below T_low -> PROPOSE; either
#      hot -> SKIP_NOT_COLD), anti-flap (a recently-split range -> SKIP_RECENTLY_
#      SPLIT), min-partitions floor (-> SKIP_AT_FLOOR).
#   2. The lineage-DEPTH cap: evaluate_split refuses a split that would
#      exceed max_lineage_depth (-> SKIP_DEPTH_CAP + needs_compaction) until
#      compaction collapses the lineage.
#   3. The idempotent merge_topic_if_eligible (concurrent-proposal no-double-
#      merge) over the in-memory store: a merge on an already-merged pair is a
#      clean None (no error, no second merge).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_broker.partition_trigger import (
    AutoSplitPolicy,
    SplitDecision,
    evaluate_split,
    SPLIT_DECISION_PROPOSE,
    SPLIT_DECISION_SKIP_DEPTH_CAP,
    AutoMergePolicy,
    MergeDecision,
    evaluate_merge,
    merge_decision_name,
    MERGE_DECISION_PROPOSE,
    MERGE_DECISION_SKIP_NOT_COLD,
    MERGE_DECISION_SKIP_RECENTLY_SPLIT,
    MERGE_DECISION_SKIP_AT_FLOOR,
)
from komira_broker.partition_map import (
    PartitionMap,
    read_partition_map_with_etag,
    persist_create_if_absent,
)
from komira_broker.partition_split import (
    SplitResult,
    split_topic,
)
from komira_broker.partition_merge import (
    MergeResult,
    merge_topic,
    merge_topic_if_eligible,
)

from komira_broker.broker_core import BrokerCore
from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema


comptime _Store = SharedInMemoryConditionalStore


# =============================================================================
# (1) evaluate_merge — COLD gate (both below T_low) + hysteresis.
# =============================================================================


def test_merge_cold_gate() raises:
    print("[test_merge_cold_gate] starting...")
    # T_low = 1000, floor 1, anti-flap ON.
    var policy = AutoMergePolicy.with_threshold(
        threshold_records=Int64(1000),
        min_partitions=1,
        allow_recently_split=False,
    )

    # BOTH cold (both < T_low) + live=4 > floor + neither recently split -> PROPOSE.
    var both_cold = evaluate_merge(
        policy, Int64(500), Int64(300), 4, False, False
    )
    assert_equal(
        both_cold.kind,
        MERGE_DECISION_PROPOSE,
        "both ranges below T_low -> PROPOSE",
    )
    assert_true(both_cold.should_propose, "both cold must propose")

    # A is HOT (>= T_low) -> not jointly cold -> SKIP_NOT_COLD.
    var a_hot = evaluate_merge(
        policy, Int64(1000), Int64(300), 4, False, False
    )
    assert_equal(
        a_hot.kind,
        MERGE_DECISION_SKIP_NOT_COLD,
        "A at/above T_low -> SKIP_NOT_COLD",
    )
    assert_false(a_hot.should_propose, "a hot range must not merge")

    # B is HOT -> SKIP_NOT_COLD.
    var b_hot = evaluate_merge(
        policy, Int64(200), Int64(5000), 4, False, False
    )
    assert_equal(
        b_hot.kind,
        MERGE_DECISION_SKIP_NOT_COLD,
        "B above T_low -> SKIP_NOT_COLD",
    )
    print("  cold gate (both below T_low) OK")
    print("[test_merge_cold_gate] PASS")


# =============================================================================
# (2) anti-flap — a recently-split range is NOT merge-eligible.
# =============================================================================


def test_merge_anti_flap_recently_split() raises:
    print("[test_merge_anti_flap_recently_split] starting...")
    var policy = AutoMergePolicy.with_threshold(
        threshold_records=Int64(1000),
        min_partitions=1,
        allow_recently_split=False,
    )

    # Both cold, but A is a RECENTLY-SPLIT child -> SKIP_RECENTLY_SPLIT (no flap).
    var a_recent = evaluate_merge(
        policy, Int64(10), Int64(10), 4, True, False
    )
    assert_equal(
        a_recent.kind,
        MERGE_DECISION_SKIP_RECENTLY_SPLIT,
        "A recently split (both cold) -> SKIP_RECENTLY_SPLIT (anti-flap)",
    )
    assert_false(a_recent.should_propose, "recently-split must not merge")

    # B recently split -> SKIP_RECENTLY_SPLIT.
    var b_recent = evaluate_merge(
        policy, Int64(10), Int64(10), 4, False, True
    )
    assert_equal(
        b_recent.kind,
        MERGE_DECISION_SKIP_RECENTLY_SPLIT,
        "B recently split -> SKIP_RECENTLY_SPLIT",
    )

    # With allow_recently_split=True the anti-flap gate is OFF (test override).
    var allow_policy = AutoMergePolicy.with_threshold(
        threshold_records=Int64(1000),
        min_partitions=1,
        allow_recently_split=True,
    )
    var allowed = evaluate_merge(
        allow_policy, Int64(10), Int64(10), 4, True, True
    )
    assert_equal(
        allowed.kind,
        MERGE_DECISION_PROPOSE,
        "allow_recently_split=True bypasses the anti-flap gate",
    )
    print("  anti-flap (recently-split not merged) OK")
    print("[test_merge_anti_flap_recently_split] PASS")


# =============================================================================
# (3) min-partitions floor — never merge below the floor.
# =============================================================================


def test_merge_min_partitions_floor() raises:
    print("[test_merge_min_partitions_floor] starting...")
    # Floor = 2: a topic at 2 live partitions must NOT merge to 1.
    var policy = AutoMergePolicy.with_threshold(
        threshold_records=Int64(1000),
        min_partitions=2,
        allow_recently_split=False,
    )

    # live=2 == floor: even both-cold -> SKIP_AT_FLOOR (the floor dominates).
    var at_floor = evaluate_merge(
        policy, Int64(10), Int64(10), 2, False, False
    )
    assert_equal(
        at_floor.kind,
        MERGE_DECISION_SKIP_AT_FLOOR,
        "live=2 == floor -> SKIP_AT_FLOOR (floor checked first)",
    )
    assert_false(at_floor.should_propose, "at floor must not merge")

    # live=3 > floor + both cold -> PROPOSE.
    var above_floor = evaluate_merge(
        policy, Int64(10), Int64(10), 3, False, False
    )
    assert_equal(
        above_floor.kind,
        MERGE_DECISION_PROPOSE,
        "live=3 > floor=2 + both cold -> PROPOSE",
    )
    print("  min-partitions floor OK")
    print("[test_merge_min_partitions_floor] PASS")


# =============================================================================
# (4) lineage-DEPTH cap — a split past the cap is refused.
# =============================================================================


def test_split_lineage_depth_cap() raises:
    print("[test_split_lineage_depth_cap] starting...")
    # A LOW threshold (so load always crosses) + a depth cap of 2.
    var policy = AutoSplitPolicy.with_threshold(
        threshold_records=Int64(1),
        max_partitions=64,
        min_segments_before_split=Int64(1),
        max_lineage_depth=2,
    )

    # candidate_parent_depth=0 -> child at depth 1 <= cap 2 -> PROPOSE.
    var d0 = evaluate_split(policy, Int64(100), Int64(5), 4, 0)
    assert_equal(d0.kind, SPLIT_DECISION_PROPOSE, "child depth 1 <= cap 2 -> PROPOSE")

    # candidate_parent_depth=1 -> child at depth 2 == cap 2 -> PROPOSE (== is OK).
    var d1 = evaluate_split(policy, Int64(100), Int64(5), 4, 1)
    assert_equal(d1.kind, SPLIT_DECISION_PROPOSE, "child depth 2 == cap 2 -> PROPOSE")

    # candidate_parent_depth=2 -> child at depth 3 > cap 2 -> SKIP_DEPTH_CAP.
    var d2 = evaluate_split(policy, Int64(100), Int64(5), 4, 2)
    assert_equal(
        d2.kind,
        SPLIT_DECISION_SKIP_DEPTH_CAP,
        "child depth 3 > cap 2 -> SKIP_DEPTH_CAP (refuse until compaction)",
    )
    assert_false(d2.should_propose, "over depth cap must not split")
    assert_true(
        d2.needs_compaction,
        "over depth cap sets needs_compaction (run a compaction pass first)",
    )

    # max_lineage_depth=0 DISABLES the cap: a deep split OK.
    var no_cap = AutoSplitPolicy.with_threshold(
        threshold_records=Int64(1),
        max_partitions=64,
        min_segments_before_split=Int64(1),
        max_lineage_depth=0,
    )
    var deep_ok = evaluate_split(no_cap, Int64(100), Int64(5), 4, 9)
    assert_equal(
        deep_ok.kind,
        SPLIT_DECISION_PROPOSE,
        "max_lineage_depth=0 disables the cap -> deep split PROPOSE",
    )
    print("  lineage-depth cap (refuse split past cap) OK")
    print("[test_split_lineage_depth_cap] PASS")


# =============================================================================
# (5) Idempotent merge_topic_if_eligible — concurrent-proposal no-double-merge.
# =============================================================================


def _manifest_prefix(cluster: String, topic: String, pid: Int) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


def _make_int64_batch(value: Int64) raises -> RecordBatch:
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(1)
    var p = arr._typed_ptr_mut()
    p.store[width=1](0, value)
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _make_broker(
    store: _Store, cluster: String, topic: String, pid: Int
) raises -> BrokerCore[_Store]:
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_manifest_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=Int64(pid),
        broker_id=String("broker-A"),
    )


def _mk_manifest(
    store: _Store, cluster: String, topic: String, pid: Int
) raises -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=store.clone(),
        prefix=_manifest_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )


def test_merge_if_eligible_idempotent_on_merged_pair() raises:
    print("[test_merge_if_eligible_idempotent_on_merged_pair] starting...")
    var store = SharedInMemoryConditionalStore()
    var cluster = String("trig")
    var topic = String("idem-merge-topic")

    # Auto seed (pid 0). Produce a few records so pid 0 has a tail. Split -> {1,2}.
    var seed = PartitionMap.auto_seed()
    persist_create_if_absent[_Store](store, cluster, topic, seed)
    var broker0 = _make_broker(store, cluster, topic, 0)
    for i in range(5):
        var rb = _make_int64_batch(Int64(100 + i))
        _ = broker0.produce(rb^, Int64(i))
        _ = broker0.flush_if_buffered(Int64(i + 1))
    _ = broker0^
    var split0 = split_topic[_Store](
        store, cluster, topic, _mk_manifest(store, cluster, topic, 0), 0
    )
    assert_equal(split0.child_a_pid, 1, "split child_a 1")
    assert_equal(split0.child_b_pid, 2, "split child_b 2")

    # FIRST merge proposal: 1+2 are a live adjacent pair -> the merge lands (Some).
    var first = merge_topic_if_eligible[_Store](
        store,
        cluster,
        topic,
        _mk_manifest(store, cluster, topic, 1),
        _mk_manifest(store, cluster, topic, 2),
        1,
        2,
    )
    assert_true(first.__bool__(), "first merge on a live adjacent pair must land")
    assert_equal(first.value().child_pid, 3, "merged child pid 3")
    var v_after_first = read_partition_map_with_etag[_Store](
        store, cluster, topic
    ).map.version
    print("  first merge landed: {1,2} -> 3 (map v", v_after_first, ")")

    # SECOND merge proposal on the SAME (now-retired) pair: a clean no-op (None),
    # NOT a double-merge, NOT an error.
    var second = merge_topic_if_eligible[_Store](
        store,
        cluster,
        topic,
        _mk_manifest(store, cluster, topic, 1),
        _mk_manifest(store, cluster, topic, 2),
        1,
        2,
    )
    assert_false(
        second.__bool__(),
        "second merge on a retired pair must be a clean None (no double-merge)",
    )
    var v_after_second = read_partition_map_with_etag[_Store](
        store, cluster, topic
    ).map.version
    assert_equal(
        v_after_second,
        v_after_first,
        "no second merge: map version unchanged after the no-op proposal",
    )
    print("  second merge on retired pair: clean no-op (map still v",
          v_after_second, ") OK")
    print("[test_merge_if_eligible_idempotent_on_merged_pair] PASS")


def main() raises:
    test_merge_cold_gate()
    test_merge_anti_flap_recently_split()
    test_merge_min_partitions_floor()
    test_split_lineage_depth_cap()
    test_merge_if_eligible_idempotent_on_merged_pair()
    print(
        "[OK] test_partition_merge_trigger_unit — merge cold gate, anti-flap"
        " (recently-split not merged), min-partitions floor, lineage-depth cap"
        " (split refused past cap), and concurrent-proposal idempotence (merge"
        " on a retired pair is a clean no-op)"
    )

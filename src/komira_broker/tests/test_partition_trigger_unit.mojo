# =============================================================================
# tests/test_partition_trigger_unit.mojo
#   Dynamic partition scaling — AUTO-SPLIT TRIGGER unit tests
#   (OFFLINE, fast — the pure decision logic, no store)
# =============================================================================
#
# The trigger, its hysteresis and caps, and the hot-key ceiling. These tests
# pin the PURE decision function `evaluate_split` (no object store):
#   1. THRESHOLD — below the threshold -> SKIP_BELOW_THRESHOLD (no proposal);
#      at/above -> PROPOSE.
#   2. CAP — at/over max_partitions -> SKIP_AT_CAP + the
#      at_cap_warning flag (regardless of load). Below the cap, normal gating.
#   3. FRESH-FLOOR — a partition over the
#      threshold but under min_segments_before_split (a freshly-forked child on
#      its first flush) -> SKIP_FRESH_FLOOR (no instant re-split).
#   4. The idempotent `split_topic_if_live` (concurrent-proposal no-double-split)
#      over the in-memory store: a split on an already-retired pid is a clean
#      None (no error, no second split).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_broker.partition_trigger import (
    AutoSplitPolicy,
    SplitDecision,
    evaluate_split,
    split_decision_name,
    SPLIT_DECISION_PROPOSE,
    SPLIT_DECISION_SKIP_BELOW_THRESHOLD,
    SPLIT_DECISION_SKIP_FRESH_FLOOR,
    SPLIT_DECISION_SKIP_AT_CAP,
    DEFAULT_SPLIT_THRESHOLD_RECORDS,
    DEFAULT_MAX_PARTITIONS,
    DEFAULT_MIN_SEGMENTS_BEFORE_SPLIT,
)
from komira_broker.partition_map import (
    PartitionMap,
    read_partition_map_with_etag,
    persist_create_if_absent,
)
from komira_broker.partition_split import (
    SplitResult,
    split_topic,
    split_topic_if_live,
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
# (1) THRESHOLD gating.
# =============================================================================


def test_threshold_below_and_above() raises:
    print("[test_threshold_below_and_above] starting...")
    # A policy with threshold 1000 records, a generous cap, floor 1 segment.
    var policy = AutoSplitPolicy.with_threshold(
        threshold_records=Int64(1000),
        max_partitions=64,
        min_segments_before_split=Int64(1),
    )

    # BELOW the threshold: no proposal.
    var below = evaluate_split(policy, Int64(999), Int64(10), 1)
    assert_equal(
        below.kind,
        SPLIT_DECISION_SKIP_BELOW_THRESHOLD,
        "999 < 1000 records -> SKIP_BELOW_THRESHOLD",
    )
    assert_false(below.should_propose, "below threshold must not propose")

    # EXACTLY at the threshold: propose (>= is the trigger).
    var at = evaluate_split(policy, Int64(1000), Int64(10), 1)
    assert_equal(
        at.kind, SPLIT_DECISION_PROPOSE, "1000 == threshold -> PROPOSE"
    )
    assert_true(at.should_propose, "at threshold must propose")

    # ABOVE the threshold: propose.
    var above = evaluate_split(policy, Int64(5000), Int64(40), 1)
    assert_equal(
        above.kind, SPLIT_DECISION_PROPOSE, "5000 > threshold -> PROPOSE"
    )
    assert_true(above.should_propose, "above threshold must propose")
    print("  threshold below/at/above OK")
    print("[test_threshold_below_and_above] PASS")


# =============================================================================
# (2) CAP — at/over max_partitions halts proposals + warns.
# =============================================================================


def test_max_partitions_cap_halts_and_warns() raises:
    print("[test_max_partitions_cap_halts_and_warns] starting...")
    # threshold 1000, cap 4, floor 1. A VERY hot partition (way over threshold).
    var policy = AutoSplitPolicy.with_threshold(
        threshold_records=Int64(1000),
        max_partitions=4,
        min_segments_before_split=Int64(1),
    )

    # Under the cap (live_count=3 < 4) AND hot -> PROPOSE.
    var under = evaluate_split(policy, Int64(100_000), Int64(500), 3)
    assert_equal(
        under.kind, SPLIT_DECISION_PROPOSE, "live=3 < cap=4 + hot -> PROPOSE"
    )

    # AT the cap (live_count == 4) -> SKIP_AT_CAP + the warning flag, regardless
    # of how hot the partition is.
    var at_cap = evaluate_split(policy, Int64(100_000), Int64(500), 4)
    assert_equal(
        at_cap.kind, SPLIT_DECISION_SKIP_AT_CAP, "live=4 == cap -> SKIP_AT_CAP"
    )
    assert_false(at_cap.should_propose, "at cap must not propose")
    assert_true(at_cap.at_cap_warning, "at cap must raise the warning flag")

    # OVER the cap (live_count > 4) -> same (defensive).
    var over_cap = evaluate_split(policy, Int64(100_000), Int64(500), 7)
    assert_equal(
        over_cap.kind,
        SPLIT_DECISION_SKIP_AT_CAP,
        "live > cap -> SKIP_AT_CAP",
    )
    assert_true(over_cap.at_cap_warning, "over cap must raise the warning flag")

    # The cap is checked FIRST: even a partition BELOW the threshold at the cap
    # still returns SKIP_AT_CAP (the cap dominates — we never propose at cap).
    var cap_dominates = evaluate_split(policy, Int64(10), Int64(1), 4)
    assert_equal(
        cap_dominates.kind,
        SPLIT_DECISION_SKIP_AT_CAP,
        "cap is checked first (even below threshold)",
    )
    print("  cap halts proposals + warns OK")
    print("[test_max_partitions_cap_halts_and_warns] PASS")


# =============================================================================
# (3) FRESH-FLOOR — a freshly-forked child does not re-split.
# =============================================================================


def test_fresh_child_floor_prevents_instant_resplit() raises:
    print("[test_fresh_child_floor_prevents_instant_resplit] starting...")
    # A LOW threshold (so a small load crosses it) but a floor of 3 segments.
    var policy = AutoSplitPolicy.with_threshold(
        threshold_records=Int64(5),
        max_partitions=64,
        min_segments_before_split=Int64(3),
    )

    # A freshly-forked child: it crossed the (tiny) threshold on its first flush
    # but has only 1 segment (< floor 3) -> SKIP_FRESH_FLOOR (no instant
    # re-split — the anti-storm guard).
    var fresh = evaluate_split(policy, Int64(10), Int64(1), 2)
    assert_equal(
        fresh.kind,
        SPLIT_DECISION_SKIP_FRESH_FLOOR,
        "over threshold but under segment floor -> SKIP_FRESH_FLOOR",
    )
    assert_false(fresh.should_propose, "fresh child must not propose")

    # Once it has accumulated enough segments (>= floor) AND is over threshold,
    # it becomes split-eligible.
    var matured = evaluate_split(policy, Int64(10), Int64(3), 2)
    assert_equal(
        matured.kind,
        SPLIT_DECISION_PROPOSE,
        "over threshold AND at segment floor -> PROPOSE",
    )
    print("  fresh-child floor prevents instant re-split OK")
    print("[test_fresh_child_floor_prevents_instant_resplit] PASS")


# =============================================================================
# (4) Idempotent split_topic_if_live — concurrent-proposal no-double-split.
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


def test_split_if_live_idempotent_on_retired_pid() raises:
    print("[test_split_if_live_idempotent_on_retired_pid] starting...")
    var store = SharedInMemoryConditionalStore()
    var cluster = String("trig")
    var topic = String("idem-topic")

    # Auto seed (1 partition pid 0). Produce a few records so pid 0's manifest
    # has a tail to freeze at.
    var seed = PartitionMap.auto_seed()
    persist_create_if_absent[_Store](store, cluster, topic, seed)
    var broker0 = _make_broker(store, cluster, topic, 0)
    for i in range(5):
        var rb = _make_int64_batch(Int64(100 + i))
        _ = broker0.produce(rb^, Int64(i))
        _ = broker0.flush_if_buffered(Int64(i + 1))
    _ = broker0^

    # FIRST proposal: pid 0 is live -> the split lands (Some).
    var m0 = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_manifest_prefix(cluster, topic, 0),
        retry=RetryPolicy.fast_test(),
    )
    var first = split_topic_if_live[_Store](store, cluster, topic, m0^, 0)
    assert_true(first.__bool__(), "first proposal on a live pid must split")
    assert_equal(first.value().parent_pid, 0, "first split parent pid 0")
    var v_after_first = read_partition_map_with_etag[_Store](
        store, cluster, topic
    ).map.version
    print("  first proposal landed: split pid 0 (map v", v_after_first, ")")

    # SECOND proposal on the SAME (now-retired) pid 0: a clean no-op (None),
    # NOT a double-split, NOT an error — the concurrent-proposal idempotence.
    var m0b = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_manifest_prefix(cluster, topic, 0),
        retry=RetryPolicy.fast_test(),
    )
    var second = split_topic_if_live[_Store](store, cluster, topic, m0b^, 0)
    assert_false(
        second.__bool__(),
        "second proposal on a retired pid must be a clean None (no double-split)",
    )
    # The map version did NOT advance again (no second split happened).
    var v_after_second = read_partition_map_with_etag[_Store](
        store, cluster, topic
    ).map.version
    assert_equal(
        v_after_second,
        v_after_first,
        "no second split: map version unchanged after the no-op proposal",
    )
    print("  second proposal on retired pid 0: clean no-op (map still v",
          v_after_second, ") OK")
    print("[test_split_if_live_idempotent_on_retired_pid] PASS")


def main() raises:
    test_threshold_below_and_above()
    test_max_partitions_cap_halts_and_warns()
    test_fresh_child_floor_prevents_instant_resplit()
    test_split_if_live_idempotent_on_retired_pid()
    print(
        "[OK] test_partition_trigger_unit — threshold gating, max_partitions"
        " cap + warning, freshly-forked-child floor, and concurrent-proposal"
        " idempotence (split on retired pid is a clean no-op)"
    )

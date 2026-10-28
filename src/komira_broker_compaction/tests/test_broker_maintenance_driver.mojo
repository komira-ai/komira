# =============================================================================
# test_broker_maintenance_driver.mojo
#   The run-once maintenance library end to end
# =============================================================================
#
# Drives `run_maintenance_pass` over the clone-shared in-memory
# ConditionalWriteStore (the substrate the broker offline tests use). It
# exercises the enumerate, dispatch-by-policy and assert logic.
#
# The fixture builds a cluster with three topics:
#   * "compactT" (cleanup.policy=compact): dup-key records across 3 chunks.
#     After the pass: the cleaner kept latest-per-key (superseded duplicates
#     gone, fewer live rows than produced).
#   * "deleteT" (cleanup.policy=delete, time-retention): an old prefix chunk and
#     a fresh chunk. After the pass: retention advanced log_start past the old
#     chunk (it was tombstoned).
#   * "compactDeleteT" (cleanup.policy=compact,delete): exercises the run-both
#     arm: the cleaner deduped and retention advanced.
#
# Baseline: without the pass, compaction never runs (all dup records survive)
# and retention never advances (log_start stays at 0), shown by
# test_red_no_maintenance.
#
# Run-once: `run_maintenance_pass` is a plain function that returns a summary;
# there is no loop, daemon or sleep. Calling it once performs all the work;
# calling it again is an idempotent no-op (the manifest CAS and the
# already-compacted state mean the second pass finds nothing to do).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.string_array import StringArray

from komira_broker.broker_core import (
    BrokerCore,
    BrokerTopicConfig,
    _topic_config_key,
)
from komira_broker.consume_core import ConsumeCore
from komira_broker.log_compaction import (
    CLEANUP_POLICY_COMPACT,
    CLEANUP_POLICY_DELETE,
    CLEANUP_POLICY_COMPACT_DELETE,
    decode_compacted_survivor_offsets,
)
from komira_broker.partition_trigger import AutoMergePolicy

from komira_broker_compaction.maintenance import (
    run_maintenance_pass,
    enumerate_topics,
    maintain_topic,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream


comptime _Store = SharedInMemoryConditionalStore


# =============================================================================
# helpers — (key:INT64, value:STRING-nullable) batch; tombstone = null value.
# =============================================================================


def _kv_schema() raises -> Schema:
    return Schema(
        names=[String("key"), String("value")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.STRING.type_id],
        dtypes=[DType.int64, DType.uint8],
        nullables=[False, True],
    )


def _make_kv_batch(
    keys: List[Int64], values: List[String], valids: List[Bool]
) raises -> RecordBatch:
    var n = len(keys)
    var karr = PrimitiveArray[DType.int64].allocate(n)
    var p = karr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, keys[i])
    var kcol = Column.from_primitive[DType.int64](karr^)
    var varr = StringArray.from_strings_with_validity(values, valids)
    var vcol = Column.from_string(varr^)
    return RecordBatch.from_typed_columns_2(_kv_schema(), kcol^, vcol^)


def _prefix(cluster: String, topic: String, partition: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(partition)


def _make_broker(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> BrokerCore[_Store]:
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=partition,
        broker_id=String("broker-A"),
    )


def _write_topic_config(
    store: _Store,
    cluster: String,
    topic: String,
    cleanup_policy: Int64,
    num_partitions: Int,
    retention_ms: Int64,
    delete_retention_ms: Int64,
) raises:
    """Persist the topic-config object (what the producer's `_persist_topic_config`
    writes the first time a topic is produced to) so the maintenance pass can
    enumerate the topic + read its policy."""
    var cfg = BrokerTopicConfig(
        num_partitions=num_partitions,
        partition_by=List[String](),
        schema=_kv_schema(),
        retention_ms=retention_ms,
        retention_bytes=Int64(-1),
        cleanup_policy=cleanup_policy,
        delete_retention_ms=delete_retention_ms,
    )
    var s = store.clone()
    _ = s.put(Path.parse(_topic_config_key(cluster, topic)), cfg.encode())


def _count_live_rows(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> Int:
    """Drain the partition back + count every surviving row across all live
    chunks (the post-compaction live-row count)."""
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    var consume = ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=partition,
    )
    var index = consume.resolve_index()
    var total = 0
    for i in range(len(index)):
        ref s = index[i]
        var seg = consume.read_segment(s.copy())
        var stream = seg^.take_stream_bytes()
        var batch = decode_arrow_ipc_stream(stream^)
        total += batch.num_rows()
    _ = consume^
    return total


def _log_start_seq(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> Int64:
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    var ls = manifest.read_log_start()
    _ = manifest^
    return ls.log_start_seq


# =============================================================================
# Fixtures — build the three topics.
# =============================================================================


def _build_compact_topic(
    store: _Store, cluster: String, topic: String, base_ts: Int64
) raises:
    """3-chunk compact partition (9 produced records, k1 written 4x, k2 2x):
      CHUNK 0 (offsets 0..4): k1->v1@0, k2->v2@1, k1->v3@2, k1->v4@3, k3->v5@4
      CHUNK 1 (offsets 5..6): k2->v6@5, k4->v7@6
      CHUNK 2 (ACTIVE 7..8):  k1->v8@7, k5->v9@8  (never compacted)
    Cleanable latest-per-key (chunks 0+1): k1->v4@3, k2->v6@5, k3->v5@4,
    k4->v7@6 => 4 survivors; 3 dropped (v1@0, v3@2, v2@1)."""
    var broker = _make_broker(store, cluster, topic, Int64(0))
    var b0 = _make_kv_batch(
        [Int64(1), Int64(2), Int64(1), Int64(1), Int64(3)],
        [String("v1"), String("v2"), String("v3"), String("v4"), String("v5")],
        [True, True, True, True, True],
    )
    _ = broker.produce(b0^, base_ts)
    _ = broker.flush_if_buffered(base_ts)
    var b1 = _make_kv_batch(
        [Int64(2), Int64(4)], [String("v6"), String("v7")], [True, True]
    )
    _ = broker.produce(b1^, base_ts + Int64(1000))
    _ = broker.flush_if_buffered(base_ts + Int64(1000))
    var b2 = _make_kv_batch(
        [Int64(1), Int64(5)], [String("v8"), String("v9")], [True, True]
    )
    _ = broker.produce(b2^, base_ts + Int64(2000))
    _ = broker.flush_if_buffered(base_ts + Int64(2000))
    _ = broker^
    _write_topic_config(
        store, cluster, topic, CLEANUP_POLICY_COMPACT, 1, Int64(-1),
        Int64(86_400_000),
    )


def _build_delete_topic(
    store: _Store, cluster: String, topic: String, cleanup_policy: Int64
) raises:
    """3-chunk delete partition. CHUNK 0 created at ts=1000 (OLD), CHUNK 1 at
    ts=2000, CHUNK 2 (ACTIVE) at ts=3000. With a retention_ms of 10_000 + the
    pass's now_ms=100_000, the oldest non-active chunks (0,1) are past
    retention => retention tombstones them + advances log_start past them."""
    var broker = _make_broker(store, cluster, topic, Int64(0))
    var b0 = _make_kv_batch(
        [Int64(10), Int64(11)], [String("a"), String("b")], [True, True]
    )
    _ = broker.produce(b0^, Int64(1000))
    _ = broker.flush_if_buffered(Int64(1000))
    var b1 = _make_kv_batch(
        [Int64(12), Int64(13)], [String("c"), String("d")], [True, True]
    )
    _ = broker.produce(b1^, Int64(2000))
    _ = broker.flush_if_buffered(Int64(2000))
    var b2 = _make_kv_batch(
        [Int64(14), Int64(15)], [String("e"), String("f")], [True, True]
    )
    _ = broker.produce(b2^, Int64(3000))
    _ = broker.flush_if_buffered(Int64(3000))
    _ = broker^
    _write_topic_config(
        store, cluster, topic, cleanup_policy, 1, Int64(10_000), Int64(10_000)
    )


# =============================================================================
# (RED) WITHOUT the maintenance pass, nothing runs.
# =============================================================================


def test_red_no_maintenance() raises:
    print("[test_red_no_maintenance] starting...")
    var store = _Store()
    var cluster = String("maintRED")
    _build_compact_topic(store, cluster, String("compactT"), Int64(1000))
    _build_delete_topic(store, cluster, String("deleteT"), CLEANUP_POLICY_DELETE)

    # No pass run → compact topic keeps ALL 9 produced rows (no dedup).
    assert_equal(
        _count_live_rows(store, cluster, String("compactT"), Int64(0)),
        9,
        "RED: WITHOUT maintenance, all 9 produced rows survive (no compaction)",
    )
    # No pass run → delete topic's log_start stays at 0 (no retention).
    assert_equal(
        _log_start_seq(store, cluster, String("deleteT"), Int64(0)),
        Int64(0),
        "RED: WITHOUT maintenance, log_start stays at 0 (no retention)",
    )
    _ = store^
    print("[test_red_no_maintenance] PASS")


# =============================================================================
# enumerate_topics finds every config.json topic on both backends' listing.
# =============================================================================


def test_enumerate_topics() raises:
    print("[test_enumerate_topics] starting...")
    var store = _Store()
    var cluster = String("maintENUM")
    _build_compact_topic(store, cluster, String("compactT"), Int64(1000))
    _build_delete_topic(store, cluster, String("deleteT"), CLEANUP_POLICY_DELETE)
    _build_delete_topic(
        store, cluster, String("compactDeleteT"), CLEANUP_POLICY_COMPACT_DELETE
    )

    var topics = enumerate_topics[_Store](store.clone(), cluster)
    assert_equal(len(topics), 3, "3 topics enumerated from config.json keys")
    var have_compact = False
    var have_delete = False
    var have_both = False
    for i in range(len(topics)):
        if topics[i] == String("compactT"):
            have_compact = True
        elif topics[i] == String("deleteT"):
            have_delete = True
        elif topics[i] == String("compactDeleteT"):
            have_both = True
    assert_true(have_compact, "compactT enumerated")
    assert_true(have_delete, "deleteT enumerated")
    assert_true(have_both, "compactDeleteT enumerated")
    _ = store^
    print("[test_enumerate_topics] PASS")


# =============================================================================
# (GREEN) the run-once pass compacts the compact topic + GC's the delete topic.
# =============================================================================


def test_maintenance_pass_runs_all_policies() raises:
    print("[test_maintenance_pass_runs_all_policies] starting...")
    var store = _Store()
    var cluster = String("maintRUN")
    _build_compact_topic(store, cluster, String("compactT"), Int64(1000))
    _build_delete_topic(store, cluster, String("deleteT"), CLEANUP_POLICY_DELETE)
    _build_delete_topic(
        store, cluster, String("compactDeleteT"), CLEANUP_POLICY_COMPACT_DELETE
    )

    # ONE run-once pass at now_ms=100_000 (old delete chunks past the 10_000
    # retention window → tombstoned; compact topic dedup'd).
    var summary = run_maintenance_pass[_Store](
        store.clone(), cluster, Int64(100_000), AutoMergePolicy.default()
    )
    assert_equal(summary.topics_scanned, 3, "3 topics scanned in one pass")
    assert_equal(len(summary.errors), 0, "no per-topic errors")

    # --- compact topic: superseded duplicates GONE (fewer rows than produced) ---
    # Cleanable survivors {v4@3, v5@4, v6@5, v7@6} (4) + active {v8@7, v9@8} (2)
    # = 6 live rows (down from 9 produced).
    var compact_rows = _count_live_rows(
        store, cluster, String("compactT"), Int64(0)
    )
    assert_equal(
        compact_rows, 6,
        "compact topic: 6 live rows after compaction (down from 9 produced)",
    )

    # --- delete topic: retention advanced log_start past the old chunks ---
    # CHUNK 0 (ts=1000) + CHUNK 1 (ts=2000) are both past now_ms-retention
    # (100_000 - 10_000 = 90_000) → tombstoned; the new first-live chunk is the
    # ACTIVE chunk (seq 2).
    assert_true(
        _log_start_seq(store, cluster, String("deleteT"), Int64(0))
        > Int64(0),
        "delete topic: retention advanced log_start past the old chunks",
    )

    # --- compact,delete topic: BOTH arms ran (orchestrate-both) ---
    # Its build is the delete fixture (distinct keys per chunk → compaction has
    # no superseded dups to drop, but it DID run + retention advanced log_start).
    assert_true(
        _log_start_seq(store, cluster, String("compactDeleteT"), Int64(0))
        > Int64(0),
        "compact,delete topic: retention arm advanced log_start (both arms ran)",
    )

    # Per-topic summary cross-check: the compact topic dropped 3 records, the
    # delete topics each tombstoned >=1 chunk.
    var saw_compact_drops = False
    var saw_retention = False
    for i in range(len(summary.per_topic)):
        ref t = summary.per_topic[i]
        if t.topic == String("compactT"):
            assert_equal(
                t.records_dropped, Int64(3),
                "compactT dropped 3 superseded records (v1@0,v3@2,v2@1)",
            )
            assert_equal(t.cleanup_policy, CLEANUP_POLICY_COMPACT, "policy=compact")
            saw_compact_drops = True
        elif t.topic == String("deleteT"):
            assert_true(
                t.retention_tombstoned > Int64(0),
                "deleteT retention tombstoned >=1 chunk",
            )
            saw_retention = True
    assert_true(saw_compact_drops, "compactT summary present")
    assert_true(saw_retention, "deleteT summary present")
    _ = store^
    print("[test_maintenance_pass_runs_all_policies] PASS")


# =============================================================================
# (GREEN) RUN-ONCE + IDEMPOTENT: a second pass is a clean no-op.
# =============================================================================


def test_maintenance_pass_idempotent_runs_once() raises:
    print("[test_maintenance_pass_idempotent_runs_once] starting...")
    var store = _Store()
    var cluster = String("maintIDEM")
    _build_compact_topic(store, cluster, String("compactT"), Int64(1000))

    # First pass: compacts (3 records dropped).
    var s1 = run_maintenance_pass[_Store](
        store.clone(), cluster, Int64(100_000), AutoMergePolicy.default()
    )
    assert_equal(s1.topics_scanned, 1, "pass 1 scanned the 1 topic")
    var rows_after_1 = _count_live_rows(
        store, cluster, String("compactT"), Int64(0)
    )
    assert_equal(rows_after_1, 6, "after pass 1: 6 live rows")
    var dropped_1 = s1.total_records_dropped()
    assert_equal(dropped_1, Int64(3), "pass 1 dropped the 3 superseded records")

    # Second pass over the SAME store: the cleaner finds nothing more to drop
    # (the compacted chunk is already latest-per-key) — IDEMPOTENT no-op. This is
    # the run-once contract: scheduler invokes -> ONE pass each tick -> exit; a
    # re-run (a retry of a crashed pass, or the next tick before new writes)
    # converges, never double-compacts.
    var s2 = run_maintenance_pass[_Store](
        store.clone(), cluster, Int64(200_000), AutoMergePolicy.default()
    )
    var rows_after_2 = _count_live_rows(
        store, cluster, String("compactT"), Int64(0)
    )
    assert_equal(
        rows_after_2, 6,
        "after pass 2: STILL 6 live rows (idempotent — no further compaction)",
    )
    assert_equal(
        s2.total_records_dropped(), Int64(0),
        "pass 2 dropped 0 records (already compacted — clean re-run no-op)",
    )
    _ = store^
    print("[test_maintenance_pass_idempotent_runs_once] PASS")


# =============================================================================
# (GREEN) a bad topic (corrupt config) is logged + SKIPPED, not a hard error.
# =============================================================================


def test_bad_topic_skipped_not_fatal() raises:
    print("[test_bad_topic_skipped_not_fatal] starting...")
    var store = _Store()
    var cluster = String("maintBAD")
    _build_compact_topic(store, cluster, String("goodT"), Int64(1000))
    # A corrupt config.json for a second "topic" — decode will raise, the pass
    # must log it into summary.errors + SKIP it, NOT abort the whole pass.
    var bad_bytes = List[UInt8]()
    for c in String("{ this is not valid config json").as_bytes():
        bad_bytes.append(c)
    var s = store.clone()
    _ = s.put(
        Path.parse(_topic_config_key(cluster, String("badT"))), bad_bytes
    )

    var summary = run_maintenance_pass[_Store](
        store.clone(), cluster, Int64(100_000), AutoMergePolicy.default()
    )
    assert_equal(summary.topics_scanned, 2, "both topics enumerated")
    # The good topic still got maintained (1 per_topic entry).
    assert_equal(
        len(summary.per_topic), 1, "the good topic was maintained"
    )
    assert_equal(
        summary.per_topic[0].topic, String("goodT"), "goodT maintained"
    )
    # The bad topic is recorded as a skipped error — NOT a raised abort.
    assert_equal(len(summary.errors), 1, "the bad topic was logged + skipped")
    assert_true(
        summary.errors[0].find(String("badT")) >= 0,
        "the skipped-error names the bad topic",
    )
    _ = store^
    print("[test_bad_topic_skipped_not_fatal] PASS")


def main() raises:
    test_red_no_maintenance()
    test_enumerate_topics()
    test_maintenance_pass_runs_all_policies()
    test_maintenance_pass_idempotent_runs_once()
    test_bad_topic_skipped_not_fatal()
    print(
        "[OK] test_broker_maintenance_driver — 5 maintenance"
        " tests passed (RED no-maintenance baseline, topic enumeration,"
        " run-once pass dispatches all policies [compact dedup + delete"
        " retention + compact,delete orchestrate-both], idempotent re-run"
        " no-op [the RUN-ONCE contract], bad-topic skipped-not-fatal — offline,"
        " drives the library entry point)"
    )

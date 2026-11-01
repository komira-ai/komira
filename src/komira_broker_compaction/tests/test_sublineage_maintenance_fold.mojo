# =============================================================================
# test_sublineage_maintenance_fold.mojo
#   The sub-lineage fold and sub-lineage-aware retention, driven by the
#   run-once maintenance library (`run_sublineage_maintenance_pass`)
# =============================================================================
#
# What it checks:
#
#   THE MAINTENANCE PASS FOLDS: set up a topic with sub-lineage data on an
#     enabled partition (per-shard `_lineage/<shard>` tails), then drive
#     `run_sublineage_maintenance_pass`. Assert: records_folded > 0, the `_base`
#     manifest exists after the pass, the live-tail shard count drops to 0, and
#     a subsequent consume reads dense and without loss across the fold
#     (identical to the pre-fold serve).
#                                  [test_maintenance_folds_enabled_partition]
#
#   DISCRIMINATING: running only the legacy `run_maintenance_pass` does not fold
#     the per-shard tails: no `_base` is written and the live-tail shard count
#     stays at its pre-pass value. With the sub-lineage pass it folds. Same
#     store, same data; the only difference is whether the sub-lineage pass ran.
#                                  [test_legacy_pass_alone_does_not_fold]
#
#   OPT-IN: the legacy `run_maintenance_pass` over a topic with no sub-lineage
#     data (a plain single-manifest partition) enumerates the topic, runs its
#     retention, and leaves the partition's manifest untouched by any
#     sub-lineage logic. A caller that does not pass the sub-lineage flag runs
#     only this pass; this asserts that run is unaffected by the sub-lineage
#     code.
#                                  [test_default_off_legacy_pass_unchanged]
#
#   IDEMPOTENT: a second `run_sublineage_maintenance_pass` over the already
#     folded store is a no-op (records_folded == 0) and the consume stays dense
#     and stable. This models a re-run after a crashed scheduler tick.
#                                  [test_maintenance_pass_idempotent]
#
# Offline assembly (no network):
#   * Each write sub-lineage `<part>/_lineage/<shard>` is populated by a
#     BrokerCore bound to that prefix (the segment write path; val is a unique
#     per-record identity, so a decoded batch's `val` column is the record id).
#   * A topic config.json is persisted at `<cluster>/_meta/topics/<topic>/
#     config.json` so the maintenance enumeration finds the topic.
#   * The maintenance library drives the fold and the sub-lineage-aware
#     retention; the sub-lineage consume resolver reads the resulting `_base`
#     and serve tail.
#
# No UnsafePointer in any signature, no wildcard origins, no
# unsafe_from_address / take_pointee. Substrate held / built by value.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_broker.broker_core import BrokerCore, BrokerTopicConfig
from komira_broker.consume_core import ConsumeCore, SegmentRef
from komira_broker.sublineage_consume import SubLineageConsumeResolver
from komira_broker.sublineage_segment_fold import SegmentBaseFold

from komira_broker_compaction.maintenance import (
    run_maintenance_pass,
    run_sublineage_maintenance_pass,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream


comptime _Store = SharedInMemoryConditionalStore
comptime _CLUSTER = String("c")
comptime _TOPIC = String("t")


# =============================================================================
# helpers — partition / shard prefixes, topic config, producers, consume.
# =============================================================================


def _partition_prefix(cluster: String, topic: String, pid: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


def _shard_prefix(base_prefix: String, shard_id: String) -> String:
    return base_prefix + "/_lineage/" + shard_id


def _topic_config_key(cluster: String, topic: String) -> String:
    return cluster + "/_meta/topics/" + topic + "/config.json"


def _persist_topic_config(
    store: _Store, cluster: String, topic: String, num_partitions: Int
) raises:
    """Persist a topic's `BrokerTopicConfig` to `<cluster>/_meta/topics/<topic>/
    config.json` so the maintenance enumeration finds the topic (the durable
    record a runtime CreateTopics / a producer's first write writes). Retention
    DISABLED (-1 / -1) so the fold's `_base` is not reaped under the test clock
    — we assert the FOLD, separately from the retention reap."""
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var cfg = BrokerTopicConfig(
        num_partitions=num_partitions,
        partition_by=List[String](),
        schema=schema^,
        retention_ms=Int64(-1),
        retention_bytes=Int64(-1),
    )
    _ = store.put(Path.parse(_topic_config_key(cluster, topic)), cfg.encode())


def _make_int64_batch(vals: List[Int64]) raises -> RecordBatch:
    """ONE-column `val:INT64` batch (val == the record's unique identity)."""
    var n = len(vals)
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, vals[i])
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _broker_at(
    store: _Store, prefix: String, pid: Int64
) raises -> BrokerCore[_Store]:
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=String(prefix), retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=_CLUSTER,
        topic=_TOPIC,
        partition=pid,
        broker_id=String("broker-A"),
    )


def _produce_one_chunk(
    store: _Store, base_prefix: String, shard: String, vals: List[Int64],
    now_ms: Int64,
) raises:
    """Buffer one batch of `vals` to source shard `shard` and FLUSH it as exactly
    ONE chunk/segment (the segment write path)."""
    var broker = _broker_at(store, _shard_prefix(base_prefix, shard), Int64(0))
    broker.buffer_batch(_make_int64_batch(vals), now_ms)
    _ = broker.flush(now_ms)
    _ = broker^


def _l(a: Int64, b: Int64) -> List[Int64]:
    var x = List[Int64]()
    x.append(a)
    x.append(b)
    return x^


def _consume_core_at(store: _Store, prefix: String) raises -> ConsumeCore[_Store]:
    return ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=CasManifestStore[_Store](
            store=store.clone(),
            prefix=String(prefix),
            retry=RetryPolicy.fast_test(),
        ),
        cluster=_CLUSTER,
        topic=_TOPIC,
        partition=Int64(0),
    )


def _resolve_dense_vals(store: _Store, index: List[SegmentRef]) raises -> List[Int64]:
    """Read each segment in dense-offset order, decode it, flatten the `val`
    column. `out[O]` is the record id at dense offset O."""
    var out = List[Int64]()
    var consume = _consume_core_at(store, String("unused"))
    for i in range(len(index)):
        var seg = consume.read_segment(index[i].copy())
        var batch = decode_arrow_ipc_stream(seg^.take_stream_bytes())
        var arr = batch.column_at(0).as_primitive[DType.int64]()
        for r in range(batch.num_rows()):
            out.append(arr.get(r))
    _ = consume^
    return out^


def _resolver_dense_vals(store: _Store, base_prefix: String) raises -> List[Int64]:
    """The full combined dense index (folded `_base` + serve-merged tail) ->
    the flat dense record-id list."""
    var resolver = SubLineageConsumeResolver[_Store](
        store.clone(), String(base_prefix)
    )
    var index = resolver.resolve_index()
    _ = resolver^
    return _resolve_dense_vals(store, index)


def _live_tail_shards(store: _Store, base_prefix: String) raises -> Int:
    """The live un-folded-tail shard count for this partition — the L-bound
    component the fold shrinks (read via the production fold's `bound_stats`)."""
    var fold = SegmentBaseFold[_Store](store.clone(), String(base_prefix))
    var b = fold.bound_stats()
    _ = fold^
    return b.live_tail_shards


def _has_base(store: _Store, base_prefix: String) raises -> Bool:
    var resolver = SubLineageConsumeResolver[_Store](
        store.clone(), String(base_prefix)
    )
    var hb = resolver.has_base()
    _ = resolver^
    return hb


def _write_three_shard_tail(store: _Store, bp: String) raises:
    """w00:{1,2}, w01:{101,102}, w02:{201,202} (interleaved write order).
    Canonical merge -> dense [1,2,101,102,201,202]."""
    _produce_one_chunk(store, bp, String("w02"), _l(Int64(201), Int64(202)), Int64(1))
    _produce_one_chunk(store, bp, String("w00"), _l(Int64(1), Int64(2)), Int64(1))
    _produce_one_chunk(store, bp, String("w01"), _l(Int64(101), Int64(102)), Int64(1))


# =============================================================================
# THE MAINTENANCE PASS ACTUALLY FOLDS — the make-or-break gate.
# =============================================================================


def test_maintenance_folds_enabled_partition() raises:
    """Set up a topic with sub-lineage data on partition 0, drive the maintenance
    LIBRARY `run_sublineage_maintenance_pass`, and assert the per-shard tails
    FOLD: records_folded > 0, `_base` exists, the live-tail shard count drops to
    0 (the L-bound shrinks), AND a subsequent consume reads dense / no-loss
    across the fold."""
    var store = _Store()
    var bp = _partition_prefix(_CLUSTER, _TOPIC, Int64(0))
    _persist_topic_config(store, _CLUSTER, _TOPIC, 1)
    _write_three_shard_tail(store, bp)

    # Pin the pre-fold serve (the whole tail, dense) + the live-tail width.
    var pre = _resolver_dense_vals(store, bp)
    assert_equal(len(pre), 6, "pre-fold serve dense [0..5]")
    assert_equal(_live_tail_shards(store, bp), 3, "3 un-folded source shards pre-pass")
    assert_false(_has_base(store, bp), "no `_base` before the maintenance pass")

    # Drive the MAINTENANCE pass (the fold trigger).
    var summary = run_sublineage_maintenance_pass[_Store](
        store.clone(), _CLUSTER, Int64(10)
    )
    assert_equal(summary.topics_scanned, 1, "the one persisted topic enumerated")
    assert_equal(len(summary.errors), 0, "no per-topic errors")
    assert_true(
        summary.total_records_folded() == Int64(6),
        "all 6 tail records folded by the maintenance pass",
    )
    assert_equal(len(summary.per_topic), 1, "one topic result")
    assert_equal(
        summary.per_topic[0].folded_partitions, 1, "partition 0 folded"
    )

    # The L-bound SHRANK: zero un-folded source tails after the fold.
    assert_equal(
        _live_tail_shards(store, bp), 0, "live-tail shard count DROPS to 0 (L shrinks)"
    )
    assert_true(_has_base(store, bp), "after the pass -> `_base` persisted")

    # CONSUME reads dense / no-loss across the fold (byte-identical to pre).
    var post = _resolver_dense_vals(store, bp)
    assert_equal(len(post), 6, "post-fold dense range unchanged [0..5]")
    for o in range(6):
        assert_equal(
            post[o], pre[o],
            "dense offset " + String(o) + " is the SAME record post-fold",
        )
    print("[test_maintenance_folds_enabled_partition] PASS")


# =============================================================================
# DISCRIMINATING — red-without-fold / green-with.
# =============================================================================


def test_legacy_pass_alone_does_not_fold() raises:
    """The legacy `run_maintenance_pass` alone does not fold the per-shard
    sub-lineage tails: no `_base` is written and the live-tail shard count
    stays at 3. The sub-lineage pass on the same store and data folds them. The
    only difference is whether the sub-lineage pass ran.

    Without the sub-lineage arm, the assertions in the second half below
    (records_folded, live_tail == 0, has_base) could not hold: the live tail
    would stay at 3."""
    var store = _Store()
    var bp = _partition_prefix(_CLUSTER, _TOPIC, Int64(0))
    _persist_topic_config(store, _CLUSTER, _TOPIC, 1)
    _write_three_shard_tail(store, bp)

    # --- RED: the legacy pass ALONE leaves the sub-lineage tails un-folded. ---
    var legacy = run_maintenance_pass[_Store](store.clone(), _CLUSTER, Int64(10))
    assert_equal(legacy.topics_scanned, 1, "legacy pass enumerates the topic")
    # The legacy retention/compaction/merge arms operate on the partition's OWN
    # single manifest (`<part>`), NOT the sub-lineage `_lineage/` subtree — so
    # the per-shard tails are UNTOUCHED.
    assert_false(
        _has_base(store, bp), "legacy pass writes NO `_base` (no sub-lineage fold)"
    )
    assert_equal(
        _live_tail_shards(store, bp), 3,
        "legacy pass leaves the live tail LARGE (3 un-folded shards) — L unbounded",
    )

    # --- GREEN: the sub-lineage pass on the SAME store FOLDS the tail. ---
    var sublin = run_sublineage_maintenance_pass[_Store](
        store.clone(), _CLUSTER, Int64(20)
    )
    assert_true(
        sublin.total_records_folded() == Int64(6),
        "sub-lineage pass folds the tail the legacy pass left",
    )
    assert_true(_has_base(store, bp), "sub-lineage pass writes `_base`")
    assert_equal(
        _live_tail_shards(store, bp), 0, "sub-lineage pass shrinks the live tail to 0"
    )
    print("[test_legacy_pass_alone_does_not_fold] PASS (RED-without / GREEN-with)")


# =============================================================================
# OPT-IN: the legacy pass over non-sub-lineage data is unchanged.
# =============================================================================


def test_default_off_legacy_pass_unchanged() raises:
    """A topic with NO sub-lineage data — a plain single-manifest partition
    (records written directly at `<part>`, NOT under `_lineage/`). The legacy
    `run_maintenance_pass` (the whole run when the sub-lineage flag is off)
    enumerates and dispatches as it always did: the partition's own manifest is
    untouched by any sub-lineage logic, and the dense consume over the
    partition's own manifest is byte-for-byte unchanged.

    This shows the opt-in boundary: the presence of the sub-lineage
    library code does NOT change the legacy pass's behavior on a non-sub-lineage
    partition (the legacy pass never reaches the sub-lineage arm)."""
    var store = _Store()
    var bp = _partition_prefix(_CLUSTER, _TOPIC, Int64(0))
    _persist_topic_config(store, _CLUSTER, _TOPIC, 1)

    # Legacy: a single consolidated manifest DIRECTLY at the partition prefix
    # (NOT under `_lineage/`) — the production single-manifest shape.
    var broker = _broker_at(store, bp, Int64(0))
    broker.buffer_batch(_make_int64_batch(_l(Int64(0), Int64(1))), Int64(1))
    _ = broker.flush(Int64(1))
    broker.buffer_batch(_make_int64_batch(_l(Int64(2), Int64(3))), Int64(2))
    _ = broker.flush(Int64(2))
    _ = broker^

    # The legacy pass runs (retention disabled in the config -> nothing reaped).
    var legacy = run_maintenance_pass[_Store](store.clone(), _CLUSTER, Int64(3))
    assert_equal(legacy.topics_scanned, 1, "legacy pass enumerates the topic")
    assert_equal(len(legacy.errors), 0, "no per-topic errors")

    # No `_base` exists (this partition was never sub-lineage; the legacy pass
    # creates none).
    assert_false(_has_base(store, bp), "no `_base` on the legacy path")

    # The legacy single-manifest dense resolve is byte-for-byte unchanged: [0..3].
    var consume = _consume_core_at(store, bp)
    var index = consume.resolve_index()
    var vals = _resolve_dense_vals(store, index)
    _ = consume^
    assert_equal(len(vals), 4, "legacy dense [0..3] unchanged")
    for o in range(4):
        assert_equal(vals[o], Int64(o), "legacy val == absolute offset (unchanged)")
    print("[test_default_off_legacy_pass_unchanged] PASS")


# =============================================================================
# IDEMPOTENT / CRASH-SAFE — a re-run after a crash is a no-op.
# =============================================================================


def test_maintenance_pass_idempotent() raises:
    """A SECOND `run_sublineage_maintenance_pass` over an already-folded store is
    a clean no-op (records_folded == 0) and the consume stays dense / stable.
    Models a re-run after a crashed scheduler tick — the fold re-derives the
    per-shard fold cursor from the durable `_LOG_START` + sees the already-
    advanced state, so it folds nothing new."""
    var store = _Store()
    var bp = _partition_prefix(_CLUSTER, _TOPIC, Int64(0))
    _persist_topic_config(store, _CLUSTER, _TOPIC, 1)
    _write_three_shard_tail(store, bp)

    var pre = _resolver_dense_vals(store, bp)
    assert_equal(len(pre), 6, "pre-fold dense [0..5]")

    # First pass folds.
    var s1 = run_sublineage_maintenance_pass[_Store](
        store.clone(), _CLUSTER, Int64(10)
    )
    assert_true(s1.total_records_folded() == Int64(6), "first pass folds 6")

    # Second pass (the crash re-run) is a clean no-op.
    var s2 = run_sublineage_maintenance_pass[_Store](
        store.clone(), _CLUSTER, Int64(11)
    )
    assert_equal(
        s2.total_records_folded(), Int64(0), "second pass folds NOTHING (idempotent)"
    )
    assert_equal(len(s2.errors), 0, "no errors on the re-run")

    # The consume stays dense / stable across the no-op re-run.
    var post = _resolver_dense_vals(store, bp)
    assert_equal(len(post), 6, "still [0..5] after the no-op re-run")
    for o in range(6):
        assert_equal(post[o], pre[o], "dense offset stable across re-run")
    print("[test_maintenance_pass_idempotent] PASS")


def main() raises:
    test_maintenance_folds_enabled_partition()
    test_legacy_pass_alone_does_not_fold()
    test_default_off_legacy_pass_unchanged()
    test_maintenance_pass_idempotent()
    print("ALL test_sublineage_maintenance_fold PASS")

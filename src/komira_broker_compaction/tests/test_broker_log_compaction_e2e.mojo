# =============================================================================
# test_broker_log_compaction_e2e.mojo
#   The log cleaner end to end (real Arrow-IPC `.seg`)
# =============================================================================
#
# The offline test in `komira_broker` (test_broker_log_compaction_offline.mojo)
# covers the pure decision, the manifest-body swap and the survivor-offset
# sidecar invariant, but it keeps the original `.seg` (that cleaner never
# re-encodes one).
#
# This test exercises the cleaner in `log_cleaner_driver.mojo`: it produces real
# Arrow-IPC `.seg`s to a `cleanup.policy=compact` partition and runs
# `ProductionLogCleaner.run_once` (decode cleanable `.seg`s, keep the
# latest-per-key survivors with wall-clock tombstone grace, re-encode the
# survivors as a new `.seg`, PUT it, CAS-swap the chunk body, and schedule the
# orphaned original `.seg` for GC). It then consumes the partition back through
# the broker's own ConsumeCore and decode path and asserts:
#
#   * survivors == latest-per-key, at the original offsets (including gaps);
#   * a tombstone is dropped once past `delete_retention_ms` (driven via the
#     segment `creation_ts_ms` vs the cleaner's `now_ms`);
#   * the active chunk's records are untouched;
#   * the orphaned original `.seg` is reaped after the grace window
#     (CompactionReapWorker), and not before.
#
# Baseline: without the cleaner, consuming returns all produced records.
# test_red_baseline_no_production_cleaner consumes without running the cleaner
# and asserts the full pre-compaction row count.
#
# Offline: the clone-shared in-memory ConditionalWriteStore
# (SharedInMemoryConditionalStore), the same substrate the other broker tests
# use.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.string_array import StringArray

from komira_broker.broker_core import BrokerCore, BrokerTopicConfig
from komira_broker.consume_core import ConsumeCore, SegmentRef
from komira_broker.manifest_body import ManifestBody
from komira_broker.log_compaction import (
    CompactionConfig,
    decode_compacted_survivor_offsets,
    CLEANUP_POLICY_COMPACT,
)

from komira_broker_compaction.log_cleaner_driver import (
    ProductionLogCleaner,
    ProductionCleanResult,
    CompactionReapWorker,
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
    """A (key:INT64, value:STRING-nullable) batch. `valids[i]==False` makes row i
    a TOMBSTONE (null value)."""
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


def _make_consume(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> ConsumeCore[_Store]:
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    return ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=partition,
    )


def _make_cleaner(
    store: _Store,
    cluster: String,
    topic: String,
    partition: Int64,
    config: CompactionConfig,
) raises -> ProductionLogCleaner[_Store]:
    var consume = _make_consume(store, cluster, topic, partition)
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    return ProductionLogCleaner[_Store](
        consume=consume^,
        segment_store=store.clone(),
        manifest=manifest^,
        config=config,
        cluster=cluster,
        topic=topic,
        partition=partition,
        key_col=0,
        value_col=1,
    )


# -----------------------------------------------------------------------------
# _ConsumedRow / _consume_all — drain a partition back into (key, value, tomb,
# abs_offset) tuples, computing each row's ABSOLUTE offset from the manifest's
# per-chunk base + the survivor-offset sidecar (a compacted chunk is SPARSE: its
# rows sit at their PRESERVED original offsets, NOT base+row).
# -----------------------------------------------------------------------------


@fieldwise_init
struct _ConsumedRow(Copyable, Movable, Deinitable):
    var key: Int64
    var value: String
    var is_tombstone: Bool
    var abs_offset: Int64


def _consume_all(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> List[_ConsumedRow]:
    """Consume the WHOLE partition back (every live chunk in offset order),
    decode each `.seg`, and emit one `_ConsumedRow` per surviving row at its
    PRESERVED absolute offset. For a compacted chunk the absolute offset of row
    `r` is `sidecar[r]` (the survivor-offset sidecar); for an un-compacted chunk
    it is `base_offset + r`."""
    var consume = _make_consume(store, cluster, topic, partition)
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    var index = consume.resolve_index()
    var out = List[_ConsumedRow]()
    for i in range(len(index)):
        ref s = index[i]
        # The survivor-offset sidecar (empty for an un-compacted chunk).
        var chunk_body = manifest.read_chunk(s.chunk_seq)
        var sidecar = decode_compacted_survivor_offsets(chunk_body)
        # GET + decode the `.seg` → one RecordBatch.
        var seg = consume.read_segment(s.copy())
        var stream = seg^.take_stream_bytes()
        var batch = decode_arrow_ipc_stream(stream^)
        var nrows = batch.num_rows()
        for r in range(nrows):
            var key = batch.column_value(0, r)
            var sa = batch.column_as_string(1)
            var tomb = sa.is_null(r)
            var val = String("") if tomb else sa.get(r)
            var abs_off: Int64
            if len(sidecar) == nrows:
                abs_off = sidecar[r]  # compacted: PRESERVED original offset.
            else:
                abs_off = s.base_offset + Int64(r)  # un-compacted: base+row.
            out.append(
                _ConsumedRow(
                    key=key,
                    value=val^,
                    is_tombstone=tomb,
                    abs_offset=abs_off,
                )
            )
    _ = manifest^
    _ = consume^
    return out^


def _has_offset(rows: List[_ConsumedRow], off: Int64) -> Bool:
    for i in range(len(rows)):
        if rows[i].abs_offset == off:
            return True
    return False


def _value_at_offset(rows: List[_ConsumedRow], off: Int64) -> String:
    for i in range(len(rows)):
        if rows[i].abs_offset == off:
            return String(rows[i].value)
    return String("<absent>")


# =============================================================================
# Build a 3-chunk compact partition:
#   CHUNK 0 (cleanable, offsets 0..4): k1->v1@0, k2->v2@1, k1->v3@2,
#                                      k1->null(TOMBSTONE)@3, k3->v4@4
#   CHUNK 1 (cleanable, offsets 5..6): k2->v5@5, k4->v6@6
#   CHUNK 2 (ACTIVE,    offsets 7..8): k1->v7@7, k5->v8@8   (never compacted)
# `chunk_ts` stamps each chunk's creation_ts (drives the wall-clock grace gate).
# =============================================================================


def _build_compact_partition(
    store: _Store,
    cluster: String,
    topic: String,
    partition: Int64,
    chunk0_ts: Int64,
    chunk1_ts: Int64,
    chunk2_ts: Int64,
) raises:
    var broker = _make_broker(store, cluster, topic, partition)
    # CHUNK 0 (cleanable): 5 records, k1 thrice (latest = tombstone @3).
    var b0 = _make_kv_batch(
        [Int64(1), Int64(2), Int64(1), Int64(1), Int64(3)],
        [String("v1"), String("v2"), String("v3"), String(""), String("v4")],
        [True, True, True, False, True],
    )
    _ = broker.produce(b0^, chunk0_ts)
    _ = broker.flush_if_buffered(chunk0_ts)
    # CHUNK 1 (cleanable): k2->v5 (supersedes chunk0 v2@1), k4->v6.
    var b1 = _make_kv_batch(
        [Int64(2), Int64(4)], [String("v5"), String("v6")], [True, True]
    )
    _ = broker.produce(b1^, chunk1_ts)
    _ = broker.flush_if_buffered(chunk1_ts)
    # CHUNK 2 (ACTIVE): k1->v7, k5->v8 — never compacted.
    var b2 = _make_kv_batch(
        [Int64(1), Int64(5)], [String("v7"), String("v8")], [True, True]
    )
    _ = broker.produce(b2^, chunk2_ts)
    _ = broker.flush_if_buffered(chunk2_ts)
    _ = broker^


# =============================================================================
# (RED) WITHOUT the production cleaner, consume returns ALL produced records.
# =============================================================================


def test_red_baseline_no_production_cleaner() raises:
    print("[test_red_baseline_no_production_cleaner] starting...")
    var store = _Store()
    var cluster = String("e2eRED")
    var topic = String("compactT")
    var pid = Int64(0)
    _build_compact_partition(
        store, cluster, topic, pid, Int64(1000), Int64(2000), Int64(3000)
    )

    # NO cleaner run → consume sees every produced record (9 total: 5+2+2).
    var rows = _consume_all(store, cluster, topic, pid)
    assert_equal(
        len(rows), 9,
        "RED: WITHOUT the cleaner, all 9 produced records survive (no dedup)",
    )
    # The superseded duplicates are STILL present (the RED signal the cleaner
    # eliminates): k1's v1@0 and v3@2, and k2's v2@1.
    assert_true(_has_offset(rows, Int64(0)), "RED: offset 0 (k1 v1) present")
    assert_true(_has_offset(rows, Int64(1)), "RED: offset 1 (k2 v2) present")
    assert_true(_has_offset(rows, Int64(2)), "RED: offset 2 (k1 v3) present")
    assert_equal(
        _value_at_offset(rows, Int64(0)), String("v1"),
        "RED: offset 0 still holds the superseded v1",
    )
    _ = store^
    print("[test_red_baseline_no_production_cleaner] PASS")


# =============================================================================
# (GREEN) WITH the production cleaner (tombstone IN-GRACE) — survivors at
# preserved offsets, gaps where superseded; active chunk untouched.
# =============================================================================


def test_production_cleaner_in_grace() raises:
    print("[test_production_cleaner_in_grace] starting...")
    var store = _Store()
    var cluster = String("e2eGRACE")
    var topic = String("compactT")
    var pid = Int64(0)
    # All chunks young: cleaner now_ms=10_000, chunks at 1000/2000/3000 with a
    # 24h grace → no tombstone is grace-expired.
    _build_compact_partition(
        store, cluster, topic, pid, Int64(1000), Int64(2000), Int64(3000)
    )

    var cleaner = _make_cleaner(
        store, cluster, topic, pid, CompactionConfig.compact(Int64(86_400_000))
    )
    var res = cleaner.run_once(Int64(10_000))
    _ = cleaner^
    assert_true(res.ran, "cleaner ran")
    assert_equal(res.cleanable_chunks, Int64(2), "2 cleanable chunks (0,1)")
    assert_equal(res.records_scanned, Int64(7), "7 records scanned (chunks 0+1)")
    # Cleanable-range latest-per-key: k1->tombstone@3 (in grace, retained),
    # k2->v5@5 (chunk1 supersedes chunk0 v2@1), k3->v4@4, k4->v6@6 → 4 survivors;
    # 3 dropped (v1@0, v3@2, v2@1).
    assert_equal(res.survivors, Int64(4), "4 survivors (k1 tomb, k2 v5, k3, k4)")
    assert_equal(res.dropped, Int64(3), "3 dropped (v1@0, v3@2, v2@1)")
    # Only CHUNK 0 has local drops (v1@0, v2@1, v3@2 → keeps tomb@3, v4@4).
    # CHUNK 1's two records (k2->v5@5, k4->v6@6) are BOTH global latest-per-key,
    # so chunk 1 is already clean → SKIPPED (no re-encode, no orphan). This is
    # the idempotency property: a chunk with no local drops is never rewritten.
    assert_equal(res.chunks_rewritten, Int64(1), "only chunk 0 had local drops")
    assert_equal(res.orphans_scheduled, Int64(1), "1 orphaned `.seg` scheduled")

    # CONSUME the partition back.
    var rows = _consume_all(store, cluster, topic, pid)
    # Survivors: chunk0 {tomb@3, v4@4}, chunk1 {v5@5, v6@6}, active {v7@7, v8@8}.
    # Total = 6 rows.
    assert_equal(len(rows), 6, "6 rows after compaction (4 cleanable + 2 active)")

    # OFFSETS PRESERVED WITH GAPS — chunk 0 survivors at 3,4 (gaps at 0,1,2);
    # chunk 1 survivors at 5,6; active at 7,8.
    assert_false(_has_offset(rows, Int64(0)), "offset 0 (k1 v1) GONE — gap")
    assert_false(_has_offset(rows, Int64(1)), "offset 1 (k2 v2) GONE — gap")
    assert_false(_has_offset(rows, Int64(2)), "offset 2 (k1 v3) GONE — gap")
    assert_true(_has_offset(rows, Int64(3)), "offset 3 (k1 tombstone) PRESERVED")
    assert_true(_has_offset(rows, Int64(4)), "offset 4 (k3 v4) PRESERVED")
    assert_true(_has_offset(rows, Int64(5)), "offset 5 (k2 v5) PRESERVED")
    assert_true(_has_offset(rows, Int64(6)), "offset 6 (k4 v6) PRESERVED")

    # LATEST-PER-KEY values at their preserved offsets.
    assert_equal(
        _value_at_offset(rows, Int64(4)), String("v4"), "k3 latest = v4 @4"
    )
    assert_equal(
        _value_at_offset(rows, Int64(5)), String("v5"), "k2 latest = v5 @5"
    )
    assert_equal(
        _value_at_offset(rows, Int64(6)), String("v6"), "k4 latest = v6 @6"
    )
    # k1's surviving cleanable record @3 is the TOMBSTONE.
    var tomb_at_3 = False
    for i in range(len(rows)):
        if rows[i].abs_offset == Int64(3) and rows[i].is_tombstone:
            tomb_at_3 = True
    assert_true(tomb_at_3, "k1 survivor @3 is the in-grace tombstone")

    # ACTIVE chunk UNTOUCHED — v7@7 + v8@8 present, dense (no gaps in 7..8).
    assert_true(_has_offset(rows, Int64(7)), "active offset 7 (k1 v7) present")
    assert_true(_has_offset(rows, Int64(8)), "active offset 8 (k5 v8) present")
    assert_equal(
        _value_at_offset(rows, Int64(7)), String("v7"),
        "active chunk untouched — v7 @7 (NOT compacted against k1's earlier recs)",
    )

    # record_count PRESERVED (never renumber) — chunk 0 still reports 5, chunk 1
    # still 2, active still 2.
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    var mb0 = ManifestBody.decode(manifest.read_chunk(Int64(0)))
    assert_equal(mb0.record_count, Int64(5), "chunk 0 record_count PRESERVED (5)")
    var mb1 = ManifestBody.decode(manifest.read_chunk(Int64(1)))
    assert_equal(mb1.record_count, Int64(2), "chunk 1 record_count PRESERVED (2)")
    var mb2 = ManifestBody.decode(manifest.read_chunk(Int64(2)))
    assert_equal(mb2.record_count, Int64(2), "active chunk 2 record_count = 2")
    # The active chunk has NO survivor sidecar (never compacted).
    assert_equal(
        len(decode_compacted_survivor_offsets(manifest.read_chunk(Int64(2)))),
        0, "active chunk 2 NOT compacted (no sidecar)",
    )
    _ = manifest^
    _ = store^
    print("[test_production_cleaner_in_grace] PASS")


# =============================================================================
# (GREEN) tombstone PAST GRACE — dropped; k1 fully deleted (no survivor at @3).
# =============================================================================


def test_production_cleaner_past_grace() raises:
    print("[test_production_cleaner_past_grace] starting...")
    var store = _Store()
    var cluster = String("e2eEXPIRE")
    var topic = String("compactT")
    var pid = Int64(0)
    # CHUNK 0 created at ts=1000; cleaner now_ms=100_000 with a 10_000 grace →
    # chunk 0 age = 99_000 >= 10_000 → its tombstone is GRACE-EXPIRED → dropped.
    # CHUNK 1 created at ts=2000 (also old, but it has no tombstone).
    _build_compact_partition(
        store, cluster, topic, pid, Int64(1000), Int64(2000), Int64(3000)
    )

    var cleaner = _make_cleaner(
        store, cluster, topic, pid, CompactionConfig.compact(Int64(10_000))
    )
    var res = cleaner.run_once(Int64(100_000))
    _ = cleaner^
    assert_true(res.ran, "cleaner ran")
    # Past-grace: k1's latest is the tombstone @3, grace-expired → k1 fully
    # deleted (no survivor). Survivors: k2->v5@5, k3->v4@4, k4->v6@6 → 3.
    assert_equal(
        res.survivors, Int64(3),
        "3 survivors past-grace (k1 deleted: tombstone dropped)",
    )

    var rows = _consume_all(store, cluster, topic, pid)
    # Cleanable survivors {v4@4, v5@5, v6@6} + active {v7@7, v8@8} = 5 rows.
    assert_equal(len(rows), 5, "5 rows past-grace (k1 dropped from cleanable)")
    # k1's tombstone @3 is GONE (past grace).
    assert_false(
        _has_offset(rows, Int64(3)),
        "offset 3 (k1 tombstone) DROPPED past grace — key fully deleted",
    )
    assert_false(_has_offset(rows, Int64(0)), "offset 0 (k1 v1) gone")
    assert_false(_has_offset(rows, Int64(2)), "offset 2 (k1 v3) gone")
    # The non-k1 survivors are intact at preserved offsets.
    assert_true(_has_offset(rows, Int64(4)), "k3 v4 @4 preserved")
    assert_true(_has_offset(rows, Int64(5)), "k2 v5 @5 preserved")
    assert_true(_has_offset(rows, Int64(6)), "k4 v6 @6 preserved")
    # Active chunk still has k1->v7@7 (compaction never touches the active region;
    # the active k1 record is a SEPARATE live value, not deleted by the cleanable
    # tombstone).
    assert_true(
        _has_offset(rows, Int64(7)),
        "active k1 v7 @7 survives (active region untouched by compaction)",
    )
    _ = store^
    print("[test_production_cleaner_past_grace] PASS")


# =============================================================================
# (GREEN) the orphaned original `.seg` is reaped AFTER grace, not before.
# =============================================================================


def test_orphan_seg_grace_gated_gc() raises:
    print("[test_orphan_seg_grace_gated_gc] starting...")
    var store = _Store()
    var cluster = String("e2eGC")
    var topic = String("compactT")
    var pid = Int64(0)
    _build_compact_partition(
        store, cluster, topic, pid, Int64(1000), Int64(2000), Int64(3000)
    )

    # Capture chunk 0's ORIGINAL `.seg` key BEFORE compaction (the orphan).
    var manifest0 = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    var orig0 = ManifestBody.decode(manifest0.read_chunk(Int64(0)))
    var orphan_key = String(orig0.object_key)
    _ = manifest0^
    # The original `.seg` exists pre-compaction.
    assert_true(
        _object_exists(store, orphan_key), "original chunk-0 `.seg` exists"
    )

    # Compact (cleaner now_ms = 10_000; orphan markers stamped at 10_000).
    var cleaner = _make_cleaner(
        store, cluster, topic, pid, CompactionConfig.compact(Int64(86_400_000))
    )
    var res = cleaner.run_once(Int64(10_000))
    _ = cleaner^
    # Only chunk 0 had local drops → 1 orphan (chunk 1 is clean, not rewritten).
    assert_equal(res.orphans_scheduled, Int64(1), "1 orphan scheduled (chunk 0)")

    # The chunk body now points at a DIFFERENT (compacted) `.seg`; the original
    # is still present (scheduled, not yet reaped).
    var manifest1 = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    var swapped0 = ManifestBody.decode(manifest1.read_chunk(Int64(0)))
    assert_true(
        String(swapped0.object_key) != orphan_key,
        "chunk 0 body swapped to a new compacted `.seg` key",
    )
    _ = manifest1^
    assert_true(
        _object_exists(store, orphan_key),
        "orphaned original `.seg` still present (scheduled, pre-grace)",
    )

    # Reap BEFORE grace elapses (orphan stamped @10_000, grace 60_000, run at
    # 20_000 → age 10_000 < 60_000 → NOT reaped).
    var reaper_early = _make_reaper(store, cluster, topic, pid, Int64(60_000))
    var r_early = reaper_early.run(Int64(20_000))
    _ = reaper_early^
    assert_equal(r_early, Int64(0), "pre-grace: 0 orphans reaped")
    assert_true(
        _object_exists(store, orphan_key),
        "pre-grace: orphan `.seg` still present (grace not elapsed)",
    )

    # Reap AFTER grace (run at 100_000 → age 90_000 >= 60_000 → reaped).
    var reaper_late = _make_reaper(store, cluster, topic, pid, Int64(60_000))
    var r_late = reaper_late.run(Int64(100_000))
    _ = reaper_late^
    assert_equal(r_late, Int64(1), "post-grace: the chunk-0 orphan reaped")
    assert_false(
        _object_exists(store, orphan_key),
        "post-grace: orphaned original `.seg` REAPED",
    )

    # The compacted partition still consumes correctly after the orphan GC
    # (the live compacted `.seg`s are NOT touched by the reaper).
    var rows = _consume_all(store, cluster, topic, pid)
    assert_equal(
        len(rows), 6, "partition still consumes 6 survivors after orphan GC"
    )
    assert_true(_has_offset(rows, Int64(4)), "k3 v4 @4 still readable post-GC")
    _ = store^
    print("[test_orphan_seg_grace_gated_gc] PASS")


def _make_reaper(
    store: _Store, cluster: String, topic: String, partition: Int64,
    grace_ms: Int64,
) raises -> CompactionReapWorker[_Store]:
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    return CompactionReapWorker[_Store](
        segment_store=store.clone(), manifest=manifest^, grace_ms=grace_ms
    )


def _object_exists(store: _Store, key: String) raises -> Bool:
    var s = store.clone()
    try:
        var _b = s.get(Path.parse(key))
        _ = _b
        return True
    except e:
        var msg = String(e)
        if (
            msg.find("not_found") >= 0
            or msg.find("NotFound") >= 0
            or msg.find("404") >= 0
            or msg.find("NoSuchKey") >= 0
        ):
            return False
        raise e^


def main() raises:
    test_red_baseline_no_production_cleaner()
    test_production_cleaner_in_grace()
    test_production_cleaner_past_grace()
    test_orphan_seg_grace_gated_gc()
    print(
        "[OK] test_broker_log_compaction_e2e — 4 PRODUCTION log-compaction"
        " tests passed (RED-baseline all-records, in-grace latest-per-key at"
        " PRESERVED offsets with gaps + active untouched, past-grace tombstone"
        " drop + key fully deleted, orphan `.seg` grace-gated GC — real"
        " Arrow-IPC `.seg` re-encode, offline)"
    )

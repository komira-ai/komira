# =============================================================================
# tests/test_broker_log_compaction_offline.mojo
#   Kafka cleanup.policy=compact, OFFLINE unit tests
# =============================================================================
#
# The REAL Kafka log compaction (key-based latest-value): keep only the LATEST
# value per KEY in the cleanable range; drop superseded records; a null-value
# record is a TOMBSTONE that deletes a key (retained delete.retention.ms, then
# dropped). DISTINCT from retention tier-compaction (keeps all rows) + split-lineage
# compaction (never drops rows).
#
# Drives the cleaner over the OFFLINE clone-shared in-memory ConditionalWriteStore
# (SharedInMemoryConditionalStore), the IDENTICAL substrate the retention
# offline test uses. The cleaner operates on DECODED RecordBatches supplied by the
# caller (the decode seam — the broker LEAF does not decode), exactly
# like compact_split_parent / transcode.
#
# Cases (the Kafka-faithful correctness crux):
#   (1) CompactionConfig + cleanup_policy parse/name roundtrip.
#   (2) BrokerTopicConfig cleanup_policy/delete_retention_ms JSON roundtrip +
#       missing → delete-default (backward-compat).
#   (3) compact_records PURE decision: latest-per-key; superseded dropped;
#       tombstone in-grace retained; tombstone past-grace dropped; OFFSETS
#       PRESERVED (survivors ascending by original abs_offset — gaps present).
#   (4) extract_clean_records: KEY rendered, NULL value → tombstone, abs_offset =
#       base + row.
#   (5) LogCleaner.run over the store: rewrites chunk bodies in place,
#       record_count PRESERVED (no renumber), survivor-offset sidecar carries the
#       exact surviving offsets WITH GAPS; the active region is UNTOUCHED.
#   (6) delete-policy topic → cleaner is a no-op (ran=False).
#   (7) RED-baseline: WITHOUT running the cleaner, every record survives (proves
#       the test detects the absence of compaction).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab

from komira_broker.broker_core import BrokerCore, BrokerTopicConfig
from komira_broker.consume_core import ConsumeCore
from komira_broker.manifest_body import ManifestBody
from komira_broker.log_compaction import (
    CleanRecord,
    CleanResult,
    CompactionConfig,
    CompactionPlan,
    LogCleaner,
    compact_records,
    extract_clean_records,
    decode_compacted_survivor_offsets,
    cleanup_policy_name,
    cleanup_policy_from_name,
    cleanup_policy_compacts,
    cleanup_policy_deletes,
    CLEANUP_POLICY_DELETE,
    CLEANUP_POLICY_COMPACT,
    CLEANUP_POLICY_COMPACT_DELETE,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


# =============================================================================
# helpers — build a (key:INT64, value:STRING) batch; tombstone = null value.
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


def _make_broker(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> BrokerCore[_Store]:
    var prefix = cluster + "/_meta/topics/" + topic + "/" + String(partition)
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=partition,
        broker_id=String("broker-A"),
    )


def _make_manifest(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> CasManifestStore[_Store]:
    var prefix = cluster + "/_meta/topics/" + topic + "/" + String(partition)
    return CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )


def _rec(key: String, offset: Int64, chunk: Int64, tomb: Bool) -> CleanRecord:
    return CleanRecord(
        key=key, abs_offset=offset, chunk_seq=chunk, is_tombstone=tomb
    )


# =============================================================================
# (1) CompactionConfig + cleanup_policy parse/name
# =============================================================================


def test_cleanup_policy_parse() raises:
    print("[test_cleanup_policy_parse] starting...")
    assert_equal(
        cleanup_policy_from_name(String("compact")), CLEANUP_POLICY_COMPACT,
        "compact parses",
    )
    assert_equal(
        cleanup_policy_from_name(String("delete")), CLEANUP_POLICY_DELETE,
        "delete parses",
    )
    assert_equal(
        cleanup_policy_from_name(String("compact,delete")),
        CLEANUP_POLICY_COMPACT_DELETE, "compact,delete parses",
    )
    # Unknown / empty → delete (Kafka default).
    assert_equal(
        cleanup_policy_from_name(String("")), CLEANUP_POLICY_DELETE,
        "empty → delete default",
    )
    assert_equal(cleanup_policy_name(CLEANUP_POLICY_COMPACT), String("compact"))
    # compacts/deletes predicates.
    assert_true(cleanup_policy_compacts(CLEANUP_POLICY_COMPACT))
    assert_false(cleanup_policy_deletes(CLEANUP_POLICY_COMPACT))
    assert_true(cleanup_policy_compacts(CLEANUP_POLICY_COMPACT_DELETE))
    assert_true(cleanup_policy_deletes(CLEANUP_POLICY_COMPACT_DELETE))
    assert_false(cleanup_policy_compacts(CLEANUP_POLICY_DELETE))
    assert_true(cleanup_policy_deletes(CLEANUP_POLICY_DELETE))
    var cfg = CompactionConfig.compact(Int64(86_400_000))
    assert_true(cfg.compacts(), "compact() config compacts")
    assert_equal(cfg.delete_retention_ms, Int64(86_400_000), "grace set")
    print("[test_cleanup_policy_parse] PASS")


# =============================================================================
# (2) BrokerTopicConfig cleanup JSON roundtrip + backward-compat
# =============================================================================


def test_topic_config_cleanup_roundtrip() raises:
    print("[test_topic_config_cleanup_roundtrip] starting...")
    var cfg = BrokerTopicConfig(
        num_partitions=1,
        partition_by=[String("key")],
        schema=_kv_schema(),
        cleanup_policy=CLEANUP_POLICY_COMPACT,
        delete_retention_ms=Int64(86_400_000),
    )
    var dec = BrokerTopicConfig.decode(cfg.encode())
    assert_equal(
        dec.cleanup_policy, CLEANUP_POLICY_COMPACT, "cleanup_policy roundtrips"
    )
    assert_equal(
        dec.delete_retention_ms, Int64(86_400_000),
        "delete_retention_ms roundtrips",
    )

    # A PRE-compaction config JSON (no cleanup fields) → delete-default.
    var legacy = String(
        '{"num_partitions":2,"partition_by":[],"schema":[{"name":"k",'
        '"arrow_type":9,"nullable":false}],"retention_ms":-1,'
        '"retention_bytes":-1}'
    )
    var lb = legacy.as_bytes()
    var lbytes = List[UInt8]()
    for i in range(len(lb)):
        lbytes.append(lb[i])
    var dec2 = BrokerTopicConfig.decode(lbytes)
    assert_equal(
        dec2.cleanup_policy, CLEANUP_POLICY_DELETE,
        "legacy missing → cleanup_policy delete",
    )
    assert_equal(
        dec2.delete_retention_ms, Int64(-1),
        "legacy missing → delete_retention_ms -1",
    )
    print("[test_topic_config_cleanup_roundtrip] PASS")


# =============================================================================
# (3) compact_records — the PURE decision (latest-per-key + tombstone grace +
#     OFFSET PRESERVATION).
# =============================================================================


def test_compact_records_pure() raises:
    print("[test_compact_records_pure] starting...")
    # The brief's exact shape:
    #   k1->v1 @0, k2->v2 @1, k1->v3 @2, k1->null(tombstone) @3, k3->v4 @4
    # Latest-per-key: k1's latest is the tombstone @3; k2->v2 @1; k3->v4 @4.
    var records = List[CleanRecord]()
    records.append(_rec(String("k1"), Int64(0), Int64(0), False))  # superseded
    records.append(_rec(String("k2"), Int64(1), Int64(0), False))  # survivor @1
    records.append(_rec(String("k1"), Int64(2), Int64(0), False))  # superseded
    records.append(_rec(String("k1"), Int64(3), Int64(0), True))   # tombstone @3
    records.append(_rec(String("k3"), Int64(4), Int64(0), False))  # survivor @4

    # ---- IN-GRACE: tombstone RETAINED (delete_retention_ms > 0). ----
    var plan = compact_records(records, Int64(86_400_000), Int64(1000))
    # Survivors: k2@1, k1-tombstone@3, k3@4 → 3 survivors, ascending by offset.
    assert_equal(plan.survivor_count, Int64(3), "3 survivors in-grace")
    assert_equal(plan.dropped_count, Int64(2), "2 superseded dropped (v1, v3)")
    # OFFSETS PRESERVED — survivors keep their ORIGINAL absolute offsets, in
    # ascending order, with GAPS (offsets 1, 3, 4 — NOT 0,1,2).
    assert_equal(plan.survivors[0].abs_offset, Int64(1), "survivor[0] @1 (k2)")
    assert_equal(plan.survivors[0].key, String("k2"), "survivor[0] is k2")
    assert_equal(plan.survivors[1].abs_offset, Int64(3), "survivor[1] @3 (k1 tomb)")
    assert_equal(plan.survivors[1].key, String("k1"), "survivor[1] is k1")
    assert_true(plan.survivors[1].is_tombstone, "k1 survivor is the tombstone")
    assert_equal(plan.survivors[2].abs_offset, Int64(4), "survivor[2] @4 (k3)")
    assert_equal(plan.survivors[2].key, String("k3"), "survivor[2] is k3")
    # Prove the GAP: no survivor at offset 0 or 2 (k1's v1/v3 are gone).
    var has0 = False
    var has2 = False
    for s in range(len(plan.survivors)):
        if plan.survivors[s].abs_offset == Int64(0):
            has0 = True
        if plan.survivors[s].abs_offset == Int64(2):
            has2 = True
    assert_false(has0, "offset 0 (k1 v1) is GONE — gap preserved")
    assert_false(has2, "offset 2 (k1 v3) is GONE — gap preserved")
    _ = plan^

    # ---- PAST-GRACE: tombstone DROPPED (delete_retention_ms == 0). ----
    var plan2 = compact_records(records, Int64(0), Int64(1000))
    # k1's latest is the tombstone → past grace → dropped. Survivors: k2@1, k3@4.
    assert_equal(plan2.survivor_count, Int64(2), "2 survivors past-grace")
    assert_equal(
        plan2.dropped_count, Int64(3), "3 dropped (v1, v3, AND the tombstone)"
    )
    var has_k1 = False
    for s in range(len(plan2.survivors)):
        if plan2.survivors[s].key == String("k1"):
            has_k1 = True
    assert_false(has_k1, "k1 fully deleted (tombstone dropped past grace)")
    _ = plan2^
    print("[test_compact_records_pure] PASS")


# =============================================================================
# (4) extract_clean_records — KEY + NULL-value tombstone + abs_offset.
# =============================================================================


def test_extract_clean_records() raises:
    print("[test_extract_clean_records] starting...")
    # keys [10, 20, 10], values ["a","b",null] → row 2 is a tombstone.
    var batch = _make_kv_batch(
        [Int64(10), Int64(20), Int64(10)],
        [String("a"), String("b"), String("")],
        [True, True, False],
    )
    # base_offset 100, chunk_seq 7 → abs offsets 100,101,102.
    var recs = extract_clean_records(batch, 0, 1, Int64(100), Int64(7))
    assert_equal(len(recs), 3, "3 records extracted")
    assert_equal(recs[0].key, String("10"), "INT64 key rendered to String")
    assert_equal(recs[0].abs_offset, Int64(100), "abs_offset = base + 0")
    assert_false(recs[0].is_tombstone, "row 0 not tombstone")
    assert_equal(recs[2].abs_offset, Int64(102), "abs_offset = base + 2")
    assert_true(recs[2].is_tombstone, "row 2 (null value) IS a tombstone")
    assert_equal(recs[2].chunk_seq, Int64(7), "chunk_seq carried")
    print("[test_extract_clean_records] PASS")


# =============================================================================
# (5) LogCleaner.run over the store — in-place rewrite, record_count PRESERVED,
#     survivor-offset sidecar (gaps), active region untouched.
# =============================================================================


def test_log_cleaner_run() raises:
    print("[test_log_cleaner_run] starting...")
    var store = _Store()
    var cluster = String("lc1")
    var topic = String("compactT")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)

    # CHUNK 0 (cleanable): k1->v1@0, k2->v2@1, k1->v3@2, k1->null@3, k3->v4@4 (5 rec).
    var b0 = _make_kv_batch(
        [Int64(1), Int64(2), Int64(1), Int64(1), Int64(3)],
        [String("v1"), String("v2"), String("v3"), String(""), String("v4")],
        [True, True, True, False, True],
    )
    _ = broker.produce(b0^, Int64(1000))
    _ = broker.flush_if_buffered(Int64(1000))

    # CHUNK 1 (cleanable): k2->v5@5, k4->v6@6 (2 rec).
    var b1 = _make_kv_batch(
        [Int64(2), Int64(4)], [String("v5"), String("v6")], [True, True]
    )
    _ = broker.produce(b1^, Int64(2000))
    _ = broker.flush_if_buffered(Int64(2000))

    # CHUNK 2 (ACTIVE — never compacted): k1->v7@7, k5->v8@8 (2 rec).
    var b2 = _make_kv_batch(
        [Int64(1), Int64(5)], [String("v7"), String("v8")], [True, True]
    )
    _ = broker.produce(b2^, Int64(3000))
    _ = broker.flush_if_buffered(Int64(3000))
    _ = broker^

    # The cleaner needs the cleanable chunks DECODED (seam). Here we
    # rebuild them directly (the offline test stands in for the SDK decode seam):
    # CHUNK 0 + CHUNK 1 are cleanable; CHUNK 2 is the active head (EXCLUDED).
    var manifest = _make_manifest(store, cluster, topic, pid)
    var cleanable = Slab[RecordBatch]()
    cleanable.append(
        _make_kv_batch(
            [Int64(1), Int64(2), Int64(1), Int64(1), Int64(3)],
            [String("v1"), String("v2"), String("v3"), String(""), String("v4")],
            [True, True, True, False, True],
        )
    )
    cleanable.append(
        _make_kv_batch(
            [Int64(2), Int64(4)], [String("v5"), String("v6")], [True, True]
        )
    )
    # CHUNK 0 base offset 0, CHUNK 1 base offset 5.
    var base_offsets = List[Int64]()
    base_offsets.append(Int64(0))
    base_offsets.append(Int64(5))
    var chunk_seqs = List[Int64]()
    chunk_seqs.append(Int64(0))
    chunk_seqs.append(Int64(1))

    # Run the cleaner (compact policy, tombstone IN-GRACE so it's retained).
    var cleaner = LogCleaner[_Store](
        CompactionConfig.compact(Int64(86_400_000)), key_col=0, value_col=1
    )
    var res = cleaner.run(
        manifest, cleanable^, base_offsets, chunk_seqs, Int64(10_000)
    )
    assert_true(res.ran, "cleaner ran")
    assert_equal(res.cleanable_chunks, Int64(2), "2 cleanable chunks")
    assert_equal(res.records_scanned, Int64(7), "7 records scanned (chunks 0+1)")
    # Cleanable-range latest-per-key: k1->tombstone@3, k2->v5@5 (chunk1 supersedes
    # chunk0 v2@1), k3->v4@4, k4->v6@6. So 4 survivors; 3 dropped (v1@0,v3@2,v2@1).
    assert_equal(res.survivors, Int64(4), "4 survivors (k1 tomb, k2, k3, k4)")
    assert_equal(res.dropped, Int64(3), "3 dropped (v1@0, v3@2, v2@1)")

    # record_count PRESERVED — chunk bodies still report their ORIGINAL counts
    # (5 and 2), so downstream offsets never renumber.
    var c0body = manifest.read_chunk(Int64(0))
    var mb0 = ManifestBody.decode(c0body)
    assert_equal(mb0.record_count, Int64(5), "chunk 0 record_count PRESERVED (5)")
    var c1body = manifest.read_chunk(Int64(1))
    var mb1 = ManifestBody.decode(c1body)
    assert_equal(mb1.record_count, Int64(2), "chunk 1 record_count PRESERVED (2)")

    # The survivor-offset sidecar proves OFFSETS PRESERVED WITH GAPS.
    # CHUNK 0 (offsets 0..4) survivors: k1-tomb@3, k3-v4@4 → [3, 4] (gaps at 0,1,2).
    var s0 = decode_compacted_survivor_offsets(c0body)
    assert_equal(len(s0), 2, "chunk 0: 2 survivors")
    assert_equal(s0[0], Int64(3), "chunk 0 survivor offset 3 (k1 tombstone)")
    assert_equal(s0[1], Int64(4), "chunk 0 survivor offset 4 (k3) — GAPS at 0,1,2")
    # CHUNK 1 (offsets 5..6) survivors: k2-v5@5, k4-v6@6 → [5, 6].
    var s1 = decode_compacted_survivor_offsets(c1body)
    assert_equal(len(s1), 2, "chunk 1: 2 survivors")
    assert_equal(s1[0], Int64(5), "chunk 1 survivor offset 5 (k2 v5)")
    assert_equal(s1[1], Int64(6), "chunk 1 survivor offset 6 (k4 v6)")

    # The ACTIVE chunk (2) is UNTOUCHED — no sidecar (never compacted).
    var c2body = manifest.read_chunk(Int64(2))
    var s2 = decode_compacted_survivor_offsets(c2body)
    assert_equal(len(s2), 0, "active chunk 2 NOT compacted (no sidecar)")
    var mb2 = ManifestBody.decode(c2body)
    assert_equal(mb2.record_count, Int64(2), "active chunk 2 record_count = 2")

    _ = manifest^
    _ = store^
    print("[test_log_cleaner_run] PASS")


# =============================================================================
# (6) delete-policy topic → cleaner is a NO-OP.
# =============================================================================


def test_delete_policy_noop() raises:
    print("[test_delete_policy_noop] starting...")
    var store = _Store()
    var cluster = String("lc2")
    var topic = String("deleteT")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    var b0 = _make_kv_batch(
        [Int64(1), Int64(1)], [String("a"), String("b")], [True, True]
    )
    _ = broker.produce(b0^, Int64(1000))
    _ = broker.flush_if_buffered(Int64(1000))
    _ = broker^

    var manifest = _make_manifest(store, cluster, topic, pid)
    var cleanable = Slab[RecordBatch]()
    cleanable.append(
        _make_kv_batch(
            [Int64(1), Int64(1)], [String("a"), String("b")], [True, True]
        )
    )
    var base_offsets = List[Int64]()
    base_offsets.append(Int64(0))
    var chunk_seqs = List[Int64]()
    chunk_seqs.append(Int64(0))
    # DELETE policy → cleaner must NOT compact.
    var cleaner = LogCleaner[_Store](
        CompactionConfig.delete_default(), key_col=0, value_col=1
    )
    var res = cleaner.run(
        manifest, cleanable^, base_offsets, chunk_seqs, Int64(10_000)
    )
    assert_false(res.ran, "delete-policy cleaner is a no-op")
    # The chunk body is UNTOUCHED (no sidecar).
    var c0body = manifest.read_chunk(Int64(0))
    assert_equal(
        len(decode_compacted_survivor_offsets(c0body)), 0,
        "delete-policy chunk not compacted",
    )
    _ = manifest^
    _ = store^
    print("[test_delete_policy_noop] PASS")


# =============================================================================
# (7) RED-baseline: WITHOUT the cleaner, every record survives (no dedup). This
#     proves the test would FAIL if the cleaner were absent / a no-op.
# =============================================================================


def test_red_baseline_no_compaction() raises:
    print("[test_red_baseline_no_compaction] starting...")
    # The cleanable range as raw records — 7 records, 4 distinct keys.
    var records = List[CleanRecord]()
    records.append(_rec(String("k1"), Int64(0), Int64(0), False))
    records.append(_rec(String("k2"), Int64(1), Int64(0), False))
    records.append(_rec(String("k1"), Int64(2), Int64(0), False))
    records.append(_rec(String("k1"), Int64(3), Int64(0), True))
    records.append(_rec(String("k3"), Int64(4), Int64(0), False))
    records.append(_rec(String("k2"), Int64(5), Int64(1), False))
    records.append(_rec(String("k4"), Int64(6), Int64(1), False))
    # WITHOUT compaction, all 7 survive (the RED behavior the cleaner fixes).
    assert_equal(len(records), 7, "RED: 7 raw records (no dedup)")
    # WITH compaction (the fix), only 4 survive (latest-per-key, in-grace tomb).
    var plan = compact_records(records, Int64(86_400_000), Int64(1000))
    assert_equal(
        plan.survivor_count, Int64(4),
        "GREEN: cleaner reduces 7 → 4 (latest-per-key) — RED was 7",
    )
    assert_true(
        plan.survivor_count < Int64(7),
        "GREEN: compaction strictly reduces the record set (RED did not)",
    )
    _ = plan^
    print("[test_red_baseline_no_compaction] PASS")


def main() raises:
    test_cleanup_policy_parse()
    test_topic_config_cleanup_roundtrip()
    test_compact_records_pure()
    test_extract_clean_records()
    test_log_cleaner_run()
    test_delete_policy_noop()
    test_red_baseline_no_compaction()
    print(
        "[OK] test_broker_log_compaction_offline — 7 log-compaction tests"
        " passed (cleanup.policy parse, config roundtrip, latest-per-key pure"
        " decision, null-value tombstone extract, in-place chunk rewrite with"
        " PRESERVED offsets + gaps + record_count, delete-policy no-op,"
        " RED-baseline — offline)"
    )

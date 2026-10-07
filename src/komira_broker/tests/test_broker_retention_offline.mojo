# =============================================================================
# tests/test_broker_retention_offline.mojo
#   Retention — OFFLINE unit tests
# =============================================================================
#
# Drives the retention machinery over the OFFLINE clone-shared in-memory
# ConditionalWriteStore (SharedInMemoryConditionalStore), exercising the
# IDENTICAL code path a real object store runs — only the backend differs.
#
# Cases:
#   (1) ManifestBody backward-compat: old 3-field body decodes (-1 trailer);
#       new 5-field body round-trips segment_bytes + creation_ts_ms.
#   (2) BrokerTopicConfig retention_ms/retention_bytes JSON roundtrip +
#       missing → -1.
#   (3) evaluate_retention TIME-based: oldest chunks past retention_ms retire,
#       active chunk never; disabled → 0; unknown ts → skip.
#   (4) evaluate_retention SIZE-based with ACTUAL bytes: keep newest suffix
#       whose cumulative bytes fit; retire the rest oldest-first.
#   (5) RetentionPass over the store: tombstones the right chunks, advances
#       log_start, NO offset gap among survivors (contiguity assert).
#   (6) PERSISTED-tombstone RESTART recovery: tombstone, DROP + rebuild the
#       store handle over the SAME backing data, assert marks SURVIVE (the
#       tombstone FSM persistence).
#   (7) ReapWorker grace enforcement: pre-grace reap = no-op; post-grace
#       deletes; idempotent; fail-loud on reaping a non-tombstoned chunk.
#   (8) CONSUME below log_start surfaces effective_start — NOT a silent
#       renumber; survivors keep correct ABSOLUTE offsets.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_broker.broker_core import (
    BrokerCore,
    BrokerTopicConfig,
)
from komira_broker.manifest_body import (
    ManifestBody,
    encode_manifest_body,
)
from komira_broker.consume_core import ConsumeCore, ConsumeReadResult
from komira_broker.retention import (
    ReapWorker,
    RetentionPolicy,
    RetentionPass,
    RetentionResult,
    evaluate_retention,
    _ChunkMeta,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


# =============================================================================
# helpers
# =============================================================================


def _make_int64_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _make_broker(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> BrokerCore[_Store]:
    var prefix = cluster + "/_meta/topics/" + topic + "/" + String(partition)
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=prefix^,
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
    var prefix = cluster + "/_meta/topics/" + topic + "/" + String(partition)
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=prefix^,
        retry=RetryPolicy.fast_test(),
    )
    return ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=partition,
    )


def _make_manifest(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> CasManifestStore[_Store]:
    var prefix = cluster + "/_meta/topics/" + topic + "/" + String(partition)
    return CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )


# =============================================================================
# (1) ManifestBody backward-compat
# =============================================================================


def test_manifest_body_backward_compat() raises:
    print("[test_manifest_body_backward_compat] starting...")
    # NEW 5-field body round-trips segment_bytes + creation_ts_ms.
    var new_body = encode_manifest_body(
        String("seg-x.seg"), Int64(128), UInt32(0xABCD),
        Int64(4096), Int64(1700000000000),
    )
    var dn = ManifestBody.decode(new_body)
    assert_equal(dn.record_count, Int64(128), "rc preserved")
    assert_equal(dn.crc32, UInt32(0xABCD), "crc preserved")
    assert_equal(dn.object_key, String("seg-x.seg"), "key preserved")
    assert_equal(dn.segment_bytes, Int64(4096), "segment_bytes preserved")
    assert_equal(
        dn.creation_ts_ms, Int64(1700000000000), "creation_ts preserved"
    )

    # OLD 3-field body (no trailer): build it by hand exactly as the legacy
    # encoder did → decode must default the trailer to -1.
    var old_body = List[UInt8]()
    # record_count (i64 LE)
    var rc = UInt64(64)
    for i in range(8):
        old_body.append(UInt8((rc >> UInt64(8 * i)) & UInt64(0xFF)))
    # crc32 (u32 LE)
    var crc = UInt32(0x1234)
    for i in range(4):
        old_body.append(UInt8(Int((crc >> UInt32(8 * i)) & UInt32(0xFF))))
    # key_len (i64 LE) + key bytes
    var key = String("old-seg.seg")
    var kb = key.as_bytes()
    var kl = UInt64(len(kb))
    for i in range(8):
        old_body.append(UInt8((kl >> UInt64(8 * i)) & UInt64(0xFF)))
    for i in range(len(kb)):
        old_body.append(kb[i])
    var do = ManifestBody.decode(old_body)
    assert_equal(do.record_count, Int64(64), "old rc preserved")
    assert_equal(do.object_key, String("old-seg.seg"), "old key preserved")
    assert_equal(do.segment_bytes, Int64(-1), "old body → segment_bytes -1")
    assert_equal(do.creation_ts_ms, Int64(-1), "old body → creation_ts -1")
    print("[test_manifest_body_backward_compat] PASS")


# =============================================================================
# (2) BrokerTopicConfig retention JSON roundtrip + missing → -1
# =============================================================================


def _one_col_schema() raises -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(String("k"), ArrowType(ArrowType.INT64.type_id), False))
    return b.build()


def test_topic_config_retention_roundtrip() raises:
    print("[test_topic_config_retention_roundtrip] starting...")
    var cfg = BrokerTopicConfig(
        num_partitions=3,
        partition_by=[String("k")],
        schema=_one_col_schema(),
        retention_ms=Int64(86400000),
        retention_bytes=Int64(1073741824),
    )
    var enc = cfg.encode()
    var dec = BrokerTopicConfig.decode(enc)
    assert_equal(dec.num_partitions, 3, "num_partitions roundtrips")
    assert_equal(dec.retention_ms, Int64(86400000), "retention_ms roundtrips")
    assert_equal(
        dec.retention_bytes, Int64(1073741824), "retention_bytes roundtrips"
    )

    # Default config (no retention specified) → -1 in the JSON, decodes to -1.
    var cfg2 = BrokerTopicConfig(
        num_partitions=1, partition_by=List[String](), schema=_one_col_schema()
    )
    var dec2 = BrokerTopicConfig.decode(cfg2.encode())
    assert_equal(dec2.retention_ms, Int64(-1), "default retention_ms = -1")
    assert_equal(dec2.retention_bytes, Int64(-1), "default retention_bytes = -1")

    # A PRE-retention config JSON (no retention fields at all) → both default to -1.
    var legacy = String(
        '{"num_partitions":2,"partition_by":[],"schema":[{"name":"k",'
        '"arrow_type":9,"nullable":false}]}'
    )
    var lb = legacy.as_bytes()
    var lbytes = List[UInt8]()
    for i in range(len(lb)):
        lbytes.append(lb[i])
    var dec3 = BrokerTopicConfig.decode(lbytes)
    assert_equal(dec3.num_partitions, 2, "legacy num_partitions parsed")
    assert_equal(dec3.retention_ms, Int64(-1), "legacy missing → retention_ms -1")
    assert_equal(
        dec3.retention_bytes, Int64(-1), "legacy missing → retention_bytes -1"
    )
    print("[test_topic_config_retention_roundtrip] PASS")


# =============================================================================
# (3) evaluate_retention — time-based
# =============================================================================


def _chunk(seq: Int64, base: Int64, rc: Int64, sb: Int64, ts: Int64) -> _ChunkMeta:
    return _ChunkMeta(
        chunk_seq=seq,
        base_offset=base,
        record_count=rc,
        segment_bytes=sb,
        creation_ts_ms=ts,
    )


def test_evaluate_time_based() raises:
    print("[test_evaluate_time_based] starting...")
    var now = Int64(10000)
    # 4 candidate chunks (active chunk EXCLUDED by the caller); creation ts at
    # 1000, 5000, 8000, 9500. retention_ms = 3000 → now - ts > 3000 retires.
    var chunks = List[_ChunkMeta]()
    chunks.append(_chunk(0, 0, 10, 100, Int64(1000)))  # age 9000 > 3000 retire
    chunks.append(_chunk(1, 10, 10, 100, Int64(5000)))  # age 5000 > 3000 retire
    chunks.append(_chunk(2, 20, 10, 100, Int64(8000)))  # age 2000 keep
    chunks.append(_chunk(3, 30, 10, 100, Int64(9500)))  # age 500 keep
    var policy = RetentionPolicy.time_based(Int64(3000))
    assert_equal(
        evaluate_retention(policy, chunks, now), Int64(2),
        "2 oldest chunks past retention_ms retire",
    )

    # disabled → 0
    assert_equal(
        evaluate_retention(RetentionPolicy.disabled(), chunks, now), Int64(0),
        "disabled retires nothing",
    )

    # all young → 0
    assert_equal(
        evaluate_retention(RetentionPolicy.time_based(Int64(100000)), chunks, now),
        Int64(0),
        "all within retention → 0",
    )

    # unknown ts (-1) on chunk 0 → time dimension skips it (stops at first)
    var unk = List[_ChunkMeta]()
    unk.append(_chunk(0, 0, 10, 100, Int64(-1)))  # unknown → skip
    unk.append(_chunk(1, 10, 10, 100, Int64(1000)))  # old but blocked by skip
    assert_equal(
        evaluate_retention(RetentionPolicy.time_based(Int64(3000)), unk, now),
        Int64(0),
        "unknown ts at head blocks time retire (never retire on missing)",
    )
    print("[test_evaluate_time_based] PASS")


# =============================================================================
# (4) evaluate_retention — size-based with ACTUAL bytes
# =============================================================================


def test_evaluate_size_based() raises:
    print("[test_evaluate_size_based] starting...")
    var now = Int64(10000)
    # 4 chunks, each 1000 bytes. retention_bytes = 2500 → keep newest suffix
    # whose cumulative <= 2500: chunks [2,3] = 2000 fits, +chunk1 = 3000 > 2500
    # → keep [2,3], retire [0,1] = 2 chunks.
    var chunks = List[_ChunkMeta]()
    chunks.append(_chunk(0, 0, 10, Int64(1000), Int64(1)))
    chunks.append(_chunk(1, 10, 10, Int64(1000), Int64(2)))
    chunks.append(_chunk(2, 20, 10, Int64(1000), Int64(3)))
    chunks.append(_chunk(3, 30, 10, Int64(1000), Int64(4)))
    var policy = RetentionPolicy.size_based(Int64(2500))
    assert_equal(
        evaluate_retention(policy, chunks, now), Int64(2),
        "keep newest 2 (2000B <= 2500B), retire oldest 2",
    )

    # retention_bytes huge → keep all → 0 retire
    assert_equal(
        evaluate_retention(RetentionPolicy.size_based(Int64(1_000_000)), chunks, now),
        Int64(0),
        "huge size budget retires nothing",
    )

    # retention_bytes 0 → keep only what fits in 0 (nothing) → retire all
    # candidates (the active chunk is excluded by the caller, always kept).
    assert_equal(
        evaluate_retention(RetentionPolicy.size_based(Int64(0)), chunks, now),
        Int64(4),
        "zero budget retires all candidate chunks",
    )
    print("[test_evaluate_size_based] PASS")


# =============================================================================
# (5) RetentionPass over the store + (8) consume-below-log_start
# =============================================================================


def _produce_n_chunks(
    mut broker: BrokerCore[_Store], n_chunks: Int, ts_step: Int64
) raises:
    """Produce `n_chunks` segments (one batch flushed per chunk via
    flush_if_buffered), each at a distinct creation ts (base + i*ts_step), each
    10 rows. Returns nothing; the manifest now has n_chunks chunks."""
    var base_ts = Int64(1000)
    for i in range(n_chunks):
        var rb = _make_int64_batch(Int64(i * 10), 10)
        _ = broker.produce(rb^, base_ts + Int64(i) * ts_step)
        _ = broker.flush_if_buffered(base_ts + Int64(i) * ts_step)


def test_retention_pass_and_consume() raises:
    print("[test_retention_pass_and_consume] starting...")
    var store = _Store()
    var cluster = String("t5")
    var topic = String("topicE")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)

    # Produce 5 chunks at ts 1000,2000,3000,4000,5000 (each 10 rows → offsets
    # 0..49 over 5 chunks: [0..9],[10..19],[20..29],[30..39],[40..49]).
    _produce_n_chunks(broker, 5, Int64(1000))

    # Time retention: now=10000, retention_ms=4000 → retire chunks older than
    # now-4000=6000. Candidate chunks = [0..3] (chunk 4 is the active/last,
    # excluded). ts: c0=1000(age9000),c1=2000(8000),c2=3000(7000),c3=4000(6000
    # age=6000 NOT >4000? age=6000>4000 retire). So c0..c3 all age>4000 → but
    # the active chunk (c4) is excluded; evaluate sees [0..3], all old → retire
    # all 4? No — c3 age = 10000-4000 = 6000 > 4000 → retire. So 4 retire.
    # Keep it to 3 retires: use retention_ms so only c0,c1,c2 retire.
    # c3 ts=4000 age=6000; pick retention_ms=6000 → age>6000 strictly:
    #   c0 9000>6000 ✓, c1 8000>6000 ✓, c2 7000>6000 ✓, c3 6000>6000 ✗.
    var policy = RetentionPolicy.time_based(Int64(6000))
    var res = broker.retention_pass_on_partition(policy, Int64(10000))
    assert_equal(res.tombstoned_count, Int64(3), "3 oldest chunks tombstoned")
    assert_true(res.advanced_log_start, "log_start advanced")
    assert_equal(res.new_log_start_seq, Int64(3), "new log_start_seq = 3")
    assert_equal(
        res.new_log_start_offset, Int64(30), "new log_start_offset = 30"
    )

    # Reap (grace=0 so all tombstoned chunks reap now).
    var reaped = broker.reap_partition(Int64(10000), Int64(0))
    assert_equal(reaped.reaped_count, Int64(3), "3 chunks reaped")

    # CONSUME from 0 → survivors are chunks 3,4 with CORRECT absolute offsets
    # 30..49 (NOT renumbered to 0..19). read_from(0) serves the surviving range.
    var consumer = _make_consume(store, cluster, topic, pid)
    var ls = consumer.log_start_offset()
    assert_equal(ls, Int64(30), "consumer log_start_offset = 30")

    # read_from_checked(0): below log_start → truncated, effective = 30.
    var checked = consumer.read_from_checked(Int64(0))
    assert_true(checked.truncated, "request below log_start is truncated")
    assert_equal(
        checked.effective_start_offset, Int64(30), "effective start = 30"
    )
    # The surviving segments keep their ABSOLUTE base offsets (30, 40).
    assert_equal(len(checked.segments), 2, "2 surviving segments")
    assert_equal(
        checked.segments[0].base_offset, Int64(30), "survivor base = 30 (abs)"
    )
    assert_equal(
        checked.segments[0].last_offset, Int64(39), "survivor last = 39"
    )
    assert_equal(
        checked.segments[1].base_offset, Int64(40), "next survivor base = 40"
    )
    _ = checked^

    # read_from_checked(40) at/above log_start → NOT truncated, 1 segment.
    var checked2 = consumer.read_from_checked(Int64(40))
    assert_false(checked2.truncated, "request at/above log_start not truncated")
    assert_equal(len(checked2.segments), 1, "1 segment from offset 40")
    assert_equal(checked2.segments[0].base_offset, Int64(40), "base 40")
    _ = checked2^

    _ = consumer^
    _ = broker^
    _ = store^
    print("[test_retention_pass_and_consume] PASS")


# =============================================================================
# (6) PERSISTED-tombstone RESTART recovery (the FSM-persistence fix)
# =============================================================================


def test_tombstone_survives_restart() raises:
    print("[test_tombstone_survives_restart] starting...")
    var store = _Store()
    var cluster = String("t6")
    var topic = String("topicF")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _produce_n_chunks(broker, 4, Int64(1000))
    _ = broker^

    # Tombstone chunk 0 + 1 via a manifest handle, with explicit ts.
    var m1 = _make_manifest(store, cluster, topic, pid)
    m1.schedule_for_delete_at(Int64(0), Int64(5000))
    m1.schedule_for_delete_at(Int64(1), Int64(5000))
    var seqs1 = m1.tombstone_seqs()
    assert_equal(len(seqs1), 2, "2 tombstones recorded")
    _ = m1^  # DROP the handle (the "restart": in-process state is gone)

    # Build a FRESH manifest handle over the SAME backing store data (clone
    # shares the Arc map = the same S3 bucket survives the restart). A legacy
    # process-local List[Int64] would re-discover ZERO marks here — the fix
    # persists them, so the fresh handle MUST find both.
    var m2 = _make_manifest(store, cluster, topic, pid)
    var seqs2 = m2.tombstone_seqs()
    assert_equal(
        len(seqs2), 2, "FRESH handle re-discovers BOTH tombstones (persisted)"
    )
    assert_equal(seqs2[0], Int64(0), "tombstone seq 0 survived")
    assert_equal(seqs2[1], Int64(1), "tombstone seq 1 survived")
    # And the schedule ts persisted too.
    assert_equal(
        m2.tombstone_schedule_ts(Int64(0)), Int64(5000),
        "schedule ts persisted",
    )
    _ = m2^
    _ = store^
    print("[test_tombstone_survives_restart] PASS")


# =============================================================================
# (7) ReapWorker grace enforcement + fail-loud + idempotence
# =============================================================================


def test_reap_grace_and_failloud() raises:
    print("[test_reap_grace_and_failloud] starting...")
    var store = _Store()
    var cluster = String("t7")
    var topic = String("topicG")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _produce_n_chunks(broker, 3, Int64(1000))
    _ = broker^

    var m = _make_manifest(store, cluster, topic, pid)
    # Tombstone chunk 0 at ts=1000, then retire it (log start -> chunk 1) the
    # way RetentionPass does: the reaper deletes only below the log start.
    m.schedule_for_delete_at(Int64(0), Int64(1000))
    var ls0 = m.read_log_start()
    _ = m.advance_log_start(Int64(1), Int64(10), ls0.etag)

    # PRE-grace reap (grace=60000, now=2000 → age=1000 < 60000) → no-op.
    # The worker also deletes the .seg object, so it takes a segment store
    # handle (clone-shares the same backing data as the broker's stores).
    var seg_store = store.clone()
    var w = ReapWorker[_Store](Int64(60000))
    var pre = w.run(seg_store, m, Int64(2000))
    assert_equal(pre.reaped_count, Int64(0), "pre-grace reap is a no-op")
    # The chunk is still readable.
    var still = m.read_chunk(Int64(0))
    assert_true(len(still) > 0, "chunk survives within grace")

    # POST-grace reap (now=61001 → age=60001 >= 60000) → deletes.
    var post = w.run(seg_store, m, Int64(61001))
    assert_equal(post.reaped_count, Int64(1), "post-grace reap deletes")

    # Idempotent: re-run reaps nothing (tombstone consumed).
    var again = w.run(seg_store, m, Int64(61002))
    assert_equal(again.reaped_count, Int64(0), "reap is idempotent")

    # fail-loud: reaping a non-tombstoned chunk raises (tombstone-first).
    var raised = False
    try:
        m.reap(Int64(2))  # chunk 2 was never tombstoned
    except e:
        raised = True
        assert_true(
            String(e).find("ScheduledForDelete") >= 0,
            "fail-loud message names tombstone-first",
        )
    assert_true(raised, "reap of non-tombstoned chunk must raise")
    _ = m^
    _ = store^
    print("[test_reap_grace_and_failloud] PASS")


# =============================================================================
# (extra) active chunk never tombstoned + survivor contiguity assert holds
# =============================================================================


def test_active_chunk_never_retired() raises:
    print("[test_active_chunk_never_retired] starting...")
    var store = _Store()
    var cluster = String("t9")
    var topic = String("topicH")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    # Single chunk → it's the active chunk → nothing can be retired.
    _produce_n_chunks(broker, 1, Int64(1000))
    # Aggressive policy: everything older than 1ms + 0 bytes.
    var policy = RetentionPolicy(Int64(1), Int64(0))
    var res = broker.retention_pass_on_partition(policy, Int64(1_000_000))
    assert_equal(
        res.tombstoned_count, Int64(0), "the only (active) chunk is never retired"
    )
    assert_false(res.advanced_log_start, "log_start does not move")
    _ = broker^
    _ = store^
    print("[test_active_chunk_never_retired] PASS")


# =============================================================================
# (extra2) retire ALL non-active chunks → new log_start = the ACTIVE chunk.
# This is the boundary (retire == len(snapshot)) an integration run can hit: with
# 3 chunks (active=2), candidates [0,1] both retire → new first-live chunk is
# the active chunk 2, which is NOT in the snapshot. Guards the off-by-one.
# =============================================================================


def test_retire_all_nonactive_chunks() raises:
    print("[test_retire_all_nonactive_chunks] starting...")
    var store = _Store()
    var cluster = String("t10")
    var topic = String("topicI")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    # 3 chunks at ts 1000,2000,3000 (offsets [0..9],[10..19],[20..29]).
    _produce_n_chunks(broker, 3, Int64(1000))
    # retention_ms=6000, now=10000 → c0 age9000, c1 age8000 both >6000 retire;
    # c2 is active (excluded). retire == 2 == len(snapshot).
    var res = broker.retention_pass_on_partition(
        RetentionPolicy.time_based(Int64(6000)), Int64(10000)
    )
    assert_equal(res.tombstoned_count, Int64(2), "2 non-active chunks retired")
    assert_equal(
        res.new_log_start_seq, Int64(2), "new log_start_seq = active chunk 2"
    )
    assert_equal(
        res.new_log_start_offset, Int64(20), "new log_start_offset = 20 (active)"
    )
    var reaped = broker.reap_partition(Int64(10000), Int64(0))
    assert_equal(reaped.reaped_count, Int64(2), "both retired chunks reaped")

    var consumer = _make_consume(store, cluster, topic, pid)
    var checked = consumer.read_from_checked(Int64(0))
    assert_true(checked.truncated, "below log_start truncated")
    assert_equal(checked.effective_start_offset, Int64(20), "effective=20")
    assert_equal(len(checked.segments), 1, "only the active chunk survives")
    assert_equal(
        checked.segments[0].base_offset, Int64(20), "survivor abs base = 20"
    )
    _ = checked^
    _ = consumer^
    _ = broker^
    _ = store^
    print("[test_retire_all_nonactive_chunks] PASS")


def main() raises:
    test_manifest_body_backward_compat()
    test_topic_config_retention_roundtrip()
    test_evaluate_time_based()
    test_evaluate_size_based()
    test_retention_pass_and_consume()
    test_tombstone_survives_restart()
    test_reap_grace_and_failloud()
    test_active_chunk_never_retired()
    test_retire_all_nonactive_chunks()
    print(
        "[OK] test_broker_retention_offline — 9 retention tests passed"
        " (persisted tombstones, log_start-aware consume, grace reaper,"
        " restart recovery, retire-all-nonactive boundary — offline)"
    )

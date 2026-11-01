# =============================================================================
# test_broker_compaction_transcode_offline.mojo
#   Transcode, worker and dual-tier consume offline unit tests
# =============================================================================
#
# Drives this package over the offline clone-shared in-memory
# ConditionalWriteStore. Exercises:
#   (1) transcode N live segments -> ONE Parquet object -> decode back: row
#       count + per-column values + nullability match; schema divergence raises.
#   (2) CompactionWorker.run_once over a real produced live partition:
#       publishes a Parquet object + a compaction-index entry (lazy swap),
#       tombstones the superseded live chunks, preserves exact offset
#       contiguity.
#   (3) DualTierConsumer reads byte-faithful from the COMPACTED tier after a
#       round, then across the live/compacted boundary after producing more.
#   (4) SLO back-pressure on the worker.
#
# Pointer rules: no UnsafePointer in any signature, no wildcard origins,
# no unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_broker.broker_core import BrokerCore, encode_segment, SegmentFooter
from komira_broker.consume_core import ConsumeCore
from komira_broker.compacted_index import CompactionIndex
from komira_broker.retention import ReapWorker

from komira_broker_compaction.transcode import (
    transcode_segments_to_parquet,
    assert_uniform_schema,
)
from komira_broker_compaction.compaction_worker import (
    CompactionWorker,
    CompactionRoundResult,
)
from komira_broker_compaction.dual_tier_consume import (
    DualTierConsumer,
    DecodedTierBatch,
    decode_compacted_parquet_bytes,
)

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


# =============================================================================
# helpers
# =============================================================================


def _partition_prefix(cluster: String, topic: String, pid: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


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
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> BrokerCore[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=pid,
        broker_id=String("broker-A"),
    )


def _make_consume(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> ConsumeCore[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )
    return ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=pid,
    )


def _make_worker(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> CompactionWorker[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    var consume = ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=CasManifestStore[_Store](
            store=store.clone(), prefix=String(prefix), retry=RetryPolicy.fast_test()
        ),
        cluster=cluster,
        topic=topic,
        partition=pid,
    )
    var index = CompactionIndex[_Store].build(
        store.clone(), String(prefix), RetryPolicy.fast_test()
    )
    var live_manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=String(prefix), retry=RetryPolicy.fast_test()
    )
    return CompactionWorker[_Store](
        consume=consume^,
        index=index^,
        segment_store=store.clone(),
        live_manifest=live_manifest^,
        cluster=cluster,
        topic=topic,
        partition=pid,
    )


def _make_dual(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> DualTierConsumer[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    var consume = ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=CasManifestStore[_Store](
            store=store.clone(), prefix=String(prefix), retry=RetryPolicy.fast_test()
        ),
        cluster=cluster,
        topic=topic,
        partition=pid,
    )
    var index = CompactionIndex[_Store].build(
        store.clone(), String(prefix), RetryPolicy.fast_test()
    )
    return DualTierConsumer[_Store](
        consume=consume^, index=index^, object_store=store.clone()
    )


def _produce_n(mut broker: BrokerCore[_Store], n_chunks: Int, rows: Int) raises:
    var base_ts = Int64(1000)
    for i in range(n_chunks):
        var rb = _make_int64_batch(Int64(i * rows), rows)
        _ = broker.produce(rb^, base_ts + Int64(i) * Int64(1000))
        _ = broker.flush_if_buffered(base_ts + Int64(i) * Int64(1000))


def _encode_one_segment_stream(base_val: Int64, n: Int) raises -> List[UInt8]:
    """Encode ONE in-memory live segment's Arrow-IPC STREAM bytes (footer
    sliced off — the shape ConsumeSegment.stream_bytes carries)."""
    var batches = Slab[RecordBatch]()
    batches.append(_make_int64_batch(base_val, n))
    var seg = encode_segment(batches^, base_val)
    var footer = SegmentFooter.decode(seg)
    var stream_len = footer.arrow_stream_len(len(seg))
    var stream = List[UInt8]()
    for i in range(stream_len):
        stream.append(seg[i])
    return stream^


# =============================================================================
# (1) transcode fidelity + schema-divergence fail-loud
# =============================================================================


def test_transcode_fidelity() raises:
    print("[test_transcode_fidelity] starting...")
    # 5 segments, 10 rows each: values 0..49 (offset order).
    var streams = Slab[List[UInt8]]()
    for i in range(5):
        streams.append(_encode_one_segment_stream(Int64(i * 10), 10))

    var parquet_bytes = transcode_segments_to_parquet(streams^)
    assert_true(len(parquet_bytes) > 8, "parquet bytes produced")

    # Decode back the compacted Parquet object; row count + values must match.
    var rb = decode_compacted_parquet_bytes(parquet_bytes^)
    assert_equal(rb.num_rows(), 50, "transcoded row count")
    assert_equal(rb.num_columns(), 1, "transcoded col count")
    var vals = rb.column_at(0).as_primitive[DType.int64]()
    for i in range(50):
        assert_equal(vals.get(i), Int64(i), "value at row " + String(i))
    print("[test_transcode_fidelity] PASS")


def _make_named_int64_batch(name: String, base_val: Int64, n: Int) raises -> RecordBatch:
    """Like `_make_int64_batch` but with a caller-chosen column name (for the
    schema-divergence test)."""
    var schema = Schema(
        names=[name],
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


def test_transcode_schema_divergence_fails() raises:
    print("[test_transcode_schema_divergence_fails] starting...")
    # Two batches with DIFFERENT schemas (different column name -> divergence).
    var batches = Slab[RecordBatch]()
    batches.append(_make_named_int64_batch(String("val"), Int64(0), 10))
    batches.append(_make_named_int64_batch(String("other"), Int64(100), 10))
    var raised = False
    try:
        assert_uniform_schema(batches)
    except e:
        raised = True
    assert_true(raised, "schema divergence must fail loud")
    _ = batches^
    print("[test_transcode_schema_divergence_fails] PASS")


# =============================================================================
# (2)+(3) CompactionWorker.run_once + dual-tier consume byte-faithful
# =============================================================================


def _crc_of_int64_values(rb: RecordBatch) raises -> Int64:
    """A cheap order-sensitive checksum of an INT64 column's values — the
    cross-tier ground-truth digest (byte-faithful proxy)."""
    var vals = rb.column_at(0).as_primitive[DType.int64]()
    var acc = Int64(1469598103934665603)  # FNV offset basis (truncated)
    for i in range(rb.num_rows()):
        acc = (acc ^ vals.get(i)) * Int64(1099511628211)
    return acc


def test_worker_round_and_dual_tier_consume() raises:
    print("[test_worker_round_and_dual_tier_consume] starting...")
    var store = _Store()
    var cluster = String("w1")
    var topic = String("t")
    var pid = Int64(0)

    # Produce 5 live segments (offsets 0..49).
    var broker = _make_broker(store, cluster, topic, pid)
    _produce_n(broker, 5, 10)

    # Ground-truth digest of the full live range [0,49] BEFORE compaction.
    var consume0 = _make_consume(store, cluster, topic, pid)
    var live_segs = consume0.read_from(Int64(0))
    var gt_acc = Int64(1469598103934665603)
    var gt_rows = 0
    for i in range(len(live_segs)):
        var b = decode_arrow_ipc_stream(live_segs[i].stream_bytes.copy())
        gt_rows += b.num_rows()
        var vals = b.column_at(0).as_primitive[DType.int64]()
        for r in range(b.num_rows()):
            gt_acc = (gt_acc ^ vals.get(r)) * Int64(1099511628211)
    assert_equal(gt_rows, 50, "ground-truth 50 rows live")

    # Run ONE compaction round (compact all 5 live segments -> 1 Parquet object).
    var worker = _make_worker(store, cluster, topic, pid)
    var res = worker.run_once(
        now_ms=Int64(100000), min_segments=Int64(2), max_segments=Int64(64)
    )
    assert_true(res.compacted, "a round was published")
    assert_equal(res.base_offset, Int64(0), "compacted base 0")
    assert_equal(res.last_offset, Int64(49), "compacted last 49 (contiguity)")
    assert_equal(res.record_count, Int64(50), "50 records compacted")
    assert_equal(res.segments_compacted, Int64(5), "5 segments folded")
    assert_equal(res.supersedes_lo, Int64(0), "supersedes lo 0")
    assert_equal(res.supersedes_hi, Int64(4), "supersedes hi 4")
    assert_equal(res.tombstoned_count, Int64(5), "5 live chunks tombstoned")

    # Dual-tier consume from offset 0 -> reads byte-faithful from COMPACTED tier.
    var dual = _make_dual(store, cluster, topic, pid)
    var batches = dual.read_from(Int64(0))
    assert_equal(len(batches), 1, "one compacted batch covers [0,49]")
    assert_true(batches[0].is_compacted, "served from compacted tier")
    assert_equal(batches[0].base_offset, Int64(0), "compacted batch base 0")
    assert_equal(batches[0].last_offset, Int64(49), "compacted batch last 49")
    assert_equal(batches[0].batch.num_rows(), 50, "50 rows from compacted tier")
    # Byte-faithful: each row's value must equal its offset (value==offset by
    # construction), AND the order-sensitive digest must match the live read.
    var cvals = batches[0].batch.column_at(0).as_primitive[DType.int64]()
    for r in range(50):
        assert_equal(
            cvals.get(r), Int64(r), "compacted row " + String(r) + " value"
        )
    var ct_acc = Int64(1469598103934665603)
    for r in range(batches[0].batch.num_rows()):
        ct_acc = (ct_acc ^ cvals.get(r)) * Int64(1099511628211)
    assert_equal(ct_acc, gt_acc, "compacted-tier digest == live ground truth")
    print("[test_worker_round_and_dual_tier_consume] PASS")


def test_dual_tier_across_boundary() raises:
    print("[test_dual_tier_across_boundary] starting...")
    var store = _Store()
    var cluster = String("w2")
    var topic = String("t")
    var pid = Int64(0)

    # Produce 5 live segments (offsets 0..49), compact them.
    var broker = _make_broker(store, cluster, topic, pid)
    _produce_n(broker, 5, 10)
    var worker = _make_worker(store, cluster, topic, pid)
    var res = worker.run_once(now_ms=Int64(100000), min_segments=Int64(2))
    assert_true(res.compacted, "first round compacted")

    # Produce 3 MORE live segments (offsets 50..79) into the live tier.
    var broker2 = _make_broker(store, cluster, topic, pid)
    var base_ts = Int64(200000)
    for i in range(3):
        var rb = _make_int64_batch(Int64(50 + i * 10), 10)
        _ = broker2.produce(rb^, base_ts + Int64(i) * Int64(1000))
        _ = broker2.flush_if_buffered(base_ts + Int64(i) * Int64(1000))

    # Dual-tier consume from 0: compacted [0,49] + live [50,79], contiguous.
    var dual = _make_dual(store, cluster, topic, pid)
    var batches = dual.read_from(Int64(0))
    # 1 compacted batch + 3 live batches.
    assert_equal(len(batches), 4, "1 compacted + 3 live across boundary")
    assert_true(batches[0].is_compacted, "first batch compacted")
    assert_equal(batches[0].last_offset, Int64(49), "compacted ends at 49")
    assert_false(batches[1].is_compacted, "second batch live")
    assert_equal(batches[1].base_offset, Int64(50), "live starts at 50")
    assert_false(batches[3].is_compacted, "last batch live")
    assert_equal(batches[3].last_offset, Int64(79), "live ends at 79")

    # Contiguous, no gap/dup across the boundary + within the live suffix.
    var total_rows = 0
    var expected_next = Int64(0)
    for i in range(len(batches)):
        assert_equal(
            batches[i].base_offset,
            expected_next,
            "contiguous base at batch " + String(i),
        )
        total_rows += batches[i].batch.num_rows()
        expected_next = batches[i].last_offset + Int64(1)
    assert_equal(total_rows, 80, "80 rows across both tiers, no gap/dup")
    assert_equal(expected_next, Int64(80), "tail offset = 80")

    # Full-range byte-faithful digest [0,79] in order.
    var acc = Int64(1469598103934665603)
    var seen = 0
    for i in range(len(batches)):
        var vals = batches[i].batch.column_at(0).as_primitive[DType.int64]()
        for r in range(batches[i].batch.num_rows()):
            acc = (acc ^ vals.get(r)) * Int64(1099511628211)
            seen += 1
    # Independent recompute over 0..79.
    var expect = Int64(1469598103934665603)
    for v in range(80):
        expect = (expect ^ Int64(v)) * Int64(1099511628211)
    assert_equal(acc, expect, "cross-boundary digest matches 0..79")
    assert_equal(seen, 80, "80 values digested")
    print("[test_dual_tier_across_boundary] PASS")


def test_worker_no_round_below_min() raises:
    print("[test_worker_no_round_below_min] starting...")
    var store = _Store()
    var cluster = String("w3")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _produce_n(broker, 1, 10)  # only 1 live segment
    var worker = _make_worker(store, cluster, topic, pid)
    var res = worker.run_once(now_ms=Int64(100000), min_segments=Int64(2))
    assert_false(res.compacted, "no round below min_segments")
    assert_equal(res.record_count, Int64(0), "nothing compacted")
    print("[test_worker_no_round_below_min] PASS")


# =============================================================================
# (4) SLO back-pressure on the worker
# =============================================================================


def test_worker_slo_backpressure() raises:
    print("[test_worker_slo_backpressure] starting...")
    var store = _Store()
    var cluster = String("w4")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _produce_n(broker, 5, 10)  # 5 uncompacted live segments

    var worker = _make_worker(store, cluster, topic, pid)
    # threshold 10 -> 5 uncompacted < 10 -> no back-pressure.
    var d0 = worker.slo_backpressure(Int64(10))
    assert_false(d0.should_backpressure, "5 < 10 -> no back-pressure")
    assert_equal(d0.uncompacted_segment_count, Int64(5), "5 uncompacted")
    # threshold 3 -> 5 > 3 -> back-pressure.
    var d1 = worker.slo_backpressure(Int64(3))
    assert_true(d1.should_backpressure, "5 > 3 -> back-pressure")

    # After compacting all 5, uncompacted drops to 0.
    var worker2 = _make_worker(store, cluster, topic, pid)
    _ = worker2.run_once(now_ms=Int64(100000), min_segments=Int64(2))
    var worker3 = _make_worker(store, cluster, topic, pid)
    var d2 = worker3.slo_backpressure(Int64(3))
    assert_false(d2.should_backpressure, "0 uncompacted -> no back-pressure")
    assert_equal(d2.uncompacted_segment_count, Int64(0), "all compacted")
    print("[test_worker_slo_backpressure] PASS")


def main() raises:
    test_transcode_fidelity()
    test_transcode_schema_divergence_fails()
    test_worker_round_and_dual_tier_consume()
    test_dual_tier_across_boundary()
    test_worker_no_round_below_min()
    test_worker_slo_backpressure()
    print("ALL test_broker_compaction_transcode_offline PASS")

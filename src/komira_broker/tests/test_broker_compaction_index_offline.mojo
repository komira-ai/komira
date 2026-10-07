# =============================================================================
# tests/test_broker_compaction_index_offline.mojo
#   Tier compaction — leaf-side compaction-index OFFLINE unit tests
# =============================================================================
#
# Drives the LEAF side of tier compaction (objectstore-only — NO sdk/parquet) over
# the OFFLINE clone-shared in-memory ConditionalWriteStore. Exercises:
#   (1) CompactedEntry body codec round-trip (every field, incl. a long key).
#   (2) CompactionIndex.append_compacted offset-contiguity: first entry must
#       start at 0; subsequent entries must start at prior_last+1; a gap or an
#       internally-inconsistent entry FAILs loud (offset contiguity).
#   (3) resolve_compacted + compacted_tail_offset over a real append sequence.
#   (4) SLO back-pressure decision: below/at/above threshold.
#   (5) dual_tier_resolve over a REAL live manifest built by
#       producing live segments, plus a compacted prefix:
#         - compacted-only (start within the compacted prefix, all live
#           superseded);
#         - live-only (nothing compacted yet);
#         - straddling [A,X] compacted + [X+1,B] live -> both tiers, in offset
#           order, no double-cover, no gap.
#
# Hard-rule audit: no UnsafePointer in any signature, no wildcard origins,
# no unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore, SegmentRef
from komira_broker.compacted_index import (
    CompactedEntry,
    CompactionIndex,
    TierRef,
    SloDecision,
    evaluate_slo_backpressure,
    dual_tier_resolve,
    compacted_prefix,
)

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


def _make_index(
    store: _Store, cluster: String, topic: String, pid: Int64
) -> CompactionIndex[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    return CompactionIndex[_Store].build(
        store.clone(), prefix, RetryPolicy.fast_test()
    )


def _produce_n(
    mut broker: BrokerCore[_Store], n_chunks: Int, rows: Int
) raises:
    """Produce `n_chunks` live segments, `rows` rows each, distinct ts."""
    var base_ts = Int64(1000)
    for i in range(n_chunks):
        var rb = _make_int64_batch(Int64(i * rows), rows)
        _ = broker.produce(rb^, base_ts + Int64(i) * Int64(1000))
        _ = broker.flush_if_buffered(base_ts + Int64(i) * Int64(1000))


# =============================================================================
# (1) CompactedEntry codec round-trip
# =============================================================================


def test_compacted_entry_codec() raises:
    print("[test_compacted_entry_codec] starting...")
    var key = String(
        "clusterX/topics/orders/0/compacted/seg-0-49-0001.parquet"
    )
    var e = CompactedEntry(
        chunk_seq=Int64(-1),
        base_offset=Int64(0),
        last_offset=Int64(49),
        record_count=Int64(50),
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(4),
        parquet_key=key,
    )
    var body = e.encode_body()
    var d = CompactedEntry.decode_body(Int64(7), body)
    assert_equal(d.chunk_seq, Int64(7), "chunk_seq stamped from append slot")
    assert_equal(d.base_offset, Int64(0), "base_offset")
    assert_equal(d.last_offset, Int64(49), "last_offset")
    assert_equal(d.record_count, Int64(50), "record_count")
    assert_equal(d.supersedes_lo, Int64(0), "supersedes_lo")
    assert_equal(d.supersedes_hi, Int64(4), "supersedes_hi")
    assert_equal(d.parquet_key, key, "parquet_key")
    print("[test_compacted_entry_codec] PASS")


# =============================================================================
# (2) append_compacted contiguity (success + fail-loud)
# =============================================================================


def test_append_contiguity_success() raises:
    print("[test_append_contiguity_success] starting...")
    var store = _Store()
    var index = _make_index(store, String("c1"), String("t"), Int64(0))

    # First entry MUST start at 0.
    var r0 = index.append_compacted(
        parquet_key=String("c1/.../p0.parquet"),
        base_offset=Int64(0),
        last_offset=Int64(49),
        record_count=Int64(50),
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(4),
    )
    assert_equal(r0.chunk_seq, Int64(0), "first compacted entry slot 0")
    assert_equal(r0.base_offset, Int64(0), "append base 0")
    assert_equal(r0.last_offset, Int64(49), "append last 49")

    # Second entry MUST start at 50 (prior_last+1).
    var r1 = index.append_compacted(
        parquet_key=String("c1/.../p1.parquet"),
        base_offset=Int64(50),
        last_offset=Int64(99),
        record_count=Int64(50),
        supersedes_lo=Int64(5),
        supersedes_hi=Int64(9),
    )
    assert_equal(r1.chunk_seq, Int64(1), "second compacted entry slot 1")

    var entries = index.resolve_compacted()
    assert_equal(len(entries), 2, "two compacted entries")
    assert_equal(entries[0].base_offset, Int64(0), "e0 base")
    assert_equal(entries[1].base_offset, Int64(50), "e1 base")
    assert_equal(
        index.compacted_tail_offset(), Int64(100), "compacted tail = 100"
    )
    print("[test_append_contiguity_success] PASS")


def test_append_contiguity_gap_fails() raises:
    print("[test_append_contiguity_gap_fails] starting...")
    var store = _Store()
    var index = _make_index(store, String("c2"), String("t"), Int64(0))

    # A first entry that does NOT start at 0 must fail loud.
    var raised_first = False
    try:
        _ = index.append_compacted(
            parquet_key=String("p.parquet"),
            base_offset=Int64(10),  # WRONG — must be 0
            last_offset=Int64(59),
            record_count=Int64(50),
            supersedes_lo=Int64(0),
            supersedes_hi=Int64(4),
        )
    except e:
        raised_first = True
    assert_true(raised_first, "non-zero first base must fail loud")

    # A valid first entry, then a GAPPED second entry must fail loud.
    _ = index.append_compacted(
        parquet_key=String("p0.parquet"),
        base_offset=Int64(0),
        last_offset=Int64(49),
        record_count=Int64(50),
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(4),
    )
    var raised_gap = False
    try:
        _ = index.append_compacted(
            parquet_key=String("p1.parquet"),
            base_offset=Int64(60),  # GAP — must be 50
            last_offset=Int64(109),
            record_count=Int64(50),
            supersedes_lo=Int64(5),
            supersedes_hi=Int64(9),
        )
    except e:
        raised_gap = True
    assert_true(raised_gap, "gapped compacted base must fail loud")

    # An internally-inconsistent entry (last != base+count-1) must fail loud.
    var raised_inconsistent = False
    try:
        _ = index.append_compacted(
            parquet_key=String("p2.parquet"),
            base_offset=Int64(50),
            last_offset=Int64(80),  # 50 + 50 - 1 = 99, not 80
            record_count=Int64(50),
            supersedes_lo=Int64(5),
            supersedes_hi=Int64(9),
        )
    except e:
        raised_inconsistent = True
    assert_true(raised_inconsistent, "inconsistent entry must fail loud")
    print("[test_append_contiguity_gap_fails] PASS")


# =============================================================================
# (4) SLO back-pressure decision
# =============================================================================


def test_slo_backpressure() raises:
    print("[test_slo_backpressure] starting...")
    # Below threshold: no back-pressure.
    var d0 = evaluate_slo_backpressure(Int64(500), Int64(1000))
    assert_false(d0.should_backpressure, "500 < 1000 -> no back-pressure")
    # At threshold (not strictly above): no back-pressure.
    var d1 = evaluate_slo_backpressure(Int64(1000), Int64(1000))
    assert_false(d1.should_backpressure, "1000 == 1000 -> no back-pressure")
    # Above threshold: back-pressure.
    var d2 = evaluate_slo_backpressure(Int64(1001), Int64(1000))
    assert_true(d2.should_backpressure, "1001 > 1000 -> back-pressure")
    assert_equal(d2.uncompacted_segment_count, Int64(1001), "count echoed")
    assert_equal(d2.threshold, Int64(1000), "threshold echoed")
    # Default threshold ~1000.
    var d3 = evaluate_slo_backpressure(Int64(1500))
    assert_true(d3.should_backpressure, "1500 > default 1000 -> back-pressure")
    print("[test_slo_backpressure] PASS")


# =============================================================================
# (5) dual_tier_resolve over a REAL live manifest
# =============================================================================


def test_dual_tier_live_only() raises:
    print("[test_dual_tier_live_only] starting...")
    var store = _Store()
    var cluster = String("d1")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _produce_n(broker, 5, 10)  # offsets 0..49 across 5 live segments

    var consume = _make_consume(store, cluster, topic, pid)
    var live_index = consume.resolve_index()
    assert_equal(len(live_index), 5, "5 live segments")

    var index = _make_index(store, cluster, topic, pid)  # nothing compacted
    var refs = dual_tier_resolve(index, live_index, Int64(0))
    assert_equal(len(refs), 5, "all 5 refs are live (nothing compacted)")
    for i in range(len(refs)):
        assert_false(refs[i].is_compacted, "live tier ref")
    # Contiguity 0..49.
    assert_equal(refs[0].base_offset, Int64(0), "first ref base 0")
    assert_equal(refs[4].last_offset, Int64(49), "last ref last 49")
    print("[test_dual_tier_live_only] PASS")


def test_dual_tier_straddle_and_compacted_only() raises:
    print("[test_dual_tier_straddle_and_compacted_only] starting...")
    var store = _Store()
    var cluster = String("d2")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _produce_n(broker, 5, 10)  # live offsets 0..49 across segs [0..9]..[40..49]

    var consume = _make_consume(store, cluster, topic, pid)
    var live_index = consume.resolve_index()
    assert_equal(len(live_index), 5, "5 live segments")

    # Simulate compaction of the first 3 live segments (offsets 0..29 ->
    # chunk_seqs 0..2) into ONE compacted Parquet object covering [0,29].
    var index = _make_index(store, cluster, topic, pid)
    _ = index.append_compacted(
        parquet_key=String("d2/.../compacted-0-29.parquet"),
        base_offset=Int64(0),
        last_offset=Int64(29),
        record_count=Int64(30),
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(2),
    )

    # STRADDLING read from offset 0: compacted [0,29] + live [30,49].
    var refs = dual_tier_resolve(index, live_index, Int64(0))
    # 1 compacted ref + 2 live refs (segs covering [30..39],[40..49]).
    assert_equal(len(refs), 3, "1 compacted + 2 live (straddle)")
    assert_true(refs[0].is_compacted, "first ref is compacted")
    assert_equal(refs[0].base_offset, Int64(0), "compacted base 0")
    assert_equal(refs[0].last_offset, Int64(29), "compacted last 29")
    assert_false(refs[1].is_compacted, "second ref is live")
    assert_equal(refs[1].base_offset, Int64(30), "live suffix base 30")
    assert_false(refs[2].is_compacted, "third ref is live")
    assert_equal(refs[2].last_offset, Int64(49), "live suffix last 49")

    # No double-cover: compacted last (29) + 1 == first live base (30).
    assert_equal(
        refs[0].last_offset + Int64(1),
        refs[1].base_offset,
        "no gap/dup across boundary",
    )

    # COMPACTED-ONLY read from offset 5: only the compacted ref intersects
    # [5,29]; the live suffix [30,49] still follows (it's > 29).
    var refs2 = dual_tier_resolve(index, live_index, Int64(5))
    assert_equal(len(refs2), 3, "compacted (straddles 5) + 2 live")
    assert_true(refs2[0].is_compacted, "compacted ref covers 5..29")

    # Read from offset 35 (inside the live suffix): NO compacted ref, 1 live.
    var refs3 = dual_tier_resolve(index, live_index, Int64(35))
    assert_equal(len(refs3), 2, "two live refs cover [30..39]+[40..49] from 35")
    assert_false(refs3[0].is_compacted, "live only")
    print("[test_dual_tier_straddle_and_compacted_only] PASS")


def main() raises:
    test_compacted_entry_codec()
    test_append_contiguity_success()
    test_append_contiguity_gap_fails()
    test_slo_backpressure()
    test_dual_tier_live_only()
    test_dual_tier_straddle_and_compacted_only()
    print("ALL test_broker_compaction_index_offline PASS")

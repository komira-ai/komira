# =============================================================================
# tests/test_broker_flush_op_elision_offline.mojo
#   No pre-flush read_head GET on the ack path
# =============================================================================
#
# BrokerCore.flush (+ flush_with_producer / flush_with_producer_txn) issues no
# pre-flush `self._manifest.read_head()` GET: its ONLY consumer would be the
# segment footer's DEBUG `base_offset`/`last_offset` fields
# (`encode_segment`'s `pre_commit_base`). That is NOT load-bearing: the consumer
# resolves every offset from the MANIFEST append's running sum, never the footer
# (see the note on the footer's offset fields in the consume_core module
# header, and `read_segment`, which returns the manifest's
# `seg.base_offset`/`seg.last_offset` and uses the footer ONLY for
# `arrow_stream_len` + the CRC integrity check). The AUTHORITATIVE offset range
# is assigned by the manifest append (step 5) regardless, so the GET would be
# pure redundant latency on the durable-ack hot path. The exactly-once twin
# `flush_with_producer_exactly_once` seeds `pre_commit_base = Int64(0)` the
# same way.
#
# The win is INVISIBLE on a single local store (one fewer round-trip ==
# identical wall time at that scale), so this test asserts by OP COUNT on the
# in-memory conditional-store conformer (`SharedInMemoryConditionalStore`),
# which carries per-verb call counters shared across every clone
# (segment-store handle + manifest handle both increment the SAME Arc-shared
# tallies).
#
# The assertions:
#   * A STEADY-STATE `read_head()` is exactly ONE `get` on the cached `_HEAD`
#     key (`CasManifestStore.read_head` fast path); `test_read_head_costs_one_get`
#     pins that. On a COLD manifest (`_HEAD` absent, the first-flush case here)
#     a pre-flush `read_head` would instead LIST-recover the tail (2 GETs), so
#     a first `flush` WITH it would issue 6 internal GETs; without it, 4
#     (one of them the reaped-slot check's `_LOG_START` GET, #486).
#   * The exact internal GET count is captured as a constant so a re-introduced
#     read_head (or any new pre-flush GET) trips the assertion LOUD.
#
# Plus offset-correctness: the consumer still resolves CORRECT absolute offsets
# from the manifest (the footer's debug base is 0 — proving the consumer never
# trusts it). And the exactly-once twin still commits exactly once; this file
# re-asserts the produce-consume offset contract.
#
# Hard-rule audit: no UnsafePointer in any signature, no wildcard origins,
# no unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.collections.slab import Slab

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema

from komira_broker.broker_core import BrokerCore, SegmentFooter
from komira_broker.consume_core import ConsumeCore, SegmentRef

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


def _partition_prefix(cluster: String, topic: String, pid: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


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
    return ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=CasManifestStore[_Store](
            store=store.clone(),
            prefix=prefix^,
            retry=RetryPolicy.fast_test(),
        ),
        cluster=cluster,
        topic=topic,
        partition=pid,
    )


def _make_manifest(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> CasManifestStore[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    return CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )


def _make_int64_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    """ONE-column `val:INT64` batch where val == base_val + i (so val == its
    absolute offset by construction across the whole topic)."""
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


# =============================================================================
# (1) read_head costs EXACTLY one GET — the op the flush elision drops.
#     This pins the magnitude of the elision (+1 GET) independently of the
#     flush-internal count, so the RED/GREEN delta is unambiguous.
# =============================================================================


def test_read_head_costs_one_get() raises:
    print("[test_read_head_costs_one_get] starting...")
    var store = _Store()
    var cluster = String("c-rh")
    var topic = String("t")
    var pid = Int64(0)

    # Produce + flush one batch so the manifest has a committed _HEAD (the
    # read_head fast path reads the cached _HEAD with exactly one `get`).
    var broker = _make_broker(store, cluster, topic, pid)
    broker.buffer_batch(_make_int64_batch(Int64(0), 4), Int64(1_700_000_000_000))
    _ = broker.flush(Int64(1_700_000_000_000))

    var manifest = _make_manifest(store, cluster, topic, pid)
    # Warm the cache path (a fresh handle's first read_head may LIST-recover);
    # the SECOND read is the steady-state cached fast path we are measuring.
    _ = manifest.read_head()

    store.reset_op_counts()
    var g0 = store.n_get()
    _ = manifest.read_head()
    var g1 = store.n_get()
    assert_equal(
        g1 - g0,
        Int64(1),
        "a steady-state read_head() is EXACTLY one GET (the elided op)",
    )
    _ = manifest^
    _ = broker^
    _ = store^
    print("[test_read_head_costs_one_get] PASS — read_head = 1 GET")


# =============================================================================
# (2) flush issues no pre-flush read_head GET.
#     Asserts the EXACT internal GET count of one `flush` of one buffered batch.
#     With a pre-flush read_head the count would be HIGHER (on this COLD
#     first-flush manifest that read_head would LIST-recover the tail, so 5
#     instead of 3).
# =============================================================================

# The exact object-store GET count internal to ONE BrokerCore.flush of one
# buffered batch over the in-mem store, AFTER the edit.
# The flush issues: the manifest append (its HEAD read + etag + _HEAD advance
# GETs, plus the reaped-slot check's `_LOG_START` GET after the chunk create
# wins: #486, manifest_slot_guard.mojo) and the segment staged-PUT (a
# conditional_put -> n_put, NOT n_get). It no longer issues the pre-flush
# read_head GET. If a future change re-introduces a pre-flush GET, this count
# rises and the assertion fails LOUD.
comptime _FLUSH_GET_COUNT_AFTER_ELISION = Int64(4)


def test_flush_drops_pre_flush_get() raises:
    print("[test_flush_drops_pre_flush_get] starting...")
    var store = _Store()
    var cluster = String("c-fl")
    var topic = String("t")
    var pid = Int64(0)

    var broker = _make_broker(store, cluster, topic, pid)
    # Buffer WITHOUT auto-flush so we isolate the flush() ops exactly.
    broker.buffer_batch(_make_int64_batch(Int64(0), 4), Int64(1_700_000_000_000))

    store.reset_op_counts()
    var res = broker.flush(Int64(1_700_000_000_000))
    var gets = store.n_get()

    # Sanity on the ack: the manifest assigned [0, 3] (4 records), authoritative.
    assert_equal(res.base_offset, Int64(0), "ack base offset 0 (manifest)")
    assert_equal(res.last_offset, Int64(3), "ack last offset 3 (manifest)")
    assert_equal(res.record_count, Int64(4), "ack record_count 4")

    assert_equal(
        gets,
        _FLUSH_GET_COUNT_AFTER_ELISION,
        (
            "flush() internal GET count with no pre-flush read_head (with one"
            " it would be 6 — a pre-flush read_head LIST-recovers the cold"
            " manifest tail; see test_read_head_costs_one_get for the warm 1-GET)"
        ),
    )
    _ = broker^
    _ = store^
    print(
        "[test_flush_drops_pre_flush_get] PASS — flush GETs ="
        " "
        + String(_FLUSH_GET_COUNT_AFTER_ELISION)
        + " (pre-flush read_head dropped)"
    )


# =============================================================================
# (3) the segment footer's offset base is now 0 (the debug field the elision
#     stopped seeding) BUT the consumer still resolves CORRECT absolute offsets
#     from the manifest — proving the consumer never trusted the footer base.
# =============================================================================


def test_consumer_offsets_correct_despite_zero_footer_base() raises:
    print("[test_consumer_offsets_correct_despite_zero_footer_base] starting...")
    var store = _Store()
    var cluster = String("c-off")
    var topic = String("t")
    var pid = Int64(0)

    var broker = _make_broker(store, cluster, topic, pid)
    # Produce THREE segments: offsets [0,3], [4,7], [8,11]. With the elision the
    # footer base is 0 for ALL THREE (it is no longer the running HEAD estimate),
    # so a consumer that trusted the footer would mis-resolve segments 2 and 3.
    broker.buffer_batch(_make_int64_batch(Int64(0), 4), Int64(1_700_000_000_000))
    var r0 = broker.flush(Int64(1_700_000_000_000))
    broker.buffer_batch(_make_int64_batch(Int64(4), 4), Int64(1_700_000_001_000))
    var r1 = broker.flush(Int64(1_700_000_001_000))
    broker.buffer_batch(_make_int64_batch(Int64(8), 4), Int64(1_700_000_002_000))
    var r2 = broker.flush(Int64(1_700_000_002_000))

    # The acks (manifest-authoritative) are contiguous + correct.
    assert_equal(r0.base_offset, Int64(0), "seg0 base 0")
    assert_equal(r1.base_offset, Int64(4), "seg1 base 4 (contiguous)")
    assert_equal(r2.base_offset, Int64(8), "seg2 base 8 (contiguous)")
    assert_equal(r2.last_offset, Int64(11), "seg2 last 11")

    # Resolve the manifest index — the consumer's authoritative offset map.
    var consume = _make_consume(store, cluster, topic, pid)
    var refs = consume.resolve_index()
    assert_equal(len(refs), 3, "three resolved segments")
    assert_equal(refs[0].base_offset, Int64(0), "ref0 base 0 (manifest)")
    assert_equal(refs[1].base_offset, Int64(4), "ref1 base 4 (manifest)")
    assert_equal(refs[2].base_offset, Int64(8), "ref2 base 8 (manifest)")
    assert_equal(refs[2].last_offset, Int64(11), "ref2 last 11 (manifest)")

    # And the on-disk segment footers' debug base IS 0 for the non-first
    # segments (the field the elision stopped seeding) — confirming the consumer
    # resolved the CORRECT offset (4, 8) from the MANIFEST, NOT this footer base.
    var obj1 = store.get(Path.parse(refs[1].object_key))
    var footer1 = SegmentFooter.decode(obj1)
    assert_equal(
        footer1.base_offset,
        Int64(0),
        "seg1 footer DEBUG base is 0 (elided estimate) — yet manifest resolves 4",
    )
    var obj2 = store.get(Path.parse(refs[2].object_key))
    var footer2 = SegmentFooter.decode(obj2)
    assert_equal(
        footer2.base_offset,
        Int64(0),
        "seg2 footer DEBUG base is 0 (elided estimate) — yet manifest resolves 8",
    )

    # The consumer reads each segment and yields it at its MANIFEST base offset.
    var seg1 = consume.read_segment(refs[1])
    assert_equal(
        seg1.base_offset, Int64(4), "read_segment base 4 (manifest, not footer)"
    )
    assert_equal(seg1.record_count, Int64(4), "seg1 4 records")

    _ = consume^
    _ = broker^
    _ = store^
    print(
        "[test_consumer_offsets_correct_despite_zero_footer_base] PASS — offsets"
        " manifest-authoritative; footer base 0 is debug-only"
    )


def main() raises:
    test_read_head_costs_one_get()
    test_flush_drops_pre_flush_get()
    test_consumer_offsets_correct_despite_zero_footer_base()
    print(
        "[OK] test_broker_flush_op_elision_offline — read_head = 1 GET,"
        " flush issues no pre-flush read_head GET, and the"
        " consumer resolves correct manifest-authoritative offsets despite the"
        " zero footer debug base"
    )

# =============================================================================
# tests/test_broker_marker_chunk_readers_offline.mojo
#   Readers that dereference a manifest chunk's `object_key` skip chunks that
#   own no segment object (txn COMMIT / ABORT markers) — OFFLINE unit tests.
# =============================================================================
#
# A txn COMMIT / ABORT marker chunk has zero records and an EMPTY object_key.
# Every reader that GETs or DELETEs the chunk's segment object must skip it.
#
# Cases (each names the defect it catches):
#   (1) tail consume (`MessageBrokerConsumer.poll_tail` ->
#       `ConsumeCore.read_chunk_segment`) across an ABORT and a COMMIT marker:
#       returns exactly the 3 data segments with contiguous offsets. Catches a
#       tail reader that GETs the marker's empty key (404).
#   (2) a full drain (`ConsumeCore.read_from`) over the same partition: the
#       markers are absent from the offset index. Catches `resolve_index`
#       emitting a SegmentRef for a marker.
#   (3) `ReapWorker` after retention retires a data chunk + both markers:
#       reaps all 3, and DELETEs exactly the data chunk's `.seg` key — never
#       the empty key. Catches the reaper deleting `Path.parse("")`.
#   (4) `LogCleaner.run` handed a marker seq: the marker body stays
#       byte-identical (no compaction sidecar is written onto it). Catches a
#       cleaner that rewrites a chunk with no segment.
#   (5) `dual_tier_resolve` over a live index with markers: no TierRef with an
#       empty key, offsets contiguous. Catches a marker leaking into the
#       live tier.
#   (6) read_committed: a marker type that is not COMMIT / ABORT (e.g. a
#       future zero-record marker) with an EMPTY txn_id is never visible as
#       data, never offset-bearing, and never references a txn (no control
#       object lookup for ""). Catches an `is_marker` narrowed to
#       COMMIT/ABORT.
#   (7) `ManifestBody.has_segment` over every shape: data chunk, zero-row data
#       chunk with a real key, COMMIT, ABORT, other marker, and a corrupt
#       MARKER_NONE body with an empty key.
#   (8) `ConsumeCore.read_chunk_segment` directly: None for each marker, the
#       data segment (with its absolute offsets) for each data chunk.
#   (9) a MARKER_NONE chunk with an empty key and records: no index entry, but
#       its records still advance the offsets (index base == tail base).
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.arrow.string_array import StringArray
from komira_core.collections.slab import Slab

from komira_broker.broker_core import BrokerCore
from komira_broker.compacted_index import CompactionIndex, dual_tier_resolve
from komira_broker.consume_core import ConsumeCore
from komira_broker.consumer_source import MessageBrokerConsumer
from komira_broker.log_compaction import (
    CompactionConfig,
    LogCleaner,
    is_chunk_compacted,
)
from komira_broker.manifest_body import (
    MARKER_ABORT,
    MARKER_COMMIT,
    MARKER_NONE,
    ManifestBody,
    encode_manifest_body,
)
from komira_broker.read_committed import (
    ChunkTxnTag,
    TxnSnapshot,
    chunk_is_offset_bearing,
    chunk_is_visible,
    collect_referenced_txn_ids,
)
from komira_broker.retention import ReapWorker, RetentionPolicy

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


comptime _Store = SharedInMemoryConditionalStore

# A marker type that is neither COMMIT nor ABORT (the next free value).
comptime _OTHER_MARKER: Int64 = 3


# =============================================================================
# _DeleteRecordingStore — delegates every verb; records each DELETEd key.
# =============================================================================


struct _DeleteRecordingStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """Delegates every verb to a shared in-memory store and appends the raw key
    of every `delete` to a log shared by all clones (single-threaded test)."""

    var _inner: _Store
    var _deletes: ArcPointer[List[String]]

    def __init__(out self, var inner: _Store):
        self._inner = inner^
        self._deletes = ArcPointer[List[String]](List[String]())

    def __init__(
        out self, var inner: _Store, var deletes: ArcPointer[List[String]]
    ):
        self._inner = inner^
        self._deletes = deletes^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._deletes.copy())

    def deleted_keys(self) -> List[String]:
        return self._deletes[].copy()

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def delete(self, path: Path) raises -> None:
        self._deletes[].append(path.raw())
        self._inner.delete(path)


# =============================================================================
# helpers
# =============================================================================


def _prefix(cluster: String, topic: String, pid: Int64) -> String:
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
    var schema = Schema(
        names=[String("key"), String("value")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.STRING.type_id],
        dtypes=[DType.int64, DType.uint8],
        nullables=[False, True],
    )
    return RecordBatch.from_typed_columns_2(schema^, kcol^, vcol^)


def _make_broker(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> BrokerCore[_Store]:
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
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
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    return ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=pid,
    )


def _make_manifest(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )


def _flush_rows(
    mut broker: BrokerCore[_Store], base_val: Int64, n: Int, ts: Int64
) raises:
    _ = broker.produce(_make_int64_batch(base_val, n), ts)
    _ = broker.flush_if_buffered(ts)


def _build_marker_partition(
    mut broker: BrokerCore[_Store],
) raises:
    """Chunks: 0 data(10 rows, ts 1000) | 1 ABORT marker (ts 2000) |
    2 data(10, ts 3000) | 3 COMMIT marker (ts 4000) | 4 data(10, ts 5000).
    Offsets: chunk 0 -> [0, 9], chunk 2 -> [10, 19], chunk 4 -> [20, 29]."""
    _flush_rows(broker, Int64(0), 10, Int64(1000))
    var abort_seq = broker.append_txn_marker(
        Int64(2000), Int64(7), Int64(1), String("txn-a"), False
    )
    assert_equal(abort_seq, Int64(1), "ABORT marker is chunk 1")
    _flush_rows(broker, Int64(10), 10, Int64(3000))
    var commit_seq = broker.append_txn_marker(
        Int64(4000), Int64(7), Int64(1), String("txn-b"), True
    )
    assert_equal(commit_seq, Int64(3), "COMMIT marker is chunk 3")
    _flush_rows(broker, Int64(20), 10, Int64(5000))


# =============================================================================
# (1) tail consume across ABORT + COMMIT markers
# =============================================================================


def test_tail_consume_across_markers() raises:
    print("[test_tail_consume_across_markers] starting...")
    var store = _Store()
    var cluster = String("mk1")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _build_marker_partition(broker)

    var src = MessageBrokerConsumer[_Store](
        _make_consume(store, cluster, topic, pid),
        String(cluster),
        String(topic),
        pid,
        Int64(0),
    )
    var segs = src.poll_tail(Int64(0))
    assert_equal(len(segs), 3, "tail returns the 3 data segments only")
    assert_equal(segs[0].chunk_seq, Int64(0), "seg 0 is chunk 0")
    assert_equal(segs[0].base_offset, Int64(0), "chunk 0 base 0")
    assert_equal(segs[0].last_offset, Int64(9), "chunk 0 last 9")
    assert_equal(segs[1].chunk_seq, Int64(2), "seg 1 is chunk 2 (ABORT skipped)")
    assert_equal(segs[1].base_offset, Int64(10), "chunk 2 base 10")
    assert_equal(segs[2].chunk_seq, Int64(4), "seg 2 is chunk 4 (COMMIT skipped)")
    assert_equal(segs[2].base_offset, Int64(20), "chunk 4 base 20")
    assert_equal(segs[2].last_offset, Int64(29), "chunk 4 last 29")
    for i in range(len(segs)):
        assert_equal(segs[i].record_count, Int64(10), "10 rows per segment")
        assert_true(len(segs[i].stream_bytes) > 0, "segment stream non-empty")
    _ = segs^

    # A poll that STARTS on a marker (chunk 3) yields only chunk 4.
    var from_marker = src.poll_tail(Int64(3))
    assert_equal(len(from_marker), 1, "poll from the COMMIT marker: 1 segment")
    assert_equal(from_marker[0].chunk_seq, Int64(4), "it is chunk 4")
    _ = from_marker^
    _ = src^
    _ = broker^
    _ = store^
    print("[test_tail_consume_across_markers] PASS")


# =============================================================================
# (2) full drain across markers
# =============================================================================


def test_drain_across_markers() raises:
    print("[test_drain_across_markers] starting...")
    var store = _Store()
    var cluster = String("mk2")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _build_marker_partition(broker)

    var consume = _make_consume(store, cluster, topic, pid)
    var index = consume.resolve_index()
    assert_equal(len(index), 3, "offset index holds the 3 data chunks only")
    for i in range(len(index)):
        assert_true(
            index[i].object_key.byte_length() > 0, "no empty key in the index"
        )
        assert_equal(index[i].base_offset, Int64(10 * i), "contiguous base")
    var res = consume.read_from_checked(Int64(0))
    assert_equal(len(res.segments), 3, "drain returns 3 segments")
    assert_equal(res.segments[2].last_offset, Int64(29), "drain ends at 29")
    _ = res^
    _ = consume^
    _ = broker^
    _ = store^
    print("[test_drain_across_markers] PASS")


# =============================================================================
# (3) ReapWorker after retention retires both markers
# =============================================================================


def test_reap_across_markers() raises:
    print("[test_reap_across_markers] starting...")
    var store = _Store()
    var cluster = String("mk3")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _build_marker_partition(broker)

    # Time retention at now=10000, retention 5500 ms: retire ts < 4500, i.e.
    # chunks 0 (data), 1 (ABORT), 2 (data), 3 (COMMIT); chunk 4 is active.
    var res = broker.retention_pass_on_partition(
        RetentionPolicy.time_based(Int64(5500)), Int64(10000)
    )
    assert_equal(res.tombstoned_count, Int64(4), "chunks 0..3 tombstoned")
    assert_equal(res.new_log_start_offset, Int64(20), "log_start offset 20")

    var m = _make_manifest(store, cluster, topic, pid)
    var key0 = String(ManifestBody.decode(m.read_chunk(Int64(0))).object_key)
    var key2 = String(ManifestBody.decode(m.read_chunk(Int64(2))).object_key)
    _ = m^

    var rec = _DeleteRecordingStore(store.clone())
    var rec_manifest = CasManifestStore[_DeleteRecordingStore](
        store=rec.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    var seg_store = rec.clone()
    var worker = ReapWorker[_DeleteRecordingStore](Int64(0))
    var reaped = worker.run(seg_store, rec_manifest, Int64(10000))
    assert_equal(reaped.reaped_count, Int64(4), "all 4 retired chunks reaped")
    assert_equal(reaped.skipped_live_count, Int64(0), "no live tombstone")

    # The segment DELETEs are exactly the two data chunks' keys. The manifest's
    # own chunk/tombstone deletes go through the same store; none may be "".
    var deleted = rec.deleted_keys()
    var n_empty = 0
    var saw0 = False
    var saw2 = False
    for i in range(len(deleted)):
        if deleted[i].byte_length() == 0:
            n_empty += 1
        if deleted[i] == key0:
            saw0 = True
        if deleted[i] == key2:
            saw2 = True
    assert_equal(n_empty, 0, "the reaper never DELETEs the empty key")
    assert_true(saw0, "chunk 0's .seg deleted")
    assert_true(saw2, "chunk 2's .seg deleted")

    # The tail still consumes after the reap: the surviving chunk 4 at [20, 29].
    var consume = _make_consume(store, cluster, topic, pid)
    var after = consume.read_from_checked(Int64(20))
    assert_equal(len(after.segments), 1, "1 surviving segment")
    assert_equal(after.segments[0].base_offset, Int64(20), "survivor base 20")
    _ = after^
    _ = consume^
    _ = seg_store^
    _ = rec_manifest^
    _ = rec^
    _ = broker^
    _ = store^
    print("[test_reap_across_markers] PASS")


# =============================================================================
# (4) LogCleaner never rewrites a marker chunk
# =============================================================================


def test_log_cleaner_skips_marker() raises:
    print("[test_log_cleaner_skips_marker] starting...")
    var store = _Store()
    var cluster = String("mk4")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    # chunk 0: data (k1, k2) | chunk 1: ABORT marker | chunk 2: data (k1) active.
    _ = broker.produce(
        _make_kv_batch(
            [Int64(1), Int64(2)], [String("a"), String("b")], [True, True]
        ),
        Int64(1000),
    )
    _ = broker.flush_if_buffered(Int64(1000))
    _ = broker.append_txn_marker(
        Int64(2000), Int64(7), Int64(1), String("txn-a"), False
    )
    _ = broker.produce(
        _make_kv_batch([Int64(1)], [String("c")], [True]), Int64(3000)
    )
    _ = broker.flush_if_buffered(Int64(3000))
    _ = broker^

    var manifest = _make_manifest(store, cluster, topic, pid)
    var marker_before = manifest.read_chunk(Int64(1))

    # The caller hands the cleaner chunks 0 and 1 (the marker paired with an
    # empty batch: it has no rows).
    var batches = Slab[RecordBatch]()
    batches.append(
        _make_kv_batch(
            [Int64(1), Int64(2)], [String("a"), String("b")], [True, True]
        )
    )
    batches.append(_make_kv_batch(List[Int64](), List[String](), List[Bool]()))
    var bases = List[Int64]()
    bases.append(Int64(0))
    bases.append(Int64(2))
    var seqs = List[Int64]()
    seqs.append(Int64(0))
    seqs.append(Int64(1))
    var cleaner = LogCleaner[_Store](
        CompactionConfig.compact(Int64(86_400_000)), key_col=0, value_col=1
    )
    var res = cleaner.run(manifest, batches^, bases, seqs, Int64(10_000))
    assert_true(res.ran, "cleaner ran")

    var marker_after = manifest.read_chunk(Int64(1))
    assert_false(
        is_chunk_compacted(marker_after), "marker carries no compaction sidecar"
    )
    assert_equal(len(marker_after), len(marker_before), "marker body length")
    for i in range(len(marker_before)):
        assert_equal(marker_after[i], marker_before[i], "marker byte-identical")
    # The data chunk alongside it WAS compacted (the guard is not a no-op).
    assert_true(
        is_chunk_compacted(manifest.read_chunk(Int64(0))), "chunk 0 compacted"
    )
    _ = manifest^
    _ = store^
    print("[test_log_cleaner_skips_marker] PASS")


# =============================================================================
# (5) dual_tier_resolve over a live index with markers
# =============================================================================


def test_dual_tier_skips_markers() raises:
    print("[test_dual_tier_skips_markers] starting...")
    var store = _Store()
    var cluster = String("mk5")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _build_marker_partition(broker)

    var consume = _make_consume(store, cluster, topic, pid)
    var live_index = consume.resolve_index()
    var index = CompactionIndex[_Store].build(
        store.clone(), _prefix(cluster, topic, pid), RetryPolicy.fast_test()
    )
    var refs = dual_tier_resolve(index, live_index, Int64(0))
    assert_equal(len(refs), 3, "3 live refs (markers absent)")
    var expect_base = Int64(0)
    for i in range(len(refs)):
        assert_false(refs[i].is_compacted, "live tier")
        assert_true(refs[i].object_key.byte_length() > 0, "no empty key")
        assert_equal(refs[i].base_offset, expect_base, "contiguous offsets")
        expect_base = refs[i].last_offset + Int64(1)
    assert_equal(expect_base, Int64(30), "covers [0, 29]")
    _ = refs^
    _ = index^
    _ = consume^
    _ = broker^
    _ = store^
    print("[test_dual_tier_skips_markers] PASS")


# =============================================================================
# (6) read_committed: a non-txn marker type with an empty txn_id
# =============================================================================


def test_read_committed_other_marker_empty_txn() raises:
    print("[test_read_committed_other_marker_empty_txn] starting...")
    var snapshot = TxnSnapshot()
    var other = ChunkTxnTag(
        marker_type=_OTHER_MARKER, txn_id=String(""), epoch=Int64(5)
    )
    assert_false(chunk_is_visible(other, snapshot), "not visible as data")
    assert_false(chunk_is_offset_bearing(other), "not offset-bearing")
    assert_false(other.is_transactional(), "not transactional")

    # A plain non-transactional data chunk beside it stays visible.
    var data = ChunkTxnTag(
        marker_type=MARKER_NONE, txn_id=String(""), epoch=Int64(-1)
    )
    assert_true(chunk_is_visible(data, snapshot), "plain data visible")

    # Collecting referenced txns over [data, other, ABORT("txn-a")] names only
    # txn-a: the empty-txn marker is not a txn boundary.
    var tags = List[ChunkTxnTag]()
    tags.append(data.copy())
    tags.append(other.copy())
    tags.append(
        ChunkTxnTag(
            marker_type=MARKER_ABORT, txn_id=String("txn-a"), epoch=Int64(1)
        )
    )
    var ids = collect_referenced_txn_ids(tags)
    assert_equal(len(ids), 1, "only txn-a is referenced")
    assert_equal(ids[0], String("txn-a"), "txn-a")
    print("[test_read_committed_other_marker_empty_txn] PASS")


# =============================================================================
# (7) ManifestBody.has_segment over every body shape
# =============================================================================


def _decoded(
    key: String, record_count: Int64, marker_type: Int64, txn_id: String
) raises -> ManifestBody:
    return ManifestBody.decode(
        encode_manifest_body(
            key,
            record_count,
            UInt32(0),
            Int64(0),
            Int64(1000),
            Int64(-1),
            Int64(-1),
            Int64(-1),
            Int64(-1),
            marker_type,
            txn_id,
        )
    )


def test_has_segment_predicate() raises:
    print("[test_has_segment_predicate] starting...")
    var seg = String("c/p/0/abc.seg")
    # MARKER_NONE + non-empty key -> True (data, txn-open data, zero-row data).
    assert_true(
        _decoded(seg, Int64(10), MARKER_NONE, String("")).has_segment(),
        "data chunk owns a segment",
    )
    assert_true(
        _decoded(seg, Int64(10), MARKER_NONE, String("txn-a")).has_segment(),
        "txn-open data chunk owns a segment",
    )
    assert_true(
        _decoded(seg, Int64(0), MARKER_NONE, String("")).has_segment(),
        "zero-row data chunk still owns its .seg (the reaper must delete it)",
    )
    # A legacy 3-field body (no txn trailer) decodes MARKER_NONE -> True.
    var legacy = List[UInt8]()
    var full = encode_manifest_body(seg, Int64(4), UInt32(9))
    for i in range(20 + seg.byte_length()):
        legacy.append(full[i])
    assert_true(
        ManifestBody.decode(legacy).has_segment(), "legacy body owns a segment"
    )
    # marker_type != MARKER_NONE -> False (first conjunct false).
    assert_false(
        _decoded(String(""), Int64(0), MARKER_COMMIT, String("t")).has_segment(),
        "COMMIT marker owns no segment",
    )
    assert_false(
        _decoded(String(""), Int64(0), MARKER_ABORT, String("t")).has_segment(),
        "ABORT marker owns no segment",
    )
    assert_false(
        _decoded(String(""), Int64(0), _OTHER_MARKER, String("")).has_segment(),
        "other marker type owns no segment",
    )
    assert_false(
        _decoded(seg, Int64(0), MARKER_COMMIT, String("t")).has_segment(),
        "a marker with a key still owns no segment",
    )
    # MARKER_NONE + empty key -> False (second conjunct false).
    assert_false(
        _decoded(String(""), Int64(10), MARKER_NONE, String("")).has_segment(),
        "a MARKER_NONE body with an empty key reports no segment",
    )
    print("[test_has_segment_predicate] PASS")


# =============================================================================
# (8) ConsumeCore.read_chunk_segment directly, chunk by chunk
# =============================================================================


def test_read_chunk_segment_markers_none() raises:
    print("[test_read_chunk_segment_markers_none] starting...")
    var store = _Store()
    var cluster = String("mk8")
    var topic = String("t")
    var pid = Int64(0)
    var broker = _make_broker(store, cluster, topic, pid)
    _build_marker_partition(broker)

    var consume = _make_consume(store, cluster, topic, pid)
    for seq in range(5):
        var got = consume.read_chunk_segment(Int64(seq))
        if seq == 1 or seq == 3:
            assert_false(Bool(got), "marker chunk yields no segment")
        else:
            assert_true(Bool(got), "data chunk yields its segment")
            var s = got.take()
            assert_equal(s.chunk_seq, Int64(seq), "chunk_seq")
            assert_equal(s.base_offset, Int64(5 * seq), "absolute base offset")
            assert_equal(s.record_count, Int64(10), "10 rows")
            _ = s^
    _ = consume^
    _ = broker^
    _ = store^
    print("[test_read_chunk_segment_markers_none] PASS")


# =============================================================================
# (9) a no-segment chunk with records keeps the offset index aligned
# =============================================================================


def test_no_segment_chunk_keeps_offsets_aligned() raises:
    """No producer writes a MARKER_NONE body with an empty key; if one is ever
    read, `resolve_index` must still count its record_count into the running
    base, so the offsets it assigns match `read_chunk_segment`'s prior sum."""
    print("[test_no_segment_chunk_keeps_offsets_aligned] starting...")
    var store = _Store()
    var cluster = String("mk9")
    var topic = String("t")
    var pid = Int64(0)
    var m = _make_manifest(store, cluster, topic, pid)
    _ = m.append(encode_manifest_body(String(""), Int64(5), UInt32(0)), Int64(5))
    _ = m^
    var broker = _make_broker(store, cluster, topic, pid)
    _flush_rows(broker, Int64(0), 10, Int64(2000))

    var consume = _make_consume(store, cluster, topic, pid)
    var index = consume.resolve_index()
    assert_equal(len(index), 1, "the empty-key chunk has no index entry")
    assert_equal(index[0].chunk_seq, Int64(1), "chunk 1 is the data chunk")
    assert_equal(index[0].base_offset, Int64(5), "base counts chunk 0's 5")
    var tail = consume.read_chunk_segment(Int64(1))
    assert_true(Bool(tail), "data chunk read")
    assert_equal(
        tail.take().base_offset, index[0].base_offset, "tail base == index base"
    )
    assert_false(Bool(consume.read_chunk_segment(Int64(0))), "chunk 0: none")
    _ = consume^
    _ = broker^
    _ = store^
    print("[test_no_segment_chunk_keeps_offsets_aligned] PASS")


def main() raises:
    test_tail_consume_across_markers()
    test_drain_across_markers()
    test_reap_across_markers()
    test_log_cleaner_skips_marker()
    test_dual_tier_skips_markers()
    test_read_committed_other_marker_empty_txn()
    test_has_segment_predicate()
    test_read_chunk_segment_markers_none()
    test_no_segment_chunk_keeps_offsets_aligned()
    print("[OK] test_broker_marker_chunk_readers_offline")

# =============================================================================
# test_read_repair_recovery.mojo
#   The read-repair recovery arm of both dual-tier consumers, and the
#   completion of an interrupted compaction round.
# =============================================================================
#
# A consumer resolves the live index, reads the first segments, and then a
# compaction round commits underneath it: the Parquet object is appended to the
# compacted index, the live chunks are tombstoned, the live log start advances
# and the superseded `.seg` objects are deleted. The reader's next segment GET
# is a not-found. The consumer re-resolves from that segment's base offset and
# must serve the range from the compacted tier, with every offset delivered
# exactly once.
#
# The race is played by `_RaceStore`: the first GET of the armed `.seg` key runs
# a real `CompactionWorker.run_once` over the shared inner store, deletes the
# superseded `.seg` objects, and then lets the GET fail as it would on a real
# store. The re-resolve sees the post-commit state.
#
#   * test_legacy_consumer_recovers_from_reaped_segment
#   * test_sublineage_consumer_recovers_from_reaped_segment
#       Each asserts the batch ranges are contiguous and non-overlapping, the
#       rows carry `val == offset`, the repaired range comes from the compacted
#       tier and the live suffix from the live tier.
#   * test_worker_tombstones_segments_of_an_interrupted_round
#       A compacted entry whose live chunks were never tombstoned (the process
#       stopped between the index append and the tombstones) is completed by the
#       next round: the chunks are tombstoned and the live log start advances.
#
#   * test_legacy_consumer_repair_covers_two_already_read_batches
#       One repaired object covers two already-read live batches: one batch.
#   * test_worker_does_not_tombstone_a_segment_the_tail_partly_covers
#       A compacted entry ending inside a live segment leaves that segment live.
#
# No pointer type in any signature, no wildcard origins.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_broker.broker_core import BrokerCore
from komira_broker.compacted_index import CompactionIndex
from komira_broker.consume_core import ConsumeCore
from komira_broker.sublineage_consume import SubLineageConsumeResolver
from komira_broker_compaction.compaction_worker import CompactionWorker
from komira_broker_compaction.dual_tier_consume import (
    DecodedTierBatch,
    DualTierConsumer,
    SubLineageDualTierConsumer,
)
from komira_parquet_api.types import CompressionCodec
from komira_parquet_writer.record_batch_writer import (
    write_record_batches_to_parquet_bytes,
)
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    tombstone_key,
)
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

comptime _Inner = SharedInMemoryConditionalStore

comptime _CLUSTER = "rr"
comptime _TOPIC = "t"
comptime _PID = Int64(0)


def _partition_prefix() -> String:
    return String(_CLUSTER) + "/_meta/topics/" + String(_TOPIC) + "/" + String(
        _PID
    )


def _make_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    """One-column `val:INT64` batch with `val == base_val + i`."""
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


def _produce_segments(
    store: _Inner, prefix: String, n_segments: Int, rows: Int
) raises -> List[String]:
    """Produce `n_segments` live segments of `rows` rows (`val == offset`) into
    the manifest at `prefix`; returns the `.seg` keys."""
    var manifest = CasManifestStore[_Inner](
        store=store.clone(),
        prefix=String(prefix),
        retry=RetryPolicy.fast_test(),
    )
    var broker = BrokerCore[_Inner](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=_PID,
        broker_id=String("broker-A"),
    )
    var keys = List[String]()
    for i in range(n_segments):
        _ = broker.produce(
            _make_batch(Int64(i * rows), rows), Int64(1000 + i * 1000)
        )
        var pr = broker.flush_if_buffered(Int64(1000 + i * 1000))
        if not pr:
            raise Error("flush produced nothing")
        keys.append(String(pr.value().copy().segment_key))
    return keys^


def _worker_on[
    S: CloneableConditionalWriteStore
](store: S, live_prefix: String, index_prefix: String) raises -> CompactionWorker[
    S
]:
    return CompactionWorker[S](
        consume=ConsumeCore[S](
            segment_store=store.clone(),
            manifest=CasManifestStore[S](
                store=store.clone(),
                prefix=String(live_prefix),
                retry=RetryPolicy.fast_test(),
            ),
            cluster=String(_CLUSTER),
            topic=String(_TOPIC),
            partition=_PID,
        ),
        index=CompactionIndex[S].build(
            store.clone(), String(index_prefix), RetryPolicy.fast_test()
        ),
        segment_store=store.clone(),
        live_manifest=CasManifestStore[S](
            store=store.clone(),
            prefix=String(live_prefix),
            retry=RetryPolicy.fast_test(),
        ),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=_PID,
    )


struct _RaceStore(CloneableConditionalWriteStore, Movable, Deinitable):
    """A clone-shared store whose first GET of `race_key` first commits a
    compaction round of `round_segments` segments over the inner store and
    deletes `reap_keys`, then performs the GET (a not-found, as the key is
    among the deleted). Every clone shares the inner state, and the fired
    marker is an object in it."""

    var inner: _Inner
    var race_key: String
    var reap_keys: List[String]
    var live_prefix: String
    var index_prefix: String
    var round_segments: Int
    var flag: String

    def __init__(
        out self,
        var inner: _Inner,
        var race_key: String,
        var reap_keys: List[String],
        var live_prefix: String,
        var index_prefix: String,
        round_segments: Int,
    ):
        self.inner = inner^
        self.race_key = race_key^
        self.reap_keys = reap_keys^
        self.flag = live_prefix + "/test-race-fired"
        self.live_prefix = live_prefix^
        self.index_prefix = index_prefix^
        self.round_segments = round_segments

    def clone(self) -> Self:
        return Self(
            self.inner.clone(),
            String(self.race_key),
            self.reap_keys.copy(),
            String(self.live_prefix),
            String(self.index_prefix),
            self.round_segments,
        )

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if path.raw() == self.race_key and not self._fired():
            _ = self.inner.put(Path.parse(self.flag), List[UInt8]())
            var worker = _worker_on[_Inner](
                self.inner, self.live_prefix, self.index_prefix
            )
            var res = worker.run_once(
                now_ms=Int64(100000),
                min_segments=Int64(self.round_segments),
                max_segments=Int64(self.round_segments),
            )
            if not res.compacted:
                raise Error("the racing round did not compact")
            for i in range(len(self.reap_keys)):
                self.inner.delete(Path.parse(self.reap_keys[i]))
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)

    def _fired(self) -> Bool:
        try:
            _ = self.inner.head(Path.parse(self.flag))
            return True
        except e:
            _ = e
            return False


def _assert_repaired(
    batches: Slab[DecodedTierBatch], compacted_last: Int64, total: Int
) raises:
    """Every offset `[0, total)` exactly once, in order, `val == offset`; the
    batches up to `compacted_last` from the compacted tier, the rest live."""
    var next = Int64(0)
    var rows = 0
    for i in range(len(batches)):
        ref b = batches[i]
        assert_equal(b.base_offset, next, "contiguous, no overlap at batch")
        assert_equal(
            b.is_compacted,
            b.last_offset <= compacted_last,
            "tier of the batch at base " + String(b.base_offset),
        )
        var arr = b.batch.column_at(0).as_primitive[DType.int64]()
        assert_equal(b.batch.num_rows(), Int(b.last_offset - b.base_offset) + 1)
        for r in range(b.batch.num_rows()):
            assert_equal(arr.get(r), b.base_offset + Int64(r), "val == offset")
        rows += b.batch.num_rows()
        next = b.last_offset + Int64(1)
    assert_equal(rows, total, "every row delivered once")
    assert_equal(next, Int64(total), "tail")


def test_legacy_consumer_recovers_from_reaped_segment() raises:
    """The second segment is compacted away between the consumer's resolve and
    its GET of that segment. The first segment was already read from the live
    tier; the repaired read replaces it with the compacted object that now
    covers it, and the live suffix follows."""
    var base = _Inner()
    var prefix = _partition_prefix()
    var keys = _produce_segments(base, prefix, 4, 10)
    var reap = List[String]()
    reap.append(keys[0])
    reap.append(keys[1])
    var store = _RaceStore(
        base.clone(), String(keys[1]), reap^, String(prefix), String(prefix), 2
    )

    var consume = ConsumeCore[_RaceStore](
        segment_store=store.clone(),
        manifest=CasManifestStore[_RaceStore](
            store=store.clone(),
            prefix=String(prefix),
            retry=RetryPolicy.fast_test(),
        ),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=_PID,
    )
    var index = CompactionIndex[_RaceStore].build(
        store.clone(), String(prefix), RetryPolicy.fast_test()
    )
    var dual = DualTierConsumer[_RaceStore](
        consume=consume^, index=index^, object_store=store.clone()
    )
    var batches = dual.read_from(Int64(0))
    assert_true(_exists(base, prefix + "/test-race-fired"), "the race ran")
    _assert_repaired(batches, Int64(19), 40)
    assert_equal(len(batches), 3, "compacted [0,19] then two live segments")


def test_sublineage_consumer_recovers_from_reaped_segment() raises:
    """The same race over the sub-lineage consumer: the live tier is the folded
    `_base` index, and the compaction index sits at the partition prefix."""
    var base = _Inner()
    var bp = _partition_prefix()
    var base_prefix = bp + "/_lineage/_base"
    var keys = _produce_segments(base, base_prefix, 4, 10)
    var reap = List[String]()
    reap.append(keys[0])
    reap.append(keys[1])
    var store = _RaceStore(
        base.clone(),
        String(keys[1]),
        reap^,
        String(base_prefix),
        String(bp),
        2,
    )

    var resolver = SubLineageConsumeResolver[_RaceStore](
        store.clone(), String(bp)
    )
    assert_true(resolver.has_base(), "the `_base` lineage is live")
    var consume = ConsumeCore[_RaceStore](
        segment_store=store.clone(),
        manifest=CasManifestStore[_RaceStore](
            store=store.clone(),
            prefix=String(base_prefix),
            retry=RetryPolicy.fast_test(),
        ),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=_PID,
    )
    var index = CompactionIndex[_RaceStore].build(
        store.clone(), String(bp), RetryPolicy.fast_test()
    )
    var dual = SubLineageDualTierConsumer[_RaceStore](
        resolver=resolver^,
        consume=consume^,
        index=index^,
        object_store=store.clone(),
    )
    var batches = dual.read_from(Int64(0))
    assert_true(_exists(base, base_prefix + "/test-race-fired"), "race ran")
    _assert_repaired(batches, Int64(19), 40)
    assert_equal(len(batches), 3, "compacted [0,19] then two live segments")


def test_worker_tombstones_segments_of_an_interrupted_round() raises:
    """The compacted entry for `[0,19]` is in the index, but the process
    stopped before tombstoning chunks 0 and 1 or advancing the live log start.
    A later round with nothing new to compact completes the interrupted one."""
    var store = _Inner()
    var prefix = _partition_prefix()
    _ = _produce_segments(store, prefix, 4, 10)

    # Commit only the first half of a round, as an interrupted process would:
    # the Parquet object and the index append, no tombstones.
    var batches = Slab[RecordBatch]()
    batches.append(_make_batch(Int64(0), 10))
    batches.append(_make_batch(Int64(10), 10))
    var pbytes = write_record_batches_to_parquet_bytes(
        batches^, codec=CompressionCodec.SNAPPY, max_rows_per_rg=10
    )
    var pkey = String(_CLUSTER) + "/compacted/interrupted-0-19.parquet"
    _ = store.put(Path.parse(pkey), pbytes^)
    var index = CompactionIndex[_Inner].build(
        store.clone(), String(prefix), RetryPolicy.fast_test()
    )
    _ = index.append_compacted(
        parquet_key=pkey,
        base_offset=Int64(0),
        last_offset=Int64(19),
        record_count=Int64(20),
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(1),
    )
    assert_equal(_tomb_count(store, prefix, 4), 0, "no tombstone yet")

    var worker = _worker_on[_Inner](store, prefix, prefix)
    var later = worker.run_once(
        now_ms=Int64(200000), min_segments=Int64(3), max_segments=Int64(64)
    )
    assert_true(not later.compacted, "nothing new to compact")
    assert_equal(
        _tomb_count(store, prefix, 4), 2, "chunks 0 and 1 are tombstoned"
    )
    var manifest = CasManifestStore[_Inner](
        store=store.clone(),
        prefix=String(prefix),
        retry=RetryPolicy.fast_test(),
    )
    var ls = manifest.read_log_start()
    assert_equal(ls.log_start_seq, Int64(2), "log start seq advanced")
    assert_equal(ls.log_start_offset, Int64(20), "log start offset advanced")


def test_legacy_consumer_repair_covers_two_already_read_batches() raises:
    """A four-segment round commits while the consumer has read the first two
    segments and is about to GET the third. The compacted object `[0,39]`
    covers both already-read live batches, so both are dropped and the result
    is exactly one batch."""
    var base = _Inner()
    var prefix = _partition_prefix()
    var keys = _produce_segments(base, prefix, 4, 10)
    var reap = List[String]()
    for i in range(4):
        reap.append(keys[i])
    var store = _RaceStore(
        base.clone(), String(keys[2]), reap^, String(prefix), String(prefix), 4
    )
    var consume = ConsumeCore[_RaceStore](
        segment_store=store.clone(),
        manifest=CasManifestStore[_RaceStore](
            store=store.clone(),
            prefix=String(prefix),
            retry=RetryPolicy.fast_test(),
        ),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=_PID,
    )
    var index = CompactionIndex[_RaceStore].build(
        store.clone(), String(prefix), RetryPolicy.fast_test()
    )
    var dual = DualTierConsumer[_RaceStore](
        consume=consume^, index=index^, object_store=store.clone()
    )
    var batches = dual.read_from(Int64(0))
    assert_true(_exists(base, prefix + "/test-race-fired"), "the race ran")
    _assert_repaired(batches, Int64(39), 40)
    assert_equal(len(batches), 1, "one compacted batch covers all four")


def test_worker_does_not_tombstone_a_segment_the_tail_partly_covers() raises:
    """A compacted entry `[0,14]` over 10-row segments covers chunk 0 fully and
    chunk 1 only partly. Only chunk 0 is tombstoned and the live log start
    moves to chunk 1 / offset 10, so offsets 15..19 stay in the live tier."""
    var store = _Inner()
    var prefix = _partition_prefix()
    _ = _produce_segments(store, prefix, 4, 10)
    var batches = Slab[RecordBatch]()
    batches.append(_make_batch(Int64(0), 15))
    var pbytes = write_record_batches_to_parquet_bytes(
        batches^, codec=CompressionCodec.SNAPPY, max_rows_per_rg=15
    )
    var pkey = String(_CLUSTER) + "/compacted/straddle-0-14.parquet"
    _ = store.put(Path.parse(pkey), pbytes^)
    var index = CompactionIndex[_Inner].build(
        store.clone(), String(prefix), RetryPolicy.fast_test()
    )
    _ = index.append_compacted(
        parquet_key=pkey,
        base_offset=Int64(0),
        last_offset=Int64(14),
        record_count=Int64(15),
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(0),
    )
    var worker = _worker_on[_Inner](store, prefix, prefix)
    try:
        # The desync guard may refuse the round afterwards; step 1b has
        # already run by then and is what this test checks.
        _ = worker.run_once(
            now_ms=Int64(200000), min_segments=Int64(3), max_segments=Int64(64)
        )
    except e:
        _ = e
    assert_equal(_tomb_count(store, prefix, 4), 1, "only chunk 0 tombstoned")
    assert_true(
        _exists(store, tombstone_key(prefix, Int64(0)).raw()), "chunk 0 marked"
    )
    var manifest = CasManifestStore[_Inner](
        store=store.clone(),
        prefix=String(prefix),
        retry=RetryPolicy.fast_test(),
    )
    var ls = manifest.read_log_start()
    assert_equal(ls.log_start_seq, Int64(1), "log start seq")
    assert_equal(ls.log_start_offset, Int64(10), "log start offset")


def _exists(store: _Inner, key: String) -> Bool:
    try:
        _ = store.head(Path.parse(key))
        return True
    except e:
        _ = e
        return False


def _tomb_count(store: _Inner, prefix: String, n_chunks: Int) -> Int:
    var c = 0
    for i in range(n_chunks):
        try:
            _ = store.head(tombstone_key(prefix, Int64(i)))
            c += 1
        except e:
            _ = e
    return c


def main() raises:
    test_legacy_consumer_recovers_from_reaped_segment()
    test_sublineage_consumer_recovers_from_reaped_segment()
    test_legacy_consumer_repair_covers_two_already_read_batches()
    test_worker_tombstones_segments_of_an_interrupted_round()
    test_worker_does_not_tombstone_a_segment_the_tail_partly_covers()
    print("ALL test_read_repair_recovery PASS")

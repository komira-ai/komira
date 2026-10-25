# =============================================================================
# test_search_compact_once_order.mojo — the merged split object is written
# BEFORE its summary is appended to the catalog.
# =============================================================================
#
# `compact_once` writes the merged split object and then appends its summary to
# the `_base` lineage. The order is load-bearing: the append is what makes the
# split visible, so a summary appended first would name an object that does not
# exist yet, which a reader cannot tell from a transient miss, and a crash
# between the two would lose the merged documents while their inputs are
# already hidden by the merged-input skip. The reverse order only leaves a
# harmless orphan object.
#
# A check after `compact_once` returns cannot see the order, because by then
# both writes have happened. So the store is wrapped in a probe that asks the
# question at the only moment it can be answered: at the instant a manifest
# chunk is written to the `_base` lineage, has a merged split object already
# been written?
#
# The verdict is recorded in the SHARED in-memory map, not in a field of the
# probe, because `compact_once` clones its store for each lineage and a field
# would belong to a different instance by then. The marker keys start with
# `__probe__/` and the probe skips them, so it never observes its own writes.
#
# Cases:
#   1  `compact_once` over the unsharded lineage writes the merged object before
#      the append (the probe fired at all: a probe that never fired would pass
#      for free), and the summary in `_base` names the very key that was
#      written.
#   2  the same over per-writer shard lineages.
#   3  a failed object write publishes nothing and retires nothing; an orphan
#      object left at the merged key by an earlier attempt is overwritten by
#      the next pass, which then publishes.
#   4  a transient failure reading a retired chunk during the reap leaves the
#      chunk and its split object in place; the next pass reaps both.
#   5  positive control: an append to `_base` that names an object nothing ever
#      wrote is reported as a violation, so the silence in case 1 is evidence.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_json import parse_json_value

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
from komira_objectstore.sublineage_shard_keys import LINEAGE_BASE_SHARD
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_search.sink import SearchSink
from komira_search.split import SplitView

from komira_search_catalog import (
    SearchMetastore,
    SplitSummary,
    make_merged_split_summary,
    make_shard_id,
    make_split_summary,
    shard_manifest_prefix,
)
from komira_search_catalog.metastore import (
    list_live_splits_across_shards_with_seq,
)

from komira_search_compaction import (
    compact_once,
    CompactionConfig,
    CompactionResult,
    MERGE_FACTOR,
    content_addressed_merge_key,
)


comptime _INDEX: String = "logs"
comptime _KEY_PREFIX: String = "order-run"
comptime _META: String = "order-run/logs/meta"

comptime _PROBE_DATA_SEEN: String = "__probe__/merged_object_was_written"
comptime _PROBE_OK: String = "__probe__/append_saw_its_object"
comptime _PROBE_VIOLATION: String = "__probe__/append_preceded_its_object"
comptime _PROBE_FAIL_PUT: String = "__probe__/fail_merged_object_put"
comptime _PROBE_FAIL_READS: String = "__probe__/fail_unsharded_chunk_reads"
comptime _PROBE_REAP_REACHED: String = "__probe__/reap_reached"
comptime _PROBE_FAIL_FIRED: String = "__probe__/chunk_read_failure_fired"
comptime _PROBE_WROTE: String = "__probe__/wrote/"


struct OrderProbeStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """A `SharedInMemoryConditionalStore` that records, for every manifest
    chunk written to the `_base` lineage, whether a merged split object had
    already been written at that instant. It can also fail the write of a
    merged object, or, once the reap has started, the first read of an unsharded-lineage
    manifest chunk, while a marker in the shared map says so."""

    var _inner: SharedInMemoryConditionalStore

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def _mark(self, key: String) raises:
        var one = List[UInt8]()
        one.append(UInt8(1))
        _ = self._inner.put(Path.parse(key), one^)

    def _exists(self, key: String) -> Bool:
        try:
            var b = self._inner.get(Path.parse(key))
            _ = b^
            return True
        except:
            return False

    def _note(self, path: Path) raises:
        var raw = path.raw()
        # Never observe our own marker writes.
        if raw.find(String("__probe__/")) == 0:
            return
        if raw.find(String("/splits/merged-")) > 0:
            if self._exists(_PROBE_FAIL_PUT):
                raise Error("injected: the merged object write failed")
            self._mark(_PROBE_DATA_SEEN)
            self._mark(String(_PROBE_WROTE) + raw)
            return
        if (
            raw.find(String("/_lineage/_base/manifest/")) > 0
            and raw.find(String(".chunk")) > 0
        ):
            # The question, asked at the only moment it can be answered.
            if self._exists(_PROBE_DATA_SEEN):
                self._mark(_PROBE_OK)
            else:
                self._mark(_PROBE_VIOLATION)

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._note(path)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._note(path)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._note(path)
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        var raw = path.raw()
        # The reap is the only reader of a tombstone, so the first tombstone
        # read marks the point where the pass has left the snapshot (which also
        # reads chunks) and entered the reap.
        if raw.find(String("/logs/meta/tombstones/")) > 0:
            self._mark(_PROBE_REAP_REACHED)
        if (
            raw.find(String("/logs/meta/manifest/")) > 0
            and raw.find(String(".chunk")) > 0
            and self._exists(_PROBE_FAIL_READS)
            and self._exists(_PROBE_REAP_REACHED)
            and not self._exists(_PROBE_FAIL_FIRED)
        ):
            self._mark(_PROBE_FAIL_FIRED)
            raise Error("injected: transient chunk read failure")
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        return self._inner.delete(path)


def _flag() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(UInt8(1))
    return b^


def _garbage() -> List[UInt8]:
    var b = List[UInt8]()
    for _ in range(3):
        b.append(UInt8(7))
    return b^


def _marked(store: SharedInMemoryConditionalStore, key: String) -> Bool:
    try:
        var b = store.get(Path.parse(key))
        _ = b^
        return True
    except:
        return False


def _uuid(seed: Int) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 7 + i * 13) & 0xFF)
    return u^


def _one_doc_ndjson(word: String, status: String, price: Int) -> String:
    return String(
        '{"index":{}}\n'
        + '{"body":"alpha '
        + word
        + '","status":"'
        + status
        + '","price":'
        + String(price)
        + "}\n"
    )


def _ingest_to_split(ndjson: String, seed: Int) raises -> List[UInt8]:
    """Bulk NDJSON (an action line, then a document line, per document) into one
    real split: the document lines become a `body` text column, a verbatim
    `_source` column, a `status` keyword column and a `price` int64 column, and
    the `SearchSink` writes them as a split with the UUID of `seed`."""
    var bodies = List[String]()
    var sources = List[String]()
    var statuses = List[String]()
    var prices = List[Int64]()
    for line in ndjson.split("\n"):
        var text = String(line)
        if text.byte_length() == 0:
            continue
        var doc = parse_json_value(text)
        if not doc.has("body"):
            continue  # the action line
        bodies.append(doc.get("body").as_string())
        sources.append(text^)
        statuses.append(doc.get("status").as_string())
        prices.append(doc.get("price").as_int64())
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, False))
    sb.add_field(Field("price", ArrowType.INT64, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(Column.from_string(StringArray.from_strings(bodies)))
    rb.add_column(Column.from_string(StringArray.from_strings(sources)))
    rb.add_column(Column.from_string(StringArray.from_strings(statuses)))
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(prices)
        )
    )
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("logs"),
        String("body"),
        _uuid(seed),
    )
    sink.init_sink(schema)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _publish_raw(
    inner: SharedInMemoryConditionalStore, lineage: String, i: Int
) raises:
    """One real one-document split, object and summary, into `lineage`."""
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        inner.clone(), lineage.copy(), RetryPolicy.fast_test()
    )
    var meta = SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String(_INDEX)
    )
    var bts = _ingest_to_split(
        _one_doc_ndjson(String("w") + String(i), "active", 10 * (i + 1)), i
    )
    var okey = String(_KEY_PREFIX) + "/logs/splits/raw" + String(i) + ".split"
    _ = inner.put(Path.parse(okey), bts.copy())
    var view = SplitView.parse(bts.copy())
    _ = meta.publish(
        make_split_summary(
            view.split_uuid(),
            Int64(view.doc_count()),
            Int64(len(bts)),
            Int64(view.min_doc_id()),
            Int64(view.max_doc_id()),
            String(_INDEX),
            String("body"),
            okey^,
        )
    )
    _ = meta^


def _publish_unsharded(inner: SharedInMemoryConditionalStore) raises:
    for i in range(MERGE_FACTOR):
        _publish_raw(inner, String(_META), i)


def _publish_sharded(inner: SharedInMemoryConditionalStore) raises:
    for i in range(MERGE_FACTOR):
        _publish_raw(
            inner,
            shard_manifest_prefix(
                String(_META), make_shard_id(String("node"), i)
            ),
            i,
        )


def _pass(
    probe: OrderProbeStore, now_ms: Int64, seed: Int
) raises -> CompactionResult:
    return compact_once(
        probe,
        String(_META),
        String(_INDEX),
        String("body"),
        CompactionConfig(String(_KEY_PREFIX), now_ms, Int64(60_000)),
        _uuid(seed),
    )


def _merged_entries(
    inner: SharedInMemoryConditionalStore,
) raises -> List[SplitSummary]:
    var live = list_live_splits_across_shards_with_seq(
        inner, String(_META), String(_INDEX)
    )
    var out = List[SplitSummary]()
    for i in range(len(live)):
        if live[i].summary.is_merged():
            out.append(live[i].summary.copy())
    return out^


def _assert_order_and_key(
    inner: SharedInMemoryConditionalStore, tag: String
) raises:
    # Non-vacuity: the probe must have seen a `_base` chunk write at all. A
    # probe that never fired would satisfy the ordering assertion for free.
    assert_true(
        _marked(inner, _PROBE_OK) or _marked(inner, _PROBE_VIOLATION),
        tag
        + ": NON-VACUITY: the probe saw no `_base` chunk write, so the ordering"
        " assertion would be vacuous; the append stopped going through the"
        " store or the key shape changed",
    )
    assert_true(
        _marked(inner, _PROBE_DATA_SEEN),
        tag + ": the probe saw the merged object being written",
    )
    assert_false(
        _marked(inner, _PROBE_VIOLATION),
        tag
        + ": ORDER: a summary was appended to `_base` while the merged object"
        " did not exist yet; the object must be written first",
    )
    assert_true(
        _marked(inner, _PROBE_OK),
        tag + ": the append saw its merged object already written",
    )
    # The oracle is coarse (any merged object counts), so also pin the key:
    # the summary visible in the catalog names exactly the key that was
    # written, and that object is a split of all the merged documents.
    var merged = _merged_entries(inner)
    assert_equal(len(merged), 1, tag + ": one merged summary is live")
    var key = merged[0].object_key.copy()
    assert_true(
        _marked(inner, String(_PROBE_WROTE) + Path.parse(key).raw()),
        tag + ": the summary names a key the pass wrote",
    )
    var view = SplitView.parse(inner.get(Path.parse(key)))
    assert_equal(
        view.doc_count(),
        MERGE_FACTOR,
        tag + ": the named object holds every merged document",
    )


def test_the_merged_object_is_written_before_its_summary_is_appended() raises:
    var inner = SharedInMemoryConditionalStore()
    _publish_unsharded(inner)
    var probe = OrderProbeStore(inner.clone())
    var result = _pass(probe, Int64(1_000_000), 950)
    assert_true(result.merged, "1: the pass merged")
    _assert_order_and_key(inner, String("1"))
    _ = probe^
    _ = inner^


def test_the_order_holds_for_writer_shard_inputs() raises:
    var inner = SharedInMemoryConditionalStore()
    _publish_sharded(inner)
    var probe = OrderProbeStore(inner.clone())
    var result = _pass(probe, Int64(1_000_000), 952)
    assert_true(result.merged, "2: the pass merged")
    assert_equal(result.seqs_retired, MERGE_FACTOR, "2: every input retired")
    _assert_order_and_key(inner, String("2"))
    _ = probe^
    _ = inner^


def test_a_failed_object_write_publishes_nothing_and_an_orphan_is_replaced() raises:
    var inner = SharedInMemoryConditionalStore()
    _publish_unsharded(inner)
    _ = inner.put(Path.parse(_PROBE_FAIL_PUT), _flag())
    var probe = OrderProbeStore(inner.clone())
    var raised = False
    try:
        _ = _pass(probe, Int64(1_000_000), 953)
    except e:
        raised = String(e).find(String("injected")) >= 0
    assert_true(raised, "3: the pass raises the object write failure")
    # Nothing was published and nothing was retired.
    assert_false(
        _marked(inner, _PROBE_OK) or _marked(inner, _PROBE_VIOLATION),
        "3: no summary was appended to `_base`",
    )
    var live = list_live_splits_across_shards_with_seq(
        inner, String(_META), String(_INDEX)
    )
    assert_equal(len(live), MERGE_FACTOR, "3: every input is still live")
    assert_equal(len(_merged_entries(inner)), 0, "3: no merged summary")

    # An earlier attempt that wrote the object and stopped before the append
    # leaves garbage at the merged key. The next pass overwrites it.
    var uuids = List[Array[UInt8, 16]]()
    for i in range(len(live)):
        uuids.append(live[i].summary.split_uuid.copy())
    var okey = content_addressed_merge_key(
        String(_KEY_PREFIX), String(_INDEX), uuids
    )
    inner.delete(Path.parse(_PROBE_FAIL_PUT))
    _ = inner.put(Path.parse(okey), _garbage())
    var result = _pass(probe, Int64(1_000_000), 954)
    assert_true(result.merged, "3: the rerun merged")
    var merged = _merged_entries(inner)
    assert_equal(len(merged), 1, "3: one merged summary after the rerun")
    assert_equal(merged[0].object_key, okey, "3: it names the orphan's key")
    var view = SplitView.parse(inner.get(Path.parse(okey)))
    assert_equal(
        view.doc_count(), MERGE_FACTOR, "3: the orphan was overwritten"
    )
    _ = probe^
    _ = inner^


def test_a_transient_chunk_read_failure_does_not_orphan_the_split_object() raises:
    var inner = SharedInMemoryConditionalStore()
    _publish_unsharded(inner)
    var probe = OrderProbeStore(inner.clone())
    _ = _pass(probe, Int64(1_000_000), 955)
    var raw_keys = List[String]()
    for i in range(MERGE_FACTOR):
        raw_keys.append(
            String(_KEY_PREFIX) + "/logs/splits/raw" + String(i) + ".split"
        )

    # Past the grace period, with the first chunk read of the reap failing: the
    # reap must leave that chunk, and the object only it names, alone.
    # The first pass's reap already read the tombstones inside their grace
    # period; forget that, so only this pass's reap arms the failure.
    inner.delete(Path.parse(_PROBE_REAP_REACHED))
    _ = inner.put(Path.parse(_PROBE_FAIL_READS), _flag())
    var failed = _pass(probe, Int64(2_000_000), 956)
    assert_true(
        _marked(inner, _PROBE_FAIL_FIRED), "4: the read failure was injected"
    )
    assert_equal(
        failed.chunks_reaped, MERGE_FACTOR - 1, "4: the other chunks are reaped"
    )
    assert_equal(failed.splits_reaped, MERGE_FACTOR - 1, "4: and their objects")
    assert_true(
        _marked(inner, raw_keys[0]),
        "4: the object of the chunk whose read failed still exists",
    )
    for i in range(1, MERGE_FACTOR):
        assert_false(
            _marked(inner, raw_keys[i]), "4: a read chunk's object is deleted"
        )
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        inner.clone(), String(_META), RetryPolicy.fast_test()
    )
    var meta = SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String(_INDEX)
    )
    assert_equal(
        len(meta.tombstoned_seqs()),
        1,
        "4: the chunk whose read failed is still retired, not reaped",
    )
    _ = meta^

    # The next pass reaps it and its object.
    var again = _pass(probe, Int64(2_000_000), 957)
    assert_equal(again.chunks_reaped, 1, "4: the retry reaps the chunk")
    assert_equal(again.splits_reaped, 1, "4: and its object")
    assert_false(_marked(inner, raw_keys[0]), "4: the object is deleted")
    _ = probe^
    _ = inner^


def test_the_probe_reports_an_append_naming_an_object_never_written() raises:
    var inner = SharedInMemoryConditionalStore()
    var probe = OrderProbeStore(inner.clone())
    # The inverted order, built by hand: append a merged summary to `_base`
    # while nothing ever wrote the object it names.
    var manifest = CasManifestStore[OrderProbeStore](
        probe.clone(),
        shard_manifest_prefix(String(_META), LINEAGE_BASE_SHARD),
        RetryPolicy.fast_test(),
    )
    var base = SearchMetastore[OrderProbeStore](manifest^, String(_INDEX))
    _ = base.publish(
        make_merged_split_summary(
            _uuid(951),
            Int64(1),
            Int64(10),
            Int64(0),
            Int64(0),
            String(_INDEX),
            String("body"),
            String(_KEY_PREFIX) + "/logs/splits/merged-never-written.split",
            Int64(1),
            List[UInt8](),
        )
    )
    assert_true(
        _marked(inner, _PROBE_VIOLATION),
        "5: POSITIVE CONTROL: the probe must report a violation when an"
        " append names an object nothing wrote; if it does not, case 1 is"
        " inert",
    )
    assert_false(
        _marked(inner, _PROBE_OK),
        "5: ...and must not also report OK",
    )
    _ = base^
    _ = probe^
    _ = inner^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

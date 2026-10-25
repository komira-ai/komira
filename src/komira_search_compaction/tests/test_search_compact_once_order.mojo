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
#   1  `compact_once` writes the merged object before the append (and the probe
#      fired at all: a probe that never fired would pass for free).
#   2  positive control: an append to `_base` that names an object nothing ever
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
    make_merged_split_summary,
    make_split_summary,
    shard_manifest_prefix,
)

from komira_search_compaction import (
    compact_once,
    CompactionConfig,
    MERGE_FACTOR,
)


comptime _INDEX: String = "logs"
comptime _KEY_PREFIX: String = "order-run"
comptime _META: String = "order-run/logs/meta"

comptime _PROBE_DATA_SEEN: String = "__probe__/merged_object_was_written"
comptime _PROBE_OK: String = "__probe__/append_saw_its_object"
comptime _PROBE_VIOLATION: String = "__probe__/append_preceded_its_object"


struct OrderProbeStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """A `SharedInMemoryConditionalStore` that records, for every manifest
    chunk written to the `_base` lineage, whether a merged split object had
    already been written at that instant."""

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
            self._mark(_PROBE_DATA_SEEN)
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
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        return self._inner.delete(path)


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



def test_the_merged_object_is_written_before_its_summary_is_appended() raises:
    var inner = SharedInMemoryConditionalStore()
    # Ingest MERGE_FACTOR small splits into the unsharded lineage, through the
    # plain store (the probe only watches the compaction pass).
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        inner.clone(), String(_META), RetryPolicy.fast_test()
    )
    var meta = SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String(_INDEX)
    )
    for i in range(MERGE_FACTOR):
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

    var probe = OrderProbeStore(inner.clone())
    var result = compact_once(
        probe,
        String(_META),
        String(_INDEX),
        String("body"),
        CompactionConfig(String(_KEY_PREFIX), Int64(1_000_000), Int64(60_000)),
        _uuid(950),
    )
    assert_true(result.merged, "1: the pass merged")

    # Non-vacuity: the probe must have seen a `_base` chunk write at all. A
    # probe that never fired would satisfy the ordering assertion for free.
    assert_true(
        _marked(inner, _PROBE_OK) or _marked(inner, _PROBE_VIOLATION),
        "1: NON-VACUITY: the probe saw no `_base` chunk write, so the ordering"
        " assertion would be vacuous; the append stopped going through the"
        " store or the key shape changed",
    )
    assert_true(
        _marked(inner, _PROBE_DATA_SEEN),
        "1: the probe saw the merged object being written",
    )
    assert_false(
        _marked(inner, _PROBE_VIOLATION),
        "1: ORDER: a summary was appended to `_base` while the merged object"
        " did not exist yet; the object must be written first",
    )
    assert_true(
        _marked(inner, _PROBE_OK),
        "1: the append saw its merged object already written",
    )
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
        "2: POSITIVE CONTROL: the probe must report a violation when an"
        " append names an object nothing wrote; if it does not, case 1 is"
        " inert",
    )
    assert_false(
        _marked(inner, _PROBE_OK),
        "2: ...and must not also report OK",
    )
    _ = base^
    _ = probe^
    _ = inner^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

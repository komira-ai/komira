# =============================================================================
# test_search_compact_once.mojo — `compact_once` end to end over the in-memory
# conditional store.
# =============================================================================
#
# Ingest MERGE_FACTOR small splits (the split object written to the store, then
# its summary published), run `compact_once` once, and assert:
#   (1)  the live split count collapsed N -> 1 in the union read across
#        lineages, with the merged split in the compactor's reserved `_base`
#        lineage (1b) and every input retired in its SOURCE lineage (1c);
#   (2)  the merged split object exists in the store at its content-addressed
#        key;
#   (3)  every document is still searchable, and a sort and a terms and an
#        average aggregation over the carried fast fields give the right
#        answers (typed fast fields survive the round trip through the store);
#   (4)  inside the grace period the old split objects are still readable (a
#        searcher that took its snapshot before the retirement finds no
#        missing object);
#   (5)  a second pass after the grace period reaps the old split objects and
#        manifest chunks, and the live set is still just the merged split.
# A further test runs the pass over writer shards and the unsharded lineage at
# once and checks that the drained shards are removed.
#
# The clock is `CompactionConfig.now_ms`, set by hand, so the transition from
# (4) to (5) is reproducible. Every post-merge read goes through a fresh clone
# of the store, as a separate process would.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_json import parse_json_value

from komira_objectstore import (
    CasManifestStore,
    RetryPolicy,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.sublineage_shard_keys import LINEAGE_BASE_SHARD

from komira_search.analyzer import AnalyzerConfig
from komira_search.fast_fields import FastFieldReader
from komira_search.sink import SearchSink
from komira_search.split import SplitView
from komira_search.source import (
    QueryIR,
    SearchCore,
    AggSpec,
    AggResults,
    AggResult,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    AGG_ORDER_COUNT_DESC,
    SORT_DESC,
    MISSING_LAST,
)

from komira_search_catalog import (
    SearchMetastore,
    make_split_summary,
    make_shard_id,
    list_live_splits_across_shards,
    shard_manifest_prefix,
)

from komira_search_compaction import (
    compact_once,
    CompactionConfig,
    CompactionResult,
    MERGE_FACTOR,
)


comptime _INDEX: String = "logs"
comptime _KEY_PREFIX: String = "compaction-run"
comptime _META: String = "compaction-run/logs/meta"


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



def _count_str(xs: List[String], v: String) -> Int:
    var c = 0
    for i in range(len(xs)):
        if xs[i] == v:
            c += 1
    return c


def _search_sources(bytes: List[UInt8], term: String) raises -> List[String]:
    var core = SearchCore(bytes.copy())
    var q = QueryIR(String("body"), term, 1000, AnalyzerConfig.text("body"))
    var res = core.search(q^)
    var out = List[String]()
    for r in range(res.batch.num_rows()):
        out.append(res.batch.column_at(2).as_string().get(r))
    return out^


def _result_by_name(res: AggResults, name: String) raises -> AggResult:
    for i in range(len(res.results)):
        if res.results[i].name == name:
            return res.results[i].copy()
    raise Error("no agg result named '" + name + "'")


def _lineage_metastore(
    store: SharedInMemoryConditionalStore, lineage_prefix: String
) raises -> SearchMetastore[SharedInMemoryConditionalStore]:
    """A metastore on ONE lineage, for the per-lineage assertions the union
    read cannot make on its own."""
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store.clone(), lineage_prefix, RetryPolicy.fast_test()
    )
    return SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String(_INDEX)
    )


def _object_key(idx: Int) -> String:
    return String(_KEY_PREFIX) + "/" + String(_INDEX) + "/splits/raw" + String(
        idx
    ) + ".split"


def _publish_raw(
    store: SharedInMemoryConditionalStore,
    lineage_prefix: String,
    bts: List[UInt8],
    okey: String,
) raises:
    """Write the split object to the store, THEN publish its summary into the
    lineage at `lineage_prefix`."""
    _ = store.put(Path.parse(okey), bts.copy())
    var view = SplitView.parse(bts.copy())
    var summ = make_split_summary(
        view.split_uuid(),
        Int64(view.doc_count()),
        Int64(len(bts)),
        Int64(view.min_doc_id()),
        Int64(view.max_doc_id()),
        String(_INDEX),
        String("body"),
        okey.copy(),
    )
    var meta = _lineage_metastore(store, lineage_prefix)
    _ = meta.publish(summ^)


def _is_gone(store: SharedInMemoryConditionalStore, key: String) -> Bool:
    try:
        var b = store.get(Path.parse(key))
        return len(b) == 0
    except e:
        _ = String(e)
        return True


# =============================================================================
# One pass over the unsharded lineage, then the grace-gated second pass.
# =============================================================================


def test_compact_once_collapses_and_reaps() raises:
    var store = SharedInMemoryConditionalStore()
    var raw_object_keys = List[String]()
    for i in range(MERGE_FACTOR):
        var word = String("w") + String(i)
        var status = String("active") if i % 2 == 0 else String("sold")
        var bts = _ingest_to_split(_one_doc_ndjson(word, status, 10 * (i + 1)), i)
        var okey = _object_key(i)
        raw_object_keys.append(okey.copy())
        # The unsharded lineage `<index>/meta`: the pass folds it into `_base`.
        _publish_raw(store, String(_META), bts, okey)
    var before = _lineage_metastore(store, String(_META)).list_live_splits()
    assert_equal(len(before), MERGE_FACTOR, "ingest: MERGE_FACTOR live splits")

    # ---- COMPACT: one pass, inside the grace period ----
    comptime T0: Int64 = 5_000_000
    comptime GRACE: Int64 = 60_000
    var cfg = CompactionConfig(
        key_prefix=String(_KEY_PREFIX), now_ms=T0, grace_ms=GRACE
    )
    var result = compact_once(
        store, String(_META), String(_INDEX), String("body"), cfg, _uuid(900)
    )
    var reader = store.clone()
    assert_true(result.merged, "compact: a merge fired")
    assert_equal(result.inputs_merged, MERGE_FACTOR, "compact: inputs merged")
    assert_equal(result.seqs_retired, MERGE_FACTOR, "compact: seqs retired")
    assert_equal(result.chunks_reaped, 0, "compact: no chunk reaped in grace")
    assert_equal(result.splits_reaped, 0, "compact: no object reaped in grace")
    # This topology has no writer shard (ingest went to the unsharded lineage,
    # the output to `_base`) and neither of those is ever reapable.
    assert_equal(
        result.shards_reaped,
        0,
        "compact: no lineage removed (`_base` and the unsharded one stay)",
    )

    # ---- (1) live set collapsed N -> 1, read across lineages ----
    var live_after = list_live_splits_across_shards(
        reader, String(_META), String(_INDEX)
    )
    assert_equal(len(live_after), 1, "(1) live set collapsed N -> 1")
    assert_true(live_after[0].is_merged(), "(1) the lone live split is merged")
    assert_equal(
        live_after[0].doc_count, Int64(MERGE_FACTOR), "(1) all N documents"
    )
    var merged_key = live_after[0].object_key.copy()

    # ---- (1b)/(1c) the two halves of the fold, per lineage ----
    var base_meta = _lineage_metastore(
        reader, shard_manifest_prefix(String(_META), LINEAGE_BASE_SHARD)
    )
    var base_live = base_meta.list_live_splits()
    assert_equal(len(base_live), 1, "(1b) the merged split is in `_base`")
    assert_true(base_live[0].is_merged(), "(1b) `_base` holds the merged split")
    var src_live = _lineage_metastore(
        reader, String(_META)
    ).list_live_splits()
    assert_equal(
        len(src_live), 0, "(1c) every input retired in its source lineage"
    )

    # ---- (2) the merged split object exists at its content-addressed key ----
    var merged_bytes = reader.get(Path.parse(merged_key))
    assert_true(len(merged_bytes) > 0, "(2) merged split object exists")
    assert_equal(
        Int64(len(merged_bytes)),
        live_after[0].byte_size,
        "(2) the summary's byte_size is the stored object's size",
    )

    # ---- (3) every document searchable; typed fast fields carried ----
    var hits = _search_sources(merged_bytes, String("alpha"))
    assert_equal(len(hits), MERGE_FACTOR, "(3) all N docs searchable")
    for i in range(len(hits)):
        assert_equal(_count_str(hits, hits[i]), 1, "(3) each doc exactly once")
    var rdr_view = SplitView.parse(merged_bytes.copy())
    var rdr = FastFieldReader(rdr_view)
    assert_true(rdr.has_field(String("status")), "(3) status carried")
    assert_true(rdr.has_field(String("price")), "(3) price carried")
    var core = SearchCore(merged_bytes.copy())
    var specs = List[AggSpec]()
    specs.append(
        AggSpec(
            String("by_status"), AGG_KIND_TERMS, String("status"), 10,
            AGG_ORDER_COUNT_DESC, 1, String(""),
        )
    )
    specs.append(AggSpec(String("avg_price"), AGG_KIND_AVG, String("price")))
    var q = QueryIR(
        String("body"), String("alpha"), 1000,
        AnalyzerConfig.text("body"), 0, None, String("price"), SORT_DESC,
        MISSING_LAST, 0, specs^,
    )
    var res = core.search(q^)
    assert_equal(res.batch.num_rows(), MERGE_FACTOR, "(3) sort returns all N")
    var ar = res.take_aggs()
    var by_status = _result_by_name(ar, String("by_status"))
    var active_count = 0
    var sold_count = 0
    for i in range(len(by_status.buckets)):
        if by_status.buckets[i].key == String("active"):
            active_count = by_status.buckets[i].doc_count
        elif by_status.buckets[i].key == String("sold"):
            sold_count = by_status.buckets[i].doc_count
    assert_equal(active_count, 5, "(3) terms agg: 5 active")
    assert_equal(sold_count, 5, "(3) terms agg: 5 sold")
    var avg_price = _result_by_name(ar, String("avg_price"))
    assert_almost_equal(
        avg_price.avg(), 55.0, atol=1e-6, msg="(3) avg(price) is 55"
    )

    # ---- (4) inside the grace period the old objects are still readable ----
    var readable_old = 0
    for i in range(len(raw_object_keys)):
        var ob = reader.get(Path.parse(raw_object_keys[i]))
        if len(ob) > 0:
            readable_old += 1
    assert_equal(
        readable_old, MERGE_FACTOR, "(4) all N old objects readable in grace"
    )

    # ---- (5) after the grace period a second pass reaps them ----
    var cfg_after = CompactionConfig(
        key_prefix=String(_KEY_PREFIX), now_ms=T0 + GRACE + 1, grace_ms=GRACE
    )
    var result2 = compact_once(
        store, String(_META), String(_INDEX), String("body"), cfg_after,
        _uuid(901),
    )
    assert_false(result2.merged, "(5) 2nd pass merges nothing")
    assert_equal(
        result2.chunks_reaped, MERGE_FACTOR, "(5) 2nd pass reaped N chunks"
    )
    assert_equal(
        result2.splits_reaped, MERGE_FACTOR, "(5) 2nd pass reaped N objects"
    )
    # The unsharded lineage is now empty and drained, yet it is still not
    # removed: `_base` and the unsharded lineage are exempt from the shard GC.
    assert_equal(result2.shards_reaped, 0, "(5) no lineage removed")
    var live_final = list_live_splits_across_shards(
        reader, String(_META), String(_INDEX)
    )
    assert_equal(len(live_final), 1, "(5) live set still just the merged split")
    var gone = 0
    for i in range(len(raw_object_keys)):
        if _is_gone(reader, raw_object_keys[i]):
            gone += 1
    assert_equal(gone, MERGE_FACTOR, "(5) all N old objects deleted")
    assert_true(
        len(reader.get(Path.parse(merged_key))) > 0,
        "(5) the merged split object survives the reap",
    )


# =============================================================================
# One pass over writer shards: fold into `_base`, then remove the drained
# shards after the grace period.
# =============================================================================


def test_compact_once_folds_writer_shards_and_removes_them() raises:
    var store = SharedInMemoryConditionalStore()
    var shard_ids = List[String]()
    for i in range(MERGE_FACTOR):
        var bts = _ingest_to_split(
            _one_doc_ndjson(String("w") + String(i), "active", 10 * (i + 1)), i
        )
        var shard_id = make_shard_id(String("node"), i)
        shard_ids.append(shard_id.copy())
        _publish_raw(
            store,
            shard_manifest_prefix(String(_META), shard_id),
            bts,
            _object_key(i),
        )
    assert_equal(
        len(list_live_splits_across_shards(store, String(_META), String(_INDEX))),
        MERGE_FACTOR,
        "shards: N live splits across N writer shards",
    )

    comptime T0: Int64 = 8_000_000
    comptime GRACE: Int64 = 60_000
    var first = compact_once(
        store,
        String(_META),
        String(_INDEX),
        String("body"),
        CompactionConfig(String(_KEY_PREFIX), T0, GRACE),
        _uuid(910),
    )
    assert_true(first.merged, "shards: the fold fired")
    assert_equal(first.seqs_retired, MERGE_FACTOR, "shards: N retired")
    # The writer shards still hold retirements inside their grace period, so
    # none is drained yet.
    assert_equal(first.shards_reaped, 0, "shards: none removed in grace")
    var after_first = list_live_splits_across_shards(
        store, String(_META), String(_INDEX)
    )
    assert_equal(len(after_first), 1, "shards: one merged split is live")
    assert_true(after_first[0].is_merged(), "shards: it is the merged split")
    assert_equal(
        after_first[0].doc_count, Int64(MERGE_FACTOR), "shards: all N docs"
    )

    # After the grace period the second pass reaps every retired chunk and
    # object, and removes the N writer shards that are now drained.
    var second = compact_once(
        store,
        String(_META),
        String(_INDEX),
        String("body"),
        CompactionConfig(String(_KEY_PREFIX), T0 + GRACE + 1, GRACE),
        _uuid(911),
    )
    assert_false(second.merged, "shards: 2nd pass merges nothing")
    assert_equal(second.chunks_reaped, MERGE_FACTOR, "shards: N chunks reaped")
    assert_equal(second.splits_reaped, MERGE_FACTOR, "shards: N objects reaped")
    assert_equal(second.shards_reaped, MERGE_FACTOR, "shards: N shards removed")
    for i in range(MERGE_FACTOR):
        assert_true(
            _is_gone(store, _object_key(i)), "shards: retired object deleted"
        )

    # A third pass has nothing left to do.
    var third = compact_once(
        store,
        String(_META),
        String(_INDEX),
        String("body"),
        CompactionConfig(String(_KEY_PREFIX), T0 + 2 * GRACE, GRACE),
        _uuid(912),
    )
    assert_false(third.merged, "shards: 3rd pass merges nothing")
    assert_equal(third.chunks_reaped, 0, "shards: 3rd pass reaps no chunk")
    assert_equal(third.splits_reaped, 0, "shards: 3rd pass reaps no object")
    assert_equal(third.shards_reaped, 0, "shards: 3rd pass removes no shard")
    var final_live = list_live_splits_across_shards(
        store, String(_META), String(_INDEX)
    )
    assert_equal(len(final_live), 1, "shards: the merged split is still live")
    assert_true(
        len(store.get(Path.parse(final_live[0].object_key))) > 0,
        "shards: the merged split object is intact",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

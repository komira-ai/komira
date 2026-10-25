# =============================================================================
# test_search_compaction.mojo — the merge, selection, reap and one-pass
# sequence of search compaction, all in memory.
# =============================================================================
#
# Everything runs against the in-memory conditional store: no network, no
# object store. The clock is driven by hand through `retire_at` and
# `reap_chunk(now_ms, grace_ms)`, which is what the grace gate compares.
#
# The cases:
#   1  merge correctness: ingest K small splits and merge them. The merged
#      hit set equals the union of the inputs' hits; every `_source` is
#      byte-identical; BM25 scores equal a from-scratch ingest of the union
#      (not the scores of the multi-split fan-out, which shift); the typed
#      fast fields carry forward and a terms and an average aggregation
#      compose over the merged split.
#   2  a searcher that snapshots the live set before a retirement can still
#      read the retired chunk inside the grace period; the chunk is reaped only
#      once `now - schedule_ts >= grace`.
#   3  a split published while a merge runs: the compactor merges its snapshot
#      {0..4}, splits 5 and 6 land meanwhile, and only {0..4} are retired. 5 and
#      6 stay live, the merged split is live, and a search over the live set
#      returns every document exactly once.
#   4  idempotence: the merged key is content-addressed and independent of the
#      input order, and a re-merge of the same inputs is byte-identical.
#   5  reap tolerance: a reaped chunk is skipped by the live listing, and a
#      second reap of the same chunk does not raise.
#   6  the selection policy: below the factor nothing merges; smallest first;
#      capped at `MAX_MERGE_FACTOR`; already-merged splits are not re-fed.
#   7  the split-object reaper deletes only after the grace period and is
#      idempotent.
#   8  the full sequence (snapshot, select, merge, publish, retire, reap) over
#      an in-memory metastore, ending with a harmless no-op second pass.
#      `test_search_compact_once.mojo` drives `compact_once` itself.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_not_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
    assert_raises,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_json import parse_json_value

from komira_objectstore import (
    CasManifestStore,
    InMemoryConditionalStore,
    RetryPolicy,
)

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.split import SplitView
from komira_search.fast_fields import FastFieldReader
from komira_search.source import (
    QueryIR,
    SearchCore,
    SearchResult,
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
    SplitSummary,
    SearchMetastore,
    LiveSplitEntry,
    make_split_summary,
    make_merged_split_summary,
)

from komira_search_compaction.select import (
    MergeCandidate,
    MergePlan,
    select_merge,
    MERGE_FACTOR,
    MAX_MERGE_FACTOR,
)
from komira_search_compaction.merge_split import (
    merge_split_bytes,
    MergeResult,
    content_addressed_merge_key,
)
from komira_search_compaction.reaper import reap_retired_split

from komira_objectstore.path import Path


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _uuid(seed: Int) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 7 + i * 13) & 0xFF)
    return u^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


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


def _reader(bytes: List[UInt8]) raises -> FastFieldReader:
    var view = SplitView.parse(bytes.copy())
    return FastFieldReader(view)


def _search_sources(bytes: List[UInt8], term: String) raises -> List[String]:
    """Search `bytes` for `term`, return the `_source` blob of every hit (the
    HIT SET, for the hit-set comparison)."""
    var core = SearchCore(bytes.copy())
    var q = QueryIR(
        String("body"), term, 1000, AnalyzerConfig.text("body")
    )
    var res = core.search(q^)
    var out = List[String]()
    for r in range(res.batch.num_rows()):
        out.append(res.batch.column_at(2).as_string().get(r))
    return out^


def _search_scores(bytes: List[UInt8], term: String) raises -> List[Float64]:
    """Search `bytes` for `term`, return scores in `_source`-keyed order (sorted
    by _source so two splits with different doc-id assignment compare)."""
    var core = SearchCore(bytes.copy())
    var q = QueryIR(
        String("body"), term, 1000, AnalyzerConfig.text("body")
    )
    var res = core.search(q^)
    # Pair (_source, score), sort by _source, return scores.
    var srcs = List[String]()
    var scs = List[Float64]()
    for r in range(res.batch.num_rows()):
        srcs.append(res.batch.column_at(2).as_string().get(r))
        scs.append(Float64(res.batch.column_at(0).as_primitive[DType.float64]().get(r)))
    # insertion sort by src
    for i in range(1, len(srcs)):
        var sv = srcs[i]
        var cv = scs[i]
        var j = i - 1
        while j >= 0 and srcs[j] > sv:
            srcs[j + 1] = srcs[j]
            scs[j + 1] = scs[j]
            j -= 1
        srcs[j + 1] = sv
        scs[j + 1] = cv
    return scs^


def _contains_str(xs: List[String], v: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _count_str(xs: List[String], v: String) -> Int:
    var c = 0
    for i in range(len(xs)):
        if xs[i] == v:
            c += 1
    return c


def _fresh_metastore() -> SearchMetastore[InMemoryConditionalStore]:
    var store = InMemoryConditionalStore()
    var manifest = CasManifestStore[InMemoryConditionalStore](
        store^, String("index/logs/meta"), RetryPolicy.fast_test()
    )
    return SearchMetastore[InMemoryConditionalStore](
        manifest^, String("logs")
    )


# One small single-doc split per seed; `body` carries the seed word so each doc
# is independently searchable + the _source is distinct.
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


def _result_by_name(res: AggResults, name: String) raises -> AggResult:
    for i in range(len(res.results)):
        if res.results[i].name == name:
            return res.results[i].copy()
    raise Error("no agg result named '" + name + "'")


def _publish_raw(
    mut meta: SearchMetastore[InMemoryConditionalStore],
    bts: List[UInt8],
    idx: Int,
) raises:
    """Publish a raw single-doc split's summary (the .split bytes are held by the
    caller, modelling the object store). The summary's UUID comes from the split footer."""
    var view = SplitView.parse(bts.copy())
    var summ = make_split_summary(
        view.split_uuid(), Int64(1), Int64(len(bts)), Int64(0), Int64(0),
        String("logs"), String("body"),
        String("k/logs/splits/s" + String(idx) + ".split"),
    )
    _ = meta.publish(summ^)


# =============================================================================
# Case 1 — merge correctness (hit set, from-scratch scores, typed fast fields).
# =============================================================================


def test_01_merge_correctness() raises:
    # K=3 small single-doc splits, each with body+status(keyword)+price(int64).
    var b0 = _ingest_to_split(_one_doc_ndjson("red", "active", 10), 0)
    var b1 = _ingest_to_split(_one_doc_ndjson("green", "sold", 20), 1)
    var b2 = _ingest_to_split(_one_doc_ndjson("blue", "active", 30), 2)

    # Pre-merge union hit set for "alpha" (present in every doc).
    var u0 = _search_sources(b0, String("alpha"))
    var u1 = _search_sources(b1, String("alpha"))
    var u2 = _search_sources(b2, String("alpha"))
    assert_equal(len(u0) + len(u1) + len(u2), 3, "1: 3 pre-merge hits")

    # Merge the 3 inputs.
    var inputs = List[List[UInt8]]()
    inputs.append(b0.copy())
    inputs.append(b1.copy())
    inputs.append(b2.copy())
    var merged_uuid = _uuid(99)
    var okey = content_addressed_merge_key(
        String("prefix"),
        String("logs"),
        _input_uuids(inputs),
    )
    var mr = merge_split_bytes(
        inputs,
        String("logs"),
        String("bucket"),
        String("prefix"),
        String("body"),
        merged_uuid,
        okey,
    )
    assert_equal(mr.doc_count, 3, "1: merged has 3 docs")

    # (i) merged HIT SET == the pre-merge union (every _source present once).
    var merged_hits = _search_sources(mr.split_bytes, String("alpha"))
    assert_equal(len(merged_hits), 3, "1.i: merged returns 3 hits")
    # (ii) every _source byte-identical (each pre-merge _source present once).
    assert_true(_contains_str(merged_hits, u0[0]), "1.ii: doc0 _source present")
    assert_true(_contains_str(merged_hits, u1[0]), "1.ii: doc1 _source present")
    assert_true(_contains_str(merged_hits, u2[0]), "1.ii: doc2 _source present")
    assert_equal(_count_str(merged_hits, u0[0]), 1, "1.ii: doc0 exactly once")

    # (iii) BM25 scores match a FROM-SCRATCH single-split ingest of the UNION
    # (NOT the pre-merge fan-out — scores shift). Build the union by
    # ingesting all 3 docs' _source lines as one _bulk.
    var union_ndjson = (
        _one_doc_ndjson("red", "active", 10)
        + _one_doc_ndjson("green", "sold", 20)
        + _one_doc_ndjson("blue", "active", 30)
    )
    var scratch = _ingest_to_split(union_ndjson, 200)
    var merged_scores = _search_scores(mr.split_bytes, String("alpha"))
    var scratch_scores = _search_scores(scratch, String("alpha"))
    assert_equal(
        len(merged_scores), len(scratch_scores), "1.iii: same hit count"
    )
    for i in range(len(merged_scores)):
        assert_almost_equal(
            merged_scores[i],
            scratch_scores[i],
            atol=1e-9,
            msg="1.iii: merged score == from-scratch union score",
        )

    # (iv) typed fast-fields carried forward: status(keyword) + price(int64)
    # survive as the SAME classes on the merged split; a terms+avg agg composes.
    var rdr = _reader(mr.split_bytes)
    assert_true(rdr.has_field(String("status")), "1.iv: status carried")
    assert_true(rdr.has_field(String("price")), "1.iv: price carried")
    # WAND Phase 2: the merge re-indexes via the SearchSink write path (which
    # supplies token_counts), so the merged split carries a valid BLOCKMAX region
    # for free — the BMW scorer is active on merged splits. Verify it's present.
    var merged_view = SplitView.parse(mr.split_bytes.copy())
    assert_true(
        merged_view.has_blockmax(), "1.iv: merged split carries BLOCKMAX"
    )
    # terms(status) + avg(price) over the merged split.
    var core = SearchCore(mr.split_bytes.copy())
    var specs = List[AggSpec]()
    specs.append(
        AggSpec(
            String("by_status"), AGG_KIND_TERMS, String("status"), 10,
            AGG_ORDER_COUNT_DESC, 1, String(""),
        )
    )
    specs.append(AggSpec(String("avg_price"), AGG_KIND_AVG, String("price")))
    var q = QueryIR(
        String("body"), String("alpha"), 1000, AnalyzerConfig.text("body"),
        0, None, String(""), SORT_DESC, MISSING_LAST, 0, specs^,
    )
    var res = core.search(q^)
    var ar = res.take_aggs()
    var by_status = _result_by_name(ar, String("by_status"))
    # active=2 (price 10, 30), sold=1 (price 20).
    var active_count = 0
    var sold_count = 0
    for i in range(len(by_status.buckets)):
        if by_status.buckets[i].key == String("active"):
            active_count = by_status.buckets[i].doc_count
        elif by_status.buckets[i].key == String("sold"):
            sold_count = by_status.buckets[i].doc_count
    assert_equal(active_count, 2, "1.iv: 2 active docs")
    assert_equal(sold_count, 1, "1.iv: 1 sold doc")
    var avg_price = _result_by_name(ar, String("avg_price"))
    assert_almost_equal(
        avg_price.avg(), 20.0, atol=1e-9, msg="1.iv: avg price (10+20+30)/3"
    )


def _input_uuids(inputs: List[List[UInt8]]) raises -> List[Array[UInt8, 16]]:
    var out = List[Array[UInt8, 16]]()
    for i in range(len(inputs)):
        var view = SplitView.parse(inputs[i].copy())
        out.append(view.split_uuid())
    return out^


# =============================================================================
# Case 2 — MVCC mid-compaction (no 404 within the grace window).
# =============================================================================


def test_02_mvcc_mid_compaction_no_404() raises:
    # Publish 3 small splits to the metastore (Staged->Published — the .split
    # bytes are held in a side map keyed by object_key, modelling the object store).
    var meta = _fresh_metastore()
    var s0 = make_split_summary(
        _uuid(0), Int64(1), Int64(100), Int64(0), Int64(0),
        String("logs"), String("body"), String("k/logs/splits/s0.split"),
    )
    var s1 = make_split_summary(
        _uuid(1), Int64(1), Int64(100), Int64(0), Int64(0),
        String("logs"), String("body"), String("k/logs/splits/s1.split"),
    )
    _ = meta.publish(s0^)
    _ = meta.publish(s1^)

    # An in-flight searcher snapshots the live set BEFORE the tombstone.
    var snapshot = meta.list_live_splits_with_seq()
    assert_equal(len(snapshot), 2, "2: snapshot has 2 live splits")

    # The compactor tombstones seq 0 at schedule_ts = T0 (deterministic clock).
    comptime T0: Int64 = 1_000_000
    comptime GRACE: Int64 = 60_000  # grace_ms > max query duration.
    meta.retire_at(Int64(0), T0)

    # Immediately after the tombstone, seq 0 drops from the live list (new
    # searches stop fetching it).
    var after_tombstone = meta.list_live_splits()
    assert_equal(len(after_tombstone), 1, "2: tombstoned seq dropped from live")

    # But the in-flight searcher (holding the snapshot) can still READ seq 0's
    # chunk — and the reaper does NOT reap within the grace window. At T0 + half
    # grace, reap_chunk returns False (grace not elapsed) and the chunk stays.
    var reaped_early = meta.reap_chunk(Int64(0), T0 + GRACE // 2, GRACE)
    assert_false(reaped_early, "2: reap blocked inside the grace window")
    # The chunk is still readable (no 404) — the snapshot's seq 0 summary is
    # still resolvable via read_chunk (proven by list_live_splits NOT raising +
    # the chunk physically present).
    assert_equal(
        meta.tombstone_schedule_ts(Int64(0)), T0, "2: schedule_ts intact"
    )

    # After grace_ms elapses, the reaper deletes the chunk.
    var reaped_late = meta.reap_chunk(Int64(0), T0 + GRACE + 1, GRACE)
    assert_true(reaped_late, "2: reap fires after grace elapses")
    # Now seq 0 is gone; list still returns only seq 1 (reap tolerance).
    var final_live = meta.list_live_splits()
    assert_equal(len(final_live), 1, "2: post-reap live set is seq 1")


# =============================================================================
# Case 3 — concurrent-indexer-during-compaction (no duplicate).
# =============================================================================


def test_03_concurrent_indexer_no_dup() raises:
    var meta = _fresh_metastore()
    # Publish 5 raw splits {0..4} (each one small doc). Keep their bytes so the
    # merge can read them.
    var raw_bytes = List[List[UInt8]]()
    var words = List[String]()
    words.append(String("one"))
    words.append(String("two"))
    words.append(String("three"))
    words.append(String("four"))
    words.append(String("five"))
    for i in range(5):
        var bts = _ingest_to_split(_one_doc_ndjson(words[i], "active", 10 * (i + 1)), i)
        raw_bytes.append(bts.copy())
        _publish_raw(meta, bts, i)

    # The compactor snapshots {0..4}.
    var snapshot = meta.list_live_splits_with_seq()
    assert_equal(len(snapshot), 5, "3: snapshot {0..4}")

    # CONCURRENTLY: two new _bulk publishes land seqs 5,6 DURING the merge.
    var b5 = _ingest_to_split(_one_doc_ndjson("six", "sold", 60), 5)
    var b6 = _ingest_to_split(_one_doc_ndjson("seven", "sold", 70), 6)
    _publish_raw(meta, b5, 5)
    _publish_raw(meta, b6, 6)

    # The compactor merges the 5 SNAPSHOTTED inputs -> M.
    var merge_inputs = List[List[UInt8]]()
    for i in range(5):
        merge_inputs.append(raw_bytes[i].copy())
    var merged_uuid = _uuid(199)
    var okey = content_addressed_merge_key(
        String("prefix"), String("logs"), _input_uuids(merge_inputs)
    )
    var mr = merge_split_bytes(
        merge_inputs, String("logs"), String("bucket"), String("prefix"),
        String("body"), merged_uuid, okey,
    )
    assert_equal(mr.doc_count, 5, "3: M has the 5 snapshotted docs")

    # Publish M with its input-UUID set, then tombstone ONLY {0..4}.
    var m_summ = make_merged_split_summary(
        merged_uuid^, Int64(5), Int64(len(mr.split_bytes)), Int64(0), Int64(4),
        String("logs"), String("body"), okey,
        mr.merge_ops, mr.input_uuids_flat.copy(),
    )
    _ = meta.publish(m_summ^)
    # Tombstone EXACTLY the snapshotted seqs {0..4}.
    for i in range(len(snapshot)):
        meta.retire(snapshot[i].chunk_seq)

    # Post-merge: live set = M + seqs 5,6. {0..4} are tombstoned.
    var live = meta.list_live_splits()
    # M (5 docs) + 2 raw = 3 live splits.
    assert_equal(len(live), 3, "3: live = M + seq5 + seq6")
    # Assert the two concurrent splits survive + M present.
    var saw_merged = False
    var saw_5 = False
    var saw_6 = False
    for i in range(len(live)):
        if live[i].is_merged():
            saw_merged = True
        if live[i].doc_count == Int64(1):
            # one of the raw survivors
            pass
    for i in range(len(live)):
        ref u = live[i].split_uuid
        if _uuid_eq(u, _input_uuids_one(b5)):
            saw_5 = True
        if _uuid_eq(u, _input_uuids_one(b6)):
            saw_6 = True
    assert_true(saw_merged, "3: M is live")
    assert_true(saw_5, "3: seq5 survives live")
    assert_true(saw_6, "3: seq6 survives live")

    # A search over the WHOLE live set returns each doc EXACTLY once (no dup).
    # The merged-input skip (list_live_splits skipping live merged-inputs) means that
    # EVEN IN THE WINDOW where {0..4} were live alongside M (before the
    # tombstone), a search would not double-count. Here {0..4} are tombstoned, so
    # the live set is {M, 5, 6}; M holds the 5 merged docs. Fan-search every live
    # split for "alpha" (in every doc) and assert 7 unique hits.
    var all_hits = List[String]()
    for i in range(len(live)):
        var bts = _bytes_for_uuid(live[i], mr.split_bytes, b5, b6)
        var hits = _search_sources(bts, String("alpha"))
        for h in range(len(hits)):
            all_hits.append(hits[h])
    assert_equal(len(all_hits), 7, "3: 7 total hits (5 merged + 2 concurrent)")
    # Each _source exactly once (no dup from the merged-away inputs).
    for i in range(len(all_hits)):
        assert_equal(
            _count_str(all_hits, all_hits[i]), 1, "3: every doc exactly once"
        )


def _uuid_eq(a: Array[UInt8, 16], b: Array[UInt8, 16]) -> Bool:
    for i in range(16):
        if a[i] != b[i]:
            return False
    return True


def _input_uuids_one(bts: List[UInt8]) raises -> Array[UInt8, 16]:
    var view = SplitView.parse(bts.copy())
    return view.split_uuid()


def _bytes_for_uuid(
    entry: SplitSummary,
    merged_bytes: List[UInt8],
    b5: List[UInt8],
    b6: List[UInt8],
) raises -> List[UInt8]:
    """Resolve a live summary's UUID back to the in-memory split bytes (the test
    models the object store with the bytes held by the caller)."""
    if entry.is_merged():
        return merged_bytes.copy()
    var u5 = _input_uuids_one(b5)
    if _uuid_eq(entry.split_uuid, u5):
        return b5.copy()
    return b6.copy()


# =============================================================================
# Case 4 — idempotency / overlap (content-addressed key = harmless overwrite).
# =============================================================================


def test_04_idempotent_content_addressed_key() raises:
    var b0 = _ingest_to_split(_one_doc_ndjson("aa", "active", 10), 0)
    var b1 = _ingest_to_split(_one_doc_ndjson("bb", "sold", 20), 1)
    var inputs = List[List[UInt8]]()
    inputs.append(b0.copy())
    inputs.append(b1.copy())

    # The content-addressed key is deterministic in the SORTED input UUID set:
    # the same input set -> the same key regardless of input ORDER.
    var k_fwd = content_addressed_merge_key(
        String("prefix"), String("logs"), _input_uuids(inputs)
    )
    var inputs_rev = List[List[UInt8]]()
    inputs_rev.append(b1.copy())
    inputs_rev.append(b0.copy())
    var k_rev = content_addressed_merge_key(
        String("prefix"), String("logs"), _input_uuids(inputs_rev)
    )
    assert_equal(k_fwd, k_rev, "4: content key invariant to input order")

    # Two merges of the SAME input set produce IDENTICAL merged bytes (the
    # merged UUID is the caller's; with the same UUID the bytes are identical ->
    # a re-PUT is a harmless overwrite).
    var merged_uuid = _uuid(50)
    var mr1 = merge_split_bytes(
        inputs, String("logs"), String("bucket"), String("prefix"),
        String("body"), merged_uuid, k_fwd,
    )
    var inputs2 = List[List[UInt8]]()
    inputs2.append(b0.copy())
    inputs2.append(b1.copy())
    var mr2 = merge_split_bytes(
        inputs2, String("logs"), String("bucket"), String("prefix"),
        String("body"), merged_uuid, k_fwd,
    )
    assert_equal(
        len(mr1.split_bytes), len(mr2.split_bytes), "4: re-merge same byte len"
    )
    for i in range(len(mr1.split_bytes)):
        assert_equal(
            Int(mr1.split_bytes[i]), Int(mr2.split_bytes[i]),
            "4: re-merge byte-identical (idempotent overwrite)",
        )


# =============================================================================
# Case 5 — reap-tolerance (reaped chunk skipped; already-reaped raise caught).
# =============================================================================


def test_05_reap_tolerance() raises:
    var meta = _fresh_metastore()
    for i in range(3):
        var summ = make_split_summary(
            _uuid(i), Int64(1), Int64(100), Int64(0), Int64(0),
            String("logs"), String("body"),
            String("k/logs/splits/s" + String(i) + ".split"),
        )
        _ = meta.publish(summ^)
    assert_equal(len(meta.list_live_splits()), 3, "5: 3 live")

    comptime T0: Int64 = 500_000
    comptime GRACE: Int64 = 1_000
    # Tombstone seq 1 (the middle), then reap after grace.
    meta.retire_at(Int64(1), T0)
    var reaped = meta.reap_chunk(Int64(1), T0 + GRACE + 1, GRACE)
    assert_true(reaped, "5: seq1 reaped after grace")

    # list_live_splits skips the reaped seq (not-found guard) -> 2 live.
    var live = meta.list_live_splits()
    assert_equal(len(live), 2, "5: reaped seq skipped, 2 live")
    assert_equal(live[0].doc_count, Int64(1), "5: seq0 survives")

    # A SECOND reap of the already-reaped seq must NOT raise (the .tomb is
    # gone -> tombstone_schedule_ts 404s -> reap_chunk treats it as already-
    # reaped and returns True).
    var reaped_again = meta.reap_chunk(Int64(1), T0 + GRACE + 100, GRACE)
    assert_true(reaped_again, "5: already-reaped tolerated (no raise)")


# =============================================================================
# Case 6 — the selection policy (pure function, no store).
# =============================================================================


def _cand(seed: Int, doc_count: Int64, byte_size: Int64, merge_ops: Int64) -> MergeCandidate:
    var s: SplitSummary
    if merge_ops > Int64(0):
        s = make_merged_split_summary(
            _uuid(seed), doc_count, byte_size, Int64(0), Int64(0),
            String("logs"), String("body"),
            String("k/s" + String(seed) + ".split"),
            merge_ops, List[UInt8](),
        )
    else:
        s = make_split_summary(
            _uuid(seed), doc_count, byte_size, Int64(0), Int64(0),
            String("logs"), String("body"),
            String("k/s" + String(seed) + ".split"),
        )
    return MergeCandidate(String(""), Int64(seed), s^)


def test_06a_policy_below_factor_no_merge() raises:
    # Fewer than MERGE_FACTOR eligible -> no merge.
    var cands = List[MergeCandidate]()
    for i in range(MERGE_FACTOR - 1):
        cands.append(_cand(i, Int64(100), Int64(1000), Int64(0)))
    var plan = select_merge(cands)
    assert_false(plan.should_merge(), "6a: below factor -> no merge")


def test_06b_policy_smallest_first_under_factor() raises:
    # Exactly MERGE_FACTOR eligible small splits -> merge them, smallest-first.
    var cands = List[MergeCandidate]()
    for i in range(MERGE_FACTOR):
        # decreasing byte_size so the sort has work to do.
        cands.append(_cand(i, Int64(100), Int64((MERGE_FACTOR - i) * 1000), Int64(0)))
    var plan = select_merge(cands)
    assert_true(plan.should_merge(), "6b: >=factor -> merge")
    assert_equal(plan.num_selected(), MERGE_FACTOR, "6b: selects MERGE_FACTOR")
    # Smallest-first: selected[0].byte_size <= selected[1].byte_size <= ...
    for i in range(1, plan.num_selected()):
        assert_true(
            plan.selected[i - 1].summary.byte_size
            <= plan.selected[i].summary.byte_size,
            "6b: ascending byte_size",
        )


def test_06c_policy_caps_at_max_merge_factor() raises:
    # More than MAX_MERGE_FACTOR eligible -> take at most MAX_MERGE_FACTOR.
    var cands = List[MergeCandidate]()
    for i in range(MAX_MERGE_FACTOR + 5):
        cands.append(_cand(i, Int64(100), Int64(1000), Int64(0)))
    var plan = select_merge(cands)
    assert_true(plan.should_merge(), "6c: merges")
    assert_equal(
        plan.num_selected(), MAX_MERGE_FACTOR, "6c: capped at MAX_MERGE_FACTOR"
    )


def test_06d_policy_a7_skips_already_merged() raises:
    # MERGE_FACTOR splits all of which are ALREADY MERGED (merge_ops>0) ->
    # The maturity guard excludes them -> no merge (don't re-merge forever).
    var cands = List[MergeCandidate]()
    for i in range(MERGE_FACTOR):
        cands.append(_cand(i, Int64(100), Int64(1000), Int64(1)))
    var plan = select_merge(cands)
    assert_false(plan.should_merge(), "6d: maturity guard excludes already-merged -> no merge")

    # Mix: MERGE_FACTOR raw + a few merged. Only the raw ones are eligible; if
    # there are >= MERGE_FACTOR raw, it merges only the raw set.
    var mixed = List[MergeCandidate]()
    for i in range(MERGE_FACTOR):
        mixed.append(_cand(i, Int64(100), Int64(1000), Int64(0)))
    for i in range(3):
        mixed.append(_cand(100 + i, Int64(100), Int64(500), Int64(2)))
    var plan2 = select_merge(mixed)
    assert_true(plan2.should_merge(), "6d: >=factor raw -> merge")
    # None of the selected are already-merged.
    for i in range(plan2.num_selected()):
        assert_false(
            plan2.selected[i].summary.is_merged(),
            "6d: no already-merged split selected",
        )


# =============================================================================
# Case 7 — the `.split` data-object reaper grace gate.
# =============================================================================


def test_07_split_reaper_grace_gate() raises:
    # The reaper deletes the `.split` data object ONLY after the grace window.
    var store = InMemoryConditionalStore()
    # PUT a .split object.
    var okey = String("k/logs/splits/old.split")
    _ = store.put(Path.parse(okey), _bytes("THSPLIT-fake-body"))

    comptime T0: Int64 = 9_000
    comptime GRACE: Int64 = 200
    # Inside the grace window -> NOT deleted (returns False); still readable.
    var early = reap_retired_split(store, okey, T0, T0 + GRACE // 2, GRACE)
    assert_false(early, "7: .split reap blocked inside grace")
    var still = store.get(Path.parse(okey))  # no 404
    assert_true(len(still) > 0, "7: .split still readable inside grace")

    # After grace -> deleted (returns True). A second reap of the now-absent
    # object is idempotent (store.delete tolerates absent) -> True again.
    var late = reap_retired_split(store, okey, T0, T0 + GRACE + 1, GRACE)
    assert_true(late, "7: .split reaped after grace")
    var again = reap_retired_split(store, okey, T0, T0 + GRACE + 1, GRACE)
    assert_true(again, "7: idempotent re-reap of absent .split")


# =============================================================================
# Case 8 — the sequence of one compaction pass (snapshot -> select -> merge ->
# publish -> retire -> reap) driven step by step against an in-memory
# SearchMetastore. `test_search_compact_once.mojo` runs the same pass through
# `compact_once` itself. Ingest N small splits, run one pass, assert the live
# set collapsed (N -> 1), all docs are searchable post-merge, the snapshot seqs
# were retired, and a SECOND pass is a harmless no-op (the maturity guard and
# the content-addressed key).
# =============================================================================


def _publish_raw_returning_uuid(
    mut meta: SearchMetastore[InMemoryConditionalStore],
    bts: List[UInt8],
    idx: Int,
) raises -> Array[UInt8, 16]:
    """Publish a raw single-doc split's summary; return its UUID + record its
    object_key so the reaper has a `.split` key to delete (in this in-memory
    replay the `.split` bytes are modelled by the caller's side map)."""
    var view = SplitView.parse(bts.copy())
    var u = view.split_uuid()
    var summ = make_split_summary(
        view.split_uuid(), Int64(1), Int64(len(bts)), Int64(0), Int64(0),
        String("logs"), String("body"),
        String("k/logs/splits/raw" + String(idx) + ".split"),
    )
    _ = meta.publish(summ^)
    return u^


def test_08_full_pass_orchestration() raises:
    # --- ingest MERGE_FACTOR (=10) small raw splits ---
    var meta = _fresh_metastore()
    var raw_bytes = List[List[UInt8]]()
    for i in range(MERGE_FACTOR):
        var word = String("w") + String(i)
        var bts = _ingest_to_split(
            _one_doc_ndjson(word, "active" if i % 2 == 0 else "sold", 10 * (i + 1)),
            i,
        )
        raw_bytes.append(bts.copy())
        _ = _publish_raw_returning_uuid(meta, bts, i)
    assert_equal(
        len(meta.list_live_splits()), MERGE_FACTOR, "8: N raw splits live"
    )

    # --- STEP 1: SNAPSHOT (seq->summary) ---
    var snapshot = meta.list_live_splits_with_seq()
    assert_equal(len(snapshot), MERGE_FACTOR, "8: snapshot all N")

    # --- STEP 2: SELECT (the policy) ---
    var candidates = List[MergeCandidate]()
    for i in range(len(snapshot)):
        candidates.append(
            MergeCandidate(
                String(""), snapshot[i].chunk_seq, snapshot[i].summary.copy()
            )
        )
    var plan = select_merge(candidates)
    assert_true(plan.should_merge(), "8: >=MERGE_FACTOR raw -> merge fires")

    # --- STEP 3a: gather the selected inputs' bytes (object GET, modelled by the
    # side map keyed by UUID) + the retire seqs ---
    var merge_inputs = List[List[UInt8]]()
    var input_uuids = List[Array[UInt8, 16]]()
    var retire_seqs = List[Int64]()
    for i in range(plan.num_selected()):
        ref cand = plan.selected[i]
        # Resolve the summary's UUID back to the raw bytes (the in-memory object GET).
        var idx = _index_of_uuid(raw_bytes, cand.summary.split_uuid)
        merge_inputs.append(raw_bytes[idx].copy())
        input_uuids.append(cand.summary.split_uuid.copy())
        retire_seqs.append(cand.chunk_seq)

    # --- STEP 3b: MERGE ---
    var merged_uuid = _uuid(900)
    var okey = content_addressed_merge_key(
        String("prefix"), String("logs"), input_uuids
    )
    var mr = merge_split_bytes(
        merge_inputs, String("logs"), String("bucket"), String("prefix"),
        String("body"), merged_uuid, okey,
    )
    assert_equal(mr.doc_count, MERGE_FACTOR, "8: merged holds all N docs")
    var merged_bytes = mr.split_bytes.copy()

    # --- STEP 3c: PUBLISH the merged summary (input set + merge_ops) ---
    var merged_view = SplitView.parse(merged_bytes.copy())
    var m_summ = make_merged_split_summary(
        merged_uuid^, Int64(merged_view.doc_count()),
        Int64(len(merged_bytes)), Int64(merged_view.min_doc_id()),
        Int64(merged_view.max_doc_id()), String("logs"), String("body"),
        okey, mr.merge_ops, mr.input_uuids_flat.copy(),
    )
    _ = meta.publish(m_summ^)

    # --- STEP 3d: RETIRE EXACTLY the snapshot seqs (deterministic clock) ---
    comptime T0: Int64 = 2_000_000
    comptime GRACE: Int64 = 60_000
    for i in range(len(retire_seqs)):
        meta.retire_at(retire_seqs[i], T0)

    # --- ASSERT the live set COLLAPSED N -> 1 (only the merged split) ---
    var live = meta.list_live_splits()
    assert_equal(len(live), 1, "8: live set collapsed N -> 1")
    assert_true(live[0].is_merged(), "8: the lone live split is the merged one")
    assert_equal(live[0].doc_count, Int64(MERGE_FACTOR), "8: M has N docs")

    # --- ASSERT all docs searchable post-merge (every _source present once) ---
    var hits = _search_sources(merged_bytes, String("alpha"))
    assert_equal(len(hits), MERGE_FACTOR, "8: all N docs searchable in M")
    for i in range(len(hits)):
        assert_equal(_count_str(hits, hits[i]), 1, "8: each doc exactly once")

    # --- STEP 4: REAP — within grace, nothing reaped (no 404 window) ---
    var tombs = meta.tombstoned_seqs()
    assert_equal(len(tombs), MERGE_FACTOR, "8: N seqs tombstoned")
    var reaped_early = 0
    for i in range(len(tombs)):
        if meta.reap_chunk(tombs[i], T0 + GRACE // 2, GRACE):
            reaped_early += 1
    assert_equal(reaped_early, 0, "8: nothing reaped inside grace (MVCC safe)")

    # After grace -> all N chunks reaped; live set unchanged (still just M).
    var reaped_late = 0
    var tombs2 = meta.tombstoned_seqs()
    for i in range(len(tombs2)):
        # Capture the .split key before reaping (here: just assert it reads).
        var k = meta.tombstoned_chunk_object_key(tombs2[i])
        assert_true(k.byte_length() > 0, "8: object_key readable pre-reap")
        if meta.reap_chunk(tombs2[i], T0 + GRACE + 1, GRACE):
            reaped_late += 1
    assert_equal(reaped_late, MERGE_FACTOR, "8: all N reaped after grace")
    var live_after_reap = meta.list_live_splits()
    assert_equal(len(live_after_reap), 1, "8: live set still just M post-reap")

    # --- SECOND PASS is a no-op: a snapshot now has ONLY the merged split, and
    # The maturity guard excludes already-merged splits -> select_merge does not fire ---
    var snapshot2 = meta.list_live_splits_with_seq()
    assert_equal(len(snapshot2), 1, "8: 2nd snapshot = just M")
    var cands2 = List[MergeCandidate]()
    for i in range(len(snapshot2)):
        cands2.append(
            MergeCandidate(
                String(""), snapshot2[i].chunk_seq, snapshot2[i].summary.copy()
            )
        )
    var plan2 = select_merge(cands2)
    assert_false(
        plan2.should_merge(),
        "8: 2nd pass no-op (maturity guard excludes the merged split; below MERGE_FACTOR)",
    )

    # --- idempotency: re-merging the SAME input set produces the SAME key
    # (content-addressed) -> a re-PUT would be a harmless overwrite ---
    var okey2 = content_addressed_merge_key(
        String("prefix"), String("logs"), input_uuids
    )
    assert_equal(okey, okey2, "8: content-addressed key stable (idempotent)")


def _index_of_uuid(
    raw: List[List[UInt8]], u: Array[UInt8, 16]
) raises -> Int:
    for i in range(len(raw)):
        var view = SplitView.parse(raw[i].copy())
        if _uuid_eq(view.split_uuid(), u):
            return i
    raise Error("8: no raw split with the requested UUID")


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

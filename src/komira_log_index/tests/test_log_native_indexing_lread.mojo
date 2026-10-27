# =============================================================================
# test_log_native_indexing_lread.mojo
#   Per-split format routing in the read and merge path.
# =============================================================================
#
# This suite is the correctness gate for reading L0 splits:
#
#   1. L0-SPLIT READ. search_l0_split over an L0 (cheap drain) split returns the
#      CORRECT, COMPLETE matching doc-ids and the _source payload for a MATCH
#      query (selective, common, multi and absent terms), checked against an
#      independent in-test brute-force oracle. The L0 split is searchable on its
#      own.
#
#   2. FORMAT DISPATCH. The route discriminator is SplitView.has_l0_posting()
#      (not a front magic, not the first split's footer): an L0 split routes to
#      search_l0_split (posting probe and TF-rank), an optimized split routes to
#      SearchCore (BM25). Over the same single-split corpus the two paths return
#      the same hit SET (only the score differs: TF-rank against BM25).
#
#   3. MIXED-SET MERGE (the load-bearing case). A fan-out over a MIXED set
#      {L0 split, optimized split} MERGES correctly: the merged result is the
#      UNION of both splits' matches with no lost and no duplicated docs. It is
#      tested over a disjoint-corpus pair so every expected (split, doc-id) is
#      individually checkable, and total_matches == oracle_L0 + oracle_optimized.
#
#   4. PAGE SLICE AND TOTAL. The L0 path honors from/size paging (the page is the
#      top-(from+size) window, sliced [from, from+size)) while total_matches
#      stays the TRUE union count regardless of the page.
#
# The loop mirrors a read fan-out's per-split decode loop (parse each split's
# footer once, route on has_l0_posting(), over-fetch to from+size, merge), so
# the suite is the end-to-end proof of per-split format routing.
#
# No UnsafePointer in any signature. The L0 reader and the merge work over owned
# Lists and the parsed SplitViews (the views own their bytes; the region Spans
# are tied to the inner _bytes origin).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
)

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.emit import emit_record
from komira_log.engine.drain import drain_to_views
from komira_log import LogRecordView
from komira_log.levels import LEVEL_INFO, LEVEL_WARN, LEVEL_ERROR
from komira_log.log_arg import ArgI64, ArgStr

from komira_log_index import (
    LOG_INDEX_TEXT_FIELD,
    LOG_INDEX_SOURCE_FIELD,
    log_index_schema,
    log_views_to_record_batch,
    L0SegmentBuilder,
    search_l0_split,
)

from komira_collections.slab import Slab

from komira_search.analyzer import AnalyzerConfig, analyze_text
from komira_search.split import SplitView
from komira_search.sink import SearchSink
from komira_search.source import (
    QueryIR,
    SearchCore,
    SearchResult,
    SORT_MODE_SCORE,
)
from komira_search.merge import merge_search_results


# -----------------------------------------------------------------------------
# Fixtures — an OTLP-style 5-site corpus, the same one the L1 suite
# uses. `base` offsets the correlation-id so two corpora can be made distinct.
# -----------------------------------------------------------------------------


def _fixed_anchor() -> CalibrationAnchor:
    var wall0_ns = UInt64(1_788_220_800) * UInt64(1_000_000_000)
    return CalibrationAnchor(
        tick0=UInt64(0), wall0_ns=wall0_ns, tick_hz=UInt64(1_000_000_000)
    )


def _dict() raises -> SiteDictionary:
    var d = SiteDictionary()
    d.register["request {} method {} status {}", "komira_http"]()
    d.register["query finished in {} ms scanned {} rows", "komira_engine"]()
    d.register["opened file {} size {} bytes", "komira_parquet"]()
    d.register["retry {} reason {}", "komira_agent"]()
    d.register["connection {} from {} closed", "komira_broker"]()
    return d^


def _fill_ring(mut r: LogRecordRing, n: Int, base: Int):
    for i in range(n):
        var m = i % 5
        var c = UInt64(base + 1000 + i)
        if m == 0:
            _ = emit_record["request {} method {} status {}", "komira_http"](
                r, LEVEL_INFO, c, ArgStr(String("/v1/query")), ArgStr(String("POST")), ArgI64(200)
            )
        elif m == 1:
            _ = emit_record[
                "query finished in {} ms scanned {} rows", "komira_engine"
            ](r, LEVEL_INFO, c, ArgI64(42), ArgI64(6001215))
        elif m == 2:
            _ = emit_record["opened file {} size {} bytes", "komira_parquet"](
                r, LEVEL_WARN, c, ArgStr(String("lineitem.parquet")), ArgI64(298000000)
            )
        elif m == 3:
            _ = emit_record["retry {} reason {}", "komira_agent"](
                r, LEVEL_ERROR, c, ArgI64(3), ArgStr(String("connection timeout to upstream"))
            )
        else:
            _ = emit_record["connection {} from {} closed", "komira_broker"](
                r, LEVEL_INFO, c, ArgI64(7), ArgStr(String("192.0.2.42"))
            )


def _drain_corpus(n: Int, base: Int = 0) raises -> List[LogRecordView]:
    var dict = _dict()
    var anchor = _fixed_anchor()
    var ring = LogRecordRing(capacity=n + 8, overflow_policy=OVERFLOW_BLOCK)
    _fill_ring(ring, n, base)
    return drain_to_views(ring, dict, anchor)


def _messages_of(views: List[LogRecordView]) -> List[String]:
    var out = List[String]()
    for i in range(len(views)):
        out.append(views[i].message)
    return out^


def _oracle_matches(
    config: AnalyzerConfig, messages: List[String], term: String
) raises -> List[Int]:
    """Independent brute-force oracle: the slots whose analyzed message contains
    the analyzed query term (== test_log_native_indexing_l1.mojo's oracle, copied — no shared code)."""
    var qa = analyze_text(term, config)
    var out = List[Int]()
    if qa.len() == 0:
        return out^
    var qterm = qa.tokens[0].term
    for slot in range(len(messages)):
        var af = analyze_text(messages[slot], config)
        for ti in range(af.len()):
            if af.tokens[ti].term == qterm:
                out.append(slot)
                break
    return out^


def _build_l0_split(views: List[LogRecordView]) raises -> List[UInt8]:
    var schema = log_index_schema()
    var batch = log_views_to_record_batch(views)
    var seg = L0SegmentBuilder(schema^)
    seg.add_batch(batch^)
    var uuid = InlineArray[UInt8, 16](fill=UInt8(7))
    return seg.serialize_split_bytes(LOG_INDEX_TEXT_FIELD, uuid)


def _build_optimized_split(views: List[LogRecordView]) raises -> List[UInt8]:
    var schema = log_index_schema()
    var batch = log_views_to_record_batch(views)
    var uuid = InlineArray[UInt8, 16](fill=UInt8(9))
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("logs"),
        LOG_INDEX_TEXT_FIELD,
        uuid,
        LOG_INDEX_SOURCE_FIELD,
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _match_query(term: String, top_k: Int = 1000, from_offset: Int = 0) -> QueryIR:
    """A plain MATCH query over the text field: `_score` sort (TF-rank on L0,
    BM25 on optimized), no filter, no aggs. top_k = `size`, from_offset = `from`.
    """
    var q = QueryIR(
        LOG_INDEX_TEXT_FIELD,
        term,
        top_k,
        AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD),
        0,
    )
    q.from_offset = from_offset
    return q^


def _doc_ids_of(res: SearchResult) raises -> List[Int]:
    """The doc-ids (the `_id` Int64 column) of a SearchResult's HitBatch, sorted
    ascending so the comparison against the oracle is order-independent."""
    var out = List[Int]()
    var n = res.batch.num_rows()
    for row in range(n):
        out.append(
            Int(res.batch.column_at(1).as_primitive[DType.int64]().get(row))
        )
    # insertion sort (small pages) so set-equality is order-independent.
    for i in range(1, len(out)):
        var v = out[i]
        var j = i - 1
        while j >= 0 and out[j] > v:
            out[j + 1] = out[j]
            j -= 1
        out[j + 1] = v
    return out^


def _lists_equal(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# =============================================================================
# CASE 1 — search_l0_split over an L0 split returns the correct + complete
# matches (vs the oracle) for selective / common / multi / absent terms, plus
# the _source payload.
# =============================================================================


def test_01_l0_split_read_matches_oracle() raises:
    var views = _drain_corpus(60)
    var messages = _messages_of(views)
    var bytes = _build_l0_split(views)
    var view = SplitView.parse(bytes^)
    assert_true(view.has_l0_posting(), "1: L0 split has the l0_posting slot")

    var config = AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD)
    var terms = [
        String("lineitem.parquet"),  # selective (m==2, ~20%)
        String("request"),           # common (m==0)
        String("scanned"),           # multi (m==1)
        String("connection"),        # appears in BOTH m==3 text + m==4 template
        String("nonesuchzzz"),       # absent
    ]
    for qi in range(len(terms)):
        ref qt = terms[qi]
        var oracle = _oracle_matches(config, messages, qt)
        var res = search_l0_split(view, _match_query(qt))
        var got = _doc_ids_of(res)
        assert_true(
            _lists_equal(got, oracle),
            String("1: L0 read == oracle for '") + qt + "' (got "
            + String(len(got)) + " want " + String(len(oracle)) + ")",
        )
        # total_matches is the TRUE union count (== the page here: top_k=1000).
        assert_equal(
            res.total_matches, len(oracle),
            String("1: total_matches == oracle count for '") + qt + "'",
        )

    # The _source payload is fetched for a hit (a non-empty JSON _source blob).
    var res_req = search_l0_split(view, _match_query(String("request")))
    assert_true(res_req.batch.num_rows() > 0, "1: 'request' has hits")
    var first_src = res_req.batch.column_at(2).as_string().get(0)
    assert_true(first_src.byte_length() > 0, "1: _source payload is non-empty")


# =============================================================================
# CASE 2 — FORMAT DISPATCH: over the SAME single-split corpus, the L0 path and
# the optimized SearchCore path return the SAME hit SET (the discriminator routes
# correctly; only the score differs — TF-rank vs BM25).
# =============================================================================


def test_02_format_dispatch_same_hitset() raises:
    var l0_bytes = _build_l0_split(_drain_corpus(50))
    var opt_bytes = _build_optimized_split(_drain_corpus(50))

    var l0_view = SplitView.parse(l0_bytes^)
    var opt_view = SplitView.parse(opt_bytes^)

    # The discriminator routes each path.
    assert_true(l0_view.has_l0_posting(), "2: L0 split -> posting probe")
    assert_false(opt_view.has_l0_posting(), "2: optimized split -> SearchCore")

    var config = AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD)
    var probe = [
        String("request"),
        String("scanned"),
        String("file"),
        String("retry"),
        String("closed"),
    ]
    var opt_core = SearchCore.from_view(opt_view^)
    for pi in range(len(probe)):
        ref pt = probe[pi]
        var l0_res = search_l0_split(l0_view, _match_query(pt))
        var opt_res = opt_core.search(_match_query(pt))
        var l0_ids = _doc_ids_of(l0_res)
        var opt_ids = _doc_ids_of(opt_res)
        assert_true(
            _lists_equal(l0_ids, opt_ids),
            String("2: L0 hit-set == optimized hit-set for '") + pt + "'",
        )
        assert_equal(
            l0_res.total_matches, opt_res.total_matches,
            String("2: total_matches match for '") + pt + "'",
        )


# =============================================================================
# CASE 3 — THE LOAD-BEARING GATE: a MIXED {L0, optimized} fan-out merges to the
# correct UNION with NO lost / NO dup docs. The two splits are over DISJOINT
# corpora so every expected (split, doc-id) is checkable and the merged total ==
# oracle_L0 + oracle_optimized. This mirrors the dispatch per-split decode loop.
# =============================================================================


def _route_and_search(bytes: List[UInt8], query: QueryIR) raises -> SearchResult:
    """The EXACT per-split route the dispatch loop does: parse the footer once,
    branch on has_l0_posting() -> search_l0_split | SearchCore.from_view."""
    var b = bytes.copy()
    var view = SplitView.parse(b^)
    if view.has_l0_posting():
        return search_l0_split(view, query)
    var core = SearchCore.from_view(view^)
    return core.search(query)


def test_03_mixed_set_merge_correct_union() raises:
    # Two DISJOINT corpora (distinct correlation-id base so the _source differs);
    # build split A as L0, split B as optimized.
    var views_a = _drain_corpus(40, base=0)
    var views_b = _drain_corpus(40, base=100000)
    var messages_a = _messages_of(views_a)
    var messages_b = _messages_of(views_b)
    var l0_bytes = _build_l0_split(views_a)   # split 0: L0
    var opt_bytes = _build_optimized_split(views_b)  # split 1: optimized

    var config = AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD)

    # A common term present in both corpora.
    var terms = [
        String("request"),
        String("scanned"),
        String("file"),
        String("connection"),
    ]
    var base_from = 0
    var base_size = 1000  # over-fetch big enough to retain every match.
    for qi in range(len(terms)):
        ref qt = terms[qi]
        var oracle_a = _oracle_matches(config, messages_a, qt)
        var oracle_b = _oracle_matches(config, messages_b, qt)

        # The per-split over-fetch query (from=0, top_k=from+size), routed
        # per-split on the format discriminator (the dispatch loop).
        var leaf = _match_query(qt, base_from + base_size, 0)
        var ra = _route_and_search(l0_bytes, leaf)
        var rb = _route_and_search(opt_bytes, leaf)

        var results = Slab[SearchResult].create(2)
        results.append(ra^)
        results.append(rb^)
        var merged = merge_search_results(
            results^, base_from, base_size, SORT_MODE_SCORE, UInt8(0), UInt8(0)
        )

        # NO LOST / NO DUP: the merged page row count == |oracle_a| + |oracle_b|
        # (every match from BOTH splits is present exactly once), and the true
        # total_matches is the same union count.
        var want_total = len(oracle_a) + len(oracle_b)
        assert_equal(
            merged.result.batch.num_rows(), want_total,
            String("3: merged page rows == union for '") + qt + "'",
        )
        assert_equal(
            merged.result.total_matches, want_total,
            String("3: merged total_matches == union for '") + qt + "'",
        )

        # PROVENANCE: each merged hit carries its split-publish-order index; every
        # split-0 doc-id maps to oracle_a, every split-1 doc-id to oracle_b. This
        # is the no-dup / no-cross-contamination check (a doc-id from the wrong
        # split, or a duplicated doc-id, fails set-equality).
        ref idx = merged.hit_split_index
        var n = merged.result.batch.num_rows()
        var seen_a = List[Int]()
        var seen_b = List[Int]()
        for row in range(n):
            var did = Int(
                merged.result.batch.column_at(1)
                .as_primitive[DType.int64]().get(row)
            )
            if idx[row] == 0:
                seen_a.append(did)
            else:
                seen_b.append(did)
        # sort the collected ids and compare to the (already ascending) oracles.
        _sort_inplace(seen_a)
        _sort_inplace(seen_b)
        assert_true(
            _lists_equal(seen_a, oracle_a),
            String("3: split-0 (L0) ids == oracle_a for '") + qt + "'",
        )
        assert_true(
            _lists_equal(seen_b, oracle_b),
            String("3: split-1 (optimized) ids == oracle_b for '") + qt + "'",
        )


def _sort_inplace(mut a: List[Int]):
    for i in range(1, len(a)):
        var v = a[i]
        var j = i - 1
        while j >= 0 and a[j] > v:
            a[j + 1] = a[j]
            j -= 1
        a[j + 1] = v


# =============================================================================
# CASE 4 — the L0 read path honors paging: the page is the [from, from+size)
# slice of the top-(from+size) window, while total_matches stays the TRUE union
# count regardless of the page.
# =============================================================================


def test_04_l0_paging_and_total() raises:
    var views = _drain_corpus(50)
    var messages = _messages_of(views)
    var bytes = _build_l0_split(views)
    var view = SplitView.parse(bytes^)

    var config = AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD)
    var term = String("request")  # a common term (m==0 -> 10 of 50 docs).
    var oracle = _oracle_matches(config, messages, term)
    var total = len(oracle)
    assert_true(total >= 4, "4: 'request' matches enough docs to page")

    # Full page: top_k high -> every match returned, total == oracle.
    var full = search_l0_split(view, _match_query(term))
    assert_equal(full.batch.num_rows(), total, "4: full page returns all")
    assert_equal(full.total_matches, total, "4: full total == oracle")

    # size=3 page: 3 rows, but total_matches stays the TRUE count.
    var page = search_l0_split(view, _match_query(term, 3, 0))
    assert_equal(page.batch.num_rows(), 3, "4: size=3 page returns 3 rows")
    assert_equal(page.total_matches, total, "4: paged total still == oracle")

    # from=2,size=2: a 2-row second page; total unchanged.
    var page2 = search_l0_split(view, _match_query(term, 2, 2))
    assert_equal(page2.batch.num_rows(), 2, "4: from=2 size=2 page returns 2")
    assert_equal(page2.total_matches, total, "4: from-offset total still == oracle")

    # size=0 (count-only): 0 rows, total still the true count.
    var count_only = search_l0_split(view, _match_query(term, 0, 0))
    assert_equal(count_only.batch.num_rows(), 0, "4: size=0 -> empty page")
    assert_equal(count_only.total_matches, total, "4: size=0 total == oracle")


def main() raises:
    var suite = TestSuite()
    suite.test[test_01_l0_split_read_matches_oracle]()
    suite.test[test_02_format_dispatch_same_hitset]()
    suite.test[test_03_mixed_set_merge_correct_union]()
    suite.test[test_04_l0_paging_and_total]()
    suite^.run()

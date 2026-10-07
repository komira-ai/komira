# =============================================================================
# test_multi_split_merge.mojo — the MULTI-SPLIT merge reducers
# =============================================================================
#
# Engine-side PURE-reducer unit suite over MULTIPLE in-memory splits built by the
# split writer (SearchSink) + the fast-fields — NO S3 / MinIO. Mirrors the
# filter/sort/aggregation in-memory-split style, ×N splits. Covers the reducer units:
#
#   1.  Merged top-k order across splits (fast-field SORT — exact key control) —
#       assert the merged page is the global order a single split over the union
#       would produce.
#   2.  Global total = SUM of per-split total_matches.
#   3.  max_score = MAX (the merged top row's score under a _score sort).
#   4.  Pagination across splits — from=2,size=2 with the page drawn from
#       DIFFERENT splits (the over-fetch correctness case); the page is the
#       GLOBAL [2,4) slice, not each split's own [2,4).
#   5.  Cross-split tiebreak determinism — equal sort key at the SAME per-split
#       doc_id (the collision case); the merged order is deterministic by
#       split-publish-order and stable across repeated merges.
#   6.  A split with zero matches contributes nothing (0 to total, no corruption).
#   7.  Merged terms buckets — doc_counts SUMMED per key, re-sorted, re-truncated
#       to base_size, sum_other_doc_count = per-split-sum + coordinator-tail.
#   8.  Merged metric aggs — avg RE-DERIVED from merged sum/count (never avg-of-
#       avg), min/max global extrema, value_count global sum, empty-set null.
#   9.  shard_size_for over-fetch bound.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_collections.slab import Slab

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.source import (
    QueryIR,
    SearchCore,
    SearchResult,
    AggSpec,
    AggResult,
    AggResults,
    _TermBucket,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    AGG_KIND_MIN,
    AGG_KIND_MAX,
    AGG_KIND_SUM,
    AGG_KIND_VALUE_COUNT,
    AGG_ORDER_COUNT_DESC,
    AGG_ORDER_COUNT_ASC,
    AGG_ORDER_KEY_ASC,
    SORT_DESC,
    SORT_ASC,
    MISSING_LAST,
    SORT_FIELD_DOC,
    SORT_MODE_SCORE,
    SORT_MODE_DOC,
    SORT_MODE_I64,
)
from komira_search.merge import (
    merge_search_results,
    merge_agg_results,
    shard_size_for,
)


# -----------------------------------------------------------------------------
# Fixture helpers (mirror test_search_aggregations / test_search_sort_pagination).
# -----------------------------------------------------------------------------


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _text_cfg() -> AnalyzerConfig:
    return AnalyzerConfig.text("body")


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def _i64_col(values: List[Int64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _f64_col(values: List[Float64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(values)
    )


def _split_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("genre", ArrowType.STRING, True))  # keyword
    sb.add_field(Field("price", ArrowType.INT64, True))
    return sb.build()


def _drive_sink(
    var batch: RecordBatch, var schema: Schema, seed: UInt8
) raises -> List[UInt8]:
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("idx"),
        String("body"),
        _uuid(seed),
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _build_split(
    seed: UInt8,
    bodies: List[String],
    sources: List[String],
    genres: List[String],
    prices: List[Int64],
) raises -> List[UInt8]:
    """Build ONE in-memory split blob with the given per-doc columns. doc_ids in
    the split are dense ascending 0..n-1 (the dense doc-store invariant) — so doc_ids COLLIDE
    across splits, exactly the scenario."""
    var schema = _split_schema()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(_str_col(bodies))
    rb.add_column(_str_col(sources))
    rb.add_column(_str_col(genres))
    rb.add_column(_i64_col(prices))
    var batch = rb.build(schema.copy())
    return _drive_sink(batch^, schema^, seed)


def _q_price_sort(
    order: UInt8, base_from: Int, base_size: Int
) raises -> QueryIR:
    """A match("alpha") query sorted by the `price` fast-field, with the per-split
    OVER-FETCH rewrite already applied: from_offset=0, top_k=base_from+base_size
    (the driver's rewrite — the leaf returns its top (from+size) UN-sliced)."""
    return QueryIR(
        String("body"), String("alpha"), base_from + base_size, _text_cfg(),
        0, None, String("price"), order, MISSING_LAST, 0, List[AggSpec](),
    )


def _q_doc_sort(order: UInt8, base_from: Int, base_size: Int) raises -> QueryIR:
    """A match("alpha") query sorted by `_doc`, over-fetched to from+size."""
    return QueryIR(
        String("body"), String("alpha"), base_from + base_size, _text_cfg(),
        0, None, SORT_FIELD_DOC, order, MISSING_LAST, 0, List[AggSpec](),
    )


def _q_score(base_from: Int, base_size: Int) raises -> QueryIR:
    """A match("alpha") query sorted by `_score` (default), over-fetched."""
    return QueryIR(
        String("body"), String("alpha"), base_from + base_size, _text_cfg(),
        0, None, String(""), SORT_DESC, MISSING_LAST, 0, List[AggSpec](),
    )


def _q_aggs(var aggs: List[AggSpec], shard_size: Int) raises -> QueryIR:
    """A match("alpha") query carrying `aggs` with the per-split terms shard_size
    over-fetch rewrite applied (the rewrite the driver does via
    rewrite_terms_bucket_sizes); size:0 hits (top_k=0)."""
    var q = QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(),
        0, None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    q.rewrite_terms_bucket_sizes(shard_size)
    return q^


# -----------------------------------------------------------------------------
# Run one split through SearchCore -> SearchResult.
# -----------------------------------------------------------------------------


def _search_split(split_bytes: List[UInt8], query: QueryIR) raises -> SearchResult:
    var core = SearchCore(split_bytes.copy())
    return core.search(query)


# Read the page's doc_ids / prices / sources from a merged SearchResult batch.
def _page_ids(res: SearchResult) raises -> List[Int64]:
    var out = List[Int64]()
    var n = res.batch.num_rows()
    for r in range(n):
        out.append(
            Int64(res.batch.column_at(1).as_primitive[DType.int64]().get(r))
        )
    return out^


def _page_sources(res: SearchResult) raises -> List[String]:
    var out = List[String]()
    var n = res.batch.num_rows()
    for r in range(n):
        out.append(res.batch.column_at(2).as_string().get(r))
    return out^


def _page_scores(res: SearchResult) raises -> List[Float64]:
    var out = List[Float64]()
    var n = res.batch.num_rows()
    for r in range(n):
        out.append(
            Float64(res.batch.column_at(0).as_primitive[DType.float64]().get(r))
        )
    return out^


def _result_by_name(res: AggResults, name: String) raises -> AggResult:
    for i in range(len(res.results)):
        if res.results[i].name == name:
            return res.results[i].copy()
    raise Error("agg result not found: " + name)


# =============================================================================
# TEST 1 — merged top-k order across splits (fast-field SORT, exact key control).
# =============================================================================
# Split A prices [30, 10]; split B prices [40, 20]. Global price-ASC order is:
#   B.doc0(10? no) — recompute: A=[30,10] -> A.doc0=30,A.doc1=10;
#   B=[40,20] -> B.doc0=40,B.doc1=20. price ASC global: 10(A.doc1),20(B.doc1),
#   30(A.doc0),40(B.doc0). The merged page must be exactly that order.
def test_topk_merge_fastfield_sort() raises:
    var sa = _build_split(
        10, [String("alpha"), String("alpha")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(30), Int64(10)],
    )
    var sb = _build_split(
        50, [String("alpha"), String("alpha")],
        [String("B0"), String("B1")],
        [String("x"), String("x")], [Int64(40), Int64(20)],
    )
    var base_from = 0
    var base_size = 10
    var ra = _search_split(sa, _q_price_sort(SORT_ASC, base_from, base_size))
    var rb = _search_split(sb, _q_price_sort(SORT_ASC, base_from, base_size))
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var merged = merge_search_results(
        results^, base_from, base_size, SORT_MODE_I64, SORT_ASC, MISSING_LAST
    )
    var srcs = _page_sources(merged.result)
    assert_equal(len(srcs), 4)
    # price ASC: 10, 20, 30, 40.
    assert_equal(srcs[0], String("A1"))
    assert_equal(srcs[1], String("B1"))
    assert_equal(srcs[2], String("A0"))
    assert_equal(srcs[3], String("B0"))
    assert_equal(merged.result.total_matches, 4)


# =============================================================================
# TEST 2 — global total = SUM; max_score = MAX (score sort).
# =============================================================================
def test_total_sum_and_max_score() raises:
    var sa = _build_split(
        10, [String("alpha beta"), String("alpha")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(1), Int64(2)],
    )
    var sb = _build_split(
        50, [String("alpha"), String("alpha beta")],
        [String("B0"), String("B1")],
        [String("x"), String("x")], [Int64(3), Int64(4)],
    )
    var ra = _search_split(sa, _q_score(0, 10))
    var rb = _search_split(sb, _q_score(0, 10))
    # Capture per-split max scores before move.
    var amax = _page_scores(ra)[0]
    var bmax = _page_scores(rb)[0]
    var expect_max = amax if amax > bmax else bmax
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var merged = merge_search_results(
        results^, 0, 10, SORT_MODE_SCORE, SORT_DESC, MISSING_LAST
    )
    assert_equal(merged.result.total_matches, 4)  # 2 + 2 matched docs.
    var mscores = _page_scores(merged.result)
    # The merged page is globally score-descending; top row == global max.
    assert_almost_equal(mscores[0], expect_max)
    for i in range(1, len(mscores)):
        assert_true(mscores[i - 1] >= mscores[i])


# =============================================================================
# TEST 3 — pagination across splits (the over-fetch correctness case).
# =============================================================================
# from=2,size=2. Global price-ASC order over 6 docs (A=[15,35,55],B=[25,45,65]):
#   15,25,35,45,55,65. Page [2,4) = 35,45.
# A doc at global rank 2 sits at per-split rank 1 — naive per-split [2,4) would
# MISS it. Each split is over-fetched to from+size=4 rows.
def test_pagination_across_splits() raises:
    var sa = _build_split(
        10, [String("alpha"), String("alpha"), String("alpha")],
        [String("A0"), String("A1"), String("A2")],
        [String("x"), String("x"), String("x")],
        [Int64(15), Int64(35), Int64(55)],
    )
    var sb = _build_split(
        50, [String("alpha"), String("alpha"), String("alpha")],
        [String("B0"), String("B1"), String("B2")],
        [String("x"), String("x"), String("x")],
        [Int64(25), Int64(45), Int64(65)],
    )
    var base_from = 2
    var base_size = 2
    var ra = _search_split(sa, _q_price_sort(SORT_ASC, base_from, base_size))
    var rb = _search_split(sb, _q_price_sort(SORT_ASC, base_from, base_size))
    # Each split over-fetched to from+size=4 rows (it has only 3 -> all 3).
    assert_equal(ra.batch.num_rows(), 3)
    assert_equal(rb.batch.num_rows(), 3)
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var merged = merge_search_results(
        results^, base_from, base_size, SORT_MODE_I64, SORT_ASC, MISSING_LAST
    )
    var srcs = _page_sources(merged.result)
    assert_equal(len(srcs), 2)
    assert_equal(srcs[0], String("A1"))  # price 35, global rank 2.
    assert_equal(srcs[1], String("B1"))  # price 45, global rank 3.
    assert_equal(merged.result.total_matches, 6)


# =============================================================================
# TEST 4 — cross-split tiebreak determinism (the doc-id collision case).
# =============================================================================
# Both splits: doc0 price=100, doc1 price=200. price ASC ties at 100 (A.doc0 vs
# B.doc0, both doc_id 0) and at 200 (A.doc1 vs B.doc1, both doc_id 1). The
# tiebreak (sort-key, doc_id, split-publish-order) orders A before B (A is split
# index 0). Stable across repeated merges.
def test_crossplit_tiebreak_determinism() raises:
    def run() raises -> List[String]:
        var sa = _build_split(
            10, [String("alpha"), String("alpha")],
            [String("A0"), String("A1")],
            [String("x"), String("x")], [Int64(100), Int64(200)],
        )
        var sb = _build_split(
            50, [String("alpha"), String("alpha")],
            [String("B0"), String("B1")],
            [String("x"), String("x")], [Int64(100), Int64(200)],
        )
        var ra = _search_split(sa, _q_price_sort(SORT_ASC, 0, 10))
        var rb = _search_split(sb, _q_price_sort(SORT_ASC, 0, 10))
        var results = Slab[SearchResult].create(2)
        results.append(ra^)
        results.append(rb^)
        var merged = merge_search_results(
            results^, 0, 10, SORT_MODE_I64, SORT_ASC, MISSING_LAST
        )
        return _page_sources(merged.result)

    var srcs = run()
    assert_equal(len(srcs), 4)
    # price 100 tie -> A.doc0 before B.doc0 (split index 0 < 1).
    assert_equal(srcs[0], String("A0"))
    assert_equal(srcs[1], String("B0"))
    # price 200 tie -> A.doc1 before B.doc1.
    assert_equal(srcs[2], String("A1"))
    assert_equal(srcs[3], String("B1"))
    # Stable across a repeated merge (deterministic).
    var srcs2 = run()
    for i in range(len(srcs)):
        assert_equal(srcs[i], srcs2[i])


# =============================================================================
# TEST 5 — a split with zero matches contributes nothing.
# =============================================================================
def test_zero_match_split() raises:
    # Split B's docs do NOT contain "alpha" -> 0 matches.
    var sa = _build_split(
        10, [String("alpha"), String("alpha")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(10), Int64(20)],
    )
    var sb = _build_split(
        50, [String("gamma"), String("delta")],
        [String("B0"), String("B1")],
        [String("x"), String("x")], [Int64(30), Int64(40)],
    )
    var ra = _search_split(sa, _q_price_sort(SORT_ASC, 0, 10))
    var rb = _search_split(sb, _q_price_sort(SORT_ASC, 0, 10))
    assert_equal(rb.batch.num_rows(), 0)  # zero matches.
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var merged = merge_search_results(
        results^, 0, 10, SORT_MODE_I64, SORT_ASC, MISSING_LAST
    )
    var srcs = _page_sources(merged.result)
    assert_equal(len(srcs), 2)  # only A's 2 docs.
    assert_equal(srcs[0], String("A0"))
    assert_equal(srcs[1], String("A1"))
    assert_equal(merged.result.total_matches, 2)  # B contributes 0.


# =============================================================================
# TEST 6 — merged terms buckets (doc_count summed, re-sorted, re-truncated).
# =============================================================================
# Split A genres: rock×2, jazz×1. Split B genres: rock×1, pop×3.
# Merged: rock=3, pop=3, jazz=1. base_size=2, count desc, key-asc tiebreak ->
# top2 = pop(3), rock(3)?  count tie rock vs pop -> key asc: pop < rock ->
# pop first. sum_other = jazz(1).
def test_terms_merge() raises:
    var sa = _build_split(
        10,
        [String("alpha"), String("alpha"), String("alpha")],
        [String("A0"), String("A1"), String("A2")],
        [String("rock"), String("rock"), String("jazz")],
        [Int64(1), Int64(2), Int64(3)],
    )
    var sb = _build_split(
        50,
        [String("alpha"), String("alpha"), String("alpha"), String("alpha")],
        [String("B0"), String("B1"), String("B2"), String("B3")],
        [String("rock"), String("pop"), String("pop"), String("pop")],
        [Int64(4), Int64(5), Int64(6), Int64(7)],
    )
    var base_size = 2
    var ss = shard_size_for(base_size)  # over-fetch each split.
    var specs_a = List[AggSpec]()
    specs_a.append(
        AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), base_size)
    )
    var specs_b = List[AggSpec]()
    specs_b.append(
        AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), base_size)
    )
    var ra = _search_split(sa, _q_aggs(specs_a^, ss))
    var rb = _search_split(sb, _q_aggs(specs_b^, ss))
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    # The ORIGINAL spec (base_size, NOT shard_size) drives the coordinator trim.
    var base_specs = List[AggSpec]()
    base_specs.append(
        AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), base_size,
                AGG_ORDER_COUNT_DESC)
    )
    var merged = merge_agg_results(results^, base_specs)
    var g = _result_by_name(merged, String("g"))
    assert_equal(len(g.buckets), 2)  # truncated to base_size.
    # rock=3, pop=3, jazz=1. count desc, key-asc tiebreak: pop < rock.
    assert_equal(g.buckets[0].key, String("pop"))
    assert_equal(g.buckets[0].doc_count, 3)
    assert_equal(g.buckets[1].key, String("rock"))
    assert_equal(g.buckets[1].doc_count, 3)
    assert_equal(g.sum_other_doc_count, 1)  # jazz dropped.


# =============================================================================
# TEST 6b — doc_count_error_upper_bound is ORDER-AWARE. The per-split error
# contribution = the doc_count of the LAST
# (smallest) bucket a split RETURNED, but ONLY when that split DROPPED a bucket.
# =============================================================================
#
# A small hand-built helper packs ONE terms AggResult (already shaped by a leaf
# `_finalize_terms`, so `last_bucket_doc_count` is set) into a SearchResult, so
# we can exercise the merge's order-semantics branch directly and deterministically
# (independent of the leaf's truncation, which TEST 6c covers end-to-end).
def _terms_split_result(
    var name: String,
    keys: List[String],
    counts: List[Int],
    last_bucket: Int,
    sum_other: Int = 0,
) raises -> SearchResult:
    var ar = AggResult(name^, AGG_KIND_TERMS)
    for i in range(len(keys)):
        ar.buckets.append(_TermBucket(keys[i].copy(), counts[i]))
    ar.last_bucket_doc_count = last_bucket
    ar.sum_other_doc_count = sum_other
    var results = List[AggResult]()
    results.append(ar^)
    return SearchResult(RecordBatch(), len(keys), AggResults(results^))


def _bound_for(
    sa_last: Int,
    sa_other: Int,
    sb_last: Int,
    sb_other: Int,
    order_code: UInt8,
    base_size: Int = 10,
) raises -> AggResult:
    """Merge two single-terms-agg splits whose per-split shaping is hand-set, and
    return the merged terms AggResult so the caller reads its
    doc_count_error_upper_bound + sum_other_doc_count."""
    var ka = List[String]()
    ka.append(String("rock"))
    ka.append(String("pop"))
    var ca = List[Int]()
    ca.append(5)
    ca.append(3)
    var kb = List[String]()
    kb.append(String("rock"))
    kb.append(String("jazz"))
    var cb = List[Int]()
    cb.append(4)
    cb.append(2)
    var sa = _terms_split_result(String("g"), ka, ca, sa_last, sa_other)
    var sb = _terms_split_result(String("g"), kb, cb, sb_last, sb_other)
    var results = Slab[SearchResult].create(2)
    results.append(sa^)
    results.append(sb^)
    var base_specs = List[AggSpec]()
    base_specs.append(
        AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), base_size,
                order_code)
    )
    var merged = merge_agg_results(results^, base_specs)
    return _result_by_name(merged, String("g"))


def test_doc_count_error_count_desc_nonzero() raises:
    # Both splits DROPPED a bucket (last_bucket_doc_count = 1 and 2). count-desc
    # bound = SUM of the dropped splits' last-returned-bucket counts = 1 + 2 = 3.
    var g = _bound_for(1, 4, 2, 6, AGG_ORDER_COUNT_DESC)
    assert_equal(g.doc_count_error_upper_bound, 3)
    # No double-count: sum_other_doc_count is the per-split dropped TAIL total
    # (4 + 6 = 10), DISTINCT from the error bound (the single smallest-bucket
    # counts). The bound (3) must NOT equal / fold into sum_other (10).
    assert_equal(g.sum_other_doc_count, 10)
    assert_true(g.doc_count_error_upper_bound != g.sum_other_doc_count)


def test_doc_count_error_no_drop_is_zero() raises:
    # Neither split dropped a bucket (last_bucket_doc_count = 0 on both) -> the
    # count-desc bound is 0 even with N splits.
    var g = _bound_for(0, 0, 0, 0, AGG_ORDER_COUNT_DESC)
    assert_equal(g.doc_count_error_upper_bound, 0)


def test_doc_count_error_key_order_is_zero() raises:
    # key-asc: exactly 0 regardless of drops (key order is globally exact).
    var g = _bound_for(1, 4, 2, 6, AGG_ORDER_KEY_ASC)
    assert_equal(g.doc_count_error_upper_bound, 0)


def test_doc_count_error_count_asc_is_minus_one() raises:
    # count-asc: -1 (indeterminate) regardless of drops.
    var g = _bound_for(1, 4, 2, 6, AGG_ORDER_COUNT_ASC)
    assert_equal(g.doc_count_error_upper_bound, -1)


def test_doc_count_error_single_split_is_zero() raises:
    # A single split is 0 by OpenSearch definition (no other shard to miss terms
    # from) — even if that lone split itself truncated (last_bucket_doc_count > 0).
    var ka = List[String]()
    ka.append(String("rock"))
    ka.append(String("pop"))
    var ca = List[Int]()
    ca.append(5)
    ca.append(3)
    var sa = _terms_split_result(String("g"), ka, ca, 3, 4)  # this split dropped.
    var results = Slab[SearchResult].create(1)
    results.append(sa^)
    var base_specs = List[AggSpec]()
    base_specs.append(
        AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), 10,
                AGG_ORDER_COUNT_DESC)
    )
    var merged = merge_agg_results(results^, base_specs)
    var g = _result_by_name(merged, String("g"))
    assert_equal(g.doc_count_error_upper_bound, 0)


def test_doc_count_error_end_to_end_drop() raises:
    # END-TO-END (real leaf truncation, the brief's headline case): split A has 3
    # distinct genres but is asked for shard_size=2, so it DROPS a bucket; the
    # leaf records last_bucket_doc_count. Split B has 2 distinct (no drop).
    # A genres: rock×2, pop×1, jazz×1. count-desc + key-asc tiebreak sorts
    #   [rock(2), jazz(1), pop(1)] -> truncate to 2 -> [rock, jazz]; pop dropped.
    #   last_bucket_doc_count = jazz's count = 1.
    # B genres: rock×1, pop×1 -> 2 distinct, shard_size 2 -> no drop -> 0.
    # count-desc bound = 1 (A) + 0 (B) = 1 (NON-zero).
    var sa = _build_split(
        10,
        [String("alpha"), String("alpha"), String("alpha"), String("alpha")],
        [String("A0"), String("A1"), String("A2"), String("A3")],
        [String("rock"), String("rock"), String("pop"), String("jazz")],
        [Int64(1), Int64(2), Int64(3), Int64(4)],
    )
    var sb = _build_split(
        50,
        [String("alpha"), String("alpha")],
        [String("B0"), String("B1")],
        [String("rock"), String("pop")],
        [Int64(5), Int64(6)],
    )
    var leaf_shard = 2  # the per-split over-fetch the driver applies.
    var specs_a = List[AggSpec]()
    specs_a.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), 10))
    var specs_b = specs_a.copy()
    var ra = _search_split(sa, _q_aggs(specs_a^, leaf_shard))
    var rb = _search_split(sb, _q_aggs(specs_b^, leaf_shard))
    # Sanity: split A truncated (recorded a per-split error contribution).
    var ga = _result_by_name(ra.agg_results, String("g"))
    assert_equal(ga.last_bucket_doc_count, 1)
    var gb = _result_by_name(rb.agg_results, String("g"))
    assert_equal(gb.last_bucket_doc_count, 0)  # B did not drop.
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var base_specs = List[AggSpec]()
    base_specs.append(
        AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), 10,
                AGG_ORDER_COUNT_DESC)
    )
    var merged = merge_agg_results(results^, base_specs)
    var g = _result_by_name(merged, String("g"))
    assert_equal(g.doc_count_error_upper_bound, 1)  # NON-zero, computed.


# =============================================================================
# TEST 7 — merged metric aggs (avg RE-DERIVED, not avg-of-avg; empty-set fidelity).
# =============================================================================
# Split A price=[10,20] (avg 15); split B price=[30,30,60] (avg 40). Naive
# avg-of-avg = (15+40)/2 = 27.5 (WRONG). Correct = (10+20+30+30+60)/5 = 30.
def test_metric_merge_avg_rederived() raises:
    var sa = _build_split(
        10, [String("alpha"), String("alpha")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(10), Int64(20)],
    )
    var sb = _build_split(
        50, [String("alpha"), String("alpha"), String("alpha")],
        [String("B0"), String("B1"), String("B2")],
        [String("x"), String("x"), String("x")],
        [Int64(30), Int64(30), Int64(60)],
    )
    var specs_a = List[AggSpec]()
    specs_a.append(AggSpec(String("av"), AGG_KIND_AVG, String("price")))
    specs_a.append(AggSpec(String("mn"), AGG_KIND_MIN, String("price")))
    specs_a.append(AggSpec(String("mx"), AGG_KIND_MAX, String("price")))
    specs_a.append(AggSpec(String("sm"), AGG_KIND_SUM, String("price")))
    specs_a.append(AggSpec(String("vc"), AGG_KIND_VALUE_COUNT, String("price")))
    var specs_b = specs_a.copy()
    var ra = _search_split(sa, _q_aggs(specs_a^, 0))
    var rb = _search_split(sb, _q_aggs(specs_b^, 0))
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var base_specs = List[AggSpec]()
    base_specs.append(AggSpec(String("av"), AGG_KIND_AVG, String("price")))
    base_specs.append(AggSpec(String("mn"), AGG_KIND_MIN, String("price")))
    base_specs.append(AggSpec(String("mx"), AGG_KIND_MAX, String("price")))
    base_specs.append(AggSpec(String("sm"), AGG_KIND_SUM, String("price")))
    base_specs.append(AggSpec(String("vc"), AGG_KIND_VALUE_COUNT, String("price")))
    var merged = merge_agg_results(results^, base_specs)
    var av = _result_by_name(merged, String("av"))
    var mn = _result_by_name(merged, String("mn"))
    var mx = _result_by_name(merged, String("mx"))
    var sm = _result_by_name(merged, String("sm"))
    var vc = _result_by_name(merged, String("vc"))
    assert_true(av.has_value)
    assert_almost_equal(av.avg(), Float64(30.0))  # NOT 27.5 (avg-of-avg).
    assert_almost_equal(mn.min, Float64(10.0))    # global min.
    assert_almost_equal(mx.max, Float64(60.0))    # global max.
    assert_almost_equal(sm.sum, Float64(150.0))   # global sum.
    assert_equal(vc.count, 5)                      # global value_count.


# =============================================================================
# TEST 8 — empty-set fidelity: no split has a value -> null avg/min/max.
# =============================================================================
# Both splits match ZERO docs -> the metric over an empty matched set.
def test_metric_merge_empty_set() raises:
    var sa = _build_split(
        10, [String("gamma"), String("gamma")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(10), Int64(20)],
    )
    var sb = _build_split(
        50, [String("delta")],
        [String("B0")], [String("x")], [Int64(30)],
    )
    var specs_a = List[AggSpec]()
    specs_a.append(AggSpec(String("av"), AGG_KIND_AVG, String("price")))
    specs_a.append(AggSpec(String("sm"), AGG_KIND_SUM, String("price")))
    specs_a.append(AggSpec(String("vc"), AGG_KIND_VALUE_COUNT, String("price")))
    var specs_b = specs_a.copy()
    var ra = _search_split(sa, _q_aggs(specs_a^, 0))
    var rb = _search_split(sb, _q_aggs(specs_b^, 0))
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var base_specs = List[AggSpec]()
    base_specs.append(AggSpec(String("av"), AGG_KIND_AVG, String("price")))
    base_specs.append(AggSpec(String("sm"), AGG_KIND_SUM, String("price")))
    base_specs.append(AggSpec(String("vc"), AGG_KIND_VALUE_COUNT, String("price")))
    var merged = merge_agg_results(results^, base_specs)
    var av = _result_by_name(merged, String("av"))
    var sm = _result_by_name(merged, String("sm"))
    var vc = _result_by_name(merged, String("vc"))
    assert_false(av.has_value)               # avg/min/max render null.
    assert_equal(vc.count, 0)                # value_count -> 0.
    assert_almost_equal(sm.sum, Float64(0.0))  # sum -> 0.0 (never null).


# =============================================================================
# TEST 9 — shard_size_for over-fetch bound (size*1.5 + 10).
# =============================================================================
def test_shard_size_for() raises:
    assert_equal(shard_size_for(10), 10 * 3 // 2 + 10)  # 25.
    assert_equal(shard_size_for(0), 10)
    assert_equal(shard_size_for(2), 2 * 3 // 2 + 10)    # 13.


# =============================================================================
# TEST 10 — _doc sort across splits honors sort_order with split-order tiebreak.
# =============================================================================
# A=[doc0,doc1], B=[doc0,doc1]. _doc ASC: doc_id 0 (A then B), doc_id 1 (A then
# B) — collision tiebreak on split index.
def test_doc_sort_across_splits() raises:
    var sa = _build_split(
        10, [String("alpha"), String("alpha")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(1), Int64(2)],
    )
    var sb = _build_split(
        50, [String("alpha"), String("alpha")],
        [String("B0"), String("B1")],
        [String("x"), String("x")], [Int64(3), Int64(4)],
    )
    var ra = _search_split(sa, _q_doc_sort(SORT_ASC, 0, 10))
    var rb = _search_split(sb, _q_doc_sort(SORT_ASC, 0, 10))
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var merged = merge_search_results(
        results^, 0, 10, SORT_MODE_DOC, SORT_ASC, MISSING_LAST
    )
    var srcs = _page_sources(merged.result)
    assert_equal(len(srcs), 4)
    assert_equal(srcs[0], String("A0"))  # doc_id 0, split 0.
    assert_equal(srcs[1], String("B0"))  # doc_id 0, split 1.
    assert_equal(srcs[2], String("A1"))  # doc_id 1, split 0.
    assert_equal(srcs[3], String("B1"))  # doc_id 1, split 1.


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

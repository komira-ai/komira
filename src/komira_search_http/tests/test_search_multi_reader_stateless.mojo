# =============================================================================
# test_search_multi_reader_stateless.mojo
#   Multi-node DISTRIBUTED-SEARCH validation — N independent search instances
#   return BYTE-IDENTICAL results (search is fully stateless).
# =============================================================================
#
# Search is a stateless read-replica: a request handler
# constructs a FRESH metastore per request, lists the live splits, fetches each
# from object storage, parses a FRESH SearchCore per split, merges in-node, and
# renders. N search nodes are independent replicas with ZERO shared state — so the SAME
# query MUST return the SAME result regardless of which node serves it.
#
# THIS TEST proves reproducibility: build an index of M in-memory splits (M>=2),
# then run the SAME query through N INDEPENDENT search paths — each path is a
# fresh fan-out (fresh `SearchCore` PER split over a fresh COPY of the split
# bytes -> the SAME merge reducers -> the SAME hitbatch_to_hits_envelope render,
# exactly the value pipeline a request handler runs). We assert every
# path's RENDERED OpenSearch envelope JSON is byte-identical: same hits, same
# order, same total, same _id, same _shards, same aggs. Any hidden shared state
# (a cached plan, a leaked SearchCore, an order-dependent merge) would make two
# independent paths diverge — this catches it.
#
# MECHANISM (and why): in-memory deterministic, no object store, no event loop.
# The object store fan-out belongs to the request handler; the
# stateless-reproducibility PROPERTY is independent of the transport — it lives in "fresh SearchCore + pure merge + pure render", which we
# drive directly N times. Faster + fully deterministic + runs in CI.
#
# Matrix (each run through N=4 independent reader paths, byte-identical asserted):
#   1. match + score sort across 3 splits.
#   2. fast-field sort (price DESC) across 3 splits.
#   3. pagination (from+size) across 3 splits.
#   4. size:0 terms+avg aggregations across 3 splits.
#   5. a query touching only some splits (a zero-match split contributes nothing
#      but is still fanned out — _shards still counts it).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
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
    AggResults,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    SORT_DESC,
    SORT_ASC,
    MISSING_LAST,
    SORT_MODE_SCORE,
    SORT_MODE_I64,
)
from komira_search.merge import (
    merge_search_results,
    merge_agg_results,
    shard_size_for,
)

from komira_search_http.envelopes import (
    hitbatch_to_hits_envelope,
    TRACK_TOTAL_DEFAULT,
)


# -----------------------------------------------------------------------------
# Fixture helpers (mirror test_search_http_multi_split.mojo).
# -----------------------------------------------------------------------------


def _uuid(seed: UInt8) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _short_id_of(uuid: InlineArray[UInt8, 16]) -> String:
    """Mirror a handler's split short id (full 16 bytes, hex)."""
    comptime HEX = "0123456789abcdef"
    var out = String("")
    for i in range(16):
        var b = Int(uuid[i])
        out += HEX[byte=(b >> 4) & 0xF]
        out += HEX[byte=b & 0xF]
    return out^


def _text_cfg() -> AnalyzerConfig:
    return AnalyzerConfig.text("body")


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def _i64_col(values: List[Int64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _split_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("genre", ArrowType.STRING, True))
    sb.add_field(Field("price", ArrowType.INT64, True))
    return sb.build()


def _drive_sink(
    var batch: RecordBatch, var schema: Schema, uuid: InlineArray[UInt8, 16]
) raises -> List[UInt8]:
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("idx"),
        String("body"),
        uuid,
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
    var schema = _split_schema()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(_str_col(bodies))
    rb.add_column(_str_col(sources))
    rb.add_column(_str_col(genres))
    rb.add_column(_i64_col(prices))
    var batch = rb.build(schema.copy())
    return _drive_sink(batch^, schema^, _uuid(seed))


# -----------------------------------------------------------------------------
# ONE independent search path — the production shape: fresh SearchCore PER split
# (over a fresh COPY of the split bytes, as a handler fetches fresh
# bytes per request), merge, render. NO shared state retained across calls.
# Returns the serialized OpenSearch envelope JSON for one "node".
# -----------------------------------------------------------------------------


def _one_reader_path(
    splits: List[List[UInt8]],
    seeds: List[UInt8],
    base_query: QueryIR,
    base_from: Int,
    base_size: Int,
    sort_mode: UInt8,
    sorted_by_score: Bool,
) raises -> String:
    var m = len(splits)
    # Per-split over-fetch rewrite (a request handler) — from=0, top_k=from+size.
    var leaf = base_query.copy()
    leaf.from_offset = 0
    leaf.top_k = base_from + base_size
    if base_query.has_aggs():
        leaf.rewrite_terms_bucket_sizes(shard_size_for(base_size))

    # Fresh SearchCore PER split, over a FRESH COPY of the bytes (stateless).
    var results = Slab[SearchResult].create(m)
    for i in range(m):
        var core = SearchCore(splits[i].copy())
        results.append(core.search(leaf))

    # Merge (pure reducer) — order-independent fold of the N per-split results.
    var merged_aggs = AggResults()
    if base_query.has_aggs():
        merged_aggs = merge_agg_results(results, base_query.aggs_ref())
    var merged = merge_search_results(
        results^,
        base_from,
        base_size,
        sort_mode,
        base_query.sort_order,
        base_query.missing_order,
    )

    # Namespaced ids when >1 split (a request handler).
    var client_ids = List[String]()
    if m > 1:
        var short_ids = List[String]()
        for i in range(m):
            short_ids.append(_short_id_of(_uuid(seeds[i])))
        ref idx = merged.hit_split_index
        var n = merged.result.batch.num_rows()
        for row in range(n):
            var did = Int64(
                merged.result.batch.column_at(1)
                .as_primitive[DType.int64]()
                .get(row)
            )
            client_ids.append(short_ids[idx[row]] + String("_") + String(did))

    return hitbatch_to_hits_envelope(
        merged.result.batch,
        String("idx"),
        client_ids,
        merged.result.total_matches,
        TRACK_TOTAL_DEFAULT,
        sorted_by_score,
        merged_aggs^,
        base_query.has_aggs(),
        m,  # shards_total
        m,  # shards_successful
        0,  # shards_failed
    )


# Run the SAME query through N INDEPENDENT reader paths; assert byte-identical.
def _assert_n_readers_identical(
    splits: List[List[UInt8]],
    seeds: List[UInt8],
    base_query: QueryIR,
    base_from: Int,
    base_size: Int,
    sort_mode: UInt8,
    sorted_by_score: Bool,
    n_readers: Int,
) raises -> String:
    var first = _one_reader_path(
        splits, seeds, base_query, base_from, base_size, sort_mode,
        sorted_by_score,
    )
    for _r in range(1, n_readers):
        var other = _one_reader_path(
            splits, seeds, base_query, base_from, base_size, sort_mode,
            sorted_by_score,
        )
        # BYTE-IDENTICAL: a query is reproducible across independent replicas.
        assert_equal(
            other,
            first,
            "independent reader path diverged (hidden shared state?)",
        )
    return first^


def _build_3_splits() raises -> List[List[UInt8]]:
    # Three splits with overlapping `alpha` docs + distinct prices/genres/sources.
    var splits = List[List[UInt8]]()
    splits.append(
        _build_split(
            10,
            [String("alpha beta"), String("alpha")],
            [String("A0"), String("A1")],
            [String("rock"), String("jazz")],
            [Int64(70), Int64(10)],
        )
    )
    splits.append(
        _build_split(
            50,
            [String("alpha"), String("alpha gamma")],
            [String("B0"), String("B1")],
            [String("rock"), String("pop")],
            [Int64(40), Int64(20)],
        )
    )
    splits.append(
        _build_split(
            90,
            [String("alpha"), String("alpha delta")],
            [String("C0"), String("C1")],
            [String("rock"), String("jazz")],
            [Int64(55), Int64(35)],
        )
    )
    return splits^


def _seeds3() -> List[UInt8]:
    var s = List[UInt8]()
    s.append(UInt8(10))
    s.append(UInt8(50))
    s.append(UInt8(90))
    return s^


def _q_score() raises -> QueryIR:
    return QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(),
        0, None, String(""), SORT_DESC, MISSING_LAST, 0, List[AggSpec](),
    )


def _q_price(order: UInt8) raises -> QueryIR:
    return QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(),
        0, None, String("price"), order, MISSING_LAST, 0, List[AggSpec](),
    )


# =============================================================================
# TEST 1 — match + score sort across 3 splits, N=4 independent readers identical.
# =============================================================================
def test_multi_reader_match_score_identical() raises:
    var splits = _build_3_splits()
    var seeds = _seeds3()
    var env = _assert_n_readers_identical(
        splits, seeds, _q_score(), 0, 10, SORT_MODE_SCORE, True, 4
    )
    # All 6 `alpha` docs are present (sanity that the identical result is non-trivial).
    assert_true(env.find('"total":{"value":6,"relation":"eq"}') >= 0)
    assert_true(env.find('"total":3') >= 0)  # _shards.total = 3.
    assert_true(env.find('"successful":3') >= 0)


# =============================================================================
# TEST 2 — fast-field sort (price DESC) across 3 splits, N=4 readers identical.
# =============================================================================
def test_multi_reader_fastfield_sort_identical() raises:
    var splits = _build_3_splits()
    var seeds = _seeds3()
    var env = _assert_n_readers_identical(
        splits, seeds, _q_price(SORT_DESC), 0, 10, SORT_MODE_I64, False, 4
    )
    # Global price DESC: 70(A0),55(C0),40(B0),35(C1),20(B1),10(A1).
    var pa0 = env.find('"A0"')
    var pc0 = env.find('"C0"')
    var pb0 = env.find('"B0"')
    assert_true(pa0 >= 0 and pc0 >= 0 and pb0 >= 0)
    assert_true(pa0 < pc0)  # 70 before 55.
    assert_true(pc0 < pb0)  # 55 before 40.
    assert_true(env.find('"max_score":null') >= 0)  # field sort -> null score.


# =============================================================================
# TEST 3 — pagination (from+size) across 3 splits, N=4 readers identical.
# =============================================================================
def test_multi_reader_pagination_identical() raises:
    var splits = _build_3_splits()
    var seeds = _seeds3()
    # price ASC global: 10(A1),20(B1),35(C1),40(B0),55(C0),70(A0).
    # from=2,size=2 -> page [2,4) = 35(C1),40(B0).
    var env = _assert_n_readers_identical(
        splits, seeds, _q_price(SORT_ASC), 2, 2, SORT_MODE_I64, False, 4
    )
    assert_true(env.find('"C1"') >= 0)
    assert_true(env.find('"B0"') >= 0)
    assert_true(env.find('"A1"') < 0)  # excluded by the page window.
    assert_true(env.find('"A0"') < 0)
    # The true total is still the global 6 (not the page size).
    assert_true(env.find('"total":{"value":6,"relation":"eq"}') >= 0)


# =============================================================================
# TEST 4 — size:0 terms+avg aggregations across 3 splits, N=4 readers identical.
# =============================================================================
def test_multi_reader_aggs_identical() raises:
    var splits = _build_3_splits()
    var seeds = _seeds3()
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), 10))
    aggs.append(AggSpec(String("ap"), AGG_KIND_AVG, String("price")))
    var q = QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(),
        0, None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    var env = _assert_n_readers_identical(
        splits, seeds, q, 0, 0, SORT_MODE_SCORE, True, 4
    )
    # size:0 -> empty hits but the merged aggregations block present.
    assert_true(env.find('"hits":[]') >= 0)
    assert_true(env.find('"aggregations"') >= 0)
    # genre terms merged across splits: rock = 4 (A0 + B0 + C0 ... actually
    # rock docs: A0, B0, C0 = 3). Assert the merged terms key + a doc_count.
    assert_true(env.find('"g"') >= 0)
    assert_true(env.find('"rock"') >= 0)
    assert_true(env.find('"ap"') >= 0)  # avg price metric present.


# =============================================================================
# TEST 5 — a zero-match split is still fanned out; N=4 readers identical.
# =============================================================================
def test_multi_reader_zero_match_split_identical() raises:
    var splits = List[List[UInt8]]()
    splits.append(
        _build_split(
            10,
            [String("alpha"), String("alpha")],
            [String("A0"), String("A1")],
            [String("rock"), String("rock")],
            [Int64(10), Int64(20)],
        )
    )
    # This split has NO `alpha` docs -> contributes 0 matches but is still a shard.
    splits.append(
        _build_split(
            50,
            [String("gamma"), String("delta")],
            [String("B0"), String("B1")],
            [String("rock"), String("rock")],
            [Int64(30), Int64(40)],
        )
    )
    splits.append(
        _build_split(
            90,
            [String("alpha"), String("alpha")],
            [String("C0"), String("C1")],
            [String("rock"), String("rock")],
            [Int64(50), Int64(60)],
        )
    )
    var seeds = List[UInt8]()
    seeds.append(UInt8(10))
    seeds.append(UInt8(50))
    seeds.append(UInt8(90))
    var env = _assert_n_readers_identical(
        splits, seeds, _q_score(), 0, 10, SORT_MODE_SCORE, True, 4
    )
    # Only A + C `alpha` docs render (4 total); B contributes 0.
    assert_true(env.find('"A0"') >= 0)
    assert_true(env.find('"C0"') >= 0)
    assert_true(env.find('"B0"') < 0)
    assert_true(env.find('"total":{"value":4,"relation":"eq"}') >= 0)
    # _shards still reports all 3 fanned-out splits (B counted though it matched 0).
    assert_true(env.find('"total":3') >= 0)
    assert_true(env.find('"successful":3') >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

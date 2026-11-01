# =============================================================================
# test_search_http_multi_split.mojo — P1.5 shim/merge e2e units
# =============================================================================
#
# Shim/driver-level units over MULTIPLE in-memory splits (built by the P0.4
# writer, no network). Following the style of the other suites here,
# these drive the value pipeline a search request handler runs — build N split
# blobs -> SearchCore per split (with the per-split over-fetch rewrite) -> the
# komira_search merge reducers -> hitbatch_to_hits_envelope with the real
# `_shards{total,successful,failed}` counts + the namespaced cross-split
# `client_ids` — and assert the RENDERED OpenSearch envelope JSON. (Fetching
# the splits from object storage is an end-to-end test's concern; this proves
# everything else.)
#
# Covers:
#   1. merged hits + global total + real _shards{total:2,successful:2,failed:0}
#      + namespaced _id rendered across 2 splits.
#   2. pagination (from+size) across splits via the rendered page.
#   3. fast-field sort across splits (the per-row sort-key surface).
#   4. size:0 aggs-only over 2 splits -> empty hits + merged aggregations.
#   5. a split with zero matches.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
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
# Fixture helpers.
# -----------------------------------------------------------------------------


def _uuid(seed: UInt8) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _short_id(seed: UInt8) -> String:
    """Mirror a handler's split short id over the same _uuid(seed) the split
    carries (full 16 uuid bytes, hex — see the BUGFIX note on
    a handler's split short id; the prior 4-byte prefix collided on same-run
    UUIDv7 timestamp heads)."""
    return _short_id_of(_uuid(seed))


def _short_id_of(uuid: InlineArray[UInt8, 16]) -> String:
    """Mirror a handler's split short id over an arbitrary 16-byte UUID (full 16
    bytes, hex)."""
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
        String("bucket"), String("prefix"), String("idx"),
        String("body"), uuid,
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _build_split_uuid(
    uuid: InlineArray[UInt8, 16],
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
    return _drive_sink(batch^, schema^, uuid)


def _build_split(
    seed: UInt8,
    bodies: List[String],
    sources: List[String],
    genres: List[String],
    prices: List[Int64],
) raises -> List[UInt8]:
    return _build_split_uuid(_uuid(seed), bodies, sources, genres, prices)


def _search_split(bytes: List[UInt8], query: QueryIR) raises -> SearchResult:
    var core = SearchCore(bytes.copy())
    return core.search(query)


# Render the merged 2-split result the SAME way a request handler does:
# over-fetch each split, merge, then hitbatch_to_hits_envelope with real shard
# counts + namespaced ids. Returns the serialized envelope JSON.
def _render_two_split_uuid(
    sa: List[UInt8],
    sb: List[UInt8],
    uuid_a: InlineArray[UInt8, 16],
    uuid_b: InlineArray[UInt8, 16],
    base_query: QueryIR,
    base_from: Int,
    base_size: Int,
    sort_mode: UInt8,
    sorted_by_score: Bool,
) raises -> String:
    var leaf = base_query.copy()
    leaf.from_offset = 0
    leaf.top_k = base_from + base_size
    if base_query.has_aggs():
        leaf.rewrite_terms_bucket_sizes(shard_size_for(base_size))
    var ra = _search_split(sa, leaf)
    var rb = _search_split(sb, leaf)
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var merged_aggs = AggResults()
    if base_query.has_aggs():
        merged_aggs = merge_agg_results(results, base_query.aggs_ref())
    var merged = merge_search_results(
        results^, base_from, base_size, sort_mode,
        base_query.sort_order, base_query.missing_order,
    )
    # Build namespaced ids exactly like the driver (2 splits -> namespaced).
    var short_ids = List[String]()
    short_ids.append(_short_id_of(uuid_a))
    short_ids.append(_short_id_of(uuid_b))
    var client_ids = List[String]()
    ref idx = merged.hit_split_index
    var n = merged.result.batch.num_rows()
    for row in range(n):
        var did = Int64(
            merged.result.batch.column_at(1).as_primitive[DType.int64]().get(row)
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
        2,  # shards_total
        2,  # shards_successful
        0,  # shards_failed
    )


def _render_two_split(
    sa: List[UInt8],
    sb: List[UInt8],
    seed_a: UInt8,
    seed_b: UInt8,
    base_query: QueryIR,
    base_from: Int,
    base_size: Int,
    sort_mode: UInt8,
    sorted_by_score: Bool,
) raises -> String:
    var leaf = base_query.copy()
    leaf.from_offset = 0
    leaf.top_k = base_from + base_size
    if base_query.has_aggs():
        leaf.rewrite_terms_bucket_sizes(shard_size_for(base_size))
    var ra = _search_split(sa, leaf)
    var rb = _search_split(sb, leaf)
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    var merged_aggs = AggResults()
    if base_query.has_aggs():
        merged_aggs = merge_agg_results(results, base_query.aggs_ref())
    var merged = merge_search_results(
        results^, base_from, base_size, sort_mode,
        base_query.sort_order, base_query.missing_order,
    )
    # Build namespaced ids exactly like the driver (2 splits -> namespaced).
    var short_ids = List[String]()
    short_ids.append(_short_id(seed_a))
    short_ids.append(_short_id(seed_b))
    var client_ids = List[String]()
    ref idx = merged.hit_split_index
    var n = merged.result.batch.num_rows()
    for row in range(n):
        var did = Int64(
            merged.result.batch.column_at(1).as_primitive[DType.int64]().get(row)
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
        2,  # shards_total
        2,  # shards_successful
        0,  # shards_failed
    )


def _q_price(order: UInt8) raises -> QueryIR:
    return QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(),
        0, None, String("price"), order, MISSING_LAST, 0, List[AggSpec](),
    )


def _q_score() raises -> QueryIR:
    return QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(),
        0, None, String(""), SORT_DESC, MISSING_LAST, 0, List[AggSpec](),
    )


# =============================================================================
# TEST 1 — merged hits + global total + real _shards + namespaced _id.
# =============================================================================
def test_merged_envelope_shards_and_namespaced_id() raises:
    var sa = _build_split(
        10, [String("alpha"), String("alpha")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(10), Int64(30)],
    )
    var sb = _build_split(
        50, [String("alpha"), String("alpha")],
        [String("B0"), String("B1")],
        [String("x"), String("x")], [Int64(20), Int64(40)],
    )
    var env = _render_two_split(
        sa, sb, 10, 50, _q_price(SORT_ASC), 0, 10, SORT_MODE_I64, False
    )
    # Real _shards counts (not the static {1,1,0,0}).
    assert_true(env.find('"total":2') >= 0)
    assert_true(env.find('"successful":2') >= 0)
    assert_true(env.find('"failed":0') >= 0)
    # Global total = 4 matched docs across the 2 splits.
    assert_true(env.find('"total":{"value":4,"relation":"eq"}') >= 0)
    # Namespaced _id disambiguates the cross-split doc-id collision: split A's
    # doc0 and split B's doc0 are <shortA>_0 and <shortB>_0 (distinct).
    var sha = _short_id(10)
    var shb = _short_id(50)
    assert_true(env.find('"_id":"' + sha + '_0"') >= 0)
    assert_true(env.find('"_id":"' + shb + '_0"') >= 0)
    assert_false(sha == shb)
    # The merged page carries all 4 sources.
    assert_true(env.find('"A0"') >= 0)
    assert_true(env.find('"B0"') >= 0)


# =============================================================================
# TEST 1b — REGRESSION: two splits minted in the SAME ingest
# run share their UUIDv7 TIMESTAMP head (bytes[0..6) = unix_ts_ms, big-endian)
# and differ only in the LOW entropy bytes. The prior 4-byte `_split_short_id`
# prefix took only the timestamp head, so doc 0 of BOTH splits rendered the
# IDENTICAL `_id` (observed `019eacbb_0`) — conflating two distinct docs for any
# OpenSearch client that addresses/dedups by `_id`. The fix spans the FULL 16-byte
# UUID, so the entropy in the low bytes makes the prefix cross-split-unique.
#
# This fixture models the REAL collision the seed-based `_uuid(seed)` helper does
# NOT (varying the seed varies byte[0], which the live generator never does for
# same-run UUIDs). It asserts the two splits' `_id` PREFIXES are DISTINCT. With
# the buggy 4-byte prefix `_short_id_of` returns the same 8 hex chars for both
# UUIDs and this FAILS; with the full-16-byte prefix it PASSES.
# =============================================================================
def test_same_run_uuid_id_collision_regression() raises:
    # Two UUIDv7-shaped ids minted milliseconds apart in one ingest run: the
    # first 6 bytes (unix_ts_ms) are IDENTICAL; only the entropy (bytes[6..16))
    # differs (here bytes[6..8) carry ver|rand_a seq, bytes[8..16) carry rand_b).
    var ua = InlineArray[UInt8, 16](fill=0)
    var ub = InlineArray[UInt8, 16](fill=0)
    # Shared timestamp head: 01 9e ac bb 12 34 (== observed `019eacbb...`).
    var ts = [
        UInt8(0x01), UInt8(0x9e), UInt8(0xac), UInt8(0xbb),
        UInt8(0x12), UInt8(0x34),
    ]
    for i in range(6):
        ua[i] = ts[i]
        ub[i] = ts[i]
    # Diverge only in the entropy tail (what the live generator actually varies).
    for i in range(6, 16):
        ua[i] = UInt8(0xA0 + (i - 6))
        ub[i] = UInt8(0xB0 + (i - 6))

    # Sanity: the BUGGY 4-byte prefix WOULD collide (both heads are `019eacbb`).
    var buggy_a = String("")
    var buggy_b = String("")
    comptime HEX = "0123456789abcdef"
    for i in range(4):
        buggy_a += HEX[byte=(Int(ua[i]) >> 4) & 0xF] + HEX[byte=Int(ua[i]) & 0xF]
        buggy_b += HEX[byte=(Int(ub[i]) >> 4) & 0xF] + HEX[byte=Int(ub[i]) & 0xF]
    assert_equal(buggy_a, String("019eacbb"))
    assert_equal(buggy_b, String("019eacbb"))  # SAME -> the old collision.

    var sa = _build_split_uuid(
        ua, [String("alpha"), String("alpha")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(10), Int64(30)],
    )
    var sb = _build_split_uuid(
        ub, [String("alpha"), String("alpha")],
        [String("B0"), String("B1")],
        [String("x"), String("x")], [Int64(20), Int64(40)],
    )
    var env = _render_two_split_uuid(
        sa, sb, ua, ub, _q_price(SORT_ASC), 0, 10, SORT_MODE_I64, False
    )
    # The fixed prefix spans all 16 bytes -> distinct.
    var sha = _short_id_of(ua)
    var shb = _short_id_of(ub)
    assert_false(sha == shb)  # the core regression assertion.
    # Both doc-0 `_id`s appear in the envelope and are DISTINCT (no `019eacbb_0`
    # collision: the full-UUID prefix disambiguates the two same-run docs).
    assert_true(env.find('"_id":"' + sha + '_0"') >= 0)
    assert_true(env.find('"_id":"' + shb + '_0"') >= 0)
    # The buggy `019eacbb_0` MUST NOT appear (it would conflate A0 and B0).
    assert_true(env.find('"_id":"019eacbb_0"') < 0)
    # All 4 distinct docs render.
    assert_true(env.find('"A0"') >= 0)
    assert_true(env.find('"B0"') >= 0)


# =============================================================================
# TEST 2 — pagination (from+size) across splits via the rendered page.
# =============================================================================
# Global price-ASC over A=[15,55],B=[25,45]: 15(A0),25(B0),45(B1),55(A1).
# from=1,size=2 -> page [1,3) = 25(B0),45(B1).
def test_pagination_rendered() raises:
    var sa = _build_split(
        10, [String("alpha"), String("alpha")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(15), Int64(55)],
    )
    var sb = _build_split(
        50, [String("alpha"), String("alpha")],
        [String("B0"), String("B1")],
        [String("x"), String("x")], [Int64(25), Int64(45)],
    )
    var env = _render_two_split(
        sa, sb, 10, 50, _q_price(SORT_ASC), 1, 2, SORT_MODE_I64, False
    )
    # The page is the GLOBAL [1,3) slice: B0(25), B1(45). A0/A1 excluded.
    assert_true(env.find('"B0"') >= 0)
    assert_true(env.find('"B1"') >= 0)
    assert_true(env.find('"A0"') < 0)
    assert_true(env.find('"A1"') < 0)
    # The true total is still the global 4 (not the page size).
    assert_true(env.find('"total":{"value":4,"relation":"eq"}') >= 0)


# =============================================================================
# TEST 3 — fast-field sort across splits (the per-row sort-key surface).
# =============================================================================
def test_fastfield_sort_rendered() raises:
    var sa = _build_split(
        10, [String("alpha"), String("alpha")],
        [String("A0"), String("A1")],
        [String("x"), String("x")], [Int64(70), Int64(10)],
    )
    var sb = _build_split(
        50, [String("alpha"), String("alpha")],
        [String("B0"), String("B1")],
        [String("x"), String("x")], [Int64(40), Int64(20)],
    )
    # price DESC global: 70(A0),40(B0),20(B1),10(A1). The rendered hits[] order
    # must be exactly that — verify A0 appears before B0 in the JSON.
    var env = _render_two_split(
        sa, sb, 10, 50, _q_price(SORT_DESC), 0, 10, SORT_MODE_I64, False
    )
    var pa0 = env.find('"A0"')
    var pb0 = env.find('"B0"')
    var pb1 = env.find('"B1"')
    var pa1 = env.find('"A1"')
    assert_true(pa0 >= 0 and pb0 >= 0 and pb1 >= 0 and pa1 >= 0)
    assert_true(pa0 < pb0)  # 70 before 40.
    assert_true(pb0 < pb1)  # 40 before 20.
    assert_true(pb1 < pa1)  # 20 before 10.
    # max_score is null under a field sort.
    assert_true(env.find('"max_score":null') >= 0)


# =============================================================================
# TEST 4 — size:0 aggs-only over 2 splits -> empty hits + merged aggregations.
# =============================================================================
def test_size0_aggs_rendered() raises:
    var sa = _build_split(
        10,
        [String("alpha"), String("alpha"), String("alpha")],
        [String("A0"), String("A1"), String("A2")],
        [String("rock"), String("rock"), String("jazz")],
        [Int64(10), Int64(20), Int64(30)],
    )
    var sb = _build_split(
        50,
        [String("alpha"), String("alpha")],
        [String("B0"), String("B1")],
        [String("rock"), String("pop")],
        [Int64(40), Int64(60)],
    )
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), 10))
    aggs.append(AggSpec(String("ap"), AGG_KIND_AVG, String("price")))
    var q = QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(),
        0, None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    var env = _render_two_split(
        sa, sb, 10, 50, q, 0, 0, SORT_MODE_SCORE, True
    )
    # Empty hits page (size 0) but the aggregations block present + merged.
    assert_true(env.find('"hits":[]') >= 0)
    assert_true(env.find('"aggregations"') >= 0)
    # terms genre merged: rock=3 (2 from A + 1 from B).
    assert_true(env.find('"g"') >= 0)
    assert_true(env.find('"rock"') >= 0)
    assert_true(env.find('"doc_count":3') >= 0)  # rock summed across splits.
    # avg price re-derived from merged sum/count: (10+20+30+40+60)/5 = 32.
    assert_true(env.find('"ap"') >= 0)
    # doc_count_error_upper_bound: NEITHER split dropped a bucket (each has <=2
    # distinct genres, well under shard_size), so the count-desc bound is 0 — the
    # correct value here, NOT a hardcoded literal. The computed NON-zero bound (a
    # split that DOES drop a bucket) is exercised by test_multi_split_render_doc_count_error.
    assert_true(env.find('"doc_count_error_upper_bound":0') >= 0)


# =============================================================================
# TEST 4b — RENDERED non-zero doc_count_error_upper_bound (§5.2 +
# amendment E): a split that DROPS a bucket past its over-fetch makes the merged
# count-desc bound NON-zero, and the renderer emits the computed value (not a
# hardcoded 0). Drives the SAME merge_agg_results -> hitbatch_to_hits_envelope
# render path the driver runs, with a tiny per-split shard_size to force the drop.
# =============================================================================
def test_multi_split_render_doc_count_error() raises:
    # Split A: 3 distinct genres (rock×2, pop×1, jazz×1); over-fetched to
    # shard_size=2 -> count-desc + key-asc tiebreak keeps [rock(2), jazz(1)],
    # DROPS pop -> last_bucket_doc_count = jazz = 1.
    # Split B: 2 distinct (rock×1, pop×1), shard_size 2 -> no drop -> 0.
    # Merged count-desc bound = 1 + 0 = 1 (rendered non-zero).
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
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), 10))
    var base_query = QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(),
        0, None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    # Per-split over-fetch with a TINY shard_size (2) so split A truncates.
    var leaf = base_query.copy()
    leaf.rewrite_terms_bucket_sizes(2)
    var ra = _search_split(sa, leaf)
    var rb = _search_split(sb, leaf)
    var results = Slab[SearchResult].create(2)
    results.append(ra^)
    results.append(rb^)
    # The ORIGINAL spec (base_size 10) drives the coordinator re-trim.
    var merged_aggs = merge_agg_results(results, base_query.aggs_ref())
    var empty_ids = List[String]()
    var env = hitbatch_to_hits_envelope(
        results[0].batch,  # any (size:0 page) batch — aggs are the subject here.
        String("idx"),
        empty_ids,
        0,
        TRACK_TOTAL_DEFAULT,
        True,
        merged_aggs^,
        True,   # has_aggs
        2, 2, 0,  # shards total/successful/failed
    )
    # The renderer emits the COMPUTED bound (1), not a hardcoded 0.
    assert_true(env.find('"doc_count_error_upper_bound":1') >= 0)
    # rock summed across splits = 3 (2 from A + 1 from B).
    assert_true(env.find('"rock"') >= 0)
    assert_true(env.find('"doc_count":3') >= 0)


# =============================================================================
# TEST 5 — a split with zero matches contributes nothing to the rendered result.
# =============================================================================
def test_zero_match_split_rendered() raises:
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
    var env = _render_two_split(
        sa, sb, 10, 50, _q_score(), 0, 10, SORT_MODE_SCORE, True
    )
    # Only A's 2 docs render; total = 2 (B contributes 0).
    assert_true(env.find('"A0"') >= 0)
    assert_true(env.find('"A1"') >= 0)
    assert_true(env.find('"B0"') < 0)
    assert_true(env.find('"total":{"value":2,"relation":"eq"}') >= 0)
    # _shards still reports the 2 fanned-out splits.
    assert_true(env.find('"total":2') >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

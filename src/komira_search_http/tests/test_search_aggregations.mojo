# =============================================================================
# test_search_aggregations.mojo — P1.4 AGGREGATIONS proof
# =============================================================================
#
# Engine-side unit suite over an IN-MEMORY split built by the P0.4 writer
# (SearchSink) + the P1.1 fast-fields, no network. Mirrors the P1.2/P1.3
# test style. Covers (engine half):
#
#   1.  metric avg/min/max/sum/value_count over a numeric field — exact, nulls
#       skipped (value_count < row count when nulls present).
#   2.  stats — all five values from one pass match the individual metrics.
#   3.  M1 (raise-trap) — a metric over a FLOAT fast-field does NOT raise (would
#       raise without the encoding-resolve dispatch).
#   4.  empty matched set (m3) — sum=0.0, value_count=0, avg/min/max=null
#       (has_value False), stats zeroed.
#   5.  terms keyword — exact buckets + doc_count; default _count desc; size
#       truncation; EXACT sum_other_doc_count; doc_count_error_upper_bound==0.
#   6.  terms order _key:asc / min_doc_count / missing toggles.
#   7.  terms numeric key stringification.
#   8.  B1 match-all-for-aggs — aggs over the whole split with NO query term.
#   9.  size:0 aggs-only — 0 hits, full-set aggs.
#   10. aggs + P1.2 filter — aggs over the FILTERED set.
#   11. aggs + P1.3 sort/from/size — aggs unaffected by the page.
#   (Case 12, the M2 fingerprint distinctness of a Searcher, runs with the
#   search runtime package, which this package's tests do not depend on.)
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
    assert_not_equal,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import Expr, BIN_GE
from komira_plan_expr.scalar_value import ScalarValue
from std.sys import size_of

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.source import (
    QueryIR,
    SearchCore,
    SearchResult,
    AggSpec,
    AggResult,
    AggResults,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    AGG_KIND_MIN,
    AGG_KIND_MAX,
    AGG_KIND_SUM,
    AGG_KIND_VALUE_COUNT,
    AGG_KIND_STATS,
    AGG_ORDER_COUNT_DESC,
    AGG_ORDER_KEY_ASC,
    SORT_DESC,
    SORT_ASC,
    MISSING_LAST,
)

from komira_search.split import SplitView
from komira_search.fast_fields import FastFieldReader
from komira_search_http.search_query import search_json_to_queryir
from komira_search_http.search_gates import gate_aggs_against_fastfields
from komira_search_http.envelopes import (
    agg_results_to_aggregations_object,
    hitbatch_to_hits_envelope,
    empty_hits_envelope,
    TRACK_TOTAL_DEFAULT,
)

from std.testing import assert_raises


# -----------------------------------------------------------------------------
# Fixture helpers (mirror test_search_sort_pagination).
# -----------------------------------------------------------------------------


def _uuid(seed: UInt8) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=0)
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


def _i64_col_nullable(
    raw: List[Int64], null_idx: List[Int]
) raises -> Column[HeapRegion]:
    var n = len(raw)
    comptime es = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * es)
    for i in range(n):
        buf.set_typed[Scalar[DType.int64]](i, raw[i])
    buf.set_length(Int64(n * es))
    var validity = Bitmap.create_all_valid(n)
    for k in range(len(null_idx)):
        validity.clear(null_idx[k])
    var arr = PrimitiveArray[DType.int64](
        buf^, n, Optional[Bitmap[HeapRegion]](validity^), len(null_idx), 0
    )
    return Column.from_primitive[DType.int64](arr)


def _str_col_nullable(
    values: List[String], valid: List[Bool]
) raises -> Column[HeapRegion]:
    return Column.from_string(
        StringArray.from_strings_with_validity(values, valid)
    )


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


# The standard fixture: 6 docs, all containing "alpha" once.
#   _source = "d<i>".
#   genre KEYWORD; price INT64 (with one NULL); score FLOAT64.
#   doc0: genre="rock"        price=100  score=4.5
#   doc1: genre="electronic"  price=50   score=1.5
#   doc2: genre="rock"        price=NULL score=3.5   <- null price
#   doc3: genre="electronic"  price=100  score=2.5
#   doc4: genre="electronic"  price=200  score=5.5
#   doc5: genre="jazz"        price=100  score=0.5
def _fixture_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("genre", ArrowType.STRING, True))  # keyword
    sb.add_field(Field("price", ArrowType.INT64, True))
    sb.add_field(Field("score", ArrowType.FLOAT64, True))
    return sb.build()


def _build_fixture(seed: UInt8) raises -> List[UInt8]:
    var schema = _fixture_schema()
    var rb = RecordBatchBuilder.with_capacity(5)
    rb.add_column(_str_col([
        String("alpha"), String("alpha"), String("alpha"),
        String("alpha"), String("alpha"), String("alpha"),
    ]))
    rb.add_column(_str_col([
        String("d0"), String("d1"), String("d2"),
        String("d3"), String("d4"), String("d5"),
    ]))
    rb.add_column(_str_col([
        String("rock"), String("electronic"), String("rock"),
        String("electronic"), String("electronic"), String("jazz"),
    ]))
    # price: doc2 is NULL.
    rb.add_column(_i64_col_nullable(
        [Int64(100), Int64(50), Int64(0), Int64(100), Int64(200), Int64(100)],
        [2],
    ))
    rb.add_column(_f64_col([
        Float64(4.5), Float64(1.5), Float64(3.5),
        Float64(2.5), Float64(5.5), Float64(0.5),
    ]))
    var batch = rb.build(schema.copy())
    return _drive_sink(batch^, schema^, seed)


# -----------------------------------------------------------------------------
# QueryIR builders.
# -----------------------------------------------------------------------------


def _metric(name: String, kind: UInt8, field: String) -> AggSpec:
    return AggSpec(name, kind, field)


def _q_match_aggs(var aggs: List[AggSpec]) raises -> QueryIR:
    """A match("alpha") QueryIR carrying `aggs` (matches all 6 docs)."""
    return QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )


def _q_noterm_aggs(var aggs: List[AggSpec]) raises -> QueryIR:
    """B1: a NO-query-term QueryIR carrying `aggs` (match-all-for-aggs). The
    query_text is empty -> analyze_text yields zero tokens -> empty `terms` ->
    the B1 match-all path populates the whole split."""
    return QueryIR(
        String("body"), String(""), 0, _text_cfg(), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )


# -----------------------------------------------------------------------------
# AggResult lookup by name.
# -----------------------------------------------------------------------------


def _result_by_name(res: AggResults, name: String) raises -> AggResult:
    for i in range(len(res.results)):
        if res.results[i].name == name:
            return res.results[i].copy()
    raise Error("no agg result named '" + name + "'")


# =============================================================================
# Case 1 — metric avg/min/max/sum/value_count over a numeric field (nulls skip).
# =============================================================================


def test_01_metric_numeric_exact_nulls_skipped() raises:
    var bytes = _build_fixture(1)
    var core = SearchCore(bytes^)
    # prices: 100,50,NULL,100,200,100 -> 5 non-null cells, sum=550, min=50,
    # max=200, avg=110, value_count=5 (doc2 null is skipped, NOT 6).
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("a"), AGG_KIND_AVG, String("price")))
    aggs.append(_metric(String("mn"), AGG_KIND_MIN, String("price")))
    aggs.append(_metric(String("mx"), AGG_KIND_MAX, String("price")))
    aggs.append(_metric(String("s"), AGG_KIND_SUM, String("price")))
    aggs.append(_metric(String("vc"), AGG_KIND_VALUE_COUNT, String("price")))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()

    var a = _result_by_name(ar, String("a"))
    assert_true(a.has_value, "1: avg present")
    assert_almost_equal(a.avg(), 110.0, msg="1: avg=110")
    var mn = _result_by_name(ar, String("mn"))
    assert_almost_equal(mn.min, 50.0, msg="1: min=50")
    var mx = _result_by_name(ar, String("mx"))
    assert_almost_equal(mx.max, 200.0, msg="1: max=200")
    var s = _result_by_name(ar, String("s"))
    assert_almost_equal(s.sum, 550.0, msg="1: sum=550")
    var vc = _result_by_name(ar, String("vc"))
    assert_equal(vc.count, 5, "1: value_count=5 (null skipped, not 6)")


# =============================================================================
# Case 2 — stats: all five from one pass match the individual metrics.
# =============================================================================


def test_02_stats_five_values() raises:
    var bytes = _build_fixture(2)
    var core = SearchCore(bytes^)
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("st"), AGG_KIND_STATS, String("price")))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var st = _result_by_name(ar, String("st"))
    assert_equal(st.count, 5, "2: stats count=5")
    assert_almost_equal(st.min, 50.0, msg="2: stats min=50")
    assert_almost_equal(st.max, 200.0, msg="2: stats max=200")
    assert_almost_equal(st.sum, 550.0, msg="2: stats sum=550")
    assert_almost_equal(st.avg(), 110.0, msg="2: stats avg=110")


# =============================================================================
# Case 3 — M1 raise-trap: a metric over a FLOAT field does NOT raise.
# =============================================================================


def test_03_M1_metric_over_float_field_no_raise() raises:
    var bytes = _build_fixture(3)
    var core = SearchCore(bytes^)
    # `score` is FLOAT64. Without the M1 encoding-resolve dispatch the agg pass
    # would call fast_field_i64 on a float field, which RAISES (fast_fields:966).
    # scores: 4.5,1.5,3.5,2.5,5.5,0.5 -> sum=18.0, min=0.5, max=5.5, avg=3.0.
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("a"), AGG_KIND_AVG, String("score")))
    aggs.append(_metric(String("mn"), AGG_KIND_MIN, String("score")))
    aggs.append(_metric(String("mx"), AGG_KIND_MAX, String("score")))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var a = _result_by_name(ar, String("a"))
    assert_almost_equal(a.avg(), 3.0, msg="3: float avg=3.0")
    var mn = _result_by_name(ar, String("mn"))
    assert_almost_equal(mn.min, 0.5, msg="3: float min=0.5")
    var mx = _result_by_name(ar, String("mx"))
    assert_almost_equal(mx.max, 5.5, msg="3: float max=5.5")


# =============================================================================
# Case 4 — empty matched set (m3): sum=0, vc=0, avg/min/max null, stats zeroed.
# =============================================================================


def test_04_m3_empty_matched_set() raises:
    var bytes = _build_fixture(4)
    var core = SearchCore(bytes^)
    # A query term that matches NOTHING -> empty touched -> aggs over zero docs.
    # (This is NOT B1: query_text is non-empty, so the B1 match-all path does
    # NOT fire — empty touched stays empty.)
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("s"), AGG_KIND_SUM, String("price")))
    aggs.append(_metric(String("vc"), AGG_KIND_VALUE_COUNT, String("price")))
    aggs.append(_metric(String("a"), AGG_KIND_AVG, String("price")))
    aggs.append(_metric(String("st"), AGG_KIND_STATS, String("price")))
    var q = QueryIR(
        String("body"), String("zzznomatch"), 10, _text_cfg(), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    var result = core.search(q)
    assert_equal(result.total_matches, 0, "4: zero matches")
    var ar = result.take_aggs()
    var s = _result_by_name(ar, String("s"))
    assert_almost_equal(s.sum, 0.0, msg="4: sum=0 (never null)")
    var vc = _result_by_name(ar, String("vc"))
    assert_equal(vc.count, 0, "4: value_count=0 (never null)")
    var a = _result_by_name(ar, String("a"))
    assert_false(a.has_value, "4: avg null (has_value False)")
    var st = _result_by_name(ar, String("st"))
    assert_equal(st.count, 0, "4: stats count=0")
    assert_false(st.has_value, "4: stats min/max/avg null")
    assert_almost_equal(st.sum, 0.0, msg="4: stats sum=0")


# =============================================================================
# Case 5 — terms keyword: exact buckets + doc_count, default _count desc,
#          size truncation, EXACT sum_other_doc_count.
# =============================================================================


def test_05_terms_keyword_default() raises:
    var bytes = _build_fixture(5)
    var core = SearchCore(bytes^)
    # genres: rock(d0,d2)=2, electronic(d1,d3,d4)=3, jazz(d5)=1.
    # default _count desc -> electronic(3), rock(2), jazz(1).
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre")))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var g = _result_by_name(ar, String("g"))
    assert_equal(len(g.buckets), 3, "5: 3 buckets")
    assert_equal(g.buckets[0].key, String("electronic"), "5: top=electronic")
    assert_equal(g.buckets[0].doc_count, 3, "5: electronic=3")
    assert_equal(g.buckets[1].key, String("rock"), "5: 2nd=rock")
    assert_equal(g.buckets[1].doc_count, 2, "5: rock=2")
    assert_equal(g.buckets[2].key, String("jazz"), "5: 3rd=jazz")
    assert_equal(g.buckets[2].doc_count, 1, "5: jazz=1")
    assert_equal(g.sum_other_doc_count, 0, "5: no dropped tail")

    # size=2 truncation -> electronic(3),rock(2); other = jazz(1).
    var aggs2 = List[AggSpec]()
    aggs2.append(AggSpec(
        String("g"), AGG_KIND_TERMS, String("genre"), 2,
        AGG_ORDER_COUNT_DESC, 1, String(""),
    ))
    var result2 = core.search(_q_match_aggs(aggs2^))
    var ar2 = result2.take_aggs()
    var g2 = _result_by_name(ar2, String("g"))
    assert_equal(len(g2.buckets), 2, "5: size=2 -> 2 buckets")
    assert_equal(g2.sum_other_doc_count, 1, "5: EXACT other=1 (jazz dropped)")


# =============================================================================
# Case 6 — terms order _key:asc / min_doc_count / missing toggles.
# =============================================================================


def test_06_terms_order_key_asc() raises:
    var bytes = _build_fixture(6)
    var core = SearchCore(bytes^)
    # _key asc -> electronic, jazz, rock (byte order).
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(
        String("g"), AGG_KIND_TERMS, String("genre"), 10,
        AGG_ORDER_KEY_ASC, 1, String(""),
    ))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var g = _result_by_name(ar, String("g"))
    assert_equal(g.buckets[0].key, String("electronic"), "6: _key asc 1st")
    assert_equal(g.buckets[1].key, String("jazz"), "6: _key asc 2nd")
    assert_equal(g.buckets[2].key, String("rock"), "6: _key asc 3rd")


def test_06b_terms_min_doc_count() raises:
    var bytes = _build_fixture(7)
    var core = SearchCore(bytes^)
    # min_doc_count=2 -> drop jazz(1); electronic(3),rock(2) remain.
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(
        String("g"), AGG_KIND_TERMS, String("genre"), 10,
        AGG_ORDER_COUNT_DESC, 2, String(""),
    ))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var g = _result_by_name(ar, String("g"))
    assert_equal(len(g.buckets), 2, "6b: min_doc_count=2 drops jazz")
    # The dropped jazz(1) does NOT count toward sum_other_doc_count (min_doc_count
    # filters BEFORE truncation; only size-truncation feeds other).
    assert_equal(g.sum_other_doc_count, 0, "6b: no size-truncation tail")


# =============================================================================
# Case 7 — terms numeric key stringification.
# =============================================================================


def test_07_terms_numeric_key() raises:
    var bytes = _build_fixture(8)
    var core = SearchCore(bytes^)
    # price: 100(d0),50(d1),NULL(d2),100(d3),200(d4),100(d5).
    # non-null buckets: "100"(d0,d3,d5)=3, "50"(d1)=1, "200"(d4)=1; null dropped
    # (no `missing`). _count desc -> "100"(3), then "50"/"200" tie -> _key asc
    # tiebreak -> "200" < "50" (byte order: '2' < '5') -> "200" then "50".
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("p"), AGG_KIND_TERMS, String("price")))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var p = _result_by_name(ar, String("p"))
    assert_equal(len(p.buckets), 3, "7: 3 non-null numeric buckets")
    assert_equal(p.buckets[0].key, String("100"), "7: top key '100'")
    assert_equal(p.buckets[0].doc_count, 3, "7: '100'=3")


def test_07b_terms_missing_substitute() raises:
    var bytes = _build_fixture(9)
    var core = SearchCore(bytes^)
    # missing="__none__" -> the null price doc (d2) lands in a "__none__" bucket
    # (m5: a substitute key in the SAME directory). buckets: "100"=3, "__none__"=1,
    # "50"=1, "200"=1.
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(
        String("p"), AGG_KIND_TERMS, String("price"), 10,
        AGG_ORDER_COUNT_DESC, 1, String("__none__"),
    ))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var p = _result_by_name(ar, String("p"))
    assert_equal(len(p.buckets), 4, "7b: null -> __none__ substitute bucket")
    # find the __none__ bucket.
    var found = False
    for i in range(len(p.buckets)):
        if p.buckets[i].key == String("__none__"):
            assert_equal(p.buckets[i].doc_count, 1, "7b: __none__=1")
            found = True
    assert_true(found, "7b: __none__ bucket present")


# =============================================================================
# Case 8 — B1 match-all-for-aggs: aggs over the whole split with NO query term.
# =============================================================================


def test_08_B1_match_all_for_aggs() raises:
    var bytes = _build_fixture(10)
    var core = SearchCore(bytes^)
    # NO query term -> empty touched WITHOUT B1 -> aggs over zero docs (silently
    # wrong). With B1, touched = all 6 docs -> sum over the 5 non-null prices.
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("s"), AGG_KIND_SUM, String("price")))
    aggs.append(_metric(String("vc"), AGG_KIND_VALUE_COUNT, String("price")))
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre")))
    var result = core.search(_q_noterm_aggs(aggs^))
    assert_equal(result.total_matches, 6, "8: B1 whole split = 6 docs")
    var ar = result.take_aggs()
    var s = _result_by_name(ar, String("s"))
    assert_almost_equal(s.sum, 550.0, msg="8: B1 sum over whole split")
    var vc = _result_by_name(ar, String("vc"))
    assert_equal(vc.count, 5, "8: B1 value_count=5 (null skipped)")
    var g = _result_by_name(ar, String("g"))
    assert_equal(len(g.buckets), 3, "8: B1 terms over whole split")


# =============================================================================
# Case 9 — size:0 aggs-only: 0 hits, full-set aggs.
# =============================================================================


def test_09_size0_aggs_only() raises:
    var bytes = _build_fixture(11)
    var core = SearchCore(bytes^)
    # match all 6 docs but size:0 (top_k=0). Hits page is empty; aggs run over
    # the full matched set regardless.
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("s"), AGG_KIND_SUM, String("price")))
    var q = QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    var result = core.search(q)
    assert_equal(result.total_matches, 6, "9: true total = 6")
    var batch = result.take_batch()
    assert_equal(batch.num_rows(), 0, "9: size:0 -> 0 hit rows")
    var ar = result.take_aggs()
    var s = _result_by_name(ar, String("s"))
    assert_almost_equal(s.sum, 550.0, msg="9: aggs over full set despite size:0")


# =============================================================================
# Case 10 — aggs + P1.2 filter: aggs over the FILTERED matched set.
# =============================================================================


def test_10_aggs_with_filter() raises:
    var bytes = _build_fixture(12)
    var core = SearchCore(bytes^)
    # filter price >= 100 -> docs with non-null price >= 100: d0(100),d3(100),
    # d4(200),d5(100) = 4 docs (d1=50 excluded; d2=NULL fails the predicate).
    # value_count over price for the survivors = 4; sum = 500.
    var pred = Expr.binary(
        BIN_GE, Expr.col_ref(String("price")),
        Expr.literal(ScalarValue.from_int64(100)),
    )
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("s"), AGG_KIND_SUM, String("price")))
    aggs.append(_metric(String("vc"), AGG_KIND_VALUE_COUNT, String("price")))
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](pred^), String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    var result = core.search(q)
    assert_equal(result.total_matches, 4, "10: filtered total = 4")
    var ar = result.take_aggs()
    var s = _result_by_name(ar, String("s"))
    assert_almost_equal(s.sum, 500.0, msg="10: sum over filtered set")
    var vc = _result_by_name(ar, String("vc"))
    assert_equal(vc.count, 4, "10: value_count over filtered set")


# =============================================================================
# Case 11 — aggs + P1.3 sort/from/size: aggs unaffected by the page window.
# =============================================================================


def test_11_aggs_with_sort_page() raises:
    var bytes = _build_fixture(13)
    var core = SearchCore(bytes^)
    # sort=price desc, from=1, size=2 -> the page is a 2-row window, but aggs are
    # over the full 6-doc matched set (5 non-null prices summing to 550).
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("s"), AGG_KIND_SUM, String("price")))
    aggs.append(_metric(String("vc"), AGG_KIND_VALUE_COUNT, String("price")))
    var q = QueryIR(
        String("body"), String("alpha"), 2, _text_cfg(), 0,
        None, String("price"), SORT_DESC, MISSING_LAST, 1, aggs^,
    )
    var result = core.search(q)
    assert_equal(result.total_matches, 6, "11: true total = 6 (not the page)")
    var batch = result.take_batch()
    assert_equal(batch.num_rows(), 2, "11: page is 2 rows")
    var ar = result.take_aggs()
    var s = _result_by_name(ar, String("s"))
    assert_almost_equal(s.sum, 550.0, msg="11: aggs over full set, not page")
    var vc = _result_by_name(ar, String("vc"))
    assert_equal(vc.count, 5, "11: value_count over full set")


# =============================================================================
# SHIM helpers.
# =============================================================================


def _jbytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _reader_for(seed: UInt8) raises -> FastFieldReader:
    var bytes = _build_fixture(seed)
    var view = SplitView.parse(bytes^)
    return FastFieldReader(view)


# =============================================================================
# Shim Case 13 — _parse_aggs lowering: metric + terms + the `aggregations`
#                synonym.
# =============================================================================


def test_13_parse_aggs_metric_and_terms() raises:
    # A match query carrying an avg metric + a terms bucket.
    var body = _jbytes(
        '{"query":{"match":{"body":"alpha"}},"aggs":{'
        '"a":{"avg":{"field":"price"}},'
        '"g":{"terms":{"field":"genre","size":5}}}}'
    )
    var q = search_json_to_queryir(Span(body), Int64(0), String("body"))
    assert_true(q.has_aggs(), "13: aggs attached")
    ref specs = q.aggs_ref()
    assert_equal(len(specs), 2, "13: 2 specs")
    # order is preserved (obj_keys order).
    assert_equal(specs[0].name, String("a"), "13: 1st = a")
    assert_equal(specs[0].kind, AGG_KIND_AVG, "13: avg kind")
    assert_equal(specs[0].field, String("price"), "13: avg field")
    assert_equal(specs[1].name, String("g"), "13: 2nd = g")
    assert_equal(specs[1].kind, AGG_KIND_TERMS, "13: terms kind")
    assert_equal(specs[1].bucket_size, 5, "13: terms size=5")


def test_13b_aggregations_synonym() raises:
    var body = _jbytes(
        '{"query":{"match":{"body":"alpha"}},"aggregations":{'
        '"s":{"stats":{"field":"price"}}}}'
    )
    var q = search_json_to_queryir(Span(body), Int64(0), String("body"))
    assert_true(q.has_aggs(), "13b: `aggregations` synonym parsed")
    ref specs = q.aggs_ref()
    assert_equal(specs[0].kind, AGG_KIND_STATS, "13b: stats")


# =============================================================================
# Shim Case 14 — B1 no-query aggs-only -> whole-split aggs (NOT 400, NOT empty).
# =============================================================================


def test_14_B1_no_query_aggs_only() raises:
    # No `query` clause, size:0, aggs present -> a no-term QueryIR with aggs.
    var body = _jbytes(
        '{"size":0,"aggs":{"g":{"terms":{"field":"genre"}}}}'
    )
    var q = search_json_to_queryir(Span(body), Int64(0), String("body"))
    assert_true(q.has_aggs(), "14: B1 aggs attached")
    assert_equal(q.query_text, String(""), "14: no-term query_text")
    assert_equal(q.top_k, 0, "14: size:0")
    # Drive it end-to-end over the split (B1 match-all-for-aggs).
    var bytes = _build_fixture(20)
    var core = SearchCore(bytes^)
    var result = core.search(q)
    assert_equal(result.total_matches, 6, "14: B1 whole split")
    var ar = result.take_aggs()
    var g = _result_by_name(ar, String("g"))
    assert_equal(len(g.buckets), 3, "14: B1 terms over whole split")


def test_14a_aggs_only_targets_the_given_text_field() raises:
    # SearchCore answers a query only from a split of the field it targets, so
    # an aggs-only / match_all request targets the index's text field, and an
    # empty name leaves it empty (the engine refuses that query when it runs).
    var body = _jbytes(
        '{"size":0,"aggs":{"g":{"terms":{"field":"genre"}}}}'
    )
    var q = search_json_to_queryir(Span(body), Int64(0), String("body"))
    assert_equal(q.field_name, String("body"), "14a: targets the text field")
    var q_default = search_json_to_queryir(Span(body), Int64(0), String(""))
    assert_equal(q_default.field_name, String(""), "14a: an empty name stays empty")
    var all_body = _jbytes(
        '{"query":{"match_all":{}},"size":0,'
        '"aggs":{"s":{"sum":{"field":"price"}}}}'
    )
    var q_all = search_json_to_queryir(Span(all_body), Int64(0), String("body"))
    assert_equal(q_all.field_name, String("body"), "14a: match_all targets it")


def test_14b_match_all_aggs() raises:
    # An explicit match_all query + aggs -> the same B1 path.
    var body = _jbytes(
        '{"query":{"match_all":{}},"size":0,'
        '"aggs":{"s":{"sum":{"field":"price"}}}}'
    )
    var q = search_json_to_queryir(Span(body), Int64(0), String("body"))
    assert_true(q.has_aggs(), "14b: match_all aggs")
    assert_equal(q.query_text, String(""), "14b: no-term")


# =============================================================================
# Shim Case 15 — the fail-loud 400s (each a specific reason).
# =============================================================================


def test_15_400_nested_sub_aggs() raises:
    var body = _jbytes(
        '{"query":{"match":{"body":"a"}},"aggs":{"g":{"terms":'
        '{"field":"genre"},"aggs":{"sub":{"avg":{"field":"price"}}}}}}'
    )
    with assert_raises():
        _ = search_json_to_queryir(Span(body), Int64(0), String("body"))


def test_15b_400_cardinality() raises:
    var body = _jbytes(
        '{"query":{"match":{"body":"a"}},"aggs":{"c":{"cardinality":'
        '{"field":"genre"}}}}'
    )
    with assert_raises():
        _ = search_json_to_queryir(Span(body), Int64(0), String("body"))


def test_15c_400_date_histogram() raises:
    var body = _jbytes(
        '{"query":{"match":{"body":"a"}},"aggs":{"d":{"date_histogram":'
        '{"field":"event_day","calendar_interval":"day"}}}}'
    )
    with assert_raises():
        _ = search_json_to_queryir(Span(body), Int64(0), String("body"))


def test_15d_400_multi_field_terms() raises:
    # A terms agg with NO `field` (multi-field/composite) -> 400.
    var body = _jbytes(
        '{"query":{"match":{"body":"a"}},"aggs":{"g":{"terms":{"size":10}}}}'
    )
    with assert_raises():
        _ = search_json_to_queryir(Span(body), Int64(0), String("body"))


def test_15e_400_unrecognized_agg_type() raises:
    var body = _jbytes(
        '{"query":{"match":{"body":"a"}},"aggs":{"x":{"bogus":'
        '{"field":"price"}}}}'
    )
    with assert_raises():
        _ = search_json_to_queryir(Span(body), Int64(0), String("body"))


# =============================================================================
# Shim Case 16 — the GATE 400s (against the split fast-fields, m1).
# =============================================================================


def test_16_gate_metric_on_keyword_400() raises:
    var reader = _reader_for(21)
    # avg over `genre` (a KEYWORD field) -> 400.
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("a"), AGG_KIND_AVG, String("genre")))
    var q = _q_match_aggs(aggs^)
    with assert_raises():
        _ = gate_aggs_against_fastfields(q^, reader)


def test_16b_gate_agg_on_absent_field_400() raises:
    var reader = _reader_for(22)
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("a"), AGG_KIND_AVG, String("nonexistent")))
    var q = _q_match_aggs(aggs^)
    with assert_raises():
        _ = gate_aggs_against_fastfields(q^, reader)


def test_16c_gate_terms_on_text_400() raises:
    var reader = _reader_for(23)
    # terms over `body` (the TEXT field — only in the inverted index, not a
    # fast-field) -> 400 (absent-from-fast-fields path).
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("body")))
    var q = _q_match_aggs(aggs^)
    with assert_raises():
        _ = gate_aggs_against_fastfields(q^, reader)


def test_16d_gate_valid_passes() raises:
    var reader = _reader_for(24)
    # avg over numeric price + terms over keyword genre -> both pass. The gate
    # now RETURNS the (possibly `.keyword`-resolved) query — discard it.
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("a"), AGG_KIND_AVG, String("price")))
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre")))
    var q = _q_match_aggs(aggs^)
    _ = gate_aggs_against_fastfields(q^, reader)  # must NOT raise.


# =============================================================================
# Shim Case 17 — the renderer: terms block + metric {value} + stats five-value.
# =============================================================================


def test_17_render_terms_block() raises:
    var bytes = _build_fixture(25)
    var core = SearchCore(bytes^)
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("by_genre"), AGG_KIND_TERMS, String("genre")))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var obj = agg_results_to_aggregations_object(ar)
    var s = obj.serialize()
    assert_true(s.find('"by_genre"') >= 0, "17: agg name key")
    # Single-split DIRECT render (no cross-split merge): the per-split AggResult's
    # doc_count_error_upper_bound stays 0 (the ctor default; the leaf only records
    # last_bucket_doc_count). A single shard's bound is 0 by OpenSearch definition
    # (§5.2) — the multi-split computed bound is exercised in
    # test_multi_split_merge.mojo.
    assert_true(
        s.find('"doc_count_error_upper_bound":0') >= 0,
        "17: single-split error bound 0",
    )
    assert_true(s.find('"sum_other_doc_count":0') >= 0, "17: other 0")
    assert_true(s.find('"electronic"') >= 0, "17: bucket key")
    assert_true(s.find('"doc_count":3') >= 0, "17: electronic count")


def test_17b_render_metric_value() raises:
    var bytes = _build_fixture(26)
    var core = SearchCore(bytes^)
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("a"), AGG_KIND_AVG, String("price")))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var s = agg_results_to_aggregations_object(ar).serialize()
    assert_true(s.find('"a"') >= 0, "17b: metric name")
    assert_true(s.find('"value":110') >= 0, "17b: avg value")


def test_17c_render_stats_five_value() raises:
    var bytes = _build_fixture(27)
    var core = SearchCore(bytes^)
    var aggs = List[AggSpec]()
    aggs.append(_metric(String("st"), AGG_KIND_STATS, String("price")))
    var result = core.search(_q_match_aggs(aggs^))
    var ar = result.take_aggs()
    var s = agg_results_to_aggregations_object(ar).serialize()
    assert_true(s.find('"count":5') >= 0, "17c: count")
    assert_true(s.find('"min":50') >= 0, "17c: min")
    assert_true(s.find('"max":200') >= 0, "17c: max")
    assert_true(s.find('"sum":550') >= 0, "17c: sum")


def test_17d_render_empty_set_metric_m3() raises:
    # m3: an empty matched set -> sum 0.0, value_count 0, avg null.
    var avg_r = AggResult(String("a"), AGG_KIND_AVG)  # has_value False.
    var sum_r = AggResult(String("s"), AGG_KIND_SUM)
    var vc_r = AggResult(String("vc"), AGG_KIND_VALUE_COUNT)
    var lst = List[AggResult]()
    lst.append(avg_r^)
    lst.append(sum_r^)
    lst.append(vc_r^)
    var ar = AggResults(lst^)
    var s = agg_results_to_aggregations_object(ar).serialize()
    assert_true(s.find('"a":{"value":null}') >= 0, "17d: avg null")
    assert_true(s.find('"s":{"value":0') >= 0, "17d: sum 0.0 (not null)")
    assert_true(s.find('"vc":{"value":0}') >= 0, "17d: value_count 0")


# =============================================================================
# Shim Case 18 — the envelope: size:0 -> aggregations + hits:[]; empty-splits
#                -> aggregations skeleton.
# =============================================================================


def test_18_size0_envelope_has_aggregations_and_empty_hits() raises:
    var bytes = _build_fixture(28)
    var core = SearchCore(bytes^)
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre")))
    var q = QueryIR(
        String("body"), String("alpha"), 0, _text_cfg(), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    var result = core.search(q)
    var agg_results = result.take_aggs()
    var batch = result.take_batch()
    var env = hitbatch_to_hits_envelope(
        batch, String("docs"), List[String](), result.total_matches,
        TRACK_TOTAL_DEFAULT, True, agg_results^, True,
    )
    assert_true(env.find('"aggregations"') >= 0, "18: aggregations present")
    assert_true(env.find('"hits":[]') >= 0, "18: empty hits array")
    assert_true(env.find('"by_genre"') < 0, "18: only the requested agg name")
    assert_true(env.find('"g":{') >= 0, "18: agg name 'g'")


def test_18b_empty_splits_envelope_skeleton() raises:
    # No live splits + aggs requested -> the aggregations skeleton (empty).
    var env = empty_hits_envelope(String("docs"), AggResults(), True)
    assert_true(env.find('"aggregations":{}') >= 0, "18b: empty skeleton")
    assert_true(env.find('"hits":[]') >= 0, "18b: empty hits")
    # No aggs requested -> NO aggregations member.
    var env2 = empty_hits_envelope(String("docs"), AggResults(), False)
    assert_true(env2.find('"aggregations"') < 0, "18b: absent when no aggs")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_search_cov_source_e2e.mojo: SearchCore end to end over a sink-written
# split: IN-list, float and repeated-field filters, the filtered match-all
# scan, terms over a numeric field, typed sorts past the page window, _doc
# sort, and a metric over an absent field.
# =============================================================================
#
# Fixture (6 docs; every "alpha" doc has the same length, so every match
# scores the same and ties fall to doc-id order):
#   doc  body   genre       price  score
#   0    alpha  rock        100    4.5
#   1    alpha  electronic   50    null
#   2    alpha  null        null   3.5
#   3    alpha  electronic  200    2.5
#   4    alpha  electronic   75    5.5
#   5    beta   jazz        100    0.5
#
#   1. IN over a keyword and over an integer field keeps the members only (a
#      null cell is no member).
#   2. A float comparison filter keeps the docs whose float passes; a null
#      float fails; an integer comparison drops the null integer.
#   3. One field named twice in an AND is resolved once and both conjuncts hold.
#   4. The no-query scan (match_all) and the aggs-only request both honor the
#      filter.
#   5. terms over an integer field: stringified keys, the missing substitute
#      for a null cell, key order.
#   6. A metric over a field the split does not carry is refused.
#   7. Typed sorts (I64 asc, F64 desc, STR asc with the null first) and _doc
#      sorts (asc, desc) with fewer page slots than matches return the right
#      rows and keys.
#   8. Every comparison operator over the integer and the float field keeps
#      exactly the docs it should (a null cell never passes).
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_plan_expr.expr import (
    Expr, BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_AND
)
from komira_plan_expr.scalar_value import ScalarValue

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
    AGG_ORDER_KEY_ASC,
    SORT_ASC,
    SORT_DESC,
    MISSING_LAST,
    MISSING_FIRST,
)


def _nullable[
    dt: DType
](raw: List[Scalar[dt]], null_idx: List[Int], at: ArrowType) raises -> Column[HeapRegion]:
    var n = len(raw)
    comptime es = size_of[Scalar[dt]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * es)
    for i in range(n):
        buf.set_typed[Scalar[dt]](i, raw[i])
    buf.set_length(Int64(n * es))
    var validity = Bitmap.create_all_valid(n)
    for k in range(len(null_idx)):
        validity.clear(null_idx[k])
    var arr = PrimitiveArray[dt](
        buf^, n, Optional[Bitmap[HeapRegion]](validity^), len(null_idx), 0
    )
    return Column.from_primitive_with_arrow_type[dt](arr^, at)


def _core() raises -> SearchCore:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("genre", ArrowType.STRING, True))
    sb.add_field(Field("price", ArrowType.INT64, True))
    sb.add_field(Field("score", ArrowType.FLOAT64, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(5)
    var body: List[String] = ["alpha", "alpha", "alpha", "alpha", "alpha", "beta"]
    rb.add_column(Column.from_string(StringArray.from_strings(body)))
    var src: List[String] = ["d0", "d1", "d2", "d3", "d4", "d5"]
    rb.add_column(Column.from_string(StringArray.from_strings(src)))
    var genre: List[String] = ["rock", "electronic", "", "electronic", "electronic", "jazz"]
    var valid: List[Bool] = [True, True, False, True, True, True]
    rb.add_column(Column.from_string(StringArray.from_strings_with_validity(genre, valid)))
    var price: List[Int64] = [100, 50, 0, 200, 75, 100]
    rb.add_column(_nullable[DType.int64](price, [2], ArrowType.INT64))
    var score: List[Float64] = [4.5, 0.0, 3.5, 2.5, 5.5, 0.5]
    rb.add_column(_nullable[DType.float64](score, [1], ArrowType.FLOAT64))
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("b"), String("p"), String("i"), String("body"), Array[UInt8, 16](fill=9)
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return SearchCore(sink.take_split_bytes())


def _q(
    text: String,
    top_k: Int = 10,
    var filter: Optional[Expr] = None,
    sort_field: String = String(""),
    order: UInt8 = SORT_DESC,
    missing: UInt8 = MISSING_LAST,
    var aggs: List[AggSpec] = List[AggSpec](),
    match_all: Bool = False,
) -> QueryIR:
    return QueryIR(
        String("body"), text.copy(), top_k, AnalyzerConfig.text("body"), 0,
        filter^, sort_field.copy(), order, missing, 0, aggs^, match_all,
    )


def _ids(r: SearchResult) raises -> List[Int]:
    var out = List[Int]()
    var arr = r.batch.column_at(1).as_primitive[DType.int64]()
    for i in range(r.batch.num_rows()):
        out.append(Int(arr.get(i)))
    return out^


def _expect(r: SearchResult, want: List[Int], total: Int, ctx: String) raises:
    assert_equal(r.total_matches, total, ctx + ": total")
    var got = _ids(r)
    assert_equal(len(got), len(want), ctx + ": rows")
    for i in range(len(want)):
        assert_equal(got[i], want[i], ctx + ": row " + String(i))


def _cmp(op: UInt8, col: String, var lit: ScalarValue) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(lit^))


def test_01_in_list_filters() raises:
    var core = _core()
    var kw = List[ScalarValue]()
    kw.append(ScalarValue.from_string(String("rock")))
    kw.append(ScalarValue.from_string(String("jazz")))
    var f1 = Expr.in_list_node(Expr.col_ref(String("genre")), kw^)
    _expect(core.search(_q("alpha", filter=f1^)), [0], 1, "1: genre IN")
    var nums = List[ScalarValue]()
    nums.append(ScalarValue.from_int64(Int64(100)))
    nums.append(ScalarValue.from_int64(Int64(75)))
    var f2 = Expr.in_list_node(Expr.col_ref(String("price")), nums^)
    _expect(core.search(_q("alpha", filter=f2^)), [0, 4], 2, "1: price IN")
    var none = List[ScalarValue]()
    none.append(ScalarValue.from_int64(Int64(1)))
    var f3 = Expr.in_list_node(Expr.col_ref(String("price")), none^)
    _expect(core.search(_q("alpha", filter=f3^)), List[Int](), 0, "1: price IN no member")


def test_02_float_and_null_filters() raises:
    var core = _core()
    var gt = _cmp(BIN_GT, String("score"), ScalarValue.from_float(3.0))
    _expect(core.search(_q("alpha", filter=gt^)), [0, 2, 4], 3, "2: score > 3")
    var le = _cmp(BIN_LE, String("score"), ScalarValue.from_float(2.5))
    _expect(core.search(_q("alpha", filter=le^)), [3], 1, "2: score <= 2.5")
    var ge = _cmp(BIN_GE, String("price"), ScalarValue.from_int64(Int64(0)))
    _expect(core.search(_q("alpha", filter=ge^)), [0, 1, 3, 4], 4, "2: price >= 0")


def test_03_one_field_twice() raises:
    var core = _core()
    var f = Expr.binary(
        BIN_AND,
        _cmp(BIN_EQ, String("genre"), ScalarValue.from_string(String("electronic"))),
        _cmp(BIN_NE, String("genre"), ScalarValue.from_string(String("rock"))),
    )
    _expect(core.search(_q("alpha", filter=f^)), [1, 3, 4], 3, "3: eq AND ne")


def test_04_filtered_match_all() raises:
    var core = _core()
    var f = _cmp(BIN_EQ, String("genre"), ScalarValue.from_string(String("electronic")))
    _expect(core.search(_q("", filter=f^, match_all=True)), [1, 3, 4], 3, "4: scan")
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre"), 10, AGG_ORDER_KEY_ASC))
    var f2 = _cmp(BIN_GE, String("price"), ScalarValue.from_int64(Int64(100)))
    var r = core.search(_q("", top_k=0, filter=f2^, aggs=aggs^))
    assert_equal(r.total_matches, 3, "4: aggs-only total (docs 0, 3, 5)")
    var ar = r.take_aggs()
    ref g = ar.results[0]
    assert_equal(len(g.buckets), 3, "4: three genres")
    var keys: List[String] = ["electronic", "jazz", "rock"]
    for i in range(3):
        assert_equal(g.buckets[i].key, keys[i], "4: key " + String(i))
        assert_equal(g.buckets[i].doc_count, 1, "4: count " + String(i))


def test_05_terms_over_integer_field() raises:
    var core = _core()
    var aggs = List[AggSpec]()
    aggs.append(
        AggSpec(String("p"), AGG_KIND_TERMS, String("price"), 10, AGG_ORDER_KEY_ASC, 1, String("none"))
    )
    var r = core.search(_q("alpha", aggs=aggs^))
    var ar = r.take_aggs()
    ref p = ar.results[0]
    var keys: List[String] = ["100", "200", "50", "75", "none"]
    assert_equal(len(p.buckets), 5, "5: five buckets")
    for i in range(5):
        assert_equal(p.buckets[i].key, keys[i], "5: key " + String(i))
        assert_equal(p.buckets[i].doc_count, 1, "5: count " + String(i))


def test_06_metric_over_absent_field() raises:
    var core = _core()
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("a"), AGG_KIND_AVG, String("nope")))
    with assert_raises(contains="SearchCore: no fast-field named 'nope'"):
        _ = core.search(_q("alpha", aggs=aggs^))


def test_07_sorts_past_the_window() raises:
    var core = _core()
    var ri = core.search(_q("alpha", 2, sort_field=String("price"), order=SORT_ASC))
    _expect(ri, [1, 4], 5, "7: price asc")
    assert_equal(ri.sort_keys.key_i64[0], Int64(50), "7: price key 0")
    assert_equal(ri.sort_keys.key_i64[1], Int64(75), "7: price key 1")
    var rf = core.search(_q("alpha", 2, sort_field=String("score"), order=SORT_DESC))
    _expect(rf, [4, 0], 5, "7: score desc")
    assert_equal(rf.sort_keys.key_f64[0], 5.5, "7: score key 0")
    assert_equal(rf.sort_keys.key_f64[1], 4.5, "7: score key 1")
    var rs = core.search(
        _q("alpha", 3, sort_field=String("genre"), order=SORT_ASC, missing=MISSING_FIRST)
    )
    _expect(rs, [2, 1, 3], 5, "7: genre asc, null first")
    assert_true(rs.sort_keys.missing[0], "7: the null genre leads")
    assert_equal(rs.sort_keys.key_str[1], String("electronic"), "7: genre key 1")
    assert_equal(rs.sort_keys.key_str[2], String("electronic"), "7: genre key 2")
    _expect(core.search(_q("alpha", 2, sort_field=String("_doc"), order=SORT_DESC)), [4, 3], 5, "7: _doc desc")
    _expect(core.search(_q("alpha", 2, sort_field=String("_doc"), order=SORT_ASC)), [0, 1], 5, "7: _doc asc")


def test_08_every_comparison_operator() raises:
    var core = _core()
    var ops: List[UInt8] = [BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE]
    # price over the alpha docs: 100, 50, null, 200, 75 (doc 2 null).
    var by_price = List[List[Int]]()
    by_price.append([0])  # == 100
    by_price.append([1, 3, 4])  # != 100
    by_price.append([1])  # < 75
    by_price.append([1, 4])  # <= 75
    by_price.append([3])  # > 100
    by_price.append([0, 3])  # >= 100
    var price_lit: List[Int64] = [100, 100, 75, 75, 100, 100]
    # score over the alpha docs: 4.5, null, 3.5, 2.5, 5.5 (doc 1 null).
    var by_score = List[List[Int]]()
    by_score.append([3])  # == 2.5
    by_score.append([0, 2, 4])  # != 2.5
    by_score.append([3])  # < 3.5
    by_score.append([2, 3])  # <= 3.5
    by_score.append([0, 4])  # > 3.5
    by_score.append([0, 4])  # >= 4.5
    var score_lit: List[Float64] = [2.5, 2.5, 3.5, 3.5, 3.5, 4.5]
    for i in range(6):
        var fp = _cmp(ops[i], String("price"), ScalarValue.from_int64(price_lit[i]))
        _expect(
            core.search(_q("alpha", filter=fp^)), by_price[i], len(by_price[i]),
            "8: price op " + String(i),
        )
        var fs = _cmp(ops[i], String("score"), ScalarValue.from_float(score_lit[i]))
        _expect(
            core.search(_q("alpha", filter=fs^)), by_score[i], len(by_score[i]),
            "8: score op " + String(i),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_search_cov_source_units.mojo: the search core's helpers, one by one
# (the bounded top-k heap, the filter comparators, the terms-bucket order, the
# doc-store reader's refusals, the QueryIR mutators).
# =============================================================================
#
#   1. _TopKHeap, _doc order: a full heap keeps the k smallest doc-ids (asc)
#      or the k largest (desc); an equal doc-id never ranks above itself.
#   2. _TopKHeap, typed keys: a full heap evicts its weakest root for a
#      stronger candidate and drops a weaker one, keeping every key column in
#      step with its doc-id (I64, F64 and STR); root_score of an empty heap is
#      the lowest finite score.
#   3. The comparators: every BIN_* op over i64 and f64, EQ/NE over strings;
#      a DATE32 and a TIMESTAMP literal compare by days and microseconds.
#   4. _resolve_colref_literal accepts the literal on either side and refuses
#      a comparison with no literal.
#   5. _terms_bucket_less under every order code, ties included.
#   6. The doc-store reader refuses a header too short, a negative count, an
#      unknown flag, an index area past the region, decreasing offsets, a blob
#      past the region, and a negative uncompressed length.
#   7. _bmw_read_doc_count refuses a region past the postings and a negative
#      count.
#   8. AggResult.avg of no cell is 0.0; QueryIR.rewrite_agg_field renames one
#      agg's field and refuses an index out of range; replace_filter installs a
#      filter; take_sort_keys moves the keys out.
#   9. The filter evaluator refuses a shape the gate never admits, an IN whose
#      child is not a column, and a field it was not given (collect/eval
#      mismatch).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_plan_expr.expr import (
    Expr,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_arrow.record_batch import RecordBatch

from komira_search.analyzer import AnalyzerConfig, AnalyzedField, Token
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.split import SplitView, serialize_split, DocStoreBuilder
from komira_search.fast_fields import FastFieldReader
from komira_search.source import (
    QueryIR,
    AggSpec,
    AggResult,
    SearchResult,
    SortKeyColumn,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    AGG_ORDER_COUNT_DESC,
    AGG_ORDER_COUNT_ASC,
    AGG_ORDER_KEY_ASC,
    AGG_ORDER_KEY_DESC,
    SORT_ASC,
    SORT_DESC,
    MISSING_LAST,
    SORT_MODE_DOC,
    SORT_MODE_I64,
    SORT_MODE_F64,
    SORT_MODE_STR,
    _TopKHeap,
    _TermBucket,
    _FilterResolvers,
    _cmp_op_i64,
    _cmp_op_f64,
    _cmp_op_str,
    _ff_literal_i64,
    _resolve_colref_literal,
    _terms_bucket_less,
    _docstore_num_docs,
    _docstore_flag,
    _docstore_blob_extent,
    _bmw_read_doc_count,
    _collect_filter_fields,
    _eval_ff_predicate,
    _eval_ff_compare,
    _eval_ff_in_list,
    hit_schema,
)


def _drain_ids(mut h: _TopKHeap) -> List[Int]:
    var order = h.drain_descending()
    var out = List[Int]()
    for i in range(len(order)):
        out.append(h.id_at(order[i]))
    return out^


def _assert_ids(got: List[Int], want: List[Int], ctx: String) raises:
    assert_equal(len(got), len(want), ctx + ": count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], ctx + ": row " + String(i))


def test_01_heap_doc_order_full() raises:
    var asc = _TopKHeap(2, SORT_MODE_DOC, SORT_ASC)
    for d in [5, 3, 9, 1, 4]:
        asc.push(0.0, d)
    _assert_ids(_drain_ids(asc), [1, 3], "1: asc keeps the two smallest")
    var desc = _TopKHeap(2, SORT_MODE_DOC, SORT_DESC)
    for d in [5, 3, 9, 1, 7]:
        desc.push(0.0, d)
    _assert_ids(_drain_ids(desc), [9, 7], "1: desc keeps the two largest")
    # The same doc-id offered twice: neither copy ranks above the other.
    var same = _TopKHeap(3, SORT_MODE_DOC, SORT_ASC)
    same.push(0.0, 4)
    same.push(0.0, 4)
    assert_false(same._a_ranks_higher(0, 1), "1: equal id not higher")
    assert_false(same._a_ranks_higher(1, 0), "1: equal id not higher (swap)")
    # A full heap does not let an equal doc-id evict its root.
    var full = _TopKHeap(1, SORT_MODE_DOC, SORT_ASC)
    full.push(1.0, 6)
    full.push(2.0, 6)
    assert_equal(full.score_at(0), 1.0, "1: the root stays")


def test_02_heap_typed_full() raises:
    # I64 ascending, capacity 2: keys 30, 10, 20, 5 -> 5 and 10 survive.
    var hi = _TopKHeap(2, SORT_MODE_I64, SORT_ASC, MISSING_LAST)
    var ks: List[Int64] = [30, 10, 20, 5]
    for i in range(4):
        hi.push_keyed(0.0, 100 + i, ks[i], 0.0, String(""), False)
    var oi = hi.drain_descending()
    assert_equal(len(oi), 2, "2: i64 two kept")
    assert_equal(hi.id_at(oi[0]), 103, "2: i64 first is key 5")
    assert_equal(hi.key_i64_at(oi[0]), Int64(5), "2: i64 key in step")
    assert_equal(hi.id_at(oi[1]), 101, "2: i64 second is key 10")
    assert_equal(hi.key_i64_at(oi[1]), Int64(10), "2: i64 key in step")
    # F64 descending, capacity 2: 1.5, 9.0, 0.5, 4.0 -> 9.0 and 4.0.
    var hf = _TopKHeap(2, SORT_MODE_F64, SORT_DESC, MISSING_LAST)
    var kf: List[Float64] = [1.5, 9.0, 0.5, 4.0]
    for i in range(4):
        hf.push_keyed(0.0, i, 0, kf[i], String(""), False)
    var of = hf.drain_descending()
    assert_equal(hf.id_at(of[0]), 1, "2: f64 first is 9.0")
    assert_equal(hf.key_f64_at(of[0]), 9.0, "2: f64 key in step")
    assert_equal(hf.id_at(of[1]), 3, "2: f64 second is 4.0")
    assert_equal(hf.key_f64_at(of[1]), 4.0, "2: f64 key in step")
    # STR ascending with a missing cell (missing last), capacity 2.
    var hs = _TopKHeap(2, SORT_MODE_STR, SORT_ASC, MISSING_LAST)
    hs.push_keyed(0.0, 0, 0, 0.0, String("pear"), False)
    hs.push_keyed(0.0, 1, 0, 0.0, String(""), True)
    hs.push_keyed(0.0, 2, 0, 0.0, String("apple"), False)
    hs.push_keyed(0.0, 3, 0, 0.0, String("zebra"), False)
    var os = hs.drain_descending()
    assert_equal(hs.id_at(os[0]), 2, "2: str first is apple")
    assert_equal(hs.key_str_at(os[0]), String("apple"), "2: str key in step")
    assert_false(hs.missing_at(os[0]), "2: apple present")
    assert_equal(hs.id_at(os[1]), 0, "2: str second is pear")
    assert_equal(hs.key_str_at(os[1]), String("pear"), "2: str key in step")
    var empty = _TopKHeap(3)
    assert_equal(empty.root_score(), Float64.MIN_FINITE, "2: empty root")


def test_03_comparators() raises:
    var ops: List[UInt8] = [BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE]
    # (lhs, rhs) = (2, 3), (3, 3), (4, 3): expected per op.
    var want_lt: List[Bool] = [False, True, True, True, False, False]
    var want_eq: List[Bool] = [True, False, False, True, False, True]
    var want_gt: List[Bool] = [False, True, False, False, True, True]
    for i in range(6):
        var op = ops[i]
        assert_equal(_cmp_op_i64(op, 2, 3), want_lt[i], "3: i64 2?3 op " + String(i))
        assert_equal(_cmp_op_i64(op, 3, 3), want_eq[i], "3: i64 3?3 op " + String(i))
        assert_equal(_cmp_op_i64(op, 4, 3), want_gt[i], "3: i64 4?3 op " + String(i))
        assert_equal(_cmp_op_f64(op, 2.5, 3.0), want_lt[i], "3: f64 lt op " + String(i))
        assert_equal(_cmp_op_f64(op, 3.0, 3.0), want_eq[i], "3: f64 eq op " + String(i))
        assert_equal(_cmp_op_f64(op, 3.5, 3.0), want_gt[i], "3: f64 gt op " + String(i))
    assert_true(_cmp_op_str(BIN_EQ, String("a"), String("a")), "3: str eq")
    assert_false(_cmp_op_str(BIN_EQ, String("a"), String("b")), "3: str eq false")
    assert_true(_cmp_op_str(BIN_NE, String("a"), String("b")), "3: str ne")
    assert_false(_cmp_op_str(BIN_NE, String("a"), String("a")), "3: str ne false")
    assert_equal(_ff_literal_i64(ScalarValue.date32(Int32(19000))), Int64(19000), "3: date32")
    assert_equal(
        _ff_literal_i64(ScalarValue.timestamp_micros(Int64(-1234567))),
        Int64(-1234567),
        "3: timestamp micros",
    )
    assert_equal(_ff_literal_i64(ScalarValue.from_int64(Int64(77))), Int64(77), "3: int")


def test_04_colref_literal_either_side() raises:
    var left = Expr.binary(
        BIN_LT, Expr.col_ref(String("price")),
        Expr.literal(ScalarValue.from_int64(Int64(5))),
    )
    var a = _resolve_colref_literal(left)
    assert_equal(a[0], String("price"), "4: col on the left")
    assert_equal(a[1].int_val, Int64(5), "4: literal on the right")
    assert_true(a[2], "4: left flag")
    var right = Expr.binary(
        BIN_LT, Expr.literal(ScalarValue.from_int64(Int64(6))),
        Expr.col_ref(String("qty")),
    )
    var b = _resolve_colref_literal(right)
    assert_equal(b[0], String("qty"), "4: col on the right")
    assert_equal(b[1].int_val, Int64(6), "4: literal on the left")
    assert_false(b[2], "4: right flag")
    var none = Expr.binary(
        BIN_EQ, Expr.col_ref(String("a")), Expr.col_ref(String("b"))
    )
    with assert_raises(contains="pushed comparison is not col-op-literal"):
        _ = _resolve_colref_literal(none)


def test_05_terms_bucket_order() raises:
    var a3 = _TermBucket(String("a"), 3)
    var b3 = _TermBucket(String("b"), 3)
    var b5 = _TermBucket(String("b"), 5)
    var a5 = _TermBucket(String("a"), 5)
    # count desc: higher count first; tie -> key asc.
    assert_true(_terms_bucket_less(b5, a3, AGG_ORDER_COUNT_DESC), "5: cd count")
    assert_true(_terms_bucket_less(a3, b3, AGG_ORDER_COUNT_DESC), "5: cd tie key")
    assert_false(_terms_bucket_less(b3, a3, AGG_ORDER_COUNT_DESC), "5: cd tie key rev")
    # count asc: lower count first; tie -> key asc.
    assert_true(_terms_bucket_less(a3, b5, AGG_ORDER_COUNT_ASC), "5: ca count")
    assert_false(_terms_bucket_less(b5, a3, AGG_ORDER_COUNT_ASC), "5: ca count rev")
    assert_true(_terms_bucket_less(a3, b3, AGG_ORDER_COUNT_ASC), "5: ca tie key")
    assert_false(_terms_bucket_less(b3, a3, AGG_ORDER_COUNT_ASC), "5: ca tie key rev")
    # key asc: lower key first; tie -> count desc.
    assert_true(_terms_bucket_less(a3, b5, AGG_ORDER_KEY_ASC), "5: ka key")
    assert_true(_terms_bucket_less(a5, a3, AGG_ORDER_KEY_ASC), "5: ka tie count")
    assert_false(_terms_bucket_less(a3, a5, AGG_ORDER_KEY_ASC), "5: ka tie count rev")
    # key desc: higher key first; tie -> count desc.
    assert_true(_terms_bucket_less(b3, a5, AGG_ORDER_KEY_DESC), "5: kd key")
    assert_false(_terms_bucket_less(a5, b3, AGG_ORDER_KEY_DESC), "5: kd key rev")
    assert_true(_terms_bucket_less(b5, b3, AGG_ORDER_KEY_DESC), "5: kd tie count")
    assert_false(_terms_bucket_less(b3, b5, AGG_ORDER_KEY_DESC), "5: kd tie count rev")


def _u64(mut out: List[UInt8], v: UInt64):
    for i in range(8):
        out.append(UInt8((v >> UInt64(8 * i)) & 0xFF))


def _ds(
    n: UInt64, flag: UInt8, offs: List[UInt64], uncs: List[UInt64], blob: Int
) -> List[UInt8]:
    var out = List[UInt8]()
    _u64(out, n)
    out.append(flag)
    for o in offs:
        _u64(out, o)
    for u in uncs:
        _u64(out, u)
    for _ in range(blob):
        out.append(0x61)
    return out^


def test_06_docstore_refusals() raises:
    var short: List[UInt8] = [1, 0, 0]
    with assert_raises(contains="_docstore_num_docs: region too short for header (3 < 9"):
        _ = _docstore_num_docs(Span(short))
    with assert_raises(contains="_docstore_flag: region too short for header"):
        _ = _docstore_flag(Span(short))
    var neg = _ds(UInt64(0xFFFF_FFFF_FFFF_FFFF), 0, List[UInt64](), List[UInt64](), 0)
    with assert_raises(contains="negative num_docs"):
        _ = _docstore_num_docs(Span(neg))
    var flag = _ds(1, 7, [0, 1], [1], 1)
    with assert_raises(contains="compressed_flag 7 unsupported"):
        _ = _docstore_num_docs(Span(flag))
    assert_equal(_docstore_flag(Span(flag)), 7, "6: the flag byte read raw")
    # Two docs need 3 offsets + 2 lengths (40 bytes); 16 are present.
    var idx = _ds(2, 0, [0, 1], List[UInt64](), 0)
    with assert_raises(contains="_docstore_blob_extent: index area [9, 49) exceeds region length 25"):
        _ = _docstore_blob_extent(Span(idx), 0)
    var dec = _ds(1, 0, [5, 3], [2], 5)
    with assert_raises(contains="bad blob offsets [start 5, end 3) for slot 0"):
        _ = _docstore_blob_extent(Span(dec), 0)
    var past = _ds(1, 0, [0, 10], [10], 4)
    with assert_raises(contains="blob [33, 43) for slot 0 exceeds region length 37"):
        _ = _docstore_blob_extent(Span(past), 0)
    var unc = _ds(1, 0, [0, 1], [UInt64(0xFFFF_FFFF_FFFF_FFFF)], 1)
    with assert_raises(contains="negative uncompressed_len for slot 0"):
        _ = _docstore_blob_extent(Span(unc), 0)
    var ok = _ds(1, 0, [0, 1], [1], 1)
    var ext = _docstore_blob_extent(Span(ok), 0)
    assert_equal(ext[0], 33, "6: blob offset")
    assert_equal(ext[1], 1, "6: blob length")


def test_07_bmw_doc_count_refusals() raises:
    var region: List[UInt8] = [3, 0, 0]
    with assert_raises(contains="_bmw_read_doc_count: posting region out of bounds"):
        _ = _bmw_read_doc_count(Span(region), 1, 3)
    with assert_raises(contains="_bmw_read_doc_count: posting region out of bounds"):
        _ = _bmw_read_doc_count(Span(region), -1, 2)
    var neg = List[UInt8]()
    for _ in range(9):
        neg.append(0xFF)
    neg.append(0x01)
    with assert_raises(contains="_bmw_read_doc_count: negative doc_count"):
        _ = _bmw_read_doc_count(Span(neg), 0, len(neg))
    var r = _bmw_read_doc_count(Span(region), 0, 3)
    assert_equal(r[0], 3, "7: doc count")
    assert_equal(r[1], 1, "7: base past the count")


def test_08_agg_and_query_mutators() raises:
    var r = AggResult(String("x"), AGG_KIND_AVG)
    assert_equal(r.avg(), 0.0, "8: no cell, avg 0")
    r.sum = 9.0
    r.count = 3
    assert_equal(r.avg(), 3.0, "8: sum / count")
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("t"), AGG_KIND_TERMS, String("genre.keyword")))
    aggs.append(AggSpec(String("a"), AGG_KIND_AVG, String("price")))
    var q = QueryIR(
        String("body"), String("x"), 10, AnalyzerConfig.text("body"), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    q.rewrite_agg_field(0, String("genre"))
    assert_equal(q.aggs_ref()[0].field, String("genre"), "8: renamed")
    assert_equal(q.aggs_ref()[1].field, String("price"), "8: other untouched")
    with assert_raises(contains="rewrite_agg_field: index 2 out of range [0, 2)"):
        q.rewrite_agg_field(2, String("y"))
    with assert_raises(contains="rewrite_agg_field: index -1 out of range"):
        q.rewrite_agg_field(-1, String("y"))
    assert_false(q.has_filter(), "8: no filter yet")
    q.replace_filter(
        Expr.binary(
            BIN_EQ, Expr.col_ref(String("genre")),
            Expr.literal(ScalarValue.from_string(String("rock"))),
        )
    )
    assert_true(q.has_filter(), "8: filter installed")
    assert_equal(q.filter_ref().binary_op(), BIN_EQ, "8: the filter's op")
    var keys = SortKeyColumn(SORT_MODE_I64)
    keys.key_i64.append(Int64(42))
    keys.missing.append(False)
    var res = SearchResult(_empty_batch(), 7, sort_keys=keys^)
    var got = res.take_sort_keys()
    assert_equal(got.count(), 1, "8: one key moved out")
    assert_equal(got.key_i64[0], Int64(42), "8: the key")
    assert_equal(res.sort_keys.count(), 0, "8: the result's keys are empty now")


def _empty_batch() raises -> RecordBatch:
    return RecordBatch.empty_from_schema(hit_schema())


def _plain_view() raises -> SplitView:
    var b = InvertedIndexBuilder.create("body")
    var toks = List[Token]()
    toks.append(Token(String("w"), 0))
    b.add_document(0, AnalyzedField(toks^))
    var fi = b.finalize()
    var ds = DocStoreBuilder(compress=False)
    ds.append(String("d").as_bytes())
    var bytes = serialize_split(
        fi, TermDictBuilder.build_from_finalized(fi), ds, String("body"),
        Array[UInt8, 16](fill=2), 0, 0, 1,
    )
    return SplitView.parse(bytes^)


def test_09_filter_shape_refusals() raises:
    var view = _plain_view()
    var reader = FastFieldReader(view)
    var none = _FilterResolvers()
    var lit = Expr.literal(ScalarValue.from_bool(True))
    with assert_raises(contains="unsupported pushed predicate shape"):
        _collect_filter_fields(none, reader, view, lit)
    with assert_raises(contains="unsupported pushed predicate shape"):
        _ = _eval_ff_predicate(none, view, lit, 0)
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int64(Int64(1)))
    var bad_in = Expr.in_list_node(Expr.literal(ScalarValue.from_int64(Int64(1))), vals.copy())
    with assert_raises(contains="IN child is not a col-ref"):
        _collect_filter_fields(none, reader, view, bad_in)
    with assert_raises(contains="IN child is not a col-ref"):
        _ = _eval_ff_in_list(none, view, bad_in, 0)
    var good_in = Expr.in_list_node(Expr.col_ref(String("price")), vals.copy())
    with assert_raises(contains="filter field 'price' not pre-resolved"):
        _ = _eval_ff_in_list(none, view, good_in, 0)
    with assert_raises(contains="filter field 'price' not pre-resolved"):
        _ = _eval_ff_predicate(none, view, good_in, 0)
    var cmp = Expr.binary(
        BIN_EQ, Expr.col_ref(String("price")),
        Expr.literal(ScalarValue.from_int64(Int64(1))),
    )
    with assert_raises(contains="filter field 'price' not pre-resolved"):
        _ = _eval_ff_compare(none, view, cmp, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

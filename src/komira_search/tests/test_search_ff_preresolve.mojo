# =============================================================================
# test_search_ff_preresolve.mojo — FF-header pre-resolve query-path guard
# =============================================================================
#
# The per-doc FastFieldReader accessor (fast_field_keyword / _i64 / _f64)
# re-parses the sub-region header on EVERY call — the keyword accessor in
# particular ALLOCATES a term_bounds List[Int] + walks the whole dict per doc
# (a large share of a terms-agg query's time). The query path pre-resolves each field's
# header ONCE per query into a KeywordFastFieldResolver / NumericFastFieldResolver
# / FloatFastFieldResolver, so the per-doc path is a single bitpack-window unpack
# (no per-doc alloc, no per-doc dict-walk).
#
# THIS TEST IS THE CORRECTNESS GUARD: it proves the pre-resolved path is
# BYTE-IDENTICAL to the per-doc accessor path, so the optimization can never
# silently change query results.
#
#   Case 1 — DIRECT resolver==accessor byte-identity over keyword / numeric /
#            float fields incl NULL cells (the load-bearing invariant; if a
#            resolver ever diverges from fast_field_*, this fails).
#   Case 2 — END-TO-END terms-agg (keyword) + avg/min/max/sum metric (numeric +
#            float) over the full matched set: exact buckets + metrics.
#   Case 3 — END-TO-END keyword filter: byte-identical survivor set (vs the
#            hand-computed expectation), AND _score is the PURE BM25 (filter
#            UNSCORED — same surviving scores as the unfiltered run).
#   Case 4 — END-TO-END fast-field SORT (keyword STR + numeric I64 + float F64):
#            byte-identical typed-key order.
#   Case 5 — multi-conjunct AND filter (keyword AND numeric range): the registry
#            resolves BOTH distinct fields once; survivor set exact.
#   Case 6 — fail-loud: an out-of-range doc_id through a resolver RAISES.
# =============================================================================

from std.sys import size_of
from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    assert_almost_equal,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.expr import Expr, BIN_EQ, BIN_GE, BIN_AND
from komira_core.plan.scalar_value import ScalarValue

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.source import (
    QueryIR,
    SearchCore,
    AggSpec,
    AggResult,
    AggResults,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    AGG_KIND_MIN,
    AGG_KIND_MAX,
    AGG_KIND_SUM,
    SORT_ASC,
    SORT_DESC,
    MISSING_LAST,
)
from komira_search.split import SplitView
from komira_search.fast_fields import (
    FastFieldReader,
    KeywordFastFieldResolver,
    NumericFastFieldResolver,
    FloatFastFieldResolver,
)


# -----------------------------------------------------------------------------
# Fixture helpers (mirror test_search_aggregations).
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


def _str_col_nullable(
    values: List[String], valid: List[Bool]
) raises -> Column[HeapRegion]:
    return Column.from_string(
        StringArray.from_strings_with_validity(values, valid)
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


def _f64_col(values: List[Float64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(values)
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
#   genre KEYWORD (incl one NULL); price INT64 (incl one NULL); score FLOAT64.
#   doc0: genre="rock"        price=100  score=4.5
#   doc1: genre="electronic"  price=50   score=1.5
#   doc2: genre=NULL          price=NULL score=3.5   <- null genre + null price
#   doc3: genre="electronic"  price=100  score=2.5
#   doc4: genre="electronic"  price=200  score=5.5
#   doc5: genre="jazz"        price=75   score=0.5
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
    var rb = RecordBatchBuilder.with_capacity(6)
    rb.add_column(_str_col([
        String("alpha"), String("alpha"), String("alpha"),
        String("alpha"), String("alpha"), String("alpha"),
    ]))
    rb.add_column(_str_col([
        String("d0"), String("d1"), String("d2"),
        String("d3"), String("d4"), String("d5"),
    ]))
    # genre: doc2 is NULL.
    rb.add_column(_str_col_nullable(
        [
            String("rock"), String("electronic"), String(""),
            String("electronic"), String("electronic"), String("jazz"),
        ],
        [True, True, False, True, True, True],
    ))
    # price: doc2 is NULL.
    rb.add_column(_i64_col_nullable(
        [Int64(100), Int64(50), Int64(0), Int64(100), Int64(200), Int64(75)],
        [2],
    ))
    rb.add_column(_f64_col([
        Float64(4.5), Float64(1.5), Float64(3.5),
        Float64(2.5), Float64(5.5), Float64(0.5),
    ]))
    var batch = rb.build(schema.copy())
    return _drive_sink(batch^, schema^, seed)


def _result_by_name(res: AggResults, name: String) raises -> AggResult:
    for i in range(len(res.results)):
        if res.results[i].name == name:
            return res.results[i].copy()
    raise Error("no agg result named '" + name + "'")


def _ids_of(batch: RecordBatch) raises -> List[Int]:
    """Read the `_id Int64` column from a HitBatch as a List[Int], in row order
    (HitBatch col order: 0=_score, 1=_id, 2=_source)."""
    var out = List[Int]()
    var arr = batch.column_at(1).as_primitive[DType.int64]()
    for r in range(batch.num_rows()):
        out.append(Int(arr.get(r)))
    return out^


def _scores_of(batch: RecordBatch) raises -> List[Float64]:
    var out = List[Float64]()
    var sc = batch.column_at(0).as_primitive[DType.float64]()
    for r in range(batch.num_rows()):
        out.append(sc.get(r))
    return out^


# =============================================================================
# Case 1 — DIRECT resolver==accessor byte-identity (the load-bearing invariant).
# =============================================================================


def test_01_resolver_equals_accessor_byte_identical() raises:
    var bytes = _build_fixture(1)
    var view = SplitView.parse(bytes^)
    assert_true(view.has_fastfields(), "1: has fast-fields")
    var reader = FastFieldReader(view)

    # ---- keyword: resolver.keyword_at == reader.fast_field_keyword per doc ----
    var kw = reader.keyword_resolver(view, String("genre"))
    for d in range(6):
        var a = reader.fast_field_keyword(view, String("genre"), d)
        var b = kw.keyword_at(view, d)
        # null-ness identical
        assert_equal(
            Bool(a), Bool(b), "1: genre null-ness identical doc " + String(d)
        )
        if a and b:
            assert_equal(
                a.value(), b.value(),
                "1: genre value identical doc " + String(d),
            )
    # doc2 genre is NULL on both paths.
    assert_false(Bool(kw.keyword_at(view, 2)), "1: doc2 genre null (resolver)")

    # ---- numeric: resolver.i64_at == reader.fast_field_i64 per doc ----
    var num = reader.numeric_resolver(view, String("price"))
    for d in range(6):
        var a = reader.fast_field_i64(view, String("price"), d)
        var b = num.i64_at(view, d)
        assert_equal(
            Bool(a), Bool(b), "1: price null-ness identical doc " + String(d)
        )
        if a and b:
            assert_equal(
                a.value(), b.value(),
                "1: price value identical doc " + String(d),
            )
    assert_false(Bool(num.i64_at(view, 2)), "1: doc2 price null (resolver)")

    # ---- float: resolver.f64_at == reader.fast_field_f64 per doc ----
    var flt = reader.float_resolver(view, String("score"))
    for d in range(6):
        var a = reader.fast_field_f64(view, String("score"), d)
        var b = flt.f64_at(view, d)
        assert_equal(
            Bool(a), Bool(b), "1: score null-ness identical doc " + String(d)
        )
        if a and b:
            assert_almost_equal(
                a.value(), b.value(), atol=0.0,
                msg="1: score value identical doc " + String(d),
            )


# =============================================================================
# Case 2 — END-TO-END aggs over the full matched set: exact buckets + metrics.
# =============================================================================


def test_02_e2e_aggs_exact() raises:
    var bytes = _build_fixture(2)
    var core = SearchCore(bytes^)
    # genres: rock(d0)=1, electronic(d1,d3,d4)=3, jazz(d5)=1, doc2 null dropped.
    # price (non-null): 100,50,100,200,75 -> sum=525, min=50, max=200, avg=105.
    # score (all 6): 4.5,1.5,3.5,2.5,5.5,0.5 -> sum=18, min=0.5, max=5.5.
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("g"), AGG_KIND_TERMS, String("genre")))
    aggs.append(AggSpec(String("ap"), AGG_KIND_AVG, String("price")))
    aggs.append(AggSpec(String("mnp"), AGG_KIND_MIN, String("price")))
    aggs.append(AggSpec(String("mxp"), AGG_KIND_MAX, String("price")))
    aggs.append(AggSpec(String("sp"), AGG_KIND_SUM, String("price")))
    aggs.append(AggSpec(String("ms"), AGG_KIND_MIN, String("score")))
    aggs.append(AggSpec(String("xs"), AGG_KIND_MAX, String("score")))
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    var result = core.search(q)
    assert_equal(result.total_matches, 6, "2: 6 matched")
    var ar = result.take_aggs()

    var g = _result_by_name(ar, String("g"))
    assert_equal(len(g.buckets), 3, "2: 3 genre buckets (null dropped)")
    assert_equal(g.buckets[0].key, String("electronic"), "2: top=electronic")
    assert_equal(g.buckets[0].doc_count, 3, "2: electronic=3")
    # rock(1) and jazz(1) tie -> _key asc tiebreak -> jazz before rock.
    assert_equal(g.buckets[1].key, String("jazz"), "2: 2nd=jazz (tie, key asc)")
    assert_equal(g.buckets[2].key, String("rock"), "2: 3rd=rock")

    assert_almost_equal(
        _result_by_name(ar, String("ap")).avg(), 105.0, msg="2: avg price=105"
    )
    assert_almost_equal(
        _result_by_name(ar, String("mnp")).min, 50.0, msg="2: min price=50"
    )
    assert_almost_equal(
        _result_by_name(ar, String("mxp")).max, 200.0, msg="2: max price=200"
    )
    assert_almost_equal(
        _result_by_name(ar, String("sp")).sum, 525.0, msg="2: sum price=525"
    )
    assert_almost_equal(
        _result_by_name(ar, String("ms")).min, 0.5, msg="2: min score=0.5"
    )
    assert_almost_equal(
        _result_by_name(ar, String("xs")).max, 5.5, msg="2: max score=5.5"
    )


# =============================================================================
# Case 3 — END-TO-END keyword filter: exact survivor set + filter UNSCORED.
# =============================================================================


def test_03_e2e_filter_keyword_unscored() raises:
    var bytes = _build_fixture(3)
    var core = SearchCore(bytes^)

    # Unfiltered run: record doc_id -> score.
    var no_filter = QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    var res_nf = core.search(no_filter)
    var hits_nf = res_nf.take_batch()
    var ids_nf = _ids_of(hits_nf)
    var sc_nf = _scores_of(hits_nf)
    assert_equal(len(ids_nf), 6, "3: 6 unfiltered hits")

    # Filtered: genre == "electronic" -> docs {1,3,4}.
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref(String("genre")),
        Expr.literal(ScalarValue.from_string(String("electronic"))),
    )
    var with_filter = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0, Optional[Expr](pred^)
    )
    var res_wf = core.search(with_filter)
    assert_equal(res_wf.total_matches, 3, "3: 3 electronic survivors")
    var hits_wf = res_wf.take_batch()
    var ids_wf = _ids_of(hits_wf)
    assert_equal(len(ids_wf), 3, "3: 3 hits returned")
    for i in range(len(ids_wf)):
        var did = ids_wf[i]
        assert_true(
            did == 1 or did == 3 or did == 4,
            "3: survivor is electronic doc " + String(did),
        )
        # filter UNSCORED: the survivor's score == its unfiltered score.
        var found = False
        for j in range(len(ids_nf)):
            if ids_nf[j] == did:
                found = True
                assert_almost_equal(
                    _scores_of(hits_wf)[i], sc_nf[j], atol=0.0,
                    msg="3: score byte-identical (filter unscored) doc "
                    + String(did),
                )
        assert_true(found, "3: survivor was in unfiltered set")


# =============================================================================
# Case 4 — END-TO-END fast-field SORT (keyword STR + numeric I64 + float F64).
# =============================================================================


def test_04_e2e_sort_typed_keys() raises:
    var bytes = _build_fixture(4)
    var core = SearchCore(bytes^)

    # Sort by price ASC (numeric I64). Non-null prices: d1=50,d5=75,d0=100,
    # d3=100,d4=200; doc2 null -> MISSING_LAST. ASC -> 50,75,100,100,200, then
    # the null doc2 last.
    var q_i64 = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String("price"), SORT_ASC, MISSING_LAST, 0,
    )
    var res_i64 = core.search(q_i64)
    var ids_i64 = _ids_of(res_i64.take_batch())
    assert_equal(len(ids_i64), 6, "4: 6 sorted hits")
    assert_equal(ids_i64[0], 1, "4: price asc first = d1 (50)")
    assert_equal(ids_i64[1], 5, "4: price asc 2nd = d5 (75)")
    assert_equal(ids_i64[5], 2, "4: null price last (MISSING_LAST)")

    # Sort by score DESC (float F64): 5.5,4.5,3.5,2.5,1.5,0.5 -> d4,d0,d2,d3,d1,d5.
    var q_f64 = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String("score"), SORT_DESC, MISSING_LAST, 0,
    )
    var res_f64 = core.search(q_f64)
    var ids_f64 = _ids_of(res_f64.take_batch())
    assert_equal(ids_f64[0], 4, "4: score desc first = d4 (5.5)")
    assert_equal(ids_f64[1], 0, "4: score desc 2nd = d0 (4.5)")
    assert_equal(ids_f64[5], 5, "4: score desc last = d5 (0.5)")

    # Sort by genre ASC (keyword STR): electronic < jazz < rock; doc2 null last.
    var q_str = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String("genre"), SORT_ASC, MISSING_LAST, 0,
    )
    var res_str = core.search(q_str)
    var ids_str = _ids_of(res_str.take_batch())
    # first three are the electronic docs {1,3,4} (in some stable order), then
    # jazz(d5), then rock(d0), then null(d2).
    assert_equal(ids_str[5], 2, "4: null genre last (MISSING_LAST)")
    assert_equal(ids_str[4], 0, "4: rock (d0) just before null")
    assert_equal(ids_str[3], 5, "4: jazz (d5) before rock")


# =============================================================================
# Case 5 — multi-conjunct AND filter (keyword AND numeric range): both fields
#          resolved once in the registry; survivor set exact.
# =============================================================================


def test_05_e2e_filter_and_two_fields() raises:
    var bytes = _build_fixture(5)
    var core = SearchCore(bytes^)
    # genre == "electronic" AND price >= 100 -> electronic docs {1,3,4} with
    # price>=100 -> {3 (100), 4 (200)}; d1 (50) drops.
    var lhs = Expr.binary(
        BIN_EQ, Expr.col_ref(String("genre")),
        Expr.literal(ScalarValue.from_string(String("electronic"))),
    )
    var rhs = Expr.binary(
        BIN_GE, Expr.col_ref(String("price")),
        Expr.literal(ScalarValue.from_int64(Int64(100))),
    )
    var pred = Expr.binary(BIN_AND, lhs^, rhs^)
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0, Optional[Expr](pred^)
    )
    var res = core.search(q)
    assert_equal(res.total_matches, 2, "5: 2 survivors (d3,d4)")
    var ids = _ids_of(res.take_batch())
    assert_equal(len(ids), 2, "5: 2 hits")
    for i in range(len(ids)):
        assert_true(
            ids[i] == 3 or ids[i] == 4, "5: survivor doc " + String(ids[i])
        )


# =============================================================================
# Case 6 — fail-loud: an out-of-range doc_id through a resolver RAISES.
# =============================================================================


def test_06_resolver_fail_loud_oob() raises:
    var bytes = _build_fixture(6)
    var view = SplitView.parse(bytes^)
    var reader = FastFieldReader(view)
    var kw = reader.keyword_resolver(view, String("genre"))
    var num = reader.numeric_resolver(view, String("price"))
    var flt = reader.float_resolver(view, String("score"))
    with assert_raises():
        _ = kw.keyword_at(view, 999)
    with assert_raises():
        _ = num.i64_at(view, 999)
    with assert_raises():
        _ = flt.f64_at(view, 999)
    # A keyword field through numeric_resolver RAISES at resolve time (fail-loud).
    with assert_raises():
        _ = reader.numeric_resolver(view, String("genre"))
    # A float field through numeric_resolver RAISES at resolve time.
    with assert_raises():
        _ = reader.numeric_resolver(view, String("score"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_search_filter_pushdown.mojo — P1.2 FILTER PUSHDOWN proof
# =============================================================================
#
# Engine-side + shim-side unit suite over an IN-MEMORY split built by the P0.4
# writer (SearchSink) + the P1.1 fast-fields, no network. Covers:
#
# ENGINE (SearchCore.search apply):
#   1.  term eq on a keyword fast-field (restricted to matched + status==active).
#   2.  term ne on a keyword fast-field.
#   3.  range boundaries on a numeric fast-field (>= / <= include the boundary;
#       > / < exclude it — the EXACT boundary check).
#   4.  range on a DATE fast-field (a real date32 literal — exercises PR2).
#   5.  bool-AND intersection (price > X AND status == "y").
#   6.  IN eq-union on a keyword fast-field.
#   7.  match + filter combined: _score is the PURE BM25 (filter UNSCORED) AND
#       the doc set is restricted.
#   8.  null-fails (a null fast-field cell is dropped by BOTH term and range —
#       three-valued logic; would FALSE-POSITIVE without the null check).
#   (Cases 9 and 10, the Searcher gate matrix and fingerprint distinctness, run
#   with the search runtime package, which this package's tests do not depend
#   on; the shim-side gate is case 16 and its accept/reject matrix is case 17.)
#
# SHIM (search_json_to_queryir term/range/bool-AND lowering — Phase B):
#   11. {"term":{...}} -> col == lit.
#   12. {"range":{...gte,lt}} -> right-leaning BIN_AND.
#   13. {"bool":{"must":[match, term]}} -> match-spec QueryIR + QueryIR.filter.
#   14. {"bool":{"should":[...]}} (OR) -> 400.
#   15. non-fast-field / type-mismatch -> 400; filter-only -> 400 (CB4).
#   16. the gate against a split's fast-field meta: a non-fast-field and a
#       type mismatch raise, a valid filter passes.
#   17. the gate accept/reject matrix, literal dtype against field dtype.
#   18. the longest admitted filter chain survives rewrite, gate and drop.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
    assert_raises,
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
from std.sys import size_of

from komira_plan_expr.expr import (
    Expr,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.split import SplitView
from komira_search.fast_fields import FastFieldReader
from komira_search.source import QueryIR, SearchCore

from komira_search_http.search_query import search_json_to_queryir


# -----------------------------------------------------------------------------
# Fixture helpers
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


def _date32_col(days: List[Int32]) raises -> Column[HeapRegion]:
    return Column.from_primitive_with_arrow_type[DType.int32](
        PrimitiveArray[DType.int32].from_list(days), ArrowType.DATE32
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


def _drive_sink(var batch: RecordBatch, var schema: Schema, seed: UInt8) raises -> List[UInt8]:
    """Drive a SearchSink over a pre-built (schema, batch). The schema MUST carry
    a "body" text col + a "_source" col + the fast-field columns."""
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


# Column accessors over the HitBatch (Float64 _score, Int64 _id, STRING _source).


def _score_at(batch: RecordBatch, row: Int) raises -> Float64:
    return Float64(batch.column_at(0).as_primitive[DType.float64]().get(row))


def _id_at(batch: RecordBatch, row: Int) raises -> Int64:
    return Int64(batch.column_at(1).as_primitive[DType.int64]().get(row))


# Build a fixture split:
#   body text "alpha" in EVERY doc (so all docs match the `match("alpha")`);
#   _source = "d<i>";
#   status KEYWORD; price INT64; rating FLOAT64; event_day DATE32.
def _fixture_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, True))  # keyword
    sb.add_field(Field("price", ArrowType.INT64, True))
    sb.add_field(Field("rating", ArrowType.FLOAT64, True))
    sb.add_field(Field("event_day", ArrowType.DATE32, True))
    return sb.build()


# 4 docs all containing "alpha":
#   doc0: status=active price=50  rating=1.5 day=19000
#   doc1: status=sold   price=100 rating=2.5 day=19100
#   doc2: status=active price=150 rating=3.5 day=19200
#   doc3: status=active price=100 rating=4.5 day=19300
def _build_fixture(seed: UInt8) raises -> List[UInt8]:
    var schema = _fixture_schema()
    var rb = RecordBatchBuilder.with_capacity(6)
    rb.add_column(_str_col([String("alpha"), String("alpha"), String("alpha"), String("alpha")]))
    rb.add_column(_str_col([String("d0"), String("d1"), String("d2"), String("d3")]))
    rb.add_column(_str_col([String("active"), String("sold"), String("active"), String("active")]))
    rb.add_column(_i64_col([Int64(50), Int64(100), Int64(150), Int64(100)]))
    rb.add_column(_f64_col([Float64(1.5), Float64(2.5), Float64(3.5), Float64(4.5)]))
    rb.add_column(_date32_col([Int32(19000), Int32(19100), Int32(19200), Int32(19300)]))
    var batch = rb.build(schema.copy())
    return _drive_sink(batch^, schema^, seed)


# Expr factory shortcuts.


def _col_eq_str(field: String, val: String) raises -> Expr:
    return Expr.binary(
        BIN_EQ, Expr.col_ref(field), Expr.literal(ScalarValue.from_string(val))
    )


def _col_op_i64(op: UInt8, field: String, v: Int64) raises -> Expr:
    return Expr.binary(
        op, Expr.col_ref(field), Expr.literal(ScalarValue.from_int64(v))
    )


# Collect the result doc-ids as a set-ish sorted check.
def _ids(hits: RecordBatch) raises -> List[Int]:
    var out = List[Int]()
    for r in range(hits.num_rows()):
        out.append(Int(_id_at(hits, r)))
    return out^


def _contains(ids: List[Int], v: Int) -> Bool:
    for i in range(len(ids)):
        if ids[i] == v:
            return True
    return False


# =============================================================================
# Case 1 — term eq on a keyword fast-field.
# =============================================================================


def test_01_term_eq_keyword() raises:
    var bytes = _build_fixture(1)
    var core = SearchCore(bytes^)
    # match "alpha" (all 4) restricted to status == "active" -> docs {0,2,3}.
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_eq_str(String("status"), String("active"))),
    )
    var _res = core.search(q)
    var hits = _res.take_batch()
    var ids = _ids(hits)
    assert_equal(len(ids), 3, "1: three active docs")
    assert_true(_contains(ids, 0) and _contains(ids, 2) and _contains(ids, 3))
    assert_false(_contains(ids, 1), "1: sold doc dropped")


# =============================================================================
# Case 2 — term ne on a keyword fast-field.
# =============================================================================


def test_02_term_ne_keyword() raises:
    var bytes = _build_fixture(2)
    var core = SearchCore(bytes^)
    # status != "sold" -> drops doc1; keeps {0,2,3}.
    var pred = Expr.binary(
        BIN_NE, Expr.col_ref(String("status")),
        Expr.literal(ScalarValue.from_string(String("sold"))),
    )
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0, Optional[Expr](pred^)
    )
    var ids = _ids(core.search(q).batch)
    assert_equal(len(ids), 3, "2: three non-sold docs")
    assert_false(_contains(ids, 1), "2: sold doc dropped")


# =============================================================================
# Case 3 — range boundaries on a numeric fast-field (EXACT boundary check).
# =============================================================================


def test_03_range_boundaries_numeric() raises:
    var bytes = _build_fixture(3)
    var core = SearchCore(bytes^)
    # prices: d0=50, d1=100, d2=150, d3=100.
    # price >= 100 -> {1,2,3} (boundary doc value==100 INCLUDED).
    var ge = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_op_i64(BIN_GE, String("price"), Int64(100))),
    )
    var ids_ge = _ids(core.search(ge).batch)
    assert_equal(len(ids_ge), 3, "3: >=100 includes boundary")
    assert_false(_contains(ids_ge, 0))
    # price > 100 -> {2} only (boundary docs 1,3 EXCLUDED).
    var gt = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_op_i64(BIN_GT, String("price"), Int64(100))),
    )
    var ids_gt = _ids(core.search(gt).batch)
    assert_equal(len(ids_gt), 1, "3: >100 excludes boundary")
    assert_true(_contains(ids_gt, 2))
    # price <= 100 -> {0,1,3} (boundary INCLUDED).
    var le = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_op_i64(BIN_LE, String("price"), Int64(100))),
    )
    var ids_le = _ids(core.search(le).batch)
    assert_equal(len(ids_le), 3, "3: <=100 includes boundary")
    assert_false(_contains(ids_le, 2))
    # price < 100 -> {0} only (boundary EXCLUDED).
    var lt = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_op_i64(BIN_LT, String("price"), Int64(100))),
    )
    var ids_lt = _ids(core.search(lt).batch)
    assert_equal(len(ids_lt), 1, "3: <100 excludes boundary")
    assert_true(_contains(ids_lt, 0))


# =============================================================================
# Case 4 — range on a DATE fast-field (a real date32 literal — PR2).
# =============================================================================


def test_04_range_date_field() raises:
    var bytes = _build_fixture(4)
    var core = SearchCore(bytes^)
    # days: d0=19000, d1=19100, d2=19200, d3=19300.
    # event_day < 19200 (date32 literal) -> {0,1}. PR2: the literal is read off
    # date32_val, not int_val.
    var pred = Expr.binary(
        BIN_LT, Expr.col_ref(String("event_day")),
        Expr.literal(ScalarValue.date32(Int32(19200))),
    )
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0, Optional[Expr](pred^)
    )
    var ids = _ids(core.search(q).batch)
    assert_equal(len(ids), 2, "4: two docs before 19200")
    assert_true(_contains(ids, 0) and _contains(ids, 1))
    assert_false(_contains(ids, 2) or _contains(ids, 3))


# =============================================================================
# Case 5 — bool-AND intersection.
# =============================================================================


def test_05_bool_and_intersection() raises:
    var bytes = _build_fixture(5)
    var core = SearchCore(bytes^)
    # price > 50 AND status == "active":
    #   price>50 -> {1,2,3}; status==active -> {0,2,3}; intersection -> {2,3}.
    var pred = Expr.binary(
        BIN_AND,
        _col_op_i64(BIN_GT, String("price"), Int64(50)),
        _col_eq_str(String("status"), String("active")),
    )
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0, Optional[Expr](pred^)
    )
    var ids = _ids(core.search(q).batch)
    assert_equal(len(ids), 2, "5: AND intersection {2,3}")
    assert_true(_contains(ids, 2) and _contains(ids, 3))


# =============================================================================
# Case 6 — IN eq-union on a keyword fast-field.
# =============================================================================


def test_06_in_list_keyword() raises:
    var bytes = _build_fixture(6)
    var core = SearchCore(bytes^)
    # status IN ("active", "pending") -> the active docs {0,2,3} ("pending"
    # matches nothing — union of eq).
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_string(String("active")))
    vals.append(ScalarValue.from_string(String("pending")))
    # in_list_node builds the canonical EXPR_IN_LIST node (Expr.in_list folds to
    # an OR-of-eq tree for small N — NOT the IN node the gate/apply handle).
    var pred = Expr.in_list_node(Expr.col_ref(String("status")), vals^)
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0, Optional[Expr](pred^)
    )
    var ids = _ids(core.search(q).batch)
    assert_equal(len(ids), 3, "6: IN union {0,2,3}")
    assert_false(_contains(ids, 1))


# =============================================================================
# Case 7 — match + filter: _score is the PURE BM25 (filter UNSCORED).
# =============================================================================


def test_07_match_filter_unscored() raises:
    var bytes = _build_fixture(7)
    var core = SearchCore(bytes^)
    # The SAME match("alpha") with NO filter vs WITH a filter: the surviving
    # docs must carry the byte-identical _score (the filter adds nothing).
    var no_filter = QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    var _res_nf = core.search(no_filter)
    var hits_nf = _res_nf.take_batch()
    # Map doc_id -> score for the no-filter run.
    var nf_id = List[Int]()
    var nf_sc = List[Float64]()
    for r in range(hits_nf.num_rows()):
        nf_id.append(Int(_id_at(hits_nf, r)))
        nf_sc.append(_score_at(hits_nf, r))

    var with_filter = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_eq_str(String("status"), String("active"))),
    )
    var _res_wf = core.search(with_filter)
    var hits_wf = _res_wf.take_batch()
    var wf_ids = _ids(hits_wf)
    # restricted to active {0,2,3}.
    assert_equal(len(wf_ids), 3, "7: restricted set")
    assert_false(_contains(wf_ids, 1))
    # every surviving doc carries the SAME _score as the unfiltered run.
    for r in range(hits_wf.num_rows()):
        var did = Int(_id_at(hits_wf, r))
        var sc = _score_at(hits_wf, r)
        var found = False
        for k in range(len(nf_id)):
            if nf_id[k] == did:
                assert_almost_equal(sc, nf_sc[k], msg="7: _score is pure BM25")
                found = True
                break
        assert_true(found, "7: surviving doc was in the unfiltered set")


# =============================================================================
# Case 8 — null-fails (three-valued logic; would FALSE-POSITIVE without it).
# =============================================================================


def test_08_null_fails() raises:
    # Fixture with NULL fast-field cells: status null at doc1; price null at doc2.
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, True))
    sb.add_field(Field("price", ArrowType.INT64, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(_str_col([String("alpha"), String("alpha"), String("alpha")]))
    rb.add_column(_str_col([String("d0"), String("d1"), String("d2")]))
    # status: d0="active", d1=NULL, d2="active".
    rb.add_column(_str_col_nullable(
        [String("active"), String("x"), String("active")],
        [True, False, True],
    ))
    # price: d0=100, d1=100, d2=NULL.
    rb.add_column(_i64_col_nullable([Int64(100), Int64(100), Int64(0)], [2]))
    var batch = rb.build(schema.copy())
    var bytes = _drive_sink(batch^, schema^, 8)
    var core = SearchCore(bytes^)

    # term on status == "active": doc1 (null status) must be DROPPED (not a
    # false positive). Survivors: {0,2}.
    var qt = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_eq_str(String("status"), String("active"))),
    )
    var ids_t = _ids(core.search(qt).batch)
    assert_equal(len(ids_t), 2, "8: term null-fails drops doc1")
    assert_false(_contains(ids_t, 1), "8: null status doc dropped")

    # range on price >= 100: doc2 (null price) must be DROPPED. Survivors: {0,1}.
    var qr = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_op_i64(BIN_GE, String("price"), Int64(100))),
    )
    var ids_r = _ids(core.search(qr).batch)
    assert_equal(len(ids_r), 2, "8: range null-fails drops doc2")
    assert_false(_contains(ids_r, 2), "8: null price doc dropped")


# =============================================================================
# Shim Case 11 — {"term":{...}} -> col == lit.
# =============================================================================


def _qir(body: String) raises -> QueryIR:
    return search_json_to_queryir(Span(body.as_bytes()), Int64(0), String("body"))


def test_11_shim_term() raises:
    # match required (CB4 — filter-only is 400), so a bool with a match arm.
    var body = String(
        '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
        '{"term":{"status":"active"}}]}}}'
    )
    var q = _qir(body)
    assert_true(q.has_filter(), "11: filter attached")
    ref f = q.filter_ref()
    assert_equal(Int(f.binary_op()), Int(BIN_EQ), "11: term -> BIN_EQ")
    ref lhs = f.binary_left_ref()
    assert_equal(lhs.col_ref_name(), String("status"), "11: col is status")
    ref rhs = f.binary_right_ref()
    assert_true(rhs.literal_value().is_string(), "11: string literal")
    assert_equal(rhs.literal_value().string_val, String("active"))


# =============================================================================
# Shim Case 12 — {"range":{...gte,lt}} -> right-leaning BIN_AND.
# =============================================================================


def test_12_shim_range_bounds() raises:
    var body = String(
        '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
        '{"range":{"price":{"gte":100,"lt":500}}}]}}}'
    )
    var q = _qir(body)
    assert_true(q.has_filter(), "12: filter attached")
    ref f = q.filter_ref()
    # right-leaning BIN_AND(gte, lt): left = price>=100, right = price<500.
    assert_equal(Int(f.binary_op()), Int(BIN_AND), "12: two bounds -> BIN_AND")
    ref l = f.binary_left_ref()
    assert_equal(Int(l.binary_op()), Int(BIN_GE), "12: left is >=")
    assert_equal(Int(l.binary_right_ref().literal_value().int_val), 100)
    ref r = f.binary_right_ref()
    assert_equal(Int(r.binary_op()), Int(BIN_LT), "12: right is <")
    assert_equal(Int(r.binary_right_ref().literal_value().int_val), 500)


# =============================================================================
# Shim Case 13 — bool must [match, term] -> match-spec QueryIR + filter.
# =============================================================================


def test_13_shim_bool_must() raises:
    var body = String(
        '{"query":{"bool":{"must":[{"match":{"body":"quick fox"}},'
        '{"term":{"status":"active"}}]}},"size":7}'
    )
    var q = _qir(body)
    # the match arm -> the match-spec QueryIR.
    assert_equal(q.field_name, String("body"), "13: match field")
    assert_equal(q.query_text, String("quick fox"), "13: match text")
    assert_equal(q.top_k, 7, "13: size")
    # the term arm -> QueryIR.filter.
    assert_true(q.has_filter(), "13: filter attached")
    ref f = q.filter_ref()
    assert_equal(Int(f.binary_op()), Int(BIN_EQ))
    assert_equal(f.binary_left_ref().col_ref_name(), String("status"))


# =============================================================================
# Shim Case 13b — fractional number -> float literal (PR3 text inspection).
# =============================================================================


def test_13b_shim_fractional_literal() raises:
    var body = String(
        '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
        '{"range":{"rating":{"gte":2.5}}}]}}}'
    )
    var q = _qir(body)
    assert_true(q.has_filter(), "13b: filter attached")
    ref f = q.filter_ref()
    # single bound -> bare comparison (no BIN_AND).
    assert_equal(Int(f.binary_op()), Int(BIN_GE), "13b: single bound bare GE")
    var lit = f.binary_right_ref().literal_value()
    assert_true(lit.is_float(), "13b: 2.5 -> float literal (PR3)")
    assert_almost_equal(lit.float_val, Float64(2.5))


# =============================================================================
# Shim Case 14 — {"bool":{"should":[...]}} (OR) -> 400.
# =============================================================================


def test_14_shim_should_400() raises:
    var body = String(
        '{"query":{"bool":{"should":[{"term":{"status":"active"}},'
        '{"term":{"status":"sold"}}]}}}'
    )
    with assert_raises():
        var _q = _qir(body)


# =============================================================================
# Shim Case 15 — filter-only (no match) -> 400 (CB4); must_not -> 400.
# =============================================================================


def test_15_shim_filter_only_and_mustnot_400() raises:
    # filter-only: a top-level term query with NO match clause -> 400 (CB4).
    var body_filter_only = String('{"query":{"term":{"status":"active"}}}')
    with assert_raises():
        var _q1 = _qir(body_filter_only)

    # bool with only a filter arm (no match) -> 400 (CB4).
    var body_bool_filter_only = String(
        '{"query":{"bool":{"filter":[{"term":{"status":"active"}}]}}}'
    )
    with assert_raises():
        var _q2 = _qir(body_bool_filter_only)

    # must_not -> 400 (P1.2 OUT).
    var body_mustnot = String(
        '{"query":{"bool":{"must":[{"match":{"body":"alpha"}}],'
        '"must_not":[{"term":{"status":"sold"}}]}}}'
    )
    with assert_raises():
        var _q3 = _qir(body_mustnot)


# =============================================================================
# Shim Case 16 — gate-and-attach: non-fast-field / type-mismatch -> 400 (§3.3).
# =============================================================================


def test_16_shim_gate_against_fastfields() raises:
    from komira_search_http.search_gates import gate_filter_against_fastfields

    var bytes = _build_fixture(16)
    var view = SplitView.parse(bytes.copy())
    var reader = FastFieldReader(view)

    # A filter on a NON-fast-field ("body" is the matched text field) -> raise.
    var q_nonff = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_eq_str(String("body"), String("alpha"))),
    )
    with assert_raises():
        var _g1 = gate_filter_against_fastfields(q_nonff^, reader)

    # A type-mismatch: string literal on the numeric "price" field -> raise.
    var q_mismatch = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_eq_str(String("price"), String("x"))),
    )
    with assert_raises():
        var _g2 = gate_filter_against_fastfields(q_mismatch^, reader)

    # A VALID fast-field filter passes the gate (returns the query).
    var q_ok = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](_col_eq_str(String("status"), String("active"))),
    )
    var gated = gate_filter_against_fastfields(q_ok^, reader)
    assert_true(gated.has_filter(), "16: valid filter passes the gate")


# =============================================================================
# Shim Case 17 — the gate accept/reject matrix over a split's fast-field meta
# (cross-dtype rejection included).
# =============================================================================


def _gate_accepts(reader: FastFieldReader, var pred: Expr) raises -> Bool:
    from komira_search_http.search_gates import gate_filter_against_fastfields

    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        Optional[Expr](pred^),
    )
    try:
        _ = gate_filter_against_fastfields(q^, reader)
    except:
        return False
    return True


def test_17_gate_matrix() raises:
    var bytes = _build_fixture(17)
    var view = SplitView.parse(bytes.copy())
    var reader = FastFieldReader(view)

    # ACCEPT: keyword term, numeric range and term, float range, date range,
    # bool-AND of two pushables.
    assert_true(
        _gate_accepts(reader, _col_eq_str(String("status"), String("active"))),
        "17: keyword term accepted",
    )
    assert_true(
        _gate_accepts(reader, _col_op_i64(BIN_GE, String("price"), Int64(100))),
        "17: numeric range accepted",
    )
    assert_true(
        _gate_accepts(reader, _col_op_i64(BIN_EQ, String("price"), Int64(100))),
        "17: numeric term accepted",
    )
    assert_true(
        _gate_accepts(
            reader,
            Expr.binary(
                BIN_GT, Expr.col_ref(String("rating")),
                Expr.literal(ScalarValue.from_float(Float64(2.0))),
            ),
        ),
        "17: float range accepted",
    )
    assert_true(
        _gate_accepts(
            reader,
            Expr.binary(
                BIN_LT, Expr.col_ref(String("event_day")),
                Expr.literal(ScalarValue.date32(Int32(19200))),
            ),
        ),
        "17: date range accepted",
    )
    assert_true(
        _gate_accepts(
            reader,
            Expr.binary(
                BIN_AND,
                _col_op_i64(BIN_GT, String("price"), Int64(50)),
                _col_eq_str(String("status"), String("active")),
            ),
        ),
        "17: bool-AND accepted",
    )

    # REJECT: range on a keyword field, an OR tree, a non-fast-field.
    assert_false(
        _gate_accepts(
            reader,
            Expr.binary(
                BIN_LT, Expr.col_ref(String("status")),
                Expr.literal(ScalarValue.from_string(String("m"))),
            ),
        ),
        "17: keyword range rejected",
    )
    assert_false(
        _gate_accepts(
            reader,
            Expr.binary(
                BIN_OR,
                _col_eq_str(String("status"), String("active")),
                _col_op_i64(BIN_GT, String("price"), Int64(50)),
            ),
        ),
        "17: OR rejected",
    )
    assert_false(
        _gate_accepts(reader, _col_eq_str(String("body"), String("alpha"))),
        "17: non-fast-field rejected",
    )

    # REJECT: literal dtype against field dtype.
    assert_false(
        _gate_accepts(reader, _col_eq_str(String("price"), String("active"))),
        "17: string literal vs int field rejected",
    )
    assert_false(
        _gate_accepts(reader, _col_eq_str(String("rating"), String("x"))),
        "17: string literal vs float field rejected",
    )
    assert_false(
        _gate_accepts(reader, _col_eq_str(String("event_day"), String("x"))),
        "17: string literal vs date field rejected",
    )
    assert_false(
        _gate_accepts(reader, _col_op_i64(BIN_EQ, String("status"), Int64(5))),
        "17: int literal vs keyword field rejected",
    )
    assert_false(
        _gate_accepts(
            reader,
            Expr.binary(
                BIN_EQ, Expr.col_ref(String("price")),
                Expr.literal(ScalarValue.from_float(Float64(1.5))),
            ),
        ),
        "17: float literal vs int field rejected",
    )
    assert_false(
        _gate_accepts(
            reader,
            Expr.binary(
                BIN_EQ, Expr.col_ref(String("rating")),
                Expr.literal(ScalarValue.from_int64(Int64(2))),
            ),
        ),
        "17: int literal vs float field rejected",
    )


# =============================================================================
# Shim Case 18 — the longest filter chain the parser admits survives the
# keyword rewrite, the validating gate and the destructor.
# =============================================================================


def test_18_longest_filter_chain_through_the_gate() raises:
    from komira_search_http.search_gates import gate_filter_against_fastfields
    from komira_search_http.search_query import MAX_BOOL_CLAUSES

    var body = String('{"query":{"bool":{"must":[{"match":{"body":"alpha"}}')
    for i in range(MAX_BOOL_CLAUSES - 1):
        body += ',{"term":{"status.keyword":"s' + String(i) + '"}}'
    body += "]}}}"
    var q = _qir(body)
    assert_true(q.has_filter(), "18: filter attached")
    var bytes = _build_fixture(18)
    var view = SplitView.parse(bytes.copy())
    var reader = FastFieldReader(view)
    var gated = gate_filter_against_fastfields(q^, reader)
    assert_true(gated.has_filter(), "18: the chain passes the gate")
    # `gated` is dropped here: the predicate chain is destroyed recursively.


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

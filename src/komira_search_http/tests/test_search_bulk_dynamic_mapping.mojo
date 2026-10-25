# =============================================================================
# test_search_bulk_dynamic_mapping.mojo — P1.6 _bulk DYNAMIC
# FIELD MAPPING proof
# =============================================================================
#
# This is the test that does the thing that 400'd before P1.6: index JSON docs
# with mixed-type fields VIA the `_bulk` DocBatch builder, then filter/sort/agg
# over them through the FULL pipeline (SearchSink -> SearchCore / FastFieldReader).
#
# TRANSLATOR units (over ndjson_bulk_to_docbatch / build_doc_batch):
#   1.  Type inference per JSON type {body,status,price,rating} ->
#       STRING/INT64/FLOAT64 (asserted via FastFieldReader.field_class_of after a
#       full ingest).
#   2.  Heterogeneous union with per-doc nulls (incl. A4: a doc OMITTING a
#       FLOAT64 `rating` -> the null cell is masked + a sort/agg over the
#       populated rows is correct).
#   3.  Type conflict (status string-then-int) -> 400.
#   4.  Coerce int->FLOAT64 (x:1.5 then x:2 -> FLOAT64, cell == 2.0).
#   5.  Fail-loud nested/array/_source-key/__fieldnorm__-key -> 400; bool -> no
#       column.
#   6.  Empty body -> 2-col path still works (count 0).
#
# FULL-PIPELINE (the thing that 400'd today):
#   7.  term on keyword `status`.
#   8.  range on numeric `price`.
#   9.  sort on `price`/`rating`; sort on `body` -> 400 (assert the 400 STATUS,
#       A3 — body 400s via the has_field-ABSENT branch, not FIELD_CLASS_TEXT).
#   10. terms agg on `status` + avg `price`; terms on `body` -> 400.
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
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_plan_expr.expr import (
    Expr,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_search.analyzer import (
    AnalyzerConfig,
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
)
from komira_search.sink import SearchSink
from komira_search.split import SplitView
from komira_search.fast_fields import FastFieldReader
from komira_search.source import (
    QueryIR,
    SearchCore,
    AggSpec,
    AggResult,
    AggResults,
    AGG_KIND_TERMS,
    AGG_KIND_AVG,
    AGG_ORDER_COUNT_DESC,
    SORT_DESC,
    SORT_ASC,
    MISSING_LAST,
)

from komira_search_http.bulk import ndjson_bulk_to_docbatch, BulkParse
from komira_search_http.search_gates import (
    gate_sort_against_fastfields,
    gate_aggs_against_fastfields,
)


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _uuid(seed: UInt8) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _text_cfg() -> AnalyzerConfig:
    return AnalyzerConfig.text("body")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _parse(ndjson: String) raises -> BulkParse:
    """Parse an NDJSON `_bulk` body through the P1.6 translator."""
    var body = _bytes(ndjson)
    return ndjson_bulk_to_docbatch(Span(body), String("body"))


def _drive_sink_from_bulk(ndjson: String, seed: UInt8) raises -> List[UInt8]:
    """The full-pipeline path: NDJSON -> translator -> SearchSink ->
    split bytes. Mirrors _drive_sink in test_search_filter_pushdown."""
    var parsed = _parse(ndjson)
    var docbatch = parsed.take_docbatch()
    var schema = docbatch.schema.copy()
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("idx"),
        String("body"),
        _uuid(seed),
    )
    sink.init_sink(schema^)
    sink.accept_batch(docbatch^)
    sink.finish()
    return sink.take_split_bytes()


def _reader(bytes: List[UInt8]) raises -> FastFieldReader:
    var view = SplitView.parse(bytes.copy())
    return FastFieldReader(view)


def _id_at(batch: RecordBatch, row: Int) raises -> Int64:
    return Int64(batch.column_at(1).as_primitive[DType.int64]().get(row))


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


def _result_by_name(res: AggResults, name: String) raises -> AggResult:
    for i in range(len(res.results)):
        if res.results[i].name == name:
            return res.results[i].copy()
    raise Error("no agg result named '" + name + "'")


# -----------------------------------------------------------------------------
# Standard fixtures.
# -----------------------------------------------------------------------------


# A 4-doc homogeneous body: each doc has body + status(keyword) + price(int64) +
# rating(float64). doc0 status=active price=50 rating=1.5; doc1 sold 100 2.5;
# doc2 active 150 3.5; doc3 active 100 4.5.
def _homogeneous_ndjson() -> String:
    return String(
        '{"index":{"_id":"a"}}\n'
        '{"body":"alpha","status":"active","price":50,"rating":1.5}\n'
        '{"index":{"_id":"b"}}\n'
        '{"body":"alpha","status":"sold","price":100,"rating":2.5}\n'
        '{"index":{"_id":"c"}}\n'
        '{"body":"alpha","status":"active","price":150,"rating":3.5}\n'
        '{"index":{"_id":"d"}}\n'
        '{"body":"alpha","status":"active","price":100,"rating":4.5}\n'
    )


# =============================================================================
# Case 1 — type inference per JSON type {string,int,float} -> classes.
# =============================================================================


def test_01_type_inference_per_json_type() raises:
    var parsed = _parse(_homogeneous_ndjson())
    # The translator built a 5-column batch.
    assert_equal(parsed.count, 4, "1: 4 docs")
    var schema = parsed.docbatch.schema.copy()
    assert_equal(schema.num_columns(), 5, "1: body+_source+status+price+rating")
    assert_equal(schema.field_name(0), String("body"), "1: col0=body")
    assert_equal(schema.field_name(1), String("_source"), "1: col1=_source")
    assert_equal(schema.field_at(2).arrow_type, ArrowType.STRING, "1: status STRING")
    assert_equal(schema.field_at(3).arrow_type, ArrowType.INT64, "1: price INT64")
    assert_equal(schema.field_at(4).arrow_type, ArrowType.FLOAT64, "1: rating FLOAT64")

    # Drive the sink and assert the fast-field CLASSES (the engine classifier).
    var bytes = _drive_sink_from_bulk(_homogeneous_ndjson(), 1)
    var reader = _reader(bytes)
    assert_true(reader.has_field(String("status")), "1: status is a fast-field")
    assert_true(reader.has_field(String("price")), "1: price is a fast-field")
    assert_true(reader.has_field(String("rating")), "1: rating is a fast-field")
    assert_false(reader.has_field(String("body")), "1: body is NOT a fast-field")
    assert_equal(
        reader.field_class_of(String("status")), FIELD_CLASS_KEYWORD,
        "1: status KEYWORD",
    )
    assert_equal(
        reader.field_class_of(String("price")), FIELD_CLASS_NUMERIC,
        "1: price NUMERIC",
    )
    assert_equal(
        reader.field_class_of(String("rating")), FIELD_CLASS_NUMERIC,
        "1: rating NUMERIC",
    )


# =============================================================================
# Case 2 — heterogeneous union with per-doc nulls (A4: omitted FLOAT64 rating).
# =============================================================================


def test_02_heterogeneous_union_per_doc_null() raises:
    # doc A {body,status}; doc B {body,price}; doc C {body,rating}.
    var ndjson = String(
        '{"index":{}}\n'
        '{"body":"alpha","status":"active"}\n'
        '{"index":{}}\n'
        '{"body":"alpha","price":100}\n'
        '{"index":{}}\n'
        '{"body":"alpha","rating":4.0}\n'
    )
    var parsed = _parse(ndjson)
    assert_equal(parsed.count, 3, "2: 3 docs")
    var schema = parsed.docbatch.schema.copy()
    # union: body,_source,status,price,rating (first-seen order).
    assert_equal(schema.num_columns(), 5, "2: union has 5 cols")
    assert_equal(schema.field_name(2), String("status"), "2: status first-seen")
    assert_equal(schema.field_name(3), String("price"), "2: price second-seen")
    assert_equal(schema.field_name(4), String("rating"), "2: rating third-seen")

    # validity: status valid only on doc0; price only on doc1; rating only doc2.
    var status_arr = parsed.docbatch.column_at(2).as_string()
    assert_false(status_arr.is_null(0), "2: status valid doc0")
    assert_true(status_arr.is_null(1), "2: status null doc1")
    assert_true(status_arr.is_null(2), "2: status null doc2")
    var price_arr = parsed.docbatch.column_at(3).as_primitive[DType.int64]()
    assert_true(price_arr.is_null(0), "2: price null doc0")
    assert_false(price_arr.is_null(1), "2: price valid doc1")
    assert_true(price_arr.is_null(2), "2: price null doc2")
    var rating_arr = parsed.docbatch.column_at(4).as_primitive[DType.float64]()
    assert_true(rating_arr.is_null(0), "2: rating null doc0")
    assert_true(rating_arr.is_null(1), "2: rating null doc1")
    assert_false(rating_arr.is_null(2), "2: rating valid doc2")

    # A4: a full-pipeline agg over the populated rating rows is correct (the
    # masked null cells are skipped). Only doc2 has rating=4.0 -> avg=4.0.
    var bytes = _drive_sink_from_bulk(ndjson, 2)
    var core = SearchCore(bytes^)
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("r"), AGG_KIND_AVG, String("rating")))
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    var result = core.search(q)
    var ar = result.take_aggs()
    var r = _result_by_name(ar, String("r"))
    assert_true(r.has_value, "2: rating avg present (1 non-null cell)")
    assert_almost_equal(r.avg(), 4.0, msg="2: avg over populated rows = 4.0")
    assert_equal(r.count, 1, "2: value_count=1 (2 null cells skipped)")


# =============================================================================
# Case 3 — type conflict (status string-then-int) -> 400.
# =============================================================================


def test_03_type_conflict_string_then_int() raises:
    # P1.7: a type conflict no longer raises the WHOLE request — the FIRST doc
    # (status string) indexes; the SECOND doc (status int) becomes a per-item
    # mapper_parsing_exception failure and is EXCLUDED.
    var ndjson = String(
        '{"index":{}}\n'
        '{"body":"alpha","status":"active"}\n'
        '{"index":{}}\n'
        '{"body":"alpha","status":5}\n'
    )
    var parsed = _parse(ndjson)
    assert_equal(parsed.count, 1, "3: only doc0 committed")
    assert_true(parsed.any_error, "3: errors true")
    assert_equal(len(parsed.items), 2)
    assert_true(parsed.items[0].ok, "3: doc0 indexed")
    assert_false(parsed.items[1].ok, "3: doc1 conflict failed")
    assert_equal(parsed.items[1].status, 400)
    assert_equal(
        parsed.items[1].error_type, String("mapper_parsing_exception")
    )
    # The established (string) type held: status is a STRING column over the 1
    # committed doc.
    var schema = parsed.docbatch.schema.copy()
    assert_equal(schema.field_at(2).arrow_type, ArrowType.STRING, "3: status STRING")


# =============================================================================
# Case 4 — coerce int->FLOAT64 (x:1.5 then x:2 -> FLOAT64, cell == 2.0).
# =============================================================================


def test_04_coerce_int_to_float() raises:
    var ndjson = String(
        '{"index":{}}\n'
        '{"body":"alpha","x":1.5}\n'
        '{"index":{}}\n'
        '{"body":"alpha","x":2}\n'
    )
    var parsed = _parse(ndjson)
    var schema = parsed.docbatch.schema.copy()
    assert_equal(schema.field_at(2).arrow_type, ArrowType.FLOAT64, "4: x FLOAT64")
    var x_arr = parsed.docbatch.column_at(2).as_primitive[DType.float64]()
    assert_false(x_arr.is_null(0), "4: doc0 valid")
    assert_false(x_arr.is_null(1), "4: doc1 valid")
    assert_almost_equal(Float64(x_arr.get(0)), 1.5, msg="4: doc0 x=1.5")
    assert_almost_equal(
        Float64(x_arr.get(1)), 2.0, msg="4: doc1 int 2 coerced to 2.0"
    )


# =============================================================================
# Case 5 — fail-loud OUT cases (nested/array/_source-key/__fieldnorm__-key ->
#          400; bool -> no column).
# =============================================================================


# P1.7: a per-doc reject (nested/array/reserved-key) no longer raises the WHOLE
# request — that ONE doc becomes a per-item status-400 failure and is excluded.
def _assert_single_item_failed(parsed: BulkParse, msg: String) raises:
    assert_equal(parsed.count, 0, msg + ": no good docs")
    assert_true(parsed.any_error, msg + ": errors true")
    assert_equal(len(parsed.items), 1, msg + ": one item")
    assert_false(parsed.items[0].ok, msg + ": item failed")
    assert_equal(parsed.items[0].status, 400, msg + ": status 400")


def test_05a_nested_object_rejected() raises:
    var ndjson = String(
        '{"index":{}}\n'
        '{"body":"alpha","obj":{"a":1}}\n'
    )
    _assert_single_item_failed(_parse(ndjson), String("5a"))


def test_05b_array_rejected() raises:
    var ndjson = String(
        '{"index":{}}\n'
        '{"body":"alpha","arr":[1,2,3]}\n'
    )
    _assert_single_item_failed(_parse(ndjson), String("5b"))


def test_05c_source_key_rejected() raises:
    var ndjson = String(
        '{"index":{}}\n'
        '{"body":"alpha","_source":"x"}\n'
    )
    _assert_single_item_failed(_parse(ndjson), String("5c"))


def test_05d_fieldnorm_key_rejected() raises:
    var ndjson = String(
        '{"index":{}}\n'
        '{"body":"alpha","__fieldnorm__":1}\n'
    )
    _assert_single_item_failed(_parse(ndjson), String("5d"))


def test_05e_bool_no_column() raises:
    # A bool field rounds-trips in _source but produces NO fast-field column.
    var ndjson = String(
        '{"index":{}}\n'
        '{"body":"alpha","active":true,"status":"sold"}\n'
    )
    var parsed = _parse(ndjson)
    var schema = parsed.docbatch.schema.copy()
    # body,_source,status — NO `active` column.
    assert_equal(schema.num_columns(), 3, "5e: bool field has no column")
    assert_equal(schema.field_name(2), String("status"), "5e: only status col")


# =============================================================================
# Case 6 — empty body -> 2-col path still works (count 0).
# =============================================================================


def test_06_empty_body() raises:
    var parsed = _parse(String(""))
    assert_equal(parsed.count, 0, "6: zero docs")
    var schema = parsed.docbatch.schema.copy()
    assert_equal(schema.num_columns(), 2, "6: empty body -> 2 cols")
    assert_equal(schema.field_name(0), String("body"), "6: body")
    assert_equal(schema.field_name(1), String("_source"), "6: _source")


# =============================================================================
# Case 7 — term filter over a _bulk-indexed keyword field (status).
# =============================================================================


def test_07_term_filter_keyword() raises:
    var bytes = _drive_sink_from_bulk(_homogeneous_ndjson(), 7)
    var core = SearchCore(bytes^)
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref(String("status")),
        Expr.literal(ScalarValue.from_string(String("active"))),
    )
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0, Optional[Expr](pred^)
    )
    var ids = _ids(core.search(q).batch)
    assert_equal(len(ids), 3, "7: three active docs (was 400 pre-P1.6)")
    assert_true(_contains(ids, 0) and _contains(ids, 2) and _contains(ids, 3))
    assert_false(_contains(ids, 1), "7: sold doc dropped")


# =============================================================================
# Case 8 — range filter over a _bulk-indexed numeric field (price).
# =============================================================================


def test_08_range_filter_numeric() raises:
    var bytes = _drive_sink_from_bulk(_homogeneous_ndjson(), 8)
    var core = SearchCore(bytes^)
    # prices: d0=50,d1=100,d2=150,d3=100. price >= 100 -> {1,2,3}.
    var pred = Expr.binary(
        BIN_GE, Expr.col_ref(String("price")),
        Expr.literal(ScalarValue.from_int64(Int64(100))),
    )
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0, Optional[Expr](pred^)
    )
    var ids = _ids(core.search(q).batch)
    assert_equal(len(ids), 3, "8: >=100 -> three docs")
    assert_false(_contains(ids, 0), "8: doc0 (50) dropped")


# =============================================================================
# Case 9 — sort over _bulk-indexed price/rating; sort on body -> 400 (A3).
# =============================================================================


def test_09_sort_numeric_and_body_400() raises:
    var bytes = _drive_sink_from_bulk(_homogeneous_ndjson(), 9)

    # sort on `price` ASC -> d0(50) first, then the two 100s, then 150.
    var core = SearchCore(bytes.copy())
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String("price"), SORT_ASC, MISSING_LAST, 0,
    )
    var ids = _ids(core.search(q).batch)
    assert_equal(len(ids), 4, "9: all 4 docs ranked")
    assert_equal(ids[0], 0, "9: lowest price (50) first")

    # sort on `rating` DESC -> d3(4.5) first.
    var core2 = SearchCore(bytes.copy())
    var q2 = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String("rating"), SORT_DESC, MISSING_LAST, 0,
    )
    var ids2 = _ids(core2.search(q2).batch)
    assert_equal(ids2[0], 3, "9: highest rating (4.5) first")

    # A3: sort on `body` -> 400 via the gate (has_field-ABSENT branch, NOT the
    # FIELD_CLASS_TEXT branch — body is never added to the fast-field entries).
    # Assert the 400 STATUS (the raise), not the exact message.
    var reader = _reader(bytes)
    var q_body = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String("body"), SORT_ASC, MISSING_LAST, 0,
    )
    with assert_raises():
        _ = gate_sort_against_fastfields(q_body^, reader)


# =============================================================================
# Case 10 — terms agg on status + avg price; terms on body -> 400.
# =============================================================================


def test_10_terms_agg_and_metric_and_body_400() raises:
    var bytes = _drive_sink_from_bulk(_homogeneous_ndjson(), 10)
    var core = SearchCore(bytes.copy())
    var aggs = List[AggSpec]()
    aggs.append(AggSpec(String("by_status"), AGG_KIND_TERMS, String("status")))
    aggs.append(AggSpec(String("avg_price"), AGG_KIND_AVG, String("price")))
    var q = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs^,
    )
    var result = core.search(q)
    var ar = result.take_aggs()

    # terms on status: active=3, sold=1 -> active first (count desc).
    var bs = _result_by_name(ar, String("by_status"))
    assert_equal(len(bs.buckets), 2, "10: two status buckets")
    assert_equal(bs.buckets[0].key, String("active"), "10: top=active")
    assert_equal(bs.buckets[0].doc_count, 3, "10: active=3")
    assert_equal(bs.buckets[1].key, String("sold"), "10: 2nd=sold")
    assert_equal(bs.buckets[1].doc_count, 1, "10: sold=1")

    # avg price over all 4 (50+100+150+100)/4 = 100.
    var ap = _result_by_name(ar, String("avg_price"))
    assert_true(ap.has_value, "10: avg present")
    assert_almost_equal(ap.avg(), 100.0, msg="10: avg price=100")

    # terms on `body` -> 400 via the agg gate.
    var reader = _reader(bytes)
    var aggs_body = List[AggSpec]()
    aggs_body.append(AggSpec(String("b"), AGG_KIND_TERMS, String("body")))
    var q_body = QueryIR(
        String("body"), String("alpha"), 10, _text_cfg(), 0,
        None, String(""), SORT_DESC, MISSING_LAST, 0, aggs_body^,
    )
    with assert_raises():
        _ = gate_aggs_against_fastfields(q_body^, reader)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

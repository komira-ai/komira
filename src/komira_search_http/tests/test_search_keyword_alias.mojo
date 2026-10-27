# =============================================================================
# test_search_keyword_alias.mojo — `.keyword` field-alias proof
# =============================================================================
#
# `.keyword` field-alias
# resolution in the OpenSearch shim (a fidelity polish so real Kibana /
# opensearch-py clients work).
#
# THE GAP: real OpenSearch maps a string field to `text` (analyzed) + a
# `<field>.keyword` keyword sub-field; clients/Kibana use `<field>.keyword` for
# exact term filters, sort, and terms aggs. P1.6 builds keyword fast-fields
# under the BARE name (`status`), so `{"term":{"status":...}}` works but
# `{"term":{"status.keyword":...}}`, `"sort":["status.keyword"]`, and
# `{"terms":{"field":"status.keyword"}}` did NOT resolve -> 400.
#
# THE FIX (simplest-correct — suffix-strip in resolution): when a queried field
# name ends in exactly ONE trailing `.keyword`, strip it and resolve against the
# bare name, accepting ONLY when the bare field is a KEYWORD fast-field. The
# QueryIR carries the BARE name (`status`) so the engine reads the right column.
#
# This is the translator-side proof: it drives the gate composition a request handler runs
#   search_json_to_queryir(body) -> gate_{filter,sort,aggs}_against_fastfields
#   -> SearchCore.search
# over an IN-MEMORY split built by the P0.4 writer (SearchSink) + P1.1
# fast-fields, no network (mirrors test_search_filter_pushdown style).
#
# Coverage:
#   1.  {"term":{"status.keyword":"active"}} resolves + SAME results as bare
#       {"term":{"status":"active"}}.
#   2.  sort:[{"status.keyword":"asc"}] resolves + SAME order as bare
#       sort:[{"status":"asc"}].
#   3.  {"terms":{"field":"status.keyword"}} resolves + SAME buckets as bare
#       {"terms":{"field":"status"}}.
#   4.  `.keyword` on a NUMERIC field (price.keyword) -> 400 (term/sort/terms).
#   5.  `.keyword` on `body` (the TEXT field, no fast-field) -> 400.
#   6.  `.keyword` on a non-existent field -> 400.
#   7.  bare `status` (term/sort/terms) still works unchanged.
#   8.  range on `status.keyword` still 400s (keyword gets term only — the
#       resolution does NOT bypass the class checks).
#   9.  single-trailing-strip scope: `status.keyword.keyword` -> 400 (strips
#       ONE level to `status.keyword`, not a fast-field).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.split import SplitView
from komira_search.fast_fields import FastFieldReader
from komira_search.source import (
    QueryIR,
    SearchCore,
    SearchResult,
    AggResult,
    AggResults,
)

from komira_search_http.search_query import search_json_to_queryir
from komira_search_http.search_gates import (
    gate_filter_against_fastfields,
    gate_sort_against_fastfields,
    gate_aggs_against_fastfields,
)


# -----------------------------------------------------------------------------
# Fixture helpers (mirror test_search_filter_pushdown / test_search_aggregations).
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


# Fixture: 4 docs all containing "alpha".
#   _source = "d<i>"; status KEYWORD; price INT64.
#   doc0: status=active price=50
#   doc1: status=sold   price=100
#   doc2: status=active price=150
#   doc3: status=active price=100
def _fixture_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, True))  # keyword
    sb.add_field(Field("price", ArrowType.INT64, True))
    return sb.build()


def _build_fixture(seed: UInt8) raises -> List[UInt8]:
    var schema = _fixture_schema()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(_str_col([
        String("alpha"), String("alpha"), String("alpha"), String("alpha")
    ]))
    rb.add_column(_str_col([String("d0"), String("d1"), String("d2"), String("d3")]))
    rb.add_column(_str_col([
        String("active"), String("sold"), String("active"), String("active")
    ]))
    rb.add_column(_i64_col([Int64(50), Int64(100), Int64(150), Int64(100)]))
    var batch = rb.build(schema.copy())
    return _drive_sink(batch^, schema^, seed)


# -----------------------------------------------------------------------------
# Gate-composition driver: parse JSON -> gate -> search. This is the EXACT
# composition a request handler runs: the parse step,
# then the field-existence/dtype + `.keyword` resolution gate against the split's
# fast-fields, then SearchCore.search.
# -----------------------------------------------------------------------------


def _qir(body: String) raises -> QueryIR:
    return search_json_to_queryir(Span(body.as_bytes()), Int64(0), String("body"))


def _gate_all(var query: QueryIR, reader: FastFieldReader) raises -> QueryIR:
    """Run the gate sequence (filter, then sort, then aggs) — each gate
    resolves `.keyword` against the reader and rewrites the QueryIR to carry the
    bare keyword fast-field name."""
    if query.has_filter():
        query = gate_filter_against_fastfields(query^, reader)
    query = gate_sort_against_fastfields(query^, reader)
    if query.has_aggs():
        query = gate_aggs_against_fastfields(query^, reader)
    return query^


def _run(bytes: List[UInt8], body: String) raises -> SearchResult:
    """Full gate composition over `bytes` for the JSON `body`."""
    var view = SplitView.parse(bytes.copy())
    var reader = FastFieldReader(view)
    var query = _gate_all(_qir(body), reader)
    var core = SearchCore(bytes.copy())
    return core.search(query)


def _expect_400(bytes: List[UInt8], body: String) raises -> Bool:
    """True iff the gate composition RAISES (a 400-shaped error) for `body`.
    The raise may come from the parse step OR the gate step."""
    try:
        var _r = _run(bytes, body)
        return False
    except:
        return True


# -----------------------------------------------------------------------------
# Result extraction.
# -----------------------------------------------------------------------------


def _id_at(batch: RecordBatch, row: Int) raises -> Int64:
    return Int64(batch.column_at(1).as_primitive[DType.int64]().get(row))


def _ids(var result: SearchResult) raises -> List[Int]:
    var batch = result.take_batch()
    var out = List[Int]()
    for r in range(batch.num_rows()):
        out.append(Int(_id_at(batch, r)))
    return out^


def _sorted_ids(var result: SearchResult) raises -> List[Int]:
    """A SET-equality view: the doc-id list sorted ascending (for term/agg
    same-results checks where order is by _score, not stable across the literal)."""
    var ids = _ids(result^)
    # insertion sort (tiny N).
    for i in range(1, len(ids)):
        var v = ids[i]
        var j = i - 1
        while j >= 0 and ids[j] > v:
            ids[j + 1] = ids[j]
            j -= 1
        ids[j + 1] = v
    return ids^


def _ordered_ids(var result: SearchResult) raises -> List[Int]:
    """The doc-id order AS RETURNED (for sort checks — order is load-bearing)."""
    return _ids(result^)


def _contains(ids: List[Int], v: Int) -> Bool:
    for i in range(len(ids)):
        if ids[i] == v:
            return True
    return False


def _eq_lists(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _result_by_name(res: AggResults, name: String) raises -> AggResult:
    for i in range(len(res.results)):
        if res.results[i].name == name:
            return res.results[i].copy()
    raise Error("no agg result named '" + name + "'")


# =============================================================================
# Case 1 — term: `status.keyword` resolves + SAME results as bare `status`.
# =============================================================================


def test_01_term_keyword_alias_same_as_bare() raises:
    var bytes = _build_fixture(1)
    var bare_body = String(
        '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
        '{"term":{"status":"active"}}]}}}'
    )
    var kw_body = String(
        '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
        '{"term":{"status.keyword":"active"}}]}}}'
    )
    var bare_ids = _sorted_ids(_run(bytes, bare_body))
    var kw_ids = _sorted_ids(_run(bytes, kw_body))
    # bare form selects the active docs {0,2,3}.
    assert_equal(len(bare_ids), 3, "1: bare term -> 3 active docs")
    assert_true(_contains(bare_ids, 0) and _contains(bare_ids, 2) and _contains(bare_ids, 3))
    assert_false(_contains(bare_ids, 1), "1: sold doc dropped")
    # `.keyword` form is byte-identical.
    assert_true(_eq_lists(bare_ids, kw_ids), "1: status.keyword == status results")


# =============================================================================
# Case 2 — sort: `status.keyword` asc resolves + SAME order as bare `status`.
# =============================================================================


def test_02_sort_keyword_alias_same_as_bare() raises:
    var bytes = _build_fixture(2)
    var bare_body = String(
        '{"query":{"match":{"body":"alpha"}},"sort":[{"status":"asc"}]}'
    )
    var kw_body = String(
        '{"query":{"match":{"body":"alpha"}},"sort":[{"status.keyword":"asc"}]}'
    )
    var bare_order = _ordered_ids(_run(bytes, bare_body))
    var kw_order = _ordered_ids(_run(bytes, kw_body))
    # status asc: "active" (0,2,3) before "sold" (1); doc-id tiebreak -> 0,2,3,1.
    assert_equal(len(bare_order), 4, "2: all 4 docs returned")
    assert_true(_eq_lists(bare_order, kw_order), "2: status.keyword sort == status sort")
    # the order is load-bearing: actives first, then sold last.
    assert_equal(kw_order[3], 1, "2: sold (doc1) sorts last under asc")


# =============================================================================
# Case 3 — terms agg: `status.keyword` resolves + SAME buckets as bare `status`.
# =============================================================================


def test_03_terms_agg_keyword_alias_same_as_bare() raises:
    var bytes = _build_fixture(3)
    var bare_body = String(
        '{"query":{"match":{"body":"alpha"}},"size":0,'
        '"aggs":{"by_status":{"terms":{"field":"status"}}}}'
    )
    var kw_body = String(
        '{"query":{"match":{"body":"alpha"}},"size":0,'
        '"aggs":{"by_status":{"terms":{"field":"status.keyword"}}}}'
    )
    var bare_res = _run(bytes, bare_body)
    var bare_aggs = bare_res.take_aggs()
    var bare_bs = _result_by_name(bare_aggs, String("by_status"))
    # active=3, sold=1 -> active first (count desc).
    assert_equal(len(bare_bs.buckets), 2, "3: bare two status buckets")
    assert_equal(bare_bs.buckets[0].key, String("active"), "3: top=active")
    assert_equal(bare_bs.buckets[0].doc_count, 3, "3: active=3")
    assert_equal(bare_bs.buckets[1].key, String("sold"), "3: 2nd=sold")
    assert_equal(bare_bs.buckets[1].doc_count, 1, "3: sold=1")

    var kw_res = _run(bytes, kw_body)
    var kw_aggs = kw_res.take_aggs()
    var kw_bs = _result_by_name(kw_aggs, String("by_status"))
    assert_equal(len(kw_bs.buckets), 2, "3: kw two status buckets")
    assert_equal(kw_bs.buckets[0].key, String("active"), "3: kw top=active")
    assert_equal(kw_bs.buckets[0].doc_count, 3, "3: kw active=3")
    assert_equal(kw_bs.buckets[1].key, String("sold"), "3: kw 2nd=sold")
    assert_equal(kw_bs.buckets[1].doc_count, 1, "3: kw sold=1")


# =============================================================================
# Case 4 — `.keyword` on a NUMERIC field -> 400 (term / sort / terms).
# =============================================================================


def test_04_keyword_on_numeric_400() raises:
    var bytes = _build_fixture(4)
    # term on price.keyword (price is INT64) -> 400 (OS only adds `.keyword` to
    # strings; the bare `price` is not a keyword field).
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
            '{"term":{"price.keyword":100}}]}}}'
        )),
        "4: term on price.keyword -> 400",
    )
    # sort on price.keyword -> 400.
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"match":{"body":"alpha"}},"sort":[{"price.keyword":"asc"}]}'
        )),
        "4: sort on price.keyword -> 400",
    )
    # terms agg on price.keyword -> 400.
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"match":{"body":"alpha"}},"size":0,'
            '"aggs":{"p":{"terms":{"field":"price.keyword"}}}}'
        )),
        "4: terms on price.keyword -> 400",
    )


# =============================================================================
# Case 5 — `.keyword` on `body` (the TEXT field, no fast-field) -> 400.
# =============================================================================


def test_05_keyword_on_body_text_400() raises:
    var bytes = _build_fixture(5)
    # term on body.keyword -> 400 (body is analyzed text with no fast-field).
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
            '{"term":{"body.keyword":"alpha"}}]}}}'
        )),
        "5: term on body.keyword -> 400",
    )
    # sort on body.keyword -> 400.
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"match":{"body":"alpha"}},"sort":[{"body.keyword":"asc"}]}'
        )),
        "5: sort on body.keyword -> 400",
    )
    # terms on body.keyword -> 400.
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"match":{"body":"alpha"}},"size":0,'
            '"aggs":{"b":{"terms":{"field":"body.keyword"}}}}'
        )),
        "5: terms on body.keyword -> 400",
    )


# =============================================================================
# Case 6 — `.keyword` on a NON-EXISTENT field -> 400.
# =============================================================================


def test_06_keyword_on_absent_field_400() raises:
    var bytes = _build_fixture(6)
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
            '{"term":{"nonexistent.keyword":"x"}}]}}}'
        )),
        "6: term on nonexistent.keyword -> 400",
    )
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"match":{"body":"alpha"}},'
            '"sort":[{"nonexistent.keyword":"asc"}]}'
        )),
        "6: sort on nonexistent.keyword -> 400",
    )
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"match":{"body":"alpha"}},"size":0,'
            '"aggs":{"n":{"terms":{"field":"nonexistent.keyword"}}}}'
        )),
        "6: terms on nonexistent.keyword -> 400",
    )


# =============================================================================
# Case 7 — bare `status` (term / sort / terms) still works unchanged.
# =============================================================================


def test_07_bare_status_still_works() raises:
    var bytes = _build_fixture(7)
    # term bare.
    var t_ids = _sorted_ids(_run(bytes, String(
        '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
        '{"term":{"status":"active"}}]}}}'
    )))
    assert_equal(len(t_ids), 3, "7: bare term -> 3 active docs")
    assert_false(_contains(t_ids, 1), "7: sold dropped")
    # sort bare.
    var s_order = _ordered_ids(_run(bytes, String(
        '{"query":{"match":{"body":"alpha"}},"sort":[{"status":"asc"}]}'
    )))
    assert_equal(len(s_order), 4, "7: bare sort -> all 4")
    assert_equal(s_order[3], 1, "7: sold last under asc")
    # terms bare.
    var a_res = _run(bytes, String(
        '{"query":{"match":{"body":"alpha"}},"size":0,'
        '"aggs":{"by_status":{"terms":{"field":"status"}}}}'
    ))
    var a_aggs = a_res.take_aggs()
    var bs = _result_by_name(a_aggs, String("by_status"))
    assert_equal(len(bs.buckets), 2, "7: bare terms -> 2 buckets")
    assert_equal(bs.buckets[0].doc_count, 3, "7: active=3")


# =============================================================================
# Case 8 — range on `status.keyword` still 400s (keyword gets term only — the
# `.keyword` resolution does NOT bypass the per-op class checks).
# =============================================================================


def test_08_range_on_keyword_alias_still_400() raises:
    var bytes = _build_fixture(8)
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
            '{"range":{"status.keyword":{"gte":"a"}}}]}}}'
        )),
        "8: range on status.keyword -> 400 (keyword gets term only)",
    )
    # the bare equivalent is ALSO 400 (same class check) — proves resolution
    # leaves the class gate intact, it does not relax it.
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
            '{"range":{"status":{"gte":"a"}}}]}}}'
        )),
        "8: range on bare status -> 400 (same class check)",
    )


# =============================================================================
# Case 9 — single-trailing-strip scope: `status.keyword.keyword` -> 400 (strips
# ONE level to `status.keyword`, which is not a fast-field; nested/dotted paths
# are out of scope per P1.6).
# =============================================================================


def test_09_double_keyword_suffix_400() raises:
    var bytes = _build_fixture(9)
    assert_true(
        _expect_400(bytes, String(
            '{"query":{"bool":{"must":[{"match":{"body":"alpha"}},'
            '{"term":{"status.keyword.keyword":"active"}}]}}}'
        )),
        "9: status.keyword.keyword -> 400 (single-level strip only)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

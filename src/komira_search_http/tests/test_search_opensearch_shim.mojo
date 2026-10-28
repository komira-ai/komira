# =============================================================================
# test_search_opensearch_shim.mojo: the wire translators of the search shim
# =============================================================================
#
# Pure value-function tests, with no server and no store. Each translator is
# fed hand-built values:
#   1. ndjson_bulk_to_docbatch: the two-column batch, the per-item outcomes and
#      the minted ordinals; an empty body, a dangling action (raises), a
#      non-index action, malformed JSON and a missing text field (each fails its
#      item), an escaped character in a source.
#   2. search_json_to_queryir: field, raw query text, default size, generation,
#      the analyzer config; the bare-string and `{"query": ...}` match forms; a
#      missing query and the clauses the translator refuses; an escaped query.
#   3. hitbatch_to_hits_envelope and empty_hits_envelope: totals, max score,
#      hits with the verbatim `_source`, the `_shards` object.
#   4. the `_bulk` response builders (`status`, not `_status`).
#   5. the error envelope.
# The dispatcher itself is covered by the dispatcher suites.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_not_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.string_array import StringArray

from komira_search.analyzer import AnalyzerConfig, analyze_text
from komira_search.source import QueryIR, hit_schema

from komira_search_http.bulk import (
    BulkParse,
    BulkItem,
    ndjson_bulk_to_docbatch,
)
from komira_search_http.config import DEFAULT_TEXT_FIELD
from komira_search_http.envelopes import (
    bulk_response_envelope,
    bulk_response_envelope_items,
    empty_hits_envelope,
    error_envelope,
    hitbatch_to_hits_envelope,
)
from komira_search_http.search_query import search_json_to_queryir


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _bytes(s: String) -> List[UInt8]:
    """Materialize a String into an owned List[UInt8] (a stand-in for req.body).
    """
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _text_at(rb: RecordBatch, row: Int) raises -> String:
    return rb.column_at(0).as_string().get(row)


def _source_at(rb: RecordBatch, row: Int) raises -> String:
    return rb.column_at(1).as_string().get(row)


def _make_hitbatch(
    scores: List[Float64], ids: List[Int64], sources: List[String]
) raises -> RecordBatch:
    """Build a HitBatch RecordBatch (the source.mojo hit_schema layout):
    _score Float64, _id Int64, _source STRING."""
    var sa = PrimitiveArray[DType.float64].from_list(scores)
    var ia = PrimitiveArray[DType.int64].from_list(ids)
    var srca = StringArray.from_strings(sources)
    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(Column.from_primitive[DType.float64](sa))
    rb.add_column(Column.from_primitive[DType.int64](ia))
    rb.add_column(Column.from_string(srca^))
    return rb.build(hit_schema())


# =============================================================================
# Case 1 — ndjson_bulk_to_docbatch
# =============================================================================


def test_01_bulk_roundtrip_two_docs() raises:
    """Alternating action+source -> 2-col DocBatch + client_ids + count."""
    var body = _bytes(
        '{"index":{"_id":"1"}}\n'
        + '{"body":"the quick brown fox"}\n'
        + '{"index":{"_id":"2"}}\n'
        + '{"body":"a lazy dog sleeps"}\n'
    )
    var parsed = ndjson_bulk_to_docbatch(Span(body), DEFAULT_TEXT_FIELD)
    assert_equal(parsed.count, 2)
    assert_false(parsed.any_error, "1: no failed items")
    assert_equal(parsed.docbatch.num_rows(), 2)
    assert_equal(parsed.docbatch.num_columns(), 2)
    # Schema: col0 = DEFAULT_TEXT_FIELD ("body"), col1 = "_source".
    assert_equal(parsed.docbatch.schema.field_name(0), DEFAULT_TEXT_FIELD)
    assert_equal(parsed.docbatch.schema.field_name(1), String("_source"))
    # The extracted text values.
    assert_equal(_text_at(parsed.docbatch, 0), String("the quick brown fox"))
    assert_equal(_text_at(parsed.docbatch, 1), String("a lazy dog sleeps"))
    # The VERBATIM source line is the _source blob.
    assert_equal(
        _source_at(parsed.docbatch, 0), String('{"body":"the quick brown fox"}')
    )
    assert_equal(
        _source_at(parsed.docbatch, 1), String('{"body":"a lazy dog sleeps"}')
    )
    # The per-item outcomes (NDJSON order): both 201/created, client_id == _id.
    assert_equal(len(parsed.items), 2)
    assert_true(parsed.items[0].ok, "1: item0 created")
    assert_true(parsed.items[1].ok, "1: item1 created")
    assert_equal(parsed.items[0].status, 201)
    assert_equal(parsed.items[0].client_id, String("1"))
    assert_equal(parsed.items[1].client_id, String("2"))


def test_02_bulk_minted_ordinal_when_id_absent() raises:
    """An action with no _id mints a dense ordinal ("0", "1", ...)."""
    var body = _bytes(
        '{"index":{}}\n'
        + '{"body":"alpha"}\n'
        + '{"index":{}}\n'
        + '{"body":"beta"}\n'
    )
    var parsed = ndjson_bulk_to_docbatch(Span(body), DEFAULT_TEXT_FIELD)
    assert_equal(parsed.count, 2)
    assert_equal(parsed.items[0].client_id, String("0"))
    assert_equal(parsed.items[1].client_id, String("1"))


def test_03_bulk_empty_body_is_zero() raises:
    """An empty body -> count 0 (the handler short-circuits to the empty
    response; this asserts the translator's zero shape)."""
    var body = _bytes("")
    var parsed = ndjson_bulk_to_docbatch(Span(body), DEFAULT_TEXT_FIELD)
    assert_equal(parsed.count, 0)
    assert_false(parsed.any_error, "3: empty body has no errors")
    assert_equal(parsed.docbatch.num_rows(), 0)
    assert_equal(parsed.docbatch.num_columns(), 2)
    assert_equal(len(parsed.items), 0)


def test_04_bulk_odd_line_count_raises() raises:
    """An odd number of non-blank lines (a dangling action) -> raises. This is
    the one whole-request raise (a dangling action has no source
    doc, so it cannot be attributed to one item)."""
    var body = _bytes('{"index":{"_id":"1"}}\n{"body":"x"}\n{"index":{"_id":"2"}}\n')
    with assert_raises():
        _ = ndjson_bulk_to_docbatch(Span(body), DEFAULT_TEXT_FIELD)


def test_05_bulk_non_index_action_is_per_item_failure() raises:
    """A non-`index` action (create/update/delete) does NOT raise the
    whole request — it becomes a per-item status-400 failure, in NDJSON order."""
    var body = _bytes('{"create":{"_id":"1"}}\n{"body":"x"}\n')
    var parsed = ndjson_bulk_to_docbatch(Span(body), DEFAULT_TEXT_FIELD)
    assert_equal(parsed.count, 0, "5: no good docs")
    assert_true(parsed.any_error, "5: errors true")
    assert_equal(len(parsed.items), 1)
    assert_false(parsed.items[0].ok, "5: item failed")
    assert_equal(parsed.items[0].status, 400)
    assert_equal(parsed.items[0].error_type, String("action_not_supported"))
    # The unsupported action's _id is still echoed.
    assert_equal(parsed.items[0].client_id, String("1"))


def test_06_bulk_malformed_json_is_per_item_failure() raises:
    """A malformed JSON line -> a per-item status-400 failure (not a
    whole-request raise)."""
    var body = _bytes('{"index":{"_id":"1"}\n{"body":"x"}\n')  # missing brace.
    var parsed = ndjson_bulk_to_docbatch(Span(body), DEFAULT_TEXT_FIELD)
    assert_true(parsed.any_error, "6: errors true")
    assert_equal(len(parsed.items), 1)
    assert_false(parsed.items[0].ok, "6: item failed")
    assert_equal(parsed.items[0].status, 400)


def test_07_bulk_missing_text_field_is_per_item_failure() raises:
    """A source doc without the text field -> a per-item status-400 failure
    (not a whole-request raise)."""
    var body = _bytes('{"index":{"_id":"1"}}\n{"title":"x"}\n')  # not "body".
    var parsed = ndjson_bulk_to_docbatch(Span(body), DEFAULT_TEXT_FIELD)
    assert_equal(parsed.count, 0, "7: no good docs")
    assert_true(parsed.any_error, "7: errors true")
    assert_equal(len(parsed.items), 1)
    assert_false(parsed.items[0].ok, "7: item failed")
    assert_equal(parsed.items[0].status, 400)
    assert_equal(parsed.items[0].client_id, String("1"))


def test_08_bulk_escaped_source_survives() raises:
    """An escaped char in the source (\\n, \\") survives the JSON parse; the
    text-field value is UNESCAPED, the _source blob is the verbatim line."""
    # Source: {"body":"line1\nline2 \"q\""}  (escaped newline + escaped quote).
    var body = _bytes(
        '{"index":{"_id":"x"}}\n'
        + '{"body":"line1\\nline2 \\"q\\""}\n'
    )
    var parsed = ndjson_bulk_to_docbatch(Span(body), DEFAULT_TEXT_FIELD)
    assert_equal(parsed.count, 1)
    # The text value is UNESCAPED: a real newline + real quotes.
    var t = _text_at(parsed.docbatch, 0)
    assert_true(t.find("line1") >= 0)
    assert_true(t.find("line2") >= 0)
    assert_true(t.find("\n") >= 0)  # the escaped \n decoded to a real newline.
    assert_true(t.find("\"q\"") >= 0)  # the escaped quotes decoded.
    # The _source blob is the VERBATIM line (escapes intact).
    var src = _source_at(parsed.docbatch, 0)
    assert_true(src.find("\\n") >= 0)  # the literal backslash-n in the source.


# =============================================================================
# Case 2 — search_json_to_queryir
# =============================================================================


def test_10_search_bare_string_match() raises:
    """The bare-string match form -> field / raw text / default size / gen."""
    var body = _bytes('{"query":{"match":{"body":"quick fox"}}}')
    var q = search_json_to_queryir(Span(body), Int64(7), DEFAULT_TEXT_FIELD)
    assert_equal(q.field_name, String("body"))
    assert_equal(q.query_text, String("quick fox"))  # RAW (not analyzed).
    assert_equal(q.top_k, 10)  # default size.
    assert_equal(q.generation, Int64(7))  # the stamped generation.
    # The analyzer is the text default, the one the indexing side uses.
    assert_true(q.analyzer_config.is_tokenized())


def test_11_search_object_match_with_size() raises:
    """The {"query":...} object match form + an explicit size."""
    var body = _bytes(
        '{"query":{"match":{"body":{"query":"lazy dog"}}},"size":3}'
    )
    var q = search_json_to_queryir(Span(body), Int64(0), DEFAULT_TEXT_FIELD)
    assert_equal(q.field_name, String("body"))
    assert_equal(q.query_text, String("lazy dog"))
    assert_equal(q.top_k, 3)


def test_12_search_analyzer_is_text_default() raises:
    """The QueryIR analyzer config is identical to the AnalyzerConfig.
    text(field) factory the SearchSink uses (the structural symmetry guard).
    Cross-checked by tokenizing the same text through both and comparing."""
    var body = _bytes('{"query":{"match":{"body":"Quick FOX"}}}')
    var q = search_json_to_queryir(Span(body), Int64(0), DEFAULT_TEXT_FIELD)
    var ref_cfg = AnalyzerConfig.text(String("body"))
    # is_tokenized() is the E7 contract both must satisfy.
    assert_true(q.analyzer_config.is_tokenized())
    assert_true(ref_cfg.is_tokenized())
    # Structural equivalence: tokenize the same text through both configs and
    # assert the produced term streams are identical (byte-identical analyzer).
    var a = analyze_text(String("Quick FOX jumps"), q.analyzer_config)
    var b = analyze_text(String("Quick FOX jumps"), ref_cfg)
    assert_equal(len(a.tokens), len(b.tokens))
    for i in range(len(a.tokens)):
        assert_equal(a.tokens[i].term, b.tokens[i].term)


def test_13_search_missing_query_raises() raises:
    var body = _bytes('{"size":5}')
    with assert_raises():
        _ = search_json_to_queryir(Span(body), Int64(0), DEFAULT_TEXT_FIELD)


def test_14_search_non_match_clause_raises() raises:
    """A term, range or bool clause with no match raises."""
    var term_body = _bytes('{"query":{"term":{"body":"x"}}}')
    with assert_raises():
        _ = search_json_to_queryir(Span(term_body), Int64(0), DEFAULT_TEXT_FIELD)
    var range_body = _bytes('{"query":{"range":{"n":{"gte":1}}}}')
    with assert_raises():
        _ = search_json_to_queryir(Span(range_body), Int64(0), DEFAULT_TEXT_FIELD)
    var bool_body = _bytes('{"query":{"bool":{"must":[]}}}')
    with assert_raises():
        _ = search_json_to_queryir(Span(bool_body), Int64(0), DEFAULT_TEXT_FIELD)
    var aggs_body = _bytes('{"query":{"match":{"body":"x"}},"aggs":{}}')
    # An empty `aggs` object beside a match still parses: the translator
    # reads it as no aggregation.
    var q = search_json_to_queryir(Span(aggs_body), Int64(0), DEFAULT_TEXT_FIELD)
    assert_equal(q.field_name, String("body"))


def test_15_search_escaped_query_decodes() raises:
    """An escaped query string (\\n / \\") decodes to the raw text correctly."""
    var body = _bytes('{"query":{"match":{"body":"a\\nb \\"c\\""}}}')
    var q = search_json_to_queryir(Span(body), Int64(0), DEFAULT_TEXT_FIELD)
    assert_true(q.query_text.find("a") >= 0)
    assert_true(q.query_text.find("\n") >= 0)  # decoded newline.
    assert_true(q.query_text.find("\"c\"") >= 0)  # decoded quotes.


# =============================================================================
# Case 3 — hitbatch_to_hits_envelope
# =============================================================================


def test_20_hits_envelope_three_rows() raises:
    """A 3-row HitBatch -> total.value 3, max_score == top, 3 hits, _shards."""
    var scores: List[Float64] = [1.5, 0.9, 0.2]
    var ids: List[Int64] = [Int64(0), Int64(1), Int64(2)]
    var sources: List[String] = [
        String('{"body":"alpha"}'),
        String('{"body":"beta"}'),
        String('{"body":"gamma"}'),
    ]
    var hb = _make_hitbatch(scores, ids, sources)
    # total_matches is the TRUE match total (== page size here, no
    # pagination); sorted_by_score True (default _score sort).
    var env = hitbatch_to_hits_envelope(hb, String("docs"), List[String](), 3)

    # total.value 3, relation eq.
    assert_true(env.find('"total":{"value":3,"relation":"eq"}') >= 0)
    # max_score == the top (descending) score.
    assert_true(env.find('"max_score":1.5') >= 0)
    # The single-shard _shards object.
    assert_true(
        env.find('"_shards":{"total":1,"successful":1,"skipped":0,"failed":0}')
        >= 0
    )
    assert_true(env.find('"timed_out":false') >= 0)
    # Three hits with _index / _id / _score / embedded-verbatim _source.
    assert_true(env.find('"_index":"docs"') >= 0)
    assert_true(env.find('"_id":"0"') >= 0)  # _id = doc_id stringified.
    assert_true(env.find('"_id":"2"') >= 0)
    assert_true(env.find('"_score":1.5') >= 0)
    # The _source blob is embedded as a JSON VALUE (an object), NOT a quoted
    # string: the rendered envelope contains the nested object form.
    assert_true(env.find('"_source":{"body":"alpha"}') >= 0)
    assert_true(env.find('"_source":{"body":"gamma"}') >= 0)


def test_21_hits_envelope_zero_rows() raises:
    """A 0-row HitBatch -> total.value 0, max_score null, hits []."""
    var scores = List[Float64]()
    var ids = List[Int64]()
    var sources = List[String]()
    var hb = _make_hitbatch(scores, ids, sources)
    var env = hitbatch_to_hits_envelope(hb, String("docs"), List[String](), 0)
    assert_true(env.find('"total":{"value":0,"relation":"eq"}') >= 0)
    assert_true(env.find('"max_score":null') >= 0)
    assert_true(env.find('"hits":[]') >= 0)
    # _shards still present on the empty result.
    assert_true(env.find('"_shards":') >= 0)


def test_22_empty_hits_envelope() raises:
    """The no-live-splits empty envelope: total 0, max_score null, hits []."""
    var env = empty_hits_envelope(String("missing"))
    assert_true(env.find('"total":{"value":0,"relation":"eq"}') >= 0)
    assert_true(env.find('"max_score":null') >= 0)
    assert_true(env.find('"hits":[]') >= 0)
    assert_true(env.find('"_shards":') >= 0)


# =============================================================================
# Case 4 — the _bulk response builder
# =============================================================================


def test_30_bulk_response_status_not_underscore() raises:
    """The _bulk response: items keyed by `index`, status 201, errors false.
    The wire field is `status` (NOT `_status`)."""
    var ids: List[String] = [String("1"), String("2")]
    var env = bulk_response_envelope(String("docs"), ids)
    assert_true(env.find('"errors":false') >= 0)
    assert_true(env.find('"took":0') >= 0)
    # Each item is keyed by the action verb `index`.
    assert_true(env.find('"index":{') >= 0)
    assert_true(env.find('"_index":"docs"') >= 0)
    assert_true(env.find('"_id":"1"') >= 0)
    assert_true(env.find('"_id":"2"') >= 0)
    assert_true(env.find('"_version":1') >= 0)
    assert_true(env.find('"result":"created"') >= 0)
    # status, NOT _status.
    assert_true(env.find('"status":201') >= 0)
    assert_false(env.find('"_status"') >= 0)


def test_31_bulk_response_empty() raises:
    """Empty count -> items []."""
    var env = bulk_response_envelope(String("docs"), List[String]())
    assert_true(env.find('"items":[]') >= 0)
    assert_true(env.find('"errors":false') >= 0)


def test_32_bulk_response_per_item_mixed() raises:
    """The per-item envelope renders a SUCCESS then a FAILURE item in
    order, with `errors:true`. A success -> status 201 + result created; a
    failure -> status 400 + error{type,reason}."""
    var items = List[BulkItem]()
    items.append(BulkItem.created(String("a")))
    items.append(
        BulkItem.failed(
            String("b"),
            String("mapper_parsing_exception"),
            String("bad field"),
        )
    )
    var env = bulk_response_envelope_items(String("docs"), items, True)
    assert_true(env.find('"errors":true') >= 0, "32: errors true")
    # The success item.
    assert_true(env.find('"_id":"a"') >= 0)
    assert_true(env.find('"status":201') >= 0)
    assert_true(env.find('"result":"created"') >= 0)
    # The failure item: status 400 + error{type,reason}; no result/_version.
    assert_true(env.find('"_id":"b"') >= 0)
    assert_true(env.find('"status":400') >= 0)
    assert_true(env.find('"type":"mapper_parsing_exception"') >= 0)
    assert_true(env.find('"reason":"bad field"') >= 0)


def test_33_bulk_response_per_item_all_success_errors_false() raises:
    """An all-success per-item envelope renders `errors:false` (the
    opensearch-py happy-path envelope shape)."""
    var items = List[BulkItem]()
    items.append(BulkItem.created(String("0")))
    items.append(BulkItem.created(String("1")))
    var env = bulk_response_envelope_items(String("docs"), items, False)
    assert_true(env.find('"errors":false') >= 0)
    assert_true(env.find('"status":201') >= 0)
    assert_false(env.find('"status":400') >= 0, "33: no failure item")
    assert_false(env.find('"error"') >= 0, "33: no error object")


# =============================================================================
# Case 5 — the error envelope
# =============================================================================


def test_40_error_envelope_4xx() raises:
    """The error envelope: {"error":{"type","reason"},"status":4xx}."""
    var env = error_envelope(
        String("parse_exception"), String("bad body"), 400
    )
    assert_true(env.find('"error":{') >= 0)
    assert_true(env.find('"type":"parse_exception"') >= 0)
    assert_true(env.find('"reason":"bad body"') >= 0)
    assert_true(env.find('"status":400') >= 0)


def test_41_error_envelope_escapes_reason() raises:
    """The reason is correctly escaped (a quote / newline in the message does
    not corrupt the JSON) — the JSON serializer escaping."""
    var env = error_envelope(
        String("parse_exception"),
        String('he said "hi"\nbye'),
        400,
    )
    # The embedded quote is escaped as \" and the newline as \n.
    assert_true(env.find('he said \\"hi\\"\\nbye') >= 0)


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

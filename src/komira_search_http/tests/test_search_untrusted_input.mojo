# =============================================================================
# test_search_untrusted_input.mojo — request bodies the shim must bound
# =============================================================================
#
# `search_json_to_queryir` and `ndjson_bulk_to_docbatch` read HTTP request
# bodies written by clients. Each case below is a body that must be refused
# (a `_search` raise, or a failed `_bulk` item) or bounded, and none may abort
# the process or corrupt the batch handed to the engine.
#
# _search:
#   1. `from` and `size` near the Int64 maximum do not wrap past the result
#      window check (the sum overflowed to a negative number).
#   2. `from` or `size` above the window alone is refused.
#   3. A bool query with more clauses than MAX_BOOL_CLAUSES is refused; one at
#      the limit parses. (The clauses fold into a chain whose depth is the
#      clause count.)
#   4. Nested bool queries and nested aggregations, 200 levels deep, are
#      refused by name, not recursed into.
#   5. JSON nested past the parser's depth limit is refused.
#
# _bulk:
#   6. A source object that names a field twice fails its item; the committed
#      batch stays rectangular and the neighbouring documents still index.
#   7. An integer outside Int64 fails its item instead of aborting the request.
#   8. A float outside Float64 (it parses to infinity) fails its item.
#   9. A document with more than MAX_DYNAMIC_FIELDS fields fails its item.
#  10. A document that would take the union schema past MAX_DYNAMIC_FIELDS
#      fields fails its item; the documents before it keep their columns.
#  11. A line that is not valid UTF-8 fails its item.
#
# Added with the review of the port:
#  13. A negative, fractional, string or out-of-range `size` / `from` is refused.
#  14. An object that names two clauses where the DSL takes one is refused
#      (a dropped sibling would drop a filter).
#  15. The aggregation count and the `terms` size are capped; a name used twice
#      is refused.
#  16. A key named twice in a `_search` body or a `_bulk` action line is refused.
#  17. Result-changing options the translator does not implement are refused.
#  18. A `_bulk` line with an unbalanced quote costs one item, not the lines
#      after it.
#  19. A `delete` action has no source line; a failed item is keyed by its
#      verb; a dangling action still raises.
#  20. The batch is bounded by documents times mapped fields.
#  21. Ill-formed UTF-8 in an action line, and in a last line with no newline.
#  22. Non-finite aggregate values render as null.
#  23. The empty-index envelope honours track_total_hits:false and renders a
#      caller-supplied aggregation skeleton.
#  24. A bool query with only filter arms and `aggs` is refused.
#
# Envelope:
#  12. A non-finite score renders as null, so the envelope is still valid JSON.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
)

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.string_array import StringArray

from komira_json import parse_json_value

from komira_search.source import (
    hit_schema,
    AggResult,
    AggResults,
    AGG_KIND_SUM,
    AGG_KIND_AVG,
    AGG_KIND_MIN,
    AGG_KIND_MAX,
    AGG_KIND_STATS,
    AGG_KIND_TERMS,
)

from komira_search_http.bulk import (
    ndjson_bulk_to_docbatch,
    BulkParse,
    MAX_DYNAMIC_FIELDS,
    MAX_BATCH_CELLS,
)
from komira_search_http.envelopes import (
    hitbatch_to_hits_envelope,
    empty_hits_envelope,
    bulk_response_envelope_items,
    agg_results_to_aggregations_object,
    TRACK_TOTAL_DEFAULT,
    TRACK_TOTAL_FALSE,
)
from komira_search_http.search_query import (
    search_json_to_queryir,
    MAX_BOOL_CLAUSES,
    MAX_RESULT_WINDOW,
    MAX_AGGS,
    MAX_TERMS_SIZE,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _search_raises(body: String) -> String:
    """The error text of `search_json_to_queryir` over `body`, or "" if it
    parsed."""
    var b = _bytes(body)
    try:
        _ = search_json_to_queryir(Span(b), Int64(0), String("body"))
    except e:
        return String(e)
    return String("")


def _parse(ndjson: String) raises -> BulkParse:
    var body = _bytes(ndjson)
    return ndjson_bulk_to_docbatch(Span(body), String("body"))


def _assert_rectangular(parsed: BulkParse, msg: String) raises:
    """Every column of the committed batch has one cell per committed doc."""
    assert_equal(parsed.docbatch.num_rows(), parsed.count, msg + ": rows")
    for c in range(parsed.docbatch.num_columns()):
        assert_equal(
            parsed.docbatch.column_at(c).length(), parsed.count, msg + ": col"
        )


def _doc_with_fields(prefix: String, n: Int) -> String:
    """A source line `{"body":"x","<prefix>0":0,...,"<prefix>n-1":0}`."""
    var s = String('{"body":"x"')
    for i in range(n):
        s += ',"' + prefix + String(i) + '":0'
    s += "}"
    return s


# =============================================================================
# 1-2 — from / size cannot wrap past the result window.
# =============================================================================


def test_01_from_plus_size_does_not_wrap() raises:
    var err = _search_raises(
        String(
            '{"query":{"match":{"body":"a"}},"from":9223372036854775807,"size":10}'
        )
    )
    assert_true(err.find("Result window is too large") >= 0, "1: " + err)
    var err2 = _search_raises(
        String(
            '{"query":{"match":{"body":"a"}},"from":9223372036854775800,'
            '"size":9223372036854775800}'
        )
    )
    assert_true(err2.find("Result window is too large") >= 0, "1b: " + err2)


def test_02_from_or_size_alone_above_window_refused() raises:
    var big = String(MAX_RESULT_WINDOW + 1)
    var e_size = _search_raises(
        String('{"query":{"match":{"body":"a"}},"size":') + big + "}"
    )
    assert_true(e_size.find("Result window is too large") >= 0, "2: size")
    var e_from = _search_raises(
        String('{"query":{"match":{"body":"a"}},"size":0,"from":') + big + "}"
    )
    assert_true(e_from.find("Result window is too large") >= 0, "2: from")
    # The window itself is allowed.
    var ok = _search_raises(
        String('{"query":{"match":{"body":"a"}},"from":9990,"size":10}')
    )
    assert_equal(ok, String(""), "2: from+size == window parses")


# =============================================================================
# 3 — the bool clause count is bounded.
# =============================================================================


def _bool_body(n_terms: Int) -> String:
    var s = String('{"query":{"bool":{"must":[{"match":{"body":"a"}}')
    for i in range(n_terms):
        s += ',{"term":{"status":"s' + String(i) + '"}}'
    s += "]}}}"
    return s


def test_03_bool_clause_count_is_bounded() raises:
    # n_terms + the match clause == MAX_BOOL_CLAUSES parses.
    assert_equal(
        _search_raises(_bool_body(MAX_BOOL_CLAUSES - 1)),
        String(""),
        "3: at the limit parses",
    )
    var err = _search_raises(_bool_body(MAX_BOOL_CLAUSES))
    assert_true(err.find("too many bool clauses") >= 0, "3: over limit: " + err)
    # Filter and must arms count together.
    var split = String('{"query":{"bool":{"must":[{"match":{"body":"a"}}')
    for i in range(MAX_BOOL_CLAUSES):
        split += ',{"term":{"status":"s"}}'
    split += '],"filter":[{"term":{"status":"x"}}]}}}'
    assert_true(
        _search_raises(split).find("too many bool clauses") >= 0,
        "3: must + filter counted together",
    )


# =============================================================================
# 4-5 — nesting is refused, not recursed into.
# =============================================================================


def _nested_bool(depth: Int) -> String:
    var q = String('{"match":{"body":"a"}}')
    for _ in range(depth):
        q = String('{"bool":{"must":[') + q + "]}}"
    return String('{"query":') + q + "}"


def _nested_aggs(depth: Int) -> String:
    var aggs = String('{"v":{"avg":{"field":"price"}}}')
    for _ in range(depth):
        aggs = String('{"g":{"terms":{"field":"genre"},"aggs":') + aggs + "}}"
    return String('{"query":{"match":{"body":"a"}},"aggs":') + aggs + "}"


def test_04_nested_bool_and_nested_aggs_refused() raises:
    # Within the JSON depth limit: the translator refuses the nesting itself.
    var e1 = _search_raises(_nested_bool(30))
    assert_true(e1.find("nested bool") >= 0, "4: nested bool: " + e1)
    var e2 = _search_raises(_nested_aggs(30))
    assert_true(e2.find("nested sub-aggregations") >= 0, "4: nested aggs: " + e2)
    # Past it: the JSON parser refuses before any translation.
    assert_true(
        _search_raises(_nested_bool(200)).find("JsonError") >= 0, "4: deep bool"
    )
    assert_true(
        _search_raises(_nested_aggs(200)).find("JsonError") >= 0, "4: deep aggs"
    )


def test_05_json_nesting_past_depth_limit_refused() raises:
    var s = String("")
    for _ in range(5000):
        s += "["
    var err = _search_raises(s)
    assert_true(err.find("JsonError") >= 0, "5: " + err)


# =============================================================================
# 6 — a duplicated field fails its item.
# =============================================================================


def test_06_duplicate_field_fails_item_batch_stays_rectangular() raises:
    var parsed = _parse(
        String(
            '{"index":{"_id":"a"}}\n{"body":"alpha","n":1}\n'
            '{"index":{"_id":"b"}}\n{"body":"beta","n":1,"n":2}\n'
            '{"index":{"_id":"c"}}\n{"body":"gamma","n":3}\n'
        )
    )
    assert_equal(len(parsed.items), 3, "6: 3 items")
    assert_true(parsed.items[0].ok, "6: a ok")
    assert_false(parsed.items[1].ok, "6: duplicate field fails")
    assert_equal(parsed.items[1].status, 400, "6: status")
    assert_equal(parsed.items[1].client_id, String("b"), "6: id echoed")
    assert_true(parsed.items[2].ok, "6: c ok")
    assert_true(parsed.any_error, "6: errors true")
    assert_equal(parsed.count, 2, "6: 2 committed")
    _assert_rectangular(parsed, "6")


# =============================================================================
# 7-8 — numbers outside the range of long / double fail the item.
# =============================================================================


def test_07_integer_out_of_int64_fails_item() raises:
    var parsed = _parse(
        String(
            '{"index":{"_id":"a"}}\n{"body":"alpha","n":99999999999999999999}\n'
            '{"index":{"_id":"b"}}\n{"body":"beta","n":5}\n'
        )
    )
    assert_equal(len(parsed.items), 2, "7: 2 items")
    assert_false(parsed.items[0].ok, "7: out-of-range integer fails its item")
    assert_equal(
        parsed.items[0].error_type, String("mapper_parsing_exception"), "7: type"
    )
    assert_true(parsed.items[1].ok, "7: neighbour indexes")
    assert_equal(parsed.count, 1, "7: 1 committed")
    _assert_rectangular(parsed, "7")


def test_08_float_out_of_float64_fails_item() raises:
    var parsed = _parse(
        String(
            '{"index":{"_id":"a"}}\n{"body":"alpha","f":1e999}\n'
            '{"index":{"_id":"b"}}\n{"body":"beta","f":1.5}\n'
        )
    )
    assert_equal(len(parsed.items), 2, "8: 2 items")
    assert_false(parsed.items[0].ok, "8: infinite float fails its item")
    assert_true(parsed.items[1].ok, "8: neighbour indexes")
    assert_equal(parsed.count, 1, "8: 1 committed")
    _assert_rectangular(parsed, "8")


# =============================================================================
# 9-10 — the dynamic field count is bounded.
# =============================================================================


def test_09_document_over_field_limit_fails_item() raises:
    var ok_doc = _doc_with_fields(String("f"), MAX_DYNAMIC_FIELDS)
    var bad_doc = _doc_with_fields(String("f"), MAX_DYNAMIC_FIELDS + 1)
    var parsed = _parse(
        String('{"index":{"_id":"a"}}\n') + ok_doc + "\n"
        + '{"index":{"_id":"b"}}\n' + bad_doc + "\n"
    )
    assert_true(parsed.items[0].ok, "9: a document at the limit indexes")
    assert_false(parsed.items[1].ok, "9: a document over the limit fails")
    assert_equal(parsed.items[1].status, 400, "9: status")
    assert_equal(parsed.count, 1, "9: 1 committed")
    # body + _source + MAX_DYNAMIC_FIELDS inferred columns.
    assert_equal(
        parsed.docbatch.num_columns(), 2 + MAX_DYNAMIC_FIELDS, "9: columns"
    )
    _assert_rectangular(parsed, "9")


def test_10_union_schema_over_field_limit_fails_item() raises:
    var half = MAX_DYNAMIC_FIELDS // 2 + 1
    var first = _doc_with_fields(String("a"), half)
    var second = _doc_with_fields(String("b"), half)
    var third = _doc_with_fields(String("a"), half)  # reuses the first's fields
    var parsed = _parse(
        String('{"index":{"_id":"1"}}\n') + first + "\n"
        + '{"index":{"_id":"2"}}\n' + second + "\n"
        + '{"index":{"_id":"3"}}\n' + third + "\n"
    )
    assert_true(parsed.items[0].ok, "10: first indexes")
    assert_false(parsed.items[1].ok, "10: new fields past the union limit fail")
    assert_equal(
        parsed.items[1].error_type, String("mapper_parsing_exception"), "10: type"
    )
    assert_true(parsed.items[2].ok, "10: a doc with known fields still indexes")
    assert_equal(parsed.count, 2, "10: 2 committed")
    assert_equal(parsed.docbatch.num_columns(), 2 + half, "10: columns")
    _assert_rectangular(parsed, "10")


# =============================================================================
# 11 — a line that is not UTF-8 fails its item.
# =============================================================================


def test_11_invalid_utf8_fails_item() raises:
    var body = _bytes(String('{"index":{"_id":"a"}}\n{"body":"x'))
    body.append(UInt8(0xFF))
    body.append(UInt8(0xFE))
    for b in _bytes(String('"}\n{"index":{"_id":"b"}}\n{"body":"fine"}\n')):
        body.append(b)
    var parsed = ndjson_bulk_to_docbatch(Span(body), String("body"))
    assert_equal(len(parsed.items), 2, "11: 2 items")
    assert_false(parsed.items[0].ok, "11: ill-formed UTF-8 fails its item")
    assert_equal(
        parsed.items[0].error_type, String("parse_exception"), "11: type"
    )
    assert_true(parsed.items[1].ok, "11: neighbour indexes")
    assert_equal(parsed.count, 1, "11: 1 committed")
    _assert_rectangular(parsed, "11")


# =============================================================================
# 12 — a non-finite score keeps the envelope valid JSON.
# =============================================================================


def test_12_non_finite_score_renders_null() raises:
    var inf = Float64(1.0) / Float64(0.0)
    var scores = List[Float64]()
    scores.append(inf)
    var ids = List[Int64]()
    ids.append(Int64(0))
    var sources = List[String]()
    sources.append(String('{"body":"a"}'))
    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(scores)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids)
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(sources)))
    var hb = rb.build(hit_schema())
    var env = hitbatch_to_hits_envelope(
        hb, String("docs"), List[String](), 1, TRACK_TOTAL_DEFAULT, True
    )
    # Parses as JSON (it would not with a bare `inf`), and the score is null.
    var root = parse_json_value(env)
    var hits = root.get(String("hits")).get(String("hits"))
    assert_true(
        hits.element_at(0).get(String("_score")).is_null(), "12: _score null"
    )
    assert_true(
        root.get(String("hits")).get(String("max_score")).is_null(),
        "12: max_score null",
    )


# =============================================================================
# 13 — size / from must be non-negative integers inside the window.
# =============================================================================


def test_13_size_and_from_values_are_checked() raises:
    var base = String('{"query":{"match":{"body":"a"}},')
    var e = _search_raises(base + '"size":-1}')
    assert_true(e.find("non-negative") >= 0, "13: size -1: " + e)
    e = _search_raises(base + '"from":-1}')
    assert_true(e.find("non-negative") >= 0, "13: from -1: " + e)
    # Not an integer: a fraction, an exponent, a string, a bool, an Int64
    # overflow.
    for bad in [
        String("1.5"), String("1e30"), String('"x"'), String("true"),
        String("99999999999999999999"),
    ]:
        assert_true(
            _search_raises(base + '"size":' + bad + "}") != String(""),
            "13: size " + bad,
        )
        assert_true(
            _search_raises(base + '"from":' + bad + "}") != String(""),
            "13: from " + bad,
        )


# =============================================================================
# 14 — one clause per object where the DSL takes one.
# =============================================================================


def test_13b_numeric_string_size_is_coerced() raises:
    # OpenSearch reads "5" as 5; so does the parser, and the window still applies.
    var base = String('{"query":{"match":{"body":"a"}},')
    assert_equal(_search_raises(base + '"size":"5"}'), String(""), "13b: ok")
    var e = _search_raises(base + '"size":"10001"}')
    assert_true(e.find("Result window is too large") >= 0, "13b: " + e)


def test_14_sibling_clauses_are_refused_not_dropped() raises:
    var one = String("more than one")
    # `match` and `bool` side by side: the bool's tenant filter would be
    # dropped.
    var e = _search_raises(
        String(
            '{"query":{"match":{"body":"x"},"bool":{"filter":'
            '[{"term":{"tenant":"a"}}]}}}'
        )
    )
    assert_true(e.find(one) >= 0, "14: match + bool: " + e)
    # `match_all` and `term` with aggs: the term would be dropped and the whole
    # split aggregated.
    e = _search_raises(
        String(
            '{"query":{"match_all":{},"term":{"tenant":"a"}},'
            '"aggs":{"a":{"avg":{"field":"f"}}}}'
        )
    )
    assert_true(e.find(one) >= 0, "14: match_all + term: " + e)
    # A field map naming two fields.
    e = _search_raises(
        String(
            '{"query":{"bool":{"must":[{"match":{"body":"x"}},'
            '{"term":{"tenant":"a","status":"b"}}]}}}'
        )
    )
    assert_true(e.find(one) >= 0, "14: term with two fields: " + e)
    e = _search_raises(
        String(
            '{"query":{"bool":{"must":[{"match":{"body":"x"}},'
            '{"range":{"a":{"gte":1},"b":{"lte":2}}}]}}}'
        )
    )
    assert_true(e.find(one) >= 0, "14: range with two fields: " + e)
    e = _search_raises(String('{"query":{"match":{"body":"x","title":"y"}}}'))
    assert_true(e.find(one) >= 0, "14: match with two fields: " + e)
    # A bool-arm element holding both `match` and `term`.
    e = _search_raises(
        String(
            '{"query":{"bool":{"filter":[{"match":{"body":"x"},'
            '"term":{"tenant":"a"}}]}}}'
        )
    )
    assert_true(e.find(one) >= 0, "14: arm element with two clauses: " + e)


# =============================================================================
# 15 — aggregation count and terms size are capped.
# =============================================================================


def _aggs_body(n: Int) -> String:
    var s = String('{"query":{"match":{"body":"a"}},"aggs":{')
    for i in range(n):
        if i > 0:
            s += ","
        s += '"a' + String(i) + '":{"avg":{"field":"f"}}'
    s += "}}"
    return s


def test_15_aggs_count_and_terms_size_are_capped() raises:
    assert_equal(_search_raises(_aggs_body(MAX_AGGS)), String(""), "15: at cap")
    var e = _search_raises(_aggs_body(MAX_AGGS + 1))
    assert_true(e.find("too many aggregations") >= 0, "15: over cap: " + e)
    var terms = String(
        '{"query":{"match":{"body":"a"}},"aggs":{"g":{"terms":{"field":"f",'
        '"size":'
    )
    assert_equal(
        _search_raises(terms + String(MAX_TERMS_SIZE) + "}}}}"),
        String(""),
        "15: terms size at cap",
    )
    for big in [String(MAX_TERMS_SIZE + 1), String("9223372036854775807")]:
        e = _search_raises(terms + big + "}}}}")
        assert_true(e.find("terms.size") >= 0, "15: terms size " + big + e)
    # The same aggregation name twice is a duplicate key.
    e = _search_raises(
        String(
            '{"query":{"match":{"body":"a"}},"aggs":{"a":{"avg":{"field":"f"}},'
            '"a":{"sum":{"field":"f"}}}}'
        )
    )
    assert_true(e.find("duplicate") >= 0, "15: duplicate agg name: " + e)


# =============================================================================
# 16 — a key named twice is refused.
# =============================================================================


def test_16_duplicate_keys_are_refused() raises:
    var e = _search_raises(
        String('{"query":{"match":{"body":"a"}},"size":1,"size":10000}')
    )
    assert_true(e.find("duplicate") >= 0, "16: search body: " + e)
    var parsed = _parse(
        String(
            '{"index":{"_id":"a"},"index":{"_id":"b"}}\n{"body":"alpha"}\n'
            '{"index":{"_id":"c"}}\n{"body":"gamma"}\n'
        )
    )
    assert_equal(len(parsed.items), 2, "16: 2 items")
    assert_false(parsed.items[0].ok, "16: duplicate action key fails")
    assert_equal(
        parsed.items[0].error_type, String("parse_exception"), "16: type"
    )
    assert_true(parsed.items[1].ok, "16: neighbour indexes")
    assert_equal(parsed.count, 1, "16: 1 committed")
    _assert_rectangular(parsed, "16")


# =============================================================================
# 17 — options that change the result set are refused, not ignored.
# =============================================================================


def test_17_result_changing_options_are_refused() raises:
    var m = String('{"query":{"match":{"body":"a"}},')
    for key in [
        String('"min_score":1'), String('"post_filter":{"term":{"a":"b"}}'),
        String('"collapse":{"field":"a"}'), String('"rescore":{}'),
        String('"terminate_after":1'),
    ]:
        assert_true(
            _search_raises(m + key + "}").find("unsupported") >= 0,
            "17: " + key,
        )
    # match options that change which documents match.
    for opt in [
        String('"operator":"and"'), String('"minimum_should_match":2'),
        String('"fuzziness":"AUTO"'),
    ]:
        var e = _search_raises(
            String('{"query":{"match":{"body":{"query":"a",') + opt + "}}}}"
        )
        assert_true(e.find("unsupported") >= 0, "17: match " + opt + e)
    # Harmless forms still parse.
    assert_equal(
        _search_raises(
            String(
                '{"query":{"match":{"body":{"query":"a","operator":"or",'
                '"boost":2}}},"_source":false,"timeout":"1s"}'
            )
        ),
        String(""),
        "17: harmless options parse",
    )


# =============================================================================
# 18-19 — _bulk framing.
# =============================================================================


def test_18_unbalanced_quote_costs_one_item() raises:
    var parsed = _parse(
        String(
            '{"index":{"_id":"a"}}\n{"body":"x\n'
            '{"index":{"_id":"b"}}\n{"body":"ok"}\n'
        )
    )
    assert_equal(len(parsed.items), 2, "18: still two items")
    assert_false(parsed.items[0].ok, "18: the broken line fails its item")
    assert_equal(parsed.items[0].client_id, String("a"), "18: id a")
    assert_true(parsed.items[1].ok, "18: the next document indexes")
    assert_equal(parsed.items[1].client_id, String("b"), "18: id b")
    assert_equal(parsed.count, 1, "18: 1 committed")
    _assert_rectangular(parsed, "18")


def test_19_delete_has_no_source_line() raises:
    var parsed = _parse(
        String(
            '{"delete":{"_id":"d1"}}\n'
            '{"index":{"_id":"a"}}\n{"body":"alpha"}\n'
            '{"delete":{"_id":"d2"}}\n'
        )
    )
    assert_equal(len(parsed.items), 3, "19: one item per action")
    assert_false(parsed.items[0].ok, "19: delete unsupported")
    assert_equal(parsed.items[0].verb, String("delete"), "19: verb")
    assert_equal(parsed.items[0].client_id, String("d1"), "19: id")
    assert_equal(
        parsed.items[0].error_type, String("action_not_supported"), "19: type"
    )
    assert_true(parsed.items[1].ok, "19: the document between indexes")
    assert_equal(parsed.items[1].client_id, String("a"), "19: id a")
    assert_equal(parsed.items[2].verb, String("delete"), "19: trailing delete")
    assert_equal(parsed.count, 1, "19: 1 committed")
    _assert_rectangular(parsed, "19")
    # The response item is keyed by the verb.
    var env = bulk_response_envelope_items(
        String("docs"), parsed.items, parsed.any_error
    )
    var items = parse_json_value(env).get(String("items"))
    assert_true(items.element_at(0).has(String("delete")), "19: keyed delete")
    assert_true(items.element_at(1).has(String("index")), "19: keyed index")
    assert_true(items.element_at(2).has(String("delete")), "19: keyed delete")
    # An update has a source line: it is consumed with its action.
    var upd = _parse(
        String(
            '{"update":{"_id":"u"}}\n{"doc":{"body":"z"}}\n'
            '{"index":{"_id":"b"}}\n{"body":"beta"}\n'
        )
    )
    assert_equal(len(upd.items), 2, "19: update + index")
    assert_equal(upd.items[0].verb, String("update"), "19: update verb")
    assert_true(upd.items[1].ok, "19: index after update")


def test_19b_dangling_action_raises() raises:
    var raised = False
    try:
        _ = _parse(
            String('{"index":{"_id":"a"}}\n{"body":"x"}\n{"index":{}}\n')
        )
    except e:
        raised = String(e).find("dangling") >= 0
    assert_true(raised, "19b: a final index action with no source raises")


# =============================================================================
# 20 — documents times mapped fields is bounded.
# =============================================================================


def test_20_batch_cell_budget_bounds_memory() raises:
    # One document with many fields, then one-field documents: every committed
    # document pads every mapped field, so documents times fields would grow
    # without bound if only the field count were capped. A small budget keeps
    # the case cheap; the production default is MAX_BATCH_CELLS.
    var wide = 100
    var budget = 1000
    var fit = budget // wide
    var body = String('{"index":{}}\n') + _doc_with_fields(String("f"), wide) + "\n"
    for _ in range(fit + 2):
        body += '{"index":{}}\n{"body":"a"}\n'
    var bytes = _bytes(body)
    var parsed = ndjson_bulk_to_docbatch(Span(bytes), String("body"), budget)
    assert_equal(len(parsed.items), fit + 3, "20: one item per action")
    assert_equal(parsed.count, fit, "20: the cell budget stops the batch")
    assert_true(parsed.items[fit - 1].ok, "20: last document inside the budget")
    assert_false(parsed.items[fit].ok, "20: first document over the budget")
    assert_equal(
        parsed.items[fit].error_type, String("mapper_parsing_exception"), "20"
    )
    assert_true(parsed.items[fit].error_reason.find("cells") >= 0, "20: reason")
    assert_false(parsed.items[fit + 1].ok, "20: later documents fail too")
    assert_true(parsed.any_error, "20: errors true")
    _assert_rectangular(parsed, "20")
    # The default budget admits a wide document on its own.
    var one = _parse(
        String('{"index":{}}\n') + _doc_with_fields(String("f"), MAX_DYNAMIC_FIELDS)
        + "\n"
    )
    assert_equal(one.count, 1, "20: a wide document fits the default budget")
    assert_true(MAX_BATCH_CELLS >= MAX_DYNAMIC_FIELDS, "20: budget >= one doc")


# =============================================================================
# 21 — ill-formed UTF-8 in an action line and in an unterminated last line.
# =============================================================================


def test_21_invalid_utf8_in_action_and_last_line() raises:
    var body = _bytes(String('{"index":{"_id":"'))
    body.append(UInt8(0xFF))
    for b in _bytes(
        String(
            '"}}\n{"body":"x"}\n{"index":{"_id":"b"}}\n{"body":"fine"}'
        )
    ):
        body.append(b)
    var parsed = ndjson_bulk_to_docbatch(Span(body), String("body"))
    assert_equal(len(parsed.items), 2, "21: 2 items")
    assert_false(parsed.items[0].ok, "21: ill-formed action line fails")
    assert_equal(
        parsed.items[0].error_type, String("parse_exception"), "21: type"
    )
    assert_true(parsed.items[1].ok, "21: neighbour (no final newline) indexes")
    assert_equal(parsed.count, 1, "21: 1 committed")
    _assert_rectangular(parsed, "21")

    var tail = _bytes(
        String('{"index":{"_id":"a"}}\n{"body":"ok"}\n{"index":{"_id":"b"}}\n{"body":"x')
    )
    tail.append(UInt8(0xFF))
    var parsed2 = ndjson_bulk_to_docbatch(Span(tail), String("body"))
    assert_equal(len(parsed2.items), 2, "21: 2 items (tail)")
    assert_true(parsed2.items[0].ok, "21: first indexes")
    assert_false(parsed2.items[1].ok, "21: ill-formed last line fails")
    assert_equal(parsed2.count, 1, "21: 1 committed (tail)")
    _assert_rectangular(parsed2, "21 tail")


# =============================================================================
# 22-23 — response envelopes stay valid JSON.
# =============================================================================


def test_22_non_finite_aggregates_render_null() raises:
    var inf = Float64(1.0) / Float64(0.0)
    var nan = inf - inf
    var results = List[AggResult]()
    var s = AggResult(String("s"), AGG_KIND_SUM)
    s.sum = inf
    results.append(s^)
    var a = AggResult(String("a"), AGG_KIND_AVG)
    a.count = 1
    a.sum = nan
    a.has_value = True
    results.append(a^)
    var mn = AggResult(String("mn"), AGG_KIND_MIN)
    mn.min = -inf
    mn.has_value = True
    results.append(mn^)
    var mx = AggResult(String("mx"), AGG_KIND_MAX)
    mx.max = inf
    mx.has_value = True
    results.append(mx^)
    var st = AggResult(String("st"), AGG_KIND_STATS)
    st.count = 1
    st.min = -inf
    st.max = inf
    st.sum = nan
    st.has_value = True
    results.append(st^)
    var obj = agg_results_to_aggregations_object(AggResults(results^))
    var root = parse_json_value(obj.serialize())
    for name in [String("s"), String("a"), String("mn"), String("mx")]:
        assert_true(
            root.get(name).get(String("value")).is_null(), "22: " + name
        )
    var stats = root.get(String("st"))
    for member in [String("min"), String("max"), String("avg"), String("sum")]:
        assert_true(stats.get(member).is_null(), "22: stats " + member)
    assert_equal(Int(stats.get(String("count")).as_int64()), 1, "22: count")


def test_23_empty_envelope_track_total_and_skeleton() raises:
    var no_total = parse_json_value(
        empty_hits_envelope(
            String("docs"), AggResults(), False, TRACK_TOTAL_FALSE
        )
    )
    assert_false(
        no_total.get(String("hits")).has(String("total")),
        "23: track_total_hits:false omits total",
    )
    var with_total = parse_json_value(empty_hits_envelope(String("docs")))
    assert_true(
        with_total.get(String("hits")).has(String("total")), "23: default"
    )
    # The caller supplies the skeleton: one unfolded result per requested agg.
    var results = List[AggResult]()
    results.append(AggResult(String("g"), AGG_KIND_TERMS))
    results.append(AggResult(String("n"), AGG_KIND_AVG))
    var skeleton = parse_json_value(
        empty_hits_envelope(
            String("docs"), AggResults(results^), True
        )
    ).get(String("aggregations"))
    assert_equal(
        skeleton.get(String("g")).get(String("buckets")).array_len(), 0, "23"
    )
    assert_true(skeleton.get(String("n")).get(String("value")).is_null(), "23")


# =============================================================================
# 24 — a filter-only bool query with aggs is refused, not aggregated unfiltered.
# =============================================================================


def test_24_filter_only_bool_with_aggs_refused() raises:
    var e = _search_raises(
        String(
            '{"query":{"bool":{"filter":[{"term":{"tenant":"a"}}]}},'
            '"aggs":{"a":{"avg":{"field":"f"}}}}'
        )
    )
    assert_true(e.find("filter-only") >= 0, "24: " + e)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

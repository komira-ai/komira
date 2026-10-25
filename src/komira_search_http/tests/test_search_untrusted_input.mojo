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

from komira_search.source import hit_schema

from komira_search_http.bulk import (
    ndjson_bulk_to_docbatch,
    BulkParse,
    MAX_DYNAMIC_FIELDS,
)
from komira_search_http.envelopes import (
    hitbatch_to_hits_envelope,
    TRACK_TOTAL_DEFAULT,
)
from komira_search_http.search_query import (
    search_json_to_queryir,
    MAX_BOOL_CLAUSES,
    MAX_RESULT_WINDOW,
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
        _ = search_json_to_queryir(Span(b), Int64(0))
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

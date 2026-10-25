# =============================================================================
# test_search_bulk_partial_success.mojo — P1.7 _bulk PER-ITEM
# PARTIAL-SUCCESS proof
# =============================================================================
#
# Source of truth: the bulk dynamic-mapping design (per-item outcome policy),
# §A6 (the per-item partial-success follow-on).
#
# This is the test that does the thing that 400'd the WHOLE request before P1.7:
# a `_bulk` body with a MIX of good and bad docs now returns per-item outcomes
# (HTTP 200, `{errors, items[]}` in NDJSON order); the GOOD docs still index and
# are searchable, the BAD docs are excluded with a per-item status-400 error.
#
# The translator-level seam is `ndjson_bulk_to_docbatch` -> BulkParse{docbatch
# (good docs only), items (NDJSON order), count (good), any_error}. These tests
# drive the translator directly, then (for searchability) the docbatch ->
# SearchSink -> SearchCore (mirrors test_search_bulk_dynamic_mapping). The
# handler-level wiring (the per-item HTTP envelope) is unit-tested in
# test_search_opensearch_shim (bulk_response_envelope_items).
#
# Cases (the bug-fix protocol — these FAIL pre-fix, where the whole request
# raised on the first bad doc):
#   1. CLEAN batch -> count==N, errors false, all items 201/created, all docs
#      searchable.
#   2. MIXED batch (2 good + 1 non-index action + 1 missing-body + 1 type-conflict
#      doc) -> errors true, per-item status correct IN NDJSON ORDER, the GOOD
#      docs searchable + the bad ones absent.
#   3. ALL-BAD batch -> errors true, count 0, no doc searchable.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
)

from komira_arrow.record_batch import RecordBatch

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.source import QueryIR, SearchCore

from komira_search_http.bulk import ndjson_bulk_to_docbatch, BulkParse


# -----------------------------------------------------------------------------
# Helpers (mirror test_search_bulk_dynamic_mapping).
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
    var body = _bytes(ndjson)
    return ndjson_bulk_to_docbatch(Span(body), String("body"))


def _drive_sink_from_parsed(
    mut parsed: BulkParse, seed: UInt8
) raises -> List[UInt8]:
    """The committed (good-docs) docbatch -> SearchSink -> split bytes."""
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


def _match_count(var bytes: List[UInt8], term: String) raises -> Int:
    """The number of hits for a bare-match query on `body` over the split."""
    var core = SearchCore(bytes^)
    var q = QueryIR(String("body"), term, 100, _text_cfg(), 0)
    return core.search(q).batch.num_rows()


# =============================================================================
# Case 1 — clean batch -> all 201, all searchable.
# =============================================================================


def test_01_clean_batch_all_created() raises:
    var ndjson = String(
        '{"index":{"_id":"a"}}\n'
        '{"body":"alpha one"}\n'
        '{"index":{"_id":"b"}}\n'
        '{"body":"alpha two"}\n'
        '{"index":{"_id":"c"}}\n'
        '{"body":"alpha three"}\n'
    )
    var parsed = _parse(ndjson)
    assert_equal(parsed.count, 3, "1: 3 good docs")
    assert_false(parsed.any_error, "1: errors false")
    assert_equal(len(parsed.items), 3, "1: 3 items")
    for i in range(3):
        assert_true(parsed.items[i].ok, "1: item created")
        assert_equal(parsed.items[i].status, 201, "1: status 201")
        assert_equal(parsed.items[i].result, String("created"), "1: created")
    assert_equal(parsed.items[0].client_id, String("a"))
    assert_equal(parsed.items[1].client_id, String("b"))
    assert_equal(parsed.items[2].client_id, String("c"))

    # All 3 docs are searchable.
    var bytes = _drive_sink_from_parsed(parsed, 1)
    assert_equal(_match_count(bytes^, String("alpha")), 3, "1: 3 docs searchable")


# =============================================================================
# Case 2 — mixed batch: 2 good + non-index + missing-body + type-conflict.
# =============================================================================


def test_02_mixed_batch_partial_success() raises:
    # NDJSON order:
    #   item0: GOOD          (index, body "alpha keep0", status active)
    #   item1: non-index     (create action) -> action_not_supported 400
    #   item2: missing-body  -> mapper_parsing_exception 400
    #   item3: GOOD          (index, body "alpha keep3", status sold)
    #   item4: type-conflict (status int 5, conflicts established STRING) -> 400
    var ndjson = String(
        '{"index":{"_id":"g0"}}\n'
        '{"body":"alpha keep0","status":"active"}\n'
        '{"create":{"_id":"x1"}}\n'
        '{"body":"alpha bad1"}\n'
        '{"index":{"_id":"x2"}}\n'
        '{"title":"alpha bad2"}\n'
        '{"index":{"_id":"g3"}}\n'
        '{"body":"alpha keep3","status":"sold"}\n'
        '{"index":{"_id":"x4"}}\n'
        '{"body":"alpha bad4","status":5}\n'
    )
    var parsed = _parse(ndjson)

    # Two good docs committed; errors true; 5 items in NDJSON order.
    assert_equal(parsed.count, 2, "2: two committed docs")
    assert_true(parsed.any_error, "2: errors true")
    assert_equal(len(parsed.items), 5, "2: five items")

    # item0 GOOD.
    assert_true(parsed.items[0].ok, "2: item0 created")
    assert_equal(parsed.items[0].status, 201)
    assert_equal(parsed.items[0].client_id, String("g0"))

    # item1 non-index -> action_not_supported 400, _id echoed.
    assert_false(parsed.items[1].ok, "2: item1 failed")
    assert_equal(parsed.items[1].status, 400)
    assert_equal(
        parsed.items[1].error_type, String("action_not_supported")
    )
    assert_equal(parsed.items[1].client_id, String("x1"))

    # item2 missing-body -> mapper_parsing_exception 400.
    assert_false(parsed.items[2].ok, "2: item2 failed")
    assert_equal(parsed.items[2].status, 400)
    assert_equal(
        parsed.items[2].error_type, String("mapper_parsing_exception")
    )
    assert_equal(parsed.items[2].client_id, String("x2"))

    # item3 GOOD.
    assert_true(parsed.items[3].ok, "2: item3 created")
    assert_equal(parsed.items[3].status, 201)
    assert_equal(parsed.items[3].client_id, String("g3"))

    # item4 type-conflict (int at established STRING) -> 400.
    assert_false(parsed.items[4].ok, "2: item4 failed")
    assert_equal(parsed.items[4].status, 400)
    assert_equal(
        parsed.items[4].error_type, String("mapper_parsing_exception")
    )
    assert_equal(parsed.items[4].client_id, String("x4"))

    # The two GOOD docs are searchable; the bad-doc bodies are absent (their
    # rows were never built). keep0 + keep3 match "keep"-prefixed tokens.
    var bytes = _drive_sink_from_parsed(parsed, 2)
    var core = SearchCore(bytes.copy())
    # "alpha" matches BOTH committed docs (2), and NONE of the excluded docs.
    var q = QueryIR(String("body"), String("alpha"), 100, _text_cfg(), 0)
    assert_equal(
        core.search(q).batch.num_rows(), 2, "2: exactly the 2 good docs"
    )
    # The bad-doc bodies (bad1/bad2/bad4) never indexed.
    var core2 = SearchCore(bytes^)
    var q_bad = QueryIR(String("body"), String("bad1"), 100, _text_cfg(), 0)
    assert_equal(
        core2.search(q_bad).batch.num_rows(), 0, "2: bad doc absent"
    )


# =============================================================================
# Case 3 — all-bad batch -> errors true, count 0, no doc searchable.
# =============================================================================


def test_03_all_bad_batch_no_doc_indexed() raises:
    var ndjson = String(
        '{"create":{"_id":"x0"}}\n'
        '{"body":"alpha bad0"}\n'
        '{"index":{"_id":"x1"}}\n'
        '{"title":"alpha bad1"}\n'
        '{"index":{"_id":"x2"}}\n'
        '{"body":"alpha bad2","obj":{"a":1}}\n'
    )
    var parsed = _parse(ndjson)
    assert_equal(parsed.count, 0, "3: zero good docs")
    assert_true(parsed.any_error, "3: errors true")
    assert_equal(len(parsed.items), 3, "3: three items")
    for i in range(3):
        assert_false(parsed.items[i].ok, "3: item failed")
        assert_equal(parsed.items[i].status, 400, "3: status 400")
    # item0 non-index.
    assert_equal(
        parsed.items[0].error_type, String("action_not_supported")
    )
    # item2 nested object.
    assert_equal(
        parsed.items[2].error_type, String("mapper_parsing_exception")
    )

    # No doc indexed: count==0, so the handler returns the all-error envelope and
    # publishes NO split (it never feeds the sink — the empty-batch path is the
    # dispatcher's count==0 short-circuit). The committed docbatch is empty.
    assert_equal(parsed.docbatch.num_rows(), 0, "3: empty docbatch")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

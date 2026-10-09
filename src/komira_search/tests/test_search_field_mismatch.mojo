# =============================================================================
# test_search_field_mismatch.mojo -- SearchCore answers only queries on the
# text field its split indexes.
#
# A split records the one text field it was built for (`SplitView.field_name`)
# and a QueryIR names the field it targets (`QueryIR.field_name`). The term
# dictionary of a split holds that field's terms only, so a query on any other
# field must not be scored against it.
#
# Pins:
#   * a `match` on another field is refused by name
#     (`SEARCH_QUERY_FIELD_MISMATCH`, naming both fields) on every scoring
#     path (`search`, `search_bmw`, `search_no_wand`), even when the query term
#     is present in the split;
#   * a `match_all` on another field is refused the same way (it would
#     otherwise return every document of the split);
#   * a query on the split's own field still returns its hits.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.source import QueryIR, SearchCore


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _split_on(field: String) raises -> List[UInt8]:
    """A split indexing `field` over two documents: "the quick fox" (_source
    "d0") and "lazy dog" (_source "d1")."""
    var sb = SchemaBuilder()
    sb.add_field(Field(field, ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(
        Column.from_string(
            StringArray.from_strings(
                [String("the quick fox"), String("lazy dog")]
            )
        )
    )
    rb.add_column(
        Column.from_string(
            StringArray.from_strings([String("d0"), String("d1")])
        )
    )
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("bucket"), String("prefix"), String("logs"), field, _uuid(3)
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _query(field: String, text: String, match_all: Bool = False) -> QueryIR:
    return QueryIR(
        field, text, 10, AnalyzerConfig.text(field), 0, None,
        match_all=match_all,
    )


def _assert_refused(msg: String, what: String) raises:
    assert_true("SEARCH_QUERY_FIELD_MISMATCH" in msg, what + ": " + msg)
    assert_true("'title'" in msg, what + " names the query field: " + msg)
    assert_true("'body'" in msg, what + " names the split field: " + msg)


def test_a_query_on_another_field_is_refused_on_every_path() raises:
    var core = SearchCore(_split_on(String("body")))
    assert_equal(core.field_name(), String("body"), "setup: a body split")
    # "fox" IS in the split's term dictionary: only the field check can
    # refuse it.
    var q = _query(String("title"), String("fox"))

    var raised = False
    try:
        _ = core.search(q)
    except err:
        raised = True
        _assert_refused(String(err), "search")
    assert_true(raised, "search: a title query on a body split is refused")

    raised = False
    try:
        _ = core.search_bmw(q)
    except err:
        raised = True
        _assert_refused(String(err), "search_bmw")
    assert_true(raised, "search_bmw: refused")

    raised = False
    try:
        _ = core.search_no_wand(q)
    except err:
        raised = True
        _assert_refused(String(err), "search_no_wand")
    assert_true(raised, "search_no_wand: refused")


def test_a_match_all_on_another_field_is_refused() raises:
    var core = SearchCore(_split_on(String("body")))
    var raised = False
    try:
        _ = core.search(_query(String("title"), String(""), match_all=True))
    except err:
        raised = True
        _assert_refused(String(err), "match_all")
    assert_true(raised, "a title match_all on a body split is refused")


def test_a_query_on_the_splits_field_returns_its_hits() raises:
    var core = SearchCore(_split_on(String("body")))
    var res = core.search(_query(String("body"), String("fox")))
    assert_equal(res.total_matches, 1, "one body doc has 'fox'")
    var batch = res.take_batch()
    assert_equal(batch.num_rows(), 1)
    assert_equal(String(batch.column_at(2).as_string().get(0)), String("d0"))
    assert_true(
        Float64(batch.column_at(0).as_primitive[DType.float64]().get(0)) > 0.0,
        "a positive BM25 score",
    )
    # The same holds for a split built on another field name: the check
    # compares names, it does not favour 'body'.
    var title_core = SearchCore(_split_on(String("title")))
    var every = title_core.search(
        _query(String("title"), String(""), match_all=True)
    )
    assert_equal(every.total_matches, 2, "match_all on title: both docs")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

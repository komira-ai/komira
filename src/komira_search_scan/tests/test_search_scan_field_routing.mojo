# =============================================================================
# test_search_scan_field_routing.mojo -- a scan of a multi-field index reads
# only the splits of the binding's field.
#
# An index `logs` declares two analyzed text fields, `body` and `title`, and
# holds one split of each (a split indexes one field: `SplitView.field_name`).
#
# Pins:
#   * a `title` scan plans and reads only the title split: a query term that
#     only the body split holds matches nothing, a term the title split holds
#     returns only title documents, and the no-query scan returns every title
#     document and no body document;
#   * a `body` scan reads only the body split;
#   * `open_split` refuses by name (`SEARCH_SPLIT_KEY_INVALID`) a split key
#     of another field's split, so a hand-built split list cannot route a
#     title query to a body split;
#   * `publish` refuses by name (`SEARCH_INDEX_UNKNOWN`) a split indexing a
#     field the index does not declare.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import resolve_for_execution

from komira_scan_resolver.drain_scan import drain_scan
from komira_scan_resolver.scan_source_resolver import ScanRequest
from komira_scan_resolver.scan_split import ScanSplit

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink

from komira_search_scan.search_split_reader import search_split_position
from komira_search_scan.search_scan_kind import (
    InMemorySearchIndexCatalog,
    SEARCH_INDEX_UNKNOWN,
    SEARCH_SPLIT_KEY_INVALID,
    SearchScanResolver,
    search_scan_kind_id,
    search_split_key,
)


comptime _Resolver = SearchScanResolver[InMemorySearchIndexCatalog]


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _split_on(
    field: String, seed: UInt8, texts: List[String], sources: List[String]
) raises -> List[UInt8]:
    """A split indexing `field`: document i has text `texts[i]` and
    `_source` `sources[i]`."""
    var sb = SchemaBuilder()
    sb.add_field(Field(field, ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_string(StringArray.from_strings(texts)))
    rb.add_column(Column.from_string(StringArray.from_strings(sources)))
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("bucket"), String("prefix"), String("logs"), field, _uuid(seed)
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _body_split() raises -> List[UInt8]:
    return _split_on(
        String("body"),
        1,
        [String("quick fox"), String("lazy dog")],
        [String("b0"), String("b1")],
    )


def _title_split() raises -> List[UInt8]:
    return _split_on(
        String("title"),
        2,
        [String("dog report"), String("weekly summary")],
        [String("t0"), String("t1")],
    )


def _resolver() raises -> _Resolver:
    """`logs` with fields body and title; split 0 indexes body, split 1
    indexes title."""
    var c = InMemorySearchIndexCatalog()
    c.create_index(String("logs"), String("body"), AnalyzerConfig.text("body"))
    c.add_field(String("logs"), String("title"), AnalyzerConfig.text("title"))
    _ = c.publish(String("logs"), _body_split())
    _ = c.publish(String("logs"), _title_split())
    return _Resolver(c^)


def _request(rt: _Resolver, field: String, query: String) raises -> ScanRequest:
    var p = ScanParams()
    p.put_str(String("index"), String("logs"))
    p.put_str(String("field"), field)
    if query != String(""):
        p.put_str(String("query"), query)
    return ScanRequest(resolve_for_execution(rt, rt.build_binding(p)))


def _sources(rt: _Resolver, field: String, query: String) raises -> List[String]:
    """The `_source` of every row the drained scan returns, in order."""
    var opened = drain_scan(rt, _request(rt, field, query))
    var out = List[String]()
    for bi in range(len(opened.batches[])):
        ref b = opened.batches[][bi]
        for r in range(b.num_rows()):
            out.append(String(b.column_at(2).as_string().get(r)))
    return out^


def _assert_sources(got: List[String], want: List[String], what: String) raises:
    var g = String("[")
    for i in range(len(got)):
        g += got[i] + String(" ")
    g += String("]")
    assert_equal(len(got), len(want), what + ": row count, got " + g)
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def test_a_title_scan_reads_only_title_splits() raises:
    var rt = _resolver()
    var plan = rt.plan_splits(_request(rt, String("title"), String("dog")))
    assert_equal(plan.num_splits(), 1, "a title scan plans the title split only")
    assert_equal(plan.splits[0].split_key, search_split_key(String("logs"), 1))
    # "fox" is only in the body split.
    _assert_sources(
        _sources(rt, String("title"), String("fox")),
        List[String](),
        String("title scan for a body-only term"),
    )
    # "dog" is in both splits: only the title document comes back.
    _assert_sources(
        _sources(rt, String("title"), String("dog")),
        [String("t0")],
        String("title scan for 'dog'"),
    )
    # The no-query scan: every title document, no body document.
    _assert_sources(
        _sources(rt, String("title"), String("")),
        [String("t0"), String("t1")],
        String("title no-query scan"),
    )


def test_a_body_scan_reads_only_body_splits() raises:
    var rt = _resolver()
    var plan = rt.plan_splits(_request(rt, String("body"), String("dog")))
    assert_equal(plan.num_splits(), 1, "a body scan plans the body split only")
    assert_equal(plan.splits[0].split_key, search_split_key(String("logs"), 0))
    _assert_sources(
        _sources(rt, String("body"), String("dog")),
        [String("b1")],
        String("body scan for 'dog'"),
    )
    _assert_sources(
        _sources(rt, String("body"), String("")),
        [String("b0"), String("b1")],
        String("body no-query scan"),
    )


def test_open_split_refuses_another_fields_split() raises:
    var rt = _resolver()
    var kind_id = search_scan_kind_id()
    var body_split = ScanSplit(
        search_split_key(String("logs"), 0),
        search_split_position(kind_id, False, 0),
        Optional(search_split_position(kind_id, True, 0)),
    )
    var raised = False
    try:
        _ = rt.open_split(_request(rt, String("title"), String("dog")), body_split)
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_SPLIT_KEY_INVALID) in msg, msg)
        assert_true("'body'" in msg, "names the split's field: " + msg)
        assert_true("'title'" in msg, "names the scan's field: " + msg)
    assert_true(raised, "a title scan never opens the body split")


def test_publish_refuses_a_split_of_an_undeclared_field() raises:
    var c = InMemorySearchIndexCatalog()
    c.create_index(String("logs"), String("body"), AnalyzerConfig.text("body"))
    var raised = False
    try:
        _ = c.publish(String("logs"), _title_split())
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_INDEX_UNKNOWN) in msg, msg)
        assert_true("'title'" in msg, "names the split's field: " + msg)
    assert_true(raised, "a title split on a body-only index is refused")
    assert_equal(c.generation(String("logs")), Int64(0), "nothing published")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

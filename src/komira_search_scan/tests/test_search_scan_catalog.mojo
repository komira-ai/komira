# =============================================================================
# test_search_scan_catalog.mojo -- the catalog seam of the
# `komira.search.index` kind: `InMemorySearchIndexCatalog` and the defaults
# `SearchIndexCatalog` gives a catalog that implements only the four
# required methods.
#
# The index `logs` declares `body` and `title`; it holds three splits in
# publish order: body (b0, b1), title (t0, t1), body (c0, c1).
#
# Pins:
#   * `create_index` refuses an index that exists, and leaves it as it was;
#   * `add_field` refuses a field the index already has, checking every
#     field (not only the first), and records each new field's analyzer;
#   * `splits_at(g)` is the first g splits in publish order, generation 0 to
#     the current one; a generation past it or below 0 is refused by name;
#     an unknown index is refused for the index before the generation, and an
#     unservable generation before an ordinal;
#   * a catalog with only the required methods gets `split_count_at`,
#     `split_at` and `split_field_at` from the trait: a scan through it reads
#     the same rows, split for split, as through the in-memory catalog, and an
#     ordinal past the generation's splits is refused by name;
#   * `catalog()` reads the resolver's catalog.
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

from komira_search_scan.search_source import analyzer_config_fingerprint
from komira_search_scan.search_split_reader import search_split_position
from komira_search_scan.search_scan_kind import (
    InMemorySearchIndexCatalog,
    SEARCH_GENERATION_NOT_AVAILABLE,
    SEARCH_INDEX_UNKNOWN,
    SEARCH_SPLIT_KEY_INVALID,
    SearchIndexCatalog,
    SearchScanResolver,
    search_scan_kind_id,
)


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _split_on(
    field: String, seed: UInt8, texts: List[String], sources: List[String]
) raises -> List[UInt8]:
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


def _body0() raises -> List[UInt8]:
    return _split_on(
        String("body"), 1, [String("quick fox"), String("lazy dog")],
        [String("b0"), String("b1")],
    )


def _title1() raises -> List[UInt8]:
    return _split_on(
        String("title"), 2, [String("dog report"), String("weekly fox")],
        [String("t0"), String("t1")],
    )


def _body2() raises -> List[UInt8]:
    return _split_on(
        String("body"), 3, [String("red fox"), String("blue dog")],
        [String("c0"), String("c1")],
    )


def _title_cfg() -> AnalyzerConfig:
    """Differs from the body analyzer in a fingerprinted field."""
    var c = AnalyzerConfig.text("title")
    c.remove_stopwords = not c.remove_stopwords
    return c^


def _catalog() raises -> InMemorySearchIndexCatalog:
    var c = InMemorySearchIndexCatalog()
    c.create_index(String("logs"), String("body"), AnalyzerConfig.text("body"))
    c.add_field(String("logs"), String("title"), _title_cfg())
    _ = c.publish(String("logs"), _body0())
    _ = c.publish(String("logs"), _title1())
    _ = c.publish(String("logs"), _body2())
    return c^


struct _RequiredOnly(SearchIndexCatalog, Movable, Deinitable):
    """A catalog implementing only the required methods; every other method
    is the trait's default."""

    var _inner: InMemorySearchIndexCatalog

    def __init__(out self, var inner: InMemorySearchIndexCatalog):
        self._inner = inner^

    def generation(self, index: String) raises -> Int64:
        return self._inner.generation(index)

    def analyzer(self, index: String, field: String) raises -> AnalyzerConfig:
        return self._inner.analyzer(index, field)

    def fields(self, index: String) raises -> List[String]:
        return self._inner.fields(index)

    def splits_at(
        self, index: String, generation: Int64
    ) raises -> List[List[UInt8]]:
        return self._inner.splits_at(index, generation)


def _same_bytes(a: List[UInt8], b: List[UInt8], what: String) raises:
    assert_equal(len(a), len(b), what + ": length")
    for i in range(len(a)):
        if a[i] != b[i]:
            assert_true(False, what + ": byte " + String(i))


def _sources_of[C: SearchIndexCatalog](
    rt: SearchScanResolver[C], field: String, query: String
) raises -> List[String]:
    var p = ScanParams()
    p.put_str(String("index"), String("logs"))
    p.put_str(String("field"), field)
    if query != String(""):
        p.put_str(String("query"), query)
    var req = ScanRequest(resolve_for_execution(rt, rt.build_binding(p)))
    var opened = drain_scan(rt, req)
    var out = List[String]()
    for bi in range(len(opened.batches[])):
        ref b = opened.batches[][bi]
        for r in range(b.num_rows()):
            out.append(String(b.column_at(2).as_string().get(r)))
    return out^


def _assert_list(got: List[String], want: List[String], what: String) raises:
    var g = String("[")
    for i in range(len(got)):
        g += got[i] + String(" ")
    assert_equal(len(got), len(want), what + ": got " + g + String("]"))
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


# =============================================================================
# create_index / add_field.
# =============================================================================


def test_create_index_refuses_an_index_that_exists() raises:
    var c = _catalog()
    var raised = False
    try:
        c.create_index(String("logs"), String("other"), _title_cfg())
    except err:
        raised = True
        var msg = String(err)
        assert_true("'logs' already exists" in msg, msg)
    assert_true(raised, "a second create of logs is refused")
    _assert_list(
        c.fields(String("logs")), [String("body"), String("title")],
        "logs keeps its fields",
    )
    assert_equal(c.generation(String("logs")), Int64(3), "and its splits")


def test_add_field_refuses_every_existing_field() raises:
    var c = _catalog()
    var names: List[String] = [String("body"), String("title")]
    for i in range(len(names)):
        var raised = False
        try:
            c.add_field(String("logs"), names[i], _title_cfg())
        except err:
            raised = True
            var msg = String(err)
            assert_true(
                String("already has field '") + names[i] + String("'") in msg,
                msg,
            )
        assert_true(raised, names[i] + String(" twice is refused"))
    _assert_list(
        c.fields(String("logs")), [String("body"), String("title")],
        "no field was added",
    )


def test_add_field_records_the_new_fields_analyzer() raises:
    var c = _catalog()
    c.add_field(String("logs"), String("tags"), AnalyzerConfig.keyword("tags"))
    _assert_list(
        c.fields(String("logs")),
        [String("body"), String("title"), String("tags")],
        "tags is the third field",
    )
    assert_equal(
        analyzer_config_fingerprint(c.analyzer(String("logs"), String("title"))),
        analyzer_config_fingerprint(_title_cfg()),
        "title analyzes with its own config",
    )
    assert_equal(
        analyzer_config_fingerprint(c.analyzer(String("logs"), String("tags"))),
        analyzer_config_fingerprint(AnalyzerConfig.keyword("tags")),
        "tags analyzes with its own config",
    )
    assert_true(
        analyzer_config_fingerprint(c.analyzer(String("logs"), String("title")))
        != analyzer_config_fingerprint(c.analyzer(String("logs"), String("body"))),
        "the two configs differ, so the check above can fail",
    )


# =============================================================================
# splits_at and the generation bound.
# =============================================================================


def test_splits_at_is_the_first_g_splits_in_publish_order() raises:
    var c = _catalog()
    var want = List[List[UInt8]]()
    want.append(_body0())
    want.append(_title1())
    want.append(_body2())
    for g in range(0, 4):
        var got = c.splits_at(String("logs"), Int64(g))
        assert_equal(len(got), g, "generation " + String(g))
        for i in range(g):
            _same_bytes(
                got[i], want[i],
                String("generation ") + String(g) + String(" split ") + String(i),
            )
        assert_equal(c.split_count_at(String("logs"), Int64(g)), g)


def test_an_unservable_generation_is_refused_by_name() raises:
    var c = _catalog()
    var gens: List[Int64] = [Int64(4), Int64(-1)]
    for i in range(len(gens)):
        var raised = False
        try:
            _ = c.splits_at(String("logs"), gens[i])
        except err:
            raised = True
            var msg = String(err)
            assert_true(String(SEARCH_GENERATION_NOT_AVAILABLE) in msg, msg)
            assert_true(
                String("generation ") + String(gens[i]) + String(" cannot")
                in msg,
                msg,
            )
        assert_true(raised, String("generation ") + String(gens[i]))


def test_the_index_is_checked_before_the_generation_before_the_ordinal() raises:
    var c = _catalog()
    var raised = False
    try:
        _ = c.split_at(String("nope"), Int64(9), 9)
    except err:
        raised = True
        assert_true(String(SEARCH_INDEX_UNKNOWN) in String(err), String(err))
    assert_true(raised, "unknown index")
    raised = False
    try:
        _ = c.split_field_at(String("logs"), Int64(9), 9)
    except err:
        raised = True
        assert_true(
            String(SEARCH_GENERATION_NOT_AVAILABLE) in String(err), String(err)
        )
    assert_true(raised, "unservable generation")
    raised = False
    try:
        _ = c.split_field_at(String("logs"), Int64(2), 2)
    except err:
        raised = True
        assert_true(String(SEARCH_SPLIT_KEY_INVALID) in String(err), String(err))
    assert_true(raised, "an ordinal at the generation's split count")


# =============================================================================
# The trait's defaults.
# =============================================================================


def test_the_trait_defaults_read_what_the_in_memory_catalog_reads() raises:
    var mem = SearchScanResolver[InMemorySearchIndexCatalog](_catalog())
    var dflt = SearchScanResolver[_RequiredOnly](_RequiredOnly(_catalog()))
    assert_equal(mem.catalog().generation(String("logs")), Int64(3))
    var cases: List[String] = [String(""), String("fox"), String("dog")]
    for i in range(len(cases)):
        var body_mem = _sources_of(mem, String("body"), cases[i])
        _assert_list(
            _sources_of(dflt, String("body"), cases[i]), body_mem,
            String("body '") + cases[i] + String("'"),
        )
        _assert_list(
            _sources_of(dflt, String("title"), cases[i]),
            _sources_of(mem, String("title"), cases[i]),
            String("title '") + cases[i] + String("'"),
        )
    # The literal answer, so both paths cannot be wrong together.
    _assert_list(
        _sources_of(dflt, String("body"), String("")),
        [String("b0"), String("b1"), String("c0"), String("c1")],
        "body: splits 0 and 2",
    )
    _assert_list(
        _sources_of(dflt, String("title"), String("")),
        [String("t0"), String("t1")],
        "title: split 1",
    )


def test_the_default_split_at_refuses_an_ordinal_past_the_generation() raises:
    var rt = SearchScanResolver[_RequiredOnly](_RequiredOnly(_catalog()))
    var p = ScanParams()
    p.put_str(String("index"), String("logs"))
    p.put_str(String("field"), String("body"))
    var req = ScanRequest(resolve_for_execution(rt, rt.build_binding(p)))
    var id = search_scan_kind_id()
    var raised = False
    try:
        _ = rt.open_split(
            req,
            ScanSplit(
                String("logs/3"),
                search_split_position(id, False, 0),
                Optional(search_split_position(id, True, 0)),
            ),
        )
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_SPLIT_KEY_INVALID) in msg, msg)
        assert_true("has 3 splits at generation 3; split 3" in msg, msg)
    assert_true(raised, "logs/3 is not a split of generation 3")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

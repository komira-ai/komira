# =============================================================================
# test_search_scan_kind.mojo -- the `komira.search.index` scan kind.
# EXECUTOR-FREE: no EngineContext, no query
# engine -- the kind is driven through core's tier-1 entry point
# (`resolve_for_execution`) and its own tier-2 `open_scan`, over an in-memory
# catalog.
#
# Pins:
#   * the kind name is `komira.search.index`;
#   * the hits equal `SearchCore` called directly, split by split;
#   * the generation is RE-RESOLVED per execution (LIVE) and the cached plan
#     keeps token 0;
#   * the cache key (fingerprint, identity_hash, render, the plan's
#     structural_hash) survives a publish;
#   * a stated generation is a pin: it reads that generation, and is identity;
#   * a no-query scan returns every live document, re-resolved per
#     execution; a stopword-only query still matches nothing;
#   * fast-field conjuncts of a request predicate are lowered into the search;
#   * the identity corpus passes core's audit;
#   * refusals are by name (unknown index, analyzer drift, foreign kind,
#     unservable pin, missing required param).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.expr import Expr, BIN_AND, BIN_EQ, BIN_GE, BIN_GT
from komira_core.plan.logical_plan import LogicalPlan
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.scan_identity_render_audit import audit_scan_identity
from komira_core.source.scan_binding import ScanBinding
from komira_core.source.scan_identity_audit import ScanIdentityCorpus
from komira_core.source.scan_kind_registry import ScanKindRegistry
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_resolver import resolve_for_execution
from komira_core.source.source_variant import SourceVariant

from komira_scan_resolver.scan_morsel_resolver import (
    SCAN_BINDING_MISSING_PARAMS,
    ScanOpened,
    ScanRequest,
)

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.source import QueryIR, SearchCore

from komira_search_runtime.search_source import analyzer_config_fingerprint
from komira_search_runtime.search_scan_kind import (
    InMemorySearchIndexCatalog,
    SEARCH_ANALYZER_MISMATCH,
    SEARCH_GENERATION_NOT_AVAILABLE,
    SEARCH_INDEX_UNKNOWN,
    SEARCH_RESOLVED_GENERATION,
    SEARCH_SCAN_KIND_NAME,
    SearchScanRuntime,
    search_scan_descriptor,
    search_scan_identity_corpus,
    search_scan_kind_id,
    search_scan_runtime,
)


comptime _Runtime = SearchScanRuntime[InMemorySearchIndexCatalog]


# -----------------------------------------------------------------------------
# Fixtures: two splits written by the production SearchSink.
#   split A: "alpha beta" | "alpha alpha" | "gamma the"   (status, price)
#            a0 active 50 | a1 sold 100   | a2 active 150
#   split B: "alpha"      | "delta"
#            b0 sold 10   | b1 active 20
# -----------------------------------------------------------------------------


def _cfg() -> AnalyzerConfig:
    return AnalyzerConfig.text("body")


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def _i64_col(values: List[Int64]) raises -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, True))  # keyword
    sb.add_field(Field("price", ArrowType.INT64, True))
    return sb.build()


def _split(
    seed: UInt8,
    bodies: List[String],
    sources: List[String],
    statuses: List[String],
    prices: List[Int64],
) raises -> List[UInt8]:
    var schema = _schema()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(_str_col(bodies))
    rb.add_column(_str_col(sources))
    rb.add_column(_str_col(statuses))
    rb.add_column(_i64_col(prices))
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("bucket"), String("prefix"), String("logs"), String("body"),
        _uuid(seed),
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _split_a() raises -> List[UInt8]:
    return _split(
        1,
        [String("alpha beta"), String("alpha alpha"), String("gamma the")],
        [String("a0"), String("a1"), String("a2")],
        [String("active"), String("sold"), String("active")],
        [Int64(50), Int64(100), Int64(150)],
    )


def _split_b() raises -> List[UInt8]:
    return _split(
        2,
        [String("alpha"), String("delta")],
        [String("b0"), String("b1")],
        [String("sold"), String("active")],
        [Int64(10), Int64(20)],
    )


def _catalog() raises -> InMemorySearchIndexCatalog:
    var c = InMemorySearchIndexCatalog()
    c.create_index(String("logs"), String("body"), _cfg())
    return c^


def _params(query: Optional[String]) -> ScanParams:
    var p = ScanParams()
    p.put_str(String("index"), String("logs"))
    p.put_str(String("field"), String("body"))
    if query:
        p.put_str(String("query"), query.value())
    return p^


# -----------------------------------------------------------------------------
# Row readers over a HitBatch (_score Float64, _id Int64, _source STRING).
# -----------------------------------------------------------------------------


def _row(batch: RecordBatch, r: Int) raises -> String:
    var sc = Float64(batch.column_at(0).as_primitive[DType.float64]().get(r))
    var id = Int64(batch.column_at(1).as_primitive[DType.int64]().get(r))
    var src = batch.column_at(2).as_string().get(r)
    return String(sc) + String("|") + String(id) + String("|") + String(src)


def _rows_of(opened: ScanOpened) raises -> List[String]:
    var out = List[String]()
    for bi in range(len(opened.batches[])):
        ref b = opened.batches[][bi]
        for r in range(b.num_rows()):
            out.append(_row(b, r))
    return out^


def _direct_rows(
    split: List[UInt8], query: String, var filter: Optional[Expr] = None
) raises -> List[String]:
    """What `SearchCore.search` returns for this split when asked for every
    match -- the kind's reference answer."""
    var core = SearchCore(split.copy())
    var q = QueryIR(
        String("body"), query, core.doc_count(), _cfg(), 0, filter^,
        match_all=(query == ""),
    )
    var res = core.search(q^)
    var batch = res.take_batch()
    var out = List[String]()
    for r in range(batch.num_rows()):
        out.append(_row(batch, r))
    return out^


def _concat(var a: List[String], b: List[String]) -> List[String]:
    for i in range(len(b)):
        a.append(b[i])
    return a^


def _assert_rows(got: List[String], want: List[String], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _open(rt: _Runtime, binding: ScanBinding) raises -> ScanOpened:
    var exec_binding = resolve_for_execution(rt, binding)
    return rt.open_scan(ScanRequest(exec_binding^))


def _source_col(opened: ScanOpened) raises -> List[String]:
    var out = List[String]()
    for bi in range(len(opened.batches[])):
        ref b = opened.batches[][bi]
        for r in range(b.num_rows()):
            out.append(String(b.column_at(2).as_string().get(r)))
    return out^


def _has(xs: List[String], v: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


# =============================================================================
# The name.
# =============================================================================


def test_the_kind_name_is_komira_search_index() raises:
    assert_equal(String(SEARCH_SCAN_KIND_NAME), String("komira.search.index"))
    var d = search_scan_descriptor()
    assert_equal(d.kind_name, String("komira.search.index"))
    assert_equal(d.kind_id, search_scan_kind_id())


# =============================================================================
# Hits == SearchCore direct.
# =============================================================================


def test_hits_equal_search_core_called_directly() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var b = rt.build_binding(_params(Optional(String("alpha"))))
    var opened = _open(rt, b)
    var want = _concat(
        _direct_rows(_split_a(), String("alpha")),
        _direct_rows(_split_b(), String("alpha")),
    )
    assert_equal(len(want), 3, "alpha is in a0, a1 and b0")
    _assert_rows(_rows_of(opened), want, "hits")
    assert_equal(opened.num_batches(), 2, "one drained batch per live split")


def test_the_erased_kind_serves_the_same_rows() raises:
    var cat = _catalog()
    _ = cat.publish(String("logs"), _split_a())
    var r = search_scan_runtime(cat^)
    assert_equal(r.kind_id(), search_scan_kind_id())
    var b = r.build_binding(_params(Optional(String("alpha"))))
    var exec_binding = resolve_for_execution(r, b)
    assert_equal(exec_binding.snapshot_token, UInt64(1))
    var opened = r.open_scan(ScanRequest(exec_binding^))
    _assert_rows(
        _rows_of(opened), _direct_rows(_split_a(), String("alpha")), "erased"
    )


# =============================================================================
# The generation is re-resolved; the cache key survives a publish.
# =============================================================================


def test_the_generation_is_re_resolved_per_execution() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var cached = rt.build_binding(_params(Optional(String("alpha"))))
    assert_equal(cached.snapshot_token, UInt64(0), "a LIVE plan carries 0")

    var e1 = resolve_for_execution(rt, cached)
    assert_equal(e1.snapshot_token, UInt64(1))
    var o1 = rt.open_scan(ScanRequest(e1^))
    assert_equal(o1.num_rows(), 2)
    assert_equal(
        o1.resolved.get_i64(String(SEARCH_RESOLVED_GENERATION)), Int64(1)
    )

    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var e2 = resolve_for_execution(rt, cached)
    assert_equal(e2.snapshot_token, UInt64(2), "the SAME plan re-resolves")
    var o2 = rt.open_scan(ScanRequest(e2^))
    assert_equal(o2.num_rows(), 3, "the published split is visible")
    assert_equal(
        o2.resolved.get_i64(String(SEARCH_RESOLVED_GENERATION)), Int64(2)
    )
    assert_equal(cached.snapshot_token, UInt64(0), "never written back")


def test_the_cache_key_survives_a_publish() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var before = rt.build_binding(_params(Optional(String("alpha"))))
    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var after = rt.build_binding(_params(Optional(String("alpha"))))
    assert_equal(before.fingerprint, after.fingerprint)
    assert_equal(before.structural_id, after.structural_id)
    assert_equal(before.identity_hash(), after.identity_hash())
    assert_equal(before.render(), after.render())
    var p_before = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(before.copy()), before.source_schema()
    )
    var p_after = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(after.copy()), after.source_schema()
    )
    assert_equal(p_before.structural_hash(), p_after.structural_hash())
    # ...while a different query is a different plan.
    var other = rt.build_binding(_params(Optional(String("delta"))))
    var p_other = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(other.copy()), other.source_schema()
    )
    assert_not_equal(p_before.structural_hash(), p_other.structural_hash())


def test_a_stated_generation_is_a_pin() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var p1 = _params(Optional(String("alpha")))
    p1.put_i64(String("generation"), Int64(1))
    var pinned = rt.build_binding(p1)
    var live = rt.build_binding(_params(Optional(String("alpha"))))
    var p2 = _params(Optional(String("alpha")))
    p2.put_i64(String("generation"), Int64(2))
    var pinned2 = rt.build_binding(p2)
    assert_not_equal(pinned.identity_hash(), live.identity_hash())
    assert_not_equal(pinned.identity_hash(), pinned2.identity_hash())

    var e = resolve_for_execution(rt, pinned)
    assert_equal(e.snapshot_token, UInt64(1), "the pin, not the current gen")
    var o = rt.open_scan(ScanRequest(e^))
    _assert_rows(
        _rows_of(o), _direct_rows(_split_a(), String("alpha")), "pinned at 1"
    )

    var p5 = _params(Optional(String("alpha")))
    p5.put_i64(String("generation"), Int64(5))
    var beyond = rt.build_binding(p5)
    var raised = False
    try:
        _ = _open(rt, beyond)
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_GENERATION_NOT_AVAILABLE) in msg, msg)
    assert_true(raised, "a pin beyond the current generation is refused")


# =============================================================================
# The no-query scan.
# =============================================================================


def test_a_no_query_scan_returns_every_live_doc() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var cached = rt.build_binding(_params(None))
    assert_equal(cached.params.get_str(String("query")), String(""))

    var o1 = _open(rt, cached)
    var s1 = _source_col(o1)
    assert_equal(len(s1), 3, "every live doc of generation 1")
    assert_true(_has(s1, String("a0")) and _has(s1, String("a1")))
    assert_true(_has(s1, String("a2")), "a doc with no query term is a row")
    _assert_rows(_rows_of(o1), _direct_rows(_split_a(), String("")), "no query")

    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var o2 = _open(rt, cached)
    var s2 = _source_col(o2)
    assert_equal(len(s2), 5, "re-resolved: generation 2's docs")
    assert_true(_has(s2, String("b0")) and _has(s2, String("b1")))
    assert_equal(
        o2.resolved.get_i64(String(SEARCH_RESOLVED_GENERATION)), Int64(2)
    )


def test_a_stopword_only_query_still_matches_nothing() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var o = _open(rt, rt.build_binding(_params(Optional(String("the")))))
    assert_equal(o.num_rows(), 0, "match semantics unchanged by the no-query scan")


# =============================================================================
# Fast-field lowering + limit.
# =============================================================================


def _eq_str(col: String, v: String) -> Expr:
    return Expr.binary(
        BIN_EQ, Expr.col_ref(col), Expr.literal(ScalarValue.from_string(v))
    )


def test_fast_field_conjuncts_are_lowered_into_the_search() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var b = rt.build_binding(_params(Optional(String("alpha"))))
    # status == 'sold' (lowerable) AND _score > 0 (not a fast-field: kept by
    # the engine above the scan, not lowered).
    var pred = Expr.binary(
        BIN_AND,
        _eq_str(String("status"), String("sold")),
        Expr.binary(
            BIN_GT,
            Expr.col_ref(String("_score")),
            Expr.literal(ScalarValue.from_float(0.0)),
        ),
    )
    var e = resolve_for_execution(rt, b)
    var o = rt.open_scan(ScanRequest(e^, predicate=Optional(pred^)))
    var want = _concat(
        _direct_rows(
            _split_a(),
            String("alpha"),
            Optional(_eq_str(String("status"), String("sold"))),
        ),
        _direct_rows(
            _split_b(),
            String("alpha"),
            Optional(_eq_str(String("status"), String("sold"))),
        ),
    )
    assert_equal(len(want), 2, "a1 and b0 are sold")
    _assert_rows(_rows_of(o), want, "lowered")


def test_a_limit_caps_the_rows() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var e = resolve_for_execution(rt, rt.build_binding(_params(None)))
    var o = rt.open_scan(ScanRequest(e^, limit=Int64(2)))
    assert_equal(o.num_rows(), 2)


# =============================================================================
# Identity corpus.
# =============================================================================


def test_the_identity_corpus_passes_the_core_audit() raises:
    var reg = ScanKindRegistry()
    reg.register(search_scan_descriptor())
    var corpora = List[ScanIdentityCorpus]()
    corpora.append(search_scan_identity_corpus())
    var rebuilt = List[ScanIdentityCorpus]()
    rebuilt.append(search_scan_identity_corpus())
    audit_scan_identity(reg, corpora, rebuilt)
    for i in range(corpora[0].num_entries()):
        reg.validate(corpora[0].bindings[i])


# =============================================================================
# Refusals, by name.
# =============================================================================


def test_an_unknown_index_is_refused_by_name() raises:
    var rt = _Runtime(_catalog())
    var p = ScanParams()
    p.put_str(String("index"), String("nope"))
    p.put_str(String("field"), String("body"))
    var raised = False
    try:
        _ = rt.build_binding(p)
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_INDEX_UNKNOWN) in msg, msg)
        assert_true("nope" in msg, msg)
    assert_true(raised)


def test_analyzer_drift_is_refused_by_name() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var p = _params(Optional(String("alpha")))
    p.put_u64(String("analyzer_fp"), analyzer_config_fingerprint(_cfg()) + 1)
    var raised = False
    try:
        _ = rt.build_binding(p)
    except err:
        raised = True
        assert_true(String(SEARCH_ANALYZER_MISMATCH) in String(err))
    assert_true(raised, "a plan built against another analyzer is refused")


def test_a_foreign_binding_and_a_missing_param_are_refused() raises:
    var cat = _catalog()
    _ = cat.publish(String("logs"), _split_a())
    var r = search_scan_runtime(cat^)
    var p = ScanParams()
    p.put_str(String("index"), String("logs"))
    var raised = False
    try:
        _ = r.build_binding(p)
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SCAN_BINDING_MISSING_PARAMS) in msg, msg)
        assert_true("field" in msg, msg)
    assert_true(raised, "field is required")

    var foreign = ScanBinding(
        kind_id=UInt32(7),
        kind_name=String("komira.other"),
        name=String("x"),
        params=ScanParams(),
        schema=Schema(),
        fingerprint=UInt64(1),
        structural_id=UInt64(1),
        gate=search_scan_descriptor().gate.copy(),
    )
    var raised2 = False
    try:
        _ = r.open_scan(ScanRequest(foreign^))
    except err:
        raised2 = True
    assert_true(raised2, "a foreign kind is refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

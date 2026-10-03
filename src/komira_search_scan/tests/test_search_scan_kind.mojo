# =============================================================================
# test_search_scan_kind.mojo -- the `komira.search.index` scan kind.
# EXECUTOR-FREE: no EngineContext, no query
# engine -- the kind is driven through core's tier-1 entry point
# (`resolve_for_execution`), its own split plan and readers, and
# `drain_scan` (the bounded read the old `open_scan` was), over an in-memory
# catalog. Every row assertion that held for `open_scan` holds for the drain.
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
#   * the plan is one bounded split per live split, `<index>/<ordinal>`, and
#     discovery is refused by name; a reader returns a split's hits in one
#     poll and then END, a resumed reader reads exactly the rest (concrete and
#     erased), and a row limit cuts inside a split at the top-ranked rows;
#   * a foreign, mis-versioned or malformed position and a split key that is
#     not one of the scan's are refused by name;
#   * the identity corpus passes core's audit;
#   * refusals are by name (unknown index, analyzer drift at bind AND at
#     execution, foreign kind,
#     unservable pin, missing required param);
#   * `field` is optional: derived when the index has
#     exactly one analyzed text field, refused by name (SEARCH_FIELD_AMBIGUOUS,
#     listing the candidates) when it has several, honoured when stated; a
#     derived field is the same identity as the same field stated.
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

from komira_scan_resolver.drain_scan import drain_scan
from komira_scan_resolver.scan_source_resolver import (
    SCAN_BINDING_MISSING_PARAMS,
    SCAN_READ_MODE_NOT_SUPPORTED,
    ScanOpened,
    ScanRequest,
)
from komira_scan_resolver.scan_split import (
    SCAN_RESOLVER_FOREIGN_KIND,
    SCAN_SPLIT_POSITION_VERSION,
    ScanSplit,
    SplitPosition,
)

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.source import QueryIR, SearchCore

from komira_search_scan.search_source import analyzer_config_fingerprint
from komira_search_scan.search_split_reader import (
    SEARCH_SPLIT_POSITION_INVALID,
    SEARCH_SPLIT_POSITION_VERSION,
    search_split_position,
)
from komira_search_scan.search_scan_kind import (
    InMemorySearchIndexCatalog,
    SEARCH_ANALYZER_MISMATCH,
    SEARCH_FIELD_AMBIGUOUS,
    SEARCH_GENERATION_NOT_AVAILABLE,
    SEARCH_INDEX_UNKNOWN,
    SEARCH_RESOLVED_GENERATION,
    SEARCH_SCAN_KIND_NAME,
    SEARCH_SPLIT_KEY_INVALID,
    SearchScanRuntime,
    search_scan_binding,
    search_scan_descriptor,
    search_scan_identity_corpus,
    search_scan_kind_id,
    search_scan_runtime,
    search_split_key,
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
    return drain_scan(rt, ScanRequest(exec_binding^))


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
    var opened = drain_scan(r, ScanRequest(exec_binding^))
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
    var o1 = drain_scan(rt, ScanRequest(e1^))
    assert_equal(o1.num_rows(), 2)
    assert_equal(
        o1.resolved.get_i64(String(SEARCH_RESOLVED_GENERATION)), Int64(1)
    )

    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var e2 = resolve_for_execution(rt, cached)
    assert_equal(e2.snapshot_token, UInt64(2), "the SAME plan re-resolves")
    var o2 = drain_scan(rt, ScanRequest(e2^))
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
    var o = drain_scan(rt, ScanRequest(e^))
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
    var o = drain_scan(rt, ScanRequest(e^, predicate=Optional(pred^)))
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
    var o = drain_scan(rt, ScanRequest(e^, limit=Int64(2)))
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


def test_analyzer_drift_is_refused_at_execution() raises:
    # The EXECUTION-time arm, not build_binding's: a binding built elsewhere
    # (a cached plan) against another analyzer reaches the drain without
    # passing `build_binding`, and must be refused there by name -- else it
    # silently matches a different term set. The binding is made directly
    # with `search_scan_binding`, so `build_binding`'s check never runs.
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var stale = search_scan_binding(
        String("logs"),
        String("body"),
        String("alpha"),
        analyzer_config_fingerprint(_cfg()) + 1,
    )
    var raised = False
    try:
        _ = _open(rt, stale)
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_ANALYZER_MISMATCH) in msg, msg)
        assert_true("logs" in msg, msg)
    assert_true(raised, "the drain refuses a binding built on another analyzer")


def test_a_foreign_binding_and_a_missing_param_are_refused() raises:
    var cat = _catalog()
    _ = cat.publish(String("logs"), _split_a())
    var r = search_scan_runtime(cat^)
    # `index` is the one required param (`field` is derived).
    var p = ScanParams()
    p.put_str(String("field"), String("body"))
    var raised = False
    try:
        _ = r.build_binding(p)
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SCAN_BINDING_MISSING_PARAMS) in msg, msg)
        assert_true("index" in msg, msg)
    assert_true(raised, "index is required")

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
        _ = drain_scan(r, ScanRequest(foreign^))
    except err:
        raised2 = True
    assert_true(raised2, "a foreign kind is refused")


# =============================================================================
# `field` is optional: derive one, refuse many, honour
# a stated one. Executor-free: the kind's own build_binding + drain_scan.
# =============================================================================


def _index_only_params(query: String) -> ScanParams:
    var p = ScanParams()
    p.put_str(String("index"), String("logs"))
    if query != String(""):
        p.put_str(String("query"), query)
    return p^


def _two_field_catalog() raises -> InMemorySearchIndexCatalog:
    var c = _catalog()
    c.add_field(String("logs"), String("title"), AnalyzerConfig.text("title"))
    return c^


def test_an_omitted_field_is_derived_when_the_index_has_one() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var derived = rt.build_binding(_index_only_params(String("alpha")))
    assert_equal(
        derived.params.get_str(String("field")),
        String("body"),
        "the binding RECORDS the derived field",
    )
    var stated = rt.build_binding(_params(Optional(String("alpha"))))
    assert_equal(
        derived.fingerprint,
        stated.fingerprint,
        "a derived field is the same identity as the field stated",
    )
    assert_true(
        derived.identity_hash() == stated.identity_hash(),
        "and the same plan-side identity_hash",
    )
    var want = _concat(
        _direct_rows(_split_a(), String("alpha")),
        _direct_rows(_split_b(), String("alpha")),
    )
    _assert_rows(_rows_of(_open(rt, derived)), want, String("derived field"))
    # The no-query read with no field: every live doc (a whole-index read
    # that states neither a query nor a field).
    var all_docs = rt.build_binding(_index_only_params(String("")))
    assert_equal(len(_source_col(_open(rt, all_docs))), 5, "every live doc")


def test_an_omitted_field_is_refused_by_name_when_the_index_has_several() raises:
    var rt = _Runtime(_two_field_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var raised = False
    try:
        _ = rt.build_binding(_index_only_params(String("alpha")))
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_FIELD_AMBIGUOUS) in msg, msg)
        assert_true("'body'" in msg, "lists candidate 'body': " + msg)
        assert_true("'title'" in msg, "lists candidate 'title': " + msg)
        assert_true("logs" in msg, "names the index: " + msg)
    assert_true(raised, "two analyzed fields: the kind refuses to guess")
    # Through the ERASED form too (the registry path a context takes).
    var cat = _two_field_catalog()
    var r = search_scan_runtime(cat^)
    var raised2 = False
    try:
        _ = r.build_binding(_index_only_params(String("")))
    except err:
        raised2 = True
        assert_true(String(SEARCH_FIELD_AMBIGUOUS) in String(err), String(err))
    assert_true(raised2, "the erased kind refuses too")


def test_an_explicit_field_is_honoured_on_a_many_field_index() raises:
    var rt = _Runtime(_two_field_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var b = rt.build_binding(_params(Optional(String("alpha"))))
    assert_equal(b.params.get_str(String("field")), String("body"))
    _assert_rows(
        _rows_of(_open(rt, b)),
        _direct_rows(_split_a(), String("alpha")),
        String("explicit field on a two-field index"),
    )
    var p = ScanParams()
    p.put_str(String("index"), String("logs"))
    p.put_str(String("field"), String("nope"))
    var raised = False
    try:
        _ = rt.build_binding(p)
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_INDEX_UNKNOWN) in msg, msg)
        assert_true("'title'" in msg, "lists the fields it has: " + msg)
    assert_true(raised, "an explicit field the index lacks is refused")


def test_a_derived_field_is_the_explicit_fields_identity() raises:
    """The identity corpus pins it: `field_derived` (field omitted, derived
    from a one-field catalog) fingerprints EXACTLY as `baseline`, and
    `field` (another field stated) does not."""
    var c = search_scan_identity_corpus()
    var base = -1
    var derived = -1
    var other = -1
    for i in range(c.num_entries()):
        if c.labels[i] == String("baseline"):
            base = i
        elif c.labels[i] == String("field_derived"):
            derived = i
        elif c.labels[i] == String("field"):
            other = i
    assert_true(base >= 0 and derived >= 0 and other >= 0, "labels present")
    assert_equal(c.bindings[derived].fingerprint, c.bindings[base].fingerprint)
    assert_equal(
        c.bindings[derived].params.get_str(String("field")), String("body")
    )
    assert_not_equal(c.bindings[other].fingerprint, c.bindings[base].fingerprint)



# =============================================================================
# The split plan and the split reader.
# =============================================================================


def _batch_rows(batch: RecordBatch) raises -> List[String]:
    var out = List[String]()
    for r in range(batch.num_rows()):
        out.append(_row(batch, r))
    return out^


def _tail(xs: List[String], start: Int) -> List[String]:
    var out = List[String]()
    for i in range(start, len(xs)):
        out.append(xs[i])
    return out^


def _request(rt: _Runtime, query: Optional[String]) raises -> ScanRequest:
    return ScanRequest(resolve_for_execution(rt, rt.build_binding(_params(query))))


def test_the_plan_is_one_bounded_split_per_live_split() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var req = _request(rt, Optional(String("alpha")))
    var plan = rt.plan_splits(req)
    assert_true(plan.complete, "a generation's split set never grows")
    assert_equal(plan.num_splits(), 2, "one split per live split")
    assert_equal(plan.splits[0].split_key, search_split_key(String("logs"), 0))
    assert_equal(plan.splits[1].split_key, String("logs/1"))
    for i in range(plan.num_splits()):
        assert_true(plan.splits[i].is_bounded(), "every split has a stop")
        assert_true(plan.splits[i].start != plan.splits[i].stop.value())
    assert_equal(
        plan.resolved.get_i64(String(SEARCH_RESOLVED_GENERATION)), Int64(2)
    )
    var raised = False
    try:
        _ = rt.discover_splits(req, List[String]())
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SCAN_READ_MODE_NOT_SUPPORTED) in msg, msg)
        assert_true(String(SEARCH_SCAN_KIND_NAME) in msg, msg)
    assert_true(raised, "a bounded kind has no splits to discover")


def test_a_reader_returns_its_split_in_one_poll_then_end() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var req = _request(rt, Optional(String("alpha")))
    var plan = rt.plan_splits(req)
    var reader = rt.open_split(req, plan.splits[0])
    var p1 = reader.poll(-1, -1)
    assert_true(p1.is_rows())
    _assert_rows(
        _batch_rows(p1.batch.value()),
        _direct_rows(_split_a(), String("alpha")),
        "one poll is the whole split",
    )
    assert_true(p1.position == plan.splits[0].stop.value(), "read to its stop")
    assert_equal(p1.source_bytes, Int64(len(_split_a())))
    var p2 = reader.poll(-1, -1)
    assert_true(p2.is_end(), "then END")
    assert_true(p2.position == plan.splits[0].stop.value())


def _resume_case(query: String, what: String) raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var want = _direct_rows(_split_a(), query)
    assert_true(len(want) >= 2, what + ": the case needs two ranks")
    var req = _request(rt, Optional(query))
    var plan = rt.plan_splits(req)
    var reader = rt.open_split(req, plan.splits[0])
    var first = reader.poll(1, -1)
    var top = List[String]()
    top.append(String(want[0]))
    _assert_rows(_batch_rows(first.batch.value()), top, what + ": the top rank")
    assert_true(
        first.position != plan.splits[0].stop.value(), what + ": not at stop"
    )
    var resumed = rt.open_split(
        req, plan.splits[0].resumed_at(first.position.copy())
    )
    var rest = resumed.poll(-1, -1)
    _assert_rows(_batch_rows(rest.batch.value()), _tail(want, 1), what + ": rest")
    assert_true(resumed.poll(-1, -1).is_end(), what + ": then END")

    # The erased reader, one rank per poll, reads the same ranks in order.
    var cat = _catalog()
    _ = cat.publish(String("logs"), _split_a())
    var r = search_scan_runtime(cat^)
    var ereq = ScanRequest(
        resolve_for_execution(r, r.build_binding(_params(Optional(query))))
    )
    var eplan = r.plan_splits(ereq)
    var er = r.open_split(ereq, eplan.splits[0])
    var got = List[String]()
    var polls = 0
    while True:
        var p = er.poll(1, -1)
        if p.is_end():
            break
        polls += 1
        assert_true(polls <= len(want) + 1, what + ": the reader ends")
        if p.batch:
            var rows = _batch_rows(p.batch.value())
            for i in range(len(rows)):
                got.append(String(rows[i]))
    _assert_rows(got, want, what + ": erased, one rank per poll")


def test_a_resumed_split_reads_exactly_the_rest() raises:
    _resume_case(String("alpha"), String("term query"))
    _resume_case(String(""), String("no-query scan"))


def test_a_limit_cut_keeps_the_top_ranked_rows() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    _ = rt.catalog_mut().publish(String("logs"), _split_b())
    var e = resolve_for_execution(rt, rt.build_binding(_params(None)))
    var o = drain_scan(rt, ScanRequest(e^, limit=Int64(4)))
    var want = _direct_rows(_split_a(), String(""))
    var b_rows = _direct_rows(_split_b(), String(""))
    want.append(String(b_rows[0]))
    _assert_rows(_rows_of(o), want, "the limit cuts split B after its top rank")
    assert_equal(o.resolved.get_i64(String(SEARCH_RESOLVED_GENERATION)), Int64(2))


def _end(id: UInt32) -> Optional[SplitPosition]:
    return Optional(search_split_position(id, True, 0))


def _expect_open_refused(
    rt: _Runtime, req: ScanRequest, split: ScanSplit, name: String, what: String
) raises:
    var raised = False
    try:
        _ = rt.open_split(req, split)
    except err:
        raised = True
        assert_true(name in String(err), what + ": " + String(err))
    assert_true(raised, what + " is refused")


def test_a_bad_position_or_split_key_is_refused_by_name() raises:
    var rt = _Runtime(_catalog())
    _ = rt.catalog_mut().publish(String("logs"), _split_a())
    var req = _request(rt, Optional(String("alpha")))
    var id = search_scan_kind_id()
    _expect_open_refused(
        rt,
        req,
        ScanSplit(
            String("logs/0"), search_split_position(id + 1, False, 0), _end(id)
        ),
        String(SCAN_RESOLVER_FOREIGN_KIND),
        "another kind's position",
    )
    var p = search_split_position(id, False, 0)
    _expect_open_refused(
        rt,
        req,
        ScanSplit(
            String("logs/0"),
            SplitPosition(id, SEARCH_SPLIT_POSITION_VERSION + 1, p.bytes.copy()),
            _end(id),
        ),
        String(SCAN_SPLIT_POSITION_VERSION),
        "another position version",
    )
    var short = List[UInt8]()
    short.append(0)
    _expect_open_refused(
        rt,
        req,
        ScanSplit(
            String("logs/0"),
            SplitPosition(id, SEARCH_SPLIT_POSITION_VERSION, short^),
            _end(id),
        ),
        String(SEARCH_SPLIT_POSITION_INVALID),
        "a malformed position",
    )
    _expect_open_refused(
        rt,
        req,
        ScanSplit(String("logs/0"), p.copy(), Optional(p.copy())),
        String(SEARCH_SPLIT_POSITION_INVALID),
        "a stop short of the split's end",
    )
    # Another index, no ordinal, not a number, and an ordinal past the
    # generation's splits.
    var keys = List[String]()
    keys.append(String("audit/0"))
    keys.append(String("logs/"))
    keys.append(String("logs/x"))
    keys.append(String("logs/1"))
    for i in range(len(keys)):
        _expect_open_refused(
            rt,
            req,
            ScanSplit(String(keys[i]), p.copy(), _end(id)),
            String(SEARCH_SPLIT_KEY_INVALID),
            String("split key '") + keys[i] + String("'"),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

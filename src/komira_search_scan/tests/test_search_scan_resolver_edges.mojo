# =============================================================================
# test_search_scan_resolver_edges.mojo -- `SearchScanResolver` edges the
# kind tests do not reach.
#
# Fixture: index `logs` (field body) holding split A
#   a0 "alpha beta"  active  50
#   a1 "alpha alpha" sold   100
#   a2 "gamma the"   active 150
#   a3 "alpha delta" sold    50
# with fast fields `status` (keyword) and `price` (int).
#
# Pins:
#   * every fast-field conjunct of a request predicate is lowered, not only
#     the first or the last, and a conjunct that is not a fast field is
#     skipped rather than ending the lowering: `status = 'sold' AND _score >
#     -1 AND price >= 100`, in that order and reversed, returns a1 alone,
#     while each fast-field conjunct alone returns two rows (a1 a3, a1 a2);
#   * a pinned generation below 0 is refused by name, naming it; a pin of 0
#     is a pin; `build_binding` refuses analyzer drift before a negative pin;
#   * `resolve_snapshot`, `plan_splits` and `open_split` each refuse a
#     foreign binding by name, naming the verb and the kind; `open_split`
#     refuses it before looking at the split's position;
#   * a tier-2 resolver is unbound: `epoch` is `SCAN_EPOCH_NONE` and
#     `is_bound` is False;
#   * `analyzer_config_fingerprint` changes when any ONE of field_class,
#     lowercase, ascii_fold, remove_stopwords or stopword_set changes, and
#     `build_binding` refuses by name a plan built against the index's
#     analyzer with only ascii_fold flipped;
#   * on a generation of 11 splits (so ordinal 10 is in range), `logs/0`,
#     `logs/9` and `logs/10` open, while `logs/:` (':' is one past '9', read
#     as digit 10 it would be ordinal 10) and `logs/1/` ('/' is one below '0',
#     read as digit -1 it would be ordinal 9) are refused as
#     SEARCH_SPLIT_KEY_INVALID.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import Expr, BIN_AND, BIN_EQ, BIN_GE, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_scan_source.scan_binding import ScanBinding, SCAN_EPOCH_NONE
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import resolve_for_execution

from komira_scan_resolver.drain_scan import drain_scan
from komira_scan_resolver.scan_source_resolver import ScanRequest
from komira_scan_resolver.scan_split import ScanSplit, SplitPosition

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.source import QueryIR, SearchCore

from komira_search_scan.search_source import analyzer_config_fingerprint
from komira_search_scan.search_split_reader import (
    SEARCH_SPLIT_POSITION_VERSION,
    search_split_position,
)
from komira_search_scan.search_scan_kind import (
    InMemorySearchIndexCatalog,
    SEARCH_ANALYZER_MISMATCH,
    SEARCH_GENERATION_NOT_AVAILABLE,
    SEARCH_SPLIT_KEY_INVALID,
    SearchScanResolver,
    search_scan_binding,
    search_scan_descriptor,
    search_scan_kind_id,
)


comptime _Resolver = SearchScanResolver[InMemorySearchIndexCatalog]


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _split_a() raises -> List[UInt8]:
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, True))
    sb.add_field(Field("price", ArrowType.INT64, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(
        Column.from_string(
            StringArray.from_strings(
                [
                    String("alpha beta"),
                    String("alpha alpha"),
                    String("gamma the"),
                    String("alpha delta"),
                ]
            )
        )
    )
    rb.add_column(
        Column.from_string(
            StringArray.from_strings(
                [String("a0"), String("a1"), String("a2"), String("a3")]
            )
        )
    )
    rb.add_column(
        Column.from_string(
            StringArray.from_strings(
                [
                    String("active"),
                    String("sold"),
                    String("active"),
                    String("sold"),
                ]
            )
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(
                [Int64(50), Int64(100), Int64(150), Int64(50)]
            )
        )
    )
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("bucket"), String("prefix"), String("logs"), String("body"),
        _uuid(1),
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _resolver() raises -> _Resolver:
    var c = InMemorySearchIndexCatalog()
    c.create_index(String("logs"), String("body"), AnalyzerConfig.text("body"))
    _ = c.publish(String("logs"), _split_a())
    return _Resolver(c^)


def _params(query: String) -> ScanParams:
    var p = ScanParams()
    p.put_str(String("index"), String("logs"))
    p.put_str(String("field"), String("body"))
    if query != String(""):
        p.put_str(String("query"), query)
    return p^


def _sources(rt: _Resolver, query: String, var pred: Optional[Expr]) raises -> List[String]:
    var e = resolve_for_execution(rt, rt.build_binding(_params(query)))
    var o = drain_scan(rt, ScanRequest(e^, predicate=pred^))
    var out = List[String]()
    for bi in range(len(o.batches[])):
        ref b = o.batches[][bi]
        for r in range(b.num_rows()):
            out.append(String(b.column_at(2).as_string().get(r)))
    return out^


def _direct_sources(query: String, var filter: Optional[Expr]) raises -> List[String]:
    """`SearchCore.search` over split A with `filter`: the reference."""
    var core = SearchCore(_split_a())
    var q = QueryIR(
        String("body"), query, core.doc_count(), AnalyzerConfig.text("body"), 0,
        filter^, match_all=(query == ""),
    )
    var res = core.search(q^)
    var batch = res.take_batch()
    var out = List[String]()
    for r in range(batch.num_rows()):
        out.append(String(batch.column_at(2).as_string().get(r)))
    return out^


def _assert_list(got: List[String], want: List[String], what: String) raises:
    var g = String("[")
    for i in range(len(got)):
        g += got[i] + String(" ")
    assert_equal(len(got), len(want), what + ": got " + g + String("]"))
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _status_sold() -> Expr:
    return Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("status")),
        Expr.literal(ScalarValue.from_string("sold")),
    )


def _price_ge_100() -> Expr:
    return Expr.binary(
        BIN_GE,
        Expr.col_ref(String("price")),
        Expr.literal(ScalarValue.from_int64(100)),
    )


def _foreign() -> ScanBinding:
    return ScanBinding(
        kind_id=UInt32(7),
        kind_name=String("komira.other"),
        name=String("x"),
        params=ScanParams(),
        schema=Schema(),
        fingerprint=UInt64(1),
        structural_id=UInt64(1),
        gate=search_scan_descriptor().gate.copy(),
    )


def _good_split() -> ScanSplit:
    var id = search_scan_kind_id()
    return ScanSplit(
        String("logs/0"),
        search_split_position(id, False, 0),
        Optional(search_split_position(id, True, 0)),
    )


def _assert_foreign(msg: String, verb: String) raises:
    assert_true(
        String("SearchScanResolver.") + verb + String(": refusing foreign kind")
        in msg,
        verb + ": " + msg,
    )
    assert_true("'komira.other'" in msg, verb + " names the kind: " + msg)


# =============================================================================
# Lowering.
# =============================================================================


def test_every_fast_field_conjunct_is_lowered() raises:
    var rt = _resolver()
    var not_ff = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("_score")),
        Expr.literal(ScalarValue.from_float(-1.0)),
    )
    # The same three conjuncts in both orders: a lowering that stops at the
    # first conjunct it cannot push, or keeps only the first or the last
    # fast-field conjunct, returns two rows in at least one order.
    var preds: List[Expr] = [
        Expr.binary(
            BIN_AND,
            Expr.binary(BIN_AND, _status_sold(), not_ff.copy()),
            _price_ge_100(),
        ),
        Expr.binary(
            BIN_AND,
            Expr.binary(BIN_AND, _price_ge_100(), not_ff.copy()),
            _status_sold(),
        ),
    ]
    var cases: List[String] = [String(""), String("alpha")]
    for p in range(len(preds)):
        for i in range(len(cases)):
            var what = (
                String("order ") + String(p) + String(" '") + cases[i] + String("'")
            )
            var got = _sources(rt, cases[i], Optional(preds[p].copy()))
            _assert_list(got, [String("a1")], what)
            _assert_list(
                got,
                _direct_sources(
                    cases[i],
                    Optional(Expr.binary(BIN_AND, _status_sold(), _price_ge_100())),
                ),
                String("reference ") + what,
            )
    # Each fast-field conjunct alone returns two rows, so no single conjunct
    # gives the pair's one row.
    _assert_list(
        _sources(rt, String(""), Optional(_price_ge_100())),
        [String("a1"), String("a2")],
        "price >= 100 alone",
    )
    _assert_list(
        _sources(rt, String(""), Optional(_status_sold())),
        [String("a1"), String("a3")],
        "status = sold alone",
    )


# =============================================================================
# The pinned generation.
# =============================================================================


def test_a_negative_pin_is_refused_and_zero_is_a_pin() raises:
    var fp = analyzer_config_fingerprint(AnalyzerConfig.text("body"))
    var raised = False
    try:
        _ = search_scan_binding(
            String("logs"), String("body"), String("q"), fp,
            Optional[Int64](Int64(-1)),
        )
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_GENERATION_NOT_AVAILABLE) in msg, msg)
        assert_true("(got -1)" in msg, msg)
    assert_true(raised, "pin -1 is refused")
    var b = search_scan_binding(
        String("logs"), String("body"), String("q"), fp,
        Optional[Int64](Int64(0)),
    )
    assert_true(b.params.has(String("generation")), "pin 0 is stated")
    assert_equal(b.params.get_i64(String("generation")), Int64(0))
    var rt = _resolver()
    assert_equal(rt.resolve_snapshot(b), UInt64(0), "pin 0 reads generation 0")
    assert_equal(rt.resolve_snapshot(
        search_scan_binding(String("logs"), String("body"), String("q"), fp)
    ), UInt64(1), "live reads generation 1")


def test_build_binding_refuses_drift_before_a_negative_pin() raises:
    var rt = _resolver()
    var p = _params(String("alpha"))
    p.put_u64(
        String("analyzer_fp"),
        analyzer_config_fingerprint(AnalyzerConfig.text("body")) + 1,
    )
    p.put_i64(String("generation"), Int64(-1))
    var raised = False
    try:
        _ = rt.build_binding(p)
    except err:
        raised = True
        assert_true(String(SEARCH_ANALYZER_MISMATCH) in String(err), String(err))
    assert_true(raised, "drift and a negative pin")


# =============================================================================
# A foreign binding.
# =============================================================================


def test_each_verb_refuses_a_foreign_binding_by_name() raises:
    var rt = _resolver()
    var raised = False
    try:
        _ = rt.resolve_snapshot(_foreign())
    except err:
        raised = True
        _assert_foreign(String(err), String("resolve_snapshot"))
    assert_true(raised, "resolve_snapshot")
    raised = False
    try:
        _ = rt.plan_splits(ScanRequest(_foreign()))
    except err:
        raised = True
        _assert_foreign(String(err), String("plan_splits"))
    assert_true(raised, "plan_splits")
    raised = False
    try:
        _ = rt.open_split(ScanRequest(_foreign()), _good_split())
    except err:
        raised = True
        _assert_foreign(String(err), String("open_split"))
    assert_true(raised, "open_split")


def test_open_split_refuses_a_foreign_binding_before_the_position() raises:
    var rt = _resolver()
    var short: List[UInt8] = [7]
    var bad = ScanSplit(
        String("elsewhere"),
        SplitPosition(search_scan_kind_id() + 1, SEARCH_SPLIT_POSITION_VERSION, short^),
        None,
    )
    var raised = False
    try:
        _ = rt.open_split(ScanRequest(_foreign()), bad)
    except err:
        raised = True
        _assert_foreign(String(err), String("open_split"))
    assert_true(raised, "foreign binding and a foreign, short position")


# =============================================================================
# The analyzer fingerprint: every discriminating field is folded.
# =============================================================================


def _assert_fp_differs(base: AnalyzerConfig, var other: AnalyzerConfig, what: String) raises:
    assert_true(
        analyzer_config_fingerprint(base) != analyzer_config_fingerprint(other),
        what + String(" changes the fingerprint"),
    )


def test_each_discriminating_analyzer_field_changes_the_fingerprint() raises:
    var base = AnalyzerConfig.text("body")
    var c = base.copy()
    c.field_class = base.field_class + 1
    _assert_fp_differs(base, c^, String("field_class"))
    c = base.copy()
    c.lowercase = False
    _assert_fp_differs(base, c^, String("lowercase"))
    c = base.copy()
    c.ascii_fold = False
    _assert_fp_differs(base, c^, String("ascii_fold"))
    c = base.copy()
    c.remove_stopwords = False
    _assert_fp_differs(base, c^, String("remove_stopwords"))
    c = base.copy()
    c.stopword_set = String("none")
    _assert_fp_differs(base, c^, String("stopword_set"))


def test_build_binding_refuses_an_ascii_fold_change_by_name() raises:
    var rt = _resolver()
    var p = _params(String("alpha"))
    p.put_u64(
        String("analyzer_fp"),
        analyzer_config_fingerprint(AnalyzerConfig.text("body")),
    )
    _ = rt.build_binding(p)  # control: the index's own analyzer binds.
    var unfolded = AnalyzerConfig.text("body")
    unfolded.ascii_fold = False
    p = _params(String("alpha"))
    p.put_u64(String("analyzer_fp"), analyzer_config_fingerprint(unfolded))
    var raised = False
    try:
        _ = rt.build_binding(p)
    except err:
        raised = True
        assert_true(String(SEARCH_ANALYZER_MISMATCH) in String(err), String(err))
    assert_true(raised, "a plan built without ascii folding is refused")


# =============================================================================
# Split keys at the edges of the digit range.
# =============================================================================


def _key_split(key: String) -> ScanSplit:
    var id = search_scan_kind_id()
    return ScanSplit(
        key,
        search_split_position(id, False, 0),
        Optional(search_split_position(id, True, 0)),
    )


def test_a_split_key_just_outside_the_digit_range_is_refused() raises:
    var c = InMemorySearchIndexCatalog()
    c.create_index(String("logs"), String("body"), AnalyzerConfig.text("body"))
    for _ in range(11):
        _ = c.publish(String("logs"), _split_a())
    var rt = _Resolver(c^)
    var req = ScanRequest(resolve_for_execution(rt, rt.build_binding(_params(String("alpha")))))
    # Controls: the first, a one-digit and a two-digit ordinal open, so a
    # refusal below comes from the key, not from an ordinal out of range.
    var good: List[String] = [String("logs/0"), String("logs/9"), String("logs/10")]
    for i in range(len(good)):
        _ = rt.open_split(req, _key_split(good[i]))
    var bad: List[String] = [String("logs/:"), String("logs/1/")]
    for i in range(len(bad)):
        var raised = False
        try:
            _ = rt.open_split(req, _key_split(bad[i]))
        except err:
            raised = True
            assert_true(String(SEARCH_SPLIT_KEY_INVALID) in String(err), String(err))
        assert_true(raised, String("split key '") + bad[i] + String("' is refused"))


# =============================================================================
# Unbound.
# =============================================================================


def test_a_tier_two_resolver_is_unbound() raises:
    var rt = _resolver()
    assert_equal(rt.epoch(), SCAN_EPOCH_NONE)
    assert_false(rt.is_bound(search_scan_kind_id(), 0))
    assert_false(rt.is_bound(search_scan_kind_id(), 1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

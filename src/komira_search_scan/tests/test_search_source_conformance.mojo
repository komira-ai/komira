# =============================================================================
# test_search_source_conformance.mojo — the search source-edge proof
# =============================================================================
#
# What a search scan reads from one split, and the plan-side surface of that
# scan. The single-shot morsel reader this file used to drive is retired: the
# `komira.search.index` kind reads a split with `search_split_hits`, so the
# reader cases now pin that function, and the plan-side cases pin the kind's
# `ScanBinding` (the retired `Searcher` spec's successor). EXECUTOR-FREE: an
# in-memory split, no engine.
#
# Coverage:
#   1.  search_split_hits(SearchCore, QueryIR) returns the ranked hits, and
#       running it twice over one core returns the same rows (the core is
#       read, never consumed).
#   2.  the hit batch matches the hit schema (`_score Float64`, `_id Int64`,
#       `_source STRING`), and `top_k` bounds the rows.
#   3.  a query that matches nothing is an empty batch of the same schema.
#   4.  the kind binding's surface: schema == the hit schema, no row estimate,
#       and a split with no fast-fields pushes no conjunct
#       (FastFieldPushdownGate).
#   5.  identity distinctness: same query_text, DIFFERENT AnalyzerConfig
#       -> DIFFERENT binding identity (folded as the kind's `analyzer_fp`
#       param, so two scans with the same text but different configs do NOT
#       collide in the plan cache). Also: different query_text -> different;
#       same everything -> same (stable across copy()).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_not_equal,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatch
from komira_core.source.scan_binding import ScanBinding

from komira_search.analyzer import (
    AnalyzedField,
    AnalyzerConfig,
    Token,
    FIELD_CLASS_TEXT,
)
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.split import serialize_split, DocStoreBuilder

from komira_core.plan.expr import Expr, BIN_EQ
from komira_core.plan.scalar_value import ScalarValue
from komira_search_scan.search_source import (
    FastFieldPushdownGate,
    analyzer_config_fingerprint,
    search_split_hits,
)
from komira_search_scan.search_scan_kind import search_scan_binding
from komira_search.source import QueryIR, SearchCore


# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------


def _af(terms: List[String]) -> AnalyzedField:
    var toks = List[Token]()
    for i in range(len(terms)):
        toks.append(Token(terms[i], i))
    return AnalyzedField(toks^)


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _text_cfg() -> AnalyzerConfig:
    return AnalyzerConfig.text("body")


def _build_split(seed: UInt8) raises -> List[UInt8]:
    """A 3-doc split: "alpha" in docs {0,1,2} with TFs {1,2,1}; doc 1 ranks first.
    _source blobs d0/d1/d2."""
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder()
    b.add_document(0, _af([String("alpha")]))
    ds.append(String("d0").as_bytes())
    b.add_document(1, _af([String("alpha"), String("alpha")]))
    ds.append(String("d1").as_bytes())
    b.add_document(2, _af([String("alpha")]))
    ds.append(String("d2").as_bytes())
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    return serialize_split(fi, td^, ds, String("body"), _uuid(seed), 0, 2, 3)


def _id_at(imm batch: RecordBatch, row: Int) raises -> Int64:
    var arr = batch.column_at(1).as_primitive[DType.int64]()
    return Int64(arr.get(row))


def _source_at(imm batch: RecordBatch, row: Int) raises -> String:
    return String(batch.column_at(2).as_string().get(row))


def _assert_hit_schema(imm batch: RecordBatch) raises:
    var sch = batch.schema.copy()
    assert_equal(sch.num_columns(), 3)
    assert_equal(sch.field_name(0), String("_score"))
    assert_equal(sch.field_name(1), String("_id"))
    assert_equal(sch.field_name(2), String("_source"))
    assert_true(sch.field_arrow_type(0) == ArrowType.FLOAT64)
    assert_true(sch.field_arrow_type(1) == ArrowType.INT64)
    assert_true(sch.field_arrow_type(2) == ArrowType.STRING)


# =============================================================================
# Case 1 — the ranked hits, and a core that is read, not consumed.
# =============================================================================


def test_01_split_hits_are_ranked_and_repeatable() raises:
    var core = SearchCore(_build_split(1))
    var q = QueryIR(String("body"), String("alpha"), 10, _text_cfg())

    var first = search_split_hits(core, q)
    assert_equal(first.num_columns(), 3)
    assert_equal(first.num_rows(), 3)
    # ranked: doc 1 (tf=2) first, then docs 0 and 2 (tf=1, tie -> lower id first).
    assert_equal(Int(_id_at(first, 0)), 1)
    assert_equal(Int(_id_at(first, 1)), 0)
    assert_equal(Int(_id_at(first, 2)), 2)
    assert_equal(_source_at(first, 0), String("d1"))

    # The same core answers again, with the same rows.
    var second = search_split_hits(core, q)
    assert_equal(second.num_rows(), 3)
    for r in range(3):
        assert_equal(_id_at(second, r), _id_at(first, r))
        assert_equal(_source_at(second, r), _source_at(first, r))


# =============================================================================
# Case 2 — the hit schema, and top_k bounds the rows.
# =============================================================================


def test_02_hit_schema_and_top_k() raises:
    var core = SearchCore(_build_split(2))
    var full = search_split_hits(
        core, QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    )
    _assert_hit_schema(full)

    var top1 = search_split_hits(
        core, QueryIR(String("body"), String("alpha"), 1, _text_cfg())
    )
    _assert_hit_schema(top1)
    assert_equal(top1.num_rows(), 1)
    assert_equal(Int(_id_at(top1, 0)), 1, "the best-ranked hit survives")


# =============================================================================
# Case 3 — no match is an empty batch with the hit schema.
# =============================================================================


def test_03_no_match_is_an_empty_hit_batch() raises:
    var core = SearchCore(_build_split(3))
    var none = search_split_hits(
        core, QueryIR(String("body"), String("omega"), 10, _text_cfg())
    )
    assert_equal(none.num_rows(), 0)
    _assert_hit_schema(none)


# =============================================================================
# Case 4 — the plan-side surface of a search scan: the kind binding + the gate.
# (Converted from the retired `Searcher` SourceLike surface. `estimate_rows ==
# top_k` has no successor: a scan has no top_k, and the binding reports -1,
# "unknown".)
# =============================================================================


def test_04_search_scan_binding_surface() raises:
    var bytes = _build_split(4)
    var b = search_scan_binding(
        String("logs"),
        String("body"),
        String("alpha"),
        analyzer_config_fingerprint(_text_cfg()),
    )

    # schema == the hit schema.
    var sch = b.source_schema()
    assert_equal(sch.num_columns(), 3)
    assert_equal(sch.field_name(0), String("_score"))
    assert_equal(sch.field_name(1), String("_id"))
    assert_equal(sch.field_name(2), String("_source"))
    assert_equal(b.estimate_rows(), -1)

    # This split carries no fast-fields: the gate lowers nothing.
    var gate = FastFieldPushdownGate.from_split_bytes(bytes)
    assert_equal(gate.num_fast_fields(), 0)
    var pred = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("status")),
        Expr.literal(ScalarValue.from_string(String("active"))),
    )
    assert_false(gate.supports_filter_pushdown(pred))


# =============================================================================
# Case 5 — identity distinctness (the plan-cache collision class).
# =============================================================================


def _binding_for(text: String, cfg: AnalyzerConfig) raises -> ScanBinding:
    return search_scan_binding(
        String("logs"), String("body"), text, analyzer_config_fingerprint(cfg)
    )


def test_05_identity_folds_analyzer_config() raises:
    # SAME query_text, but DIFFERENT AnalyzerConfig:
    #   cfg_default = text() (lowercase + fold + english stopwords)
    #   cfg_nostop  = text() but remove_stopwords = False
    # They normalize a query to DIFFERENT term sets -> MUST NOT collide.
    var cfg_default = AnalyzerConfig.text("body")
    var cfg_nostop = AnalyzerConfig(
        String("body"), FIELD_CLASS_TEXT, True, True, False, String("")
    )
    var b_default = _binding_for(String("the alpha"), cfg_default)
    var b_nostop = _binding_for(String("the alpha"), cfg_nostop)

    assert_not_equal(
        analyzer_config_fingerprint(cfg_default),
        analyzer_config_fingerprint(cfg_nostop),
    )
    assert_not_equal(b_default.fingerprint, b_nostop.fingerprint)
    assert_not_equal(b_default.identity_hash(), b_nostop.identity_hash())


def test_05b_identity_distinct_and_stable() raises:
    var cfg = AnalyzerConfig.text("body")
    var b1 = _binding_for(String("alpha"), cfg)
    var b2 = _binding_for(String("beta"), cfg)  # different text
    # different query_text -> different identity.
    assert_not_equal(b1.fingerprint, b2.fingerprint)
    assert_not_equal(b1.identity_hash(), b2.identity_hash())

    # same everything -> same identity, STABLE across copy().
    var b1b = _binding_for(String("alpha"), cfg)
    assert_equal(b1.fingerprint, b1b.fingerprint)
    assert_equal(b1.identity_hash(), b1b.identity_hash())
    var b1_copy = b1.copy()
    assert_equal(b1.fingerprint, b1_copy.fingerprint)
    assert_equal(b1.identity_hash(), b1_copy.identity_hash())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

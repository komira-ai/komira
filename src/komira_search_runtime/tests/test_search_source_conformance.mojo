# =============================================================================
# test_search_source_conformance.mojo — the search source-edge proof
# =============================================================================
#
# The MorselSourceImpl CONFORMANCE proof: drives SearchMorselSource.next_morsel(0)
# returning the 1 HitBatch Morsel then None (the single-shot Atomic cursor + EOF),
# plus the Searcher SourceLike plan-spec surface (schema / estimate_rows /
# fingerprint) and the fingerprint-distinctness guard (folding the
# AnalyzerConfig discriminating fields into the FNV hash so two queries with the
# same text but different configs do NOT collide in the plan cache).
#
# Coverage:
#   1.  SearchMorselSource.from_spec(Searcher) -> next_morsel(0) returns the one
#       HitBatch Morsel; next_morsel(0) again returns None (single-pass EOF).
#   2.  the HitBatch Morsel carries the ranked hits (schema-tag-guarded).
#   3.  output_schema / row_count_hint / partition_hint / capabilities.
#   4.  Searcher SourceLike: schema / estimate_rows (== top_k) / supports_pushdown.
#   5.  fingerprint distinctness: same query_text, DIFFERENT AnalyzerConfig
#       -> DIFFERENT fingerprint. Also: different query_text -> different; same
#       everything -> same (stable across copy()).
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

# Import Morsel directly: this conformance test IS an engine-protocol test (it
# drives the MorselSourceImpl seam).
from komira_morsel.morsel import Morsel

from komira_search.analyzer import (
    AnalyzedField,
    AnalyzerConfig,
    Token,
    FIELD_CLASS_TEXT,
)
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.split import serialize_split, DocStoreBuilder

from komira_search_runtime.search_source import Searcher, SearchMorselSource
from komira_search.source import QueryIR


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


# =============================================================================
# Case 1 + 2 — next_morsel single-shot: one HitBatch Morsel, then None.
# =============================================================================


def test_01_next_morsel_single_shot_then_eof() raises:
    var bytes = _build_split(1)
    var q = QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    var spec = Searcher(bytes^, String("split-1"), String("logs"), q^)
    var reader = SearchMorselSource.from_spec(spec)

    # FIRST claim returns the one HitBatch Morsel.
    var first = reader.next_morsel(0)
    assert_true(Bool(first))
    var morsel: Morsel = first.take()
    assert_equal(morsel.batch.num_columns(), 3)
    assert_equal(morsel.batch.num_rows(), 3)
    # ranked: doc 1 (tf=2) first, then docs 0 and 2 (tf=1, tie -> lower id first).
    assert_equal(Int(_id_at(morsel.batch, 0)), 1)
    assert_equal(Int(_id_at(morsel.batch, 1)), 0)
    assert_equal(Int(_id_at(morsel.batch, 2)), 2)

    # SECOND claim sees c >= 1 -> single-pass EOF (None).
    var second = reader.next_morsel(0)
    assert_false(Bool(second))
    # ... and stays None on every subsequent claim.
    var third = reader.next_morsel(0)
    assert_false(Bool(third))


# =============================================================================
# Case 3 — output_schema / row_count_hint / partition_hint / capabilities.
# =============================================================================


def test_03_reader_metadata() raises:
    var bytes = _build_split(3)
    var q = QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    var spec = Searcher(bytes^, String("split-3"), String("logs"), q^)
    var reader = SearchMorselSource.from_spec(spec)

    var sch = reader.output_schema()
    assert_equal(sch.num_columns(), 3)
    assert_true(sch.field_arrow_type(0) == ArrowType.FLOAT64)
    assert_true(sch.field_arrow_type(1) == ArrowType.INT64)
    assert_true(sch.field_arrow_type(2) == ArrowType.STRING)

    # 3 matching docs -> row_count_hint == 3.
    assert_equal(reader.row_count_hint(), 3)
    # a single split is one logical partition.
    assert_equal(reader.partition_hint(), 1)
    # no hooks advertised.
    var caps = reader.capabilities()
    assert_false(caps.supports_projection)
    assert_false(caps.supports_decode_filter)
    assert_false(caps.supports_dynamic_filter)
    assert_false(caps.supports_as_source)


# =============================================================================
# Case 4 — Searcher SourceLike surface: schema / estimate_rows / pushdown.
# =============================================================================


def test_04_searcher_sourcelike_surface() raises:
    var bytes = _build_split(4)
    var q = QueryIR(String("body"), String("alpha"), 7, _text_cfg())
    var spec = Searcher(bytes^, String("split-4"), String("logs"), q^)

    # schema == the hit schema.
    var sch = spec.schema()
    assert_equal(sch.num_columns(), 3)
    assert_equal(sch.field_name(0), String("_score"))
    assert_equal(sch.field_name(1), String("_id"))
    assert_equal(sch.field_name(2), String("_source"))
    # estimate_rows == top_k.
    assert_equal(spec.estimate_rows(), 7)


# =============================================================================
# Case 5 — fingerprint distinctness (the plan-cache collision class).
# =============================================================================


def test_05_fingerprint_folds_analyzer_config() raises:
    var bytes_a = _build_split(5)
    var bytes_b = _build_split(5)

    # Two Searchers, SAME query_text, but DIFFERENT AnalyzerConfig:
    #   cfg_default = text() (lowercase + fold + english stopwords)
    #   cfg_nostop  = text() but remove_stopwords = False
    # They normalize a query to DIFFERENT term sets -> MUST NOT CSE-collide.
    var cfg_default = AnalyzerConfig.text("body")
    var cfg_nostop = AnalyzerConfig(
        String("body"), FIELD_CLASS_TEXT, True, True, False, String("")
    )

    var q_default = QueryIR(
        String("body"), String("the alpha"), 10, cfg_default^
    )
    var q_nostop = QueryIR(
        String("body"), String("the alpha"), 10, cfg_nostop^
    )

    var spec_default = Searcher(
        bytes_a^, String("split-5"), String("logs"), q_default^
    )
    var spec_nostop = Searcher(
        bytes_b^, String("split-5"), String("logs"), q_nostop^
    )

    assert_not_equal(
        spec_default.fingerprint(),
        spec_nostop.fingerprint(),
    )


def test_05b_fingerprint_distinct_and_stable() raises:
    var ba = _build_split(6)
    var bb = _build_split(6)
    var bc = _build_split(6)
    var q1 = QueryIR(
        String("body"), String("alpha"), 10, AnalyzerConfig.text("body")
    )
    var q2 = QueryIR(
        String("body"), String("beta"), 10, AnalyzerConfig.text("body")
    )  # different text

    var s1 = Searcher(ba^, String("split-6"), String("logs"), q1^)
    var s2 = Searcher(bb^, String("split-6"), String("logs"), q2^)
    # different query_text -> different fingerprint.
    assert_not_equal(s1.fingerprint(), s2.fingerprint())

    # same everything -> same fingerprint, STABLE across copy().
    var q1b = QueryIR(String("body"), String("alpha"), 10, AnalyzerConfig.text("body"))
    var s1b = Searcher(bc^, String("split-6"), String("logs"), q1b^)
    assert_equal(s1.fingerprint(), s1b.fingerprint())
    var s1_copy = s1.copy()
    assert_equal(s1.fingerprint(), s1_copy.fingerprint())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

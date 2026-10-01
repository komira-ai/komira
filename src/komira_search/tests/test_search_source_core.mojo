# =============================================================================
# test_search_source_core.mojo — the SearchCore KEYSTONE proof
# =============================================================================
#
# The PURE read-path proof (no morsel runtime).
# Builds a small split IN-MEMORY via the exact analyzer -> inverted index ->
# term dictionary -> split writer write path
# (analyze -> InvertedIndexBuilder -> finalize -> TermDictBuilder + DocStoreBuilder
# -> serialize_split), then drives SearchCore.search(QueryIR) and asserts RANKED
# hits against MODERN-BM25 hand vectors recomputed in-test (cross-checked via the
# SAME score.mojo functions, so the assertions track the scorer, not a magic
# constant).
#
# Coverage (enumerated cases):
#   1.  single-term `match`: matching doc-ids == the term's posting list; per-doc
#       scores == bm25_score_contribution(bm25_idf(n, N), tf, Bm25Params()).
#   2.  multi-term union + SUM: a doc matching two query terms gets the SUM; a
#       doc matching one gets only that one.
#   3.  term absent in split: lookup -> None -> contributes nothing (no crash).
#   4.  top-k truncation: top_k < #matches -> exactly the top_k highest, DESC.
#   5.  _source fetch: each hit's _source == the doc-store blob for its slot.
#   6.  query-time SYMMETRY: indexed "café" folds to "cafe"; query "CAFÉ" matches
#       via the SAME _analyze_bytes funnel.
#   7.  dedup query terms: a repeated query term does NOT double-count IDF.
#   8.  HitBatch schema: _score Float64 / _id Int64 / _source STRING.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
    assert_raises,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.record_batch import RecordBatch

from komira_search.analyzer import (
    AnalyzedField,
    AnalyzerConfig,
    Token,
    FIELD_CLASS_TEXT,
)
from komira_search.inverted import InvertedIndexBuilder, FinalizedIndex
from komira_search.term_dict import TermDictBuilder, TermDictionary
from komira_search.split import serialize_split, DocStoreBuilder
from komira_search.fast_fields import (
    NumericFastFieldBuilder,
    serialize_fastfields_region,
    FastFieldSpec,
    KeywordFastFieldBuilder,
)
from komira_search.score import Bm25Params, bm25_idf, bm25_score_contribution
from komira_search.source import (
    QueryIR,
    SearchCore,
    HIT_COL_SCORE,
    HIT_COL_ID,
    HIT_COL_SOURCE,
)


# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------


def _af(terms: List[String]) -> AnalyzedField:
    """An AnalyzedField from a flat list of term strings (emission-order)."""
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
    """The v1 TEXT analyzer (lowercase + ASCII-fold + English stopwords)."""
    return AnalyzerConfig.text("body")


def _expected_contrib(
    n: Int, big_n: Int, tf: Int, dl: Int, avgdl: Float64
) -> Float64:
    """The MODERN-BM25 single-term contribution WITH doc-length normalization,
    recomputed via score.mojo so the assertion tracks the scorer (not a hardcoded
    constant). Default Bm25Params() carries the Lucene/OpenSearch b=0.75; `dl` is
    the scored doc's token count (its "__fieldnorm__"), `avgdl` the per-split
    average. This MIRRORS what SearchCore.search feeds the scorer per posting
    (fast-fields cutover)."""
    return bm25_score_contribution(
        bm25_idf(n, big_n), tf, Bm25Params(), doc_len=dl, avg_doc_len=avgdl
    )


def _avgdl(doc_terms: List[List[String]]) -> Float64:
    """The per-split avg doc length = sum(token_count_i) / N. The token count of
    doc i (its "__fieldnorm__") is len(doc_terms[i]) — these splits feed
    pre-analyzed term lists, so no stopword/fold reduction applies (every term
    in the list is one token). Matches FastFieldReader.fieldnorms()."""
    var total = 0
    var n = len(doc_terms)
    for i in range(n):
        total += len(doc_terms[i])
    if n == 0:
        return 0.0
    return Float64(total) / Float64(n)


# Column accessors over the HitBatch (Float64 _score, Int64 _id, STRING _source).


def _score_at(batch: RecordBatch, row: Int) raises -> Float64:
    var arr = batch.column_at(0).as_primitive[DType.float64]()
    return Float64(arr.get(row))


def _id_at(batch: RecordBatch, row: Int) raises -> Int64:
    var arr = batch.column_at(1).as_primitive[DType.int64]()
    return Int64(arr.get(row))


def _source_at(batch: RecordBatch, row: Int) raises -> String:
    var arr = batch.column_at(2).as_string()
    return arr.get(row)


# A reusable split builder: maps each doc's pre-analyzed term list + _source blob
# into the in-memory split bytes (the analyzer->the split writer write path).


def _build_split(
    doc_terms: List[List[String]],
    doc_sources: List[String],
    seed: UInt8,
) raises -> List[UInt8]:
    """Build a single split from per-doc analyzed terms + _source blobs. doc_id i
    == the i-th doc (dense, min_doc_id=0).

    Fieldnorm: this WRITES the "__fieldnorm__" fast-field region (one INT64
    per doc == that doc's token count len(doc_terms[i])) the SAME way the
    production IndexSink does — so SearchCore.search exercises the real
    b=0.75 doc-length-normalization path. Without it the split would have
    no fieldnorm and the scorer would silently degrade to b=0,
    defeating the b=0.75 proof. The fieldnorm region carries ONLY the
    fieldnorm (no other fast-field columns) — exactly the all-inverted-plus-
    fieldnorm shape a text-only index produces."""
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder()
    var n = len(doc_terms)
    var fieldnorm = NumericFastFieldBuilder(
        ArrowType.INT64.type_id, DType.int64
    )
    for i in range(n):
        b.add_document(i, _af(doc_terms[i]))
        ds.append(doc_sources[i].as_bytes())
        # dl == the per-doc token count (these are pre-analyzed term lists, so
        # the token count is exactly len(doc_terms[i])).
        fieldnorm.append_int(len(doc_terms[i]), is_null=False)
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var ff_region = serialize_fastfields_region(
        List[FastFieldSpec](),
        List[NumericFastFieldBuilder](),
        List[KeywordFastFieldBuilder](),
        fieldnorm,
    )
    return serialize_split(
        fi, td^, ds, String("body"), _uuid(seed), 0, n - 1, n, ff_region^
    )


# =============================================================================
# Case 1 — single-term match: doc-ids == posting list, scores == hand vectors.
# =============================================================================


def test_01_single_term_match_ranked() raises:
    # 4 docs. "alpha" in docs {0, 2, 3} with TFs {1, 3, 2}. N = 4, n = 3.
    var doc_terms = List[List[String]]()
    doc_terms.append([String("alpha")])  # doc 0: tf(alpha)=1
    doc_terms.append([String("beta")])  # doc 1: no alpha
    doc_terms.append(
        [String("alpha"), String("alpha"), String("alpha")]
    )  # doc 2: tf(alpha)=3
    doc_terms.append([String("alpha"), String("alpha")])  # doc 3: tf(alpha)=2
    var doc_sources: List[String] = [
        String("d0"),
        String("d1"),
        String("d2"),
        String("d3"),
    ]
    var bytes = _build_split(doc_terms, doc_sources, 1)
    var core = SearchCore(bytes^)
    assert_equal(core.doc_count(), 4)

    var q = QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    var _res_hits = core.search(q)
    var hits = _res_hits.take_batch()

    # 3 matching docs, ranked DESC by score. n=3, N=4 -> idf fixed. dls = {doc0:
    # 1, doc2: 3, doc3: 2}; avgdl = (1+1+3+2)/4 = 1.75. With b=0.75 the longer
    # docs take a length penalty, but here dl grows WITH tf (the repeats ARE the
    # length), so tf-saturation still dominates: doc2(tf3,dl3) > doc3(tf2,dl2) >
    # doc0(tf1,dl1) — ranking PRESERVED across the cutover.
    var av1 = _avgdl(doc_terms)
    assert_almost_equal(av1, 1.75)
    assert_equal(hits.num_rows(), 3)
    assert_equal(Int(_id_at(hits, 0)), 2)
    assert_equal(Int(_id_at(hits, 1)), 3)
    assert_equal(Int(_id_at(hits, 2)), 0)
    # Scores match the modern-BM25 length-normalized hand vectors (b=0.75).
    assert_almost_equal(_score_at(hits, 0), _expected_contrib(3, 4, 3, 3, av1))
    assert_almost_equal(_score_at(hits, 1), _expected_contrib(3, 4, 2, 2, av1))
    assert_almost_equal(_score_at(hits, 2), _expected_contrib(3, 4, 1, 1, av1))
    # Descending invariant.
    assert_true(_score_at(hits, 0) > _score_at(hits, 1))
    assert_true(_score_at(hits, 1) > _score_at(hits, 2))


# =============================================================================
# Case 2 — multi-term union + SUM.
# =============================================================================


def test_02_multi_term_union_sum() raises:
    # doc 0: "alpha beta"  -> matches both query terms (alpha, beta)
    # doc 1: "alpha"        -> matches only alpha
    # doc 2: "beta"         -> matches only beta
    # doc 3: "gamma"        -> matches neither
    var doc_terms = List[List[String]]()
    doc_terms.append([String("alpha"), String("beta")])
    doc_terms.append([String("alpha")])
    doc_terms.append([String("beta")])
    doc_terms.append([String("gamma")])
    var doc_sources: List[String] = [
        String("d0"),
        String("d1"),
        String("d2"),
        String("d3"),
    ]
    var bytes = _build_split(doc_terms, doc_sources, 2)
    var core = SearchCore(bytes^)

    var q = QueryIR(String("body"), String("alpha beta"), 10, _text_cfg())
    var _res_hits = core.search(q)
    var hits = _res_hits.take_batch()

    # n(alpha)=2 docs {0,1}; n(beta)=2 docs {0,2}. N=4. All TFs == 1.
    # dls = {doc0: 2, doc1: 1, doc2: 1, doc3: 1}; avgdl = (2+1+1+1)/4 = 1.25.
    # doc0 carries BOTH terms but is the LONGEST doc (dl=2) -> each of its term
    # contributions takes a length penalty (dl=2 > avgdl=1.25); docs 1/2 are
    # SHORTER (dl=1 < avgdl) -> their single contribution is boosted. The SUM of
    # doc0's two (penalized) terms still strictly exceeds either single
    # (boosted) term -> doc0 ranks first; docs 1,2 tie (same n, tf, dl).
    var av2 = _avgdl(doc_terms)
    assert_almost_equal(av2, 1.25)
    # doc0's per-term contribution (dl=2); docs 1/2's contribution (dl=1).
    var c0_alpha = _expected_contrib(2, 4, 1, 2, av2)
    var c0_beta = _expected_contrib(2, 4, 1, 2, av2)
    var c_single = _expected_contrib(2, 4, 1, 1, av2)
    # doc 0 = alpha + beta (SUM); docs 1, 2 = single term each. doc 3 absent.
    assert_equal(hits.num_rows(), 3)
    # doc 0 ranks first (sum of both, even with the length penalty).
    assert_equal(Int(_id_at(hits, 0)), 0)
    assert_almost_equal(_score_at(hits, 0), c0_alpha + c0_beta)
    # docs 1 and 2 tie on score; tie-break = lower doc_id first -> doc 1 then 2.
    assert_equal(Int(_id_at(hits, 1)), 1)
    assert_equal(Int(_id_at(hits, 2)), 2)
    assert_almost_equal(_score_at(hits, 1), c_single)
    assert_almost_equal(_score_at(hits, 2), c_single)
    # the union doc strictly outranks the single-term docs.
    assert_true(_score_at(hits, 0) > _score_at(hits, 1))


# =============================================================================
# Case 3 — term absent in split contributes nothing (no crash).
# =============================================================================


def test_03_term_absent() raises:
    var doc_terms = List[List[String]]()
    doc_terms.append([String("alpha")])
    doc_terms.append([String("beta")])
    var doc_sources: List[String] = [String("d0"), String("d1")]
    var bytes = _build_split(doc_terms, doc_sources, 3)
    var core = SearchCore(bytes^)

    # query a term that is NOT in the split -> empty result, schema-valid.
    var q = QueryIR(String("body"), String("zzz_not_present"), 10, _text_cfg())
    var _res_hits = core.search(q)
    var hits = _res_hits.take_batch()
    assert_equal(hits.num_rows(), 0)
    assert_equal(hits.num_columns(), 3)

    # query mixing a present + absent term: only the present term contributes.
    var q2 = QueryIR(String("body"), String("alpha zzz"), 10, _text_cfg())
    var _res_hits2 = core.search(q2)
    var hits2 = _res_hits2.take_batch()
    assert_equal(hits2.num_rows(), 1)
    assert_equal(Int(_id_at(hits2, 0)), 0)
    # dls = {doc0: 1, doc1: 1}; avgdl = 1.0. dl == avgdl -> norm = 1.0 -> the
    # length term is neutral (score == the pre-cutover b=0 value here).
    var av3 = _avgdl(doc_terms)
    assert_almost_equal(av3, 1.0)
    assert_almost_equal(_score_at(hits2, 0), _expected_contrib(1, 2, 1, 1, av3))


# =============================================================================
# Case 4 — top-k truncation: exactly top_k highest-scoring docs, descending.
# =============================================================================


def test_04_top_k_truncation() raises:
    # 5 docs all containing "alpha" with strictly increasing TFs 1..5, so the
    # ranking is fully determined: doc 4 (tf=5) > doc 3 > doc 2 > doc 1 > doc 0.
    var doc_terms = List[List[String]]()
    var doc_sources = List[String]()
    for i in range(5):
        var terms = List[String]()
        for _ in range(i + 1):  # tf = i+1
            terms.append(String("alpha"))
        doc_terms.append(terms^)
        doc_sources.append(String("d") + String(i))
    var bytes = _build_split(doc_terms, doc_sources, 4)
    var core = SearchCore(bytes^)

    # top_k = 2 over 5 matches -> exactly the 2 highest, descending.
    var q = QueryIR(String("body"), String("alpha"), 2, _text_cfg())
    var _res_hits = core.search(q)
    var hits = _res_hits.take_batch()
    assert_equal(hits.num_rows(), 2)
    assert_equal(Int(_id_at(hits, 0)), 4)  # tf=5, highest
    assert_equal(Int(_id_at(hits, 1)), 3)  # tf=4, second
    assert_true(_score_at(hits, 0) > _score_at(hits, 1))
    # dl == tf for each doc (the i+1 alpha tokens ARE the length); avgdl =
    # (1+2+3+4+5)/5 = 3.0. n=5, N=5 -> idf == ln(1 + 0.5/5.5). tf-saturation
    # still dominates the length penalty -> ranking PRESERVED (doc4 > doc3).
    var av4 = _avgdl(doc_terms)
    assert_almost_equal(av4, 3.0)
    assert_almost_equal(_score_at(hits, 0), _expected_contrib(5, 5, 5, 5, av4))
    assert_almost_equal(_score_at(hits, 1), _expected_contrib(5, 5, 4, 4, av4))


# =============================================================================
# Case 5 — _source fetch: each hit's _source == the doc-store blob for its slot.
# =============================================================================


def test_05_source_fetch() raises:
    var doc_terms = List[List[String]]()
    doc_terms.append([String("alpha")])
    doc_terms.append([String("alpha"), String("alpha")])
    doc_terms.append([String("beta")])
    var doc_sources: List[String] = [
        String("{\"id\":0}"),
        String("{\"id\":1}"),
        String("{\"id\":2}"),
    ]
    var bytes = _build_split(doc_terms, doc_sources, 5)
    var core = SearchCore(bytes^)

    var q = QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    var _res_hits = core.search(q)
    var hits = _res_hits.take_batch()
    assert_equal(hits.num_rows(), 2)
    # doc 1 (tf=2) ranks first -> _source == doc_sources[1]; doc 0 second.
    assert_equal(Int(_id_at(hits, 0)), 1)
    assert_equal(_source_at(hits, 0), String("{\"id\":1}"))
    assert_equal(Int(_id_at(hits, 1)), 0)
    assert_equal(_source_at(hits, 1), String("{\"id\":0}"))


# =============================================================================
# Case 6 — query-time symmetry: indexed "café" folds to "cafe"; "CAFÉ" matches.
# =============================================================================


def test_06_query_time_symmetry() raises:
    # Index the RAW text "café" through the SAME analyzer (lowercase + ASCII-fold)
    # so the stored term is the folded "cafe". The query "CAFÉ" must fold to the
    # SAME "cafe" via the SAME _analyze_bytes funnel and match.
    from komira_search.analyzer import analyze_text

    var cfg = _text_cfg()
    var doc0 = analyze_text(String("café"), cfg)  # index-time analyze
    var doc1 = analyze_text(String("teahouse"), cfg)

    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, doc0^)
    b.add_document(1, doc1^)
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var ds = DocStoreBuilder()
    ds.append(String("the cafe doc").as_bytes())
    ds.append(String("the tea doc").as_bytes())
    var bytes = serialize_split(
        fi, td^, ds, String("body"), _uuid(6), 0, 1, 2
    )
    var core = SearchCore(bytes^)

    # Query with an UPPERCASE accented form -> folds to "cafe" -> matches doc 0.
    var q = QueryIR(String("body"), String("CAFÉ"), 10, cfg.copy())
    var _res_hits = core.search(q)
    var hits = _res_hits.take_batch()
    assert_equal(hits.num_rows(), 1)
    assert_equal(Int(_id_at(hits, 0)), 0)
    assert_equal(_source_at(hits, 0), String("the cafe doc"))


# =============================================================================
# Case 7 — dedup query terms: a repeated query term does NOT double-count.
# =============================================================================


def test_07_dedup_query_terms() raises:
    var doc_terms = List[List[String]]()
    doc_terms.append([String("alpha")])
    doc_terms.append([String("beta")])
    var doc_sources: List[String] = [String("d0"), String("d1")]
    var bytes = _build_split(doc_terms, doc_sources, 7)
    var core = SearchCore(bytes^)

    # query "alpha alpha alpha" must score doc 0 the SAME as query "alpha"
    # (deduped to one unique term — no triple IDF contribution).
    var q_rep = QueryIR(String("body"), String("alpha alpha alpha"), 10, _text_cfg())
    var _res_hits_rep = core.search(q_rep)
    var hits_rep = _res_hits_rep.take_batch()
    var q_one = QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    var _res_hits_one = core.search(q_one)
    var hits_one = _res_hits_one.take_batch()

    assert_equal(hits_rep.num_rows(), 1)
    assert_equal(hits_one.num_rows(), 1)
    assert_almost_equal(_score_at(hits_rep, 0), _score_at(hits_one, 0))
    # dls = {doc0: 1, doc1: 1}; avgdl = 1.0; dl == avgdl -> norm = 1.0.
    var av7 = _avgdl(doc_terms)
    assert_almost_equal(av7, 1.0)
    assert_almost_equal(_score_at(hits_rep, 0), _expected_contrib(1, 2, 1, 1, av7))


# =============================================================================
# Case 8 — HitBatch schema: _score Float64 / _id Int64 / _source STRING.
# =============================================================================


def test_08_hit_batch_schema() raises:
    var doc_terms = List[List[String]]()
    doc_terms.append([String("alpha")])
    var doc_sources: List[String] = [String("d0")]
    var bytes = _build_split(doc_terms, doc_sources, 8)
    var core = SearchCore(bytes^)

    var q = QueryIR(String("body"), String("alpha"), 10, _text_cfg())
    var _res_hits = core.search(q)
    var hits = _res_hits.take_batch()
    assert_equal(hits.num_columns(), 3)
    assert_equal(hits.schema.field_name(0), HIT_COL_SCORE)
    assert_equal(hits.schema.field_name(1), HIT_COL_ID)
    assert_equal(hits.schema.field_name(2), HIT_COL_SOURCE)
    assert_true(hits.schema.field_arrow_type(0) == ArrowType.FLOAT64)
    assert_true(hits.schema.field_arrow_type(1) == ArrowType.INT64)
    assert_true(hits.schema.field_arrow_type(2) == ArrowType.STRING)
    assert_equal(hits.num_rows(), 1)


# =============================================================================
# Case 9 — corrupt-split fail-loud at construction.
# =============================================================================


def test_09_corrupt_split_raises() raises:
    var doc_terms = List[List[String]]()
    doc_terms.append([String("alpha")])
    var doc_sources: List[String] = [String("d0")]
    var good = _build_split(doc_terms, doc_sources, 9)
    # Corrupt the front magic -> SplitView.parse (at SearchCore construction)
    # must raise loudly.
    var bad = List[UInt8]()
    for i in range(len(good)):
        bad.append(good[i])
    bad[0] = UInt8(0)
    with assert_raises():
        var _c = SearchCore(bad^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

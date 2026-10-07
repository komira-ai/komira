# =============================================================================
# test_search_wand_phase0_equivalence.mojo
#   WAND — the EXACT top-K equivalence gate.
# =============================================================================
#
# Relies on the float-summation-order pin and the _TopKHeap.is_full() /
# root_score() accessors.
#
# For the WAND-eligible path (SORT_MODE_SCORE, no aggs, no filter, >= 2 present
# query terms, a bounded window) SearchCore.search runs a DAAT term-max merge that
# SKIPS the full BM25 scoring of docs whose summed per-term max-impact UPPER
# bound is STRICTLY < theta (the running K-th-best score). The result MUST stay
# BYTE-IDENTICAL to scoring everyone. Single-term / aggs / filter / count-only
# queries take the EXACT brute walk; the multi-term score-ranked
# cases below exercise the WAND path.
#
# THE LOAD-BEARING GATE (correctness must NOT be compromised):
# the result MUST be BYTE-IDENTICAL to a brute-force top-K. The brute-force
# baseline is an INDEPENDENT in-test oracle (`_brute_topk`) — a from-scratch
# re-implementation of "score EVERY matching doc, sort by (score DESC, doc_id
# ASC), page-slice" computed directly from the decoded postings + fieldnorms.
# The oracle does NOT call SearchCore and does NOT skip — it is the reference the
# WAND-skipping SearchCore must reproduce exactly. If WAND ever differs, the gate
# HARD-FAILS (a wrong bound or wrong theta boundary drops a true top-K doc).
#
# Each cell asserts, over the returned page:
#   (1) identical doc-id sequence,
#   (2) BIT-identical Float64 scores (raw `==`, NOT epsilon — the float-order
#       pin makes exact equality achievable),
#   (3) identical score-tie -> lower-doc-id tiebreak,
#   (4) identical total_matches.
#
# Matrix (scoped to the `match` query surface — match is always disjunctive,
# there is no AND operator yet, so "conjunctive" = a query whose
# terms FULLY co-occur, exercising the multi-term sum on overlapping postings):
#   * single-term match (brute path — n_present < 2)
#   * multi-term OR (disjunctive — partial overlap; WAND path)
#   * multi-term "AND" (all terms co-occur in the same docs — full overlap)
#   * from/size pagination (the over-fetch window)
#   * sort-by-score (the default _score path) + explicit "_score"
#   * a score-TIE corpus (duplicate-content docs) — pins the tiebreak +
#     the theta-boundary (ub == theta must NOT be skipped)
#   * K=1 (heap warm-up never engages) and K >= all matches (no truncation)
#   * a SELECTIVE skewed-IDF corpus where WAND ACTUALLY skips: a rare high-idf
#     term + a common low-idf term, K small -> the common-only docs fall below
#     theta and get skipped. Proves the skipping does NOT change the result, over
#     K=1/2/3, term-order swaps, and a tied-low-score group at the theta boundary.
#
# Encapsulation: ZERO UnsafePointer / wildcard / from_address / take_pointee.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch

from komira_search.analyzer import AnalyzedField, AnalyzerConfig, Token
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
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
    SearchResult,
    SORT_FIELD_SCORE,
)


# -----------------------------------------------------------------------------
# Write-path helper (cloned from test_search_source_core.mojo `_build_split`):
# per-doc pre-analyzed term list + _source blob -> in-memory split bytes, with
# the "__fieldnorm__" fast-field region (one INT64/doc == token count) so the
# real b=0.75 doc-length-normalization path runs.
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


def _build_split(
    doc_terms: List[List[String]],
    doc_sources: List[String],
    seed: UInt8,
    blockmax: Bool = True,
) raises -> List[UInt8]:
    """Build one split from per-doc analyzed terms + _source blobs. doc_id i ==
    the i-th doc (dense, min_doc_id=0). Writes a "__fieldnorm__" INT64/doc =
    len(doc_terms[i]) so the b=0.75 fieldnorm path runs (identical to the
    source-core keystone's builder).

    When `blockmax` is True (DEFAULT) the split carries the WAND Phase-2 BLOCKMAX
    region (per-doc token_counts + total supplied to serialize_split), so
    SearchCore.search takes the BMW block-max path. When False the split is
    written WITHOUT the BLOCKMAX region (token_counts omitted) — an OLD-shaped
    split that SearchCore falls back to Phase-1 term-max WAND on (the
    backward-compat case). Either way the result MUST be byte-identical to the
    brute oracle."""
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder()
    var n = len(doc_terms)
    var fieldnorm = NumericFastFieldBuilder(
        ArrowType.INT64.type_id, DType.int64
    )
    var token_counts = List[Int]()
    var total_tokens = 0
    for i in range(n):
        b.add_document(i, _af(doc_terms[i]))
        ds.append(doc_sources[i].as_bytes())
        fieldnorm.append_int(len(doc_terms[i]), is_null=False)
        token_counts.append(len(doc_terms[i]))
        total_tokens += len(doc_terms[i])
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var ff_region = serialize_fastfields_region(
        List[FastFieldSpec](),
        List[NumericFastFieldBuilder](),
        List[KeywordFastFieldBuilder](),
        fieldnorm,
    )
    if blockmax:
        return serialize_split(
            fi,
            td^,
            ds,
            String("body"),
            _uuid(seed),
            0,
            n - 1,
            n,
            ff_region^,
            total_tokens,
            token_counts^,
        )
    # Backward-compat path: no total / no token_counts -> no BLOCKMAX region.
    return serialize_split(
        fi, td^, ds, String("body"), _uuid(seed), 0, n - 1, n, ff_region^
    )


# -----------------------------------------------------------------------------
# HitBatch accessors.
# -----------------------------------------------------------------------------


def _score_at(batch: RecordBatch, row: Int) raises -> Float64:
    return Float64(batch.column_at(0).as_primitive[DType.float64]().get(row))


def _id_at(batch: RecordBatch, row: Int) raises -> Int64:
    return Int64(batch.column_at(1).as_primitive[DType.int64]().get(row))


# -----------------------------------------------------------------------------
# THE INDEPENDENT BRUTE-FORCE ORACLE.
#
# Re-implements the reference top-K from first principles over the SAME corpus,
# WITHOUT calling SearchCore. Mirrors the documented scoring contract exactly:
#   * avgdl = sum(token_count) / N   (token_count_i = len(doc_terms[i]))
#   * idf(t) = bm25_idf(doc_freq(t), N), precomputed once per UNIQUE query term
#   * a doc's score = Σ_{t in dedup-term order, t in doc} contribution(t, doc)
#     summed IN dedup-term order  so the f64 result is bit-identical
#   * dedup the query terms in first-seen order
#   * rank by (score DESC, doc_id ASC), then page-slice [from, from+size)
#
# Returns (ids, scores) parallel lists for the page, plus total_matches.
# `doc_terms` is the per-doc analyzed token list (these tests pass pre-analyzed
# single-token terms, so query tokenization == splitting on spaces + dedup,
# matching what analyze_text does for these space-separated lowercase tokens).
# -----------------------------------------------------------------------------


@fieldwise_init
struct _Oracle(Movable):
    var ids: List[Int]
    var scores: List[Float64]
    var total_matches: Int


def _dedup_query_terms(query_text: String) -> List[String]:
    """Split the query on spaces + dedup in first-seen order (these test queries
    are lowercase single-token words, so this == the analyze_text + dedup the
    source path runs; no stopword/fold applies to these tokens)."""
    var terms = List[String]()
    for part in query_text.split(" "):
        var t = String(part)
        if t.byte_length() == 0:
            continue
        var seen = False
        for ui in range(len(terms)):
            if terms[ui] == t:
                seen = True
                break
        if not seen:
            terms.append(t)
    return terms^


def _doc_freq(doc_terms: List[List[String]], term: String) -> Int:
    var n = 0
    for d in range(len(doc_terms)):
        for k in range(len(doc_terms[d])):
            if doc_terms[d][k] == term:
                n += 1
                break
    return n


def _tf(doc: List[String], term: String) -> Int:
    var c = 0
    for k in range(len(doc)):
        if doc[k] == term:
            c += 1
    return c


def _brute_topk(
    doc_terms: List[List[String]],
    query_text: String,
    top_k: Int,
    from_offset: Int,
) raises -> _Oracle:
    var n = len(doc_terms)
    var big_n = n
    var params = Bm25Params()

    # avgdl = sum(token counts) / N.
    var total_tokens = 0
    for d in range(n):
        total_tokens += len(doc_terms[d])
    var avgdl = (Float64(total_tokens) / Float64(n)) if n > 0 else 0.0

    var qterms = _dedup_query_terms(query_text)

    # Precompute idf per unique query term (idf depends only on (n, N)).
    var idfs = List[Float64]()
    for ti in range(len(qterms)):
        idfs.append(bm25_idf(_doc_freq(doc_terms, qterms[ti]), big_n))

    # Per-doc score, summed IN dedup-term order; `touched` = first-touched.
    # Mirror the source path's first-touch test (acc[slot] == 0.0 BEFORE the +=)
    # so the matched set + order match byte-for-byte, including the rare
    # zero-contribution duplicate-append corner.
    var acc = List[Float64](length=n if n > 0 else 0, fill=0.0)
    var touched = List[Int]()
    for ti in range(len(qterms)):
        var term = qterms[ti]
        var idf = idfs[ti]
        for d in range(n):
            var tf = _tf(doc_terms[d], term)
            if tf == 0:
                continue  # doc d does not contain this term -> no posting.
            if acc[d] == 0.0:
                touched.append(d)
            var dl = len(doc_terms[d])
            acc[d] = acc[d] + bm25_score_contribution(
                idf, tf, params, doc_len=dl, avg_doc_len=avgdl
            )

    var total_matches = len(touched)

    # Rank the touched docs by (score DESC, doc_id ASC) — selection sort over a
    # small set, identical ordering to the _TopKHeap SCORE-mode tiebreak.
    var ord = List[Int]()
    for i in range(len(touched)):
        ord.append(touched[i])
    var m = len(ord)
    for i in range(m):
        var best = i
        for j in range(i + 1, m):
            var sj = acc[ord[j]]
            var sb = acc[ord[best]]
            var jw: Bool
            if sj != sb:
                jw = sj > sb
            else:
                jw = ord[j] < ord[best]
            if jw:
                best = j
        var t = ord[i]
        ord[i] = ord[best]
        ord[best] = t

    # Page-slice [from, min(len, from+size)).
    var page_start = from_offset if from_offset > 0 else 0
    var page_end = from_offset + top_k
    if page_end > m:
        page_end = m
    var ids = List[Int]()
    var scores = List[Float64]()
    if page_start < page_end:
        for oi in range(page_start, page_end):
            ids.append(ord[oi])
            scores.append(acc[ord[oi]])
    return _Oracle(ids^, scores^, total_matches)


# -----------------------------------------------------------------------------
# The differential assertion: run SearchCore.search and assert BYTE-IDENTICAL to
# the oracle (page ids in order, BIT-exact f64 scores, total_matches).
# -----------------------------------------------------------------------------


def _assert_batch_eq_oracle(
    var res: SearchResult,
    doc_terms: List[List[String]],
    query_text: String,
    top_k: Int,
    from_offset: Int,
    label: String,
) raises:
    """Assert one SearchResult is byte-identical to the brute oracle (page ids in
    order, BIT-exact f64 scores, total_matches)."""
    ref got = res.batch
    var want = _brute_topk(doc_terms, query_text, top_k, from_offset)

    # (4) total_matches identical.
    assert_equal(
        res.total_matches,
        want.total_matches,
        String("total_matches mismatch [") + label + String("]"),
    )
    # Page row count identical.
    assert_equal(
        got.num_rows(),
        len(want.ids),
        String("page row count mismatch [") + label + String("]"),
    )
    # (1) doc-id sequence + (2) BIT-identical Float64 scores + (3) tiebreak order.
    for r in range(got.num_rows()):
        assert_equal(
            Int(_id_at(got, r)),
            want.ids[r],
            String("doc-id mismatch at row ") + String(r) + String(" [")
            + label + String("]"),
        )
        # RAW f64 equality (NOT epsilon): the float-order pin makes the
        # WAND/BMW sum bit-identical to the brute-force sum.
        var gs = _score_at(got, r)
        var ws = want.scores[r]
        assert_true(
            gs == ws,
            String("score NOT bit-identical at row ") + String(r) + String(
                " ["
            ) + label + String("]: got ") + String(gs) + String(" want ")
            + String(ws),
        )


def _assert_one(
    core: SearchCore,
    doc_terms: List[List[String]],
    query_text: String,
    top_k: Int,
    from_offset: Int,
    sort_field: String,
    label: String,
) raises:
    """Assert ALL THREE scorer paths are byte-identical to the brute oracle:
      * search        — Phase-1 term-max WAND (the production default);
      * search_bmw    — Phase-2 BMW block-max (forced; the codec skip-list path);
      * search_no_wand — the brute baseline (sanity-pins the oracle itself).
    Any divergence in ANY path is a HARD FAIL (a non-byte-identical
    top-K is a wrong answer)."""
    var q = QueryIR(
        String("body"),
        query_text,
        top_k,
        _text_cfg(),
        0,
        None,
        sort_field,
        UInt8(0),  # SORT_DESC
        UInt8(0),  # MISSING_LAST
        from_offset,
    )
    var r1 = core.search(q)
    _assert_batch_eq_oracle(
        r1^, doc_terms, query_text, top_k, from_offset,
        label + String(" [phase1]"),
    )
    var r2 = core.search_bmw(q)
    _assert_batch_eq_oracle(
        r2^, doc_terms, query_text, top_k, from_offset,
        label + String(" [bmw]"),
    )
    var r3 = core.search_no_wand(q)
    _assert_batch_eq_oracle(
        r3^, doc_terms, query_text, top_k, from_offset,
        label + String(" [brute]"),
    )


def _assert_equiv(
    doc_terms: List[List[String]],
    doc_sources: List[String],
    query_text: String,
    top_k: Int,
    from_offset: Int,
    sort_field: String,
    seed: UInt8,
    label: String,
) raises:
    """Assert byte-identity to the brute oracle for BOTH split shapes:
      (a) the BLOCKMAX split (SearchCore takes the Phase-2 BMW block-max path);
      (b) the NO-BLOCKMAX split (an OLD split -> Phase-1 term-max WAND fallback).
    A WAND/BMW divergence from the oracle in EITHER shape is a HARD FAIL — the
    backward-compat fallback MUST also be byte-identical."""
    # (a) BLOCKMAX (BMW) split.
    var bmw_bytes = _build_split(doc_terms, doc_sources, seed, blockmax=True)
    var bmw_core = SearchCore(bmw_bytes^)
    _assert_one(
        bmw_core,
        doc_terms,
        query_text,
        top_k,
        from_offset,
        sort_field,
        label + String(" [BMW]"),
    )
    # (b) NO-BLOCKMAX (Phase-1 fallback) split — backward-compat.
    var p1_bytes = _build_split(doc_terms, doc_sources, seed, blockmax=False)
    var p1_core = SearchCore(p1_bytes^)
    _assert_one(
        p1_core,
        doc_terms,
        query_text,
        top_k,
        from_offset,
        sort_field,
        label + String(" [P1-fallback]"),
    )


# Two reusable corpora ----------------------------------------------------------


def _corpus_mixed() -> Tuple[List[List[String]], List[String]]:
    """6 docs over {alpha, beta, gamma} with varied tf + dl. alpha in {0,1,2,4},
    beta in {0,2,3}, gamma in {1,5}. Overlap (doc0 alpha+beta) + singletons."""
    var dt = List[List[String]]()
    dt.append([String("alpha"), String("beta")])  # 0: a1 b1
    dt.append([String("alpha"), String("gamma"), String("gamma")])  # 1: a1 g2
    dt.append(
        [String("alpha"), String("alpha"), String("beta")]
    )  # 2: a2 b1
    dt.append([String("beta")])  # 3: b1
    dt.append([String("alpha")])  # 4: a1
    dt.append([String("gamma")])  # 5: g1
    var src = List[String]()
    for i in range(6):
        src.append(String("doc") + String(i))
    return (dt^, src^)


def _corpus_cooccur() -> Tuple[List[List[String]], List[String]]:
    """4 docs where `red` and `blue` ALWAYS co-occur (full overlap) — the
    "conjunctive"-shaped multi-term sum (match is a disjunctive union, but on
    fully-overlapping postings the union == intersection). Varied tf so scores
    differ."""
    var dt = List[List[String]]()
    dt.append([String("red"), String("blue")])  # 0
    dt.append([String("red"), String("red"), String("blue")])  # 1
    dt.append([String("red"), String("blue"), String("blue")])  # 2
    dt.append([String("green")])  # 3: neither
    var src = List[String]()
    for i in range(4):
        src.append(String("c") + String(i))
    return (dt^, src^)


def _corpus_ties() -> Tuple[List[List[String]], List[String]]:
    """6 docs, three pairs of IDENTICAL content (so equal scores) -> pins the
    score-tie -> lower-doc-id tiebreak. Docs 0/1 == "x", 2/3 == "x x", 4/5 ==
    "x x x"."""
    var dt = List[List[String]]()
    dt.append([String("x")])  # 0
    dt.append([String("x")])  # 1 (== 0)
    dt.append([String("x"), String("x")])  # 2
    dt.append([String("x"), String("x")])  # 3 (== 2)
    dt.append([String("x"), String("x"), String("x")])  # 4
    dt.append([String("x"), String("x"), String("x")])  # 5 (== 4)
    var src = List[String]()
    for i in range(6):
        src.append(String("t") + String(i))
    return (dt^, src^)


def _corpus_selective() -> Tuple[List[List[String]], List[String]]:
    """A SELECTIVE skewed-IDF corpus that forces the WAND path to actually SKIP.
    `rare` occurs in only 2 docs (high idf -> high contribution); `common`
    occurs in MANY docs (low idf -> low contribution). On a query `rare common`
    with K small, the two `rare` docs (which also carry `common`) dominate the
    top-K; once the heap fills, theta rises above the common-only docs' upper
    bound, so they get skipped. The brute oracle still scores everyone -> the
    differential proves the skip changes nothing.

    Layout (20 docs):
      docs 0..1   : `rare common`         (the two high-scoring winners)
      docs 2..15  : `common filler<i>`    (common-only; low score; skip targets)
      docs 16..19 : `filler<i>`           (neither query term; never matched)
    Varied filler so doc lengths differ (the dl/avgdl normalization is live).
    """
    var dt = List[List[String]]()
    # Two docs carrying BOTH the rare and the common term.
    dt.append([String("rare"), String("common")])  # 0
    dt.append([String("rare"), String("rare"), String("common")])  # 1
    # Common-only docs (the skip targets) — varied tf + dl.
    for i in range(2, 16):
        var d = List[String]()
        d.append(String("common"))
        # vary the doc length so the dl normalization differs per doc.
        for _ in range((i % 3) + 1):
            d.append(String("filler") + String(i))
        dt.append(d^)
    # Docs that carry neither query term.
    for i in range(16, 20):
        dt.append([String("filler") + String(i)])
    var src = List[String]()
    for i in range(20):
        src.append(String("s") + String(i))
    return (dt^, src^)


def _corpus_selective_tied() -> Tuple[List[List[String]], List[String]]:
    """Like _corpus_selective but the common-only skip targets all have IDENTICAL
    content (so identical low scores) — pins the theta-BOUNDARY: a doc whose
    upper bound == theta must NOT be skipped (it could tie the K-th best and win
    on the lower-doc-id tiebreak). The two `rare common` winners + a block of
    equal-score `common` docs exercise the `ub >= theta` (NOT `>`) skip rule."""
    var dt = List[List[String]]()
    dt.append([String("rare"), String("common")])  # 0
    dt.append([String("rare"), String("common")])  # 1 (== 0)
    # 10 IDENTICAL common-only docs (equal scores -> tie at the boundary).
    for _ in range(10):
        dt.append([String("common"), String("common")])
    var src = List[String]()
    for i in range(12):
        src.append(String("u") + String(i))
    return (dt^, src^)


def _corpus_multiblock() -> Tuple[List[List[String]], List[String]]:
    """A MULTI-BLOCK corpus (300 docs) that exercises the BMW block-DECODE skip +
    the block-BOUNDARY corner (POSTING_BLOCK_DOCS == 128). `common` is in EVERY
    doc (300 docs -> 3 posting blocks: [0,128) [128,256) [256,300)), so BMW must
    decode block doc-ids across all 3 blocks for the union AND skip the TF-unpack
    of the below-theta blocks. `rare` is planted in a HANDFUL of docs placed at
    and around the block edges (127, 128, 255, 256 — the cardinal off-by-one BMW
    risk: a competitive doc at a block boundary must NOT be dropped). Doc lengths
    vary (live dl/avgdl). The brute oracle scores everyone; the differential
    proves the multi-block decode-skip + the boundary handling change nothing.

    Layout (n = 300):
      every doc        : `common` + varied filler (3 posting blocks)
      docs {127,128,255,256,5} ALSO carry `rare` (high idf; block-edge placement)
    """
    var n = 300
    var rare_at = List[Int]()
    rare_at.append(5)
    rare_at.append(127)  # last doc of block 0
    rare_at.append(128)  # first doc of block 1
    rare_at.append(255)  # last doc of block 1
    rare_at.append(256)  # first doc of block 2
    var dt = List[List[String]]()
    for i in range(n):
        var d = List[String]()
        d.append(String("common"))
        var has_rare = False
        for k in range(len(rare_at)):
            if rare_at[k] == i:
                has_rare = True
                break
        if has_rare:
            d.append(String("rare"))
        # vary the doc length so dl normalization differs per doc/block.
        for _ in range((i % 4) + 1):
            d.append(String("filler") + String(i % 7))
        dt.append(d^)
    var src = List[String]()
    for i in range(n):
        src.append(String("m") + String(i))
    return (dt^, src^)


# =============================================================================
# Tests
# =============================================================================


def test_single_term() raises:
    var c = _corpus_mixed()
    _assert_equiv(
        c[0], c[1], String("alpha"), 10, 0, String(""), 10,
        String("single-term alpha"),
    )
    _assert_equiv(
        c[0], c[1], String("gamma"), 10, 0, String(""), 10,
        String("single-term gamma"),
    )


def test_multi_term_or_disjunctive() raises:
    var c = _corpus_mixed()
    # alpha+beta: partial overlap (doc0, doc2 carry both; others one).
    _assert_equiv(
        c[0], c[1], String("alpha beta"), 10, 0, String(""), 11,
        String("multi-OR alpha beta"),
    )
    # three-term union.
    _assert_equiv(
        c[0], c[1], String("alpha beta gamma"), 10, 0, String(""), 11,
        String("multi-OR alpha beta gamma"),
    )


def test_multi_term_cooccur_conjunctive_shape() raises:
    var c = _corpus_cooccur()
    # red+blue fully co-occur -> the multi-term SUM over overlapping postings.
    _assert_equiv(
        c[0], c[1], String("red blue"), 10, 0, String(""), 12,
        String("cooccur red blue"),
    )


def test_pagination_from_size() raises:
    var c = _corpus_mixed()
    # Over-fetch window: from=1 size=2 over the alpha+beta+gamma union.
    _assert_equiv(
        c[0], c[1], String("alpha beta gamma"), 2, 1, String(""), 13,
        String("page from=1 size=2"),
    )
    # from=2 size=10 (past the start, fewer than size remaining).
    _assert_equiv(
        c[0], c[1], String("alpha beta gamma"), 10, 2, String(""), 13,
        String("page from=2 size=10"),
    )
    # from beyond total -> empty page (still schema-valid).
    _assert_equiv(
        c[0], c[1], String("alpha beta gamma"), 5, 100, String(""), 13,
        String("page from=100 (empty)"),
    )


def test_sort_by_score_explicit() raises:
    var c = _corpus_mixed()
    # explicit "_score" == default "" -> SORT_MODE_SCORE; must be byte-identical.
    _assert_equiv(
        c[0], c[1], String("alpha beta gamma"), 10, 0, SORT_FIELD_SCORE, 14,
        String("explicit _score sort"),
    )


def test_score_tie_tiebreak() raises:
    var c = _corpus_ties()
    # Equal-content docs -> equal scores; the tiebreak must yield ascending
    # doc-id within each tie group, byte-identical to the heap's SCORE tiebreak.
    _assert_equiv(
        c[0], c[1], String("x"), 10, 0, String(""), 15,
        String("score-tie full page"),
    )
    # The tie corpus under a tight page (size=3) — the tie ordering at the page
    # boundary must still be the heap's exact resolution.
    _assert_equiv(
        c[0], c[1], String("x"), 3, 0, String(""), 15,
        String("score-tie page size=3"),
    )


def test_k1_and_k_ge_all() raises:
    var c = _corpus_mixed()
    # K=1 (heap warm-up never fully engages on a >1-match query).
    _assert_equiv(
        c[0], c[1], String("alpha beta gamma"), 1, 0, String(""), 16,
        String("K=1"),
    )
    # K >= all matches (no truncation; must still be exact + ordered).
    _assert_equiv(
        c[0], c[1], String("alpha beta gamma"), 100, 0, String(""), 16,
        String("K>=all"),
    )


def test_term_absent() raises:
    var c = _corpus_mixed()
    # A query term absent in the split contributes nothing (no crash); the other
    # term still scores. zzz absent, alpha present.
    _assert_equiv(
        c[0], c[1], String("alpha zzz"), 10, 0, String(""), 17,
        String("term absent zzz"),
    )
    # ALL terms absent -> empty page, total_matches == 0.
    _assert_equiv(
        c[0], c[1], String("zzz qqq"), 10, 0, String(""), 17,
        String("all terms absent"),
    )


def test_wand_selective_skip() raises:
    """The headline WAND-skipping case: a rare high-idf term + a common low-idf
    term over a SELECTIVE corpus, K small enough that the common-only docs fall
    below theta and get SKIPPED. The result MUST be byte-identical to the brute
    oracle (which scores everyone). Sweeps K and term order."""
    var c = _corpus_selective()
    # K=1: only the single strongest doc survives; theta engages immediately.
    _assert_equiv(
        c[0], c[1], String("rare common"), 1, 0, String(""), 30,
        String("selective rare+common K=1"),
    )
    # K=2: both `rare common` winners; the 14 common-only docs are skip targets.
    _assert_equiv(
        c[0], c[1], String("rare common"), 2, 0, String(""), 30,
        String("selective rare+common K=2"),
    )
    # K=3: the two winners + the strongest common-only doc; the rest skipped.
    _assert_equiv(
        c[0], c[1], String("rare common"), 3, 0, String(""), 30,
        String("selective rare+common K=3"),
    )
    # Term ORDER swapped — the dedup-term order changes, so the per-doc float
    # sum order changes; both WAND and the oracle must agree under either order.
    _assert_equiv(
        c[0], c[1], String("common rare"), 2, 0, String(""), 30,
        String("selective common+rare K=2 (order swap)"),
    )
    # A pagination window over the selective corpus (from=1 size=2).
    _assert_equiv(
        c[0], c[1], String("rare common"), 2, 1, String(""), 30,
        String("selective rare+common from=1 size=2"),
    )
    # K >= all matched (no skip — every matched doc reaches the heap; must still
    # be byte-identical).
    _assert_equiv(
        c[0], c[1], String("rare common"), 100, 0, String(""), 30,
        String("selective rare+common K>=all"),
    )


def test_wand_selective_theta_boundary() raises:
    """The theta-BOUNDARY case (the cardinal WAND correctness corner): a block of
    EQUAL-score common-only docs at the threshold. The skip rule is STRICTLY
    `ub < theta` — a doc whose bound == theta must still be evaluated (it may tie
    the K-th best and win the lower-doc-id tiebreak). Byte-identity over a sweep
    of K straddling the tie group proves the boundary is exactly right."""
    var c = _corpus_selective_tied()
    for k in range(1, 8):
        _assert_equiv(
            c[0], c[1], String("rare common"), k, 0, String(""), 31,
            String("selective-tied K=") + String(k),
        )
    # And a paginated window landing inside the tie group.
    _assert_equiv(
        c[0], c[1], String("rare common"), 3, 2, String(""), 31,
        String("selective-tied from=2 size=3"),
    )


def test_bmw_multiblock_skip_and_boundary() raises:
    """The Phase-2 BMW headline: a 300-doc / 3-posting-block corpus where the
    common term spans all 3 blocks (so BMW decodes block doc-ids across blocks
    for the exact union, and skips the TF-unpack of below-theta blocks), and the
    `rare` term is planted AT and around the block boundaries (127/128/255/256).
    The result MUST be byte-identical to the brute oracle that scores everyone —
    over a K sweep that straddles the boundary placements + a pagination window +
    the term-order swap. A dropped block-edge doc, an off-by-one in the block
    byte-offset skip-list, or a wrong last/first-doc handling would diverge."""
    var c = _corpus_multiblock()
    # K sweep: K=1/2/3/5/8 — the `rare` docs (5 of them, at block edges) must all
    # rank above the common-only sea once theta engages; the multi-block decode +
    # skip must still surface them in the right order.
    _assert_equiv(
        c[0], c[1], String("rare common"), 1, 0, String(""), 40,
        String("multiblock K=1"),
    )
    _assert_equiv(
        c[0], c[1], String("rare common"), 3, 0, String(""), 40,
        String("multiblock K=3"),
    )
    _assert_equiv(
        c[0], c[1], String("rare common"), 5, 0, String(""), 40,
        String("multiblock K=5 (all rare docs)"),
    )
    _assert_equiv(
        c[0], c[1], String("rare common"), 8, 0, String(""), 40,
        String("multiblock K=8 (rare docs + top common)"),
    )
    # Pagination window crossing the rare/common ranking boundary.
    _assert_equiv(
        c[0], c[1], String("rare common"), 4, 3, String(""), 40,
        String("multiblock from=3 size=4"),
    )
    # Term-order swap (dedup-term order changes -> the per-doc float sum order
    # changes; both BMW and the oracle must agree under either order).
    _assert_equiv(
        c[0], c[1], String("common rare"), 5, 0, String(""), 40,
        String("multiblock common+rare K=5 (order swap)"),
    )
    # K >= all matched (no skip — every matched doc reaches the heap; the
    # multi-block decode + union must still be byte-identical).
    _assert_equiv(
        c[0], c[1], String("rare common"), 1000, 0, String(""), 40,
        String("multiblock K>=all"),
    )
    # A single-common-term multi-block query (n_present < 2 -> brute path on BOTH
    # split shapes; pins that the BLOCKMAX split's brute fallback is also exact).
    _assert_equiv(
        c[0], c[1], String("common"), 10, 0, String(""), 40,
        String("multiblock single-term common"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

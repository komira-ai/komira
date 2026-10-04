# =============================================================================
# test_search_bm25.mojo — the BM25 scorer unit test
# =============================================================================
#
# The scorer pins the MODERN Lucene 8.0+/OpenSearch 3.0+ BM25Similarity: NO
# (k1+1) numerator. Every `want` below is RECOMPUTED in-test to full Float64
# precision from the modern formula (NOT copied from a literal — a vector
# computed with the Legacy form would be off by the 2.2x factor), asserted to
# abs(got - want) < 1e-9.
#
# Coverage:
#   IDF        — bm25_idf hand-checked vectors: idf(5,10)=ln2,
#                idf(1,10), idf(10,10) n=N, idf(1,1) N=1, idf(0,10) n=0.
#   CONTRIB    — bm25_score_contribution modern vectors (idf=ln2, k1=1.2, b=0):
#                tf={0,1,2,3,10}; saturation ceiling = idf (NOT 2.2*idf).
#   PARITY     — OpenSearch-parity vector: contribution(idf(5,10),2,default)
#                ~= 0.4332170 (the MODERN value, NOT the Legacy 0.9530774).
#   LEGACY     — bm25_score_contribution with legacy=True recovers the (k1+1)
#                numerator (asserts the opt-in field works + is NOT the default).
#   TF_COMPONENT — saturation factor at b=0 = tf/(tf+k1); ceiling -> 1.0.
#   EDGE       — n=0, n=N (>0), tf=0 (exactly 0.0), N=1.
#   ACCUM      — single-term and multi-term union/sum on a hand-built
#                Dict[Int, Float64] doc_id->score map (pure scalars, no split):
#                a doc matching two terms gets the SUM of the two contributions.
# =============================================================================

from std.math import log
from std.testing import (
    TestSuite,
    assert_true,
    assert_false,
    assert_equal,
)

from komira_search.score import (
    Bm25Params,
    bm25_idf,
    bm25_tf_component,
    bm25_score_contribution,
)


# -----------------------------------------------------------------------------
# Test helpers — recompute the references IN-TEST (do NOT trust copied literals)
# -----------------------------------------------------------------------------

comptime TOL: Float64 = 1e-9


def _close(got: Float64, want: Float64) -> Bool:
    """abs(got - want) < TOL."""
    var d = got - want
    if d < 0.0:
        d = -d
    return d < TOL


def _ref_idf(n: Int, big_n: Int) -> Float64:
    """The IDF reference, recomputed independently of score.mojo's impl
    (same formula, separate evaluation — this is the cross-check)."""
    var nf = Float64(n)
    var nn = Float64(big_n)
    return log(1.0 + (nn - nf + 0.5) / (nf + 0.5))


def _ref_contrib_modern(idf: Float64, tf: Int, k1: Float64) -> Float64:
    """MODERN contribution reference with NO length norm (avgdl unusable -> the
    dl/avgdl term vanishes -> norm=1.0): idf * tf / (tf + k1). This is the value
    bm25_score_contribution returns when called WITHOUT doc_len/avg_doc_len even
    at the b=0.75 default (avgdl==0.0 degrades to norm=1.0)."""
    var tff = Float64(tf)
    return idf * (tff / (tff + k1))


def _ref_contrib_lengthnorm(
    idf: Float64, tf: Int, k1: Float64, b: Float64, dl: Int, avgdl: Float64
) -> Float64:
    """MODERN contribution reference WITH doc-length normalization (b>0):
    idf * tf / (tf + k1 * (1 - b + b * dl/avgdl)). Recomputed independently of
    score.mojo so the assertion cross-checks the scorer."""
    var tff = Float64(tf)
    var norm = 1.0 - b + b * (Float64(dl) / avgdl)
    return idf * (tff / (tff + k1 * norm))


def _ref_contrib_legacy(idf: Float64, tf: Int, k1: Float64) -> Float64:
    """LEGACY contribution reference at b=0: idf * (tf*(k1+1)) / (tf + k1)."""
    var tff = Float64(tf)
    return idf * ((tff * (k1 + 1.0)) / (tff + k1))


# -----------------------------------------------------------------------------
# IDF hand-checked vectors — recomputed in-test
# -----------------------------------------------------------------------------


def test_idf_vectors() raises:
    # idf(5,10) = ln(1 + 5.5/5.5) = ln(2).
    assert_true(_close(bm25_idf(5, 10), log(2.0)))
    assert_true(_close(bm25_idf(5, 10), _ref_idf(5, 10)))
    # idf(1,10) = ln(1 + 9.5/1.5) = ln(7.3333...).
    assert_true(_close(bm25_idf(1, 10), _ref_idf(1, 10)))
    assert_true(_close(bm25_idf(1, 10), log(1.0 + 9.5 / 1.5)))
    # idf(10,10) n=N = ln(1 + 0.5/10.5) — small but strictly POSITIVE.
    assert_true(_close(bm25_idf(10, 10), _ref_idf(10, 10)))
    assert_true(bm25_idf(10, 10) > 0.0)
    # idf(1,1) N=1 = ln(1 + 0.5/1.5).
    assert_true(_close(bm25_idf(1, 1), _ref_idf(1, 1)))
    # idf(0,10) n=0 defensive = ln(1 + 10.5/0.5) = ln(22) — finite, positive.
    assert_true(_close(bm25_idf(0, 10), _ref_idf(0, 10)))
    assert_true(_close(bm25_idf(0, 10), log(22.0)))


# -----------------------------------------------------------------------------
# Contribution hand-checked vectors — MODERN form, idf=ln2, k1=1.2, b=0
# -----------------------------------------------------------------------------


def test_contribution_modern_vectors() raises:
    var p = Bm25Params()  # k1=1.2, b=0.75, avgdl=0.0, legacy=False (modern)
    assert_equal(p.k1, 1.2)
    assert_equal(p.b, 0.75)  # Lucene/OpenSearch default
    assert_false(p.legacy)
    var idf = bm25_idf(5, 10)  # = ln 2
    # Called WITHOUT doc_len/avg_doc_len, avgdl==0.0 -> the dl/avgdl term is
    # unusable -> the scorer degrades to norm=1.0 -> the vectors below are the
    # SAME tf/(tf+k1) as the pre-cutover b=0 form. The dedicated length-norm
    # vectors are in test_contribution_lengthnorm_vectors below.

    # tf=0 -> exactly 0.0 (graceful).
    assert_equal(bm25_score_contribution(idf, 0, p), 0.0)
    # tf={1,2,3,10}: each == idf * tf/(tf+1.2), recomputed independently.
    var tfs = List[Int]()
    tfs.append(1)
    tfs.append(2)
    tfs.append(3)
    tfs.append(10)
    for i in range(len(tfs)):
        var tf = tfs[i]
        var got = bm25_score_contribution(idf, tf, p)
        var want = _ref_contrib_modern(idf, tf, 1.2)
        assert_true(_close(got, want))

    # tf=1 modern: idf * 1/2.2 ~= 0.3150669.
    assert_true(_close(bm25_score_contribution(idf, 1, p), idf * (1.0 / 2.2)))
    # tf=2 modern: idf * 2/3.2 ~= 0.4332170 (the parity value; NOT 0.9530774).
    assert_true(_close(bm25_score_contribution(idf, 2, p), idf * (2.0 / 3.2)))
    # tf=10 modern: idf * 10/11.2 ~= 0.6188814.
    assert_true(_close(bm25_score_contribution(idf, 10, p), idf * (10.0 / 11.2)))


# -----------------------------------------------------------------------------
# Saturation ceiling — modern factor -> 1.0 (ceiling = idf), NOT 2.2*idf
# -----------------------------------------------------------------------------


def test_saturation_ceiling_is_idf() raises:
    var p = Bm25Params()
    var idf = bm25_idf(5, 10)
    # As tf grows the contribution approaches idf (factor -> 1.0), bounded ABOVE
    # by idf. The Legacy (k1+1) form would approach 2.2*idf — assert we do NOT.
    var huge = bm25_score_contribution(idf, 1_000_000, p)
    assert_true(huge < idf)  # strictly below the ceiling
    assert_true(huge > idf * 0.999)  # but very close to it
    assert_true(huge < idf * 1.5)  # decisively NOT the 2.2*idf Legacy ceiling

    # Monotonic increase in tf, all bounded by idf.
    var c1 = bm25_score_contribution(idf, 1, p)
    var c2 = bm25_score_contribution(idf, 2, p)
    var c10 = bm25_score_contribution(idf, 10, p)
    assert_true(c1 < c2)
    assert_true(c2 < c10)
    assert_true(c10 < idf)


# -----------------------------------------------------------------------------
# OpenSearch-parity vector — MODERN value 0.4332170, NOT 0.9530774
# -----------------------------------------------------------------------------


def test_opensearch_parity_vector() raises:
    # bm25_score_contribution(bm25_idf(5,10), 2, Bm25Params()) = ln2 * 2/3.2.
    var got = bm25_score_contribution(bm25_idf(5, 10), 2, Bm25Params())
    var want = log(2.0) * (2.0 / 3.2)
    assert_true(_close(got, want))
    # Sanity: the MODERN value is ~0.4332170, well clear of the Legacy 0.9530774.
    assert_true(got > 0.43)
    assert_true(got < 0.44)
    assert_true(got < 0.9)  # decisively NOT the Legacy value


# -----------------------------------------------------------------------------
# Legacy opt-in — legacy=True recovers the (k1+1) numerator; NOT the default
# -----------------------------------------------------------------------------


def test_legacy_opt_in() raises:
    var idf = bm25_idf(5, 10)  # = ln 2
    var modern = Bm25Params()  # legacy False (default)
    var legacy = Bm25Params(k1=1.2, b=0.0, avgdl=0.0, legacy=True)
    assert_false(modern.legacy)
    assert_true(legacy.legacy)

    # Legacy tf=2: idf * (2*2.2)/3.2 ~= 0.9530774 (the Legacy value).
    var got_legacy = bm25_score_contribution(idf, 2, legacy)
    var want_legacy = _ref_contrib_legacy(idf, 2, 1.2)
    assert_true(_close(got_legacy, want_legacy))
    assert_true(_close(got_legacy, idf * ((2.0 * 2.2) / 3.2)))

    # The legacy value is exactly (k1+1) = 2.2x the modern value at any tf>0.
    var got_modern = bm25_score_contribution(idf, 2, modern)
    assert_true(_close(got_legacy, got_modern * 2.2))


# -----------------------------------------------------------------------------
# bm25_tf_component directly — b=0 factor = tf/(tf+k1); ceiling -> 1.0
# -----------------------------------------------------------------------------


def test_tf_component_b0() raises:
    # Explicit b=0 opt-out: the dl/avgdl term vanishes, factor = tf/(tf+k1).
    var p0 = Bm25Params(b=0.0)
    assert_equal(p0.b, 0.0)
    # tf=0 -> 0.0; tf=2 -> 2/3.2 = 0.625; tf=large -> ~1.0.
    assert_equal(bm25_tf_component(0, p0), 0.0)
    assert_true(_close(bm25_tf_component(2, p0), 2.0 / 3.2))
    assert_true(_close(bm25_tf_component(1, p0), 1.0 / 2.2))
    var ceil = bm25_tf_component(1_000_000, p0)
    assert_true(ceil < 1.0)
    assert_true(ceil > 0.999)
    # At b=0 doc_len / avg_doc_len are IGNORED: passing junk values changes
    # nothing (the dl/avgdl term is never evaluated).
    assert_equal(bm25_tf_component(2, p0, doc_len=999, avg_doc_len=42.0),
                 bm25_tf_component(2, p0))


# -----------------------------------------------------------------------------
# bm25_tf_component / bm25_score_contribution WITH length norm (b=0.75 default)
# -----------------------------------------------------------------------------


def test_tf_component_lengthnorm() raises:
    # Default params: k1=1.2, b=0.75. With dl/avgdl supplied the denominator is
    # tf + k1*(1 - b + b*dl/avgdl).
    var p = Bm25Params()
    assert_equal(p.b, 0.75)

    # avg_doc_len == 0.0 (and params.avgdl == 0.0) -> the dl/avgdl term is
    # UNUSABLE -> the scorer degrades to norm=1.0 (== b=0 behavior), NEVER a
    # div-by-zero. Passing dl with avgdl=0 changes nothing.
    assert_true(_close(bm25_tf_component(2, p), 2.0 / 3.2))
    assert_true(_close(
        bm25_tf_component(2, p, doc_len=999, avg_doc_len=0.0), 2.0 / 3.2
    ))

    # dl == avgdl -> ratio 1.0 -> norm = (1 - b + b*1) = 1.0 -> factor == b=0.
    assert_true(_close(
        bm25_tf_component(2, p, doc_len=10, avg_doc_len=10.0), 2.0 / 3.2
    ))

    # SHORT doc (dl < avgdl): norm < 1 -> denominator smaller -> factor LARGER
    # (a short doc matching a term is more "about" it -> ranks higher). dl=5,
    # avgdl=10, b=0.75: norm = 1 - 0.75 + 0.75*0.5 = 0.625; denom = 2 + 1.2*0.625
    # = 2.75; factor = 2/2.75.
    var short = bm25_tf_component(2, p, doc_len=5, avg_doc_len=10.0)
    assert_true(_close(short, 2.0 / (2.0 + 1.2 * 0.625)))
    assert_true(short > 2.0 / 3.2)  # short doc scores higher than avg-length

    # LONG doc (dl > avgdl): norm > 1 -> factor SMALLER. dl=20, avgdl=10:
    # norm = 1 - 0.75 + 0.75*2 = 1.75; denom = 2 + 1.2*1.75 = 4.1; factor=2/4.1.
    var long = bm25_tf_component(2, p, doc_len=20, avg_doc_len=10.0)
    assert_true(_close(long, 2.0 / (2.0 + 1.2 * 1.75)))
    assert_true(long < 2.0 / 3.2)  # long doc scores lower than avg-length

    # Monotone in dl: short > avg > long at fixed tf.
    assert_true(short > bm25_tf_component(2, p, doc_len=10, avg_doc_len=10.0))
    assert_true(bm25_tf_component(2, p, doc_len=10, avg_doc_len=10.0) > long)


def test_contribution_lengthnorm_vectors() raises:
    # bm25_score_contribution == idf * bm25_tf_component WITH length norm.
    var p = Bm25Params()  # b=0.75
    var idf = bm25_idf(5, 10)  # ln 2

    # dl=5, avgdl=10 (short doc), tf=2.
    var got_short = bm25_score_contribution(
        idf, 2, p, doc_len=5, avg_doc_len=10.0
    )
    var want_short = _ref_contrib_lengthnorm(idf, 2, 1.2, 0.75, 5, 10.0)
    assert_true(_close(got_short, want_short))

    # dl=20, avgdl=10 (long doc), tf=2.
    var got_long = bm25_score_contribution(
        idf, 2, p, doc_len=20, avg_doc_len=10.0
    )
    var want_long = _ref_contrib_lengthnorm(idf, 2, 1.2, 0.75, 20, 10.0)
    assert_true(_close(got_long, want_long))

    # The short doc strictly outscores the long doc at the same tf+idf.
    assert_true(got_short > got_long)

    # tf=0 -> 0.0 regardless of dl.
    assert_equal(
        bm25_score_contribution(idf, 0, p, doc_len=7, avg_doc_len=10.0), 0.0
    )

    # avg_doc_len arg WINS over params.avgdl when both set; params.avgdl is the
    # fallback. With params.avgdl=10 and NO explicit arg, dl=5 uses 10.0.
    var p_with_avgdl = Bm25Params(k1=1.2, b=0.75, avgdl=10.0)
    var got_fallback = bm25_score_contribution(idf, 2, p_with_avgdl, doc_len=5)
    assert_true(_close(got_fallback, want_short))


# -----------------------------------------------------------------------------
# Edge cases
# -----------------------------------------------------------------------------


def test_edge_cases() raises:
    var p = Bm25Params()
    # n=0 -> finite positive idf (no ln(0), no div-by-zero).
    var idf0 = bm25_idf(0, 10)
    assert_true(idf0 > 0.0)
    assert_true(_close(idf0, log(22.0)))
    # n=N -> small POSITIVE idf (the Lucene 1+ shift; naive ln(N/n) would be 0).
    var idf_nn = bm25_idf(10, 10)
    assert_true(idf_nn > 0.0)
    # tf=0 -> contribution exactly 0.0.
    assert_equal(bm25_score_contribution(bm25_idf(5, 10), 0, p), 0.0)
    # N=1 single-doc split scores without error.
    var idf_n1 = bm25_idf(1, 1)
    assert_true(idf_n1 > 0.0)
    var c = bm25_score_contribution(idf_n1, 1, p)
    assert_true(_close(c, idf_n1 * (1.0 / 2.2)))


# -----------------------------------------------------------------------------
# Single-term accumulation — mimic the SearchCore protocol on a Dict map
# -----------------------------------------------------------------------------


def test_single_term_accumulation() raises:
    # One query term, idf precomputed ONCE, three docs with tf = {1, 2, 3}.
    # acc[doc_id] += contribution — assert each doc's score == the vector.
    var p = Bm25Params()
    var idf = bm25_idf(5, 10)  # ln 2

    var acc = Dict[Int, Float64]()
    # (doc_id, tf) postings for this single term.
    var doc_ids = List[Int]()
    var tfs = List[Int]()
    doc_ids.append(100)
    tfs.append(1)
    doc_ids.append(200)
    tfs.append(2)
    doc_ids.append(300)
    tfs.append(3)

    for i in range(len(doc_ids)):
        var did = doc_ids[i]
        var contribution = bm25_score_contribution(idf, tfs[i], p)
        if did in acc:
            acc[did] = acc[did] + contribution
        else:
            acc[did] = contribution

    assert_true(_close(acc[100], _ref_contrib_modern(idf, 1, 1.2)))
    assert_true(_close(acc[200], _ref_contrib_modern(idf, 2, 1.2)))
    assert_true(_close(acc[300], _ref_contrib_modern(idf, 3, 1.2)))


# -----------------------------------------------------------------------------
# Multi-term union/sum invariant — a doc matching BOTH terms gets SUM
# -----------------------------------------------------------------------------


def test_multi_term_union_and_sum() raises:
    var p = Bm25Params()
    var n_docs = 10

    # Two terms with overlapping posting lists (the UNION).
    #   term A: df=5  -> idf_a = ln 2.    postings: doc 1 (tf 2), doc 2 (tf 1)
    #   term B: df=1  -> idf_b larger.    postings: doc 2 (tf 3), doc 3 (tf 1)
    # doc 2 matches BOTH -> its score must be contrib_a(2,tf=1)+contrib_b(2,tf=3).
    # doc 1 matches A only; doc 3 matches B only.
    var idf_a = bm25_idf(5, n_docs)
    var idf_b = bm25_idf(1, n_docs)
    assert_true(idf_b > idf_a)  # rarer term -> higher idf (sanity)

    var acc = Dict[Int, Float64]()

    # --- term A posting walk ---
    var a_docs = List[Int]()
    var a_tfs = List[Int]()
    a_docs.append(1)
    a_tfs.append(2)
    a_docs.append(2)
    a_tfs.append(1)
    for i in range(len(a_docs)):
        var did = a_docs[i]
        var c = bm25_score_contribution(idf_a, a_tfs[i], p)
        if did in acc:
            acc[did] = acc[did] + c
        else:
            acc[did] = c

    # --- term B posting walk ---
    var b_docs = List[Int]()
    var b_tfs = List[Int]()
    b_docs.append(2)
    b_tfs.append(3)
    b_docs.append(3)
    b_tfs.append(1)
    for i in range(len(b_docs)):
        var did = b_docs[i]
        var c = bm25_score_contribution(idf_b, b_tfs[i], p)
        if did in acc:
            acc[did] = acc[did] + c
        else:
            acc[did] = c

    # Independently-computed expected per-doc scores.
    var want_doc1 = _ref_contrib_modern(idf_a, 2, 1.2)  # A only
    var want_doc2 = (
        _ref_contrib_modern(idf_a, 1, 1.2)
        + _ref_contrib_modern(idf_b, 3, 1.2)
    )  # A + B summed
    var want_doc3 = _ref_contrib_modern(idf_b, 1, 1.2)  # B only

    assert_true(_close(acc[1], want_doc1))
    assert_true(_close(acc[2], want_doc2))
    assert_true(_close(acc[3], want_doc3))

    # The union/sum invariant: doc 2 (both terms) strictly exceeds either single
    # contribution that fed it.
    assert_true(acc[2] > _ref_contrib_modern(idf_a, 1, 1.2))
    assert_true(acc[2] > _ref_contrib_modern(idf_b, 3, 1.2))
    # Exactly three matched docs across the union.
    assert_equal(len(acc), 3)


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

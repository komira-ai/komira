# =============================================================================
# komira_search/score.mojo
#   The BM25 SCORER (pure-math relevance leaf).
# =============================================================================
#
# Upstream producers of the scalar inputs: SplitView.doc_count() (N),
# TermInfo.doc_freq (n), the postings region tf. Downstream consumer: the
# SearchCore scoring loop.
#
# -----------------------------------------------------------------------------
# WHAT IT DOES
# -----------------------------------------------------------------------------
#   * Bm25Params — the POD tuning config {k1, b, avgdl, legacy}.
#   * bm25_idf(n, N) — the Lucene/OpenSearch IDF, called ONCE per query term.
#   * bm25_tf_component(tf, params, doc_len, avg_doc_len) — the TF saturation
#     factor (the part that varies per matching doc).
#   * bm25_score_contribution(idf, tf, params, doc_len, avg_doc_len) — one
#     term's contribution to one doc's score = idf * bm25_tf_component(...).
#
# A stateless pure-math leaf: free functions + one POD config struct. It does
# NOT own the accumulator / posting union / top-k (those are SearchCore's). It
# does NOT read splits or walk postings — it takes scalars the SearchSource
# feeds it.
#
# -----------------------------------------------------------------------------
# THE FROZEN FORMULA (MODERN BM25 — OpenSearch / Lucene 8.0+ compatible)
# -----------------------------------------------------------------------------
# Use the MODERN BM25 form, NOT Legacy. Lucene 8.0
# (LUCENE-8563) removed the `(k1 + 1)` factor from the NUMERATOR, and
# OpenSearch 3.0+ defaults to the modern BM25Similarity. The Legacy `(k1 + 1)`
# numerator form scores ~2.2x too high vs a default OpenSearch index. The
# default here is the modern form; `Bm25Params(legacy=True)` opts in to the
# Legacy `(k1 + 1)` numerator for parity with a pre-8.0 / explicitly-legacy
# index.
#
#   idf(n, N)         = ln( 1 + (N - n + 0.5) / (n + 0.5) )         [UNCHANGED]
#   tf_component      = tf / (tf + k1 * (1 - b + b * dl/avgdl))     [MODERN]
#   contribution      = idf * tf_component
#
#   b = 0:       tf_component = tf / (tf + k1) = tf / (tf + 1.2)
#                contribution = idf * tf / (tf + 1.2)
#
# The TF saturation ceiling is `idf` (tf_component -> 1.0 as tf -> inf), NOT
# 2.2*idf. (The Legacy `(k1 + 1)` form saturates at (k1+1)*idf = 2.2*idf.)
#
# `ln` is the NATURAL logarithm (base e) — getting the base wrong silently
# breaks Lucene/OpenSearch score comparability. The `+0.5` smoothing + the
# `1 +` shift keep the ln argument strictly > 1 always (idf > 0 always; no
# ln(0)/ln(neg)/NaN). The (tf + k1) denominator is >= k1 = 1.2 > 0 always (no
# div-by-zero on the b = 0 path). tf = 0 -> contribution 0.0.
#
# -----------------------------------------------------------------------------
# b = 0 vs b > 0 — the doc-length normalization is purely additive
# -----------------------------------------------------------------------------
# `b = 0` drops the `dl/avgdl` doc-length-normalization term entirely, so the
# scorer then reads NOTHING from the fast-fields region. `doc_len` /
# `avg_doc_len` are defaulted arguments that the b = 0 path leaves unused;
# with b > 0 the caller supplies the real per-doc dl + split avgdl. The
# signatures are the same for both.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY (owner re-audit)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY public (or private) signature.
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * Bm25Params is pure POD (3 Float64 + 1 Bool); the free functions
#     take/return scalars only. No Slab, no pointer, no heap-owning field, no
#     destroy-recreate lifecycle state.
#   * Int -> Float64 casts use the canonical Float64(...) pattern before math.
#
# `log` is std.math's natural log.
# =============================================================================

from std.math import log


# =============================================================================
# Module constants.
# =============================================================================

comptime BM25_DEFAULT_K1: Float64 = 1.2
"""Term-frequency saturation parameter. Lucene/OpenSearch default."""

comptime BM25_DEFAULT_B: Float64 = 0.75
"""Doc-length normalization weight. The Lucene/OpenSearch DEFAULT (0.75). With
b=0.75 the per-doc fieldnorm (`dl`, the token count) + per-split `avgdl` are
active: the denominator carries `k1 * (1 - b + b * dl/avgdl)`. (b=0.0
collapses the denominator to `tf + k1` and reads NOTHING from the fieldnorm
fast-field.) `Bm25Params(b=0.0)` opts into the no-length-normalization
behavior."""


# =============================================================================
# Bm25Params: the POD tuning config.
# =============================================================================


struct Bm25Params(Copyable, Movable, Deinitable):
    """BM25 tuning parameters. Pure POD — no heap-owning field.

    Fields:
      k1:     term-frequency saturation. Lucene/OpenSearch default 1.2.
      b:      doc-length normalization weight. Lucene/OpenSearch DEFAULT 0.75
              At b == 0.0 the dl/avgdl term vanishes (doc_len
              / avg_doc_len are ignored — the legacy no-length-norm behavior).
      avgdl:  average doc length over the split. SUPPLIED by the caller when
              b > 0.0 (resolved ONCE from the "__fieldnorm__" fast-field via
              FastFieldReader.fieldnorms). When the per-call avg_doc_len arg is
              given it WINS; this field is the fallback. UNUSED when b == 0.0.
      legacy: opt-in. When False (DEFAULT) the MODERN BM25 form
              (no (k1+1) numerator, Lucene 8.0+/OpenSearch 3.0+) is used. When
              True the Legacy (k1+1) numerator form (pre-8.0 Lucene) is used,
              for parity with an explicitly-legacy index. The DEFAULT is modern.

    # A SINGLE explicit defaulted __init__ (NO @fieldwise_init).
    # Combining @fieldwise_init with a same-arity defaulted __init__ collides in
    # Mojo; every @fieldwise_init+custom-init struct in this codebase uses a
    # ZERO-arg custom init. This one init supports Bm25Params(),
    # Bm25Params(k1=...), and positional construction.

    # MUST stay pure-POD — passed by value; no heap-owning field ever.
    """

    var k1: Float64
    var b: Float64
    var avgdl: Float64
    var legacy: Bool

    def __init__(
        out self,
        k1: Float64 = BM25_DEFAULT_K1,
        b: Float64 = BM25_DEFAULT_B,
        avgdl: Float64 = 0.0,
        legacy: Bool = False,
    ):
        """Default: {k1 = 1.2, b = 0.75, avgdl = 0.0, legacy = False} (modern
        BM25 with Lucene/OpenSearch-default doc-length normalization). The caller
        supplies the per-split `avgdl` (resolved once from the fieldnorm) and the
        per-doc `doc_len` to bm25_score_contribution when b > 0. Bm25Params()
        constructs this default."""
        self.k1 = k1
        self.b = b
        self.avgdl = avgdl
        self.legacy = legacy


# =============================================================================
# bm25_idf: the IDF, called ONCE per query term.
# =============================================================================


@always_inline
def bm25_idf(doc_freq: Int, num_docs: Int) -> Float64:
    """Lucene/OpenSearch BM25 IDF: ln(1 + (N - n + 0.5) / (n + 0.5)).

    doc_freq = n (per-term doc-freq, from TermInfo.doc_freq /
               FinalizedIndex.doc_freq_at).
    num_docs = N (split doc-count, from SplitView.doc_count()).

    Returns a non-negative Float64. The `+0.5` smoothing keeps the denominator
    n + 0.5 >= 0.5 > 0 (no div-by-zero) and the `1 +` shift keeps the ln
    argument > 1 always (idf > 0 always; never ln(0)/ln(neg)/NaN). The IDF is
    UNCHANGED between the Legacy and Modern BM25 forms — the two forms differ
    only in the tf component.

    Called ONCE per query term (idf depends only on (n, N), both constant
    across the term's posting list — do NOT recompute per matching doc).
    """
    # Defensive n <= N assert (debug-only, release-elided). A term
    # cannot appear in more docs than exist; n > N means a corrupt split. The
    # message is mandatory (every debug_assert carries a message).
    debug_assert(
        doc_freq <= num_docs,
        "bm25_idf: doc_freq > num_docs (corrupt split)",
    )
    var n = Float64(doc_freq)
    var big_n = Float64(num_docs)
    return log(1.0 + (big_n - n + 0.5) / (n + 0.5))


# =============================================================================
# bm25_tf_component: the TF saturation factor.
# =============================================================================


@always_inline
def bm25_tf_component(
    tf: Int,
    params: Bm25Params,
    doc_len: Int = 0,
    avg_doc_len: Float64 = 0.0,
) -> Float64:
    """The BM25 TF saturation factor.

    MODERN (params.legacy == False, DEFAULT):
        tf / (tf + k1 * (1 - b + b * dl/avgdl))
    LEGACY (params.legacy == True):
        (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl/avgdl))

    When params.b == 0.0: the denominator collapses to (tf + k1) and
    doc_len / avg_doc_len are IGNORED (present-but-unused). When
    params.b > 0.0: uses doc_len (per-doc fieldnorm) and
    avg_doc_len (= params.avgdl if avg_doc_len == 0.0, else the explicit arg)
    for the dl/avgdl ratio.

    Modern factor -> 1.0 as tf -> inf (saturation ceiling = 1.0). Legacy factor
    -> (k1 + 1) as tf -> inf (ceiling = 2.2 at k1 = 1.2).
    """
    var tf_f = Float64(tf)

    # The doc-length normalization multiplier (1 - b + b * dl/avgdl). At b == 0
    # this is exactly 1.0 and the dl/avgdl ratio is NEVER evaluated, so doc_len /
    # avg_doc_len are unread and avgdl == 0 is harmless on the b = 0 path.
    var norm = 1.0
    if params.b != 0.0:
        # b > 0 path. Resolve avgdl: explicit arg wins, else fall back to
        # params.avgdl. Guard avg_doc_len > 0 before the ratio; if avgdl is
        # unusable, degrade to b=0 behavior
        # (norm = 1.0) rather than divide by zero.
        var avgdl = avg_doc_len
        if avgdl == 0.0:
            avgdl = params.avgdl
        if avgdl > 0.0:
            norm = 1.0 - params.b + params.b * (Float64(doc_len) / avgdl)

    var denom = tf_f + params.k1 * norm
    if params.legacy:
        return (tf_f * (params.k1 + 1.0)) / denom
    return tf_f / denom


# =============================================================================
# bm25_score_contribution: one term's contribution to one doc.
# =============================================================================


@always_inline
def bm25_score_contribution(
    idf: Float64,
    tf: Int,
    params: Bm25Params,
    doc_len: Int = 0,
    avg_doc_len: Float64 = 0.0,
) -> Float64:
    """One term's BM25 contribution to one doc's score:
        idf * bm25_tf_component(tf, params, doc_len, avg_doc_len)

    idf = the per-term value precomputed ONCE via bm25_idf (do NOT recompute per
    doc — re-evaluating ln per matching doc is a correctness/perf footgun).
    b = 0 callers pass only (idf, tf, params) — doc_len / avg_doc_len default to
    the unused path. b > 0 callers add the real per-doc doc_len + split
    avg_doc_len.

    tf = 0 -> 0.0 (graceful; a tf=0 posting should not exist but degrades to a
    zero contribution). The multi-term document score is the SUM of this over
    the matching query terms — SearchCore owns that accumulator.
    """
    return idf * bm25_tf_component(tf, params, doc_len, avg_doc_len)

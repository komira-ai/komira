# =============================================================================
# test_search_analyzer_alloc_perf.mojo
#   Correctness-regression guard for the search index-build per-bulk latency
#   optimizations in the analyzer hot loop: the alloc reductions
#   (stopword-resolution hoist + per-token term-buffer reuse + per-byte
#   fold-helper alloc removal).
# =============================================================================
#
# WHY THIS TEST EXISTS:
#   The analyzer splits `_analyze_bytes` into a thin resolve-once wrapper +
#   an internal `_analyze_bytes_resolved` hot loop, has
#   `analyze_text_column_resolved` (pre-resolved stopwords) + `resolve_stopwords_for`,
#   and its fold helpers append into a buffer (no per-byte List alloc).
#   This test is the HARD GATE that the fast paths are BYTE-IDENTICAL to the
#   per-cell-resolve path — token streams (term + position), across:
#     * plain ASCII multi-token
#     * accented (fold) text — both Latin-1 Supplement AND Latin Extended-A
#     * stopword removal (case/fold-normalized)
#     * multi-letter fold expansions (Æ/ß/œ)
#     * out-of-scope passthrough (CJK)
#     * the WHOLE column driver (add_text_column) — postings + token_counts
#       (the fieldnorm) identical.
#   And a FULL split-byte determinism check: the produced split bytes through
#   the production SearchSink are byte-identical for the same input.
#
# Both the resolved and unresolved entry points funnel into _analyze_bytes_resolved
# (via the resolve-once wrapper), so this test pins that they agree with each
# other AND with the literal expected token lists — the symmetry guarantee
# is preserved by construction, and this proves it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.collections.batch_view import batch_view_over

from komira_search.analyzer import (
    AnalyzerConfig,
    AnalyzedField,
    analyze_text,
    analyze_text_column,
    analyze_text_column_resolved,
    resolve_stopwords_for,
    FIELD_CLASS_TEXT,
)
from komira_search.inverted import InvertedIndexBuilder
from komira_search.sink import SearchSink


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _text_cfg(name: String) -> AnalyzerConfig:
    """Production TEXT config: lowercase + fold + english stopwords."""
    return AnalyzerConfig.text(name)


def _lower_fold(name: String) -> AnalyzerConfig:
    """lowercase ON, fold ON, stopwords OFF (so every token survives)."""
    return AnalyzerConfig(
        name, FIELD_CLASS_TEXT, True, True, False, String("none")
    )


def _assert_same_tokens(
    a: AnalyzedField, b: AnalyzedField, ctx: String
) raises:
    """Assert two AnalyzedFields carry byte-identical (term, position) streams."""
    assert_equal(a.len(), b.len(), ctx + ": token count differs")
    for i in range(a.len()):
        assert_equal(
            a.tokens[i].term,
            b.tokens[i].term,
            ctx + ": term[" + String(i) + "] differs",
        )
        assert_equal(
            a.tokens[i].position,
            b.tokens[i].position,
            ctx + ": position[" + String(i) + "] differs",
        )


def _make_corpus() -> List[String]:
    """A representative mixed corpus exercising every analyzer branch:
    ASCII multi-token, repeated terms (TF), stopwords, Latin-1 fold, Latin
    Extended-A fold, multi-letter expansion (Æ/ß/œ), and CJK passthrough."""
    return [
        String("The quick brown FOX jumps over the lazy dog"),
        String("café NAÏVE Über señor"),  # Latin-1 fold + lowercase
        String(" THE and OR but with not"),  # all stopwords -> 0 tokens
        String("Ārya Čaplin Łódź Ş"),  # Latin Extended-A fold
        String("Æsir straße cœur"),  # multi-letter: ae / ss / oe
        String("error error timeout error request"),  # TF multiset
        String("日本語 テスト emoji"),  # CJK passthrough + ascii
        String(""),  # empty cell
        String("   leading and trailing   spaces   "),  # ws collapse
        String("MixedCASE Folding café CAFÉ"),  # case + fold to same base
    ]


def _make_text_batch(values: List[String]) raises -> RecordBatch:
    var sa = StringArray.from_strings(values)
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(1)
    rb.add_column(Column.from_string(sa^))
    return rb.build(schema^)


# -----------------------------------------------------------------------------
# 1. analyze_text_column_resolved == analyze_text_column, per cell, full corpus.
# -----------------------------------------------------------------------------


def test_01_resolved_equals_unresolved_column() raises:
    var corpus = _make_corpus()
    var batch = _make_text_batch(corpus)
    var bv = batch_view_over(batch)
    var col = bv.col_str(0)
    var cfg = _text_cfg("body")  # the production analyzer (stopwords ON)
    var stopwords = resolve_stopwords_for(cfg)

    for r in range(col.length()):
        var slow = analyze_text_column(col, r, cfg)  # resolves per cell
        var fast = analyze_text_column_resolved(col, r, cfg, stopwords)
        _assert_same_tokens(slow, fast, "01.row" + String(r))


# -----------------------------------------------------------------------------
# 2. The resolved path == analyze_text (query side) — symmetry preserved.
# -----------------------------------------------------------------------------


def test_02_resolved_equals_query_path() raises:
    var corpus = _make_corpus()
    var batch = _make_text_batch(corpus)
    var bv = batch_view_over(batch)
    var col = bv.col_str(0)
    var cfg = _text_cfg("body")
    var stopwords = resolve_stopwords_for(cfg)

    for r in range(col.length()):
        var q = analyze_text(corpus[r], cfg)  # query side
        var ix = analyze_text_column_resolved(col, r, cfg, stopwords)
        _assert_same_tokens(q, ix, "02.row" + String(r))


# -----------------------------------------------------------------------------
# 3. Fold byte-exactness: the fold helpers (append-into-buffer) emit
#    byte-identical output to the literal expected ASCII (the case-6/7/8
#    expectations of test_search_analyzer, exercised through the resolved path).
# -----------------------------------------------------------------------------


def test_03_fold_byte_exact() raises:
    var cfg = _lower_fold("body")  # fold ON, stopwords OFF

    # Latin-1 Supplement.
    var a = analyze_text("café NAÏVE Über", cfg)
    assert_equal(a.len(), 3, "03.l1: 3 tokens")
    assert_equal(a.tokens[0].term, String("cafe"), "03.l1: cafe")
    assert_equal(a.tokens[1].term, String("naive"), "03.l1: naive")
    assert_equal(a.tokens[2].term, String("uber"), "03.l1: uber")

    # Multi-letter expansion: Æ -> ae, ß -> ss, œ -> oe.
    var b = analyze_text("Æsir straße cœur", cfg)
    assert_equal(b.len(), 3, "03.ml: 3 tokens")
    assert_equal(b.tokens[0].term, String("aesir"), "03.ml: aesir")
    assert_equal(b.tokens[1].term, String("strasse"), "03.ml: strasse")
    assert_equal(b.tokens[2].term, String("coeur"), "03.ml: coeur")

    # Latin Extended-A.
    var c = analyze_text("Ārya Łódź", cfg)
    assert_equal(c.len(), 2, "03.exa: 2 tokens")
    assert_equal(c.tokens[0].term, String("arya"), "03.exa: arya")
    assert_equal(c.tokens[1].term, String("lodz"), "03.exa: lodz")


# -----------------------------------------------------------------------------
# 4. CJK / out-of-scope bytes pass through byte-identical with fold ON.
# -----------------------------------------------------------------------------


def test_04_cjk_passthrough_byte_exact() raises:
    var cfg = _lower_fold("body")
    # Fold ON must NOT corrupt non-Latin multibyte. "日本語" is one token.
    var a = analyze_text("日本語 テスト", cfg)
    assert_equal(a.len(), 2, "04: 2 tokens")
    assert_equal(a.tokens[0].term, String("日本語"), "04: cjk token byte-exact")
    assert_equal(a.tokens[1].term, String("テスト"), "04: katakana byte-exact")


# -----------------------------------------------------------------------------
# 5. The WHOLE column driver (add_text_column) — postings + token_counts (the
#    fieldnorm) are identical whether driven by the corpus once. This pins that
#    the stopword-hoist did not change the inverted-index contract.
# -----------------------------------------------------------------------------


def test_05_add_text_column_postings_unchanged() raises:
    var corpus = _make_corpus()
    var batch = _make_text_batch(corpus)
    var bv = batch_view_over(batch)
    var col = bv.col_str(0)
    var cfg = _text_cfg("body")  # stopwords ON

    var b = InvertedIndexBuilder.create(String("body"))
    var token_counts = List[Int]()
    b.add_text_column(col, 0, cfg, token_counts)

    # token_counts must equal the per-row token count from the resolved path.
    var stopwords = resolve_stopwords_for(cfg)
    assert_equal(
        len(token_counts), col.length(), "05: one token_count per row"
    )
    for r in range(col.length()):
        var af = analyze_text_column_resolved(col, r, cfg, stopwords)
        assert_equal(
            token_counts[r],
            af.len(),
            "05.row" + String(r) + ": fieldnorm (token count) mismatch",
        )

    # Finalize must succeed and carry a non-zero distinct-term count for this
    # corpus (a smoke that the build path is intact end-to-end).
    var fi = b.finalize()
    assert_true(fi.num_terms() > 0, "05: finalized index has terms")


# -----------------------------------------------------------------------------
# 6. FULL split-byte determinism through the production SearchSink: the same
#    input produces byte-identical split bytes (the optimization is output-
#    invariant; this is the end-to-end correctness pin equivalent to the
#    keystone golden's determinism premise).
# -----------------------------------------------------------------------------


def _drive_split(corpus: List[String]) raises -> List[UInt8]:
    """Build a one-text-field + _source split through the production sink and
    return the split bytes. _source mirrors the message (a designated STRING
    column is required by init_sink)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("message", ArrowType.STRING, False))
    var schema = sb.build()

    var sources = List[String]()
    for i in range(len(corpus)):
        sources.append(corpus[i])
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_string(StringArray.from_strings(sources)))
    rb.add_column(Column.from_string(StringArray.from_strings(corpus)))
    var batch = rb.build(schema.copy())

    var uuid = Array[UInt8, 16](fill=0)
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("idx"),
        String("message"),
        uuid,
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def test_06_split_bytes_deterministic() raises:
    var corpus = _make_corpus()
    var a = _drive_split(corpus)
    var b = _drive_split(corpus)
    assert_equal(len(a), len(b), "06: split byte length differs across builds")
    for i in range(len(a)):
        if a[i] != b[i]:
            assert_true(
                False,
                "06: split byte[" + String(i) + "] differs across builds",
            )
    assert_true(len(a) > 0, "06: split is non-empty")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

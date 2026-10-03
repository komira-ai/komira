# =============================================================================
# test_search_analyzer.mojo — the tokenizer/analyzer unit test
# =============================================================================
#
# A 20-case test plan (case 17 = assert-raise on a non-TEXT field).
#
# Coverage (20 enumerated cases):
#   1.  whitespace split — basic
#   2.  whitespace — collapse runs + leading/trailing
#   3.  whitespace — empty + all-whitespace
#   4.  lowercase
#   5.  lowercase boundary (off-by-one around A-Z / a-z)
#   6.  ASCII-fold — Latin-1 Supplement
#   7.  ASCII-fold — multi-letter expansion (Æ/ß/œ)
#   8.  ASCII-fold — Latin Extended-A
#   9.  ASCII-fold — out-of-scope passthrough (CJK / Cyrillic / emoji)
#   10. ASCII-fold disabled
#   11. stopwords — English default
#   12. stopwords — case/fold-normalized match
#   13. stopwords — disabled / "none"
#   14. stopwords — unknown tag raises
#   15. TF multiset, NOT dedup
#   16. position slot populated, monotonic
#   17. per-field config — keyword passthrough RAISES
#   18. column-at-a-time path (StringColumnView)
#   19. index/query symmetry (byte-identical token lists)
#   20. UTF-8 multibyte does not split a token
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.collections.batch_view import batch_view_over

from komira_search.analyzer import (
    AnalyzerConfig,
    Token,
    AnalyzedField,
    analyze_text,
    analyze_text_column,
    FIELD_CLASS_TEXT,
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_DATE,
)


# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------


def _no_transform(name: String) -> AnalyzerConfig:
    """A TEXT config with ALL transforms OFF (pure whitespace split)."""
    return AnalyzerConfig(
        name, FIELD_CLASS_TEXT, False, False, False, String("none")
    )


def _lowercase_only(name: String) -> AnalyzerConfig:
    """TEXT config: lowercase ON, fold OFF, stopwords OFF."""
    return AnalyzerConfig(
        name, FIELD_CLASS_TEXT, True, False, False, String("none")
    )


def _lower_fold(name: String) -> AnalyzerConfig:
    """TEXT config: lowercase ON, fold ON, stopwords OFF."""
    return AnalyzerConfig(
        name, FIELD_CLASS_TEXT, True, True, False, String("none")
    )


def _terms(af: AnalyzedField) -> List[String]:
    """Extract just the term strings (in emission order)."""
    var out = List[String]()
    for i in range(af.len()):
        out.append(af.tokens[i].term)
    return out^


def _assert_terms(
    got: AnalyzedField, expected: List[String], ctx: String
) raises:
    var terms = _terms(got)
    assert_equal(
        len(terms),
        len(expected),
        ctx + ": token count " + String(len(terms)) + " != " + String(len(expected)),
    )
    for i in range(len(expected)):
        assert_equal(terms[i], expected[i], ctx + ": token[" + String(i) + "]")


# -----------------------------------------------------------------------------
# 1. Whitespace split — basic
# -----------------------------------------------------------------------------


def test_01_whitespace_basic() raises:
    var cfg = _no_transform("body")
    var af = analyze_text("the quick brown fox", cfg)
    _assert_terms(
        af, [String("the"), String("quick"), String("brown"), String("fox")], "1"
    )


# -----------------------------------------------------------------------------
# 2. Whitespace — collapse runs + leading/trailing
# -----------------------------------------------------------------------------


def test_02_whitespace_collapse() raises:
    var cfg = _no_transform("body")
    var af = analyze_text("  foo\t\tbar \n baz  ", cfg)
    _assert_terms(af, [String("foo"), String("bar"), String("baz")], "2")


# -----------------------------------------------------------------------------
# 3. Whitespace — empty + all-whitespace
# -----------------------------------------------------------------------------


def test_03_whitespace_empty() raises:
    var cfg = _no_transform("body")
    var af_empty = analyze_text("", cfg)
    assert_equal(af_empty.len(), 0, "3a: empty -> 0 tokens")
    var af_ws = analyze_text("   \t\n", cfg)
    assert_equal(af_ws.len(), 0, "3b: all-whitespace -> 0 tokens")


# -----------------------------------------------------------------------------
# 4. Lowercase
# -----------------------------------------------------------------------------


def test_04_lowercase() raises:
    var cfg = _lowercase_only("body")
    var af = analyze_text("The QUICK Fox", cfg)
    _assert_terms(af, [String("the"), String("quick"), String("fox")], "4")


# -----------------------------------------------------------------------------
# 5. Lowercase boundary (chars around A-Z / a-z)
# -----------------------------------------------------------------------------


def test_05_lowercase_boundary() raises:
    # "@A[`z{" — @=0x40 (before A), A=0x41, [=0x5B (after Z), `=0x60 (before a),
    # z=0x7A, {=0x7B (after z). Only A folds to 'a'; the others pass through.
    var cfg = _lowercase_only("body")
    var af = analyze_text("@A[`z{", cfg)
    # One token (no whitespace). Expect "@a[`z{".
    _assert_terms(af, [String("@a[`z{")], "5")


# -----------------------------------------------------------------------------
# 6. ASCII-fold — Latin-1 Supplement
# -----------------------------------------------------------------------------


def test_06_fold_latin1() raises:
    var cfg = _lower_fold("body")
    var af = analyze_text("café NAÏVE Über", cfg)
    _assert_terms(af, [String("cafe"), String("naive"), String("uber")], "6")


# -----------------------------------------------------------------------------
# 7. ASCII-fold — multi-letter expansion (Æ -> ae, ß -> ss, œ -> oe)
# -----------------------------------------------------------------------------


def test_07_fold_multiletter() raises:
    var cfg = _lower_fold("body")
    var af = analyze_text("Æsop straße œuvre", cfg)
    _assert_terms(
        af, [String("aesop"), String("strasse"), String("oeuvre")], "7"
    )


# -----------------------------------------------------------------------------
# 8. ASCII-fold — Latin Extended-A
# -----------------------------------------------------------------------------


def test_08_fold_latin_ext_a() raises:
    var cfg = _lower_fold("body")
    var af = analyze_text("Dvořák Łódź", cfg)
    _assert_terms(af, [String("dvorak"), String("lodz")], "8")


# -----------------------------------------------------------------------------
# 9. ASCII-fold — out-of-scope passthrough (CJK / Cyrillic / emoji)
# -----------------------------------------------------------------------------


def test_09_fold_out_of_scope() raises:
    # Each token is outside the fold ranges; with fold ON they must pass
    # through byte-identical (folding must not corrupt non-Latin bytes).
    var cfg = _lower_fold("body")
    var af = analyze_text("日本語 привет 🚀", cfg)
    _assert_terms(
        af, [String("日本語"), String("привет"), String("🚀")], "9"
    )


# -----------------------------------------------------------------------------
# 10. ASCII-fold disabled (raw bytes preserved)
# -----------------------------------------------------------------------------


def test_10_fold_disabled() raises:
    # lowercase ON, fold OFF: "café" stays "café" (the é bytes pass through).
    var cfg = _lowercase_only("body")
    var af = analyze_text("café", cfg)
    _assert_terms(af, [String("café")], "10")


# -----------------------------------------------------------------------------
# 11. Stopwords — English default
# -----------------------------------------------------------------------------


def test_11_stopwords_english() raises:
    var cfg = AnalyzerConfig.text("body")  # lowercase + fold + english stopwords
    var af = analyze_text("the quick brown fox jumps over the lazy dog", cfg)
    # "the" (x2) removed; "over" is NOT in the 33-word minimal set, so it stays.
    _assert_terms(
        af,
        [
            String("quick"),
            String("brown"),
            String("fox"),
            String("jumps"),
            String("over"),
            String("lazy"),
            String("dog"),
        ],
        "11",
    )


# -----------------------------------------------------------------------------
# 12. Stopwords — case/fold-normalized match (removal runs AFTER normalize)
# -----------------------------------------------------------------------------


def test_12_stopwords_normalized() raises:
    var cfg = AnalyzerConfig.text("body")
    # "The" -> "the" (stopword); "AND" -> "and" (stopword) -> 0 tokens.
    var af = analyze_text("The AND", cfg)
    assert_equal(af.len(), 0, "12: both normalize to stopwords -> 0 tokens")


# -----------------------------------------------------------------------------
# 13. Stopwords — disabled / "none"
# -----------------------------------------------------------------------------


def test_13_stopwords_disabled() raises:
    # remove_stopwords=False: all 9 tokens retained (lowercase still applies).
    var cfg = AnalyzerConfig(
        String("body"), FIELD_CLASS_TEXT, True, True, False, String("english")
    )
    var af = analyze_text("the quick brown fox jumps over the lazy dog", cfg)
    assert_equal(af.len(), 9, "13: stopwords disabled -> all 9 retained")


# -----------------------------------------------------------------------------
# 14. Stopwords — unknown tag raises (fail-loud)
# -----------------------------------------------------------------------------


def test_14_stopwords_unknown_tag_raises() raises:
    var cfg = AnalyzerConfig(
        String("body"), FIELD_CLASS_TEXT, True, True, True, String("klingon")
    )
    with assert_raises(contains="unknown stopword_set tag"):
        _ = analyze_text("the quick brown fox", cfg)


# -----------------------------------------------------------------------------
# 15. TF multiset, NOT dedup
# -----------------------------------------------------------------------------


def test_15_tf_multiset() raises:
    var cfg = _no_transform("body")
    var af = analyze_text("the cat the cat cat", cfg)
    # 5 tokens, order preserved (NOT deduped to 2).
    _assert_terms(
        af,
        [
            String("the"),
            String("cat"),
            String("the"),
            String("cat"),
            String("cat"),
        ],
        "15",
    )
    # Explicit TF assertion: cat x3, the x2.
    var cat_count = 0
    var the_count = 0
    for i in range(af.len()):
        if af.tokens[i].term == "cat":
            cat_count += 1
        elif af.tokens[i].term == "the":
            the_count += 1
    assert_equal(cat_count, 3, "15: TF(cat) == 3")
    assert_equal(the_count, 2, "15: TF(the) == 2")
    assert_true(af.len() != 2, "15: NOT deduped")


# -----------------------------------------------------------------------------
# 16. Position slot populated, monotonic
# -----------------------------------------------------------------------------


def test_16_position_monotonic() raises:
    var cfg = _no_transform("body")
    var af = analyze_text("alpha beta gamma", cfg)
    assert_equal(af.len(), 3, "16: 3 tokens")
    for i in range(af.len()):
        assert_equal(af.tokens[i].position, i, "16: position[" + String(i) + "]")


# -----------------------------------------------------------------------------
# 17. Per-field config — keyword passthrough RAISES
# -----------------------------------------------------------------------------


def test_17_keyword_raises() raises:
    var cfg = AnalyzerConfig.keyword("k")
    assert_false(cfg.is_tokenized(), "17: keyword is_tokenized() == False")
    # Amendment 3: analyzing a non-TEXT field is a programming error -> raise.
    with assert_raises(contains="not a TEXT field"):
        _ = analyze_text("some keyword value", cfg)


# -----------------------------------------------------------------------------
# 18. Column-at-a-time path (StringColumnView)
# -----------------------------------------------------------------------------


def _make_text_batch() raises -> RecordBatch:
    var values: List[String] = [
        String("Hello World"),
        String("café au lait"),
        String(""),
    ]
    var sa = StringArray.from_strings(values)
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(1)
    rb.add_column(Column.from_string(sa^))
    return rb.build(schema^)


def test_18_column_at_a_time() raises:
    var batch = _make_text_batch()
    var bv = batch_view_over(batch)
    var col = bv.col_str(0)
    var cfg = AnalyzerConfig.text("body")  # lowercase + fold + english stopwords

    # Row 0: "Hello World" -> ["hello", "world"].
    var af0 = analyze_text_column(col, 0, cfg)
    _assert_terms(af0, [String("hello"), String("world")], "18.row0")

    # Row 1: "café au lait" -> ["cafe", "au", "lait"] (au/lait not stopwords).
    var af1 = analyze_text_column(col, 1, cfg)
    _assert_terms(af1, [String("cafe"), String("au"), String("lait")], "18.row1")

    # Row 2: "" -> [].
    var af2 = analyze_text_column(col, 2, cfg)
    assert_equal(af2.len(), 0, "18.row2: empty cell -> 0 tokens")


# -----------------------------------------------------------------------------
# 19. Index/query symmetry — byte-identical token lists
# -----------------------------------------------------------------------------


def _make_symmetry_batch() raises -> RecordBatch:
    var values: List[String] = [String("The Café")]
    var sa = StringArray.from_strings(values)
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(1)
    rb.add_column(Column.from_string(sa^))
    return rb.build(schema^)


def test_19_index_query_symmetry() raises:
    # Use a config WITHOUT stopwords so "the" survives and we compare a real
    # multi-token list. lowercase + fold ON.
    var cfg = _lower_fold("body")

    # Query path: analyze_text over the string.
    var q = analyze_text("The Café", cfg)

    # Index path: analyze_text_column over the SAME bytes in a column.
    var batch = _make_symmetry_batch()
    var bv = batch_view_over(batch)
    var col = bv.col_str(0)
    var ix = analyze_text_column(col, 0, cfg)

    # Byte-identical token lists.
    var q_terms = _terms(q)
    var ix_terms = _terms(ix)
    assert_equal(len(q_terms), len(ix_terms), "19: token count differs")
    for i in range(len(q_terms)):
        assert_equal(q_terms[i], ix_terms[i], "19: token[" + String(i) + "]")
    # And the actual expected value.
    _assert_terms(q, [String("the"), String("cafe")], "19.query")
    _assert_terms(ix, [String("the"), String("cafe")], "19.index")


# -----------------------------------------------------------------------------
# 20. UTF-8 multibyte does not split a token (fold OFF)
# -----------------------------------------------------------------------------


def test_20_utf8_no_split() raises:
    # "café" with fold OFF: the é is 2 UTF-8 bytes (0xC3 0xA9); the 0xA9
    # continuation byte is non-whitespace, so never a boundary -> ONE token.
    var cfg = _no_transform("body")
    var af = analyze_text("café", cfg)
    assert_equal(af.len(), 1, "20: ONE token")
    _assert_terms(af, [String("café")], "20")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_search_cov_analyzer.mojo: the analyzer's fold table, swept whole, and
# the stopword-resolution edges.
# =============================================================================
#
#   1. Latin-1 Supplement sweep: every codepoint U+00C0..U+00FF, alone between
#      two ASCII letters, folds to the base letter(s) an independent table in
#      this file gives (x and ÷ have none and pass through unchanged).
#   2. Latin Extended-A sweep: every codepoint U+0100..U+017F, the same way.
#   3. A 0xC5 lead followed by a byte that is no continuation of U+0100..U+017F
#      (0xC0) passes through unchanged, both bytes.
#   4. Stopword tags: "" and "none" with removal ON remove nothing; the column
#      driver's resolve_stopwords_for returns nothing when removal is OFF and
#      the 33-word set for "english"; it raises on a non-TEXT config.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_search.analyzer import (
    AnalyzerConfig,
    AnalyzedField,
    analyze_text,
    resolve_stopwords_for,
    FIELD_CLASS_TEXT,
    FIELD_CLASS_KEYWORD,
)


def _lower_fold() -> AnalyzerConfig:
    return AnalyzerConfig(
        String("body"), FIELD_CLASS_TEXT, True, True, False, String("none")
    )


def _latin1_base(cp: Int) -> String:
    """The fold of U+00C0..U+00FF, from the Unicode names: the upper (C0..DF)
    and lower (E0..FF) rows hold the same letters; × (D7) and ÷ (F7) have
    none; ß (DF) is "ss", ÿ (FF) is "y"."""
    if cp == 0xD7 or cp == 0xF7:
        return String("")
    if cp == 0xDF:
        return String("ss")
    if cp == 0xFF:
        return String("y")
    var row: List[String] = [
        "a", "a", "a", "a", "a", "a", "ae", "c",
        "e", "e", "e", "e", "i", "i", "i", "i",
        "d", "n", "o", "o", "o", "o", "o", "",
        "o", "u", "u", "u", "u", "y", "th", "",
    ]
    return row[(cp - 0xC0) & 0x1F]


def _ext_a_base(cp: Int) -> String:
    """The fold of U+0100..U+017F (Latin Extended-A), by the base letter of
    each codepoint's Unicode name."""
    var bases: List[String] = [
        # 0x100..0x10F: A a A a A a C c C c C c C c D d
        "a", "a", "a", "a", "a", "a", "c", "c",
        "c", "c", "c", "c", "c", "c", "d", "d",
        # 0x110..0x11F: D d E e E e E e E e E e G g G g
        "d", "d", "e", "e", "e", "e", "e", "e",
        "e", "e", "e", "e", "g", "g", "g", "g",
        # 0x120..0x12F: G g G g H h H h I i I i I i I i
        "g", "g", "g", "g", "h", "h", "h", "h",
        "i", "i", "i", "i", "i", "i", "i", "i",
        # 0x130..0x13F: I-dot dotless-i IJ ij J j K k kra L l L l L l L
        "i", "i", "ij", "ij", "j", "j", "k", "k",
        "k", "l", "l", "l", "l", "l", "l", "l",
        # 0x140..0x14F: l L l N n N n N n 'n Eng eng O o O o
        "l", "l", "l", "n", "n", "n", "n", "n",
        "n", "n", "n", "n", "o", "o", "o", "o",
        # 0x150..0x15F: O o OE oe R r R r R r S s S s S s
        "o", "o", "oe", "oe", "r", "r", "r", "r",
        "r", "r", "s", "s", "s", "s", "s", "s",
        # 0x160..0x16F: S s T t T t T t U u U u U u U u
        "s", "s", "t", "t", "t", "t", "t", "t",
        "u", "u", "u", "u", "u", "u", "u", "u",
        # 0x170..0x17F: U u U u W w Y y Y Z z Z z Z z long-s
        "u", "u", "u", "u", "w", "w", "y", "y",
        "y", "z", "z", "z", "z", "z", "z", "s",
    ]
    return bases[cp - 0x100]


def _one_term(af: AnalyzedField, ctx: String) raises -> String:
    assert_equal(af.len(), 1, ctx + ": one token")
    return af.tokens[0].term


def test_01_latin1_sweep() raises:
    var cfg = _lower_fold()
    for cp in range(0xC0, 0x100):
        var ch = chr(cp)
        var base = _latin1_base(cp)
        var want = String("x") + (base if base.byte_length() > 0 else ch) + "x"
        var got = _one_term(analyze_text(String("X") + ch + "X", cfg), "1")
        assert_equal(got, want, "1: U+" + hex(cp))


def test_02_latin_ext_a_sweep() raises:
    var cfg = _lower_fold()
    for cp in range(0x100, 0x180):
        var want = String("x") + _ext_a_base(cp) + "x"
        var got = _one_term(analyze_text(String("X") + chr(cp) + "X", cfg), "2")
        assert_equal(got, want, "2: U+" + hex(cp))


def test_03_ext_a_lead_without_mapping_passes_through() raises:
    # 0xC5 0xC0 would be U+0180, past Latin Extended-A: no mapping, so both
    # bytes are kept as they are (the scalar path still consumes two bytes).
    var raw: List[UInt8] = [0x78, 0xC5, 0xC0, 0x78]
    var text = String(StringSlice(unsafe_from_utf8=Span(raw)))
    var got = _one_term(analyze_text(text, _lower_fold()), "3")
    var gb = got.as_bytes()
    assert_equal(len(gb), 4, "3: four bytes")
    for i in range(4):
        assert_equal(gb[i], raw[i], "3: byte " + String(i))


def test_04_stopword_tags() raises:
    # Removal ON with the "" and "none" tags: no word is removed.
    for tag in [String(""), String("none")]:
        var cfg = AnalyzerConfig(
            String("body"), FIELD_CLASS_TEXT, True, True, True, tag.copy()
        )
        var af = analyze_text("the cat and a dog", cfg)
        assert_equal(af.len(), 5, "4: nothing removed for tag '" + tag + "'")
        assert_equal(len(resolve_stopwords_for(cfg)), 0, "4: empty set")
    # Removal OFF: the column driver resolves no set even for "english".
    var off = AnalyzerConfig(
        String("body"), FIELD_CLASS_TEXT, True, True, False, String("english")
    )
    assert_equal(len(resolve_stopwords_for(off)), 0, "4: removal off")
    var on = AnalyzerConfig.text("body")
    assert_equal(len(resolve_stopwords_for(on)), 33, "4: english has 33")
    # A KEYWORD config is no TEXT field: the column driver refuses it.
    with assert_raises(contains="is not a TEXT field"):
        _ = resolve_stopwords_for(AnalyzerConfig.keyword("tag"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

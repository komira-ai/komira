# =============================================================================
# test_search_analyzer_simd_classify.mojo
#   Correctness-regression guard for the analyzer byte-walk SIMD
#   classification: the per-byte whitespace test +
#   ASCII-gate + ASCII-lowercase are SIMD-staged once over the whole cell
#   (analyzer.mojo `_simd_classify_into`), with the token-carve loop reading
#   the precomputed masks and bulk-copying pure-ASCII spans. Bytes >= 0x80 take
#   the scalar lowercase + Latin-fold path.
# =============================================================================
#
# WHY THIS TEST EXISTS:
#   The SIMD classification must produce token streams (term + position) that are
#   BYTE-IDENTICAL to the all-scalar path the analyzer ran before. This test is
#   the HARD GATE: it carries a SELF-CONTAINED scalar reference tokenizer (a
#   verbatim re-implementation of the pre-SIMD `_analyze_bytes_resolved` inner
#   loop — whitespace split + per-byte ASCII lowercase + the Latin-fold dispatch)
#   and asserts the PRODUCTION `analyze_text` (now SIMD) agrees with it
#   byte-for-byte over a corpus that exercises every boundary case:
#     * ASCII words, runs of whitespace + punctuation
#     * token at buffer start / end
#     * sub-SIMD-width tokens (1-2 byte tokens)
#     * a word STRADDLING a 16-byte lane boundary (forces the SIMD chunk + the
#       pure-ASCII bulk-copy to span a chunk edge)
#     * the Latin-fold-scalar path: accented bytes >= 0x80 (Latin-1 Supplement
#       AND Latin Extended-A) still fold correctly via the scalar fallback span
#     * a SPAN MIX: a pure-ASCII span before AND after a folded span in one cell
#     * CJK / out-of-scope passthrough (>= 0x80 non-Latin, byte-identical)
#
#   The scalar reference here is independent of the production code (it does NOT
#   call into analyzer.mojo's hot loop), so a regression that made the SIMD path
#   diverge would be caught even if the production scalar fallback were also
#   broken. Both lowercase-ON+fold-ON and lowercase-OFF configs are checked (the
#   pure-ASCII fast path copies the lowered slice when do_lower, the original
#   bytes when not — both must match the scalar reference).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_search.analyzer import (
    AnalyzerConfig,
    AnalyzedField,
    Token,
    analyze_text,
    FIELD_CLASS_TEXT,
)


# -----------------------------------------------------------------------------
# SELF-CONTAINED scalar reference — a verbatim re-implementation of the pre-SIMD
# analyzer inner loop. Whitespace bytes + ASCII lowercase + Latin-fold dispatch
# are duplicated here so the comparison is SIMD-vs-INDEPENDENT-scalar, not
# SIMD-vs-the-same-code.
# -----------------------------------------------------------------------------


def _ref_is_ws(c: UInt8) -> Bool:
    return (
        c == UInt8(32)
        or c == UInt8(9)
        or c == UInt8(10)
        or c == UInt8(13)
        or c == UInt8(11)
        or c == UInt8(12)
    )


def _ref_lower(c: UInt8) -> UInt8:
    if c >= UInt8(65) and c <= UInt8(90):
        return c + UInt8(32)
    return c


def _ref_fold_latin1(mut out: List[UInt8], b2: UInt8) -> Bool:
    var lo = b2 & UInt8(0x1F)
    var v = Int(lo)
    if v <= 5:
        out.append(UInt8(97))
        return True
    if v == 6:
        out.append(UInt8(97))
        out.append(UInt8(101))
        return True
    if v == 7:
        out.append(UInt8(99))
        return True
    if v >= 8 and v <= 11:
        out.append(UInt8(101))
        return True
    if v >= 12 and v <= 15:
        out.append(UInt8(105))
        return True
    if v == 16:
        out.append(UInt8(100))
        return True
    if v == 17:
        out.append(UInt8(110))
        return True
    if v >= 18 and v <= 22:
        out.append(UInt8(111))
        return True
    if v == 24:
        out.append(UInt8(111))
        return True
    if v >= 25 and v <= 28:
        out.append(UInt8(117))
        return True
    if v == 29:
        out.append(UInt8(121))
        return True
    if v == 30:
        out.append(UInt8(116))
        out.append(UInt8(104))
        return True
    if v == 31:
        if b2 == UInt8(0xBF):
            out.append(UInt8(121))
            return True
        out.append(UInt8(115))
        out.append(UInt8(115))
        return True
    return False


def _ref_fold_ext_a(mut out: List[UInt8], lead: UInt8, b2: UInt8) -> Bool:
    var cp = 0x100 + (Int(lead) - 0xC4) * 0x40 + (Int(b2) - 0x80)
    if cp < 0x100 or cp > 0x17F:
        return False
    if cp >= 0x100 and cp <= 0x105:
        out.append(UInt8(97))
        return True
    if cp >= 0x106 and cp <= 0x10D:
        out.append(UInt8(99))
        return True
    if cp >= 0x10E and cp <= 0x111:
        out.append(UInt8(100))
        return True
    if cp >= 0x112 and cp <= 0x11B:
        out.append(UInt8(101))
        return True
    if cp >= 0x11C and cp <= 0x123:
        out.append(UInt8(103))
        return True
    if cp >= 0x124 and cp <= 0x127:
        out.append(UInt8(104))
        return True
    if cp >= 0x128 and cp <= 0x131:
        out.append(UInt8(105))
        return True
    if cp >= 0x132 and cp <= 0x133:
        out.append(UInt8(105))
        out.append(UInt8(106))
        return True
    if cp >= 0x134 and cp <= 0x135:
        out.append(UInt8(106))
        return True
    if cp >= 0x136 and cp <= 0x138:
        out.append(UInt8(107))
        return True
    if cp >= 0x139 and cp <= 0x142:
        out.append(UInt8(108))
        return True
    if cp >= 0x143 and cp <= 0x14B:
        out.append(UInt8(110))
        return True
    if cp >= 0x14C and cp <= 0x151:
        out.append(UInt8(111))
        return True
    if cp >= 0x152 and cp <= 0x153:
        out.append(UInt8(111))
        out.append(UInt8(101))
        return True
    if cp >= 0x154 and cp <= 0x159:
        out.append(UInt8(114))
        return True
    if cp >= 0x15A and cp <= 0x161:
        out.append(UInt8(115))
        return True
    if cp >= 0x162 and cp <= 0x167:
        out.append(UInt8(116))
        return True
    if cp >= 0x168 and cp <= 0x173:
        out.append(UInt8(117))
        return True
    if cp >= 0x174 and cp <= 0x175:
        out.append(UInt8(119))
        return True
    if cp >= 0x176 and cp <= 0x178:
        out.append(UInt8(121))
        return True
    if cp >= 0x179 and cp <= 0x17E:
        out.append(UInt8(122))
        return True
    if cp == 0x17F:
        out.append(UInt8(115))
        return True
    return False


def _ref_analyze(text: String, do_lower: Bool, do_fold: Bool) -> AnalyzedField:
    """The pre-SIMD all-scalar tokenizer (stopwords OFF). Whitespace split,
    per-byte ASCII lowercase, Latin-fold dispatch — verbatim mirror of the
    analyzer's pre-SIMD inner loop. Used as the independent oracle."""
    var bytes = text.as_bytes()
    var result = AnalyzedField(List[Token]())
    var n = len(bytes)
    var i = 0
    var position = 0
    var term_bytes = List[UInt8]()
    while i < n:
        while i < n and _ref_is_ws(bytes[i]):
            i += 1
        if i >= n:
            break
        term_bytes.clear()
        while i < n and not _ref_is_ws(bytes[i]):
            var b = bytes[i]
            if b < UInt8(0x80):
                if do_lower:
                    term_bytes.append(_ref_lower(b))
                else:
                    term_bytes.append(b)
                i += 1
            elif do_fold and (
                b == UInt8(0xC3) or b == UInt8(0xC4) or b == UInt8(0xC5)
            ):
                if i + 1 >= n:
                    term_bytes.append(b)
                    i += 1
                else:
                    var b2 = bytes[i + 1]
                    var mapped: Bool
                    if b == UInt8(0xC3):
                        mapped = _ref_fold_latin1(term_bytes, b2)
                    else:
                        mapped = _ref_fold_ext_a(term_bytes, b, b2)
                    if not mapped:
                        term_bytes.append(b)
                        term_bytes.append(b2)
                    i += 2
            else:
                term_bytes.append(b)
                i += 1
        if len(term_bytes) == 0:
            continue
        # SAFETY: the oracle mirrors production: UTF-8 cell, whole-sequence fold output.
        var term = String(StringSlice(unsafe_from_utf8=Span(term_bytes)))
        result.tokens.append(Token(term^, position))
        position += 1
    return result^


def _cfg(do_lower: Bool, do_fold: Bool) -> AnalyzerConfig:
    # stopwords OFF so EVERY token survives (the classification, not removal, is
    # under test). lowercase / fold toggled per case.
    return AnalyzerConfig(
        String("body"), FIELD_CLASS_TEXT, do_lower, do_fold, False, String("none")
    )


def _assert_same(
    got: AnalyzedField, want: AnalyzedField, ctx: String
) raises:
    assert_equal(got.len(), want.len(), ctx + ": token count differs")
    for i in range(got.len()):
        assert_equal(
            got.tokens[i].term, want.tokens[i].term,
            ctx + ": term[" + String(i) + "] differs",
        )
        assert_equal(
            got.tokens[i].position, want.tokens[i].position,
            ctx + ": position[" + String(i) + "] differs",
        )


def _check(text: String, ctx: String) raises:
    """Assert the production (SIMD) analyze_text == the independent scalar oracle
    for BOTH lowercase-ON+fold-ON and lowercase-OFF configs."""
    var lf = _cfg(True, True)
    _assert_same(analyze_text(text, lf), _ref_analyze(text, True, True), ctx + ".lower+fold")
    var nolower = _cfg(False, True)
    _assert_same(
        analyze_text(text, nolower), _ref_analyze(text, False, True),
        ctx + ".nolower",
    )


# -----------------------------------------------------------------------------
# 1. Boundary corpus: every case the SIMD lane/span carve must get right.
# -----------------------------------------------------------------------------


def test_01_boundary_corpus_byte_identical() raises:
    _check("The quick brown FOX jumps over the lazy dog", "01.ascii_words")
    _check("a b c d e f g", "01.subwidth_tokens")  # 1-byte tokens
    _check("ab cd ef", "01.two_byte_tokens")
    _check("  leading and trailing   spaces   ", "01.ws_runs")
    _check("hello,world;foo.bar:baz!qux", "01.punctuation_no_split")
    _check("startTOKEN middle endTOKEN", "01.start_end_tokens")
    _check("", "01.empty")
    _check("   ", "01.all_ws")
    _check("single", "01.single_token")
    _check("\t\n\r\x0b\x0c mixed\tws\nhere", "01.exotic_ws")


# -----------------------------------------------------------------------------
# 2. Lane-boundary straddle: a token that crosses the 16-byte SIMD chunk edge,
#    and a token that starts inside one chunk and ends in the next. W(u8)=16 on
#    NEON, 32/64 on AVX — the straddle is constructed to cross W=16; on wider W
#    it simply lands inside one chunk (still exercised by the scalar tail too).
# -----------------------------------------------------------------------------


def test_02_lane_boundary_straddle() raises:
    # A 20-char word starting at byte 0 crosses the W=16 chunk edge (bytes 16-19
    # are in the second chunk / tail). Mixed case forces lowercase across the edge.
    _check("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "02.long_word_crosses_edge")
    # Token boundary EXACTLY at byte 16 (space at index 16).
    _check("0123456789ABCDEF GHIJKLMNOP", "02.space_at_16")
    # Whitespace run straddling the chunk edge.
    _check("aaaaaaaaaaaaaaa     bbbbbbbbbbbbbbb", "02.ws_run_across_edge")
    # Many short tokens so token starts land at varied lane offsets.
    _check("aa bb cc dd ee ff gg hh ii jj kk ll mm nn", "02.varied_lane_offsets")


# -----------------------------------------------------------------------------
# 3. Latin-fold-scalar path: accented bytes >= 0x80 fold correctly via the
#    scalar fallback span (the SIMD path NEVER folds; it routes the span to the
#    scalar fold loop). Latin-1 Supplement + Latin Extended-A + multi-letter.
# -----------------------------------------------------------------------------


def test_03_latin_fold_scalar_fallback() raises:
    _check("café NAÏVE Über señor", "03.latin1")
    _check("Ārya Čaplin Łódź Ş", "03.ext_a")
    _check("Æsir straße cœur", "03.multiletter")  # ae / ss / oe
    _check("MixedCASE Folding café CAFÉ", "03.case_and_fold")
    # Truncated multibyte at the very end of the cell (0xC3 lead, no continuation).
    var trunc = List[UInt8]()
    trunc.append(UInt8(97))  # 'a'
    trunc.append(UInt8(0xC3))  # dangling lead at buffer end
    # SAFETY: deliberately truncated UTF-8: the test is about this byte shape.
    var truncs = String(StringSlice(unsafe_from_utf8=Span(trunc)))
    # analyze with fold ON — both production + oracle must pass the lead through.
    var lf = _cfg(True, True)
    _assert_same(
        analyze_text(truncs, lf), _ref_analyze(truncs, True, True),
        "03.truncated_lead",
    )


# -----------------------------------------------------------------------------
# 4. Span mix: pure-ASCII span BEFORE and AFTER a folded span in ONE cell. This
#    pins that first_nonascii correctly gates only the spans that touch >= 0x80,
#    and that pure-ASCII spans after the first non-ASCII byte still match (they
#    route to the scalar fallback but emit identical bytes).
# -----------------------------------------------------------------------------


def test_04_span_mix() raises:
    _check("plain café plain2 Über last", "04.ascii_fold_ascii")
    _check("ascii1 ascii2 café Ārya ascii3", "04.two_ascii_then_two_fold")
    # Non-Latin >= 0x80 (CJK) passes through; surrounded by ascii spans.
    _check("before 日本語 after テスト end", "04.cjk_passthrough_mixed")
    # A long ascii run AFTER a fold byte (would-be fast-path span gated to scalar).
    _check("é aaaaaaaaaaaaaaaaaaaaaaaaaaaa", "04.long_ascii_after_fold")


# -----------------------------------------------------------------------------
# 5. CJK / out-of-scope passthrough byte-exact (fold ON must not corrupt
#    non-Latin multibyte; the bytes pass through the scalar fallback span).
# -----------------------------------------------------------------------------


def test_05_cjk_passthrough() raises:
    _check("日本語 テスト emoji", "05.cjk_katakana_ascii")
    _check("emoji😀here plain", "05.emoji_4byte")
    _check("Ελληνικά κείμενο", "05.greek")  # 0xCE/0xCF leads (not fold candidates)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

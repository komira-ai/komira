# =============================================================================
# komira_search/analyzer.mojo
#   The tokenizer / analyzer.
# =============================================================================
#
# It is a pure, stateless tokenizer/analyzer: a value-typed config in, a
# TF-countable multiset of tokens out. v1 pipeline (per-field configurable):
#   1. whitespace split  (ASCII whitespace bytes are the ONLY token boundary)
#   2. ASCII lowercase   (A..Z -> a..z; gated on config.lowercase)
#   3. ASCII-fold        (Latin-1 Supplement + Latin Extended-A diacritic strip
#                         -> unaccented ASCII; gated on config.ascii_fold)
#   4. stopword removal  (English minimal set; gated on config.remove_stopwords)
#
# -----------------------------------------------------------------------------
# THE SYMMETRY GUARANTEE
# -----------------------------------------------------------------------------
# BOTH public entry points (`analyze_text` for the query side, and
# `analyze_text_column` for the index side) funnel into ONE internal byte-span
# normalizer `_analyze_bytes(bytes: Span[UInt8, _], config)`. Index-time and
# query-time tokenization are therefore byte-identical BY CONSTRUCTION, not by
# convention — byte-identical index/query tokenization holds structurally.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY (this module is the safety owner)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY public (or private) signature. The surface is
#     value structs (AnalyzerConfig / Token / AnalyzedField) + String / List +
#     StringColumnView[origin] with a CONCRETE Origin[mut=False].
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * Token / AnalyzedField have heap-owning fields (String, List[Token]).
#     They therefore live ONLY in plain List[Token] on the stack / in the
#     per-document accumulator — NEVER as byte-slab elements in v1. (The slab is
#     the downstream IndexCore's concern; there is no slab here.)
#   * Hot loops are @always_inline and walk a resolved contiguous byte Span.
#     The normalized term is built from folded bytes via
#     String(StringSlice(unsafe_from_utf8=Span(buf))) — the same idiom
#     the core packages' StringColumnView uses.
#
# -----------------------------------------------------------------------------
# BYTE-SOURCE DECISION for analyze_text_column
# -----------------------------------------------------------------------------
# CHOICE: one-copy-per-cell (materialize the cell to String ONCE via
# StringView.to_string(), then .as_bytes() -> Span -> _analyze_bytes).
#
# RATIONALE: a zero-copy borrowed Span[UInt8, origin] over the cell's bytes
# would be preferable IF it could be safely threaded through the concrete
# origin. It CANNOT here without a safety/encapsulation violation:
#   - StringColumnView.get(row) returns a StringView whose only public byte
#     accessor is `byte_at(i)`, which re-derives `col = self._batch[].column_at`
#     AND bounds-checks PER BYTE — exactly the per-byte re-derivation that
#     must stay out of the hot loop.
#   - To get a contiguous Span[UInt8, origin] over the cell I would have to
#     reach into the column's private `_data: SharedAlignedBuffer`, whose
#     internal `_ptr` is an UnsafePointer[UInt8, MutExternalOrigin] (a WILDCARD
#     origin). Building a Span from it would surface a wildcard / sever the
#     origin chain, which the safety rules forbid.
# So the fallback applies: ONE String copy per cell (not per byte).
# This is O(cell_bytes) copy once, then the hot normalizer walks the owned
# String's contiguous bytes. It is NOT a byte_at() loop.
# =============================================================================

from std.sys import simd_width_of

from komira_arrow.string_column_view import StringColumnView


# =============================================================================
# Field-class constants. Only TEXT is tokenized.
# =============================================================================

comptime FIELD_CLASS_TEXT: UInt8 = 0  # analyzed -> inverted index -> `match`
comptime FIELD_CLASS_KEYWORD: UInt8 = 1  # exact -> term-dict lookup -> fast-field
comptime FIELD_CLASS_NUMERIC: UInt8 = 2  # range/sort/filter -> fast-field
comptime FIELD_CLASS_DATE: UInt8 = 3  # range/sort/filter -> fast-field

# The default English stopword set tag. Resolves to the
# 33-word Lucene-minimal ENGLISH_STOP_WORDS_SET below.
comptime DEFAULT_ENGLISH_STOPWORDS: String = "english"


# =============================================================================
# Private ASCII byte kernels — LOCAL copies.
# `_is_ascii_ws` / `_to_lower` are PRIVATE in
# komira_kernels' cast_to_varchar_kernels; importing private symbols across
# the module boundary violates the encapsulation rule. They are 3-line
# predicates — lift local copies here.
# =============================================================================


@always_inline
def _is_ascii_ws(c: UInt8) -> Bool:
    """ASCII whitespace: space, tab, LF, CR, VT, FF. (Mirror of
    komira_kernels' cast_to_varchar_kernels `_is_ascii_ws`.)"""
    return (
        c == UInt8(32)
        or c == UInt8(9)
        or c == UInt8(10)
        or c == UInt8(13)
        or c == UInt8(11)
        or c == UInt8(12)
    )


@always_inline
def _to_lower(c: UInt8) -> UInt8:
    """ASCII lowercase: A..Z -> a..z; every other byte unchanged. (Mirror of
    komira_kernels' cast_to_varchar_kernels `_to_lower`.)"""
    if c >= UInt8(65) and c <= UInt8(90):  # 'A'..'Z'
        return c + UInt8(32)
    return c


# =============================================================================
# AnalyzerConfig: per-field analyzer configuration (a VALUE).
# =============================================================================


@fieldwise_init
struct AnalyzerConfig(Copyable, Movable, Deinitable):
    """Per-field analyzer configuration. A VALUE — no heap-owning pointer
    fields (never a byte-slab element; held on the index
    mapping by value). Persisted with the index mapping (meta.json per-field
    summary / split footer) so IndexCore (build) and SearchCore (query)
    reconstruct the IDENTICAL analyzer — the query-time symmetry requirement.

    Fields:
      field_name:  the column name this config applies to.
      field_class: one of FIELD_CLASS_*. Only TEXT is tokenized; KEYWORD /
                   NUMERIC / DATE pass through to fast-fields untokenized.
      lowercase:   apply ASCII lowercase normalization (default True for TEXT).
      ascii_fold:  apply ASCII-folding (accent strip; default True for TEXT).
      remove_stopwords: apply stopword removal (default True for TEXT).
      stopword_set: which stopword set ("" or "none" = none; "english" =
                    the 33-word Lucene-minimal set). A String tag, NOT an
                    embedded list, so the config stays a small persistable
                    value and the set itself is resolved at analyze time.
                    Forward-compatible: new named sets add a tag, not a field.
    """

    var field_name: String
    var field_class: UInt8
    var lowercase: Bool
    var ascii_fold: Bool
    var remove_stopwords: Bool
    var stopword_set: String

    @staticmethod
    def text(field_name: String) -> AnalyzerConfig:
        """The v1 default TEXT analyzer: lowercase + ASCII-fold + English
        stopwords."""
        return AnalyzerConfig(
            field_name, FIELD_CLASS_TEXT, True, True, True, String("english")
        )

    @staticmethod
    def keyword(field_name: String) -> AnalyzerConfig:
        """A KEYWORD field: NOT tokenized (the whole cell is one term)."""
        return AnalyzerConfig(
            field_name, FIELD_CLASS_KEYWORD, False, False, False, String("")
        )

    @always_inline
    def is_tokenized(self) -> Bool:
        return self.field_class == FIELD_CLASS_TEXT


# =============================================================================
# Token: one emitted term (a position slot is reserved for phrase queries).
# =============================================================================


@fieldwise_init
struct Token(Copyable, Movable, Deinitable):
    """One emitted term from analyzing a text field.

    Fields:
      term:     the normalized term bytes as a String (lowercased,
                ASCII-folded). THE canonical term identity — the
                inverted-index build hashes fnv1a_64(term.as_bytes()) into the
                term -> postings hashmap, and the term dictionary stores it.
      position: token ordinal within the source field (0-based). RESERVED FOR
                phrase queries. v1 sets it but the inverted-index build
                IGNORES it (positions will live in a separate .pos stream).
                Keeping the slot means adding the .pos stream later does
                NOT change Token's shape or the analyze API.
    """

    var term: String
    var position: Int


# =============================================================================
# AnalyzedField: the per-document result (a TF-countable multiset).
# =============================================================================


@fieldwise_init
struct AnalyzedField(Copyable, Movable, Deinitable):
    """The result of analyzing ONE document's value for ONE text field.

    `tokens` is a MULTISET (a flat List in emission order), NOT a dedup set:
    the inverted-index build counts term frequency by tallying repeated terms
    (TF = count of equal Token.term within one AnalyzedField). Do NOT dedup
    here. Emission order is preserved so a later .pos stream reads positions
    monotonically.
    """

    var tokens: List[Token]

    @always_inline
    def len(self) -> Int:
        return len(self.tokens)


# =============================================================================
# Stopword set resolution (the 33-word Lucene-minimal English core).
# =============================================================================
#
# The classic Lucene ENGLISH_STOP_WORDS_SET (33 words), the OpenSearch/Lucene
# `_english_`-compatible core. Represented as a SORTED List[String] so
# membership is a binary search (O(log 33)) — no per-token rebuild, no
# over-engineered perfect-hash for 33 words. Built once per analyze call (33
# tiny strings — cheap) inside _analyze_bytes; the resolver returns the sorted
# list for the active tag.


def _resolve_stopwords(tag: String) raises -> List[String]:
    """Resolve a stopword-set tag to a SORTED List[String] for binary-search
    membership. "" / "none" -> empty list (no removal). "english" -> the
    33-word minimal set. Unknown tag -> raise (fail-loud: do NOT silently
    apply none)."""
    if tag == "" or tag == "none":
        return List[String]()
    if tag == "english":
        # SORTED (ascending) so _stopword_contains can binary-search.
        return [
            String("a"),
            String("an"),
            String("and"),
            String("are"),
            String("as"),
            String("at"),
            String("be"),
            String("but"),
            String("by"),
            String("for"),
            String("if"),
            String("in"),
            String("into"),
            String("is"),
            String("it"),
            String("no"),
            String("not"),
            String("of"),
            String("on"),
            String("or"),
            String("such"),
            String("that"),
            String("the"),
            String("their"),
            String("then"),
            String("there"),
            String("these"),
            String("they"),
            String("this"),
            String("to"),
            String("was"),
            String("will"),
            String("with"),
        ]
    raise Error(
        "AnalyzerConfig: unknown stopword_set tag '"
        + tag
        + "' (expected '', 'none', or 'english')"
    )


@always_inline
def _stopword_contains(sorted_set: List[String], term: String) -> Bool:
    """Binary-search membership against a SORTED List[String]."""
    var lo = 0
    var hi = len(sorted_set)
    while lo < hi:
        var mid = (lo + hi) >> 1
        ref m = sorted_set[mid]
        if m == term:
            return True
        elif m < term:
            lo = mid + 1
        else:
            hi = mid
    return False


# =============================================================================
# ASCII-fold (Latin-1 Supplement + Latin Extended-A diacritic strip).
# =============================================================================
#
# A byte-level fold over the two UTF-8 ranges that cover the vast majority of
# accented Latin text. The token span has ALREADY been ASCII-lowercased (if
# config.lowercase) by the caller, but fold runs on raw multibyte lead bytes
# (lowercase touches only A..Z, never the 0xC3/0xC4/0xC5 leads), so fold maps
# BOTH upper- and lower-case accented forms to lowercase ASCII directly.
#
# Bounds safety: on a 0xC3/0xC4/0xC5 lead byte, the 2nd
# (and for 0xC4/0xC5 the relevant) continuation byte is bounds-checked against
# the span end BEFORE it is read. A truncated/invalid multibyte sequence at the
# span boundary passes through UNCHANGED (the lead byte is appended as-is and
# the walk advances by one), never indexing past the span end.


@always_inline
def _append_byte(mut out: List[UInt8], b: UInt8):
    out.append(b)


@always_inline
def _append_two(mut out: List[UInt8], a: UInt8, b: UInt8):
    out.append(a)
    out.append(b)


# PERF-CRITICAL (search index-build per-bulk latency): the fold
# helpers append the folded ASCII byte(s) DIRECTLY into the caller's term buffer
# and return Bool ("mapped?") instead of returning a freshly-allocated
# List[UInt8] per non-ASCII byte. A return-by-value-List shape allocates +
# frees one List on EVERY accented byte (and the empty-list "no mapping" probe
# still allocates). For accented corpora this is per-byte heap churn in the
# hottest loop in the build (`_analyze_bytes`). Do NOT revert to a List-returning
# shape — the alloc-per-byte is exactly the per-token/per-byte churn a
# fat-document bulk index pays. The byte output is bit-identical to a
# List-returning shape (regression-guarded by test_search_analyzer cases 6-9 +
# test_search_analyzer_alloc_perf).


@always_inline
def _fold_latin1_into(mut out: List[UInt8], b2: UInt8) -> Bool:
    """Fold the SECOND byte of a 0xC3 <b2> two-byte UTF-8 sequence
    (U+00C0..U+00FF, Latin-1 Supplement) to unaccented lowercase ASCII,
    APPENDING the folded ASCII byte(s) into `out`. Returns True if a mapping was
    applied (bytes appended), False if there is no mapping (nothing appended —
    the caller passes the original 2 bytes through unchanged).

    Covers both upper- (U+00C0..U+00DF -> b2 0x80..0x9F) and lower-case
    (U+00E0..U+00FF -> b2 0xA0..0xBF) accented forms; both fold to the SAME
    lowercase ASCII base. Multi-letter expansions: Æ/æ -> ae, ß -> ss."""
    var lo = b2 & UInt8(0x1F)  # low 5 bits: same offset within upper/lower row
    var v = Int(lo)
    # a: À Á Â Ã Ä Å  (lo 0x00..0x05)
    if v <= 5:
        out.append(UInt8(97))  # 'a'
        return True
    # Æ / æ  (lo 0x06) -> "ae"
    if v == 6:
        out.append(UInt8(97))  # 'a'
        out.append(UInt8(101))  # 'e'
        return True
    # Ç / ç  (lo 0x07) -> 'c'
    if v == 7:
        out.append(UInt8(99))  # 'c'
        return True
    # È É Ê Ë  (lo 0x08..0x0B) -> 'e'
    if v >= 8 and v <= 11:
        out.append(UInt8(101))  # 'e'
        return True
    # Ì Í Î Ï  (lo 0x0C..0x0F) -> 'i'
    if v >= 12 and v <= 15:
        out.append(UInt8(105))  # 'i'
        return True
    # Ð / ð  (lo 0x10) -> 'd' (eth)
    if v == 16:
        out.append(UInt8(100))  # 'd'
        return True
    # Ñ / ñ  (lo 0x11) -> 'n'
    if v == 17:
        out.append(UInt8(110))  # 'n'
        return True
    # Ò Ó Ô Õ Ö  (lo 0x12..0x16) -> 'o'  (0x17 = × multiply sign / ÷ — skip)
    if v >= 18 and v <= 22:
        out.append(UInt8(111))  # 'o'
        return True
    # Ø / ø  (lo 0x18) -> 'o'
    if v == 24:
        out.append(UInt8(111))  # 'o'
        return True
    # Ù Ú Û Ü  (lo 0x19..0x1C) -> 'u'
    if v >= 25 and v <= 28:
        out.append(UInt8(117))  # 'u'
        return True
    # Ý / ý  (lo 0x1D) -> 'y'
    if v == 29:
        out.append(UInt8(121))  # 'y'
        return True
    # Þ / þ  (lo 0x1E) -> 'th' (thorn)
    if v == 30:
        out.append(UInt8(116))  # 't'
        out.append(UInt8(104))  # 'h'
        return True
    # ß  (lo 0x1F, only the lower-half byte 0x9F = U+00DF) -> "ss";
    # ÿ  (lo 0x1F upper-half byte 0xBF = U+00FF) -> 'y'.
    if v == 31:
        if b2 == UInt8(0xBF):  # ÿ (U+00FF)
            out.append(UInt8(121))  # 'y'
            return True
        # ß (U+00DF, b2 == 0x9F)
        out.append(UInt8(115))  # 's'
        out.append(UInt8(115))  # 's'
        return True
    return False  # no mapping (× ÷ etc.); pass original bytes through


@always_inline
def _fold_latin_ext_a_into(mut out: List[UInt8], lead: UInt8, b2: UInt8) -> Bool:
    """Fold a 0xC4 <b2> or 0xC5 <b2> two-byte UTF-8 sequence
    (U+0100..U+017F, Latin Extended-A) to unaccented lowercase ASCII, APPENDING
    the folded ASCII byte(s) into `out`. Returns True if a mapping was applied,
    False if no mapping (nothing appended — caller passes the 2 bytes through).

    The codepoint is U+0100 + ((lead - 0xC4) * 0x40) + (b2 - 0x80). The fold is
    by base letter; both the even (upper) and odd (lower) codepoints in a
    case-pair fold to the same lowercase ASCII."""
    var cp = 0x100 + (Int(lead) - 0xC4) * 0x40 + (Int(b2) - 0x80)
    if cp < 0x100 or cp > 0x17F:
        return False  # out of range -> no mapping
    # Map by codepoint range. Each contiguous block of case-pairs shares a base.
    # Ā ā Ă ă Ą ą  (0x100..0x105) -> 'a'
    if cp >= 0x100 and cp <= 0x105:
        out.append(UInt8(97))
        return True
    # Ć ć Ĉ ĉ Ċ ċ Č č  (0x106..0x10D) -> 'c'
    if cp >= 0x106 and cp <= 0x10D:
        out.append(UInt8(99))
        return True
    # Ď ď Đ đ  (0x10E..0x111) -> 'd'
    if cp >= 0x10E and cp <= 0x111:
        out.append(UInt8(100))
        return True
    # Ē ē Ĕ ĕ Ė ė Ę ę Ě ě  (0x112..0x11B) -> 'e'
    if cp >= 0x112 and cp <= 0x11B:
        out.append(UInt8(101))
        return True
    # Ĝ ĝ Ğ ğ Ġ ġ Ģ ģ  (0x11C..0x123) -> 'g'
    if cp >= 0x11C and cp <= 0x123:
        out.append(UInt8(103))
        return True
    # Ĥ ĥ Ħ ħ  (0x124..0x127) -> 'h'
    if cp >= 0x124 and cp <= 0x127:
        out.append(UInt8(104))
        return True
    # Ĩ ĩ Ī ī Ĭ ĭ Į į İ  (0x128..0x130) -> 'i'  (0x131 ı dotless -> 'i' too)
    if cp >= 0x128 and cp <= 0x131:
        out.append(UInt8(105))
        return True
    # Ĳ ĳ  (0x132..0x133) -> "ij"
    if cp >= 0x132 and cp <= 0x133:
        out.append(UInt8(105))  # 'i'
        out.append(UInt8(106))  # 'j'
        return True
    # Ĵ ĵ  (0x134..0x135) -> 'j'
    if cp >= 0x134 and cp <= 0x135:
        out.append(UInt8(106))
        return True
    # Ķ ķ ĸ  (0x136..0x138) -> 'k'
    if cp >= 0x136 and cp <= 0x138:
        out.append(UInt8(107))
        return True
    # Ĺ ĺ Ļ ļ Ľ ľ Ŀ ŀ Ł ł  (0x139..0x142) -> 'l'
    if cp >= 0x139 and cp <= 0x142:
        out.append(UInt8(108))
        return True
    # Ń ń Ņ ņ Ň ň ŉ Ŋ ŋ  (0x143..0x14B) -> 'n'
    if cp >= 0x143 and cp <= 0x14B:
        out.append(UInt8(110))
        return True
    # Ō ō Ŏ ŏ Ő ő  (0x14C..0x151) -> 'o'
    if cp >= 0x14C and cp <= 0x151:
        out.append(UInt8(111))
        return True
    # Œ œ  (0x152..0x153) -> "oe"
    if cp >= 0x152 and cp <= 0x153:
        out.append(UInt8(111))  # 'o'
        out.append(UInt8(101))  # 'e'
        return True
    # Ŕ ŕ Ŗ ŗ Ř ř  (0x154..0x159) -> 'r'
    if cp >= 0x154 and cp <= 0x159:
        out.append(UInt8(114))
        return True
    # Ś ś Ŝ ŝ Ş ş Š š  (0x15A..0x161) -> 's'
    if cp >= 0x15A and cp <= 0x161:
        out.append(UInt8(115))
        return True
    # Ţ ţ Ť ť Ŧ ŧ  (0x162..0x167) -> 't'
    if cp >= 0x162 and cp <= 0x167:
        out.append(UInt8(116))
        return True
    # Ũ ũ Ū ū Ŭ ŭ Ů ů Ű ű Ų ų  (0x168..0x173) -> 'u'
    if cp >= 0x168 and cp <= 0x173:
        out.append(UInt8(117))
        return True
    # Ŵ ŵ  (0x174..0x175) -> 'w'
    if cp >= 0x174 and cp <= 0x175:
        out.append(UInt8(119))
        return True
    # Ŷ ŷ Ÿ  (0x176..0x178) -> 'y'
    if cp >= 0x176 and cp <= 0x178:
        out.append(UInt8(121))
        return True
    # Ź ź Ż ż Ž ž  (0x179..0x17E) -> 'z'
    if cp >= 0x179 and cp <= 0x17E:
        out.append(UInt8(122))
        return True
    # ſ  (0x17F long s) -> 's'
    if cp == 0x17F:
        out.append(UInt8(115))
        return True
    return False  # cov: unreachable the ranges above cover every cp in [0x100, 0x17F]


# =============================================================================
# SIMD byte classification (the hottest index-build leaf).
# =============================================================================
#
# PERF-CRITICAL (search index-build per-bulk latency): the per-byte
# CLASSIFICATION the analyzer runs in its hot token loop — the whitespace test
# (`_is_ascii_ws`), the ASCII gate (`b < 0x80`), and ASCII-lowercase
# (`_to_lower`) — dominates the analyzer's self-time, and the analyzer is a
# large share of per-bulk build time. A SIMD[uint8,16] classification kernel is
# several times faster than the scalar one and bit-identical.
#
# THE OPTIMIZATION (SCOPE: ASCII-ONLY — bounds the correctness risk):
# `_simd_classify_into` walks the WHOLE cell byte stream ONCE with SIMD, writing
# two parallel per-byte buffers:
#   * `lowered[i]` = the ASCII-lowercased byte (A..Z -> a..z; every other byte
#                    UNCHANGED — byte-identical to `_to_lower`). For a byte >=0x80
#                    `_to_lower` is the identity, so `lowered[i] == bytes[i]`.
#   * `ws[i]`      = 1 if `bytes[i]` is ASCII whitespace, else 0 (byte-identical
#                    to `_is_ascii_ws`).
# It also returns the index of the FIRST byte >= 0x80 in the cell (or `n` if the
# cell is pure ASCII). The token-carve loop in `_analyze_bytes_resolved` then:
#   * uses `ws[]` to find token boundaries scalar (find-first-set boundary scan),
#   * for a token span that lies ENTIRELY before the first non-ASCII byte (the
#     common case for log/trace text), bulk-copies the precomputed `lowered[]`
#     slice into the term buffer (no per-byte branch, no fold dispatch),
#   * for any span that touches a byte >= 0x80, falls back to the EXISTING scalar
#     per-byte path (lowercase + Latin-fold) on the ORIGINAL bytes — the Latin
#     fold is NEVER SIMD'd (continuation bytes break lane alignment).
#
# WHY BYTE-IDENTICAL: the SIMD lane ops compute EXACTLY `_to_lower` /
# `_is_ascii_ws` per lane (a select on the upper-case lane-mask; a 6-way OR of
# equality compares). The scalar tail (`n % W`) re-runs the same scalar
# predicates. The pure-ASCII span copy emits the same bytes the scalar token loop
# would have appended (lowercase-then-copy for `b < 0x80` with fold a no-op on
# ASCII). The non-ASCII fallback span is the scalar per-byte path. Guarded
# by test_search_analyzer_simd_classify (byte-identical (term, position) over the
# boundary corpus) + the full test_search_* suite incl. the BM25 keystone golden.
#
# `lowered` / `ws` are plain `List[UInt8]` held on the stack inside
# `_analyze_bytes_resolved` (and reused across the cell's tokens) — NEVER a
# byte-slab element. No wildcard origin, no UnsafePointer crosses any boundary.


@always_inline
def _simd_classify_into[
    bytes_origin: Origin[mut=False]
](
    bytes: Span[UInt8, bytes_origin],
    mut lowered: List[UInt8],
    mut ws: List[UInt8],
) -> Int:
    """SIMD-classify `bytes` into `lowered` (ASCII-lowercased copy) + `ws`
    (per-byte whitespace flag 0/1). Both output buffers are CLEARED then refilled
    to `len(bytes)`. Returns the index of the FIRST byte >= 0x80 (or `len(bytes)`
    if the cell is pure ASCII), so the caller can fast-path pure-ASCII token spans
    and only fall to the scalar fold path past that boundary.

    Bit-identical to applying `_to_lower` / `_is_ascii_ws` per byte (asserted by
    test_search_analyzer_simd_classify). Hand-staged as a branchless lane
    mask — the autovectorizer does NOT fire."""
    var n = len(bytes)
    lowered.clear()
    ws.clear()
    if n == 0:
        return 0
    lowered.resize(n, UInt8(0))
    ws.resize(n, UInt8(0))

    # `lowered` and `ws` were resized to `n` just above and are not resized
    # again in this function, and `bytes` has length `n`. The SIMD loop covers
    # [0, simd_end) with simd_end = (n // W) * W; the scalar tail [simd_end, n).
    # SAFETY: every load and store through these three pointers is at index < n.
    var src = bytes.unsafe_ptr()
    var lo_ptr = lowered.unsafe_ptr()
    var ws_ptr = ws.unsafe_ptr()

    comptime W = simd_width_of[DType.uint8]()
    var ws_space = SIMD[DType.uint8, W](32)
    var ws_tab = SIMD[DType.uint8, W](9)
    var ws_lf = SIMD[DType.uint8, W](10)
    var ws_cr = SIMD[DType.uint8, W](13)
    var ws_vt = SIMD[DType.uint8, W](11)
    var ws_ff = SIMD[DType.uint8, W](12)
    var upper_lo = SIMD[DType.uint8, W](65)  # 'A'
    var upper_hi = SIMD[DType.uint8, W](90)  # 'Z'
    var plus32 = SIMD[DType.uint8, W](32)
    var high_bit = SIMD[DType.uint8, W](0x80)
    var one8 = SIMD[DType.uint8, W](1)
    var zero8 = SIMD[DType.uint8, W](0)

    var first_nonascii = n
    var simd_end = (n // W) * W
    var i = 0
    while i < simd_end:
        var v = src.load[width=W](i)
        # ASCII-lowercase: is_upper lane-mask -> select(b + 32, b). Byte-identical
        # to _to_lower (A..Z -> a..z; every other byte unchanged, incl. >= 0x80).
        var is_upper = v.ge(upper_lo) & v.le(upper_hi)
        var lowered_v = is_upper.select(v + plus32, v)
        lo_ptr.store[width=W](i, lowered_v)
        # whitespace lane-mask (6-way OR of equality compares) -> 0/1 byte.
        var is_ws = (
            v.eq(ws_space)
            | v.eq(ws_tab)
            | v.eq(ws_lf)
            | v.eq(ws_cr)
            | v.eq(ws_vt)
            | v.eq(ws_ff)
        )
        ws_ptr.store[width=W](i, is_ws.select(one8, zero8))
        # First non-ASCII (>= 0x80) byte in this chunk, if any (cold for OTLP).
        if first_nonascii == n:
            var nonascii = (v & high_bit).ne(zero8)
            if nonascii.reduce_or():
                # Locate the first set lane scalar (rare; only fires once).
                for k in range(W):
                    if Int(src[i + k]) >= 0x80:
                        first_nonascii = i + k
                        break
        i += W

    # Scalar tail (n % W bytes) — same predicates, byte-identical.
    while i < n:
        var b = src[i]
        lo_ptr[i] = _to_lower(b)
        ws_ptr[i] = UInt8(1) if _is_ascii_ws(b) else UInt8(0)
        if first_nonascii == n and Int(b) >= 0x80:
            first_nonascii = i
        i += 1

    return first_nonascii


# =============================================================================
# The ONE internal byte-span normalizer.
# Both public entry points funnel through here.
# =============================================================================


def _analyze_bytes_resolved[
    bytes_origin: Origin[mut=False]
](
    bytes: Span[UInt8, bytes_origin],
    config: AnalyzerConfig,
    stopwords: List[String],
) raises -> AnalyzedField:
    """THE internal normalizer hot loop — operates on a PRE-RESOLVED stopword
    set so the resolution (33 String allocs) is hoisted OUT of any per-row loop
    by the caller (the column driver resolves once per batch, not once per doc).

    `config.remove_stopwords` still gates removal; when it is False the caller
    passes an empty `stopwords` and the membership check is skipped. The caller
    is responsible for the non-text fail-loud guard (so the column
    driver doesn't re-check per row).

    PERF-CRITICAL (search index-build per-bulk latency): the per-
    token term buffer is allocated ONCE here and REUSED across every token in
    `bytes` via clear-and-refill (`tb.clear()`), instead of `var tb =
    List[UInt8]()` per token. The fold helpers append directly into `tb` (no
    per-byte List alloc). The String for each emitted term is still one alloc per
    surviving token (it is moved into the Token and must outlive the buffer).
    Output is byte-identical to a per-token-alloc shape (regression-
    guarded by the full test_search_analyzer suite + the keystone BM25 golden).

    PERF-CRITICAL (search index-build per-bulk latency): the per-byte
    CLASSIFICATION (whitespace test + ASCII-gate + lowercase) is SIMD-staged
    ONCE over the whole cell via `_simd_classify_into` (see the SIMD byte
    classification section). The token-carve loop reads the precomputed `ws[]` mask for
    boundaries and bulk-copies the precomputed `lowered[]` slice for pure-ASCII
    spans; only spans touching a byte >= 0x80 fall to the scalar lowercase+fold
    path (the Latin fold is NEVER SIMD'd). Byte-identical to an all-scalar
    shape — guarded by test_search_analyzer_simd_classify + the BM25 keystone
    golden. The `lowered` / `ws` scratch are reused across the cell's tokens.
    """
    var result = AnalyzedField(List[Token]())
    var n = len(bytes)
    var i = 0
    var position = 0
    var do_remove = config.remove_stopwords
    var do_lower = config.lowercase
    var do_fold = config.ascii_fold

    # One reusable term buffer for the whole cell (cleared per token).
    var term_bytes = List[UInt8]()

    # SIMD-classify the whole cell ONCE: lowered[] (ASCII-lowercased copy) + ws[]
    # (per-byte whitespace flag) + first_nonascii (the >= 0x80 boundary). When
    # lowercase is DISABLED we still need ws[] for the whitespace split, but the
    # ASCII fast-path must copy the ORIGINAL bytes — so `lowered` is only consulted
    # for the term bytes when `do_lower` is True (else the fast path copies `bytes`
    # directly, byte-identical to the scalar `else: append(b)` branch).
    var lowered = List[UInt8]()
    var ws = List[UInt8]()
    var first_nonascii = _simd_classify_into(bytes, lowered, ws)
    # SAFETY: `_simd_classify_into` leaves `ws` with length n = len(bytes), `ws`
    # is not resized while `ws_ptr` is live, and every `ws_ptr[i]` below is
    # guarded by `i < n` first.
    var ws_ptr = ws.unsafe_ptr()

    while i < n:
        # Skip a run of whitespace (collapses leading/trailing/repeated WS).
        # SIMD: read the precomputed per-byte whitespace flag.
        while i < n and ws_ptr[i] != UInt8(0):
            i += 1
        if i >= n:
            break
        # Now bytes[i] is the start of a non-whitespace token span. Scan the span
        # end via the precomputed ws[] mask and detect whether it is pure ASCII.
        var span_start = i
        while i < n and ws_ptr[i] == UInt8(0):
            i += 1
        var span_end = i  # exclusive

        # Build the term String for this span. The empty-span case cannot arise
        # (span_start < span_end by the carve), so no empty-skip is needed for the
        # fast path; the fold path can only EXPAND, never erase, so it is also
        # non-empty — the defensive empty check below is retained for the fold
        # path only.
        var term: String
        if span_end <= first_nonascii:
            # Pure-ASCII span (the ~99% case): construct the term String DIRECTLY
            # from the precomputed contiguous slice — no per-byte append, no
            # intermediate term_bytes copy. `lowered[span_start:span_end]` already
            # holds the SIMD-lowercased bytes (byte-identical to the scalar
            # lowercase-then-copy branch); when do_lower is False the original
            # `bytes` slice is the term (byte-identical to the `else: append(b)`
            # branch). Fold is a no-op on ASCII, so both are exact.
            if do_lower:
                var span = Span(lowered)[span_start:span_end]
                # SAFETY: the span ends at or before `first_nonascii`: pure ASCII.
                term = String(StringSlice(unsafe_from_utf8=span))
            else:
                var span = bytes[span_start:span_end]
                # SAFETY: the span ends at or before `first_nonascii`: pure ASCII.
                term = String(StringSlice(unsafe_from_utf8=span))
        else:
            # Span touches a byte >= 0x80: run the EXISTING scalar lowercase +
            # Latin-fold path over the ORIGINAL bytes into
            # the reusable term_bytes buffer.
            term_bytes.clear()
            var j = span_start
            while j < span_end:
                var b = bytes[j]
                if b < UInt8(0x80):
                    # ASCII byte: lowercase (if enabled), copy through.
                    if do_lower:
                        term_bytes.append(_to_lower(b))
                    else:
                        term_bytes.append(b)
                    j += 1
                elif do_fold and (
                    b == UInt8(0xC3) or b == UInt8(0xC4) or b == UInt8(0xC5)
                ):
                    # Latin fold candidate. Bounds-check 2nd byte.
                    if j + 1 >= n:
                        # Truncated multibyte at span end: pass lead through.
                        term_bytes.append(b)
                        j += 1
                    else:
                        var b2 = bytes[j + 1]
                        var mapped: Bool
                        if b == UInt8(0xC3):
                            mapped = _fold_latin1_into(term_bytes, b2)
                        else:
                            mapped = _fold_latin_ext_a_into(term_bytes, b, b2)
                        if not mapped:
                            # No mapping: pass the 2 bytes through unchanged
                            # (still 2 bytes consumed).
                            term_bytes.append(b)
                            term_bytes.append(b2)
                        j += 2
                else:
                    # Non-ASCII byte, fold disabled OR not a Latin lead: pass
                    # through unchanged (byte-for-byte; never a token boundary).
                    term_bytes.append(b)
                    j += 1
            # Defensive: a span folding to nothing (the fold map never erases, so
            # this cannot fire) — skip empties (no empty term is ever emitted).
            if len(term_bytes) == 0:
                continue  # cov: unreachable every consumed byte appends at least one byte
            # SAFETY: the cell is UTF-8 text, spans end at ASCII whitespace, and
            # the fold maps emit whole UTF-8 sequences, so `term_bytes` is too.
            term = String(StringSlice(unsafe_from_utf8=Span(term_bytes)))

        # Stopword removal runs AFTER lowercase+fold (so "The" -> "the" matches).
        if do_remove and _stopword_contains(stopwords, term):
            continue

        result.tokens.append(Token(term^, position))
        position += 1

    return result^


def _analyze_bytes[
    bytes_origin: Origin[mut=False]
](bytes: Span[UInt8, bytes_origin], config: AnalyzerConfig) raises -> AnalyzedField:
    """THE internal normalizer — the single source of tokenization truth.

    Walks `bytes` once: split on ASCII whitespace into maximal non-whitespace
    token spans; within each span, lowercase+fold (per config) into a fresh
    term String; drop empty terms; drop stopwords (per config, post-normalize);
    emit Token(term, position) with monotonically increasing position.

    Funnel point for analyze_text (query side) and analyze_text_column (index
    side): index-time and query-time tokenization are byte-identical because
    both reach this function with the same bytes + config.

    Resolves the stopword set ONCE then delegates to `_analyze_bytes_resolved`.
    Single-cell callers (the query side, single-doc tests) use this. The hot
    column driver instead resolves the set ONCE per batch and calls
    `_analyze_bytes_resolved` per row directly (see analyze_text_column_resolved).

    Raises:
      If `not config.is_tokenized()` (analyzing a
      non-TEXT field is a programming error; fail loud at the first cell).
      If config.stopword_set is an unknown tag (and removal is on).
    """
    # Non-text path = fail-loud.
    if not config.is_tokenized():
        raise Error(
            "analyze: field '"
            + config.field_name
            + "' is not a TEXT field (field_class="
            + String(Int(config.field_class))
            + "); analyzing a non-TEXT field is a programming error"
        )

    # Resolve the stopword set ONCE per call (only when removal is enabled).
    var stopwords = List[String]()
    if config.remove_stopwords:
        stopwords = _resolve_stopwords(config.stopword_set)

    return _analyze_bytes_resolved(bytes, config, stopwords)


def resolve_stopwords_for(config: AnalyzerConfig) raises -> List[String]:
    """Resolve the stopword set for `config` ONCE (the column driver hoists this
    out of its per-row loop). Returns an empty list when removal is disabled.

    Also performs the non-text fail-loud guard so the column driver
    can check it ONCE per batch (rather than once per row inside the hot loop).
    Raises on a non-TEXT config or an unknown stopword_set tag."""
    if not config.is_tokenized():
        raise Error(
            "analyze: field '"
            + config.field_name
            + "' is not a TEXT field (field_class="
            + String(Int(config.field_class))
            + "); analyzing a non-TEXT field is a programming error"
        )
    if config.remove_stopwords:
        return _resolve_stopwords(config.stopword_set)
    return List[String]()


# =============================================================================
# The public analyze entry points (BOTH funnel into _analyze_bytes).
# =============================================================================


def analyze_text(text: String, config: AnalyzerConfig) raises -> AnalyzedField:
    """Tokenize + normalize ONE document's / one query's text value per
    `config`. The QUERY-SIDE entry point (SearchCore tokenizes a query
    *string*).

    Takes a String (matches the codebase borrowed-param
    idiom + StringView.to_string()'s return type), then funnels its bytes into
    the single internal normalizer `_analyze_bytes`.

    v1 pipeline (per-field configurable): whitespace split -> ASCII lowercase
    -> ASCII-fold -> stopword removal. See _analyze_bytes.

    Raises:
      If `not config.is_tokenized()` or on an unknown
      stopword_set tag.
    """
    return _analyze_bytes(text.as_bytes(), config)


def analyze_text_column[
    origin: Origin[mut=False]
](
    col: StringColumnView[origin], row: Int, config: AnalyzerConfig
) raises -> AnalyzedField:
    """Column-at-a-time entry point: analyze the cell at `row` of a borrowed
    STRING column. The INDEX-SIDE path — IndexCore.add_documents borrows the
    text column out of the DocBatch RecordBatch via StringColumnView and
    iterates rows (one document per row), calling this per row.

    Byte source (see module header): the cell is
    materialized to a String ONCE via StringView.to_string() (one O(cell)
    copy), then its contiguous bytes are funneled into `_analyze_bytes`. This
    is NOT a per-byte byte_at() loop; the one-copy fallback is sanctioned
    because a zero-copy Span[UInt8, origin] cannot be threaded without
    surfacing the column buffer's wildcard-origin internal pointer.

    Raises:
      If the column is not a varlen STRING column or `row` is out of range
      (from StringColumnView.get); if `not config.is_tokenized()`;
      or on an unknown stopword_set tag.
    """
    var cell = col.get(row).to_string()
    return _analyze_bytes(cell.as_bytes(), config)


def analyze_text_column_resolved[
    origin: Origin[mut=False]
](
    col: StringColumnView[origin],
    row: Int,
    config: AnalyzerConfig,
    stopwords: List[String],
) raises -> AnalyzedField:
    """The hot column-driver entry point: analyze the cell at `row` using a
    PRE-RESOLVED stopword set (resolved ONCE per batch by the caller via
    resolve_stopwords_for). Byte-identical to analyze_text_column — the only
    difference is the stopword set + the non-text guard are hoisted out of the
    per-row loop (see add_text_column).

    PERF-CRITICAL (search index-build per-bulk latency): this avoids
    re-resolving the 33-word English stopword set (33 String heap allocs) on
    every document. For a 200-doc bulk that is 6600 String allocs eliminated.
    Do NOT route the column driver back through analyze_text_column (which
    re-resolves per cell). Output is byte-identical — guarded by
    test_search_analyzer_alloc_perf + the BM25 keystone golden.

    Raises:
      From StringColumnView.get (non-STRING column / out-of-range row). The
      non-text + unknown-stopword-tag guards are the CALLER's (resolve_stopwords_for),
      done ONCE per batch.
    """
    var cell = col.get(row).to_string()
    return _analyze_bytes_resolved(cell.as_bytes(), config, stopwords)

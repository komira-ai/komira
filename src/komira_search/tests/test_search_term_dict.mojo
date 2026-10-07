# =============================================================================
# test_search_term_dict.mojo — the two-stage term-dict unit test
# =============================================================================
#
# A 12-case test plan over term_dict's design points B1–B8, including the
# corruption cases 8b/8c, the B6 case 4b, and the B5 serialize-before-patch
# raise.
#
# Coverage (enumerated cases):
#   1.   single term
#   2.   many terms across a block boundary (21 = 16 + 5; _num_blocks == 2)
#   3.   front-coding shared-prefix decode (LCP shrink: "search" -> "season")
#   4.   sparse-index binary search HIT (first term of a non-zero block)
#   4b. query EQUAL to a non-zero block's first term -> block*BLOCK_TERMS
#   5.   sparse-index MISS / near-miss prefix + before-all + after-all -> None
#   6.   lookup found / not-found ("cat" present, "cats" absent)
#   7.   doc_freq carried through (distinct df values)
#   8.   round-trip serialize -> deserialize -> lookup + magic/version mismatch
#   8b. truncated/oversized ULEB128 length prefix mid-region -> raises
#   8c. oversized shared_prefix_len -> raises
#   9.   write_uleb128 <-> read_uleb128 round-trip (boundary byte counts)
#   10.  FST-swap seam — stage (b) independently readable via offsets table
#   11.  TermInfo patch-pass (set_posting_location) + out-of-range/negative raise
#   11b. serialize BEFORE patch (any UNSET) raises
#   12.  empty (n=0 canonical form) + single partial block (< BLOCK_TERMS)
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_buffer.byte_buffer import ByteBuffer, write_uleb128

from komira_search.analyzer import AnalyzedField, Token
from komira_search.inverted import InvertedIndexBuilder, FinalizedIndex
from komira_search.term_dict import (
    TermDictBuilder,
    TermDictionary,
    TermInfoStore,
    TermInfo,
    BLOCK_TERMS,
    POSTING_LOC_UNSET,
)


# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------


def _af(terms: List[String]) -> AnalyzedField:
    """Build an AnalyzedField from a flat list of term strings (positions in
    emission order). The builder is driven directly with synthetic multisets."""
    var toks = List[Token]()
    for i in range(len(terms)):
        toks.append(Token(terms[i], i))
    return AnalyzedField(toks^)


def _span_of(s: String) -> List[UInt8]:
    """A String's bytes as an owned List[UInt8] (the lookup() Span source)."""
    var out = List[UInt8]()
    for c in s.as_bytes():
        out.append(c)
    return out^


def _lookup(imm d: TermDictionary, term: String) raises -> Optional[Int]:
    """lookup() over a String term (materialized to a stable byte list)."""
    var bytes = _span_of(term)
    return d.lookup(Span(bytes))


# Build a FinalizedIndex over a list of (term, doc_count) by emitting `term`
# into `doc_count` distinct documents (df == doc_count). Each doc carries ONLY
# the terms whose doc-quota still covers it, so each term's doc-freq == its
# requested doc_count. Ordinals come out lexicographically sorted by finalize.
def _build_fi_with_dfs(
    pairs: List[Tuple[String, Int]],
) raises -> FinalizedIndex:
    var b = InvertedIndexBuilder.create("body")
    # Find the max df so we know how many docs to emit.
    var max_df = 0
    for k in range(len(pairs)):
        if pairs[k][1] > max_df:
            max_df = pairs[k][1]
    var doc_id = 0
    for d in range(max_df):
        var terms = List[String]()
        for k in range(len(pairs)):
            if d < pairs[k][1]:
                terms.append(pairs[k][0])
        if len(terms) > 0:
            b.add_document(doc_id, _af(terms)^)
            doc_id += 1
    return b.finalize()


# Build a FinalizedIndex over a flat list of distinct terms (each df == 1),
# all in ONE document.
def _build_fi(terms: List[String]) raises -> FinalizedIndex:
    var b = InvertedIndexBuilder.create("body")
    if len(terms) > 0:
        b.add_document(0, _af(terms)^)
    return b.finalize()


# -----------------------------------------------------------------------------
# Case 1 — single term
# -----------------------------------------------------------------------------


def test_case1_single_term() raises:
    var terms = List[String]()
    terms.append("hello")
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    assert_equal(d.num_terms(), 1)
    var got = _lookup(d, "hello")
    assert_true(Bool(got))
    assert_equal(got.value(), 0)
    var ti = d.term_info_at(0)
    assert_equal(ti.doc_freq, 1)
    assert_equal(ti.posting_offset, POSTING_LOC_UNSET)
    assert_equal(ti.posting_len, POSTING_LOC_UNSET)


# -----------------------------------------------------------------------------
# Case 2 — many terms across a block boundary (21 terms -> 2 blocks)
# -----------------------------------------------------------------------------


def _t2_terms() -> List[String]:
    # "t00".."t20" — lex-sorted == numeric order (2-digit zero-padded).
    var terms = List[String]()
    for i in range(21):
        var s = "t"
        if i < 10:
            s += "0"
        s += String(i)
        terms.append(s)
    return terms^


def test_case2_block_boundary() raises:
    var terms = _t2_terms()
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    assert_equal(d.num_terms(), 21)
    assert_equal(d.num_blocks(), 2)  # 16 + 5
    # Every term resolves to its lex ordinal.
    for i in range(21):
        var got = _lookup(d, terms[i])
        assert_true(Bool(got))
        assert_equal(got.value(), i)
    assert_equal(_lookup(d, "t00").value(), 0)
    assert_equal(_lookup(d, "t20").value(), 20)


# -----------------------------------------------------------------------------
# Case 3 — front-coding shared-prefix decode (LCP shrink)
# -----------------------------------------------------------------------------


def test_case3_front_coding_decode() raises:
    # Lex order: "search" < "searcher" < "searching" < "season".
    # LCP shrinks from "sea..." to just "sea" at the search->season step.
    var terms = List[String]()
    terms.append("search")
    terms.append("searcher")
    terms.append("searching")
    terms.append("season")
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    assert_equal(d.num_terms(), 4)
    assert_equal(_lookup(d, "search").value(), 0)
    assert_equal(_lookup(d, "searcher").value(), 1)
    assert_equal(_lookup(d, "searching").value(), 2)
    assert_equal(_lookup(d, "season").value(), 3)
    # An absent prefix that shares the block must NOT match.
    assert_false(Bool(_lookup(d, "sea")))
    assert_false(Bool(_lookup(d, "seasons")))


# -----------------------------------------------------------------------------
# Case 4 — sparse-index binary search HIT (first term of a non-zero block)
# -----------------------------------------------------------------------------


def _t4_terms() -> List[String]:
    # 40 terms -> 3 blocks (16 + 16 + 8). "u000".."u039", lex == numeric.
    var terms = List[String]()
    for i in range(40):
        var s = "u"
        if i < 10:
            s += "00"
        elif i < 100:
            s += "0"
        s += String(i)
        terms.append(s)
    return terms^


def test_case4_sparse_hit() raises:
    var terms = _t4_terms()
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    assert_equal(d.num_terms(), 40)
    assert_equal(d.num_blocks(), 3)
    # Block 1's first term is ordinal 16 == "u016"; block 2's is ordinal 32.
    assert_equal(_lookup(d, terms[16]).value(), 16)
    assert_equal(_lookup(d, terms[32]).value(), 32)


# -----------------------------------------------------------------------------
# Case 4b — query EQUAL to a non-zero block's first term resolves to
#               block*BLOCK_TERMS (k == 0), NOT the prior block's last term.
# -----------------------------------------------------------------------------


def test_case4b_block_first_term_k0() raises:
    var terms = _t4_terms()
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    # ordinal 16 == block 1, k == 0  => 1*BLOCK_TERMS + 0 == 16.
    var got = _lookup(d, terms[16])
    assert_true(Bool(got))
    assert_equal(got.value(), 1 * BLOCK_TERMS + 0)
    # Sanity: the prior block's LAST term is ordinal 15 != 16.
    assert_equal(_lookup(d, terms[15]).value(), 15)


# -----------------------------------------------------------------------------
# Case 5 — sparse-index MISS / near-miss prefix + before/after all -> None
# -----------------------------------------------------------------------------


def test_case5_miss() raises:
    var terms = List[String]()
    terms.append("search")
    terms.append("searching")
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    # Absent but lexicographically BETWEEN two real terms in the same block.
    assert_false(Bool(_lookup(d, "searchin")))
    # Before all blocks (block < 0) and after all blocks (scan-to-end).
    assert_false(Bool(_lookup(d, "aaa")))
    assert_false(Bool(_lookup(d, "zzz")))


# -----------------------------------------------------------------------------
# Case 6 — lookup found / not-found ("cat" present, "cats" absent)
# -----------------------------------------------------------------------------


def test_case6_found_notfound() raises:
    var terms = List[String]()
    terms.append("apple")
    terms.append("banana")
    terms.append("cat")
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    assert_true(Bool(_lookup(d, "apple")))
    assert_true(Bool(_lookup(d, "banana")))
    assert_true(Bool(_lookup(d, "cat")))
    # One-byte-longer absent variant.
    assert_false(Bool(_lookup(d, "cats")))
    assert_false(Bool(_lookup(d, "dog")))


# -----------------------------------------------------------------------------
# Case 7 — doc_freq carried through (distinct df values)
# -----------------------------------------------------------------------------


def test_case7_doc_freq() raises:
    # term "alpha" in 3 docs, "beta" in 1 doc.
    var pairs = List[Tuple[String, Int]]()
    pairs.append(("alpha", 3))
    pairs.append(("beta", 1))
    var fi = _build_fi_with_dfs(pairs)
    var d = TermDictBuilder.build_from_finalized(fi)
    var ord_a = _lookup(d, "alpha")
    var ord_b = _lookup(d, "beta")
    assert_true(Bool(ord_a))
    assert_true(Bool(ord_b))
    assert_equal(d.term_info_at(ord_a.value()).doc_freq, 3)
    assert_equal(d.term_info_at(ord_b.value()).doc_freq, 1)


# -----------------------------------------------------------------------------
# Case 8 — round-trip serialize -> deserialize -> lookup + magic/version mismatch
# -----------------------------------------------------------------------------


def test_case8_roundtrip() raises:
    var terms = _t4_terms()  # 40 terms, 3 blocks
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    # Patch all posting locations so serialize does not raise.
    for ordinal in range(d.num_terms()):
        d.set_posting_location(ordinal, ordinal * 10, ordinal + 1)

    var buf = List[UInt8]()
    d.serialize(buf)

    var d2 = TermDictionary.deserialize(buf^)
    assert_equal(d2.num_terms(), 40)
    assert_equal(d2.field_name(), "body")
    for i in range(40):
        var got = _lookup(d2, terms[i])
        assert_true(Bool(got))
        assert_equal(got.value(), i)
        var ti = d2.term_info_at(i)
        assert_equal(ti.posting_offset, i * 10)
        assert_equal(ti.posting_len, i + 1)
    # Absent terms still None post-roundtrip.
    assert_false(Bool(_lookup(d2, "zzz")))


def test_case8_magic_mismatch() raises:
    var terms = List[String]()
    terms.append("x")
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    d.set_posting_location(0, 0, 1)
    var buf = List[UInt8]()
    d.serialize(buf)
    # Corrupt byte 0 (the magic).
    buf[0] = UInt8(ord("X"))
    with assert_raises():
        _ = TermDictionary.deserialize(buf^)


def test_case8_version_mismatch() raises:
    var terms = List[String]()
    terms.append("x")
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    d.set_posting_location(0, 0, 1)
    var buf = List[UInt8]()
    d.serialize(buf)
    # Corrupt the version byte (index 6, right after the 6-byte magic).
    buf[6] = UInt8(99)
    with assert_raises():
        _ = TermDictionary.deserialize(buf^)


# -----------------------------------------------------------------------------
# Case 8b — truncated/oversized ULEB128 length prefix mid-region -> raises
# -----------------------------------------------------------------------------


def test_case8b_corrupt_length_prefix() raises:
    # Build a multi-block dict, serialize, then corrupt the first-term length
    # prefix inside the stage-a region to an oversized value. deserialize must
    # fail loud BEFORE any bulk read, not OOB or mis-parse.
    var terms = _t4_terms()
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    for ordinal in range(d.num_terms()):
        d.set_posting_location(ordinal, 0, 1)
    var buf = List[UInt8]()
    d.serialize(buf)

    # Locate stage_a_offset from the offsets table to find the first-term
    # region. Header = 6 (magic) + 1 (version) + 1 (flags) + 4 (fname_len) +
    # fname bytes. fname == "body" (4 bytes). Then 4 u64 offsets.
    var off_table_start = 6 + 1 + 1 + 4 + 4
    var stage_a_offset = _read_u64(buf, off_table_start)
    # stage-a layout: num_blocks u64 + num_terms u64 + (num_blocks+1) u64
    # offsets + num_blocks u64 counts, THEN the first first-term's ULEB128
    # length prefix. With 3 blocks: 2 + 4 + 3 = 9 u64 = 72 bytes in.
    var first_len_pos = Int(stage_a_offset) + (2 + (3 + 1) + 3) * 8
    # Corrupt the length prefix to an oversized single-byte ULEB128 (0x7F=127),
    # which exceeds the remaining bytes of the first-term region -> raises.
    # (The real first term "u000" is 4 bytes; 127 overshoots the whole rest.)
    buf[first_len_pos] = UInt8(0x7F)
    with assert_raises():
        _ = TermDictionary.deserialize(buf^)


# -----------------------------------------------------------------------------
# Case 8c — oversized shared_prefix_len in a block -> raises (front-decode)
# -----------------------------------------------------------------------------


def test_case8c_corrupt_shared_prefix() raises:
    # "search","searcher" share LCP 6. Corrupt the SECOND term's
    # shared_prefix_len in the block stream to an oversized value, then a
    # lookup that must scan that block (front-decode) must raise (the
    # shared_prefix_len > current decoded length is fail-loud).
    var terms = List[String]()
    terms.append("search")
    terms.append("searcher")
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    for ordinal in range(d.num_terms()):
        d.set_posting_location(ordinal, 0, 1)
    var buf = List[UInt8]()
    d.serialize(buf)

    var off_table_start = 6 + 1 + 1 + 4 + 4
    var stage_a_offset = Int(_read_u64(buf, off_table_start))
    # stage-a header for 1 block (1+1 block_offset, 1 block_count):
    #   num_blocks u64 + num_terms u64 + 2 block_offset u64 + 1 block_count u64
    #   = 5 u64 = 40 bytes.
    var hdr = stage_a_offset + 5 * 8
    # ONE first-term arena entry: ULEB(6)=1 byte + "search"=6 bytes = 7 bytes.
    var after_first_arena = hdr + 1 + 6
    # block_bytes_len u64 (8 bytes), then block_bytes begin.
    var block_bytes_start = after_first_arena + 8
    # block_bytes: term0 = ULEB(6)=1 + "search"=6 = 7 bytes; THEN term1's
    # shared_prefix_len ULEB byte (the one we corrupt).
    var term1_shared_pos = block_bytes_start + 1 + 6
    # Corrupt the shared_prefix_len to a value > 6 (the current decoded
    # length). 0x7F=127 is a valid single-byte ULEB but > 6 -> B2 fail-loud.
    buf[term1_shared_pos] = UInt8(0x7F)

    var d2 = TermDictionary.deserialize(buf^)
    # The lookup of "searcher" front-decodes term1 -> must raise on the
    # corrupt shared_prefix_len.
    with assert_raises():
        _ = _lookup(d2, "searcher")


def _read_u64(imm buf: List[UInt8], pos: Int) -> UInt64:
    var v = UInt64(0)
    for i in range(8):
        v |= UInt64(Int(buf[pos + i])) << UInt64(8 * i)
    return v


# -----------------------------------------------------------------------------
# Case 9 — write_uleb128 <-> read_uleb128 round-trip (boundary byte counts)
# -----------------------------------------------------------------------------


def _uleb_byte_count(v: Int) -> Int:
    var out = List[UInt8]()
    write_uleb128(v, out)
    return len(out)


def test_case9_uleb_roundtrip() raises:
    var vals = List[Int]()
    vals.append(0)
    vals.append(1)
    vals.append(127)
    vals.append(128)
    vals.append(16383)
    vals.append(16384)
    vals.append(2097151)
    vals.append(2097152)
    vals.append(123456789)
    for k in range(len(vals)):
        var v = vals[k]
        var out = List[UInt8]()
        write_uleb128(v, out)
        var cur = ByteBuffer(out^)
        assert_equal(cur.read_uleb128(), v)
    # Byte-count boundaries (the zigzag trap guard: 127 -> 1 byte, 128 -> 2).
    assert_equal(_uleb_byte_count(0), 1)
    assert_equal(_uleb_byte_count(127), 1)
    assert_equal(_uleb_byte_count(128), 2)
    assert_equal(_uleb_byte_count(16383), 2)
    assert_equal(_uleb_byte_count(16384), 3)


# -----------------------------------------------------------------------------
# Case 10 — FST-swap seam: stage (b) independently readable via offsets table
# -----------------------------------------------------------------------------


def test_case10_fst_swap_seam() raises:
    var terms = _t4_terms()  # 40 terms
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    for ordinal in range(d.num_terms()):
        d.set_posting_location(ordinal, ordinal * 7, ordinal * 2 + 1)
    var buf = List[UInt8]()
    d.serialize(buf)

    # Read stage_b_offset / stage_b_len from the offsets table WITHOUT parsing
    # stage (a) — the invariant an FST swap relies on.
    var off_table_start = 6 + 1 + 1 + 4 + 4  # fname == "body" (4 bytes)
    var stage_b_offset = Int(_read_u64(buf, off_table_start + 16))
    var stage_b_len = Int(_read_u64(buf, off_table_start + 24))

    # Slice out JUST the stage-b region and reconstruct the store directly.
    var store_bytes = List[UInt8]()
    for i in range(stage_b_offset, stage_b_offset + stage_b_len):
        store_bytes.append(buf[i])
    var store_cur = ByteBuffer(store_bytes^)
    var num_terms = stage_b_len // 24
    var store = TermInfoStore.deserialize(store_cur, num_terms)

    assert_equal(store.num_terms(), 40)
    for ordinal in range(40):
        var ti = store.get(ordinal)
        assert_equal(ti.posting_offset, ordinal * 7)
        assert_equal(ti.posting_len, ordinal * 2 + 1)
        assert_equal(ti.doc_freq, 1)
    _ = buf  # buf still owns the original bytes (we copied the slice out)


# -----------------------------------------------------------------------------
# Case 11 — TermInfo patch-pass (set_posting_location) + out-of-range/negative
# -----------------------------------------------------------------------------


def test_case11_patch_pass() raises:
    var terms = List[String]()
    terms.append("alpha")
    terms.append("beta")
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    # Pre-patch: UNSET.
    assert_equal(d.term_info_at(0).posting_offset, POSTING_LOC_UNSET)
    var df0 = d.term_info_at(0).doc_freq
    var df1 = d.term_info_at(1).doc_freq
    # Patch.
    d.set_posting_location(0, 100, 8)
    d.set_posting_location(1, 200, 16)
    assert_equal(d.term_info_at(0).posting_offset, 100)
    assert_equal(d.term_info_at(0).posting_len, 8)
    assert_equal(d.term_info_at(1).posting_offset, 200)
    assert_equal(d.term_info_at(1).posting_len, 16)
    # doc_freq unchanged by the patch.
    assert_equal(d.term_info_at(0).doc_freq, df0)
    assert_equal(d.term_info_at(1).doc_freq, df1)
    # Out-of-range ordinal raises.
    with assert_raises():
        d.set_posting_location(5, 0, 0)
    # Negative offset/len raises.
    with assert_raises():
        d.set_posting_location(0, -1, 4)
    with assert_raises():
        d.set_posting_location(0, 4, -1)


# -----------------------------------------------------------------------------
# Case 11b — serialize BEFORE patch (any UNSET) raises
# -----------------------------------------------------------------------------


def test_case11b_serialize_before_patch_raises() raises:
    var terms = List[String]()
    terms.append("alpha")
    terms.append("beta")
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    # No set_posting_location calls — both rows still POSTING_LOC_UNSET.
    var buf = List[UInt8]()
    with assert_raises():
        d.serialize(buf)
    # Patch only ONE of two -> still raises (the other is UNSET).
    var d2 = TermDictBuilder.build_from_finalized(_build_fi(terms))
    d2.set_posting_location(0, 0, 1)
    var buf2 = List[UInt8]()
    with assert_raises():
        d2.serialize(buf2)


# -----------------------------------------------------------------------------
# Case 12 — empty (n=0 canonical form) + single partial block (< BLOCK_TERMS)
# -----------------------------------------------------------------------------


def test_case12_empty() raises:
    var terms = List[String]()  # zero terms
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    assert_equal(d.num_terms(), 0)
    assert_equal(d.num_blocks(), 0)  # B4 canonical form
    assert_false(Bool(_lookup(d, "anything")))
    # Serialize/deserialize an empty dict cleanly (no UNSET rows -> no B5 raise).
    var buf = List[UInt8]()
    d.serialize(buf)
    var d2 = TermDictionary.deserialize(buf^)
    assert_equal(d2.num_terms(), 0)
    assert_equal(d2.num_blocks(), 0)
    assert_equal(d2.field_name(), "body")
    assert_false(Bool(_lookup(d2, "anything")))


def test_case12_single_partial_block() raises:
    var terms = List[String]()
    terms.append("cherry")
    terms.append("apple")
    terms.append("banana")  # 3 terms < BLOCK_TERMS -> one partial block
    var fi = _build_fi(terms)
    var d = TermDictBuilder.build_from_finalized(fi)
    assert_equal(d.num_terms(), 3)
    assert_equal(d.num_blocks(), 1)
    # Lex order: apple(0), banana(1), cherry(2).
    assert_equal(_lookup(d, "apple").value(), 0)
    assert_equal(_lookup(d, "banana").value(), 1)
    assert_equal(_lookup(d, "cherry").value(), 2)
    assert_false(Bool(_lookup(d, "date")))


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

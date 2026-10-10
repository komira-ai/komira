# =============================================================================
# test_search_cov_index_dict.mojo: the inverted-index builder's collision and
# range edges, and the term dictionary's refusals of corrupt bytes.
# =============================================================================
#
#   1. Every FinalizedIndex accessor refuses an ordinal outside [0, num_terms).
#   2. Two different terms given the SAME hash stay two terms: a same-salt
#      directory hit compares the bytes (a different length, then same length
#      different bytes), and each term is found again under that hash.
#   3. create_with_capacity rounds the directory past the default for a large
#      hint (and the builder still indexes).
#   4. The term dictionary's stage (a) refuses a block index outside its range,
#      a decoded length past its bound, and a decoded term past MAX_TERM_LEN.
#   5. SortedBlockTermMap.deserialize refuses a negative count, an offset table
#      or a count table past the bytes left, a first-term length past the bytes
#      left, and one past MAX_TERM_LEN.
#   6. TermInfoStore: get refuses an ordinal out of range; deserialize refuses a
#      negative count and a store larger than the bytes left.
#   7. TermDictionary.deserialize refuses bytes too short for the magic, a field
#      name longer than the bytes left, and stage offsets past the end; a stage
#      length of 2^63 - 1 (Int.MAX), whose sum with an in-range offset wraps
#      Int negative, is refused by the same check, for stage a and stage b
#      (komira-ai/komira#1203).
#   8. lookup_info returns the term's row for a present term, None for an
#      absent one.
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
    SortedBlockTermMap,
    MAX_TERM_LEN,
)


def _af(terms: List[String]) -> AnalyzedField:
    var toks = List[Token]()
    for i in range(len(terms)):
        toks.append(Token(terms[i], i))
    return AnalyzedField(toks^)


def _fi(terms: List[String]) raises -> FinalizedIndex:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af(terms))
    return b.finalize()


def _u64(mut out: List[UInt8], v: UInt64):
    for i in range(8):
        out.append(UInt8((v >> UInt64(8 * i)) & 0xFF))


def _u32(mut out: List[UInt8], v: UInt32):
    for i in range(4):
        out.append(UInt8((v >> UInt32(8 * i)) & 0xFF))


def test_01_finalized_accessors_refuse_out_of_range() raises:
    var fi = _fi([String("alpha"), String("beta")])
    assert_equal(fi.num_terms(), 2, "1: two terms")
    for bad in [-1, 2]:
        with assert_raises(contains="term_bytes_at: ordinal out of range [0, 2)"):
            _ = fi.term_bytes_at(bad)
        with assert_raises(contains="doc_freq_at: ordinal out of range [0, 2)"):
            _ = fi.doc_freq_at(bad)
        with assert_raises(
            contains="posting_doc_ids_at: ordinal out of range [0, 2)"
        ):
            _ = fi.posting_doc_ids_at(bad)
        with assert_raises(contains="posting_tfs_at: ordinal out of range [0, 2)"):
            _ = fi.posting_tfs_at(bad)
    # The last valid ordinal still answers.
    assert_equal(fi.doc_freq_at(1), 1, "1: ordinal 1 answers")


def test_02_same_hash_different_terms_stay_distinct() raises:
    var b = InvertedIndexBuilder.create("body")
    var h = UInt64(0xABCD_0000_0000_0005)
    var t_ab: List[UInt8] = [0x61, 0x62]  # "ab"
    var t_abc: List[UInt8] = [0x61, 0x62, 0x63]  # "abc": other length
    var t_xy: List[UInt8] = [0x78, 0x79]  # "xy": same length, other bytes
    var id_ab = b._find_or_insert(h, Span(t_ab))
    var id_abc = b._find_or_insert(h, Span(t_abc))
    var id_xy = b._find_or_insert(h, Span(t_xy))
    assert_equal(id_ab, 0, "2: ab first")
    assert_equal(id_abc, 1, "2: abc is a new term (length differs)")
    assert_equal(id_xy, 2, "2: xy is a new term (bytes differ)")
    assert_equal(b.num_terms(), 3, "2: three terms")
    # Each is found again under the shared hash, past the others' slots.
    assert_equal(b._find_or_insert(h, Span(t_xy)), 2, "2: xy again")
    assert_equal(b._find_or_insert(h, Span(t_abc)), 1, "2: abc again")
    assert_equal(b._find_or_insert(h, Span(t_ab)), 0, "2: ab again")
    assert_equal(b.num_terms(), 3, "2: still three terms")


def test_03_create_with_capacity_large_hint() raises:
    var b = InvertedIndexBuilder.create_with_capacity("body", 1000, 4000)
    # 1000 * 3 / 2 = 1500 -> the directory doubles from 64 to 2048.
    assert_equal(b._dir_cap, 2048, "3: directory rounded up to 2048")
    var words = List[String]()
    for i in range(50):
        words.append(String("w") + String(i))
    b.add_document(0, _af(words))
    var fi = b.finalize()
    assert_equal(fi.num_terms(), 50, "3: all 50 terms indexed")


def test_04_stage_a_refusals() raises:
    var d = TermDictBuilder.build_from_finalized(_fi([String("one")]))
    with assert_raises(contains="_first_term_at: block 1 out of range [0, 1)"):
        _ = d._stage_a._first_term_at(1)
    with assert_raises(contains="_first_term_at: block -1 out of range"):
        _ = d._stage_a._first_term_at(-1)
    with assert_raises(contains="decoded length suffix=5 out of bounds [0, 4]"):
        d._stage_a._check_len(5, 4, String("suffix"))
    with assert_raises(contains="decoded length suffix=-1 out of bounds"):
        d._stage_a._check_len(-1, 4, String("suffix"))
    d._stage_a._check_len(4, 4, String("suffix"))  # the bound itself is valid
    with assert_raises(contains="exceeds MAX_TERM_LEN"):
        d._stage_a._check_term_len(MAX_TERM_LEN + 1)
    d._stage_a._check_term_len(MAX_TERM_LEN)  # the cap itself is valid


def _stage_a_deser(var bytes: List[UInt8]) raises:
    var cur = ByteBuffer(bytes^)
    _ = SortedBlockTermMap.deserialize(cur)


def test_05_stage_a_deserialize_refusals() raises:
    # Negative block count (u64 with the top bit set).
    var neg = List[UInt8]()
    _u64(neg, UInt64(0xFFFF_FFFF_FFFF_FFFF))
    _u64(neg, 0)
    with assert_raises(contains="deserialize: negative count"):
        _stage_a_deser(neg^)
    var neg_t = List[UInt8]()
    _u64(neg_t, 0)
    _u64(neg_t, UInt64(0xFFFF_FFFF_FFFF_FFFF))
    with assert_raises(contains="deserialize: negative count"):
        _stage_a_deser(neg_t^)
    # Offset table (num_blocks + 1 = 3 entries = 24 bytes) past 16 bytes left.
    var off_t = List[UInt8]()
    _u64(off_t, 2)
    _u64(off_t, 2)
    _u64(off_t, 0)
    _u64(off_t, 0)
    with assert_raises(contains="block_offset table exceeds remaining bytes"):
        _stage_a_deser(off_t^)
    # Offset table fits (2 entries) but the count table (1 entry) does not.
    var cnt_t = List[UInt8]()
    _u64(cnt_t, 1)
    _u64(cnt_t, 1)
    _u64(cnt_t, 0)
    _u64(cnt_t, 0)
    cnt_t.append(0)
    with assert_raises(contains="block_count table"):
        _stage_a_deser(cnt_t^)
    # A first-term length (ULEB 5) past the 2 bytes left.
    var fl = List[UInt8]()
    _u64(fl, 1)
    _u64(fl, 1)
    _u64(fl, 0)
    _u64(fl, 0)
    _u64(fl, 1)
    write_uleb128(5, fl)
    fl.append(0x61)
    fl.append(0x62)
    with assert_raises(contains="first_len 5 out of bounds"):
        _stage_a_deser(fl^)
    # A first-term length past MAX_TERM_LEN, with that many bytes present.
    var big = List[UInt8]()
    _u64(big, 1)
    _u64(big, 1)
    _u64(big, 0)
    _u64(big, 0)
    _u64(big, 1)
    write_uleb128(MAX_TERM_LEN + 1, big)
    for _ in range(MAX_TERM_LEN + 1):
        big.append(0x61)
    with assert_raises(contains="first-term length 65537 exceeds MAX_TERM_LEN"):
        _stage_a_deser(big^)


def test_06_term_info_store_refusals() raises:
    var d = TermDictBuilder.build_from_finalized(_fi([String("one")]))
    with assert_raises(contains="TermInfoStore.get: ordinal 1 out of range [0, 1)"):
        _ = d.term_info_at(1)
    with assert_raises(contains="TermInfoStore.get: ordinal -1 out of range"):
        _ = d.term_info_at(-1)
    var empty = ByteBuffer(List[UInt8]())
    with assert_raises(contains="negative num_terms"):
        _ = TermInfoStore.deserialize(empty, -1)
    # Two rows are 48 bytes; 47 are present.
    var short = List[UInt8]()
    for _ in range(47):
        short.append(0)
    var cur = ByteBuffer(short^)
    with assert_raises(contains="store region (48 bytes) exceeds remaining"):
        _ = TermInfoStore.deserialize(cur, 2)
    # Exactly 48 bytes is enough.
    var exact = List[UInt8]()
    for _ in range(48):
        exact.append(0)
    var cur2 = ByteBuffer(exact^)
    assert_equal(TermInfoStore.deserialize(cur2, 2).num_terms(), 2, "6: fits")


def _header(fname_len: UInt32) -> List[UInt8]:
    var out = List[UInt8]()
    for c in "STDICT".as_bytes():
        out.append(c)
    out.append(1)  # version
    out.append(0)  # flags
    _u32(out, fname_len)
    return out^


def test_07_term_dictionary_deserialize_refusals() raises:
    var short: List[UInt8] = [0x53, 0x54, 0x44, 0x49, 0x43]  # "STDIC"
    with assert_raises(contains="too short for magic"):
        _ = TermDictionary.deserialize(short^)
    # A field name of 10 bytes with 2 left.
    var fname = _header(10)
    fname.append(0x62)
    fname.append(0x6F)
    with assert_raises(contains="field_name_len 10 out of bounds"):
        _ = TermDictionary.deserialize(fname^)
    # Stage a past the end: the offsets table names [44, 44 + 100).
    var stages = _header(0)
    _u64(stages, 44)
    _u64(stages, 100)
    _u64(stages, 44)
    _u64(stages, 0)
    with assert_raises(contains="stage offsets/lengths out of bounds"):
        _ = TermDictionary.deserialize(stages^)
    # Stage b past the end (stage a empty and in range).
    var stage_b = _header(0)
    _u64(stage_b, 44)
    _u64(stage_b, 0)
    _u64(stage_b, 44)
    _u64(stage_b, 24)
    with assert_raises(contains="stage offsets/lengths out of bounds"):
        _ = TermDictionary.deserialize(stage_b^)


def test_07b_wrapping_stage_lengths_refused() raises:
    comptime MAX = UInt64(0x7FFF_FFFF_FFFF_FFFF)
    var stage_a = _header(0)
    _u64(stage_a, 44)
    _u64(stage_a, MAX)
    _u64(stage_a, 44)
    _u64(stage_a, 0)
    with assert_raises(contains="stage offsets/lengths out of bounds"):
        _ = TermDictionary.deserialize(stage_a^)
    var stage_b = _header(0)
    _u64(stage_b, 44)
    _u64(stage_b, 0)
    _u64(stage_b, 44)
    _u64(stage_b, MAX)
    with assert_raises(contains="stage offsets/lengths out of bounds"):
        _ = TermDictionary.deserialize(stage_b^)
    # Stage b one byte past the end: [44, 45) of 44 bytes.
    var one = _header(0)
    _u64(one, 44)
    _u64(one, 0)
    _u64(one, 44)
    _u64(one, 1)
    with assert_raises(contains="stage offsets/lengths out of bounds"):
        _ = TermDictionary.deserialize(one^)


def test_08_lookup_info() raises:
    var fi = _fi([String("beta"), String("alpha"), String("beta")])
    var d = TermDictBuilder.build_from_finalized(fi)
    var beta: List[UInt8] = [0x62, 0x65, 0x74, 0x61]
    var info = d.lookup_info(Span(beta))
    assert_true(Bool(info), "8: beta present")
    assert_equal(info.value().doc_freq, 1, "8: beta df 1")
    var gamma: List[UInt8] = [0x67, 0x61, 0x6D]
    assert_false(Bool(d.lookup_info(Span(gamma))), "8: gam absent")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

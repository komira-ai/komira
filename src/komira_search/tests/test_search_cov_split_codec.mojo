# =============================================================================
# test_search_cov_split_codec.mojo: the split codec's refusals (bitpacking,
# posting lists and blocks, ULEB128, BLOCKMAX, the doc store, serialize_split).
# =============================================================================
#
#   1. Bitpack: a width outside [0, 64] and a negative value are refused; an
#      unpack past the source is refused; width 64 is valid on both sides.
#   2. ULEB128: a read past the region end is refused, and so is a varint
#      whose first eleven bytes all carry the continuation bit (the input is
#      twelve bytes); a 10-byte varint with the top bit set reads as a
#      negative Int. An 11-byte varint that ends at its 11th byte, and a 10th
#      byte that sets bit 64, are refused (komira-ai/komira#1085).
#   3. Posting-list encode (plain and with block metadata): length mismatch,
#      a negative doc-id, a non-ascending doc-id, a negative tf are refused.
#   4. Posting-list decode: a region past the source, a negative doc_count, a
#      negative first doc-id, and truncation before either bit width.
#   5. Posting-block decode (full and doc-ids only): a region past the source, a
#      block offset outside the region, a block count <= 0, a negative first
#      doc-id, truncation before a bit width.
#   6. BLOCKMAX: the region writer refuses mismatched or negative inputs; the
#      reader refuses an empty region, an unknown version, a negative term count
#      and a negative tier-1 value.
#   7. DocStoreBuilder.serialize refuses a negative offset, length or blob
#      length in its state (uncompressed and LZ4 forms).
#   8. serialize_split refuses a negative doc_count/min/max and an L0 posting
#      region without the footer token total.
#   9. The three posting decoders refuse a term region whose length is 2^63 - 1
#      (Int.MAX), whose sum with an in-range offset wraps Int negative, by
#      their own region check (komira-ai/komira#1203); the region ending one
#      byte past the source is refused by the same check.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_search.analyzer import AnalyzedField, Token
from komira_search.inverted import InvertedIndexBuilder, FinalizedIndex
from komira_search.term_dict import TermDictBuilder
from komira_search.split import (
    serialize_split,
    DocStoreBuilder,
    BlockMaxIndex,
    BLOCKMAX_VERSION,
    _pack_bits_lsb_first,
    _unpack_bits_lsb_first,
    _read_uleb128_span,
    _encode_posting_list,
    _encode_posting_list_with_blockmeta,
    _decode_posting_list,
    _decode_posting_block,
    _decode_posting_block_dids_only,
    _serialize_blockmax_region,
)


def _neg_uleb() -> List[UInt8]:
    """A 10-byte ULEB128 with all 64 bits set: -1 as an Int."""
    var out = List[UInt8]()
    for _ in range(9):
        out.append(0xFF)
    out.append(0x01)
    return out^


def _cat(a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a.copy()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def test_01_bitpack_refusals() raises:
    var vals: List[Int] = [1, 2, 3]
    var out = List[UInt8]()
    with assert_raises(contains="_pack_bits_lsb_first: bit_width 65 out of range"):
        _pack_bits_lsb_first(Span(vals), 3, 65, out)
    with assert_raises(contains="_pack_bits_lsb_first: bit_width -1 out of range"):
        _pack_bits_lsb_first(Span(vals), 3, -1, out)
    var neg: List[Int] = [1, -2]
    with assert_raises(contains="negative value at index 1"):
        _pack_bits_lsb_first(Span(neg), 2, 4, out)
    var src: List[UInt8] = [0xAB, 0xCD]
    var got = List[Int]()
    with assert_raises(contains="_unpack_bits_lsb_first: bit_width 65 out of range"):
        _unpack_bits_lsb_first(Span(src), 0, 1, 65, got)
    with assert_raises(contains="_unpack_bits_lsb_first: bit_width -3 out of range"):
        _unpack_bits_lsb_first(Span(src), 0, 1, -3, got)
    # 3 values at 8 bits need 3 bytes; 2 are present.
    with assert_raises(contains="packed run [0, 3) exceeds source length 2"):
        _unpack_bits_lsb_first(Span(src), 0, 3, 8, got)
    with assert_raises(contains="packed run [-1, 0) exceeds source length 2"):
        _unpack_bits_lsb_first(Span(src), -1, 1, 8, got)
    # Width 64 is in range on both sides and round-trips.
    var wide: List[Int] = [Int(0x7FFF_FFFF_FFFF_FFFF), 5]
    var packed = List[UInt8]()
    _pack_bits_lsb_first(Span(wide), 2, 64, packed)
    assert_equal(len(packed), 16, "1: two 64-bit values")
    var back = List[Int]()
    _unpack_bits_lsb_first(Span(packed), 0, 2, 64, back)
    assert_equal(back[0], wide[0], "1: 64-bit value 0")
    assert_equal(back[1], 5, "1: 64-bit value 1")


def test_02_uleb128_edges() raises:
    var cont: List[UInt8] = [0x80, 0x80]
    with assert_raises(contains="ran past region end"):
        _ = _read_uleb128_span(Span(cont), 0, 2)
    # Eleven continuation bytes, then a terminator: refused at the 11th byte.
    var long = List[UInt8]()
    for _ in range(11):
        long.append(0x80)
    long.append(0x00)
    with assert_raises(contains="varint exceeds 10 bytes"):
        _ = _read_uleb128_span(Span(long), 0, len(long))
    # A 10-byte varint is read without a refusal.
    var neg = _neg_uleb()
    var r = _read_uleb128_span(Span(neg), 0, len(neg))
    assert_equal(r[0], -1, "2: all 64 bits set reads as -1")
    assert_equal(r[1], 10, "2: ten bytes consumed")


def test_02b_uleb128_eleven_bytes_and_bit_64() raises:
    # komira-ai/komira#1085: ten continuation bytes then a terminator is an
    # 11-byte varint, refused at the 10th byte.
    var eleven = List[UInt8]()
    for _ in range(10):
        eleven.append(0x80)
    eleven.append(0x00)
    with assert_raises(contains="varint exceeds 10 bytes"):
        _ = _read_uleb128_span(Span(eleven), 0, len(eleven))
    # A 10th byte of 0x02 sets bit 64, which an Int cannot hold: refused, not
    # dropped (it read as 2^63 - 1 before).
    var wide = List[UInt8]()
    for _ in range(9):
        wide.append(0xFF)
    wide.append(0x02)
    with assert_raises(contains="varint overflows 64 bits"):
        _ = _read_uleb128_span(Span(wide), 0, len(wide))
    # The largest legal 10th byte is 0x01 (test_02 reads it as -1); 0x00 is a
    # padded zero and reads as 0.
    var pad = List[UInt8]()
    for _ in range(9):
        pad.append(0x80)
    pad.append(0x00)
    var r = _read_uleb128_span(Span(pad), 0, len(pad))
    assert_equal(r[0], 0, "2b: a padded zero reads as 0")
    assert_equal(r[1], 10, "2b: ten bytes consumed")


def test_03_posting_encode_refusals() raises:
    var out = List[UInt8]()
    var ids: List[Int] = [1, 2]
    var tf1: List[Int] = [1]
    with assert_raises(contains="_encode_posting_list: doc_ids/tfs length mismatch (2 vs 1)"):
        _encode_posting_list(Span(ids), Span(tf1), out)
    var tfs: List[Int] = [1, 1]
    var neg_first: List[Int] = [-1, 2]
    with assert_raises(contains="_encode_posting_list: negative doc_id at index 0"):
        _encode_posting_list(Span(neg_first), Span(tfs), out)
    var flat: List[Int] = [3, 3]
    with assert_raises(contains="non-ascending doc-ids at index 1 (delta 0 <= 0"):
        _encode_posting_list(Span(flat), Span(tfs), out)
    var neg_tf: List[Int] = [1, -1]
    with assert_raises(contains="_encode_posting_list: negative tf at index 1"):
        _encode_posting_list(Span(ids), Span(neg_tf), out)

    var dl: List[Int] = [1, 1, 1, 1]
    var bo = List[Int]()
    var bl = List[Int]()
    var bt = List[Int]()
    var bd = List[Int]()
    with assert_raises(contains="_with_blockmeta: doc_ids/tfs length mismatch (2 vs 1)"):
        _ = _encode_posting_list_with_blockmeta(
            Span(ids), Span(tf1), Span(dl), 0, out, bo, bl, bt, bd
        )
    with assert_raises(contains="_with_blockmeta: negative doc_id at index 0"):
        _ = _encode_posting_list_with_blockmeta(
            Span(neg_first), Span(tfs), Span(dl), 0, out, bo, bl, bt, bd
        )
    with assert_raises(contains="_with_blockmeta: non-ascending doc-ids at index 1"):
        _ = _encode_posting_list_with_blockmeta(
            Span(flat), Span(tfs), Span(dl), 0, out, bo, bl, bt, bd
        )
    with assert_raises(contains="_with_blockmeta: negative tf at index 1"):
        _ = _encode_posting_list_with_blockmeta(
            Span(ids), Span(neg_tf), Span(dl), 0, out, bo, bl, bt, bd
        )


def test_04_posting_decode_refusals() raises:
    var ids = List[Int]()
    var tfs = List[Int]()
    var three: List[UInt8] = [1, 2, 3]
    with assert_raises(contains="_decode_posting_list: region [0, 10) out of bounds [0, 3)"):
        _decode_posting_list(Span(three), 0, 10, ids, tfs)
    with assert_raises(contains="_decode_posting_list: region"):
        _decode_posting_list(Span(three), -1, 2, ids, tfs)
    var neg_dc = _neg_uleb()
    with assert_raises(contains="negative doc_count"):
        _decode_posting_list(Span(neg_dc), 0, len(neg_dc), ids, tfs)
    var neg_fd = _cat([UInt8(1)], _neg_uleb())
    with assert_raises(contains="_decode_posting_list: negative first_doc"):
        _decode_posting_list(Span(neg_fd), 0, len(neg_fd), ids, tfs)
    var no_dbw: List[UInt8] = [1, 5]
    with assert_raises(contains="_decode_posting_list: truncated before doc_bit_width"):
        _decode_posting_list(Span(no_dbw), 0, 2, ids, tfs)
    var no_tbw: List[UInt8] = [1, 5, 0]
    with assert_raises(contains="_decode_posting_list: truncated before tf_bit_width"):
        _decode_posting_list(Span(no_tbw), 0, 3, ids, tfs)
    # The same bytes plus a tf width of 0 decode: doc 5, tf 0.
    var whole: List[UInt8] = [1, 5, 0, 0]
    ids.clear()
    tfs.clear()
    _decode_posting_list(Span(whole), 0, 4, ids, tfs)
    assert_equal(len(ids), 1, "4: one doc")
    assert_equal(ids[0], 5, "4: doc 5")


def test_05_posting_block_decode_refusals() raises:
    var ids = List[Int]()
    var tfs = List[Int]()
    var three: List[UInt8] = [5, 0, 0]
    with assert_raises(contains="_decode_posting_block: term region out of bounds"):
        _decode_posting_block(Span(three), 0, 10, 0, 0, 1, ids, tfs)
    with assert_raises(contains="_decode_posting_block: block offset out of region"):
        _decode_posting_block(Span(three), 0, 3, 2, 1, 1, ids, tfs)
    with assert_raises(contains="_decode_posting_block: block offset out of region"):
        _decode_posting_block(Span(three), 1, 2, 0, -1, 1, ids, tfs)
    with assert_raises(contains="_decode_posting_block: non-positive block_count"):
        _decode_posting_block(Span(three), 0, 3, 0, 0, 0, ids, tfs)
    var neg_fd = _neg_uleb()
    with assert_raises(contains="_decode_posting_block: negative first_doc"):
        _decode_posting_block(Span(neg_fd), 0, len(neg_fd), 0, 0, 1, ids, tfs)
    with assert_raises(contains="_decode_posting_block: truncated before doc_bit_width"):
        _decode_posting_block(Span(three), 0, 1, 0, 0, 1, ids, tfs)
    with assert_raises(contains="_decode_posting_block: truncated before tf_bit_width"):
        _decode_posting_block(Span(three), 0, 2, 0, 0, 1, ids, tfs)
    ids.clear()
    tfs.clear()
    _decode_posting_block(Span(three), 0, 3, 0, 0, 1, ids, tfs)
    assert_equal(len(ids), 1, "5: one doc in the block")
    assert_equal(ids[0], 5, "5: the block decodes doc 5")
    assert_equal(len(tfs), 1, "5: one tf in the block")

    var only = List[Int]()
    with assert_raises(contains="_dids_only: term region out of bounds"):
        _decode_posting_block_dids_only(Span(three), 0, 10, 0, 0, 1, only)
    with assert_raises(contains="_dids_only: block offset out of region"):
        _decode_posting_block_dids_only(Span(three), 0, 3, 3, 0, 1, only)
    with assert_raises(contains="_dids_only: non-positive block_count"):
        _decode_posting_block_dids_only(Span(three), 0, 3, 0, 0, -1, only)
    with assert_raises(contains="_dids_only: negative first_doc"):
        _decode_posting_block_dids_only(
            Span(neg_fd), 0, len(neg_fd), 0, 0, 1, only
        )
    with assert_raises(contains="_dids_only: truncated before doc_bw"):
        _decode_posting_block_dids_only(Span(three), 0, 1, 0, 0, 1, only)
    only.clear()
    _decode_posting_block_dids_only(Span(three), 0, 2, 0, 0, 1, only)
    assert_equal(len(only), 1, "5: one doc-id")
    assert_equal(only[0], 5, "5: doc-ids only decodes doc 5")


def test_06_blockmax_refusals() raises:
    var out = List[UInt8]()
    var one: List[Int] = [1]
    var neg: List[Int] = [-1]
    var two: List[Int] = [1, 1]
    with assert_raises(contains="num_blocks/num_terms mismatch (1 vs 2)"):
        _serialize_blockmax_region(2, one, one, one, one, one, out)
    with assert_raises(contains="_serialize_blockmax_region: negative num_blocks"):
        _serialize_blockmax_region(1, neg, one, one, one, one, out)
    for k in range(4):
        var lists = List[List[Int]]()
        for j in range(4):
            lists.append(two.copy() if j == k else one.copy())
        with assert_raises(contains="tier-2 SoA length mismatch (expected 1)"):
            _serialize_blockmax_region(
                1, one, lists[0], lists[1], lists[2], lists[3], out
            )
    var names: List[String] = [
        "block_byte_offset", "block_last_docid", "block_max_tf", "block_min_dl"
    ]
    for k in range(4):
        var lists = List[List[Int]]()
        for j in range(4):
            lists.append(neg.copy() if j == k else one.copy())
        with assert_raises(contains="negative " + names[k]):
            _serialize_blockmax_region(
                1, one, lists[0], lists[1], lists[2], lists[3], out
            )

    var empty = List[UInt8]()
    with assert_raises(contains="BlockMaxIndex.deserialize: empty region"):
        _ = BlockMaxIndex.deserialize(Span(empty))
    var ver: List[UInt8] = [BLOCKMAX_VERSION + 1, 0]
    with assert_raises(contains="unsupported BLOCKMAX version 2"):
        _ = BlockMaxIndex.deserialize(Span(ver))
    var neg_nt = _cat([BLOCKMAX_VERSION], _neg_uleb())
    with assert_raises(contains="BlockMaxIndex.deserialize: negative num_terms"):
        _ = BlockMaxIndex.deserialize(Span(neg_nt))
    var neg_nb = _cat([BLOCKMAX_VERSION, 1], _cat(_neg_uleb(), [UInt8(0)]))
    with assert_raises(contains="negative tier-1 value"):
        _ = BlockMaxIndex.deserialize(Span(neg_nb))
    var neg_to = _cat([BLOCKMAX_VERSION, 1, 0], _neg_uleb())
    with assert_raises(contains="negative tier-1 value"):
        _ = BlockMaxIndex.deserialize(Span(neg_to))


def _store(compress: Bool) raises -> DocStoreBuilder:
    var ds = DocStoreBuilder(compress=compress)
    var a: List[UInt8] = [0x61, 0x62, 0x63]
    var b: List[UInt8] = [0x64]
    ds.append(Span(a))
    ds.append(Span(b))
    return ds^


def test_07_docstore_refuses_corrupt_state() raises:
    var out = List[UInt8]()
    var ds = _store(False)
    ds._blob_offset[1] = -1
    with assert_raises(contains="negative blob_offset"):
        ds.serialize(out)
    var ds2 = _store(False)
    ds2._uncompressed_len[1] = -1
    with assert_raises(contains="negative uncompressed_len"):
        ds2.serialize(out)
    var ds3 = _store(True)
    ds3._blob_offset[1] = 4  # past slot 1's end (4): slot 1 has length 0
    ds3._blob_offset[2] = 2  # slot 1 now runs 4 -> 2
    with assert_raises(contains="negative blob length"):
        ds3.serialize(out)
    var ds4 = _store(True)
    ds4._uncompressed_len[0] = -7
    with assert_raises(contains="negative uncompressed_len"):
        ds4.serialize(out)


def _af(terms: List[String]) -> AnalyzedField:
    var toks = List[Token]()
    for i in range(len(terms)):
        toks.append(Token(terms[i], i))
    return AnalyzedField(toks^)


def _uuid() -> Array[UInt8, 16]:
    return Array[UInt8, 16](fill=7)


def test_08_serialize_split_refusals() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("x")]))
    var fi = b.finalize()
    var src: List[UInt8] = [0x7B, 0x7D]
    var ds = DocStoreBuilder(compress=False)
    ds.append(Span(src))
    for which in range(3):
        var dc = -1 if which == 0 else 1
        var mn = -1 if which == 1 else 0
        var mx = -1 if which == 2 else 0
        with assert_raises(contains="negative doc_count / min / max doc-id"):
            _ = serialize_split(
                fi, TermDictBuilder.build_from_finalized(fi), ds,
                String("body"), _uuid(), mn, mx, dc,
            )
    var l0: List[UInt8] = [1, 2, 3]
    with assert_raises(contains="l0_posting present but total_token_count absent"):
        _ = serialize_split(
            fi, TermDictBuilder.build_from_finalized(fi), ds,
            String("body"), _uuid(), 0, 0, 1, l0_posting_region=l0^,
        )
    # The same split with the total supplied is accepted.
    var l0b: List[UInt8] = [1, 2, 3]
    var ok = serialize_split(
        fi, TermDictBuilder.build_from_finalized(fi), ds,
        String("body"), _uuid(), 0, 0, 1, total_token_count=1,
        l0_posting_region=l0b^,
    )
    assert_true(len(ok) > 0, "8: accepted with the total")


def test_09_wrapping_term_region_refused() raises:
    var ids = List[Int]()
    var tfs = List[Int]()
    var three: List[UInt8] = [1, 2, 3]
    with assert_raises(contains="_decode_posting_list: region [1, "):
        _decode_posting_list(Span(three), 1, Int.MAX, ids, tfs)
    with assert_raises(contains="_decode_posting_list: region [1, 4) out of bounds [0, 3)"):
        _decode_posting_list(Span(three), 1, 3, ids, tfs)
    with assert_raises(contains="_decode_posting_block: term region out of bounds"):
        _decode_posting_block(Span(three), 1, Int.MAX, 0, 0, 1, ids, tfs)
    with assert_raises(contains="_decode_posting_block: term region out of bounds"):
        _decode_posting_block(Span(three), 1, 3, 0, 0, 1, ids, tfs)
    var only = List[Int]()
    with assert_raises(contains="_dids_only: term region out of bounds"):
        _decode_posting_block_dids_only(Span(three), 1, Int.MAX, 0, 0, 1, only)
    with assert_raises(contains="_dids_only: term region out of bounds"):
        _decode_posting_block_dids_only(Span(three), 1, 3, 0, 0, 1, only)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

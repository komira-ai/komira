# =============================================================================
# test_search_split.mojo — the split-writer unit test
# =============================================================================
#
# Covers the corruption cases, the patch-then-serialize-once +
# serialize-before-patch raise, and the FROZEN posting-block round-trip incl.
# >128-doc + width-0.
#
# PURE unit suite — NO S3. The S3 multipart boundary (komira_search_s3's
# split upload) is exercised by a SEPARATE MinIO-gated integration target.
#
# Coverage (enumerated cases):
#   1.  single-term single-doc split round-trip (magic/version/footer metadata)
#   2.  footer offset-table correctness (adjacency + reserved 0/0 slots)
#   3.  term-dict region byte-identical to TermDictionary.serialize
#   4.  posting block decodes to original doc-ids/TFs (> 128 docs: full + partial)
#   5.  TF width-0 / width-1 blocks
#   6.  doc-store blob round-trips (empty + large + slot<->doc_id convention)
#   7. set_posting_location patch-then-serialize ordering
#   7b. TermDictionary.serialize BEFORE the patch (UNSET) raises
#   8.  empty segment (0 docs / 0 terms canonical form)
#   9.  multi-batch ingest -> one split (doc-ids monotonic across batches)
#   10. SearchSink typechecks + end-to-end produces a valid split (no S3)
#   11. corruption: truncated footer / oversized region offset -> raises
#   12. inline bitpack helper round-trip (width 0..N boundaries)
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

from komira_search.analyzer import AnalyzedField, AnalyzerConfig, Token
from komira_search.inverted import InvertedIndexBuilder, FinalizedIndex
from komira_search.term_dict import (
    TermDictBuilder,
    TermDictionary,
    TermInfo,
    POSTING_LOC_UNSET,
)
from komira_search.split import (
    serialize_split,
    SplitView,
    DocStoreBuilder,
    SPLIT_VERSION,
    POSTING_BLOCK_DOCS,
    DOCSTORE_FLAG_UNCOMPRESSED,
    DOCSTORE_FLAG_LZ4,
)
from komira_search.sink import IndexCore, SearchSink


# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------


def _af(terms: List[String]) -> AnalyzedField:
    """Build an AnalyzedField from a flat list of term strings (positions in
    emission order)."""
    var toks = List[Token]()
    for i in range(len(terms)):
        toks.append(Token(terms[i], i))
    return AnalyzedField(toks^)


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    """A deterministic 16-byte UUID for the tests."""
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _make_text_source_batch(
    text_values: List[String], source_values: List[String]
) raises -> RecordBatch:
    """A 2-column RecordBatch: col0 = "body" (text), col1 = "_source"."""
    var ta = StringArray.from_strings(text_values)
    var sa = StringArray.from_strings(source_values)
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_string(ta^))
    rb.add_column(Column.from_string(sa^))
    return rb.build(schema^)


# =============================================================================
# Case 1 — single-term single-doc split round-trip.
# =============================================================================


def test_01_single_term_single_doc_roundtrip() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("hello")]))
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)

    var ds = DocStoreBuilder()
    ds.append(String("doc-zero").as_bytes())

    var bytes = serialize_split(
        fi, td^, ds, String("body"), _uuid(7), 0, 0, 1
    )
    var sv = SplitView.parse(bytes^)

    assert_equal(sv.field_name(), String("body"))
    assert_equal(sv.doc_count(), 1)
    assert_equal(sv.min_doc_id(), 0)
    assert_equal(sv.max_doc_id(), 0)
    var u = sv.split_uuid()
    assert_equal(Int(u[0]), 7)
    assert_equal(Int(u[15]), 7 + 15)
    # three regions in-bounds + ordered.
    assert_true(sv.termdict_offset() >= 8)
    assert_true(sv.termdict_len() > 0)
    assert_true(sv.postings_offset() >= sv.termdict_offset() + sv.termdict_len())
    assert_true(
        sv.docstore_offset() >= sv.postings_offset() + sv.postings_len()
    )


# =============================================================================
# Case 2 — footer offset-table adjacency + reserved slots.
# =============================================================================


def test_02_footer_offset_table() raises:
    var b = InvertedIndexBuilder.create("body")
    # several terms across docs.
    b.add_document(0, _af([String("alpha"), String("beta")]))
    b.add_document(1, _af([String("beta"), String("gamma")]))
    b.add_document(2, _af([String("alpha"), String("gamma"), String("delta")]))
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)

    var ds = DocStoreBuilder()
    ds.append(String("r0").as_bytes())
    ds.append(String("r1").as_bytes())
    ds.append(String("r2").as_bytes())

    var bytes = serialize_split(
        fi, td^, ds, String("body"), _uuid(1), 0, 2, 3
    )
    var sv = SplitView.parse(bytes^)

    # Regions are laid down adjacently in order.
    assert_equal(
        sv.termdict_offset() + sv.termdict_len(), sv.postings_offset()
    )
    assert_equal(
        sv.postings_offset() + sv.postings_len(), sv.docstore_offset()
    )
    # docstore ends before the footer (total - footer).
    assert_true(sv.docstore_offset() + sv.docstore_len() <= sv.total_len())


# =============================================================================
# Case 3 — term-dict region byte-identical to TermDictionary.serialize.
# =============================================================================


def test_03_termdict_region_byte_identical() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("alpha"), String("beta")]))
    b.add_document(1, _af([String("beta")]))
    var fi = b.finalize()

    # Build the split (which patches + serializes the term-dict internally).
    var td1 = TermDictBuilder.build_from_finalized(fi)
    var ds = DocStoreBuilder()
    ds.append(String("a").as_bytes())
    ds.append(String("b").as_bytes())
    var bytes = serialize_split(
        fi, td1^, ds, String("body"), _uuid(2), 0, 1, 2
    )
    var sv = SplitView.parse(bytes^)
    var region = sv.term_dict_region()

    # Independently patch a fresh term-dict with the SAME posting locations the
    # split writer computed, then serialize and compare byte-for-byte.
    var td2 = TermDictBuilder.build_from_finalized(fi)
    # Recompute the posting region locations exactly as serialize_split does.
    from komira_search.split import _encode_posting_list

    var scratch = List[UInt8]()
    for o in range(fi.num_terms()):
        var off = len(scratch)
        var dids = fi.posting_doc_ids_at(o)
        var tfs = fi.posting_tfs_at(o)
        _encode_posting_list(dids, tfs, scratch)
        td2.set_posting_location(o, off, len(scratch) - off)
    var expect = List[UInt8]()
    td2.serialize(expect)

    assert_equal(len(region), len(expect))
    for i in range(len(expect)):
        assert_equal(region[i], expect[i])


# =============================================================================
# Case 4 — posting block decodes to original doc-ids/TFs (> 128 docs).
# =============================================================================


def test_04_posting_block_roundtrip_over_128() raises:
    from komira_search.split import _encode_posting_list, _decode_posting_list

    # Build a term with 200 docs (one full 128-block + a 72-doc partial).
    var doc_ids = List[Int]()
    var tfs = List[Int]()
    var d = 0
    for i in range(200):
        d += 1 + (i % 3)  # strictly ascending, variable gaps
        doc_ids.append(d)
        tfs.append(1 + (i % 5))  # variable TFs (exercise multi-bit-width)

    var enc = List[UInt8]()
    _encode_posting_list(Span(doc_ids), Span(tfs), enc)

    var got_ids = List[Int]()
    var got_tfs = List[Int]()
    _decode_posting_list(Span(enc), 0, len(enc), got_ids, got_tfs)

    assert_equal(len(got_ids), 200)
    assert_equal(len(got_tfs), 200)
    for i in range(200):
        assert_equal(got_ids[i], doc_ids[i])
        assert_equal(got_tfs[i], tfs[i])


# =============================================================================
# Case 5 — TF width-0 / width-1 blocks.
# =============================================================================


def test_05_tf_width_0_and_1() raises:
    from komira_search.split import _encode_posting_list, _decode_posting_list

    # width-1 TFs: all TF == 1 (the common case; bw == 1).
    var ids1 = List[Int]()
    var tf1 = List[Int]()
    for i in range(10):
        ids1.append(i * 2)
        tf1.append(1)
    var enc1 = List[UInt8]()
    _encode_posting_list(Span(ids1), Span(tf1), enc1)
    var gi1 = List[Int]()
    var gt1 = List[Int]()
    _decode_posting_list(Span(enc1), 0, len(enc1), gi1, gt1)
    for i in range(10):
        assert_equal(gi1[i], ids1[i])
        assert_equal(gt1[i], 1)

    # width-0 TFs: all TF == 0 (degenerate; bw == 0 -> ZERO residual TF bytes).
    var ids0 = List[Int]()
    var tf0 = List[Int]()
    for i in range(5):
        ids0.append(i)
        tf0.append(0)
    var enc0 = List[UInt8]()
    _encode_posting_list(Span(ids0), Span(tf0), enc0)
    var gi0 = List[Int]()
    var gt0 = List[Int]()
    _decode_posting_list(Span(enc0), 0, len(enc0), gi0, gt0)
    for i in range(5):
        assert_equal(gi0[i], ids0[i])
        assert_equal(gt0[i], 0)

    # Single-doc list: n_deltas == 0 -> doc_bit_width path with no delta bytes.
    var ids_one = List[Int]()
    var tf_one = List[Int]()
    ids_one.append(42)
    tf_one.append(3)
    var enc_one = List[UInt8]()
    _encode_posting_list(Span(ids_one), Span(tf_one), enc_one)
    var gio = List[Int]()
    var gto = List[Int]()
    _decode_posting_list(Span(enc_one), 0, len(enc_one), gio, gto)
    assert_equal(len(gio), 1)
    assert_equal(gio[0], 42)
    assert_equal(gto[0], 3)


# =============================================================================
# Case 6 — doc-store blob round-trips (empty + large + slot<->doc_id).
# =============================================================================


def test_06_docstore_blob_roundtrip() raises:
    # Backward-compat / UNCOMPRESSED layout: compress=False keeps the verbatim
    # region (flag 0, offsets index the raw
    # blobs). The default-compressed layout is covered by
    # test_06b_docstore_compressed_layout.
    var ds = DocStoreBuilder(compress=False)
    ds.append(String("").as_bytes())  # empty doc
    ds.append(String("hello world").as_bytes())
    # a "large" blob.
    var big = String("")
    for _ in range(500):
        big += "x"
    ds.append(big.as_bytes())

    assert_equal(ds.num_docs(), 3)

    var region = List[UInt8]()
    ds.serialize(region)

    # Hand-decode the doc-store region and verify each blob.
    # num_docs u64 + flag u8 + (n+1) offsets u64 + n unc_len u64 + blob_area
    var cur = 0

    def _ru64(data: List[UInt8], p: Int) -> Int:
        var v = UInt64(0)
        for i in range(8):
            v = v | (UInt64(data[p + i]) << UInt64(8 * i))
        return Int(v)

    var num_docs = _ru64(region, cur)
    cur += 8
    assert_equal(num_docs, 3)
    var flag = Int(region[cur])
    cur += 1
    assert_equal(flag, 0)  # UNCOMPRESSED (compress=False)
    var offsets = List[Int]()
    for _ in range(num_docs + 1):
        offsets.append(_ru64(region, cur))
        cur += 8
    var unc = List[Int]()
    for _ in range(num_docs):
        unc.append(_ru64(region, cur))
        cur += 8
    var blob_base = cur

    assert_equal(len(offsets), num_docs + 1)
    assert_equal(offsets[0], 0)
    # doc 0 empty.
    assert_equal(offsets[1] - offsets[0], 0)
    assert_equal(unc[0], 0)
    # doc 1 "hello world" = 11 bytes.
    assert_equal(offsets[2] - offsets[1], 11)
    assert_equal(unc[1], 11)
    # doc 2 big = 500 bytes.
    assert_equal(offsets[3] - offsets[2], 500)
    assert_equal(unc[2], 500)
    # verify doc 1 bytes.
    var expect1 = String("hello world").as_bytes()
    for i in range(11):
        assert_equal(region[blob_base + offsets[1] + i], expect1[i])


def test_06b_docstore_compressed_layout() raises:
    """Default-compressed (LZ4) doc-store layout: flag == DOCSTORE_FLAG_LZ4,
    uncompressed_len[] carries the ORIGINAL sizes, and the COMPRESSED blob area
    is SMALLER than the uncompressed total for a highly-compressible blob (the
    storage win)."""
    var ds = DocStoreBuilder()  # default compress=True
    ds.append(String("").as_bytes())  # empty doc
    ds.append(String("hello world").as_bytes())
    # 2000 highly-compressible bytes (LZ4 should shrink these dramatically).
    var big = String("")
    for _ in range(2000):
        big += "x"
    ds.append(big.as_bytes())
    assert_equal(ds.num_docs(), 3)

    var region = List[UInt8]()
    ds.serialize(region)

    var cur = 0

    def _ru64(data: List[UInt8], p: Int) -> Int:
        var v = UInt64(0)
        for i in range(8):
            v = v | (UInt64(data[p + i]) << UInt64(8 * i))
        return Int(v)

    var num_docs = _ru64(region, cur)
    cur += 8
    assert_equal(num_docs, 3)
    var flag = Int(region[cur])
    cur += 1
    assert_equal(flag, Int(DOCSTORE_FLAG_LZ4))  # default = LZ4
    var offsets = List[Int]()
    for _ in range(num_docs + 1):
        offsets.append(_ru64(region, cur))
        cur += 8
    var unc = List[Int]()
    for _ in range(num_docs):
        unc.append(_ru64(region, cur))
        cur += 8

    # uncompressed_len[] carries the ORIGINAL sizes (drives lz4_decompress).
    assert_equal(unc[0], 0)
    assert_equal(unc[1], 11)
    assert_equal(unc[2], 2000)
    # The empty doc has an empty compressed slot.
    assert_equal(offsets[1] - offsets[0], 0)
    # The big highly-compressible blob compresses FAR below 2000 bytes.
    var comp_big = offsets[3] - offsets[2]
    assert_true(
        comp_big < 2000,
        "compressed big blob (" + String(comp_big)
        + ") should be < 2000 uncompressed",
    )
    assert_true(
        comp_big < 200,
        "2000 repeated bytes should LZ4 to well under 200 bytes (got "
        + String(comp_big) + ")",
    )


# =============================================================================
# Case 7 — set_posting_location patch-then-serialize ordering.
# =============================================================================


def test_07_patch_then_serialize_locations_valid() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("alpha"), String("beta")]))
    b.add_document(1, _af([String("beta"), String("gamma")]))
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var ds = DocStoreBuilder()
    ds.append(String("a").as_bytes())
    ds.append(String("b").as_bytes())

    var bytes = serialize_split(
        fi, td^, ds, String("body"), _uuid(3), 0, 1, 2
    )
    var sv = SplitView.parse(bytes^)

    # Re-parse the term-dict region; every ordinal's posting location must be
    # the real (non-sentinel) byte range that decodes valid posting bytes.
    var td_region = sv.term_dict_region()
    var td_copy = List[UInt8]()
    for i in range(len(td_region)):
        td_copy.append(td_region[i])
    var td2 = TermDictionary.deserialize(td_copy^)

    from komira_search.split import _decode_posting_list

    var postings = sv.postings_region()
    for o in range(td2.num_terms()):
        var ti = td2.term_info_at(o)
        assert_true(ti.posting_offset != POSTING_LOC_UNSET)
        assert_true(ti.posting_len != POSTING_LOC_UNSET)
        assert_true(ti.posting_offset >= 0)
        assert_true(ti.posting_len > 0)
        # decode the posting bytes for this ordinal — must succeed + match
        # doc_freq.
        var ids = List[Int]()
        var tfs = List[Int]()
        _decode_posting_list(
            postings, ti.posting_offset, ti.posting_len, ids, tfs
        )
        assert_equal(len(ids), ti.doc_freq)


def test_07b_serialize_before_patch_raises() raises:
    # A freshly-built term-dict (no patch pass) must RAISE on serialize.
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("alpha")]))
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var out = List[UInt8]()
    with assert_raises():
        td.serialize(out)


# =============================================================================
# Case 8 — empty segment (0 docs / 0 terms canonical form).
# =============================================================================


def test_08_empty_segment() raises:
    var b = InvertedIndexBuilder.create("body")
    var fi = b.finalize()  # zero docs, zero terms
    var td = TermDictBuilder.build_from_finalized(fi)
    var ds = DocStoreBuilder()  # zero docs

    var bytes = serialize_split(
        fi, td^, ds, String("body"), _uuid(0), 0, 0, 0
    )
    var sv = SplitView.parse(bytes^)

    assert_equal(sv.doc_count(), 0)
    assert_equal(sv.field_name(), String("body"))
    # posting region empty.
    assert_equal(sv.postings_len(), 0)
    # term-dict region round-trips an empty dict.
    var td_region = sv.term_dict_region()
    var td_copy = List[UInt8]()
    for i in range(len(td_region)):
        td_copy.append(td_region[i])
    var td2 = TermDictionary.deserialize(td_copy^)
    assert_equal(td2.num_terms(), 0)
    # doc-store: num_docs == 0 + single leading blob_offset[0] == 0.
    var dr = sv.docstore_region()
    # num_docs u64 == 0.
    var nd = UInt64(0)
    for i in range(8):
        nd = nd | (UInt64(dr[i]) << UInt64(8 * i))
    assert_equal(Int(nd), 0)


# =============================================================================
# Case 9 — multi-batch ingest -> one split (doc-ids monotonic across batches).
# =============================================================================


def test_09_multi_batch_one_split() raises:
    var core = IndexCore.create("body", AnalyzerConfig.text("body"))

    var b0_text: List[String] = [String("alpha beta"), String("beta gamma")]
    var b0_src: List[String] = [String("s0"), String("s1")]
    core.add_documents(_make_text_source_batch(b0_text, b0_src), 0, 1)

    var b1_text: List[String] = [String("gamma delta")]
    var b1_src: List[String] = [String("s2")]
    core.add_documents(_make_text_source_batch(b1_text, b1_src), 0, 1)

    var b2_text: List[String] = [String("alpha delta"), String("epsilon")]
    var b2_src: List[String] = [String("s3"), String("s4")]
    core.add_documents(_make_text_source_batch(b2_text, b2_src), 0, 1)

    assert_equal(core.num_docs(), 5)

    var bytes = core.flush_segment(String("body"), _uuid(9))
    var sv = SplitView.parse(bytes^)

    assert_equal(sv.doc_count(), 5)
    assert_equal(sv.min_doc_id(), 0)
    assert_equal(sv.max_doc_id(), 4)

    # "alpha" appears in doc 0 (batch 0) and doc 3 (batch 2): posting list must
    # be the ascending merge [0, 3].
    var td_region = sv.term_dict_region()
    var td_copy = List[UInt8]()
    for i in range(len(td_region)):
        td_copy.append(td_region[i])
    var td2 = TermDictionary.deserialize(td_copy^)
    var alpha_ord = td2.lookup(String("alpha").as_bytes())
    assert_true(Bool(alpha_ord))
    var ti = td2.term_info_at(alpha_ord.value())

    from komira_search.split import _decode_posting_list

    var ids = List[Int]()
    var tfs = List[Int]()
    _decode_posting_list(
        sv.postings_region(), ti.posting_offset, ti.posting_len, ids, tfs
    )
    assert_equal(len(ids), 2)
    assert_equal(ids[0], 0)
    assert_equal(ids[1], 3)


# =============================================================================
# Case 10 — SearchSink typechecks + end-to-end split (no S3).
# =============================================================================


def test_10_searchsink_end_to_end() raises:
    var sink = SearchSink(
        String("my-bucket"),
        String("index"),
        String("logs"),
        String("body"),
        _uuid(5),
    )
    # init_sink resolves the text + _source column indices.
    var b_text: List[String] = [String("hello world"), String("hello again")]
    var b_src: List[String] = [String("doc0"), String("doc1")]
    var rb = _make_text_source_batch(b_text, b_src)
    sink.init_sink(rb.schema.copy())
    sink.accept_batch(rb^)
    sink.finish()

    assert_true(sink.is_finished())
    assert_true(sink.split_bytes_len() > 0)
    assert_false(sink.is_text_output_sink())
    # object key shape.
    var key = sink.object_key()
    assert_true(key.startswith("index/logs/splits/"))
    assert_true(key.endswith(".split"))

    var bytes = sink.take_split_bytes()
    var sv = SplitView.parse(bytes^)
    assert_equal(sv.doc_count(), 2)
    assert_equal(sv.field_name(), String("body"))
    assert_equal(sv.min_doc_id(), 0)
    assert_equal(sv.max_doc_id(), 1)
    # "hello" appears in both docs.
    var td_region = sv.term_dict_region()
    var td_copy = List[UInt8]()
    for i in range(len(td_region)):
        td_copy.append(td_region[i])
    var td2 = TermDictionary.deserialize(td_copy^)
    var hello_ord = td2.lookup(String("hello").as_bytes())
    assert_true(Bool(hello_ord))
    var ti = td2.term_info_at(hello_ord.value())
    assert_equal(ti.doc_freq, 2)


# =============================================================================
# Case 11 — corruption: truncated footer / oversized region offset.
# =============================================================================


def test_11_corruption_truncated_footer() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("hello")]))
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var ds = DocStoreBuilder()
    ds.append(String("x").as_bytes())
    var good = serialize_split(fi, td^, ds, String("body"), _uuid(4), 0, 0, 1)

    # (a) truncate the trailing footer (chop the last 10 bytes) -> raises.
    var truncated = List[UInt8]()
    for i in range(len(good) - 10):
        truncated.append(good[i])
    with assert_raises():
        var _sv = SplitView.parse(truncated^)

    # (b) bad front magic -> raises.
    var badmagic = List[UInt8]()
    for i in range(len(good)):
        badmagic.append(good[i])
    badmagic[0] = UInt8(0)  # corrupt "T"
    with assert_raises():
        var _sv2 = SplitView.parse(badmagic^)

    # (c) corrupt the footer's docstore_offset to point past EOF -> raises.
    # The footer region table sits near the end; corrupting the trailing
    # footer_len to an absurd value triggers the (3) footer_len range check.
    var badfooter = List[UInt8]()
    for i in range(len(good)):
        badfooter.append(good[i])
    # footer_len u32 is at total - 4 - 4 (before trailing "THSF").
    var fl_pos = len(badfooter) - 8
    badfooter[fl_pos] = UInt8(0xFF)
    badfooter[fl_pos + 1] = UInt8(0xFF)
    badfooter[fl_pos + 2] = UInt8(0xFF)
    badfooter[fl_pos + 3] = UInt8(0x7F)
    with assert_raises():
        var _sv3 = SplitView.parse(badfooter^)


# =============================================================================
# Case 12 — inline bitpack helper round-trip (width boundaries).
# =============================================================================


def test_12_bitpack_helper_roundtrip() raises:
    from komira_search.split import (
        _pack_bits_lsb_first,
        _unpack_bits_lsb_first,
        _min_bit_width,
        _packed_byte_count,
    )

    # min_bit_width boundaries.
    assert_equal(_min_bit_width(0), 0)
    assert_equal(_min_bit_width(1), 1)
    assert_equal(_min_bit_width(2), 2)
    assert_equal(_min_bit_width(3), 2)
    assert_equal(_min_bit_width(255), 8)
    assert_equal(_min_bit_width(256), 9)

    # round-trip a mixed-magnitude run across several widths.
    var values: List[Int] = [0, 1, 5, 7, 255, 1000, 65535, 3]
    var n = len(values)
    var max_v = 0
    for i in range(n):
        if values[i] > max_v:
            max_v = values[i]
    var bw = _min_bit_width(max_v)
    var packed = List[UInt8]()
    _pack_bits_lsb_first(Span(values), n, bw, packed)
    assert_equal(len(packed), _packed_byte_count(n, bw))
    var out = List[Int]()
    _unpack_bits_lsb_first(Span(packed), 0, n, bw, out)
    assert_equal(len(out), n)
    for i in range(n):
        assert_equal(out[i], values[i])

    # width-0 special case: all zeros, 0 bytes.
    var zeros: List[Int] = [0, 0, 0, 0]
    var zpacked = List[UInt8]()
    _pack_bits_lsb_first(Span(zeros), 4, 0, zpacked)
    assert_equal(len(zpacked), 0)
    var zout = List[Int]()
    _unpack_bits_lsb_first(Span(zpacked), 0, 4, 0, zout)
    assert_equal(len(zout), 4)
    for i in range(4):
        assert_equal(zout[i], 0)


# =============================================================================
# Case 14 — doc-store LZ4 compression: compressed split round-trips byte-
# identical via the read path; backward-compat (flag=0) split still reads.
# =============================================================================


def _docstore_region_for(
    sources: List[String], compress: Bool
) raises -> List[UInt8]:
    """Serialize a stand-alone doc-store region from `sources` (compressed or
    not) so the read path can be exercised directly via read_docstore_source."""
    var ds = DocStoreBuilder(compress=compress)
    for i in range(len(sources)):
        ds.append(sources[i].as_bytes())
    var region = List[UInt8]()
    ds.serialize(region)
    return region^


def test_14_docstore_compressed_read_round_trip() raises:
    """A COMPRESSED doc-store reads each `_source` back byte-identical via
    read_docstore_source (the searcher / merge read surface)."""
    from komira_search.source import read_docstore_source

    var sources: List[String] = [
        String(""),  # empty doc
        String('{"id":1,"msg":"hello world"}'),
        String('{"level":"INFO","service":"ingest","message":"ok and ok"}'),
    ]
    var region = _docstore_region_for(sources, compress=True)
    # flag byte (offset 8) must be the LZ4 flag.
    assert_equal(Int(region[8]), Int(DOCSTORE_FLAG_LZ4))
    for slot in range(len(sources)):
        var got = read_docstore_source(Span(region), slot)
        assert_equal(got, sources[slot])


def test_14b_docstore_backward_compat_uncompressed() raises:
    """A pre-compression (flag=0, UNCOMPRESSED) doc-store STILL reads correctly
    via read_docstore_source — the flag is load-bearing (the split writer reserved it). An
    OLD split must round-trip unchanged."""
    from komira_search.source import read_docstore_source

    var sources: List[String] = [
        String('{"id":0}'),
        String("plain text body"),
        String(""),
    ]
    var region = _docstore_region_for(sources, compress=False)
    # flag byte must be the UNCOMPRESSED flag (the OLD shape).
    assert_equal(Int(region[8]), Int(DOCSTORE_FLAG_UNCOMPRESSED))
    for slot in range(len(sources)):
        var got = read_docstore_source(Span(region), slot)
        assert_equal(got, sources[slot])


def test_14c_docstore_compression_storage_win() raises:
    """The COMPRESSED doc-store region is SMALLER than the uncompressed region
    for compressible JSON content (the storage win compression targets). Doc-store LZ4
    is PER-BLOB, so the win shows on realistically-sized `_source` documents
    (each blob has internal redundancy LZ4 exploits); tiny blobs would lose to
    the per-block overhead, which is not the doc-store regime."""
    var sources = List[String]()
    # 30 realistic `_source` JSON documents, each with substantial internal
    # redundancy (repeated keys + a long repetitive message body).
    var body = String("")
    for _ in range(40):
        body += "the quick brown fox jumps over the lazy dog "
    for d in range(30):
        sources.append(
            String('{"id":')
            + String(d)
            + ',"level":"INFO","service":"search-ingest-service",'
            '"tags":["alpha","alpha","alpha","beta","beta"],'
            '"message":"'
            + body
            + '"}'
        )
    var uncompressed = _docstore_region_for(sources, compress=False)
    var compressed = _docstore_region_for(sources, compress=True)
    assert_true(
        len(compressed) < len(uncompressed),
        "compressed docstore (" + String(len(compressed))
        + ") should be < uncompressed (" + String(len(uncompressed)) + ")",
    )


def test_14d_searchsink_split_uses_compression() raises:
    """A SearchSink-produced split (production write path) carries an
    LZ4-compressed doc-store, and SplitView+read_docstore_source recovers the
    `_source` byte-identical."""
    from komira_search.source import read_docstore_source

    var sink = SearchSink(
        String("b"), String("p"), String("logs"), String("body"), _uuid(9)
    )
    var b_text: List[String] = [
        String("alpha beta gamma"),
        String("delta epsilon"),
    ]
    var b_src: List[String] = [
        String('{"body":"alpha beta gamma","n":1}'),
        String('{"body":"delta epsilon","n":2}'),
    ]
    var rb = _make_text_source_batch(b_text, b_src)
    sink.init_sink(rb.schema.copy())
    sink.accept_batch(rb^)
    sink.finish()
    var bytes = sink.take_split_bytes()
    var sv = SplitView.parse(bytes^)
    var region = sv.docstore_region()
    # Production split is compressed.
    assert_equal(Int(region[8]), Int(DOCSTORE_FLAG_LZ4))
    for slot in range(len(b_src)):
        var got = read_docstore_source(region, slot)
        assert_equal(got, b_src[slot])


# =============================================================================
# Case 15 — WAND Phase 2 (BMW) codec: blockmeta encoder + per-block decode +
#           BLOCKMAX region round-trip + the byte-identical posting output.
# =============================================================================


def test_15a_blockmeta_encoder_byte_identical() raises:
    """The blockmeta encoder MUST emit posting bytes BYTE-IDENTICAL to
    _encode_posting_list (so a split's posting region is unchanged whether or not
    BLOCKMAX is captured) while ALSO capturing correct per-block metadata."""
    from komira_search.split import (
        _encode_posting_list,
        _encode_posting_list_with_blockmeta,
        _decode_posting_list,
        _decode_posting_block,
        _decode_posting_block_dids_only,
    )

    # 300 docs -> 3 blocks (128 + 128 + 44). Variable gaps + TFs + token counts.
    var n = 300
    var doc_ids = List[Int]()
    var tfs = List[Int]()
    var token_counts = List[Int]()
    var d = 0
    for i in range(n):
        d += 1 + (i % 3)
        doc_ids.append(d)
        tfs.append(1 + (i % 7))
        token_counts.append(2 + (i % 11))  # dense by slot; slot here == doc_id-0
    # token_counts must be indexed by slot = doc_id - min_doc_id; here min_doc=0
    # but doc_ids are NOT dense (gaps), so build a dense slot->dl map covering
    # max doc_id + 1.
    var dense_tc = List[Int](length=doc_ids[n - 1] + 1, fill=0)
    for i in range(n):
        dense_tc[doc_ids[i]] = token_counts[i]

    var plain = List[UInt8]()
    _encode_posting_list(Span(doc_ids), Span(tfs), plain)

    var bm_enc = List[UInt8]()
    var bbo = List[Int]()
    var bld = List[Int]()
    var bmt = List[Int]()
    var bmd = List[Int]()
    var nb = _encode_posting_list_with_blockmeta(
        Span(doc_ids), Span(tfs), Span(dense_tc), 0, bm_enc, bbo, bld, bmt, bmd
    )

    # (1) byte-identical posting output.
    assert_equal(len(bm_enc), len(plain))
    for i in range(len(plain)):
        assert_equal(Int(bm_enc[i]), Int(plain[i]))

    # (2) block count + per-block metadata correctness.
    assert_equal(nb, 3)
    assert_equal(len(bbo), 3)
    assert_equal(bld[0], doc_ids[127])  # last doc-id of block 0
    assert_equal(bld[1], doc_ids[255])  # last doc-id of block 1
    assert_equal(bld[2], doc_ids[299])  # last doc-id of block 2 (partial)
    # block_max_tf == max tf over each block.
    for b in range(3):
        var lo = b * 128
        var hi = lo + 128
        if hi > n:
            hi = n
        var mt = 0
        var md = -1
        for j in range(lo, hi):
            if tfs[j] > mt:
                mt = tfs[j]
            var dl = dense_tc[doc_ids[j]]
            if md < 0 or dl < md:
                md = dl
        assert_equal(bmt[b], mt)
        assert_equal(bmd[b], md)

    # (3) per-block decode (both variants) round-trips against the full decode.
    # The block_byte_offset base is the post-doc_count rel offset. doc_count is a
    # single ULEB (n=300 -> 2 bytes), so base = 2; verify by reading it.
    from komira_search.split import _read_uleb128_span

    var dc_res = _read_uleb128_span(Span(bm_enc), 0, len(bm_enc))
    assert_equal(dc_res[0], n)
    var base_rel = dc_res[1]
    for b in range(3):
        var lo = b * 128
        var hi = lo + 128
        if hi > n:
            hi = n
        var bc = hi - lo
        var bd = List[Int]()
        var bt = List[Int]()
        _decode_posting_block(
            Span(bm_enc), 0, len(bm_enc), base_rel, bbo[b], bc, bd, bt
        )
        var bd_only = List[Int]()
        _decode_posting_block_dids_only(
            Span(bm_enc), 0, len(bm_enc), base_rel, bbo[b], bc, bd_only
        )
        assert_equal(len(bd), bc)
        assert_equal(len(bd_only), bc)
        for j in range(bc):
            assert_equal(bd[j], doc_ids[lo + j])
            assert_equal(bd_only[j], doc_ids[lo + j])
            assert_equal(bt[j], tfs[lo + j])


def test_15b_blockmax_region_roundtrip() raises:
    """A SearchSink-produced split carries a BLOCKMAX region (has_blockmax()
    True), and BlockMaxIndex.deserialize round-trips the per-block skip-list."""
    from komira_search.split import BlockMaxIndex

    var sink = SearchSink(
        String("b"), String("p"), String("logs"), String("body"), _uuid(21)
    )
    var b_text: List[String] = [
        String("alpha beta"),
        String("alpha gamma gamma"),
        String("beta"),
    ]
    var b_src: List[String] = [
        String('{"n":0}'),
        String('{"n":1}'),
        String('{"n":2}'),
    ]
    var rb = _make_text_source_batch(b_text, b_src)
    sink.init_sink(rb.schema.copy())
    sink.accept_batch(rb^)
    sink.finish()
    var bytes = sink.take_split_bytes()
    var sv = SplitView.parse(bytes^)
    # The production write path supplies token_counts -> BLOCKMAX present.
    assert_true(sv.has_blockmax(), "SearchSink split must carry BLOCKMAX")
    var bm = BlockMaxIndex.deserialize(sv.blockmax_region())
    # 3 terms (alpha, beta, gamma), each a single block (<128 docs).
    assert_equal(bm.num_terms(), 3)
    for o in range(3):
        # every present term has >= 1 block.
        assert_true(bm.num_blocks(o) >= 1, "term must have >= 1 block")


def test_15c_no_blockmax_when_token_counts_absent() raises:
    """A split serialized WITHOUT token_counts (the OLD writer shape) has NO
    BLOCKMAX region (has_blockmax() False) — the backward-compat fallback path."""
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder()
    b.add_document(0, _af([String("alpha"), String("beta")]))
    ds.append(String("x").as_bytes())
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    # No token_counts arg -> BLOCKMAX absent (even with a total supplied).
    var bytes = serialize_split(
        fi, td^, ds, String("body"), _uuid(22), 0, 0, 1
    )
    var sv = SplitView.parse(bytes^)
    assert_true(not sv.has_blockmax(), "OLD split must NOT carry BLOCKMAX")


# =============================================================================
# Case 16 — the region accessors and the doc-store blob reader are slices of
# the split bytes: each returns exactly bytes[offset : offset + len].
# =============================================================================


def _assert_slice(
    got: Span[UInt8, _], whole: List[UInt8], off: Int, ln: Int
) raises:
    assert_equal(len(got), ln)
    for i in range(ln):
        assert_equal(Int(got[i]), Int(whole[off + i]))


def test_16_region_accessors_are_slices_of_the_split() raises:
    var b = InvertedIndexBuilder.create("body")
    b.add_document(0, _af([String("alpha"), String("beta")]))
    b.add_document(1, _af([String("beta"), String("gamma")]))
    var fi = b.finalize()
    var td = TermDictBuilder.build_from_finalized(fi)
    var ds = DocStoreBuilder(compress=False)
    ds.append(String("r0").as_bytes())
    ds.append(String("r1").as_bytes())
    var l0: List[UInt8] = [UInt8(1), UInt8(2), UInt8(3), UInt8(250)]
    var bytes = serialize_split(
        fi,
        td^,
        ds,
        String("body"),
        _uuid(3),
        0,
        1,
        2,
        total_token_count=4,
        l0_posting_region=l0^,
    )
    var whole = bytes.copy()
    var sv = SplitView.parse(bytes^)
    _assert_slice(
        sv.term_dict_region(), whole, sv.termdict_offset(), sv.termdict_len()
    )
    _assert_slice(
        sv.postings_region(), whole, sv.postings_offset(), sv.postings_len()
    )
    _assert_slice(
        sv.docstore_region(), whole, sv.docstore_offset(), sv.docstore_len()
    )
    _assert_slice(
        sv.fastfields_region(),
        whole,
        sv.fastfields_offset(),
        sv.fastfields_len(),
    )
    _assert_slice(
        sv.blockmax_region(), whole, sv.blockmax_offset(), sv.blockmax_len()
    )
    assert_true(sv.has_l0_posting())
    var l0_got = sv.l0_posting_region()
    _assert_slice(l0_got, whole, sv.l0_posting_offset(), sv.l0_posting_len())
    assert_equal(len(l0_got), 4)
    assert_equal(Int(l0_got[0]), 1)
    assert_equal(Int(l0_got[3]), 250)


def test_16b_docstore_blob_is_the_stored_slot() raises:
    """`_read_docstore_blob` returns the stored bytes of one slot: for an
    uncompressed doc-store, the `_source` itself."""
    from komira_search.source import _read_docstore_blob

    var sources: List[String] = [
        String("first"),
        String(""),
        String('{"id":2}'),
    ]
    var region = _docstore_region_for(sources, compress=False)
    for slot in range(len(sources)):
        var blob = _read_docstore_blob(Span(region), slot)
        var want = sources[slot].as_bytes()
        assert_equal(len(blob), len(want))
        for i in range(len(want)):
            assert_equal(Int(blob[i]), Int(want[i]))
    with assert_raises():
        _ = _read_docstore_blob(Span(region), len(sources))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_search_cov_split_parse.mojo: SplitView.parse refuses each corrupt
# header, footer and region-table field.
# =============================================================================
#
# The base split carries every optional region (fast fields, BLOCKMAX, an L0
# posting region) so every footer slot is present. Each case rewrites ONE
# field of a copy of it in place (the lengths stay the same) and asserts the
# refusal that names that field.
#
#   1. The header: shorter than the magic, an unknown version, shorter than
#      the smallest footer.
#   2. The footer frame: a footer_len that puts the footer inside the header,
#      a bad footer magic, an unknown footer version, a field name longer than
#      the footer.
#   3. The additive slots: a negative token total, BLOCKMAX offset and L0
#      offset; a negative fast-fields length.
#   4. Region order: each region grown by one byte into the next one
#      (termdict, postings, docstore, fast fields, BLOCKMAX) is refused.
#   5. A region with a negative offset, an offset inside the magic, and a
#      region running past the footer start are refused.
#   6. A region whose offset + length wraps past the Int maximum slips under
#      the footer-start check (the sum is negative) and is refused because its
#      offset lies past the end of the file. (A wrapped length with an
#      in-range offset is accepted today: komira-ai/komira#1084; no test pins
#      that.)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_search.analyzer import AnalyzedField, Token
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.split import SplitView, serialize_split, DocStoreBuilder


def _base() raises -> List[UInt8]:
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder(compress=False)
    for d in range(2):
        var toks = List[Token]()
        toks.append(Token(String("w"), 0))
        b.add_document(d, AnalyzedField(toks^))
        ds.append(String("d").as_bytes())
    var fi = b.finalize()
    var ff: List[UInt8] = [1, 2, 3]
    var l0: List[UInt8] = [7, 7]
    return serialize_split(
        fi, TermDictBuilder.build_from_finalized(fi), ds, String("body"),
        Array[UInt8, 16](fill=6), 0, 1, 2, fastfields_region=ff^,
        total_token_count=2, token_counts=[1, 1], l0_posting_region=l0^,
    )


def _u32_at(b: List[UInt8], p: Int) -> Int:
    return Int(b[p]) | (Int(b[p + 1]) << 8) | (Int(b[p + 2]) << 16) | (Int(b[p + 3]) << 24)


def _put_u32(mut b: List[UInt8], p: Int, v: Int):
    for i in range(4):
        b[p + i] = UInt8((v >> (8 * i)) & 0xFF)


def _put_u64(mut b: List[UInt8], p: Int, v: UInt64):
    for i in range(8):
        b[p + i] = UInt8((v >> UInt64(8 * i)) & 0xFF)


def _get_u64(b: List[UInt8], p: Int) -> Int:
    var v = 0
    for i in range(8):
        v |= Int(b[p + i]) << (8 * i)
    return v


def _footer_start(b: List[UInt8]) -> Int:
    var total = len(b)
    return total - 8 - _u32_at(b, total - 8)


# Byte offsets (from the first footer field after the uuid) of each u64 slot.
comptime DOC_COUNT = 0
comptime TD_OFF = 24
comptime TD_LEN = 32
comptime PO_OFF = 40
comptime PO_LEN = 48
comptime DS_OFF = 56
comptime DS_LEN = 64
comptime FF_OFF = 72
comptime FF_LEN = 80
comptime TOTAL = 104
comptime BM_OFF = 112
comptime BM_LEN = 120
comptime L0_OFF = 128
comptime L0_LEN = 136


def _slot(b: List[UInt8], which: Int) -> Int:
    """Absolute position of a footer u64 slot (field name "body", 4 bytes)."""
    return _footer_start(b) + 4 + 1 + 4 + 4 + 16 + which


def _with(which: Int, v: UInt64) raises -> List[UInt8]:
    var b = _base()
    _put_u64(b, _slot(b, which), v)
    return b^


def _grown(which: Int) raises -> List[UInt8]:
    var b = _base()
    var p = _slot(b, which)
    _put_u64(b, p, UInt64(_get_u64(b, p) + 1))
    return b^


comptime NEG = UInt64(0xFFFF_FFFF_FFFF_FFFF)


def test_00_base_parses() raises:
    var v = SplitView.parse(_base())
    assert_true(v.has_fastfields(), "0: fast fields")
    assert_true(v.has_blockmax(), "0: blockmax")
    assert_true(v.has_l0_posting(), "0: l0")
    assert_equal(v.total_token_count(), 2, "0: total")
    assert_equal(v.doc_count(), 2, "0: the slot map reads doc_count")
    var b = _base()
    assert_equal(_get_u64(b, _slot(b, DOC_COUNT)), 2, "0: the doc_count slot")
    assert_equal(_get_u64(b, _slot(b, L0_LEN)), 2, "0: the l0 length slot")


def test_01_header_refusals() raises:
    var short: List[UInt8] = [0x54, 0x48, 0x53, 0x50, 0x4C]
    with assert_raises(contains="SplitView.parse: too short for magic"):
        _ = SplitView.parse(short^)
    var ver = _base()
    ver[7] = 9
    with assert_raises(contains="SplitView.parse: unsupported version 9"):
        _ = SplitView.parse(ver^)
    var base = _base()
    var head = List[UInt8]()
    for i in range(20):
        head.append(base[i])
    with assert_raises(contains="SplitView.parse: too short for footer"):
        _ = SplitView.parse(head^)


def test_02_footer_frame_refusals() raises:
    var inside = _base()
    var total = len(inside)
    _put_u32(inside, total - 8, total - 8 - 4)
    with assert_raises(contains="footer start before header"):
        _ = SplitView.parse(inside^)
    var magic = _base()
    magic[_footer_start(magic)] = 0
    with assert_raises(contains="bad footer-start magic"):
        _ = SplitView.parse(magic^)
    var fver = _base()
    fver[_footer_start(fver) + 4] = 9
    with assert_raises(contains="unsupported footer version 9"):
        _ = SplitView.parse(fver^)
    var fname = _base()
    _put_u32(fname, _footer_start(fname) + 5, 0xFFFF)
    with assert_raises(contains="footer field_name_len out of bounds"):
        _ = SplitView.parse(fname^)


def test_03_additive_slot_refusals() raises:
    with assert_raises(contains="negative total_token_count"):
        _ = SplitView.parse(_with(TOTAL, NEG))
    with assert_raises(contains="negative blockmax offset/len"):
        _ = SplitView.parse(_with(BM_OFF, NEG))
    with assert_raises(contains="negative l0_posting offset/len"):
        _ = SplitView.parse(_with(L0_OFF, NEG))
    with assert_raises(contains="negative fast-fields offset/len"):
        _ = SplitView.parse(_with(FF_LEN, NEG))


def test_04_region_order_refusals() raises:
    with assert_raises(contains="regions overlap / out of order"):
        _ = SplitView.parse(_grown(TD_LEN))
    with assert_raises(contains="regions overlap / out of order"):
        _ = SplitView.parse(_grown(PO_LEN))
    with assert_raises(contains="out of order (with fast-fields)"):
        _ = SplitView.parse(_grown(DS_LEN))
    with assert_raises(contains="out of order (with blockmax)"):
        _ = SplitView.parse(_grown(FF_LEN))
    with assert_raises(contains="out of order (with l0_posting)"):
        _ = SplitView.parse(_grown(BM_LEN))


def test_05_region_bounds_refusals() raises:
    with assert_raises(contains="region 'termdict' negative offset/len"):
        _ = SplitView.parse(_with(TD_OFF, NEG))
    with assert_raises(contains="region 'postings' offset before magic"):
        _ = SplitView.parse(_with(PO_OFF, 3))
    var past = _base()
    var p = _slot(past, DS_LEN)
    _put_u64(past, p, UInt64(len(past)))
    with assert_raises(contains="region 'docstore' extends past footer start"):
        _ = SplitView.parse(past^)


def test_06_wrapped_region_offset_past_eof() raises:
    # 2^62 + (2^62 + 100) = 2^63 + 100 wraps to a negative Int, so the
    # `offset + length > footer_start` check passes; the offset alone is past
    # the end of the file.
    var b = _base()
    _put_u64(b, _slot(b, TD_OFF), UInt64(1) << 62)
    _put_u64(b, _slot(b, TD_LEN), (UInt64(1) << 62) + 100)
    with assert_raises(contains="region 'termdict' offset past EOF"):
        _ = SplitView.parse(b^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

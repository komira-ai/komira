# =============================================================================
# test_search_cov_ff_corrupt.mojo: the fast-field reader's refusals of corrupt
# region bytes, sub-region by sub-region.
# =============================================================================
#
# A split read at query time is attacker-influenced; every decode checks a
# length before it reads. Each case below writes a fast-fields region by hand
# (an independent writer in this file: "THFF", version, ULEB128 directory, then
# the sub-regions, every ULEB one byte), wraps it in a 3-doc split, and asserts
# the reader refuses it with the message of that check, never reading past it.
#
#   1. The directory: a region shorter than its header, an unknown version, a
#      field count larger than the region, a name past the end, an entry cut
#      inside its three type bytes, a sub-region past the end.
#   2. NUMERIC sub-region: truncated before the bit width, before the validity
#      flag, a validity bitmap past the end, a slot past its own doc count (the
#      accessor and the resolver), a packed window past the region.
#   3. FLOAT sub-region: the same checks, through the accessor and the
#      resolver.
#   4. KEYWORD sub-region: a negative dictionary size, a term past the end,
#      truncation before the code width and before the validity flag, a
#      validity bitmap past the end, a slot past its doc count, a code past
#      the dictionary (accessor, resolver and materializer).
#   5. A "__fieldnorm__" entry that is not numeric is refused by fieldnorms and
#      fieldnorm_resolver; FieldnormResolver refuses each corrupt header and a
#      slot past its doc count, and reads a null cell as 0.
#   6. An entry whose sub-region no longer lies in the region (a parsed entry
#      changed after parse) is refused by every decoder.
#   7. A length of 2^63 - 1 (Int.MAX), whose sum with an in-range offset wraps
#      Int negative, is refused by its own check: a sub-region in the
#      directory, a dictionary term in a KEYWORD sub-region, a field name
#      (komira-ai/komira#1203). A sub-region one byte past the region end is
#      refused by the same check.
#   8. Each bound pinned at its exact edge: a field name one byte longer than
#      the bytes left in the region, and a KEYWORD dictionary term one byte
#      longer than the bytes left in its sub-region, are refused by their own
#      checks (a bound off by one, or one that drops the offset, reads past).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.arrow_types import ArrowType

from komira_search.analyzer import (
    AnalyzedField,
    Token,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_KEYWORD,
)
from komira_search.inverted import InvertedIndexBuilder
from komira_search.term_dict import TermDictBuilder
from komira_search.split import SplitView, serialize_split, DocStoreBuilder
from komira_search.fast_fields import (
    FastFieldReader,
    FastFieldEntry,
    FieldnormResolver,
    FF_ENC_FOR_BITPACK,
    FF_ENC_FLOAT_FULL,
    FF_ENC_KEYWORD_DICT,
)


@fieldwise_init
struct _Ent(Copyable, Movable):
    var name: String
    var cls: UInt8
    var atype: UInt8
    var enc: UInt8
    var sub: List[UInt8]


def _num(name: String, var sub: List[UInt8]) -> _Ent:
    return _Ent(
        name, FIELD_CLASS_NUMERIC, ArrowType.INT64.type_id, FF_ENC_FOR_BITPACK,
        sub^,
    )


def _flt(name: String, var sub: List[UInt8]) -> _Ent:
    return _Ent(
        name, FIELD_CLASS_NUMERIC, ArrowType.FLOAT64.type_id, FF_ENC_FLOAT_FULL,
        sub^,
    )


def _kw(name: String, var sub: List[UInt8]) -> _Ent:
    return _Ent(
        name, FIELD_CLASS_KEYWORD, ArrowType.STRING.type_id, FF_ENC_KEYWORD_DICT,
        sub^,
    )


def _region(ents: List[_Ent]) raises -> List[UInt8]:
    """The THFF bytes for `ents`, sub-regions in order after the directory.
    Every ULEB128 here is a single byte (the test keeps regions < 128 bytes)."""
    var dir_len = 4 + 1 + 1
    for i in range(len(ents)):
        dir_len += 1 + ents[i].name.byte_length() + 3 + 1 + 1
    var out = List[UInt8]()
    for c in "THFF".as_bytes():
        out.append(c)
    out.append(1)
    out.append(UInt8(len(ents)))
    var off = dir_len
    for i in range(len(ents)):
        ref e = ents[i]
        out.append(UInt8(e.name.byte_length()))
        for c in e.name.as_bytes():
            out.append(c)
        out.append(e.cls)
        out.append(e.atype)
        out.append(e.enc)
        out.append(UInt8(off))
        out.append(UInt8(len(e.sub)))
        off += len(e.sub)
    for i in range(len(ents)):
        for b in ents[i].sub:
            out.append(b)
    assert_true(len(out) < 128, "the fixture keeps every ULEB one byte")
    return out^


def _split(var ff: List[UInt8]) raises -> SplitView:
    """A 3-doc split (docs 0..2, each the term "w") with `ff` as its region."""
    var b = InvertedIndexBuilder.create("body")
    var ds = DocStoreBuilder(compress=False)
    for d in range(3):
        var toks = List[Token]()
        toks.append(Token(String("w"), 0))
        b.add_document(d, AnalyzedField(toks^))
        ds.append(String("d").as_bytes())
    var fi = b.finalize()
    var bytes = serialize_split(
        fi, TermDictBuilder.build_from_finalized(fi), ds, String("body"),
        Array[UInt8, 16](fill=1), 0, 2, 3, fastfields_region=ff^,
    )
    return SplitView.parse(bytes^)


def _view_of(var ents: List[_Ent]) raises -> SplitView:
    return _split(_region(ents))


def _one(var e: _Ent) raises -> SplitView:
    var ents = List[_Ent]()
    ents.append(e^)
    return _view_of(ents^)


def test_01_directory_refusals() raises:
    var short: List[UInt8] = [0x54, 0x48, 0x46, 0x46]
    with assert_raises(contains="region too short for header"):
        _ = FastFieldReader(_split(short^))
    var ver: List[UInt8] = [0x54, 0x48, 0x46, 0x46, 2]
    with assert_raises(contains="unsupported region version 2"):
        _ = FastFieldReader(_split(ver^))
    var many: List[UInt8] = [0x54, 0x48, 0x46, 0x46, 1, 100]
    with assert_raises(contains="implausible num_fields"):
        _ = FastFieldReader(_split(many^))
    var name: List[UInt8] = [0x54, 0x48, 0x46, 0x46, 1, 1, 50, 0x61]
    with assert_raises(contains="field name out of bounds"):
        _ = FastFieldReader(_split(name^))
    var cut: List[UInt8] = [0x54, 0x48, 0x46, 0x46, 1, 1, 1, 0x61, 0, 0]
    with assert_raises(contains="directory entry truncated"):
        _ = FastFieldReader(_split(cut^))
    var past: List[UInt8] = [0x54, 0x48, 0x46, 0x46, 1, 1, 1, 0x61, 0, 5, 1, 0, 100]
    with assert_raises(contains="sub-region [0, 100) out of region"):
        _ = FastFieldReader(_split(past^))


def test_02_numeric_refusals() raises:
    var n = String("n")
    var v1 = _one(_num(n, [3, 0]))
    with assert_raises(contains="numeric header truncated (bits)"):
        _ = FastFieldReader(v1).fast_field_i64(v1, n, 0)
    var v2 = _one(_num(n, [3, 0, 8]))
    with assert_raises(contains="numeric header truncated (validity_flag)"):
        _ = FastFieldReader(v2).fast_field_i64(v2, n, 0)
    var v3 = _one(_num(n, [9, 0, 0, 1, 0xFF]))
    with assert_raises(contains="FastFieldReader: validity bitmap out of bounds"):
        _ = FastFieldReader(v3).fast_field_i64(v3, n, 0)
    # One doc in the sub-region; the split holds three.
    var v4 = _one(_num(n, [1, 0, 8, 0, 42]))
    var r4 = FastFieldReader(v4)
    assert_equal(r4.fast_field_i64(v4, n, 0).value(), Int64(42), "2: doc 0")
    with assert_raises(contains="slot out of numeric sub-region range"):
        _ = r4.fast_field_i64(v4, n, 2)
    var nr = r4.numeric_resolver(v4, n)
    assert_equal(nr.i64_at(v4, 0).value(), Int64(42), "2: resolver doc 0")
    with assert_raises(contains="i64_at: slot out of numeric"):
        _ = nr.i64_at(v4, 1)
    # Header says 8-bit values; no packed byte follows (the region's end).
    var v5 = _one(_num(n, [3, 0, 8, 0]))
    with assert_raises(contains="bitpack window out of bounds"):
        _ = FastFieldReader(v5).fast_field_i64(v5, n, 0)


def test_03_float_refusals() raises:
    var g = String("g")
    var v1 = _one(_flt(g, [3]))
    with assert_raises(contains="FastFieldReader: float header truncated (width)"):
        _ = FastFieldReader(v1).fast_field_f64(v1, g, 0)
    with assert_raises(contains="float_resolver: header truncated (width)"):
        _ = FastFieldReader(v1).float_resolver(v1, g)
    var v2 = _one(_flt(g, [3, 64]))
    with assert_raises(contains="FastFieldReader: float header truncated (validity_flag)"):
        _ = FastFieldReader(v2).fast_field_f64(v2, g, 0)
    with assert_raises(contains="float_resolver: header truncated (validity_flag)"):
        _ = FastFieldReader(v2).float_resolver(v2, g)
    var v3 = _one(_flt(g, [9, 64, 1, 0xFF]))
    with assert_raises(contains="float validity bitmap out of bounds"):
        _ = FastFieldReader(v3).fast_field_f64(v3, g, 0)
    with assert_raises(contains="float_resolver: validity bitmap OOB"):
        _ = FastFieldReader(v3).float_resolver(v3, g)
    # One doc (2.0 as f64 bits) in the sub-region; the split holds three.
    var v4 = _one(_flt(g, [1, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0x40]))
    var r4 = FastFieldReader(v4)
    assert_equal(r4.fast_field_f64(v4, g, 0).value(), 2.0, "3: doc 0")
    with assert_raises(contains="slot out of float sub-region range"):
        _ = r4.fast_field_f64(v4, g, 1)
    var fr = r4.float_resolver(v4, g)
    assert_equal(fr.f64_at(v4, 0).value(), 2.0, "3: resolver doc 0")
    with assert_raises(contains="f64_at: slot out of float sub-region range"):
        _ = fr.f64_at(v4, 2)
    var v5 = _one(_flt(g, [3, 64, 0]))
    with assert_raises(contains="bitpack window out of bounds"):
        _ = FastFieldReader(v5).fast_field_f64(v5, g, 0)


def test_04_keyword_refusals() raises:
    var k = String("k")
    var neg: List[UInt8] = [3, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1]
    var v1 = _one(_kw(k, neg^))
    with assert_raises(contains="negative dict_size"):
        _ = FastFieldReader(v1).fast_field_keyword(v1, k, 0)
    var v2 = _one(_kw(k, [3, 1, 5, 0x61]))
    with assert_raises(contains="dict term out of bounds"):
        _ = FastFieldReader(v2).fast_field_keyword(v2, k, 0)
    var v3 = _one(_kw(k, [3, 1, 1, 0x61]))
    with assert_raises(contains="keyword header truncated (code_bits)"):
        _ = FastFieldReader(v3).fast_field_keyword(v3, k, 0)
    var v4 = _one(_kw(k, [3, 1, 1, 0x61, 0]))
    with assert_raises(contains="keyword header truncated (validity_flag)"):
        _ = FastFieldReader(v4).keyword_resolver(v4, k)
    var v5 = _one(_kw(k, [9, 1, 1, 0x61, 0, 1, 0xFF]))
    with assert_raises(contains="keyword validity bitmap out of bounds"):
        _ = FastFieldReader(v5).fast_field_keyword(v5, k, 0)
    # One doc ("a") in the sub-region; the split holds three.
    var v6 = _one(_kw(k, [1, 1, 1, 0x61, 0, 0]))
    var r6 = FastFieldReader(v6)
    assert_equal(r6.fast_field_keyword(v6, k, 0).value(), String("a"), "4: doc 0")
    with assert_raises(contains="slot out of keyword sub-region range"):
        _ = r6.fast_field_keyword(v6, k, 1)
    var kr = r6.keyword_resolver(v6, k)
    with assert_raises(contains="keyword_at: slot out of keyword"):
        _ = kr.keyword_at(v6, 2)
    # Three 2-bit codes, each 3, against a one-term dictionary.
    var v7 = _one(_kw(k, [3, 1, 1, 0x61, 2, 0, 0x3F]))
    var r7 = FastFieldReader(v7)
    with assert_raises(contains="FastFieldReader: dict code 3 >= dict_size 1"):
        _ = r7.fast_field_keyword(v7, k, 0)
    with assert_raises(contains="KeywordFastFieldResolver: dict code 3 >= dict_size 1"):
        _ = r7.keyword_resolver(v7, k).keyword_at(v7, 1)
    with assert_raises(contains="_materialize_keyword: code 3 >= dict_size 1"):
        _ = r7.fast_field_column(v7, k)


def test_05_fieldnorm_refusals() raises:
    var fname = String("__fieldnorm__")
    var vf = _one(_flt(fname, [3, 64, 0]))
    var rf = FastFieldReader(vf)
    with assert_raises(contains="fieldnorms: '__fieldnorm__' is not a numeric"):
        _ = rf.fieldnorms(vf)
    with assert_raises(contains="fieldnorm_resolver: '__fieldnorm__' is not a"):
        _ = rf.fieldnorm_resolver()
    var vk = _one(_kw(fname, [3, 1, 1, 0x61, 0, 0]))
    with assert_raises(contains="fieldnorms: '__fieldnorm__' is not a numeric"):
        _ = FastFieldReader(vk).fieldnorms(vk)
    with assert_raises(contains="fieldnorm_resolver: '__fieldnorm__' is not a"):
        _ = FastFieldReader(vk).fieldnorm_resolver()

    # FieldnormResolver over hand-made entries (its constructor is public).
    var subs = List[List[UInt8]]()
    subs.append([3, 0])  # 0: truncated before the bit width
    subs.append([3, 0, 8])  # 1: truncated before the validity flag
    subs.append([9, 0, 0, 1, 0xFF])  # 2: validity bitmap past the end
    subs.append([1, 0, 8, 0, 6])  # 3: one doc (dl 6) of the split's three
    # 4: three docs, dl 5 / null / 7 (bitmap 0b101).
    subs.append([3, 0, 8, 1, 0x05, 5, 0, 7])
    var ents = List[_Ent]()
    for i in range(len(subs)):
        ents.append(_num(String("f") + String(i), subs[i].copy()))
    var v = _view_of(ents^)
    var r = FastFieldReader(v)
    var msgs: List[String] = [
        "FieldnormResolver: numeric header truncated (bits)",
        "FieldnormResolver: numeric header truncated (validity_flag)",
        "FieldnormResolver: validity bitmap out of bounds",
    ]
    for i in range(3):
        var e = r._entries[i].copy()
        var fr = FieldnormResolver(entry=e^, min_doc_id=0, doc_count=3)
        with assert_raises(contains=msgs[i]):
            _ = fr.dl_at(v, 0)
    var fr3 = FieldnormResolver(entry=r._entries[3].copy(), min_doc_id=0, doc_count=3)
    assert_equal(fr3.dl_at(v, 0), 6, "5: one-doc dl")
    with assert_raises(contains="dl_at: slot out of fieldnorm sub-region range"):
        _ = fr3.dl_at(v, 1)
    var fr4 = FieldnormResolver(entry=r._entries[4].copy(), min_doc_id=0, doc_count=3)
    assert_equal(fr4.dl_at(v, 0), 5, "5: dl 5")
    assert_equal(fr4.dl_at(v, 1), 0, "5: a null dl reads 0")
    assert_equal(fr4.dl_at(v, 2), 7, "5: dl 7")
    var bad = r._entries[4].copy()
    bad.sub_len = 200
    var fr5 = FieldnormResolver(entry=bad^, min_doc_id=0, doc_count=3)
    with assert_raises(contains="FieldnormResolver: numeric sub-region out of bounds"):
        _ = fr5.dl_at(v, 0)


def test_06_entry_outside_region_refused() raises:
    var ents = List[_Ent]()
    ents.append(_num(String("n"), [3, 0, 8, 0, 1, 2, 3]))
    ents.append(_flt(String("g"), [1, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0x40]))
    ents.append(_kw(String("k"), [3, 1, 1, 0x61, 0, 0]))
    var v = _view_of(ents^)
    var r = FastFieldReader(v)
    for i in range(3):
        r._entries[i].sub_len = 500
    with assert_raises(contains="FastFieldReader: numeric sub-region out of bounds"):
        _ = r.fast_field_i64(v, String("n"), 0)
    with assert_raises(contains="FastFieldReader: float sub-region out of bounds"):
        _ = r.fast_field_f64(v, String("g"), 0)
    with assert_raises(contains="float_resolver: float sub-region OOB"):
        _ = r.float_resolver(v, String("g"))
    with assert_raises(contains="FastFieldReader: keyword sub-region out of bounds"):
        _ = r.fast_field_keyword(v, String("k"), 0)


def _uleb_int_max(mut out: List[UInt8]):
    """Int.MAX (2^63 - 1) as a ULEB128: nine 0xFF bytes, then 0x00."""
    for _ in range(9):
        out.append(0xFF)
    out.append(0x00)


def test_07_wrapping_lengths_refused() raises:
    # Directory entry: sub-offset 1, sub-length Int.MAX (1 + len wraps).
    var sub: List[UInt8] = [0x54, 0x48, 0x46, 0x46, 1, 1, 1, 0x61, 0, 5, 1, 1]
    _uleb_int_max(sub)
    with assert_raises(contains="FastFieldReader: sub-region [1, "):
        _ = FastFieldReader(_split(sub^))
    # The same check one byte past the end: a 13-byte region, [12, 14).
    var one: List[UInt8] = [0x54, 0x48, 0x46, 0x46, 1, 1, 1, 0x61, 0, 5, 1, 12, 2]
    with assert_raises(contains="sub-region [12, 14) out of region"):
        _ = FastFieldReader(_split(one^))
    # KEYWORD dictionary: 3 docs, 1 term of length Int.MAX.
    var kw: List[UInt8] = [3, 1]
    _uleb_int_max(kw)
    kw.append(0x61)
    var k = String("k")
    var v = _one(_kw(k, kw^))
    with assert_raises(contains="FastFieldReader: dict term out of bounds"):
        _ = FastFieldReader(v).fast_field_keyword(v, k, 0)
    # Field name of length Int.MAX at directory position 6.
    var name: List[UInt8] = [0x54, 0x48, 0x46, 0x46, 1, 1]
    _uleb_int_max(name)
    name.append(0x61)
    with assert_raises(contains="FastFieldReader: field name out of bounds"):
        _ = FastFieldReader(_split(name^))



def test_08_one_byte_past_end_refused() raises:
    # Field name: the 8-byte region has 1 byte after the name length at
    # position 7, and the name claims 2. A bound of `name_len > rlen` or
    # `name_len > rlen - pos + 1` would read region[8].
    var name: List[UInt8] = [0x54, 0x48, 0x46, 0x46, 1, 1, 2, 0x61]
    with assert_raises(contains="FastFieldReader: field name out of bounds"):
        _ = FastFieldReader(_split(name^))
    # KEYWORD dictionary: 3 docs, 1 term of length 2 with 1 byte left in the
    # 4-byte sub-region. A bound off by one walks the term past the
    # sub-region end and is refused later, by a different check.
    var k = String("k")
    var v = _one(_kw(k, [3, 1, 2, 0x61]))
    with assert_raises(contains="FastFieldReader: dict term out of bounds"):
        _ = FastFieldReader(v).fast_field_keyword(v, k, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

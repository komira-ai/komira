# Direct tests of `decode_column_with_levels` (nested_decoder.mojo): the
# present values and the definition / repetition levels of a leaf column
# chunk, over V1 and V2 pages, PLAIN and dictionary-encoded, every supported
# type, and the malformed chunks it refuses.
#
# Chunks are encoded here from parquet-format: Thrift Compact page headers
# (parquet.thrift), PLAIN values and RLE / Bit-Packing Hybrid levels and codes
# (Encodings.md). The leaf modelled in most tests is `list<int32>` (max
# definition level 3, max repetition level 1) over the rows [[1, 2], [],
# null, [3, null]]: levels (def, rep) = (3,0) (3,1) (1,0) (0,0) (3,0) (2,1),
# present values 1, 2, 3.
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.nested_decoder import decode_column_with_levels

comptime _PLAIN = 0
comptime _RLE_DICTIONARY = 8
comptime _DEFS: List[Int] = [3, 3, 1, 0, 3, 2]
comptime _REPS: List[Int] = [0, 1, 0, 0, 0, 1]


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _uleb(mut out: List[UInt8], v: Int):
    var x = v
    while True:
        var b = x & 0x7F
        x >>= 7
        if x != 0:
            out.append(UInt8(b | 0x80))
        else:
            out.append(UInt8(b))
            return


def _i32(mut out: List[UInt8], v: Int):
    out.append(UInt8((1 << 4) | 5))
    _uleb(out, (v << 1) ^ (v >> 63))


def _header(
    page_type: Int,
    uncomp: Int,
    comp: Int,
    nv: Int,
    enc: Int,
    def_len: Int = 0,
    rep_len: Int = 0,
    is_compressed: Bool = True,
) -> List[UInt8]:
    var h = List[UInt8]()
    _i32(h, page_type)
    _i32(h, uncomp)
    _i32(h, comp)
    if page_type == 0:
        h.append(UInt8((2 << 4) | 12))
        _i32(h, nv)
        _i32(h, enc)
        _i32(h, 3)
        _i32(h, 3)
        h.append(UInt8(0))
    elif page_type == 2:
        h.append(UInt8((4 << 4) | 12))
        _i32(h, nv)
        _i32(h, enc)
        h.append(UInt8(0))
    elif page_type == 3:
        h.append(UInt8((5 << 4) | 12))
        _i32(h, nv)
        _i32(h, 0)
        _i32(h, nv)
        _i32(h, enc)
        _i32(h, def_len)
        _i32(h, rep_len)
        h.append(UInt8((1 << 4) | (1 if is_compressed else 2)))
        h.append(UInt8(0))
    h.append(UInt8(0))
    return h^


def _hybrid(values: List[Int], bw: Int) -> List[UInt8]:
    """One bit-packed run of `values` at width `bw`, zero-padded to 8."""
    var out = List[UInt8]()
    var groups = (len(values) + 7) // 8
    _uleb(out, (groups << 1) | 1)
    var acc = 0
    var nbits = 0
    for i in range(groups * 8):
        acc |= (values[i] if i < len(values) else 0) << nbits
        nbits += bw
        while nbits >= 8:
            out.append(UInt8(acc & 0xFF))
            acc >>= 8
            nbits -= 8
    if nbits > 0:
        out.append(UInt8(acc & 0xFF))
    return out^


def _v1_levels(values: List[Int], bw: Int) -> List[UInt8]:
    var run = _hybrid(values, bw)
    var out = List[UInt8]()
    _le(out, len(run), 4)
    out.extend(run^)
    return out^


def _compressed(codec: CompressionCodec, body: List[UInt8]) raises -> List[UInt8]:
    if codec == CompressionCodec.UNCOMPRESSED:
        return body.copy()
    var out = List[UInt8](length=compress_bound(codec, len(body)), fill=UInt8(0))
    out.resize(compress(codec, Span(body), Span(out)), UInt8(0))
    return out^


def _v1_page(
    mut chunk: List[UInt8],
    defs: List[Int],
    reps: List[Int],
    values: List[UInt8],
    enc: Int,
    codec: CompressionCodec,
) raises:
    var body = _v1_levels(reps, 1)
    body.extend(_v1_levels(defs, 2))
    body.extend(values.copy())
    var payload = _compressed(codec, body)
    chunk.extend(_header(0, len(body), len(payload), len(defs), enc))
    chunk.extend(payload^)


def _ints(values: List[Int], width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, values[i], width)
    return out^


def _check_levels(leaf_defs: List[Int32], leaf_reps: List[Int32]) raises:
    var defs = materialize[_DEFS]()
    var reps = materialize[_REPS]()
    assert_equal(len(leaf_defs), len(defs))
    assert_equal(len(leaf_reps), len(reps))
    for i in range(len(defs)):
        assert_equal(Int(leaf_defs[i]), defs[i], "def level " + String(i))
        assert_equal(Int(leaf_reps[i]), reps[i], "rep level " + String(i))


def test_list_of_int32_v1_every_codec() raises:
    var codecs: List[CompressionCodec] = [CompressionCodec.UNCOMPRESSED, CompressionCodec.SNAPPY]
    for c in range(len(codecs)):
        var chunk = List[UInt8]()
        _v1_page(chunk, materialize[_DEFS](), materialize[_REPS](), _ints([1, 2, 3], 4), _PLAIN, codecs[c])
        var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT32, codecs[c], 6, 3, 1)
        _check_levels(leaf.def_levels, leaf.rep_levels)
        assert_equal(leaf.column.length(), 3, "the present values only")
        var arr = leaf.column.as_primitive[DType.int32]()
        assert_equal(arr.get_typed[Int32](2), Int32(3))


def test_levels_and_values_across_two_v1_pages() raises:
    # Rows split [[1, 2], []] | [null, [3, null]].
    var chunk = List[UInt8]()
    _v1_page(chunk, [3, 3, 1], [0, 1, 0], _ints([1, 2], 8), _PLAIN, CompressionCodec.UNCOMPRESSED)
    _v1_page(chunk, [0, 3, 2], [0, 0, 1], _ints([3], 8), _PLAIN, CompressionCodec.UNCOMPRESSED)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    _check_levels(leaf.def_levels, leaf.rep_levels)
    var arr = leaf.column.as_primitive[DType.int64]()
    assert_equal(arr.length, 3)
    assert_equal(arr.get_typed[Int64](0), Int64(1))
    assert_equal(arr.get_typed[Int64](2), Int64(3))


def test_v2_pages_with_and_without_compressed_values() raises:
    for compressed_flag in range(2):
        var reps = _hybrid(materialize[_REPS](), 1)
        var defs = _hybrid(materialize[_DEFS](), 2)
        var values = _ints([1, 2, 3], 4)
        var is_comp = compressed_flag == 1
        var payload = _compressed(CompressionCodec.SNAPPY, values) if is_comp else values.copy()
        var page = reps.copy()
        page.extend(defs.copy())
        page.extend(payload^)
        var chunk = _header(
            3, len(reps) + len(defs) + len(values), len(page), 6, _PLAIN,
            len(defs), len(reps), is_comp,
        )
        chunk.extend(page^)
        var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT32, CompressionCodec.SNAPPY, 6, 3, 1)
        _check_levels(leaf.def_levels, leaf.rep_levels)
        var arr = leaf.column.as_primitive[DType.int32]()
        assert_equal(arr.get_typed[Int32](1), Int32(2), "is_compressed " + String(is_comp))


def test_dictionary_indices_decode_at_their_declared_bit_width() raises:
    # Dictionary [111, 222]; a V2 page (no level sections) of one RLE run of
    # eight code 1. The page body is [bit width 1][run header 0x10][1]: a
    # decoder that skips the bit-width byte twice reads 0x10 as the width
    # and resolves dict[0] = 111.
    var chunk = _header(2, 8, 8, 2, _PLAIN)
    chunk.extend(_ints([111, 222], 4))
    var body: List[UInt8] = [UInt8(1), UInt8(0x10), UInt8(1)]
    chunk.extend(_header(3, 3, 3, 8, _RLE_DICTIONARY, 0, 0, False))
    chunk.extend(body^)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 8, 1, 0)
    assert_equal(leaf.column.length(), 8)
    var arr = leaf.column.as_primitive[DType.int32]()
    for i in range(8):
        assert_equal(arr.get_typed[Int32](i), Int32(222))


def test_float_double_and_boolean_leaves() raises:
    var f = List[UInt8]()
    _le(f, Int(Float32(1.5).to_bits()), 4)
    _le(f, Int(Float32(-4.0).to_bits()), 4)
    _le(f, Int(Float32(8.25).to_bits()), 4)
    var chunk = List[UInt8]()
    _v1_page(chunk, materialize[_DEFS](), materialize[_REPS](), f, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.FLOAT, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    assert_equal(leaf.column.as_primitive[DType.float32]().get_typed[Float32](1), Float32(-4.0))
    # Booleans 1, 0, 1: PLAIN bit-packed LSB first.
    var b = List[UInt8]()
    b.append(UInt8(0b101))
    var bchunk = List[UInt8]()
    _v1_page(bchunk, materialize[_DEFS](), materialize[_REPS](), b, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var bleaf = decode_column_with_levels(Span(bchunk), ParquetType.BOOLEAN, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    assert_equal(bleaf.column.length(), 3, "a boolean leaf keeps its values")
    var barr = bleaf.column.as_boolean()
    assert_true(barr.get(0))
    assert_true(not barr.get(1))
    assert_true(barr.get(2))


def _strings(values: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, values[i].byte_length(), 4)
        out.extend(Span(values[i].as_bytes()))
    return out^


def test_plain_strings_across_two_pages_keep_every_page() raises:
    var chunk = List[UInt8]()
    _v1_page(chunk, [3, 3, 1], [0, 1, 0], _strings(["ab", ""]), _PLAIN, CompressionCodec.UNCOMPRESSED)
    _v1_page(chunk, [0, 3, 2], [0, 0, 1], _strings(["xyz"]), _PLAIN, CompressionCodec.UNCOMPRESSED)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    assert_equal(leaf.column.length(), 3, "the first page's strings are kept")
    var arr = leaf.column.as_string()
    assert_equal(arr.get(0), "ab")
    assert_equal(arr.get(1), "")
    assert_equal(arr.get(2), "xyz")


def test_dictionary_strings_across_two_pages() raises:
    var dict_body = _strings(["red", "go"])
    var chunk = _header(2, len(dict_body), len(dict_body), 2, _PLAIN)
    chunk.extend(dict_body^)
    var c1: List[UInt8] = [UInt8(1)]
    c1.extend(_hybrid([1, 0], 1))
    _v1_page(chunk, [3, 3, 1], [0, 1, 0], c1, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var c2: List[UInt8] = [UInt8(1)]
    c2.extend(_hybrid([1], 1))
    _v1_page(chunk, [0, 3, 2], [0, 0, 1], c2, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    assert_true(leaf.column.is_dictionary())
    assert_equal(leaf.column.length(), 3)
    var d = leaf.column.as_dictionary()
    assert_equal(d.get(0), "go")
    assert_equal(d.get(1), "red")
    assert_equal(d.get(2), "go")


def test_a_string_chunk_mixing_dictionary_and_plain_pages_is_refused() raises:
    var chunk = _header(2, 7, 7, 1, _PLAIN)
    chunk.extend(_strings(["red"]))
    var c1: List[UInt8] = [UInt8(1)]
    c1.extend(_hybrid([0, 0], 1))
    _v1_page(chunk, [3, 3, 1], [0, 1, 0], c1, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    _v1_page(chunk, [0, 3, 2], [0, 0, 1], _strings(["x"]), _PLAIN, CompressionCodec.UNCOMPRESSED)
    with assert_raises(contains="mixes dictionary and PLAIN data pages"):
        _ = decode_column_with_levels(Span(chunk), ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 6, 3, 1)


def test_a_numeric_chunk_may_spill_from_dictionary_to_plain() raises:
    var chunk = _header(2, 4, 4, 1, _PLAIN)
    chunk.extend(_ints([9], 4))
    var c1: List[UInt8] = [UInt8(1)]
    c1.extend(_hybrid([0, 0], 1))
    _v1_page(chunk, [3, 3, 1], [0, 1, 0], c1, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    _v1_page(chunk, [0, 3, 2], [0, 0, 1], _ints([5], 4), _PLAIN, CompressionCodec.UNCOMPRESSED)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    var arr = leaf.column.as_primitive[DType.int32]()
    assert_equal(arr.get_typed[Int32](0), Int32(9))
    assert_equal(arr.get_typed[Int32](2), Int32(5), "the PLAIN page is decoded as PLAIN")


def test_malformed_chunks_are_refused() raises:
    # A page that declares more values than the chunk.
    var too_many = List[UInt8]()
    _v1_page(too_many, materialize[_DEFS](), materialize[_REPS](), _ints([1, 2, 3], 4), _PLAIN, CompressionCodec.UNCOMPRESSED)
    with assert_raises(contains="page declares 6 values but only 2"):
        _ = decode_column_with_levels(Span(too_many), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 2, 3, 1)
    # A body that runs past the chunk.
    var cut = List[UInt8]()
    _v1_page(cut, materialize[_DEFS](), materialize[_REPS](), _ints([1, 2, 3], 4), _PLAIN, CompressionCodec.UNCOMPRESSED)
    cut.resize(len(cut) - 3, UInt8(0))
    with assert_raises(contains="exceeds remaining column-chunk bytes"):
        _ = decode_column_with_levels(Span(cut), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    # A dictionary that claims more entries than it holds.
    var big_dict = _header(2, 4, 4, 1000, _PLAIN)
    big_dict.extend(_ints([1], 4))
    with assert_raises(contains="exceeds decoded dictionary bytes"):
        _ = decode_column_with_levels(Span(big_dict), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    # A dictionary-encoded page with no dictionary.
    var no_dict = List[UInt8]()
    var c: List[UInt8] = [UInt8(1)]
    c.extend(_hybrid([0, 0, 0], 1))
    _v1_page(no_dict, materialize[_DEFS](), materialize[_REPS](), c, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    with assert_raises(contains="no dictionary page before it"):
        _ = decode_column_with_levels(Span(no_dict), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    # A PLAIN string whose length runs past the page.
    var bad_str = List[UInt8]()
    var sv = List[UInt8]()
    _le(sv, 40, 4)
    sv.append(UInt8(65))
    _v1_page(bad_str, [3], [0], sv, _PLAIN, CompressionCodec.UNCOMPRESSED)
    with assert_raises(contains="runs past its page"):
        _ = decode_column_with_levels(Span(bad_str), ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 1, 3, 1)
    with assert_raises(contains="negative num_values"):
        _ = decode_column_with_levels(Span(bad_str), ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, -1, 3, 1)


def test_a_chunk_with_no_present_value_is_an_empty_column() raises:
    var chunk = List[UInt8]()
    _v1_page(chunk, [0, 1], [0, 0], List[UInt8](), _PLAIN, CompressionCodec.UNCOMPRESSED)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 2, 3, 1)
    assert_equal(leaf.column.length(), 0)
    assert_equal(len(leaf.def_levels), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

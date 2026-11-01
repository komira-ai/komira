# Direct tests of `decode_column_with_levels` (nested_decoder.mojo) for the
# leaves test_nested_decoder_direct does not reach: dictionary-encoded INT64,
# FLOAT and DOUBLE leaves, PLAIN DOUBLE leaves, a required (level-free) leaf,
# skipped index pages, a dictionary page that is not decoded as a dictionary,
# and the pages it refuses (an unsupported encoding or type, a value section
# that runs out, a decoded body smaller than its level sections).
#
# Chunks are encoded here from parquet-format: Thrift Compact page headers
# (parquet.thrift), PLAIN values and RLE / Bit-Packing Hybrid levels and codes
# (Encodings.md). The leaf modelled is `list<T>` (max definition level 3, max
# repetition level 1) over the rows [[a, b], [], null, [c, null]]: levels
# (def, rep) = (3,0) (3,1) (1,0) (0,0) (3,0) (2,1), present values a, b, c.
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.nested_decoder import _page_body, decode_column_with_levels

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



def _f32(values: List[Float32]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, Int(values[i].to_bits()), 4)
    return out^


def _f64(values: List[Float64]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, Int(values[i].to_bits()), 8)
    return out^


def _strings(values: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, values[i].byte_length(), 4)
        out.extend(Span(values[i].as_bytes()))
    return out^


def _dict_codes(codes: List[Int]) -> List[UInt8]:
    """A dictionary-encoded page's value section: bit width 1, then the codes."""
    var out: List[UInt8] = [UInt8(1)]
    out.extend(_hybrid(codes, 1))
    return out^


def _check_list_levels(leaf_defs: List[Int32], leaf_reps: List[Int32]) raises:
    var defs = materialize[_DEFS]()
    var reps = materialize[_REPS]()
    assert_equal(len(leaf_defs), len(defs))
    assert_equal(len(leaf_reps), len(reps))
    for i in range(len(defs)):
        assert_equal(Int(leaf_defs[i]), defs[i], "def level " + String(i))
        assert_equal(Int(leaf_reps[i]), reps[i], "rep level " + String(i))


def _dict_chunk(dict_entries: Int, dict_body: List[UInt8]) -> List[UInt8]:
    var chunk = _header(2, len(dict_body), len(dict_body), dict_entries, _PLAIN)
    chunk.extend(dict_body.copy())
    return chunk^


def test_dictionary_int64_leaf_resolves_codes_to_values() raises:
    var chunk = _dict_chunk(2, _ints([100, -200], 8))
    _v1_page(
        chunk, materialize[_DEFS](), materialize[_REPS](), _dict_codes([1, 0, 1]),
        _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED,
    )
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    _check_list_levels(leaf.def_levels, leaf.rep_levels)
    var arr = leaf.column.as_primitive[DType.int64]()
    assert_equal(arr.length, 3)
    assert_equal(arr.get_typed[Int64](0), Int64(-200))
    assert_equal(arr.get_typed[Int64](1), Int64(100))
    assert_equal(arr.get_typed[Int64](2), Int64(-200))


def test_dictionary_float_leaf_resolves_codes_to_values() raises:
    var chunk = _dict_chunk(2, _f32([1.5, -2.25]))
    _v1_page(
        chunk, materialize[_DEFS](), materialize[_REPS](), _dict_codes([0, 0, 1]),
        _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED,
    )
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.FLOAT, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    var arr = leaf.column.as_primitive[DType.float32]()
    assert_equal(arr.length, 3)
    assert_equal(arr.get_typed[Float32](0), Float32(1.5))
    assert_equal(arr.get_typed[Float32](1), Float32(1.5))
    assert_equal(arr.get_typed[Float32](2), Float32(-2.25))


def test_dictionary_double_leaf_resolves_codes_to_values() raises:
    var chunk = _dict_chunk(2, _f64([0.125, 1e300]))
    _v1_page(
        chunk, materialize[_DEFS](), materialize[_REPS](), _dict_codes([1, 1, 0]),
        _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED,
    )
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.DOUBLE, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    var arr = leaf.column.as_primitive[DType.float64]()
    assert_equal(arr.length, 3)
    assert_equal(arr.get_typed[Float64](0), Float64(1e300))
    assert_equal(arr.get_typed[Float64](1), Float64(1e300))
    assert_equal(arr.get_typed[Float64](2), Float64(0.125))


def test_plain_double_leaf_keeps_values_across_two_pages() raises:
    # Rows split [[1, 2], []] | [null, [3, null]].
    var chunk = List[UInt8]()
    _v1_page(chunk, [3, 3, 1], [0, 1, 0], _f64([0.5, -1.5]), _PLAIN, CompressionCodec.UNCOMPRESSED)
    _v1_page(chunk, [0, 3, 2], [0, 0, 1], _f64([9.75]), _PLAIN, CompressionCodec.UNCOMPRESSED)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.DOUBLE, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    _check_list_levels(leaf.def_levels, leaf.rep_levels)
    var arr = leaf.column.as_primitive[DType.float64]()
    assert_equal(arr.length, 3)
    assert_equal(arr.get_typed[Float64](0), Float64(0.5))
    assert_equal(arr.get_typed[Float64](1), Float64(-1.5))
    assert_equal(arr.get_typed[Float64](2), Float64(9.75))


def test_a_dictionary_page_with_no_present_value_adds_no_codes() raises:
    # Every level is below the maximum, so the page holds levels and no codes:
    # the leaf is an empty column, not an error.
    var chunk = _dict_chunk(1, _ints([7], 4))
    _v1_page(chunk, [0, 1], [0, 0], List[UInt8](), _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 2, 3, 1)
    assert_equal(leaf.column.length(), 0)
    assert_equal(len(leaf.def_levels), 2)
    assert_equal(Int(leaf.def_levels[1]), 1)


def test_a_dictionary_page_with_present_values_and_no_codes_is_refused() raises:
    var chunk = _dict_chunk(1, _ints([7], 4))
    _v1_page(chunk, [3, 3], [0, 1], List[UInt8](), _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    with assert_raises(contains="2 present values and no codes"):
        _ = decode_column_with_levels(Span(chunk), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 2, 3, 1)


def test_an_index_page_is_skipped() raises:
    # An INDEX_PAGE (page type 1) between two data pages carries no values
    # and is passed over.
    var chunk = List[UInt8]()
    _v1_page(chunk, [3, 3, 1], [0, 1, 0], _ints([1, 2], 4), _PLAIN, CompressionCodec.UNCOMPRESSED)
    chunk.extend(_header(1, 3, 3, 0, _PLAIN))
    chunk.extend(_ints([0, 0, 0], 1))
    _v1_page(chunk, [0, 3, 2], [0, 0, 1], _ints([3], 4), _PLAIN, CompressionCodec.UNCOMPRESSED)
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 6, 3, 1)
    _check_list_levels(leaf.def_levels, leaf.rep_levels)
    var arr = leaf.column.as_primitive[DType.int32]()
    assert_equal(arr.length, 3)
    assert_equal(arr.get_typed[Int32](2), Int32(3))


def test_a_required_leaf_has_level_zero_and_every_value() raises:
    # max definition level 0 and max repetition level 0: a V1 page has no level
    # sections, only values; every value is present at level 0.
    var chunk = List[UInt8]()
    var header = _header(0, 12, 12, 3, _PLAIN)
    chunk.extend(header^)
    chunk.extend(_ints([10, 20, 30], 4))
    var leaf = decode_column_with_levels(Span(chunk), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 3, 0, 0)
    assert_equal(len(leaf.def_levels), 3)
    assert_equal(len(leaf.rep_levels), 0)
    for i in range(3):
        assert_equal(Int(leaf.def_levels[i]), 0)
    var arr = leaf.column.as_primitive[DType.int32]()
    assert_equal(arr.length, 3)
    assert_equal(arr.get_typed[Int32](0), Int32(10))
    assert_equal(arr.get_typed[Int32](2), Int32(30))


def test_an_unsupported_data_page_encoding_is_refused() raises:
    # DELTA_BINARY_PACKED (5) is not an encoding this decoder reads.
    var chunk = List[UInt8]()
    _v1_page(chunk, materialize[_DEFS](), materialize[_REPS](), _ints([1, 2, 3], 4), 5, CompressionCodec.UNCOMPRESSED)
    with assert_raises(contains="unsupported data page encoding DELTA_BINARY_PACKED"):
        _ = decode_column_with_levels(Span(chunk), ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 6, 3, 1)


def test_a_dictionary_page_of_a_type_without_dictionaries_is_refused() raises:
    # A BOOLEAN leaf has no dictionary decoding.
    var chunk = _dict_chunk(2, _ints([1], 1))
    with assert_raises(contains="unsupported dictionary type"):
        _ = decode_column_with_levels(Span(chunk), ParquetType.BOOLEAN, CompressionCodec.UNCOMPRESSED, 2, 3, 1)


def test_a_plain_page_of_a_type_without_a_plain_decoder_is_refused() raises:
    # FIXED_LEN_BYTE_ARRAY leaves are not decoded by this decoder.
    var chunk = List[UInt8]()
    _v1_page(chunk, [3], [0], _ints([1, 2], 1), _PLAIN, CompressionCodec.UNCOMPRESSED)
    with assert_raises(contains="unsupported plain type"):
        _ = decode_column_with_levels(Span(chunk), ParquetType.FIXED_LEN_BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 1, 3, 1)


def test_a_plain_string_with_no_room_for_its_length_prefix_is_refused() raises:
    # The second string starts with only two bytes left, not the four of its
    # length prefix.
    var values = _strings(["ab"])
    values.extend(_ints([1, 2], 1))
    var chunk = List[UInt8]()
    _v1_page(chunk, [3, 3], [0, 1], values, _PLAIN, CompressionCodec.UNCOMPRESSED)
    with assert_raises(contains="value 1 has no room for its length prefix"):
        _ = decode_column_with_levels(Span(chunk), ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 2, 3, 1)


def test_a_compressed_body_smaller_than_its_level_sections_is_refused() raises:
    # The page header parser refuses such a header, so the body decoder is
    # called as a page of that header would call it: 5 bytes of level
    # sections in a page that declares 3 decoded bytes.
    var page = _compressed(CompressionCodec.SNAPPY, _ints([1, 2, 3, 4, 5, 6], 1))
    with assert_raises(contains="uncompressed_page_size 3 is smaller than its level sections"):
        _ = _page_body(CompressionCodec.SNAPPY, Span(page), 3, 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

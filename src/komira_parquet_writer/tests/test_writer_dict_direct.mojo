# Dictionary column chunks (`writer_dict`, `writer_dict_numeric`), read back
# by a page reader written in this file.
#
# What each test proves, and the defect it catches:
#   * test_index_stream_*: the bit-width byte, one bit-packed run padded to
#     a group of 8, decoding to the indices at every width 1..20; a one-entry
#     dictionary is width 0 AND an RLE run of the row count (a stream of the
#     width byte alone decodes to zero indices; red under that mutant); a
#     width over 32 is refused.
#   * test_string_chunk_layout: [DICTIONARY_PAGE (PLAIN BYTE_ARRAY values,
#     num_values = cardinality)][DATA_PAGE (RLE_DICTIONARY, levels, indices
#     of the non-null rows)], the sizes and `dict_page_size` the file
#     writer needs, and the encodings list.
#   * test_string_high_cardinality_is_none: over the threshold the encoder
#     returns None (write PLAIN), never a failure.
#   * test_numeric_sliced_nullable: a SLICED INT64 column: levels and the
#     indices name the slice's own rows (the predecessor's levels ignored
#     the offset; red under that mutant), the dictionary values are the
#     distinct non-null values in first-seen order, and the statistics skip
#     the null slot.
#   * test_numeric_float_stats_and_signed_zero: -0.0 and +0.0 are two
#     dictionary entries; statistics carry no nan_count (a dictionary
#     cannot count NaN rows).
#   * test_required_with_null_is_refused, test_compressed_bodies.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_parquet_codec.compression import decompress
from komira_parquet_writer import (
    encode_dict_indices_rle,
    encode_dict_numeric_column_page,
    encode_dict_string_column_page,
)


# --- an independent reader for what the encoders write -----------------------
# Written here from parquet.thrift and parquet-format Encodings.md, not from
# the package's code and not from the package's reader.


def _uvarint(b: List[UInt8], mut pos: Int) raises -> UInt64:
    var shift = UInt64(0)
    var v = UInt64(0)
    while True:
        if pos >= len(b):
            raise Error("varint runs past the end")
        var x = UInt64(b[pos])
        pos += 1
        v |= (x & 0x7F) << shift
        if x & 0x80 == 0:
            break
        shift += 7
    return v


def _varint(b: List[UInt8], mut pos: Int) raises -> Int:
    return Int(_uvarint(b, pos))


def _unzig64(z: UInt64) -> Int64:
    return Int64(z >> 1) ^ -Int64(z & 1)


def _unzig(v: Int) -> Int:
    return (v >> 1) ^ -(v & 1)


def _skip(b: List[UInt8], mut pos: Int, t: Int) raises:
    if t == 1 or t == 2:
        return
    if t == 3:
        pos += 1
        return
    if t == 4 or t == 5 or t == 6:
        _ = _varint(b, pos)
        return
    if t == 8:
        var n = _varint(b, pos)
        pos += n
        return
    if t == 12:
        var last = 0
        while True:
            var h = Int(b[pos])
            pos += 1
            if h == 0:
                return
            if h >> 4 == 0:
                last = _unzig(_varint(b, pos))
            _skip(b, pos, h & 0xF)
        return
    raise Error("unexpected compact type " + String(t))


@fieldwise_init
struct Page(Copyable, Movable):
    var type: Int
    var uncompressed: Int
    var compressed: Int
    var num_values: Int
    var encoding: Int
    var def_encoding: Int
    var body_start: Int
    var end: Int


def _page(b: List[UInt8], start: Int) raises -> Page:
    """Parse the PageHeader at `start`: fields 1, 2, 3 and the DataPageHeader
    (5) or DictionaryPageHeader (7)."""
    var pos = start
    var last = 0
    var p = Page(-1, -1, -1, -1, -1, -1, -1, -1)
    while True:
        var h = Int(b[pos])
        pos += 1
        if h == 0:
            break
        var t = h & 0xF
        var id = last + (h >> 4) if h >> 4 != 0 else _unzig(_varint(b, pos))
        last = id
        if id == 1 and t == 5:
            p.type = _unzig(_varint(b, pos))
        elif id == 2 and t == 5:
            p.uncompressed = _unzig(_varint(b, pos))
        elif id == 3 and t == 5:
            p.compressed = _unzig(_varint(b, pos))
        elif (id == 5 or id == 7) and t == 12:
            var ilast = 0
            while True:
                var ih = Int(b[pos])
                pos += 1
                if ih == 0:
                    break
                var it = ih & 0xF
                var iid = ilast + (ih >> 4) if ih >> 4 != 0 else _unzig(_varint(b, pos))
                ilast = iid
                if iid == 1 and it == 5:
                    p.num_values = _unzig(_varint(b, pos))
                elif iid == 2 and it == 5:
                    p.encoding = _unzig(_varint(b, pos))
                elif iid == 3 and it == 5 and id == 5:
                    p.def_encoding = _unzig(_varint(b, pos))
                else:
                    _skip(b, pos, it)
        else:
            _skip(b, pos, t)
    p.body_start = pos
    p.end = pos + p.compressed
    return p^


def _slice(b: List[UInt8], start: Int, end: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=max(end - start, 1))
    for i in range(start, end):
        out.append(b[i])
    return out^


def _bits(b: List[UInt8], bit_pos: Int, width: Int) -> UInt64:
    """`width` bits starting at bit `bit_pos`, LSB first."""
    var v = UInt64(0)
    for k in range(width):
        var at = bit_pos + k
        if (b[at >> 3] >> UInt8(at & 7)) & 1 == 1:
            v |= UInt64(1) << UInt64(k)
    return v


def _hybrid(b: List[UInt8], start: Int, end: Int, width: Int, count: Int) raises -> List[Int]:
    """Decode `count` values of the RLE / bit-packed hybrid in [start, end)."""
    var out = List[Int]()
    var pos = start
    while len(out) < count:
        if pos >= end:
            raise Error("hybrid stream ends after " + String(len(out)) + " of " + String(count))
        var h = _varint(b, pos)
        if h & 1 == 1:
            var n = (h >> 1) * 8
            var region = _slice(b, pos, pos + (h >> 1) * width)
            for i in range(n):
                if len(out) < count:
                    out.append(Int(_bits(region, i * width, width)))
            pos += (h >> 1) * width
        else:
            var run = h >> 1
            var v = 0
            for k in range((width + 7) // 8):
                v |= Int(b[pos + k]) << (8 * k)
            pos += (width + 7) // 8
            for _ in range(run):
                if len(out) < count:
                    out.append(v)
    return out^


@fieldwise_init
struct Levels(Movable):
    var values: List[Int]
    var end: Int


def _levels(body: List[UInt8], count: Int) raises -> Levels:
    """V1 definition levels (max 1): 4-byte LE length, then the hybrid.
    Returns the levels and the offset of the values after them."""
    var n = Int(body[0]) | (Int(body[1]) << 8) | (Int(body[2]) << 16) | (Int(body[3]) << 24)
    return Levels(_hybrid(body, 4, 4 + n, 1, count), 4 + n)


def test_index_stream_widths() raises:
    for w in range(1, 21):
        var idx = List[Int32]()
        for i in range(29):
            idx.append(Int32((i * 7919) % (1 << w)))
        var enc = encode_dict_indices_rle(idx, w)
        assert_equal(Int(enc[0]), w, "width byte")
        var got = _hybrid(enc, 1, len(enc), w, 29)
        for i in range(29):
            assert_equal(got[i], Int(idx[i]), "w=" + String(w) + " index " + String(i))
        # One run of 4 groups: header 9, then 4 * w bytes.
        assert_equal(len(enc), 2 + 4 * w)


def test_index_stream_width_zero_is_a_run() raises:
    var idx = List[Int32]()
    for _ in range(300):
        idx.append(0)
    var enc = encode_dict_indices_rle(idx, 0)
    # [0x00][varint 600 = 0xD8 0x04]
    assert_equal(len(enc), 3)
    assert_equal(Int(enc[0]), 0)
    var got = _hybrid(enc, 1, len(enc), 0, 300)
    assert_equal(len(got), 300)
    with assert_raises(contains="outside [0, 32]"):
        _ = encode_dict_indices_rle(idx, 33)


def test_string_chunk_layout() raises:
    var vals: List[String] = ["a", "bb", "a", "", "bb", "a", "a", "bb", "a", "a"]
    var valid: List[Bool] = [True, True, True, False, True, True, True, True, True, True]
    var s = StringArray.from_strings_with_validity(vals, valid)
    var page = encode_dict_string_column_page(2, s, "s", cardinality_threshold=0.5).value().copy()
    var d = _page(page.data, 0)
    assert_equal(d.type, 2, "DICTIONARY_PAGE")
    assert_equal(d.encoding, Int(Encoding.PLAIN.value))
    var dict_body = _slice(page.data, d.body_start, d.end)
    assert_equal(page.dict_page_size, d.end)
    var p = _page(page.data, d.end)
    assert_equal(p.type, 0, "DATA_PAGE")
    assert_equal(p.encoding, Int(Encoding.RLE_DICTIONARY.value))
    assert_equal(p.num_values, 10)
    assert_equal(p.end, len(page.data))
    assert_equal(page.uncompressed_size, d.uncompressed + p.uncompressed)
    assert_equal(page.compressed_size, d.compressed + p.compressed)
    # Dictionary entries, in first-seen order; read their strings.
    var entries = List[String]()
    var pos = 0
    for _ in range(d.num_values):
        var n = Int(dict_body[pos]) | (Int(dict_body[pos + 1]) << 8)
        pos += 4
        var e = String()
        for k in range(n):
            e += chr(Int(dict_body[pos + k]))
        pos += n
        entries.append(e^)
    assert_equal(pos, len(dict_body))
    var body = _slice(page.data, p.body_start, p.end)
    var lv = _levels(body, 10)
    assert_equal(lv.values[3], 0)
    var width = Int(body[lv.end])
    var idx = _hybrid(body, lv.end + 1, len(body), width, 9)
    var k = 0
    for i in range(10):
        if i == 3:
            continue
        assert_equal(entries[idx[k]], vals[i], "row " + String(i))
        k += 1
    assert_equal(len(page.encodings), 3)
    assert_true(page.parquet_type == ParquetType.BYTE_ARRAY)
    assert_equal(page.column_index, 2)


def test_string_high_cardinality_is_none() raises:
    var vals: List[String] = ["a", "b", "c", "d", "e"]
    var s = StringArray.from_strings(vals)
    assert_false(encode_dict_string_column_page(0, s, "s").__bool__())


def test_numeric_sliced_nullable() raises:
    var a = PrimitiveArray[DType.int64].allocate_nullable(40)
    for i in range(40):
        a.set(i, Int64((i % 4) * 10))
    a.set(13, -777)
    a._set_null(13)
    var s = a.slice(5, 20)
    var page = encode_dict_numeric_column_page[DType.int64](0, s, "n", nullable=True).value().copy()
    var d = _page(page.data, 0)
    var dict_body = _slice(page.data, d.body_start, d.end)
    assert_equal(d.num_values, 4)
    var dv = List[Int]()
    for e in range(4):
        dv.append(Int(dict_body[e * 8]))
    # Rows 5, 6, 7, 8 -> 10, 20, 30, 0: first-seen order.
    assert_equal(dv[0], 10)
    assert_equal(dv[1], 20)
    assert_equal(dv[2], 30)
    assert_equal(dv[3], 0)
    var p = _page(page.data, d.end)
    var body = _slice(page.data, p.body_start, p.end)
    var lv = _levels(body, 20)
    for i in range(20):
        assert_equal(lv.values[i], 0 if i + 5 == 13 else 1, "level " + String(i))
    var idx = _hybrid(body, lv.end + 1, len(body), Int(body[lv.end]), 19)
    var k = 0
    for i in range(20):
        if i + 5 == 13:
            continue
        assert_equal(dv[idx[k]], ((i + 5) % 4) * 10, "row " + String(i))
        k += 1
    ref st = page.statistics.value()
    assert_equal(st.null_count.value(), 1)
    assert_equal(Int(st.min_value.value()[0]), 0, "the null slot's -777 is not the min")
    assert_equal(Int(st.max_value.value()[0]), 30)
    assert_true(st.distinct_count.__bool__(), "INT64 dictionary carries an HLL count")


def test_numeric_float_stats_and_signed_zero() raises:
    var a = PrimitiveArray[DType.float64].from_list([0.0, -0.0, 1.5, 0.0, 1.5])
    var page = encode_dict_numeric_column_page[DType.float64](0, a, "f").value().copy()
    var d = _page(page.data, 0)
    assert_equal(d.num_values, 3, "-0.0 and +0.0 are two entries")
    ref st = page.statistics.value()
    assert_false(st.nan_count.__bool__())
    assert_true(page.parquet_type == ParquetType.DOUBLE)


def test_required_with_null_is_refused() raises:
    var a = PrimitiveArray[DType.int32].allocate_nullable(3)
    a._set_null(0)
    with assert_raises(contains="is REQUIRED but holds"):
        _ = encode_dict_numeric_column_page[DType.int32](0, a, "n", nullable=False)


def test_compressed_bodies() raises:
    var vals = List[String]()
    for i in range(3000):
        vals.append(String("value-") + String(i % 5))
    var s = StringArray.from_strings(vals)
    var page = encode_dict_string_column_page(
        0, s, "s", nullable=False, codec=CompressionCodec.SNAPPY
    ).value().copy()
    var d = _page(page.data, 0)
    var p = _page(page.data, d.end)
    var raw = List[UInt8](length=p.uncompressed, fill=UInt8(0))
    var body = _slice(page.data, p.body_start, p.end)
    var n = decompress(CompressionCodec.SNAPPY, Span(body), Span(raw))
    assert_equal(n, p.uncompressed)
    var idx = _hybrid(raw, 1, len(raw), Int(raw[0]), 3000)
    assert_equal(idx[7], 2)
    assert_equal(len(page.encodings), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

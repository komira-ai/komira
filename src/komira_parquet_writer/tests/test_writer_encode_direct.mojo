# The PLAIN page encoders (`writer_encode`) and the page assembler
# (`column_page`), read back by a page reader written in this file.
#
# What each test proves, and the defect it catches:
#   * test_def_levels_*: the V1 level frame (4-byte length, one bit-packed
#     run) decodes to the validity of rows [offset, offset + n). The
#     predecessor copied the bitmap from bit 0 whatever the array's offset,
#     so a sliced array's levels named other rows' nulls (red with the
#     offset ignored); bits past the last row are 0.
#   * test_plain_values_sliced_nullable: the non-null values of a SLICED
#     array, in order. The predecessor tested validity bit i instead of
#     offset + i (red under that mutant).
#   * test_plain_column_*: header (DATA_PAGE, sizes, num_values counting
#     nulls, PLAIN, RLE levels), body = levels then non-null values; an
#     OPTIONAL column with no null still carries levels; statistics skip
#     null slots; the encodings list; a REQUIRED column holding a null is
#     refused rather than writing the null slot's bytes as a value.
#   * test_compressed_page: the body decompresses to the uncompressed body
#     and the header holds both sizes.
#   * test_strings_*: BYTE_ARRAY bytes, nulls skipped; the large-offset
#     twin's page is byte-identical.
#   * test_boolean_*: one bit per value LSB first, nulls skipped, tail 0.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_parquet_codec.compression import decompress
from komira_parquet_writer import (
    encode_boolean_column_page,
    encode_def_levels_all_valid,
    encode_def_levels_from_bitmap,
    encode_large_string_column_page,
    encode_plain_boolean_data,
    encode_plain_byte_array_data,
    encode_plain_column,
    encode_plain_values,
    encode_string_column_page,
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


# --- fixtures ---------------------------------------------------------------


def _nullable_i64(n: Int, null_every: Int) raises -> PrimitiveArray[DType.int64]:
    """Rows 0..n-1 hold 100 + i; every `null_every`-th row is null and its
    slot holds a hostile value."""
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        if i % null_every == 1:
            a.set(i, -999999)
            a._set_null(i)
        else:
            a.set(i, Int64(100 + i))
    return a^


def _le_i64(b: List[UInt8], at: Int) -> Int64:
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(b[at + k]) << UInt64(8 * k)
    return Int64(v)


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), what + ": byte " + String(i))


# --- definition levels --------------------------------------------------------


def test_def_levels_all_valid_frame() raises:
    _same(encode_def_levels_all_valid(0), [0, 0, 0, 0], "empty")
    # 10 levels: two groups -> header (2 << 1) | 1 = 5, then 0xFF, 0x03.
    _same(encode_def_levels_all_valid(10), [3, 0, 0, 0, 5, 0xFF, 0x03], "10 levels")


def test_def_levels_refuse_a_negative_count() raises:
    with assert_raises(contains="negative level count -1"):
        _ = encode_def_levels_all_valid(-1)
    var a = _nullable_i64(8, 3)
    with assert_raises(contains="negative level count -1"):
        _ = encode_def_levels_from_bitmap(a.validity.value(), 0, -1)


def test_def_levels_follow_the_offset() raises:
    var a = _nullable_i64(40, 3)
    for start in range(0, 12):
        var s = a.slice(start, 20)
        var lv = encode_def_levels_from_bitmap(s.validity.value(), s.offset, s.length)
        var got = _levels(lv, 20)
        for i in range(20):
            var want = 0 if (start + i) % 3 == 1 else 1
            assert_equal(
                got.values[i], want, "slice at " + String(start) + ", row " + String(i)
            )
        # Bits past row 20 in the last byte are 0 (deterministic bytes).
        assert_equal(Int(lv[len(lv) - 1]) >> 4, 0, "tail bits at " + String(start))


# --- PLAIN values -------------------------------------------------------------


def test_plain_values_sliced_nullable() raises:
    var a = _nullable_i64(30, 4)
    var s = a.slice(5, 17)
    var bytes = encode_plain_values[DType.int64](s, skip_nulls=True)
    var want = List[Int64]()
    for i in range(5, 22):
        if i % 4 != 1:
            want.append(Int64(100 + i))
    assert_equal(len(bytes), len(want) * 8)
    for k in range(len(want)):
        assert_equal(_le_i64(bytes, k * 8), want[k], "value " + String(k))


def test_plain_column_optional_with_nulls() raises:
    var a = _nullable_i64(9, 3)
    var page = encode_plain_column[DType.int64](4, a, "c", nullable=True)
    var p = _page(page.data, 0)
    assert_equal(p.type, 0, "DATA_PAGE")
    assert_equal(p.num_values, 9, "num_values counts the nulls")
    assert_equal(p.encoding, Int(Encoding.PLAIN.value))
    assert_equal(p.def_encoding, Int(Encoding.RLE.value))
    assert_equal(p.end, len(page.data), "one page, nothing after it")
    assert_equal(p.uncompressed, p.compressed)
    assert_equal(page.uncompressed_size, p.uncompressed)
    assert_equal(page.compressed_size, p.compressed)
    var body = _slice(page.data, p.body_start, p.end)
    var lv = _levels(body, 9)
    var at = lv.end
    for i in range(9):
        assert_equal(lv.values[i], 0 if i % 3 == 1 else 1, "level " + String(i))
        if i % 3 != 1:
            assert_equal(_le_i64(body, at), Int64(100 + i), "value of row " + String(i))
            at += 8
    assert_equal(at, len(body), "only the non-null values follow the levels")
    ref st = page.statistics.value()
    assert_equal(st.null_count.value(), 3)
    assert_equal(_le_i64(st.min_value.value(), 0), 100, "a null slot's -999999 is not the min")
    assert_equal(_le_i64(st.max_value.value(), 0), 108)
    assert_equal(len(page.encodings), 2)
    assert_true(page.encodings[0] == Encoding.RLE and page.encodings[1] == Encoding.PLAIN)
    assert_true(page.parquet_type == ParquetType.INT64)
    assert_equal(page.column_index, 4)


def test_plain_column_optional_without_nulls_has_levels() raises:
    var a = PrimitiveArray[DType.int32].from_list([7, 8, 9])
    var page = encode_plain_column[DType.int32](0, a, "c", nullable=True)
    var p = _page(page.data, 0)
    var body = _slice(page.data, p.body_start, p.end)
    var lv = _levels(body, 3)
    assert_equal(len(body) - lv.end, 12, "three INT32 values after the levels")


def test_plain_column_required() raises:
    var a = PrimitiveArray[DType.float64].from_list([1.5, -2.0, 3.25])
    var page = encode_plain_column[DType.float64](0, a, "c")
    var p = _page(page.data, 0)
    assert_equal(p.compressed, 24, "no levels for a REQUIRED column")
    assert_equal(len(page.encodings), 1)
    assert_true(page.parquet_type == ParquetType.DOUBLE)
    assert_true(page.statistics.__bool__(), "DOUBLE statistics")


def test_required_column_with_a_null_is_refused() raises:
    var a = _nullable_i64(4, 2)
    with assert_raises(contains="is REQUIRED but holds"):
        _ = encode_plain_column[DType.int64](0, a, "c", nullable=False)


def test_compressed_page() raises:
    var a = PrimitiveArray[DType.int64].allocate(4000)
    for i in range(4000):
        a.set(i, Int64(i % 13))
    var page = encode_plain_column[DType.int64](0, a, "c", codec=CompressionCodec.ZSTD)
    var p = _page(page.data, 0)
    assert_true(p.compressed < p.uncompressed, "compressed")
    assert_equal(p.uncompressed, 32000)
    var out = List[UInt8](length=p.uncompressed, fill=UInt8(0))
    var body = _slice(page.data, p.body_start, p.end)
    var n = decompress(CompressionCodec.ZSTD, Span(body), Span(out))
    assert_equal(n, 32000)
    for i in range(4000):
        assert_equal(_le_i64(out, i * 8), Int64(i % 13))
    assert_true(page.codec == CompressionCodec.ZSTD)


# --- strings and booleans -----------------------------------------------------


def test_strings_plain_bytes() raises:
    var vals: List[String] = ["ab", "", "xyz", "q"]
    var valid: List[Bool] = [True, True, False, True]
    var s = StringArray.from_strings_with_validity(vals, valid)
    var b = encode_plain_byte_array_data(s)
    _same(b, [2, 0, 0, 0, 97, 98, 0, 0, 0, 0, 1, 0, 0, 0, 113], "nulls skipped")


def test_strings_page_and_large_twin_identical() raises:
    var vals: List[String] = ["red", "green", "", "blue", "red"]
    var valid: List[Bool] = [True, False, True, True, True]
    var narrow = StringArray.from_strings_with_validity(vals, valid)
    var wide = LargeStringArray.from_strings_with_validity(vals, valid)
    var p1 = encode_string_column_page(0, narrow, "s")
    var p2 = encode_large_string_column_page(0, wide, "s")
    _same(p1.data, p2.data, "narrow and large pages")
    var p = _page(p1.data, 0)
    var body = _slice(p1.data, p.body_start, p.end)
    var lv = _levels(body, 5)
    assert_equal(lv.values[1], 0)
    assert_equal(len(body) - lv.end, 4 * 4 + 3 + 0 + 4 + 3, "four values")
    with assert_raises(contains="is REQUIRED but holds"):
        _ = encode_string_column_page(0, narrow, "s", nullable=False)


def test_boolean_bits() raises:
    var a = BooleanArray.allocate_nullable(11)
    for i in range(11):
        a.set(i, i % 3 == 0)
    a._set_null(3)
    a._set_null(10)
    # Non-null rows 0,1,2,4,5,6,7,8,9 -> T F F F F T F F T.
    _same(encode_plain_boolean_data(a), [0b00100001, 0b00000001], "nulls skipped")
    var b = BooleanArray.allocate(11)
    for i in range(11):
        b.set(i, True)
    _same(encode_plain_boolean_data(b), [0xFF, 0x07], "tail bits are 0")
    var page = encode_boolean_column_page(0, a, "b")
    var p = _page(page.data, 0)
    assert_equal(p.num_values, 11)
    assert_true(page.parquet_type == ParquetType.BOOLEAN)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

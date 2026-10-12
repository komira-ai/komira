# Decimal128 as FIXED_LEN_BYTE_ARRAY(16) DECIMAL (`decimal_encode`).
#
# What each test proves, and the defect it catches:
#   * test_values_are_big_endian: each non-null value is its i128 in 16
#     big-endian two's-complement bytes (a little-endian or sign-dropping
#     write fails on -1 and -256); null rows are skipped after the levels.
#   * test_statistics_signed_order: min/max are the signed i128 extremes in
#     the same form; the null slot's value is not one of them.
#   * test_schema_element: FLBA, type_length 16, ConvertedType DECIMAL,
#     precision/scale, repetition; an invalid precision or scale raises
#     (the predecessor clamped it, which changes every value's meaning: red
#     under that mutant).
#   * test_required_with_null_is_refused: the predecessor skipped the null
#     slot in a REQUIRED page, so the page held fewer values than rows.
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.decimal_array import Decimal128Array
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.types import CONVERTED_TYPE_DECIMAL, FieldRepetitionType, ParquetType
from komira_parquet_writer import decimal128_schema_element, encode_decimal128_column_page


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


comptime I128 = SIMD[DType.int128, 1]


def _big() -> I128:
    return I128(1234567890) * I128(10000000000) + I128(1234567890)


def _be(b: List[UInt8], at: Int) -> I128:
    var v = I128(0)
    for k in range(16):
        v = (v << I128(8)) | I128(Int(b[at + k]))
    return v


def _array() raises -> Decimal128Array[HeapRegion]:
    var a = Decimal128Array.allocate_nullable(4, 20, 2)
    a.set_i128(0, I128(-1))
    a.set_i128(1, _big())
    a.set_i128(2, -(I128(9999999999) * I128(10000000000) + I128(9999999999)))
    a.set_i128(3, I128(-256))
    a.set_null(2)
    return a^


def test_values_are_big_endian() raises:
    var a = _array()
    var page = encode_decimal128_column_page(0, a, "d", nullable=True)
    var p = _page(page.data, 0)
    var body = _slice(page.data, p.body_start, p.end)
    var lv = _levels(body, 4)
    assert_equal(lv.values[2], 0)
    assert_equal(len(body) - lv.end, 48, "three 16-byte values")
    for k in range(16):
        assert_equal(Int(body[lv.end + k]), 0xFF, "-1 is all ones")
    assert_true(_be(body, lv.end + 16) == _big())
    assert_equal(Int(body[lv.end + 32 + 14]), 0xFF)
    assert_equal(Int(body[lv.end + 32 + 15]), 0x00, "-256 ends ..FF 00")
    assert_true(page.parquet_type == ParquetType.FIXED_LEN_BYTE_ARRAY)


def test_statistics_signed_order() raises:
    var a = _array()
    var page = encode_decimal128_column_page(0, a, "d", nullable=True)
    ref st = page.statistics.value()
    assert_true(_be(st.min_value.value(), 0) == I128(-256), "the null slot is not the min")
    assert_true(_be(st.max_value.value(), 0) == _big())
    assert_equal(st.null_count.value(), 1)


def test_schema_element() raises:
    var e = decimal128_schema_element("d", 20, 2, True)
    assert_true(e.type.value() == ParquetType.FIXED_LEN_BYTE_ARRAY)
    assert_equal(e.type_length.value(), 16)
    assert_equal(e.converted_type.value(), CONVERTED_TYPE_DECIMAL)
    assert_equal(e.precision.value(), 20)
    assert_equal(e.scale.value(), 2)
    assert_true(e.repetition_type.value() == FieldRepetitionType.OPTIONAL)
    with assert_raises(contains="precision 0 is outside"):
        _ = decimal128_schema_element("d", 0, 0, False)
    with assert_raises(contains="scale -2 is outside"):
        _ = decimal128_schema_element("d", 10, -2, False)
    with assert_raises(contains="scale 11 is outside"):
        _ = decimal128_schema_element("d", 10, 11, False)


def test_required_with_null_is_refused() raises:
    var a = _array()
    with assert_raises(contains="is REQUIRED but holds"):
        _ = encode_decimal128_column_page(0, a, "d", nullable=False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

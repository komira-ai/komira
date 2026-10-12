# BYTE_STREAM_SPLIT (`writer_bss`) against the definition in
# parquet-format Encodings.md: stream k holds byte k of every value.
#
# What each test proves, and the defect it catches:
#   * test_transpose_matches_definition: every count 0..70 for FLOAT and
#     DOUBLE (the 16-value shuffle path, its byte tail, and both together)
#     against a byte-at-a-time transpose written here. A wrong shuffle mask
#     or a tail that writes the wrong stream fails it.
#   * test_ragged_input_refused: a byte count that is not whole values.
#   * test_page_*: header encoding BYTE_STREAM_SPLIT, levels for OPTIONAL
#     then the transposed NON-NULL values of a sliced array (a null slot's
#     bytes in the streams, or another row's, fail it); FLOAT statistics
#     with the NaN excluded from min/max; a REQUIRED column with a null is
#     refused.
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_api.types import Encoding, ParquetType
from komira_parquet_writer import encode_bss_column_page, encode_byte_stream_split
from komira_parquet_writer.writer_encode import encode_plain_values


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


def _reference(plain: List[UInt8], k: Int) -> List[UInt8]:
    var n = len(plain) // k
    var out = List[UInt8](length=len(plain), fill=UInt8(0))
    for i in range(n):
        for s in range(k):
            out[s * n + i] = plain[i * k + s]
    return out^


def _pattern(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i * 37 + 11) % 251))
    return out^


def test_transpose_matches_definition() raises:
    for n in range(0, 71):
        var p4 = _pattern(n * 4)
        var got4 = encode_byte_stream_split[DType.float32](p4)
        var want4 = _reference(p4, 4)
        assert_equal(len(got4), len(want4))
        for i in range(len(want4)):
            assert_equal(Int(got4[i]), Int(want4[i]), "f32 n=" + String(n) + " byte " + String(i))
        var p8 = _pattern(n * 8)
        var got8 = encode_byte_stream_split[DType.float64](p8)
        var want8 = _reference(p8, 8)
        assert_equal(len(got8), len(want8))
        for i in range(len(want8)):
            assert_equal(Int(got8[i]), Int(want8[i]), "f64 n=" + String(n) + " byte " + String(i))


def test_ragged_input_refused() raises:
    with assert_raises(contains="not a whole number"):
        _ = encode_byte_stream_split[DType.float64](_pattern(12))


def test_page_optional_sliced() raises:
    var a = PrimitiveArray[DType.float64].allocate_nullable(40)
    for i in range(40):
        a.set(i, Float64(i) + 0.5)
    a.set(9, 1.0e300)
    a._set_null(9)
    a._set_null(20)
    var s = a.slice(3, 30)
    var page = encode_bss_column_page[DType.float64](0, s, "f", nullable=True)
    # The page is built from the non-null rows 3..32 except 9 and 20.
    var want_vals = List[Float64]()
    for i in range(3, 33):
        if i != 9 and i != 20:
            want_vals.append(Float64(i) + 0.5)
    var dense = PrimitiveArray[DType.float64].from_list(want_vals)
    var want = _reference(encode_plain_values[DType.float64](dense, skip_nulls=False), 8)

    var p = _page(page.data, 0)
    assert_equal(p.encoding, Int(Encoding.BYTE_STREAM_SPLIT.value))
    assert_equal(p.num_values, 30)
    var body = _slice(page.data, p.body_start, p.end)
    var lv = _levels(body, 30)
    assert_equal(lv.values[6], 0, "row 9 is null")
    assert_equal(lv.values[17], 0, "row 20 is null")
    assert_equal(len(body) - lv.end, len(want))
    for i in range(len(want)):
        assert_equal(Int(body[lv.end + i]), Int(want[i]), "stream byte " + String(i))
    ref st = page.statistics.value()
    assert_equal(st.null_count.value(), 2)
    assert_true(page.parquet_type == ParquetType.DOUBLE)


def test_page_float_nan_not_in_minmax() raises:
    var a = PrimitiveArray[DType.float32].from_list([2.0, Float32.MAX, 1.0])
    a.set(1, Float32(0.0) / Float32(0.0))
    var page = encode_bss_column_page[DType.float32](0, a, "f")
    ref st = page.statistics.value()
    var mx = st.max_value.value().copy()
    var bits = UInt32(mx[0]) | (UInt32(mx[1]) << 8) | (UInt32(mx[2]) << 16) | (UInt32(mx[3]) << 24)
    assert_equal(bits, UInt32(0x40000000), "max is 2.0, not NaN")
    assert_equal(st.nan_count.value(), 1)
    var b = PrimitiveArray[DType.float32].allocate_nullable(2)
    b._set_null(1)
    with assert_raises(contains="is REQUIRED but holds"):
        _ = encode_bss_column_page[DType.float32](0, b, "f")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

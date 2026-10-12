# DELTA_BINARY_PACKED (`writer_delta`), decoded by a reader written in this
# file from parquet-format Encodings.md.
#
# What each test proves, and the defect it catches:
#   * test_exact_bytes_small: the header (2048, 8, count, zigzag first
#     value) and a block whose deltas all equal min_delta: eight width-0
#     bytes and no miniblock body.
#   * test_round_trip_*: every count 0..300 and 2049/4100 (partial and
#     several blocks), random INT64 and INT32 values, decode to the input.
#   * test_int64_deltas_wider_than_signed: deltas spanning more than the
#     signed 64-bit range. The predecessor took `delta - min_delta` as a
#     SIGNED subtraction; it overflowed, the miniblock got width 0 and the
#     values decoded wrong (red under that mutant).
#   * test_int32_widths_never_exceed_32: INT32 values at both extremes. The
#     predecessor took INT32 deltas in 64-bit arithmetic, so a miniblock
#     could be 33 bits wide, which a reader rejects for INT32 (red under
#     that mutant); 32-bit wrapping deltas still decode exactly.
#   * test_page_*: header encoding DELTA_BINARY_PACKED, levels for OPTIONAL,
#     the body holds the non-null values only, min/max skip null slots, a
#     REQUIRED column with a null is refused.
from std.random import random_si64, seed
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_api.types import Encoding, ParquetType
from komira_parquet_writer import (
    encode_dbp_column_page,
    encode_delta_binary_packed_i32,
    encode_delta_binary_packed_i64,
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


@fieldwise_init
struct Decoded(Movable):
    var values: List[Int64]
    var max_width: Int
    var end: Int


def _dbp_decode(b: List[UInt8], start: Int, int32: Bool) raises -> Decoded:
    var pos = start
    var block = _varint(b, pos)
    var mbs = _varint(b, pos)
    var total = _varint(b, pos)
    var cur = _unzig64(_uvarint(b, pos))
    var out = List[Int64]()
    var max_width = 0
    if total == 0:
        return Decoded(out^, 0, pos)
    out.append(cur)
    var per_mb = block // mbs
    while len(out) < total:
        var min_delta = _unzig64(_uvarint(b, pos))
        var widths = List[Int]()
        for _ in range(mbs):
            widths.append(Int(b[pos]))
            pos += 1
        for mb in range(mbs):
            if len(out) >= total:
                break
            var w = widths[mb]
            max_width = max(max_width, w)
            var region = _slice(b, pos, pos + per_mb * w // 8)
            for k in range(per_mb):
                if len(out) >= total:
                    break
                var adj = _bits(region, k * w, w) if w > 0 else UInt64(0)
                var next = UInt64(cur) + UInt64(min_delta) + adj
                if int32:
                    cur = Int64(Int32(next))
                else:
                    cur = Int64(next)
                out.append(cur)
            pos += per_mb * w // 8
    return Decoded(out^, max_width, pos)


def _check_i64(values: List[Int64], what: String) raises:
    var enc = encode_delta_binary_packed_i64(values)
    var d = _dbp_decode(enc, 0, False)
    assert_equal(d.end, len(enc), what + ": every byte consumed")
    assert_equal(len(d.values), len(values), what + ": count")
    for i in range(len(values)):
        assert_equal(d.values[i], values[i], what + ": value " + String(i))


def _check_i32(values: List[Int32], what: String) raises:
    var enc = encode_delta_binary_packed_i32(values)
    var d = _dbp_decode(enc, 0, True)
    assert_equal(d.end, len(enc), what + ": every byte consumed")
    assert_true(d.max_width <= 32, what + ": INT32 miniblock wider than 32 bits")
    assert_equal(len(d.values), len(values), what + ": count")
    for i in range(len(values)):
        assert_equal(Int(d.values[i]), Int(values[i]), what + ": value " + String(i))


def test_exact_bytes_small() raises:
    var enc = encode_delta_binary_packed_i64([1, 2, 3, 4, 5])
    var want: List[UInt8] = [0x80, 0x10, 0x08, 0x05, 0x02, 0x02, 0, 0, 0, 0, 0, 0, 0, 0]
    assert_equal(len(enc), len(want))
    for i in range(len(want)):
        assert_equal(Int(enc[i]), Int(want[i]), "byte " + String(i))
    var empty = encode_delta_binary_packed_i64(List[Int64]())
    assert_equal(len(empty), 5, "header only: 2048, 8, 0, 0")


def test_round_trip_int64() raises:
    seed(7)
    var counts: List[Int] = [2049, 4100]
    for n in range(0, 301):
        counts.append(n)
    for c in range(len(counts)):
        var n = counts[c]
        var v = List[Int64]()
        for i in range(n):
            # Mostly small steps, sometimes a big jump.
            if i % 37 == 5:
                v.append(random_si64(-(1 << 60), 1 << 60))
            else:
                v.append(Int64(i * 3) + random_si64(-50, 50))
        _check_i64(v, "n=" + String(n))


def test_round_trip_int32() raises:
    seed(11)
    for n in range(0, 301):
        var v = List[Int32]()
        for i in range(n):
            v.append(Int32(random_si64(-1000000, 1000000)))
        _check_i32(v, "n=" + String(n))


def test_int64_deltas_wider_than_signed() raises:
    var lo = Int64.MIN
    var hi = Int64.MAX
    _check_i64([0, -6000000000000000000, 0, 6000000000000000000, 0], "wide deltas")
    _check_i64([lo, hi, lo, hi, 0, lo], "extremes")


def test_int32_widths_never_exceed_32() raises:
    var lo = Int32.MIN
    var hi = Int32.MAX
    _check_i32([lo, hi, lo, hi, 0, -1, hi], "extremes")
    var v = List[Int32]()
    for i in range(600):
        v.append(lo if i % 2 == 0 else hi)
    _check_i32(v, "alternating extremes")


def test_page_optional_int64() raises:
    var a = PrimitiveArray[DType.int64].allocate_nullable(10)
    for i in range(10):
        a.set(i, Int64(1000 - i * 7))
    a.set(4, 999999999)
    a._set_null(4)
    var page = encode_dbp_column_page[DType.int64](0, a, "c", nullable=True)
    var p = _page(page.data, 0)
    assert_equal(p.encoding, Int(Encoding.DELTA_BINARY_PACKED.value))
    assert_equal(p.num_values, 10)
    var body = _slice(page.data, p.body_start, p.end)
    var lv = _levels(body, 10)
    assert_equal(lv.values[4], 0)
    var d = _dbp_decode(body, lv.end, False)
    assert_equal(d.end, len(body))
    assert_equal(len(d.values), 9, "non-null values only")
    assert_equal(d.values[4], 1000 - 35, "row 5 follows row 3")
    ref st = page.statistics.value()
    assert_equal(st.null_count.value(), 1)
    var mn = st.min_value.value().copy()
    var mx = st.max_value.value().copy()
    assert_equal(Int(mn[0]) | (Int(mn[1]) << 8), 1000 - 63)
    assert_equal(Int(mx[0]) | (Int(mx[1]) << 8), 1000, "the null slot's value is not the max")
    assert_true(page.parquet_type == ParquetType.INT64)


def test_page_required_int32() raises:
    var a = PrimitiveArray[DType.int32].from_list([5, -5, 7])
    var page = encode_dbp_column_page[DType.int32](0, a, "c")
    var p = _page(page.data, 0)
    var body = _slice(page.data, p.body_start, p.end)
    var d = _dbp_decode(body, 0, True)
    assert_equal(len(d.values), 3)
    assert_equal(Int(d.values[1]), -5)
    assert_equal(len(page.encodings), 1)
    var b = PrimitiveArray[DType.int32].allocate_nullable(2)
    b._set_null(0)
    with assert_raises(contains="is REQUIRED but holds"):
        _ = encode_dbp_column_page[DType.int32](0, b, "c", nullable=False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

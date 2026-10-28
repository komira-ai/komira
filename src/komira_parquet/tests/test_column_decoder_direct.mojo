# Direct tests of `decode_column_pages` (column_decoder) on chunks of
# non-dictionary pages: the single PLAIN page moved into its column, nullable
# V1 and V2 pages, BOOLEAN, INT96, FIXED_LEN_BYTE_ARRAY, DELTA_BINARY_PACKED,
# BYTE_STREAM_SPLIT, DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY pages, the
# page CRC, and the malformed chunks it refuses. Dictionary chunks are in
# test_column_decoder_dict_direct; files pyarrow wrote are in
# test_column_decoder_pyarrow.
#
# Chunks are encoded here from parquet-format: Thrift Compact page headers
# (parquet.thrift), PLAIN values, RLE / bit-packed hybrid levels, and the
# DELTA encodings (Encodings.md).
from std.memory import bitcast
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.column_decoder import (
    NumericDictCodesHolder,
    decode_column_pages,
)
from komira_parquet.scan_copy_trace import (
    bss_decode_copy_count,
    bss_decode_into_count,
    reset_scan_copy_counts,
    reset_scan_copy_gates,
    set_bss_decode_into_enabled,
)

comptime _DATA = 0
comptime _V2 = 3
comptime _PLAIN = 0
comptime _RLE = 3
comptime _DBP = 5
comptime _DLBA = 6
comptime _DBA = 7
comptime _BSS = 9
comptime _NO_CRC = -1
comptime _GOOD_CRC = -2
comptime _CRC32_POLY: UInt32 = 0xEDB88320
comptime _CRC32C_POLY: UInt32 = 0x82F63B78


# --- encoders ----------------------------------------------------------------


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(v: Int) -> Int:
    return (v << 1) ^ (v >> 63)


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _crc(data: List[UInt8], poly: UInt32) -> UInt32:
    """A reflected CRC-32 by the bit: `poly` 0xEDB88320 is CRC-32 (gzip),
    0x82F63B78 is CRC-32C (Castagnoli)."""
    var c = UInt32(0xFFFFFFFF)
    for i in range(len(data)):
        c ^= UInt32(data[i])
        for _ in range(8):
            if c & 1 == 1:
                c = (c >> 1) ^ poly
            else:
                c >>= 1
    return c ^ UInt32(0xFFFFFFFF)


struct _Thrift(Movable):
    """A Thrift Compact writer of the page header fields used here."""

    var b: List[UInt8]
    var last: Int

    def __init__(out self):
        self.b = List[UInt8]()
        self.last = 0

    def field(mut self, id: Int, t: Int):
        self.b.append(UInt8(((id - self.last) << 4) | t))
        self.last = id

    def i32(mut self, id: Int, v: Int):
        self.field(id, 5)
        _uleb(self.b, _zz(v))

    def begin(mut self, id: Int) -> Int:
        self.field(id, 12)
        var saved = self.last
        self.last = 0
        return saved

    def end(mut self, saved: Int):
        self.b.append(UInt8(0))
        self.last = saved


def _stored(codec: CompressionCodec, body: List[UInt8]) raises -> List[UInt8]:
    if codec == CompressionCodec.UNCOMPRESSED:
        return body.copy()
    var out = List[UInt8](length=compress_bound(codec, len(body)), fill=UInt8(0))
    out.resize(compress(codec, Span(body), Span(out)), UInt8(0))
    return out^


def _page(
    mut chunk: List[UInt8],
    page_type: Int,
    nv: Int,
    enc: Int,
    body: List[UInt8],
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
    crc: Int = _NO_CRC,
    def_len: Int = 0,
    v2_compressed: Bool = True,
) raises:
    """Append one page. A V2 page's first `def_len` body bytes are its
    definition level section, stored as is; the rest is compressed."""
    var stored: List[UInt8]
    if page_type == _V2:
        stored = List[UInt8]()
        var values = List[UInt8]()
        for i in range(len(body)):
            if i < def_len:
                stored.append(body[i])
            else:
                values.append(body[i])
        if v2_compressed:
            stored.extend(_stored(codec, values))
        else:
            stored.extend(values^)
    else:
        stored = _stored(codec, body)
    var t = _Thrift()
    t.i32(1, page_type)
    t.i32(2, len(body))
    t.i32(3, len(stored))
    if crc != _NO_CRC:
        var c = Int(_crc(stored, _CRC32_POLY)) if crc == _GOOD_CRC else crc
        t.i32(4, c - (1 << 32) if c >= (1 << 31) else c)
    if page_type == _DATA:
        var s = t.begin(5)
        t.i32(1, nv)
        t.i32(2, enc)
        t.i32(3, _RLE)
        t.i32(4, _RLE)
        t.end(s)
    elif page_type == 2:
        var s = t.begin(7)
        t.i32(1, nv)
        t.i32(2, enc)
        t.end(s)
    else:
        var s = t.begin(8)
        t.i32(1, nv)
        t.i32(2, 0)
        t.i32(3, nv)
        t.i32(4, enc)
        t.i32(5, def_len)
        t.i32(6, 0)
        t.field(7, 1 if v2_compressed else 2)
        t.end(s)
    t.b.append(UInt8(0))
    chunk.extend(t.b.copy())
    chunk.extend(stored^)


def _hybrid(values: List[Int], bw: Int) -> List[UInt8]:
    """One bit-packed run of `values` at width `bw`, padded to 8 values."""
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


def _v1_defs(defs: List[Int]) -> List[UInt8]:
    var run = _hybrid(defs, 1)
    var out = List[UInt8]()
    _le(out, len(run), 4)
    out.extend(run^)
    return out^


def _ints(values: List[Int], width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, values[i], width)
    return out^


def _width(v: UInt64) -> Int:
    var w = 0
    var x = v
    while x != 0:
        w += 1
        x >>= 1
    return w


def _dbp(values: List[Int], mut out: List[UInt8], declared: Int = -1):
    """`values` as DELTA_BINARY_PACKED (block 128, 4 miniblocks); the header
    declares `declared` values when given."""
    var block_size = 128
    var mb_count = 4
    _uleb(out, block_size)
    _uleb(out, mb_count)
    _uleb(out, len(values) if declared < 0 else declared)
    _uleb(out, _zz(values[0] if len(values) > 0 else 0))
    var mb_size = block_size // mb_count
    var i = 1
    while i < len(values):
        var end = min(i + block_size, len(values))
        var deltas = List[Int]()
        for j in range(i, end):
            deltas.append(values[j] - values[j - 1])
        var md = deltas[0]
        for j in range(len(deltas)):
            md = min(md, deltas[j])
        _uleb(out, _zz(md))
        var widths = List[Int]()
        for m in range(mb_count):
            var w = 0
            for j in range(m * mb_size, min((m + 1) * mb_size, len(deltas))):
                w = max(w, _width(UInt64(deltas[j] - md)))
            widths.append(w)
            out.append(UInt8(w))
        for m in range(mb_count):
            var w = widths[m]
            var start = len(out)
            for _ in range((mb_size * w + 7) // 8):
                out.append(UInt8(0))
            for k in range(mb_size):
                var j = m * mb_size + k
                var u = UInt64(deltas[j] - md) if j < len(deltas) else UInt64(0)
                for b in range(w):
                    if (u >> UInt64(b)) & 1 == 1:
                        var bit = k * w + b
                        out[start + (bit >> 3)] |= UInt8(1 << (bit & 7))
        i = end


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for k in range(len(b)):
        out.append(b[k])
    return out^


def _dlba(strings: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    var lens = List[Int]()
    for i in range(len(strings)):
        lens.append(strings[i].byte_length())
    _dbp(lens, out)
    for i in range(len(strings)):
        out.extend(_bytes_of(strings[i]))
    return out^


def _dba(strings: List[String]) -> List[UInt8]:
    """Prefix lengths shared with the previous value, then the suffixes as
    DELTA_LENGTH_BYTE_ARRAY."""
    var prefixes = List[Int]()
    var suffixes = List[String]()
    var prev = String("")
    for i in range(len(strings)):
        var cur = strings[i]
        var p = 0
        var a = prev.as_bytes()
        var b = cur.as_bytes()
        while p < len(a) and p < len(b) and a[p] == b[p]:
            p += 1
        prefixes.append(p)
        suffixes.append(String(cur[byte=p:]))
        prev = cur
    var out = List[UInt8]()
    _dbp(prefixes, out)
    out.extend(_dlba(suffixes))
    return out^


# --- decode and read ---------------------------------------------------------


def _decode(
    chunk: List[UInt8],
    ptype: ParquetType,
    nv: Int,
    nullable: Bool,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
    type_length: Int = 0,
    converted_type: Int = -1,
    scale: Int = 0,
    precision: Int = 0,
    decode_move: Bool = True,
) raises -> Column[HeapRegion]:
    var holder = NumericDictCodesHolder()
    var ctx = ColumnDecodeContext()
    return decode_column_pages(
        Span(chunk),
        ptype,
        codec,
        nv,
        nullable,
        False,
        holder,
        ctx,
        type_length,
        converted_type,
        scale,
        True,
        precision,
        decode_move,
    )


def _check_i64(c: Column[HeapRegion], want: List[Int], nulls: List[Int]) raises:
    """`c` is INT64 with `want` at its non-null rows and nulls at `nulls`."""
    assert_equal(c.length(), len(want))
    var a = c.as_primitive[DType.int64]()
    var k = 0
    for i in range(len(want)):
        var is_null = k < len(nulls) and nulls[k] == i
        assert_equal(c.is_null_at(i), is_null, "row " + String(i))
        if is_null:
            k += 1
        else:
            assert_equal(Int(a.get(i)), want[i], "row " + String(i))
    assert_equal(c.null_count(), len(nulls))


def _check_i32(c: Column[HeapRegion], want: List[Int], nulls: List[Int]) raises:
    assert_equal(c.length(), len(want))
    var a = c.as_primitive[DType.int32]()
    var k = 0
    for i in range(len(want)):
        var is_null = k < len(nulls) and nulls[k] == i
        assert_equal(c.is_null_at(i), is_null, "row " + String(i))
        if is_null:
            k += 1
        else:
            assert_equal(Int(a.get(i)), want[i], "row " + String(i))
    assert_equal(c.null_count(), len(nulls))


# --- the single PLAIN page ---------------------------------------------------


def test_a_single_plain_page_is_moved_or_copied_to_the_same_column() raises:
    # A REQUIRED INT32 chunk of one PLAIN page: the decoded page is the
    # column's data. The moved buffer and the copying reference must agree,
    # under each codec.
    var codecs: List[CompressionCodec] = [
        CompressionCodec.UNCOMPRESSED,
        CompressionCodec.SNAPPY,
        CompressionCodec.ZSTD,
    ]
    var vals: List[Int] = [1, -2, 3, 2147483647, -2147483648]
    for ci in range(len(codecs)):
        var chunk = List[UInt8]()
        _page(chunk, _DATA, 5, _PLAIN, _ints(vals, 4), codecs[ci])
        var moved = _decode(chunk, ParquetType.INT32, 5, False, codecs[ci])
        var copied = _decode(
            chunk, ParquetType.INT32, 5, False, codecs[ci], decode_move=False
        )
        assert_true(moved.arrow_type == ArrowType.INT32)
        assert_true(copied.arrow_type == ArrowType.INT32)
        _check_i32(moved, vals, [])
        _check_i32(copied, vals, [])


def test_a_single_page_int32_decimal_is_decimal128() raises:
    # Fixed: the single-page path returned a REQUIRED INT32 DECIMAL chunk as
    # plain INT32 while a two-page chunk of the same column came back as
    # Decimal128. Both are Decimal128 now.
    var one = List[UInt8]()
    _page(one, _DATA, 2, _PLAIN, _ints([12345, -1], 4))
    var two = List[UInt8]()
    _page(two, _DATA, 1, _PLAIN, _ints([12345], 4))
    _page(two, _DATA, 1, _PLAIN, _ints([-1], 4))
    for which in range(2):
        var c = _decode(
            one if which == 0 else two,
            ParquetType.INT32,
            2,
            False,
            converted_type=5,
            scale=2,
            precision=9,
        )
        assert_true(c.arrow_type == ArrowType.DECIMAL128, "chunk " + String(which))
        var d = c.as_decimal128()
        assert_true(d.get_i128(0) == SIMD[DType.int128, 1](12345))
        assert_true(d.get_i128(1) == SIMD[DType.int128, 1](-1))


def test_a_short_single_plain_page_is_refused() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA, 3, _PLAIN, _ints([1, 2], 8))
    with assert_raises(contains="PLAIN page declares 3 values"):
        _ = _decode(chunk, ParquetType.INT64, 3, False)


# --- levels ------------------------------------------------------------------


def test_nullable_v1_pages_spread_their_nulls() raises:
    # Two SNAPPY V1 pages of an OPTIONAL INT64: 7, null, 9 | null, 11.
    var chunk = List[UInt8]()
    var p1 = _v1_defs([1, 0, 1])
    p1.extend(_ints([7, 9], 8))
    _page(chunk, _DATA, 3, _PLAIN, p1, CompressionCodec.SNAPPY)
    var p2 = _v1_defs([0, 1])
    p2.extend(_ints([11], 8))
    _page(chunk, _DATA, 2, _PLAIN, p2, CompressionCodec.SNAPPY)
    var c = _decode(chunk, ParquetType.INT64, 5, True, CompressionCodec.SNAPPY)
    _check_i64(c, [7, 0, 9, 0, 11], [1, 3])


def test_v2_definition_levels_have_no_length_prefix() raises:
    # Fixed: a V2 page's definition level section is bare RLE / bit-packed
    # hybrid of the length its header gives; it was read as a V1 section,
    # whose first 4 bytes are a length, so the page was misread or refused.
    # Here: ZSTD values, levels 1 0 1 1, then a V2 page with no level bytes
    # (every value present) and one stored uncompressed.
    var chunk = List[UInt8]()
    var defs = _hybrid([1, 0, 1, 1], 1)
    var dl = len(defs)
    var body = defs^
    body.extend(_ints([5, 6, 7], 4))
    _page(chunk, _V2, 4, _PLAIN, body, CompressionCodec.ZSTD, def_len=dl)
    _page(chunk, _V2, 2, _PLAIN, _ints([8, 9], 4), CompressionCodec.ZSTD)
    _page(
        chunk,
        _V2,
        1,
        _PLAIN,
        _ints([10], 4),
        CompressionCodec.ZSTD,
        v2_compressed=False,
    )
    var c = _decode(chunk, ParquetType.INT32, 7, True, CompressionCodec.ZSTD)
    _check_i32(c, [5, 0, 6, 7, 8, 9, 10], [1])


def test_v2_level_sections_longer_than_the_page_are_refused() raises:
    var chunk = List[UInt8]()
    _page(chunk, _V2, 1, _PLAIN, _ints([1], 4), def_len=99)
    with assert_raises(contains="exceed the page body"):
        _ = _decode(chunk, ParquetType.INT32, 1, True)


# --- physical types ------------------------------------------------------------


def test_boolean_pages_join_across_a_byte_boundary_with_nulls() raises:
    # Page 1: five values T F T T F; page 2: T null T. The second page's bits
    # land at bit 5 of the chunk's first byte and on.
    var chunk = List[UInt8]()
    var p1 = _v1_defs([1, 1, 1, 1, 1])
    p1.append(UInt8(0b01101))
    _page(chunk, _DATA, 5, _PLAIN, p1)
    var p2 = _v1_defs([1, 0, 1])
    p2.append(UInt8(0b11))
    _page(chunk, _DATA, 3, _PLAIN, p2)
    var c = _decode(chunk, ParquetType.BOOLEAN, 8, True)
    assert_equal(c.length(), 8)
    assert_equal(c.null_count(), 1)
    var b = c.as_boolean()
    var want: List[Bool] = [True, False, True, True, False, True, False, True]
    for i in range(8):
        assert_equal(c.is_null_at(i), i == 6, "row " + String(i))
        if i != 6:
            assert_equal(b.get(i), want[i], "row " + String(i))


def test_int96_becomes_int64_nanoseconds() raises:
    # INT96 = 8 bytes of nanoseconds in the day, then the Julian day.
    # Day 2440588 is 1970-01-01.
    var body = List[UInt8]()
    _le(body, 1, 8)
    _le(body, 2440588, 4)
    _le(body, 0, 8)
    _le(body, 2440589, 4)
    var two = List[UInt8]()
    var a = List[UInt8]()
    var b = List[UInt8]()
    for i in range(12):
        a.append(body[i])
        b.append(body[12 + i])
    _page(two, _DATA, 1, _PLAIN, a)
    _page(two, _DATA, 1, _PLAIN, b)
    var c = _decode(two, ParquetType.INT96, 2, False)
    _check_i64(c, [1, 86400 * 1000000000], [])


def test_fixed_len_byte_array_keeps_its_nulls() raises:
    # Fixed: an OPTIONAL FIXED_LEN_BYTE_ARRAY chunk came back with only its
    # present values (2 rows for 3). Now: "ab", null, "cd".
    var chunk = List[UInt8]()
    var p = _v1_defs([1, 0, 1])
    p.extend(_bytes_of("abcd"))
    _page(chunk, _DATA, 3, _PLAIN, p)
    var c = _decode(chunk, ParquetType.FIXED_LEN_BYTE_ARRAY, 3, True, type_length=2)
    assert_equal(c.length(), 3)
    assert_equal(c.null_count(), 1)
    assert_true(c.is_null_at(1))
    var bin = c.as_binary()
    assert_equal(len(bin.get(0)), 2)
    assert_equal(Int(bin.get(0)[1]), ord("b"))
    assert_equal(Int(bin.get(2)[0]), ord("c"))
    # The DECIMAL control: big-endian 0x0100 is 256.
    var dchunk = List[UInt8]()
    var dp = List[UInt8]()
    dp.append(UInt8(1))
    dp.append(UInt8(0))
    _page(dchunk, _DATA, 1, _PLAIN, dp)
    var d = _decode(
        dchunk, ParquetType.FIXED_LEN_BYTE_ARRAY, 1, False, type_length=2,
        converted_type=5,
    )
    assert_true(d.as_decimal128().get_i128(0) == SIMD[DType.int128, 1](256))


def test_delta_binary_packed_pages_append() raises:
    var chunk = List[UInt8]()
    var p1 = List[UInt8]()
    _dbp([10, 11, 15], p1)
    _page(chunk, _DATA, 3, _DBP, p1)
    var p2 = List[UInt8]()
    _dbp([100, 90], p2)
    _page(chunk, _DATA, 2, _DBP, p2)
    _check_i64(_decode(chunk, ParquetType.INT64, 5, False), [10, 11, 15, 100, 90], [])
    _check_i32(_decode(chunk, ParquetType.INT32, 5, False), [10, 11, 15, 100, 90], [])


def test_a_delta_page_whose_stream_is_short_is_refused() raises:
    # Hardening: the page declares 4 values, its stream 3. The decoder pads a
    # short stream with its last value, so the chunk came back with a
    # made-up fourth row.
    var chunk = List[UInt8]()
    var p = List[UInt8]()
    _dbp([1, 2, 3], p)
    _page(chunk, _DATA, 4, _DBP, p)
    with assert_raises(contains="its stream declares 3 values, the page 4"):
        _ = _decode(chunk, ParquetType.INT64, 4, False)


def _bss_f32(values: List[Float32]) -> List[UInt8]:
    var out = List[UInt8](length=len(values) * 4, fill=UInt8(0))
    for i in range(len(values)):
        var bits = Int(bitcast[DType.uint32](values[i]))
        for k in range(4):
            out[k * len(values) + i] = UInt8((bits >> (8 * k)) & 0xFF)
    return out^


def test_byte_stream_split_arms_agree_and_count() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA, 3, _BSS, _bss_f32([1.5, -2.0, 3.25]))
    _page(chunk, _DATA, 2, _BSS, _bss_f32([0.0, 1e10]))
    var want: List[Float32] = [1.5, -2.0, 3.25, 0.0, 1e10]
    for arm in range(2):
        reset_scan_copy_counts()
        set_bss_decode_into_enabled(arm == 0)
        var c = _decode(chunk, ParquetType.FLOAT, 5, False)
        var a = c.as_primitive[DType.float32]()
        for i in range(5):
            assert_equal(a.get(i), want[i], "arm " + String(arm))
        assert_equal(bss_decode_into_count(), 2 if arm == 0 else 0)
        assert_equal(bss_decode_copy_count(), 0 if arm == 0 else 2)
    reset_scan_copy_gates()


def test_delta_string_pages_keep_every_page() raises:
    # Fixed: a BYTE_ARRAY chunk of DELTA_LENGTH_BYTE_ARRAY or DELTA_BYTE_ARRAY
    # pages kept only its last page. Now every page, in order, nulls spread.
    var chunk = List[UInt8]()
    var p1 = _v1_defs([1, 0, 1])
    p1.extend(_dlba(["ab", "c"]))
    _page(chunk, _DATA, 3, _DLBA, p1)
    var p2 = _v1_defs([1, 1])
    p2.extend(_dba(["cat", "car"]))
    _page(chunk, _DATA, 2, _DBA, p2)
    var c = _decode(chunk, ParquetType.BYTE_ARRAY, 5, True)
    assert_equal(c.length(), 5)
    assert_equal(c.null_count(), 1)
    assert_true(c.is_null_at(1))
    assert_equal(c.utf8_value_at(0), "ab")
    assert_equal(c.utf8_value_at(2), "c")
    assert_equal(c.utf8_value_at(3), "cat")
    assert_equal(c.utf8_value_at(4), "car")


# --- the page CRC --------------------------------------------------------------


def test_the_crc_helpers_match_their_check_values() raises:
    # The reference CRCs of this file against the published check values of
    # "123456789", so the tests below test the decoder, not the helper.
    var s = _bytes_of("123456789")
    assert_equal(Int(_crc(s, _CRC32_POLY)), 0xCBF43926)
    assert_equal(Int(_crc(s, _CRC32C_POLY)), 0xE3069283)


def test_a_page_crc_is_the_standard_crc32_of_the_stored_page() raises:
    var good = List[UInt8]()
    _page(good, _DATA, 2, _PLAIN, _ints([3, 4], 8), CompressionCodec.SNAPPY, crc=_GOOD_CRC)
    _page(good, _DATA, 1, _PLAIN, _ints([5], 8), CompressionCodec.SNAPPY, crc=_GOOD_CRC)
    _check_i64(_decode(good, ParquetType.INT64, 3, False, CompressionCodec.SNAPPY), [3, 4, 5], [])
    # One stored byte changed after the CRC was taken: refused before decode.
    var flipped = good.copy()
    flipped[len(flipped) - 1] ^= UInt8(0x40)
    with assert_raises(contains="page CRC mismatch"):
        _ = _decode(flipped, ParquetType.INT64, 3, False, CompressionCodec.SNAPPY)
    # A header carrying the CRC-32C of the page (the algorithm the decoder
    # this was ported from used) is refused: the format's checksum is CRC-32.
    var stored = _stored(CompressionCodec.SNAPPY, _ints([3, 4], 8))
    var castagnoli = List[UInt8]()
    _page(
        castagnoli,
        _DATA,
        2,
        _PLAIN,
        _ints([3, 4], 8),
        CompressionCodec.SNAPPY,
        crc=Int(_crc(stored, _CRC32C_POLY)),
    )
    with assert_raises(contains="page CRC mismatch"):
        _ = _decode(castagnoli, ParquetType.INT64, 2, False, CompressionCodec.SNAPPY)


# --- refusals ------------------------------------------------------------------


def test_malformed_chunks_are_refused() raises:
    var one = List[UInt8]()
    _page(one, _DATA, 2, _PLAIN, _ints([1, 2], 8))
    with assert_raises(contains="num_values -1 is out of range"):
        _ = _decode(one, ParquetType.INT64, -1, False)
    # The page declares 2 values, the chunk 1.
    with assert_raises(contains="page declares 2 values but only 1"):
        _ = _decode(one, ParquetType.INT64, 1, False)
    # The page body runs past the chunk.
    var cut = List[UInt8]()
    for i in range(len(one) - 3):
        cut.append(one[i])
    with assert_raises(contains="exceeds remaining column-chunk bytes"):
        _ = _decode(cut, ParquetType.INT64, 2, False)
    # A short PLAIN page in a two-page chunk.
    var short = List[UInt8]()
    _page(short, _DATA, 1, _PLAIN, _ints([1], 8))
    _page(short, _DATA, 2, _PLAIN, _ints([1], 8))
    with assert_raises(contains="PLAIN page declares 2 values"):
        _ = _decode(short, ParquetType.INT64, 3, False)
    # DELTA_BINARY_PACKED on DOUBLE, BYTE_STREAM_SPLIT on INT64, a level
    # encoding as a value encoding.
    var dbl = List[UInt8]()
    var p = List[UInt8]()
    _dbp([1], p)
    _page(dbl, _DATA, 1, _DBP, p)
    with assert_raises(contains="DELTA_BINARY_PACKED is not an encoding"):
        _ = _decode(dbl, ParquetType.DOUBLE, 1, False)
    var bss = List[UInt8]()
    _page(bss, _DATA, 1, _BSS, _ints([1], 8))
    with assert_raises(contains="BYTE_STREAM_SPLIT is not an encoding"):
        _ = _decode(bss, ParquetType.INT64, 1, False)
    var rle = List[UInt8]()
    _page(rle, _DATA, 1, _RLE, _ints([1], 8))
    with assert_raises(contains="unsupported data page encoding"):
        _ = _decode(rle, ParquetType.INT64, 1, False)


def test_a_footer_count_above_the_pages_is_refused() raises:
    # The footer's count never sizes a buffer alone: 2^36 INT64 values would
    # be a 512 GiB buffer, and the one page here holds two.
    var chunk = List[UInt8]()
    _page(chunk, _DATA, 2, _PLAIN, _ints([1, 2], 8))
    for count in [1 << 36, 3]:
        with assert_raises(contains="data pages hold 2"):
            _ = _decode(chunk, ParquetType.INT64, count, False)
    # A chunk of no data page at all and a count above zero.
    var empty = List[UInt8]()
    with assert_raises(contains="data pages hold 0"):
        _ = _decode(empty, ParquetType.INT64, 5, False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

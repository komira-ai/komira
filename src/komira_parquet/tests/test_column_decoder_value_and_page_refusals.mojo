# Direct tests of `decode_column_pages` (column_decoder) on chunks whose
# pages the value and page decoders refuse or route off the common path: a
# DELTA_LENGTH_BYTE_ARRAY / DELTA_BYTE_ARRAY page on a numeric column, PLAIN
# FIXED_LEN_BYTE_ARRAY with no type length, a short PLAIN BOOLEAN page, an
# unknown physical type, a DELTA_BINARY_PACKED stream that ends after its
# first value, a V2 definition-level section that ends early, BYTE_STREAM_SPLIT
# DOUBLE pages in both arms, DOUBLE and FIXED_LEN_BYTE_ARRAY dictionaries, and
# the single PLAIN page of every numeric type moved or copied, stored
# uncompressed in a V2 page.
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



comptime _RLE_DICT = 8


def _bss_f64(values: List[Float64]) -> List[UInt8]:
    var out = List[UInt8](length=len(values) * 8, fill=UInt8(0))
    for i in range(len(values)):
        var bits = Int(bitcast[DType.uint64](values[i]))
        for k in range(8):
            out[k * len(values) + i] = UInt8((bits >> (8 * k)) & 0xFF)
    return out^


def _codes(codes: List[Int], bw: Int) -> List[UInt8]:
    var out: List[UInt8] = [UInt8(bw)]
    out.extend(_hybrid(codes, bw))
    return out^


# --- encodings the physical type has no decoder for ---------------------------


def test_delta_string_encodings_on_a_numeric_column_are_refused() raises:
    var dlba = List[UInt8]()
    _page(dlba, _DATA, 2, _DLBA, _dlba(["ab", "c"]))
    with assert_raises(contains="is not an encoding of physical type"):
        _ = _decode(dlba, ParquetType.INT32, 2, False)
    var dba = List[UInt8]()
    _page(dba, _DATA, 2, _DBA, _dba(["ab", "ac"]))
    with assert_raises(contains="is not an encoding of physical type"):
        _ = _decode(dba, ParquetType.INT64, 2, False)


def test_plain_fixed_len_byte_array_without_a_type_length_is_refused() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA, 1, _PLAIN, _bytes_of("ab"))
    with assert_raises(contains="FIXED_LEN_BYTE_ARRAY column is missing type_length"):
        _ = _decode(chunk, ParquetType.FIXED_LEN_BYTE_ARRAY, 1, False, type_length=0)


def test_a_plain_boolean_page_shorter_than_its_values_is_refused() raises:
    # 16 values need 2 packed bytes; the page body holds 1.
    var chunk = List[UInt8]()
    _page(chunk, _DATA, 16, _PLAIN, [UInt8(0xFF)])
    with assert_raises(contains="PLAIN BOOLEAN page declares 16 values (2 packed bytes) but the page body holds only 1"):
        _ = _decode(chunk, ParquetType.BOOLEAN, 16, False)


def test_an_unknown_physical_type_is_refused() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA, 1, _PLAIN, _ints([1], 4))
    with assert_raises(contains="unsupported physical type"):
        _ = _decode(chunk, ParquetType(99), 1, False)


def test_a_delta_stream_that_ends_after_its_first_value_is_refused() raises:
    # The stream declares 3 values (as the page does) but a zero block size,
    # so only its first value can be read: the chunk must not be padded.
    var p = List[UInt8]()
    _uleb(p, 0)
    _uleb(p, 0)
    _uleb(p, 3)
    _uleb(p, _zz(5))
    var chunk = List[UInt8]()
    _page(chunk, _DATA, 3, _DBP, p)
    with assert_raises(contains="it decodes 1 of its 3 values"):
        _ = _decode(chunk, ParquetType.INT64, 3, False)
    with assert_raises(contains="it decodes 1 of its 3 values"):
        _ = _decode(chunk, ParquetType.INT32, 3, False)


def test_a_v2_definition_level_section_that_ends_early_is_refused() raises:
    # 20 values declared; the section holds one bit-packed group of 8 levels.
    var defs = _hybrid([1, 0, 1, 1], 1)
    var dl = len(defs)
    var body = defs^
    body.extend(_ints([1, 2, 3], 4))
    var chunk = List[UInt8]()
    _page(chunk, _V2, 20, _PLAIN, body, def_len=dl)
    with assert_raises(contains="its definition level section holds 8 levels, the page declares 20"):
        _ = _decode(chunk, ParquetType.INT32, 20, True)


# --- BYTE_STREAM_SPLIT DOUBLE ---------------------------------------------------


def test_byte_stream_split_double_arms_agree_and_count() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA, 3, _BSS, _bss_f64([1.5, -2.0, 1e300]))
    _page(chunk, _DATA, 2, _BSS, _bss_f64([0.0, -0.125]))
    var want: List[Float64] = [1.5, -2.0, 1e300, 0.0, -0.125]
    for arm in range(2):
        reset_scan_copy_counts()
        set_bss_decode_into_enabled(arm == 0)
        var c = _decode(chunk, ParquetType.DOUBLE, 5, False)
        var a = c.as_primitive[DType.float64]()
        for i in range(5):
            assert_equal(a.get(i), want[i], "arm " + String(arm))
        assert_equal(bss_decode_into_count(), 2 if arm == 0 else 0)
        assert_equal(bss_decode_copy_count(), 0 if arm == 0 else 2)
    reset_scan_copy_gates()


# --- dictionaries ---------------------------------------------------------------


def test_a_double_dictionary_chunk_resolves_its_codes() raises:
    var chunk = List[UInt8]()
    var dict_body = List[UInt8]()
    for v in [0.5, -4.25]:
        _le(dict_body, Int(bitcast[DType.uint64](Float64(v))), 8)
    _page(chunk, 2, 2, _PLAIN, dict_body)
    _page(chunk, _DATA, 4, _RLE_DICT, _codes([1, 0, 0, 1], 1))
    var c = _decode(chunk, ParquetType.DOUBLE, 4, False)
    var a = c.as_primitive[DType.float64]()
    var want: List[Float64] = [-4.25, 0.5, 0.5, -4.25]
    for i in range(4):
        assert_equal(a.get(i), want[i], "row " + String(i))


def test_a_fixed_len_byte_array_dictionary_chunk_resolves_its_codes() raises:
    var chunk = List[UInt8]()
    _page(chunk, 2, 2, _PLAIN, _bytes_of("abcd"))
    _page(chunk, _DATA, 3, _RLE_DICT, _codes([1, 0, 1], 1))
    var c = _decode(chunk, ParquetType.FIXED_LEN_BYTE_ARRAY, 3, False, type_length=2)
    assert_equal(c.length(), 3)
    var bin = c.as_binary()
    assert_equal(Int(bin.get(0)[0]), ord("c"))
    assert_equal(Int(bin.get(0)[1]), ord("d"))
    assert_equal(Int(bin.get(1)[0]), ord("a"))
    assert_equal(Int(bin.get(2)[1]), ord("d"))


def test_a_fixed_len_byte_array_dictionary_without_a_type_length_is_refused() raises:
    var chunk = List[UInt8]()
    _page(chunk, 2, 2, _PLAIN, _bytes_of("abcd"))
    _page(chunk, _DATA, 3, _RLE_DICT, _codes([1, 0, 1], 1))
    with assert_raises(contains="FIXED_LEN_BYTE_ARRAY column is missing type_length"):
        _ = _decode(chunk, ParquetType.FIXED_LEN_BYTE_ARRAY, 3, False, type_length=0)


# --- the single PLAIN page --------------------------------------------------------


def test_a_single_plain_page_of_every_numeric_type_is_moved_or_copied() raises:
    for moved in range(2):
        var move = moved == 0
        var i64 = List[UInt8]()
        _page(i64, _DATA, 3, _PLAIN, _ints([5, -6, 9000000000], 8))
        var c64 = _decode(i64, ParquetType.INT64, 3, False, decode_move=move)
        _check_i64(c64, [5, -6, 9000000000], [])

        var f32 = List[UInt8]()
        var fb = List[UInt8]()
        _le(fb, Int(bitcast[DType.uint32](Float32(1.5))), 4)
        _le(fb, Int(bitcast[DType.uint32](Float32(-8.0))), 4)
        _page(f32, _DATA, 2, _PLAIN, fb)
        var cf = _decode(f32, ParquetType.FLOAT, 2, False, decode_move=move)
        assert_true(cf.arrow_type == ArrowType.FLOAT32)
        assert_equal(cf.as_primitive[DType.float32]().get(1), Float32(-8.0))

        var f64 = List[UInt8]()
        var db = List[UInt8]()
        _le(db, Int(bitcast[DType.uint64](Float64(2.5))), 8)
        _le(db, Int(bitcast[DType.uint64](Float64(-1e100))), 8)
        _page(f64, _DATA, 2, _PLAIN, db)
        var cd = _decode(f64, ParquetType.DOUBLE, 2, False, decode_move=move)
        assert_true(cd.arrow_type == ArrowType.FLOAT64)
        assert_equal(cd.as_primitive[DType.float64]().get(0), Float64(2.5))
        assert_equal(cd.as_primitive[DType.float64]().get(1), Float64(-1e100))


def test_a_single_v2_page_stored_uncompressed_under_a_compressed_chunk_codec() raises:
    # The page header says is_compressed = false, so the SNAPPY chunk codec
    # does not apply to its values.
    var chunk = List[UInt8]()
    _page(
        chunk, _V2, 3, _PLAIN, _ints([4, 5, 6], 4),
        CompressionCodec.SNAPPY, v2_compressed=False,
    )
    _check_i32(_decode(chunk, ParquetType.INT32, 3, False, CompressionCodec.SNAPPY), [4, 5, 6], [])
    _check_i32(
        _decode(chunk, ParquetType.INT32, 3, False, CompressionCodec.SNAPPY, decode_move=False),
        [4, 5, 6], [],
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

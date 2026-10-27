# Direct tests of `decode_column_pages` on chunks with no dictionary codes:
# PLAIN fixed-width, DECIMAL, FLOAT, DOUBLE, FIXED_LEN_BYTE_ARRAY and BOOLEAN
# chunks copied (not moved) into their column, with and without nulls; the
# all-null chunk of every physical type and annotation; and the chunk with no
# value at all, which is an empty column of its type.
#
# Chunks are encoded here from parquet-format: Thrift Compact page headers
# (parquet.thrift), PLAIN values, and RLE / bit-packed hybrid definition
# levels behind V1 data pages (Encodings.md).
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.types import (
    CONVERTED_TYPE_DATE,
    CONVERTED_TYPE_DECIMAL,
    CONVERTED_TYPE_INT_16,
    CONVERTED_TYPE_INT_8,
    CONVERTED_TYPE_UINT_16,
    CONVERTED_TYPE_UINT_32,
    CONVERTED_TYPE_UINT_64,
    CONVERTED_TYPE_UINT_8,
    CONVERTED_TYPE_UTF8,
    CompressionCodec,
    ParquetType,
)

from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.column_decoder_finish import _all_null_column
from komira_parquet.column_decoder import (
    NumericDictCodesHolder,
    decode_column_pages,
)

comptime _DATA = 0
comptime _DICT = 2
comptime _PLAIN = 0
comptime _RLE = 3
comptime _RLE_DICT = 8
comptime _DECIMAL = CONVERTED_TYPE_DECIMAL


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _f32(mut out: List[UInt8], v: Float32):
    var bits = bitcast[DType.uint32, 1](SIMD[DType.float32, 1](v))[0]
    for k in range(4):
        out.append(UInt8((bits >> UInt32(8 * k)) & 0xFF))


def _f64(mut out: List[UInt8], v: Float64):
    var bits = bitcast[DType.uint64, 1](SIMD[DType.float64, 1](v))[0]
    for k in range(8):
        out.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))


def _field(mut h: List[UInt8], delta: Int, t: Int):
    h.append(UInt8((delta << 4) | t))


def _i32(mut h: List[UInt8], delta: Int, v: Int):
    _field(h, delta, 5)
    _uleb(h, (v << 1) ^ (v >> 63))


def _page(
    mut chunk: List[UInt8], page_type: Int, nv: Int, enc: Int, body: List[UInt8]
):
    """Append one uncompressed V1 data page or dictionary page."""
    var h = List[UInt8]()
    _i32(h, 1, page_type)
    _i32(h, 1, len(body))
    _i32(h, 1, len(body))
    if page_type == _DATA:
        _field(h, 2, 12)
        _i32(h, 1, nv)
        _i32(h, 1, enc)
        _i32(h, 1, _RLE)
        _i32(h, 1, _RLE)
        h.append(UInt8(0))
    else:
        _field(h, 4, 12)
        _i32(h, 1, nv)
        _i32(h, 1, enc)
        h.append(UInt8(0))
    h.append(UInt8(0))
    chunk.extend(h^)
    chunk.extend(body.copy())


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


def _defs(defs: List[Int]) -> List[UInt8]:
    """V1 definition levels; empty `defs` is a REQUIRED column: no section."""
    var out = List[UInt8]()
    if len(defs) == 0:
        return out^
    var run = _hybrid(defs, 1)
    _le(out, len(run), 4)
    out.extend(run^)
    return out^


def _codes(codes: List[Int], bw: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(bw))
    out.extend(_hybrid(codes, bw))
    return out^


def _ints(values: List[Int], width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        _le(out, values[i], width)
    return out^


def _strs(values: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        var b = values[i].as_bytes()
        _le(out, len(b), 4)
        for k in range(len(b)):
            out.append(b[k])
    return out^


def _codes_page(
    mut chunk: List[UInt8], codes: List[Int], bw: Int, defs: List[Int]
):
    """A data page of dictionary codes behind `defs` (empty: REQUIRED)."""
    var body = _defs(defs)
    body.extend(_codes(codes, bw))
    _page(chunk, _DATA, len(defs) if len(defs) > 0 else len(codes), _RLE_DICT, body)


def _plain_page(mut chunk: List[UInt8], values: List[UInt8], nv: Int, defs: List[Int]):
    """A PLAIN data page of `nv` rows (nulls included) behind `defs`."""
    var body = _defs(defs)
    body.extend(values.copy())
    _page(chunk, _DATA, nv, _PLAIN, body)


def _dict_chunk(
    dict_body: List[UInt8], nd: Int, codes: List[Int], defs: List[Int]
) -> List[UInt8]:
    """A dictionary page and one page of 1-bit codes (`defs`: see `_defs`)."""
    var chunk = List[UInt8]()
    _page(chunk, _DICT, nd, _PLAIN, dict_body)
    _codes_page(chunk, codes, 1 if nd <= 2 else 2, defs)
    return chunk^


def _decode(
    chunk: List[UInt8],
    ptype: ParquetType,
    nv: Int,
    nullable: Bool,
    mut ctx: ColumnDecodeContext,
    type_length: Int = 0,
    converted_type: Int = -1,
    scale: Int = 0,
    precision: Int = 0,
    decode_move: Bool = False,
) raises -> Column[HeapRegion]:
    var holder = NumericDictCodesHolder()
    return decode_column_pages(
        Span(chunk),
        ptype,
        CompressionCodec.UNCOMPRESSED,
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


def _dec(v: Int) -> SIMD[DType.int128, 1]:
    return SIMD[DType.int128, 1](v)


def _one_page(values: List[UInt8], nv: Int, defs: List[Int]) -> List[UInt8]:
    var chunk = List[UInt8]()
    _plain_page(chunk, values, nv, defs)
    return chunk^


# --- PLAIN values copied into their column ----------------------------------


def test_int32_plain_pages_are_copied_when_not_moved() raises:
    # Two pages, so the chunk is not the one-page chunk whose buffer is
    # decoded straight into the column.
    var ctx = ColumnDecodeContext()
    var chunk = _one_page(_ints([5, -6], 4), 2, [])
    _plain_page(chunk, _ints([7], 4), 1, [])
    var c = _decode(chunk, ParquetType.INT32, 3, False, ctx)
    var a = c.as_primitive[DType.int32]()
    assert_equal(c.length(), 3)
    assert_equal(c.null_count(), 0)
    assert_equal(Int(a.get(0)), 5)
    assert_equal(Int(a.get(1)), -6)
    assert_equal(Int(a.get(2)), 7)


def test_decimal_plain_values_spread_over_their_nulls() raises:
    var ctx = ColumnDecodeContext()
    var i32 = _one_page(_ints([1234, -5], 4), 3, [1, 0, 1])
    var c = _decode(
        i32, ParquetType.INT32, 3, True, ctx, converted_type=_DECIMAL,
        scale=2, precision=9,
    )
    assert_true(c.arrow_type == ArrowType.DECIMAL128)
    assert_equal(c.null_count(), 1)
    assert_true(c.is_null_at(1))
    var d = c.as_decimal128()
    assert_true(d.get_i128(0) == _dec(1234))
    assert_true(d.get_i128(2) == _dec(-5))
    var i64 = _one_page(_ints([1234, -5], 8), 3, [0, 1, 1])
    var e = _decode(
        i64, ParquetType.INT64, 3, True, ctx, converted_type=_DECIMAL,
        scale=2, precision=18,
    )
    assert_true(e.arrow_type == ArrowType.DECIMAL128)
    assert_equal(e.null_count(), 1)
    assert_true(e.is_null_at(0))
    var ed = e.as_decimal128()
    assert_true(ed.get_i128(1) == _dec(1234))
    assert_true(ed.get_i128(2) == _dec(-5))


def test_int64_decimal_plain_values_without_nulls_are_dense() raises:
    var ctx = ColumnDecodeContext()
    var chunk = _one_page(_ints([1234, -5], 8), 2, [])
    var c = _decode(
        chunk, ParquetType.INT64, 2, False, ctx, converted_type=_DECIMAL,
        scale=2, precision=18,
    )
    assert_equal(c.length(), 2)
    assert_equal(c.null_count(), 0)
    var d = c.as_decimal128()
    assert_true(d.get_i128(0) == _dec(1234))
    assert_true(d.get_i128(1) == _dec(-5))


def test_float_plain_values_copy_and_spread_over_nulls() raises:
    var ctx = ColumnDecodeContext()
    var vals = List[UInt8]()
    _f32(vals, 1.5)
    _f32(vals, -2.0)
    var two_pages = _one_page(vals, 2, [])
    _plain_page(two_pages, vals, 2, [])
    var dense = _decode(two_pages, ParquetType.FLOAT, 4, False, ctx)
    var da = dense.as_primitive[DType.float32]()
    assert_equal(dense.length(), 4)
    assert_equal(da.get(0), Float32(1.5))
    assert_equal(da.get(1), Float32(-2.0))
    assert_equal(da.get(2), Float32(1.5))
    assert_equal(da.get(3), Float32(-2.0))
    var nulls = _decode(
        _one_page(vals, 3, [1, 0, 1]), ParquetType.FLOAT, 3, True, ctx
    )
    var na = nulls.as_primitive[DType.float32]()
    assert_equal(nulls.null_count(), 1)
    assert_true(nulls.is_null_at(1))
    assert_equal(na.get(0), Float32(1.5))
    assert_equal(na.get(2), Float32(-2.0))


def test_double_plain_values_spread_over_nulls() raises:
    var ctx = ColumnDecodeContext()
    var vals = List[UInt8]()
    _f64(vals, 1.5)
    _f64(vals, -2.0)
    var nulls = _decode(
        _one_page(vals, 3, [0, 1, 1]), ParquetType.DOUBLE, 3, True, ctx
    )
    var na = nulls.as_primitive[DType.float64]()
    assert_equal(nulls.null_count(), 1)
    assert_true(nulls.is_null_at(0))
    assert_equal(na.get(1), Float64(1.5))
    assert_equal(na.get(2), Float64(-2.0))


def test_flba_plain_values_without_nulls_are_binary() raises:
    var ctx = ColumnDecodeContext()
    var vals = List[UInt8]()
    for ch in "abcdef".as_bytes():
        vals.append(ch)
    var c = _decode(
        _one_page(vals, 3, []), ParquetType.FIXED_LEN_BYTE_ARRAY, 3, False, ctx,
        type_length=2,
    )
    var b = c.as_binary()
    assert_equal(c.length(), 3)
    assert_equal(c.null_count(), 0)
    assert_equal(len(b.get(1)), 2)
    assert_equal(Int(b.get(1)[0]), ord("c"))
    assert_equal(Int(b.get(2)[1]), ord("f"))


def test_boolean_plain_values_without_nulls_are_the_packed_bits() raises:
    var ctx = ColumnDecodeContext()
    var vals = List[UInt8]()
    vals.append(UInt8(0b101))
    var c = _decode(_one_page(vals, 3, []), ParquetType.BOOLEAN, 3, False, ctx)
    var b = c.as_boolean()
    assert_equal(c.length(), 3)
    assert_equal(c.null_count(), 0)
    assert_true(b.get(0))
    assert_false(b.get(1))
    assert_true(b.get(2))


# --- chunks with no value ----------------------------------------------------


def _verdict(
    c: Column[HeapRegion], ptype: ParquetType, ct: Int, expect: ArrowType, rows: Int
) raises -> String:
    """The empty string when `c` has `rows` null rows of type `expect`, else
    what differs."""
    var bad = String("")
    if c.arrow_type != expect:
        bad += " type " + String(c.arrow_type) + " not " + String(expect)
    if c.length() != rows or c.null_count() != rows:
        bad += " rows " + String(c.length()) + " nulls " + String(c.null_count())
    if bad != "":
        bad = " [" + String(ptype) + " annotation " + String(ct) + ":" + bad + "]"
    return bad


def _all_null_plain(
    ptype: ParquetType, expect: ArrowType, type_length: Int = 0
) raises -> String:
    """A PLAIN page of 3 rows, every one null, has 3 null rows of `expect`."""
    var ctx = ColumnDecodeContext()
    var c = _decode(
        _one_page(List[UInt8](), 3, [0, 0, 0]), ptype, 3, True, ctx,
        type_length=type_length,
    )
    return _verdict(c, ptype, -1, expect, 3)


def _all_null_dict(
    ptype: ParquetType,
    ct: Int,
    expect: ArrowType,
    type_length: Int = 0,
    precision: Int = 0,
) raises -> String:
    """A dictionary of no entries and a page of 3 null rows have 3 null rows
    of `expect`, the type the chunk's annotation names."""
    var chunk = List[UInt8]()
    _page(chunk, _DICT, 0, _PLAIN, List[UInt8]())
    var body = _defs([0, 0, 0])
    body.append(UInt8(0))
    _page(chunk, _DATA, 3, _RLE_DICT, body)
    var ctx = ColumnDecodeContext()
    var c = _decode(
        chunk, ptype, 3, True, ctx, type_length=type_length,
        converted_type=ct, scale=2, precision=precision,
    )
    return _verdict(c, ptype, ct, expect, 3)


def test_an_all_null_plain_chunk_has_its_rows() raises:
    var bad = String("")
    bad += _all_null_plain(ParquetType.INT32, ArrowType.INT32)
    bad += _all_null_plain(ParquetType.INT64, ArrowType.INT64)
    bad += _all_null_plain(ParquetType.INT96, ArrowType.INT64)
    bad += _all_null_plain(ParquetType.FLOAT, ArrowType.FLOAT32)
    bad += _all_null_plain(ParquetType.DOUBLE, ArrowType.FLOAT64)
    bad += _all_null_plain(ParquetType.BOOLEAN, ArrowType.BOOL)
    bad += _all_null_plain(ParquetType.BYTE_ARRAY, ArrowType.STRING)
    bad += _all_null_plain(
        ParquetType.FIXED_LEN_BYTE_ARRAY, ArrowType.BINARY, type_length=4
    )
    assert_equal(bad, "")


def test_an_all_null_dictionary_chunk_has_its_rows_in_the_annotated_type() raises:
    var bad = String("")
    bad += _all_null_dict(ParquetType.INT32, -1, ArrowType.INT32)
    bad += _all_null_dict(ParquetType.INT32, CONVERTED_TYPE_UINT_32, ArrowType.UINT32)
    bad += _all_null_dict(ParquetType.INT32, CONVERTED_TYPE_DATE, ArrowType.DATE32)
    bad += _all_null_dict(ParquetType.INT32, CONVERTED_TYPE_INT_8, ArrowType.INT8)
    bad += _all_null_dict(ParquetType.INT32, CONVERTED_TYPE_INT_16, ArrowType.INT16)
    bad += _all_null_dict(ParquetType.INT32, CONVERTED_TYPE_UINT_8, ArrowType.UINT8)
    bad += _all_null_dict(ParquetType.INT32, CONVERTED_TYPE_UINT_16, ArrowType.UINT16)
    bad += _all_null_dict(ParquetType.INT64, -1, ArrowType.INT64)
    bad += _all_null_dict(ParquetType.INT64, CONVERTED_TYPE_UINT_64, ArrowType.UINT64)
    bad += _all_null_dict(ParquetType.FLOAT, -1, ArrowType.FLOAT32)
    bad += _all_null_dict(ParquetType.DOUBLE, -1, ArrowType.FLOAT64)
    bad += _all_null_dict(ParquetType.BYTE_ARRAY, CONVERTED_TYPE_UTF8, ArrowType.STRING)
    bad += _all_null_dict(ParquetType.BYTE_ARRAY, -1, ArrowType.BINARY)
    bad += _all_null_dict(
        ParquetType.FIXED_LEN_BYTE_ARRAY, -1, ArrowType.BINARY, type_length=4
    )
    bad += _all_null_dict(
        ParquetType.INT32, CONVERTED_TYPE_DECIMAL, ArrowType.DECIMAL128,
        precision=9,
    )
    # A DECIMAL chunk that declares no precision takes the widest.
    bad += _all_null_dict(ParquetType.INT64, CONVERTED_TYPE_DECIMAL, ArrowType.DECIMAL128)
    assert_equal(bad, "")


def test_a_boolean_chunk_with_no_accumulator_is_all_null_rows_when_asked() raises:
    # A BOOLEAN chunk always has its accumulator once a page is decoded, so
    # the chunk-level path never asks; the helper still answers.
    var bits = List[UInt8](length=1, fill=UInt8(0))
    var c = _all_null_column(
        ParquetType.BOOLEAN, -1, 0, 0, bits.unsafe_ptr(), 3
    )
    assert_true(Bool(c))
    assert_equal(_verdict(c.value(), ParquetType.BOOLEAN, -1, ArrowType.BOOL, 3), "")


def _empty(
    ptype: ParquetType, ct: Int, expect: ArrowType, type_length: Int = 0
) raises -> String:
    var ctx = ColumnDecodeContext()
    var c = _decode(
        List[UInt8](), ptype, 0, False, ctx, type_length=type_length,
        converted_type=ct, scale=2, precision=9,
    )
    var bad = String("")
    if c.arrow_type != expect:
        bad += " type " + String(c.arrow_type) + " not " + String(expect)
    if c.length() != 0:
        bad += " rows " + String(c.length())
    if bad != "":
        bad = " [" + String(ptype) + " annotation " + String(ct) + ":" + bad + "]"
    return bad


def test_a_chunk_with_no_values_is_an_empty_column_of_its_type() raises:
    var bad = String("")
    bad += _empty(ParquetType.INT32, -1, ArrowType.INT32)
    bad += _empty(ParquetType.INT32, CONVERTED_TYPE_UINT_32, ArrowType.UINT32)
    bad += _empty(ParquetType.INT32, CONVERTED_TYPE_DATE, ArrowType.DATE32)
    bad += _empty(ParquetType.INT32, CONVERTED_TYPE_INT_8, ArrowType.INT8)
    bad += _empty(ParquetType.INT32, CONVERTED_TYPE_INT_16, ArrowType.INT16)
    bad += _empty(ParquetType.INT32, CONVERTED_TYPE_UINT_8, ArrowType.UINT8)
    bad += _empty(ParquetType.INT32, CONVERTED_TYPE_UINT_16, ArrowType.UINT16)
    bad += _empty(ParquetType.INT64, -1, ArrowType.INT64)
    bad += _empty(ParquetType.INT64, CONVERTED_TYPE_UINT_64, ArrowType.UINT64)
    bad += _empty(ParquetType.INT96, -1, ArrowType.INT64)
    bad += _empty(ParquetType.FLOAT, -1, ArrowType.FLOAT32)
    bad += _empty(ParquetType.DOUBLE, -1, ArrowType.FLOAT64)
    bad += _empty(ParquetType.BOOLEAN, -1, ArrowType.BOOL)
    bad += _empty(ParquetType.BYTE_ARRAY, CONVERTED_TYPE_UTF8, ArrowType.STRING)
    bad += _empty(ParquetType.BYTE_ARRAY, -1, ArrowType.BINARY)
    bad += _empty(ParquetType.FIXED_LEN_BYTE_ARRAY, -1, ArrowType.BINARY, type_length=4)
    bad += _empty(ParquetType.INT32, CONVERTED_TYPE_DECIMAL, ArrowType.DECIMAL128)
    assert_equal(bad, "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# Direct tests of `decode_column_pages` on dictionary chunks, one test per
# shape the assembly of a chunk's column takes: the reused codes buffer for
# INT32 and for chunks with nulls or PLAIN pages, string runs that end on
# dictionary codes, the string-share switch, INT32 / INT64 / FLOAT / DOUBLE /
# FIXED_LEN_BYTE_ARRAY dictionaries resolved with and without nulls (and
# under both settings of the resolve-move switch), DECIMAL dictionaries on
# INT32 / INT64 / FIXED_LEN_BYTE_ARRAY, and numeric chunks whose dictionary
# pages are followed by PLAIN pages.
#
# Chunks are encoded here from parquet-format: Thrift Compact page headers
# (parquet.thrift), PLAIN dictionary pages, and RLE_DICTIONARY data pages (a
# bit-width byte, then the codes as RLE / bit-packed hybrid) behind V1
# definition levels (Encodings.md).
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
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import CompressionCodec, ParquetType

from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.column_decoder_assemble import _assemble
from komira_parquet.column_decoder_state import _ChunkAcc
from komira_parquet.column_decoder import (
    NumericDictCodesHolder,
    decode_column_pages,
)
from komira_parquet.scan_copy_trace import (
    dict_resolve_copy_count,
    dict_resolve_move_count,
    reset_scan_copy_counts,
    reset_scan_copy_gates,
    set_dict_resolve_move_enabled,
    set_string_share_enabled,
    string_copy_count,
    string_share_count,
)

comptime _DATA = 0
comptime _DICT = 2
comptime _PLAIN = 0
comptime _RLE = 3
comptime _RLE_DICT = 8
comptime _DECIMAL = 5


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
    preserve_dict: Bool = True,
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
        preserve_dict,
        precision,
    )


def _dec(v: Int) -> SIMD[DType.int128, 1]:
    return SIMD[DType.int128, 1](v)


# --- the reused codes buffer -------------------------------------------------


def test_int32_codes_in_the_reused_buffer_become_a_numeric_dictionary() raises:
    var ctx = ColumnDecodeContext(
        numeric_dict_vec_enabled=True, recycle_codes_enabled=True
    )
    var chunk = _dict_chunk(_ints([70, 80, 90], 4), 3, [2, 0, 1, 1], [])
    var c = _decode(chunk, ParquetType.INT32, 4, False, ctx)
    assert_true(c.is_numeric_dict())
    assert_equal(c.length(), 4)
    var want: List[Int] = [90, 70, 80, 80]
    for i in range(4):
        assert_equal(Int(c.dict_value_i64(c.dict_code_at(i))), want[i])


def test_codes_in_the_reused_buffer_with_nulls_resolve_to_a_spread_column() raises:
    # A null row has no code, so the chunk cannot stay a numeric dictionary:
    # the codes are copied out of the shared buffer and resolved.
    var ctx = ColumnDecodeContext(
        numeric_dict_vec_enabled=True, recycle_codes_enabled=True
    )
    var chunk = _dict_chunk(_ints([10, 20], 8), 2, [1, 0, 1], [1, 0, 1, 1])
    var c = _decode(chunk, ParquetType.INT64, 4, True, ctx)
    assert_false(c.is_numeric_dict())
    assert_equal(c.length(), 4)
    assert_equal(c.null_count(), 1)
    var a = c.as_primitive[DType.int64]()
    var want: List[Int] = [20, 0, 10, 20]
    for i in range(4):
        assert_equal(c.is_null_at(i), i == 1)
        if i != 1:
            assert_equal(Int(a.get(i)), want[i])


def test_codes_in_the_reused_buffer_then_plain_pages_keep_page_order() raises:
    var ctx = ColumnDecodeContext(
        numeric_dict_vec_enabled=True, recycle_codes_enabled=True
    )
    var chunk = _dict_chunk(_ints([10, 20], 8), 2, [1, 0], [])
    _plain_page(chunk, _ints([30, 40], 8), 2, [])
    var c = _decode(chunk, ParquetType.INT64, 4, False, ctx)
    assert_false(c.is_numeric_dict())
    var a = c.as_primitive[DType.int64]()
    var want: List[Int] = [20, 10, 30, 40]
    assert_equal(c.length(), 4)
    for i in range(4):
        assert_equal(Int(a.get(i)), want[i])


# --- string runs -------------------------------------------------------------


def _strings_ending_on_codes() raises -> List[UInt8]:
    """REQUIRED BYTE_ARRAY: codes a b | PLAIN zz | codes b b."""
    var chunk = List[UInt8]()
    _page(chunk, _DICT, 2, _PLAIN, _strs(["a", "b"]))
    _codes_page(chunk, [0, 1], 1, [])
    _plain_page(chunk, _strs(["zz"]), 1, [])
    _codes_page(chunk, [1, 1], 1, [])
    return chunk^


def _check_strings(c: Column[HeapRegion]) raises:
    var want: List[String] = ["a", "b", "zz", "b", "b"]
    assert_true(c.arrow_type == ArrowType.STRING)
    assert_equal(c.length(), 5)
    assert_equal(c.null_count(), 0)
    for i in range(5):
        assert_equal(c.utf8_value_at(i), want[i], "row " + String(i))


def test_string_pages_that_end_on_dictionary_codes_resolve_the_tail() raises:
    var ctx = ColumnDecodeContext()
    reset_scan_copy_counts()
    var c = _decode(_strings_ending_on_codes(), ParquetType.BYTE_ARRAY, 5, False, ctx)
    _check_strings(c)
    assert_equal(string_share_count(), 1)
    assert_equal(string_copy_count(), 0)


def test_string_runs_are_deep_copied_when_sharing_is_off() raises:
    set_string_share_enabled(False)
    var ctx = ColumnDecodeContext()
    reset_scan_copy_counts()
    var c = _decode(_strings_ending_on_codes(), ParquetType.BYTE_ARRAY, 5, False, ctx)
    reset_scan_copy_gates()
    _check_strings(c)
    assert_equal(string_copy_count(), 1)
    assert_equal(string_share_count(), 0)


# --- numeric dictionaries ----------------------------------------------------


def test_int32_dictionary_is_kept_as_a_numeric_dictionary() raises:
    var ctx = ColumnDecodeContext(numeric_dict_vec_enabled=True)
    var chunk = _dict_chunk(_ints([-4, 9], 4), 2, [1, 0, 0, 1], [])
    var c = _decode(chunk, ParquetType.INT32, 4, False, ctx)
    assert_true(c.is_numeric_dict())
    assert_equal(c.dict_size(), 2)
    var want: List[Int] = [9, -4, -4, 9]
    for i in range(4):
        assert_equal(Int(c.dict_value_i64(c.dict_code_at(i))), want[i])


def test_int32_dictionary_resolve_moves_or_copies_its_values() raises:
    var ctx = ColumnDecodeContext()
    var chunk = _dict_chunk(_ints([-4, 9], 4), 2, [1, 0, 1], [])
    set_dict_resolve_move_enabled(True)
    reset_scan_copy_counts()
    var moved = _decode(chunk, ParquetType.INT32, 3, False, ctx)
    assert_equal(dict_resolve_move_count(), 1)
    assert_equal(dict_resolve_copy_count(), 0)
    set_dict_resolve_move_enabled(False)
    reset_scan_copy_counts()
    var copied = _decode(chunk, ParquetType.INT32, 3, False, ctx)
    assert_equal(dict_resolve_move_count(), 0)
    assert_equal(dict_resolve_copy_count(), 1)
    reset_scan_copy_gates()
    var want: List[Int] = [9, -4, 9]
    var m = moved.as_primitive[DType.int32]()
    var k = copied.as_primitive[DType.int32]()
    for i in range(3):
        assert_equal(Int(m.get(i)), want[i])
        assert_equal(Int(k.get(i)), want[i])


def test_int32_dictionary_with_nulls_spreads_its_values() raises:
    var ctx = ColumnDecodeContext()
    var chunk = _dict_chunk(_ints([-4, 9], 4), 2, [1, 0, 1], [1, 1, 0, 1])
    reset_scan_copy_counts()
    var c = _decode(chunk, ParquetType.INT32, 4, True, ctx)
    assert_equal(dict_resolve_copy_count(), 1)
    var a = c.as_primitive[DType.int32]()
    var want: List[Int] = [9, -4, 0, 9]
    assert_equal(c.null_count(), 1)
    for i in range(4):
        assert_equal(c.is_null_at(i), i == 2)
        if i != 2:
            assert_equal(Int(a.get(i)), want[i])


def test_int64_dictionary_resolve_moves_its_values() raises:
    var ctx = ColumnDecodeContext()
    var chunk = _dict_chunk(_ints([-4, 9], 8), 2, [1, 0, 1], [])
    set_dict_resolve_move_enabled(True)
    reset_scan_copy_counts()
    var c = _decode(chunk, ParquetType.INT64, 3, False, ctx)
    reset_scan_copy_gates()
    assert_equal(dict_resolve_move_count(), 1)
    assert_equal(dict_resolve_copy_count(), 0)
    var a = c.as_primitive[DType.int64]()
    assert_equal(Int(a.get(0)), 9)
    assert_equal(Int(a.get(1)), -4)
    assert_equal(Int(a.get(2)), 9)


def _float_dict() -> List[UInt8]:
    var d = List[UInt8]()
    _f32(d, 1.5)
    _f32(d, -2.0)
    return d^


def test_float_dictionary_moves_copies_or_spreads_its_values() raises:
    var ctx = ColumnDecodeContext()
    var plain = _dict_chunk(_float_dict(), 2, [1, 0, 1], [])
    set_dict_resolve_move_enabled(True)
    reset_scan_copy_counts()
    var moved = _decode(plain, ParquetType.FLOAT, 3, False, ctx)
    assert_equal(dict_resolve_move_count(), 1)
    set_dict_resolve_move_enabled(False)
    reset_scan_copy_counts()
    _ = _decode(plain, ParquetType.FLOAT, 3, False, ctx)
    assert_equal(dict_resolve_copy_count(), 1)
    reset_scan_copy_gates()
    var m = moved.as_primitive[DType.float32]()
    assert_equal(m.get(0), Float32(-2.0))
    assert_equal(m.get(1), Float32(1.5))
    assert_equal(m.get(2), Float32(-2.0))
    var nulls = _dict_chunk(_float_dict(), 2, [1, 0, 1], [1, 0, 1, 1])
    reset_scan_copy_counts()
    var s = _decode(nulls, ParquetType.FLOAT, 4, True, ctx)
    assert_equal(dict_resolve_copy_count(), 1)
    var sa = s.as_primitive[DType.float32]()
    assert_equal(s.null_count(), 1)
    assert_true(s.is_null_at(1))
    assert_equal(sa.get(0), Float32(-2.0))
    assert_equal(sa.get(2), Float32(1.5))
    assert_equal(sa.get(3), Float32(-2.0))


def _double_dict() -> List[UInt8]:
    var d = List[UInt8]()
    _f64(d, 1.5)
    _f64(d, -2.0)
    return d^


def test_double_dictionary_moves_copies_or_spreads_its_values() raises:
    var ctx = ColumnDecodeContext()
    var plain = _dict_chunk(_double_dict(), 2, [1, 0, 1], [])
    set_dict_resolve_move_enabled(True)
    reset_scan_copy_counts()
    var moved = _decode(plain, ParquetType.DOUBLE, 3, False, ctx)
    assert_equal(dict_resolve_move_count(), 1)
    set_dict_resolve_move_enabled(False)
    reset_scan_copy_counts()
    _ = _decode(plain, ParquetType.DOUBLE, 3, False, ctx)
    assert_equal(dict_resolve_copy_count(), 1)
    reset_scan_copy_gates()
    var m = moved.as_primitive[DType.float64]()
    assert_equal(m.get(0), Float64(-2.0))
    assert_equal(m.get(1), Float64(1.5))
    assert_equal(m.get(2), Float64(-2.0))
    var nulls = _dict_chunk(_double_dict(), 2, [1, 0, 1], [1, 0, 1, 1])
    reset_scan_copy_counts()
    var s = _decode(nulls, ParquetType.DOUBLE, 4, True, ctx)
    assert_equal(dict_resolve_copy_count(), 1)
    var sa = s.as_primitive[DType.float64]()
    assert_equal(s.null_count(), 1)
    assert_true(s.is_null_at(1))
    assert_equal(sa.get(0), Float64(-2.0))
    assert_equal(sa.get(2), Float64(1.5))
    assert_equal(sa.get(3), Float64(-2.0))


# --- DECIMAL dictionaries ----------------------------------------------------


def test_int32_decimal_dictionary_resolves_to_decimal128_with_nulls() raises:
    var ctx = ColumnDecodeContext()
    var chunk = _dict_chunk(_ints([1234, -5], 4), 2, [0, 1, 0], [1, 0, 1, 1])
    var c = _decode(
        chunk, ParquetType.INT32, 4, True, ctx, converted_type=_DECIMAL,
        scale=2, precision=9,
    )
    assert_true(c.arrow_type == ArrowType.DECIMAL128)
    assert_equal(c.length(), 4)
    assert_equal(c.null_count(), 1)
    assert_true(c.is_null_at(1))
    var d = c.as_decimal128()
    assert_true(d.get_i128(0) == _dec(1234))
    assert_true(d.get_i128(2) == _dec(-5))
    assert_true(d.get_i128(3) == _dec(1234))


def test_int32_decimal_dictionary_without_nulls_is_dense() raises:
    var ctx = ColumnDecodeContext()
    var chunk = _dict_chunk(_ints([1234, -5], 4), 2, [1, 0], [])
    var c = _decode(
        chunk, ParquetType.INT32, 2, False, ctx, converted_type=_DECIMAL,
        scale=2, precision=9,
    )
    assert_equal(c.length(), 2)
    assert_equal(c.null_count(), 0)
    var d = c.as_decimal128()
    assert_true(d.get_i128(0) == _dec(-5))
    assert_true(d.get_i128(1) == _dec(1234))


def test_int64_decimal_dictionary_without_nulls_is_dense() raises:
    var ctx = ColumnDecodeContext()
    var chunk = _dict_chunk(_ints([1234, -5], 8), 2, [1, 0, 1], [])
    var c = _decode(
        chunk, ParquetType.INT64, 3, False, ctx, converted_type=_DECIMAL,
        scale=2, precision=18,
    )
    assert_equal(c.length(), 3)
    assert_equal(c.null_count(), 0)
    var d = c.as_decimal128()
    assert_true(d.get_i128(0) == _dec(-5))
    assert_true(d.get_i128(1) == _dec(1234))
    assert_true(d.get_i128(2) == _dec(-5))


# --- FIXED_LEN_BYTE_ARRAY dictionaries ---------------------------------------


def _flba_dict() -> List[UInt8]:
    """Two 2-byte entries, big-endian 0x0100 (256) and 0xFFFB (-5)."""
    var d = List[UInt8]()
    d.append(UInt8(0x01))
    d.append(UInt8(0x00))
    d.append(UInt8(0xFF))
    d.append(UInt8(0xFB))
    return d^


def test_flba_dictionary_resolves_to_binary_with_and_without_nulls() raises:
    var ctx = ColumnDecodeContext()
    var dense = _dict_chunk(_flba_dict(), 2, [1, 0, 1], [])
    var c = _decode(dense, ParquetType.FIXED_LEN_BYTE_ARRAY, 3, False, ctx, type_length=2)
    var b = c.as_binary()
    assert_equal(c.length(), 3)
    assert_equal(Int(b.get(0)[0]), 0xFF)
    assert_equal(Int(b.get(0)[1]), 0xFB)
    assert_equal(Int(b.get(1)[0]), 0x01)
    assert_equal(Int(b.get(2)[1]), 0xFB)
    var nulls = _dict_chunk(_flba_dict(), 2, [1, 0], [1, 0, 1])
    var s = _decode(nulls, ParquetType.FIXED_LEN_BYTE_ARRAY, 3, True, ctx, type_length=2)
    var sb = s.as_binary()
    assert_equal(s.length(), 3)
    assert_equal(s.null_count(), 1)
    assert_true(s.is_null_at(1))
    assert_equal(Int(sb.get(0)[0]), 0xFF)
    assert_equal(Int(sb.get(2)[0]), 0x01)
    assert_equal(len(sb.get(2)), 2)


def test_flba_decimal_dictionary_resolves_to_decimal128() raises:
    var ctx = ColumnDecodeContext()
    var dense = _dict_chunk(_flba_dict(), 2, [1, 0, 1], [])
    var c = _decode(
        dense, ParquetType.FIXED_LEN_BYTE_ARRAY, 3, False, ctx, type_length=2,
        converted_type=_DECIMAL, scale=0, precision=4,
    )
    assert_true(c.arrow_type == ArrowType.DECIMAL128)
    var d = c.as_decimal128()
    assert_true(d.get_i128(0) == _dec(-5))
    assert_true(d.get_i128(1) == _dec(256))
    assert_true(d.get_i128(2) == _dec(-5))
    var nulls = _dict_chunk(_flba_dict(), 2, [1, 0], [0, 1, 1])
    var s = _decode(
        nulls, ParquetType.FIXED_LEN_BYTE_ARRAY, 3, True, ctx, type_length=2,
        converted_type=_DECIMAL, scale=0, precision=4,
    )
    var sd = s.as_decimal128()
    assert_equal(s.null_count(), 1)
    assert_true(s.is_null_at(0))
    assert_true(sd.get_i128(1) == _dec(-5))
    assert_true(sd.get_i128(2) == _dec(256))


# --- dictionary pages followed by PLAIN pages ---------------------------------


def test_int32_dictionary_then_plain_pages_resolve_in_page_order() raises:
    var ctx = ColumnDecodeContext()
    var chunk = _dict_chunk(_ints([7, 8], 4), 2, [1, 0], [])
    _plain_page(chunk, _ints([42, 43], 4), 2, [])
    var c = _decode(chunk, ParquetType.INT32, 4, False, ctx)
    var a = c.as_primitive[DType.int32]()
    var want: List[Int] = [8, 7, 42, 43]
    assert_equal(c.length(), 4)
    for i in range(4):
        assert_equal(Int(a.get(i)), want[i])
    # With nulls spread over both pages.
    var nulled = _dict_chunk(_ints([7, 8], 4), 2, [1, 0], [1, 0, 1])
    _plain_page(nulled, _ints([42, 43], 4), 3, [1, 1, 0])
    var n = _decode(nulled, ParquetType.INT32, 6, True, ctx)
    var na = n.as_primitive[DType.int32]()
    var nwant: List[Int] = [8, 0, 7, 42, 43, 0]
    assert_equal(n.null_count(), 2)
    for i in range(6):
        assert_equal(n.is_null_at(i), i == 1 or i == 5)
        if not n.is_null_at(i):
            assert_equal(Int(na.get(i)), nwant[i])


def test_int64_dictionary_then_plain_pages_resolve_in_page_order() raises:
    var ctx = ColumnDecodeContext()
    var chunk = _dict_chunk(_ints([7, 8], 8), 2, [1, 0], [])
    _plain_page(chunk, _ints([42, 43], 8), 2, [])
    var c = _decode(chunk, ParquetType.INT64, 4, False, ctx)
    var a = c.as_primitive[DType.int64]()
    var want: List[Int] = [8, 7, 42, 43]
    assert_equal(c.length(), 4)
    for i in range(4):
        assert_equal(Int(a.get(i)), want[i])
    var nulled = _dict_chunk(_ints([7, 8], 8), 2, [1, 0], [1, 0, 1])
    _plain_page(nulled, _ints([42, 43], 8), 3, [1, 1, 0])
    var n = _decode(nulled, ParquetType.INT64, 6, True, ctx)
    var na = n.as_primitive[DType.int64]()
    var nwant: List[Int] = [8, 0, 7, 42, 43, 0]
    assert_equal(n.null_count(), 2)
    for i in range(6):
        assert_equal(n.is_null_at(i), i == 1 or i == 5)
        if not n.is_null_at(i):
            assert_equal(Int(na.get(i)), nwant[i])


def test_float_dictionary_then_plain_pages_resolve_in_page_order() raises:
    var ctx = ColumnDecodeContext()
    var tail = List[UInt8]()
    _f32(tail, 3.25)
    var chunk = _dict_chunk(_float_dict(), 2, [1, 0], [])
    _plain_page(chunk, tail, 1, [])
    var c = _decode(chunk, ParquetType.FLOAT, 3, False, ctx)
    var a = c.as_primitive[DType.float32]()
    assert_equal(c.length(), 3)
    assert_equal(a.get(0), Float32(-2.0))
    assert_equal(a.get(1), Float32(1.5))
    assert_equal(a.get(2), Float32(3.25))
    var nulled = _dict_chunk(_float_dict(), 2, [1, 0], [1, 0, 1])
    _plain_page(nulled, tail, 2, [0, 1])
    var n = _decode(nulled, ParquetType.FLOAT, 5, True, ctx)
    var na = n.as_primitive[DType.float32]()
    assert_equal(n.null_count(), 2)
    assert_true(n.is_null_at(1))
    assert_true(n.is_null_at(3))
    assert_equal(na.get(0), Float32(-2.0))
    assert_equal(na.get(2), Float32(1.5))
    assert_equal(na.get(4), Float32(3.25))


def test_double_dictionary_then_plain_pages_resolve_in_page_order() raises:
    var ctx = ColumnDecodeContext()
    var tail = List[UInt8]()
    _f64(tail, 3.25)
    var chunk = _dict_chunk(_double_dict(), 2, [1, 0], [])
    _plain_page(chunk, tail, 1, [])
    var c = _decode(chunk, ParquetType.DOUBLE, 3, False, ctx)
    var a = c.as_primitive[DType.float64]()
    assert_equal(c.length(), 3)
    assert_equal(a.get(0), Float64(-2.0))
    assert_equal(a.get(1), Float64(1.5))
    assert_equal(a.get(2), Float64(3.25))
    var nulled = _dict_chunk(_double_dict(), 2, [1, 0], [1, 0, 1])
    _plain_page(nulled, tail, 2, [0, 1])
    var n = _decode(nulled, ParquetType.DOUBLE, 5, True, ctx)
    var na = n.as_primitive[DType.float64]()
    assert_equal(n.null_count(), 2)
    assert_true(n.is_null_at(1))
    assert_true(n.is_null_at(3))
    assert_equal(na.get(0), Float64(-2.0))
    assert_equal(na.get(2), Float64(1.5))
    assert_equal(na.get(4), Float64(3.25))


def test_codes_under_a_physical_type_with_no_dictionary_are_refused() raises:
    # The page decoder refuses a BOOLEAN or INT96 dictionary page, so no
    # chunk reaches assembly like this; assembly refuses it too, by name.
    var acc = _ChunkAcc(ParquetType.BOOLEAN, 1, False, 0, False, False)
    acc.has_dict = True
    acc.dict_idx_buf = OwnedAlignedBuffer(4)
    acc.dict_idx_count = 1
    var ctx = ColumnDecodeContext()
    var holder = NumericDictCodesHolder()
    with assert_raises(contains="no dictionary decoding for physical type"):
        _ = _assemble(acc, ctx, False, holder, -1, 0, 0, True, False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

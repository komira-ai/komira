# Direct tests of `decode_column_pages` (column_decoder) on dictionary
# chunks: string dictionaries kept or rebuilt dense (and the rebuild
# counter), numeric dictionaries resolved, kept as dictionary columns, or
# decoded into the context's reused codes buffer, the codes handed to the
# fused count, chunks that switch from dictionary pages to PLAIN pages, the
# all-null dictionary chunk, and the dictionary chunks it refuses.
#
# Chunks are encoded here from parquet-format: Thrift Compact page headers
# (parquet.thrift), PLAIN dictionary pages, and RLE_DICTIONARY data pages (a
# bit-width byte, then the codes as RLE / bit-packed hybrid) behind V1
# definition levels (Encodings.md).
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
from komira_parquet.dict_mat_counter import (
    dict_to_string_array_call_count,
    reset_dict_to_string_array_call_count,
)

comptime _DATA = 0
comptime _DICT = 2
comptime _PLAIN = 0
comptime _RLE = 3
comptime _RLE_DICT = 8


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


def _field(mut h: List[UInt8], delta: Int, t: Int):
    h.append(UInt8((delta << 4) | t))


def _i32(mut h: List[UInt8], delta: Int, v: Int):
    _field(h, delta, 5)
    _uleb(h, _zz(v))


def _page(
    mut chunk: List[UInt8],
    page_type: Int,
    nv: Int,
    enc: Int,
    body: List[UInt8],
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises:
    """Append one V1 data page or dictionary page."""
    var stored: List[UInt8]
    if codec == CompressionCodec.UNCOMPRESSED:
        stored = body.copy()
    else:
        stored = List[UInt8](length=compress_bound(codec, len(body)), fill=UInt8(0))
        stored.resize(compress(codec, Span(body), Span(stored)), UInt8(0))
    var h = List[UInt8]()
    _i32(h, 1, page_type)
    _i32(h, 1, len(body))
    _i32(h, 1, len(stored))
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


def _defs(defs: List[Int]) -> List[UInt8]:
    var run = _hybrid(defs, 1)
    var out = List[UInt8]()
    _le(out, len(run), 4)
    out.extend(run^)
    return out^


def _codes(codes: List[Int], bw: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(bw))
    if len(codes) > 0:
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


def _decode(
    chunk: List[UInt8],
    ptype: ParquetType,
    nv: Int,
    nullable: Bool,
    mut ctx: ColumnDecodeContext,
    preserve_dict: Bool = True,
    converted_type: Int = -1,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> Column[HeapRegion]:
    var holder = NumericDictCodesHolder()
    return decode_column_pages(
        Span(chunk),
        ptype,
        codec,
        nv,
        nullable,
        False,
        holder,
        ctx,
        0,
        converted_type,
        2,
        preserve_dict,
        0,
    )


def _dict_str(c: Column[HeapRegion], row: Int) raises -> String:
    """Row `row` of a string dictionary column, resolved."""
    var bv = c.string_dict_value_at(c.string_dict_code_at(row))
    var buf = List[UInt8](capacity=bv.len())
    for k in range(bv.len()):
        buf.append(bv.read_u8_at(k))
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


# --- string dictionaries -----------------------------------------------------


def _string_chunk() raises -> List[UInt8]:
    """OPTIONAL BYTE_ARRAY: dictionary x yy zzz; rows zzz, x, null, yy."""
    var chunk = List[UInt8]()
    _page(chunk, _DICT, 3, _PLAIN, _strs(["x", "yy", "zzz"]), CompressionCodec.SNAPPY)
    var p = _defs([1, 1, 0, 1])
    p.extend(_codes([2, 0, 1], 2))
    _page(chunk, _DATA, 4, _RLE_DICT, p, CompressionCodec.SNAPPY)
    return chunk^


def test_a_string_dictionary_is_kept_or_rebuilt_dense_and_counted() raises:
    var chunk = _string_chunk()
    var ctx = ColumnDecodeContext()
    reset_dict_to_string_array_call_count()
    var kept = _decode(
        chunk, ParquetType.BYTE_ARRAY, 4, True, ctx, codec=CompressionCodec.SNAPPY
    )
    # Kept as a dictionary column: no dense rebuild.
    assert_equal(dict_to_string_array_call_count(), 0)
    assert_true(kept.is_string_dict())
    assert_equal(kept.length(), 4)
    assert_equal(kept.null_count(), 1)
    assert_true(kept.is_null_at(2))
    assert_equal(_dict_str(kept, 0), "zzz")
    assert_equal(_dict_str(kept, 1), "x")
    assert_equal(_dict_str(kept, 3), "yy")
    var dense = _decode(
        chunk,
        ParquetType.BYTE_ARRAY,
        4,
        True,
        ctx,
        preserve_dict=False,
        codec=CompressionCodec.SNAPPY,
    )
    assert_equal(dict_to_string_array_call_count(), 1)
    assert_true(dense.arrow_type == ArrowType.STRING)
    assert_equal(dense.length(), 4)
    assert_true(dense.is_null_at(2))
    assert_equal(dense.utf8_value_at(0), "zzz")
    assert_equal(dense.utf8_value_at(3), "yy")


def test_string_runs_after_a_dictionary_keep_page_order() raises:
    # Dictionary a b; codes a b | PLAIN zz | codes b b | PLAIN (null) q.
    var chunk = List[UInt8]()
    _page(chunk, _DICT, 2, _PLAIN, _strs(["a", "b"]))
    var p1 = _defs([1, 1])
    p1.extend(_codes([0, 1], 1))
    _page(chunk, _DATA, 2, _RLE_DICT, p1)
    var p2 = _defs([1])
    p2.extend(_strs(["zz"]))
    _page(chunk, _DATA, 1, _PLAIN, p2)
    var p3 = _defs([1, 1])
    p3.extend(_codes([1, 1], 1))
    _page(chunk, _DATA, 2, _RLE_DICT, p3)
    var p4 = _defs([0, 1])
    p4.extend(_strs(["q"]))
    _page(chunk, _DATA, 2, _PLAIN, p4)
    var ctx = ColumnDecodeContext()
    var c = _decode(chunk, ParquetType.BYTE_ARRAY, 7, True, ctx)
    assert_true(c.arrow_type == ArrowType.STRING)
    assert_equal(c.length(), 7)
    var want: List[String] = ["a", "b", "zz", "b", "b", "", "q"]
    for i in range(7):
        assert_equal(c.is_null_at(i), i == 5, "row " + String(i))
        if i != 5:
            assert_equal(c.utf8_value_at(i), want[i], "row " + String(i))


# --- numeric dictionaries ----------------------------------------------------


def _int_chunk(entries: List[Int], p1: List[Int], p2: List[Int]) raises -> List[UInt8]:
    """REQUIRED INT64: a dictionary page and two pages of codes."""
    var chunk = List[UInt8]()
    _page(chunk, _DICT, len(entries), _PLAIN, _ints(entries, 8))
    _page(chunk, _DATA, len(p1), _RLE_DICT, _codes(p1, 2))
    _page(chunk, _DATA, len(p2), _RLE_DICT, _codes(p2, 2))
    return chunk^


def test_a_numeric_dictionary_is_resolved_or_kept() raises:
    var chunk = _int_chunk([100, 200, 300], [0, 2], [1, 1, 0])
    var want: List[Int] = [100, 300, 200, 200, 100]
    var plain_ctx = ColumnDecodeContext()
    var flat = _decode(chunk, ParquetType.INT64, 5, False, plain_ctx)
    assert_false(flat.is_numeric_dict())
    var a = flat.as_primitive[DType.int64]()
    for i in range(5):
        assert_equal(Int(a.get(i)), want[i])
    var vec_ctx = ColumnDecodeContext(numeric_dict_vec_enabled=True)
    var kept = _decode(chunk, ParquetType.INT64, 5, False, vec_ctx)
    assert_true(kept.is_numeric_dict())
    assert_equal(kept.dict_size(), 3)
    for i in range(5):
        assert_equal(Int(kept.dict_value_i64(kept.dict_code_at(i))), want[i])


def test_the_reused_codes_buffer_serves_chunk_after_chunk() raises:
    # With recycle_codes_enabled the codes of each chunk go to the context's
    # one buffer, sized for the largest chunk and overwritten per chunk.
    var ctx = ColumnDecodeContext(
        numeric_dict_vec_enabled=True, recycle_codes_enabled=True
    )
    var first = _decode(
        _int_chunk([5, 6, 7, 8], [3, 3], [0, 1, 2]), ParquetType.INT64, 5, False, ctx
    )
    var cap = ctx.codes_capacity()
    assert_true(cap >= 5 * 4)
    var second = _decode(
        _int_chunk([9, 10], [1], [0, 0]), ParquetType.INT64, 3, False, ctx
    )
    assert_equal(ctx.codes_capacity(), cap)
    var w1: List[Int] = [8, 8, 5, 6, 7]
    var w2: List[Int] = [10, 9, 9]
    assert_true(first.is_numeric_dict())
    for i in range(5):
        assert_equal(Int(first.dict_value_i64(first.dict_code_at(i))), w1[i])
    for i in range(3):
        assert_equal(Int(second.dict_value_i64(second.dict_code_at(i))), w2[i])


def test_the_fused_count_gets_checked_codes() raises:
    var holder = NumericDictCodesHolder()
    var ctx = ColumnDecodeContext()
    var chunk = _int_chunk([100, 200, 300], [0, 2], [1, 1, 0])
    var placeholder = decode_column_pages(
        Span(chunk), ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 5, False,
        True, holder, ctx,
    )
    assert_equal(placeholder.length(), 0)
    assert_true(Bool(holder.out))
    ref got = holder.out.value()
    assert_equal(got.codes.length, 5)
    assert_equal(len(got.dict_values), 3)
    assert_equal(Int(got.codes.get(1)), 2)
    assert_equal(Int(got.dict_values[2]), 300)
    # Hardening: a code outside the 3-entry dictionary (3) is refused; the
    # fused count indexes its entries with the codes unchecked.
    var bad = _int_chunk([100, 200, 300], [0, 3], [1])
    var holder2 = NumericDictCodesHolder()
    with assert_raises():
        _ = decode_column_pages(
            Span(bad), ParquetType.INT64, CompressionCodec.UNCOMPRESSED, 3,
            False, True, holder2, ctx,
        )


def test_float_double_and_decimal_dictionaries() raises:
    var ctx = ColumnDecodeContext()
    var f = List[UInt8]()
    var fd = List[UInt8]()
    _le(fd, Int(0x3FC00000), 4)  # 1.5
    _le(fd, Int(0xC0000000), 4)  # -2.0
    _page(f, _DICT, 2, _PLAIN, fd)
    _page(f, _DATA, 3, _RLE_DICT, _codes([1, 0, 1], 1))
    var fc = _decode(f, ParquetType.FLOAT, 3, False, ctx)
    var fa = fc.as_primitive[DType.float32]()
    assert_equal(fa.get(0), Float32(-2.0))
    assert_equal(fa.get(1), Float32(1.5))
    # OPTIONAL INT64 DECIMAL(scale 2): 1234, null, -5.
    var d = List[UInt8]()
    _page(d, _DICT, 2, _PLAIN, _ints([1234, -5], 8))
    var p = _defs([1, 0, 1])
    p.extend(_codes([0, 1], 1))
    _page(d, _DATA, 3, _RLE_DICT, p)
    var dc = _decode(d, ParquetType.INT64, 3, True, ctx, converted_type=5)
    assert_true(dc.arrow_type == ArrowType.DECIMAL128)
    assert_equal(dc.length(), 3)
    assert_true(dc.is_null_at(1))
    var dd = dc.as_decimal128()
    assert_true(dd.get_i128(0) == SIMD[DType.int128, 1](1234))
    assert_true(dd.get_i128(2) == SIMD[DType.int128, 1](-5))


def test_a_numeric_chunk_may_switch_from_dictionary_to_plain_once() raises:
    # OPTIONAL INT32: dictionary 7 8; codes 8 7 | PLAIN 42 null 43.
    var chunk = List[UInt8]()
    _page(chunk, _DICT, 2, _PLAIN, _ints([7, 8], 4))
    var p1 = _defs([1, 1])
    p1.extend(_codes([1, 0], 1))
    _page(chunk, _DATA, 2, _RLE_DICT, p1)
    var p2 = _defs([1, 0, 1])
    p2.extend(_ints([42, 43], 4))
    _page(chunk, _DATA, 3, _PLAIN, p2)
    var ctx = ColumnDecodeContext()
    var c = _decode(chunk, ParquetType.INT32, 5, True, ctx)
    assert_equal(c.length(), 5)
    assert_equal(c.null_count(), 1)
    var a = c.as_primitive[DType.int32]()
    var want: List[Int] = [8, 7, 42, 0, 43]
    for i in range(5):
        assert_equal(c.is_null_at(i), i == 3)
        if i != 3:
            assert_equal(Int(a.get(i)), want[i])
    # A dictionary page after the PLAIN page is refused.
    var back = chunk.copy()
    var p3 = _defs([1])
    p3.extend(_codes([0], 1))
    _page(back, _DATA, 1, _RLE_DICT, p3)
    with assert_raises(contains="after a PLAIN page"):
        _ = _decode(back, ParquetType.INT32, 6, True, ctx)


def test_an_all_null_dictionary_chunk_has_its_rows() raises:
    # A dictionary of no entries and a page of 3 nulls: no value accumulator
    # fires, and the column is 3 null rows of the chunk's type.
    var ctx = ColumnDecodeContext()
    var chunk = List[UInt8]()
    _page(chunk, _DICT, 0, _PLAIN, List[UInt8]())
    var p = _defs([0, 0, 0])
    p.extend(_codes([], 0))
    _page(chunk, _DATA, 3, _RLE_DICT, p)
    var c = _decode(chunk, ParquetType.INT64, 3, True, ctx)
    assert_true(c.arrow_type == ArrowType.INT64)
    assert_equal(c.length(), 3)
    assert_equal(c.null_count(), 3)
    var s = _decode(chunk, ParquetType.BYTE_ARRAY, 3, True, ctx, converted_type=0)
    assert_equal(s.length(), 3)
    assert_equal(s.null_count(), 3)


def test_dictionary_chunks_it_refuses() raises:
    var ctx = ColumnDecodeContext()
    # Codes with no dictionary page before them.
    var nodict = List[UInt8]()
    _page(nodict, _DATA, 2, _RLE_DICT, _codes([0, 1], 1))
    with assert_raises(contains="no dictionary page before it"):
        _ = _decode(nodict, ParquetType.INT64, 2, False, ctx)
    # A dictionary page declaring more entries than its bytes hold.
    var big = List[UInt8]()
    _page(big, _DICT, 4, _PLAIN, _ints([1, 2], 8))
    _page(big, _DATA, 1, _RLE_DICT, _codes([0], 1))
    with assert_raises(contains="corrupt dictionary page"):
        _ = _decode(big, ParquetType.INT64, 1, False, ctx)
    # A BOOLEAN dictionary.
    var b = List[UInt8]()
    _page(b, _DICT, 1, _PLAIN, _ints([1], 1))
    with assert_raises(contains="no dictionary decoding"):
        _ = _decode(b, ParquetType.BOOLEAN, 1, False, ctx)
    # A DECIMAL chunk that switches from dictionary to PLAIN pages: refused
    # (its PLAIN tail used to be dropped, leaving the column short).
    var dec = List[UInt8]()
    _page(dec, _DICT, 1, _PLAIN, _ints([9], 4))
    _page(dec, _DATA, 1, _RLE_DICT, _codes([0], 1))
    _page(dec, _DATA, 1, _PLAIN, _ints([3], 4))
    with assert_raises(contains="DECIMAL chunk that switches"):
        _ = _decode(dec, ParquetType.INT32, 2, False, ctx, converted_type=5)


def test_a_dictionary_page_does_not_count_toward_the_chunks_values() raises:
    # Dictionary of 3 entries, then one data page of 2 values.
    var chunk = List[UInt8]()
    _page(chunk, _DICT, 3, _PLAIN, _ints([10, 20, 30], 8))
    _page(chunk, _DATA, 2, _RLE_DICT, _codes([2, 0], 2))
    var ctx = ColumnDecodeContext()
    var c = _decode(chunk, ParquetType.INT64, 2, False, ctx, False)
    assert_equal(c.length(), 2)
    assert_equal(Int(c.as_primitive[DType.int64]().get(0)), 30)
    # 4 is the dictionary entries plus the data values: if the dictionary
    # page were counted this would decode; it is above the 2 the data page
    # holds, so it is refused.
    with assert_raises(contains="data pages hold 2"):
        _ = _decode(chunk, ParquetType.INT64, 4, False, ctx, False)


def test_a_huge_count_after_a_good_page_and_a_corrupt_header_is_refused() raises:
    var chunk = List[UInt8]()
    _page(chunk, _DATA, 2, _PLAIN, _ints([1, 2], 8))
    for _ in range(6):
        chunk.append(UInt8(0xFF))
    var ctx = ColumnDecodeContext()
    with assert_raises(contains="data pages hold 2"):
        _ = _decode(chunk, ParquetType.INT64, 1 << 36, False, ctx)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

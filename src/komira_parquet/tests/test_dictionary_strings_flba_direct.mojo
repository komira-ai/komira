# Direct tests of `dictionary.mojo` and `dictionary_resolve.mojo`, part 2:
# the BYTE_ARRAY dictionary (`resolve_as_string_dict`, `string_dict_column`)
# and the FIXED_LEN_BYTE_ARRAY dictionary (`resolve_flba_as_binary`,
# `resolve_flba_decimal_to_float64`), and the copy helpers behind them.
# Dictionary pages are PLAIN (BYTE_ARRAY: a 4-byte little-endian length then
# the bytes; FLBA: `type_length` bytes per value). A DECIMAL value is the
# big-endian two's-complement integer divided by 10^scale.
from std.sys import simd_width_of
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_parquet.dictionary import (
    DictionaryDecoder,
    _copy_int32_array,
    _copy_string_array_from_opt,
)
from komira_parquet.dictionary_resolve import _Gathers
from komira_parquet.plain_flba import decode_plain_fixed_len_byte_array


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _ba_page(values: List[String]) -> List[UInt8]:
    var page = List[UInt8]()
    for i in range(len(values)):
        var b = values[i].as_bytes()
        _le(page, len(b), 4)
        for k in range(len(b)):
            page.append(b[k])
    return page^


def _be(v: Int64, width: Int) -> List[UInt8]:
    var out = List[UInt8](length=width, fill=0)
    var u = UInt64(v)
    for i in range(width):
        if i < 8:
            out[width - 1 - i] = UInt8((u >> UInt64(8 * i)) & 0xFF)
        else:
            out[width - 1 - i] = UInt8(0xFF) if v < 0 else UInt8(0)
    return out^


def _codes(values: List[Int]) raises -> PrimitiveArray[DType.int32]:
    var arr = PrimitiveArray[DType.int32].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, Int32(values[i]))
    return arr^


def _raises(part: String, err: String) raises:
    assert_true(part in err, "expected '" + part + "' in: " + err)


def _strings() -> List[String]:
    var s: List[String] = ["", "a", "hello", "wörld", "zz"]
    return s^


def _string_decoder() raises -> DictionaryDecoder:
    var page = _ba_page(_strings())
    var d = DictionaryDecoder()
    d.init_dict_byte_array(Span(page), len(_strings()))
    return d^


# --- BYTE_ARRAY dictionary ---------------------------------------------------


def test_resolve_as_string_dict_values_and_copies() raises:
    var d = _string_decoder()
    var codes: List[Int] = [4, 0, 3, 3, 1, 2]
    var arr = d.resolve_as_string_dict(_codes(codes))
    assert_equal(arr.length, len(codes))
    var s = _strings()
    for i in range(len(codes)):
        assert_equal(arr.get(i), s[codes[i]])
    # No codes: an empty array over the same dictionary.
    var none = d.resolve_as_string_dict(_codes(List[Int]()))
    assert_equal(none.length, 0)


def test_resolve_as_string_dict_keeps_the_nulls_of_the_codes() raises:
    var d = _string_decoder()
    var idx = PrimitiveArray[DType.int32].allocate_nullable(4)
    idx.set(0, Int32(2))
    idx.set(2, Int32(4))
    idx.set(3, Int32(1))
    idx.validity.value().clear(1)
    idx.null_count = 1
    var arr = d.resolve_as_string_dict(idx)
    assert_true(Bool(arr.indices.validity), "the copy keeps the validity")
    assert_equal(arr.indices.null_count, 1)
    assert_false(arr.indices.validity.value().test(1))
    assert_true(arr.indices.validity.value().test(3))
    assert_equal(arr.get(3), String("a"))


def test_resolve_as_string_dict_refusals() raises:
    var empty = DictionaryDecoder()
    var one: List[Int] = [0]
    try:
        _ = empty.resolve_as_string_dict(_codes(one))
        assert_true(False, "no dictionary")
    except e:
        _raises("no BYTE_ARRAY dictionary loaded", String(e))
    var d = _string_decoder()
    var bad: List[Int] = [0, 5]
    try:
        _ = d.resolve_as_string_dict(_codes(bad))
        assert_true(False, "a code past the dictionary")
    except e:
        _raises("resolve_as_string_dict saw dictionary codes in [0, 5]", String(e))


def test_string_dict_column_moves_the_codes_in() raises:
    var d = _string_decoder()
    var codes: List[Int] = [3, 3, 0, 4, 2]
    var col = d.string_dict_column(_codes(codes))
    assert_true(col.arrow_type == ArrowType.DICTIONARY)
    assert_equal(col._length, 5)
    assert_equal(col._null_count, 0)
    assert_equal(col._dict_size, 5)
    assert_equal(col._data.len(), 5 * 4)
    var s = _strings()
    for i in range(len(codes)):
        var view = col.string_dict_value_at(codes[i])
        var want = s[codes[i]].as_bytes()
        assert_equal(view.len(), len(want))
        for k in range(len(want)):
            assert_equal(view.read_u8_at(k), want[k])


def test_string_dict_column_refusals() raises:
    var one: List[Int] = [0]
    var empty = DictionaryDecoder()
    try:
        _ = empty.string_dict_column(_codes(one))
        assert_true(False, "no dictionary")
    except e:
        _raises("no BYTE_ARRAY dictionary", String(e))
    var d = _string_decoder()
    var nullable = PrimitiveArray[DType.int32].allocate_nullable(2)
    try:
        _ = d.string_dict_column(nullable^)
        assert_true(False, "nullable codes")
    except e:
        _raises("nullable codes take the scatter arm", String(e))
    var bad: List[Int] = [7]
    try:
        _ = d.string_dict_column(_codes(bad))
        assert_true(False, "out of range")
    except e:
        _raises("string_dict_column saw dictionary codes in [7, 7]", String(e))
    # A header that claims more codes than the buffer holds: 4 codes over an
    # 8-byte buffer (the allocation is larger and zeroed, so the range check
    # reads zeros and the length check is what refuses).
    var buf = OwnedAlignedBuffer(64)
    buf.zero()
    buf.set_length(8)
    var short = PrimitiveArray[DType.int32](buf^, 4, None, 0, 0)
    try:
        _ = d.string_dict_column(short^)
        assert_true(False, "a short code buffer")
    except e:
        _raises("code buffer holds 8 bytes but the array header claims 16", String(e))


def test_copy_helpers_direct() raises:
    var none = Optional[StringArray[HeapRegion]](None)
    try:
        _ = _copy_string_array_from_opt(none)
        assert_true(False, "no StringArray")
    except e:
        _raises("no StringArray to copy", String(e))
    # A dictionary of empty strings copies no data bytes.
    var empties: List[String] = ["", ""]
    var page = _ba_page(empties)
    var d = DictionaryDecoder()
    d.init_dict_byte_array(Span(page), 2)
    var copy = _copy_string_array_from_opt(d.dict_values_bytes)
    assert_equal(copy.length, 2)
    assert_equal(copy.data_length, 0)
    assert_equal(copy.get(1), String(""))
    var c = _copy_int32_array(_codes(List[Int]()))
    assert_equal(c.length, 0)
    assert_false(Bool(c.validity))


# --- FIXED_LEN_BYTE_ARRAY dictionary -----------------------------------------


def _flba_decoder(values: List[Int64], width: Int) raises -> DictionaryDecoder:
    var page = List[UInt8]()
    for i in range(len(values)):
        var b = _be(values[i], width)
        for k in range(width):
            page.append(b[k])
    var d = DictionaryDecoder()
    d.init_dict_fixed_len_byte_array(Span(page), len(values), width)
    return d^


def test_resolve_flba_as_binary_values() raises:
    var vals: List[Int64] = [Int64(1), Int64(-2), Int64(0x010203)]
    var d = _flba_decoder(vals, 3)
    var codes: List[Int] = [2, 0, 1, 2]
    var arr = d.resolve_flba_as_binary(_codes(codes))
    assert_equal(arr.length, 4)
    assert_equal(arr.data_length, 12)
    for i in range(len(codes)):
        var got = arr.get(i)
        var want = _be(vals[codes[i]], 3)
        assert_equal(len(got), 3)
        for k in range(3):
            assert_equal(got[k], want[k])
    var none = d.resolve_flba_as_binary(_codes(List[Int]()))
    assert_equal(none.length, 0)


def test_resolve_flba_as_binary_refusals() raises:
    var empty = DictionaryDecoder()
    var one: List[Int] = [0]
    try:
        _ = empty.resolve_flba_as_binary(_codes(one))
        assert_true(False, "no dictionary")
    except e:
        _raises("no FIXED_LEN_BYTE_ARRAY dictionary loaded", String(e))
    var vals: List[Int64] = [Int64(1)]
    var d = _flba_decoder(vals, 2)
    var bad: List[Int] = [1]
    try:
        _ = d.resolve_flba_as_binary(_codes(bad))
        assert_true(False, "out of range")
    except e:
        _raises("resolve_flba_as_binary saw dictionary codes in [1, 1]", String(e))


def test_resolve_flba_as_binary_refuses_values_past_the_int32_offsets() raises:
    """One 1 MiB dictionary entry resolved 2049 times is 2^31 + 2^20 bytes,
    past what Int32 offsets address: refused before the 2 GiB allocation."""
    comptime MIB = 1 << 20
    var page = List[UInt8](length=MIB, fill=7)
    var d = DictionaryDecoder()
    d.init_dict_fixed_len_byte_array(Span(page), 1, MIB)
    var codes = List[Int](length=2049, fill=0)
    try:
        _ = d.resolve_flba_as_binary(_codes(codes))
        assert_true(False, "values past the Int32 offsets")
    except e:
        _raises("2049 values of 1048576 bytes pass the Int32 offsets", String(e))
    # Two values of 1 MiB are fine.
    var two = List[Int](length=2, fill=0)
    var arr = d.resolve_flba_as_binary(_codes(two))
    assert_equal(arr.data_length, 2 * MIB)


def test_flba_body_with_a_zero_width_copies_nothing() raises:
    """`_Gathers.resolve_flba_as_binary` handed a zero width (a dictionary decoded at
    width 1, resolved at width 0) writes zero offsets and no bytes."""
    var bytes: List[UInt8] = [9, 8]
    var dict = decode_plain_fixed_len_byte_array(Span(bytes), 2, 1)
    var codes: List[Int] = [1, 0, 1]
    var arr = _Gathers.resolve_flba_as_binary(_codes(codes), dict, 0)
    assert_equal(arr.length, 3)
    assert_equal(arr.data_length, 0)
    assert_equal(len(arr.get(2)), 0)


def _decimal_expect(v: Int64, scale: Int) -> Float64:
    var divisor = Float64(1.0)
    for _ in range(scale):
        divisor = divisor * Float64(10.0)
    return Float64(v) * (Float64(1.0) / divisor)


def test_resolve_flba_decimal_every_width_path() raises:
    """Widths 16 and 8 take the cross-row SIMD body and its scalar tail;
    other widths the scalar loop. Values are signed and the scale divides."""
    comptime W = simd_width_of[DType.float64]()
    var vals: List[Int64] = [
        Int64(0), Int64(1), Int64(-1), Int64(123456789), Int64(-98765),
        Int64(9223372036854775807), Int64(-9223372036854775807), Int64(42),
    ]
    var widths: List[Int] = [16, 8, 4, 12, 1]
    for wi in range(len(widths)):
        var width = widths[wi]
        var dv = List[Int64]()
        for i in range(len(vals)):
            var v = vals[i]
            if width < 8:
                v = v % Int64(1 << (8 * width - 1))
            dv.append(v)
        var d = _flba_decoder(dv, width)
        for n in range(0, 2 * W + 3):
            var codes = List[Int]()
            for i in range(n):
                codes.append((i * 3 + 1) % len(dv))
            for scale in range(0, 4, 3):
                var got = d.resolve_flba_decimal_to_float64(_codes(codes), scale)
                assert_equal(got.length, n)
                for i in range(n):
                    assert_equal(
                        got.get(i).to_bits(),
                        _decimal_expect(dv[codes[i]], scale).to_bits(),
                        "width " + String(width) + " row " + String(i),
                    )


def test_resolve_flba_decimal_refusals() raises:
    var empty = DictionaryDecoder()
    var one: List[Int] = [0]
    try:
        _ = empty.resolve_flba_decimal_to_float64(_codes(one), 2)
        assert_true(False, "no dictionary")
    except e:
        _raises("no FIXED_LEN_BYTE_ARRAY dictionary loaded", String(e))
    var vals: List[Int64] = [Int64(5)]
    var d = _flba_decoder(vals, 16)
    var bad: List[Int] = [0, -1]
    try:
        _ = d.resolve_flba_decimal_to_float64(_codes(bad), 0)
        assert_true(False, "out of range")
    except e:
        _raises("resolve_flba_decimal_to_float64 saw dictionary codes in [-1, 0]", String(e))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# Direct tests of `null_expand.mojo`: dense decoded values scattered into a
# nullable array by definition-level bits (1 = value, 0 = null, LSB-first),
# and the all-null constructors. The expected array is the definition: row i
# holds the next dense value when bit i is set and is null otherwise; a set
# bit past the dense values is a valid row with the zero value; the validity
# bitmap is the bits, with nothing set past `total`.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.bitmap import Bitmap
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_parquet.null_expand import (
    _all_null_binary,
    _all_null_primitive,
    _copy_def_bits_to_validity,
    _def_bit_is_set,
    _expand_with_nulls_boolean,
    _expand_with_nulls_decimal128,
    _expand_with_nulls_float32,
    _expand_with_nulls_float64,
    _expand_with_nulls_int32,
    _expand_with_nulls_int64,
    _expand_with_nulls_string,
)


def _bits(pattern: List[Bool]) -> List[UInt8]:
    """Packed LSB-first; every bit past the pattern is SET (garbage the
    expansion must not let into the validity bitmap)."""
    var out = List[UInt8](length=(len(pattern) + 7) // 8 + 1, fill=0xFF)
    for i in range(len(pattern)):
        if not pattern[i]:
            out[i >> 3] = out[i >> 3] & ~UInt8(1 << (i & 7))
    return out^


def _pattern(n: Int) -> List[Bool]:
    var p = List[Bool]()
    for i in range(n):
        p.append(i % 3 != 1)
    return p^


def _count(p: List[Bool]) -> Int:
    var c = 0
    for i in range(len(p)):
        if p[i]:
            c += 1
    return c


def test_def_bit_is_set() raises:
    var p: List[Bool] = [True, False, False, True, True, False, True, False, True]
    var b = _bits(p)
    for i in range(len(p)):
        assert_equal(_def_bit_is_set(b.unsafe_ptr(), i), p[i])


def test_copy_def_bits_clears_bits_past_total() raises:
    for total in range(0, 18):
        var bm = Bitmap.create_all_valid(total)
        var p = _pattern(total)
        var b = _bits(p)
        _copy_def_bits_to_validity(bm, b.unsafe_ptr(), total)
        for i in range(total):
            assert_equal(bm.test(i), p[i], "bit " + String(i))
        assert_equal(bm.popcount(), _count(p), "no bit past total")


def test_expand_int32_and_int64() raises:
    for total in range(0, 20):
        var p = _pattern(total)
        var dense = _count(p)
        var v32 = PrimitiveArray[DType.int32].allocate(dense)
        var v64 = PrimitiveArray[DType.int64].allocate(dense)
        for i in range(dense):
            v32.set(i, Int32(i * 10 - 3))
            v64.set(i, Int64(i) * -100000000000)
        var b = _bits(p)
        var a = _expand_with_nulls_int32(v32, b.unsafe_ptr(), total)
        var c = _expand_with_nulls_int64(v64, b.unsafe_ptr(), total)
        assert_equal(a.length, total)
        assert_equal(a.null_count, total - dense)
        assert_equal(c.null_count, total - dense)
        var k = 0
        for i in range(total):
            assert_equal(a.validity.value().test(i), p[i])
            if p[i]:
                assert_equal(a.get(i), Int32(k * 10 - 3))
                assert_equal(c.get(i), Int64(k) * -100000000000)
                k += 1
            else:
                assert_equal(a.get(i), Int32(0))
                assert_equal(c.get(i), Int64(0))


def test_expand_floats_and_fewer_values_than_bits() raises:
    """Six set bits and four dense values: the last two set rows stay zero
    (valid, as the bits say) and nothing is read past the values."""
    var p: List[Bool] = [True, True, False, True, True, True, True]
    var b = _bits(p)
    var f32 = PrimitiveArray[DType.float32].allocate(4)
    var f64 = PrimitiveArray[DType.float64].allocate(4)
    for i in range(4):
        f32.set(i, Float32(i) + 0.5)
        f64.set(i, Float64(i) - 0.25)
    var a = _expand_with_nulls_float32(f32, b.unsafe_ptr(), 7)
    var c = _expand_with_nulls_float64(f64, b.unsafe_ptr(), 7)
    assert_equal(a.null_count, 1)
    assert_equal(a.get(0), Float32(0.5))
    assert_equal(a.get(3), Float32(2.5))
    assert_equal(a.get(4), Float32(3.5))
    assert_equal(a.get(5), Float32(0))
    assert_equal(c.get(4), Float64(2.75))
    assert_equal(c.get(6), Float64(0))
    assert_true(c.validity.value().test(6))
    # Four dense values in a buffer of eight: the four past the array's
    # length are sentinels (99) that a read past the dense values would show.
    var b32 = OwnedAlignedBuffer(8 * 4)
    var b64 = OwnedAlignedBuffer(8 * 8)
    for i in range(8):
        b32.set_typed[Int32](i, Int32(i + 1) if i < 4 else Int32(99))
        b64.set_typed[Int64](i, Int64(i + 1) if i < 4 else Int64(99))
    b32.set_length(8 * 4)
    b64.set_length(8 * 8)
    var i32 = PrimitiveArray[DType.int32](b32^, 4, None, 0, 0)
    var i64 = PrimitiveArray[DType.int64](b64^, 4, None, 0, 0)
    var d = _expand_with_nulls_int32(i32, b.unsafe_ptr(), 7)
    var e = _expand_with_nulls_int64(i64, b.unsafe_ptr(), 7)
    assert_equal(d.get(4), Int32(4))
    assert_equal(d.get(5), Int32(0))
    assert_equal(e.get(4), Int64(4))
    assert_equal(e.get(6), Int64(0))
    assert_equal(e.null_count, 1)


def test_expand_decimal128() raises:
    var p: List[Bool] = [False, True, True, False, True]
    var b = _bits(p)
    var dense = Decimal128Array.allocate_nullable(3, 20, 4)
    for i in range(3):
        dense.data.write_i128_le_at(i * 16, Int128(i * 7 - 8))
    var a = _expand_with_nulls_decimal128(dense, b.unsafe_ptr(), 5)
    assert_equal(a.length, 5)
    assert_equal(a.null_count, 2)
    assert_equal(a.precision, 20)
    assert_equal(a.scale, 4)
    assert_equal(a.data.read_i128_le_at(1 * 16), Int128(-8))
    assert_equal(a.data.read_i128_le_at(2 * 16), Int128(-1))
    assert_equal(a.data.read_i128_le_at(3 * 16), Int128(0))
    assert_equal(a.data.read_i128_le_at(4 * 16), Int128(6))
    # Fewer dense values than set bits.
    var two = Decimal128Array.allocate_nullable(1, 10, 0)
    two.data.write_i128_le_at(0, Int128(5))
    var t = _expand_with_nulls_decimal128(two, b.unsafe_ptr(), 5)
    assert_equal(t.data.read_i128_le_at(16), Int128(5))
    assert_equal(t.data.read_i128_le_at(32), Int128(0))


def test_expand_string() raises:
    var p: List[Bool] = [True, False, True, True, False]
    var b = _bits(p)
    var vals: List[String] = ["x", "", "yz"]
    var s = _expand_with_nulls_string(StringArray.from_strings(vals), b.unsafe_ptr(), 5)
    assert_equal(s.length, 5)
    assert_equal(s.get(0), String("x"))
    assert_true(s.is_null(1))
    assert_equal(s.get(2), String(""))
    assert_false(s.is_null(2))
    assert_equal(s.get(3), String("yz"))
    assert_true(s.is_null(4))
    # More set bits than strings: the extra rows are null and empty.
    var one: List[String] = ["only"]
    var t = _expand_with_nulls_string(StringArray.from_strings(one), b.unsafe_ptr(), 5)
    assert_equal(t.get(0), String("only"))
    assert_true(t.is_null(2))
    assert_true(t.is_null(3))


def test_expand_boolean() raises:
    var p: List[Bool] = [True, False, True, True, False, True]
    var b = _bits(p)
    var dense = Bitmap.create(4)
    dense.set(0)
    dense.set(2)  # dense values: True, False, True, False
    var a = _expand_with_nulls_boolean(dense, 4, b.unsafe_ptr(), 6)
    assert_equal(a.null_count, 2)
    var want: List[Bool] = [True, False, False, True, False, False]
    for i in range(6):
        assert_equal(a.validity.value().test(i), p[i])
        assert_equal(a.data.test(i), want[i], "row " + String(i))
    # A dense count shorter than the set bits.
    var c = _expand_with_nulls_boolean(dense, 1, b.unsafe_ptr(), 6)
    assert_true(c.data.test(0))
    assert_false(c.data.test(2))


def test_all_null_constructors() raises:
    for total in range(0, 10, 3):
        var a = _all_null_primitive[DType.int16](total)
        assert_equal(a.length, total)
        assert_equal(a.null_count, total)
        var b = _all_null_binary(total)
        assert_equal(b.length, total)
        assert_equal(b.data_length, 0)
        for i in range(total):
            assert_true(a.is_null(i))
            assert_true(b.is_null(i))
            assert_equal(len(b.get(i)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_iceberg_bounds.mojo — single-value serialization and bound scans.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. The scalar serializers produce the bytes of Iceberg table spec
#      Appendix D (little-endian ints and floats, UTF-8 without a length
#      prefix, one byte for a boolean): a wrong byte order silently mis-prunes.
#   2. Integer / string / boolean scans return min and max, skip nulls and
#      count them, and give no bound for an all-null column.
#   3. A float or double scan never writes a NaN bound (a NaN first value must
#      not poison the min and max) and writes a zero lower bound as -0.0 and a
#      zero upper bound as +0.0, so the bound covers either zero.
#   4. String bounds compare by unsigned bytes (a multi-byte character sorts
#      after ASCII), and bound_bytes keeps bytes >= 0x80 verbatim.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_true, assert_equal, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_iceberg import (
    serialize_boolean,
    serialize_int32,
    serialize_int64,
    serialize_float32,
    serialize_float64,
    serialize_string,
    serialize_bytes,
    bound_int32,
    bound_int64,
    bound_float32,
    bound_float64,
    bound_boolean,
    bound_string,
    bound_bytes,
    ColumnBound,
)


def _same(a: List[UInt8], expected: List[Int]) -> Bool:
    if len(a) != len(expected):
        return False
    for i in range(len(a)):
        if Int(a[i]) != expected[i]:
            return False
    return True


def test_scalar_serialization_is_appendix_d() raises:
    assert_true(_same(serialize_boolean(True), [1]))
    assert_true(_same(serialize_boolean(False), [0]))
    # int 34 -> 22 00 00 00 (the spec's example); -2 -> FE FF FF FF.
    assert_true(_same(serialize_int32(Int32(34)), [0x22, 0, 0, 0]))
    assert_true(_same(serialize_int32(Int32(-2)), [0xFE, 0xFF, 0xFF, 0xFF]))
    # long 34 -> 22 00 00 00 00 00 00 00.
    assert_true(_same(serialize_int64(Int64(34)), [0x22, 0, 0, 0, 0, 0, 0, 0]))
    assert_true(
        _same(serialize_int64(Int64(-1)), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    )
    # float 1.0 -> 00 00 80 3F; double 1.0 -> 00 00 00 00 00 00 F0 3F.
    assert_true(_same(serialize_float32(Float32(1.0)), [0, 0, 0x80, 0x3F]))
    assert_true(
        _same(serialize_float64(Float64(1.0)), [0, 0, 0, 0, 0, 0, 0xF0, 0x3F])
    )
    # string: UTF-8 bytes, no length prefix ("iceberg", then "é" = C3 A9).
    assert_equal(len(serialize_string(String("iceberg"))), 7)
    assert_true(_same(serialize_string(String("é")), [0xC3, 0xA9]))
    var raw = List[UInt8]()
    raw.append(0x00)
    raw.append(0xFF)
    assert_true(_same(serialize_bytes(raw), [0x00, 0xFF]))


def test_int_bounds_skip_nulls_and_count_them() raises:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(5)
    arr.set(0, Int64(7))
    arr.set(1, Int64(-3))
    arr.set(2, Int64(99))
    arr.set(3, Int64(0))
    arr.set(4, Int64(1000000))
    arr._set_null(2)  # the 99 is null: it must not become the max
    var b = bound_int64(4, arr)
    assert_equal(b.field_id, 4)
    assert_equal(b.null_count, 1)
    assert_equal(b.value_count, 5)
    assert_true(_same(b.lower.value(), [0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    assert_true(_same(b.upper.value(), [0x40, 0x42, 0x0F, 0, 0, 0, 0, 0]))


def test_int32_bounds() raises:
    var vals = List[Int32]()
    vals.append(Int32(5))
    vals.append(Int32(-8))
    vals.append(Int32(5))
    var b = bound_int32(1, PrimitiveArray[DType.int32].from_list(vals))
    assert_true(_same(b.lower.value(), [0xF8, 0xFF, 0xFF, 0xFF]))
    assert_true(_same(b.upper.value(), [5, 0, 0, 0]))
    assert_equal(b.null_count, 0)


def test_all_null_column_has_no_bound() raises:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(2)
    arr._set_null(0)
    arr._set_null(1)
    var b = bound_int32(9, arr)
    assert_false(Bool(b.lower))
    assert_false(Bool(b.upper))
    assert_equal(b.null_count, 2)
    assert_equal(b.value_count, 2)
    var empty = bound_int64(3, PrimitiveArray[DType.int64].from_list(List[Int64]()))
    assert_false(Bool(empty.lower))
    assert_equal(empty.value_count, 0)


def test_boolean_bounds() raises:
    var arr = BooleanArray.allocate(3)
    arr.set(0, True)
    arr.set(1, True)
    arr.set(2, True)
    var all_true = bound_boolean(1, arr)
    assert_true(_same(all_true.lower.value(), [1]))
    assert_true(_same(all_true.upper.value(), [1]))
    arr.set(1, False)
    var mixed = bound_boolean(1, arr)
    assert_true(_same(mixed.lower.value(), [0]))
    assert_true(_same(mixed.upper.value(), [1]))


def test_float_nan_is_never_a_bound() raises:
    var nan = Float64(0) / Float64(0)
    var vals = List[Float64]()
    vals.append(nan)  # a NaN FIRST must not stick as min and max
    vals.append(2.5)
    vals.append(-1.5)
    vals.append(nan)
    var b = bound_float64(1, PrimitiveArray[DType.float64].from_list(vals))
    assert_true(_same(b.lower.value(), _le64(-1.5)))
    assert_true(_same(b.upper.value(), _le64(2.5)))
    assert_equal(b.value_count, 4)

    var only_nan = List[Float64]()
    only_nan.append(nan)
    var bn = bound_float64(1, PrimitiveArray[DType.float64].from_list(only_nan))
    assert_false(Bool(bn.lower))
    assert_false(Bool(bn.upper))

    var nan32 = Float32(0) / Float32(0)
    var v32 = List[Float32]()
    v32.append(nan32)
    v32.append(Float32(3.0))
    var b32 = bound_float32(2, PrimitiveArray[DType.float32].from_list(v32))
    assert_true(_same(b32.lower.value(), [0, 0, 0x40, 0x40]))
    assert_true(_same(b32.upper.value(), [0, 0, 0x40, 0x40]))


def _le64(v: Float64) -> List[Int]:
    var bytes = serialize_float64(v)
    var out = List[Int]()
    for i in range(len(bytes)):
        out.append(Int(bytes[i]))
    return out^


def test_float_zero_bounds_cover_both_zeros() raises:
    # +0.0 first: the lower bound must still be -0.0 (sign bit set) and the
    # upper bound +0.0, whichever zero the scan met first.
    var vals = List[Float64]()
    vals.append(Float64(0.0))
    vals.append(Float64(0.0))
    var b = bound_float64(1, PrimitiveArray[DType.float64].from_list(vals))
    assert_true(_same(b.lower.value(), [0, 0, 0, 0, 0, 0, 0, 0x80]))
    assert_true(_same(b.upper.value(), [0, 0, 0, 0, 0, 0, 0, 0]))
    var v32 = List[Float32]()
    v32.append(bitcast[DType.float32, 1](UInt32(0x80000000)))
    var b32 = bound_float32(1, PrimitiveArray[DType.float32].from_list(v32))
    assert_true(_same(b32.lower.value(), [0, 0, 0, 0x80]))
    assert_true(_same(b32.upper.value(), [0, 0, 0, 0]))


def test_string_bounds_compare_unsigned_bytes() raises:
    var names = List[String]()
    names.append(String("b"))
    names.append(String("é"))  # C3 A9 sorts after every ASCII byte
    names.append(String("Z"))
    names.append(String("a"))
    var b = bound_string(2, StringArray[HeapRegion].from_strings(names))
    assert_true(_same(b.lower.value(), [ord("Z")]))
    assert_true(_same(b.upper.value(), [0xC3, 0xA9]))

    var valid = List[Bool]()
    valid.append(True)
    valid.append(False)
    var two = List[String]()
    two.append(String("m"))
    two.append(String("zzz"))  # null: ignored
    var bn = bound_string(
        2, StringArray[HeapRegion].from_strings_with_validity(two, valid)
    )
    assert_true(_same(bn.upper.value(), [ord("m")]))
    assert_equal(bn.null_count, 1)


def test_bytes_bounds_keep_high_bytes_verbatim() raises:
    var keys = List[List[UInt8]]()
    var k1 = List[UInt8]()
    k1.append(0x00)
    k1.append(0xFF)
    var k2 = List[UInt8]()
    k2.append(0x00)
    k2.append(0x80)
    k2.append(0x01)
    var k3 = List[UInt8]()
    k3.append(0x01)
    keys.append(k1^)
    keys.append(k2^)
    keys.append(k3^)
    var b = bound_bytes(7, keys)
    assert_true(_same(b.lower.value(), [0x00, 0x80, 0x01]))
    assert_true(_same(b.upper.value(), [0x01]))
    assert_equal(b.value_count, 3)
    assert_equal(b.null_count, 0)
    var none = bound_bytes(7, List[List[UInt8]]())
    assert_false(Bool(none.lower))


def _f64(vals: List[Float64]) raises -> ColumnBound:
    return bound_float64(1, PrimitiveArray[DType.float64].from_list(vals))


def _f32(vals: List[Float32]) raises -> ColumnBound:
    return bound_float32(1, PrimitiveArray[DType.float32].from_list(vals))


def test_zero_bounds_in_every_mix() raises:
    var nz64 = bitcast[DType.float64, 1](UInt64(0x8000000000000000))
    var nz32 = bitcast[DType.float32, 1](UInt32(0x80000000))
    var NEG0_64: List[Int] = [0, 0, 0, 0, 0, 0, 0, 0x80]
    var POS0_64: List[Int] = [0, 0, 0, 0, 0, 0, 0, 0]
    # f64: lower is always -0.0 and upper +0.0 when that bound is a zero.
    var a = List[Float64]()
    a.append(nz64)
    var ba = _f64(a)
    assert_true(_same(ba.lower.value(), NEG0_64))
    assert_true(_same(ba.upper.value(), POS0_64))
    var b = List[Float64]()
    b.append(Float64(0))
    b.append(Float64(5))
    var bb = _f64(b)
    assert_true(_same(bb.lower.value(), NEG0_64))
    assert_true(_same(bb.upper.value(), _le64(5.0)))
    var c = List[Float64]()
    c.append(Float64(-5))
    c.append(nz64)
    var bc = _f64(c)
    assert_true(_same(bc.lower.value(), _le64(-5.0)))
    assert_true(_same(bc.upper.value(), POS0_64))
    # f32, the same four shapes.
    var NEG0_32: List[Int] = [0, 0, 0, 0x80]
    var POS0_32: List[Int] = [0, 0, 0, 0]
    var d = List[Float32]()
    d.append(Float32(0))
    var bd = _f32(d)
    assert_true(_same(bd.lower.value(), NEG0_32))
    assert_true(_same(bd.upper.value(), POS0_32))
    var e = List[Float32]()
    e.append(nz32)
    var be = _f32(e)
    assert_true(_same(be.lower.value(), NEG0_32))
    assert_true(_same(be.upper.value(), POS0_32))
    var f = List[Float32]()
    f.append(nz32)
    f.append(Float32(5))
    var bf = _f32(f)
    assert_true(_same(bf.lower.value(), NEG0_32))
    assert_true(_same(bf.upper.value(), [0, 0, 0xA0, 0x40]))
    var g = List[Float32]()
    g.append(Float32(-5))
    g.append(Float32(0))
    var bg = _f32(g)
    assert_true(_same(bg.lower.value(), [0, 0, 0xA0, 0xC0]))
    assert_true(_same(bg.upper.value(), POS0_32))


def test_float_scans_count_nulls_and_all_nan() raises:
    var arr = PrimitiveArray[DType.float32].allocate_nullable(3)
    arr.set(0, Float32(1.5))
    arr.set(1, Float32(9.0))
    arr.set(2, Float32(-2.0))
    arr._set_null(1)
    var b = bound_float32(5, arr)
    assert_equal(b.null_count, 1)
    assert_equal(b.value_count, 3)
    assert_true(_same(b.lower.value(), [0, 0, 0, 0xC0]))
    assert_true(_same(b.upper.value(), [0, 0, 0xC0, 0x3F]))
    var nan32 = Float32(0) / Float32(0)
    var only = List[Float32]()
    only.append(nan32)
    only.append(nan32)
    var bn = _f32(only)
    assert_false(Bool(bn.lower))
    assert_equal(bn.value_count, 2)
    var inf = List[Float64]()
    inf.append(Float64(1) / Float64(0))
    inf.append(Float64(-1) / Float64(0))
    var bi = _f64(inf)
    assert_true(_same(bi.lower.value(), [0, 0, 0, 0, 0, 0, 0xF0, 0xFF]))
    assert_true(_same(bi.upper.value(), [0, 0, 0, 0, 0, 0, 0xF0, 0x7F]))


def main() raises:
    test_scalar_serialization_is_appendix_d()
    test_int_bounds_skip_nulls_and_count_them()
    test_int32_bounds()
    test_all_null_column_has_no_bound()
    test_boolean_bounds()
    test_float_nan_is_never_a_bound()
    test_float_zero_bounds_cover_both_zeros()
    test_string_bounds_compare_unsigned_bytes()
    test_bytes_bounds_keep_high_bytes_verbatim()
    test_zero_bounds_in_every_mix()
    test_float_scans_count_nulls_and_all_nan()
    print("test_iceberg_bounds: all passed")

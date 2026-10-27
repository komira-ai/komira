# The always-inlined helpers of the decoders at inputs chosen at run time:
# the zero and negative widths of the FLBA integer decoders, each narrow
# integer ConvertedType of a decoded INT32 column, and the spelling of the
# ARROW:schema key byte by byte. The existing direct tests pass these as
# literals, which the compiler folds out of the inlined body; here a
# non-inlined caller takes them as arguments, so the helpers' own branches run.
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.types import (
    CONVERTED_TYPE_INT_8,
    CONVERTED_TYPE_INT_16,
    CONVERTED_TYPE_UINT_8,
    CONVERTED_TYPE_UINT_16,
    CONVERTED_TYPE_UINT_32,
    ParquetType,
)

from komira_parquet.decimal_decode import _flba_bytes_to_i128
from komira_parquet.decode_helpers import _narrow_int_logical_type
from komira_parquet.footer_header import _arrow_schema_key_byte
from komira_parquet.plain_flba import _flba_value_to_int64_be

comptime _I128 = SIMD[DType.int128, 1]


@no_inline
def _i128_of(bytes: List[UInt8], width: Int) -> _I128:
    return _flba_bytes_to_i128(bytes.unsafe_ptr(), width)


@no_inline
def _i64_of(bytes: List[UInt8], width: Int) -> Int64:
    return _flba_value_to_int64_be(bytes.unsafe_ptr(), width)


@no_inline
def _narrowed(values: List[Int], converted_type: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, Int32(values[i]))
    return _narrow_int_logical_type(
        Column.from_primitive[DType.int32](arr), ParquetType.INT32, converted_type
    )


@no_inline
def _key_byte(i: Int) -> UInt8:
    return _arrow_schema_key_byte(i)


def test_a_decimal_of_no_width_is_zero_and_a_negative_one_is_sign_extended() raises:
    var b: List[UInt8] = [UInt8(0xFF), UInt8(0xFE)]
    assert_true(_i128_of(b, 0) == _I128(0))
    assert_true(_i128_of(b, -3) == _I128(0))
    assert_true(_i128_of(b, 1) == _I128(-1))
    assert_true(_i128_of(b, 2) == _I128(-2))


def test_an_flba_integer_of_no_width_is_zero_and_the_sign_comes_from_the_first_byte() raises:
    var b: List[UInt8] = [UInt8(0xFF), UInt8(0x01)]
    assert_equal(_i64_of(b, 0), Int64(0))
    assert_equal(_i64_of(b, -2), Int64(0))
    assert_equal(_i64_of(b, 1), Int64(-1))
    assert_equal(_i64_of(b, 2), Int64(-255))


def test_each_narrow_integer_annotation_keeps_the_low_bytes() raises:
    var vals: List[Int] = [-128, 127, 255, -1, 300, 65535]
    var c16 = _narrowed(vals, CONVERTED_TYPE_INT_16)
    assert_true(c16.arrow_type == ArrowType.INT16)
    assert_equal(c16.as_primitive[DType.int16]().get(0), Int16(-128))
    assert_equal(c16.as_primitive[DType.int16]().get(4), Int16(300))
    var u8 = _narrowed(vals, CONVERTED_TYPE_UINT_8)
    assert_true(u8.arrow_type == ArrowType.UINT8)
    assert_equal(u8.as_primitive[DType.uint8]().get(2), UInt8(255))
    assert_equal(u8.as_primitive[DType.uint8]().get(4), UInt8(44))
    var u16 = _narrowed(vals, CONVERTED_TYPE_UINT_16)
    assert_true(u16.arrow_type == ArrowType.UINT16)
    assert_equal(u16.as_primitive[DType.uint16]().get(3), UInt16(65535))
    assert_equal(u16.as_primitive[DType.uint16]().get(5), UInt16(65535))
    var i8 = _narrowed(vals, CONVERTED_TYPE_INT_8)
    assert_true(i8.arrow_type == ArrowType.INT8)
    assert_equal(i8.as_primitive[DType.int8]().get(1), Int8(127))
    # UINT_32 is not narrowed: the column stays INT32.
    var same = _narrowed(vals, CONVERTED_TYPE_UINT_32)
    assert_true(same.arrow_type == ArrowType.INT32)


def test_the_arrow_schema_key_spells_its_literal() raises:
    var want = String("ARROW:schema").as_bytes()
    for i in range(12):
        assert_equal(Int(_key_byte(i)), Int(want[i]), "byte " + String(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

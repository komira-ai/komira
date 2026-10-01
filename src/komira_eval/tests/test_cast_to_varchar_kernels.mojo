# =============================================================================
# Tests for the cast-to-varchar kernels at
# komira_eval.cast_to_varchar_kernels
# =============================================================================
#
# This file exercises:
#
#   - Int8 / Int16 / UInt8 / UInt16 / UInt32 / UInt64 -> StringArray
#     (byte-exact edge-case checks on INT*_MIN / INT*_MAX / 0).
#   - Bool -> StringArray ("true" / "false" / null = empty).
#   - DICTIONARY (StringDictionaryArray) -> StringArray (decode-at-cast).
#   - NULL -> StringArray (N empty cells, validity all-zero).
#   - String passthrough.
#
# These tests are the canonical regression set for the public API.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.bitmap import Bitmap

from komira_eval.cast_to_varchar_kernels import (
    cast_int8_to_string,
    cast_int16_to_string,
    cast_int32_to_string,
    cast_int64_to_string,
    cast_uint8_to_string,
    cast_uint16_to_string,
    cast_uint32_to_string,
    cast_uint64_to_string,
    cast_bool_to_string,
    cast_string_passthrough,
    cast_dictionary_to_string,
    cast_null_to_empty,
)


# =============================================================================
# Helpers — build PrimitiveArray fixtures with optional null mask
# =============================================================================


def _build_int64(vals: List[Int64], nulls: List[Bool]) raises -> PrimitiveArray[DType.int64]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int64](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _build_int32(vals: List[Int32], nulls: List[Bool]) raises -> PrimitiveArray[DType.int32]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int32](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _build_int16(vals: List[Int16], nulls: List[Bool]) raises -> PrimitiveArray[DType.int16]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int16].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int16](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _build_int8(vals: List[Int8], nulls: List[Bool]) raises -> PrimitiveArray[DType.int8]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int8].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int8](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _build_uint64(vals: List[UInt64], nulls: List[Bool]) raises -> PrimitiveArray[DType.uint64]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.uint64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.uint64](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _build_uint32(vals: List[UInt32], nulls: List[Bool]) raises -> PrimitiveArray[DType.uint32]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.uint32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.uint32](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _build_uint16(vals: List[UInt16], nulls: List[Bool]) raises -> PrimitiveArray[DType.uint16]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.uint16].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.uint16](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _build_uint8(vals: List[UInt8], nulls: List[Bool]) raises -> PrimitiveArray[DType.uint8]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.uint8].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.uint8](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _build_bool(vals: List[Bool], nulls: List[Bool]) raises -> PrimitiveArray[DType.bool]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.bool].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.bool](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _all_false(n: Int) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(False)
    return out^


# =============================================================================
# Int64 byte-exact verify — INT64_MIN / INT64_MAX / 0 / +-1
# =============================================================================


def test_cast_int64_to_string_edge_cases() raises:
    """Byte-exact: 0, +-1, INT64_MAX, INT64_MIN, INT64_MAX-1."""
    var vals = List[Int64]()
    vals.append(Int64(0))
    vals.append(Int64(1))
    vals.append(Int64(-1))
    vals.append(Int64(9223372036854775807))      # INT64_MAX
    vals.append(Int64(-9223372036854775808))     # INT64_MIN
    vals.append(Int64(9223372036854775806))      # INT64_MAX - 1
    var arr = _build_int64(vals, _all_false(6))
    var sa = cast_int64_to_string(arr)
    assert_equal(sa.length, 6)
    assert_equal(sa.null_count, 0)
    assert_equal(sa.get(0), String("0"))
    assert_equal(sa.get(1), String("1"))
    assert_equal(sa.get(2), String("-1"))
    assert_equal(sa.get(3), String("9223372036854775807"))
    assert_equal(sa.get(4), String("-9223372036854775808"))
    assert_equal(sa.get(5), String("9223372036854775806"))


def test_cast_int64_to_string_with_nulls() raises:
    """Nulls -> empty cell; non-nulls preserved."""
    var vals = List[Int64]()
    vals.append(Int64(42))
    vals.append(Int64(0))         # will be marked null
    vals.append(Int64(-12345))
    vals.append(Int64(0))         # will be marked null
    var nulls = List[Bool]()
    nulls.append(False)
    nulls.append(True)
    nulls.append(False)
    nulls.append(True)
    var arr = _build_int64(vals, nulls)
    var sa = cast_int64_to_string(arr)
    assert_equal(sa.length, 4)
    assert_equal(sa.null_count, 2)
    assert_equal(sa.get(0), String("42"))
    assert_true(sa.is_null(1))
    assert_equal(sa.get(1), String(""))   # null cell = empty
    assert_equal(sa.get(2), String("-12345"))
    assert_true(sa.is_null(3))


# =============================================================================
# Int32 / Int16 / Int8 — INT*_MIN / INT*_MAX edges
# =============================================================================


def test_cast_int32_to_string_edges() raises:
    var vals = List[Int32]()
    vals.append(Int32(0))
    vals.append(Int32(2147483647))     # INT32_MAX
    vals.append(Int32(-2147483648))    # INT32_MIN
    var arr = _build_int32(vals, _all_false(3))
    var sa = cast_int32_to_string(arr)
    assert_equal(sa.get(0), String("0"))
    assert_equal(sa.get(1), String("2147483647"))
    assert_equal(sa.get(2), String("-2147483648"))


def test_cast_int16_to_string_edges() raises:
    var vals = List[Int16]()
    vals.append(Int16(0))
    vals.append(Int16(32767))
    vals.append(Int16(-32768))
    var arr = _build_int16(vals, _all_false(3))
    var sa = cast_int16_to_string(arr)
    assert_equal(sa.get(0), String("0"))
    assert_equal(sa.get(1), String("32767"))
    assert_equal(sa.get(2), String("-32768"))


def test_cast_int8_to_string_edges() raises:
    var vals = List[Int8]()
    vals.append(Int8(0))
    vals.append(Int8(127))
    vals.append(Int8(-128))
    vals.append(Int8(-1))
    var arr = _build_int8(vals, _all_false(4))
    var sa = cast_int8_to_string(arr)
    assert_equal(sa.get(0), String("0"))
    assert_equal(sa.get(1), String("127"))
    assert_equal(sa.get(2), String("-128"))
    assert_equal(sa.get(3), String("-1"))


# =============================================================================
# UInt64 / 32 / 16 / 8 — unsigned MAX edges
# =============================================================================


def test_cast_uint64_to_string_edges() raises:
    var vals = List[UInt64]()
    vals.append(UInt64(0))
    vals.append(UInt64(1))
    vals.append(UInt64(18446744073709551615))   # UINT64_MAX
    var arr = _build_uint64(vals, _all_false(3))
    var sa = cast_uint64_to_string(arr)
    assert_equal(sa.get(0), String("0"))
    assert_equal(sa.get(1), String("1"))
    assert_equal(sa.get(2), String("18446744073709551615"))


def test_cast_uint32_to_string_edges() raises:
    var vals = List[UInt32]()
    vals.append(UInt32(0))
    vals.append(UInt32(4294967295))    # UINT32_MAX
    var arr = _build_uint32(vals, _all_false(2))
    var sa = cast_uint32_to_string(arr)
    assert_equal(sa.get(0), String("0"))
    assert_equal(sa.get(1), String("4294967295"))


def test_cast_uint16_to_string_edges() raises:
    var vals = List[UInt16]()
    vals.append(UInt16(0))
    vals.append(UInt16(65535))
    var arr = _build_uint16(vals, _all_false(2))
    var sa = cast_uint16_to_string(arr)
    assert_equal(sa.get(0), String("0"))
    assert_equal(sa.get(1), String("65535"))


def test_cast_uint8_to_string_edges() raises:
    var vals = List[UInt8]()
    vals.append(UInt8(0))
    vals.append(UInt8(255))
    var arr = _build_uint8(vals, _all_false(2))
    var sa = cast_uint8_to_string(arr)
    assert_equal(sa.get(0), String("0"))
    assert_equal(sa.get(1), String("255"))


# =============================================================================
# Bool -> "true" / "false" — DuckDB-lowercase parity
# =============================================================================


def test_cast_bool_to_string_basic() raises:
    """True -> "true" (4 bytes), False -> "false" (5 bytes)."""
    var vals = List[Bool]()
    vals.append(True)
    vals.append(False)
    vals.append(True)
    vals.append(False)
    vals.append(True)
    var arr = _build_bool(vals, _all_false(5))
    var sa = cast_bool_to_string(arr)
    assert_equal(sa.length, 5)
    assert_equal(sa.null_count, 0)
    assert_equal(sa.get(0), String("true"))
    assert_equal(sa.get(1), String("false"))
    assert_equal(sa.get(2), String("true"))
    assert_equal(sa.get(3), String("false"))
    assert_equal(sa.get(4), String("true"))


def test_cast_bool_to_string_with_nulls() raises:
    var vals = List[Bool]()
    vals.append(True)
    vals.append(False)
    vals.append(True)
    var nulls = List[Bool]()
    nulls.append(False)
    nulls.append(True)
    nulls.append(False)
    var arr = _build_bool(vals, nulls)
    var sa = cast_bool_to_string(arr)
    assert_equal(sa.length, 3)
    assert_equal(sa.null_count, 1)
    assert_equal(sa.get(0), String("true"))
    assert_true(sa.is_null(1))
    assert_equal(sa.get(1), String(""))
    assert_equal(sa.get(2), String("true"))


# =============================================================================
# String passthrough — identity returns same StringArray
# =============================================================================


def test_cast_string_passthrough_identity() raises:
    """`cast_string_passthrough` returns the input by move; round-trips
    every value."""
    var vals = List[String]()
    vals.append(String("alpha"))
    vals.append(String("beta gamma"))
    vals.append(String(""))
    vals.append(String("delta"))
    var sa_in = StringArray.from_strings(vals)
    # Snapshot values before move-out.
    var v0 = sa_in.get(0)
    var v1 = sa_in.get(1)
    var v2 = sa_in.get(2)
    var v3 = sa_in.get(3)
    var sa_out = cast_string_passthrough(sa_in^)
    assert_equal(sa_out.length, 4)
    assert_equal(sa_out.get(0), v0)
    assert_equal(sa_out.get(1), v1)
    assert_equal(sa_out.get(2), v2)
    assert_equal(sa_out.get(3), v3)


# =============================================================================
# DICTIONARY -> STRING — decode-at-cast roundtrip
# =============================================================================


def test_cast_dictionary_to_string_basic() raises:
    """Small 3-value dict + 10 indices: decode each index and verify the
    output StringArray matches `dict.get(indices[i])`."""
    var dict_values = List[String]()
    dict_values.append(String("apple"))
    dict_values.append(String("banana"))
    dict_values.append(String("cherry"))
    var dict = StringArray.from_strings(dict_values)
    # 10 indices cycling 0, 1, 2, 0, 1, 2, 0, 1, 2, 0
    var indices = PrimitiveArray[DType.int32].allocate(10)
    for i in range(10):
        indices.set(i, Scalar[DType.int32](i % 3))
    var dict_arr = StringDictionaryArray.from_parts(indices^, dict^)
    var sa = cast_dictionary_to_string(dict_arr^)
    assert_equal(sa.length, 10)
    assert_equal(sa.null_count, 0)
    assert_equal(sa.get(0), String("apple"))
    assert_equal(sa.get(1), String("banana"))
    assert_equal(sa.get(2), String("cherry"))
    assert_equal(sa.get(3), String("apple"))
    assert_equal(sa.get(4), String("banana"))
    assert_equal(sa.get(5), String("cherry"))
    assert_equal(sa.get(6), String("apple"))
    assert_equal(sa.get(7), String("banana"))
    assert_equal(sa.get(8), String("cherry"))
    assert_equal(sa.get(9), String("apple"))


# =============================================================================
# NULL -> STRING — N empty cells, all-null validity
# =============================================================================


def test_cast_null_to_empty_basic() raises:
    """5-row NULL column -> StringArray of 5 empty cells, all null."""
    var sa = cast_null_to_empty(5)
    assert_equal(sa.length, 5)
    assert_equal(sa.null_count, 5)
    assert_equal(sa.data_length, 0)
    for i in range(5):
        assert_true(sa.is_null(i))
        assert_equal(sa.get(i), String(""))


def test_cast_null_to_empty_zero_rows() raises:
    """Zero-row NULL column degenerate case: 0 length, 0 null_count
    (no rows = no nulls), data buffer empty."""
    var sa = cast_null_to_empty(0)
    assert_equal(sa.length, 0)
    assert_equal(sa.null_count, 0)
    assert_equal(sa.data_length, 0)


# =============================================================================
# Variable-width Int64 — non-edge round-trip
# =============================================================================


def test_cast_int64_to_string_variable_widths() raises:
    """Mix 1-digit through 10-digit values to exercise the 2-digit Andersson
    inner loop with a mid-range tail."""
    var vals = List[Int64]()
    vals.append(Int64(7))                # 1 digit
    vals.append(Int64(42))               # 2 digits
    vals.append(Int64(123))              # 3 digits
    vals.append(Int64(9876))             # 4 digits
    vals.append(Int64(99999))            # 5 digits
    vals.append(Int64(123456))           # 6 digits
    vals.append(Int64(-7654321))         # 7 + sign
    vals.append(Int64(98765432))         # 8 digits
    vals.append(Int64(123456789))        # 9 digits
    vals.append(Int64(9876543210))       # 10 digits
    var arr = _build_int64(vals, _all_false(10))
    var sa = cast_int64_to_string(arr)
    assert_equal(sa.length, 10)
    assert_equal(sa.get(0), String("7"))
    assert_equal(sa.get(1), String("42"))
    assert_equal(sa.get(2), String("123"))
    assert_equal(sa.get(3), String("9876"))
    assert_equal(sa.get(4), String("99999"))
    assert_equal(sa.get(5), String("123456"))
    assert_equal(sa.get(6), String("-7654321"))
    assert_equal(sa.get(7), String("98765432"))
    assert_equal(sa.get(8), String("123456789"))
    assert_equal(sa.get(9), String("9876543210"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

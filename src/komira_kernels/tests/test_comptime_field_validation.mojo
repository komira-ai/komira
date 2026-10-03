# =============================================================================
# Tests for comptime_field_validation.mojo.
#
# Coverage:
#   - Positive cases: comptime_field_validation[T, i, expected]() compiles
#     when the dtype matches the field at index i.
#   - _dtype_matches[FieldT, dt] returns True for matching pairs and False
#     for mismatches.
#
# Limitation note: the negative case (wrong dtype at the wrong index → COMPILE
# error) cannot be tested as a runtime assert because the failure happens at
# compile time, before the test binary runs. We rely on:
#   (a) the SimdOf typed-accessor surface using `comptime_field_validation`
#       internally — every `get_f64[i]()` call is a positive integration
#       test; the library building green confirms every accessor compiles cleanly against the validation gate.
#   (b) manual probes for negative cases (bad dtype fires a clear
#       `constrained[]` error message at the call site).
# =============================================================================

from std.testing import TestSuite, assert_true, assert_false

from komira_kernels.comptime_field_validation import (
    comptime_field_validation,
    _dtype_matches,
)


@fieldwise_init
struct LineItemRow(Copyable, Movable):
    var price: Float64
    var qty: Int64
    var disc: Float64


@fieldwise_init
struct WideRow(Copyable, Movable):
    var f64v: Float64
    var f32v: Float32
    var i64v: Int64
    var i32v: Int32
    var i16v: Int16
    var i8v:  Int8
    var u64v: UInt64
    var u32v: UInt32
    var u16v: UInt16
    var u8v:  UInt8
    var bv:   Bool


# -----------------------------------------------------------------------------
# 1) _dtype_matches — the per-pair predicate
# -----------------------------------------------------------------------------


def test_dtype_matches_positive() raises:
    """Every supported (FieldT, DType) pair returns True."""
    assert_true(_dtype_matches[Float64, DType.float64]())
    assert_true(_dtype_matches[Float32, DType.float32]())
    assert_true(_dtype_matches[Int64, DType.int64]())
    assert_true(_dtype_matches[Int32, DType.int32]())
    assert_true(_dtype_matches[Int16, DType.int16]())
    assert_true(_dtype_matches[Int8, DType.int8]())
    assert_true(_dtype_matches[UInt64, DType.uint64]())
    assert_true(_dtype_matches[UInt32, DType.uint32]())
    assert_true(_dtype_matches[UInt16, DType.uint16]())
    assert_true(_dtype_matches[UInt8, DType.uint8]())
    assert_true(_dtype_matches[Bool, DType.bool]())


def test_dtype_matches_negative() raises:
    """Mismatched (FieldT, DType) pairs return False."""
    assert_false(_dtype_matches[Float64, DType.int64]())
    assert_false(_dtype_matches[Int32, DType.float32]())
    assert_false(_dtype_matches[Bool, DType.uint8]())
    assert_false(_dtype_matches[Float32, DType.float64]())  # promoted
    assert_false(_dtype_matches[Int64, DType.uint64]())     # signed/unsigned


def test_dtype_matches_unsupported_returns_false() raises:
    """A FieldT not in the supported set returns False (the comptime
    `constrained[]` would fire on the actual validation call)."""
    assert_false(_dtype_matches[LineItemRow, DType.float64]())


# -----------------------------------------------------------------------------
# 2) comptime_field_validation — positive cases
# -----------------------------------------------------------------------------
#
# Each call site below is a comptime assertion; the test passes as long as
# the file compiles. Wrapping in def-bodies keeps the assertions inside a
# discoverable test fn (so TestSuite reports each as a passing case).


def test_validate_lineitem_field0_f64() raises:
    """Field 0 of LineItemRow is Float64 — validates cleanly."""
    comptime_field_validation[LineItemRow, 0, DType.float64]()
    assert_true(True)


def test_validate_lineitem_field1_i64() raises:
    """Field 1 of LineItemRow is Int64."""
    comptime_field_validation[LineItemRow, 1, DType.int64]()
    assert_true(True)


def test_validate_lineitem_field2_f64() raises:
    """Field 2 of LineItemRow is Float64."""
    comptime_field_validation[LineItemRow, 2, DType.float64]()
    assert_true(True)


def test_validate_wide_row_all_fields() raises:
    """Validate every supported (i, dtype) pair on WideRow."""
    comptime_field_validation[WideRow, 0, DType.float64]()
    comptime_field_validation[WideRow, 1, DType.float32]()
    comptime_field_validation[WideRow, 2, DType.int64]()
    comptime_field_validation[WideRow, 3, DType.int32]()
    comptime_field_validation[WideRow, 4, DType.int16]()
    comptime_field_validation[WideRow, 5, DType.int8]()
    comptime_field_validation[WideRow, 6, DType.uint64]()
    comptime_field_validation[WideRow, 7, DType.uint32]()
    comptime_field_validation[WideRow, 8, DType.uint16]()
    comptime_field_validation[WideRow, 9, DType.uint8]()
    comptime_field_validation[WideRow, 10, DType.bool]()
    assert_true(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

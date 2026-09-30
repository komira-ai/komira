# =============================================================================
# test_col_scalar_type_complete.mojo — the `col_scalar` read primitive
# =============================================================================
#
# The keystone typed read primitive. Validates that
# `BatchView.col_scalar[dt]` reads the FULL fixed-width matrix BIT-EXACTLY,
# and — the load-bearing assertion — that an i64 channel (read an F64 column
# via col_i64 then NUMERICALLY cast to Scalar[float64]) produces GARBAGE,
# which col_scalar avoids.
#
# This is the direct read-primitive check for the silent-corruption class a
# join key read through an i64 channel belongs to.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.column import Column
from komira_core.arrow.schema import SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType

from komira_core.collections.batch_view import (
    BatchView,
    batch_view_over,
    scalar_arrow_type,
)


# ---------------------------------------------------------------------------
# Single-column builders for each fixed-width DType
# ---------------------------------------------------------------------------


def _f64_batch(vals: List[Float64]) raises -> RecordBatch:
    var prim = List[Scalar[DType.float64]]()
    for i in range(len(vals)):
        prim.append(Scalar[DType.float64](vals[i]))
    var arr = PrimitiveArray[DType.float64].from_list(prim)
    var sb = SchemaBuilder()
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.float64](arr^)
    )


def _f32_batch(vals: List[Float32]) raises -> RecordBatch:
    var prim = List[Scalar[DType.float32]]()
    for i in range(len(vals)):
        prim.append(Scalar[DType.float32](vals[i]))
    var arr = PrimitiveArray[DType.float32].from_list(prim)
    var sb = SchemaBuilder()
    sb.add_field(Field("f", ArrowType.FLOAT32, False))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.float32](arr^)
    )


def _i32_batch(vals: List[Int32]) raises -> RecordBatch:
    var prim = List[Scalar[DType.int32]]()
    for i in range(len(vals)):
        prim.append(Scalar[DType.int32](vals[i]))
    var arr = PrimitiveArray[DType.int32].from_list(prim)
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT32, False))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.int32](arr^)
    )


def _i16_batch(vals: List[Int16]) raises -> RecordBatch:
    var prim = List[Scalar[DType.int16]]()
    for i in range(len(vals)):
        prim.append(Scalar[DType.int16](vals[i]))
    var arr = PrimitiveArray[DType.int16].from_list(prim)
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT16, False))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.int16](arr^)
    )


def _u32_batch(vals: List[UInt32]) raises -> RecordBatch:
    var prim = List[Scalar[DType.uint32]]()
    for i in range(len(vals)):
        prim.append(Scalar[DType.uint32](vals[i]))
    var arr = PrimitiveArray[DType.uint32].from_list(prim)
    var sb = SchemaBuilder()
    sb.add_field(Field("u", ArrowType.UINT32, False))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.uint32](arr^)
    )


# ---------------------------------------------------------------------------
# RED-before / GREEN-after: the F64 i64-channel corruption
# ---------------------------------------------------------------------------


def test_col_scalar_f64_exact_vs_i64_channel_corruption() raises:
    """THE keystone check. An F64 column read via an i64 channel
    (col_i64 -> Scalar[float64](i64_bits)) is GARBAGE; col_scalar[float64] is
    exact. This is the silent-corruption class a join key read through an
    i64 channel belongs to."""
    var vals: List[Float64] = [
        Float64(4.2),
        Float64(100.25),
        Float64(-7.5),
        Float64(3.141592653589793),
    ]
    var batch = _f64_batch(vals)
    var bv = batch_view_over(batch)

    # GREEN: col_scalar[float64] reads the exact float.
    assert_equal(bv.col_scalar[DType.float64](0, 0), Float64(4.2))
    assert_equal(bv.col_scalar[DType.float64](0, 1), Float64(100.25))
    assert_equal(bv.col_scalar[DType.float64](0, 2), Float64(-7.5))
    assert_equal(
        bv.col_scalar[DType.float64](0, 3), Float64(3.141592653589793)
    )

    # The i64 channel reads the float's BIT PATTERN as
    # an Int64 then NUMERICALLY casts to Float64 -> garbage. We reconstruct
    # that exact lossy path here and assert it does NOT equal the true value
    # (proving the corruption col_scalar removes).
    var i64_bits_0 = bv.col_i64(0).load[1](0)[0]  # raw 8 bytes of 4.2 as i64
    var corrupt_0 = Scalar[DType.float64](i64_bits_0)  # numeric cast (lossy)
    assert_false(
        corrupt_0 == Float64(4.2),
        "i64-channel must NOT reproduce 4.2 (it reads the bit pattern)",
    )
    # And col_scalar is exactly NOT that corrupt value.
    assert_true(bv.col_scalar[DType.float64](0, 0) != corrupt_0)


def test_col_scalar_f32_exact() raises:
    var vals: List[Float32] = [Float32(1.5), Float32(-2.25), Float32(8.125)]
    var batch = _f32_batch(vals)
    var bv = batch_view_over(batch)
    assert_equal(bv.col_scalar[DType.float32](0, 0), Float32(1.5))
    assert_equal(bv.col_scalar[DType.float32](0, 1), Float32(-2.25))
    assert_equal(bv.col_scalar[DType.float32](0, 2), Float32(8.125))


def test_col_scalar_i32_exact() raises:
    var vals: List[Int32] = [Int32(7), Int32(-99), Int32(2000000000)]
    var batch = _i32_batch(vals)
    var bv = batch_view_over(batch)
    assert_equal(bv.col_scalar[DType.int32](0, 0), Int32(7))
    assert_equal(bv.col_scalar[DType.int32](0, 1), Int32(-99))
    assert_equal(bv.col_scalar[DType.int32](0, 2), Int32(2000000000))


def test_col_scalar_i16_narrow_no_overread() raises:
    """A narrow I16 column read via col_scalar[int16] is exact — an i64
    channel would over-read 8 bytes (reading adjacent cells)."""
    var vals: List[Int16] = [Int16(5), Int16(-32000), Int16(32767)]
    var batch = _i16_batch(vals)
    var bv = batch_view_over(batch)
    assert_equal(bv.col_scalar[DType.int16](0, 0), Int16(5))
    assert_equal(bv.col_scalar[DType.int16](0, 1), Int16(-32000))
    assert_equal(bv.col_scalar[DType.int16](0, 2), Int16(32767))


def test_col_scalar_u32_exact() raises:
    var vals: List[UInt32] = [UInt32(0), UInt32(4000000000), UInt32(123)]
    var batch = _u32_batch(vals)
    var bv = batch_view_over(batch)
    assert_equal(bv.col_scalar[DType.uint32](0, 0), UInt32(0))
    assert_equal(bv.col_scalar[DType.uint32](0, 1), UInt32(4000000000))
    assert_equal(bv.col_scalar[DType.uint32](0, 2), UInt32(123))


# ---------------------------------------------------------------------------
# scalar_arrow_type — the output-schema synthesis mirror
# ---------------------------------------------------------------------------


def test_scalar_arrow_type_full_matrix() raises:
    assert_true(scalar_arrow_type[DType.int64]() == ArrowType.INT64)
    assert_true(scalar_arrow_type[DType.uint64]() == ArrowType.UINT64)
    assert_true(scalar_arrow_type[DType.int32]() == ArrowType.INT32)
    assert_true(scalar_arrow_type[DType.uint32]() == ArrowType.UINT32)
    assert_true(scalar_arrow_type[DType.int16]() == ArrowType.INT16)
    assert_true(scalar_arrow_type[DType.uint16]() == ArrowType.UINT16)
    assert_true(scalar_arrow_type[DType.int8]() == ArrowType.INT8)
    assert_true(scalar_arrow_type[DType.uint8]() == ArrowType.UINT8)
    assert_true(scalar_arrow_type[DType.float64]() == ArrowType.FLOAT64)
    assert_true(scalar_arrow_type[DType.float32]() == ArrowType.FLOAT32)
    assert_true(scalar_arrow_type[DType.bool]() == ArrowType.BOOL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

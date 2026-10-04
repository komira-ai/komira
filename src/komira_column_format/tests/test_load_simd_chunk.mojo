# =============================================================================
# test_load_simd_chunk.mojo — RecordBatch -> SIMD chunk loader tests
# =============================================================================
#
# UDF-PHASE-B3-7-PREREQ (RFC §6.2 prerequisite primitive). Tests the
# `load_simd_chunk[dtype, W]` free function in
# `komira_engine_operators/load_simd_chunk.mojo`. These tests would
# FAIL at pre-B3-7-PREREQ HEAD because the function did not exist.
#
# Coverage:
#   - W=4 / W=8 SIMD load returns the expected values.
#   - Validity mask is all-True for a non-nullable column.
#   - Validity mask reflects per-lane nulls for a nullable column.
#   - Out-of-bounds chunk_start raises.
#   - Multi-column batch: each col_idx reads from the right column.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType

from komira_engine_operators.load_simd_chunk import load_simd_chunk


# =============================================================================
# Helpers
# =============================================================================


def _schema_f64_one() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, False))
    return sb.build()


def _schema_f64_two() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("y"), ArrowType.FLOAT64, False))
    return sb.build()


def _schema_i64_nullable_one() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    return sb.build()


def _batch_one_f64(var vals: List[Float64]) raises -> RecordBatch:
    var typed: List[Scalar[DType.float64]] = []
    for i in range(len(vals)):
        typed.append(Scalar[DType.float64](vals[i]))
    var col = Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(typed)
    )
    return RecordBatch.from_typed_columns_1(_schema_f64_one()^, col^)


def _batch_two_f64(
    var xs: List[Float64], var ys: List[Float64]
) raises -> RecordBatch:
    var xs_typed: List[Scalar[DType.float64]] = []
    for i in range(len(xs)):
        xs_typed.append(Scalar[DType.float64](xs[i]))
    var ys_typed: List[Scalar[DType.float64]] = []
    for i in range(len(ys)):
        ys_typed.append(Scalar[DType.float64](ys[i]))
    var col_x = Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(xs_typed)
    )
    var col_y = Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(ys_typed)
    )
    return RecordBatch.from_typed_columns_2(_schema_f64_two()^, col_x^, col_y^)


def _batch_one_i64_with_nulls(
    var vals: List[Int],
    var null_idxs: List[Int],
) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, Scalar[DType.int64](vals[i]))
    for i in range(len(null_idxs)):
        arr._set_null(null_idxs[i])
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema_i64_nullable_one()^, col^)


# =============================================================================
# Tests
# =============================================================================


def test_load_simd_chunk_w4_f64_values() raises:
    """load_simd_chunk[f64, 4] returns the expected 4 lanes."""
    var rb = _batch_one_f64([1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5])
    var (vals, valid) = load_simd_chunk[DType.float64, 4](rb, 0, 0)
    assert_equal(vals[0], Float64(1.5))
    assert_equal(vals[1], Float64(2.5))
    assert_equal(vals[2], Float64(3.5))
    assert_equal(vals[3], Float64(4.5))
    assert_true(valid[0])
    assert_true(valid[1])
    assert_true(valid[2])
    assert_true(valid[3])


def test_load_simd_chunk_w4_offset_chunk() raises:
    """load_simd_chunk at non-zero chunk_start advances to the right lanes."""
    var rb = _batch_one_f64([1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5])
    var (vals, valid) = load_simd_chunk[DType.float64, 4](rb, 0, 4)
    assert_equal(vals[0], Float64(5.5))
    assert_equal(vals[1], Float64(6.5))
    assert_equal(vals[2], Float64(7.5))
    assert_equal(vals[3], Float64(8.5))
    assert_true(valid[0])
    assert_true(valid[1])
    assert_true(valid[2])
    assert_true(valid[3])


def test_load_simd_chunk_w8_all_valid() raises:
    """load_simd_chunk[f64, 8] over a non-nullable column gives all-True validity."""
    var rb = _batch_one_f64([1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5])
    var (vals, valid) = load_simd_chunk[DType.float64, 8](rb, 0, 0)
    assert_equal(vals[0], Float64(1.5))
    assert_equal(vals[7], Float64(8.5))
    for j in range(8):
        assert_true(valid[j])


def test_load_simd_chunk_with_nulls_validity_mask() raises:
    """A nullable column with per-lane nulls returns the right validity mask."""
    # Values: 10, 20, 30, 40, 50, 60, 70, 80. Null indices 1, 3, 5.
    var rb = _batch_one_i64_with_nulls(
        [10, 20, 30, 40, 50, 60, 70, 80],
        [1, 3, 5],
    )
    var (vals, valid) = load_simd_chunk[DType.int64, 8](rb, 0, 0)
    assert_equal(vals[0], Int64(10))
    # We don't assert vals at null positions (Arrow leaves those bytes as
    # whatever was set; only the validity bit is the contract).
    assert_true(valid[0])
    assert_false(valid[1])
    assert_true(valid[2])
    assert_false(valid[3])
    assert_true(valid[4])
    assert_false(valid[5])
    assert_true(valid[6])
    assert_true(valid[7])


def test_load_simd_chunk_multi_column_col_idx() raises:
    """load_simd_chunk(col_idx=0) and col_idx=1 read from the right columns."""
    var rb = _batch_two_f64(
        [1.0, 2.0, 3.0, 4.0],
        [10.0, 20.0, 30.0, 40.0],
    )
    var (vx, valx) = load_simd_chunk[DType.float64, 4](rb, 0, 0)
    var (vy, valy) = load_simd_chunk[DType.float64, 4](rb, 1, 0)
    _ = valx
    _ = valy
    assert_equal(vx[0], Float64(1.0))
    assert_equal(vx[3], Float64(4.0))
    assert_equal(vy[0], Float64(10.0))
    assert_equal(vy[3], Float64(40.0))


def test_load_simd_chunk_out_of_bounds_raises() raises:
    """load_simd_chunk raises when chunk_start + W > col length."""
    var rb = _batch_one_f64([1.0, 2.0, 3.0, 4.0])
    var raised = False
    try:
        var (_v, _vv) = load_simd_chunk[DType.float64, 4](rb, 0, 2)
        _ = _v
        _ = _vv
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

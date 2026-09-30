# =============================================================================
# Unit tests for BatchView[origin] + ColView[dtype, origin] + BoolColView
# =============================================================================
#
# BatchView / ColView / BoolColView: the typed, origin-carrying column views.
#
# Coverage:
#   BatchView:
#     1. n_rows / num_columns over a 3-row batch
#     2. col_i64 / col_i32 / col_f64 / col_f32 / col_bool round-trip
#     3. BatchView.over factory matches direct-ctor path
#
#   ColView:
#     4. load[W=1] / load[W=2] over Int64 / Int32 / Float64 / Float32
#     5. validity_load[W] on a non-nullable column = all-True splat
#     6. validity_load[W] on a nullable column matches per-bit pattern
#     7. has_validity() / length() accessors agree with underlying column
#
#   BoolColView:
#     8. load_bit per-row on a bit-packed BooleanArray column
#     9. load[W] SIMD unpack matches scalar load_bit round-trip
#    10. validity_load[W] on nullable / non-nullable BooleanArray columns
#
# Not covered (these views have no such typed accessors):
#   * String / LargeString / Binary typed accessors
#   * Decimal128 / Decimal256 typed accessors
#   * Temporal types (Date / Timestamp / Duration / Interval)
#   * Dictionary-decoded / List / Struct / Map / Union
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.collections import (
    BatchView,
    ColView,
    BoolColView,
    batch_view_over,
)
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema


# =============================================================================
# Builders
# =============================================================================


def _build_int64_batch_3rows() raises -> RecordBatch:
    """3-row Int64 batch: [10, 20, 30]."""
    var vals = List[Scalar[DType.int64]]()
    vals.append(Scalar[DType.int64](Int64(10)))
    vals.append(Scalar[DType.int64](Int64(20)))
    vals.append(Scalar[DType.int64](Int64(30)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("x", DType.int64, True))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_int32_batch_4rows() raises -> RecordBatch:
    """4-row Int32 batch: [1, 2, 3, 4]."""
    var vals = List[Scalar[DType.int32]]()
    vals.append(Scalar[DType.int32](Int32(1)))
    vals.append(Scalar[DType.int32](Int32(2)))
    vals.append(Scalar[DType.int32](Int32(3)))
    vals.append(Scalar[DType.int32](Int32(4)))
    var arr = PrimitiveArray[DType.int32].from_list(vals^)
    var schema = Schema.from_fields_1(Field("x", DType.int32, True))
    var col = Column.from_primitive[DType.int32](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_float64_batch_4rows() raises -> RecordBatch:
    """4-row Float64 batch: [0.5, 1.5, 2.5, 3.5]."""
    var vals = List[Scalar[DType.float64]]()
    vals.append(Scalar[DType.float64](Float64(0.5)))
    vals.append(Scalar[DType.float64](Float64(1.5)))
    vals.append(Scalar[DType.float64](Float64(2.5)))
    vals.append(Scalar[DType.float64](Float64(3.5)))
    var arr = PrimitiveArray[DType.float64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("x", DType.float64, True))
    var col = Column.from_primitive[DType.float64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_float32_batch_4rows() raises -> RecordBatch:
    """4-row Float32 batch: [0.25, 1.25, 2.25, 3.25]."""
    var vals = List[Scalar[DType.float32]]()
    vals.append(Scalar[DType.float32](Float32(0.25)))
    vals.append(Scalar[DType.float32](Float32(1.25)))
    vals.append(Scalar[DType.float32](Float32(2.25)))
    vals.append(Scalar[DType.float32](Float32(3.25)))
    var arr = PrimitiveArray[DType.float32].from_list(vals^)
    var schema = Schema.from_fields_1(Field("x", DType.float32, True))
    var col = Column.from_primitive[DType.float32](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_int64_nullable_batch() raises -> RecordBatch:
    """3-row nullable Int64 batch: [42, NULL, 7]. Row 1 is null.

    `allocate_nullable(N)` returns an array with the validity bitmap
    pre-set to all-valid (see `primitive_array.mojo`). We set
    rows 0/2 to their values (idempotent on the bitmap) and explicitly
    null row 1.
    """
    var arr = PrimitiveArray[DType.int64].allocate_nullable(3)
    arr.set(0, Scalar[DType.int64](Int64(42)))
    arr.set(2, Scalar[DType.int64](Int64(7)))
    arr._set_null(1)
    arr.null_count = 1
    var schema = Schema.from_fields_1(Field("x", DType.int64, True))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_bool_batch_8rows() raises -> RecordBatch:
    """8-row boolean batch: alternating [T, F, T, F, T, F, T, F]."""
    var bm = BooleanArray.allocate(8)
    bm.set(0, True)
    bm.set(1, False)
    bm.set(2, True)
    bm.set(3, False)
    bm.set(4, True)
    bm.set(5, False)
    bm.set(6, True)
    bm.set(7, False)
    var schema = Schema.from_fields_1(Field("b", DType.bool, True))
    var col = Column.from_boolean(bm^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


# =============================================================================
# 1. BatchView basic accessors
# =============================================================================


def test_n_rows_and_num_columns() raises:
    """BatchView.n_rows() and num_columns() match the wrapped batch."""
    var batch = _build_int64_batch_3rows()
    var bv = BatchView(batch)
    assert_equal(bv.n_rows(), 3)
    assert_equal(bv.num_columns(), 1)


def test_over_factory_matches_ctor() raises:
    """batch_view_over(batch) yields the same n_rows / col read as the
    direct ctor (the free factory mirrors `BatchView.over`).
    """
    var batch = _build_int64_batch_3rows()
    var bv = batch_view_over(batch)
    assert_equal(bv.n_rows(), 3)
    var col = bv.col_i64(0)
    var v = col.load[1](0)
    assert_equal(Int(v[0]), 10)


# =============================================================================
# 2. ColView Int64 / Int32 / Float64 / Float32 round-trip
# =============================================================================


def test_col_i64_load_w1() raises:
    """ColView[Int64] load[W=1] reads scalar elements."""
    var batch = _build_int64_batch_3rows()
    var bv = BatchView(batch)
    var col = bv.col_i64(0)
    assert_equal(col.length(), 3)
    assert_equal(Int(col.load[1](0)[0]), 10)
    assert_equal(Int(col.load[1](1)[0]), 20)
    assert_equal(Int(col.load[1](2)[0]), 30)


def test_col_i64_load_w2_simd() raises:
    """ColView[Int64] load[W=2] reads a 2-lane SIMD chunk."""
    var batch = _build_int64_batch_3rows()
    var bv = BatchView(batch)
    var col = bv.col_i64(0)
    var v = col.load[2](0)
    assert_equal(Int(v[0]), 10)
    assert_equal(Int(v[1]), 20)


def test_col_i32_load_w4() raises:
    """ColView[Int32] load[W=4] reads a 4-lane SIMD chunk."""
    var batch = _build_int32_batch_4rows()
    var bv = BatchView(batch)
    var col = bv.col_i32(0)
    var v = col.load[4](0)
    assert_equal(Int(v[0]), 1)
    assert_equal(Int(v[1]), 2)
    assert_equal(Int(v[2]), 3)
    assert_equal(Int(v[3]), 4)


def test_col_f64_load_w2() raises:
    """ColView[Float64] load[W=2] reads a 2-lane SIMD chunk."""
    var batch = _build_float64_batch_4rows()
    var bv = BatchView(batch)
    var col = bv.col_f64(0)
    var v = col.load[2](0)
    assert_true(Float64(v[0]) > 0.4 and Float64(v[0]) < 0.6)
    assert_true(Float64(v[1]) > 1.4 and Float64(v[1]) < 1.6)


def test_col_f32_load_w4() raises:
    """ColView[Float32] load[W=4] reads a 4-lane SIMD chunk."""
    var batch = _build_float32_batch_4rows()
    var bv = BatchView(batch)
    var col = bv.col_f32(0)
    var v = col.load[4](0)
    assert_true(Float32(v[0]) > Float32(0.2) and Float32(v[0]) < Float32(0.3))
    assert_true(Float32(v[3]) > Float32(3.2) and Float32(v[3]) < Float32(3.3))


# =============================================================================
# 3. validity_load — non-nullable / nullable
# =============================================================================


def test_validity_load_non_nullable_all_true() raises:
    """Non-nullable column: validity_load returns all-True splat."""
    var batch = _build_int64_batch_3rows()
    var bv = BatchView(batch)
    var col = bv.col_i64(0)
    assert_false(col.has_validity())
    var v = col.validity_load[2](0)
    assert_equal(Bool(v[0]), True)
    assert_equal(Bool(v[1]), True)


def test_validity_load_nullable_matches_pattern() raises:
    """Nullable column: validity_load reports row 1 of 3 as null."""
    var batch = _build_int64_nullable_batch()
    var bv = BatchView(batch)
    var col = bv.col_i64(0)
    assert_true(col.has_validity())
    # MOJO 1.0.0: SIMD lane counts must be a power of two, so the original
    # single `validity_load[3](0)` is no longer expressible. The batch has
    # exactly 3 rows, so widening to W=4 would read row 3 out of bounds --
    # split into 2+1 instead, which asserts the identical three rows.
    var v01 = col.validity_load[2](0)
    assert_equal(Bool(v01[0]), True)   # row 0 valid
    assert_equal(Bool(v01[1]), False)  # row 1 null
    var v2 = col.validity_load[1](2)
    assert_equal(Bool(v2[0]), True)    # row 2 valid


# =============================================================================
# 4. BoolColView (bit-packed)
# =============================================================================


def test_bool_col_load_bit() raises:
    """BoolColView.load_bit returns per-row bool from bit-packed
    BooleanArray."""
    var batch = _build_bool_batch_8rows()
    var bv = BatchView(batch)
    var col = bv.col_bool(0)
    assert_equal(col.length(), 8)
    assert_equal(col.load_bit(0), True)
    assert_equal(col.load_bit(1), False)
    assert_equal(col.load_bit(2), True)
    assert_equal(col.load_bit(7), False)


def test_bool_col_load_simd_w4() raises:
    """BoolColView.load[W=4] returns the first 4 bits as SIMD bool."""
    var batch = _build_bool_batch_8rows()
    var bv = BatchView(batch)
    var col = bv.col_bool(0)
    var v = col.load[4](0)
    assert_equal(Bool(v[0]), True)
    assert_equal(Bool(v[1]), False)
    assert_equal(Bool(v[2]), True)
    assert_equal(Bool(v[3]), False)


def test_bool_col_validity_load_non_nullable() raises:
    """Non-nullable BooleanArray: validity_load = all True."""
    var batch = _build_bool_batch_8rows()
    var bv = BatchView(batch)
    var col = bv.col_bool(0)
    assert_false(col.has_validity())
    var v = col.validity_load[8](0)
    for i in range(8):
        assert_equal(Bool(v[i]), True)


# =============================================================================
# 5. Multi-call same column re-borrow (Pointer-rebind shape)
# =============================================================================


def test_repeated_col_access_returns_same_data() raises:
    """Calling col_i64(0) twice returns equivalent views — the
    Pointer-rebind path is deterministic, no per-call state."""
    var batch = _build_int64_batch_3rows()
    var bv = BatchView(batch)
    var c1 = bv.col_i64(0)
    var c2 = bv.col_i64(0)
    assert_equal(c1.length(), c2.length())
    assert_equal(Int(c1.load[1](0)[0]), Int(c2.load[1](0)[0]))
    assert_equal(Int(c1.load[1](2)[0]), Int(c2.load[1](2)[0]))


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

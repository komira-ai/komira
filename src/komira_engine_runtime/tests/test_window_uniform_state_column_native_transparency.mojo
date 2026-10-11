# =============================================================================
# test_window_uniform_state_column_native_transparency.mojo
#
# P-2.B.2b transparency gate for the WindowUniformState column-native breaker
# migration. The migrated `WindowUniformState.drain_to_record_batch` produces a
# ColumnNativeBatch internally and bridges to RecordBatch at the breaker output
# via the P-2.A shim (column_native_from_record_batch ->
# record_batch_from_column_native). Because the ColumnNativeBatch body IS a
# THSPLC chunk, the lift+lower is byte-identical to a spill/restore round-trip,
# so the migrated drain is byte-identical to the prior direct RecordBatch drain.
#
# WindowUniformState drains (every input column in sorted order) ⊕ (the window
# output columns) — a mixed-DType, variable-arity RecordBatch. Input columns
# carry their native DType (Int64/Int32/Float64/Float32); window output columns
# carry the WindowFn's OUT_DT (e.g. RowNumber -> Int64, an avg/sum frame fn ->
# Float64). All fields are declared NULLABLE. The bridge transparency below
# proves the lift+lower the migration inserts is byte-identical for a
# representative mixed-DType drain shape (Int64 input ⊕ Float64 input ⊕ Int64
# window-output col).
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder

from komira_arrow_ipc.record_batch_compare import record_batch_byte_equal

from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)


def _i64_prim(
    var vals: List[Scalar[DType.int64]]
) raises -> PrimitiveArray[DType.int64]:
    return PrimitiveArray[DType.int64].from_list(vals^)


def _f64_prim(
    var vals: List[Scalar[DType.float64]]
) raises -> PrimitiveArray[DType.float64]:
    return PrimitiveArray[DType.float64].from_list(vals^)


def _i32_prim(
    var vals: List[Scalar[DType.int32]]
) raises -> PrimitiveArray[DType.int32]:
    return PrimitiveArray[DType.int32].from_list(vals^)


def _window_uniform_mixed(
    var i64in: List[Scalar[DType.int64]],
    var f64in: List[Scalar[DType.float64]],
    var i64win: List[Scalar[DType.int64]],
) raises -> RecordBatch:
    """A representative WindowUniformState drain shape: Int64 input col ⊕ Float64
    input col ⊕ Int64 window-output col, all NULLABLE — matches the migrated
    drain's column-emit order and per-col DType exactly."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("rn"), ArrowType.INT64, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(Column.from_primitive[DType.int64](_i64_prim(i64in^)))
    rb.add_column(Column.from_primitive[DType.float64](_f64_prim(f64in^)))
    rb.add_column(Column.from_primitive[DType.int64](_i64_prim(i64win^)))
    return rb.build(schema^)


def test_bridge_byte_identical_window_uniform_mixed_dtype() raises:
    """The mixed-DType WindowUniformState drain (Int64 input ⊕ Float64 input ⊕
    Int64 window output) round-trips byte-identical through the breaker-output
    bridge. Two partitions of key k, RowNumber window output restarting per
    partition (the partition-sorted output)."""
    var k: List[Scalar[DType.int64]] = [1, 1, 2, 2, 2]
    var v: List[Scalar[DType.float64]] = [1.5, 2.5, 3.5, 4.5, 5.5]
    var rn: List[Scalar[DType.int64]] = [1, 2, 1, 2, 3]
    var k2: List[Scalar[DType.int64]] = [1, 1, 2, 2, 2]
    var v2: List[Scalar[DType.float64]] = [1.5, 2.5, 3.5, 4.5, 5.5]
    var rn2: List[Scalar[DType.int64]] = [1, 2, 1, 2, 3]
    var golden = _window_uniform_mixed(k^, v^, rn^)
    var to_bridge = _window_uniform_mixed(k2^, v2^, rn2^)
    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_rows() == 5, "row count preserved")
    assert_true(native.num_columns() == 3, "col count preserved")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "WindowUniformState mixed-DType drain bridge must be byte-identical",
    )


def _window_uniform_i32(
    var i32in: List[Scalar[DType.int32]],
    var f32: List[Scalar[DType.float64]],
) raises -> RecordBatch:
    """Int32 input col ⊕ Float64 window output — exercises the Int32 input-col
    emit arm + a Float64 window-output arm in the drain."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k32"), ArrowType.INT32, True))
    sb.add_field(Field(String("favg"), ArrowType.FLOAT64, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_primitive[DType.int32](_i32_prim(i32in^)))
    rb.add_column(Column.from_primitive[DType.float64](_f64_prim(f32^)))
    return rb.build(schema^)


def test_bridge_byte_identical_window_uniform_i32_f64() raises:
    """An Int32 input col ⊕ Float64 window-output col round-trips
    byte-identical — exercises the narrower input DType + a float-output window
    def shape."""
    var k: List[Scalar[DType.int32]] = [10, 20, 30]
    var f: List[Scalar[DType.float64]] = [1.0, 1.5, 2.0]
    var k2: List[Scalar[DType.int32]] = [10, 20, 30]
    var f2: List[Scalar[DType.float64]] = [1.0, 1.5, 2.0]
    var golden = _window_uniform_i32(k^, f^)
    var to_bridge = _window_uniform_i32(k2^, f2^)
    var native = column_native_from_record_batch(to_bridge^)
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "WindowUniformState (Int32 input + Float64 output) drain bridge"
        " byte-identical",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

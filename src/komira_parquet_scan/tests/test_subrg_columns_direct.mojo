# subrg_columns and batch_filter on hand-filled buffers and batches:
#   - the scan builders keep the column's type: an INT32 dictionary and an
#     INT32 PLAIN column stay INT32, FLOAT stays FLOAT32, INT64 / DOUBLE keep
#     theirs; the aggregate builders widen INT32 to INT64 and FLOAT to FLOAT64;
#   - an out-of-range code resolves to entry 0, and rows past `v_total` are
#     filled (entry 0 or 0), on both resolve arms (fused and loop);
#   - the INT32 codes placeholder;
#   - the batch filter: the rows where the predicate is TRUE, in order; a row
#     whose operand is NULL (UNKNOWN) dropped even when every value passes.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet.decode_arm_trace import set_dict_resolve_fused_enabled
from komira_parquet_api.types import ParquetType
from komira_parquet_scan.batch_filter import filter_batch_by_predicate
from komira_parquet_scan.subrg_columns import (
    build_flat_plain_col,
    build_int32_codes_col,
    build_one_scan_col,
    resolve_flat_f64_col,
    resolve_flat_int64_col,
)
from komira_plan_expr.expr import BIN_GT, Expr
from komira_plan_expr.scalar_value import ScalarValue


def _i32_buf(values: List[Int]) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(max(len(values), 1) * 8)
    b.set_length(Int64(max(len(values), 1) * 8))
    for i in range(len(values)):
        b.set_typed[Int32](i, Int32(values[i]))
    return b^


def _f32_buf(values: List[Float32]) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(len(values) * 8)
    b.set_length(Int64(len(values) * 8))
    for i in range(len(values)):
        b.set_typed[Float32](i, values[i])
    return b^


def _i64_buf(values: List[Int]) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(len(values) * 8)
    b.set_length(Int64(len(values) * 8))
    for i in range(len(values)):
        b.set_typed[Int64](i, Int64(values[i]))
    return b^


def test_scan_builders_keep_the_type() raises:
    var codes = _i32_buf([2, 0, 1])
    var di: List[Int64] = [7, -3, 1 << 20]
    var df: List[Float64] = [0.5, -1.25, 3.0]
    var c32 = build_one_scan_col(codes, 3, 3, True, False, ParquetType.INT32, di, df)
    assert_true(c32.arrow_type == ArrowType.INT32)
    assert_equal(Int(c32.as_primitive[DType.int32]().get(0)), 1 << 20)
    var c64 = build_one_scan_col(codes, 3, 3, True, False, ParquetType.INT64, di, df)
    assert_true(c64.arrow_type == ArrowType.INT64)
    assert_equal(Int(c64.as_primitive[DType.int64]().get(1)), 7)
    var cf = build_one_scan_col(codes, 3, 3, True, True, ParquetType.FLOAT, di, df)
    assert_true(cf.arrow_type == ArrowType.FLOAT32)
    assert_equal(Float64(cf.as_primitive[DType.float32]().get(2)), -1.25)
    var cd = build_one_scan_col(codes, 3, 3, True, True, ParquetType.DOUBLE, di, df)
    assert_true(cd.arrow_type == ArrowType.FLOAT64)
    var p32 = build_one_scan_col(_i32_buf([5, -6]), 2, 2, False, False, ParquetType.INT32, di, df)
    assert_true(p32.arrow_type == ArrowType.INT32)
    assert_equal(Int(p32.as_primitive[DType.int32]().get(1)), -6)
    var pf = build_one_scan_col(_f32_buf([1.5, 2.5]), 2, 2, False, True, ParquetType.FLOAT, di, df)
    assert_true(pf.arrow_type == ArrowType.FLOAT32)
    var p64 = build_one_scan_col(_i64_buf([1 << 40]), 1, 1, False, False, ParquetType.INT64, di, df)
    assert_equal(Int(p64.as_primitive[DType.int64]().get(0)), 1 << 40)


def test_aggregate_builders_widen() raises:
    var a32 = build_flat_plain_col(_i32_buf([5, -6]), 2, 2, ParquetType.INT32)
    assert_true(a32.arrow_type == ArrowType.INT64)
    assert_equal(Int(a32.as_primitive[DType.int64]().get(1)), -6)
    var af = build_flat_plain_col(_f32_buf([1.5, 2.5]), 2, 2, ParquetType.FLOAT)
    assert_true(af.arrow_type == ArrowType.FLOAT64)
    assert_equal(Float64(af.as_primitive[DType.float64]().get(1)), 2.5)


def test_out_of_range_codes_and_the_tail_on_both_arms() raises:
    var di: List[Int64] = [11, 22]
    var df: List[Float64] = [1.0, 2.0]
    for fused in [True, False]:
        set_dict_resolve_fused_enabled(fused)
        # Codes 1, 5 (out of range), -1 (out of range); only 2 of 4 rows filled.
        var codes = _i32_buf([1, 5, -1, 0])
        var c = resolve_flat_int64_col(codes, 4, 3, di)
        assert_equal(Int(c.as_primitive[DType.int64]().get(0)), 22)
        assert_equal(Int(c.as_primitive[DType.int64]().get(1)), 11)
        assert_equal(Int(c.as_primitive[DType.int64]().get(2)), 11)
        assert_equal(Int(c.as_primitive[DType.int64]().get(3)), 11)
        var f = resolve_flat_f64_col(codes, 4, 1, df)
        assert_equal(Float64(f.as_primitive[DType.float64]().get(0)), 2.0)
        assert_equal(Float64(f.as_primitive[DType.float64]().get(3)), 1.0)
    set_dict_resolve_fused_enabled(True)
    var p = build_flat_plain_col(_i64_buf([9, 9]), 3, 2, ParquetType.INT64)
    assert_equal(Int(p.as_primitive[DType.int64]().get(2)), 0)
    var placeholder = build_int32_codes_col(_i32_buf([4, 3]), 2)
    assert_true(placeholder.arrow_type == ArrowType.INT32)
    assert_equal(Int(placeholder.as_primitive[DType.int32]().get(0)), 4)


def _batch_with_nulls() raises -> RecordBatch:
    """x = 0..5, NULL at rows 1 and 4."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(6)
    for i in range(6):
        arr.set_typed[Scalar[DType.int64]](i, Int64(i))
    arr._set_null(1)
    arr._set_null(4)
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    return RecordBatch.from_typed_columns_1(sb.build(), Column.from_primitive[DType.int64](arr^))


def test_the_batch_filter() raises:
    var gt = Expr.binary(BIN_GT, Expr.col_ref("x"), Expr.literal(ScalarValue.from_int(0)))
    var out = filter_batch_by_predicate(_batch_with_nulls(), gt)
    var want: List[Int] = [2, 3, 5]
    assert_equal(out.num_rows(), 3)
    for i in range(3):
        assert_equal(Int(out.column_at(0).as_primitive[DType.int64]().get(i)), want[i])
    var all_pass = Expr.binary(BIN_GT, Expr.col_ref("x"), Expr.literal(ScalarValue.from_int(-1)))
    var kept = filter_batch_by_predicate(_batch_with_nulls(), all_pass)
    assert_equal(kept.num_rows(), 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

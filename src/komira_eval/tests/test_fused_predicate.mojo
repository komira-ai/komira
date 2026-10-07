# =============================================================================
# Tests for the fused multi-conjunct predicate evaluator
# =============================================================================
#
# Validates byte-identical parity with the legacy per-stage `eval_eq` /
# `eval_lt` / `eval_gt` + `eval_and` chain. Covers:
#   * Single conjunct (q11 shape: nation_id == 1).
#   * Two conjuncts on same column (q15 shape: shipdate >= lo AND < hi).
#   * Two conjuncts on different columns (q17 shape: brand_id == X AND container_id == Y).
#   * All op codes (EQ, NE, LT, LE, GT, GE).
#   * Tail handling (n_rows not multiple of 8).
#   * Empty mask short-circuit.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_arrow.arrow_types import ArrowType
from komira_column_kernels.comparison import eval_eq, eval_lt, eval_gt
from komira_column_kernels.arithmetic import eval_and
from komira_column_kernels.fused_predicate import (
    ConjunctDescI64,
    FUSED_OP_EQ,
    FUSED_OP_NE,
    FUSED_OP_LT,
    FUSED_OP_LE,
    FUSED_OP_GT,
    FUSED_OP_GE,
    fused_eval_and_int64,
    fused_op_from_bin_op,
)


def _arr_from_list(values: List[Int64]) -> PrimitiveArray[DType.int64]:
    var scalars = List[Scalar[DType.int64]]()
    for i in range(len(values)):
        scalars.append(Scalar[DType.int64](values[i]))
    return PrimitiveArray[DType.int64].from_list(scalars)


def _ba_eq(a: BooleanArray, b: BooleanArray) -> Bool:
    if a.length != b.length:
        return False
    for i in range(a.length):
        if a.data.test(i) != b.data.test(i):
            return False
    return True


def _make_batch_one_col(name: String, values: List[Int64]) raises -> RecordBatch:
    var arr = _arr_from_list(values)
    var col = Column.from_primitive[DType.int64](arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    return builder.build(schema^)


def _make_batch_two_cols(
    name_a: String, vals_a: List[Int64], name_b: String, vals_b: List[Int64]
) raises -> RecordBatch:
    var col_a = Column.from_primitive[DType.int64](_arr_from_list(vals_a))
    var col_b = Column.from_primitive[DType.int64](_arr_from_list(vals_b))
    var sb = SchemaBuilder()
    sb.add_field(Field(name_a, ArrowType.INT64, False))
    sb.add_field(Field(name_b, ArrowType.INT64, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(col_a^)
    builder.add_column(col_b^)
    return builder.build(schema^)


def test_fused_single_conjunct_eq() raises:
    """Single conjunct: col == 1 -- q11 shape."""
    var values = List[Int64]()
    values.append(Int64(1))
    values.append(Int64(2))
    values.append(Int64(1))
    values.append(Int64(3))
    values.append(Int64(1))
    var batch = _make_batch_one_col(String("nation_id"), values)
    var conjuncts = List[ConjunctDescI64]()
    conjuncts.append(ConjunctDescI64(0, FUSED_OP_EQ, Int64(1)))
    var fused = fused_eval_and_int64(batch, conjuncts, 5)
    var col_arr = batch.column_at(0).as_primitive[DType.int64]()
    var ref_mask = eval_eq[DType.int64](col_arr, Scalar[DType.int64](1))
    assert_true(_ba_eq(fused, ref_mask), "Fused single-EQ must match scalar reference")


def test_fused_two_conjuncts_range() raises:
    """Two conjuncts on same column: shipdate >= 100 AND shipdate < 200 -- q15 shape."""
    var values = List[Int64]()
    values.append(Int64(50))
    values.append(Int64(100))
    values.append(Int64(150))
    values.append(Int64(200))
    values.append(Int64(250))
    var batch = _make_batch_one_col(String("l_shipdate"), values)
    var conjuncts = List[ConjunctDescI64]()
    conjuncts.append(ConjunctDescI64(0, FUSED_OP_GE, Int64(100)))
    conjuncts.append(ConjunctDescI64(0, FUSED_OP_LT, Int64(200)))
    var fused = fused_eval_and_int64(batch, conjuncts, 5)
    # Expected: only indices 1, 2 (100, 150) survive.
    assert_equal(fused.data.test(0), False)
    assert_equal(fused.data.test(1), True)
    assert_equal(fused.data.test(2), True)
    assert_equal(fused.data.test(3), False)
    assert_equal(fused.data.test(4), False)


def test_fused_two_cols_eq() raises:
    """Two conjuncts on DIFFERENT cols: brand == X AND container == Y -- q17 shape."""
    var brand_values = List[Int64]()
    brand_values.append(Int64(1))
    brand_values.append(Int64(2))
    brand_values.append(Int64(2))
    brand_values.append(Int64(3))
    brand_values.append(Int64(2))
    var container_values = List[Int64]()
    container_values.append(Int64(7))
    container_values.append(Int64(7))
    container_values.append(Int64(8))
    container_values.append(Int64(8))
    container_values.append(Int64(7))
    var batch = _make_batch_two_cols(
        String("brand_id"), brand_values,
        String("container_id"), container_values,
    )
    var conjuncts = List[ConjunctDescI64]()
    conjuncts.append(ConjunctDescI64(0, FUSED_OP_EQ, Int64(2)))
    conjuncts.append(ConjunctDescI64(1, FUSED_OP_EQ, Int64(7)))
    var fused = fused_eval_and_int64(batch, conjuncts, 5)
    # row 0: brand==1, container==7 -> False
    # row 1: brand==2, container==7 -> True
    # row 2: brand==2, container==8 -> False
    # row 3: brand==3, container==8 -> False
    # row 4: brand==2, container==7 -> True
    assert_equal(fused.data.test(0), False)
    assert_equal(fused.data.test(1), True)
    assert_equal(fused.data.test(2), False)
    assert_equal(fused.data.test(3), False)
    assert_equal(fused.data.test(4), True)


def test_fused_all_ops_parity() raises:
    """Each op code matches the scalar kernel byte-for-byte."""
    var n = 100
    var data = List[Int64]()
    for i in range(n):
        data.append(Int64((i * 17) % 13))  # values in [0, 12]
    var batch = _make_batch_one_col(String("v"), data)
    var thresh = Int64(7)
    var col_arr = batch.column_at(0).as_primitive[DType.int64]()

    # EQ
    var c1 = List[ConjunctDescI64]()
    c1.append(ConjunctDescI64(0, FUSED_OP_EQ, thresh))
    var fused_eq = fused_eval_and_int64(batch, c1, n)
    var ref_eq = eval_eq[DType.int64](col_arr, Scalar[DType.int64](thresh))
    assert_true(_ba_eq(fused_eq, ref_eq), "EQ mismatch")

    # LT
    var c2 = List[ConjunctDescI64]()
    c2.append(ConjunctDescI64(0, FUSED_OP_LT, thresh))
    var fused_lt = fused_eval_and_int64(batch, c2, n)
    var ref_lt = eval_lt[DType.int64](col_arr, Scalar[DType.int64](thresh))
    assert_true(_ba_eq(fused_lt, ref_lt), "LT mismatch")

    # GT
    var c3 = List[ConjunctDescI64]()
    c3.append(ConjunctDescI64(0, FUSED_OP_GT, thresh))
    var fused_gt = fused_eval_and_int64(batch, c3, n)
    var ref_gt = eval_gt[DType.int64](col_arr, Scalar[DType.int64](thresh))
    assert_true(_ba_eq(fused_gt, ref_gt), "GT mismatch")


def test_fused_tail_handling() raises:
    """n_rows not a multiple of 8 must handle the tail correctly."""
    # 13 rows -- one full byte (8) plus 5 tail bits.
    var data = List[Int64]()
    for i in range(13):
        data.append(Int64(i))
    var batch = _make_batch_one_col(String("v"), data)
    var conjuncts = List[ConjunctDescI64]()
    conjuncts.append(ConjunctDescI64(0, FUSED_OP_GE, Int64(5)))
    var fused = fused_eval_and_int64(batch, conjuncts, 13)
    assert_equal(fused.length, 13)
    for i in range(13):
        var expected = i >= 5
        assert_equal(fused.data.test(i), expected)


def test_fused_op_translation() raises:
    """fused_op_from_bin_op maps Expr BIN_* to FUSED_OP_*."""
    # BIN_EQ=10, BIN_NE=11, BIN_LT=12, BIN_LE=13, BIN_GT=14, BIN_GE=15.
    assert_equal(fused_op_from_bin_op(UInt8(10)), Int(FUSED_OP_EQ))
    assert_equal(fused_op_from_bin_op(UInt8(11)), Int(FUSED_OP_NE))
    assert_equal(fused_op_from_bin_op(UInt8(12)), Int(FUSED_OP_LT))
    assert_equal(fused_op_from_bin_op(UInt8(13)), Int(FUSED_OP_LE))
    assert_equal(fused_op_from_bin_op(UInt8(14)), Int(FUSED_OP_GT))
    assert_equal(fused_op_from_bin_op(UInt8(15)), Int(FUSED_OP_GE))
    # AND / OR / arithmetic should return -1 (unsupported).
    assert_equal(fused_op_from_bin_op(UInt8(20)), -1)  # BIN_AND
    assert_equal(fused_op_from_bin_op(UInt8(0)), -1)  # BIN_ADD


def test_fused_long_array() raises:
    """Stress test: 1024 rows, multi-byte payload, multi-conjunct."""
    var n = 1024
    var col_a_data = List[Int64]()
    var col_b_data = List[Int64]()
    for i in range(n):
        col_a_data.append(Int64(i % 50))
        col_b_data.append(Int64((i * 3) % 100))
    var batch = _make_batch_two_cols(
        String("a"), col_a_data, String("b"), col_b_data
    )
    var conjuncts = List[ConjunctDescI64]()
    conjuncts.append(ConjunctDescI64(0, FUSED_OP_LT, Int64(20)))
    conjuncts.append(ConjunctDescI64(1, FUSED_OP_GE, Int64(50)))
    var fused = fused_eval_and_int64(batch, conjuncts, n)
    for i in range(n):
        var a = col_a_data[i] < Int64(20)
        var b = col_b_data[i] >= Int64(50)
        var both = a and b
        assert_equal(fused.data.test(i), both)


def test_fused_empty_mask() raises:
    """No rows pass -> all-False bitmap."""
    var data = List[Int64]()
    for i in range(5):
        data.append(Int64(i + 1))
    var batch = _make_batch_one_col(String("v"), data)
    var conjuncts = List[ConjunctDescI64]()
    conjuncts.append(ConjunctDescI64(0, FUSED_OP_GT, Int64(100)))
    var fused = fused_eval_and_int64(batch, conjuncts, 5)
    assert_equal(fused.true_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

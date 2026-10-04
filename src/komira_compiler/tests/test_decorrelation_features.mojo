"""Unit tests for decorrelation + SUM type promotion + col-vs-col comparison."""

from std.testing import assert_true, assert_equal
from komira_core.plan.logical_plan import _infer_agg_field
from komira_core.plan.agg_expr import sum, min, max, count
from komira_core.plan.col_expr import col
from komira_core.plan.expr import Expr
from komira_compiler.compiler_eval_predicate import _eval_predicate
from komira_core.eval.comparison import eval_col_gt, eval_col_lt, eval_col_eq
from komira_core.arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.arrow_types import ArrowType


# =============================================================================
# SUM type promotion tests
# =============================================================================

def test_sum_int32_promotes_to_int64() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("qty", ArrowType.INT32, False))
    var schema = sb.build()
    var agg = sum(col("qty")).alias("total")
    var field = _infer_agg_field(agg, schema)
    assert_true(field.arrow_type == ArrowType.INT64, "SUM(INT32) should be INT64")
    print("PASS: SUM(INT32) -> INT64")

def test_sum_float32_promotes_to_float64() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("price", ArrowType.FLOAT32, False))
    var schema = sb.build()
    var agg = sum(col("price")).alias("total")
    var field = _infer_agg_field(agg, schema)
    assert_true(field.arrow_type == ArrowType.FLOAT64, "SUM(FLOAT32) should be FLOAT64")
    print("PASS: SUM(FLOAT32) -> FLOAT64")

def test_sum_int64_stays() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    var schema = sb.build()
    var agg = sum(col("id")).alias("total")
    var field = _infer_agg_field(agg, schema)
    assert_true(field.arrow_type == ArrowType.INT64, "SUM(INT64) should stay INT64")
    print("PASS: SUM(INT64) -> INT64")

def test_min_no_promotion() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("qty", ArrowType.INT32, False))
    var schema = sb.build()
    var agg = min(col("qty")).alias("min_qty")
    var field = _infer_agg_field(agg, schema)
    assert_true(field.arrow_type == ArrowType.INT32, "MIN(INT32) should stay INT32")
    print("PASS: MIN(INT32) -> INT32")


# =============================================================================
# Column-vs-column kernel tests
# =============================================================================

def test_col_gt_float64() raises:
    var left = PrimitiveArray[DType.float64].allocate(4)
    var right = PrimitiveArray[DType.float64].allocate(4)
    var lp = left._typed_ptr_mut()
    var rp = right._typed_ptr_mut()
    (lp + 0)[] = Scalar[DType.float64](10.0)
    (lp + 1)[] = Scalar[DType.float64](5.0)
    (lp + 2)[] = Scalar[DType.float64](8.0)
    (lp + 3)[] = Scalar[DType.float64](3.0)
    (rp + 0)[] = Scalar[DType.float64](7.0)
    (rp + 1)[] = Scalar[DType.float64](5.0)
    (rp + 2)[] = Scalar[DType.float64](9.0)
    (rp + 3)[] = Scalar[DType.float64](1.0)

    var result = eval_col_gt[DType.float64](left, right)
    assert_true(result.true_count() == 2, "col_gt: expected 2 true")
    print("PASS: eval_col_gt float64")

def test_col_lt_int64() raises:
    var left = PrimitiveArray[DType.int64].allocate(3)
    var right = PrimitiveArray[DType.int64].allocate(3)
    var lp = left._typed_ptr_mut()
    var rp = right._typed_ptr_mut()
    (lp + 0)[] = Scalar[DType.int64](1)
    (lp + 1)[] = Scalar[DType.int64](5)
    (lp + 2)[] = Scalar[DType.int64](3)
    (rp + 0)[] = Scalar[DType.int64](2)
    (rp + 1)[] = Scalar[DType.int64](3)
    (rp + 2)[] = Scalar[DType.int64](3)

    var result = eval_col_lt[DType.int64](left, right)
    assert_true(result.true_count() == 1, "col_lt: expected 1 true")
    print("PASS: eval_col_lt int64")


# =============================================================================
# _eval_predicate col-vs-col integration test
# =============================================================================

def test_predicate_col_vs_col() raises:
    var n = 4
    var a_arr = PrimitiveArray[DType.float64].allocate(n)
    var b_arr = PrimitiveArray[DType.float64].allocate(n)
    var ap = a_arr._typed_ptr_mut()
    var bp = b_arr._typed_ptr_mut()
    (ap + 0)[] = Scalar[DType.float64](10.0)
    (ap + 1)[] = Scalar[DType.float64](5.0)
    (ap + 2)[] = Scalar[DType.float64](8.0)
    (ap + 3)[] = Scalar[DType.float64](3.0)
    (bp + 0)[] = Scalar[DType.float64](7.0)
    (bp + 1)[] = Scalar[DType.float64](5.0)
    (bp + 2)[] = Scalar[DType.float64](9.0)
    (bp + 3)[] = Scalar[DType.float64](1.0)

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.FLOAT64, False))
    sb.add_field(Field("b", ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](a_arr^))
    rbb.add_column(Column.from_primitive[DType.float64](b_arr^))
    var batch = rbb.build(sb.build())

    # Test col("a") > col("b")
    var pred_gt = col("a") > col("b")
    var mask_gt = _eval_predicate(pred_gt, batch)
    assert_true(mask_gt.true_count() == 2, "a>b: expected 2 true")
    print("PASS: _eval_predicate col(a) > col(b)")

    # Test col("a") < col("b")
    var pred_lt = col("a") < col("b")
    var mask_lt = _eval_predicate(pred_lt, batch)
    assert_true(mask_lt.true_count() == 1, "a<b: expected 1 true (8<9)")
    print("PASS: _eval_predicate col(a) < col(b)")

    # Test col("a") == col("b")
    var pred_eq = col("a") == col("b")
    var mask_eq = _eval_predicate(pred_eq, batch)
    assert_true(mask_eq.true_count() == 1, "a==b: expected 1 true (5==5)")
    print("PASS: _eval_predicate col(a) == col(b)")


# =============================================================================
# Edge case tests (PE/TE review additions)
# =============================================================================

def test_col_eq_all_equal() raises:
    """All elements equal -- result should be all-true."""
    var left = PrimitiveArray[DType.int64].allocate(5)
    var right = PrimitiveArray[DType.int64].allocate(5)
    var lp = left._typed_ptr_mut()
    var rp = right._typed_ptr_mut()
    for i in range(5):
        (lp + i)[] = Scalar[DType.int64](42)
        (rp + i)[] = Scalar[DType.int64](42)
    var result = eval_col_eq[DType.int64](left, right)
    assert_true(result.true_count() == 5, "all-equal: expected 5 true")
    print("PASS: eval_col_eq all-equal")


def test_col_gt_single_element() raises:
    """Single-element arrays (remainder path only, no full bytes)."""
    var left = PrimitiveArray[DType.float64].allocate(1)
    var right = PrimitiveArray[DType.float64].allocate(1)
    left._typed_ptr_mut()[] = Scalar[DType.float64](10.0)
    right._typed_ptr_mut()[] = Scalar[DType.float64](5.0)
    var result = eval_col_gt[DType.float64](left, right)
    assert_true(result.true_count() == 1, "single-element gt: expected 1 true")
    print("PASS: eval_col_gt single element")


def test_col_lt_single_element_false() raises:
    """Single element where comparison is false."""
    var left = PrimitiveArray[DType.int32].allocate(1)
    var right = PrimitiveArray[DType.int32].allocate(1)
    left._typed_ptr_mut()[] = Scalar[DType.int32](3)
    right._typed_ptr_mut()[] = Scalar[DType.int32](1)
    var result = eval_col_lt[DType.int32](left, right)
    assert_true(result.true_count() == 0, "single-element lt: expected 0 true")
    print("PASS: eval_col_lt single element false")


def test_col_gt_remainder_path() raises:
    """Non-multiple-of-8 length exercises the remainder loop (11 elements)."""
    var n = 11
    var left = PrimitiveArray[DType.float64].allocate(n)
    var right = PrimitiveArray[DType.float64].allocate(n)
    var lp = left._typed_ptr_mut()
    var rp = right._typed_ptr_mut()
    # left[i] = i, right[i] = 5 for all i
    # Elements where i > 5: indices 6,7,8,9,10 = 5 true
    for i in range(n):
        (lp + i)[] = Scalar[DType.float64](Float64(i))
        (rp + i)[] = Scalar[DType.float64](5.0)
    var result = eval_col_gt[DType.float64](left, right)
    assert_true(result.true_count() == 5, "remainder-path gt: expected 5 true")
    print("PASS: eval_col_gt remainder path (11 elements)")


def test_col_eq_none_equal() raises:
    """No elements equal -- result should be all-false."""
    var left = PrimitiveArray[DType.int64].allocate(4)
    var right = PrimitiveArray[DType.int64].allocate(4)
    var lp = left._typed_ptr_mut()
    var rp = right._typed_ptr_mut()
    for i in range(4):
        (lp + i)[] = Scalar[DType.int64](i)
        (rp + i)[] = Scalar[DType.int64](i + 10)
    var result = eval_col_eq[DType.int64](left, right)
    assert_true(result.true_count() == 0, "none-equal: expected 0 true")
    print("PASS: eval_col_eq none equal")


def test_predicate_col_ne_and_ge_le() raises:
    """NE, GE, LE dispatch through NOT inversion in _eval_col_vs_col."""
    var n = 4
    var a_arr = PrimitiveArray[DType.float64].allocate(n)
    var b_arr = PrimitiveArray[DType.float64].allocate(n)
    var ap = a_arr._typed_ptr_mut()
    var bp = b_arr._typed_ptr_mut()
    # a = [10, 5, 8, 3], b = [7, 5, 9, 1]
    (ap + 0)[] = Scalar[DType.float64](10.0)
    (ap + 1)[] = Scalar[DType.float64](5.0)
    (ap + 2)[] = Scalar[DType.float64](8.0)
    (ap + 3)[] = Scalar[DType.float64](3.0)
    (bp + 0)[] = Scalar[DType.float64](7.0)
    (bp + 1)[] = Scalar[DType.float64](5.0)
    (bp + 2)[] = Scalar[DType.float64](9.0)
    (bp + 3)[] = Scalar[DType.float64](1.0)

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.FLOAT64, False))
    sb.add_field(Field("b", ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](a_arr^))
    rbb.add_column(Column.from_primitive[DType.float64](b_arr^))
    var batch = rbb.build(sb.build())

    # NE: a != b => [10!=7, 5!=5, 8!=9, 3!=1] = [T,F,T,T] = 3
    var pred_ne = col("a") != col("b")
    var mask_ne = _eval_predicate(pred_ne, batch)
    assert_true(mask_ne.true_count() == 3, "a!=b: expected 3 true")
    print("PASS: _eval_predicate col(a) != col(b)")

    # GE: a >= b => [T, T, F, T] = 3
    var pred_ge = col("a") >= col("b")
    var mask_ge = _eval_predicate(pred_ge, batch)
    assert_true(mask_ge.true_count() == 3, "a>=b: expected 3 true")
    print("PASS: _eval_predicate col(a) >= col(b)")

    # LE: a <= b => [F, T, T, F] = 2
    var pred_le = col("a") <= col("b")
    var mask_le = _eval_predicate(pred_le, batch)
    assert_true(mask_le.true_count() == 2, "a<=b: expected 2 true")
    print("PASS: _eval_predicate col(a) <= col(b)")


def test_col_gt_int32_cross_type_values() raises:
    """INT32 col-vs-col with negative values and zero."""
    var left = PrimitiveArray[DType.int32].allocate(4)
    var right = PrimitiveArray[DType.int32].allocate(4)
    var lp = left._typed_ptr_mut()
    var rp = right._typed_ptr_mut()
    (lp + 0)[] = Scalar[DType.int32](-5)
    (lp + 1)[] = Scalar[DType.int32](0)
    (lp + 2)[] = Scalar[DType.int32](100)
    (lp + 3)[] = Scalar[DType.int32](-1)
    (rp + 0)[] = Scalar[DType.int32](-10)
    (rp + 1)[] = Scalar[DType.int32](0)
    (rp + 2)[] = Scalar[DType.int32](50)
    (rp + 3)[] = Scalar[DType.int32](1)
    # gt: [-5>-10=T, 0>0=F, 100>50=T, -1>1=F] = 2
    var result = eval_col_gt[DType.int32](left, right)
    assert_true(result.true_count() == 2, "int32 negatives gt: expected 2 true")
    print("PASS: eval_col_gt int32 with negatives")


def main() raises:
    print("=== SUM Type Promotion ===")
    test_sum_int32_promotes_to_int64()
    test_sum_float32_promotes_to_float64()
    test_sum_int64_stays()
    test_min_no_promotion()
    print()
    print("=== Column-vs-Column Kernels ===")
    test_col_gt_float64()
    test_col_lt_int64()
    print()
    print("=== Predicate Col-vs-Col Integration ===")
    test_predicate_col_vs_col()
    print()
    print("=== Edge Cases (PE/TE review) ===")
    test_col_eq_all_equal()
    test_col_gt_single_element()
    test_col_lt_single_element_false()
    test_col_gt_remainder_path()
    test_col_eq_none_equal()
    test_predicate_col_ne_and_ge_le()
    test_col_gt_int32_cross_type_values()
    print()
    print("All 19 tests PASS")

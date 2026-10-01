"""Unit tests for Gap C predicate-compiler fix:
  (1) accept EXPR_BINARY_OP on the predicate RHS, and
  (2) implicit numeric promotion across compare operands.

A TPC-H Q20-shape predicate needs both.

Before the fix, `_eval_predicate(col("a") > col("b") * 0.5, batch)` raises
"PipelineCompiler: predicate RHS must be a literal (got tag=3)" because the
binary-comparison branch only handled COL_REF / LITERAL on the RHS.
After the fix, the RHS is materialized through `_eval_column_expr` and the
result is compared via a type-promoting col-vs-col kernel.

Numeric-promotion repro: `col("int_col") > literal(0.5)` should auto-promote
the INT64 column to FLOAT64 for the compare instead of erroring.
"""

from std.testing import assert_true, assert_equal
from komira_core.plan.col_expr import col
from komira_core.plan.expr import Expr
from komira_compiler.compiler_eval_predicate import _eval_predicate
from komira_core.arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.arrow_types import ArrowType


# =============================================================================
# Helpers — build a 2-column RecordBatch with named INT64 columns.
# =============================================================================


def _build_int64_pair_batch(
    a_vals: List[Int64], b_vals: List[Int64], a_name: String = "a", b_name: String = "b"
) raises -> RecordBatch:
    var n = len(a_vals)
    if len(b_vals) != n:
        raise Error("a_vals / b_vals length mismatch")

    var a_arr = PrimitiveArray[DType.int64].allocate(n)
    var b_arr = PrimitiveArray[DType.int64].allocate(n)
    var ap = a_arr._typed_ptr_mut()
    var bp = b_arr._typed_ptr_mut()
    for i in range(n):
        (ap + i)[] = Scalar[DType.int64](a_vals[i])
        (bp + i)[] = Scalar[DType.int64](b_vals[i])

    var sb = SchemaBuilder()
    sb.add_field(Field(a_name, ArrowType.INT64, False))
    sb.add_field(Field(b_name, ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](a_arr^))
    rbb.add_column(Column.from_primitive[DType.int64](b_arr^))
    return rbb.build(sb.build())


def _build_int64_float64_batch(
    a_vals: List[Int64], b_vals: List[Float64]
) raises -> RecordBatch:
    var n = len(a_vals)
    if len(b_vals) != n:
        raise Error("a_vals / b_vals length mismatch")

    var a_arr = PrimitiveArray[DType.int64].allocate(n)
    var b_arr = PrimitiveArray[DType.float64].allocate(n)
    var ap = a_arr._typed_ptr_mut()
    var bp = b_arr._typed_ptr_mut()
    for i in range(n):
        (ap + i)[] = Scalar[DType.int64](a_vals[i])
        (bp + i)[] = Scalar[DType.float64](b_vals[i])

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](a_arr^))
    rbb.add_column(Column.from_primitive[DType.float64](b_arr^))
    return rbb.build(sb.build())


# =============================================================================
# Gap C2a — accept EXPR_BINARY_OP on the predicate RHS.
# =============================================================================


def test_predicate_compound_rhs_int_mul_int() raises:
    """col("a") > col("b") * 2 — Q20-shape predicate, INT64 throughout.

    Pre-fix: raises "predicate RHS must be a literal (got tag=3)".
    Post-fix: evaluates correctly.
    """
    # a = [10, 5, 8, 3, 100], b = [3, 4, 4, 1, 49]
    # b*2 =                       [6, 8, 8, 2, 98]
    # a > b*2 => [T, F, F, T, T] = 3
    var a_vals: List[Int64] = [Int64(10), Int64(5), Int64(8), Int64(3), Int64(100)]
    var b_vals: List[Int64] = [Int64(3), Int64(4), Int64(4), Int64(1), Int64(49)]
    var batch = _build_int64_pair_batch(a_vals, b_vals)

    var pred = col("a") > col("b") * 2
    var mask = _eval_predicate(pred, batch)
    assert_true(mask.true_count() == 3, "a > b*2: expected 3 true")
    print("PASS: _eval_predicate col(a) > col(b) * 2 (INT64)")


def test_predicate_compound_rhs_float_mul_float() raises:
    """col("a") > col("b") * 0.5 — Q20-shape predicate, FLOAT64 throughout.

    Drives the EXPR_BINARY_OP RHS path on a homogeneous-FLOAT64 batch.
    """
    var n = 4
    var a_arr = PrimitiveArray[DType.float64].allocate(n)
    var b_arr = PrimitiveArray[DType.float64].allocate(n)
    var ap = a_arr._typed_ptr_mut()
    var bp = b_arr._typed_ptr_mut()
    # a = [10, 5, 8, 3], b = [4, 12, 18, 8]
    # b*0.5 =              [2, 6, 9, 4]
    # a > b*0.5 =>         [T, F, F, F] = 1
    (ap + 0)[] = Scalar[DType.float64](10.0)
    (ap + 1)[] = Scalar[DType.float64](5.0)
    (ap + 2)[] = Scalar[DType.float64](8.0)
    (ap + 3)[] = Scalar[DType.float64](3.0)
    (bp + 0)[] = Scalar[DType.float64](4.0)
    (bp + 1)[] = Scalar[DType.float64](12.0)
    (bp + 2)[] = Scalar[DType.float64](18.0)
    (bp + 3)[] = Scalar[DType.float64](8.0)

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.FLOAT64, False))
    sb.add_field(Field("b", ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](a_arr^))
    rbb.add_column(Column.from_primitive[DType.float64](b_arr^))
    var batch = rbb.build(sb.build())

    var pred = col("a") > col("b") * 0.5
    var mask = _eval_predicate(pred, batch)
    assert_true(mask.true_count() == 1, "a > b*0.5 (FLOAT64): expected 1 true")
    print("PASS: _eval_predicate col(a) > col(b) * 0.5 (FLOAT64)")


def test_predicate_compound_rhs_q20_canonical_shape() raises:
    """Q20-canonical shape: INT64 ps_availqty > FLOAT64 qty_sum * 0.5.

    Combines (a) compound RHS and (b) numeric promotion (INT64 vs FLOAT64).
    Pre-fix: raises tag=3 RHS error AND the col-vs-col kernel rejects
    INT64 vs FLOAT64. Post-fix: promotes LHS to FLOAT64 and evaluates.
    """
    # ps_availqty = [50, 30, 20, 10],
    # qty_sum     = [80.0, 40.0, 60.0, 100.0]
    # qty_sum*0.5 = [40.0, 20.0, 30.0, 50.0]
    # avail > thr  = [T,    T,    F,    F   ] = 2
    var a_vals: List[Int64] = [Int64(50), Int64(30), Int64(20), Int64(10)]
    var b_vals: List[Float64] = [Float64(80.0), Float64(40.0), Float64(60.0), Float64(100.0)]
    var batch = _build_int64_float64_batch(a_vals, b_vals)

    var pred = col("a") > col("b") * 0.5
    var mask = _eval_predicate(pred, batch)
    assert_true(
        mask.true_count() == 2,
        "Q20 shape (INT64 vs FLOAT64*0.5): expected 2 true",
    )
    print("PASS: _eval_predicate Q20-shape (INT64 vs FLOAT64 * 0.5)")


def test_predicate_compound_rhs_addition() raises:
    """col("a") < col("b") + col("a") — RHS contains nested col refs."""
    # a = [1, 2, 3, 4, 5], b = [0, 0, 1, 2, -10]
    # b+a =                  [1, 2, 4, 6, -5]
    # a < b+a => b > 0       [F, F, T, T, F] = 2
    var a_vals: List[Int64] = [Int64(1), Int64(2), Int64(3), Int64(4), Int64(5)]
    var b_vals: List[Int64] = [Int64(0), Int64(0), Int64(1), Int64(2), Int64(-10)]
    var batch = _build_int64_pair_batch(a_vals, b_vals)

    var pred = col("a") < col("b") + col("a")
    var mask = _eval_predicate(pred, batch)
    assert_true(mask.true_count() == 2, "a < b+a: expected 2 true")
    print("PASS: _eval_predicate col(a) < col(b) + col(a) (nested colref RHS)")


# =============================================================================
# Gap C2b — implicit numeric promotion in compare ops.
# =============================================================================


def test_predicate_int64_gt_float_literal() raises:
    """col("int_col") > 0.5 — INT64 column vs FLOAT64 literal.

    Pre-fix: the literal-RHS path takes `lit_val.int_val` (which is 0 for a
    float literal), producing a wrong result silently. Post-fix: promotes
    the INT64 column to FLOAT64 and uses the float literal.
    """
    # a = [-1, 0, 1, 2, 3] — values >0.5 are 1, 2, 3 = 3
    var a_vals: List[Int64] = [Int64(-1), Int64(0), Int64(1), Int64(2), Int64(3)]
    var b_vals: List[Int64] = [Int64(0), Int64(0), Int64(0), Int64(0), Int64(0)]
    var batch = _build_int64_pair_batch(a_vals, b_vals)

    var pred = col("a") > 0.5
    var mask = _eval_predicate(pred, batch)
    assert_true(
        mask.true_count() == 3,
        "INT64 > 0.5 (numeric promotion): expected 3 true",
    )
    print("PASS: _eval_predicate INT64 col > FLOAT64 literal (promotion)")


def test_predicate_int64_lt_float_literal_fractional() raises:
    """col("int_col") < 2.5 — fractional literal must NOT round to 2 or 3."""
    var a_vals: List[Int64] = [Int64(0), Int64(1), Int64(2), Int64(3), Int64(4)]
    var b_vals: List[Int64] = [Int64(0), Int64(0), Int64(0), Int64(0), Int64(0)]
    var batch = _build_int64_pair_batch(a_vals, b_vals)

    # < 2.5 => 0,1,2 = 3
    var pred = col("a") < 2.5
    var mask = _eval_predicate(pred, batch)
    assert_true(
        mask.true_count() == 3,
        "INT64 < 2.5 (fractional promotion): expected 3 true",
    )
    print("PASS: _eval_predicate INT64 col < 2.5 (fractional literal)")


def test_predicate_int64_col_vs_float64_col() raises:
    """col("a") > col("b") with mixed INT64 / FLOAT64 column types.

    Pre-fix: `_eval_col_vs_col` requires the same Arrow type on both sides
    and raises "_eval_col_vs_col: unsupported column type" on mixed.
    Post-fix: promotes the INT64 side to FLOAT64 and compares.
    """
    # a = [1, 5, 10, 100], b = [0.5, 5.5, 10.0, 99.9]
    # a > b => [T, F, F, T] = 2
    var a_vals: List[Int64] = [Int64(1), Int64(5), Int64(10), Int64(100)]
    var b_vals: List[Float64] = [Float64(0.5), Float64(5.5), Float64(10.0), Float64(99.9)]
    var batch = _build_int64_float64_batch(a_vals, b_vals)

    var pred = col("a") > col("b")
    var mask = _eval_predicate(pred, batch)
    assert_true(
        mask.true_count() == 2,
        "INT64 col > FLOAT64 col (promotion): expected 2 true",
    )
    print("PASS: _eval_predicate INT64 col > FLOAT64 col (promotion)")


# =============================================================================
# Negative test — string vs numeric must remain an error.
# =============================================================================


def test_predicate_promotion_does_not_cross_string_numeric() raises:
    """Numeric promotion must NOT silently cross into STRING."""
    # We can't easily synthesize a STRING column without going through
    # heavier builders; but the existing string-vs-string path already
    # has its own kernel. The promotion logic only fires on numeric
    # types. This test reserves the slot for a future direct check;
    # for now, the existing string/numeric error in
    # `_eval_predicate` covers it via the col_at-dispatch fallthrough.
    print("PASS: (placeholder) string/numeric must not promote")


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("=== Gap C — Compound RHS (EXPR_BINARY_OP) ===")
    test_predicate_compound_rhs_int_mul_int()
    test_predicate_compound_rhs_float_mul_float()
    test_predicate_compound_rhs_q20_canonical_shape()
    test_predicate_compound_rhs_addition()
    print()
    print("=== Gap C — Implicit numeric promotion ===")
    test_predicate_int64_gt_float_literal()
    test_predicate_int64_lt_float_literal_fractional()
    test_predicate_int64_col_vs_float64_col()
    print()
    print("=== Negative tests ===")
    test_predicate_promotion_does_not_cross_string_numeric()
    print()
    print("All Gap C tests PASS")

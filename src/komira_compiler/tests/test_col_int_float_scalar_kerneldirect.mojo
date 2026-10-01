# =============================================================================
# column scalar-binary INT-col {op} FLOAT-literal type-parity
# =============================================================================
#
# Regression for a COLUMN-side silent-wrong bug:
#
#   `_eval_binary_col_scalar` (compiler_eval_column.mojo) had INT64/INT32
#   arms that read `sv.int_val` of a FLOAT ScalarValue. But
#   `ScalarValue.from_float` sets `int_val = 0` (the value lives in
#   `float_val`). So `int_col + 0.5` via the scalar fast-path read the
#   literal as 0 -> added 0 -> WRONG, silently. The col-col path (per-node
#   promotion) was correct; this is specifically the col-op-FLOAT-SCALAR
#   fast path.
#
# The fix dispatches on the scalar's REAL dtype (`sv.is_float`): when an
# integer column meets a FLOAT literal, promote the int column to f64, run
# the float kernel with `sv.float_val`, and output f64 — matching SQL /
# column per-node promotion AND the row path.
#
# Symmetric arm: a FLOAT-col vs INT-literal (value in `int_val`, float_val
# is 0) — the FLOAT64 arm now reads `int_val` when `sv.is_int`.
#
# KERNEL-DIRECT: drives `_eval_column_expr` (which routes the
# `EXPR_LITERAL` right operand into `_eval_binary_col_scalar`) over a
# hand-built INT64 RecordBatch + a float ScalarValue literal — no
# materialize / collect / read_csv. The comparison case (`int_col > 0.5`)
# drives `_eval_predicate` and is a parity-CONFIRMING guard (the comparison
# scalar path promotes too).
#
# RED-before: the int arms read `int_val`=0 -> `int_col + 0.5` == int_col
# (adds 0), `int_col * 1.5` == 0, etc. GREEN-after: SQL-correct f64.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.plan.expr import (
    Expr, BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_GT,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_compiler.compiler_eval_predicate import _eval_predicate


# =============================================================================
# Helpers
# =============================================================================


def _i64_batch(vals: List[Int64], name: String = "a") raises -> RecordBatch:
    """One-column non-nullable INT64 RecordBatch."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](vals[i]))
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(sb.build())


def _f64_batch(vals: List[Float64], name: String = "a") raises -> RecordBatch:
    """One-column non-nullable FLOAT64 RecordBatch."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.float64](vals[i]))
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](arr^))
    return rbb.build(sb.build())


def _approx(a: Float64, b: Float64) -> Bool:
    var d = a - b
    if d < 0.0:
        d = -d
    return d < 1e-9


# =============================================================================
# THE BUG — INT-col {op} FLOAT-literal
# =============================================================================


def test_int_col_add_float_lit() raises:
    """int_col + 0.5 -> f64, SQL-correct (RED-before adds 0)."""
    var batch = _i64_batch([Int64(7), Int64(2), Int64(10)])
    var expr = Expr.binary(
        BIN_ADD, Expr.col_ref("a"), Expr.literal(ScalarValue.from_float(0.5))
    )
    var out = _eval_column_expr(expr, batch)
    # Output must be FLOAT64 (int promoted), not int64.
    assert_true(out.arrow_type == ArrowType.FLOAT64)
    var arr = out.as_primitive[DType.float64]()
    assert_true(_approx(arr.get(0), 7.5))
    assert_true(_approx(arr.get(1), 2.5))
    assert_true(_approx(arr.get(2), 10.5))


def test_int_col_mul_float_lit() raises:
    """int_col * 1.5 -> f64 (RED-before multiplies by 0)."""
    var batch = _i64_batch([Int64(4), Int64(3), Int64(8)])
    var expr = Expr.binary(
        BIN_MUL, Expr.col_ref("a"), Expr.literal(ScalarValue.from_float(1.5))
    )
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.FLOAT64)
    var arr = out.as_primitive[DType.float64]()
    assert_true(_approx(arr.get(0), 6.0))
    assert_true(_approx(arr.get(1), 4.5))
    assert_true(_approx(arr.get(2), 12.0))


def test_int_col_sub_float_lit() raises:
    """int_col - 0.25 -> f64 (RED-before subtracts 0)."""
    var batch = _i64_batch([Int64(5), Int64(1), Int64(100)])
    var expr = Expr.binary(
        BIN_SUB, Expr.col_ref("a"), Expr.literal(ScalarValue.from_float(0.25))
    )
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.FLOAT64)
    var arr = out.as_primitive[DType.float64]()
    assert_true(_approx(arr.get(0), 4.75))
    assert_true(_approx(arr.get(1), 0.75))
    assert_true(_approx(arr.get(2), 99.75))


def test_int_col_div_float_lit() raises:
    """int_col / 2.0 -> f64 float division (RED-before divides by 0)."""
    var batch = _i64_batch([Int64(7), Int64(10), Int64(3)])
    var expr = Expr.binary(
        BIN_DIV, Expr.col_ref("a"), Expr.literal(ScalarValue.from_float(2.0))
    )
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.FLOAT64)
    var arr = out.as_primitive[DType.float64]()
    # FLOAT division, not truncating int-div: 7/2 = 3.5 (not 3).
    assert_true(_approx(arr.get(0), 3.5))
    assert_true(_approx(arr.get(1), 5.0))
    assert_true(_approx(arr.get(2), 1.5))


# =============================================================================
# SYMMETRIC ARM — FLOAT-col {op} INT-literal (value in int_val, not float_val)
# =============================================================================


def test_float_col_add_int_lit() raises:
    """float_col + 5 (INT literal) -> f64 (RED-before adds float_val=0)."""
    var batch = _f64_batch([Float64(1.5), Float64(2.25), Float64(10.0)])
    var expr = Expr.binary(
        BIN_ADD, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5))
    )
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.FLOAT64)
    var arr = out.as_primitive[DType.float64]()
    assert_true(_approx(arr.get(0), 6.5))
    assert_true(_approx(arr.get(1), 7.25))
    assert_true(_approx(arr.get(2), 15.0))


# =============================================================================
# PARITY-CONFIRMING GUARD — the comparison path already promotes
# =============================================================================


def test_int_col_gt_float_lit() raises:
    """int_col > 0.5 -> Bool, SQL-correct via the predicate scalar path.

    This case was already fixed; the test guards the comparison
    arm against regression now that the arithmetic arms are fixed.
    """
    var batch = _i64_batch([Int64(0), Int64(1), Int64(5)])
    var expr = Expr.binary(
        BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_float(0.5))
    )
    var out = _eval_predicate(expr, batch)
    assert_equal(len(out), 3)
    # 0 > 0.5 -> False ; 1 > 0.5 -> True ; 5 > 0.5 -> True
    assert_false(out.get(0))
    assert_true(out.get(1))
    assert_true(out.get(2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

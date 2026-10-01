# =============================================================================
# `<literal> - <column>` MUST KEEP THE COLUMN'S NULLS
# =============================================================================
#
# SILENT WRONG ANSWER, measured through the cross-surface element
# `proj_reflected_arith` (`SELECT 100 - v AS s ...`) at the sql, polars AND
# pandas doors, int64:
#
#     proj_reflected_arith/int64/nulls   row 1 is [None, 100, None, None],
#                                        want [None, None, None, None]
#
# `100 + v` and `3 * v` were NULL on the NULL row; only the SUB was wrong, and
# it answered the LITERAL. DuckDB answers NULL (committed oracle).
#
# ROOT CAUSE (`compiler_eval_column.mojo`, the scalar-LEFT fast path of the
# binary arm): `scalar - col` is computed as `-(col - scalar)`. The inner
# `_eval_binary_col_scalar` KEEPS the column's validity (it clones it onto its
# result), but the negation re-multiplies through `eval_mul_scalar`, which
# allocates a FRESH array with NO validity bitmap — so every NULL row came back
# valid, holding `-(0 - 100) = 100`: the literal.
#
# KERNEL-DIRECT: drives `_eval_column_expr` over a hand-built nullable
# RecordBatch, the same entry `test_col_int_float_scalar_kerneldirect` uses.
# RED before the fix: `is_null_at(1)` is False (the row reads 100 / 100.0).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import (
    SchemaBuilder, Field, RecordBatch, RecordBatchBuilder,
)
from komira_core.plan.expr import Expr, BIN_SUB
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_column import _eval_column_expr


def _i64_nullable(vals: List[Int64], null_at: Int) raises -> RecordBatch:
    """One NULLABLE INT64 column `v`; row `null_at` is NULL (payload 0)."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](vals[i]))
    # `set` marks a lane VALID, so the null is imposed AFTER the writes.
    arr._set_null(null_at)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(sb.build())


def _f64_nullable(vals: List[Float64], null_at: Int) raises -> RecordBatch:
    """One NULLABLE FLOAT64 column `v`; row `null_at` is NULL (payload 0.0)."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, Scalar[DType.float64](vals[i]))
    arr._set_null(null_at)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](arr^))
    return rbb.build(sb.build())


def test_int_literal_minus_nullable_int_col_keeps_nulls() raises:
    """100 - v over [10, NULL, 30] -> [90, NULL, 70] (RED-before: NULL -> 100)."""
    var batch = _i64_nullable([Int64(10), Int64(0), Int64(30)], 1)
    var expr = Expr.binary(
        BIN_SUB, Expr.literal(ScalarValue.from_int(100)), Expr.col_ref("v")
    )
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.INT64)
    assert_false(out.is_null_at(0))
    assert_true(out.is_null_at(1))  # NULL in, NULL out -- not the literal
    assert_false(out.is_null_at(2))
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Int64(90))  # the SIGN: 100 - 10, not 10 - 100
    assert_equal(arr.get(2), Int64(70))


def test_float_literal_minus_nullable_float_col_keeps_nulls() raises:
    """1.5 - v over [0.5, NULL, 2.0] -> [1.0, NULL, -0.5]."""
    var batch = _f64_nullable([Float64(0.5), Float64(0.0), Float64(2.0)], 1)
    var expr = Expr.binary(
        BIN_SUB, Expr.literal(ScalarValue.from_float(1.5)), Expr.col_ref("v")
    )
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.FLOAT64)
    assert_false(out.is_null_at(0))
    assert_true(out.is_null_at(1))
    assert_false(out.is_null_at(2))
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.float64]()
    assert_equal(arr.get(0), Float64(1.0))
    assert_equal(arr.get(2), Float64(-0.5))


def test_literal_minus_non_nullable_col_stays_all_valid() raises:
    """The CONTROL: no validity in, none invented out (100 - [1, 2] = [99, 98])."""
    var arr = PrimitiveArray[DType.int64].allocate(2)
    arr.set(0, Scalar[DType.int64](1))
    arr.set(1, Scalar[DType.int64](2))
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    var batch = rbb.build(sb.build())
    var expr = Expr.binary(
        BIN_SUB, Expr.literal(ScalarValue.from_int(100)), Expr.col_ref("v")
    )
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.null_count(), 0)
    var o = out.as_primitive[DType.int64]()
    assert_equal(o.get(0), Int64(99))
    assert_equal(o.get(1), Int64(98))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

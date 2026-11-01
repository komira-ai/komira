# =============================================================================
# test_computed_project_int_overflow_raises.mojo: integer `+ - *` in a
# computed projection raises DuckDB's `Out of Range Error: Overflow in ...`
# =============================================================================
#
# SUBJECT: `compute_project.eval_project_exprs_over_batch`, which evaluates a
# strict expression on one of two routes, chosen per batch:
#
#   * the column evaluator (`komira_batch_eval._eval_column_expr`), taken when
#     an input column of the expression holds a NULL; its kernels raise on
#     overflow;
#   * the per-DType `ExpressionExecutor` walkers, taken for a NULL-free batch
#     (the usual post-aggregate batch). Their I64 arithmetic must raise too,
#     not wrap.
#
# And the walker's raise must not become a decline: `_eval_computed_column`
# turns every other walker error into None, and a caller would then refuse
# under another name. These tests pin that the overflow propagates with
# DuckDB's sentence.
#
# 1. CONTROL: in-range arithmetic over the same batch shape answers (a change
#    that made the walker decline everything would pass 2 and fail here).
# 2. `num + 1`, `num * 2`, `num - x` over a NULL-free batch (the walker
#    route) raise.
# 3. The column-evaluator route: the same expression over a batch whose input
#    holds a NULL raises too; the NULL row itself does not.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_SUB, BIN_MUL
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray

from komira_dispatch_project.compute_project import (
    eval_project_exprs_over_batch,
)


comptime I64_MAX = Int64(9223372036854775807)
comptime I64_MIN = Int64(-9223372036854775807) - 1


def _batch(num: List[Int64], num_null: Int, i32: List[Int32]) raises -> RecordBatch:
    """`g` (a passthrough key), `num` INT64 (optionally one NULL row), `x`
    INT64 = 10 everywhere, `i` INT32."""
    var n = len(num)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("g"), ArrowType.INT64, False))
    sb.add_field(Field(String("num"), ArrowType.INT64, num_null >= 0))
    sb.add_field(Field(String("x"), ArrowType.INT64, False))
    sb.add_field(Field(String("i"), ArrowType.INT32, False))
    var g = List[Scalar[DType.int64]]()
    var xs = List[Scalar[DType.int64]]()
    var iv = List[Scalar[DType.int32]]()
    for r in range(n):
        g.append(Scalar[DType.int64](r))
        xs.append(Scalar[DType.int64](10))
        iv.append(Scalar[DType.int32](i32[r]))
    var numa: PrimitiveArray[DType.int64]
    if num_null >= 0:
        numa = PrimitiveArray[DType.int64].allocate_nullable(n)
        for r in range(n):
            numa.set(r, Scalar[DType.int64](num[r]))
        numa._set_null(num_null)
    else:
        var nl = List[Scalar[DType.int64]]()
        for r in range(n):
            nl.append(Scalar[DType.int64](num[r]))
        numa = PrimitiveArray[DType.int64].from_list(nl)
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(g)))
    rbb.add_column(Column.from_primitive[DType.int64](numa^))
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(xs)))
    rbb.add_column(Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(iv)))
    return rbb.build(sb.build())


def _project(var e: Expr, out_at: ArrowType) raises -> ExprArray:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("g")))
    exprs.append(Expr.alias(e^, String("y")))
    return exprs^


def _out_schema(out_at: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("g"), ArrowType.INT64, False))
    sb.add_field(Field(String("y"), out_at, True))
    return sb.build()


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _run(var e: Expr, var batch: RecordBatch, out_at: ArrowType) raises -> String:
    """"" + the answer's first cell, or the raise text, or "DECLINED"."""
    try:
        var out_opt = eval_project_exprs_over_batch(
            batch^, _project(e^, out_at), _out_schema(out_at)
        )
        if not out_opt:
            return String("DECLINED")
        var out = out_opt.take()
        if out_at == ArrowType.INT32:
            return String("ANSWER ") + String(Int(out.column_as_primitive_int32(1).get(0)))
        return String("ANSWER ") + String(Int(out.column_as_primitive_int64(1).get(0)))
    except err:
        return String(err)


def _raises(got: String, want: String) raises:
    assert_true(
        got.find(want) >= 0,
        String("want a raise containing `") + want + "`, got `" + got + "`",
    )


# =============================================================================
# 1. CONTROL
# =============================================================================


def _small() raises -> RecordBatch:
    return _batch([Int64(40), Int64(2)], -1, [Int32(7), Int32(8)])


def test_in_range_arithmetic_answers_on_the_walker_route() raises:
    assert_equal(
        _run(Expr.binary(BIN_ADD, Expr.col_ref(String("num")), _lit(1)), _small(), ArrowType.INT64),
        "ANSWER 41",
    )
    assert_equal(
        _run(Expr.binary(BIN_MUL, Expr.col_ref(String("num")), _lit(2)), _small(), ArrowType.INT64),
        "ANSWER 80",
    )
    assert_equal(
        _run(
            Expr.binary(BIN_SUB, Expr.col_ref(String("num")), Expr.col_ref(String("x"))),
            _small(),
            ArrowType.INT64,
        ),
        "ANSWER 30",
    )
    # the boundary itself is an answer: MAX - x fits
    assert_equal(
        _run(
            Expr.binary(BIN_SUB, Expr.col_ref(String("num")), Expr.col_ref(String("x"))),
            _batch([I64_MAX], -1, [Int32(1)]),
            ArrowType.INT64,
        ),
        "ANSWER 9223372036854775797",
    )


# =============================================================================
# 2. The NULL-free (walker) route
# =============================================================================


def test_walker_add_overflow_raises_not_wraps_not_declines() raises:
    var b = _batch([I64_MAX, Int64(2)], -1, [Int32(7), Int32(8)])
    _raises(
        _run(Expr.binary(BIN_ADD, Expr.col_ref(String("num")), _lit(1)), b^, ArrowType.INT64),
        "Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!",
    )


def test_walker_mul_overflow_raises() raises:
    var b = _batch([I64_MAX, Int64(2)], -1, [Int32(7), Int32(8)])
    _raises(
        _run(Expr.binary(BIN_MUL, Expr.col_ref(String("num")), _lit(2)), b^, ArrowType.INT64),
        "Overflow in multiplication of INT64 (9223372036854775807 * 2)!",
    )


def test_walker_sub_overflow_raises() raises:
    var b = _batch([I64_MIN, Int64(2)], -1, [Int32(7), Int32(8)])
    _raises(
        _run(
            Expr.binary(BIN_SUB, Expr.col_ref(String("num")), Expr.col_ref(String("x"))),
            b^,
            ArrowType.INT64,
        ),
        "Overflow in subtraction of INT64 (-9223372036854775808 - 10)!",
    )


# No INT32 case here: this evaluator declines `i + i` over an INT32 column
# (the translator has no I32 arithmetic node), so a caller falls back to the
# column evaluator, whose INT32 kernels raise on overflow
# (`komira_batch_eval`'s test_int_arith_overflow_raises pins that).


# =============================================================================
# 3. The column-evaluator route: an input that holds a NULL
# =============================================================================


def test_overlay_route_raises_for_a_valid_overflow_beside_a_null() raises:
    var b = _batch([Int64(5), I64_MAX, Int64(0)], 2, [Int32(1), Int32(1), Int32(1)])
    _raises(
        _run(Expr.binary(BIN_ADD, Expr.col_ref(String("num")), _lit(1)), b^, ArrowType.INT64),
        "Overflow in addition of INT64 (9223372036854775807 + 1)!",
    )


def test_overlay_route_null_row_with_an_overflowing_payload_is_null() raises:
    """Row 1's payload is MAX under a NULL bit: NULL + 1 is NULL, not a raise."""
    var b = _batch([Int64(5), I64_MAX], 1, [Int32(1), Int32(1)])
    var out_opt = eval_project_exprs_over_batch(
        b^,
        _project(Expr.binary(BIN_ADD, Expr.col_ref(String("num")), _lit(1)), ArrowType.INT64),
        _out_schema(ArrowType.INT64),
    )
    assert_true(Bool(out_opt), "served")
    var out = out_opt.take()
    var y = out.column_as_primitive_int64(1)
    assert_equal(Int(y.get(0)), 6)
    assert_true(y.is_null(1), "NULL + 1 is NULL")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# The public entry points (`evaluate.evaluate_column`,
# `evaluate.evaluate_predicate`) return what the evaluators behind them return.
#
# Each test pins one property a caller relies on: a projection keeps an
# operand's NULL and computes the values (an entry that broadcast the literal
# or dropped validity fails the value and NULL asserts), a predicate reports
# UNKNOWN as data 0 with validity 0 (an entry that collapsed UNKNOWN to FALSE
# without validity fails the validity asserts), and a column the batch does not
# have raises rather than producing a column.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_plan_expr.expr import BIN_GT, BIN_SUB, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_batch_eval.evaluate import evaluate_column, evaluate_predicate


def _ints_with_null_at_1() raises -> RecordBatch:
    """One nullable INT64 column `v` = [10, NULL, 30]."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(3)
    arr.set(0, Scalar[DType.int64](10))
    arr.set(1, Scalar[DType.int64](0))
    arr.set(2, Scalar[DType.int64](30))
    arr._set_null(1)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(sb.build())


def test_evaluate_column_projects_and_keeps_nulls() raises:
    """100 - v over [10, NULL, 30] is [90, NULL, 70]."""
    var batch = _ints_with_null_at_1()
    var expr = Expr.binary(
        BIN_SUB, Expr.literal(ScalarValue.from_int(100)), Expr.col_ref("v")
    )
    var out = evaluate_column(expr, batch)
    assert_true(out.arrow_type == ArrowType.INT64)
    assert_equal(out.length(), 3)
    assert_true(out.is_null_at(1))
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Int64(90))
    assert_equal(arr.get(2), Int64(70))


def test_evaluate_predicate_reports_unknown_as_invalid() raises:
    """v > 15 over [10, NULL, 30] is [FALSE, UNKNOWN, TRUE]."""
    var batch = _ints_with_null_at_1()
    var expr = Expr.binary(
        BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(15))
    )
    var mask = evaluate_predicate(expr, batch)
    assert_equal(len(mask), 3)
    assert_false(mask.data.test(0))
    assert_false(mask.data.test(1))
    assert_true(mask.data.test(2))
    assert_true(Bool(mask.validity), "a nullable operand must leave a validity bitmap")
    assert_true(mask.validity.value().test(0))
    assert_false(mask.validity.value().test(1))
    assert_true(mask.validity.value().test(2))


def test_evaluate_column_refuses_an_unknown_column() raises:
    """A column reference the batch does not have raises; no column is invented."""
    var batch = _ints_with_null_at_1()
    with assert_raises():
        _ = evaluate_column(Expr.col_ref("missing"), batch)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

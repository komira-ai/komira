# =============================================================================
# test_round_digits_projection — `EXPR_ROUND_DIGITS` through the projection
# evaluator, with the declared Field agreeing with the evaluated Column
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.heap_region import HeapRegion
from column_kernels.compiler_helpers import field_for_expr
from plan_expr.expr import (
    Expr,
    RDG_ROUND,
    RDG_ROUND_HALF_EVEN,
    RDG_TRUNC,
)
from scalar_arithmetic.decimal_arith import I128
from batch_eval.eval_column import _eval_column_expr


def _batch() raises -> RecordBatch:
    """Three rows. `i` INT32 [1250, NULL, -1250]; `f` FLOAT64
    [2.5, -2.5, 0.125]; `d` DECIMAL(12,4) [1.2345, NULL, -7.9955]; `s`
    STRING."""
    var ia = PrimitiveArray[DType.int32].allocate_nullable(3)
    ia.set(0, Int32(1250))
    ia.set(1, Int32(7))
    ia.set(2, Int32(-1250))
    ia.validity.value().clear(1)
    ia.null_count = 1

    var fa = PrimitiveArray[DType.float64].from_list([2.5, -2.5, 0.125])

    var da = Decimal128Array.allocate(3, 12, 4)
    da.set_i128(0, I128(12345))
    da.set_i128(1, I128(7))
    da.set_i128(2, I128(-79955))
    da.set_null(1)

    var ss = List[String]()
    ss.append(String("a"))
    ss.append(String("b"))
    ss.append(String("c"))

    var sb = SchemaBuilder()
    sb.add_field(Field(String("i"), ArrowType.INT32, True))
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, False))
    sb.add_field(Field.decimal128(String("d"), 12, 4, True))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int32](ia^))
    rb.add_column(Column.from_primitive[DType.float64](fa^))
    rb.add_column(Column.from_decimal128(da^))
    rb.add_column(Column.from_string(StringArray.from_strings(ss)))
    return rb.build(sb.build())


def _rdg(op: UInt8, name: String, digits: Int) -> Expr:
    return Expr.round_digits(op, Expr.col_ref(name), Int32(digits))


def _assert_declared_matches(
    expr: Expr, batch: RecordBatch, col: Column[HeapRegion]
) raises:
    var declared = field_for_expr(expr, batch.schema)
    assert_true(declared.arrow_type == col.arrow_type)
    assert_equal(col.length(), batch.num_rows())
    if declared.arrow_type == ArrowType.DECIMAL128:
        assert_equal(declared.decimal_precision, col.decimal_precision())
        assert_equal(declared.decimal_scale, col.decimal_scale())


def test_round_float64_column_rounds_half_away_and_matches_declared() raises:
    var batch = _batch()
    var e = _rdg(RDG_ROUND, "f", 0)
    var col = _eval_column_expr(e, batch)
    _assert_declared_matches(e, batch, col)
    var arr = col.as_primitive[DType.float64]()
    assert_equal(arr.get(0), 3.0)
    assert_equal(arr.get(1), -3.0)
    assert_equal(arr.get(2), 0.0)


def test_trunc_float64_column_with_digits() raises:
    var batch = _batch()
    var e = _rdg(RDG_TRUNC, "f", 2)
    var col = _eval_column_expr(e, batch)
    _assert_declared_matches(e, batch, col)
    var arr = col.as_primitive[DType.float64]()
    assert_equal(arr.get(2), 0.12)


def test_half_even_float64_column_halves_go_to_even() raises:
    var batch = _batch()
    var e = _rdg(RDG_ROUND_HALF_EVEN, "f", 0)
    var col = _eval_column_expr(e, batch)
    _assert_declared_matches(e, batch, col)
    var arr = col.as_primitive[DType.float64]()
    assert_equal(arr.get(0), 2.0)
    assert_equal(arr.get(1), -2.0)


def test_round_int32_column_keeps_type_and_null() raises:
    var batch = _batch()
    var e = _rdg(RDG_ROUND, "i", -2)
    var col = _eval_column_expr(e, batch)
    _assert_declared_matches(e, batch, col)
    var arr = col.as_primitive[DType.int32]()
    assert_equal(arr.get(0), Int32(1300))
    assert_true(arr.is_null(1))
    assert_equal(arr.get(2), Int32(-1300))
    assert_true(field_for_expr(e, batch.schema).nullable)


def test_round_decimal_column_stamps_the_walker_precision_and_scale() raises:
    var batch = _batch()
    var e = _rdg(RDG_ROUND, "d", 2)
    var col = _eval_column_expr(e, batch)
    _assert_declared_matches(e, batch, col)
    assert_equal(col.decimal_precision(), 12)
    assert_equal(col.decimal_scale(), 2)
    var arr = col.as_decimal128()
    assert_equal(arr.get_i128(0), I128(123))
    assert_true(arr.is_null(1))
    assert_equal(arr.get_i128(2), I128(-800))


def test_trunc_decimal_column_negative_digits_is_scale_zero() raises:
    var batch = _batch()
    var e = _rdg(RDG_TRUNC, "d", -1)
    var col = _eval_column_expr(e, batch)
    _assert_declared_matches(e, batch, col)
    assert_equal(col.decimal_scale(), 0)
    assert_equal(col.as_decimal128().get_i128(0), I128(0))


def test_round_decimal_all_zero_column_is_non_nullable_and_valid_zero() raises:
    var batch = _batch()
    var e = _rdg(RDG_ROUND, "d", -8)
    var col = _eval_column_expr(e, batch)
    _assert_declared_matches(e, batch, col)
    assert_true(not field_for_expr(e, batch.schema).nullable)
    var arr = col.as_decimal128()
    for i in range(3):
        assert_true(not arr.is_null(i))
        assert_equal(arr.get_i128(i), I128(0))


def test_round_digits_under_an_alias_evaluates_the_child() raises:
    var batch = _batch()
    var e = Expr.alias(_rdg(RDG_ROUND, "f", 0), String("r"))
    var col = _eval_column_expr(e, batch)
    assert_equal(col.as_primitive[DType.float64]().get(0), 3.0)


def test_half_even_over_decimal_is_refused_by_name() raises:
    var batch = _batch()
    var e = _rdg(RDG_ROUND_HALF_EVEN, "d", 2)
    var declared = field_for_expr(e, batch.schema)
    assert_true(declared.arrow_type == ArrowType.DECIMAL128)
    assert_equal(declared.decimal_scale, 4)
    with assert_raises(contains="no DECIMAL rule"):
        _ = _eval_column_expr(e, batch)


def test_round_digits_over_a_string_column_is_refused_by_name() raises:
    var batch = _batch()
    with assert_raises(contains="round(x, digits) / trunc(x, digits) support"):
        _ = _eval_column_expr(_rdg(RDG_ROUND, "s", 1), batch)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

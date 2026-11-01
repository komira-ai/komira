# =============================================================================
# test_filter_null_literal_alias_is_null.mojo
#
# evaluate_filter_narrowed over predicates whose three-valued logic needs a
# node that is neither a comparison nor a plain AND/OR/NOT:
#   * a NULL boolean literal under AND / OR / NOT (UNKNOWN, never FALSE),
#   * an alias wrapped around an OR (the alias must not hide the OR's arms),
#   * IS NULL / IS NOT NULL (the operand's NULLs are the answer, so the
#     operand's validity must not be folded into the result).
#
# Fixture: a = [10, 20, 30, 40, 50] (no NULLs),
#          b = [999, NULL, 999, NULL, 999] (NULL rows 1 and 3).
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.selection_vector import SelectionVector
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_GT,
    BIN_OR,
    Expr,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_batch_eval.conjunction import evaluate_filter_narrowed


def _int64_column(
    values: List[Int64], null_indices: List[Int]
) raises -> PrimitiveArray[DType.int64]:
    var length = len(values)
    comptime elem_size = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(length, 1) * elem_size)
    for i in range(length):
        buf.set_typed[Scalar[DType.int64]](i, Scalar[DType.int64](values[i]))
    buf.set_length(Int64(length * elem_size))
    var validity = Bitmap.create_all_valid(length)
    for k in range(len(null_indices)):
        validity.clear(null_indices[k])
    return PrimitiveArray[DType.int64](
        buf^,
        length,
        Optional[Bitmap[HeapRegion]](validity^),
        len(null_indices),
        0,
    )


def _batch() raises -> RecordBatch:
    var a_vals: List[Int64] = [10, 20, 30, 40, 50]
    var b_vals: List[Int64] = [999, 999, 999, 999, 999]
    var no_nulls: List[Int] = []
    var b_nulls: List[Int] = [1, 3]
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    return RecordBatch.from_columns_2(
        sb.build(),
        _int64_column(a_vals, no_nulls),
        _int64_column(b_vals, b_nulls),
    )


def _gt(name: String, v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref(name), Expr.literal(ScalarValue.from_int64(v))
    )


def _null_bool() -> Expr:
    return Expr.literal(ScalarValue.null(DType.bool))


def _rows(sv: SelectionVector) raises -> List[Int]:
    var out = List[Int]()
    var ptr = sv.indices._typed_ptr_ro()
    for i in range(sv.length()):
        out.append(Int(ptr[i]))
    return out^


def _check(expr: Expr, expected: List[Int]) raises:
    var batch = _batch()
    var got = _rows(evaluate_filter_narrowed(batch, expr))
    assert_equal(len(got), len(expected))
    for i in range(len(expected)):
        assert_equal(got[i], expected[i])


def test_not_null_literal_keeps_no_rows() raises:
    """`NOT NULL` is UNKNOWN on every row, so nothing survives."""
    _check(Expr.unary(UN_NOT, _null_bool()), [])


def test_negated_conjunction_with_null_literal_arm() raises:
    """`NOT (a > 25 AND NULL)`: rows 0, 1 have `a > 25` FALSE, so the AND is a
    known FALSE and its negation TRUE; rows 2..4 are TRUE AND NULL = UNKNOWN."""
    _check(
        Expr.unary(UN_NOT, Expr.binary(BIN_AND, _gt("a", 25), _null_bool())),
        [0, 1],
    )


def test_disjunction_with_null_literal_arm() raises:
    """`a > 25 OR NULL` keeps the rows where `a > 25` is TRUE."""
    _check(Expr.binary(BIN_OR, _gt("a", 25), _null_bool()), [2, 3, 4])


def test_negated_disjunction_with_null_literal_arm() raises:
    """`NOT (a > 25 OR NULL)`: FALSE OR NULL = UNKNOWN, TRUE OR NULL = TRUE, so
    the negation keeps nothing."""
    _check(
        Expr.unary(UN_NOT, Expr.binary(BIN_OR, _gt("a", 25), _null_bool())),
        [],
    )


def test_aliased_disjunction_keeps_TRUE_OR_NULL_rows() raises:
    """`(a > 25 OR b > 1000) AS p` keeps row 3 (`TRUE OR UNKNOWN`) exactly as
    the unaliased OR does."""
    var inner = Expr.binary(BIN_OR, _gt("a", 25), _gt("b", 1000))
    _check(Expr.alias(inner^, "p"), [2, 3, 4])


def test_is_null_finds_exactly_the_missing_values() raises:
    _check(Expr.unary(UN_IS_NULL, Expr.col_ref("b")), [1, 3])


def test_is_not_null_is_the_complement() raises:
    _check(Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("b")), [0, 2, 4])


def test_is_null_or_comparison_on_the_same_column() raises:
    """`b IS NULL OR b > 5`: the NULL rows satisfy the left arm, the rest the
    right one, so every row survives."""
    _check(
        Expr.binary(
            BIN_OR, Expr.unary(UN_IS_NULL, Expr.col_ref("b")), _gt("b", 5)
        ),
        [0, 1, 2, 3, 4],
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

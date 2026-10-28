# =============================================================================
# OP_FILTER over the selection mask
# =============================================================================
#
# `FilterOp` is run on morsels of the sample table (a = r, b = r * 10 with NULL
# where r % 5 == 2). What these tests prove:
#
#   * A predicate that keeps some rows leaves the batch's rows where they are
#     and records the kept ones in the batch's selection mask; the operator
#     reports NEED_MORE_INPUT.
#   * A predicate that keeps every row leaves no mask, and one that keeps none
#     reports FILTERED_EMPTY.
#   * An UNKNOWN predicate drops the row, also under NOT (NOT UNKNOWN is
#     UNKNOWN), and survives an OR with TRUE; IS NULL keeps the NULL rows; a
#     predicate that is UNKNOWN on every row is FILTERED_EMPTY.
#   * A morsel that arrives with a mask is gathered before the predicate is
#     evaluated, so the second of two filters sees only the rows the first kept.
#   * A morsel with no rows is FILTERED_EMPTY.
#   * A predicate whose NULL scope the evaluator cannot derive is refused by
#     name, on the first morsel, and not guessed at.
#   * The workers' filters share one predicate: two instances made from one
#     `FilterShared` give the same answer.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_arrow.schema import RecordBatch
from komira_exec_types.exec_result import ExecResult
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_physical_plan.physical_plan import MorselOp
from komira_pipeline_exec.op_filter import FilterShared
from komira_pipeline_exec.plan_harness import (
    int64_column,
    sample_batch,
)
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LT,
    BIN_OR,
    Expr,
    MATH_SQRT,
    UN_IS_NULL,
    UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, _col(name), _lit(v))


def _filter(var predicate: Expr) raises -> FilterShared:
    return FilterShared(MorselOp.filter(predicate^))


def _selected_a(ref batch: RecordBatch) raises -> List[Int]:
    """Column a of the rows the batch's mask keeps (every row without one)."""
    var a = int64_column(batch, 0)
    var out = List[Int]()
    for i in range(len(a)):
        if batch.has_selection_mask() and not batch.selection_mask_get(i):
            continue
        out.append(a[i])
    return out^


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "element " + String(i))


def _run(var predicate: Expr, start: Int, rows: Int) raises -> Morsel:
    var op = _filter(predicate^).make()
    var m = Morsel(sample_batch(start, rows), 0, 0)
    _ = op.execute(m)
    return m^


def test_a_filter_records_the_kept_rows_as_a_mask() raises:
    var pred = Expr.binary(BIN_AND, _cmp(BIN_GE, "a", 4), _cmp(BIN_LT, "a", 8))
    var op = _filter(pred^).make()
    var m = Morsel(sample_batch(0, 10), 0, 0)
    var rc = op.execute(m)
    assert_true(rc.is_need_more_input())
    assert_equal(m.num_rows(), 10)
    assert_true(m.batch.has_selection_mask())
    assert_equal(m.batch.selection_mask_true_count(), 4)
    _expect(_selected_a(m.batch), [4, 5, 6, 7])


def test_a_predicate_that_keeps_every_row_leaves_no_mask() raises:
    var op = _filter(_cmp(BIN_GE, "a", 0)).make()
    var m = Morsel(sample_batch(0, 10), 0, 0)
    var rc = op.execute(m)
    assert_true(rc.is_need_more_input())
    assert_false(m.batch.has_selection_mask())
    assert_equal(m.num_rows(), 10)


def test_a_predicate_that_keeps_no_row_is_filtered_empty() raises:
    var op = _filter(_cmp(BIN_GT, "a", 100)).make()
    var m = Morsel(sample_batch(0, 10), 0, 0)
    assert_true(op.execute(m).is_filtered_empty())


def test_an_unknown_predicate_drops_the_row() raises:
    # b is NULL at rows 2 and 7; b > 15 is TRUE at 3, 4, 5, 6, 8, 9.
    var m = _run(_cmp(BIN_GT, "b", 15), 0, 10)
    _expect(_selected_a(m.batch), [3, 4, 5, 6, 8, 9])


def test_not_of_an_unknown_predicate_is_still_unknown() raises:
    # NOT (b > 15) keeps rows 0 and 1 only: rows 2 and 7 are UNKNOWN, not TRUE.
    var m = _run(Expr.unary(UN_NOT, _cmp(BIN_GT, "b", 15)), 0, 10)
    _expect(_selected_a(m.batch), [0, 1])


def test_true_or_unknown_keeps_the_row() raises:
    # Row 2 is UNKNOWN on the left and TRUE on the right.
    var pred = Expr.binary(BIN_OR, _cmp(BIN_GT, "b", 15), _cmp(BIN_EQ, "a", 2))
    var m = _run(pred^, 0, 10)
    _expect(_selected_a(m.batch), [2, 3, 4, 5, 6, 8, 9])


def test_is_null_keeps_the_null_rows() raises:
    var m = _run(Expr.unary(UN_IS_NULL, _col("b")), 0, 10)
    _expect(_selected_a(m.batch), [2, 7])


def test_a_predicate_unknown_on_every_row_is_filtered_empty() raises:
    # The one row of this morsel is row 2, whose b is NULL.
    var op = _filter(_cmp(BIN_GT, "b", 0)).make()
    var m = Morsel(sample_batch(2, 1), 0, 0)
    assert_true(op.execute(m).is_filtered_empty())


def test_a_second_filter_sees_only_the_rows_the_first_kept() raises:
    var first = _filter(_cmp(BIN_GE, "a", 2)).make()
    var second = _filter(_cmp(BIN_LT, "a", 5)).make()
    var m = Morsel(sample_batch(0, 10), 0, 0)
    _ = first.execute(m)
    assert_true(m.batch.has_selection_mask())
    var rc = second.execute(m)
    assert_true(rc.is_need_more_input())
    # The rows 0 and 1 were gathered away before the second predicate ran.
    assert_equal(m.num_rows(), 8)
    _expect(_selected_a(m.batch), [2, 3, 4])


def test_a_morsel_with_no_rows_is_filtered_empty() raises:
    var op = _filter(_cmp(BIN_GE, "a", 0)).make()
    var m = Morsel(sample_batch(0, 0), 0, 0)
    assert_true(op.execute(m).is_filtered_empty())


def test_a_predicate_with_no_null_scope_is_refused_by_name() raises:
    var pred = Expr.binary(BIN_GT, Expr.math_fn(MATH_SQRT, _col("a")), _lit(1))
    var op = _filter(pred^).make()
    var m = Morsel(sample_batch(0, 10), 0, 0)
    with assert_raises(contains="OP_FILTER refuses its predicate"):
        _ = op.execute(m)


def test_instances_of_one_shared_filter_agree() raises:
    var shared = _filter(_cmp(BIN_GE, "a", 6))
    var one = shared.make()
    var two = shared.make()
    var m1 = Morsel(sample_batch(0, 10), 0, 0)
    var m2 = Morsel(sample_batch(0, 10), 1, 1)
    _ = one.execute(m1)
    _ = two.execute(m2)
    _expect(_selected_a(m1.batch), [6, 7, 8, 9])
    _expect(_selected_a(m2.batch), [6, 7, 8, 9])


def test_a_filter_needs_a_predicate() raises:
    with assert_raises(contains="carries no predicate"):
        _ = FilterShared(MorselOp.limit(3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

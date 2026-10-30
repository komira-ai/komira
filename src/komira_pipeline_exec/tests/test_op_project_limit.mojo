# =============================================================================
# OP_PROJECT and OP_LIMIT
# =============================================================================
#
# Both run on morsels of the sample table (a = r, b = r * 10 with NULL where
# r % 5 == 2, s = "s" + r % 4). What these tests prove:
#
# Project
#   * Columns come out in the order the projection names them, a dropped
#     column is gone, a repeated column appears twice under its new names, and
#     the values are those of the input rows.
#   * A computed column is evaluated for the selected rows only.
#   * Under a selection mask a projection of bare columns keeps the mask and
#     the physical rows, and a computed projection yields only the selected
#     rows, with no mask.
#   * A projection with no expressions, or with a different number of names, is
#     refused by name.
#
# Limit
#   * Across morsels one after another the first `limit` rows pass: whole
#     morsels while the budget lasts, a cut morsel at the boundary, then empty
#     morsels; the operator reports FINISHED at the morsel that spends the
#     budget and on every later one.
#   * A limit that lands exactly on the end of a morsel leaves that morsel whole
#     and reports FINISHED.
#   * Two operators made from one `LimitShared` (two workers) draw on one
#     budget: the rows that pass add up to the limit.
#   * Limit 0 passes nothing and reports FINISHED on the first morsel.
#   * A selection mask counts its selected rows: a limit under the selected
#     count leaves the mask alone, a limit inside it gathers and cuts.
#   * A negative row count is refused by name.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_arrow.schema import RecordBatch
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_physical_plan.physical_plan import MorselOp
from komira_pipeline_exec.op_filter import FilterShared
from komira_pipeline_exec.op_limit import LimitShared
from komira_pipeline_exec.op_project import ProjectShared
from komira_pipeline_exec.plan_harness import (
    column_names,
    int64_column,
    null_column,
    project_columns,
    sample_batch,
    string_column,
)
from komira_plan_expr.expr import (
    BIN_ADD,
    BIN_GE,
    BIN_MUL,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _names(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    if c.byte_length() > 0:
        out.append(c)
    return out^


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "element " + String(i))


def _filter_ge(a: Int) raises -> FilterShared:
    return FilterShared(
        MorselOp.filter(Expr.binary(BIN_GE, Expr.col_ref("a"), _lit(a)))
    )


# ---- project ----------------------------------------------------------------


def test_a_projection_reorders_and_drops_columns() raises:
    var reorder = ProjectShared(project_columns(_names("s", "a"))).make()
    var m = Morsel(sample_batch(0, 6), 0, 0)
    _ = reorder.execute(m)
    var got = column_names(m.batch)
    assert_equal(len(got), 2)
    assert_equal(got[0], "s")
    assert_equal(got[1], "a")
    var s = string_column(m.batch, 0)
    assert_equal(s[0], "s0")
    assert_equal(s[5], "s1")
    _expect(int64_column(m.batch, 1), [0, 1, 2, 3, 4, 5])

    var drop = ProjectShared(project_columns(_names("b"))).make()
    var m2 = Morsel(sample_batch(0, 6), 0, 0)
    _ = drop.execute(m2)
    assert_equal(m2.num_columns(), 1)
    assert_equal(column_names(m2.batch)[0], "b")
    var nulls = null_column(m2.batch, 0)
    assert_true(nulls[2])
    assert_false(nulls[3])
    assert_equal(int64_column(m2.batch, 0)[4], 40)


def test_a_column_can_appear_twice_under_new_names() raises:
    var exprs = Slab[Expr]()
    exprs.append(Expr.col_ref("a"))
    exprs.append(Expr.col_ref("a"))
    var op = ProjectShared(MorselOp.project(exprs^, _names("x", "y"))).make()
    var m = Morsel(sample_batch(0, 4), 0, 0)
    _ = op.execute(m)
    var got = column_names(m.batch)
    assert_equal(got[0], "x")
    assert_equal(got[1], "y")
    _expect(int64_column(m.batch, 0), [0, 1, 2, 3])
    _expect(int64_column(m.batch, 1), [0, 1, 2, 3])


def test_a_computed_column_is_evaluated_for_the_selected_rows() raises:
    var exprs = Slab[Expr]()
    exprs.append(Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(1000)))
    var proj = ProjectShared(MorselOp.project(exprs^, _names("a1000"))).make()
    var filter = _filter_ge(7).make()
    var m = Morsel(sample_batch(0, 10), 0, 0)
    _ = filter.execute(m)
    assert_true(m.batch.has_selection_mask())
    _ = proj.execute(m)
    assert_false(m.batch.has_selection_mask())
    assert_equal(column_names(m.batch)[0], "a1000")
    _expect(int64_column(m.batch, 0), [1007, 1008, 1009])


def test_a_projection_of_columns_keeps_the_mask() raises:
    var proj = ProjectShared(project_columns(_names("s", "a"))).make()
    var filter = _filter_ge(7).make()
    var m = Morsel(sample_batch(0, 10), 0, 0)
    _ = filter.execute(m)
    _ = proj.execute(m)
    # The rows are still all there, and the mask says which are kept.
    assert_true(m.batch.has_selection_mask())
    assert_equal(m.num_rows(), 10)
    assert_equal(m.batch.selection_mask_true_count(), 3)
    assert_true(m.batch.selection_mask_get(7))
    assert_false(m.batch.selection_mask_get(6))
    assert_equal(column_names(m.batch)[0], "s")


def test_a_projection_without_expressions_is_refused() raises:
    with assert_raises(contains="carries no expressions"):
        _ = ProjectShared(MorselOp.limit(1))
    var exprs = Slab[Expr]()
    exprs.append(Expr.col_ref("a"))
    exprs.append(Expr.col_ref("b"))
    with assert_raises(contains="2 expressions and 1 names"):
        _ = ProjectShared(MorselOp.project(exprs^, _names("only")))


# ---- limit ------------------------------------------------------------------


def _limit_morsels(
    limit: Int, rows: Int, count: Int
) raises -> List[Int]:
    """Feed `count` morsels of `rows` rows to one limit; the rows (column a)
    that come out, with -1 after each morsel that reported FINISHED."""
    var shared = LimitShared(MorselOp.limit(limit))
    var op = shared.make()
    var out = List[Int]()
    for k in range(count):
        var m = Morsel(sample_batch(k * rows, rows), k, k)
        var rc = op.execute(m)
        var got = int64_column(m.batch, 0)
        for i in range(len(got)):
            out.append(got[i])
        if rc.is_finished():
            out.append(-1)
    return out^


def test_a_limit_passes_whole_morsels_then_cuts_one() raises:
    # Morsels of 10 rows, limit 25: 0-9, 10-19, 20-24 then spent.
    var got = _limit_morsels(25, 10, 5)
    var want = List[Int]()
    for r in range(25):
        want.append(r)
    want.append(-1)  # the cut morsel spends the budget
    want.append(-1)  # the next one finds it spent and is empty
    want.append(-1)
    _expect(got, want)


def test_a_limit_that_ends_on_a_morsel_boundary_leaves_it_whole() raises:
    var got = _limit_morsels(20, 10, 3)
    var want = List[Int]()
    for r in range(20):
        want.append(r)
        if r == 19:
            want.append(-1)
    want.append(-1)
    _expect(got, want)


def test_limit_zero_passes_nothing() raises:
    var got = _limit_morsels(0, 10, 2)
    _expect(got, [-1, -1])


def test_a_limit_larger_than_the_input_never_finishes() raises:
    var got = _limit_morsels(1000, 10, 3)
    assert_equal(len(got), 30)
    assert_equal(got[29], 29)


def test_two_workers_draw_on_one_budget() raises:
    var shared = LimitShared(MorselOp.limit(25))
    var w0 = shared.make()
    var w1 = shared.make()
    var passed = 0
    var finished = 0
    for k in range(4):
        var m0 = Morsel(sample_batch(k * 20, 10), k, k)
        var rc0 = w0.execute(m0)
        passed += m0.num_rows()
        if rc0.is_finished():
            finished += 1
        var m1 = Morsel(sample_batch(k * 20 + 10, 10), k, k)
        var rc1 = w1.execute(m1)
        passed += m1.num_rows()
        if rc1.is_finished():
            finished += 1
    assert_equal(passed, 25)
    # Both workers were told to stop once the budget was spent.
    assert_true(finished >= 2)


def test_a_limit_counts_the_selected_rows_of_a_masked_morsel() raises:
    # a >= 4 keeps 6 of 10 rows.
    var filter = _filter_ge(4).make()
    var roomy = LimitShared(MorselOp.limit(6)).make()
    var m = Morsel(sample_batch(0, 10), 0, 0)
    _ = filter.execute(m)
    var rc = roomy.execute(m)
    # The limit spends exactly the selected rows: nothing is cut, the mask stays.
    assert_true(rc.is_finished())
    assert_true(m.batch.has_selection_mask())
    assert_equal(m.num_rows(), 10)
    assert_equal(m.batch.selection_mask_true_count(), 6)

    var tight = LimitShared(MorselOp.limit(4)).make()
    var m2 = Morsel(sample_batch(0, 10), 0, 0)
    var filter2 = _filter_ge(4).make()
    _ = filter2.execute(m2)
    var rc2 = tight.execute(m2)
    assert_true(rc2.is_finished())
    assert_false(m2.batch.has_selection_mask())
    _expect(int64_column(m2.batch, 0), [4, 5, 6, 7])


def test_a_negative_limit_is_refused() raises:
    with assert_raises(contains="row count of zero or more"):
        _ = LimitShared(MorselOp.limit(-1))
    with assert_raises(contains="row count of zero or more"):
        _ = LimitShared(MorselOp.filter(Expr.col_ref("a")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

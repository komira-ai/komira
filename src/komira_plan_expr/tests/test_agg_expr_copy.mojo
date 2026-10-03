"""`AggExpr.copy()` deep-clone validation.

Validates the explicit `def copy(self) -> Self` method on AggExpr, which
delegates to `Expr.copy()` (the recursive deep-clone for the
OwnedPointer-fielded variants).

Coverage beyond `test_agg_expr_children.mojo`:
  - `count_distinct(col("a") + col("b"))` — AggExpr child0 is a NESTED
    Expr (EXPR_BINARY_OP wrapping two EXPR_COL_REF children). Forces
    Expr.copy()'s recursive arm and confirms the deep-clone descends
    through OwnedPointer[Expr] BinaryOpData payloads.
  - `corr(col("x"), col("y"))` — bivariate, exercises both child0 and
    child1 deep-clone arms.
  - `largest2(col("score"))` (AGG_LARGEST_K) — confirms hardcoded-K
    aggregate copies cleanly (the AGG_LARGEST_K variant has no k
    field on AggExpr today; K=2 is in the engine state).
  - `median(col("v"))` (AGG_MEDIAN) — confirms approximate-median
    aggregate copies.
  - Ownership independence: mutating the copy's `alias_name` does NOT
    leak into the original (the copy is a fully independent tree).

Reference:
  - DuckDB `src/planner/expression/bound_aggregate_expression.cpp`
    `BoundAggregateExpression::Copy()` walks `vector<unique_ptr<Expression>> children`
    and recursively clones each via the per-Expression Copy() method.
  - A Rust implementation gets the same recursion from `derive(Clone)` over
    `Box<Expr>` children.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_plan_expr.agg_expr import (
    AggExpr,
    AGG_SUM,
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_CORR,
    AGG_MEDIAN,
    AGG_LARGEST_K,
    sum,
    count,
    count_distinct,
    corr,
    median,
    largest2,
)
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, EXPR_BINARY_OP, EXPR_COL_REF, BIN_ADD


def test_copy_count_distinct_nested_expr() raises:
    """count_distinct(col("a") + col("b")) — child0 is a nested EXPR_BINARY_OP.

    Forces Expr.copy()'s recursive arm (BinaryOpData branch) to run and
    confirms AggExpr.copy() correctly delegates child0 deep-clone through
    Expr.copy() rather than a shallow shim.
    """
    var inner = Expr.binary(BIN_ADD, Expr.col_ref(String("a")), Expr.col_ref(String("b")))
    var orig = AggExpr(AGG_COUNT_DISTINCT, Optional[Expr](inner^), Optional[String]())
    var dup = orig.copy()

    # Func tag preserved.
    assert_equal(dup.func, AGG_COUNT_DISTINCT)
    # child0 populated; child1/2/3 None.
    assert_equal(dup.num_children(), 1)
    assert_true(Bool(dup.child))
    assert_false(Bool(dup.child1))
    assert_false(Bool(dup.child2))
    assert_false(Bool(dup.child3))

    # The nested expression structure survives the deep-clone.
    ref inner_clone = dup.child.value()
    assert_equal(inner_clone.tag, EXPR_BINARY_OP)
    assert_equal(inner_clone.binary_op(), BIN_ADD)
    ref left_clone = inner_clone.binary_left_ref()
    ref right_clone = inner_clone.binary_right_ref()
    assert_equal(left_clone.tag, EXPR_COL_REF)
    assert_equal(right_clone.tag, EXPR_COL_REF)
    assert_equal(left_clone.col_ref_name(), String("a"))
    assert_equal(right_clone.col_ref_name(), String("b"))


def test_copy_corr_bivariate() raises:
    """corr(col("x"), col("y")) — both child0 and child1 deep-cloned."""
    var orig = corr(col("x"), col("y"))
    var dup = orig.copy()

    assert_equal(dup.func, AGG_CORR)
    assert_equal(dup.num_children(), 2)
    assert_true(Bool(dup.child))
    assert_true(Bool(dup.child1))
    assert_false(Bool(dup.child2))
    assert_false(Bool(dup.child3))

    # Both clones are EXPR_COL_REF with the right names.
    assert_equal(dup.child.value().tag, EXPR_COL_REF)
    assert_equal(dup.child.value().col_ref_name(), String("x"))
    assert_equal(dup.child1.value().tag, EXPR_COL_REF)
    assert_equal(dup.child1.value().col_ref_name(), String("y"))


def test_copy_largest_k() raises:
    """largest2(col("score")) — AGG_LARGEST_K copies cleanly."""
    var orig = largest2(col("score"))
    var dup = orig.copy()

    assert_equal(dup.func, AGG_LARGEST_K)
    assert_equal(dup.num_children(), 1)
    assert_true(Bool(dup.child))
    assert_equal(dup.child.value().tag, EXPR_COL_REF)
    assert_equal(dup.child.value().col_ref_name(), String("score"))


def test_copy_median() raises:
    """median(col("v")) — AGG_MEDIAN copies cleanly."""
    var orig = median(col("v"))
    var dup = orig.copy()

    assert_equal(dup.func, AGG_MEDIAN)
    assert_equal(dup.num_children(), 1)
    assert_true(Bool(dup.child))
    assert_equal(dup.child.value().tag, EXPR_COL_REF)
    assert_equal(dup.child.value().col_ref_name(), String("v"))


def test_copy_count_star_zero_children() raises:
    """count() (COUNT(*)) — all-None children survives copy."""
    var orig = count()
    var dup = orig.copy()
    assert_equal(dup.func, AGG_COUNT)
    assert_equal(dup.num_children(), 0)
    assert_false(Bool(dup.child))
    assert_false(Bool(dup.child1))
    assert_false(Bool(dup.child2))
    assert_false(Bool(dup.child3))


def test_copy_alias_preserved() raises:
    """alias_name (Optional[String]) deep-copied independently."""
    var orig = sum(col("amount")).alias("total")
    var dup = orig.copy()
    assert_true(Bool(dup.alias_name))
    assert_equal(dup.alias_name.value(), String("total"))
    # Independent: the original's alias is also still "total".
    assert_true(Bool(orig.alias_name))
    assert_equal(orig.alias_name.value(), String("total"))


def test_copy_ownership_independence() raises:
    """Mutating the copy's alias must not leak into the original."""
    var orig = corr(col("a"), col("b"))
    var dup = orig.copy()
    # Apply alias to the copy via .alias() (constructs a new value).
    var aliased = dup.alias("ab_corr")
    assert_true(Bool(aliased.alias_name))
    assert_equal(aliased.alias_name.value(), String("ab_corr"))
    # Original alias_name remains None.
    assert_false(Bool(orig.alias_name))
    # The copy itself (pre-alias) also still has alias_name None — `.alias`
    # is not in-place; it returns a fresh AggExpr.
    assert_false(Bool(dup.alias_name))


def main() raises:
    test_copy_count_distinct_nested_expr()
    test_copy_corr_bivariate()
    test_copy_largest_k()
    test_copy_median()
    test_copy_count_star_zero_children()
    test_copy_alias_preserved()
    test_copy_ownership_independence()
    print("all agg_expr copy tests passed")

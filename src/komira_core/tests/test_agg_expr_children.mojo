"""AggExpr children: the four child slots.

Validates:
  - `corr(col1, col2)` constructor populates child + child1, leaves child2/child3 None.
  - `num_children()` returns the right populated count for 0/1/2-arg shapes.
  - `copy()` deep-copies all 4 child slots (not just slot 0).
  - `alias()` preserves all child slots and overrides alias_name.
  - Slot-0 source-compat: `agg.child` field access works for the unary case.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_core.plan.agg_expr import (
    AggExpr,
    AGG_SUM,
    AGG_COUNT,
    AGG_CORR,
    sum,
    count,
    corr,
)
from komira_core.plan.col_expr import col


def test_count_star_zero_children() raises:
    """COUNT(*) has all 4 child slots None."""
    var agg = count()
    assert_equal(agg.func, AGG_COUNT)
    assert_equal(agg.num_children(), 0)
    assert_false(Bool(agg.child))
    assert_false(Bool(agg.child1))
    assert_false(Bool(agg.child2))
    assert_false(Bool(agg.child3))


def test_sum_one_child() raises:
    """SUM(col("x")) populates slot 0 only."""
    var agg = sum(col("x"))
    assert_equal(agg.func, AGG_SUM)
    assert_equal(agg.num_children(), 1)
    assert_true(Bool(agg.child))
    assert_false(Bool(agg.child1))
    assert_false(Bool(agg.child2))
    assert_false(Bool(agg.child3))


def test_corr_two_children() raises:
    """corr(col("x"), col("y")) populates slots 0 and 1, leaves 2 and 3 None."""
    var agg = corr(col("x"), col("y"))
    assert_equal(agg.func, AGG_CORR)
    assert_equal(agg.num_children(), 2)
    assert_true(Bool(agg.child))
    assert_true(Bool(agg.child1))
    assert_false(Bool(agg.child2))
    assert_false(Bool(agg.child3))


def test_copy_preserves_all_slots() raises:
    """copy() must deep-copy all populated child slots, not just slot 0."""
    var orig = corr(col("a"), col("b"))
    var dup = orig.copy()
    assert_equal(dup.func, AGG_CORR)
    assert_equal(dup.num_children(), 2)
    assert_true(Bool(dup.child))
    assert_true(Bool(dup.child1))
    # The deep copy is independent from the original — mutating the
    # copy's alias must not affect the original.
    var aliased = dup.alias("my_corr")
    assert_true(Bool(aliased.alias_name))
    assert_equal(aliased.alias_name.value(), String("my_corr"))
    # Original alias_name remains None.
    assert_false(Bool(orig.alias_name))


def test_alias_preserves_all_slots() raises:
    """alias(name) keeps all child slots intact and sets alias_name."""
    var agg = corr(col("x"), col("y")).alias("xy_corr")
    assert_equal(agg.num_children(), 2)
    assert_true(Bool(agg.child))
    assert_true(Bool(agg.child1))
    assert_true(Bool(agg.alias_name))
    assert_equal(agg.alias_name.value(), String("xy_corr"))


def test_field_access_source_compat() raises:
    """Pre-children callsite syntax `agg.child` must keep working as field access."""
    var agg = sum(col("amount"))
    # The dominant pre-children read shape:
    if agg.child:
        # walk the inner expression — proves field access compiles
        ref inner = agg.child.value()
        assert_equal(inner.tag, inner.tag)  # tautology, just exercising .value()
    else:
        raise Error("expected slot 0 populated")


def main() raises:
    test_count_star_zero_children()
    test_sum_one_child()
    test_corr_two_children()
    test_copy_preserves_all_slots()
    test_alias_preserves_all_slots()
    test_field_access_source_compat()
    print("all agg_expr children tests passed")

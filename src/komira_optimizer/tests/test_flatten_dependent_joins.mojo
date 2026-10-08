"""`flatten_dependent_joins`
rule unit tests.

Validates the lowering shape per kind, the outer-ref hoist algorithm, the
UnresolvedOuterRef negative case, and the nested-correlation handling.

References (cited in module-doc of flatten_dependent_joins.mojo):
  - DuckDB src/planner/subquery/flatten_dependent_join.cpp
  - DataFusion optimizer/src/decorrelate_predicate_subquery.rs +
    scalar_subquery_to_join.rs

Coverage matrix:
  Test 1: EXISTS  -> JOIN_SEMI
  Test 2: NOT_EXISTS -> JOIN_ANTI
  Test 3: SCALAR  -> JOIN_LEFT + Aggregate sink
  Test 4: multi-key outer_refs (Q20 shape, 2-key EXISTS)
  Test 5: outer-ref hoist — Filter(inner, outer_eq) -> hoisted on= clause
  Test 6: UnresolvedOuterRef negative — outer_ref not in parent schema
  Test 7: nested correlated subquery (subquery in subquery) — verify
          BOTH levels of correlation are lowered.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_COL_REF,
    EXPR_BINARY_OP,
    BIN_EQ,
    BIN_GT,
    BIN_AND,
)
from komira_plan_expr.agg_expr import AggExpr, sum, AGG_SUM, AGG_MEAN
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_AGGREGATE,
    SOURCE_PARQUET,
    CORR_KIND_EXISTS,
    CORR_KIND_NOT_EXISTS,
    CORR_KIND_SCALAR,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_LEFT,
)

from komira_optimizer.flatten_dependent_joins import (
    flatten_dependent_joins,
    _plan_contains_correlated_subquery,
    _expr_contains_correlated_subquery,
)


# =============================================================================
# Fixtures
# =============================================================================


def _make_outer_scan() -> LogicalPlan:
    """Outer plan: scan over a tiny customer table (c_custkey, c_nationkey)."""
    var b = SchemaBuilder()
    b.add_field(Field(String("c_custkey"), ArrowType.INT64, False))
    b.add_field(Field(String("c_nationkey"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("customer.parquet"), SOURCE_PARQUET, schema^)


def _make_inner_scan() -> LogicalPlan:
    """Inner subquery scan: orders(o_orderkey, o_custkey)."""
    var b = SchemaBuilder()
    b.add_field(Field(String("o_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("o_custkey"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("orders.parquet"), SOURCE_PARQUET, schema^)


def _make_outer_scan_q20() -> LogicalPlan:
    """Outer plan for the Q20 multi-key shape (partsupp w/ ps_partkey, ps_suppkey)."""
    var b = SchemaBuilder()
    b.add_field(Field(String("ps_partkey"), ArrowType.INT64, False))
    b.add_field(Field(String("ps_suppkey"), ArrowType.INT64, False))
    b.add_field(Field(String("ps_availqty"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("partsupp.parquet"), SOURCE_PARQUET, schema^)


def _make_inner_scan_q20() -> LogicalPlan:
    """Inner subquery for Q20: lineitem(l_partkey, l_suppkey, l_quantity)."""
    var b = SchemaBuilder()
    b.add_field(Field(String("l_partkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_suppkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_quantity"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("lineitem.parquet"), SOURCE_PARQUET, schema^)


# =============================================================================
# Test 1: EXISTS -> JOIN_SEMI
# =============================================================================


def test_exists_lowers_to_semi_join() raises:
    var outer = _make_outer_scan()
    var inner = _make_inner_scan()
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var corr = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    var plan = LogicalPlan.filter(corr^, outer^)

    var lowered = flatten_dependent_joins(plan^)

    # After lowering, the root should be a Join, not a Filter.
    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_SEMI)
    # Equi-keys: default to same-named outer_ref since the inner plan has
    # no top-level Filter to hoist from. Outer = c_custkey, Inner = c_custkey
    # (the default hoist falls back to outer_refs for both sides).
    assert_equal(len(lowered._join.value()[].left_on), 1)
    assert_equal(lowered._join.value()[].left_on[0], String("c_custkey"))
    # Invariant: no correlated subquery remains.
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 2: NOT_EXISTS -> JOIN_ANTI
# =============================================================================


def test_not_exists_lowers_to_anti_join() raises:
    var outer = _make_outer_scan()
    var inner = _make_inner_scan()
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var corr = Expr.correlated_subquery(inner^, refs^, CORR_KIND_NOT_EXISTS)
    var plan = LogicalPlan.filter(corr^, outer^)

    var lowered = flatten_dependent_joins(plan^)

    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_ANTI)
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 3: SCALAR -> JOIN_LEFT + Aggregate sink
# =============================================================================


def test_scalar_lowers_to_left_join_with_agg_sink() raises:
    """Q17 shape: lineitem.l_quantity < 0.2 * AVG(l_quantity) for the
    matching p_partkey. We model this as Filter(outer, lhs > corr_sq).

    The correlated subquery's inner plan is an Aggregate over the inner
    scan (mirrors the canonical Q17 inner SELECT AVG(...) ...).
    """
    var outer = _make_outer_scan_q20()  # partsupp-shaped for symmetry
    var inner_scan = _make_inner_scan_q20()
    # Build inner aggregate: SUM(l_quantity) — same shape applies to AVG.
    var gb = ExprArray()
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref(String("l_quantity"))), Optional(String("__corr_scalar_0"))))
    var inner_agg = LogicalPlan.aggregate(gb^, aggs^, inner_scan^)

    var refs = List[String]()
    refs.append(String("ps_partkey"))
    var corr = Expr.correlated_subquery(inner_agg^, refs^, CORR_KIND_SCALAR)

    # Build the parent comparison: ps_availqty > corr_sq.
    var lhs = Expr.col_ref(String("ps_availqty"))
    var pred = Expr.binary(BIN_GT, lhs^, corr^)
    var plan = LogicalPlan.filter(pred^, outer^)

    var lowered = flatten_dependent_joins(plan^)

    # The lowered plan should be: Filter(rewritten_pred, LeftJoin(outer, Aggregate(...)))
    assert_equal(lowered.tag, PLAN_FILTER)
    ref join_node = lowered._filter.value()[].child[]
    assert_equal(join_node.tag, PLAN_JOIN)
    assert_equal(join_node._join.value()[].join_type, JOIN_LEFT)
    # Right side should be an Aggregate (the agg-sink that emits the
    # scalar). Walk through PLAN_AGGREGATE.
    ref right_side = join_node._join.value()[].right[]
    assert_equal(right_side.tag, PLAN_AGGREGATE)
    # No correlated subquery remains.
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 4: Multi-key outer_refs (Q20 shape — 2-key EXISTS)
# =============================================================================


def test_multi_key_outer_refs_q20() raises:
    var outer = _make_outer_scan_q20()
    var inner = _make_inner_scan_q20()
    var refs = List[String]()
    refs.append(String("ps_partkey"))
    refs.append(String("ps_suppkey"))
    var corr = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    var plan = LogicalPlan.filter(corr^, outer^)

    var lowered = flatten_dependent_joins(plan^)

    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_SEMI)
    # 2-key join.
    assert_equal(len(lowered._join.value()[].left_on), 2)
    assert_equal(lowered._join.value()[].left_on[0], String("ps_partkey"))
    assert_equal(lowered._join.value()[].left_on[1], String("ps_suppkey"))
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 5: Outer-ref hoist — Filter(inner, outer_eq) -> hoisted on= clause
# =============================================================================


def test_outer_ref_hoist_promotes_eq_predicate_to_join_keys() raises:
    """The inner plan is `Filter(orders_scan, c_custkey EQ o_custkey)`.
    The hoist algorithm should promote that equality into the join's
    left_on=[c_custkey] / right_on=[o_custkey] and drop the inner Filter.
    """
    var outer = _make_outer_scan()
    var inner_scan = _make_inner_scan()
    # Build Filter(inner_scan, BIN_EQ(c_custkey, o_custkey)).
    var eq_pred = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("c_custkey")),
        Expr.col_ref(String("o_custkey")),
    )
    var inner_filtered = LogicalPlan.filter(eq_pred^, inner_scan^)
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var corr = Expr.correlated_subquery(inner_filtered^, refs^, CORR_KIND_EXISTS)
    var plan = LogicalPlan.filter(corr^, outer^)

    var lowered = flatten_dependent_joins(plan^)

    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_SEMI)
    # The hoist should have produced (c_custkey, o_custkey) as the join keys.
    assert_equal(len(lowered._join.value()[].left_on), 1)
    assert_equal(lowered._join.value()[].left_on[0], String("c_custkey"))
    assert_equal(lowered._join.value()[].right_on[0], String("o_custkey"))
    # The inner-side filter should have been consumed entirely — the
    # join's right child should be the bare Scan (not a Filter).
    ref right_side = lowered._join.value()[].right[]
    assert_equal(right_side.tag, PLAN_SCAN)
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 6: UnresolvedOuterRef negative test
# =============================================================================


def test_unresolved_outer_ref_raises() raises:
    """An outer_ref that does NOT appear in the parent's output_schema
    must raise `UnresolvedOuterRef: <name>`.
    """
    var outer = _make_outer_scan()  # has c_custkey, c_nationkey
    var inner = _make_inner_scan()
    var refs = List[String]()
    refs.append(String("not_a_real_column"))  # NOT in outer schema
    var corr = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    var plan = LogicalPlan.filter(corr^, outer^)

    var raised = False
    try:
        var _lowered = flatten_dependent_joins(plan^)
    except e:
        var msg = String(e)
        if msg.find("UnresolvedOuterRef") >= 0:
            raised = True
    assert_true(raised)


# =============================================================================
# Test 7: Nested correlated subquery (subquery in subquery)
# =============================================================================


def test_nested_correlated_subquery() raises:
    """The inner plan ITSELF contains a correlated subquery. After
    `flatten_dependent_joins` returns, the outer correlation AND the
    inner correlation should both be lowered (the lowering flattens the
    subquery's inner plan before it builds the join).

    Shape:
      Filter(outer, EXISTS(
        Filter(orders, EXISTS(
          inner_scan, [o_custkey]
        )), [c_custkey]
      ))
    """
    var outer = _make_outer_scan()

    # Innermost: lineitem-shaped scan we'll correlate orders -> lineitem on.
    var innermost = _make_inner_scan_q20()
    var inner_refs = List[String]()
    inner_refs.append(String("o_custkey"))  # orders.o_custkey corr to inner
    # The inner correlation: a scan whose parent Filter holds an
    # EXISTS-correlated reference back to orders.
    # We need orders.o_custkey to be in scope at the EXISTS-site.
    # Build an inner subquery whose parent schema (orders) has o_custkey.
    var middle_scan = _make_inner_scan()  # orders(o_orderkey, o_custkey)
    var inner_corr = Expr.correlated_subquery(
        innermost^, inner_refs^, CORR_KIND_EXISTS,
    )
    var middle_filter = LogicalPlan.filter(inner_corr^, middle_scan^)

    var outer_refs = List[String]()
    outer_refs.append(String("c_custkey"))
    # Outer correlation: customer.c_custkey -> middle_filter.
    # Note: the outer-correlation outer_ref c_custkey isn't in middle_scan's
    # schema, but that's fine — the inner plan's outer_refs are validated
    # against the OUTER's parent schema, not the inner's schema.
    var outer_corr = Expr.correlated_subquery(
        middle_filter^, outer_refs^, CORR_KIND_EXISTS,
    )
    var plan = LogicalPlan.filter(outer_corr^, outer^)

    var lowered = flatten_dependent_joins(plan^)

    # Both correlations should be lowered.
    assert_false(_plan_contains_correlated_subquery(lowered))
    # Root is the outer-correlation lowered into a SEMI join.
    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_SEMI)


# =============================================================================
# Idempotence: a plan with NO correlated subqueries is unchanged.
# =============================================================================


def test_idempotent_no_correlation() raises:
    """A plan containing no correlated subqueries should pass through
    unchanged (structurally; we check the tag survives)."""
    var outer = _make_outer_scan()
    var lowered = flatten_dependent_joins(outer^)
    # Scan -> Scan.
    assert_equal(lowered.tag, PLAN_SCAN)


def main() raises:
    test_exists_lowers_to_semi_join()
    test_not_exists_lowers_to_anti_join()
    test_scalar_lowers_to_left_join_with_agg_sink()
    test_multi_key_outer_refs_q20()
    test_outer_ref_hoist_promotes_eq_predicate_to_join_keys()
    test_unresolved_outer_ref_raises()
    test_nested_correlated_subquery()
    test_idempotent_no_correlation()
    print("All flatten_dependent_joins tests passed.")

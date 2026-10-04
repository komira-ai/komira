"""resolve_scalar_subqueries detection tests.

Covers the SCANNER + the per-call cache shape (the materialize driver lives
in the SDK, see the module-doc of `resolve_scalar_subqueries.mojo`).

Coverage:
  Test 1: uncorrelated SCALAR (outer_refs == []) is detected.
  Test 2: correlated SCALAR (outer_refs != []) is NOT detected -- those
          belong to `flatten_dependent_joins` (B.k.2), not this pass.
  Test 3: the pass returns the plan unchanged (the shell is non-mutating).
"""

from std.testing import assert_equal, assert_true

from komira_core.arrow.schema import SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.expr import (
    Expr,
    BIN_GT,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.agg_expr import AggExpr, AGG_SUM
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    CORR_KIND_SCALAR,
)

from komira_compiler.resolve_scalar_subqueries import (
    resolve_scalar_subqueries,
    find_uncorrelated_scalar_subqueries,
)


def _make_lineitem() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_quantity"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(
        String("lineitem.parquet"), SOURCE_PARQUET, schema^
    )


def _make_orders() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("o_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("o_custkey"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(
        String("orders.parquet"), SOURCE_PARQUET, schema^
    )


def test_uncorrelated_scalar_subquery_detected() raises:
    """An EXPR_CORRELATED_SUBQUERY with kind=SCALAR and no outer_refs is
    detected as an uncorrelated-scalar candidate.

    Plan shape:
        Filter(
          lineitem.scan,
          l_quantity > (corr_subq[SCALAR, outer_refs=[]] over
            Aggregate(scan(orders), [], [SUM(o_custkey)]))
        )
    """
    var inner_aggs = AggExprArray()
    inner_aggs.append(AggExpr(
        AGG_SUM,
        Optional(Expr.col_ref(String("o_custkey"))),
        Optional(String("__corr_scalar_0")),
    ))
    var inner_gb = ExprArray()
    var inner_plan = LogicalPlan.aggregate(
        inner_gb^, inner_aggs^, _make_orders()^
    )

    var empty_refs = List[String]()
    var corr = Expr.correlated_subquery(
        inner_plan^, empty_refs^, CORR_KIND_SCALAR
    )

    var pred = Expr.binary(
        BIN_GT, Expr.col_ref(String("l_quantity"))^, corr^
    )
    var plan = LogicalPlan.filter(pred^, _make_lineitem()^)

    var n = find_uncorrelated_scalar_subqueries(plan)
    assert_equal(n, 1)


def test_correlated_scalar_subquery_not_detected() raises:
    """An EXPR_CORRELATED_SUBQUERY with kind=SCALAR and a non-empty
    outer_refs list is NOT counted -- it belongs to flatten_dependent_joins,
    not this pass.

    Plan shape: same as Test 1 but `outer_refs = [l_orderkey]`.
    """
    var inner_aggs = AggExprArray()
    inner_aggs.append(AggExpr(
        AGG_SUM,
        Optional(Expr.col_ref(String("o_custkey"))),
        Optional(String("__corr_scalar_1")),
    ))
    var inner_gb = ExprArray()
    var inner_plan = LogicalPlan.aggregate(
        inner_gb^, inner_aggs^, _make_orders()^
    )

    var refs = List[String]()
    refs.append(String("l_orderkey"))
    var corr = Expr.correlated_subquery(
        inner_plan^, refs^, CORR_KIND_SCALAR
    )

    var pred = Expr.binary(
        BIN_GT, Expr.col_ref(String("l_quantity"))^, corr^
    )
    var plan = LogicalPlan.filter(pred^, _make_lineitem()^)

    var n = find_uncorrelated_scalar_subqueries(plan)
    assert_equal(n, 0)


def test_pass_returns_plan_unchanged() raises:
    """The no-execution form is non-mutating; the returned plan must structurally
    equal the input.
    """
    var p = _make_lineitem()
    var before_h = p.structural_hash()
    var after = resolve_scalar_subqueries(p^)
    assert_equal(after.structural_hash(), before_h)


def main() raises:
    test_uncorrelated_scalar_subquery_detected()
    test_correlated_scalar_subquery_not_detected()
    test_pass_returns_plan_unchanged()
    print("test_resolve_scalar_subqueries: all 3 cases PASS")

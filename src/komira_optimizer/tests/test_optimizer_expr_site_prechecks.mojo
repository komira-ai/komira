# =============================================================================
# test_optimizer_expr_site_prechecks -- the three prechecks the driver reads
# before `fold_constants`, `simplify_predicates` and `rewrite_in_clauses`
# =============================================================================
#
# Each precheck walks `optimizer_expr._walk_expr_sites`, the walk its pass
# rewrites through, and answers True when some site holds work for the rule
# (for the IN rewrite: when the plan holds a site at all). A site the precheck
# skipped would leave the pass unrun on a plan whose only work sits there, so
# each test puts the one piece of work at one site and asks all three.
#
# `F` is a foldable expression (`a + (1 + 2)`), `S` a simplifiable one
# (`(a > 1) AND true`), `C` neither (`a > 1`).
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT, BIN_AND
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT, AGG_CORR
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
)
from komira_optimizer.optimizer_expr import (
    _plan_has_foldable_exprs,
    _plan_has_simplifiable_exprs,
    _plan_has_in_sites,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _c(name: String) -> Expr:
    return Expr.col_ref(name)


def _i(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _F() -> Expr:
    return Expr.binary(BIN_ADD, _c("a"), Expr.binary(BIN_ADD, _i(1), _i(2)))


def _S() -> Expr:
    return Expr.binary(BIN_AND, Expr.binary(BIN_GT, _c("a"), _i(1)), Expr.literal(ScalarValue.from_bool(True)))


def _C() -> Expr:
    return Expr.binary(BIN_GT, _c("a"), _i(1))


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    return sb.build()


def _scan(var filter: Optional[Expr] = None) -> LogicalPlan:
    return LogicalPlan.scan("s.parquet", SOURCE_PARQUET, _schema(), None, filter^)


def _answers(var p: LogicalPlan) -> String:
    """The three prechecks on `p`, as `fold simplify in` with 1 for True."""
    var s = String("")
    s += "1" if _plan_has_foldable_exprs(p) else "0"
    s += " 1" if _plan_has_simplifiable_exprs(p) else " 0"
    s += " 1" if _plan_has_in_sites(p) else " 0"
    return s^


def _project(var e0: Expr, var e1: Expr, var child: LogicalPlan) -> LogicalPlan:
    var pe = ExprArray()
    pe.append(e0^)
    pe.append(e1^)
    return LogicalPlan.project(pe^, child^)


def _agg_slot(k: Int, var e: Expr) -> LogicalPlan:
    """`Aggregate(CORR(a, a))` over a bare scan, with `e` in argument slot
    `k` (slots 2 and 3 are set after construction; no constructor takes four
    inputs)."""
    var a0 = AggExpr(AGG_CORR, Optional(_c("a")), Optional(_c("b")), Optional(String("k")))
    if k == 0:
        a0.child = Optional(e^)
    elif k == 1:
        a0.child1 = Optional(e^)
    elif k == 2:
        a0.child2 = Optional(e^)
    else:
        a0.child3 = Optional(e^)
    var aggs = AggExprArray()
    aggs.append(a0^)
    return LogicalPlan.aggregate(ExprArray(), aggs^, _scan())


def _count_star(var key: Expr, var child: LogicalPlan) -> LogicalPlan:
    """`Aggregate(group_by=[key], COUNT(*))`: no argument slot is filled."""
    var gb = ExprArray()
    gb.append(key^)
    var none: Optional[Expr] = None
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, none^, Optional(String("n"))))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _join(var left: LogicalPlan, var right: LogicalPlan, var residual: Optional[Expr]) -> LogicalPlan:
    var lon: List[String] = ["a"]
    var ron: List[String] = ["a"]
    var r: Optional[OwnedPointer[Expr]] = None
    if residual:
        r = OwnedPointer(residual.take())
    return LogicalPlan.join(left^, right^, lon^, ron^, JOIN_INNER, residual=r^)


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s^


# -----------------------------------------------------------------------------
# One site at a time
# -----------------------------------------------------------------------------


def test_a_scan_filter_is_a_site_for_fold_and_simplify_only() raises:
    """Catches: the Scan arm skipped by a precheck (mutant: the arm returns
    False when not rewriting), and the IN precheck reading a scan filter,
    which `rewrite_in_clauses` does not rewrite (mutant: the
    `rule != _SITE_RULE_IN` guard dropped)."""
    assert_equal(_answers(_scan(_F())), "1 0 0")
    assert_equal(_answers(_scan(_S())), "0 1 0")
    assert_equal(_answers(_scan(_C())), "0 0 0")
    assert_equal(_answers(_scan()), "0 0 0")


def test_a_filter_predicate_is_a_site() raises:
    """Catches: the Filter predicate skipped by a precheck (mutant: the
    predicate visited only when rewriting)."""
    assert_equal(_answers(LogicalPlan.filter(_F(), _scan())), "1 0 1")
    assert_equal(_answers(LogicalPlan.filter(_S(), _scan())), "0 1 1")
    assert_equal(_answers(LogicalPlan.filter(_C(), _scan())), "0 0 1")


def test_every_project_expression_is_a_site() raises:
    """Catches: a precheck reading only the first Project expression, or
    none (mutant: the expression loop run only when rewriting)."""
    assert_equal(_answers(_project(_C(), _F(), _scan())), "1 0 1")
    assert_equal(_answers(_project(_C(), _S(), _scan())), "0 1 1")
    assert_equal(_answers(_project(_C(), _C(), _scan())), "0 0 1")


def test_a_site_below_a_filter_project_or_aggregate_is_read() raises:
    """Catches: a precheck that stops at a Filter, Project or Aggregate
    instead of reading the scan filter under it (mutant: the child's True
    not returned)."""
    assert_equal(_answers(LogicalPlan.filter(_C(), _scan(_F()))), "1 0 1")
    assert_equal(_answers(_project(_C(), _C(), _scan(_S()))), "0 1 1")
    assert_equal(_answers(_count_star(_c("a"), _scan(_F()))), "1 0 0")


def test_every_aggregate_argument_slot_is_a_site() raises:
    """Catches: komira#1306's Aggregate half, a precheck skipping an
    aggregate function's argument slot 0, 1, 2 or 3 (mutant per slot: the
    slot visited only when rewriting)."""
    for k in range(4):
        assert_equal(_answers(_agg_slot(k, _F())), "1 0 1", "slot " + String(k))
        assert_equal(_answers(_agg_slot(k, _S())), "0 1 1", "slot " + String(k))
        assert_equal(_answers(_agg_slot(k, _C())), "0 0 1", "slot " + String(k))


def test_group_by_keys_and_count_star_hold_no_site() raises:
    """Catches: a precheck reading an Aggregate's group-by keys, which no
    pass rewrites, or treating COUNT(*)'s empty slots as sites."""
    assert_equal(_answers(_count_star(_F(), _scan())), "0 0 0")
    assert_equal(_answers(_count_star(_S(), _scan())), "0 0 0")


def test_a_join_residual_is_a_site() raises:
    """Catches: komira#1306's Join half, a precheck skipping the residual
    condition (mutant: the residual visited only when rewriting), and a
    precheck reading a residual the Join does not have."""
    assert_equal(_answers(_join(_scan(), _scan(), Optional(_F()))), "1 0 1")
    assert_equal(_answers(_join(_scan(), _scan(), Optional(_S()))), "0 1 1")
    assert_equal(_answers(_join(_scan(), _scan(), Optional(_C()))), "0 0 1")
    assert_equal(_answers(_join(_scan(), _scan(), Optional[Expr]())), "0 0 0")


def test_both_join_children_are_read() raises:
    """Catches: a precheck reading only one child of a Join (mutant per
    side: the child's True not returned)."""
    assert_equal(_answers(_join(_scan(_F()), _scan(), Optional[Expr]())), "1 0 0")
    assert_equal(_answers(_join(_scan(), _scan(_S()), Optional[Expr]())), "0 1 0")
    assert_equal(_answers(_join(_scan(), LogicalPlan.filter(_C(), _scan()), Optional[Expr]())), "0 0 1")


def test_the_walk_descends_sort_limit_distinct_topn_and_stops_at_union() raises:
    """Catches: a precheck that stops at a Sort, Limit, Distinct or TopN,
    and one that reads under a Union, which none of the passes rewrites."""
    var sk: List[String] = ["a"]
    var sd: List[Bool] = [False]
    assert_equal(_answers(LogicalPlan.sort(sk.copy(), sd.copy(), _scan(_F()))), "1 0 0")
    assert_equal(_answers(LogicalPlan.limit(10, _scan(_S()))), "0 1 0")
    assert_equal(_answers(LogicalPlan.distinct(None, LogicalPlan.filter(_C(), _scan()))), "0 0 1")
    assert_equal(_answers(LogicalPlan.topn(sk.copy(), sd.copy(), 5, _scan(_F()))), "1 0 0")
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(LogicalPlan.filter(_F(), _scan(_S()))))
    assert_equal(_answers(LogicalPlan.union(children^, _schema())), "0 0 0")


def test_a_precheck_changes_nothing() raises:
    """Catches: a precheck that rewrites while it reads (mutant: the check
    walk instantiated with `rewrite` True). Every site of this plan holds
    work, and its render is the same after all three prechecks."""
    var p = _join(
        LogicalPlan.filter(_F(), _project(_S(), _F(), _scan(_S()))),
        _agg_slot(0, _F()),
        Optional(_S()),
    )
    var before = _render(p)
    assert_true(_plan_has_foldable_exprs(p))
    assert_true(_plan_has_simplifiable_exprs(p))
    assert_true(_plan_has_in_sites(p))
    assert_equal(_render(p), before)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

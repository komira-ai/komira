"""Branch tests of `komira_optimizer.flatten_dependent_joins`.

`test_flatten_dependent_joins` and `test_correlated_subquery_lowerings` cover
the EXISTS / NOT EXISTS / SCALAR lowerings over a Filter at the plan root.
These tests reach the rest: the walk under every node kind, the AND-chain
lowering, `IN (subquery)`, the side-aware hoist that keeps a non-equi
correlation as a join residual, the refusals, and each expression walker
per expression kind. Each test names the defect it catches.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_LITERAL,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_STRING_OP,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_GT,
    BIN_AND,
    UN_NOT,
    UN_IS_NOT_NULL,
    STR_CONTAINS,
    COL_SIDE_NONE,
    COL_SIDE_LEFT,
    COL_SIDE_RIGHT,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    SOURCE_PARQUET,
    CORR_KIND_EXISTS,
    CORR_KIND_NOT_EXISTS,
    CORR_KIND_SCALAR,
    JOIN_INNER,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_LEFT,
)

from komira_optimizer.flatten_dependent_joins import (
    flatten_dependent_joins,
    flatten_dependent_joins_inplace,
    _expr_contains_correlated_subquery,
    _expr_collect_column_names,
    _plan_contains_correlated_subquery,
    _expr_has_side_qualifier,
    _expr_references_outer_side,
    _rewrite_inner_none_to_right,
    _try_lift_side_equi,
    _lower_correlated_into_join,
)
from komira_optimizer.join_predicate_decompose import join_predicate_decompose


# =============================================================================
# Fixtures
# =============================================================================


def _scan(path: String, var cols: List[String]) -> LogicalPlan:
    var sb = SchemaBuilder()
    for i in range(len(cols)):
        sb.add_field(Field(cols[i], ArrowType.INT64, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _l(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _l2(a: String, b: String) -> List[String]:
    var out = _l(a)
    out.append(b)
    return out^


def _customer() -> LogicalPlan:
    return _scan("customer.parquet", _l2("c_custkey", "c_nationkey"))


def _orders() -> LogicalPlan:
    return _scan("orders.parquet", _l2("o_orderkey", "o_custkey"))


def _corr(kind: UInt8) -> Expr:
    """A subquery over orders correlated on c_custkey (bare inner scan)."""
    return Expr.correlated_subquery(_orders(), _l("c_custkey"), kind)


def _scalar_corr() -> Expr:
    """SCALAR subquery: `sum(o_orderkey)` over orders, correlated on c_custkey."""
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("o_orderkey")), Optional(String("s"))))
    var agg = LogicalPlan.aggregate(ExprArray(), aggs^, _orders())
    return Expr.correlated_subquery(agg^, _l("c_custkey"), CORR_KIND_SCALAR)


def _gt0(col: String) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(0)))


def _exists_filter() -> LogicalPlan:
    return LogicalPlan.filter(_corr(CORR_KIND_EXISTS), _customer())


def _raises_with(var plan: LogicalPlan, needle: String) raises -> Bool:
    try:
        _ = flatten_dependent_joins(plan^)
    except e:
        return String(e).find(needle) >= 0
    return False


# =============================================================================
# The plan walk
# =============================================================================


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    var desc = List[Bool]()
    desc.append(False)
    if kind == 0:
        var exprs = ExprArray()
        exprs.append(Expr.col_ref("c_custkey"))
        return LogicalPlan.project(exprs^, child^)
    if kind == 1:
        var gb = ExprArray()
        gb.append(Expr.col_ref("c_custkey"))
        return LogicalPlan.aggregate(gb^, AggExprArray(), child^)
    if kind == 2:
        return LogicalPlan.sort(_l("c_custkey"), desc^, child^)
    if kind == 3:
        return LogicalPlan.limit(5, child^)
    if kind == 4:
        return LogicalPlan.distinct(None, child^)
    if kind == 5:
        return LogicalPlan.topn(_l("c_custkey"), desc^, 5, child^)
    if kind == 6:
        return LogicalPlan.join(child^, _orders(), _l("c_custkey"), _l("o_custkey"), JOIN_INNER)
    if kind == 7:
        return LogicalPlan.join(_orders(), child^, _l("o_custkey"), _l("c_custkey"), JOIN_INNER)
    if kind == 8:
        return LogicalPlan.partition_by(
            _l("c_custkey"), _l("c_custkey"), desc^, List[PartitionExpr](), child^
        )
    if kind == 9:
        return LogicalPlan.partition_topn(_l("c_custkey"), _l("c_custkey"), desc^, 1, child^)
    raise Error("test: unknown wrapper kind " + String(kind))


def _child_of(plan: LogicalPlan, kind: Int) -> LogicalPlan:
    if kind == 0:
        return plan._project.value()[].child[].copy()
    if kind == 1:
        return plan._aggregate.value()[].child[].copy()
    if kind == 2:
        return plan._sort.value()[].child[].copy()
    if kind == 3:
        return plan._limit.value()[].child[].copy()
    if kind == 4:
        return plan._distinct.value()[].child[].copy()
    if kind == 5:
        return plan._topn.value()[].child[].copy()
    if kind == 6:
        return plan._join.value()[].left[].copy()
    if kind == 7:
        return plan._join.value()[].right[].copy()
    if kind == 8:
        return plan._partition_by.value()[].child[].copy()
    return plan._partition_topn.value()[].child[].copy()


def test_walk_lowers_under_every_node_kind() raises:
    """`Filter(EXISTS)` under Project, Aggregate, Sort, Limit, Distinct,
    TopN, either input of a Join, PartitionBy and PartitionTopN is lowered
    to a SEMI join. For the kinds the invariant check walks (all but the two
    partition kinds) it reports the subquery before and not after.

    Catches: any one recursion arm of the walk removed (that subquery stays
    in the plan unlowered); a Join arm walking one input only; any one arm
    of `_plan_contains_correlated_subquery` removed (it misses the subquery
    before lowering)."""
    for kind in range(10):
        var plan = _wrap(kind, _exists_filter())
        if kind < 8:
            assert_true(_plan_contains_correlated_subquery(plan))
        flatten_dependent_joins_inplace(plan)
        assert_false(_plan_contains_correlated_subquery(plan))
        var lowered = _child_of(plan, kind)
        assert_equal(lowered.tag, PLAN_JOIN)
        assert_equal(lowered._join.value()[].join_type, JOIN_SEMI)


def test_project_with_a_subquery_expression_raises() raises:
    """A Project whose expression holds a subquery raises the "not yet
    supported" error; the invariant check sees the subquery in a Project
    expression.

    Catches: the Project lowering silently leaving the subquery in place;
    the check's Project arm not looking at the expressions."""
    var exprs = ExprArray()
    exprs.append(Expr.alias(_scalar_corr(), "x"))
    var plan = LogicalPlan.project(exprs^, _customer())
    assert_true(_plan_contains_correlated_subquery(plan))
    assert_true(_raises_with(plan^, "correlated subquery in Project not yet supported"))


# =============================================================================
# Filter shapes
# =============================================================================


def test_and_chain_stacks_semi_and_anti_joins_over_a_filter() raises:
    """`c_nationkey > 0 AND EXISTS(..) AND NOT EXISTS(..)` becomes
    `Anti(Semi(Filter(c_nationkey > 0, customer), ..), ..)`: the plain
    conjunct sits directly over the child and each subquery adds one join
    in conjunct order. Without a plain conjunct the Semi join sits directly
    on the scan.

    Catches: the plain conjunct dropped or put above the joins; the joins
    built in reverse order; a join kind swapped; an empty Filter left over
    the scan when no plain conjunct exists."""
    var pred = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_AND, _gt0("c_nationkey"), _corr(CORR_KIND_EXISTS)),
        _corr(CORR_KIND_NOT_EXISTS),
    )
    var out = flatten_dependent_joins(LogicalPlan.filter(pred^, _customer()))
    assert_equal(out.tag, PLAN_JOIN)
    assert_equal(out._join.value()[].join_type, JOIN_ANTI)
    ref semi = out._join.value()[].left[]
    assert_equal(semi.tag, PLAN_JOIN)
    assert_equal(semi._join.value()[].join_type, JOIN_SEMI)
    ref base = semi._join.value()[].left[]
    assert_equal(base.tag, PLAN_FILTER)
    assert_equal(base._filter.value()[].child[].tag, PLAN_SCAN)

    var pred2 = Expr.binary(BIN_AND, _corr(CORR_KIND_EXISTS), _corr(CORR_KIND_NOT_EXISTS))
    var out2 = flatten_dependent_joins(LogicalPlan.filter(pred2^, _customer()))
    assert_equal(out2._join.value()[].join_type, JOIN_ANTI)
    assert_equal(out2._join.value()[].left[]._join.value()[].left[].tag, PLAN_SCAN)


def test_and_chain_with_a_nested_subquery_raises() raises:
    """`c_nationkey > (scalar subquery) AND EXISTS(..)` raises: a subquery
    inside an AND-chain conjunct is refused.

    Catches: the nested conjunct treated as plain (the subquery would then
    sit in the residual Filter, unlowered)."""
    var pred = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_GT, Expr.col_ref("c_nationkey"), _scalar_corr()),
        _corr(CORR_KIND_EXISTS),
    )
    assert_true(_raises_with(LogicalPlan.filter(pred^, _customer()), "nested inside an AND-chain"))


def test_scalar_subquery_on_the_left_of_a_comparison() raises:
    """`(scalar subquery) < c_nationkey` becomes
    `Filter(__corr_scalar_0 < c_nationkey, LeftJoin(customer, Aggregate))`:
    the subquery operand is replaced by the aggregate's output column and
    the other operand and the operator are kept.

    Catches: the left-operand branch removed (this shape then raises);
    operands swapped in the rewritten comparison; the operator replaced."""
    var pred = Expr.binary(BIN_LT, _scalar_corr(), Expr.col_ref("c_nationkey"))
    var out = flatten_dependent_joins(LogicalPlan.filter(pred^, _customer()))
    assert_equal(out.tag, PLAN_FILTER)
    ref p = out._filter.value()[].predicate
    assert_equal(p.binary_op(), BIN_LT)
    assert_equal(p.binary_left_ref().col_ref_name(), String("__corr_scalar_0"))
    assert_equal(p.binary_right_ref().col_ref_name(), String("c_nationkey"))
    ref j = out._filter.value()[].child[]
    assert_equal(j._join.value()[].join_type, JOIN_LEFT)
    ref agg = j._join.value()[].right[]
    assert_equal(agg.tag, PLAN_AGGREGATE)
    assert_equal(len(agg._aggregate.value()[].group_by), 1)


def test_unsupported_filter_shapes_raise() raises:
    """Refused shapes, each with its own message: a comparison with an
    EXISTS on the right or on the left; `NOT EXISTS` written as a NOT over
    EXISTS; a comparison of two scalar subqueries; a subquery nested below
    the comparison's direct operand.

    Catches: a non-SCALAR kind lowered as a scalar (its result column does
    not exist); an unsupported shape returning with the subquery still in
    the plan instead of raising."""
    var rhs = Expr.binary(BIN_GT, Expr.col_ref("c_nationkey"), _corr(CORR_KIND_EXISTS))
    assert_true(_raises_with(LogicalPlan.filter(rhs^, _customer()), "non-SCALAR correlated RHS"))
    var lhs = Expr.binary(BIN_GT, _corr(CORR_KIND_EXISTS), Expr.col_ref("c_nationkey"))
    assert_true(_raises_with(LogicalPlan.filter(lhs^, _customer()), "non-SCALAR correlated LHS"))
    var un = Expr.unary(UN_NOT, _corr(CORR_KIND_EXISTS))
    assert_true(_raises_with(LogicalPlan.filter(un^, _customer()), "unsupported parent-shape"))
    var both = Expr.binary(BIN_LT, _scalar_corr(), _scalar_corr())
    assert_true(_raises_with(LogicalPlan.filter(both^, _customer()), "unsupported parent-shape"))
    var deep = Expr.binary(
        BIN_GT, Expr.col_ref("c_nationkey"),
        Expr.binary(BIN_GT, _scalar_corr(), Expr.literal(ScalarValue.from_int(1))),
    )
    assert_true(_raises_with(LogicalPlan.filter(deep^, _customer()), "unsupported parent-shape"))


# =============================================================================
# Lowering per kind
# =============================================================================


def test_in_subquery_appends_its_key_after_the_correlation_keys() raises:
    """`c_custkey IN (SELECT o_custkey FROM orders)` correlated on
    c_nationkey becomes a SEMI join on (c_nationkey, c_custkey) =
    (c_nationkey, o_custkey); an IN whose left column is not in the outer
    schema raises `UnresolvedOuterRef` naming it.

    Catches: IN lowered to a join kind other than SEMI; the IN key not
    appended, or put before the correlation keys; the IN left column not
    validated."""
    var e = Expr.in_correlated_subquery(_orders(), _l("c_nationkey"), "c_custkey", "o_custkey")
    var out = flatten_dependent_joins(LogicalPlan.filter(e^, _customer()))
    ref j = out._join.value()[]
    assert_equal(j.join_type, JOIN_SEMI)
    assert_equal(len(j.left_on), 2)
    assert_equal(j.left_on[0], String("c_nationkey"))
    assert_equal(j.left_on[1], String("c_custkey"))
    assert_equal(j.right_on[0], String("c_nationkey"))
    assert_equal(j.right_on[1], String("o_custkey"))

    var bad = Expr.in_correlated_subquery(_orders(), List[String](), "nope", "o_custkey")
    assert_true(_raises_with(LogicalPlan.filter(bad^, _customer()), "UnresolvedOuterRef: nope"))


def test_bare_scalar_kind_and_unknown_kind() raises:
    """A SCALAR subquery used directly as the Filter predicate lowers to a
    LEFT join; a subquery of an unknown kind (77) raises naming the kind.

    Catches: the SCALAR arm of the kind switch removed (it then raises as
    unknown); an unknown kind lowered to some join instead of refused."""
    var out = flatten_dependent_joins(LogicalPlan.filter(_scalar_corr(), _customer()))
    assert_equal(out._join.value()[].join_type, JOIN_LEFT)
    var odd = Expr.correlated_subquery(_orders(), _l("c_custkey"), UInt8(77))
    assert_true(_raises_with(LogicalPlan.filter(odd^, _customer()), "unknown correlated-subquery kind: 77"))


def test_lowering_with_a_residual_predicate_wraps_the_join() raises:
    """`_lower_correlated_into_join` given a residual predicate returns
    `Filter(residual, Semi(..))`; given None, the bare join.

    Catches: the residual predicate dropped."""
    var outer = _customer()
    var corr = _corr(CORR_KIND_EXISTS)
    var out = _lower_correlated_into_join(outer^, corr, Optional(_gt0("c_nationkey")))
    assert_equal(out.tag, PLAN_FILTER)
    assert_equal(out._filter.value()[].child[]._join.value()[].join_type, JOIN_SEMI)
    var out2 = _lower_correlated_into_join(_customer(), corr, None)
    assert_equal(out2.tag, PLAN_JOIN)


def test_scalar_refusals() raises:
    """A SCALAR subquery is refused when it has a non-equi correlation
    (`c_custkey < o_custkey` written with an outer-side ref), when its inner
    Aggregate has two aggregates, and when its inner plan has no columns.

    Catches: the non-equi correlation dropped from a scalar subquery (wrong
    answers); the first of two aggregates silently used; a MEAN over a
    column that does not exist."""
    var nonequi = LogicalPlan.filter(
        Expr.binary(BIN_LT, Expr.left("c_custkey"), Expr.col_ref("o_custkey")), _orders()
    )
    var c1 = Expr.correlated_subquery(nonequi^, _l("c_custkey"), CORR_KIND_SCALAR)
    var p1 = Expr.binary(BIN_GT, Expr.col_ref("c_nationkey"), c1^)
    assert_true(_raises_with(LogicalPlan.filter(p1^, _customer()), "non-equi correlation in a scalar"))

    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("o_orderkey")), Optional(String("s"))))
    aggs.append(AggExpr(AGG_MAX, Optional(Expr.col_ref("o_orderkey")), Optional(String("m"))))
    var two = LogicalPlan.aggregate(ExprArray(), aggs^, _orders())
    var c2 = Expr.correlated_subquery(two^, _l("c_custkey"), CORR_KIND_SCALAR)
    var p2 = Expr.binary(BIN_GT, Expr.col_ref("c_nationkey"), c2^)
    assert_true(_raises_with(LogicalPlan.filter(p2^, _customer()), "exactly 1 agg expr"))

    var empty = _scan("empty.parquet", List[String]())
    var c3 = Expr.correlated_subquery(empty^, _l("c_custkey"), CORR_KIND_SCALAR)
    var p3 = Expr.binary(BIN_GT, Expr.col_ref("c_nationkey"), c3^)
    assert_true(_raises_with(LogicalPlan.filter(p3^, _customer()), "no output columns"))


# =============================================================================
# The outer-ref hoist
# =============================================================================


def test_name_hoist_swapped_and_unhoistable_conjuncts() raises:
    """Name-based hoist (plain refs): `o_custkey = c_custkey` (outer ref on
    the right) lifts to (c_custkey, o_custkey) and the inner Filter goes
    away. A Filter whose conjuncts name no outer ref
    (`o_orderkey = o_custkey`, `o_orderkey > 0`, `o_custkey = 3`,
    `o_orderkey IS NOT NULL`) is kept whole on the inner side and the keys
    fall back to the outer refs.

    Catches: the swapped-operand branch removed or keyed in operand order;
    an EQ of two inner columns, a non-EQ, an EQ with a literal or a
    non-binary conjunct hoisted; kept conjuncts dropped when rebuilding the
    inner Filter."""
    var swapped = LogicalPlan.filter(
        Expr.binary(BIN_EQ, Expr.col_ref("o_custkey"), Expr.col_ref("c_custkey")), _orders()
    )
    var c1 = Expr.correlated_subquery(swapped^, _l("c_custkey"), CORR_KIND_EXISTS)
    var out = flatten_dependent_joins(LogicalPlan.filter(c1^, _customer()))
    ref j = out._join.value()[]
    assert_equal(j.left_on[0], String("c_custkey"))
    assert_equal(j.right_on[0], String("o_custkey"))
    assert_equal(j.right[].tag, PLAN_SCAN)

    var keep = Expr.binary(
        BIN_AND,
        Expr.binary(
            BIN_AND,
            Expr.binary(
                BIN_AND,
                Expr.binary(BIN_EQ, Expr.col_ref("o_orderkey"), Expr.col_ref("o_custkey")),
                _gt0("o_orderkey"),
            ),
            Expr.binary(BIN_EQ, Expr.col_ref("o_custkey"), Expr.literal(ScalarValue.from_int(3))),
        ),
        Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("o_orderkey")),
    )
    var inner = LogicalPlan.filter(keep^, _orders())
    var c2 = Expr.correlated_subquery(inner^, _l("c_custkey"), CORR_KIND_EXISTS)
    var out2 = flatten_dependent_joins(LogicalPlan.filter(c2^, _customer()))
    ref j2 = out2._join.value()[]
    assert_equal(j2.left_on[0], String("c_custkey"))
    assert_equal(j2.right_on[0], String("c_custkey"))
    ref rf = j2.right[]
    assert_equal(rf.tag, PLAN_FILTER)
    # Four conjuncts rebuilt as AND(AND(AND(c1, c2), c3), c4).
    ref p = rf._filter.value()[].predicate
    assert_equal(p.binary_op(), BIN_AND)
    assert_equal(p.binary_right_ref().tag, EXPR_UNARY_OP)
    ref p2 = p.binary_left_ref()
    assert_equal(p2.binary_op(), BIN_AND)
    ref p3 = p2.binary_left_ref()
    assert_equal(p3.binary_op(), BIN_AND)
    assert_equal(p3.binary_left_ref().binary_op(), BIN_EQ)


def test_side_aware_hoist_keeps_a_non_equi_correlation_as_residual() raises:
    """The self-correlated shape (outer refs marked LEFT by the binder):
    inner Filter over l3 with `left.l_orderkey = l_orderkey`,
    `l_suppkey <> left.l_suppkey`, `l_receiptdate > l_commitdate` and
    `left.l_suppkey < l_suppkey`. The EQ lifts to keys; the plain conjunct
    stays on the inner Filter; the two non-equi conjuncts become the join
    residual with the inner refs marked RIGHT. `join_predicate_decompose`
    then rewrites that residual to plain refs with `l_suppkey_right`.

    Catches: a non-equi correlation left on the inner Filter (it then
    compares l_suppkey with itself and the correlation is lost); the inner
    refs not re-marked RIGHT; the plain conjunct moved into the residual;
    only the first residual conjunct kept."""
    var l3cols = List[String]()
    l3cols.append("l_orderkey")
    l3cols.append("l_suppkey")
    l3cols.append("l_receiptdate")
    l3cols.append("l_commitdate")
    var l3 = _scan("l3.parquet", l3cols^)
    var pred = Expr.binary(
        BIN_AND,
        Expr.binary(
            BIN_AND,
            Expr.binary(
                BIN_AND,
                Expr.binary(BIN_EQ, Expr.left("l_orderkey"), Expr.col_ref("l_orderkey")),
                Expr.binary(BIN_NE, Expr.col_ref("l_suppkey"), Expr.left("l_suppkey")),
            ),
            Expr.binary(BIN_GT, Expr.col_ref("l_receiptdate"), Expr.col_ref("l_commitdate")),
        ),
        Expr.binary(BIN_LT, Expr.left("l_suppkey"), Expr.col_ref("l_suppkey")),
    )
    var inner = LogicalPlan.filter(pred^, l3^)
    var c = Expr.correlated_subquery(inner^, _l2("l_orderkey", "l_suppkey"), CORR_KIND_EXISTS)
    var l1 = _scan("l1.parquet", _l2("l_orderkey", "l_suppkey"))
    var out = flatten_dependent_joins(LogicalPlan.filter(c^, l1^))
    ref j = out._join.value()[]
    assert_equal(j.join_type, JOIN_SEMI)
    assert_equal(len(j.left_on), 1)
    assert_equal(j.left_on[0], String("l_orderkey"))
    assert_equal(j.right_on[0], String("l_orderkey"))
    assert_equal(j.right[].tag, PLAN_FILTER)
    assert_equal(j.right[]._filter.value()[].predicate.binary_op(), BIN_GT)
    assert_true(j.has_residual())
    ref r = j.residual.value()[]
    assert_equal(r.binary_op(), BIN_AND)
    ref ne = r.binary_left_ref()
    assert_equal(ne.binary_op(), BIN_NE)
    assert_equal(ne.binary_left_ref().col_ref_side(), COL_SIDE_RIGHT)
    assert_equal(ne.binary_right_ref().col_ref_side(), COL_SIDE_LEFT)
    ref lt = r.binary_right_ref()
    assert_equal(lt.binary_op(), BIN_LT)
    assert_equal(lt.binary_left_ref().col_ref_side(), COL_SIDE_LEFT)
    assert_equal(lt.binary_right_ref().col_ref_side(), COL_SIDE_RIGHT)

    var decomposed = join_predicate_decompose(out^)
    ref r2 = decomposed._join.value()[].residual.value()[]
    ref ne2 = r2.binary_left_ref()
    assert_equal(ne2.binary_left_ref().col_ref_name(), String("l_suppkey_right"))
    assert_equal(ne2.binary_left_ref().col_ref_side(), COL_SIDE_NONE)
    assert_equal(ne2.binary_right_ref().col_ref_name(), String("l_suppkey"))


def test_side_aware_hoist_with_only_an_equi_key_drops_the_inner_filter() raises:
    """A NOT EXISTS whose inner Filter is only `left.c_custkey = o_custkey`
    becomes an ANTI join on (c_custkey, o_custkey) over the bare scan, with
    no residual.

    Catches: an empty inner Filter built when nothing stays inner; a
    residual built from zero conjuncts."""
    var inner = LogicalPlan.filter(
        Expr.binary(BIN_EQ, Expr.col_ref("o_custkey"), Expr.left("c_custkey")), _orders()
    )
    var c = Expr.correlated_subquery(inner^, _l("c_custkey"), CORR_KIND_NOT_EXISTS)
    var out = flatten_dependent_joins(LogicalPlan.filter(c^, _customer()))
    ref j = out._join.value()[]
    assert_equal(j.join_type, JOIN_ANTI)
    assert_equal(j.left_on[0], String("c_custkey"))
    assert_equal(j.right_on[0], String("o_custkey"))
    assert_equal(j.right[].tag, PLAN_SCAN)
    assert_false(j.has_residual())


def test_try_lift_side_equi_shapes() raises:
    """`_try_lift_side_equi` lifts `left.a = b` and `b = left.a` (and
    `right.b = left.a`) as (a, b); it refuses a non-binary, a non-EQ, an EQ
    with a literal operand, and an EQ of two outer refs.

    Catches: either orientation removed or keyed in operand order; any
    refusal guard removed (a literal or two outer refs would become a join
    key)."""
    var lo = List[String]()
    var ro = List[String]()
    assert_true(_try_lift_side_equi(Expr.binary(BIN_EQ, Expr.left("a"), Expr.col_ref("b")), lo, ro))
    assert_true(_try_lift_side_equi(Expr.binary(BIN_EQ, Expr.col_ref("b"), Expr.left("a")), lo, ro))
    assert_true(_try_lift_side_equi(Expr.binary(BIN_EQ, Expr.right("b"), Expr.left("a")), lo, ro))
    assert_equal(len(lo), 3)
    for i in range(3):
        assert_equal(lo[i], String("a"))
        assert_equal(ro[i], String("b"))
    assert_false(_try_lift_side_equi(Expr.left("a"), lo, ro))
    assert_false(_try_lift_side_equi(Expr.binary(BIN_LT, Expr.left("a"), Expr.col_ref("b")), lo, ro))
    assert_false(_try_lift_side_equi(
        Expr.binary(BIN_EQ, Expr.left("a"), Expr.literal(ScalarValue.from_int(1))), lo, ro
    ))
    assert_false(_try_lift_side_equi(Expr.binary(BIN_EQ, Expr.left("a"), Expr.left("b")), lo, ro))
    assert_equal(len(lo), 3)


# =============================================================================
# Expression walkers, per expression kind
# =============================================================================


def _wrap_expr(kind: Int, var e: Expr) -> Expr:
    """`e` under a unary, cast, alias, string op, IN list or aggregate."""
    if kind == 0:
        return Expr.unary(UN_NOT, e^)
    if kind == 1:
        return Expr.cast(e^, DType.float64)
    if kind == 2:
        return Expr.alias(e^, "x")
    if kind == 3:
        return Expr.string_op(STR_CONTAINS, e^, "p")
    if kind == 4:
        var vals = List[ScalarValue]()
        vals.append(ScalarValue.from_int(1))
        return Expr.in_list_node(e^, vals^)
    return Expr.agg_fn(AGG_SUM, e^)


def test_expression_walkers_see_through_every_wrapper() raises:
    """Under each of unary, cast, alias, string op, IN list and aggregate:
    `_expr_contains_correlated_subquery` finds a subquery,
    `_expr_collect_column_names` collects the col-ref,
    `_expr_has_side_qualifier` finds a LEFT or RIGHT ref, and
    `_expr_references_outer_side` finds a LEFT ref but not a RIGHT one. The
    binary arms look at both operands; a literal answers False / nothing.

    Catches: any one arm of the four walkers removed (a subquery or outer
    ref under that wrapper goes unseen, so a correlation is lowered wrong
    or not at all); `_expr_references_outer_side` treating RIGHT as outer;
    a binary arm looking at one operand only."""
    for kind in range(6):
        assert_true(_expr_contains_correlated_subquery(_wrap_expr(kind, _corr(CORR_KIND_EXISTS))))
        assert_false(_expr_contains_correlated_subquery(_wrap_expr(kind, Expr.col_ref("a"))))
        var acc = List[String]()
        _expr_collect_column_names(_wrap_expr(kind, Expr.col_ref("a")), acc)
        assert_equal(len(acc), 1)
        assert_equal(acc[0], String("a"))
        assert_true(_expr_has_side_qualifier(_wrap_expr(kind, Expr.left("a"))))
        assert_true(_expr_has_side_qualifier(_wrap_expr(kind, Expr.right("a"))))
        assert_false(_expr_has_side_qualifier(_wrap_expr(kind, Expr.col_ref("a"))))
        assert_true(_expr_references_outer_side(_wrap_expr(kind, Expr.left("a"))))
        assert_false(_expr_references_outer_side(_wrap_expr(kind, Expr.right("a"))))

    var p = Expr.col_ref("p")
    var lit = Expr.literal(ScalarValue.from_int(1))
    assert_true(_expr_contains_correlated_subquery(
        Expr.binary(BIN_LT, _corr(CORR_KIND_EXISTS), p.copy())))
    assert_true(_expr_contains_correlated_subquery(
        Expr.binary(BIN_LT, p.copy(), _corr(CORR_KIND_EXISTS))))
    assert_false(_expr_contains_correlated_subquery(Expr.binary(BIN_LT, p.copy(), p.copy())))
    assert_false(_expr_contains_correlated_subquery(lit))
    var acc2 = List[String]()
    _expr_collect_column_names(Expr.binary(BIN_LT, Expr.col_ref("a"), Expr.col_ref("b")), acc2)
    _expr_collect_column_names(lit, acc2)
    assert_equal(len(acc2), 2)
    assert_equal(acc2[1], String("b"))
    assert_true(_expr_has_side_qualifier(Expr.binary(BIN_LT, Expr.left("a"), p.copy())))
    assert_true(_expr_has_side_qualifier(Expr.binary(BIN_LT, p.copy(), Expr.right("a"))))
    assert_false(_expr_has_side_qualifier(lit))
    assert_true(_expr_references_outer_side(Expr.binary(BIN_LT, Expr.left("a"), p.copy())))
    assert_true(_expr_references_outer_side(Expr.binary(BIN_LT, p.copy(), Expr.left("a"))))
    assert_false(_expr_references_outer_side(Expr.binary(BIN_LT, p.copy(), p.copy())))
    assert_false(_expr_references_outer_side(lit))


def test_rewrite_inner_none_to_right() raises:
    """`_rewrite_inner_none_to_right` keeps LEFT refs LEFT and marks plain
    and RIGHT refs RIGHT, inside a binary, a unary, a cast and a string op
    (keeping op, target and pattern); a literal copies through.

    Catches: an outer (LEFT) ref re-marked RIGHT (the correlation would
    then compare the inner column with itself); any one recursion arm
    removed; a wrapper rebuilt with a wrong payload."""
    var b = _rewrite_inner_none_to_right(Expr.binary(BIN_NE, Expr.left("a"), Expr.col_ref("b")))
    assert_equal(b.binary_op(), BIN_NE)
    assert_equal(b.binary_left_ref().col_ref_side(), COL_SIDE_LEFT)
    assert_equal(b.binary_left_ref().col_ref_name(), String("a"))
    assert_equal(b.binary_right_ref().col_ref_side(), COL_SIDE_RIGHT)
    assert_equal(b.binary_right_ref().col_ref_name(), String("b"))
    var r = _rewrite_inner_none_to_right(Expr.right("c"))
    assert_equal(r.col_ref_side(), COL_SIDE_RIGHT)

    var u = _rewrite_inner_none_to_right(Expr.unary(UN_NOT, Expr.col_ref("b")))
    assert_equal(u.tag, EXPR_UNARY_OP)
    assert_equal(u.unary_op(), UN_NOT)
    assert_equal(u.unary_child_ref().col_ref_side(), COL_SIDE_RIGHT)
    var c = _rewrite_inner_none_to_right(Expr.cast(Expr.col_ref("b"), DType.float64))
    assert_equal(c.tag, EXPR_CAST)
    assert_true(c.cast_target() == DType.float64)
    assert_equal(c.cast_child_ref().col_ref_side(), COL_SIDE_RIGHT)
    var s = _rewrite_inner_none_to_right(Expr.string_op(STR_CONTAINS, Expr.col_ref("b"), "zz"))
    assert_equal(s.tag, EXPR_STRING_OP)
    assert_equal(s.string_op_pattern(), String("zz"))
    assert_equal(s.string_op_child_ref().col_ref_side(), COL_SIDE_RIGHT)
    var l = _rewrite_inner_none_to_right(Expr.literal(ScalarValue.from_int(4)))
    assert_equal(l.tag, EXPR_LITERAL)
    assert_equal(l.literal_value().int_val, Int64(4))


def main() raises:
    test_walk_lowers_under_every_node_kind()
    test_project_with_a_subquery_expression_raises()
    test_and_chain_stacks_semi_and_anti_joins_over_a_filter()
    test_and_chain_with_a_nested_subquery_raises()
    test_scalar_subquery_on_the_left_of_a_comparison()
    test_unsupported_filter_shapes_raise()
    test_in_subquery_appends_its_key_after_the_correlation_keys()
    test_bare_scalar_kind_and_unknown_kind()
    test_lowering_with_a_residual_predicate_wraps_the_join()
    test_scalar_refusals()
    test_name_hoist_swapped_and_unhoistable_conjuncts()
    test_side_aware_hoist_keeps_a_non_equi_correlation_as_residual()
    test_side_aware_hoist_with_only_an_equi_key_drops_the_inner_filter()
    test_try_lift_side_equi_shapes()
    test_expression_walkers_see_through_every_wrapper()
    test_rewrite_inner_none_to_right()
    print("All flatten_dependent_joins branch tests passed.")

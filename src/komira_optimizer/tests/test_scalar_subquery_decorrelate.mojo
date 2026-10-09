# =============================================================================
# test_scalar_subquery_decorrelate -- single-row subqueries become CROSS joins
# =============================================================================
#
# An uncorrelated SCALAR subquery whose inner plan provably yields at most one
# row and one column is lowered to `Join(CROSS, child, Project(v AS
# __scalar_subq_N, inner))`, the subquery becomes `col_ref(__scalar_subq_N)`,
# and a Filter is wrapped in an identity Project so its output schema does
# not move. Anything else is left for the materialize-and-substitute pass.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_COL_REF,
    EXPR_CORRELATED_SUBQUERY,
    BIN_GT,
    BIN_EQ,
    BIN_AND,
    UN_NEGATE,
    STR_LIKE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    CORR_KIND_SCALAR,
    JOIN_CROSS,
    JOIN_INNER,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_JOIN,
    PLAN_SCAN,
)

from komira_optimizer.scalar_subquery_decorrelate import (
    scalar_subquery_decorrelate,
    scalar_subquery_decorrelate_inplace,
    SCALAR_SUBQ_COL_PREFIX,
    _DecorrSite,
    _expr_contains_decorrelatable_scalar,
    _find_site_col_for_hash,
    _restore_schema,
    _is_uncorrelated_scalar_subquery,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema1(col: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(col, ArrowType.INT64, False))
    return b.build()


def _customer() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("c_custkey"), ArrowType.INT64, False))
    b.add_field(Field(String("c_acctbal"), ArrowType.INT64, False))
    return LogicalPlan.scan(String("customer.parquet"), SOURCE_PARQUET, b.build())


def _orders() -> LogicalPlan:
    return LogicalPlan.scan(String("orders.parquet"), SOURCE_PARQUET, _schema1(String("o_total")))


def _global_agg(func: UInt8 = AGG_SUM) -> LogicalPlan:
    """`SELECT func(o_total) AS v FROM orders`: one row, one column."""
    var aggs = AggExprArray()
    aggs.append(AggExpr(func, Optional(Expr.col_ref(String("o_total"))), Optional(String("v"))))
    return LogicalPlan.aggregate(ExprArray(), aggs^, _orders())


def _grouped_agg() -> LogicalPlan:
    """One column, but one row PER GROUP: not provably single-row."""
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref(String("o_total"))), Optional(String("v"))))
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("o_total")))
    var agg = LogicalPlan.aggregate(gb^, aggs^, _orders())
    var pe = ExprArray()
    pe.append(Expr.col_ref(String("v")))
    return LogicalPlan.project(pe^, agg^)


def _subq_over(var inner: LogicalPlan) -> Expr:
    return Expr.correlated_subquery(inner^, List[String](), CORR_KIND_SCALAR)


def _subq(func: UInt8 = AGG_SUM) -> Expr:
    return _subq_over(_global_agg(func))


def _bal() -> Expr:
    return Expr.col_ref(String("c_acctbal"))


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _gt(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_GT, l^, r^)


def _and(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_AND, l^, r^)


def _names(imm plan: LogicalPlan) -> List[String]:
    var out = List[String]()
    for i in range(plan.output_schema.num_columns()):
        out.append(plan.output_schema.field_name(i))
    return out^


def _col(i: Int) -> String:
    return SCALAR_SUBQ_COL_PREFIX + String(i)


def _assert_filter_decorrelated(imm node: LogicalPlan) raises:
    """`node` is Project(identity, Filter(... col_ref(__scalar_subq_0) ...,
    Join(CROSS, customer, Project(v AS __scalar_subq_0, inner))))."""
    assert_equal(node.tag, PLAN_PROJECT)
    var names = _names(node)
    assert_equal(len(names), 2)
    assert_equal(names[0], String("c_custkey"))
    assert_equal(names[1], String("c_acctbal"))
    ref f = node.project_data_ref().child[]
    assert_equal(f.tag, PLAN_FILTER)
    ref j = f.filter_data_ref().child[]
    assert_equal(j.tag, PLAN_JOIN)
    assert_equal(Int(j.join_data_ref().join_type), Int(JOIN_CROSS))
    assert_equal(j.join_data_ref().left[].tag, PLAN_SCAN)
    ref r = j.join_data_ref().right[]
    assert_equal(r.tag, PLAN_PROJECT)
    assert_equal(r.output_schema.num_columns(), 1)
    assert_equal(r.output_schema.field_name(0), _col(0))


# =============================================================================
# The Filter rewrite
# =============================================================================


def test_a_filter_on_a_global_aggregate_becomes_a_cross_join() raises:
    # Catches: no rewrite; a JOIN type other than CROSS; the subquery left in
    # the predicate; the synthesized column escaping the Filter's schema.
    var plan = LogicalPlan.filter(_gt(_bal(), _subq()), _customer())
    var out = scalar_subquery_decorrelate(plan^)
    _assert_filter_decorrelated(out)
    ref pred = out.project_data_ref().child[].filter_data_ref().predicate
    assert_equal(pred.binary_right_ref().tag, EXPR_COL_REF)
    assert_equal(pred.binary_right_ref().col_ref_name(), _col(0))


def test_one_subquery_used_twice_is_one_join() raises:
    # Catches: de-dup by hash removed (two CROSS joins of the same aggregate).
    var pred = _and(_gt(_bal(), _subq()), _gt(_subq(), _bal()))
    var out = scalar_subquery_decorrelate(LogicalPlan.filter(pred^, _customer()))
    _assert_filter_decorrelated(out)
    ref p = out.project_data_ref().child[].filter_data_ref().predicate
    assert_equal(p.binary_left_ref().binary_right_ref().col_ref_name(), _col(0))
    assert_equal(p.binary_right_ref().binary_left_ref().col_ref_name(), _col(0))


def test_two_subqueries_chain_two_joins_left_deep() raises:
    # Catches: one name for two subqueries, or a chain that is not left-deep
    # (the second join's left must be the first join).
    var pred = _and(_gt(_bal(), _subq(AGG_SUM)), _gt(_bal(), _subq(AGG_MAX)))
    var out = scalar_subquery_decorrelate(LogicalPlan.filter(pred^, _customer()))
    assert_equal(out.tag, PLAN_PROJECT)
    assert_equal(len(_names(out)), 2)
    ref f = out.project_data_ref().child[]
    ref j1 = f.filter_data_ref().child[]
    assert_equal(Int(j1.join_data_ref().join_type), Int(JOIN_CROSS))
    assert_equal(j1.join_data_ref().right[].output_schema.field_name(0), _col(1))
    ref j0 = j1.join_data_ref().left[]
    assert_equal(j0.tag, PLAN_JOIN)
    assert_equal(j0.join_data_ref().right[].output_schema.field_name(0), _col(0))
    assert_equal(j0.join_data_ref().left[].tag, PLAN_SCAN)
    ref p = f.filter_data_ref().predicate
    assert_equal(p.binary_left_ref().binary_right_ref().col_ref_name(), _col(0))
    assert_equal(p.binary_right_ref().binary_right_ref().col_ref_name(), _col(1))


def test_single_row_proofs_through_limit_project_sort_distinct() raises:
    # LIMIT 1 is single-row; Project / Sort / Distinct over a global aggregate
    # are single-row. Catches: any of those arms answering False.
    var lim1 = LogicalPlan.limit(1, _orders())
    var out1 = scalar_subquery_decorrelate(
        LogicalPlan.filter(_gt(_bal(), _subq_over(lim1^)), _customer())
    )
    _assert_filter_decorrelated(out1)

    var pe = ExprArray()
    pe.append(Expr.col_ref(String("v")))
    var keys = List[String]()
    keys.append(String("v"))
    var desc = List[Bool]()
    desc.append(False)
    var chain = LogicalPlan.project(
        pe^,
        LogicalPlan.sort(keys^, desc^, LogicalPlan.distinct(None, _global_agg())),
    )
    var out2 = scalar_subquery_decorrelate(
        LogicalPlan.filter(_gt(_bal(), _subq_over(chain^)), _customer())
    )
    _assert_filter_decorrelated(out2)


def _not_single_row(c: Int) -> LogicalPlan:
    if c == 0:
        return LogicalPlan.limit(2, _orders())
    if c == 1:
        return _grouped_agg()
    if c == 2:
        return _orders()
    return _customer()


def test_subqueries_that_are_not_provably_single_row_stay() raises:
    # LIMIT 2, a grouped aggregate under a Project, a bare scan and a
    # two-column inner plan all stay for materialize-and-substitute. Catches:
    # a cardinality or width check that admits them (a CROSS join against
    # several rows multiplies the outer side).
    for c in range(4):
        var plan = LogicalPlan.filter(
            _gt(_bal(), _subq_over(_not_single_row(c))), _customer()
        )
        var before = plan.structural_hash()
        var out = scalar_subquery_decorrelate(plan^)
        assert_equal(out.tag, PLAN_FILTER)
        assert_equal(out.structural_hash(), before)


def test_a_correlated_subquery_stays() raises:
    # Catches: decorrelating a subquery that names an outer column.
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var corr = Expr.correlated_subquery(_global_agg(), refs^, CORR_KIND_SCALAR)
    var plan = LogicalPlan.filter(_gt(_bal(), corr^), _customer())
    var before = plan.structural_hash()
    var out = scalar_subquery_decorrelate(plan^)
    assert_equal(out.structural_hash(), before)


# =============================================================================
# The Project rewrite
# =============================================================================


def test_a_project_expression_gets_a_cross_join_and_keeps_its_schema() raises:
    # Catches: no Project rewrite; an identity wrapper added where the schema
    # did not move (the Project itself must be the root).
    var pe = ExprArray()
    pe.append(Expr.alias(_subq(), String("t")))
    pe.append(_bal())
    var plan = LogicalPlan.project(pe^, _customer())
    var out = scalar_subquery_decorrelate(plan^)
    assert_equal(out.tag, PLAN_PROJECT)
    var names = _names(out)
    assert_equal(len(names), 2)
    assert_equal(names[0], String("t"))
    assert_equal(names[1], String("c_acctbal"))
    ref j = out.project_data_ref().child[]
    assert_equal(j.tag, PLAN_JOIN)
    assert_equal(Int(j.join_data_ref().join_type), Int(JOIN_CROSS))
    ref t = out.project_data_ref().exprs[0]
    assert_equal(t.alias_child_ref().col_ref_name(), _col(0))


def test_a_project_without_a_subquery_is_untouched() raises:
    # Catches: a Project rebuilt (and hashed differently) with nothing to do.
    var pe = ExprArray()
    pe.append(_bal())
    var plan = LogicalPlan.project(pe^, _customer())
    var before = plan.structural_hash()
    var out = scalar_subquery_decorrelate(plan^)
    assert_equal(out.structural_hash(), before)


# =============================================================================
# The expression walkers
# =============================================================================


def test_every_walked_container_is_seen_and_rewritten() raises:
    # Each container on the walk set holds the subquery. Catches: an arm
    # dropped from the containment check (that container would be ignored),
    # from the collector (the rewrite would raise: hash not collected), or
    # from the rewriter (the subquery would survive).
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    assert_true(_expr_contains_decorrelatable_scalar(_subq()))
    assert_true(_expr_contains_decorrelatable_scalar(_gt(_bal(), _subq())))
    assert_true(_expr_contains_decorrelatable_scalar(Expr.unary(UN_NEGATE, _subq())))
    assert_true(_expr_contains_decorrelatable_scalar(Expr.cast(_subq(), DType.float64)))
    assert_true(_expr_contains_decorrelatable_scalar(Expr.alias(_subq(), String("a"))))
    assert_true(
        _expr_contains_decorrelatable_scalar(Expr.string_op(STR_LIKE, _subq(), String("1%")))
    )
    assert_true(_expr_contains_decorrelatable_scalar(Expr.in_list_node(_subq(), vals.copy())))
    assert_true(_expr_contains_decorrelatable_scalar(Expr.agg_fn(AGG_MAX, _subq())))
    # A column and a CASE body are not on the walk set.
    assert_false(_expr_contains_decorrelatable_scalar(_bal()))
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_gt(_bal(), _lit(0)), _subq()))
    assert_false(_expr_contains_decorrelatable_scalar(Expr.when(cases^, _lit(0))))

    var e = _gt(_bal(), _subq())
    e = _and(e^, Expr.binary(BIN_EQ, Expr.unary(UN_NEGATE, _subq()), _lit(1)))
    e = _and(e^, Expr.binary(BIN_EQ, Expr.cast(_subq(), DType.float64), _lit(1)))
    e = _and(e^, Expr.binary(BIN_EQ, Expr.alias(_subq(), String("a")), _lit(1)))
    e = _and(e^, Expr.string_op(STR_LIKE, _subq(), String("1%")))
    e = _and(e^, Expr.in_list_node(_subq(), vals^))
    e = _and(e^, Expr.binary(BIN_EQ, Expr.agg_fn(AGG_MAX, _subq()), _lit(1)))
    e = _and(e^, Expr.binary(BIN_EQ, _bal(), _lit(2)))
    var out = scalar_subquery_decorrelate(LogicalPlan.filter(e^, _customer()))
    _assert_filter_decorrelated(out)
    ref p = out.project_data_ref().child[].filter_data_ref().predicate
    # Left-deep chain, read from the right.
    assert_equal(p.binary_right_ref().binary_left_ref().col_ref_name(), String("c_acctbal"))
    ref r1 = p.binary_left_ref()
    assert_equal(
        r1.binary_right_ref().binary_left_ref().agg_fn_child_ref().col_ref_name(), _col(0)
    )
    ref r2 = r1.binary_left_ref()
    assert_equal(r2.binary_right_ref().in_list_child_ref().col_ref_name(), _col(0))
    assert_equal(r2.binary_right_ref().in_list_len(), 1)
    ref r3 = r2.binary_left_ref()
    assert_equal(r3.binary_right_ref().string_op_child_ref().col_ref_name(), _col(0))
    assert_equal(r3.binary_right_ref().string_op_pattern(), String("1%"))
    ref r4 = r3.binary_left_ref()
    assert_equal(
        r4.binary_right_ref().binary_left_ref().alias_child_ref().col_ref_name(), _col(0)
    )
    ref r5 = r4.binary_left_ref()
    assert_equal(
        r5.binary_right_ref().binary_left_ref().cast_child_ref().col_ref_name(), _col(0)
    )
    assert_true(r5.binary_right_ref().binary_left_ref().cast_target() == DType.float64)
    ref r6 = r5.binary_left_ref()
    assert_equal(
        r6.binary_right_ref().binary_left_ref().unary_child_ref().col_ref_name(), _col(0)
    )
    assert_equal(r6.binary_left_ref().binary_right_ref().col_ref_name(), _col(0))


def test_a_case_body_beside_a_rewritten_site_is_kept() raises:
    # A predicate with one decorrelatable site AND a correlated subquery and a
    # CASE holding a subquery. Catches: the rewriter replacing what the
    # collector skipped (it would raise: hash not collected) or dropping them.
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var corr = Expr.correlated_subquery(_global_agg(AGG_MAX), refs^, CORR_KIND_SCALAR)
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_gt(_bal(), _lit(0)), _subq(AGG_MAX)))
    var e = _and(_gt(_bal(), _subq()), _gt(_bal(), corr^))
    e = _and(e^, Expr.binary(BIN_EQ, Expr.when(cases^, _lit(0)), _lit(1)))
    var out = scalar_subquery_decorrelate(LogicalPlan.filter(e^, _customer()))
    _assert_filter_decorrelated(out)
    ref p = out.project_data_ref().child[].filter_data_ref().predicate
    assert_equal(
        p.binary_right_ref().binary_left_ref().when_case_result_ref(0).tag,
        EXPR_CORRELATED_SUBQUERY,
    )
    assert_equal(
        p.binary_left_ref().binary_right_ref().binary_right_ref().tag,
        EXPR_CORRELATED_SUBQUERY,
    )
    assert_equal(
        p.binary_left_ref().binary_left_ref().binary_right_ref().col_ref_name(), _col(0)
    )


# =============================================================================
# The plan walk
# =============================================================================


def _decorrelatable_filter() -> LogicalPlan:
    return LogicalPlan.filter(_gt(_bal(), _subq()), _customer())


def _keys() -> List[String]:
    var k = List[String]()
    k.append(String("c_acctbal"))
    return k^


def _desc() -> List[Bool]:
    var d = List[Bool]()
    d.append(False)
    return d^


def _custkey() -> List[String]:
    var k = List[String]()
    k.append(String("c_custkey"))
    return k^


def _wrap(kind: Int) raises -> LogicalPlan:
    """A node of the given kind over a decorrelatable Filter (two for a Join)."""
    if kind == 0:
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional(_bal()), Optional(String("s"))))
        return LogicalPlan.aggregate(ExprArray(), aggs^, _decorrelatable_filter())
    if kind == 1:
        return LogicalPlan.sort(_keys(), _desc(), _decorrelatable_filter())
    if kind == 2:
        return LogicalPlan.limit(5, _decorrelatable_filter())
    if kind == 3:
        return LogicalPlan.distinct(None, _decorrelatable_filter())
    if kind == 4:
        return LogicalPlan.topn(_keys(), _desc(), 3, _decorrelatable_filter())
    if kind == 5:
        return LogicalPlan.partition_by(
            List[String](), _keys(), _desc(), List[PartitionExpr](),
            _decorrelatable_filter(),
        )
    if kind == 6:
        return LogicalPlan.partition_topn(
            _custkey(), _keys(), _desc(), 2, _decorrelatable_filter()
        )
    if kind == 7:
        var pe = ExprArray()
        pe.append(_bal())
        return LogicalPlan.project(pe^, _decorrelatable_filter())
    return LogicalPlan.join(
        _decorrelatable_filter(), _decorrelatable_filter(),
        _custkey(), _custkey(), JOIN_INNER,
    )


def _assert_child_decorrelated(imm plan: LogicalPlan, kind: Int) raises:
    if kind == 0:
        _assert_filter_decorrelated(plan.aggregate_data_ref().child[])
    elif kind == 1:
        _assert_filter_decorrelated(plan.sort_data_ref().child[])
    elif kind == 2:
        _assert_filter_decorrelated(plan.limit_data_ref().child[])
    elif kind == 3:
        _assert_filter_decorrelated(plan.distinct_data_ref().child[])
    elif kind == 4:
        _assert_filter_decorrelated(plan.topn_data_ref().child[])
    elif kind == 5:
        _assert_filter_decorrelated(plan.partition_by_data_ref().child[])
    elif kind == 6:
        _assert_filter_decorrelated(plan.partition_topn_data_ref().child[])
    elif kind == 7:
        _assert_filter_decorrelated(plan.project_data_ref().child[])
    else:
        _assert_filter_decorrelated(plan.join_data_ref().left[])
        _assert_filter_decorrelated(plan.join_data_ref().right[])


def test_the_walk_reaches_a_filter_under_every_node_kind() raises:
    # Aggregate, Sort, Limit, Distinct, TopN, PartitionBy, PartitionTopN,
    # Project, and both sides of a Join. Catches: a recursion arm dropped
    # from `scalar_subquery_decorrelate_inplace` (the Filter below that node
    # kind would keep its subquery).
    for kind in range(9):
        var plan = _wrap(kind)
        scalar_subquery_decorrelate_inplace(plan)
        _assert_child_decorrelated(plan, kind)


def test_a_filter_under_a_filter_is_rewritten_first() raises:
    # Children first: catches a walk that rewrites the outer Filter and never
    # descends (the inner subquery would survive).
    var inner = _decorrelatable_filter()
    var outer = LogicalPlan.filter(_gt(_bal(), _lit(0)), inner^)
    scalar_subquery_decorrelate_inplace(outer)
    assert_equal(outer.tag, PLAN_FILTER)
    _assert_filter_decorrelated(outer.filter_data_ref().child[])


def test_a_scan_is_a_leaf() raises:
    var plan = _customer()
    var before = plan.structural_hash()
    scalar_subquery_decorrelate_inplace(plan)
    assert_equal(plan.structural_hash(), before)


# =============================================================================
# The defensive helpers, called directly
# =============================================================================


def test_restore_schema_wraps_when_names_differ_at_equal_width() raises:
    # Catches: a width-only comparison, which would let a renamed column
    # escape the node that introduced it.
    var node = _orders()
    var out = _restore_schema(node^, _schema1(String("other")))
    assert_equal(out.tag, PLAN_PROJECT)
    assert_equal(out.project_data_ref().child[].tag, PLAN_SCAN)
    assert_equal(out.project_data_ref().exprs[0].col_ref_name(), String("other"))
    # Equal names: returned as-is.
    var same = _restore_schema(_orders(), _schema1(String("o_total")))
    assert_equal(same.tag, PLAN_SCAN)


def test_a_hash_the_collector_never_saw_raises() raises:
    # Catches: a silent fallback name when the collect and rewrite walks drift.
    var sites = Slab[_DecorrSite]()
    with assert_raises():
        _ = _find_site_col_for_hash(sites, 12345)
    sites.append(_DecorrSite(_orders(), 7, _col(0)))
    assert_equal(_find_site_col_for_hash(sites, 7), _col(0))


def test_the_site_predicate() raises:
    # Called directly, the predicate refuses a non-subquery node and a
    # correlated one. Catches: a predicate that reads the subquery payload of
    # any node, or one that ignores outer refs.
    assert_false(_is_uncorrelated_scalar_subquery(_bal()))
    var refs = List[String]()
    refs.append(String("c_custkey"))
    var corr = Expr.correlated_subquery(_global_agg(), refs^, CORR_KIND_SCALAR)
    assert_false(_is_uncorrelated_scalar_subquery(corr))
    assert_true(_is_uncorrelated_scalar_subquery(_subq()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

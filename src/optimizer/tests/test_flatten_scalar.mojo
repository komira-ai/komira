"""Tests of the scalar-subquery lowering of `flatten_dependent_joins` over the
SQL binder's shape, and of the expression walks in `flatten_scalar`.

The binder (`sql.sql_bind_corr_scalar`) writes a correlated scalar subquery
as `Project([v AS __corr0_v], Filter(__corr0_k0 = left(c_custkey),
Project([o_custkey AS __corr0_k0, __corr0_a0], Aggregate(group_by=[o_custkey],
[sum(o_orderkey) AS __corr0_a0], orders))))`. What each test proves:

  test_a_grouped_scalar_is_a_left_join_on_its_keys
      `c_nationkey > (that subquery)` becomes `Filter(c_nationkey >
      __corr0_v, Project([<the join's columns>, coalesce(__corr0_a0, 0) AS
      __corr0_v], LeftJoin(customer, <the grouped body>) on c_custkey =
      __corr0_k0))`: the Project's expression is computed above the join
      (a filter does not evaluate a CASE) and the correlation Filter is
      gone; two keys keep their order.
  test_a_grouped_scalar_value_names
      a computed value with no alias is the column `__corr_value`; a value
      that is a bare column is read straight off the join, no Project.
  test_the_same_subquery_twice_is_joined_once
      `x > 1 AND x < 5` over one binder subquery (BETWEEN repeats its
      operand) adds one LEFT join and reads its column twice, for a computed
      value and for a bare column; an unaliased value is joined each time.
  test_grouped_scalar_refusals
      a correlation that is not an equality (the join would need a
      residual), a Filter with no correlation at all, and a body not grouped
      by its keys (a bare scan, a different number of group keys) are
      refused, each by its message.
  test_a_nested_subquery_in_a_grouped_body_is_lowered
      an EXISTS in the grouped body's own Filter is a SEMI join inside the
      LEFT join's right side.
  test_predicate_subquery_search_per_expression_kind
      `expr_contains_predicate_subquery` finds an EXISTS under every node
      kind it descends and nothing in a scalar subquery or a plain column.
  test_scalar_lowering_per_expression_kind
      `lower_scalar_subqueries_in` replaces a scalar under NOT, CAST, an
      alias and each CASE slot; returns an expression with no subquery as
      it is; raises its refusal for an EXISTS and for a scalar under a kind
      it does not descend (a string operation, an aggregate).
"""

from std.testing import assert_equal, assert_true, assert_false

from arrow.schema import SchemaBuilder, Field
from arrow.arrow_types import ArrowType
from plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_CAST,
    EXPR_UNARY_OP,
    EXPR_WHEN,
    BIN_AND,
    BIN_EQ,
    BIN_GT,
    BIN_LT,
    UN_NOT,
    STR_CONTAINS,
)
from plan_expr.agg_expr import AggExpr, AGG_SUM
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_JOIN,
    SOURCE_PARQUET,
    CORR_KIND_EXISTS,
    CORR_KIND_SCALAR,
    JOIN_SEMI,
    JOIN_LEFT,
)
from plan_ir.corr_subquery import corr_data_inner_plan_ref
from optimizer.flatten_dependent_joins import (
    flatten_dependent_joins,
    _plan_contains_correlated_subquery,
)
from optimizer.flatten_scalar import (
    expr_contains_predicate_subquery,
    lower_scalar_subqueries_in,
)


def _scan(path: String, var cols: List[String]) -> LogicalPlan:
    var sb = SchemaBuilder()
    for i in range(len(cols)):
        sb.add_field(Field(cols[i], ArrowType.INT64, True))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _customer() -> LogicalPlan:
    return _scan("customer.parquet", ["c_custkey", "c_nationkey"])


def _orders() -> LogicalPlan:
    return _scan("orders.parquet", ["o_orderkey", "o_custkey", "o_status"])


def _grouped(var source: LogicalPlan, var keys: List[String]) raises -> LogicalPlan:
    """`Project([<key i> AS __corr0_k<i>, __corr0_a0], Aggregate(group_by=keys,
    [sum(o_orderkey) AS __corr0_a0], source))`."""
    var gb = ExprArray()
    for i in range(len(keys)):
        gb.append(Expr.col_ref(keys[i]))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("o_orderkey")), Optional(String("__corr0_a0"))))
    var agg = LogicalPlan.aggregate(gb^, aggs^, source^)
    var pe = ExprArray()
    for i in range(len(keys)):
        pe.append(Expr.alias(Expr.col_ref(keys[i]), "__corr0_k" + String(i)))
    pe.append(Expr.col_ref("__corr0_a0"))
    return LogicalPlan.project(pe^, agg^)


def _coalesce0(name: String) -> Expr:
    """`CASE WHEN name IS NULL THEN 0 ELSE name END`, the value a count's
    column is read through."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(
        Expr.unary(UN_NOT, Expr.binary(BIN_EQ, Expr.col_ref(name), Expr.col_ref(name))),
        Expr.literal(ScalarValue.from_int(0)),
    ))
    return Expr.when(cases^, Expr.col_ref(name))


def _binder_scalar(var corr: Expr, var body: LogicalPlan, var refs: List[String], aliased: Bool = True) -> Expr:
    var value = _coalesce0("__corr0_a0")
    var pe = ExprArray()
    if aliased:
        pe.append(Expr.alias(value^, "__corr0_v"))
    else:
        pe.append(value^)
    var inner = LogicalPlan.project(pe^, LogicalPlan.filter(corr^, body^))
    return Expr.correlated_subquery(inner^, refs^, CORR_KIND_SCALAR)


def _key_eq(i: Int, outer: String) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref("__corr0_k" + String(i)), Expr.left(outer))


def _one_key_scalar(aliased: Bool = True) raises -> Expr:
    return _binder_scalar(_key_eq(0, "c_custkey"), _grouped(_orders(), ["o_custkey"]), ["c_custkey"], aliased)


def _gt_nation(var scalar: Expr) -> LogicalPlan:
    return LogicalPlan.filter(
        Expr.binary(BIN_GT, Expr.col_ref("c_nationkey"), scalar^), _customer()
    )


def _raises_with(var plan: LogicalPlan, needle: String) raises -> Bool:
    try:
        _ = flatten_dependent_joins(plan^)
    except e:
        assert_true(String(e).find(needle) >= 0, String(e))
        return True
    return False


def test_a_grouped_scalar_is_a_left_join_on_its_keys() raises:
    var out = flatten_dependent_joins(_gt_nation(_one_key_scalar()))
    assert_false(_plan_contains_correlated_subquery(out))
    assert_equal(out.tag, PLAN_FILTER)
    ref p = out._filter.value()[].predicate
    assert_equal(p.binary_op(), BIN_GT)
    assert_equal(p.binary_right_ref().col_ref_name(), String("__corr0_v"))
    ref pr = out._filter.value()[].child[]
    assert_equal(pr.tag, PLAN_PROJECT)
    ref pexprs = pr._project.value()[].exprs
    assert_equal(pexprs[len(pexprs) - 1].alias_name(), String("__corr0_v"))
    assert_equal(pexprs[len(pexprs) - 1].alias_child_ref().tag, EXPR_WHEN)
    assert_equal(pexprs[0].col_ref_name(), String("c_custkey"))
    ref j = pr._project.value()[].child[]._join.value()[]
    assert_equal(j.join_type, JOIN_LEFT)
    assert_equal(len(j.left_on), 1)
    assert_equal(j.left_on[0], String("c_custkey"))
    assert_equal(j.right_on[0], String("__corr0_k0"))
    assert_equal(j.right[].tag, PLAN_PROJECT)
    assert_false(j.has_residual())

    var two = _binder_scalar(
        Expr.binary(BIN_AND, _key_eq(0, "c_custkey"), _key_eq(1, "c_nationkey")),
        _grouped(_orders(), ["o_custkey", "o_status"]),
        ["c_custkey", "c_nationkey"],
    )
    var out2 = flatten_dependent_joins(_gt_nation(two^))
    ref j2 = out2._filter.value()[].child[]._project.value()[].child[]._join.value()[]
    assert_equal(j2.left_on[0], String("c_custkey"))
    assert_equal(j2.left_on[1], String("c_nationkey"))
    assert_equal(j2.right_on[0], String("__corr0_k0"))
    assert_equal(j2.right_on[1], String("__corr0_k1"))


def test_a_grouped_scalar_value_names() raises:
    var out = flatten_dependent_joins(_gt_nation(_one_key_scalar(aliased=False)))
    assert_equal(
        out._filter.value()[].predicate.binary_right_ref().col_ref_name(),
        String("__corr_value"),
    )
    var pe = ExprArray()
    pe.append(Expr.alias(Expr.col_ref("__corr0_a0"), "__corr0_v"))
    var inner = LogicalPlan.project(
        pe^, LogicalPlan.filter(_key_eq(0, "c_custkey"), _grouped(_orders(), ["o_custkey"]))
    )
    var bare = Expr.correlated_subquery(inner^, ["c_custkey"], CORR_KIND_SCALAR)
    var out2 = flatten_dependent_joins(_gt_nation(bare^))
    assert_equal(
        out2._filter.value()[].predicate.binary_right_ref().col_ref_name(),
        String("__corr0_a0"),
    )
    assert_equal(out2._filter.value()[].child[].tag, PLAN_JOIN)


def _count_left_joins(plan: LogicalPlan) -> Int:
    var n = 0
    if plan.tag == PLAN_JOIN:
        n = 1 + _count_left_joins(plan._join.value()[].left[])
    elif plan.tag == PLAN_PROJECT:
        n = _count_left_joins(plan._project.value()[].child[])
    elif plan.tag == PLAN_FILTER:
        n = _count_left_joins(plan._filter.value()[].child[])
    return n


def _between(var a: Expr, var b: Expr) -> LogicalPlan:
    return LogicalPlan.filter(
        Expr.binary(
            BIN_AND,
            Expr.binary(BIN_GT, a^, Expr.literal(ScalarValue.from_int(1))),
            Expr.binary(BIN_LT, b^, Expr.literal(ScalarValue.from_int(5))),
        ),
        _customer(),
    )


def _bare_value_scalar() raises -> Expr:
    var pe = ExprArray()
    pe.append(Expr.alias(Expr.col_ref("__corr0_a0"), "__corr0_v"))
    var inner = LogicalPlan.project(
        pe^, LogicalPlan.filter(_key_eq(0, "c_custkey"), _grouped(_orders(), ["o_custkey"]))
    )
    return Expr.correlated_subquery(inner^, ["c_custkey"], CORR_KIND_SCALAR)


def test_the_same_subquery_twice_is_joined_once() raises:
    var out = flatten_dependent_joins(_between(_one_key_scalar(), _one_key_scalar()))
    assert_false(_plan_contains_correlated_subquery(out))
    assert_equal(_count_left_joins(out), 1)
    ref p = out._filter.value()[].predicate
    assert_equal(p.binary_left_ref().binary_left_ref().col_ref_name(), String("__corr0_v"))
    assert_equal(p.binary_right_ref().binary_left_ref().col_ref_name(), String("__corr0_v"))
    var bare = flatten_dependent_joins(_between(_bare_value_scalar(), _bare_value_scalar()))
    assert_equal(_count_left_joins(bare), 1)
    assert_equal(
        bare._filter.value()[].predicate.binary_right_ref().binary_left_ref().col_ref_name(),
        String("__corr0_a0"),
    )
    var unaliased = flatten_dependent_joins(
        _between(_one_key_scalar(aliased=False), _one_key_scalar(aliased=False))
    )
    assert_equal(_count_left_joins(unaliased), 2)


def test_grouped_scalar_refusals() raises:
    var nonequi = _binder_scalar(
        Expr.binary(BIN_LT, Expr.col_ref("__corr0_k0"), Expr.left("c_custkey")),
        _grouped(_orders(), ["o_custkey"]),
        ["c_custkey"],
    )
    var corr_msg = "correlated other than by inner = outer column equalities"
    assert_true(_raises_with(_gt_nation(nonequi^), corr_msg))
    var none = _binder_scalar(
        Expr.binary(BIN_GT, Expr.col_ref("__corr0_a0"), Expr.literal(ScalarValue.from_int(0))),
        _grouped(_orders(), ["o_custkey"]),
        List[String](),
    )
    assert_true(_raises_with(_gt_nation(none^), corr_msg))
    var grouped_msg = "not grouped by its correlation keys"
    var bare = _binder_scalar(
        Expr.binary(BIN_EQ, Expr.col_ref("o_custkey"), Expr.left("c_custkey")),
        _orders(),
        ["c_custkey"],
    )
    assert_true(_raises_with(_gt_nation(bare^), grouped_msg))
    var wrong = _binder_scalar(
        _key_eq(0, "c_custkey"), _grouped(_orders(), ["o_custkey", "o_status"]), ["c_custkey"]
    )
    assert_true(_raises_with(_gt_nation(wrong^), grouped_msg))


def test_a_nested_subquery_in_a_grouped_body_is_lowered() raises:
    var exists = Expr.correlated_subquery(
        LogicalPlan.filter(
            Expr.binary(BIN_EQ, Expr.col_ref("c_custkey"), Expr.left("o_custkey")),
            _customer(),
        ),
        ["o_custkey"],
        CORR_KIND_EXISTS,
    )
    var body = _grouped(LogicalPlan.filter(exists^, _orders()), ["o_custkey"])
    var s = _binder_scalar(_key_eq(0, "c_custkey"), body^, ["c_custkey"])
    var out = flatten_dependent_joins(_gt_nation(s^))
    assert_false(_plan_contains_correlated_subquery(out))
    ref right = out._filter.value()[].child[]._project.value()[].child[]._join.value()[].right[]
    ref agg_child = right._project.value()[].child[]._aggregate.value()[].child[]
    assert_equal(agg_child.tag, PLAN_JOIN)
    assert_equal(agg_child._join.value()[].join_type, JOIN_SEMI)


def _exists() raises -> Expr:
    return Expr.correlated_subquery(_orders(), ["c_custkey"], CORR_KIND_EXISTS)


def _scalar() raises -> Expr:
    return _one_key_scalar()


def _when_with(slot: Int, var e: Expr) -> Expr:
    """A CASE holding `e` in its WHEN (0), THEN (1) or ELSE (2) slot."""
    var lit = Expr.literal(ScalarValue.from_int(1))
    var cases = List[WhenCaseData]()
    if slot == 0:
        cases.append(WhenCaseData(e^, lit.copy()))
        return Expr.when(cases^, lit^)
    if slot == 1:
        cases.append(WhenCaseData(Expr.col_ref("c_nationkey"), e^))
        return Expr.when(cases^, lit^)
    cases.append(WhenCaseData(Expr.col_ref("c_nationkey"), lit.copy()))
    return Expr.when(cases^, e^)


def test_predicate_subquery_search_per_expression_kind() raises:
    var one = Expr.literal(ScalarValue.from_int(1))
    assert_true(expr_contains_predicate_subquery(_exists()))
    assert_true(expr_contains_predicate_subquery(Expr.binary(BIN_AND, one.copy(), _exists())))
    assert_true(expr_contains_predicate_subquery(Expr.binary(BIN_AND, _exists(), one.copy())))
    assert_true(expr_contains_predicate_subquery(Expr.unary(UN_NOT, _exists())))
    assert_true(expr_contains_predicate_subquery(Expr.cast(_exists(), DType.int64)))
    assert_true(expr_contains_predicate_subquery(Expr.alias(_exists(), "e")))
    assert_true(expr_contains_predicate_subquery(Expr.string_op(STR_CONTAINS, _exists(), "x")))
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    assert_true(expr_contains_predicate_subquery(Expr.in_list_node(_exists(), vals^)))
    assert_true(expr_contains_predicate_subquery(Expr.agg_fn(AGG_SUM, _exists())))
    for slot in range(3):
        assert_true(expr_contains_predicate_subquery(_when_with(slot, _exists())))
    assert_false(expr_contains_predicate_subquery(_when_with(0, one.copy())))
    assert_false(expr_contains_predicate_subquery(_scalar()))
    assert_false(expr_contains_predicate_subquery(Expr.binary(BIN_AND, one.copy(), _scalar())))
    assert_false(expr_contains_predicate_subquery(Expr.col_ref("c_custkey")))


def _lowered(var e: Expr) raises -> Expr:
    var base = _customer()
    var n = 0
    var out = lower_scalar_subqueries_in(base, e, n, "refused here")
    assert_equal(base.tag, PLAN_PROJECT)
    assert_equal(n, 1)
    return out^


def _lower_raises(var e: Expr) raises -> Bool:
    var base = _customer()
    var n = 0
    try:
        _ = lower_scalar_subqueries_in(base, e, n, "refused here")
    except err:
        assert_equal(String(err), "refused here")
        return True
    return False


def test_scalar_lowering_per_expression_kind() raises:
    assert_equal(_lowered(Expr.unary(UN_NOT, _scalar())).tag, EXPR_UNARY_OP)
    assert_equal(_lowered(Expr.cast(_scalar(), DType.int64)).tag, EXPR_CAST)
    var aliased = _lowered(Expr.alias(_scalar(), "s"))
    assert_equal(aliased.alias_name(), String("s"))
    for slot in range(3):
        assert_equal(_lowered(_when_with(slot, _scalar())).tag, EXPR_WHEN)

    var base = _customer()
    var n = 0
    var plain = lower_scalar_subqueries_in(base, Expr.col_ref("c_custkey"), n, "x")
    assert_equal(plain.col_ref_name(), String("c_custkey"))
    assert_equal(base.tag, PLAN_SCAN)
    assert_equal(n, 0)

    assert_true(_lower_raises(_exists()))
    assert_true(_lower_raises(Expr.string_op(STR_CONTAINS, _scalar(), "x")))
    assert_true(_lower_raises(Expr.agg_fn(AGG_SUM, _scalar())))


def main() raises:
    test_a_grouped_scalar_is_a_left_join_on_its_keys()
    test_a_grouped_scalar_value_names()
    test_the_same_subquery_twice_is_joined_once()
    test_grouped_scalar_refusals()
    test_a_nested_subquery_in_a_grouped_body_is_lowered()
    test_predicate_subquery_search_per_expression_kind()
    test_scalar_lowering_per_expression_kind()
    print("All flatten_scalar tests passed.")

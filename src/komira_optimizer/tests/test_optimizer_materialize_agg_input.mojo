"""Tests of `komira_optimizer.optimizer_materialize_agg_input`.

`materialize_agg_input` lifts every aggregate input that is not a column
reference (or an alias of one) into a Project spliced under the Aggregate,
and points the aggregate at the new column. Each test names the defect it
catches.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field, Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    BIN_ADD,
    BIN_MUL,
    BIN_GT,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT, AGG_CORR, AGG_MAX
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    SOURCE_PARQUET,
    JOIN_INNER,
)

from komira_optimizer.optimizer_materialize_agg_input import (
    materialize_agg_input,
    _is_trivially_resolvable,
    _referenced_column_name,
)


# =============================================================================
# Fixtures
# =============================================================================


def _scan() -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.INT64, nullable=False))
    sb.add_field(Field("c", ArrowType.INT64, nullable=False))
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _mul(l: String, r: String) -> Expr:
    return Expr.binary(BIN_MUL, Expr.col_ref(l), Expr.col_ref(r))


def _sum(var e: Expr, name: String) -> AggExpr:
    return AggExpr(AGG_SUM, Optional(e^), Optional(name))


def _one(var a: AggExpr) -> AggExprArray:
    var out = AggExprArray()
    out.append(a^)
    return out^


def _cols(*names: String) -> ExprArray:
    var e = ExprArray()
    for n in names:
        e.append(Expr.col_ref(n))
    return e^


def _out_names(plan: LogicalPlan) -> String:
    var s = String("")
    for i in range(plan.output_schema.num_columns()):
        if i > 0:
            s += ","
        s += plan.output_schema.field_name(i)
    return s


def _child(plan: LogicalPlan) -> LogicalPlan:
    return plan._aggregate.value()[].child[].copy()


def _slot_name(slot: Optional[Expr]) raises -> String:
    assert_true(Bool(slot))
    assert_equal(slot.value().tag, EXPR_COL_REF)
    return slot.value().col_ref_name()


# =============================================================================
# The rewrite
# =============================================================================


def test_binop_input_is_lifted_into_a_project() raises:
    """sum(a * b) over Scan(a,b,c): a Project `a * b AS __agg_in_0` is
    spliced under the Aggregate, the agg slot becomes `col(__agg_in_0)`, and
    the Aggregate's output schema is unchanged.

    Catches: no Project spliced; the slot left as the binop; the output
    schema renamed."""
    var plan = LogicalPlan.aggregate(ExprArray(), _one(_sum(_mul("a", "b"), "s")), _scan())
    var before = _out_names(plan)
    var out = materialize_agg_input(plan^)
    assert_equal(_out_names(out), before)
    var proj = _child(out)
    assert_equal(proj.tag, PLAN_PROJECT)
    assert_equal(_out_names(proj), String("__agg_in_0"))
    assert_equal(proj._project.value()[].exprs[0].tag, EXPR_ALIAS)
    assert_equal(proj._project.value()[].exprs[0].alias_child_ref().tag, EXPR_BINARY_OP)
    assert_equal(_slot_name(out._aggregate.value()[].agg_exprs[0].child), String("__agg_in_0"))


def test_column_inputs_are_left_alone() raises:
    """sum(a), count(alias(a)) and max(col_idx 1) over Scan: no Project.

    Catches: a column reference, an alias of one or a column index treated
    as derived."""
    var aggs = AggExprArray()
    aggs.append(_sum(Expr.col_ref("a"), "s"))
    aggs.append(AggExpr(AGG_COUNT, Optional(Expr.alias(Expr.col_ref("a"), "x")), Optional(String("n"))))
    aggs.append(AggExpr(AGG_MAX, Optional(Expr.col_idx(1)), Optional(String("m"))))
    var out = materialize_agg_input(LogicalPlan.aggregate(ExprArray(), aggs^, _scan()))
    assert_equal(_child(out).tag, PLAN_SCAN)


def test_every_slot_is_lifted_under_its_own_name() raises:
    """corr(a * 2, b + 1) and a sum whose slots 2 and 3 are `a + c` and
    `b * c`: four inputs are lifted as __agg_in_0 .. __agg_in_3, in slot
    order.

    Catches: a slot (1, 2 or 3) not scanned (it stays a binop); the name
    counter not advanced (two slots share __agg_in_0)."""
    var aggs = AggExprArray()
    aggs.append(AggExpr(
        AGG_CORR,
        Optional(Expr.binary(BIN_MUL, Expr.col_ref("a"), _lit(2))),
        Optional(Expr.binary(BIN_ADD, Expr.col_ref("b"), _lit(1))),
        Optional(String("r")),
    ))
    var wide = _sum(Expr.col_ref("a"), "s")
    wide.child2 = Optional(Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("c")))
    wide.child3 = Optional(_mul("b", "c"))
    aggs.append(wide^)
    var out = materialize_agg_input(LogicalPlan.aggregate(ExprArray(), aggs^, _scan()))
    ref ae = out._aggregate.value()[].agg_exprs
    assert_equal(_slot_name(ae[0].child), String("__agg_in_0"))
    assert_equal(_slot_name(ae[0].child1), String("__agg_in_1"))
    assert_equal(_slot_name(ae[1].child), String("a"))
    assert_equal(_slot_name(ae[1].child2), String("__agg_in_2"))
    assert_equal(_slot_name(ae[1].child3), String("__agg_in_3"))
    assert_equal(_out_names(_child(out)), String("a,__agg_in_0,__agg_in_1,__agg_in_2,__agg_in_3"))


def test_nested_aggregates_each_get_a_project() raises:
    """sum(s * 2) over Aggregate(group a, sum(a * b) AS s) over Scan: both
    aggregates get their own materialize Project.

    Catches: the walk stopping at the first Aggregate (the inner one keeps
    its binop)."""
    var inner = LogicalPlan.aggregate(_cols("a"), _one(_sum(_mul("a", "b"), "s")), _scan())
    var outer = LogicalPlan.aggregate(
        ExprArray(), _one(_sum(Expr.binary(BIN_MUL, Expr.col_ref("s"), _lit(2)), "t")), inner^
    )
    var out = materialize_agg_input(outer^)
    var p1 = _child(out)
    assert_equal(p1.tag, PLAN_PROJECT)
    var agg2 = p1._project.value()[].child[].copy()
    assert_equal(agg2.tag, PLAN_AGGREGATE)
    assert_equal(_child(agg2).tag, PLAN_PROJECT)
    assert_equal(_slot_name(agg2._aggregate.value()[].agg_exprs[0].child), String("__agg_in_0"))


def test_project_carries_only_the_columns_the_aggregate_reads() raises:
    """Group by c, sum(a * b), max(alias(b)) over Scan(a,b,c): the Project is
    [b, c, __agg_in_0] (child-schema order, `a` not passed through).

    Catches: every child column passed through (a stays); the kept columns
    emitted in key order or twice."""
    var aggs = AggExprArray()
    aggs.append(_sum(_mul("a", "b"), "s"))
    aggs.append(AggExpr(AGG_MAX, Optional(Expr.alias(Expr.col_ref("b"), "bb")), Optional(String("m"))))
    var gb = ExprArray()
    gb.append(Expr.alias(Expr.col_ref("c"), "c"))
    gb.append(Expr.col_ref("b"))
    var out = materialize_agg_input(LogicalPlan.aggregate(gb^, aggs^, _scan()))
    assert_equal(_out_names(_child(out)), String("b,c,__agg_in_0"))


def test_project_passes_every_column_when_it_cannot_narrow() raises:
    """Each of these keeps every child column in the Project: a retained
    column-index slot; a group key that is not a column reference; a group
    key naming a column the child lacks.

    Catches: narrowing past a column index (it would read a different
    column); narrowing with an unresolvable key; narrowing to a name the
    child does not have."""
    var a1 = AggExprArray()
    a1.append(_sum(_mul("a", "b"), "s"))
    a1.append(AggExpr(AGG_MAX, Optional(Expr.col_idx(2)), Optional(String("m"))))
    var o1 = materialize_agg_input(LogicalPlan.aggregate(ExprArray(), a1^, _scan()))
    assert_equal(_out_names(_child(o1)), String("a,b,c,__agg_in_0"))

    var gb = ExprArray()
    gb.append(Expr.binary(BIN_ADD, Expr.col_ref("c"), _lit(1)))
    var o2 = materialize_agg_input(LogicalPlan.aggregate(gb^, _one(_sum(_mul("a", "b"), "s")), _scan()))
    assert_equal(_out_names(_child(o2)), String("a,b,c,__agg_in_0"))

    var o3 = materialize_agg_input(
        LogicalPlan.aggregate(_cols("zz"), _one(_sum(_mul("a", "b"), "s")), _scan())
    )
    assert_equal(_out_names(_child(o3)), String("a,b,c,__agg_in_0"))


def test_existing_project_is_folded_not_stacked() raises:
    """sum(a * b) grouped by k over Project(a, b, a + b AS k) over Scan: the
    Aggregate's child is ONE Project over the scan, computing k and
    __agg_in_0.

    Catches: the new Project stacked over the existing one (Project over
    Project)."""
    var pe = _cols("a", "b")
    pe.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b")), "k"))
    var plan = LogicalPlan.aggregate(_cols("k"), _one(_sum(_mul("a", "b"), "s")), LogicalPlan.project(pe^, _scan()))
    var out = materialize_agg_input(plan^)
    var proj = _child(out)
    assert_equal(proj.tag, PLAN_PROJECT)
    assert_equal(proj._project.value()[].child[].tag, PLAN_SCAN)
    assert_equal(_out_names(proj), String("k,__agg_in_0"))


def test_aggregates_under_every_node_kind_are_rewritten() raises:
    """sum(a * b) grouped by a under Filter, Project, Sort, Limit, Distinct,
    TopN and either side of a Join gets its Project.

    Catches: any one recursion arm removed."""
    var desc = List[Bool]()
    desc.append(False)
    var keys = List[String]()
    keys.append("a")
    for kind in range(8):
        var agg = LogicalPlan.aggregate(_cols("a"), _one(_sum(_mul("a", "b"), "s")), _scan())
        var plan: LogicalPlan
        if kind == 0:
            plan = LogicalPlan.filter(Expr.binary(BIN_GT, Expr.col_ref("a"), _lit(0)), agg^)
        elif kind == 1:
            plan = LogicalPlan.project(_cols("a"), agg^)
        elif kind == 2:
            plan = LogicalPlan.sort(keys.copy(), desc.copy(), agg^)
        elif kind == 3:
            plan = LogicalPlan.limit(3, agg^)
        elif kind == 4:
            plan = LogicalPlan.distinct(None, agg^)
        elif kind == 5:
            plan = LogicalPlan.topn(keys.copy(), desc.copy(), 3, agg^)
        elif kind == 6:
            plan = LogicalPlan.join(agg^, _scan(), keys.copy(), keys.copy(), JOIN_INNER)
        else:
            plan = LogicalPlan.join(_scan(), agg^, keys.copy(), keys.copy(), JOIN_INNER)
        var out = materialize_agg_input(plan^)
        var found: LogicalPlan
        if kind == 0:
            found = out._filter.value()[].child[].copy()
        elif kind == 1:
            found = out._project.value()[].child[].copy()
        elif kind == 2:
            found = out._sort.value()[].child[].copy()
        elif kind == 3:
            found = out._limit.value()[].child[].copy()
        elif kind == 4:
            found = out._distinct.value()[].child[].copy()
        elif kind == 5:
            found = out._topn.value()[].child[].copy()
        elif kind == 6:
            found = out._join.value()[].left[].copy()
        else:
            found = out._join.value()[].right[].copy()
        assert_equal(_child(found).tag, PLAN_PROJECT, "kind " + String(kind))


# =============================================================================
# Helpers
# =============================================================================


def test_trivially_resolvable_and_referenced_name() raises:
    """A column reference, a column index and an alias of either are
    resolvable; an alias of a binop and a literal are not. Only a column
    reference (or an alias of one) has a referenced name.

    Catches: any alias accepted (an alias of a binop not lifted); a column
    index given a name (narrowing would renumber it)."""
    assert_true(_is_trivially_resolvable(Expr.col_ref("a")))
    assert_true(_is_trivially_resolvable(Expr.col_idx(0)))
    assert_true(_is_trivially_resolvable(Expr.alias(Expr.col_idx(0), "x")))
    assert_false(_is_trivially_resolvable(Expr.alias(_mul("a", "b"), "x")))
    assert_false(_is_trivially_resolvable(_lit(1)))
    assert_equal(_referenced_column_name(Expr.alias(Expr.col_ref("a"), "x")).value(), String("a"))
    assert_false(Bool(_referenced_column_name(Expr.col_idx(0))))
    var out = materialize_agg_input(LogicalPlan.aggregate(
        ExprArray(), _one(_sum(Expr.alias(_mul("a", "b"), "x"), "s")), _scan()
    ))
    assert_equal(_child(out).tag, PLAN_PROJECT)


def main() raises:
    test_binop_input_is_lifted_into_a_project()
    test_column_inputs_are_left_alone()
    test_every_slot_is_lifted_under_its_own_name()
    test_nested_aggregates_each_get_a_project()
    test_project_carries_only_the_columns_the_aggregate_reads()
    test_project_passes_every_column_when_it_cannot_narrow()
    test_existing_project_is_folded_not_stacked()
    test_aggregates_under_every_node_kind_are_rewritten()
    test_trivially_resolvable_and_referenced_name()
    print("All optimizer_materialize_agg_input tests passed.")

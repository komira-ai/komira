# =============================================================================
# Rule 13, `absorb_expression_into_aggregate`: every guard, every aggregate
# input slot and every recursion arm.
# =============================================================================
#
# The rule folds `Aggregate(Project(X))` into `Aggregate(X)` by substituting
# the Project's expressions into the group keys and into ALL FOUR input slots
# of each aggregate (`child`, `child1`, `child2`, `child3`). It leaves the pair
# standing when any of those reads a REPLACED column under a node the
# substitution returns as built: absorbing there would re-point the read at
# the original column. Each test names the defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_MUL
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT, AGG_CORR
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_SCAN,
    SOURCE_PARQUET,
    JOIN_INNER,
)
from komira_optimizer.optimizer_join import absorb_expression_into_aggregate


def _scan() -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("g", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("x", ArrowType.FLOAT64, True))
    sb.add_field(Field("y", ArrowType.FLOAT64, True))
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())


def _project() -> LogicalPlan:
    """Project([g, upper(s) AS s, x * 4.0 AS x, y]): `s` and `x` are REPLACED."""
    var pe = ExprArray()
    pe.append(Expr.col_ref("g"))
    pe.append(Expr.alias(col("s").upper(), "s"))
    pe.append(
        Expr.alias(
            Expr.binary(BIN_MUL, Expr.col_ref("x"), Expr.literal(ScalarValue.from_float(4.0))),
            "x",
        )
    )
    pe.append(Expr.col_ref("y"))
    return LogicalPlan.project(pe^, _scan())


def _unsafe() -> Expr:
    """A read of the replaced `s` under a node the substitution returns as built."""
    return Expr.regexp_like(Expr.col_ref("s"), "^Z")


def _agg(var keys: ExprArray, var aggs: AggExprArray) -> LogicalPlan:
    return LogicalPlan.aggregate(keys^, aggs^, _project())


def _g_keys() -> ExprArray:
    var k = ExprArray()
    k.append(Expr.col_ref("g"))
    return k^


def _sum_x() -> AggExprArray:
    var a = AggExprArray()
    a.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("x")), Optional[String](String("sx"))))
    return a^


def _absorbable() -> LogicalPlan:
    return _agg(_g_keys(), _sum_x())


def _render(e: Expr) -> String:
    var s = String("")
    e.write_to(s)
    return s


def _absorbed(p: LogicalPlan) -> Bool:
    """The aggregate now reads the scan directly."""
    return p._aggregate.value()[].child[].tag == PLAN_SCAN


# -----------------------------------------------------------------------------
# The guards: each input position declines on its own
# -----------------------------------------------------------------------------


def test_unsafe_group_key_leaves_the_project_standing() raises:
    """A group key `regexp_like(s)` over the replaced `s`. Catches the group-key
    guard dropped (the key would read the original lower-case `s`)."""
    var k = ExprArray()
    k.append(_unsafe())
    var out = absorb_expression_into_aggregate(_agg(k^, _sum_x()))
    assert_equal(Int(out._aggregate.value()[].child[].tag), Int(PLAN_PROJECT))


def test_unsafe_slot_zero_leaves_the_project_standing() raises:
    """Catches the `child` guard dropped."""
    var a = AggExprArray()
    a.append(AggExpr(AGG_SUM, Optional[Expr](_unsafe()), Optional[String](String("z"))))
    var out = absorb_expression_into_aggregate(_agg(_g_keys(), a^))
    assert_equal(Int(out._aggregate.value()[].child[].tag), Int(PLAN_PROJECT))


def test_unsafe_slot_one_leaves_the_project_standing() raises:
    """corr(y, regexp_like(s)): slot 1 alone is unsafe. Catches the `child1`
    guard dropped."""
    var a = AggExprArray()
    a.append(
        AggExpr(
            AGG_CORR, Optional[Expr](Expr.col_ref("y")), Optional[Expr](_unsafe()),
            Optional[String](String("c")),
        )
    )
    var out = absorb_expression_into_aggregate(_agg(_g_keys(), a^))
    assert_equal(Int(out._aggregate.value()[].child[].tag), Int(PLAN_PROJECT))


def test_unsafe_slot_two_leaves_the_project_standing() raises:
    """Slot 2 alone is unsafe. Catches the `child2` guard dropped."""
    var a = AggExprArray()
    var e = AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("y")), Optional[String](String("c")))
    e.child2 = Optional[Expr](_unsafe())
    a.append(e^)
    var out = absorb_expression_into_aggregate(_agg(_g_keys(), a^))
    assert_equal(Int(out._aggregate.value()[].child[].tag), Int(PLAN_PROJECT))


def test_unsafe_slot_three_leaves_the_project_standing() raises:
    """Slot 3 alone is unsafe. Catches the `child3` guard dropped."""
    var a = AggExprArray()
    var e = AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("y")), Optional[String](String("c")))
    e.child3 = Optional[Expr](_unsafe())
    a.append(e^)
    var out = absorb_expression_into_aggregate(_agg(_g_keys(), a^))
    assert_equal(Int(out._aggregate.value()[].child[].tag), Int(PLAN_PROJECT))


# -----------------------------------------------------------------------------
# The absorption: every slot is substituted and kept
# -----------------------------------------------------------------------------


def test_all_four_slots_are_substituted_and_preserved() raises:
    """corr(x, x) with slots 2 and 3 also reading the replaced `x`: after the
    absorption every slot reads `x * 4.0`. Catches a body that substitutes or
    keeps slot 0 only (a multi-input aggregate would lose its other inputs)."""
    var a = AggExprArray()
    var e = AggExpr(
        AGG_CORR, Optional[Expr](Expr.col_ref("x")), Optional[Expr](Expr.col_ref("x")),
        Optional[String](String("c")),
    )
    e.child2 = Optional[Expr](Expr.col_ref("x"))
    e.child3 = Optional[Expr](Expr.col_ref("x"))
    a.append(e^)
    var out = absorb_expression_into_aggregate(_agg(_g_keys(), a^))
    assert_true(_absorbed(out))
    ref ae = out._aggregate.value()[].agg_exprs[0]
    assert_equal(Int(ae.func), Int(AGG_CORR))
    # Presence first, so a dropped slot fails here instead of aborting on an
    # empty Optional below.
    assert_true(Bool(ae.child), "slot 0 kept")
    assert_true(Bool(ae.child1), "slot 1 kept")
    assert_true(Bool(ae.child2), "slot 2 kept")
    assert_true(Bool(ae.child3), "slot 3 kept")
    assert_true(_render(ae.child.value()).find("BinaryOp(MUL") >= 0)
    assert_true(_render(ae.child1.value()).find("BinaryOp(MUL") >= 0)
    assert_true(_render(ae.child2.value()).find("BinaryOp(MUL") >= 0)
    assert_true(_render(ae.child3.value()).find("BinaryOp(MUL") >= 0)
    assert_equal(ae.alias_name.value(), "c")


def test_group_keys_are_substituted_and_the_schema_kept() raises:
    """A group key over the replaced `x` reads `x * 4.0` afterwards, and the
    output names are unchanged. Catches the group-key substitution dropped."""
    var k = ExprArray()
    k.append(Expr.col_ref("x"))
    var out = absorb_expression_into_aggregate(_agg(k^, _sum_x()))
    assert_true(_absorbed(out))
    assert_true(_render(out._aggregate.value()[].group_by[0]).find("BinaryOp(MUL") >= 0)
    assert_equal(out.output_schema.num_columns(), 2)
    assert_equal(out.output_schema.field_name(1), "sx")


def test_count_star_without_alias_is_absorbed_as_is() raises:
    """count(*) has no input and no alias: absorbed, both stay absent. Catches
    an empty slot or alias being invented by the rebuild."""
    var a = AggExprArray()
    a.append(AggExpr(AGG_COUNT, None, None))
    var out = absorb_expression_into_aggregate(_agg(_g_keys(), a^))
    assert_true(_absorbed(out))
    ref ae = out._aggregate.value()[].agg_exprs[0]
    assert_false(Bool(ae.child))
    assert_false(Bool(ae.child1))
    assert_false(Bool(ae.alias_name))


def test_aggregate_over_a_non_project_is_untouched() raises:
    """Aggregate(Scan): nothing to absorb. Catches the PROJECT test dropped."""
    var out = absorb_expression_into_aggregate(
        LogicalPlan.aggregate(_g_keys(), AggExprArray(), _scan())
    )
    assert_equal(Int(out.tag), Int(PLAN_AGGREGATE))
    assert_equal(Int(out._aggregate.value()[].child[].tag), Int(PLAN_SCAN))


# -----------------------------------------------------------------------------
# The recursion arms
# -----------------------------------------------------------------------------


def test_every_wrapper_reaches_an_absorbable_aggregate() raises:
    """Filter, Project, Sort, Limit, Distinct, TopN, both join sides and a
    nested Aggregate each recurse. Catches a recursion arm dropped."""
    var f = absorb_expression_into_aggregate(LogicalPlan.filter(Expr.col_ref("g"), _absorbable()))
    assert_true(_absorbed(f._filter.value()[].child[]))

    var pe = ExprArray()
    pe.append(Expr.col_ref("g"))
    var p = absorb_expression_into_aggregate(LogicalPlan.project(pe^, _absorbable()))
    assert_true(_absorbed(p._project.value()[].child[]))

    var sk: List[String] = ["g"]
    var sd: List[Bool] = [False]
    var s = absorb_expression_into_aggregate(LogicalPlan.sort(sk^, sd^, _absorbable()))
    assert_true(_absorbed(s._sort.value()[].child[]))

    var l = absorb_expression_into_aggregate(LogicalPlan.limit(3, _absorbable()))
    assert_true(_absorbed(l._limit.value()[].child[]))

    var d = absorb_expression_into_aggregate(LogicalPlan.distinct(None, _absorbable()))
    assert_true(_absorbed(d._distinct.value()[].child[]))

    var tk: List[String] = ["g"]
    var td: List[Bool] = [True]
    var t = absorb_expression_into_aggregate(LogicalPlan.topn(tk^, td^, 2, _absorbable()))
    assert_true(_absorbed(t._topn.value()[].child[]))

    var lo: List[String] = ["g"]
    var ro: List[String] = ["g"]
    var j = absorb_expression_into_aggregate(
        LogicalPlan.join(_absorbable(), _absorbable(), lo^, ro^, JOIN_INNER)
    )
    assert_true(_absorbed(j._join.value()[].left[]))
    assert_true(_absorbed(j._join.value()[].right[]))

    var outer = absorb_expression_into_aggregate(
        LogicalPlan.aggregate(_g_keys(), AggExprArray(), _absorbable())
    )
    assert_true(_absorbed(outer._aggregate.value()[].child[]))


def test_a_scan_root_is_returned_unchanged() raises:
    """Catches a walk that raises on a leaf or turns it into another node."""
    var out = absorb_expression_into_aggregate(_scan())
    assert_equal(Int(out.tag), Int(PLAN_SCAN))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# select_aggregates, the plan half: the one-row reduction, the broadcast, the
# hidden whole-frame windows and the filter over an aggregate.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * `select_as_aggregate` takes a list of aggregates (bare or aliased) and
#     names them by polars' rule, declines anything else, and hands back the
#     naming refusal (a non-aggregate accepted, an alias of a column taken for
#     an aggregate, a refusal swallowed);
#   * `bind_agg_operands` re-binds all four operand slots (a slot skipped);
#   * `broadcast_aggregates` declines a list with no aggregate and a pure
#     aggregate `select`, and otherwise turns each top aggregate into a
#     whole-frame window named by its alias or root column;
#   * the hidden-window builders name each window `__komira_agg_<i>`, refuse a
#     STRING operand by name and skip COUNT, computed and unknown operands;
#   * `select_reducing_aggregates` is a PROJECT over a 0-key AGGREGATE;
#     `select_broadcasting_aggregates` a PROJECT over a PARTITION BY;
#   * `filter_over_aggregates` gives the input's columns back, and refuses an
#     INT8 column compared with an aggregate;
#   * `drop_hidden_columns` drops exactly the hidden columns.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_MAX, AGG_MEAN, AGG_SUM
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_GT,
    BIN_MUL,
    EXPR_ALIAS,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_WINDOW_FN,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_FILTER,
    PLAN_PARTITION_BY,
    PLAN_PROJECT,
    SOURCE_PARQUET,
)

from komira_sdk.select_aggregates import (
    HIDDEN_AGG_PREFIX,
    _column_refs,
    _refuse_unserved_window_operands,
    bind_agg_operands,
    broadcast_aggregates,
    drop_hidden_columns,
    filter_over_aggregates,
    select_as_aggregate,
    select_broadcasting_aggregates,
    select_reducing_aggregates,
    with_hidden_aggregate_windows,
)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("i8", ArrowType.INT8, False))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


def _lit() -> Expr:
    return Expr.literal(ScalarValue.from_int(2))


def _agg(op: UInt8, n: String) -> Expr:
    return Expr.agg_fn(op, _c(n))


def _names(plan: LogicalPlan) -> String:
    var out = String()
    for i in range(plan.output_schema.num_columns()):
        if i > 0:
            out += ","
        out += plan.output_schema.field_name(i)
    return out^


def _hidden(i: Int) -> String:
    return String(HIDDEN_AGG_PREFIX) + String(i)


# ---- select_as_aggregate / bind_agg_operands ---------------------------------


def test_select_as_aggregate() raises:
    var why = String()
    assert_false(Bool(select_as_aggregate(ExprArray(), _schema(), why)), "empty")
    var ex = ExprArray()
    ex.append(_agg(AGG_MAX, "a"))
    ex.append(Expr.alias(_agg(AGG_SUM, "f"), "total"))
    var r = select_as_aggregate(ex, _schema(), why)
    assert_true(Bool(r))
    ref aggs = r.value()
    assert_equal(len(aggs), 2)
    assert_equal(Int(aggs[0].func), Int(AGG_MAX))
    assert_equal(aggs[0].alias_name.value(), "a", "polars' name")
    assert_equal(aggs[1].alias_name.value(), "total", "the alias")
    assert_equal(why, "", "no refusal")
    var mixed = ExprArray()
    mixed.append(_agg(AGG_MAX, "a"))
    mixed.append(_c("a"))
    assert_false(Bool(select_as_aggregate(mixed, _schema(), why)), "a column")
    var aliased_col = ExprArray()
    aliased_col.append(Expr.alias(_c("a"), "x"))
    assert_false(Bool(select_as_aggregate(aliased_col, _schema(), why)), "an aliased column")
    assert_equal(why, "")
    var lit_rooted = ExprArray()
    lit_rooted.append(Expr.agg_fn(AGG_SUM, _lit()))
    assert_false(Bool(select_as_aggregate(lit_rooted, _schema(), why)))
    assert_true(why.find("LEFTMOST") != -1, "the naming refusal: " + why)


def test_bind_agg_operands_every_slot() raises:
    var aggs = AggExprArray()
    var ae = AggExpr(AGG_SUM, Optional[Expr](_c("a")), Optional[Expr](_c("f")), Optional[String]("x"))
    ae.child2 = Optional[Expr](_c("a"))
    ae.child3 = Optional[Expr](_c("f"))
    aggs.append(ae^)
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    bind_agg_operands(aggs, _schema())
    assert_equal(aggs[0].child.value().col_ref_name(), "a")
    assert_equal(aggs[0].child1.value().col_ref_name(), "f")
    assert_equal(aggs[0].child2.value().col_ref_name(), "a")
    assert_equal(aggs[0].child3.value().col_ref_name(), "f")
    assert_false(Bool(aggs[1].child), "a childless aggregate stays childless")


# ---- broadcast_aggregates ---------------------------------------------------


def test_broadcast_declines() raises:
    var why = String()
    var none = ExprArray()
    none.append(_c("a"))
    assert_false(Bool(broadcast_aggregates(none, True, why)), "no aggregate")
    var only = ExprArray()
    only.append(_agg(AGG_MAX, "a"))
    assert_false(Bool(broadcast_aggregates(only, False, why)), "select of aggregates")
    assert_true(Bool(broadcast_aggregates(only, True, why)), "with_columns broadcasts")


def test_broadcast_names_each_window() raises:
    var why = String()
    var ex = ExprArray()
    ex.append(_c("s"))
    ex.append(Expr.alias(_agg(AGG_MAX, "a"), "hi"))
    ex.append(_agg(AGG_MEAN, "f"))
    var r = broadcast_aggregates(ex, False, why)
    ref out = r.value()
    assert_equal(len(out), 3)
    assert_equal(Int(out[0].tag), Int(EXPR_COL_REF), "a column passes")
    assert_equal(out[1].alias_name(), "hi")
    assert_equal(Int(out[1].alias_child_ref().tag), Int(EXPR_WINDOW_FN))
    assert_equal(out[2].alias_name(), "f", "the root column")
    assert_equal(Int(out[2].alias_child_ref().tag), Int(EXPR_WINDOW_FN))
    var unnamed = ExprArray()
    unnamed.append(_c("s"))
    unnamed.append(Expr.agg_fn(AGG_SUM, _lit()))
    assert_false(Bool(broadcast_aggregates(unnamed, False, why)))
    assert_true(why.find("LEFTMOST") != -1, why)


# ---- the hidden windows -----------------------------------------------------


def test_unserved_window_operands() raises:
    var ok = List[Expr]()
    ok.append(_agg(AGG_COUNT, "s"))
    ok.append(Expr.agg_fn(AGG_SUM, Expr.binary(BIN_MUL, _c("a"), _lit())))
    ok.append(_agg(AGG_SUM, "nope"))
    ok.append(_agg(AGG_MAX, "f"))
    ok.append(_agg(AGG_MEAN, "i8"))
    _refuse_unserved_window_operands(ok, _schema())
    var bad = List[Expr]()
    bad.append(_agg(AGG_MAX, "a"))
    bad.append(_agg(AGG_MAX, "s"))
    var raised = False
    try:
        _refuse_unserved_window_operands(bad, _schema())
    except e:
        raised = True
        assert_true(String(e).find("column `s` beside the frame's columns") != -1, String(e))
    assert_true(raised, "a STRING operand is refused")


def test_select_reducing_aggregates() raises:
    var ex = ExprArray()
    ex.append(Expr.alias(Expr.binary(BIN_ADD, _agg(AGG_SUM, "a"), _lit()), "t"))
    ex.append(Expr.binary(BIN_ADD, _agg(AGG_MAX, "f"), _lit()))
    ex.append(Expr.alias(_lit(), "k"))
    ex.append(_lit())
    var p = select_reducing_aggregates(ex, _scan())
    assert_equal(Int(p.tag), Int(PLAN_PROJECT))
    ref agg = p.project_data_ref().child[]
    assert_equal(Int(agg.tag), Int(PLAN_AGGREGATE))
    assert_equal(_names(agg), _hidden(0) + "," + _hidden(1))
    ref outs = p.project_data_ref().exprs
    assert_equal(outs[0].alias_name(), "t", "an alias carrying an aggregate")
    assert_equal(outs[1].alias_name(), "f", "an aggregate's root name")
    assert_equal(outs[2].alias_name(), "k", "an alias without one is kept")
    assert_equal(Int(outs[3].tag), Int(EXPR_LITERAL), "a bare literal as built")


def test_select_broadcasting_aggregates() raises:
    var ex = ExprArray()
    ex.append(_c("s"))
    ex.append(Expr.binary(BIN_ADD, _c("a"), _agg(AGG_MAX, "a")))
    var p = select_broadcasting_aggregates(ex, _scan())
    assert_equal(Int(p.tag), Int(PLAN_PROJECT))
    ref inner = p.project_data_ref().child[]
    assert_equal(Int(inner.tag), Int(PLAN_PARTITION_BY))
    assert_equal(_names(inner), "a,f,s,i8," + _hidden(0))
    assert_equal(_names(p), "s,a")


def test_with_hidden_aggregate_windows_names_every_expression() raises:
    var ex = ExprArray()
    ex.append(Expr.binary(BIN_MUL, _c("f"), _lit()))
    ex.append(Expr.alias(_agg(AGG_MEAN, "a"), "m"))
    ex.append(_lit())
    var hoisted = ExprArray()
    var p = with_hidden_aggregate_windows(ex, _scan(), hoisted)
    assert_equal(Int(p.tag), Int(PLAN_PARTITION_BY))
    assert_equal(_names(p), "a,f,s,i8," + _hidden(0))
    assert_equal(len(hoisted), 3)
    assert_equal(hoisted[0].alias_name(), "f", "named even without an aggregate")
    assert_equal(hoisted[1].alias_name(), "m")
    assert_equal(hoisted[1].alias_child_ref().col_ref_name(), _hidden(0))
    assert_equal(Int(hoisted[2].tag), Int(EXPR_LITERAL), "no name: as built")
    var dropped = drop_hidden_columns(p^)
    assert_equal(Int(dropped.tag), Int(PLAN_PROJECT))
    assert_equal(_names(dropped), "a,f,s,i8")


def test_column_refs() raises:
    var refs = _column_refs(_schema())
    assert_equal(len(refs), 4)
    assert_equal(refs[3].col_ref_name(), "i8")


# ---- filter_over_aggregates -------------------------------------------------


def test_filter_over_aggregates() raises:
    var pred = Expr.binary(BIN_GT, _c("a"), _agg(AGG_MEAN, "a"))
    var p = filter_over_aggregates(pred^, _scan())
    assert_equal(Int(p.tag), Int(PLAN_PROJECT))
    assert_equal(_names(p), "a,f,s,i8", "the input's columns back")
    ref f = p.project_data_ref().child[]
    assert_equal(Int(f.tag), Int(PLAN_FILTER))
    assert_equal(Int(f.filter_data_ref().child[].tag), Int(PLAN_PARTITION_BY))
    # A column the input lacks is not this check's to refuse.
    var unknown = Expr.binary(BIN_GT, _c("nope"), _agg(AGG_MEAN, "a"))
    _ = filter_over_aggregates(unknown^, _scan())


def test_filter_over_aggregates_refuses_int8() raises:
    var pred = Expr.binary(BIN_GT, _c("i8"), _agg(AGG_MEAN, "i8"))
    var raised = False
    try:
        _ = filter_over_aggregates(pred^, _scan())
    except e:
        raised = True
        assert_true(String(e).find("a filter comparing the int8 column `i8`") != -1, String(e))
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

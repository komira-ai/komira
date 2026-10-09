# =============================================================================
# optimizer_misc: the schema guards of `_build_topn_below_project`
# =============================================================================
#
# Rule 14b moves a TopN below a Project over an Aggregate. Its proof reads
# three schemas: the Project's (`s_p`), the Aggregate's (`s_x`) and the TopN's
# own, which is the contract with every node above it. No plan constructor
# produces a node whose `output_schema` disagrees with its expressions, so the
# guards that refuse such a node are reached by editing a node's
# `output_schema` after construction (the same method as
# `test_optimizer_agg_group_fd_direct.mojo`). Each test builds a plan the rule
# FIRES on, edits one schema, and asserts the rule now declines: the plan
# comes back as TopN over Project, as built. Each names the defect it catches.
#
# The edits are chosen so that a removed guard lets the rewrite through (a
# wrong plan) rather than reading past a list: a STRING column is no tie-break
# key, a narrowed schema is read only up to its own width.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import Expr, BIN_SUB
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_TOPN,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_misc import push_topn_below_project


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _scan(names: List[String]) -> LogicalPlan:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, True))
    return LogicalPlan.scan("hits.parquet", SOURCE_PARQUET, sb.build())


def _count(name: String) -> AggExpr:
    var no_child: Optional[Expr] = None
    return AggExpr(AGG_COUNT, no_child^, Optional(name))


def _minus(col: String, k: Int) -> Expr:
    return Expr.binary(BIN_SUB, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(k)))


def _q35_topn(with_d: Bool) -> LogicalPlan:
    """TopN [c DESC, client_ip] n=3 over
    Project [client_ip, client_ip-1 AS c1, client_ip-2 AS c2, client_ip-3 AS c3, c]
    over Aggregate [client_ip; count(*) AS c (, count(*) AS d)].

    `d`, when present, is an aggregate column the Project does not read."""
    var names = List[String]()
    names.append("client_ip")
    var gb = ExprArray()
    gb.append(Expr.col_ref("client_ip"))
    var aggs = AggExprArray()
    aggs.append(_count("c"))
    if with_d:
        aggs.append(_count("d"))
    var agg = LogicalPlan.aggregate(gb^, aggs^, _scan(names))
    var p = ExprArray()
    p.append(Expr.col_ref("client_ip"))
    p.append(Expr.alias(_minus("client_ip", 1), "c1"))
    p.append(Expr.alias(_minus("client_ip", 2), "c2"))
    p.append(Expr.alias(_minus("client_ip", 3), "c3"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, agg^)
    var keys = List[String]()
    keys.append("c")
    keys.append("client_ip")
    var desc = List[Bool]()
    desc.append(True)
    desc.append(False)
    return LogicalPlan.topn(keys^, desc^, 3, proj^)


def _fired(imm out: LogicalPlan) raises -> Bool:
    return (
        out.tag == PLAN_PROJECT
        and out._project.value()[].child[].tag == PLAN_TOPN
        and out._project.value()[].child[]._topn.value()[].child[].tag
        == PLAN_AGGREGATE
    )


def _declined(imm out: LogicalPlan) raises -> Bool:
    """Came back as built: TopN over Project over Aggregate."""
    return (
        out.tag == PLAN_TOPN
        and out._topn.value()[].child[].tag == PLAN_PROJECT
        and out._topn.value()[].child[]._project.value()[].child[].tag
        == PLAN_AGGREGATE
    )


def _with_string_column(imm s: Schema) -> Schema:
    """`s` plus one trailing STRING column (no tie-break key)."""
    var sb = SchemaBuilder()
    for i in range(s.num_columns()):
        sb.add_field(s.field_at_unchecked(i))
    sb.add_field(Field("extra", ArrowType.STRING, True))
    return sb.build()


def _first(imm s: Schema, k: Int) -> Schema:
    """The first `k` columns of `s`."""
    var sb = SchemaBuilder()
    for i in range(k):
        sb.add_field(s.field_at_unchecked(i))
    return sb.build()


def _renamed(imm s: Schema, idx: Int, name: String) -> Schema:
    var sb = SchemaBuilder()
    for i in range(s.num_columns()):
        if i == idx:
            sb.add_field(Field(name, s.field_arrow_type(i), True))
        else:
            sb.add_field(s.field_at_unchecked(i))
    return sb.build()


def _retyped(imm s: Schema, idx: Int, t: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    for i in range(s.num_columns()):
        if i == idx:
            sb.add_field(Field(s.field_name(i), t, True))
        else:
            sb.add_field(s.field_at_unchecked(i))
    return sb.build()


# -----------------------------------------------------------------------------
# the unedited plans fire (the baseline every decline below is measured from)
# -----------------------------------------------------------------------------


def test_unedited_plans_fire() raises:
    # Without this, a decline below could come from an unrelated gate.
    assert_true(_fired(push_topn_below_project(_q35_topn(False))))
    assert_true(_fired(push_topn_below_project(_q35_topn(True))))


# -----------------------------------------------------------------------------
# (gate) the Project's schema must match its expression list
# -----------------------------------------------------------------------------


def test_declines_when_the_project_schema_is_wider_than_its_exprs() raises:
    # `s_p` carries a sixth column no Project entry produces. Defect: the
    # `n_out != s_p.num_columns()` gate removed (the proof would reason about
    # a Project output that does not exist and fire).
    var plan = _q35_topn(False)
    ref proj = plan._topn.value()[].child[]
    proj.output_schema = _with_string_column(proj.output_schema)
    assert_true(_declined(push_topn_below_project(plan^)))


def test_declines_when_the_aggregate_schema_is_narrower_than_its_keys() raises:
    # Two group keys, one aggregate column left in `s_x`; the Project reads
    # only the first key. Defect: the `s_x.num_columns() < n_group_keys` gate
    # removed (the totality check reads group-key slot 1 of a one-column
    # schema).
    var names = List[String]()
    names.append("a")
    names.append("b")
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    gb.append(Expr.col_ref("b"))
    var aggs = AggExprArray()
    aggs.append(_count("c"))
    var agg = LogicalPlan.aggregate(gb^, aggs^, _scan(names))
    agg.output_schema = _first(agg.output_schema, 1)
    var p = ExprArray()
    p.append(Expr.col_ref("a"))
    p.append(Expr.alias(_minus("a", 1), "a1"))
    var proj = LogicalPlan.project(p^, agg^)
    var keys = List[String]()
    keys.append("a")
    var desc = List[Bool]()
    desc.append(False)
    var plan = LogicalPlan.topn(keys^, desc^, 3, proj^)
    assert_true(_declined(push_topn_below_project(plan^)))


# -----------------------------------------------------------------------------
# (4) the copied aggregate must re-derive the schema the proof was made against
# -----------------------------------------------------------------------------


def test_declines_when_the_aggregate_copy_is_wider_than_s_x() raises:
    # `s_x` lost the unread column `d`; the copy re-derives all three. Defect:
    # the width comparison removed (the TopN would be rebuilt over an
    # aggregate whose columns the proof never saw).
    var plan = _q35_topn(True)
    ref agg = plan._topn.value()[].child[]._project.value()[].child[]
    agg.output_schema = _first(agg.output_schema, 2)
    assert_true(_declined(push_topn_below_project(plan^)))


def test_declines_when_the_aggregate_copy_names_a_column_differently() raises:
    # `s_x` calls the unread column `zz`; the copy calls it `d`. Defect: the
    # per-name comparison removed.
    var plan = _q35_topn(True)
    ref agg = plan._topn.value()[].child[]._project.value()[].child[]
    agg.output_schema = _renamed(agg.output_schema, 2, "zz")
    assert_true(_declined(push_topn_below_project(plan^)))


# -----------------------------------------------------------------------------
# (5) post-condition: the rewritten subtree keeps the TopN's output schema
# -----------------------------------------------------------------------------


def test_declines_when_the_topn_schema_has_another_width() raises:
    # The TopN declares four columns; the rewrite would emit five. Defect:
    # the width post-condition removed (the parent would see a column it
    # never declared).
    var plan = _q35_topn(False)
    plan.output_schema = _first(plan.output_schema, 4)
    assert_true(_declined(push_topn_below_project(plan^)))


def test_declines_when_the_topn_schema_names_a_column_differently() raises:
    # The TopN calls column 1 `zz`; the rewrite would call it `c1`. Defect:
    # the name post-condition removed.
    var plan = _q35_topn(False)
    plan.output_schema = _renamed(plan.output_schema, 1, "zz")
    assert_true(_declined(push_topn_below_project(plan^)))


def test_declines_when_the_topn_schema_types_a_column_differently() raises:
    # The TopN declares `client_ip` FLOAT64; the rewrite would emit INT64.
    # Defect: the type post-condition removed.
    var plan = _q35_topn(False)
    plan.output_schema = _retyped(plan.output_schema, 0, ArrowType.FLOAT64)
    var out = push_topn_below_project(plan^)
    assert_true(_declined(out))
    assert_equal(out.output_schema.field_name(0), "client_ip")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

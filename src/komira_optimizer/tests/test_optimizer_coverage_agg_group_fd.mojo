# =============================================================================
# optimizer_agg_group_fd: the surviving-key name post-condition
# =============================================================================
#
# After the rewrite, `_build_fd_elided` checks that the new Aggregate gave every
# surviving key its own name back. `LogicalPlan.aggregate` names duplicate keys
# `ip`, `ip_1`, so two group keys both reading `ip` never pass step (1) as
# built. Editing the old Aggregate's `output_schema` to call column 1 `ip`
# again (the method of `test_optimizer_agg_group_fd_direct.mojo`) lets every
# earlier gate pass: both `ip` keys are base keys and `k = ip - 1` is elided.
# The rebuilt Aggregate over [ip, ip] names its columns [ip, ip_1, c], so the
# post-condition must refuse it.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import Expr, BIN_SUB
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_AGGREGATE,
    PLAN_PROJECT,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_agg_group_fd import (
    elide_functionally_dependent_group_keys,
)


def _renamed(imm s: Schema, idx: Int, name: String) -> Schema:
    var sb = SchemaBuilder()
    for i in range(s.num_columns()):
        if i == idx:
            sb.add_field(Field(name, s.field_arrow_type(i), True))
        else:
            sb.add_field(s.field_at_unchecked(i))
    return sb.build()


def test_declines_when_a_surviving_key_comes_back_renamed() raises:
    """Project [ip] over Aggregate [ip, ip, k; count(*) AS c] over
    Project [ip, ip-1 AS k], with the Aggregate's column 1 renamed `ip`.

    Defect caught: the surviving-key name check removed. The rule would then
    emit Aggregate [ip, ip] whose second column is `ip_1`, a column no plan
    above it was proven against. Asserted: the plan comes back unchanged, the
    Aggregate still has three keys and its schema still reads [ip, ip, k, c]."""
    var sb = SchemaBuilder()
    sb.add_field(Field("ip", ArrowType.INT64, False))
    var scan = LogicalPlan.scan("hits.parquet", SOURCE_PARQUET, sb.build())
    var inner = ExprArray()
    inner.append(Expr.col_ref("ip"))
    inner.append(Expr.alias(
        Expr.binary(BIN_SUB, Expr.col_ref("ip"), Expr.literal(ScalarValue.from_int(1))),
        "k",
    ))
    var gb = ExprArray()
    gb.append(Expr.col_ref("ip"))
    gb.append(Expr.col_ref("ip"))
    gb.append(Expr.col_ref("k"))
    var aggs = AggExprArray()
    var no_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, no_child^, Optional(String("c"))))
    var agg = LogicalPlan.aggregate(gb^, aggs^, LogicalPlan.project(inner^, scan^))
    assert_equal(agg.output_schema.field_name(1), "ip_1")
    agg.output_schema = _renamed(agg.output_schema, 1, "ip")
    var outer = ExprArray()
    outer.append(Expr.col_ref("ip"))
    var plan = LogicalPlan.project(outer^, agg^)

    var out = elide_functionally_dependent_group_keys(plan^)
    assert_equal(out.tag, PLAN_PROJECT)
    ref out_agg = out._project.value()[].child[]
    assert_equal(out_agg.tag, PLAN_AGGREGATE)
    assert_equal(len(out_agg._aggregate.value()[].group_by), 3)
    assert_equal(out_agg.output_schema.num_columns(), 4)
    assert_equal(out_agg.output_schema.field_name(0), "ip")
    assert_equal(out_agg.output_schema.field_name(1), "ip")
    assert_equal(out_agg.output_schema.field_name(2), "k")
    assert_equal(out_agg.output_schema.field_name(3), "c")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_optimizer_sum_rewrite.mojo -- the SUM(x+C) rewrite AND its dedup partner.
#
# ⛔ THE TWO PASSES ARE TESTED TOGETHER BECAUSE THEY ARE ONE OPTIMISATION.
# `rewrite_sum_of_offset` emits one SUM per match plus a COUNT per non-zero offset;
# `dedup_common_aggregates` is what collapses them. A test of either alone
# cannot see the property that matters -- that ClickBench cbq29's 90 SUMs, 89
# of them over a computed `rw + k`, become 2 aggregates over the RAW column.
#
# WHAT EACH CASE FALSIFIES
#   * `test_sum_of_offsets_collapses_to_two_aggregates` -- the win itself.
#     Without the rewrite the node keeps 3 SUMs, two over computed inputs;
#     without the dedup it has 5.
#   * `test_output_schema_is_byte_identical` -- the rewrite must not move a
#     single output name or position. This is the one that fails if the private
#     `__sr_*` / `__acse_*` aliases leak.
#   * `test_dedup_does_not_renumber_a_surviving_unaliased_aggregate` -- the
#     `_disambiguate_field` hazard: `sum(a), sum(a), sum(b)` names its outputs
#     `sum, sum_1, sum_2`, and a dedup that did NOT force explicit aliases
#     would rename the surviving `sum(b)` to `sum_1`.
#   * the four DECLINE cases -- float aggregand, float offset, grouped node,
#     and a node with no offset at all. Each is a case where firing would be
#     either a wrong answer or pure overhead.
# =============================================================================

from std.collections import List, Optional
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT, AGG_MAX
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_SUB
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_AGGREGATE,
    PLAN_PROJECT,
    SOURCE_PARQUET,
)

from komira_optimizer.optimizer_sum_rewrite import rewrite_sum_of_offset
from komira_optimizer.optimizer_agg_cse import dedup_common_aggregates


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _scan() -> LogicalPlan:
    """`hits(rw INT64, f FLOAT64, other INT64)` -- the cbq29 shape in miniature."""
    var sb = SchemaBuilder()
    sb.add_field(Field("rw", ArrowType.INT64, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    sb.add_field(Field("other", ArrowType.INT64, True))
    return LogicalPlan.scan("hits.parquet", SOURCE_PARQUET, sb.build())


def _sum_of(var e: Expr, name: String) -> AggExpr:
    return AggExpr(AGG_SUM, Optional[Expr](e^), Optional[String](name))


def _plus(name: String, k: Int) -> Expr:
    return Expr.binary(
        BIN_ADD, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(k))
    )


def _first_aggregate(imm plan: LogicalPlan) raises -> Int:
    """Number of agg exprs at the first PLAN_AGGREGATE below `plan`, or -1 if
    there is none. Walks Project chains only -- which is all these plans have.
    """
    if plan.tag == PLAN_AGGREGATE:
        return len(plan._aggregate.value()[].agg_exprs)
    if plan.tag == PLAN_PROJECT:
        return _first_aggregate(plan._project.value()[].child[])
    return -1


def _names(imm plan: LogicalPlan) -> List[String]:
    var out = List[String]()
    for i in range(plan.output_schema.num_columns()):
        out.append(plan.output_schema.field_name(i))
    return out^


# -----------------------------------------------------------------------------
# the win
# -----------------------------------------------------------------------------


def test_sum_of_offsets_collapses_to_two_aggregates() raises:
    """`sum(rw), sum(rw+1), sum(rw+2)` -- cbq29 at N=3 -- has 3 aggregates, 5
    after the rewrite and 2 after the dedup."""
    var aggs = AggExprArray()
    aggs.append(_sum_of(Expr.col_ref("rw"), String("s0")))
    aggs.append(_sum_of(_plus(String("rw"), 1), String("s1")))
    aggs.append(_sum_of(_plus(String("rw"), 2), String("s2")))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    assert_equal(_first_aggregate(plan), 3)

    # The rewrite ALONE: 3 -> 5 (sum, sum+count, sum+count). This assertion is
    # the one that says the two passes are a pair: the rewrite is a
    # PESSIMISATION at this point.
    var rewritten = rewrite_sum_of_offset(plan^)
    assert_equal(rewritten.tag, PLAN_PROJECT)
    assert_equal(_first_aggregate(rewritten), 5)

    # The pair: 5 -> 2.
    var deduped = dedup_common_aggregates(rewritten^)
    assert_equal(_first_aggregate(deduped), 2)


def test_output_schema_is_byte_identical() raises:
    """Neither pass may move a name or a position. The private `__sr_*` /
    `__acse_*` aliases must be invisible from outside the node."""
    var aggs = AggExprArray()
    aggs.append(_sum_of(Expr.col_ref("rw"), String("s0")))
    aggs.append(_sum_of(_plus(String("rw"), 7), String("s1")))
    aggs.append(AggExpr(AGG_MAX, Optional[Expr](Expr.col_ref("other")), Optional[String]("mx")))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var before = _names(plan)

    var after_plan = dedup_common_aggregates(rewrite_sum_of_offset(plan^))
    var after = _names(after_plan)

    assert_equal(len(after), len(before))
    for i in range(len(before)):
        assert_equal(after[i], before[i])
    # The MAX is untouched and still there.
    assert_equal(_first_aggregate(after_plan), 3)


def test_subtraction_folds_with_a_negative_offset() raises:
    """`sum(rw - 5)` is the same rewrite with C = -5."""
    var aggs = AggExprArray()
    aggs.append(
        _sum_of(
            Expr.binary(
                BIN_SUB,
                Expr.col_ref("rw"),
                Expr.literal(ScalarValue.from_int(5)),
            ),
            String("s"),
        )
    )
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var out = dedup_common_aggregates(rewrite_sum_of_offset(plan^))
    assert_equal(out.tag, PLAN_PROJECT)
    assert_equal(_first_aggregate(out), 2)


def test_dedup_does_not_renumber_a_surviving_unaliased_aggregate() raises:
    """`sum(rw), sum(rw), sum(other)` publishes `sum, sum_1, sum_2`. Deduping to
    two aggregates must NOT rename the survivor to `sum_1`."""
    var aggs = AggExprArray()
    var c0: Optional[Expr] = Optional(Expr.col_ref("rw"))
    var c1: Optional[Expr] = Optional(Expr.col_ref("rw"))
    var c2: Optional[Expr] = Optional(Expr.col_ref("other"))
    var none_name: Optional[String] = None
    aggs.append(AggExpr(AGG_SUM, c0^, none_name.copy()))
    aggs.append(AggExpr(AGG_SUM, c1^, none_name.copy()))
    aggs.append(AggExpr(AGG_SUM, c2^, none_name^))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var before = _names(plan)
    assert_equal(len(before), 3)

    var out = dedup_common_aggregates(plan^)
    assert_equal(_first_aggregate(out), 2)
    var after = _names(out)
    assert_equal(len(after), 3)
    for i in range(3):
        assert_equal(after[i], before[i])


# -----------------------------------------------------------------------------
# the declines -- each one is a wrong answer or pure overhead if it fires
# -----------------------------------------------------------------------------


def test_float_aggregand_is_declined() raises:
    """⛔ `sum(f + 1)` over a FLOAT column must NOT fold: re-associating an IEEE
    sum changes the answer."""
    var aggs = AggExprArray()
    aggs.append(_sum_of(_plus(String("f"), 1), String("s")))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var out = rewrite_sum_of_offset(plan^)
    assert_equal(out.tag, PLAN_AGGREGATE)
    assert_equal(_first_aggregate(out), 1)


def test_float_offset_is_declined() raises:
    """⛔ `sum(rw + 1.5)` -- integral column, FLOAT offset. Still a float sum."""
    var aggs = AggExprArray()
    aggs.append(
        _sum_of(
            Expr.binary(
                BIN_ADD,
                Expr.col_ref("rw"),
                Expr.literal(ScalarValue.from_float(1.5)),
            ),
            String("s"),
        )
    )
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var out = rewrite_sum_of_offset(plan^)
    assert_equal(out.tag, PLAN_AGGREGATE)


def test_grouped_aggregate_is_declined() raises:
    """⛔ 0-key only. A grouped fold would run the post-aggregate arithmetic per
    GROUP and add a real per-group COUNT accumulator."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("other"))
    var aggs = AggExprArray()
    aggs.append(_sum_of(_plus(String("rw"), 1), String("s")))
    var plan = LogicalPlan.aggregate(gb^, aggs^, _scan())
    var out = rewrite_sum_of_offset(plan^)
    assert_equal(out.tag, PLAN_AGGREGATE)


def test_a_node_with_no_offset_is_left_alone() raises:
    """⛔ GATE 4. A plain `sum(rw)` must not acquire a Project and a COUNT it
    has no use for. Without this gate every 0-key plain SUM would get
    both."""
    var aggs = AggExprArray()
    aggs.append(_sum_of(Expr.col_ref("rw"), String("s0")))
    aggs.append(_sum_of(Expr.col_ref("other"), String("s1")))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var out = rewrite_sum_of_offset(plan^)
    assert_equal(out.tag, PLAN_AGGREGATE)
    assert_equal(_first_aggregate(out), 2)


def test_dedup_without_duplicates_is_a_noop() raises:
    """The dedup half on its own, on the shape a human writes: untouched."""
    var aggs = AggExprArray()
    aggs.append(_sum_of(Expr.col_ref("rw"), String("s0")))
    aggs.append(_sum_of(Expr.col_ref("other"), String("s1")))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var out = dedup_common_aggregates(plan^)
    assert_equal(out.tag, PLAN_AGGREGATE)
    assert_equal(_first_aggregate(out), 2)


def test_a_count_is_not_deduped_into_a_sum() raises:
    """`sum(rw)` and `count(rw)` share an INPUT but not a FUNCTION. Collapsing
    them would answer the row count for the sum."""
    var aggs = AggExprArray()
    aggs.append(_sum_of(Expr.col_ref("rw"), String("s")))
    aggs.append(
        AggExpr(
            AGG_COUNT,
            Optional[Expr](Expr.col_ref("rw")),
            Optional[String]("c"),
        )
    )
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var out = dedup_common_aggregates(plan^)
    assert_equal(out.tag, PLAN_AGGREGATE)
    assert_equal(_first_aggregate(out), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

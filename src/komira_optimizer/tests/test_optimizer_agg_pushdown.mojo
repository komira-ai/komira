# =============================================================================
# Tests for partial-aggregate pushdown below join
# =============================================================================
#
# The production rule is GATED off by ENABLE_AGG_PUSHDOWN_BELOW_JOIN = False.
# These tests cover:
#
#   1. Default-gate behaviour: push_aggregate_below_join is a no-op for any
#      shape, even one that would otherwise rewrite. This is the load-bearing
#      contract for v0.4 today -- without uniqueness inference, the only
#      sound action is to leave the plan alone.
#
#   2. Clause-level coverage via the gate-bypassed _classify_push_inner:
#      each of clauses (a), (b), (c) and the auxiliary checks (whitelist,
#      side-keys-in-group-by, name collision) must independently REJECT a
#      candidate that violates only that clause.
#
#   3. AVG decomposition: when the gate WERE flipped on, AVG must split
#      into partial SUM + partial COUNT and emit two merge SUM aggregates
#      with the v0.3-compatible aliases.
#
# The clause-(c) test is currently UNREACHABLE in the all-pass direction
# because _other_side_key_unique() unconditionally returns False (no
# uniqueness infra). The test asserts that fact -- the day uniqueness
# inference lands and starts returning True for some shape, the assertion
# will flip and the developer will know to extend the test suite.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import (
    AggExpr,
    sum as agg_sum,
    count as agg_count,
    min as agg_min,
    max as agg_max,
    mean as agg_mean,
    AGG_SUM,
    AGG_COUNT,
    AGG_MIN,
    AGG_MAX,
    AGG_MEAN,
)
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_SEMI,
    JOIN_ANTI,
)
from komira_optimizer.optimizer_partial_agg import (
    push_aggregate_below_join,
    ENABLE_AGG_PUSHDOWN_BELOW_JOIN,
    _classify_push,
    _classify_push_inner,
    _PUSH_NONE,
    _PUSH_LEFT,
    _PUSH_RIGHT,
    _build_partial_and_merge,
    _other_side_key_unique,
)


# =============================================================================
# Schema builders
# =============================================================================


def _orders_schema() raises -> Schema:
    """orders: order_id, customer_id, region, price."""
    var sb = SchemaBuilder()
    sb.add_field(Field("order_id", ArrowType.INT64, False))
    sb.add_field(Field("customer_id", ArrowType.INT64, False))
    sb.add_field(Field("region", ArrowType.INT64, False))
    sb.add_field(Field("price", ArrowType.INT64, False))
    return sb.build()


def _customers_schema() raises -> Schema:
    """customers: customer_id (PK), country."""
    var sb = SchemaBuilder()
    sb.add_field(Field("customer_id", ArrowType.INT64, False))
    sb.add_field(Field("country", ArrowType.INT64, False))
    return sb.build()


def _str_list1(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _str_list2(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def _scan_orders() raises -> LogicalPlan:
    return LogicalPlan.scan(
        String("orders.parquet"), SOURCE_PARQUET, _orders_schema()
    )


def _scan_customers() raises -> LogicalPlan:
    return LogicalPlan.scan(
        String("customers.parquet"), SOURCE_PARQUET, _customers_schema()
    )


# All group-by + agg-input columns reference ONLY the LEFT (orders) side.
# Pushing onto LEFT preserves the join key (customer_id is in group_by).
def _build_pushable_left_plan() raises -> LogicalPlan:
    """Aggregate(group_by=[customer_id], SUM(price), COUNT(*), MIN(price),
                 MAX(price))
       Join(orders, customers, INNER, on=customer_id).
    """
    var join = LogicalPlan.join(
        _scan_orders(),
        _scan_customers(),
        _str_list1("customer_id"),
        _str_list1("customer_id"),
        JOIN_INNER,
    )
    var gb = ExprArray()
    gb.append(col("customer_id").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("price")).alias("total_price"))
    aggs.append(agg_count(col("price")).alias("n"))
    aggs.append(agg_min(col("price")).alias("min_price"))
    aggs.append(agg_max(col("price")).alias("max_price"))
    return LogicalPlan.aggregate(gb^, aggs^, join^)


# =============================================================================
# 1. Gate-default behaviour
# =============================================================================


def test_gate_default_is_disabled() raises:
    """The comptime gate must remain False until uniqueness infra lands."""
    assert_false(
        ENABLE_AGG_PUSHDOWN_BELOW_JOIN,
        "ENABLE_AGG_PUSHDOWN_BELOW_JOIN must default to False",
    )
    print("test_gate_default_is_disabled OK")


def test_pushdown_is_noop_when_gated() raises:
    """Even on a perfectly pushable shape, the rule must not transform."""
    var plan = _build_pushable_left_plan()
    var rewritten = push_aggregate_below_join(plan^)

    # The top-level shape must remain Aggregate(Join(Scan, Scan)) -- if the
    # rule had fired we would see Aggregate(Join(Aggregate(Scan), Scan)).
    assert_equal(Int(rewritten.tag), Int(PLAN_AGGREGATE), "top must stay Aggregate")
    var child_tag = rewritten._aggregate.value()[].child[].tag
    assert_equal(Int(child_tag), Int(PLAN_JOIN), "child must remain Join")
    var grandchild_tag = rewritten._aggregate.value()[].child[]._join.value()[].left[].tag
    # Left child of the join must STILL be a Scan (no partial aggregate).
    assert_false(
        Int(grandchild_tag) == Int(PLAN_AGGREGATE),
        "no partial Aggregate may be inserted below the join while the gate is False",
    )
    print("test_pushdown_is_noop_when_gated OK")


def test_classify_push_returns_none_when_gated() raises:
    """The public _classify_push must return _PUSH_NONE on a pushable shape."""
    var plan = _build_pushable_left_plan()
    ref join_ref = plan._aggregate.value()[].child[]
    var decision = _classify_push(plan, join_ref)
    assert_equal(
        Int(decision.kind),
        Int(_PUSH_NONE),
        "gated _classify_push must always return _PUSH_NONE",
    )
    print("test_classify_push_returns_none_when_gated OK")


# =============================================================================
# 2. Clause-level coverage (gate-bypassed)
# =============================================================================
#
# We use _classify_push_inner so we can isolate each clause. _PUSH_NONE means
# the rule rejected the candidate; _PUSH_LEFT/_PUSH_RIGHT means it would
# fire (subject to clause (c) which today always rejects).


def test_clause_a_rejects_left_join() raises:
    """LEFT join must not be rewritten (row-preservation semantics)."""
    var join = LogicalPlan.join(
        _scan_orders(),
        _scan_customers(),
        _str_list1("customer_id"),
        _str_list1("customer_id"),
        JOIN_LEFT,
    )
    var gb = ExprArray()
    gb.append(col("customer_id").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("price")).alias("s"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_push_inner(plan, join_ref)
    assert_equal(Int(d.kind), Int(_PUSH_NONE), "LEFT join must reject")
    print("test_clause_a_rejects_left_join OK")


def test_clause_a_rejects_semi_join() raises:
    var join = LogicalPlan.join(
        _scan_orders(),
        _scan_customers(),
        _str_list1("customer_id"),
        _str_list1("customer_id"),
        JOIN_SEMI,
    )
    var gb = ExprArray()
    gb.append(col("customer_id").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("price")).alias("s"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_push_inner(plan, join_ref)
    assert_equal(Int(d.kind), Int(_PUSH_NONE), "SEMI join must reject")
    print("test_clause_a_rejects_semi_join OK")


def test_clause_a_rejects_anti_join() raises:
    var join = LogicalPlan.join(
        _scan_orders(),
        _scan_customers(),
        _str_list1("customer_id"),
        _str_list1("customer_id"),
        JOIN_ANTI,
    )
    var gb = ExprArray()
    gb.append(col("customer_id").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("price")).alias("s"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_push_inner(plan, join_ref)
    assert_equal(Int(d.kind), Int(_PUSH_NONE), "ANTI join must reject")
    print("test_clause_a_rejects_anti_join OK")


def test_clause_b_rejects_columns_spanning_both_sides() raises:
    """Group-by references both sides => not pushable."""
    var join = LogicalPlan.join(
        _scan_orders(),
        _scan_customers(),
        _str_list1("customer_id"),
        _str_list1("customer_id"),
        JOIN_INNER,
    )
    var gb = ExprArray()
    gb.append(col("region").copy_expr())   # left side
    gb.append(col("country").copy_expr())  # right side
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("price")).alias("s"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_push_inner(plan, join_ref)
    assert_equal(
        Int(d.kind),
        Int(_PUSH_NONE),
        "group-by spanning both sides must reject",
    )
    print("test_clause_b_rejects_columns_spanning_both_sides OK")


def test_clause_b_rejects_agg_input_on_other_side() raises:
    """Group-by on left, agg input on right => not pushable."""
    var join = LogicalPlan.join(
        _scan_orders(),
        _scan_customers(),
        _str_list1("customer_id"),
        _str_list1("customer_id"),
        JOIN_INNER,
    )
    var gb = ExprArray()
    gb.append(col("customer_id").copy_expr())  # both sides have this
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("country")).alias("s"))  # right-only
    aggs.append(agg_min(col("price")).alias("m"))    # left-only
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_push_inner(plan, join_ref)
    assert_equal(
        Int(d.kind),
        Int(_PUSH_NONE),
        "agg inputs spanning both sides must reject",
    )
    print("test_clause_b_rejects_agg_input_on_other_side OK")


def test_clause_c_other_side_unique_returns_false_today() raises:
    """Uniqueness infra not yet present -- helper must always say False.

    When uniqueness inference lands this assertion will flip; the developer
    must then extend the test suite to cover the all-pass direction.
    """
    var plan = _build_pushable_left_plan()
    ref join_ref = plan._aggregate.value()[].child[]
    assert_false(
        _other_side_key_unique(join_ref, True),
        "_other_side_key_unique must return False until uniqueness infra lands",
    )
    assert_false(
        _other_side_key_unique(join_ref, False),
        "_other_side_key_unique must return False until uniqueness infra lands",
    )
    print("test_clause_c_other_side_unique_returns_false_today OK")


def test_clause_c_blocks_otherwise_pushable_shape() raises:
    """Even with clauses (a) + (b) green, clause (c) blocks the rewrite."""
    var plan = _build_pushable_left_plan()
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_push_inner(plan, join_ref)
    # All other clauses pass; clause (c) returns False; result must be NONE.
    assert_equal(
        Int(d.kind),
        Int(_PUSH_NONE),
        "clause (c) must reject when uniqueness is unproven",
    )
    print("test_clause_c_blocks_otherwise_pushable_shape OK")


# =============================================================================
# 3. Whitelist + side-keys-in-group-by (auxiliary correctness checks)
# =============================================================================


def test_whitelist_rejects_count_distinct() raises:
    """COUNT(DISTINCT) is not partial-aggregatable across joins."""
    from komira_plan_expr.agg_expr import count_distinct
    var join = LogicalPlan.join(
        _scan_orders(),
        _scan_customers(),
        _str_list1("customer_id"),
        _str_list1("customer_id"),
        JOIN_INNER,
    )
    var gb = ExprArray()
    gb.append(col("customer_id").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("price")).alias("d"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_push_inner(plan, join_ref)
    assert_equal(
        Int(d.kind),
        Int(_PUSH_NONE),
        "COUNT_DISTINCT must be rejected by whitelist",
    )
    print("test_whitelist_rejects_count_distinct OK")


def test_side_join_key_must_be_in_group_by() raises:
    """If the pushed-side join key is not in group_by, we cannot push."""
    var join = LogicalPlan.join(
        _scan_orders(),
        _scan_customers(),
        _str_list1("customer_id"),
        _str_list1("customer_id"),
        JOIN_INNER,
    )
    # group_by is `region` (left-side col), NOT the join key `customer_id`.
    var gb = ExprArray()
    gb.append(col("region").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("price")).alias("s"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, join^)
    ref join_ref = plan._aggregate.value()[].child[]
    var d = _classify_push_inner(plan, join_ref)
    assert_equal(
        Int(d.kind),
        Int(_PUSH_NONE),
        "join key not in group_by must reject",
    )
    print("test_side_join_key_must_be_in_group_by OK")


# =============================================================================
# 4. Partial+merge construction (AVG decomposition)
# =============================================================================


def test_build_partial_merge_sum_count_min_max() raises:
    """SUM/COUNT/MIN/MAX produce 1 partial + 1 merge each, with the
    correct merge op (COUNT becomes SUM, others stay)."""
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("x")).alias("s"))
    aggs.append(agg_count(col("x")).alias("c"))
    aggs.append(agg_min(col("x")).alias("mn"))
    aggs.append(agg_max(col("x")).alias("mx"))

    var partials = AggExprArray()
    var merges = AggExprArray()
    _build_partial_and_merge(aggs, partials, merges)

    assert_equal(len(partials), 4, "4 partial aggs expected")
    assert_equal(len(merges), 4, "4 merge aggs expected")

    # Partial funcs match input funcs.
    assert_equal(Int(partials[0].func), Int(AGG_SUM), "partial[0] = SUM")
    assert_equal(Int(partials[1].func), Int(AGG_COUNT), "partial[1] = COUNT")
    assert_equal(Int(partials[2].func), Int(AGG_MIN), "partial[2] = MIN")
    assert_equal(Int(partials[3].func), Int(AGG_MAX), "partial[3] = MAX")

    # Merge funcs: COUNT->SUM, others unchanged.
    assert_equal(Int(merges[0].func), Int(AGG_SUM), "merge[0] = SUM")
    assert_equal(Int(merges[1].func), Int(AGG_SUM), "merge[1] = SUM (count->sum)")
    assert_equal(Int(merges[2].func), Int(AGG_MIN), "merge[2] = MIN")
    assert_equal(Int(merges[3].func), Int(AGG_MAX), "merge[3] = MAX")

    # Partial alias prefix.
    assert_true(
        partials[0].alias_name.value().startswith("__partial_sum_"),
        "partial sum alias must start with __partial_sum_",
    )
    print("test_build_partial_merge_sum_count_min_max OK")


def test_avg_decomposes_into_two_partials_two_merges() raises:
    """As in v0.3: AVG -> partial SUM + partial COUNT,
    merge SUM + SUM, with __partial_avg_sum_/__partial_avg_count_ aliases.
    """
    var aggs = AggExprArray()
    aggs.append(agg_mean(col("price")).alias("avg_price"))

    var partials = AggExprArray()
    var merges = AggExprArray()
    _build_partial_and_merge(aggs, partials, merges)

    # AVG produces TWO partial aggs and TWO merge aggs.
    assert_equal(len(partials), 2, "AVG -> 2 partial aggs")
    assert_equal(len(merges), 2, "AVG -> 2 merge aggs")

    # Partials are SUM and COUNT of the original input.
    assert_equal(Int(partials[0].func), Int(AGG_SUM), "partial[0] = SUM(input)")
    assert_equal(Int(partials[1].func), Int(AGG_COUNT), "partial[1] = COUNT(input)")
    assert_equal(
        partials[0].alias_name.value(),
        String("__partial_avg_sum_avg_price"),
        "partial SUM alias",
    )
    assert_equal(
        partials[1].alias_name.value(),
        String("__partial_avg_count_avg_price"),
        "partial COUNT alias",
    )

    # Both merges are SUM and reference the partial aliases.
    assert_equal(Int(merges[0].func), Int(AGG_SUM), "merge[0] = SUM")
    assert_equal(Int(merges[1].func), Int(AGG_SUM), "merge[1] = SUM")
    assert_equal(
        merges[0].alias_name.value(),
        String("__partial_avg_sum_avg_price"),
        "merge SUM alias preserves partial-sum name",
    )
    assert_equal(
        merges[1].alias_name.value(),
        String("__partial_avg_count_avg_price"),
        "merge COUNT alias preserves partial-count name",
    )
    print("test_avg_decomposes_into_two_partials_two_merges OK")


# =============================================================================
# Test runner
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

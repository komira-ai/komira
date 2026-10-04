# =============================================================================
# DetectPerfectHashAgg planner-assertion test
# =============================================================================
#
# Proves the planner rewrite rule recognises the B-1 benchmark plan shape:
#
#       Aggregate(group=[col("key10")], aggs=[SUM(val).alias(total)],
#                 child=Scan(Parquet, "b1.parquet"))
#
# Negative cases guard against silent fall-through to the FlatHash path:
#   * 2-key agg                         -> ineligible
#   * COUNT_DISTINCT present            -> ineligible
#   * STRING key                        -> ineligible
#   * Non-scan child (Filter, Project)  -> ineligible
#   * No aggregates                     -> ineligible
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.plan.agg_expr import (
    AggExpr,
    count_distinct,
    sum as agg_sum,
)
from komira_core.plan.col_expr import col
from komira_core.plan.expr import Expr
from komira_core.plan.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
)
from komira_compiler.optimizer_perfect_hash import detect_perfect_hash_agg_shape


# =============================================================================
# Helpers -- construct B-1-shaped plans
# =============================================================================


def _b1_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("key10", ArrowType.INT64, False))
    sb.add_field(Field("val", ArrowType.FLOAT64, False))
    return sb.build()


def _make_parquet_scan(var schema: Schema) raises -> LogicalPlan:
    return LogicalPlan.scan(
        String("b1.parquet"),
        SOURCE_PARQUET,
        schema^,
    )


def _b1_aggregate() raises -> LogicalPlan:
    """The exact plan shape B-1 produces: SELECT key10, SUM(val) FROM
    parquet GROUP BY key10.
    """
    var gb = ExprArray()
    gb.append(col("key10").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("val")).alias("total"))
    var scan = _make_parquet_scan(_b1_schema())
    return LogicalPlan.aggregate(gb^, aggs^, scan^)


# =============================================================================
# Positive case
# =============================================================================


def test_b1_shape_is_detected() raises:
    var plan = _b1_aggregate()
    assert_true(
        detect_perfect_hash_agg_shape(plan),
        "B-1 shape (INT64 key + SUM + Scan(Parquet)) must be detected",
    )
    print("test_b1_shape_is_detected OK")


# =============================================================================
# Negative cases
# =============================================================================


def test_two_key_agg_rejected() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("k1", ArrowType.INT64, False))
    sb.add_field(Field("k2", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.FLOAT64, False))
    var gb = ExprArray()
    gb.append(col("k1").copy_expr())
    gb.append(col("k2").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")))
    var scan = _make_parquet_scan(sb.build())
    var plan = LogicalPlan.aggregate(gb^, aggs^, scan^)
    assert_true(
        not detect_perfect_hash_agg_shape(plan),
        "2-key agg must be rejected",
    )
    print("test_two_key_agg_rejected OK")


def test_count_distinct_rejected() raises:
    var gb = ExprArray()
    gb.append(col("key10").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("val")))
    var scan = _make_parquet_scan(_b1_schema())
    var plan = LogicalPlan.aggregate(gb^, aggs^, scan^)
    assert_true(
        not detect_perfect_hash_agg_shape(plan),
        "COUNT_DISTINCT must be rejected (Phase 2c scope)",
    )
    print("test_count_distinct_rejected OK")


def test_string_key_rejected() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("name", ArrowType.STRING, False))
    sb.add_field(Field("v", ArrowType.FLOAT64, False))
    var gb = ExprArray()
    gb.append(col("name").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")))
    var scan = _make_parquet_scan(sb.build())
    var plan = LogicalPlan.aggregate(gb^, aggs^, scan^)
    assert_true(
        not detect_perfect_hash_agg_shape(plan),
        "STRING key must fall through to FlatHash",
    )
    print("test_string_key_rejected OK")


def test_filter_between_scan_and_agg_rejected() raises:
    """Filter above the Parquet scan breaks the direct Scan child
    requirement -- the detector conservatively rejects, forcing B-1
    shapes with filters to the FlatHash path (matches the legacy
    `execute_streaming_parquet_agg_ph` gate which also requires
    has_filter=False).
    """
    var scan = _make_parquet_scan(_b1_schema())
    var pred = col("val") > 0.0
    var filt = LogicalPlan.filter(pred^, scan^)
    var gb = ExprArray()
    gb.append(col("key10").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("val")))
    var plan = LogicalPlan.aggregate(gb^, aggs^, filt^)
    assert_true(
        not detect_perfect_hash_agg_shape(plan),
        "Filter between Scan and Agg must be rejected",
    )
    print("test_filter_between_scan_and_agg_rejected OK")


def test_no_agg_exprs_rejected() raises:
    var gb = ExprArray()
    gb.append(col("key10").copy_expr())
    var aggs = AggExprArray()
    var scan = _make_parquet_scan(_b1_schema())
    var plan = LogicalPlan.aggregate(gb^, aggs^, scan^)
    assert_true(
        not detect_perfect_hash_agg_shape(plan),
        "Aggregate with zero agg exprs must be rejected",
    )
    print("test_no_agg_exprs_rejected OK")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

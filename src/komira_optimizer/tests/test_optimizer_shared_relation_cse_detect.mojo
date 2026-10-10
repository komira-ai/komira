# =============================================================================
# detect_shared_cross_canonical: the q11 shared-relation shape
# =============================================================================
#
# TPC-H q11 compares a grouped SUM against an ungrouped SUM over the same
# relation. After scalar-subquery decorrelation both aggregates sit under one
# JOIN_CROSS, and column pruning (not in this tree) leaves the two scans of
# `t` with different projections. `detect_shared_cross_canonical` must
# recognise the two scans as
# one relation (projection-insensitive fingerprint) and return the WIDER one,
# whose columns cover both aggregates.
#
# Four cases, each with the defect it catches:
#   1. wider relation on the left -> the left relation (pk, v) is returned.
#      Catches a fingerprint that hashes the scan projection (the two scans
#      then hash apart and the detector returns None).
#   2. wider relation on the right -> the right relation is returned.
#      Catches a detector that keeps only the left-superset branch (None).
#   3. the two scans carry different pushed-down filters -> None.
#      Catches a fingerprint that leaves the scan filter out (two relations
#      with different rows would fold into one).
#   4. the same two aggregates under an INNER join -> None.
#      Catches the removal of the JOIN_CROSS check (an inner join is not the
#      decorrelated scalar broadcast this rewrite is sound for).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, sum as agg_sum
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
    JOIN_CROSS,
    JOIN_INNER,
)
from komira_optimizer.optimizer_shared_relation_cse import (
    detect_shared_cross_canonical,
)


def _t_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return sb.build()


def _names(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _names2(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def _v_gt(k: Int) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(k))
    )


def _scan_t(var proj: List[String], var filter: Optional[Expr] = None) -> LogicalPlan:
    return LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _t_schema(),
        projection=Optional(proj^),
        filter=filter^,
    )


def _grouped(var filter: Optional[Expr] = None) -> LogicalPlan:
    """Aggregate(group pk, sum(v) AS pv) over Scan(t, [pk, v])."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("pk"))
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")).alias("pv"))
    return LogicalPlan.aggregate(gb^, aggs^, _scan_t(_names2("pk", "v"), filter^))


def _total(var filter: Optional[Expr] = None) -> LogicalPlan:
    """Project(tot) over Aggregate(sum(v) AS tot) over Scan(t, [v])."""
    var gb = ExprArray()
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")).alias("tot"))
    var agg = LogicalPlan.aggregate(gb^, aggs^, _scan_t(_names("v"), filter^))
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("tot"))
    return LogicalPlan.project(exprs^, agg^)


def _filter_over(var join: LogicalPlan) -> LogicalPlan:
    var pred = Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.col_ref("tot"))
    return LogicalPlan.filter(pred^, join^)


def _join(var left: LogicalPlan, var right: LogicalPlan, jt: UInt8) -> LogicalPlan:
    return LogicalPlan.join(left^, right^, List[String](), List[String](), jt)


def test_q11_wider_relation_on_the_left_is_returned() raises:
    var plan = _filter_over(_join(_grouped(), _total(), JOIN_CROSS))
    var rel = detect_shared_cross_canonical(plan)
    assert_true(Bool(rel), "the two scans of t are one relation: detect must fire")
    ref s = rel.value().output_schema
    assert_equal(s.num_columns(), 2, "the wider relation carries pk and v")
    assert_equal(s.field_name(0), String("pk"))
    assert_equal(s.field_name(1), String("v"))


def test_q11_wider_relation_on_the_right_is_returned() raises:
    var plan = _filter_over(_join(_total(), _grouped(), JOIN_CROSS))
    var rel = detect_shared_cross_canonical(plan)
    assert_true(Bool(rel), "the superset may sit on either side of the CROSS")
    ref s = rel.value().output_schema
    assert_equal(s.num_columns(), 2, "the right (wider) relation is returned")
    assert_equal(s.field_name(0), String("pk"))
    assert_equal(s.field_name(1), String("v"))


def test_different_scan_filters_do_not_fold() raises:
    var left = _grouped(Optional(_v_gt(1)))
    var right = _total(Optional(_v_gt(2)))
    var plan = _filter_over(_join(left^, right^, JOIN_CROSS))
    var rel = detect_shared_cross_canonical(plan)
    assert_false(
        Bool(rel), "scans with different pushed-down filters read different rows"
    )


def test_inner_join_is_not_the_cross_shape() raises:
    var plan = _filter_over(_join(_grouped(), _total(), JOIN_INNER))
    var rel = detect_shared_cross_canonical(plan)
    assert_false(Bool(rel), "only a JOIN_CROSS of two aggregates is folded")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

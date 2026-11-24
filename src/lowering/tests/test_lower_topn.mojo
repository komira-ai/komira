# =============================================================================
# test_lower_topn: a range of a sort's order cut as one SINK_TOPN segment
# =============================================================================
#
# Each test builds a logical plan over a lineitem-shaped table, lowers it under
# the constant reference host profile and compares the render (or the fields
# of the segments and the top-n parameter rows) with what the plan means.
#
#   test_a_topn_over_a_scan_is_one_result_segment
#     TopN(3) over a scan with a descending key and an explicit NULL placement
#     is one SINK_TOPN segment that is the result; the whole render, with its
#     topn line (keys, directions, NULL placement, offset=0 n=3).
#   test_a_limit_with_an_offset_over_a_sort_is_one_topn_segment
#     Limit(4, offset 6) over a Sort is one SINK_TOPN segment (offset=6 n=4)
#     and no sort parameter row.
#   test_a_limit_over_a_projection_over_a_sort_fuses_the_projection_above_the_topn
#     Limit over a rename Project over a Sort: a SINK_TOPN segment, then a
#     SOURCE_SINK_OUTPUT segment over an E3 edge that runs the project and
#     collects.
#   test_limits_over_a_sort_compose_into_one_range
#     Limit over Limit over Sort: (3, off 2) over (10, off 4) keeps offset 6
#     n 3; (5, off 8) over (10) keeps offset 8 n 2; (5, off 20) over (10)
#     keeps n 0; three limits compose innermost first.
#   test_limits_over_a_topn_compose_into_one_range
#     Limit over TopN: (2, off 1) over TopN(5) keeps offset 1 n 2; (10) over
#     TopN(3) keeps n 3; (4, off 9) over TopN(5) keeps n 0.
#   test_offsets_saturate_instead_of_overflowing
#     Two offsets near Int.MAX add to Int.MAX in the recorded range.
#   test_a_limit_over_projections_and_limits_of_a_sort_is_one_range
#     Projections between two limits and a sort do not break the chain; the
#     one segment holds the composed range and each projection is fused above.
#   test_a_topn_over_an_aggregate_is_an_aggregate_then_a_topn_segment
#     TopN over an aggregate: SINK_AGG segment, SINK_TOPN segment reading it
#     over an E3 edge, the topn the result.
#   test_a_limit_without_an_offset_over_a_scan_stays_an_operator
#     Limit with offset 0 over a scan is an OP_LIMIT in the collect segment, no
#     topn parameter row.
#   test_a_plain_sort_stays_a_sort_sink
#     A Sort alone is a SINK_SORT with one sort row and no topn row; a filter
#     over a sort stays fused over the sort's reading pipeline.
#   test_a_limit_under_a_sort_stays_an_operator
#     Sort over Limit: the limit is an OP_LIMIT in the segment feeding the
#     sort.
#   test_a_topn_below_a_filter_below_an_aggregate_is_cut_in_order
#     Aggregate over Filter over TopN: topn segment, then a segment that
#     filters and aggregates.
#   test_a_topn_in_a_union_branch_is_that_branch_s_segment
#     A TopN as a UNION ALL branch is a SINK_TOPN segment read by the concat.
#   test_equal_arguments_render_equal
#     Lowering the same top-n plan twice renders byte-equal.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.memory import OwnedPointer

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import HostProfile, reference_host_profile
from host_profile.morsel_sizing_policy import MorselSizingPolicy
from lowering.lower import lower
from lowering.lowered_plan import LoweredPlan, LoweringInputs
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    EDGE_E3_PUBLISH_WAIT,
    OP_FILTER,
    OP_LIMIT,
    OP_PROJECT,
    SINK_AGG,
    SINK_COLLECT,
    SINK_SORT,
    SINK_TOPN,
    SOURCE_CONCAT,
    SOURCE_SINK_OUTPUT,
)
from plan_expr.agg_expr import AggExpr, AGG_SUM
from plan_expr.expr import Expr, BIN_LE
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
)
from plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)


# =============================================================================
# Fixtures
# =============================================================================


def _lineitem() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("flag", ArrowType.STRING, False))
    sb.add_field(Field("qty", ArrowType.INT64, False))
    sb.add_field(Field("price", ArrowType.FLOAT64, False))
    sb.add_field(Field("ship", ArrowType.INT64, False))
    return sb.build()


def _names(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _bools(n: Int, value: Bool) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(value)
    return out^


def _pair(a: Bool, b: Bool) -> List[Bool]:
    var out = List[Bool]()
    out.append(a)
    out.append(b)
    return out^


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _ship_le(v: Int64) -> Expr:
    return Expr.binary(BIN_LE, _col("ship"), Expr.literal(ScalarValue.from_int64(v)))


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows, List[String](), List[ColumnStats](), STATS_SOURCE_PARQUET_METADATA
    )


def _scan() -> LogicalPlan:
    return LogicalPlan.scan(
        String("lineitem.parquet"), SOURCE_PARQUET, _lineitem()
    )


def _host() raises -> HostProfile:
    return reference_host_profile("test-build")


def _inputs(scans: Int = 1) raises -> LoweringInputs:
    var inputs = LoweringInputs()
    for _ in range(scans):
        inputs.add_scan(Optional[TableStats](_stats(6000)), List[String]())
    return inputs^


def _lowered(plan: LogicalPlan, scans: Int = 1) raises -> LoweredPlan:
    return lower(plan, _host(), _inputs(scans))


def _sort_qty() -> LogicalPlan:
    return LogicalPlan.sort(_names("qty"), _bools(1, False), _scan())


def _rename_qty(var child: LogicalPlan) -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.alias(_col("qty"), "q"))
    exprs.append(_col("flag"))
    return LogicalPlan.project(exprs^, child^)


def _range_of(plan: LogicalPlan) raises -> String:
    """The `offset` and `n` of the one top-n row of `plan`'s lowering, which
    is also its only segment."""
    var lp = _lowered(plan)
    assert_equal(len(lp.segments), 1)
    assert_equal(lp.segments[0].sink_kind, SINK_TOPN)
    assert_equal(len(lp.params.topn), 1)
    assert_equal(len(lp.params.sort), 0)
    ref t = lp.params.topn[0]
    return String(t.offset) + " " + String(t.n)


# =============================================================================
# One segment
# =============================================================================


def test_a_topn_over_a_scan_is_one_result_segment() raises:
    var plan = LogicalPlan.topn(
        _names("qty", "flag"),
        _pair(False, True),
        3,
        _scan(),
        Optional[List[Bool]](_pair(True, False)),
    )
    var policy = MorselSizingPolicy.for_host(_host())
    var m = policy.default_morsel_rows(_lineitem())
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_PARQUET path=lineitem.parquet total=True\n"
    expected += "  sink: (SINK_TOPN, NONE, COLUMNAR) param=0 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(m) + " card_rows=6000 mem_bytes=0\n"
    expected += "params: agg=0 sort=0 topn=1 batches=0\n"
    expected += "  topn 0: keys=qty asc nulls_first, flag desc nulls_last offset=0 n=3\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(_lowered(plan)), expected)


def test_a_limit_with_an_offset_over_a_sort_is_one_topn_segment() raises:
    var lp = _lowered(LogicalPlan.limit(4, _sort_qty(), 6))
    assert_equal(len(lp.segments), 1)
    assert_equal(lp.result_seg_id, 0)
    assert_equal(lp.segments[0].sink_kind, SINK_TOPN)
    assert_equal(lp.segments[0].sink_param_id, 0)
    assert_equal(len(lp.params.sort), 0)
    assert_equal(len(lp.params.topn), 1)
    ref t = lp.params.topn[0]
    assert_equal(len(t.sort_keys), 1)
    assert_equal(t.sort_keys[0], "qty")
    assert_equal(t.descending[0], False)
    assert_equal(t.nulls_first[0], False)
    assert_equal(t.offset, 6)
    assert_equal(t.n, 4)


def test_a_limit_over_a_projection_over_a_sort_fuses_the_projection_above_the_topn() raises:
    var lp = _lowered(LogicalPlan.limit(3, _rename_qty(_sort_qty()), 2))
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.result_seg_id, 1)
    ref first = lp.segments[0]
    assert_equal(first.sink_kind, SINK_TOPN)
    assert_equal(len(first.ops), 0)
    assert_equal(len(lp.params.topn), 1)
    assert_equal(lp.params.topn[0].offset, 2)
    assert_equal(lp.params.topn[0].n, 3)
    ref top = lp.segments[1]
    assert_equal(top.source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(top.source_spec.dep_seg_ids[0], 0)
    assert_equal(len(top.deps), 1)
    assert_equal(top.deps[0], 0)
    assert_equal(top.edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    assert_equal(len(top.ops), 1)
    assert_equal(top.ops[0].tag, OP_PROJECT)
    var names = top.ops[0].project_names.value().copy()
    assert_equal(names[0], "q")
    assert_equal(names[1], "flag")
    assert_equal(top.sink_kind, SINK_COLLECT)


# =============================================================================
# Composition of the range
# =============================================================================


def test_limits_over_a_sort_compose_into_one_range() raises:
    var inner = LogicalPlan.limit(10, _sort_qty(), 4)
    assert_equal(_range_of(LogicalPlan.limit(3, inner^, 2)), "6 3")
    assert_equal(
        _range_of(LogicalPlan.limit(5, LogicalPlan.limit(10, _sort_qty()), 8)),
        "8 2",
    )
    assert_equal(
        _range_of(LogicalPlan.limit(5, LogicalPlan.limit(10, _sort_qty()), 20)),
        "20 0",
    )
    var three = LogicalPlan.limit(
        2, LogicalPlan.limit(6, LogicalPlan.limit(20, _sort_qty(), 1), 3), 1
    )
    assert_equal(_range_of(three^), "5 2")
    assert_equal(_range_of(LogicalPlan.limit(7, _sort_qty())), "0 7")


def test_limits_over_a_topn_compose_into_one_range() raises:
    var topn5 = LogicalPlan.topn(_names("qty"), _bools(1, False), 5, _scan())
    assert_equal(_range_of(LogicalPlan.limit(2, topn5^, 1)), "1 2")
    var topn3 = LogicalPlan.topn(_names("qty"), _bools(1, False), 3, _scan())
    assert_equal(_range_of(LogicalPlan.limit(10, topn3^)), "0 3")
    var topn5b = LogicalPlan.topn(_names("qty"), _bools(1, False), 5, _scan())
    assert_equal(_range_of(LogicalPlan.limit(4, topn5b^, 9)), "9 0")
    var topn5c = LogicalPlan.topn(_names("qty"), _bools(1, False), 5, _scan())
    assert_equal(_range_of(topn5c^), "0 5")


def test_offsets_saturate_instead_of_overflowing() raises:
    var big = Int.MAX - 5
    var plan = LogicalPlan.limit(
        3, LogicalPlan.limit(Int.MAX, _sort_qty(), big), big
    )
    assert_equal(_range_of(plan^), String(Int.MAX) + " 3")


def test_a_limit_over_projections_and_limits_of_a_sort_is_one_range() raises:
    var inner = LogicalPlan.limit(10, _rename_qty(_sort_qty()), 3)
    var again = ExprArray()
    again.append(Expr.alias(_col("q"), "r"))
    again.append(_col("flag"))
    var outer = LogicalPlan.limit(4, LogicalPlan.project(again^, inner^), 2)
    var lp = _lowered(outer^)
    assert_equal(len(lp.params.topn), 1)
    assert_equal(lp.params.topn[0].offset, 5)
    assert_equal(lp.params.topn[0].n, 4)
    var topn_segments = 0
    for i in range(len(lp.segments)):
        if lp.segments[i].sink_kind == SINK_TOPN:
            topn_segments += 1
    assert_equal(topn_segments, 1)
    ref top = lp.segments[len(lp.segments) - 1]
    assert_equal(top.sink_kind, SINK_COLLECT)
    assert_equal(len(top.ops), 2)
    assert_equal(top.ops[0].tag, OP_PROJECT)
    assert_equal(top.ops[1].tag, OP_PROJECT)


# =============================================================================
# Shapes that stay as they were, and a top-n beside other breakers
# =============================================================================


def test_a_topn_over_an_aggregate_is_an_aggregate_then_a_topn_segment() raises:
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(AGG_SUM, Optional[Expr](_col("price")), Optional[String]("total"))
    )
    var keys = ExprArray()
    keys.append(_col("qty"))
    var agg = LogicalPlan.aggregate(keys^, aggs^, _scan())
    var plan = LogicalPlan.topn(_names("total"), _bools(1, True), 2, agg^)
    var lp = _lowered(plan)
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.result_seg_id, 1)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    ref top = lp.segments[1]
    assert_equal(top.sink_kind, SINK_TOPN)
    assert_equal(top.source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(top.deps[0], 0)
    assert_equal(top.edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    assert_equal(len(lp.params.agg), 1)
    assert_equal(len(lp.params.topn), 1)
    assert_equal(lp.params.topn[0].sort_keys[0], "total")
    assert_equal(lp.params.topn[0].descending[0], True)
    assert_equal(lp.params.topn[0].n, 2)


def test_a_limit_without_an_offset_over_a_scan_stays_an_operator() raises:
    var lp = _lowered(LogicalPlan.limit(9, _scan()))
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.sink_kind, SINK_COLLECT)
    assert_equal(len(seg.ops), 1)
    assert_equal(seg.ops[0].tag, OP_LIMIT)
    assert_equal(seg.ops[0].limit_count, 9)
    assert_equal(len(lp.params.topn), 0)


def test_a_plain_sort_stays_a_sort_sink() raises:
    var lp = _lowered(_sort_qty())
    assert_equal(len(lp.segments), 1)
    assert_equal(lp.segments[0].sink_kind, SINK_SORT)
    assert_equal(len(lp.params.sort), 1)
    assert_equal(len(lp.params.topn), 0)
    var filtered = LogicalPlan.filter(_ship_le(5), _sort_qty())
    var lp2 = _lowered(filtered^)
    assert_equal(len(lp2.segments), 2)
    assert_equal(lp2.segments[0].sink_kind, SINK_SORT)
    assert_equal(lp2.segments[1].ops[0].tag, OP_FILTER)
    assert_equal(len(lp2.params.topn), 0)


def test_a_limit_under_a_sort_stays_an_operator() raises:
    var plan = LogicalPlan.sort(
        _names("qty"), _bools(1, False), LogicalPlan.limit(5, _scan())
    )
    var lp = _lowered(plan^)
    assert_equal(len(lp.segments), 1)
    assert_equal(lp.segments[0].sink_kind, SINK_SORT)
    assert_equal(len(lp.segments[0].ops), 1)
    assert_equal(lp.segments[0].ops[0].tag, OP_LIMIT)
    assert_equal(len(lp.params.topn), 0)


def test_a_topn_below_a_filter_below_an_aggregate_is_cut_in_order() raises:
    var topn = LogicalPlan.topn(_names("qty"), _bools(1, False), 4, _scan())
    var filtered = LogicalPlan.filter(_ship_le(5), topn^)
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(AGG_SUM, Optional[Expr](_col("price")), Optional[String]("total"))
    )
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, filtered^)
    var lp = _lowered(plan^)
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.result_seg_id, 1)
    assert_equal(lp.segments[0].sink_kind, SINK_TOPN)
    ref top = lp.segments[1]
    assert_equal(top.sink_kind, SINK_AGG)
    assert_equal(top.source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(len(top.ops), 1)
    assert_equal(top.ops[0].tag, OP_FILTER)
    assert_equal(lp.params.topn[0].n, 4)
    assert_equal(len(lp.params.agg), 1)


def test_a_topn_in_a_union_branch_is_that_branch_s_segment() raises:
    var topn = LogicalPlan.topn(_names("qty"), _bools(1, False), 2, _scan())
    var schema = topn.output_schema.copy()
    var branches = List[OwnedPointer[LogicalPlan]]()
    branches.append(OwnedPointer(topn^))
    branches.append(OwnedPointer(_scan()))
    var lp = _lowered(LogicalPlan.union(branches^, schema^), 2)
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].sink_kind, SINK_TOPN)
    assert_equal(lp.segments[1].sink_kind, SINK_COLLECT)
    ref top = lp.segments[2]
    assert_equal(top.source_kind, SOURCE_CONCAT)
    assert_equal(top.source_spec.dep_seg_ids[0], 0)
    assert_equal(top.source_spec.dep_seg_ids[1], 1)
    assert_equal(len(lp.params.topn), 1)


def test_equal_arguments_render_equal() raises:
    var a = render_lowered_plan(
        _lowered(LogicalPlan.limit(4, _rename_qty(_sort_qty()), 6))
    )
    var b = render_lowered_plan(
        _lowered(LogicalPlan.limit(4, _rename_qty(_sort_qty()), 6))
    )
    assert_equal(a, b)
    assert_true("topn 0: keys=qty asc nulls_last offset=6 n=4" in a)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

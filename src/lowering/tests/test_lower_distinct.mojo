# =============================================================================
# test_lower_distinct: SELECT DISTINCT cut to a SINK_AGG with no aggregate
# =============================================================================
#
# A distinct ends the open pipeline in a SINK_AGG segment whose AggSinkData has
# every column of the node, in order, as its group keys and no aggregate, and
# opens a pipeline that reads that segment's output over an E3 edge. Each test
# builds a logical plan, lowers it under the constant reference host profile
# and compares the render or the segment fields with that meaning.
#
# Tests, and the behaviour each asserts:
#   test_a_distinct_over_an_integer_column_is_one_aggregate_segment_with_that_key:
#     one segment whose sink is (SINK_AGG, I64, COLUMNAR); its AggSinkData has
#     the column as the only group key and no aggregate, and the whole render
#     is the expected text.
#   test_a_distinct_over_a_string_column_picks_the_string_row_by_the_footer:
#     the sink is STRING COLUMNAR, and STRING DICT_ENCODED only when the
#     inputs say the column is dictionary encoded.
#   test_a_distinct_over_two_dictionary_strings_keeps_the_columns_in_order:
#     the sink is (SINK_AGG, STRING, DICT_ENCODED) and the group keys are the
#     two columns in the node's column order, not alphabetical order.
#   test_a_sort_over_a_distinct_is_two_segments_joined_by_an_e3_edge: the
#     distinct segment is segment 0, the sort reads its output over E3 and is
#     the result.
#   test_a_limit_over_a_distinct_fuses_into_the_reopened_pipeline: the limit is
#     an operator of the segment that reads the distinct's output and ends in
#     SINK_COLLECT, which is the result.
#   test_a_distinct_over_a_filter_carries_the_filter_in_its_segment: the filter
#     is the segment's operator before the aggregate sink, and the render shows
#     it.
#   test_a_distinct_over_a_distinct_has_two_dense_aggregate_parameters: two
#     SINK_AGG segments, aggregate parameters 0 and 1, the second reading the
#     first over E3.
#   test_a_distinct_over_an_aggregate_reads_the_aggregate_output: a distinct
#     above an aggregate is a second SINK_AGG segment grouped by the
#     aggregate's output columns.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import HostProfile, reference_host_profile
from host_profile.morsel_sizing_policy import MorselSizingPolicy
from lowering.lower import lower
from lowering.lowered_plan import LoweredPlan, LoweringInputs
from lowering.render import render_lowered_plan
from lowering.sink_capability import triple_name
from physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    EDGE_E3_PUBLISH_WAIT,
    OP_FILTER,
    OP_LIMIT,
    SINK_AGG,
    SINK_COLLECT,
    SINK_SORT,
    SOURCE_SINK_OUTPUT,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr, BIN_GT
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


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _names(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows,
        List[String](),
        List[ColumnStats](),
        STATS_SOURCE_PARQUET_METADATA,
    )


def _bools(a: Bool) -> List[Bool]:
    var out = List[Bool]()
    out.append(a)
    return out^


def _host() raises -> HostProfile:
    return reference_host_profile("test-build")


def _inputs(var dict_columns: List[String] = List[String]()) -> LoweringInputs:
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(6000)), dict_columns^)
    return inputs^


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, _host(), inputs)


def _int_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    return sb.build()


def _string_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    return sb.build()


def _reversed_strings() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("t", ArrowType.STRING, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    return sb.build()


def _scan(var schema: Schema, path: String = "d.parquet") -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, schema^)


def _k_gt_zero() -> Expr:
    return Expr.binary(BIN_GT, _col("k"), Expr.literal(ScalarValue.from_int64(0)))


def test_a_distinct_over_an_integer_column_is_one_aggregate_segment_with_that_key() raises:
    var plan = LogicalPlan.distinct(None, _scan(_int_schema()))
    var m = MorselSizingPolicy.for_host(_host()).agg_morsel_rows(_int_schema())
    var lp = _lowered(plan, _inputs())
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_PARQUET path=d.parquet total=True\n"
    expected += "  sink: (SINK_AGG, I64, COLUMNAR) param=0 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(m) + " card_rows=6000 mem_bytes=0\n"
    expected += "params: agg=1 sort=0 batches=0\n"
    expected += "  agg 0: group_by=[" + String(_col("k")) + "] aggs=[]\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(lp), expected)
    assert_equal(len(lp.segments), 1)
    assert_equal(lp.result_seg_id, 0)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    assert_equal(lp.segments[0].sink_param_id, 0)
    assert_equal(len(lp.params.agg), 1)
    ref agg = lp.params.agg[0]
    assert_equal(len(agg.group_by_exprs), 1)
    assert_equal(String(agg.group_by_exprs[0]), String(_col("k")))
    assert_equal(len(agg.agg_exprs), 0)
    assert_equal(agg.output_schema.num_columns(), 1)
    assert_equal(agg.output_schema.field_name(0), "k")


def test_a_distinct_over_a_string_column_picks_the_string_row_by_the_footer() raises:
    var plan = LogicalPlan.distinct(None, _scan(_string_schema()))
    var plain = _lowered(plan, _inputs())
    ref a = plain.segments[plain.result_seg_id]
    assert_equal(triple_name(a.sink_kind, a.sink_key_dtype, a.sink_orientation), "(SINK_AGG, STRING, COLUMNAR)")
    assert_equal(len(plain.params.agg[0].agg_exprs), 0)

    var encoded = _lowered(
        LogicalPlan.distinct(None, _scan(_string_schema())), _inputs(_names("s"))
    )
    ref b = encoded.segments[encoded.result_seg_id]
    assert_equal(triple_name(b.sink_kind, b.sink_key_dtype, b.sink_orientation), "(SINK_AGG, STRING, DICT_ENCODED)")

    # A dictionary fact about another column says nothing about this one.
    var other = _lowered(
        LogicalPlan.distinct(None, _scan(_string_schema())), _inputs(_names("t"))
    )
    ref c = other.segments[other.result_seg_id]
    assert_equal(triple_name(c.sink_kind, c.sink_key_dtype, c.sink_orientation), "(SINK_AGG, STRING, COLUMNAR)")


def test_a_distinct_over_two_dictionary_strings_keeps_the_columns_in_order() raises:
    var plan = LogicalPlan.distinct(None, _scan(_reversed_strings()))
    var lp = _lowered(plan, _inputs(_names("s", "t")))
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(triple_name(seg.sink_kind, seg.sink_key_dtype, seg.sink_orientation), "(SINK_AGG, STRING, DICT_ENCODED)")
    ref agg = lp.params.agg[0]
    assert_equal(len(agg.group_by_exprs), 2)
    assert_equal(String(agg.group_by_exprs[0]), String(_col("t")))
    assert_equal(String(agg.group_by_exprs[1]), String(_col("s")))
    assert_equal(len(agg.agg_exprs), 0)
    assert_equal(agg.output_schema.num_columns(), 2)
    assert_equal(agg.output_schema.field_name(0), "t")
    assert_equal(agg.output_schema.field_name(1), "s")


def test_a_sort_over_a_distinct_is_two_segments_joined_by_an_e3_edge() raises:
    var distinct = LogicalPlan.distinct(None, _scan(_int_schema()))
    var distinct_schema = distinct.output_schema.copy()
    var plan = LogicalPlan.sort(_names("k"), _bools(False), distinct^)
    var policy = MorselSizingPolicy.for_host(_host())
    var lp = _lowered(plan, _inputs())
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_PARQUET path=d.parquet total=True\n"
    expected += "  sink: (SINK_AGG, I64, COLUMNAR) param=0 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(policy.agg_morsel_rows(_int_schema())) + " card_rows=6000 mem_bytes=0\n"
    expected += "segment 1\n"
    expected += "  source: SOURCE_SINK_OUTPUT from=0\n"
    expected += "  sink: (SINK_SORT, NONE, COLUMNAR) param=0 state=1\n"
    expected += "  deps: 0/E3\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(policy.default_morsel_rows(distinct_schema)) + " card_rows=0 mem_bytes=0\n"
    expected += "params: agg=1 sort=1 batches=0\n"
    expected += "  agg 0: group_by=[" + String(_col("k")) + "] aggs=[]\n"
    expected += "  sort 0: keys=k asc nulls_last\n"
    expected += "result: segment 1\n"
    assert_equal(render_lowered_plan(lp), expected)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    assert_equal(lp.segments[1].source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(lp.segments[1].sink_kind, SINK_SORT)
    assert_equal(lp.segments[1].edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    assert_equal(lp.result_seg_id, 1)


def test_a_limit_over_a_distinct_fuses_into_the_reopened_pipeline() raises:
    var plan = LogicalPlan.limit(5, LogicalPlan.distinct(None, _scan(_int_schema())))
    var lp = _lowered(plan, _inputs())
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.result_seg_id, 1)
    ref first = lp.segments[0]
    assert_equal(first.sink_kind, SINK_AGG)
    assert_equal(len(first.ops), 0)
    ref top = lp.segments[1]
    assert_equal(top.source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(top.source_spec.dep_seg_ids[0], 0)
    assert_equal(len(top.deps), 1)
    assert_equal(top.deps[0], 0)
    assert_equal(top.edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    assert_equal(len(top.ops), 1)
    assert_equal(top.ops[0].tag, OP_LIMIT)
    assert_equal(top.ops[0].limit_count, 5)
    assert_equal(top.sink_kind, SINK_COLLECT)
    assert_equal(top.sink_param_id, -1)


def test_a_distinct_over_a_filter_carries_the_filter_in_its_segment() raises:
    var plan = LogicalPlan.distinct(
        None, LogicalPlan.filter(_k_gt_zero(), _scan(_int_schema()))
    )
    var policy = MorselSizingPolicy.for_host(_host())
    var lp = _lowered(plan, _inputs())
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_PARQUET path=d.parquet total=True\n"
    expected += "  op 0: FILTER " + String(_k_gt_zero()) + "\n"
    expected += "  sink: (SINK_AGG, I64, COLUMNAR) param=0 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(policy.agg_morsel_rows(_int_schema())) + " card_rows=6000 mem_bytes=0\n"
    expected += "params: agg=1 sort=0 batches=0\n"
    expected += "  agg 0: group_by=[" + String(_col("k")) + "] aggs=[]\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(lp), expected)
    assert_equal(len(lp.segments), 1)
    assert_equal(lp.segments[0].ops[0].tag, OP_FILTER)


def test_a_distinct_over_a_distinct_has_two_dense_aggregate_parameters() raises:
    var plan = LogicalPlan.distinct(
        None, LogicalPlan.distinct(None, _scan(_int_schema()))
    )
    var lp = _lowered(plan, _inputs())
    assert_equal(len(lp.segments), 2)
    assert_equal(len(lp.params.agg), 2)
    assert_equal(lp.result_seg_id, 1)
    ref inner = lp.segments[0]
    ref outer = lp.segments[1]
    assert_equal(inner.sink_kind, SINK_AGG)
    assert_equal(outer.sink_kind, SINK_AGG)
    assert_equal(inner.sink_param_id, 0)
    assert_equal(outer.sink_param_id, 1)
    assert_equal(outer.source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(outer.edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    for i in range(2):
        assert_equal(len(lp.params.agg[i].agg_exprs), 0)
        assert_equal(String(lp.params.agg[i].group_by_exprs[0]), String(_col("k")))


def test_a_distinct_over_an_aggregate_reads_the_aggregate_output() raises:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var keys = ExprArray()
    keys.append(_col("k"))
    var agg = LogicalPlan.aggregate(keys^, aggs^, _scan(_int_schema()))
    var plan = LogicalPlan.distinct(None, agg^)
    # The aggregate's output is (k INT64, n INT64): two integer columns have
    # no sink row, so the plan is refused by name rather than cut.
    try:
        _ = _lowered(plan, _inputs())
        assert_true(False, "a distinct over two integer columns lowered")
    except e:
        assert_equal(
            String(e),
            "LOWERING_SINK_UNSERVED: a group key of 2 columns is served only when every column is a dictionary encoded string",
        )
    # Over the aggregate's single key column it is a second SINK_AGG.
    var aggs2 = AggExprArray()
    aggs2.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var keys2 = ExprArray()
    keys2.append(_col("k"))
    var only_k = ExprArray()
    only_k.append(_col("k"))
    var plan2 = LogicalPlan.distinct(
        None,
        LogicalPlan.project(
            only_k^,
            LogicalPlan.aggregate(keys2^, aggs2^, _scan(_int_schema())),
        ),
    )
    var lp = _lowered(plan2, _inputs())
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    assert_equal(len(lp.params.agg[0].agg_exprs), 1)
    assert_equal(lp.segments[1].sink_kind, SINK_AGG)
    assert_equal(len(lp.segments[1].ops), 1)
    assert_equal(len(lp.params.agg[1].agg_exprs), 0)
    assert_equal(String(lp.params.agg[1].group_by_exprs[0]), String(_col("k")))
    assert_equal(lp.result_seg_id, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

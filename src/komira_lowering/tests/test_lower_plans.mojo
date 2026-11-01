# =============================================================================
# test_lower_plans: small plans lowered, and the rendered physical plan asserted
# =============================================================================
#
# Each test builds a logical plan over a lineitem-shaped table, lowers it under
# the constant reference host profile and compares the render (or the fields
# of the segments) with what the plan means: where it is cut, which operators
# fuse, which sink row each group key picks, which indices the parameters get.
# Morsel sizes are expected from the sizing policy applied to the schema that
# flows INTO the segment's sink.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_host_profile.host_profile import HostProfile, reference_host_profile
from komira_host_profile.morsel_sizing_policy import MorselSizingPolicy
from komira_lowering.lower import lower
from komira_lowering.lowered_plan import LoweredPlan, LoweringInputs
from komira_lowering.render import render_lowered_plan
from komira_lowering.sink_capability import triple_name
from komira_physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    EDGE_E3_PUBLISH_WAIT,
    OP_FILTER,
    OP_LIMIT,
    OP_PROJECT,
    SINK_AGG,
    SINK_COLLECT,
    SINK_SORT,
    SOURCE_BATCH,
    SOURCE_PARQUET as SEG_SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_MEAN, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_GT, BIN_LE, BIN_MUL
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
)
from komira_plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.source_variant import SourceVariant


# =============================================================================
# Fixtures
# =============================================================================


def _lineitem() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("flag", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, False))
    sb.add_field(Field("qty", ArrowType.INT64, False))
    sb.add_field(Field("price", ArrowType.FLOAT64, False))
    sb.add_field(Field("disc", ArrowType.FLOAT64, False))
    sb.add_field(Field("ship", ArrowType.INT64, False))
    return sb.build()


def _names(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    if c != "":
        out.append(c)
    return out^


def _bools(n: Int, value: Bool) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(value)
    return out^


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _ship_le(v: Int64) -> Expr:
    return Expr.binary(BIN_LE, _col("ship"), Expr.literal(ScalarValue.from_int64(v)))


def _keys(names: List[String]) -> ExprArray:
    var out = ExprArray()
    for i in range(len(names)):
        out.append(_col(names[i]))
    return out^


def _sum_as(col: String, out_name: String) -> AggExpr:
    return AggExpr(AGG_SUM, Optional[Expr](_col(col)), Optional[String](out_name))


def _revenue() -> AggExpr:
    return AggExpr(
        AGG_SUM,
        Optional[Expr](Expr.binary(BIN_MUL, _col("price"), _col("disc"))),
        Optional[String]("revenue"),
    )


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows,
        List[String](),
        List[ColumnStats](),
        STATS_SOURCE_PARQUET_METADATA,
    )


def _scan(
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) -> LogicalPlan:
    return LogicalPlan.scan(
        String("lineitem.parquet"),
        SOURCE_PARQUET,
        _lineitem(),
        projection^,
        filter^,
    )


def _host() raises -> HostProfile:
    return reference_host_profile("test-build")


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, _host(), inputs)


def _one_scan(
    var dict_columns: List[String] = List[String](), rows: Int = 6000
) -> LoweringInputs:
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(rows)), dict_columns^)
    return inputs^


# =============================================================================
# Cut shapes, rendered whole
# =============================================================================


def test_ungrouped_filter_aggregate_is_one_segment() raises:
    var scan = _scan(Optional[List[String]](_names("price", "disc", "ship")))
    var flow = scan.output_schema.copy()
    var aggs = AggExprArray()
    aggs.append(_revenue())
    var plan = LogicalPlan.aggregate(
        ExprArray(), aggs^, LogicalPlan.filter(_ship_le(100), scan^)
    )
    var m = MorselSizingPolicy.for_host(_host()).agg_morsel_rows(flow)
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_PARQUET path=lineitem.parquet total=True projection=[price, disc, ship]\n"
    expected += "  op 0: FILTER " + String(_ship_le(100)) + "\n"
    expected += "  sink: (SINK_AGG, NONE, COLUMNAR) param=0 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(m) + " card_rows=6000 mem_bytes=0\n"
    expected += "params: agg=1 sort=0 batches=0\n"
    expected += "  agg 0: group_by=[] aggs=[" + String(_revenue()) + "]\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(_lowered(plan, _one_scan())), expected)


def test_grouped_dictionary_aggregate_then_sort_is_two_segments() raises:
    var scan = _scan(None, Optional[Expr](_ship_le(100)))
    var scan_schema = scan.output_schema.copy()
    var aggs = AggExprArray()
    aggs.append(_sum_as("qty", "sum_qty"))
    aggs.append(
        AggExpr(AGG_MEAN, Optional[Expr](_col("price")), Optional[String]("avg_price"))
    )
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var agg = LogicalPlan.aggregate(_keys(_names("flag", "status")), aggs^, scan^)
    var agg_schema = agg.output_schema.copy()
    var plan = LogicalPlan.sort(
        _names("flag", "status"), _bools(2, False), agg^
    )
    var policy = MorselSizingPolicy.for_host(_host())
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_PARQUET path=lineitem.parquet total=True filter=" + String(_ship_le(100)) + "\n"
    expected += "  sink: (SINK_AGG, STRING, DICT_ENCODED) param=0 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(policy.agg_morsel_rows(scan_schema)) + " card_rows=6000 mem_bytes=0\n"
    expected += "segment 1\n"
    expected += "  source: SOURCE_SINK_OUTPUT from=0\n"
    expected += "  sink: (SINK_SORT, NONE, COLUMNAR) param=0 state=1\n"
    expected += "  deps: 0/E3\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(policy.default_morsel_rows(agg_schema)) + " card_rows=0 mem_bytes=0\n"
    expected += "params: agg=1 sort=1 batches=0\n"
    var group_by = "[" + String(_col("flag")) + ", " + String(_col("status")) + "]"
    expected += "  agg 0: group_by=" + group_by + " aggs=["
    expected += String(_sum_as("qty", "sum_qty")) + ", "
    expected += String(AggExpr(AGG_MEAN, Optional[Expr](_col("price")), Optional[String]("avg_price"))) + ", "
    expected += String(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n"))) + "]\n"
    expected += "  sort 0: keys=flag asc nulls_last, status asc nulls_last\n"
    expected += "result: segment 1\n"
    var dict_columns = _names("flag", "status")
    assert_equal(
        render_lowered_plan(_lowered(plan, _one_scan(dict_columns^))), expected
    )


def test_scan_alone_collects_with_projection_and_pushed_filter() raises:
    var scan = _scan(
        Optional[List[String]](_names("qty", "price")),
        Optional[Expr](_ship_le(100)),
    )
    var flow = scan.output_schema.copy()
    var lp = _lowered(scan, _one_scan())
    assert_equal(len(lp.segments), 1)
    assert_equal(lp.result_seg_id, 0)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SEG_SOURCE_PARQUET)
    assert_true(seg.source_spec.parquet_spec_is_total)
    assert_equal(seg.source_spec.parquet_path, "lineitem.parquet")
    assert_equal(len(seg.source_spec.parquet_projection.value()), 2)
    assert_equal(String(seg.source_spec.parquet_filter.value()), String(_ship_le(100)))
    assert_equal(len(seg.ops), 0)
    assert_equal(seg.sink_kind, SINK_COLLECT)
    assert_equal(seg.sink_param_id, -1)
    assert_equal(
        seg.morsel_rows,
        MorselSizingPolicy.for_host(_host()).bulk_scan_morsel_rows(flow),
    )


def test_filter_project_and_limit_fuse_under_one_collect() raises:
    var rev = Expr.alias(Expr.binary(BIN_MUL, _col("price"), _col("disc")), "rev")
    var exprs = ExprArray()
    exprs.append(rev^)
    exprs.append(_col("qty"))
    var proj = LogicalPlan.project(
        exprs^, LogicalPlan.filter(_ship_le(100), _scan())
    )
    var flow = proj.output_schema.copy()
    var plan = LogicalPlan.limit(10, proj^)
    var lp = _lowered(plan, _one_scan())
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(len(seg.ops), 3)
    assert_equal(seg.ops[0].tag, OP_FILTER)
    assert_equal(seg.ops[1].tag, OP_PROJECT)
    assert_equal(seg.ops[2].tag, OP_LIMIT)
    assert_equal(seg.ops[2].limit_count, 10)
    var names = seg.ops[1].project_names.value().copy()
    assert_equal(len(names), 2)
    assert_equal(names[0], "rev")
    assert_equal(names[1], "qty")
    assert_equal(seg.sink_kind, SINK_COLLECT)
    assert_equal(len(seg.deps), 0)
    assert_equal(
        seg.morsel_rows,
        MorselSizingPolicy.for_host(_host()).default_morsel_rows(flow),
    )


def test_project_over_an_aggregate_reads_the_aggregate_output() raises:
    var aggs = AggExprArray()
    aggs.append(_sum_as("price", "total"))
    var agg = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var doubled = ExprArray()
    doubled.append(
        Expr.alias(
            Expr.binary(BIN_MUL, _col("total"), Expr.literal(ScalarValue.from_float(2.0))),
            "twice",
        )
    )
    var plan = LogicalPlan.project(doubled^, agg^)
    var lp = _lowered(plan, _one_scan())
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.result_seg_id, 1)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    ref top = lp.segments[1]
    assert_equal(top.source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(top.source_spec.dep_seg_ids[0], 0)
    assert_equal(len(top.deps), 1)
    assert_equal(top.deps[0], 0)
    assert_equal(top.edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    assert_equal(len(top.ops), 1)
    assert_equal(top.ops[0].tag, OP_PROJECT)
    assert_equal(top.sink_kind, SINK_COLLECT)


# =============================================================================
# The sink row a group key picks
# =============================================================================


def _key_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", ArrowType.INT64, False))
    sb.add_field(Field("i32", ArrowType.INT32, False))
    sb.add_field(Field("f64", ArrowType.FLOAT64, False))
    sb.add_field(Field("f32", ArrowType.FLOAT32, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("t", ArrowType.STRING, False))
    return sb.build()


def _count_by(keys: List[String]) -> LogicalPlan:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    return LogicalPlan.aggregate(
        _keys(keys),
        aggs^,
        LogicalPlan.scan(String("keys.parquet"), SOURCE_PARQUET, _key_schema()),
    )


def _sink_of(plan: LogicalPlan, var dict_columns: List[String]) raises -> String:
    var lp = _lowered(plan, _one_scan(dict_columns^))
    ref seg = lp.segments[lp.result_seg_id]
    return triple_name(seg.sink_kind, seg.sink_key_dtype, seg.sink_orientation)


def test_each_group_key_type_picks_its_sink_row() raises:
    assert_equal(_sink_of(_count_by(List[String]()), List[String]()), "(SINK_AGG, NONE, COLUMNAR)")
    assert_equal(_sink_of(_count_by(_names("i64")), List[String]()), "(SINK_AGG, I64, COLUMNAR)")
    assert_equal(_sink_of(_count_by(_names("i32")), List[String]()), "(SINK_AGG, I32, COLUMNAR)")
    assert_equal(_sink_of(_count_by(_names("f64")), List[String]()), "(SINK_AGG, F64, COLUMNAR)")
    assert_equal(_sink_of(_count_by(_names("f32")), List[String]()), "(SINK_AGG, F32, COLUMNAR)")


def test_a_string_key_is_dictionary_encoded_only_when_the_footers_say_so() raises:
    assert_equal(_sink_of(_count_by(_names("s")), List[String]()), "(SINK_AGG, STRING, COLUMNAR)")
    assert_equal(_sink_of(_count_by(_names("s")), _names("s")), "(SINK_AGG, STRING, DICT_ENCODED)")
    # A dictionary fact about another column says nothing about this one.
    assert_equal(_sink_of(_count_by(_names("s")), _names("t")), "(SINK_AGG, STRING, COLUMNAR)")
    assert_equal(_sink_of(_count_by(_names("s", "t")), _names("s", "t")), "(SINK_AGG, STRING, DICT_ENCODED)")


def test_a_dictionary_fact_does_not_survive_a_projection_or_a_breaker() raises:
    var exprs = ExprArray()
    exprs.append(_col("s"))
    exprs.append(_col("i64"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var projected = LogicalPlan.aggregate(
        _keys(_names("s")),
        aggs^,
        LogicalPlan.project(
            exprs^,
            LogicalPlan.scan(String("keys.parquet"), SOURCE_PARQUET, _key_schema()),
        ),
    )
    assert_equal(_sink_of(projected, _names("s")), "(SINK_AGG, STRING, COLUMNAR)")

    var inner_aggs = AggExprArray()
    inner_aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var outer_aggs = AggExprArray()
    outer_aggs.append(_sum_as("n", "total"))
    var stacked = LogicalPlan.aggregate(
        _keys(_names("s")),
        outer_aggs^,
        LogicalPlan.aggregate(
            _keys(_names("s")),
            inner_aggs^,
            LogicalPlan.scan(String("keys.parquet"), SOURCE_PARQUET, _key_schema()),
        ),
    )
    var lp = _lowered(stacked, _one_scan(_names("s")))
    assert_equal(len(lp.segments), 2)
    ref inner = lp.segments[0]
    ref outer = lp.segments[1]
    assert_equal(triple_name(inner.sink_kind, inner.sink_key_dtype, inner.sink_orientation), "(SINK_AGG, STRING, DICT_ENCODED)")
    assert_equal(triple_name(outer.sink_kind, outer.sink_key_dtype, outer.sink_orientation), "(SINK_AGG, STRING, COLUMNAR)")
    # Parameter indices are dense and follow the cut order.
    assert_equal(inner.sink_param_id, 0)
    assert_equal(outer.sink_param_id, 1)
    assert_equal(len(lp.params.agg), 2)


# =============================================================================
# Other scans, estimates, and equal arguments
# =============================================================================


def _resident() raises -> InMemorySource:
    var vals = List[Int64]()
    for i in range(8):
        vals.append(Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    var rb = RecordBatch.from_columns_1(sb.build(), PrimitiveArray[DType.int64].from_list(vals))
    return InMemorySource.from_record_batch(rb^)


def test_an_in_memory_scan_is_a_batch_source_with_its_filter_and_projection_as_operators() raises:
    var pushed = Expr.binary(BIN_GT, _col("a"), Expr.literal(ScalarValue.from_int64(3)))
    var source = _resident()
    var schema = source.schema()
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(source^),
        schema^,
        Optional[List[String]](_names("a")),
        Optional[Expr](pushed.copy()),
    )
    var lp = _lowered(scan, _one_scan())
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_BATCH)
    assert_equal(seg.source_spec.batch_handle_id, 0)
    assert_equal(len(lp.params.batches), 1)
    assert_equal(len(seg.ops), 2)
    assert_equal(seg.ops[0].tag, OP_FILTER)
    assert_equal(String(seg.ops[0].filter_predicate.value()), String(pushed))
    assert_equal(seg.ops[1].tag, OP_PROJECT)
    assert_equal(seg.sink_kind, SINK_COLLECT)


def test_the_card_estimate_is_the_footer_row_count_or_zero() raises:
    var known = _lowered(_scan(), _one_scan(List[String](), 4242))
    assert_equal(known.segments[0].card_estimate_rows, 4242)
    var inputs = LoweringInputs()
    inputs.add_scan()
    var unknown = _lowered(_scan(), inputs)
    assert_equal(unknown.segments[0].card_estimate_rows, 0)
    assert_equal(unknown.segments[0].mem_estimate_bytes, 0)


def test_every_segment_is_sized_stamped_and_ordered_none() raises:
    var aggs = AggExprArray()
    aggs.append(_sum_as("qty", "q"))
    var agg = LogicalPlan.aggregate(_keys(_names("flag")), aggs^, _scan())
    var plan = LogicalPlan.sort(_names("flag"), _bools(1, True), agg^)
    var lp = _lowered(plan, _one_scan())
    assert_equal(len(lp.segments), 2)
    for i in range(len(lp.segments)):
        ref seg = lp.segments[i]
        assert_equal(seg.seg_id, i)
        assert_equal(seg.ir_version, PHYSICAL_PLAN_IR_VERSION)
        assert_true(seg.morsel_rows > 0)
        assert_equal(seg.partition_count, 1)
        assert_equal(seg.sink_state_id, i)
        assert_equal(seg.cancel_slot, -1)
        assert_equal(seg.error_slot, -1)
    assert_equal(lp.params.sort[0].descending[0], True)


def _small_l2_host() raises -> HostProfile:
    var base = reference_host_profile("test-build")
    var hw = base.hardware.copy()
    hw.e_core_l2_bytes = 128 * 1024
    return HostProfile(
        "test-build",
        hw^,
        base.thread_count,
        base.memory_budget_bytes,
        base.spill_tiers,
    )


def _lines(text: String) -> List[String]:
    var out = List[String]()
    for part in text.split("\n"):
        out.append(String(part))
    return out^


def test_equal_arguments_render_equal() raises:
    var a = render_lowered_plan(_lowered(_count_by(_names("s")), _one_scan(_names("s"))))
    var b = render_lowered_plan(_lowered(_count_by(_names("s")), _one_scan(_names("s"))))
    assert_equal(a, b)


def test_a_different_host_changes_only_the_morsel_size() raises:
    var plan_a = _count_by(_names("i64"))
    var plan_b = _count_by(_names("i64"))
    var small = lower(plan_a, _small_l2_host(), _one_scan())
    var reference = lower(plan_b, _host(), _one_scan())
    var ls = _lines(render_lowered_plan(small))
    var lr = _lines(render_lowered_plan(reference))
    assert_equal(len(ls), len(lr))
    var differing = 0
    for i in range(len(ls)):
        if ls[i] != lr[i]:
            differing += 1
            assert_true("morsel_rows=" in ls[i])
    assert_equal(differing, 1)
    assert_true(small.segments[0].morsel_rows != reference.segments[0].morsel_rows)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

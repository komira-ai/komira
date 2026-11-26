# =============================================================================
# test_lower_window: window nodes lowered, and the rendered physical plan
# asserted
# =============================================================================
#
# Each test lowers a PLAN_PARTITION_BY node under the constant reference host
# profile and compares the render with what the plan means: the child's
# pipeline ends in a SINK_PARTITION_BY segment whose param row is the node's
# keys and functions, and what stands above the window reads that segment over
# an E3 edge. Morsel sizes are expected from the sizing policy applied to the
# schema that flows INTO the segment's sink.
#
#   test_a_scan_under_a_window_is_one_segment_that_is_the_result
#   test_a_filter_and_a_projection_under_a_window_fuse_into_its_pipeline
#   test_a_projection_over_a_window_reads_the_window_segment
#   test_two_stacked_windows_are_two_chained_segments_with_params_in_cut_order
#   test_a_node_with_two_functions_is_one_segment_and_one_param_row
#   test_the_declared_schema_marks_a_sum_over_a_nullable_column_nullable
#   test_every_reader_of_a_shared_window_takes_its_nullable_sum
#   test_a_frame_that_can_be_empty_makes_its_column_nullable
#   test_a_limit_above_a_window_with_keys_is_refused_and_one_with_no_key_is_cut
#   test_a_window_over_a_join_ends_the_probe_pipeline_in_the_window_sink
#   test_a_window_over_an_aggregation_reads_the_aggregate_output
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import HostProfile, reference_host_profile
from host_profile.morsel_sizing_policy import MorselSizingPolicy
from lowering.cut_walk import cut_plan
from lowering.lower import lower
from lowering.lowered_plan import LoweredPlan, LoweringInputs, LOWERING_UNCUTTABLE_NODE
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import PHYSICAL_PLAN_IR_VERSION
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr, BIN_GT
from plan_expr.partition_expr import (
    PartitionExpr,
    PartitionFrame,
    PF_AVG,
    PF_COUNT,
    PF_MAX,
    PF_MIN,
    PF_SUM,
    FRAME_UNITS_ROWS,
    FRAME_UNITS_RANGE,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
)
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    PLAN_LIMIT,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_RIGHT,
    plan_tag_name,
)
from plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)


# =============================================================================
# Fixtures
# =============================================================================


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _names(a: String = "", b: String = "") -> List[String]:
    var out = List[String]()
    if a != "":
        out.append(a)
    if b != "":
        out.append(b)
    return out^


def _flags(a: Bool, b: Bool = False, count: Int = 1) -> List[Bool]:
    var out = List[Bool]()
    if count >= 1:
        out.append(a)
    if count >= 2:
        out.append(b)
    return out^


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("g", ArrowType.STRING, False))
    sb.add_field(Field("o", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, True))
    sb.add_field(Field("x", ArrowType.FLOAT64, False))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows,
        List[String](),
        List[ColumnStats](),
        STATS_SOURCE_PARQUET_METADATA,
    )


def _inputs(a: Int, b: Int = -1) -> LoweringInputs:
    """The facts of one scan (two when `b` is given), in scan order."""
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(a)))
    if b >= 0:
        inputs.add_scan(Optional[TableStats](_stats(b)))
    return inputs^


def _host() raises -> HostProfile:
    return reference_host_profile("test-build")


def _policy() raises -> MorselSizingPolicy:
    return MorselSizingPolicy.for_host(_host())


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, _host(), inputs)


def _rn() -> PartitionExpr:
    return PartitionExpr.row_number().with_frame(
        PartitionFrame.running_range()
    ).with_alias("rn")


def _running_sum(col: String, name: String) -> PartitionExpr:
    return PartitionExpr.running_sum(col).with_frame(
        PartitionFrame.running_range()
    ).with_alias(name)


def _exprs(var a: PartitionExpr) -> List[PartitionExpr]:
    var out = List[PartitionExpr]()
    out.append(a^)
    return out^


def _window(
    partition: List[String],
    order: List[String],
    descending: List[Bool],
    var exprs: List[PartitionExpr],
    var child: LogicalPlan,
    var nulls_first: Optional[List[Bool]] = None,
) raises -> LogicalPlan:
    return LogicalPlan.partition_by(
        partition.copy(), order.copy(), descending.copy(), exprs^, child^,
        nulls_first^,
    )


def _segment(
    seg_id: Int,
    source: String,
    ops: List[String],
    sink: String,
    param: Int,
    deps: String,
    morsel_rows: Int,
    card_rows: Int,
) -> String:
    var out = String("segment ") + String(seg_id) + "\n"
    out += "  source: " + source + "\n"
    for i in range(len(ops)):
        out += "  op " + String(i) + ": " + ops[i] + "\n"
    out += "  sink: " + sink + " param=" + String(param) + " state=" + String(seg_id) + "\n"
    out += "  deps: " + deps + "\n"
    out += "  order: ORDER_NONE partitions=1\n"
    out += "  estimates: morsel_rows=" + String(morsel_rows) + " card_rows=" + String(card_rows) + " mem_bytes=0\n"
    return out^


def _plan_text(segments: String, params: String, result: Int) -> String:
    var out = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    out += segments
    out += params
    out += "result: segment " + String(result) + "\n"
    return out^


def _ops(a: String = "", b: String = "") -> List[String]:
    var out = List[String]()
    if a != "":
        out.append(a)
    if b != "":
        out.append(b)
    return out^


comptime _WINDOW = "(SINK_PARTITION_BY, NONE, COLUMNAR)"
comptime _COLLECT = "(SINK_COLLECT, NONE, COLUMNAR)"
comptime _PARQUET_T = "SOURCE_PARQUET path=t.parquet total=True"


# =============================================================================
# Cut shapes, rendered whole
# =============================================================================


def test_a_scan_under_a_window_is_one_segment_that_is_the_result() raises:
    var scan = _scan()
    var flow = scan.output_schema.copy()
    var plan = _window(_names("g"), _names("o"), _flags(False), _exprs(_rn()), scan^)
    var segments = _segment(
        0, _PARQUET_T, _ops(), _WINDOW, 0, "none",
        _policy().default_morsel_rows(flow), 500,
    )
    var params = String("params: agg=0 sort=0 topn=0 window=1 batches=0\n")
    params += "  window 0: partition=[g] order=[o asc] exprs=[" + String(_rn()) + "]\n"
    assert_equal(
        render_lowered_plan(_lowered(plan, _inputs(500))),
        _plan_text(segments, params, 0),
    )


def test_a_filter_and_a_projection_under_a_window_fuse_into_its_pipeline() raises:
    var predicate = Expr.binary(BIN_GT, _col("o"), Expr.literal(ScalarValue.from_int64(5)))
    var exprs = ExprArray()
    exprs.append(_col("g"))
    exprs.append(_col("o"))
    exprs.append(_col("v"))
    var project = LogicalPlan.project(exprs^, LogicalPlan.filter(predicate.copy(), _scan()))
    var flow = project.output_schema.copy()
    var plan = _window(
        _names("g"), _names("o", "v"), _flags(True, False, 2), _exprs(_rn()), project^
    )
    var project_text = String("PROJECT g := ") + String(_col("g"))
    project_text += ", o := " + String(_col("o"))
    project_text += ", v := " + String(_col("v"))
    var segments = _segment(
        0, _PARQUET_T,
        _ops("FILTER " + String(predicate), project_text),
        _WINDOW, 0, "none", _policy().default_morsel_rows(flow), 500,
    )
    var params = String("params: agg=0 sort=0 topn=0 window=1 batches=0\n")
    params += "  window 0: partition=[g] order=[o desc, v asc] exprs=[" + String(_rn()) + "]\n"
    assert_equal(
        render_lowered_plan(_lowered(plan, _inputs(500))),
        _plan_text(segments, params, 0),
    )


def test_a_projection_over_a_window_reads_the_window_segment() raises:
    var scan = _scan()
    var scan_schema = scan.output_schema.copy()
    var window = _window(_names("g"), _names("o"), _flags(False), _exprs(_rn()), scan^)
    var exprs = ExprArray()
    exprs.append(_col("g"))
    exprs.append(_col("rn"))
    var project = LogicalPlan.project(exprs^, window^)
    var flow = project.output_schema.copy()
    var project_text = String("PROJECT g := ") + String(_col("g"))
    project_text += ", rn := " + String(_col("rn"))
    var segments = _segment(
        0, _PARQUET_T, _ops(), _WINDOW, 0, "none",
        _policy().default_morsel_rows(scan_schema), 500,
    )
    segments += _segment(
        1, "SOURCE_SINK_OUTPUT from=0", _ops(project_text), _COLLECT, -1, "0/E3",
        _policy().default_morsel_rows(flow), 0,
    )
    var params = String("params: agg=0 sort=0 topn=0 window=1 batches=0\n")
    params += "  window 0: partition=[g] order=[o asc] exprs=[" + String(_rn()) + "]\n"
    assert_equal(
        render_lowered_plan(_lowered(project, _inputs(500))),
        _plan_text(segments, params, 1),
    )


def test_two_stacked_windows_are_two_chained_segments_with_params_in_cut_order() raises:
    var scan = _scan()
    var scan_schema = scan.output_schema.copy()
    var first = _window(_names("g"), _names("o"), _flags(False), _exprs(_rn()), scan^)
    var first_schema = first.output_schema.copy()
    var rank = PartitionExpr.rank().with_alias("rk")
    var plan = _window(_names("o"), _names("rn"), _flags(True), _exprs(rank.copy()), first^)
    var segments = _segment(
        0, _PARQUET_T, _ops(), _WINDOW, 0, "none",
        _policy().default_morsel_rows(scan_schema), 500,
    )
    segments += _segment(
        1, "SOURCE_SINK_OUTPUT from=0", _ops(), _WINDOW, 1, "0/E3",
        _policy().default_morsel_rows(first_schema), 0,
    )
    var params = String("params: agg=0 sort=0 topn=0 window=2 batches=0\n")
    params += "  window 0: partition=[g] order=[o asc] exprs=[" + String(_rn()) + "]\n"
    params += "  window 1: partition=[o] order=[rn desc] exprs=[" + String(rank) + "]\n"
    assert_equal(
        render_lowered_plan(_lowered(plan, _inputs(500))),
        _plan_text(segments, params, 1),
    )


def test_a_node_with_two_functions_is_one_segment_and_one_param_row() raises:
    var scan = _scan()
    var flow = scan.output_schema.copy()
    var exprs = _exprs(_rn())
    exprs.append(_running_sum("x", "total"))
    var plan = _window(_names("g"), _names("o"), _flags(False), exprs.copy(), scan^)
    var segments = _segment(
        0, _PARQUET_T, _ops(), _WINDOW, 0, "none",
        _policy().default_morsel_rows(flow), 500,
    )
    var params = String("params: agg=0 sort=0 topn=0 window=1 batches=0\n")
    params += "  window 0: partition=[g] order=[o asc] exprs=["
    params += String(exprs[0]) + ", " + String(exprs[1]) + "]\n"
    assert_equal(
        render_lowered_plan(_lowered(plan, _inputs(500))),
        _plan_text(segments, params, 0),
    )


def test_the_declared_schema_marks_a_sum_over_a_nullable_column_nullable() raises:
    var exprs = _exprs(_rn())
    exprs.append(_running_sum("v", "sum_v"))
    exprs.append(_running_sum("x", "sum_x"))
    var avg = PartitionExpr.running_avg("v").with_frame(PartitionFrame.running_range()).with_alias("avg_v")
    exprs.append(avg^)
    var plan = _window(_names("g"), _names("o"), _flags(False), exprs^, _scan())
    # The logical node declares the sums not nullable.
    ref logical = plan.output_schema
    assert_false(logical.field_nullable(4))
    assert_false(logical.field_nullable(5))
    assert_false(logical.field_nullable(7))

    var lp = _lowered(plan, _inputs(500))
    ref declared = lp.params.window[0].output_schema
    assert_equal(declared.num_columns(), 8)
    assert_false(declared.field_nullable(4))  # rn
    assert_true(declared.field_nullable(5))  # SUM over the nullable v
    assert_false(declared.field_nullable(6))  # SUM over the non-nullable x
    assert_true(declared.field_nullable(7))  # AVG over the nullable v
    assert_equal(declared.field_name(5), "sum_v")

    # The pipeline that reads the window's output carries the same schema.
    var above = LogicalPlan.filter(
        Expr.binary(BIN_GT, _col("o"), Expr.literal(ScalarValue.from_int64(0))), plan^
    )
    var cut = cut_plan(above, _inputs(500))
    assert_equal(len(cut.flow_schemas), 2)
    assert_true(cut.flow_schemas[1].field_nullable(5))
    assert_false(cut.flow_schemas[1].field_nullable(4))
    assert_false(cut.flow_schemas[1].field_nullable(6))
    assert_true(cut.flow_schemas[1].field_nullable(7))


def _o_gt_zero(var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.filter(
        Expr.binary(BIN_GT, _col("o"), Expr.literal(ScalarValue.from_int64(0))), child^
    )


def test_every_reader_of_a_shared_window_takes_its_nullable_sum() raises:
    # (window over t) WHERE o > 0 UNION ALL (a reference to that window)
    # WHERE o > 0: the window is a shared subplan, cut once and read twice.
    var exprs = _exprs(_rn())
    exprs.append(_running_sum("v", "sum_v"))
    var window = _window(_names("g"), _names("o"), _flags(False), exprs^, _scan())
    var ref_ = LogicalPlan.cse_ref(
        window.structural_hash(), window.output_schema.copy()
    )
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_o_gt_zero(window.copy())))
    children.append(OwnedPointer(_o_gt_zero(ref_^)))
    var plan = LogicalPlan.union(children^, window.output_schema.copy())
    # The logical node declares the sum not nullable.
    assert_false(window.output_schema.field_nullable(5))

    var cut = cut_plan(plan, _inputs(500))
    # 0: the window sink. 1 and 2: each branch's filter over 0's output,
    # collected. 3: the concatenation of 1 and 2.
    assert_equal(len(cut.flow_schemas), 4)
    for seg in range(1, 3):
        assert_equal(cut.flow_schemas[seg].field_name(5), "sum_v")
        assert_true(cut.flow_schemas[seg].field_nullable(5))
        assert_false(cut.flow_schemas[seg].field_nullable(4))


def _rows(start: UInt8, start_offset: Int64, end: UInt8, end_offset: Int64) -> PartitionFrame:
    return PartitionFrame(FRAME_UNITS_ROWS, start, start_offset, end, end_offset)


def _range(start: UInt8, start_offset: Int64, end: UInt8, end_offset: Int64) -> PartitionFrame:
    return PartitionFrame(FRAME_UNITS_RANGE, start, start_offset, end, end_offset)


def test_a_frame_that_can_be_empty_makes_its_column_nullable() raises:
    # Every argument is the non-nullable x, so only the frame decides. A frame
    # that does not hold the current row is empty at a partition's edge, where
    # SUM, AVG, MIN, MAX, FIRST_VALUE and LAST_VALUE answer NULL; COUNT
    # answers 0.
    var following = _rows(FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_FOLLOWING, 2)
    var exprs = _exprs(_rn())
    exprs.append(PartitionExpr.agg_with_frame(PF_SUM, "x", following.copy()).with_alias("a"))
    exprs.append(PartitionExpr.agg_with_frame(
        PF_SUM, "x", _rows(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_FOLLOWING, 1)).with_alias("b"))
    exprs.append(PartitionExpr.agg_with_frame(
        PF_MIN, "x", _range(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_PRECEDING, 1)).with_alias("c"))
    exprs.append(PartitionExpr.first_value("x").with_frame(
        _rows(FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_PRECEDING, 1)).with_alias("d"))
    exprs.append(PartitionExpr.last_value("x").with_frame(
        _range(FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_FOLLOWING, 3)).with_alias("e"))
    exprs.append(PartitionExpr.agg_with_frame(PF_COUNT, "x", following.copy()).with_alias("f"))
    exprs.append(PartitionExpr.agg_with_frame(
        PF_MAX, "x", _rows(FRAME_BOUND_FOLLOWING, 0, FRAME_BOUND_FOLLOWING, 2)).with_alias("g2"))
    # `0 FOLLOWING` as a start and `0 PRECEDING` as an end hold the current
    # row.
    exprs.append(PartitionExpr.agg_with_frame(
        PF_AVG, "x", _range(FRAME_BOUND_FOLLOWING, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0)).with_alias("h"))
    exprs.append(PartitionExpr.agg_with_frame(
        PF_SUM, "x", _rows(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_PRECEDING, 0)).with_alias("i"))
    exprs.append(PartitionExpr.agg_with_frame(
        PF_SUM, "x", _range(FRAME_BOUND_PRECEDING, 3, FRAME_BOUND_PRECEDING, 1)).with_alias("j"))
    var plan = _window(_names("g"), _names("o"), _flags(False), exprs^, _scan())
    for c in range(4, 15):
        assert_false(plan.output_schema.field_nullable(c), "the logical column " + String(c))

    var lp = _lowered(plan, _inputs(500))
    ref declared = lp.params.window[0].output_schema
    assert_equal(declared.num_columns(), 15)
    var want: List[Bool] = [
        False,  # rn
        True,   # SUM, 1 FOLLOWING AND 2 FOLLOWING
        False,  # SUM, 1 PRECEDING AND 1 FOLLOWING
        True,   # MIN, RANGE UNBOUNDED PRECEDING AND 1 PRECEDING
        True,   # FIRST_VALUE, 2 PRECEDING AND 1 PRECEDING
        False,  # LAST_VALUE, RANGE CURRENT ROW AND 3 FOLLOWING
        False,  # COUNT, 1 FOLLOWING AND 2 FOLLOWING
        False,  # MAX, 0 FOLLOWING AND 2 FOLLOWING
        False,  # AVG, RANGE 0 FOLLOWING AND UNBOUNDED FOLLOWING
        False,  # SUM, UNBOUNDED PRECEDING AND 0 PRECEDING
        True,   # SUM, RANGE 3 PRECEDING AND 1 PRECEDING
    ]
    for j in range(len(want)):
        assert_equal(declared.field_nullable(4 + j), want[j], declared.field_name(4 + j))


def test_a_limit_above_a_window_with_keys_is_refused_and_one_with_no_key_is_cut() raises:
    var keyed = LogicalPlan.limit(
        10, _window(_names("g"), _names(), _flags(False, False, 0), _exprs(_rn()), _scan())
    )
    var message = String()
    try:
        _ = _lowered(keyed, _inputs(500))
    except e:
        message = String(e)
    assert_equal(
        message,
        String(LOWERING_UNCUTTABLE_NODE)
        + ": "
        + plan_tag_name(PLAN_LIMIT)
        + " (a limit over a sorted stream that is not one range of its sort (a"
        + " filter or a shared subplan stands between them, or the stream is a"
        + " window's output); no order is recorded on a segment) is not cut",
    )

    var row_number = PartitionExpr.row_number().with_frame(
        PartitionFrame.default_unordered()
    ).with_alias("rn")
    var scan = _scan()
    var scan_schema = scan.output_schema.copy()
    var window = _window(_names(), _names(), _flags(False, False, 0), _exprs(row_number.copy()), scan^)
    var window_schema = window.output_schema.copy()
    var plan = LogicalPlan.limit(10, window^)
    var segments = _segment(
        0, _PARQUET_T, _ops(), _WINDOW, 0, "none",
        _policy().default_morsel_rows(scan_schema), 500,
    )
    segments += _segment(
        1, "SOURCE_SINK_OUTPUT from=0", _ops("LIMIT 10"), _COLLECT, -1, "0/E3",
        _policy().default_morsel_rows(window_schema), 0,
    )
    var params = String("params: agg=0 sort=0 topn=0 window=1 batches=0\n")
    params += "  window 0: partition=[] order=[] exprs=[" + String(row_number) + "]\n"
    assert_equal(
        render_lowered_plan(_lowered(plan, _inputs(500))),
        _plan_text(segments, params, 1),
    )


def test_a_window_over_a_join_ends_the_probe_pipeline_in_the_window_sink() raises:
    var lsb = SchemaBuilder()
    lsb.add_field(Field("k", ArrowType.INT64, False))
    lsb.add_field(Field("a", ArrowType.INT64, False))
    var rsb = SchemaBuilder()
    rsb.add_field(Field("k2", ArrowType.INT64, False))
    rsb.add_field(Field("a", ArrowType.STRING, False))
    var right = LogicalPlan.scan("r.parquet", SOURCE_PARQUET, rsb.build())
    var right_schema = right.output_schema.copy()
    var join = LogicalPlan.join(
        LogicalPlan.scan("l.parquet", SOURCE_PARQUET, lsb.build()),
        right^,
        _names("k"),
        _names("k2"),
        JOIN_INNER,
        JOIN_ALGO_AUTO,
        None,
        JOIN_BUILD_SIDE_RIGHT,
    )
    var join_schema = join.output_schema.copy()
    var plan = _window(_names("k"), _names("k2"), _flags(False), _exprs(_rn()), join^)
    var segments = _segment(
        0, "SOURCE_PARQUET path=r.parquet total=True", _ops(), "(SINK_HASH_BUILD, NONE, COLUMNAR)", -1, "none",
        _policy().default_morsel_rows(right_schema), 222,
    )
    segments += _segment(
        1, "SOURCE_PARQUET path=l.parquet total=True", _ops("JOIN_PROBE build_seg=0 on=[k=k2]"),
        _WINDOW, 0, "0/E3", _policy().join_probe_morsel_rows(join_schema), 0,
    )
    var params = String("params: agg=0 sort=0 topn=0 window=1 batches=0\n")
    params += "  window 0: partition=[k] order=[k2 asc] exprs=[" + String(_rn()) + "]\n"
    assert_equal(
        render_lowered_plan(_lowered(plan, _inputs(111, 222))),
        _plan_text(segments, params, 1),
    )


def test_a_window_over_an_aggregation_reads_the_aggregate_output() raises:
    var scan = _scan()
    var scan_schema = scan.output_schema.copy()
    var group_by = ExprArray()
    group_by.append(_col("g"))
    var aggs = AggExprArray()
    var count = AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n"))
    aggs.append(count.copy())
    var agg = LogicalPlan.aggregate(group_by^, aggs^, scan^)
    var agg_schema = agg.output_schema.copy()
    var rank = PartitionExpr.rank().with_frame(PartitionFrame.running_range()).with_alias("rk")
    var plan = _window(_names(), _names("n"), _flags(True), _exprs(rank.copy()), agg^)
    var segments = _segment(
        0, _PARQUET_T, _ops(), "(SINK_AGG, STRING, COLUMNAR)", 0, "none",
        _policy().agg_morsel_rows(scan_schema), 500,
    )
    segments += _segment(
        1, "SOURCE_SINK_OUTPUT from=0", _ops(), _WINDOW, 0, "0/E3",
        _policy().default_morsel_rows(agg_schema), 0,
    )
    var params = String("params: agg=1 sort=0 topn=0 window=1 batches=0\n")
    params += "  agg 0: group_by=[" + String(_col("g")) + "] aggs=[" + String(count) + "]\n"
    params += "  window 0: partition=[] order=[n desc] exprs=[" + String(rank) + "]\n"
    assert_equal(
        render_lowered_plan(_lowered(plan, _inputs(500))),
        _plan_text(segments, params, 1),
    )


def _window_param_row(var plan: LogicalPlan) raises -> String:
    var text = render_lowered_plan(_lowered(plan, _inputs(500)))
    for line in text.split("\n"):
        if String(line).startswith("  window 0:"):
            return String(line)
    return String("")


def test_a_placement_that_is_not_the_derived_one_is_rendered_and_carried() raises:
    var placed = _window(
        _names("g"), _names("o"), _flags(False), _exprs(_rn()), _scan(),
        Optional(_flags(True)),
    )
    assert_equal(
        _window_param_row(placed^),
        "  window 0: partition=[g] order=[o asc nulls_first] exprs=["
        + String(_rn()) + "]",
    )
    var desc = _window(
        _names("g"), _names("o", "v"), _flags(True, False, 2), _exprs(_rn()),
        _scan(), Optional(_flags(True, False, 2)),
    )
    assert_equal(
        _window_param_row(desc^),
        "  window 0: partition=[g] order=[o desc nulls_first, v asc] exprs=["
        + String(_rn()) + "]",
    )
    var carried = _window(
        _names("g"), _names("o", "v"), _flags(False, True, 2), _exprs(_rn()),
        _scan(), Optional(_flags(False, True, 2)),
    )
    var lp = _lowered(carried, _inputs(500))
    assert_equal(len(lp.params.window[0].nulls_first), 2)
    assert_false(lp.params.window[0].nulls_first[0])
    assert_true(lp.params.window[0].nulls_first[1])


def test_a_placement_equal_to_the_derived_one_renders_as_no_placement() raises:
    var stated = _window(
        _names("g"), _names("o"), _flags(True), _exprs(_rn()), _scan(),
        Optional(_flags(False)),
    )
    assert_equal(
        _window_param_row(stated^),
        "  window 0: partition=[g] order=[o desc] exprs=[" + String(_rn()) + "]",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

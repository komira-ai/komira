# =============================================================================
# test_lower_joins: inner equi-joins lowered, and the rendered physical plan
# asserted
# =============================================================================
#
# Each test lowers a join under the constant reference host profile and
# compares the render with what the plan means: the build child ends in a
# SINK_HASH_BUILD segment, the probe child's pipeline gains an OP_JOIN_PROBE
# and an E3 edge to that segment. Morsel sizes are expected from the sizing
# policy: a segment with a join probe in it uses the join probe tier, applied
# to the schema that flows INTO the segment's sink.
#
#   test_the_right_child_builds_when_the_side_is_right_or_unset
#   test_the_left_child_builds_and_a_projection_restores_the_node_columns
#   test_a_three_table_chain_has_two_build_segments_and_one_probe_pipeline
#   test_a_join_under_an_aggregate_ends_the_probe_pipeline_in_the_aggregate
#   test_the_build_segment_carries_its_scans_row_count_and_the_probe_zero
#   test_scans_are_consumed_left_subtree_first_whichever_side_builds
#   test_a_build_child_that_is_an_aggregate_adds_a_segment_before_the_build
#   test_equal_arguments_render_equal
#   test_an_int32_key_against_an_int64_key_lowers
#   test_a_right_build_whose_node_renames_a_column_gains_a_projection
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
from physical_plan.physical_plan import PHYSICAL_PLAN_IR_VERSION
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_LEFT,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_BUILD_SIDE_UNSET,
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


def _names(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _table(
    path: String, a: String, at: ArrowType, b: String, bt: ArrowType
) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, at, False))
    sb.add_field(Field(b, bt, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _left() -> LogicalPlan:
    return _table("l.parquet", "k", ArrowType.INT64, "a", ArrowType.INT64)


def _right() -> LogicalPlan:
    return _table("r.parquet", "k2", ArrowType.INT64, "a", ArrowType.STRING)


def _join(var left: LogicalPlan, var right: LogicalPlan, lon: String, ron: String, side: UInt8) -> LogicalPlan:
    return LogicalPlan.join(
        left^, right^, _names(lon), _names(ron), JOIN_INNER, JOIN_ALGO_AUTO, None, side
    )


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows,
        List[String](),
        List[ColumnStats](),
        STATS_SOURCE_PARQUET_METADATA,
    )


def _inputs(a: Int, b: Int, c: Int = -1) -> LoweringInputs:
    """The facts of two scans (three when `c` is given), in scan order."""
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(a)))
    inputs.add_scan(Optional[TableStats](_stats(b)))
    if c >= 0:
        inputs.add_scan(Optional[TableStats](_stats(c)))
    return inputs^


def _host() raises -> HostProfile:
    return reference_host_profile("test-build")


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, _host(), inputs)


def _policy() raises -> MorselSizingPolicy:
    return MorselSizingPolicy.for_host(_host())


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


def _no_params() -> String:
    return String("params: agg=0 sort=0 topn=0 batches=0\n")


def _ops(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _no_ops() -> List[String]:
    return List[String]()


comptime _BUILD = "(SINK_HASH_BUILD, NONE, COLUMNAR)"
comptime _COLLECT = "(SINK_COLLECT, NONE, COLUMNAR)"


# =============================================================================
# The build side and the probe pipeline
# =============================================================================


def _right_builds_text(right_schema: Schema, out_schema: Schema) raises -> String:
    var segments = _segment(
        0, "SOURCE_PARQUET path=r.parquet total=True", _no_ops(), _BUILD, -1, "none",
        _policy().default_morsel_rows(right_schema), 222,
    )
    segments += _segment(
        1, "SOURCE_PARQUET path=l.parquet total=True", _ops("JOIN_PROBE build_seg=0 on=[k=k2]"),
        _COLLECT, -1, "0/E3", _policy().join_probe_morsel_rows(out_schema), 0,
    )
    return _plan_text(segments, _no_params(), 1)


def _check_right_builds(side: UInt8) raises:
    var plan = _join(_left(), _right(), "k", "k2", side)
    var out_schema = plan.output_schema.copy()
    var expected = _right_builds_text(_right().output_schema.copy(), out_schema)
    assert_equal(render_lowered_plan(_lowered(plan, _inputs(111, 222))), expected)


def test_the_right_child_builds_when_the_side_is_right_or_unset() raises:
    _check_right_builds(JOIN_BUILD_SIDE_RIGHT)
    _check_right_builds(JOIN_BUILD_SIDE_UNSET)


def test_the_left_child_builds_and_a_projection_restores_the_node_columns() raises:
    var plan = _join(_left(), _right(), "k", "k2", JOIN_BUILD_SIDE_LEFT)
    var out_schema = plan.output_schema.copy()
    # The node's columns are k, a, k2, a_right; the probe emits the right
    # child's columns first (k2, a), then the left child's (k, a_right).
    var project = String("PROJECT k := ") + String(_col("k"))
    project += ", a := " + String(_col("a_right"))
    project += ", k2 := " + String(_col("k2"))
    project += ", a_right := " + String(_col("a"))
    var segments = _segment(
        0, "SOURCE_PARQUET path=l.parquet total=True", _no_ops(), _BUILD, -1, "none",
        _policy().default_morsel_rows(_left().output_schema.copy()), 111,
    )
    segments += _segment(
        1, "SOURCE_PARQUET path=r.parquet total=True",
        _ops("JOIN_PROBE build_seg=0 on=[k2=k]", project),
        _COLLECT, -1, "0/E3", _policy().join_probe_morsel_rows(out_schema), 0,
    )
    var expected = _plan_text(segments, _no_params(), 1)
    assert_equal(render_lowered_plan(_lowered(plan, _inputs(111, 222))), expected)


def test_a_three_table_chain_has_two_build_segments_and_one_probe_pipeline() raises:
    var customer = _table("customer.parquet", "c_custkey", ArrowType.INT64, "c_name", ArrowType.STRING)
    var orders = _table("orders.parquet", "o_orderkey", ArrowType.INT64, "o_custkey", ArrowType.INT64)
    var lineitem = _table("lineitem.parquet", "l_orderkey", ArrowType.INT64, "l_price", ArrowType.FLOAT64)
    var orders_schema = orders.output_schema.copy()
    var lineitem_schema = lineitem.output_schema.copy()
    var inner = _join(customer^, orders^, "c_custkey", "o_custkey", JOIN_BUILD_SIDE_RIGHT)
    var plan = _join(inner^, lineitem^, "o_orderkey", "l_orderkey", JOIN_BUILD_SIDE_RIGHT)
    var out_schema = plan.output_schema.copy()
    var segments = _segment(
        0, "SOURCE_PARQUET path=orders.parquet total=True", _no_ops(), _BUILD, -1, "none",
        _policy().default_morsel_rows(orders_schema), 20,
    )
    segments += _segment(
        1, "SOURCE_PARQUET path=lineitem.parquet total=True", _no_ops(), _BUILD, -1, "none",
        _policy().default_morsel_rows(lineitem_schema), 30,
    )
    segments += _segment(
        2,
        "SOURCE_PARQUET path=customer.parquet total=True",
        _ops(
            "JOIN_PROBE build_seg=0 on=[c_custkey=o_custkey]",
            "JOIN_PROBE build_seg=1 on=[o_orderkey=l_orderkey]",
        ),
        _COLLECT, -1, "0/E3 1/E3", _policy().join_probe_morsel_rows(out_schema), 0,
    )
    var expected = _plan_text(segments, _no_params(), 2)
    assert_equal(render_lowered_plan(_lowered(plan, _inputs(10, 20, 30))), expected)


def _count_by_s(var child: LogicalPlan) -> LogicalPlan:
    var group_by = ExprArray()
    group_by.append(_col("s"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    return LogicalPlan.aggregate(group_by^, aggs^, child^)


def _s_left() -> LogicalPlan:
    return _table("l.parquet", "k", ArrowType.INT64, "s", ArrowType.STRING)


def _v_right() -> LogicalPlan:
    return _table("r.parquet", "k2", ArrowType.INT64, "v", ArrowType.INT64)


def test_a_join_under_an_aggregate_ends_the_probe_pipeline_in_the_aggregate() raises:
    var join = _join(_s_left(), _v_right(), "k", "k2", JOIN_BUILD_SIDE_RIGHT)
    var join_schema = join.output_schema.copy()
    var plan = _count_by_s(join^)
    var segments = _segment(
        0, "SOURCE_PARQUET path=r.parquet total=True", _no_ops(), _BUILD, -1, "none",
        _policy().default_morsel_rows(_v_right().output_schema.copy()), 0,
    )
    # The string key is from a dictionary encoded column of the probe scan, but
    # after a join the name may no longer mean that column: COLUMNAR.
    segments += _segment(
        1, "SOURCE_PARQUET path=l.parquet total=True", _ops("JOIN_PROBE build_seg=0 on=[k=k2]"),
        "(SINK_AGG, STRING, COLUMNAR)", 0, "0/E3", _policy().join_probe_morsel_rows(join_schema), 0,
    )
    var params = String("params: agg=1 sort=0 topn=0 batches=0\n")
    params += "  agg 0: group_by=[" + String(_col("s")) + "] aggs=["
    params += String(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n"))) + "]\n"
    var expected = _plan_text(segments, params, 1)
    var inputs = LoweringInputs()
    inputs.add_scan(None, _names("s"))
    inputs.add_scan()
    assert_equal(render_lowered_plan(_lowered(plan, inputs)), expected)

    # The same aggregate over the dictionary encoded scan alone keeps the
    # dictionary encoding.
    var alone = LoweringInputs()
    alone.add_scan(None, _names("s"))
    var lp = _lowered(_count_by_s(_s_left()), alone)
    ref seg = lp.segments[lp.result_seg_id]
    assert_equal(
        triple_name(seg.sink_kind, seg.sink_key_dtype, seg.sink_orientation),
        "(SINK_AGG, STRING, DICT_ENCODED)",
    )


# =============================================================================
# Estimates and scan order
# =============================================================================


def test_the_build_segment_carries_its_scans_row_count_and_the_probe_zero() raises:
    var plan = _join(_left(), _right(), "k", "k2", JOIN_BUILD_SIDE_RIGHT)
    var lp = _lowered(plan, _inputs(111, 222))
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].card_estimate_rows, 222)
    assert_equal(lp.segments[1].card_estimate_rows, 0)
    assert_equal(lp.segments[0].mem_estimate_bytes, 0)
    assert_equal(lp.segments[1].mem_estimate_bytes, 0)


def test_scans_are_consumed_left_subtree_first_whichever_side_builds() raises:
    var right_builds = _lowered(
        _join(_left(), _right(), "k", "k2", JOIN_BUILD_SIDE_RIGHT), _inputs(111, 222)
    )
    assert_equal(right_builds.segments[0].source_spec.parquet_path, "r.parquet")
    assert_equal(right_builds.segments[0].card_estimate_rows, 222)
    assert_equal(right_builds.segments[1].source_spec.parquet_path, "l.parquet")

    var left_builds = _lowered(
        _join(_left(), _right(), "k", "k2", JOIN_BUILD_SIDE_LEFT), _inputs(111, 222)
    )
    assert_equal(left_builds.segments[0].source_spec.parquet_path, "l.parquet")
    assert_equal(left_builds.segments[0].card_estimate_rows, 111)
    assert_equal(left_builds.segments[1].source_spec.parquet_path, "r.parquet")


def test_a_build_child_that_is_an_aggregate_adds_a_segment_before_the_build() raises:
    var group_by = ExprArray()
    group_by.append(_col("k2"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var agg = LogicalPlan.aggregate(group_by^, aggs^, _v_right())
    var agg_schema = agg.output_schema.copy()
    var scan_schema = _v_right().output_schema.copy()
    var plan = _join(_left(), agg^, "k", "k2", JOIN_BUILD_SIDE_RIGHT)
    var out_schema = plan.output_schema.copy()
    var segments = _segment(
        0, "SOURCE_PARQUET path=r.parquet total=True", _no_ops(), "(SINK_AGG, I64, COLUMNAR)", 0, "none",
        _policy().agg_morsel_rows(scan_schema), 700,
    )
    segments += _segment(
        1, "SOURCE_SINK_OUTPUT from=0", _no_ops(), _BUILD, -1, "0/E3",
        _policy().default_morsel_rows(agg_schema), 0,
    )
    segments += _segment(
        2, "SOURCE_PARQUET path=l.parquet total=True", _ops("JOIN_PROBE build_seg=1 on=[k=k2]"),
        _COLLECT, -1, "1/E3", _policy().join_probe_morsel_rows(out_schema), 0,
    )
    var params = String("params: agg=1 sort=0 topn=0 batches=0\n")
    params += "  agg 0: group_by=[" + String(_col("k2")) + "] aggs=["
    params += String(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n"))) + "]\n"
    var expected = _plan_text(segments, params, 2)
    assert_equal(render_lowered_plan(_lowered(plan, _inputs(500, 700))), expected)


# =============================================================================
# Determinism and key types
# =============================================================================


def test_equal_arguments_render_equal() raises:
    var a = render_lowered_plan(
        _lowered(_join(_left(), _right(), "k", "k2", JOIN_BUILD_SIDE_LEFT), _inputs(111, 222))
    )
    var b = render_lowered_plan(
        _lowered(_join(_left(), _right(), "k", "k2", JOIN_BUILD_SIDE_LEFT), _inputs(111, 222))
    )
    assert_equal(a, b)


def test_an_int32_key_against_an_int64_key_lowers() raises:
    var left = _table("l.parquet", "k32", ArrowType.INT32, "a", ArrowType.INT64)
    var plan = _join(left^, _right(), "k32", "k2", JOIN_BUILD_SIDE_RIGHT)
    var text = render_lowered_plan(_lowered(plan, _inputs(111, 222)))
    assert_true("JOIN_PROBE build_seg=0 on=[k32=k2]" in text, text)
    var swapped = _table("r.parquet", "k2", ArrowType.INT32, "a", ArrowType.STRING)
    var plan2 = _join(_left(), swapped^, "k", "k2", JOIN_BUILD_SIDE_RIGHT)
    var text2 = render_lowered_plan(_lowered(plan2, _inputs(111, 222)))
    assert_true("JOIN_PROBE build_seg=0 on=[k=k2]" in text2, text2)


def test_a_right_build_whose_node_renames_a_column_gains_a_projection() raises:
    # The probe emits k, a, k2, a_right; a node that names the last column
    # `ra` gets a projection after the probe under the node's names, and the
    # same join under the probe's own names gets none.
    var plan = _join(_left(), _right(), "k", "k2", JOIN_BUILD_SIDE_RIGHT)
    var text = render_lowered_plan(_lowered(plan, _inputs(111, 222)))
    assert_true("PROJECT " not in text, text)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("k2", ArrowType.INT64, False))
    sb.add_field(Field("ra", ArrowType.STRING, False))
    plan.output_schema = sb.build()
    var renamed = render_lowered_plan(_lowered(plan, _inputs(111, 222)))
    assert_true("PROJECT k := " in renamed, renamed)
    assert_true(", ra := " in renamed, renamed)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

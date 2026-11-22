# =============================================================================
# test_lower_join_kinds: LEFT, RIGHT, FULL, SEMI, ANTI and CROSS joins lowered
# =============================================================================
#
# Each test lowers a join under the constant reference host profile and reads
# the segments: the build child ends in a SINK_HASH_BUILD segment (its
# `sink_param_id` is -1), the probe child's pipeline gains an OP_JOIN_PROBE
# with an E3 edge to that segment. The probe's join type is the probe's view,
# the probe side as its left input: the plan's type when the right child
# builds (side RIGHT or UNSET); LEFT and RIGHT exchanged when the left child
# builds, with INNER, FULL and CROSS as they are, and a projection after the
# probe that puts the columns in the node's order under the node's names.
#
#   test_a_right_building_outer_join_keeps_the_plan_type_and_its_columns
#   test_an_unset_build_side_builds_the_right_child
#   test_a_semi_or_anti_join_probes_with_its_left_columns_only
#   test_a_cross_join_probes_with_no_key
#   test_a_left_join_that_builds_its_left_child_probes_as_a_right_join
#   test_a_right_join_that_builds_its_left_child_probes_as_a_left_join
#   test_full_inner_and_cross_joins_keep_their_type_when_the_left_child_builds
#   test_a_left_build_projection_renames_a_colliding_column_to_the_nodes_name
#   test_a_nested_join_meets_its_scans_in_pre_order
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import LoweredPlan, LoweringInputs
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    KEY_DTYPE_NONE,
    OP_JOIN_PROBE,
    OP_PROJECT,
    SINK_COLLECT,
    SINK_HASH_BUILD,
    SINK_ORIENT_COLUMNAR,
)
from plan_expr.expr import Expr
from plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
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


def _names(a: String = "", b: String = "") -> List[String]:
    var out = List[String]()
    if a != "":
        out.append(a)
    if b != "":
        out.append(b)
    return out^


def _joined(names: List[String]) -> String:
    var out = String("")
    for i in range(len(names)):
        if i > 0:
            out += ","
        out += names[i]
    return out^


def _table(
    path: String, a: String, at: ArrowType, b: String, bt: ArrowType
) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, at, False))
    sb.add_field(Field(b, bt, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _left() -> LogicalPlan:
    return _table("l.parquet", "k", ArrowType.INT64, "v", ArrowType.INT64)


def _right() -> LogicalPlan:
    return _table("r.parquet", "k2", ArrowType.INT64, "w", ArrowType.STRING)


def _join(join_type: UInt8, side: UInt8) -> LogicalPlan:
    """A join of the two tables on k = k2; a CROSS join names no key."""
    var lon = _names("k")
    var ron = _names("k2")
    if join_type == JOIN_CROSS:
        lon = _names()
        ron = _names()
    return LogicalPlan.join(
        _left(), _right(), lon^, ron^, join_type, JOIN_ALGO_AUTO, None, side
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


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, reference_host_profile("test-build"), inputs)


def _node_names(plan: LogicalPlan) -> String:
    var out = List[String]()
    for i in range(plan.output_schema.num_columns()):
        out.append(plan.output_schema.field_name(i))
    return _joined(out)


def _expect_two_segments(
    lp: LoweredPlan, build_path: String, probe_path: String
) raises:
    """Segment 0 builds `build_path`; segment 1 reads `probe_path`, waits for
    segment 0 over an E3 edge and collects the result."""
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.result_seg_id, 1)
    ref build = lp.segments[0]
    assert_equal(build.source_spec.parquet_path, build_path)
    assert_equal(build.sink_kind, SINK_HASH_BUILD)
    assert_equal(build.sink_key_dtype, KEY_DTYPE_NONE)
    assert_equal(build.sink_orientation, SINK_ORIENT_COLUMNAR)
    assert_equal(build.sink_param_id, -1)
    assert_equal(len(build.deps), 0)
    assert_equal(len(build.ops), 0)
    ref probe = lp.segments[1]
    assert_equal(probe.source_spec.parquet_path, probe_path)
    assert_equal(probe.sink_kind, SINK_COLLECT)
    assert_equal(len(probe.deps), 1)
    assert_equal(probe.deps[0], 0)
    assert_equal(probe.edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    assert_true(len(probe.ops) >= 1, "the probe segment holds no operator")
    assert_equal(probe.ops[0].tag, OP_JOIN_PROBE)
    assert_equal(probe.ops[0].probe_build_seg, 0)


def _expect_probe(
    lp: LoweredPlan, join_type: UInt8, probe_keys: String, build_keys: String
) raises:
    ref op = lp.segments[1].ops[0]
    assert_equal(op.probe_join_type, join_type)
    assert_equal(_joined(op.probe_left_keys), probe_keys)
    assert_equal(_joined(op.probe_right_keys), build_keys)


def _check_right_builds(join_type: UInt8, side: UInt8, node_names: String) raises:
    var plan = _join(join_type, side)
    assert_equal(_node_names(plan), node_names)
    var lp = _lowered(plan, _inputs(111, 222))
    _expect_two_segments(lp, "r.parquet", "l.parquet")
    assert_equal(lp.segments[0].card_estimate_rows, 222)
    var keyed = join_type != JOIN_CROSS
    _expect_probe(lp, join_type, "k" if keyed else "", "k2" if keyed else "")
    # The probe emits the node's columns under the node's names: no projection.
    assert_equal(len(lp.segments[1].ops), 1)
    var text = render_lowered_plan(lp)
    assert_true("PROJECT " not in text, text)


# =============================================================================
# The right child builds
# =============================================================================


def test_a_right_building_outer_join_keeps_the_plan_type_and_its_columns() raises:
    _check_right_builds(JOIN_LEFT, JOIN_BUILD_SIDE_RIGHT, "k,v,k2,w")
    _check_right_builds(JOIN_RIGHT, JOIN_BUILD_SIDE_RIGHT, "k,v,k2,w")
    _check_right_builds(JOIN_FULL, JOIN_BUILD_SIDE_RIGHT, "k,v,k2,w")


def test_an_unset_build_side_builds_the_right_child() raises:
    _check_right_builds(JOIN_LEFT, JOIN_BUILD_SIDE_UNSET, "k,v,k2,w")
    _check_right_builds(JOIN_FULL, JOIN_BUILD_SIDE_UNSET, "k,v,k2,w")
    _check_right_builds(JOIN_SEMI, JOIN_BUILD_SIDE_UNSET, "k,v")
    _check_right_builds(JOIN_CROSS, JOIN_BUILD_SIDE_UNSET, "k,v,k2,w")


def test_a_semi_or_anti_join_probes_with_its_left_columns_only() raises:
    _check_right_builds(JOIN_SEMI, JOIN_BUILD_SIDE_RIGHT, "k,v")
    _check_right_builds(JOIN_ANTI, JOIN_BUILD_SIDE_RIGHT, "k,v")
    _check_right_builds(JOIN_ANTI, JOIN_BUILD_SIDE_UNSET, "k,v")


def test_a_cross_join_probes_with_no_key() raises:
    _check_right_builds(JOIN_CROSS, JOIN_BUILD_SIDE_RIGHT, "k,v,k2,w")
    var lp = _lowered(_join(JOIN_CROSS, JOIN_BUILD_SIDE_RIGHT), _inputs(111, 222))
    assert_equal(len(lp.segments[1].ops[0].probe_left_keys), 0)
    assert_equal(len(lp.segments[1].ops[0].probe_right_keys), 0)


# =============================================================================
# The left child builds
# =============================================================================


def _check_left_builds(join_type: UInt8, probe_type: UInt8) raises:
    """The left child builds: the probe is the right child, its keys are the
    right keys, and a projection restores the node's columns."""
    var plan = _join(join_type, JOIN_BUILD_SIDE_LEFT)
    assert_equal(_node_names(plan), "k,v,k2,w")
    var lp = _lowered(plan, _inputs(111, 222))
    _expect_two_segments(lp, "l.parquet", "r.parquet")
    assert_equal(lp.segments[0].card_estimate_rows, 111)
    var keyed = join_type != JOIN_CROSS
    _expect_probe(lp, probe_type, "k2" if keyed else "", "k" if keyed else "")
    # The probe emits the right child's columns (k2, w) and then the left's
    # (k, v); the projection names them in the node's order.
    ref seg = lp.segments[1]
    assert_equal(len(seg.ops), 2)
    assert_equal(seg.ops[1].tag, OP_PROJECT)
    assert_equal(_joined(seg.ops[1].project_names.value()), "k,v,k2,w")
    var text = render_lowered_plan(lp)
    assert_true("PROJECT k := " + String(Expr.col_ref("k")) in text, text)
    assert_true(", w := " + String(Expr.col_ref("w")) in text, text)


def test_a_left_join_that_builds_its_left_child_probes_as_a_right_join() raises:
    _check_left_builds(JOIN_LEFT, JOIN_RIGHT)


def test_a_right_join_that_builds_its_left_child_probes_as_a_left_join() raises:
    _check_left_builds(JOIN_RIGHT, JOIN_LEFT)


def test_full_inner_and_cross_joins_keep_their_type_when_the_left_child_builds() raises:
    _check_left_builds(JOIN_FULL, JOIN_FULL)
    _check_left_builds(JOIN_INNER, JOIN_INNER)
    _check_left_builds(JOIN_CROSS, JOIN_CROSS)


def test_a_left_build_projection_renames_a_colliding_column_to_the_nodes_name() raises:
    # Both sides hold `k`; the node names the right one `k_right`. The probe
    # emits the right child first, so its `k` is the probe's `k` and the left
    # child's is the probe's `k_right`; the projection restores the node's
    # names, `k` from the probe's `k_right`.
    var left = _table("l.parquet", "k", ArrowType.INT64, "a", ArrowType.INT64)
    var right = _table("r.parquet", "k", ArrowType.INT64, "b", ArrowType.INT64)
    var plan = LogicalPlan.join(
        left^,
        right^,
        _names("k"),
        _names("k"),
        JOIN_LEFT,
        JOIN_ALGO_AUTO,
        None,
        JOIN_BUILD_SIDE_LEFT,
    )
    assert_equal(_node_names(plan), "k,a,k_right,b")
    var lp = _lowered(plan, _inputs(111, 222))
    _expect_two_segments(lp, "l.parquet", "r.parquet")
    _expect_probe(lp, JOIN_RIGHT, "k", "k")
    ref seg = lp.segments[1]
    assert_equal(len(seg.ops), 2)
    assert_equal(seg.ops[1].tag, OP_PROJECT)
    assert_equal(_joined(seg.ops[1].project_names.value()), "k,a,k_right,b")
    var text = render_lowered_plan(lp)
    assert_true("PROJECT k := " + String(Expr.col_ref("k_right")) in text, text)
    assert_true(", k_right := " + String(Expr.col_ref("k")) in text, text)
    # The same join that builds its right child needs no projection.
    var right_builds = LogicalPlan.join(
        _table("l.parquet", "k", ArrowType.INT64, "a", ArrowType.INT64),
        _table("r.parquet", "k", ArrowType.INT64, "b", ArrowType.INT64),
        _names("k"),
        _names("k"),
        JOIN_LEFT,
        JOIN_ALGO_AUTO,
        None,
        JOIN_BUILD_SIDE_RIGHT,
    )
    var lp2 = _lowered(right_builds, _inputs(111, 222))
    assert_equal(len(lp2.segments[1].ops), 1)
    _expect_probe(lp2, JOIN_LEFT, "k", "k")


# =============================================================================
# Scan order
# =============================================================================


def test_a_nested_join_meets_its_scans_in_pre_order() raises:
    # (a LEFT JOIN b) FULL JOIN c, the right child building each time: the
    # scans are a, b, c, so segment 0 builds b (222) and segment 1 builds c (333).
    var a = _table("a.parquet", "k", ArrowType.INT64, "x", ArrowType.INT64)
    var b = _table("b.parquet", "k2", ArrowType.INT64, "y", ArrowType.INT64)
    var c = _table("c.parquet", "k3", ArrowType.INT64, "z", ArrowType.INT64)
    var inner = LogicalPlan.join(
        a^, b^, _names("k"), _names("k2"), JOIN_LEFT,
        JOIN_ALGO_AUTO, None, JOIN_BUILD_SIDE_RIGHT,
    )
    var plan = LogicalPlan.join(
        inner^, c^, _names("k2"), _names("k3"), JOIN_FULL,
        JOIN_ALGO_AUTO, None, JOIN_BUILD_SIDE_RIGHT,
    )
    var lp = _lowered(plan, _inputs(111, 222, 333))
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].source_spec.parquet_path, "b.parquet")
    assert_equal(lp.segments[0].card_estimate_rows, 222)
    assert_equal(lp.segments[1].source_spec.parquet_path, "c.parquet")
    assert_equal(lp.segments[1].card_estimate_rows, 333)
    ref probe = lp.segments[2]
    assert_equal(probe.source_spec.parquet_path, "a.parquet")
    assert_equal(len(probe.ops), 2)
    assert_equal(probe.ops[0].probe_build_seg, 0)
    assert_equal(probe.ops[0].probe_join_type, JOIN_LEFT)
    assert_equal(probe.ops[1].probe_build_seg, 1)
    assert_equal(probe.ops[1].probe_join_type, JOIN_FULL)
    assert_equal(len(probe.deps), 2)
    assert_equal(probe.edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    assert_equal(probe.edge_tags[1], EDGE_E3_PUBLISH_WAIT)

    # a LEFT JOIN (b INNER JOIN c), the outer join building its left child a:
    # b and c are walked before a is closed, so segment 0 builds c (333), then
    # segment 1 builds a (111), and b is the probe's source.
    var a2 = _table("a.parquet", "k", ArrowType.INT64, "x", ArrowType.INT64)
    var b2 = _table("b.parquet", "k2", ArrowType.INT64, "y", ArrowType.INT64)
    var c2 = _table("c.parquet", "k3", ArrowType.INT64, "z", ArrowType.INT64)
    var right = LogicalPlan.join(
        b2^, c2^, _names("k2"), _names("k3"), JOIN_INNER,
        JOIN_ALGO_AUTO, None, JOIN_BUILD_SIDE_RIGHT,
    )
    var plan2 = LogicalPlan.join(
        a2^, right^, _names("k"), _names("k2"), JOIN_LEFT,
        JOIN_ALGO_AUTO, None, JOIN_BUILD_SIDE_LEFT,
    )
    var lp2 = _lowered(plan2, _inputs(111, 222, 333))
    assert_equal(len(lp2.segments), 3)
    assert_equal(lp2.segments[0].source_spec.parquet_path, "c.parquet")
    assert_equal(lp2.segments[0].card_estimate_rows, 333)
    assert_equal(lp2.segments[1].source_spec.parquet_path, "a.parquet")
    assert_equal(lp2.segments[1].card_estimate_rows, 111)
    ref probe2 = lp2.segments[2]
    assert_equal(probe2.source_spec.parquet_path, "b.parquet")
    assert_equal(probe2.ops[0].probe_build_seg, 0)
    assert_equal(probe2.ops[0].probe_join_type, JOIN_INNER)
    assert_equal(probe2.ops[1].probe_build_seg, 1)
    assert_equal(probe2.ops[1].probe_join_type, JOIN_RIGHT)
    assert_equal(probe2.ops[2].tag, OP_PROJECT)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_lower_union: how a UNION ALL is cut, and what about one is refused
# =============================================================================
#
# A union ends each branch in a segment of its own and opens a pipeline whose
# source is SOURCE_CONCAT over those segments, in branch order, with an E3
# edge to each. Each test builds a small plan, lowers it under the reference
# host profile and checks the segments, their sources, edges, operators and
# sinks, or the refusal text.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweredPlan,
    LoweringInputs,
    LOWERING_UNCUTTABLE_NODE,
    LOWERING_INPUTS_SCAN_COUNT,
    LOWERING_JOIN_UNSERVED,
)
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    KEY_DTYPE_I64,
    KEY_DTYPE_STRING,
    OP_FILTER,
    OP_LIMIT,
    OP_PROJECT,
    SINK_AGG,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SINK_SORT,
    SOURCE_CONCAT,
    SOURCE_PARQUET as SEG_SOURCE_PARQUET,
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
    PLAN_UNION,
    plan_tag_name,
)
from plan_stats.table_stats import TableStats, STATS_SOURCE_PARQUET_METADATA
from plan_stats.table_stats import ColumnStats


# =============================================================================
# Fixtures
# =============================================================================


def _schema(first: String = "k", nullable: Bool = False) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(first, ArrowType.INT64, nullable))
    sb.add_field(Field("s", ArrowType.STRING, False))
    return sb.build()


def _scan_of(path: String, schema: Schema) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, schema.copy())


def _scan(path: String) -> LogicalPlan:
    return _scan_of(path, _schema())


def _union_as(
    var a: LogicalPlan, var b: LogicalPlan, schema: Schema
) -> LogicalPlan:
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(a^))
    children.append(OwnedPointer(b^))
    return LogicalPlan.union(children^, schema.copy())


def _union2(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    return _union_as(a^, b^, _schema())


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows,
        List[String](),
        List[ColumnStats](),
        STATS_SOURCE_PARQUET_METADATA,
    )


def _inputs(scans: Int) -> LoweringInputs:
    var inputs = LoweringInputs()
    for _ in range(scans):
        inputs.add_scan()
    return inputs^


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, reference_host_profile("test-build"), inputs)


def _count_by(var child: LogicalPlan, key: String) -> LogicalPlan:
    var group_by = ExprArray()
    group_by.append(Expr.col_ref(key))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    return LogicalPlan.aggregate(group_by^, aggs^, child^)


def _k_gt(v: Int64) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref("k"), Expr.literal(ScalarValue.from_int64(v)))


def _message(plan: LogicalPlan, inputs: LoweringInputs) raises -> String:
    """The refusal text, or an empty string when the plan lowers."""
    try:
        _ = _lowered(plan, inputs)
    except e:
        return String(e)
    return String("")


def _refused_with(message: String, token: String, why: String) raises:
    assert_true(message.startswith(token + ": "), String("message does not start with the token: ") + message)
    assert_true(why in message, String("message does not say why (") + why + "): " + message)


def _expect_concat_of(lp: LoweredPlan, seg: Int, a: Int, b: Int) raises:
    """Segment `seg` reads the outputs of `a` then `b` over E3 edges."""
    ref s = lp.segments[seg]
    assert_equal(s.source_kind, SOURCE_CONCAT)
    assert_equal(len(s.source_spec.dep_seg_ids), 2)
    assert_equal(s.source_spec.dep_seg_ids[0], a)
    assert_equal(s.source_spec.dep_seg_ids[1], b)
    assert_equal(len(s.deps), 2)
    assert_equal(s.deps[0], a)
    assert_equal(s.deps[1], b)
    assert_equal(s.edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    assert_equal(s.edge_tags[1], EDGE_E3_PUBLISH_WAIT)


# =============================================================================
# Cut shapes
# =============================================================================


def test_a_union_of_two_scans_collects_each_branch_and_concatenates() raises:
    var plan = _union2(_scan("a.parquet"), _scan("b.parquet"))
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(10)))
    inputs.add_scan(Optional[TableStats](_stats(20)))
    var lp = _lowered(plan, inputs)
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.result_seg_id, 2)
    # Each branch is its own collect segment over its own file, with its own
    # scan's row count.
    assert_equal(lp.segments[0].source_kind, SEG_SOURCE_PARQUET)
    assert_equal(lp.segments[0].source_spec.parquet_path, "a.parquet")
    assert_equal(lp.segments[0].sink_kind, SINK_COLLECT)
    assert_equal(lp.segments[0].card_estimate_rows, 10)
    assert_equal(len(lp.segments[0].deps), 0)
    assert_equal(lp.segments[1].source_spec.parquet_path, "b.parquet")
    assert_equal(lp.segments[1].sink_kind, SINK_COLLECT)
    assert_equal(lp.segments[1].card_estimate_rows, 20)
    # The union is the concatenation of segments 0 then 1, collected.
    _expect_concat_of(lp, 2, 0, 1)
    assert_equal(len(lp.segments[2].ops), 0)
    assert_equal(lp.segments[2].sink_kind, SINK_COLLECT)
    assert_equal(lp.segments[2].card_estimate_rows, 0)
    var text = render_lowered_plan(lp)
    assert_true("  source: SOURCE_CONCAT from=0,1\n" in text, text)
    assert_true("  deps: 0/E3 1/E3\n" in text, text)


def test_a_union_of_three_branches_reads_them_in_branch_order() raises:
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_scan("a.parquet")))
    children.append(OwnedPointer(_scan("b.parquet")))
    children.append(OwnedPointer(_scan("c.parquet")))
    var plan = LogicalPlan.union(children^, _schema())
    var lp = _lowered(plan, _inputs(3))
    assert_equal(len(lp.segments), 4)
    assert_equal(lp.segments[0].source_spec.parquet_path, "a.parquet")
    assert_equal(lp.segments[1].source_spec.parquet_path, "b.parquet")
    assert_equal(lp.segments[2].source_spec.parquet_path, "c.parquet")
    ref top = lp.segments[3]
    assert_equal(top.source_kind, SOURCE_CONCAT)
    assert_equal(len(top.source_spec.dep_seg_ids), 3)
    for i in range(3):
        assert_equal(top.source_spec.dep_seg_ids[i], i)
        assert_equal(top.deps[i], i)
        assert_equal(top.edge_tags[i], EDGE_E3_PUBLISH_WAIT)


def test_operators_above_a_union_fuse_onto_the_concatenation() raises:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("s"))
    var union = _union2(_scan("a.parquet"), _scan("b.parquet"))
    var plan = LogicalPlan.limit(
        5, LogicalPlan.project(exprs^, LogicalPlan.filter(_k_gt(3), union^))
    )
    var lp = _lowered(plan, _inputs(2))
    assert_equal(len(lp.segments), 3)
    assert_equal(len(lp.segments[0].ops), 0)
    assert_equal(len(lp.segments[1].ops), 0)
    _expect_concat_of(lp, 2, 0, 1)
    ref top = lp.segments[2]
    assert_equal(len(top.ops), 3)
    assert_equal(top.ops[0].tag, OP_FILTER)
    assert_equal(top.ops[1].tag, OP_PROJECT)
    assert_equal(top.ops[2].tag, OP_LIMIT)
    assert_equal(top.ops[2].limit_count, 5)
    assert_equal(top.sink_kind, SINK_COLLECT)


def test_an_aggregate_above_a_union_closes_the_concatenation_columnar() raises:
    # Both scans' footers say `s` is dictionary encoded in every row group,
    # but the aggregate reads the concatenation, not a scan: COLUMNAR.
    var inputs = LoweringInputs()
    var dict_a = List[String]()
    dict_a.append("s")
    var dict_b = List[String]()
    dict_b.append("s")
    inputs.add_scan(None, dict_a^)
    inputs.add_scan(None, dict_b^)
    var plan = _count_by(_union2(_scan("a.parquet"), _scan("b.parquet")), "s")
    var lp = _lowered(plan, inputs)
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.result_seg_id, 2)
    _expect_concat_of(lp, 2, 0, 1)
    assert_equal(lp.segments[2].sink_kind, SINK_AGG)
    assert_equal(lp.segments[2].sink_key_dtype, KEY_DTYPE_STRING)
    assert_equal(lp.segments[2].sink_orientation, SINK_ORIENT_COLUMNAR)


def test_a_sort_above_a_union_sorts_the_concatenation() raises:
    var keys = List[String]()
    keys.append("k")
    var desc = List[Bool]()
    desc.append(False)
    var plan = LogicalPlan.sort(
        keys^, desc^, _union2(_scan("a.parquet"), _scan("b.parquet"))
    )
    var lp = _lowered(plan, _inputs(2))
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.result_seg_id, 2)
    _expect_concat_of(lp, 2, 0, 1)
    assert_equal(lp.segments[2].sink_kind, SINK_SORT)


def test_a_branch_that_ends_in_a_breaker_is_read_from_that_segment() raises:
    # Two grouped counts of one schema: each branch is its aggregate's own
    # segment, and no collect segment stands between it and the union.
    var a = _count_by(_scan("a.parquet"), "k")
    var b = _count_by(_scan("b.parquet"), "k")
    var schema = a.output_schema.copy()
    var lp = _lowered(_union_as(a^, b^, schema), _inputs(2))
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    assert_equal(lp.segments[0].sink_key_dtype, KEY_DTYPE_I64)
    assert_equal(lp.segments[1].sink_kind, SINK_AGG)
    _expect_concat_of(lp, 2, 0, 1)
    assert_equal(lp.segments[2].sink_kind, SINK_COLLECT)


def test_a_breaker_with_an_operator_after_it_ends_in_a_collect() raises:
    # The first branch fuses a projection onto its aggregate's output, so the
    # branch is that pipeline, ended in a collect that reads segment 0.
    var a = _count_by(_scan("a.parquet"), "k")
    var schema = a.output_schema.copy()
    var keep = ExprArray()
    keep.append(Expr.col_ref("k"))
    keep.append(Expr.col_ref("n"))
    var projected = LogicalPlan.project(keep^, a^)
    var b = _count_by(_scan("b.parquet"), "k")
    var lp = _lowered(_union_as(projected^, b^, schema), _inputs(2))
    assert_equal(len(lp.segments), 4)
    assert_equal(lp.segments[0].sink_kind, SINK_AGG)
    assert_equal(lp.segments[1].source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(lp.segments[1].source_spec.dep_seg_ids[0], 0)
    assert_equal(len(lp.segments[1].ops), 1)
    assert_equal(lp.segments[1].sink_kind, SINK_COLLECT)
    assert_equal(lp.segments[2].sink_kind, SINK_AGG)
    _expect_concat_of(lp, 3, 1, 2)


def test_a_union_nested_in_a_branch_is_its_own_concatenation() raises:
    var inner = _union2(_scan("a.parquet"), _scan("b.parquet"))
    var plan = _union2(inner^, _scan("c.parquet"))
    var lp = _lowered(plan, _inputs(3))
    assert_equal(len(lp.segments), 5)
    _expect_concat_of(lp, 2, 0, 1)
    assert_equal(lp.segments[2].sink_kind, SINK_COLLECT)
    assert_equal(lp.segments[3].source_spec.parquet_path, "c.parquet")
    _expect_concat_of(lp, 4, 2, 3)
    assert_equal(lp.result_seg_id, 4)


def test_a_branch_may_differ_from_the_union_only_in_nullability() raises:
    # The concatenation merges validity, so a nullable branch under a union
    # that is not nullable (or the other way) lowers.
    var plan = _union_as(
        _scan("a.parquet"),
        _scan_of("b.parquet", _schema("k", True)),
        _schema("k", True),
    )
    assert_equal(_message(plan, _inputs(2)), "")


# =============================================================================
# Refusals
# =============================================================================


def test_a_branch_of_another_layout_is_refused_before_it_is_cut() raises:
    # Another column count.
    var narrow = SchemaBuilder()
    narrow.add_field(Field("k", ArrowType.INT64, False))
    var plan = _union2(_scan("a.parquet"), _scan_of("b.parquet", narrow.build()))
    _refused_with(
        _message(plan, _inputs(2)),
        LOWERING_UNCUTTABLE_NODE,
        "branch 2 has 1 columns and the union 2",
    )
    assert_true(plan_tag_name(PLAN_UNION) in _message(plan, _inputs(2)))
    # Another name.
    plan = _union2(_scan("a.parquet"), _scan_of("b.parquet", _schema("x")))
    var msg = _message(plan, _inputs(2))
    _refused_with(msg, LOWERING_UNCUTTABLE_NODE, "branch 2 column 1 is `x`")
    assert_true("the union's is `k`" in msg, msg)
    # Another type.
    var wide = SchemaBuilder()
    wide.add_field(Field("k", ArrowType.INT32, False))
    wide.add_field(Field("s", ArrowType.STRING, False))
    plan = _union2(_scan_of("a.parquet", wide.build()), _scan("b.parquet"))
    _refused_with(
        _message(plan, _inputs(2)), LOWERING_UNCUTTABLE_NODE, "branch 1 column 1 is `k`"
    )


def test_a_branch_of_another_decimal_scale_or_timezone_is_refused() raises:
    var d2b = SchemaBuilder()
    d2b.add_field(Field.decimal128("p", 12, 2, False))
    var d2 = d2b.build()
    var d4b = SchemaBuilder()
    d4b.add_field(Field.decimal128("p", 12, 4, False))
    var d4 = d4b.build()
    var plan = _union_as(_scan_of("a.parquet", d2), _scan_of("b.parquet", d4), d2)
    var msg = _message(plan, _inputs(2))
    _refused_with(msg, LOWERING_UNCUTTABLE_NODE, "branch 2 column 1 is `p`")
    assert_true("(12, 4)" in msg and "(12, 2)" in msg, msg)

    var utcb = SchemaBuilder()
    utcb.add_field(Field.timestamp("t", ArrowType.TIMESTAMP_US, "UTC", False))
    var utc = utcb.build()
    var naiveb = SchemaBuilder()
    naiveb.add_field(Field("t", ArrowType.TIMESTAMP_US, False))
    var naive = naiveb.build()
    plan = _union_as(_scan_of("a.parquet", utc), _scan_of("b.parquet", naive), utc)
    msg = _message(plan, _inputs(2))
    _refused_with(msg, LOWERING_UNCUTTABLE_NODE, "branch 2 column 1 is `t`")
    assert_true("tz=UTC" in msg, msg)
    # The same two decimals at one scale lower.
    plan = _union_as(_scan_of("a.parquet", d2), _scan_of("b.parquet", d2), d2)
    assert_equal(_message(plan, _inputs(2)), "")


def test_a_union_with_no_branch_is_refused() raises:
    var plan = LogicalPlan.union(List[OwnedPointer[LogicalPlan]](), _schema())
    _refused_with(
        _message(plan, _inputs(0)), LOWERING_UNCUTTABLE_NODE, "a union with no branch"
    )


def test_a_refused_node_in_a_branch_refuses_the_whole_union() raises:
    var keys = List[String]()
    keys.append("k")
    var join = LogicalPlan.join(
        _scan("a.parquet"), _scan("b.parquet"), keys.copy(), keys.copy(), UInt8(9)
    )
    var schema = join.output_schema.copy()
    var plan = _union_as(join^, _scan_of("c.parquet", schema), schema)
    _refused_with(
        _message(plan, _inputs(3)), LOWERING_JOIN_UNSERVED, "a type 9 join"
    )


def test_inputs_must_hold_one_entry_per_scan_of_every_branch() raises:
    var plan = _union2(_scan("a.parquet"), _scan("b.parquet"))
    # Too few: the second branch's scan finds no entry.
    _refused_with(
        _message(plan, _inputs(1)),
        LOWERING_INPUTS_SCAN_COUNT,
        "the plan has more than 1 scans",
    )
    # Too many: counted after every branch is cut.
    _refused_with(
        _message(plan, _inputs(3)),
        LOWERING_INPUTS_SCAN_COUNT,
        "the plan has 2 scans and the inputs hold 3",
    )
    assert_equal(_message(plan, _inputs(2)), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

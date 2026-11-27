# =============================================================================
# test_lower_partition_topn: partition top-n nodes lowered, and the rendered
# physical plan asserted
# =============================================================================
#
# Each test lowers a PLAN_PARTITION_TOPN node (the optimizer's fusion of
# `WHERE rn <= K` over a ROW_NUMBER or RANK window) under the constant
# reference host profile and checks what the plan means: the child's pipeline
# ends in a SINK_PARTITION_TOPN segment whose param row is the node's keys,
# count and function, and what stands above reads that segment over an E3
# edge. Morsel sizes are expected from the sizing policy applied to the schema
# that flows INTO the segment's sink.
#
#   test_a_scan_under_a_partition_top_n_is_one_segment_that_is_the_result
#                       one segment, its param row rendered, the sink data the
#                       node's keys, k, ROW_NUMBER and the child's schema.
#   test_a_named_rank_column_is_appended_and_read_by_the_projection_above
#                       the sink's schema is the child's plus a non-NULL INT64
#                       column of that name, and a projection above reads it
#                       from the partition top-n segment.
#   test_a_rank_node_keeps_its_function_and_heap_capacity
#                       RANK and over_fetch_k reach the sink data unchanged.
#   test_two_sort_keys_render_each_direction
#                       the param line lists every sort key with its
#                       direction.
#   test_a_limit_above_a_keyed_partition_top_n_is_refused_and_one_with_no_key_is_cut
#                       the reader of a keyed node is a sorted stream, as a
#                       keyed window's is.
#   test_a_partition_top_n_the_sink_does_not_serve_is_refused_by_name
#                       a negative count, a descending list of another length,
#                       DENSE_RANK, a key that is not a column, a key of a type
#                       the sort does not order.
#   test_a_partition_top_n_read_twice_is_cut_once
#                       in a shared subplan it is one segment both branches of
#                       a union read.
#   test_a_reference_below_a_partition_top_n_is_found_and_read_over_e3
#                       a shared subplan referenced under the node is cut once
#                       and the node's segment reads it.
#   test_a_left_child_that_is_a_partition_top_n_keeps_its_scans_facts
#                       beside a reference on the right, each scan keeps its
#                       own statistics.
#   test_a_shared_subtree_holding_a_partition_top_n_over_a_reference_is_found
#                       a canonical subtree with the node over a reference is
#                       found by its unfolded hash.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import HostProfile, reference_host_profile
from host_profile.morsel_sizing_policy import MorselSizingPolicy
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweredPlan,
    LoweringInputs,
    LOWERING_UNCUTTABLE_NODE,
    LOWERING_WINDOW_UNSERVED,
)
from lowering.render import render_lowered_plan
from plan_expr.expr import Expr
from plan_expr.partition_expr import PF_DENSE_RANK, PF_RANK, PF_ROW_NUMBER
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_RIGHT,
)
from physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    PHYSICAL_PLAN_IR_VERSION,
    SINK_COLLECT,
    SINK_PARTITION_TOPN,
    SOURCE_CONCAT,
    SOURCE_PARQUET as SEG_SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
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
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, True))
    sb.add_field(Field("h", ArrowType.INT16, False))
    return sb.build()


def _scan(path: String = "t.parquet") -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema())


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows, List[String](), List[ColumnStats](), STATS_SOURCE_PARQUET_METADATA
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


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, _host(), inputs)


def _message(plan: LogicalPlan, inputs: LoweringInputs) raises -> String:
    """The refusal text, or an empty string when the plan lowers."""
    try:
        _ = _lowered(plan, inputs)
    except e:
        return String(e)
    return String("")


def _refused_with(message: String, token: String, why: String) raises:
    assert_true(message.startswith(token + ": "), "no token: " + message)
    assert_true(why in message, "does not say " + why + ": " + message)


def _top(
    var child: LogicalPlan,
    k: Int = 2,
    partition: String = "g",
    var rank_col: Optional[String] = None,
    func: UInt8 = PF_ROW_NUMBER,
    over_fetch_k: Int = -1,
) -> LogicalPlan:
    """The rows of `child` whose ROW_NUMBER (or `func`) over k DESC within
    `partition` (none when empty) is at most `k`."""
    return LogicalPlan.partition_topn(
        _names(partition), _names("k"), _flags(True), k, child^,
        func, over_fetch_k, rank_col^,
    )


def _ref_to(canonical: LogicalPlan) -> LogicalPlan:
    """The reference `plan_cse` leaves for a later occurrence of `canonical`."""
    return LogicalPlan.cse_ref(
        canonical.structural_hash(), canonical.output_schema.copy()
    )


def _union(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(a^))
    children.append(OwnedPointer(b^))
    return LogicalPlan.union(children^, schema^)


def _inner_join(var left: LogicalPlan, var right: LogicalPlan) -> LogicalPlan:
    """left JOIN right ON k = k, the right child building."""
    return LogicalPlan.join(
        left^, right^, _names("k"), _names("k"), JOIN_INNER, JOIN_ALGO_AUTO,
        None, JOIN_BUILD_SIDE_RIGHT,
    )


def _expect_reads(lp: LoweredPlan, seg: Int, producer: Int) raises:
    """Segment `seg` reads the output of `producer` over one E3 edge."""
    ref s = lp.segments[seg]
    assert_equal(s.source_kind, SOURCE_SINK_OUTPUT)
    assert_equal(len(s.source_spec.dep_seg_ids), 1)
    assert_equal(s.source_spec.dep_seg_ids[0], producer)
    assert_equal(len(s.deps), 1)
    assert_equal(s.deps[0], producer)
    assert_equal(s.edge_tags[0], EDGE_E3_PUBLISH_WAIT)


def _expect_concat(lp: LoweredPlan, seg: Int, a: Int, b: Int) raises:
    """Segment `seg` concatenates `a` then `b`, one E3 edge each."""
    ref s = lp.segments[seg]
    assert_equal(s.source_kind, SOURCE_CONCAT)
    assert_equal(len(s.source_spec.dep_seg_ids), 2)
    assert_equal(s.source_spec.dep_seg_ids[0], a)
    assert_equal(s.source_spec.dep_seg_ids[1], b)
    assert_equal(len(s.deps), 2)
    assert_equal(s.edge_tags[0], EDGE_E3_PUBLISH_WAIT)
    assert_equal(s.edge_tags[1], EDGE_E3_PUBLISH_WAIT)


def _schema_text(schema: Schema) -> String:
    var out = String("")
    for i in range(schema.num_columns()):
        out += (
            schema.field_name(i)
            + ":"
            + String(schema.field_arrow_type(i))
            + (" null" if schema.field_nullable(i) else "")
            + ";"
        )
    return out^


comptime _PTOPN = "(SINK_PARTITION_TOPN, NONE, COLUMNAR)"


# =============================================================================
# Cut shapes
# =============================================================================


def test_a_scan_under_a_partition_top_n_is_one_segment_that_is_the_result() raises:
    var scan = _scan()
    var flow = scan.output_schema.copy()
    var lp = _lowered(_top(scan^), _inputs(500))
    var rows = MorselSizingPolicy.for_host(_host()).default_morsel_rows(flow)
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_PARQUET path=t.parquet total=True\n"
    expected += "  sink: " + String(_PTOPN) + " param=0 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += (
        "  estimates: morsel_rows=" + String(rows) + " card_rows=500 mem_bytes=0\n"
    )
    expected += "params: agg=0 sort=0 topn=0 window=0 batches=0\n"
    expected += "  partition_topn 0: partition=[g] order=[k desc] fn=ROW_NUMBER k=2\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(lp), expected)
    assert_equal(len(lp.params.partition_topn), 1)
    ref d = lp.params.partition_topn[0]
    assert_equal(d.k, 2)
    assert_equal(d.func, PF_ROW_NUMBER)
    assert_equal(d.over_fetch_k, 2)
    assert_false(Bool(d.output_rank_col_name))
    assert_equal(_schema_text(d.output_schema), _schema_text(_schema()))
    assert_equal(len(d.descending), 1)
    assert_true(d.descending[0])


def test_a_named_rank_column_is_appended_and_read_by_the_projection_above() raises:
    var top = _top(_scan(), 3, rank_col=Optional[String]("rn"))
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    exprs.append(Expr.col_ref("rn"))
    var plan = LogicalPlan.project(exprs^, top^)
    var lp = _lowered(plan, _inputs(500))
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].sink_kind, SINK_PARTITION_TOPN)
    assert_equal(lp.segments[1].sink_kind, SINK_COLLECT)
    _expect_reads(lp, 1, 0)
    assert_equal(lp.result_seg_id, 1)
    ref d = lp.params.partition_topn[0]
    assert_equal(d.output_rank_col_name.value(), "rn")
    assert_equal(
        _schema_text(d.output_schema),
        _schema_text(_schema()) + "rn:" + String(ArrowType.INT64) + ";",
    )
    var text = render_lowered_plan(lp)
    assert_true(
        "  partition_topn 0: partition=[g] order=[k desc] fn=ROW_NUMBER k=3"
        " rank_col=rn\n" in text,
        text,
    )


def test_a_rank_node_keeps_its_function_and_heap_capacity() raises:
    var lp = _lowered(
        _top(_scan(), 2, func=PF_RANK, over_fetch_k=18), _inputs(500)
    )
    ref d = lp.params.partition_topn[0]
    assert_equal(d.func, PF_RANK)
    assert_equal(d.k, 2)
    assert_equal(d.over_fetch_k, 18)
    var text = render_lowered_plan(lp)
    assert_true("fn=RANK k=2\n" in text, text)


def test_two_sort_keys_render_each_direction() raises:
    var two = LogicalPlan.partition_topn(
        _names("g"), _names("k", "v"), _flags(False, True, 2), 4, _scan()
    )
    var text = render_lowered_plan(_lowered(two, _inputs(500)))
    assert_true(
        "  partition_topn 0: partition=[g] order=[k asc, v desc]"
        " fn=ROW_NUMBER k=4\n" in text,
        text,
    )


def test_a_limit_above_a_keyed_partition_top_n_is_refused_and_one_with_no_key_is_cut() raises:
    _refused_with(
        _message(LogicalPlan.limit(5, _top(_scan())), _inputs(500)),
        LOWERING_UNCUTTABLE_NODE,
        "a limit over a sorted stream",
    )
    # No partition and no sort key: the rows come out in no order at all.
    var bare = LogicalPlan.partition_topn(
        List[String](), List[String](), List[Bool](), 4, _scan()
    )
    var lp = _lowered(LogicalPlan.limit(5, bare^), _inputs(500))
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].sink_kind, SINK_PARTITION_TOPN)
    _expect_reads(lp, 1, 0)


def test_a_partition_top_n_the_sink_does_not_serve_is_refused_by_name() raises:
    _refused_with(
        _message(_top(_scan(), -1), _inputs(500)),
        LOWERING_UNCUTTABLE_NODE,
        "a partition top-n with a negative count",
    )
    var mismatched = LogicalPlan.partition_topn(
        _names("g"), _names("k"), _flags(True, False, 2), 2, _scan()
    )
    _refused_with(
        _message(mismatched, _inputs(500)),
        LOWERING_WINDOW_UNSERVED,
        "the partition top-n has 1 sort keys and 2 descending flags",
    )
    _refused_with(
        _message(_top(_scan(), 2, func=PF_DENSE_RANK), _inputs(500)),
        LOWERING_WINDOW_UNSERVED,
        "the partition top-n numbers its rows with DENSE_RANK; only"
        " ROW_NUMBER and RANK are served",
    )
    _refused_with(
        _message(_top(_scan(), 2, partition="nope"), _inputs(500)),
        LOWERING_WINDOW_UNSERVED,
        "the PARTITION BY key 'nope' is not a column of the input",
    )
    var short_key = LogicalPlan.partition_topn(
        _names("g"), _names("h"), _flags(False), 2, _scan()
    )
    _refused_with(
        _message(short_key, _inputs(500)),
        LOWERING_WINDOW_UNSERVED,
        "the ORDER BY key 'h' has type",
    )


# =============================================================================
# In a shared subplan
# =============================================================================


def test_a_partition_top_n_read_twice_is_cut_once() raises:
    var canonical = _top(_scan())
    var plan = _union(canonical.copy(), _ref_to(canonical))
    var lp = _lowered(plan, _inputs(500))
    assert_equal(len(lp.segments), 2)
    assert_equal(lp.segments[0].sink_kind, SINK_PARTITION_TOPN)
    _expect_concat(lp, 1, 0, 0)
    assert_equal(len(lp.params.partition_topn), 1)


def test_a_reference_below_a_partition_top_n_is_found_and_read_over_e3() raises:
    # A top-n of the scan, then (that top-n) UNION ALL (a partition top-n over
    # a reference to it).
    var canonical = LogicalPlan.topn(_names("k"), _flags(False), 10, _scan())
    var plan = _union(canonical.copy(), _top(_ref_to(canonical)))
    var lp = _lowered(plan, _inputs(500))
    # 0: the top-n. 1: the partition top-n over 0's output. 2: 0 and 1.
    assert_equal(len(lp.segments), 3)
    assert_equal(lp.segments[1].sink_kind, SINK_PARTITION_TOPN)
    _expect_reads(lp, 1, 0)
    _expect_concat(lp, 2, 0, 1)


def test_a_left_child_that_is_a_partition_top_n_keeps_its_scans_facts() raises:
    # Left: a partition top-n over l (scan 0). Right: X UNION ALL ref(X)
    # (scan 1). The right child is walked first, from scan 1, so the
    # partition top-n's scan is counted when the left child's are skipped.
    var x = _scan("x.parquet")
    var plan = _inner_join(
        _top(_scan("l.parquet")), _union(x.copy(), _ref_to(x))
    )
    var lp = _lowered(plan, _inputs(10, 99))
    var seen = 0
    for i in range(len(lp.segments)):
        ref seg = lp.segments[i]
        if seg.source_kind != SEG_SOURCE_PARQUET:
            continue
        seen += 1
        if seg.source_spec.parquet_path == "l.parquet":
            assert_equal(seg.card_estimate_rows, 10)
            assert_equal(seg.sink_kind, SINK_PARTITION_TOPN)
        else:
            assert_equal(seg.card_estimate_rows, 99)
    assert_true(seen >= 2, "both scans are read")


def test_a_shared_subtree_holding_a_partition_top_n_over_a_reference_is_found() raises:
    # The producer saw inner = top-n of the scan and P = a partition top-n
    # over inner UNION ALL inner, and the plan P UNION ALL P. It keeps the
    # first P, folds the second inner inside it and the second P, each
    # reference carrying the hash of the subtree as it stood before folding.
    var inner = LogicalPlan.topn(_names("k"), _flags(False), 10, _scan())
    var seen = _top(_union(inner.copy(), inner.copy()))
    var kept = _top(_union(inner.copy(), _ref_to(inner)))
    var plan = _union(kept^, _ref_to(seen))
    var lp = _lowered(plan, _inputs(500))
    # 0: the top-n. 1: its two reads, concatenated into the partition top-n.
    # 2: the partition top-n's output twice.
    assert_equal(len(lp.segments), 3)
    _expect_concat(lp, 1, 0, 0)
    assert_equal(lp.segments[1].sink_kind, SINK_PARTITION_TOPN)
    _expect_concat(lp, 2, 1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

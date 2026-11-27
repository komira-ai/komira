# =============================================================================
# test_lower_unnest: the physical plan of an Unnest
# =============================================================================
#
# Tests, and the behaviour each asserts:
#   test_an_unnest_is_one_unnest_op_on_its_scan_s_pipeline
#       a PLAN_UNNEST over a scan renders as one segment: the scan's source,
#       an OP_UNNEST naming the list column and its keep_empty flag, the
#       collect sink, and no row estimate past the unnest (the scan alone
#       keeps its estimate).
#   test_keep_empty_reaches_the_operator
#       the flag of the node is the flag of the operator, both ways.
#   test_a_projection_above_an_unnest_is_fused_after_it
#       Project(Unnest(scan)), the shape SQL binds, is one segment whose
#       OP_UNNEST comes before its OP_PROJECT.
#   test_an_unnest_ends_the_sort_order
#       a limit above an unnest above a sort lowers in two segments: the
#       sort's, and one that unnests the sorted rows and then limits them (the
#       unnest's rows are not the sort's order, so the limit is no range).
#   test_an_unnest_over_a_union_counts_both_scans
#       an Unnest over a UNION ALL of two scans lowers with two scans in the
#       inputs, each scan its own segment.
#   test_a_shared_unnest_is_cut_once
#       a union of an unnest and a reference to it holds one OP_UNNEST, in a
#       segment both branches read.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import LoweredPlan, LoweringInputs
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    OP_LIMIT,
    OP_PROJECT,
    OP_UNNEST,
)
from plan_expr.expr import Expr
from plan_ir.logical_plan import ExprArray, LogicalPlan, SOURCE_PARQUET
from plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)


def _t() -> Schema:
    """The scanned table: id INT64, tags LIST<STRING>."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field.list_of_string("tags", True))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _t())


def _unnest(var child: LogicalPlan, keep_empty: Bool = False) raises -> LogicalPlan:
    return LogicalPlan.unnest(child^, String("tags"), keep_empty)


def _inputs(scans: Int = 1) -> LoweringInputs:
    var inputs = LoweringInputs()
    for _ in range(scans):
        inputs.add_scan(
            Optional[TableStats](
                TableStats(
                    100,
                    List[String](),
                    List[ColumnStats](),
                    STATS_SOURCE_PARQUET_METADATA,
                )
            )
        )
    return inputs^


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, reference_host_profile("test-build"), inputs)


def _ops_of(plan: LoweredPlan, seg: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for k in range(len(plan.segments[seg].ops)):
        out.append(plan.segments[seg].ops[k].tag)
    return out^


def _union_of(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


def test_an_unnest_is_one_unnest_op_on_its_scan_s_pipeline() raises:
    var plan = _lowered(_unnest(_scan()), _inputs())
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_PARQUET path=t.parquet total=True\n"
    expected += "  op 0: UNNEST tags keep_empty=false\n"
    expected += "  sink: (SINK_COLLECT, NONE, COLUMNAR) param=-1 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += (
        "  estimates: morsel_rows=" + String(plan.segments[0].morsel_rows)
        + " card_rows=0 mem_bytes=0\n"
    )
    expected += "params: agg=0 sort=0 topn=0 window=0 batches=0\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(plan), expected)
    assert_equal(plan.segments[0].ops[0].unnest_column, "tags")

    var plain = _lowered(_scan(), _inputs())
    assert_equal(plain.segments[0].card_estimate_rows, 100)


def test_keep_empty_reaches_the_operator() raises:
    var dropped = _lowered(_unnest(_scan(), False), _inputs())
    var kept = _lowered(_unnest(_scan(), True), _inputs())
    assert_true(not dropped.segments[0].ops[0].unnest_keep_empty)
    assert_true(kept.segments[0].ops[0].unnest_keep_empty)
    assert_true(
        "UNNEST tags keep_empty=true" in render_lowered_plan(kept)
    )


def test_a_projection_above_an_unnest_is_fused_after_it() raises:
    var pe = ExprArray()
    pe.append(Expr.col_ref("id"))
    pe.append(Expr.alias(Expr.col_ref("tags"), String("tag")))
    var plan = _lowered(LogicalPlan.project(pe^, _unnest(_scan())), _inputs())
    assert_equal(len(plan.segments), 1)
    var ops = _ops_of(plan, 0)
    assert_equal(len(ops), 2)
    assert_equal(Int(ops[0]), Int(OP_UNNEST))
    assert_equal(Int(ops[1]), Int(OP_PROJECT))


def test_an_unnest_ends_the_sort_order() raises:
    var asc = List[Bool]()
    asc.append(False)
    var keys = List[String]()
    keys.append("id")
    var sorted = LogicalPlan.sort(keys^, asc^, _scan())
    var plan = _lowered(LogicalPlan.limit(5, _unnest(sorted^)), _inputs())
    assert_equal(len(plan.segments), 2, render_lowered_plan(plan))
    var ops = _ops_of(plan, 1)
    assert_equal(len(ops), 2)
    assert_equal(Int(ops[0]), Int(OP_UNNEST))
    assert_equal(Int(ops[1]), Int(OP_LIMIT))


def test_an_unnest_over_a_union_counts_both_scans() raises:
    var plan = _lowered(_unnest(_union_of(_scan(), _scan())), _inputs(2))
    var unnests = 0
    for i in range(len(plan.segments)):
        for k in range(len(plan.segments[i].ops)):
            if plan.segments[i].ops[k].tag == OP_UNNEST:
                unnests += 1
    assert_equal(unnests, 1, render_lowered_plan(plan))
    assert_true(len(plan.segments) >= 2)


def test_a_shared_unnest_is_cut_once() raises:
    var canonical = _unnest(_scan())
    var reference = LogicalPlan.cse_ref(
        canonical.structural_hash(), canonical.output_schema.copy()
    )
    var plan = _lowered(_union_of(canonical^, reference^), _inputs())
    var unnests = 0
    var unnest_seg = -1
    for i in range(len(plan.segments)):
        for k in range(len(plan.segments[i].ops)):
            if plan.segments[i].ops[k].tag == OP_UNNEST:
                unnests += 1
                unnest_seg = i
    assert_equal(unnests, 1)
    var readers = 0
    for i in range(len(plan.segments)):
        for d in range(len(plan.segments[i].deps)):
            if plan.segments[i].deps[d] == unnest_seg:
                readers += 1
    assert_true(readers >= 2, render_lowered_plan(plan))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

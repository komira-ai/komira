# =============================================================================
# test_lower_udf_nodes: the physical plan of user-function plans
# =============================================================================
#
# Tests, and the behaviour each asserts:
#   test_an_ungrouped_frame_is_one_udf_frame_op_over_its_read_set
#       a PLAN_MAP_BATCHES over a scan renders as one segment: the scan's
#       source, an OP_UDF_FRAME that reads exactly the read set and writes the
#       node's columns, the collect sink, no row estimate past the frame, and
#       the UdfRef line; the same scan without the frame keeps its estimate.
#   test_a_frame_with_an_empty_read_set_reads_no_column
#       a read set that is set and empty lowers, and the frame receives no
#       column (the render prints no reads).
#   test_a_step_is_a_udf_step_source_with_its_literals_and_no_scan
#       a PLAN_STEP renders as a SOURCE_UDF_STEP segment with its literals and
#       output names; it takes no ScanFacts, so a plan of one step lowers with
#       no scan in the inputs and is refused with one.
#   test_a_projection_column_that_is_a_call_is_a_udf_apply_before_the_project
#       a SCALAR call and a ROW call, each a whole projection column (one under
#       an alias), become OP_UDF_APPLY operators in column order, each writing
#       __udf_apply:<position>, then an OP_PROJECT reading those columns in the
#       calls' places; the ROW call carries its read set; the row estimate of
#       the scan is kept.
#   test_the_udf_list_is_carried_whole_and_in_order
#       ParamTable.udfs is the inputs' list, every entry in order, an unused
#       one included; a plan with no UdfRef renders no udf line.
#   test_lowering_inputs_copy_their_udf_list_deeply
#       a copy of LoweringInputs holds an equal UdfRef list, and changing the
#       copy leaves the original as it was.
#   test_a_frame_ends_dictionary_keys_and_the_sort_order
#       a string group key read past a frame is COLUMNAR although the scan's
#       footers name the column dictionary encoded, and a limit above a frame
#       above a sort lowers (the frame's rows are not the sort's order).
#   test_a_step_beside_a_scan_in_a_union_keeps_the_scan_s_facts
#       a UNION ALL of a scan and a step: the scan's segment keeps its row
#       estimate, the step's segment is SOURCE_UDF_STEP, and the inputs hold
#       one scan.
#   test_a_shared_frame_is_cut_once
#       a union of a frame and a reference to it holds one OP_UDF_FRAME, in a
#       segment both branches read.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import LoweredPlan, LoweringInputs
from lowering.render import render_lowered_plan
from physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    OP_PROJECT,
    OP_UDF_APPLY,
    OP_UDF_FRAME,
    SINK_AGG,
    SINK_ORIENT_COLUMNAR,
    SOURCE_PARQUET as SEG_SOURCE_PARQUET,
    SOURCE_UDF_STEP,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr
from plan_expr.scalar_value import ScalarValue
from plan_expr.udf_data import UDF_NULL_MANUAL, UDF_STABILITY_STABLE, UDF_STABILITY_VOLATILE
from plan_expr.udf_type import UdfType
from plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
)
from plan_ir.udf_ref import (
    CODE_FORM_VALUE,
    UdfCode,
    UdfRef,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    UDF_REF_KIND_ROW,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_STEP,
)
from plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)


# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------


def _schema3(
    a: String, ta: ArrowType, b: String = "", tb: ArrowType = ArrowType.INT64,
    c: String = "", tc: ArrowType = ArrowType.INT64,
) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ta, True))
    if b != "":
        sb.add_field(Field(b, tb, True))
    if c != "":
        sb.add_field(Field(c, tc, True))
    return sb.build()


def _t() -> Schema:
    """The scanned table: k INT64, v FLOAT64, s STRING."""
    return _schema3("k", ArrowType.INT64, "v", ArrowType.FLOAT64, "s", ArrowType.STRING)


def _scan() -> LogicalPlan:
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _t())


def _names(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    if c != "":
        out.append(c)
    return out^


def _leaf(name: String, t: ArrowType) -> UdfType:
    return UdfType(name, t, Field(name, t, True).dtype, True)


def _struct(schema: Schema) -> UdfType:
    var kids = List[UdfType]()
    for i in range(schema.num_columns()):
        kids.append(_leaf(schema.field_name(i), schema.field_arrow_type(i)))
    return UdfType(
        "out", ArrowType.STRUCT, Field("out", ArrowType.STRUCT, True).dtype, True, kids^
    )


def _ref(
    kind: UInt8,
    entry: String,
    var args: List[UdfType],
    var ret: UdfType,
    var read_set: Optional[List[String]] = None,
    stability: UInt8 = UDF_STABILITY_STABLE,
) -> UdfRef:
    return UdfRef(
        kind,
        UdfCode("komira/python", CODE_FORM_VALUE, entry),
        args^,
        Optional(ret^),
        stability,
        UDF_NULL_MANUAL,
        read_set^,
    )


def _frame_ref(var reads: List[String], output: Schema) -> UdfRef:
    """A MAP_BATCHES_FRAME function reading `reads` (columns of `_t`)."""
    var t = _t()
    var args = List[UdfType]()
    for i in range(len(reads)):
        for c in range(t.num_columns()):
            if t.field_name(c) == reads[i]:
                args.append(_leaf(reads[i], t.field_arrow_type(c)))
    return _ref(
        UDF_REF_KIND_MAP_BATCHES_FRAME, "m:frame", args^, _struct(output),
        Optional(reads^),
    )


def _step_ref(literals: Int, output: Schema) -> UdfRef:
    var args = List[UdfType]()
    for i in range(literals):
        args.append(_leaf("x" + String(i), ArrowType.INT64))
    return _ref(
        UDF_REF_KIND_STEP, "m:step", args^, _struct(output),
        stability=UDF_STABILITY_VOLATILE,
    )


def _frame(var child: LogicalPlan, index: Int, output: Schema) raises -> LogicalPlan:
    return LogicalPlan.map_batches(child^, index, List[Expr](), output.copy())


def _stats(rows: Int) -> TableStats:
    return TableStats(
        rows, List[String](), List[ColumnStats](), STATS_SOURCE_PARQUET_METADATA
    )


def _inputs(scans: Int = 1) -> LoweringInputs:
    var inputs = LoweringInputs()
    for _ in range(scans):
        inputs.add_scan(Optional[TableStats](_stats(100)))
    return inputs^


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, reference_host_profile("test-build"), inputs)


def _segment(
    plan: LoweredPlan, seg_id: Int, source: String, ops: List[String],
    card_rows: Int,
) -> String:
    """The render of a collect segment with no dependency: the morsel size is
    the host's, read from the lowered segment."""
    var out = String("segment ") + String(seg_id) + "\n"
    out += "  source: " + source + "\n"
    for i in range(len(ops)):
        out += "  op " + String(i) + ": " + ops[i] + "\n"
    out += "  sink: (SINK_COLLECT, NONE, COLUMNAR) param=-1 state=" + String(seg_id) + "\n"
    out += "  deps: none\n"
    out += "  order: ORDER_NONE partitions=1\n"
    out += (
        "  estimates: morsel_rows=" + String(plan.segments[seg_id].morsel_rows)
        + " card_rows=" + String(card_rows) + " mem_bytes=0\n"
    )
    return out^


def _header() -> String:
    return String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"


comptime _PARAMS = "params: agg=0 sort=0 batches=0\n"
comptime _T_SOURCE = "SOURCE_PARQUET path=t.parquet total=True"


# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------


def test_an_ungrouped_frame_is_one_udf_frame_op_over_its_read_set() raises:
    var out = _schema3("k2", ArrowType.INT64, "w", ArrowType.FLOAT64)
    var inputs = _inputs()
    inputs.add_udf(_frame_ref(_names("s", "v"), out))
    var plan = _lowered(_frame(_scan(), 0, out), inputs)
    var ops = List[String]()
    ops.append("UDF_FRAME udf=0 MAP_BATCHES_FRAME reads=[s, v] out=[k2, w]")
    var expected = _header() + _segment(plan, 0, _T_SOURCE, ops, 0)
    expected += _PARAMS
    expected += "  udf 0: MAP_BATCHES_FRAME runtime=komira/python entry=m:frame\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(plan), expected)
    assert_equal(Int(plan.segments[0].ops[0].tag), Int(OP_UDF_FRAME))

    var plain = _lowered(_scan(), _inputs())
    assert_equal(plain.segments[0].card_estimate_rows, 100)


def test_a_frame_with_an_empty_read_set_reads_no_column() raises:
    var out = _schema3("n", ArrowType.INT64)
    var inputs = _inputs()
    inputs.add_udf(_frame_ref(List[String](), out))
    var plan = _lowered(_frame(_scan(), 0, out), inputs)
    var ops = List[String]()
    ops.append("UDF_FRAME udf=0 MAP_BATCHES_FRAME out=[n]")
    var expected = _header() + _segment(plan, 0, _T_SOURCE, ops, 0)
    expected += _PARAMS
    expected += "  udf 0: MAP_BATCHES_FRAME runtime=komira/python entry=m:frame\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(plan), expected)
    assert_equal(len(plan.segments[0].ops[0].udf.value().reads), 0)


def test_a_step_is_a_udf_step_source_with_its_literals_and_no_scan() raises:
    var out = _schema3("k", ArrowType.INT64, "v", ArrowType.FLOAT64)
    var inputs = _inputs(0)
    inputs.add_udf(_step_ref(2, out))
    var lits = List[ScalarValue]()
    lits.append(ScalarValue.from_int(7))
    lits.append(ScalarValue.from_int(8))
    var step = LogicalPlan.step(0, lits^, out.copy())
    var plan = _lowered(step, inputs)
    var source = (
        String("SOURCE_UDF_STEP udf=0 STEP literals=[")
        + String(ScalarValue.from_int(7)) + ", " + String(ScalarValue.from_int(8))
        + "] out=[k, v]"
    )
    var expected = _header() + _segment(plan, 0, source, List[String](), 0)
    expected += _PARAMS
    expected += "  udf 0: STEP runtime=komira/python entry=m:step\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(plan), expected)
    assert_equal(Int(plan.segments[0].source_kind), Int(SOURCE_UDF_STEP))

    var one_scan = _inputs(1)
    one_scan.add_udf(_step_ref(2, out))
    var message = String("")
    try:
        _ = _lowered(step, one_scan)
    except e:
        message = String(e)
    assert_equal(
        message,
        "LOWERING_INPUTS_SCAN_COUNT: the plan has 0 scans and the inputs hold 1",
    )


def test_a_projection_column_that_is_a_call_is_a_udf_apply_before_the_project() raises:
    var inputs = _inputs()
    var scalar_args = List[UdfType]()
    scalar_args.append(_leaf("v", ArrowType.FLOAT64))
    inputs.add_udf(_ref(UDF_REF_KIND_SCALAR, "m:double", scalar_args^, _leaf("r", ArrowType.FLOAT64)))
    var row_args = List[UdfType]()
    row_args.append(_leaf("k", ArrowType.INT64))
    row_args.append(_leaf("s", ArrowType.STRING))
    inputs.add_udf(_ref(
        UDF_REF_KIND_ROW, "m:row", row_args^, _leaf("r", ArrowType.STRING),
        Optional(_names("k", "s")),
    ))
    var call0 = List[Expr]()
    call0.append(Expr.col_ref("v"))
    var call1 = List[Expr]()
    call1.append(Expr.col_ref("k"))
    call1.append(Expr.col_ref("s"))
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("k"))
    exprs.append(Expr.alias(Expr.udf_apply(0, _leaf("r", ArrowType.FLOAT64), call0^), "y"))
    exprs.append(Expr.udf_apply(1, _leaf("r", ArrowType.STRING), call1^))
    var node = LogicalPlan.project(exprs^, _scan())
    var plan = _lowered(node, inputs)
    var k = String(Expr.col_ref("k"))
    var v = String(Expr.col_ref("v"))
    var s = String(Expr.col_ref("s"))
    var ops = List[String]()
    ops.append("UDF_APPLY udf=0 SCALAR args=[" + v + "] out=[__udf_apply:1]")
    ops.append(
        "UDF_APPLY udf=1 ROW reads=[k, s] args=[" + k + ", " + s
        + "] out=[__udf_apply:2]"
    )
    ops.append(
        "PROJECT " + node.output_schema.field_name(0) + " := " + k
        + ", y := " + String(Expr.col_ref("__udf_apply:1"))
        + ", " + node.output_schema.field_name(2) + " := "
        + String(Expr.col_ref("__udf_apply:2"))
    )
    var expected = _header() + _segment(plan, 0, _T_SOURCE, ops, 100)
    expected += _PARAMS
    expected += "  udf 0: SCALAR runtime=komira/python entry=m:double\n"
    expected += "  udf 1: ROW runtime=komira/python entry=m:row\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(plan), expected)
    assert_equal(Int(plan.segments[0].ops[0].tag), Int(OP_UDF_APPLY))
    assert_equal(Int(plan.segments[0].ops[2].tag), Int(OP_PROJECT))


def test_the_udf_list_is_carried_whole_and_in_order() raises:
    var out = _schema3("n", ArrowType.INT64)
    var inputs = _inputs()
    inputs.add_udf(_step_ref(0, out))
    inputs.add_udf(_frame_ref(_names("k"), out))
    var plan = _lowered(_frame(_scan(), 1, out), inputs)
    assert_equal(len(plan.params.udfs), 2)
    assert_equal(Int(plan.params.udfs[0].kind), Int(UDF_REF_KIND_STEP))
    assert_equal(plan.params.udfs[0].code.entry, "m:step")
    assert_equal(Int(plan.params.udfs[1].kind), Int(UDF_REF_KIND_MAP_BATCHES_FRAME))
    assert_equal(plan.segments[0].ops[0].udf.value().udf_index, 1)
    var text = render_lowered_plan(plan)
    assert_true("  udf 0: STEP runtime=komira/python entry=m:step\n  udf 1: MAP_BATCHES_FRAME" in text, text)

    var none = render_lowered_plan(_lowered(_scan(), _inputs()))
    assert_false("udf" in none, none)


def test_lowering_inputs_copy_their_udf_list_deeply() raises:
    var out = _schema3("n", ArrowType.INT64)
    var inputs = _inputs()
    inputs.add_udf(_frame_ref(_names("k"), out))
    var c = inputs.copy()
    assert_equal(len(c.scans), 1)
    assert_equal(len(c.udfs), 1)
    assert_equal(c.udfs[0].code.entry, "m:frame")
    assert_equal(c.udfs[0].read_set.value()[0], "k")
    c.udfs[0].code.entry = "changed"
    c.udfs[0].read_set.value()[0] = "v"
    c.add_udf(_step_ref(0, out))
    assert_equal(inputs.udfs[0].code.entry, "m:frame")
    assert_equal(inputs.udfs[0].read_set.value()[0], "k")
    assert_equal(len(inputs.udfs), 1)


def test_a_frame_ends_dictionary_keys_and_the_sort_order() raises:
    var out = _schema3("s", ArrowType.STRING)
    var inputs = LoweringInputs()
    inputs.add_scan(Optional[TableStats](_stats(100)), _names("s"))
    inputs.add_udf(_frame_ref(_names("s"), out))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var keys = ExprArray()
    keys.append(Expr.col_ref("s"))
    var grouped = LogicalPlan.aggregate(keys^, aggs^, _frame(_scan(), 0, out))
    var plan = _lowered(grouped, inputs)
    assert_equal(len(plan.segments), 1)
    assert_equal(Int(plan.segments[0].ops[0].tag), Int(OP_UDF_FRAME))
    assert_equal(Int(plan.segments[0].sink_kind), Int(SINK_AGG))
    assert_equal(Int(plan.segments[0].sink_orientation), Int(SINK_ORIENT_COLUMNAR))
    assert_equal(plan.segments[0].card_estimate_rows, 0)

    var sort_inputs = _inputs()
    sort_inputs.add_udf(_frame_ref(_names("s"), out))
    var asc = List[Bool]()
    asc.append(False)
    var sorted = LogicalPlan.sort(_names("k"), asc^, _scan())
    var limited = LogicalPlan.limit(5, _frame(sorted^, 0, out))
    var lowered = _lowered(limited, sort_inputs)
    assert_equal(len(lowered.segments), 2)
    assert_equal(Int(lowered.segments[1].ops[0].tag), Int(OP_UDF_FRAME))


def _union_of(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


def test_a_step_beside_a_scan_in_a_union_keeps_the_scan_s_facts() raises:
    var inputs = _inputs()
    inputs.add_udf(_step_ref(0, _t()))
    var step = LogicalPlan.step(0, List[ScalarValue](), _t())
    var plan = _lowered(_union_of(_scan(), step^), inputs)
    assert_equal(len(plan.segments), 3)
    assert_equal(Int(plan.segments[0].source_kind), Int(SEG_SOURCE_PARQUET))
    assert_equal(plan.segments[0].card_estimate_rows, 100)
    assert_equal(Int(plan.segments[1].source_kind), Int(SOURCE_UDF_STEP))
    assert_equal(plan.segments[1].card_estimate_rows, 0)
    var text = render_lowered_plan(plan)
    assert_true("  source: SOURCE_UDF_STEP udf=0 STEP out=[k, v, s]\n" in text, text)


def test_a_shared_frame_is_cut_once() raises:
    var out = _t()
    var inputs = _inputs()
    inputs.add_udf(_frame_ref(_names("k", "v"), out))
    var canonical = _frame(_scan(), 0, out)
    var reference = LogicalPlan.cse_ref(
        canonical.structural_hash(), canonical.output_schema.copy()
    )
    var plan = _lowered(_union_of(canonical^, reference^), inputs)
    var frames = 0
    var frame_seg = -1
    for i in range(len(plan.segments)):
        for k in range(len(plan.segments[i].ops)):
            if plan.segments[i].ops[k].tag == OP_UDF_FRAME:
                frames += 1
                frame_seg = i
    assert_equal(frames, 1)
    var readers = 0
    for i in range(len(plan.segments)):
        for d in range(len(plan.segments[i].deps)):
            if plan.segments[i].deps[d] == frame_seg:
                readers += 1
    assert_true(readers >= 2, render_lowered_plan(plan))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

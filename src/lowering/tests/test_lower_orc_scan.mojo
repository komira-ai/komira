# =============================================================================
# test_lower_orc_scan: a scan of one ORC file lowered
# =============================================================================
#
# The ORC scans here are built the way the SQL binder builds the leaf of
# `read_orc` (an `OrcSource` behind the `komira.orc` binding, its schema the
# file's footer). What each test proves:
#
#   * test_an_orc_scan_reads_its_projection_at_the_bound_types: the segment is
#     SOURCE_ORC; its spec names the file and the columns of the projection,
#     in the projection's order, at the bound types; no operator is added; the
#     render names the file and the columns.
#   * test_an_orc_scan_with_no_projection_reads_every_column: the spec's schema
#     is the scan's whole schema, in its order.
#   * test_a_pushed_filter_reads_the_whole_file_then_filters_and_projects: a
#     filter the scan carries is an operator over the whole schema, followed by
#     the projection as an operator.
#   * test_a_pushed_filter_with_no_projection_adds_only_the_filter: the
#     filter is the one operator, over the whole schema the spec reads.
#   * test_a_projection_of_a_column_the_schema_lacks_is_refused: with and
#     without a filter, LOWERING_UNCUTTABLE_NODE naming the column and the ORC
#     scan.
#   * test_a_scan_bound_with_no_column_is_refused: an `OrcSource.from_path`
#     leaf, whose schema was never read, is LOWERING_UNCUTTABLE_NODE.
#   * test_an_aggregation_over_an_orc_scan_reads_by_value: a string group key
#     over an ORC scan takes the COLUMNAR row, and a count(*) over no column
#     reads a spec of no column.
#   * test_an_unbounded_orc_scan_is_refused: LOWERING_SCAN_NOT_TOTAL.
#   * test_an_avro_scan_is_still_refused: the arm is ORC's only.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweredPlan,
    LoweringInputs,
    LOWERING_SCAN_NOT_TOTAL,
    LOWERING_UNCUTTABLE_NODE,
)
from lowering.render import render_lowered_plan
from lowering.sink_capability import triple_name
from physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    OP_FILTER,
    OP_PROJECT,
    SINK_AGG,
    SINK_COLLECT,
    SOURCE_ORC,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr, BIN_GT
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
)
from plan_ir.plan_decisions import SCAN_UNBOUNDED
from scan_source.avro_source import AvroSource
from scan_source.orc_source import OrcSource
from scan_source.source_variant import SourceVariant


def _schema() -> Schema:
    """The schema the binder reads from a file whose footer lists
    id, k, f, s in this order, nullable."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("k", ArrowType.STRING, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _names(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _orc_scan(
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) raises -> LogicalPlan:
    var schema = _schema()
    return LogicalPlan.scan_from_source(
        SourceVariant(OrcSource(String("rows.orc"), schema.copy(), List[Int]())),
        schema^,
        projection^,
        filter^,
    )


def _f_gt(v: Float64) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("f"), Expr.literal(ScalarValue.from_float(v))
    )


def _inputs() -> LoweringInputs:
    var inputs = LoweringInputs()
    inputs.add_scan()
    return inputs^


def _lowered(plan: LogicalPlan) raises -> LoweredPlan:
    return lower(plan, reference_host_profile("test-build"), _inputs())


def _message(plan: LogicalPlan) raises -> String:
    """The refusal text, or an empty string when the plan lowers."""
    try:
        _ = _lowered(plan)
    except e:
        return String(e)
    return String("")


def _columns(schema: Schema) -> String:
    var out = String()
    for i in range(schema.num_columns()):
        if i > 0:
            out += ","
        out += schema.field_name(i) + ":" + String(schema.field_arrow_type(i))
    return out^


def test_an_orc_scan_reads_its_projection_at_the_bound_types() raises:
    var lp = _lowered(_orc_scan(Optional(_names("s", "id"))))
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_ORC)
    assert_equal(seg.source_spec.orc_path, "rows.orc")
    assert_equal(_columns(seg.source_spec.orc_schema), "s:string,id:int64")
    assert_equal(len(seg.ops), 0)
    assert_equal(seg.sink_kind, SINK_COLLECT)
    assert_true(seg.morsel_rows > 0)
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_ORC path=rows.orc columns=[s:string, id:int64]\n"
    expected += "  sink: (SINK_COLLECT, NONE, COLUMNAR) param=-1 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(seg.morsel_rows) + " card_rows=0 mem_bytes=0\n"
    expected += "params: agg=0 sort=0 topn=0 window=0 batches=0\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(lp), expected)


def test_an_orc_scan_with_no_projection_reads_every_column() raises:
    var lp = _lowered(_orc_scan())
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_ORC)
    assert_equal(
        _columns(seg.source_spec.orc_schema),
        "id:int64,k:string,f:float64,s:string",
    )
    assert_equal(len(seg.ops), 0)


def test_a_pushed_filter_reads_the_whole_file_then_filters_and_projects() raises:
    var lp = _lowered(_orc_scan(Optional(_names("s")), Optional(_f_gt(1.5))))
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_ORC)
    assert_equal(
        _columns(seg.source_spec.orc_schema),
        "id:int64,k:string,f:float64,s:string",
    )
    assert_equal(len(seg.ops), 2)
    assert_equal(seg.ops[0].tag, OP_FILTER)
    assert_equal(String(seg.ops[0].filter_predicate.value()), String(_f_gt(1.5)))
    assert_equal(seg.ops[1].tag, OP_PROJECT)
    ref names = seg.ops[1].project_names.value()
    assert_equal(len(names), 1)
    assert_equal(names[0], "s")


def test_a_pushed_filter_with_no_projection_adds_only_the_filter() raises:
    var lp = _lowered(_orc_scan(None, Optional(_f_gt(0.0))))
    ref seg = lp.segments[0]
    assert_equal(len(seg.ops), 1)
    assert_equal(seg.ops[0].tag, OP_FILTER)
    assert_equal(
        _columns(seg.source_spec.orc_schema),
        "id:int64,k:string,f:float64,s:string",
    )


def test_a_projection_of_a_column_the_schema_lacks_is_refused() raises:
    var plain = _message(_orc_scan(Optional(_names("id", "zz"))))
    assert_true(plain.startswith(String(LOWERING_UNCUTTABLE_NODE) + ": "), plain)
    assert_true("an ORC scan that projects 'zz', a column its schema does not hold" in plain, plain)
    var filtered = _message(
        _orc_scan(Optional(_names("zz")), Optional(_f_gt(0.0)))
    )
    assert_true(filtered.startswith(String(LOWERING_UNCUTTABLE_NODE) + ": "), filtered)
    assert_true("'zz'" in filtered, filtered)


def test_a_scan_bound_with_no_column_is_refused() raises:
    var message = _message(
        LogicalPlan.scan_from_source(
            SourceVariant(OrcSource.from_path(String("rows.orc"))), Schema()
        )
    )
    assert_true(message.startswith(String(LOWERING_UNCUTTABLE_NODE) + ": "), message)
    assert_true("no column" in message, message)


def test_an_aggregation_over_an_orc_scan_reads_by_value() raises:
    var keys = ExprArray()
    keys.append(Expr.col_ref("k"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var grouped = _lowered(
        LogicalPlan.aggregate(keys^, aggs^, _orc_scan(Optional(_names("k"))))
    )
    ref g = grouped.segments[grouped.result_seg_id]
    assert_equal(g.source_kind, SOURCE_ORC)
    assert_equal(g.sink_kind, SINK_AGG)
    assert_equal(
        triple_name(g.sink_kind, g.sink_key_dtype, g.sink_orientation),
        "(SINK_AGG, STRING, COLUMNAR)",
    )
    var count = AggExprArray()
    count.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var none = List[String]()
    var counted = _lowered(
        LogicalPlan.aggregate(ExprArray(), count^, _orc_scan(Optional(none^)))
    )
    ref c = counted.segments[0]
    assert_equal(c.source_kind, SOURCE_ORC)
    assert_equal(c.source_spec.orc_schema.num_columns(), 0)


def test_an_unbounded_orc_scan_is_refused() raises:
    var schema = _schema()
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(OrcSource(String("rows.orc"), schema.copy(), List[Int]())),
        schema^,
        boundedness=SCAN_UNBOUNDED,
    )
    var message = _message(scan)
    assert_true(message.startswith(String(LOWERING_SCAN_NOT_TOTAL) + ": "), message)


def test_an_avro_scan_is_still_refused() raises:
    var schema = _schema()
    var message = _message(
        LogicalPlan.scan_from_source(
            SourceVariant(AvroSource(String("t.avro"), schema.copy())), schema^
        )
    )
    assert_true(message.startswith(String(LOWERING_UNCUTTABLE_NODE) + ": "), message)
    assert_true("avro" in message, message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

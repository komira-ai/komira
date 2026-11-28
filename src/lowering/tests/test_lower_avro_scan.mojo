# =============================================================================
# test_lower_avro_scan: a scan of one Avro object container file lowered
# =============================================================================
#
# The Avro scans here are built the way the SQL binder builds the leaf of
# `read_avro('path')`: an `AvroSource` behind the `komira.avro` binding, whose
# schema is the one the file's header gives. What each test proves:
#
#   * test_an_avro_scan_reads_its_projection_at_the_bound_types: the segment is
#     SOURCE_AVRO, not refused; its spec names the file and the columns of the
#     projection, in the projection's order, at the bound types; no operator
#     is added; the render names the kind, the file and the columns.
#   * test_an_avro_scan_with_no_projection_delivers_every_column: the spec's
#     schema is the scan's whole schema, in its order.
#   * test_a_pushed_filter_reads_every_column_then_filters_and_projects: a
#     filter the scan carries is an operator over the whole schema, followed by
#     the projection as an operator, so a filter on a column the projection
#     leaves out still has its column.
#   * test_a_projection_of_a_column_the_avro_schema_lacks_is_refused: with and
#     without a filter, LOWERING_UNCUTTABLE_NODE naming the Avro scan and the
#     column.
#   * test_an_aggregation_over_an_avro_scan_reads_by_value: a string group key
#     over an Avro scan is served by the COLUMNAR sink row.
#   * test_an_unbounded_avro_scan_is_refused: LOWERING_SCAN_NOT_TOTAL, as for
#     every other source.
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
    SOURCE_AVRO,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr, BIN_GT
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import LogicalPlan, ExprArray, AggExprArray
from plan_ir.plan_decisions import SCAN_UNBOUNDED
from scan_source.avro_source import AvroSource
from scan_source.source_variant import SourceVariant


def _schema() -> Schema:
    """The schema `read_avro` binds for a file whose writer schema is the
    record {id: long, name: ["null", string], score: double, day: date}."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, True))
    sb.add_field(Field("score", ArrowType.FLOAT64, False))
    sb.add_field(Field("day", ArrowType.DATE32, False))
    return sb.build()


def _names(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _avro_scan(
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) raises -> LogicalPlan:
    var schema = _schema()
    return LogicalPlan.scan_from_source(
        SourceVariant(AvroSource(String("data.avro"), schema.copy())),
        schema^,
        projection^,
        filter^,
    )


def _id_gt(v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("id"), Expr.literal(ScalarValue.from_int64(v))
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


def test_an_avro_scan_reads_its_projection_at_the_bound_types() raises:
    var lp = _lowered(_avro_scan(Optional(_names("name", "id"))))
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_AVRO)
    assert_equal(seg.source_spec.avro_path, "data.avro")
    assert_equal(_columns(seg.source_spec.avro_schema), "name:string,id:int64")
    assert_equal(len(seg.ops), 0)
    assert_equal(seg.sink_kind, SINK_COLLECT)
    assert_true(seg.morsel_rows > 0)
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_AVRO path=data.avro columns=[name:string, id:int64]\n"
    expected += "  sink: (SINK_COLLECT, NONE, COLUMNAR) param=-1 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=" + String(seg.morsel_rows) + " card_rows=0 mem_bytes=0\n"
    expected += "params: agg=0 sort=0 topn=0 window=0 batches=0\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(lp), expected)


def test_an_avro_scan_with_no_projection_delivers_every_column() raises:
    var lp = _lowered(_avro_scan())
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_AVRO)
    assert_equal(
        _columns(seg.source_spec.avro_schema),
        "id:int64,name:string,score:float64,day:date32",
    )
    assert_equal(len(seg.ops), 0)


def test_a_pushed_filter_reads_every_column_then_filters_and_projects() raises:
    var lp = _lowered(_avro_scan(Optional(_names("name")), Optional(_id_gt(3))))
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_AVRO)
    assert_equal(
        _columns(seg.source_spec.avro_schema),
        "id:int64,name:string,score:float64,day:date32",
    )
    assert_equal(len(seg.ops), 2)
    assert_equal(seg.ops[0].tag, OP_FILTER)
    assert_equal(String(seg.ops[0].filter_predicate.value()), String(_id_gt(3)))
    assert_equal(seg.ops[1].tag, OP_PROJECT)
    ref names = seg.ops[1].project_names.value()
    assert_equal(len(names), 1)
    assert_equal(names[0], "name")


def test_a_projection_of_a_column_the_avro_schema_lacks_is_refused() raises:
    var plain = _message(_avro_scan(Optional(_names("id", "zz"))))
    assert_true(plain.startswith(String(LOWERING_UNCUTTABLE_NODE) + ": "), plain)
    assert_true(
        "an Avro scan that projects 'zz', a column its schema does not hold"
        in plain,
        plain,
    )
    var filtered = _message(
        _avro_scan(Optional(_names("zz")), Optional(_id_gt(0)))
    )
    assert_true(filtered.startswith(String(LOWERING_UNCUTTABLE_NODE) + ": "), filtered)
    assert_true("an Avro scan that projects 'zz'" in filtered, filtered)


def test_an_aggregation_over_an_avro_scan_reads_by_value() raises:
    var keys = ExprArray()
    keys.append(Expr.col_ref("name"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var grouped = _lowered(
        LogicalPlan.aggregate(keys^, aggs^, _avro_scan(Optional(_names("name"))))
    )
    ref g = grouped.segments[grouped.result_seg_id]
    assert_equal(g.source_kind, SOURCE_AVRO)
    assert_equal(g.sink_kind, SINK_AGG)
    assert_equal(
        triple_name(g.sink_kind, g.sink_key_dtype, g.sink_orientation),
        "(SINK_AGG, STRING, COLUMNAR)",
    )


def test_an_unbounded_avro_scan_is_refused() raises:
    var schema = _schema()
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(AvroSource(String("data.avro"), schema.copy())),
        schema^,
        boundedness=SCAN_UNBOUNDED,
    )
    var message = _message(scan)
    assert_true(message.startswith(String(LOWERING_SCAN_NOT_TOTAL) + ": "), message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

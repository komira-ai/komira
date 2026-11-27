# =============================================================================
# test_lower_csv: a CSV scan lowered to a SOURCE_CSV segment
# =============================================================================
#
# A `komira.csv` scan opens a SOURCE_CSV pipeline whose spec carries the
# file's path, the dialect its binding records and every column of the file
# with the type the plan bound it at; the scan's filter and projection are
# operators over that full schema. Each test builds the scan the way
# `read_csv` does (`scan_from_source` over a `CsvSource`) or the way the
# positional factory does (`LogicalPlan.scan(path, SOURCE_CSV, schema)`), lowers
# it under the reference host profile and asserts the segment. A scan with no
# header row is refused by name: the reader's column names would not be
# DuckDB's.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweredPlan,
    LoweringInputs,
    LOWERING_UNCUTTABLE_NODE,
)
from lowering.render import render_lowered_plan
from lowering.sink_capability import triple_name
from physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    OP_FILTER,
    OP_PROJECT,
    SINK_COLLECT,
    SOURCE_CSV as SEG_SOURCE_CSV,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr, BIN_GT
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_CSV,
)
from scan_source.csv_source import CsvSource
from scan_source.source_variant import SourceVariant


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("price", ArrowType.FLOAT64, True))
    sb.add_field(Field("day", ArrowType.DATE32, True))
    sb.add_field(Field("name", ArrowType.STRING, True))
    return sb.build()


def _names(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _csv_scan(
    delimiter: UInt8,
    has_header: Bool,
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
    skip: Int = 0,
) raises -> LogicalPlan:
    var cs = CsvSource(
        String("data/t.csv.gz"),
        _schema(),
        quote_style_tag=0,
        delimiter=delimiter,
        has_header=has_header,
        skip=skip,
    )
    return LogicalPlan.scan_from_source(
        SourceVariant(cs^), _schema(), projection^, filter^
    )


def _one_scan() -> LoweringInputs:
    var inputs = LoweringInputs()
    inputs.add_scan()
    return inputs^


def _lowered(plan: LogicalPlan) raises -> LoweredPlan:
    return lower(plan, reference_host_profile("test-build"), _one_scan())


def _id_gt(v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("id"), Expr.literal(ScalarValue.from_int64(v))
    )


def test_a_csv_scan_is_a_csv_source_with_its_dialect_and_bound_columns() raises:
    var lp = _lowered(_csv_scan(UInt8(ord("|")), True))
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SEG_SOURCE_CSV)
    ref s = seg.source_spec
    assert_equal(s.csv_spec.path, "data/t.csv.gz")
    assert_equal(Int(s.csv_spec.delimiter), ord("|"))
    assert_true(s.csv_spec.has_header)
    assert_equal(s.csv_spec.quote_style_tag, 0)
    assert_equal(len(s.csv_spec.column_names), 4)
    assert_equal(len(s.csv_spec.column_types), 4)
    assert_equal(s.csv_spec.column_names[0], "id")
    assert_equal(s.csv_spec.column_names[3], "name")
    assert_true(s.csv_spec.column_types[0] == ArrowType.INT64)
    assert_true(s.csv_spec.column_types[1] == ArrowType.FLOAT64)
    assert_true(s.csv_spec.column_types[2] == ArrowType.DATE32)
    assert_true(s.csv_spec.column_types[3] == ArrowType.STRING)
    # The CSV arm carries no Parquet fields and no batch handle.
    assert_equal(s.parquet_path, "")
    assert_equal(s.batch_handle_id, -1)
    assert_equal(len(seg.ops), 0)
    assert_equal(seg.sink_kind, SINK_COLLECT)
    assert_equal(seg.card_estimate_rows, 0)


def test_a_csv_scan_with_no_header_row_is_refused_by_name() raises:
    # The reader would name the columns col_0, col_1, ...; DuckDB names them
    # column0, column1, ..., so the scan is refused rather than answered.
    var msg = String("")
    try:
        _ = _lowered(_csv_scan(UInt8(ord(",")), False))
    except e:
        msg = String(e)
    assert_true(msg.startswith(String(LOWERING_UNCUTTABLE_NODE) + ": "), msg)
    assert_true("a CSV scan with header=false" in msg, msg)
    assert_true("column0, column1" in msg, msg)


def test_the_csv_segment_renders_its_path_dialect_and_columns() raises:
    var text = render_lowered_plan(_lowered(_csv_scan(UInt8(ord(";")), True)))
    var want = (
        "  source: SOURCE_CSV path=data/t.csv.gz delimiter=59 header=True"
        " quote_style=0 columns=[id:int64, price:float64, day:date32,"
        " name:string]\n"
    )
    assert_true(want in text, text)
    assert_true(
        text.startswith(
            String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
        ),
        text,
    )


def test_a_csv_scan_carries_the_lines_it_skips_into_its_spec() raises:
    var lp = _lowered(_csv_scan(UInt8(ord(",")), True, skip=2))
    assert_equal(lp.segments[0].source_spec.csv_spec.skip, 2)
    var none = _lowered(_csv_scan(UInt8(ord(",")), True))
    assert_equal(none.segments[0].source_spec.csv_spec.skip, 0)


def test_the_csv_segment_renders_its_skip_only_when_it_skips() raises:
    var skipping = render_lowered_plan(
        _lowered(_csv_scan(UInt8(ord(";")), True, skip=2))
    )
    assert_true(" quote_style=0 skip=2 columns=[" in skipping, skipping)
    var plain = render_lowered_plan(_lowered(_csv_scan(UInt8(ord(";")), True)))
    assert_false("skip" in plain, plain)


def test_a_csv_scan_with_no_header_row_is_refused_even_with_a_skip() raises:
    var msg = String("")
    try:
        _ = _lowered(_csv_scan(UInt8(ord(",")), False, skip=1))
    except e:
        msg = String(e)
    assert_true(msg.startswith(String(LOWERING_UNCUTTABLE_NODE) + ": "), msg)
    assert_true("a CSV scan with header=false" in msg, msg)
    assert_true("column0, column1" in msg, msg)


def test_a_csv_scan_projection_and_filter_are_operators_over_the_full_schema() raises:
    var scan = _csv_scan(
        UInt8(ord(",")),
        True,
        Optional[List[String]](_names("name", "id")),
        Optional[Expr](_id_gt(3)),
    )
    var lp = _lowered(scan)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SEG_SOURCE_CSV)
    # The spec names every column of the file, not the projection.
    assert_equal(len(seg.source_spec.csv_spec.column_names), 4)
    assert_equal(len(seg.ops), 2)
    assert_equal(seg.ops[0].tag, OP_FILTER)
    assert_equal(String(seg.ops[0].filter_predicate.value()), String(_id_gt(3)))
    assert_equal(seg.ops[1].tag, OP_PROJECT)
    ref names = seg.ops[1].project_names.value()
    assert_equal(len(names), 2)
    assert_equal(names[0], "name")
    assert_equal(names[1], "id")


def test_the_positional_csv_factory_lowers_with_the_default_dialect() raises:
    var scan = LogicalPlan.scan(String("plain.csv"), SOURCE_CSV, _schema())
    var lp = _lowered(scan)
    ref s = lp.segments[0].source_spec
    assert_equal(lp.segments[0].source_kind, SEG_SOURCE_CSV)
    assert_equal(s.csv_spec.path, "plain.csv")
    assert_equal(Int(s.csv_spec.delimiter), ord(","))
    assert_true(s.csv_spec.has_header)
    assert_equal(s.csv_spec.quote_style_tag, 0)


def test_a_string_key_over_a_csv_scan_is_columnar_never_dictionary() raises:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var keys = ExprArray()
    keys.append(Expr.col_ref("name"))
    var plan = LogicalPlan.aggregate(
        keys^, aggs^, _csv_scan(UInt8(ord(",")), True)
    )
    var lp = _lowered(plan)
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SEG_SOURCE_CSV)
    assert_equal(
        triple_name(seg.sink_kind, seg.sink_key_dtype, seg.sink_orientation),
        "(SINK_AGG, STRING, COLUMNAR)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

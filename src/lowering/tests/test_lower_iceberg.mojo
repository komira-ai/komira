# =============================================================================
# test_lower_iceberg: an Iceberg table scan lowered to a SOURCE_ICEBERG segment
# =============================================================================
#
# A scan whose source is a binding of kind `komira.iceberg.table` opens a
# SOURCE_ICEBERG pipeline. Lowering reads no table metadata: the files come
# from the inputs (`LoweringInputs.add_iceberg_scan`), which the host filled
# before lowering. Each test builds the scan the way the Iceberg binding does
# (a `ScanBinding` of that kind name over `SourceVariant.from_binding`), lowers
# it under the reference host profile and asserts the segment.
#
#   test_an_iceberg_scan_is_an_iceberg_source_with_the_planned_files: the spec
#     is the one the inputs carry, the files, the delete files they refer to
#     and the bound columns with their field ids, and no other arm's field is
#     set.
#   test_an_iceberg_scan_pushed_filter_and_projection_are_operators_over_the_full_schema:
#     the filter the optimizer pushed into the scan is kept as the first
#     operator and the projection is the second, over every bound column.
#   test_an_iceberg_scan_without_planned_files_is_refused_by_name: the exact
#     refusal when the inputs hold no files for the scan.
#   test_the_iceberg_segment_renders_its_columns_files_and_deletes: the render
#     line of the source.
#   test_an_iceberg_scan_card_estimate_is_the_inputs_row_count: the statistics
#     given beside the files are the segment's row estimate.
#   test_a_binding_of_another_kind_is_not_cut: a binding with another kind
#     name is refused as an unknown source, and the Iceberg arm is not entered.
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
)
from lowering.render import render_lowered_plan
from physical_plan.iceberg_scan_spec import (
    IcebergDataFileSpec,
    IcebergDeleteSpec,
    IcebergScanSpec,
)
from physical_plan.physical_plan import (
    OP_FILTER,
    OP_PROJECT,
    SINK_COLLECT,
    SOURCE_ICEBERG,
)
from plan_expr.expr import Expr, BIN_GT
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import LogicalPlan
from plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from scan_source.pushdown_gate import PushdownGate
from scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SNAPSHOT_PINNED,
)
from scan_source.scan_params import ScanParams
from scan_source.source_variant import SourceVariant


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("name", ArrowType.STRING, True))
    return sb.build()


def _strings(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _ints(a: Int, b: Int = -1) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    if b >= 0:
        out.append(b)
    return out^


def _binding(kind_name: String) -> ScanBinding:
    var params = ScanParams()
    params.put_str(String("metadata_path"), String("/warehouse/orders/m.json"))
    return ScanBinding(
        kind_id=scan_kind_id(kind_name),
        kind_name=kind_name.copy(),
        name=String("/warehouse/orders/m.json"),
        params=params^,
        schema=_schema(),
        fingerprint=UInt64(11),
        structural_id=UInt64(11),
        gate=PushdownGate.conjunctive_comparison(False),
        snapshot_policy=SNAPSHOT_PINNED,
        snapshot_token=UInt64(7),
    )


def _scan(
    kind_name: String = "komira.iceberg.table",
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(_binding(kind_name)),
        _schema(),
        projection^,
        filter^,
    )


def _spec() -> IcebergScanSpec:
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    var files = List[IcebergDataFileSpec]()
    files.append(
        IcebergDataFileSpec(
            String("/warehouse/orders/data/a.parquet"),
            String("file:///warehouse/orders/data/a.parquet"),
            _ints(0),
            _ints(1),
        )
    )
    files.append(
        IcebergDataFileSpec(
            String("/warehouse/orders/data/b.parquet"),
            String("file:///warehouse/orders/data/b.parquet"),
            List[Int](),
            List[Int](),
        )
    )
    var deletes = List[IcebergDeleteSpec]()
    deletes.append(
        IcebergDeleteSpec(
            String("/warehouse/orders/data/pos.parquet"),
            1,
            String("PARQUET"),
            List[String](),
        )
    )
    deletes.append(
        IcebergDeleteSpec(
            String("/warehouse/orders/data/eq.avro"),
            2,
            String("AVRO"),
            _strings("id"),
        )
    )
    return IcebergScanSpec(
        _strings("id", "name"), types^, _ints(1, 2), files^, deletes^
    )


def _inputs() -> LoweringInputs:
    var inputs = LoweringInputs()
    inputs.add_iceberg_scan(_spec())
    return inputs^


def _lowered(plan: LogicalPlan, inputs: LoweringInputs) raises -> LoweredPlan:
    return lower(plan, reference_host_profile("test-build"), inputs)


def _id_gt(v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("id"), Expr.literal(ScalarValue.from_int64(v))
    )


def test_an_iceberg_scan_is_an_iceberg_source_with_the_planned_files() raises:
    var lp = _lowered(_scan(), _inputs())
    assert_equal(len(lp.segments), 1)
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_ICEBERG)
    assert_equal(seg.sink_kind, SINK_COLLECT)
    assert_equal(len(seg.ops), 0)
    ref spec = seg.source_spec.iceberg_spec
    assert_equal(len(spec.column_names), 2)
    assert_equal(spec.column_names[0], "id")
    assert_equal(spec.column_names[1], "name")
    assert_true(spec.column_types[0] == ArrowType.INT64)
    assert_true(spec.column_types[1] == ArrowType.STRING)
    assert_equal(spec.column_field_ids[0], 1)
    assert_equal(spec.column_field_ids[1], 2)
    assert_equal(len(spec.data_files), 2)
    assert_equal(spec.data_files[0].path, "/warehouse/orders/data/a.parquet")
    assert_equal(
        spec.data_files[0].stored_path,
        "file:///warehouse/orders/data/a.parquet",
    )
    assert_equal(len(spec.data_files[0].position_deletes), 1)
    assert_equal(spec.data_files[0].position_deletes[0], 0)
    assert_equal(spec.data_files[0].equality_deletes[0], 1)
    assert_equal(len(spec.data_files[1].position_deletes), 0)
    assert_equal(len(spec.deletes), 2)
    assert_equal(spec.deletes[0].content, 1)
    assert_equal(spec.deletes[0].file_format, "PARQUET")
    assert_equal(spec.deletes[1].path, "/warehouse/orders/data/eq.avro")
    assert_equal(spec.deletes[1].equality_columns[0], "id")
    # No other arm's field is set.
    assert_equal(seg.source_spec.parquet_path, "")
    assert_equal(seg.source_spec.batch_handle_id, -1)
    assert_equal(len(seg.source_spec.csv_spec.column_names), 0)


def test_an_iceberg_scan_pushed_filter_and_projection_are_operators_over_the_full_schema() raises:
    var scan = _scan(
        "komira.iceberg.table",
        Optional[List[String]](_strings("name")),
        Optional[Expr](_id_gt(3)),
    )
    var lp = _lowered(scan, _inputs())
    ref seg = lp.segments[0]
    assert_equal(seg.source_kind, SOURCE_ICEBERG)
    # The spec names every bound column, not the projection.
    assert_equal(len(seg.source_spec.iceberg_spec.column_names), 2)
    assert_equal(len(seg.ops), 2)
    assert_equal(seg.ops[0].tag, OP_FILTER)
    assert_equal(String(seg.ops[0].filter_predicate.value()), String(_id_gt(3)))
    assert_equal(seg.ops[1].tag, OP_PROJECT)
    ref names = seg.ops[1].project_names.value()
    assert_equal(len(names), 1)
    assert_equal(names[0], "name")


def test_an_iceberg_scan_without_planned_files_is_refused_by_name() raises:
    var inputs = LoweringInputs()
    inputs.add_scan()
    var msg = String("")
    try:
        _ = _lowered(_scan(), inputs)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(LOWERING_SCAN_NOT_TOTAL)
        + ": an Iceberg scan whose files were not planned",
    )


def test_the_iceberg_segment_renders_its_columns_files_and_deletes() raises:
    var text = render_lowered_plan(_lowered(_scan(), _inputs()))
    var want = (
        "  source: SOURCE_ICEBERG columns=[id:int64#1, name:string#2]"
        " files=[/warehouse/orders/data/a.parquet"
        " (stored=file:///warehouse/orders/data/a.parquet"
        " position_deletes=[0] equality_deletes=[1]),"
        " /warehouse/orders/data/b.parquet"
        " (stored=file:///warehouse/orders/data/b.parquet"
        " position_deletes=[] equality_deletes=[])]"
        " deletes=[/warehouse/orders/data/pos.parquet"
        " (content=1 format=PARQUET equality_columns=[]),"
        " /warehouse/orders/data/eq.avro"
        " (content=2 format=AVRO equality_columns=[id])]\n"
    )
    assert_true(want in text, text)


def test_an_iceberg_scan_card_estimate_is_the_inputs_row_count() raises:
    var inputs = LoweringInputs()
    inputs.add_iceberg_scan(
        _spec(),
        Optional[TableStats](
            TableStats(
                4200,
                List[String](),
                List[ColumnStats](),
                STATS_SOURCE_PARQUET_METADATA,
            )
        ),
    )
    var lp = _lowered(_scan(), inputs)
    assert_equal(lp.segments[0].card_estimate_rows, 4200)


def test_a_binding_of_another_kind_is_not_cut() raises:
    var msg = String("")
    try:
        _ = _lowered(_scan("komira.search.index"), _inputs())
    except e:
        msg = String(e)
    assert_true(msg.startswith("LOWERING_UNCUTTABLE_NODE: "), msg)
    assert_true("a komira.search.index source" in msg, msg)


def main() raises:
    var suite = TestSuite()
    suite.test[test_an_iceberg_scan_is_an_iceberg_source_with_the_planned_files]()
    suite.test[test_an_iceberg_scan_pushed_filter_and_projection_are_operators_over_the_full_schema]()
    suite.test[test_an_iceberg_scan_without_planned_files_is_refused_by_name]()
    suite.test[test_the_iceberg_segment_renders_its_columns_files_and_deletes]()
    suite.test[test_an_iceberg_scan_card_estimate_is_the_inputs_row_count]()
    suite.test[test_a_binding_of_another_kind_is_not_cut]()
    suite^.run()

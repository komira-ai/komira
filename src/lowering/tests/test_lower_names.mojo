# =============================================================================
# test_lower_names: the names a render and a refusal print, and two group keys
# that are never dictionary encoded
# =============================================================================
#
# test_render_names_every_source_edge_order_and_operator
#     a hand-built LoweredPlan of four segments renders to the exact text:
#     every source kind, every edge tag, every order kind, and the PROJECT,
#     LIMIT and JOIN_PROBE operator lines.
# test_render_prints_the_number_of_a_tag_it_has_no_name_for
#     an unknown source kind, edge tag, order kind and operator tag render as
#     SOURCE_<n>, E<n>, ORDER_<n> and OP_<n>.
# test_every_sink_kind_has_its_name
#     triple_name prints SINK_AGG through SINK_JOIN_PROBE, one name per kind.
# test_an_unknown_sink_key_and_orientation_print_their_numbers
#     triple_name prints SINK_<n>, KEY_<n> and ORIENT_<n>, and admit_segment
#     refuses that triple with the text naming it.
# test_a_string_key_over_an_in_memory_scan_is_columnar_whatever_the_footers_say
#     a STRING group key over an in-memory scan lowers to
#     (SINK_AGG, STRING, COLUMNAR) although the facts name the column as
#     dictionary encoded.
# test_an_aliased_string_key_over_a_parquet_scan_is_columnar
#     a STRING group key that is an alias of a column lowers to
#     (SINK_AGG, STRING, COLUMNAR) although the facts name the column as
#     dictionary encoded; the bare column beside it is DICT_ENCODED.
# =============================================================================

from std.testing import TestSuite, assert_equal

from arrow.arrow_types import ArrowType
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from containers.slab import Slab
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LOWERING_SINK_UNSERVED,
    LoweredPlan,
    LoweringInputs,
    ParamTable,
)
from lowering.render import render_lowered_plan
from lowering.sink_capability import admit_segment, triple_name
from physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    SegmentDescPod,
    SourceSpecPod,
    MorselOp,
    SOURCE_BATCH,
    SOURCE_SINK_OUTPUT,
    SOURCE_CONCAT,
    SINK_AGG,
    SINK_SORT,
    SINK_TOPN,
    SINK_COLLECT,
    SINK_HASH_BUILD,
    SINK_PARTITION_BY,
    SINK_PARTITION_TOPN,
    SINK_SMJ_BUILD,
    SINK_ASOF_JOIN,
    SINK_JOIN_PROBE,
    SINK_ORIENT_COLUMNAR,
    SINK_ORIENT_DICT_ENCODED,
    KEY_DTYPE_NONE,
    KEY_DTYPE_STRING,
    EDGE_E1_MORSEL_STREAM,
    EDGE_E2_INGEST_STREAM,
    EDGE_E3_PUBLISH_WAIT,
    EDGE_E4_PARTITION_WISE,
    EDGE_E5_INDEPENDENT,
    ORDER_NONE,
    ORDER_PARTITION_ID,
    ORDER_ROW_RANGE,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT
from plan_expr.expr import Expr
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
)
from plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from scan_source.in_memory_source import InMemorySource
from scan_source.source_variant import SourceVariant


def _seg(
    seg_id: Int,
    source_kind: UInt8,
    var source_spec: SourceSpecPod,
    var ops: Slab[MorselOp],
    sink_kind: UInt8,
    key: UInt8,
    orientation: UInt8,
    var deps: List[Int],
    var edge_tags: List[UInt8],
    order_key_kind: UInt8 = ORDER_NONE,
    partition_count: Int = 1,
) -> SegmentDescPod:
    return SegmentDescPod(
        seg_id,
        source_kind,
        source_spec^,
        ops^,
        sink_kind,
        key,
        orientation,
        -1,
        seg_id,
        deps^,
        edge_tags^,
        partition_count,
        order_key_kind,
    )


def _plan_of(var segments: List[SegmentDescPod], result_seg_id: Int) -> LoweredPlan:
    return LoweredPlan(segments^, ParamTable(), result_seg_id)


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def test_render_names_every_source_edge_order_and_operator() raises:
    var exprs = ExprArray()
    exprs.append(_col("a"))
    exprs.append(_col("b"))
    var names = List[String]()
    names.append("x")
    names.append("y")
    var ops0 = Slab[MorselOp]()
    ops0.append(MorselOp.project(exprs^, names^))
    ops0.append(MorselOp.limit(5))
    ops0.append(
        MorselOp.join_probe(3, List[String](), List[String](), UInt8(0))
    )
    var segments = List[SegmentDescPod]()
    segments.append(
        _seg(
            0,
            SOURCE_BATCH,
            SourceSpecPod.batch(7),
            ops0^,
            SINK_COLLECT,
            KEY_DTYPE_NONE,
            SINK_ORIENT_COLUMNAR,
            List[Int](),
            List[UInt8](),
        )
    )
    var producers = List[Int]()
    producers.append(0)
    producers.append(2)
    var deps1 = List[Int]()
    var tags1 = List[UInt8]()
    for _ in range(5):
        deps1.append(0)
    tags1.append(EDGE_E1_MORSEL_STREAM)
    tags1.append(EDGE_E2_INGEST_STREAM)
    tags1.append(EDGE_E3_PUBLISH_WAIT)
    tags1.append(EDGE_E4_PARTITION_WISE)
    tags1.append(EDGE_E5_INDEPENDENT)
    segments.append(
        _seg(
            1,
            SOURCE_CONCAT,
            SourceSpecPod.concat(producers^),
            Slab[MorselOp](),
            SINK_SORT,
            KEY_DTYPE_NONE,
            SINK_ORIENT_COLUMNAR,
            deps1^,
            tags1^,
            ORDER_PARTITION_ID,
            4,
        )
    )
    var deps2 = List[Int]()
    deps2.append(1)
    var tags2 = List[UInt8]()
    tags2.append(EDGE_E3_PUBLISH_WAIT)
    segments.append(
        _seg(
            2,
            SOURCE_SINK_OUTPUT,
            SourceSpecPod.from_sink_output(1),
            Slab[MorselOp](),
            SINK_AGG,
            KEY_DTYPE_STRING,
            SINK_ORIENT_DICT_ENCODED,
            deps2^,
            tags2^,
            ORDER_ROW_RANGE,
        )
    )
    var plan = _plan_of(segments^, 2)

    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_BATCH batch=7\n"
    expected += "  op 0: PROJECT x := " + String(_col("a")) + ", y := " + String(_col("b")) + "\n"
    expected += "  op 1: LIMIT 5\n"
    expected += "  op 2: JOIN_PROBE build_seg=3 on=[]\n"
    expected += "  sink: (SINK_COLLECT, NONE, COLUMNAR) param=-1 state=0\n"
    expected += "  deps: none\n"
    expected += "  order: ORDER_NONE partitions=1\n"
    expected += "  estimates: morsel_rows=0 card_rows=0 mem_bytes=0\n"
    expected += "segment 1\n"
    expected += "  source: SOURCE_CONCAT from=0,2\n"
    expected += "  sink: (SINK_SORT, NONE, COLUMNAR) param=-1 state=1\n"
    expected += "  deps: 0/E1 0/E2 0/E3 0/E4 0/E5\n"
    expected += "  order: ORDER_PARTITION_ID partitions=4\n"
    expected += "  estimates: morsel_rows=0 card_rows=0 mem_bytes=0\n"
    expected += "segment 2\n"
    expected += "  source: SOURCE_SINK_OUTPUT from=1\n"
    expected += "  sink: (SINK_AGG, STRING, DICT_ENCODED) param=-1 state=2\n"
    expected += "  deps: 1/E3\n"
    expected += "  order: ORDER_ROW_RANGE partitions=1\n"
    expected += "  estimates: morsel_rows=0 card_rows=0 mem_bytes=0\n"
    expected += "params: agg=0 sort=0 topn=0 window=0 batches=0\n"
    expected += "result: segment 2\n"
    assert_equal(render_lowered_plan(plan), expected)


def test_render_prints_the_number_of_a_tag_it_has_no_name_for() raises:
    var ops = Slab[MorselOp]()
    ops.append(MorselOp(tag=UInt8(77)))
    var deps = List[Int]()
    deps.append(5)
    var tags = List[UInt8]()
    tags.append(UInt8(9))
    var segments = List[SegmentDescPod]()
    segments.append(
        _seg(
            0,
            UInt8(99),
            SourceSpecPod(),
            ops^,
            SINK_COLLECT,
            KEY_DTYPE_NONE,
            SINK_ORIENT_COLUMNAR,
            deps^,
            tags^,
            UInt8(6),
        )
    )
    var plan = _plan_of(segments^, 0)
    var expected = String("ir_version ") + String(PHYSICAL_PLAN_IR_VERSION) + "\n"
    expected += "segment 0\n"
    expected += "  source: SOURCE_99 from=\n"
    expected += "  op 0: OP_77\n"
    expected += "  sink: (SINK_COLLECT, NONE, COLUMNAR) param=-1 state=0\n"
    expected += "  deps: 5/E9\n"
    expected += "  order: ORDER_6 partitions=1\n"
    expected += "  estimates: morsel_rows=0 card_rows=0 mem_bytes=0\n"
    expected += "params: agg=0 sort=0 topn=0 window=0 batches=0\n"
    expected += "result: segment 0\n"
    assert_equal(render_lowered_plan(plan), expected)


def test_every_sink_kind_has_its_name() raises:
    var n = KEY_DTYPE_NONE
    var c = SINK_ORIENT_COLUMNAR
    assert_equal(triple_name(SINK_AGG, n, c), "(SINK_AGG, NONE, COLUMNAR)")
    assert_equal(triple_name(SINK_SORT, n, c), "(SINK_SORT, NONE, COLUMNAR)")
    assert_equal(triple_name(SINK_TOPN, n, c), "(SINK_TOPN, NONE, COLUMNAR)")
    assert_equal(triple_name(SINK_COLLECT, n, c), "(SINK_COLLECT, NONE, COLUMNAR)")
    assert_equal(triple_name(SINK_HASH_BUILD, n, c), "(SINK_HASH_BUILD, NONE, COLUMNAR)")
    assert_equal(triple_name(SINK_PARTITION_BY, n, c), "(SINK_PARTITION_BY, NONE, COLUMNAR)")
    assert_equal(triple_name(SINK_PARTITION_TOPN, n, c), "(SINK_PARTITION_TOPN, NONE, COLUMNAR)")
    assert_equal(triple_name(SINK_SMJ_BUILD, n, c), "(SINK_SMJ_BUILD, NONE, COLUMNAR)")
    assert_equal(triple_name(SINK_ASOF_JOIN, n, c), "(SINK_ASOF_JOIN, NONE, COLUMNAR)")
    assert_equal(triple_name(SINK_JOIN_PROBE, n, c), "(SINK_JOIN_PROBE, NONE, COLUMNAR)")


def test_an_unknown_sink_key_and_orientation_print_their_numbers() raises:
    assert_equal(
        triple_name(UInt8(200), UInt8(99), UInt8(7)),
        "(SINK_200, KEY_99, ORIENT_7)",
    )
    var message = String()
    try:
        admit_segment(
            _seg(
                3,
                SOURCE_SINK_OUTPUT,
                SourceSpecPod.from_sink_output(0),
                Slab[MorselOp](),
                UInt8(200),
                UInt8(99),
                UInt8(7),
                List[Int](),
                List[UInt8](),
            )
        )
    except e:
        message = String(e)
    assert_equal(
        message,
        String(LOWERING_SINK_UNSERVED)
        + ": segment 3 ends in (SINK_200, KEY_99, ORIENT_7), which no row of"
        " the sink capability table serves",
    )


# =============================================================================
# Group keys that are never dictionary encoded
# =============================================================================


def _stats() -> TableStats:
    return TableStats(
        10,
        List[String](),
        List[ColumnStats](),
        STATS_SOURCE_PARQUET_METADATA,
    )


def _string_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.STRING, False))
    return sb.build()


def _count(var keys: ExprArray, var child: LogicalPlan) -> LogicalPlan:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    return LogicalPlan.aggregate(keys^, aggs^, child^)


def _sink_of(plan: LogicalPlan) raises -> String:
    var inputs = LoweringInputs()
    var dict_columns = List[String]()
    dict_columns.append("a")
    inputs.add_scan(Optional[TableStats](_stats()), dict_columns^)
    var lp = lower(plan, reference_host_profile("test-build"), inputs)
    ref seg = lp.segments[lp.result_seg_id]
    return triple_name(seg.sink_kind, seg.sink_key_dtype, seg.sink_orientation)


def test_a_string_key_over_an_in_memory_scan_is_columnar_whatever_the_footers_say() raises:
    var vals = List[Int64]()
    vals.append(Int64(1))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    var rb = RecordBatch.from_columns_1(
        sb.build(), PrimitiveArray[DType.int64].from_list(vals)
    )
    var source = InMemorySource.from_record_batch(rb^)
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(source^), _string_schema()
    )
    var keys = ExprArray()
    keys.append(_col("a"))
    assert_equal(_sink_of(_count(keys^, scan^)), "(SINK_AGG, STRING, COLUMNAR)")


def test_an_aliased_string_key_over_a_parquet_scan_is_columnar() raises:
    var bare = ExprArray()
    bare.append(_col("a"))
    assert_equal(
        _sink_of(
            _count(
                bare^,
                LogicalPlan.scan(
                    String("keys.parquet"), SOURCE_PARQUET, _string_schema()
                ),
            )
        ),
        "(SINK_AGG, STRING, DICT_ENCODED)",
    )
    var aliased = ExprArray()
    aliased.append(Expr.alias(_col("a"), "k"))
    assert_equal(
        _sink_of(
            _count(
                aliased^,
                LogicalPlan.scan(
                    String("keys.parquet"), SOURCE_PARQUET, _string_schema()
                ),
            )
        ),
        "(SINK_AGG, STRING, COLUMNAR)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

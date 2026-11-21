# =============================================================================
# test_lower_refusals: what lowering refuses, by name, and what it does not
# =============================================================================
#
# Every refusal token is raised by the plan that should raise it and by no
# other: each case checks the exact token that starts the message and the text
# that says why, and a neighbouring plan that differs only in the refused
# detail lowers. A refused plan never produces a LoweredPlan.
#
# Tests, and the behaviour each asserts:
#   test_nodes_the_cutter_does_not_cut_are_refused_by_tag: a join, union,
#     top-n, view reference, shared-subplan reference and cast to string are
#     each refused by their tag name.
#   test_a_refused_node_below_a_breaker_refuses_the_whole_plan: a join under an
#     aggregate refuses the plan; the aggregate over a scan lowers.
#   test_a_distinct_over_a_column_list_is_refused_and_one_over_the_row_is_cut:
#     a distinct that names columns is refused with the exact text; the same
#     distinct over the whole row lowers.
#   test_a_distinct_over_two_columns_of_one_name_is_refused_and_distinct_names_are_cut:
#     a distinct whose child repeats a column name is refused with the exact
#     text, also when the repeat is not adjacent; two differently named integer
#     columns are not this refusal but the unserved-sink one.
#   test_a_distinct_over_no_column_is_refused_and_one_column_is_cut: a distinct
#     over a zero-column schema is refused with the exact text; one column
#     lowers.
#   test_a_distinct_over_columns_no_sink_row_serves_is_refused: a distinct over
#     a date, a bool, two integers, an integer and a string, or two strings of
#     which one is not dictionary encoded is refused as an unserved sink with
#     the exact text; an integer column, and two dictionary encoded strings,
#     lower.
# The remaining tests are named for the refusal they hold.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_UNCUTTABLE_NODE,
    LOWERING_SINK_UNSERVED,
    LOWERING_SCAN_NOT_TOTAL,
    LOWERING_INPUTS_SCAN_COUNT,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_UDF
from plan_expr.partition_expr import PartitionExpr
from plan_expr.partition_pred_pod import PartitionPredicatePod
from plan_expr.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_KIND_FILTER,
    UDF_KIND_AGG,
    DTAG_I64,
)
from plan_expr.expr import Expr, BIN_GT
from plan_expr.fs_descriptor_pod import FsDescriptorPod, FS_SCHEME_S3
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    SOURCE_CSV,
    SOURCE_KIND_UNSET,
    JOIN_INNER,
    PLAN_JOIN,
    PLAN_UNION,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    PLAN_LIMIT,
    PLAN_AGGREGATE,
    PLAN_PARTITION_BY,
    PLAN_EXCHANGE,
    plan_tag_name,
)
from plan_ir.logical_plan_variants import AggGroupTopK
from plan_ir.plan_decisions import (
    AGG_MODE_FINAL,
    EXCHANGE_KIND_GATHER,
    SCAN_UNBOUNDED,
)
from plan_ir.plan_decisions import AGG_MODE_PARTIAL, AGG_MODE_SINGLE, AGG_MODE_UNSET
from scan_source.parquet_source import ParquetSource
from scan_source.source_variant import SourceVariant


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("d", ArrowType.DATE32, False))
    sb.add_field(Field("b", ArrowType.BOOL, False))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _schema())


def _inputs(scans: Int = 1) -> LoweringInputs:
    var inputs = LoweringInputs()
    for _ in range(scans):
        inputs.add_scan()
    return inputs^


def _bools(a: Bool) -> List[Bool]:
    var out = List[Bool]()
    out.append(a)
    return out^


def _names(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _count_by(var child: LogicalPlan, keys: List[String], mode: UInt8 = AGG_MODE_UNSET) -> LogicalPlan:
    var group_by = ExprArray()
    for i in range(len(keys)):
        group_by.append(Expr.col_ref(keys[i]))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    return LogicalPlan.aggregate(group_by^, aggs^, child^, mode)


def _message(plan: LogicalPlan, inputs: LoweringInputs) raises -> String:
    """The refusal text, or an empty string when the plan lowers."""
    try:
        _ = lower(plan, reference_host_profile("test-build"), inputs)
    except e:
        return String(e)
    return String("")


def _refused_with(message: String, token: String, why: String) raises:
    assert_true(message.startswith(token + ": "), String("message does not start with the token: ") + message)
    assert_true(why in message, String("message does not say why (") + why + "): " + message)


def test_nodes_the_cutter_does_not_cut_are_refused_by_tag() raises:
    var join = LogicalPlan.join(_scan(), _scan(), _names("k"), _names("k"), JOIN_INNER)
    _refused_with(_message(join, _inputs(2)), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_JOIN))

    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_scan()))
    children.append(OwnedPointer(_scan()))
    var union = LogicalPlan.union(children^, _schema())
    _refused_with(_message(union, _inputs(2)), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_UNION))

    var topn = LogicalPlan.topn(_names("k"), _bools(False), 5, _scan())
    _refused_with(_message(topn, _inputs()), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_TOPN))

    var view = LogicalPlan.view_ref(String("v"), _schema())
    _refused_with(_message(view, _inputs(0)), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_VIEW_REF))

    var shared = LogicalPlan.cse_ref(UInt64(7), _schema())
    _refused_with(_message(shared, _inputs(0)), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_CSE_REF))

    var cast = LogicalPlan.cast_to_varchar(_scan())
    _refused_with(_message(cast, _inputs()), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_CAST_TO_VARCHAR))


def test_a_refused_node_below_a_breaker_refuses_the_whole_plan() raises:
    var join = LogicalPlan.join(_scan(), _scan(), _names("k"), _names("k"), JOIN_INNER)
    var plan = _count_by(join^, List[String]())
    _refused_with(_message(plan, _inputs(2)), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_JOIN))
    # The same aggregate over a scan lowers.
    assert_equal(_message(_count_by(_scan(), List[String]()), _inputs()), "")


def test_a_limit_with_an_offset_is_refused_and_a_plain_limit_is_cut() raises:
    _refused_with(_message(LogicalPlan.limit(5, _scan(), 2), _inputs()), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_LIMIT))
    _refused_with(_message(LogicalPlan.limit(-3, _scan()), _inputs()), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_LIMIT))
    assert_equal(_message(LogicalPlan.limit(5, _scan()), _inputs()), "")


def test_a_partial_aggregate_is_refused_and_a_single_one_is_cut() raises:
    _refused_with(_message(_count_by(_scan(), List[String](), AGG_MODE_PARTIAL), _inputs()), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_AGGREGATE))
    assert_equal(_message(_count_by(_scan(), List[String](), AGG_MODE_SINGLE), _inputs()), "")


def test_a_source_other_than_parquet_or_memory_is_refused() raises:
    var csv = LogicalPlan.scan(String("t.csv"), SOURCE_CSV, _schema())
    _refused_with(_message(csv, _inputs()), LOWERING_UNCUTTABLE_NODE, "csv")


def _parquet_scan(var source: ParquetSource) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(SourceVariant(source^), _schema())


def test_a_parquet_scan_the_segment_arm_cannot_carry_is_refused() raises:
    var remote = _parquet_scan(
        ParquetSource(String("a.parquet"), _schema()).with_fs_descriptor(
            FsDescriptorPod.cloud(FS_SCHEME_S3, String("bucket"), 3)
        )
    )
    _refused_with(_message(remote, _inputs()), LOWERING_SCAN_NOT_TOTAL, "local")

    # One local file lowers.
    assert_equal(_message(_parquet_scan(ParquetSource(String("a.parquet"), _schema())), _inputs()), "")


def test_a_scan_of_several_files_lowers() raises:
    var two = List[String]()
    two.append("a.parquet")
    two.append("b.parquet")
    var multi = _parquet_scan(
        ParquetSource.partitioned(two^, _schema(), List[Field](), List[List[String]]())
    )
    assert_equal(_message(multi, _inputs()), "")


def test_a_hive_partitioned_scan_lowers() raises:
    var two = List[String]()
    two.append("dt=2026-10-01/a.parquet")
    two.append("dt=2026-10-02/b.parquet")
    var cols = List[Field]()
    cols.append(Field("dt", ArrowType.STRING, False))
    var values = List[List[String]]()
    values.append(_names("2026-10-01"))
    values.append(_names("2026-10-02"))
    var hive = _parquet_scan(ParquetSource.partitioned(two^, _schema(), cols^, values^))
    assert_equal(_message(hive, _inputs()), "")


def test_a_hive_directory_scan_is_refused_and_a_plain_scan_lowers() raises:
    var source = ParquetSource(String("a.parquet"), _schema())
    source.hive_dir_scan = True
    _refused_with(_message(_parquet_scan(source^), _inputs()), LOWERING_SCAN_NOT_TOTAL, "lazily")
    assert_equal(_message(_parquet_scan(ParquetSource(String("a.parquet"), _schema())), _inputs()), "")


def _two_string_scan() -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("t", ArrowType.STRING, False))
    return LogicalPlan.scan(String("u.parquet"), SOURCE_PARQUET, sb.build())


def test_a_group_key_no_sink_row_serves_is_refused() raises:
    _refused_with(_message(_count_by(_scan(), _names("d")), _inputs()), LOWERING_SINK_UNSERVED, "no sink row")
    _refused_with(_message(_count_by(_scan(), _names("b")), _inputs()), LOWERING_SINK_UNSERVED, "no sink row")
    _refused_with(_message(_count_by(_scan(), _names("k", "v")), _inputs()), LOWERING_SINK_UNSERVED, "2 columns")
    # Two strings are served only when both are dictionary encoded.
    var one_dictionary = LoweringInputs()
    one_dictionary.add_scan(None, _names("s"))
    var strings = _two_string_scan()
    _refused_with(_message(_count_by(strings^, _names("s", "t")), one_dictionary), LOWERING_SINK_UNSERVED, "dictionary")
    _refused_with(_message(_count_by(_scan(), _names("s", "k")), _inputs()), LOWERING_SINK_UNSERVED, "2 columns")
    # An integer key lowers.
    assert_equal(_message(_count_by(_scan(), _names("k")), _inputs()), "")


def _only(name: String) -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(name))
    return LogicalPlan.project(exprs^, _scan())


def _pair(a: String, b: String) -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(a))
    exprs.append(Expr.col_ref(b))
    return LogicalPlan.project(exprs^, _scan())


def _uncuttable_text(why: String) -> String:
    return String(LOWERING_UNCUTTABLE_NODE) + ": " + plan_tag_name(PLAN_DISTINCT) + " (" + why + ") is not cut"


def _unserved_text(why: String) -> String:
    return String(LOWERING_SINK_UNSERVED) + ": " + why


def test_a_distinct_over_a_column_list_is_refused_and_one_over_the_row_is_cut() raises:
    var listed = LogicalPlan.distinct(Optional[List[String]](_names("k")), _scan())
    assert_equal(_message(listed, _inputs()), _uncuttable_text("a distinct over a column list"))
    assert_equal(_message(LogicalPlan.distinct(None, _only("k")), _inputs()), "")


def test_a_distinct_over_two_columns_of_one_name_is_refused_and_distinct_names_are_cut() raises:
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.col_ref("k"), "x"))
    exprs.append(Expr.alias(Expr.col_ref("v"), "x"))
    var repeated = LogicalPlan.distinct(None, LogicalPlan.project(exprs^, _scan()))
    assert_equal(
        _message(repeated, _inputs()),
        _uncuttable_text("a distinct over two columns both named `x`"),
    )
    # The repeat need not be adjacent.
    var spread = ExprArray()
    spread.append(Expr.alias(Expr.col_ref("k"), "x"))
    spread.append(Expr.alias(Expr.col_ref("v"), "y"))
    spread.append(Expr.alias(Expr.col_ref("k"), "x"))
    var far = LogicalPlan.distinct(None, LogicalPlan.project(spread^, _scan()))
    assert_equal(
        _message(far, _inputs()),
        _uncuttable_text("a distinct over two columns both named `x`"),
    )
    var named = ExprArray()
    named.append(Expr.alias(Expr.col_ref("k"), "x"))
    named.append(Expr.alias(Expr.col_ref("v"), "y"))
    var other = LogicalPlan.distinct(None, LogicalPlan.project(named^, _scan()))
    # Two differently named integer columns are the unserved-sink refusal, not this one.
    assert_equal(
        _message(other, _inputs()),
        _unserved_text(
            "a group key of 2 columns is served only when every column is a dictionary encoded string"
        ),
    )


def test_a_distinct_over_no_column_is_refused_and_one_column_is_cut() raises:
    var sb = SchemaBuilder()
    var empty = LogicalPlan.scan(String("e.parquet"), SOURCE_PARQUET, sb.build())
    assert_equal(
        _message(LogicalPlan.distinct(None, empty^), _inputs()),
        _uncuttable_text("a distinct over no column"),
    )
    assert_equal(_message(LogicalPlan.distinct(None, _only("k")), _inputs()), "")


def test_a_distinct_over_columns_no_sink_row_serves_is_refused() raises:
    var no_row = String(" has no sink row")
    assert_equal(
        _message(LogicalPlan.distinct(None, _only("d")), _inputs()),
        _unserved_text("a group key column of type " + String(ArrowType.DATE32) + no_row),
    )
    assert_equal(
        _message(LogicalPlan.distinct(None, _only("b")), _inputs()),
        _unserved_text("a group key column of type " + String(ArrowType.BOOL) + no_row),
    )
    var two_columns = _unserved_text(
        "a group key of 2 columns is served only when every column is a dictionary encoded string"
    )
    assert_equal(_message(LogicalPlan.distinct(None, _pair("k", "v")), _inputs()), two_columns)
    assert_equal(_message(LogicalPlan.distinct(None, _pair("s", "k")), _inputs()), two_columns)
    # Two strings are served only when both are dictionary encoded.
    var one_dictionary = LoweringInputs()
    one_dictionary.add_scan(None, _names("s"))
    assert_equal(
        _message(LogicalPlan.distinct(None, _two_string_scan()), one_dictionary),
        two_columns,
    )
    # An integer column, and two dictionary encoded strings, lower.
    assert_equal(_message(LogicalPlan.distinct(None, _only("k")), _inputs()), "")
    var both = LoweringInputs()
    both.add_scan(None, _names("s", "t"))
    assert_equal(_message(LogicalPlan.distinct(None, _two_string_scan()), both), "")


def _udf(kind: UInt8) -> OwnedPointer[UdfData]:
    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append((String("v"), DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append((String("v"), DTAG_I64))
    return OwnedPointer(UdfData(kind, String("u"), in_cols^, out_cols^, 1, 1))


def _v_greater_than_zero() -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int64(0)))


def _v_only() -> ExprArray:
    var out = ExprArray()
    out.append(Expr.col_ref("v"))
    return out^


def test_a_node_that_carries_a_udf_is_refused_and_its_plain_form_is_cut() raises:
    var udf_filter = LogicalPlan.filter_with_udf(
        _v_greater_than_zero(), _scan(), _udf(UDF_KIND_FILTER)
    )
    _refused_with(_message(udf_filter, _inputs()), LOWERING_UNCUTTABLE_NODE, "a filter with a UDF")
    assert_equal(_message(LogicalPlan.filter(_v_greater_than_zero(), _scan()), _inputs()), "")

    var udf_project = LogicalPlan.project_with_udf(_v_only(), _scan(), _udf(UDF_KIND_MAP))
    _refused_with(_message(udf_project, _inputs()), LOWERING_UNCUTTABLE_NODE, "a projection with a UDF")
    assert_equal(_message(LogicalPlan.project(_v_only(), _scan()), _inputs()), "")

    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    var udf_agg = LogicalPlan.aggregate_with_udf(
        ExprArray(), aggs^, _scan(), _udf(UDF_KIND_AGG)
    )
    _refused_with(_message(udf_agg, _inputs()), LOWERING_UNCUTTABLE_NODE, "an aggregation with a UDF")
    assert_equal(_message(_count_by(_scan(), List[String]()), _inputs()), "")


def test_a_udf_aggregate_function_is_refused_and_a_builtin_one_is_cut() raises:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_UDF, Optional[Expr](Expr.col_ref("v")), Optional[String]("u")))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    _refused_with(_message(plan, _inputs()), LOWERING_UNCUTTABLE_NODE, "a UDF aggregate function")
    assert_equal(_message(_count_by(_scan(), List[String]()), _inputs()), "")


def test_a_group_top_k_aggregate_is_refused_and_the_same_aggregate_without_it_is_cut() raises:
    var plain = _count_by(_scan(), _names("k"))
    assert_equal(_message(plain, _inputs()), "")
    var annotated = _count_by(_scan(), _names("k"))
    annotated._aggregate.value()[].group_topk = Optional(
        AggGroupTopK(_names("n"), _bools(True), 3)
    )
    _refused_with(_message(annotated, _inputs()), LOWERING_UNCUTTABLE_NODE, "a group top-k")


def test_a_final_aggregate_is_refused_and_a_single_one_is_cut() raises:
    _refused_with(_message(_count_by(_scan(), List[String](), AGG_MODE_FINAL), _inputs()), LOWERING_UNCUTTABLE_NODE, "a partial or final aggregation")
    assert_equal(_message(_count_by(_scan(), List[String](), AGG_MODE_UNSET), _inputs()), "")


def test_a_window_and_an_exchange_are_refused() raises:
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    var window = LogicalPlan.partition_by(
        _names("k"), _names("v"), _bools(False), exprs^, _scan()
    )
    _refused_with(_message(window, _inputs()), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_PARTITION_BY))

    var exchange = LogicalPlan.exchange(_scan(), EXCHANGE_KIND_GATHER)
    _refused_with(_message(exchange, _inputs()), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_EXCHANGE))
    assert_equal(_message(_scan(), _inputs()), "")


def _sorted_scan() -> LogicalPlan:
    return LogicalPlan.sort(_names("k"), _bools(False), _scan())


def test_a_limit_over_a_sorted_stream_is_refused_and_other_shapes_over_a_sort_are_cut() raises:
    _refused_with(_message(LogicalPlan.limit(5, _sorted_scan()), _inputs()), LOWERING_UNCUTTABLE_NODE, "a limit over a sorted stream")
    # Operators between the sort and the limit keep the stream sorted.
    var filtered = LogicalPlan.filter(_v_greater_than_zero(), _sorted_scan())
    _refused_with(_message(LogicalPlan.limit(5, filtered^), _inputs()), LOWERING_UNCUTTABLE_NODE, "a limit over a sorted stream")
    var projected = LogicalPlan.project(_v_only(), _sorted_scan())
    _refused_with(_message(LogicalPlan.limit(5, projected^), _inputs()), LOWERING_UNCUTTABLE_NODE, "a limit over a sorted stream")
    # A filter over a sort, a sort alone, and a limit below a sort are cut.
    assert_equal(_message(LogicalPlan.filter(_v_greater_than_zero(), _sorted_scan()), _inputs()), "")
    assert_equal(_message(_sorted_scan(), _inputs()), "")
    assert_equal(_message(LogicalPlan.sort(_names("k"), _bools(False), LogicalPlan.limit(5, _scan())), _inputs()), "")
    # An aggregation over a sort ends the sorted stream: a limit above it is cut.
    var counted = _count_by(_sorted_scan(), List[String]())
    assert_equal(_message(LogicalPlan.limit(5, counted^), _inputs()), "")


def test_an_unbounded_scan_is_refused_and_a_bounded_one_is_cut() raises:
    var unbounded = LogicalPlan.scan_from_source(
        SourceVariant(ParquetSource(String("a.parquet"), _schema())),
        _schema(),
        None,
        None,
        None,
        None,
        SOURCE_KIND_UNSET,
        SCAN_UNBOUNDED,
    )
    _refused_with(_message(unbounded, _inputs()), LOWERING_SCAN_NOT_TOTAL, "unbounded")
    assert_equal(_message(_parquet_scan(ParquetSource(String("a.parquet"), _schema())), _inputs()), "")


def test_a_parquet_scan_with_a_partition_predicate_is_refused() raises:
    var source = ParquetSource(String("a.parquet"), _schema())
    source.hive_predicate = Optional(PartitionPredicatePod.empty())
    _refused_with(_message(_parquet_scan(source^), _inputs()), LOWERING_SCAN_NOT_TOTAL, "lazily")
    assert_equal(_message(_parquet_scan(ParquetSource(String("a.parquet"), _schema())), _inputs()), "")


def test_inputs_must_hold_one_entry_per_scan() raises:
    _refused_with(_message(_scan(), _inputs(0)), LOWERING_INPUTS_SCAN_COUNT, "more than 0")
    _refused_with(_message(_scan(), _inputs(2)), LOWERING_INPUTS_SCAN_COUNT, "1 scans and the inputs hold 2")
    assert_equal(_message(_scan(), _inputs(1)), "")


def test_the_refusal_tokens_are_four_distinct_names() raises:
    var tokens = List[String]()
    tokens.append(String(LOWERING_UNCUTTABLE_NODE))
    tokens.append(String(LOWERING_SINK_UNSERVED))
    tokens.append(String(LOWERING_SCAN_NOT_TOTAL))
    tokens.append(String(LOWERING_INPUTS_SCAN_COUNT))
    for i in range(len(tokens)):
        for j in range(i + 1, len(tokens)):
            assert_true(tokens[i] != tokens[j])
        assert_true(tokens[i].startswith("LOWERING_"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

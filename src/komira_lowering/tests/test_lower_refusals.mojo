# =============================================================================
# test_lower_refusals: what lowering refuses, by name, and what it does not
# =============================================================================
#
# Every refusal token is raised by the plan that should raise it and by no
# other: each case checks the exact token that starts the message and the text
# that says why, and a neighbouring plan that differs only in the refused
# detail lowers. A refused plan never produces a LoweredPlan.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_host_profile.host_profile import reference_host_profile
from komira_lowering.lower import lower
from komira_lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_UNCUTTABLE_NODE,
    LOWERING_SINK_UNSERVED,
    LOWERING_SCAN_NOT_TOTAL,
    LOWERING_INPUTS_SCAN_COUNT,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod, FS_SCHEME_S3
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    SOURCE_CSV,
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
    plan_tag_name,
)
from komira_plan_ir.plan_decisions import AGG_MODE_PARTIAL, AGG_MODE_SINGLE, AGG_MODE_UNSET
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant


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

    var distinct = LogicalPlan.distinct(None, _scan())
    _refused_with(_message(distinct, _inputs()), LOWERING_UNCUTTABLE_NODE, plan_tag_name(PLAN_DISTINCT))

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
    var two = List[String]()
    two.append("a.parquet")
    two.append("b.parquet")
    var multi = _parquet_scan(
        ParquetSource.partitioned(two^, _schema(), List[Field](), List[List[String]]())
    )
    _refused_with(_message(multi, _inputs()), LOWERING_SCAN_NOT_TOTAL, "2 files")

    var one = List[String]()
    one.append("a.parquet")
    var cols = List[Field]()
    cols.append(Field("dt", ArrowType.STRING, False))
    var values = List[List[String]]()
    values.append(_names("2026-10-01"))
    var hive = _parquet_scan(ParquetSource.partitioned(one^, _schema(), cols^, values^))
    _refused_with(_message(hive, _inputs()), LOWERING_SCAN_NOT_TOTAL, "Hive")

    var remote = _parquet_scan(
        ParquetSource(String("a.parquet"), _schema()).with_fs_descriptor(
            FsDescriptorPod.cloud(FS_SCHEME_S3, String("bucket"), 3)
        )
    )
    _refused_with(_message(remote, _inputs()), LOWERING_SCAN_NOT_TOTAL, "local")

    # One local file lowers.
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

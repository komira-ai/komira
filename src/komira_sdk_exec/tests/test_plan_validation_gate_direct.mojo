# =============================================================================
# The plan-validation gate and the glob-options mapping, driven directly.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * an entry token that is not a row of the route ledger raises
#     PLAN_VALIDATION_UNREGISTERED_ENTRY, and the ledger's "unit-test" token is
#     accepted (a ledger check that stops refusing, or refuses the harness);
#   * a SCAN plan is VALIDATED and ran (a gate that declines every plan);
#   * a UNION under the RIGHT child of a JOIN is NOT_VALIDATED, names
#     PLAN_UNION, and did not run; the same under the LEFT child (a scan that
#     stops at the left child and reports a clean walk);
#   * a FILTER on a column the scan lacks is FAILED with the validator's detail
#     (a failure reported as VALIDATED); `validate_plan_at_entry` raises on it
#     and on nothing else (a dropped raise, or a raise on a skipped plan);
#   * `plan_tag_name` returns the tag's own name for each of the 16 plan tags
#     (two arms swapped) and a placeholder for an unlisted tag;
#   * `to_glob_options` carries `allow_empty_glob` True and False through
#     (a hard-coded value);
#   * the validate switch is a parameter and defaults off.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_fs.file_discovery import GlobDiscoveryOptions
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    JOIN_INNER,
    SOURCE_PARQUET,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
)
from komira_sdk.parquet_read_options import ParquetReadOptions

from komira_sdk_exec.parquet_glob_options import to_glob_options
from komira_sdk_exec.plan_validation_gate import (
    PV_STATUS_FAILED,
    PV_STATUS_NOT_VALIDATED,
    PV_STATUS_VALIDATED,
    plan_tag_name,
    plan_validation_enabled,
    plan_validation_outcome,
    validate_plan_at_entry,
)
from komira_sdk_exec.plan_validation_routes import PV_ENTRY_TEST_HARNESS


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())


def _keys(a: String) -> List[String]:
    var k = List[String]()
    k.append(a)
    return k^


def _union() -> LogicalPlan:
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_scan()))
    kids.append(OwnedPointer(_scan()))
    return LogicalPlan.union(kids^, _schema())


def _join(var left: LogicalPlan, var right: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(
        left^, right^, _keys("a"), _keys("a"), JOIN_INNER
    )


def _filter_on_missing_column() -> LogicalPlan:
    return LogicalPlan.filter(col("nope") > 0, _scan())


def test_the_entry_must_be_a_ledger_row() raises:
    with assert_raises(contains="PLAN_VALIDATION_UNREGISTERED_ENTRY"):
        _ = plan_validation_outcome(_scan(), "no-such-entry")
    var ok = plan_validation_outcome(_scan(), PV_ENTRY_TEST_HARNESS)
    assert_true(ok.validated())
    assert_equal(ok.entry, "unit-test")


def test_a_scan_validates() raises:
    var o = plan_validation_outcome(_scan(), PV_ENTRY_TEST_HARNESS)
    assert_equal(Int(o.status), Int(PV_STATUS_VALIDATED))
    assert_true(o.validated())
    assert_true(o.ran_at_all())
    assert_equal(o.unmodeled_tag, -1)


def test_a_union_under_a_join_is_not_validated() raises:
    var right = plan_validation_outcome(
        _join(_scan(), _union()), PV_ENTRY_TEST_HARNESS
    )
    assert_equal(Int(right.status), Int(PV_STATUS_NOT_VALIDATED))
    assert_equal(right.unmodeled_tag, Int(PLAN_UNION))
    assert_true(right.message.find("PLAN_UNION") != -1)
    assert_false(right.ran_at_all())
    assert_false(right.validated())

    var left = plan_validation_outcome(
        _join(_union(), _scan()), PV_ENTRY_TEST_HARNESS
    )
    assert_equal(Int(left.status), Int(PV_STATUS_NOT_VALIDATED))
    assert_equal(left.unmodeled_tag, Int(PLAN_UNION))
    assert_false(left.ran_at_all())


def test_a_missing_column_fails_and_only_a_failure_raises() raises:
    var o = plan_validation_outcome(
        _filter_on_missing_column(), PV_ENTRY_TEST_HARNESS
    )
    assert_equal(Int(o.status), Int(PV_STATUS_FAILED))
    assert_true(o.ran_at_all())
    assert_false(o.validated())
    assert_true(o.detail.find("column 'nope' not found. Available: [a, b]") != -1)
    assert_true(o.message.find("FAILED") != -1)

    with assert_raises(contains="column 'nope' not found"):
        validate_plan_at_entry(_filter_on_missing_column(), PV_ENTRY_TEST_HARNESS)

    # A skipped plan and a clean plan do not raise.
    validate_plan_at_entry(_join(_scan(), _union()), PV_ENTRY_TEST_HARNESS)
    validate_plan_at_entry(_scan(), PV_ENTRY_TEST_HARNESS)


def _expect_name(tag: UInt8, want: String) raises:
    assert_equal(plan_tag_name(tag), want)


def test_plan_tag_name_for_each_tag() raises:
    _expect_name(PLAN_SCAN, "PLAN_SCAN")
    _expect_name(PLAN_FILTER, "PLAN_FILTER")
    _expect_name(PLAN_PROJECT, "PLAN_PROJECT")
    _expect_name(PLAN_AGGREGATE, "PLAN_AGGREGATE")
    _expect_name(PLAN_JOIN, "PLAN_JOIN")
    _expect_name(PLAN_SORT, "PLAN_SORT")
    _expect_name(PLAN_LIMIT, "PLAN_LIMIT")
    _expect_name(PLAN_DISTINCT, "PLAN_DISTINCT")
    _expect_name(PLAN_TOPN, "PLAN_TOPN")
    _expect_name(PLAN_PARTITION_BY, "PLAN_PARTITION_BY")
    _expect_name(PLAN_PARTITION_TOPN, "PLAN_PARTITION_TOPN")
    _expect_name(PLAN_ASOF_JOIN, "PLAN_ASOF_JOIN")
    _expect_name(PLAN_UNION, "PLAN_UNION")
    _expect_name(PLAN_VIEW_REF, "PLAN_VIEW_REF")
    _expect_name(PLAN_CSE_REF, "PLAN_CSE_REF")
    _expect_name(PLAN_CAST_TO_VARCHAR, "PLAN_CAST_TO_VARCHAR")
    _expect_name(UInt8(200), "<unnamed plan tag 200>")


def test_to_glob_options_carries_allow_empty_glob() raises:
    var strict = ParquetReadOptions(False, False, False)
    var lax = ParquetReadOptions(False, True, False)
    assert_false(to_glob_options(strict).allow_empty_glob)
    assert_true(to_glob_options(lax).allow_empty_glob)


def test_the_validate_switch_is_a_parameter_defaulting_off() raises:
    assert_false(plan_validation_enabled())
    assert_false(plan_validation_enabled(False))
    assert_true(plan_validation_enabled(True))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

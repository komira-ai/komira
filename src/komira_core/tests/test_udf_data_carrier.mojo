# =============================================================================
# test_udf_data_carrier.mojo — the UdfData IR carrier
# =============================================================================
#
# Validates the `UdfData` IR carrier on FilterData / ProjectData /
# AggregateData (LogicalPlan node payloads): an
# `Optional[OwnedPointer[UdfData]]` field with matching factory methods
# (`filter_with_udf` / `project_with_udf` / `aggregate_with_udf`) on
# `LogicalPlan` and a top-level `has_udf()` / `udf_method_kind()` predicate
# pair, which row-mode execution uses to detect UDF presence.
#
# What this validates:
#   1. `LogicalPlan.filter_with_udf(predicate, child, udf)` produces a Filter
#      node where `has_udf() == True` and `udf_method_kind() == UDF_KIND_FILTER`.
#   2. `LogicalPlan.project_with_udf(...)` and `.aggregate_with_udf(...)`
#      mirror the same shape with `UDF_KIND_MAP` / `UDF_KIND_AGG`.
#   3. `has_udf()` is False on the ordinary Expr-only path (filter/project/
#      aggregate without `_with_udf`).
#   4. `udf_method_kind()` returns 255 (DTAG_UNKNOWN sentinel) when
#      `has_udf()` is False or the node is non-FILTER/PROJECT/AGGREGATE.
#   5. `plan.copy()` preserves the UdfData payload (deep clone via
#      FilterData/ProjectData/AggregateData.copy).
#   6. `str(plan)` (write_to) renders the UDF when present — the text feeds
#      `LogicalPlan.structural_hash` so the UDF identity participates in
#      plan dedup automatically.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.schema import SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray, AggExprArray,
    PLAN_FILTER, PLAN_PROJECT, PLAN_AGGREGATE, PLAN_SCAN,
)
from komira_core.plan.expr import Expr
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.udf_data import (
    UdfData,
    UDF_KIND_MAP, UDF_KIND_FILTER, UDF_KIND_AGG,
    UDF_NULL_PROPAGATE,
    UDF_STABILITY_IMMUTABLE,
    UDF_PAR_STATELESS, UDF_PAR_MERGEABLE,
    DTAG_I64, DTAG_BOOL, DTAG_F64,
)
from komira_core_ffi.posix import _read_env


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# A test may be executed by more than one build action at a time, on one
# worker, without a sandbox. A fixed `/tmp` path is shared by every one of
# those executions. `TEST_TMPDIR` is unique per test action, which is what
# makes them disjoint.
#
# ⚠ `_read_env`, NOT `std.os.getenv` — Mojo's MLIR FFI legalization allows at
# most ONE `getenv` declaration per link unit and `komira_core_ffi.posix` is
# the canonical one.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        return String("/tmp")
    return d


# Helper: build a 2-column dummy parquet scan (a, b: i64). The on-disk path
# is never opened — these tests only exercise the plan-IR layer.
def _scan_two_i64_cols() raises -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    var schema = sb.build()
    return LogicalPlan.scan(
        (_scratch_dir() + String("/test_udf_data_carrier.parquet")),
        0,  # SOURCE_PARQUET
        schema^,
        Optional[List[String]](None),
        Optional[Expr](None),
        Optional[Int](None),
    )


# Helper: build a FILTER UdfData snapshot for col "a" (I64).
def _filter_udf_data(name: String, factory_id: UInt32, salt: UInt32) -> OwnedPointer[UdfData]:
    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append(("a", DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append((name + "_pred", DTAG_BOOL))
    return OwnedPointer(UdfData(
        kind=UDF_KIND_FILTER,
        name=name,
        input_columns=in_cols^,
        output_columns=out_cols^,
        operator_factory_id=factory_id,
        call_site_salt=salt,
        null_mode=UDF_NULL_PROPAGATE,
        stability=UDF_STABILITY_IMMUTABLE,
        parallelism_tag=UDF_PAR_STATELESS,
    ))


def _map_udf_data(name: String, factory_id: UInt32, salt: UInt32) -> OwnedPointer[UdfData]:
    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append(("a", DTAG_I64))
    in_cols.append(("b", DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append(("r", DTAG_F64))
    return OwnedPointer(UdfData(
        kind=UDF_KIND_MAP,
        name=name,
        input_columns=in_cols^,
        output_columns=out_cols^,
        operator_factory_id=factory_id,
        call_site_salt=salt,
        null_mode=UDF_NULL_PROPAGATE,
        stability=UDF_STABILITY_IMMUTABLE,
        parallelism_tag=UDF_PAR_STATELESS,
    ))


def _agg_udf_data(name: String, factory_id: UInt32, salt: UInt32) -> OwnedPointer[UdfData]:
    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append(("b", DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append(("agg_out", DTAG_F64))
    return OwnedPointer(UdfData(
        kind=UDF_KIND_AGG,
        name=name,
        input_columns=in_cols^,
        output_columns=out_cols^,
        operator_factory_id=factory_id,
        call_site_salt=salt,
        null_mode=UDF_NULL_PROPAGATE,
        stability=UDF_STABILITY_IMMUTABLE,
        parallelism_tag=UDF_PAR_MERGEABLE,
    ))


# =============================================================================
# 1. filter_with_udf produces a Filter node carrying UdfData; has_udf() True.
# =============================================================================
def test_filter_with_udf_round_trip() raises:
    var child = _scan_two_i64_cols()
    var udf = _filter_udf_data("AdultFilter", UInt32(7001), UInt32(0))
    # Placeholder true predicate — operator-build driver routes through UDF.
    var pred = Expr.literal(ScalarValue.from_bool(True))
    var plan = LogicalPlan.filter_with_udf(pred^, child^, udf^)
    assert_true(plan.is_filter())
    assert_true(plan.has_udf())
    assert_equal(plan.udf_method_kind(), UDF_KIND_FILTER)
    # FilterData.has_udf direct accessor.
    assert_true(plan.filter_data_ref().has_udf())


# =============================================================================
# 2. project_with_udf produces a Project node carrying UdfData; UDF_KIND_MAP.
# =============================================================================
def test_project_with_udf_round_trip() raises:
    var child = _scan_two_i64_cols()
    var udf = _map_udf_data("MyMap", UInt32(7002), UInt32(0))
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    var plan = LogicalPlan.project_with_udf(exprs^, child^, udf^)
    assert_true(plan.is_project())
    assert_true(plan.has_udf())
    assert_equal(plan.udf_method_kind(), UDF_KIND_MAP)
    assert_true(plan.project_data_ref().has_udf())


# =============================================================================
# 3. aggregate_with_udf produces an Aggregate node carrying UdfData;
#    output schema includes the UDF's output columns.
# =============================================================================
def test_aggregate_with_udf_round_trip() raises:
    var child = _scan_two_i64_cols()
    var udf = _agg_udf_data("MyAgg", UInt32(7003), UInt32(0))
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("a")))
    var aggs = AggExprArray()
    var plan = LogicalPlan.aggregate_with_udf(gb^, aggs^, child^, udf^)
    assert_true(plan.is_aggregate())
    assert_true(plan.has_udf())
    assert_equal(plan.udf_method_kind(), UDF_KIND_AGG)
    assert_true(plan.aggregate_data_ref().has_udf())
    # Output schema includes group_by col "a" + UDF output col "agg_out".
    assert_equal(plan.output_schema.num_columns(), 2)
    assert_equal(plan.output_schema.field_name(0), String("a"))
    assert_equal(plan.output_schema.field_name(1), String("agg_out"))


# =============================================================================
# 4. has_udf() / udf_method_kind() on the ordinary (non-UDF) path are False.
# =============================================================================
def test_ordinary_filter_has_no_udf() raises:
    var child = _scan_two_i64_cols()
    var pred = Expr.literal(ScalarValue.from_bool(True))
    var plan = LogicalPlan.filter(pred^, child^)
    assert_true(plan.is_filter())
    assert_false(plan.has_udf())
    assert_equal(plan.udf_method_kind(), UInt8(255))


def test_ordinary_project_has_no_udf() raises:
    var child = _scan_two_i64_cols()
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("a")))
    var plan = LogicalPlan.project(exprs^, child^)
    assert_true(plan.is_project())
    assert_false(plan.has_udf())
    assert_equal(plan.udf_method_kind(), UInt8(255))


def test_scan_has_no_udf() raises:
    var plan = _scan_two_i64_cols()
    assert_true(plan.is_scan())
    assert_false(plan.has_udf())
    assert_equal(plan.udf_method_kind(), UInt8(255))


# =============================================================================
# 5. plan.copy() preserves the UDF payload.
# =============================================================================
def test_copy_preserves_udf() raises:
    var child = _scan_two_i64_cols()
    var udf = _filter_udf_data("AdultFilter", UInt32(7001), UInt32(3))
    var pred = Expr.literal(ScalarValue.from_bool(True))
    var plan = LogicalPlan.filter_with_udf(pred^, child^, udf^)
    var plan_copy = plan.copy()
    assert_true(plan_copy.has_udf())
    assert_equal(plan_copy.udf_method_kind(), UDF_KIND_FILTER)
    # operator_factory_id + call_site_salt preserved.
    assert_equal(
        plan_copy.filter_data_ref().udf.value()[].operator_factory_id,
        UInt32(7001),
    )
    assert_equal(
        plan_copy.filter_data_ref().udf.value()[].call_site_salt,
        UInt32(3),
    )


# =============================================================================
# 6. write_to renders the UDF when present; structural_hash differs from
#    the no-UDF baseline.
# =============================================================================
def test_write_to_renders_udf() raises:
    var child = _scan_two_i64_cols()
    var udf = _filter_udf_data("AdultFilter", UInt32(7001), UInt32(0))
    var pred = Expr.literal(ScalarValue.from_bool(True))
    var plan_with = LogicalPlan.filter_with_udf(pred^, child^, udf^)
    var s = String(plan_with)
    # The UdfData.write_to renders "udf<FILTER>" — verify it appears in the
    # plan's text. `String.find(needle)` returns -1 on miss.
    assert_true(s.find(String("udf<FILTER>")) >= 0)


def test_structural_hash_differs_when_udf_present() raises:
    var child_a = _scan_two_i64_cols()
    var pred_a = Expr.literal(ScalarValue.from_bool(True))
    var plan_no_udf = LogicalPlan.filter(pred_a^, child_a^)
    var h_no = plan_no_udf.structural_hash()
    var child_b = _scan_two_i64_cols()
    var udf = _filter_udf_data("AdultFilter", UInt32(7001), UInt32(0))
    var pred_b = Expr.literal(ScalarValue.from_bool(True))
    var plan_with_udf = LogicalPlan.filter_with_udf(pred_b^, child_b^, udf^)
    var h_yes = plan_with_udf.structural_hash()
    assert_true(h_no != h_yes)


def test_structural_hash_differs_across_call_site_salt() raises:
    var child_a = _scan_two_i64_cols()
    var udf_a = _filter_udf_data("SameF", UInt32(7001), UInt32(0))
    var pred_a = Expr.literal(ScalarValue.from_bool(True))
    var plan_a = LogicalPlan.filter_with_udf(pred_a^, child_a^, udf_a^)
    var h_a = plan_a.structural_hash()
    var child_b = _scan_two_i64_cols()
    var udf_b = _filter_udf_data("SameF", UInt32(7001), UInt32(1))
    var pred_b = Expr.literal(ScalarValue.from_bool(True))
    var plan_b = LogicalPlan.filter_with_udf(pred_b^, child_b^, udf_b^)
    var h_b = plan_b.structural_hash()
    # S1 — same UDF type at two call sites must hash differently (plan-CSE
    # never shares them).
    assert_true(h_a != h_b)


def main() raises:
    test_filter_with_udf_round_trip()
    test_project_with_udf_round_trip()
    test_aggregate_with_udf_round_trip()
    test_ordinary_filter_has_no_udf()
    test_ordinary_project_has_no_udf()
    test_scan_has_no_udf()
    test_copy_preserves_udf()
    test_write_to_renders_udf()
    test_structural_hash_differs_when_udf_present()
    test_structural_hash_differs_across_call_site_salt()
    print("All tests passed.")

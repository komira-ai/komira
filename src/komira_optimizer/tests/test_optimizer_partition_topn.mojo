# =============================================================================
# Tests for fuse_partition_topn optimizer rule
# =============================================================================
#
# Verifies that Filter(rn <= K) above PartitionBy(RowNumber) is fused into
# a single PartitionTopN node.
# =============================================================================

from std.os import getenv, setenv
from std.testing import assert_equal, assert_true

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_SCAN,
)
from komira_plan_expr.expr import Expr, EXPR_COL_REF, BIN_LE, BIN_LT, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.partition_expr import PartitionExpr, PF_ROW_NUMBER, PF_RANK, PF_SUM
from komira_optimizer.optimizer_partition_topn import fuse_partition_topn
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# The test runner makes `TEST_TMPDIR` a fresh directory for each run, so no
# two executions share it. `test_tmpdir()` raises when it is unset or empty
# instead of falling back to a directory other runs share.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


# =============================================================================
# Helpers
# =============================================================================


def _schema_3col() -> Schema:
    """Create a 3-column schema: a(INT64), b(INT64), c(FLOAT64)."""
    var builder = SchemaBuilder()
    builder.add_field(Field("a", ArrowType.INT64, False))
    builder.add_field(Field("b", ArrowType.INT64, False))
    builder.add_field(Field("c", ArrowType.FLOAT64, False))
    return builder.build()


def _scan_node() raises -> LogicalPlan:
    """Create a dummy scan node."""
    var schema = _schema_3col()
    return LogicalPlan.scan(
        (_scratch_dir() + String("/test.parquet")),
        0,  # SOURCE_PARQUET
        schema^,
        Optional[List[String]](None),
        Optional[Expr](None),
        Optional[Int](None),
    )


def _str_list1(s: String) -> List[String]:
    """Create a single-element List[String]."""
    var l = List[String]()
    l.append(s)
    return l^


def _bool_list1(b: Bool) -> List[Bool]:
    """Create a single-element List[Bool]."""
    var l = List[Bool]()
    l.append(b)
    return l^


def _partition_by_row_number(
    var child: LogicalPlan,
    var partition_keys: List[String],
    var order_keys: List[String],
    var descending: List[Bool],
) raises -> LogicalPlan:
    """Build a PartitionBy(RowNumber) node."""
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    return LogicalPlan.partition_by(
        partition_keys^, order_keys^, descending^, exprs^, child^
    )


def _rn_col_name(plan: LogicalPlan) -> String:
    """Get the row_number column name from a PartitionBy output schema."""
    return plan.output_schema.field_name(plan.output_schema.num_columns() - 1)


# =============================================================================
# Tests
# =============================================================================


def test_basic_lteq() raises:
    """Filter(rn <= 5) above PartitionBy(RowNumber) -> PartitionTopN(limit=5)."""
    var scan = _scan_node()
    var pb = _partition_by_row_number(
        scan^, _str_list1("a"), _str_list1("b"), _bool_list1(True)
    )
    var rn_name = _rn_col_name(pb)

    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rn_name),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(optimized._partition_topn.value()[].k, 5)
    assert_equal(
        optimized._partition_topn.value()[].partition_keys[0], String("a")
    )
    assert_equal(optimized._partition_topn.value()[].descending[0], True)
    print("PASS test_basic_lteq")


def test_lt() raises:
    """Filter(rn < 5) -> PartitionTopN(limit=4)."""
    var scan = _scan_node()
    var pb = _partition_by_row_number(
        scan^, _str_list1("a"), _str_list1("b"), _bool_list1(False)
    )
    var rn_name = _rn_col_name(pb)

    var pred = Expr.binary(
        BIN_LT,
        Expr.col_ref(rn_name),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(optimized._partition_topn.value()[].k, 4)
    print("PASS test_lt")


def test_project_absorbed() raises:
    """Project(drop rn) -> Filter(rn <= 3) -> PartitionBy -> PartitionTopN.

    The Project that was stripping the rn column should be absorbed because
    PartitionTopN output already has the original schema without rn.
    """
    var scan = _scan_node()
    var pb = _partition_by_row_number(
        scan^, _str_list1("a"), _str_list1("b"), _bool_list1(True)
    )
    var rn_name = _rn_col_name(pb)

    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rn_name),
        Expr.literal(ScalarValue.from_int(3)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    # Project that keeps only original columns (a, b, c) -- drops rn.
    from komira_collections.slab import Slab
    var proj_exprs = Slab[Expr]()
    proj_exprs.append(Expr.col_ref(String("a")))
    proj_exprs.append(Expr.col_ref(String("b")))
    proj_exprs.append(Expr.col_ref(String("c")))
    var project = LogicalPlan.project(proj_exprs^, filter_plan^)

    var optimized = fuse_partition_topn(project^)
    # Project should be absorbed; result is PartitionTopN directly.
    assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(optimized._partition_topn.value()[].k, 3)
    print("PASS test_project_absorbed")


def test_rank_fires_post_slot6() raises:
    """Rule DOES fire when PartitionBy has Rank: `_ENABLE_PF_RANK_FUSE`
    is True, so the optimizer fuses RANK plans
    just like ROW_NUMBER plans (with `over_fetch_k = K + EPSILON` for
    tie tolerance).
    """
    var scan = _scan_node()
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.rank())
    var pb = LogicalPlan.partition_by(
        _str_list1("a"), _str_list1("b"), _bool_list1(True), exprs^, scan^
    )
    var rk_name = _rn_col_name(pb)

    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rk_name),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(optimized._partition_topn.value()[].k, 5)
    # Contract: PF_RANK == 1, over_fetch_k = K + 16 (EPSILON).
    assert_equal(Int(optimized._partition_topn.value()[].func), 1)
    assert_equal(optimized._partition_topn.value()[].over_fetch_k, 5 + 16)
    print("PASS test_rank_fires")


def test_no_fire_multi_expr() raises:
    """Rule does NOT fire when PartitionBy has multiple exprs."""
    var scan = _scan_node()
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    exprs.append(PartitionExpr.running_sum(String("c")))
    var pb = LogicalPlan.partition_by(
        _str_list1("a"), _str_list1("b"), _bool_list1(True), exprs^, scan^
    )

    # Use the first expr's column name (row_number's auto-name).
    var rn_name = pb.output_schema.field_name(
        pb.output_schema.num_columns() - 2
    )

    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rn_name),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_multi_expr")


def test_no_fire_wrong_column() raises:
    """Rule does NOT fire when filter references a data column, not rn."""
    var scan = _scan_node()
    var pb = _partition_by_row_number(
        scan^, _str_list1("a"), _str_list1("b"), _bool_list1(True)
    )

    # Filter on "a" instead of rn column.
    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(String("a")),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_wrong_column")


def test_no_fire_wrong_op() raises:
    """Rule does NOT fire when filter op is > (not <= or <)."""
    var scan = _scan_node()
    var pb = _partition_by_row_number(
        scan^, _str_list1("a"), _str_list1("b"), _bool_list1(True)
    )
    var rn_name = _rn_col_name(pb)

    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(rn_name),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_FILTER))
    print("PASS test_no_fire_wrong_op")


def test_output_schema_no_rn_column() raises:
    """PartitionTopN output schema should NOT have the rn column."""
    var scan = _scan_node()
    var pb = _partition_by_row_number(
        scan^, _str_list1("a"), _str_list1("b"), _bool_list1(True)
    )
    var rn_name = _rn_col_name(pb)

    var pred = Expr.binary(
        BIN_LE,
        Expr.col_ref(rn_name),
        Expr.literal(ScalarValue.from_int(3)),
    )
    var filter_plan = LogicalPlan.filter(pred^, pb^)

    var optimized = fuse_partition_topn(filter_plan^)
    assert_equal(Int(optimized.tag), Int(PLAN_PARTITION_TOPN))
    # PartitionTopN output schema = child schema (3 cols), no rn column.
    assert_equal(optimized.output_schema.num_columns(), 3)
    assert_equal(optimized.output_schema.field_name(0), String("a"))
    assert_equal(optimized.output_schema.field_name(1), String("b"))
    assert_equal(optimized.output_schema.field_name(2), String("c"))
    print("PASS test_output_schema_no_rn_column")


def test_scratch_dir_refuses_without_a_test_tmpdir() raises:
    """With TEST_TMPDIR and TMPDIR both empty, `_scratch_dir` raises rather
    than hand back a directory this run does not own. Restores both."""
    var saved_test = getenv("TEST_TMPDIR")
    var saved_tmp = getenv("TMPDIR")
    _ = setenv("TEST_TMPDIR", "", True)
    _ = setenv("TMPDIR", "", True)
    var got = String("")
    var raised = False
    try:
        got = _scratch_dir()
    except:
        raised = True
    _ = setenv("TEST_TMPDIR", saved_test, True)
    _ = setenv("TMPDIR", saved_tmp, True)
    assert_true(raised, "_scratch_dir returned " + got)
    print("PASS test_scratch_dir_refuses_without_a_test_tmpdir")


def main() raises:
    test_basic_lteq()
    test_lt()
    test_project_absorbed()
    test_rank_fires_post_slot6()
    test_no_fire_multi_expr()
    test_no_fire_wrong_column()
    test_no_fire_wrong_op()
    test_output_schema_no_rn_column()
    print("All fuse_partition_topn tests passed")
    test_scratch_dir_refuses_without_a_test_tmpdir()

# =============================================================================
# optimizer_filter: `_split_join_residual_to_side` on a node that is not a join
# =============================================================================
#
# `push_join_residual_to_side` calls `_split_join_residual_to_side` only on a
# PLAN_JOIN, after recursing into its children. The helper's own first gate
# returns any other node unchanged; this test calls the helper directly with a
# Scan and with a Filter so that gate is executed and its answer pinned.
# Defect caught: a helper that reads `plan._join` before checking the tag (the
# Optional is empty on a Scan or Filter, so the read aborts) or that rebuilds a
# non-join node.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_FILTER,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_filter import _split_join_residual_to_side


def _scan() -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.STRING, True))
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())


def test_a_scan_comes_back_unchanged() raises:
    var out = _split_join_residual_to_side(_scan())
    assert_true(out.tag == PLAN_SCAN)
    assert_equal(out.output_schema.num_columns(), 2)
    assert_equal(out.output_schema.field_name(0), "a")
    assert_equal(out.output_schema.field_name(1), "b")


def test_a_filter_comes_back_unchanged() raises:
    var pred = Expr.binary(
        BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(1))
    )
    var out = _split_join_residual_to_side(LogicalPlan.filter(pred^, _scan()))
    assert_true(out.tag == PLAN_FILTER)
    assert_true(out._filter.value()[].child[].tag == PLAN_SCAN)
    assert_equal(out.output_schema.num_columns(), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

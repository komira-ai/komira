# =============================================================================
# Range/date selectivity audit
# =============================================================================
#
# Verification (not modification) tests for the range/date/IS-NULL/AND-of-ranges
# selectivity propagation. The selectivity dispatch
# lives in `optimizer_filter_selectivity._selectivity_of` (BIN_LT/LE/GT/GE →
# DEFAULT_RANGE_SELECTIVITY = 0.3; AND → product, OR →
# inclusion-exclusion). The wiring sites are `optimizer_stats.estimate_cardinality`
# (scan dispatch to compute_selectivity) and `optimizer_reorder._extract_join_chain_inner`
# (leaf JoinRelation cardinality + scale_table_stats_for_selectivity NDV cap).
#
# These tests pin the DuckDB-style behavior so a future refactor can't
# silently regress the range/date defaults. The Q5-shape test in particular
# is load-bearing for Q5 plan-shape stability (Q5's only filter is
# `o_orderdate >= '1994-01-01' AND o_orderdate < '1995-01-01'` =
# AND-of-ranges = 0.3 * 0.3 = 0.09, which narrows orders from 1.5M to 135K).
#
# These tests verify and do not modify: if one fails, the bug is in the
# selectivity code, not in the test.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_expr.expr import Expr
from komira_optimizer.optimizer_filter_selectivity import (
    compute_selectivity,
    DEFAULT_RANGE_SELECTIVITY,
    DEFAULT_IS_NULL_SELECTIVITY,
    DEFAULT_IS_NOT_NULL_SELECTIVITY,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import TableStats


# =============================================================================
# Test 1 — Q5-shape: AND-of-two-ranges = product (0.3 * 0.3 = 0.09)
# =============================================================================
#
# Q5 has `o_orderdate >= '1994-01-01' AND o_orderdate < '1995-01-01'` —
# both children are BIN_GE / BIN_LT → 30% each → AND → 0.09 product.
# Under SF1 orders (1.5M rows), this narrows to ~135K. The wiring path
# is: PLAN_SCAN with filter → estimate_cardinality dispatches to
# compute_selectivity → BIN_AND branches into recursive product →
# `Int(1_500_000 * 0.09)` = 135_000.
#
# This test pins the SELECTIVITY only — the cardinality scale-down of a
# filtered scan is covered by test_optimizer_stats_b5_ceil.mojo.


def test_b2_q5_shape_and_of_two_ranges_is_product() raises:
    """`o_orderdate >= lit AND o_orderdate < lit` → 0.3 * 0.3 = 0.09."""
    var left_p = Expr.binary(
        15,  # BIN_GE
        Expr.col_ref("o_orderdate"),
        Expr.literal(ScalarValue.from_int(19940101)),
    )
    var right_p = Expr.binary(
        12,  # BIN_LT
        Expr.col_ref("o_orderdate"),
        Expr.literal(ScalarValue.from_int(19950101)),
    )
    var pred = Expr.binary(20, left_p^, right_p^)  # BIN_AND
    var stats: Optional[TableStats] = None
    var sel = compute_selectivity(pred, stats)
    # 0.3 * 0.3 = 0.09, with float tolerance.
    assert_true(sel > 0.089 and sel < 0.091)


# =============================================================================
# Test 2 — Range LT / LE / GE: each is DEFAULT_RANGE_SELECTIVITY (0.3)
# =============================================================================
#
# BIN_GT is covered through the cardinality in test_optimizer_stats_b5_ceil.mojo
# and under NOT in Test 5 below. This file pins the three remaining range tags
# (LT / LE / GE) so the rubric is symmetric.


def test_b2_range_lt_is_30pct() raises:
    """`col < lit` → 30% (DuckDB range default)."""
    var pred = Expr.binary(
        12,  # BIN_LT
        Expr.col_ref("col"),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.29 and sel < 0.31)


def test_b2_range_le_is_30pct() raises:
    """`col <= lit` → 30%."""
    var pred = Expr.binary(
        13,  # BIN_LE
        Expr.col_ref("col"),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.29 and sel < 0.31)


def test_b2_range_ge_is_30pct() raises:
    """`col >= lit` → 30%."""
    var pred = Expr.binary(
        15,  # BIN_GE
        Expr.col_ref("col"),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.29 and sel < 0.31)


# =============================================================================
# Test 3 — IS_NULL / IS_NOT_NULL flat defaults
# =============================================================================
#
# IS_NULL = 5%, IS_NOT_NULL = 95% (DuckDB defaults for null-fraction-less
# columns). These tests pin the constants as verification anchors.


def test_b2_is_null_constant_matches() raises:
    """The DEFAULT_IS_NULL_SELECTIVITY constant must be 5%."""
    # Sanity-check on the export. If someone bumps the constant we want
    # this to fail loudly before a downstream regression bites Q5/Q9.
    assert_true(DEFAULT_IS_NULL_SELECTIVITY > 0.049
                and DEFAULT_IS_NULL_SELECTIVITY < 0.051)


def test_b2_is_not_null_constant_matches() raises:
    """The DEFAULT_IS_NOT_NULL_SELECTIVITY constant must be 95%."""
    assert_true(DEFAULT_IS_NOT_NULL_SELECTIVITY > 0.949
                and DEFAULT_IS_NOT_NULL_SELECTIVITY < 0.951)


def test_b2_range_constant_matches() raises:
    """The DEFAULT_RANGE_SELECTIVITY constant must be 30%.

    Load-bearing for Q5: changing this constant breaks Q5 plan-shape.
    """
    assert_true(DEFAULT_RANGE_SELECTIVITY > 0.29
                and DEFAULT_RANGE_SELECTIVITY < 0.31)


# =============================================================================
# Test 4 — AND-of-three-ranges (compound)
# =============================================================================
#
# A 3-way AND of ranges must compose into 0.3 ** 3 = 0.027 (independence
# assumption). This guards against an accidental flat-default fallback
# at the BIN_AND branch.


def test_b2_and_of_three_ranges_is_product_cubed() raises:
    """`(a > 5) AND (b > 5) AND (c > 5)` → 0.3 ** 3 = 0.027."""
    var p1 = Expr.binary(14, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5)))
    var p2 = Expr.binary(14, Expr.col_ref("b"), Expr.literal(ScalarValue.from_int(5)))
    var p3 = Expr.binary(14, Expr.col_ref("c"), Expr.literal(ScalarValue.from_int(5)))
    # Build left-deep ((p1 AND p2) AND p3).
    var p12 = Expr.binary(20, p1^, p2^)  # BIN_AND
    var pred = Expr.binary(20, p12^, p3^)  # BIN_AND
    var sel = compute_selectivity(pred, Optional[TableStats]())
    # 0.3 ** 3 = 0.027. Tolerance widened slightly for compound product.
    assert_true(sel > 0.026 and sel < 0.028)


# =============================================================================
# Test 5 — Range NOT-WRAPPED equals complement (1 - 0.30 = 0.70)
# =============================================================================
#
# A `NOT (col > lit)` predicate must flip the range default. Covers the
# unary-NOT recursion path through the binary BIN_GT branch.


def test_b2_not_range_is_complement() raises:
    """`NOT (col > lit)` → 1 - 0.30 = 0.70."""
    var inner = Expr.binary(14, Expr.col_ref("c"), Expr.literal(ScalarValue.from_int(5)))
    var pred = Expr.unary(0, inner^)  # UN_NOT
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.69 and sel < 0.71)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

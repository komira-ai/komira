# =============================================================================
# LIKE pattern differentiation
# =============================================================================
#
# This replaces the flat 20% LIKE selectivity with pattern-shape-aware
# differentiation matching DuckDB's `relation_statistics_helper.cpp:~165`:
#   `LIKE 'pat%'` (prefix anchored): 10%
#   `LIKE '%pat'` (suffix anchored): 15%
#   `LIKE '%pat%'` (contains)       : 20%  (legacy default, preserved)
#   STR_STARTS_WITH                  : 10%
#   STR_ENDS_WITH                    : 15%
#   STR_CONTAINS                     : 20%
#
# Q9's `p_name LIKE '%green%'` continues at 20% (contains) — this
# does NOT regress Q9. Q5 has no LIKE — unaffected.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_expr.expr import Expr
from komira_optimizer.optimizer_filter_selectivity import (
    compute_selectivity,
    DEFAULT_STRING_PATTERN_SELECTIVITY,
    PREFIX_PATTERN_SELECTIVITY,
    SUFFIX_PATTERN_SELECTIVITY,
)
from komira_plan_stats.table_stats import TableStats

# STR_* tag values (from komira_plan_expr.expr — STR_CONTAINS=0,
# STR_STARTS_WITH=1, STR_ENDS_WITH=2, STR_LIKE=3).
comptime STR_CONTAINS_TAG: UInt8 = 0
comptime STR_STARTS_WITH_TAG: UInt8 = 1
comptime STR_ENDS_WITH_TAG: UInt8 = 2
comptime STR_LIKE_TAG: UInt8 = 3


# =============================================================================
# STR_LIKE pattern-shape classification
# =============================================================================


def test_b3_like_prefix_is_10pct() raises:
    """`col LIKE 'pat%'` (prefix anchored) -> 10% selectivity."""
    var pred = Expr.string_op(STR_LIKE_TAG, Expr.col_ref("c"), "pat%")
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.099 and sel < 0.101)


def test_b3_like_suffix_is_15pct() raises:
    """`col LIKE '%pat'` (suffix anchored) -> 15% selectivity."""
    var pred = Expr.string_op(STR_LIKE_TAG, Expr.col_ref("c"), "%pat")
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.149 and sel < 0.151)


def test_b3_like_contains_is_20pct() raises:
    """`col LIKE '%pat%'` (contains) -> 20% selectivity (legacy default).

    Load-bearing for Q9: `p_name LIKE '%green%'` must continue at 20%
    so part narrows 200K -> 40K. This test pins the Q9 case as a
    regression guard.
    """
    var pred = Expr.string_op(STR_LIKE_TAG, Expr.col_ref("p_name"), "%green%")
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.199 and sel < 0.201)


def test_b3_like_no_wildcards_defaults_to_20pct() raises:
    """`col LIKE 'pat'` (no wildcards) -> 20% fallback (don't under-estimate)."""
    var pred = Expr.string_op(STR_LIKE_TAG, Expr.col_ref("c"), "pat")
    var sel = compute_selectivity(pred, Optional[TableStats]())
    # No anchor signal -> default contains-shape (20%).
    assert_true(sel > 0.199 and sel < 0.201)


def test_b3_like_empty_pattern_defaults_to_20pct() raises:
    """`col LIKE ''` -> 20% fallback (defensive)."""
    var pred = Expr.string_op(STR_LIKE_TAG, Expr.col_ref("c"), "")
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.199 and sel < 0.201)


# =============================================================================
# STR_STARTS_WITH / STR_ENDS_WITH / STR_CONTAINS bind at construction
# =============================================================================


def test_b3_starts_with_is_10pct() raises:
    """`STARTS_WITH(col, 'pat')` -> 10% (prefix shape, regardless of pattern)."""
    var pred = Expr.string_op(STR_STARTS_WITH_TAG, Expr.col_ref("c"), "pat")
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.099 and sel < 0.101)


def test_b3_ends_with_is_15pct() raises:
    """`ENDS_WITH(col, 'pat')` -> 15% (suffix shape)."""
    var pred = Expr.string_op(STR_ENDS_WITH_TAG, Expr.col_ref("c"), "pat")
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.149 and sel < 0.151)


def test_b3_contains_is_20pct() raises:
    """`CONTAINS(col, 'pat')` -> 20% (contains shape)."""
    var pred = Expr.string_op(STR_CONTAINS_TAG, Expr.col_ref("c"), "pat")
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.199 and sel < 0.201)


# =============================================================================
# Constants pinned
# =============================================================================


def test_b3_prefix_constant_matches() raises:
    """PREFIX_PATTERN_SELECTIVITY must be 10%."""
    assert_true(PREFIX_PATTERN_SELECTIVITY > 0.099
                and PREFIX_PATTERN_SELECTIVITY < 0.101)


def test_b3_suffix_constant_matches() raises:
    """SUFFIX_PATTERN_SELECTIVITY must be 15%."""
    assert_true(SUFFIX_PATTERN_SELECTIVITY > 0.149
                and SUFFIX_PATTERN_SELECTIVITY < 0.151)


def test_b3_contains_constant_matches() raises:
    """DEFAULT_STRING_PATTERN_SELECTIVITY (contains) must remain 20%."""
    assert_true(DEFAULT_STRING_PATTERN_SELECTIVITY > 0.199
                and DEFAULT_STRING_PATTERN_SELECTIVITY < 0.201)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

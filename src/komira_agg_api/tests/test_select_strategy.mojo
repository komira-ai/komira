# =============================================================================
# test_select_strategy
# =============================================================================
#
# Asserts `select_strategy(hint, estimated_cardinality, is_sorted)` selects the
# expected aggregation strategy:
#   - S1 is split by cardinality: `STRATEGY_S1_RADIX` (below
#     S1_PARTITIONED_THRESHOLD) vs `STRATEGY_S1_PARTITIONED` (at or above).
#   - S2 is deferred: high-cardinality Adaptive routes to S1_PARTITIONED with a
#     perf warning. Force hints still return S2 verbatim.
# =============================================================================

from std.testing import assert_equal

from komira_agg_api.agg_strategy import (
    select_strategy,
    AGG_HINT_ADAPTIVE,
    AGG_HINT_FORCE_THREAD_LOCAL,
    AGG_HINT_FORCE_GLOBAL_CONCURRENT,
    AGG_HINT_FORCE_SORT_BASED,
    STRATEGY_S1_RADIX,
    STRATEGY_S1_PARTITIONED,
    STRATEGY_S2_CAS_GLOBAL,
    STRATEGY_S3_STREAMING_SORT,
)


# -----------------------------------------------------------------------------
# Force-hint tests
# -----------------------------------------------------------------------------


def test_force_thread_local_low_card() raises:
    """ForceThreadLocal yields the thread-local S1 strategy regardless of est.

    At est >= S1_PARTITIONED_THRESHOLD, S1 splits into S1_PARTITIONED. We test
    the low-card S1 bucket here.
    """
    var d = select_strategy(AGG_HINT_FORCE_THREAD_LOCAL, 100, False)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)


def test_force_thread_local_high_card_v04_split() raises:
    """ForceThreadLocal at >= S1_PARTITIONED_THRESHOLD routes to
    S1_PARTITIONED (the high-card S1 bucket). Threshold = 5M; use 6M to stay
    above the threshold."""
    var d = select_strategy(AGG_HINT_FORCE_THREAD_LOCAL, 6_000_000, True)
    assert_equal(d.strategy, STRATEGY_S1_PARTITIONED)


def test_force_global_concurrent() raises:
    """ForceGlobalConcurrent yields S2 verbatim."""
    var d = select_strategy(AGG_HINT_FORCE_GLOBAL_CONCURRENT, 100, False)
    assert_equal(d.strategy, STRATEGY_S2_CAS_GLOBAL)


def test_force_sort_based() raises:
    """ForceSortBased yields S3 verbatim."""
    var d = select_strategy(AGG_HINT_FORCE_SORT_BASED, 100, False)
    assert_equal(d.strategy, STRATEGY_S3_STREAMING_SORT)


# -----------------------------------------------------------------------------
# Adaptive tests
# -----------------------------------------------------------------------------


def test_adaptive_low_cardinality() raises:
    """adaptive @ 10K → S1_RADIX."""
    var d = select_strategy(AGG_HINT_ADAPTIVE, 10_000, False)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)


def test_adaptive_medium_cardinality_v04_split() raises:
    """At exactly S1_PARTITIONED_THRESHOLD the `>=` boundary routes into
    S1_PARTITIONED; the S1 split exposes the boundary explicitly. Threshold =
    5M; use 5M directly."""
    var d = select_strategy(AGG_HINT_ADAPTIVE, 5_000_000, False)
    assert_equal(d.strategy, STRATEGY_S1_PARTITIONED)


def test_adaptive_just_below_partitioned_threshold() raises:
    """Just below S1_PARTITIONED_THRESHOLD (5M) → S1_RADIX, the thread-local
    strategy for low/mid card."""
    var d = select_strategy(AGG_HINT_ADAPTIVE, 4_999_999, False)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)


def test_adaptive_very_high_cardinality_v04_defer() raises:
    """adaptive @ 20M → S1_PARTITIONED.

    S2 (global concurrent) is deferred, so high-card Adaptive falls through to
    S1_PARTITIONED.
    """
    var d = select_strategy(AGG_HINT_ADAPTIVE, 20_000_000, False)
    assert_equal(d.strategy, STRATEGY_S1_PARTITIONED)


def test_adaptive_1_5m_groups() raises:
    """adaptive @ 1.5M (below 10M S1_THRESHOLD) → S1.

    1.5M < S1_PARTITIONED_THRESHOLD (5M) so we stay on S1_RADIX.
    """
    var d = select_strategy(AGG_HINT_ADAPTIVE, 1_500_000, False)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)


def test_adaptive_sorted_low_cardinality() raises:
    """adaptive @ presorted+5K → S3_STREAMING_SORT."""
    var d = select_strategy(AGG_HINT_ADAPTIVE, 5_000, True)
    assert_equal(d.strategy, STRATEGY_S3_STREAMING_SORT)


def test_adaptive_sorted_high_cardinality() raises:
    """adaptive @ presorted+100K → S1 (above
    S3_SORTED_THRESHOLD=10K, parallel S1 wins)."""
    var d = select_strategy(AGG_HINT_ADAPTIVE, 100_000, True)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)


def test_adaptive_sorted_at_s3_threshold_boundary() raises:
    """At exactly S3_SORTED_THRESHOLD=10_000, `<=` keeps S3 active."""
    var d = select_strategy(AGG_HINT_ADAPTIVE, 10_000, True)
    assert_equal(d.strategy, STRATEGY_S3_STREAMING_SORT)


# -----------------------------------------------------------------------------
# Estimate / sortedness propagation
# -----------------------------------------------------------------------------


def test_decision_propagates_estimate_and_sortedness() raises:
    """The StrategyDecision carries both inputs verbatim — needed by
    downstream sub-table sizing and the StreamingS3 single-worker check.
    """
    var d = select_strategy(AGG_HINT_ADAPTIVE, 12_345, True)
    assert_equal(d.estimated_cardinality, 12_345)
    assert_equal(d.presorted, True)


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    test_force_thread_local_low_card()
    test_force_thread_local_high_card_v04_split()
    test_force_global_concurrent()
    test_force_sort_based()
    test_adaptive_low_cardinality()
    test_adaptive_medium_cardinality_v04_split()
    test_adaptive_just_below_partitioned_threshold()
    test_adaptive_very_high_cardinality_v04_defer()
    test_adaptive_1_5m_groups()
    test_adaptive_sorted_low_cardinality()
    test_adaptive_sorted_high_cardinality()
    test_adaptive_sorted_at_s3_threshold_boundary()
    test_decision_propagates_estimate_and_sortedness()
    print("test_select_strategy: all 13 tests OK")

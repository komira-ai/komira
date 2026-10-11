"""Aggregation strategy selector tests: S1/S2/S3 selector + HLL estimator.

Validates:
  - HLL register width = 12 bits, 4096 registers.
  - S3 only on presorted + <10K + single-worker.
  - S2 deferred (we keep S1 but can detect >10M estimate).
  - HLL large-cardinality estimate is within ~20% of truth.
  - HLL small-cardinality (linear counting) exact for low counts.
"""

from std.testing import assert_equal, assert_true

from komira_agg_api.agg_strategy import (
    STRATEGY_S1_RADIX,
    STRATEGY_S1_MINIMAP,
    STRATEGY_S1_PARTITIONED,
    STRATEGY_S2_CAS_GLOBAL,
    STRATEGY_S3_STREAMING_SORT,
    S1_MAX_CARDINALITY,
    S1_PARTITIONED_THRESHOLD,
    S3_SORTED_THRESHOLD,
    HLL_PRECISION,
    HLL_NUM_REGISTERS,
    HyperLogLog,
    choose_strategy,
    is_s3_eligible,
)


def test_hll_constants() raises:
    assert_equal(HLL_PRECISION, 12)
    assert_equal(HLL_NUM_REGISTERS, 4096)
    assert_equal(1 << HLL_PRECISION, HLL_NUM_REGISTERS)


def _mix(x: UInt64) -> UInt64:
    """Simple avalanche mixer so test-input cardinality maps to hashes with
    decent spread. xorshift-ish — good enough for register-index coverage."""
    var h = x
    h = h ^ (h >> UInt64(33))
    h = h * UInt64(0xFF51AFD7ED558CCD)
    h = h ^ (h >> UInt64(33))
    h = h * UInt64(0xC4CEB9FE1A85EC53)
    h = h ^ (h >> UInt64(33))
    if h == UInt64(0):
        h = UInt64(1)
    return h


def test_hll_small_cardinality_exact() raises:
    """Linear-counting branch: small N should estimate close to N."""
    var hll = HyperLogLog()
    var n = 100
    for i in range(n):
        hll.add(_mix(UInt64(i)))
    var est = hll.estimate()
    # Small-range correction gives near-exact for N << m.
    # Allow +/-10% tolerance.
    assert_true(est >= n * 9 // 10)
    assert_true(est <= n * 11 // 10)


def test_hll_large_cardinality_estimate_within_20pct() raises:
    """Large-range HLL: accuracy ~1.04/sqrt(m) ≈ 1.6% at m=4096, but we
    allow 20% slack for tiny register corner-cases."""
    var hll = HyperLogLog()
    var n = 50_000
    for i in range(n):
        hll.add(_mix(UInt64(i) * UInt64(2654435761)))
    var est = hll.estimate()
    assert_true(est >= n * 80 // 100)
    assert_true(est <= n * 120 // 100)


def test_choose_strategy_s1_default() raises:
    """Mid cardinality, non-presorted -> S1."""
    var d = choose_strategy(100_000, False, 4)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)


def test_choose_strategy_s3_presorted_single_worker_small() raises:
    """Presorted + 1 worker + <10K -> S3."""
    var d = choose_strategy(500, True, 1)
    assert_equal(d.strategy, STRATEGY_S3_STREAMING_SORT)


def test_choose_strategy_s3_downgraded_if_too_many_groups() raises:
    """Presorted + 1 worker but 10K groups: S3 cap is strict < so NOT S3."""
    var d = choose_strategy(S3_SORTED_THRESHOLD, True, 1)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)


def test_choose_strategy_s3_downgraded_if_unsorted() raises:
    """Unsorted input: never S3 even if <10K."""
    var d = choose_strategy(500, False, 1)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)


def test_choose_strategy_s3_downgraded_if_multiworker() raises:
    """S3 is single-worker; multi-worker presorted stays S1."""
    var d = choose_strategy(500, True, 4)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)


def test_choose_strategy_s2_deferred_stays_s1_partitioned() raises:
    """Above S1_MAX_CARDINALITY the selector deliberately stays on S1 (S2 is
    not implemented) and routes through the Partitioned sub-strategy
    (Path 2) — at that cardinality, MiniMap+Abandon is strictly worse."""
    var d = choose_strategy(S1_MAX_CARDINALITY + 1, False, 8)
    assert_equal(d.strategy, STRATEGY_S1_PARTITIONED)
    assert_true(d.estimated_cardinality > S1_MAX_CARDINALITY)


# ---------------------------------------------------------------------------
# S1-MiniMap vs S1-Partitioned crossover tests.
# ---------------------------------------------------------------------------


def test_s1_minimap_alias_of_radix() raises:
    """STRATEGY_S1_MINIMAP is a readability alias — same tag value."""
    assert_equal(Int(STRATEGY_S1_MINIMAP), Int(STRATEGY_S1_RADIX))


def test_choose_strategy_s1_minimap_below_threshold() raises:
    """Estimate just below S1_PARTITIONED_THRESHOLD -> S1_MINIMAP (Path 1)."""
    var d = choose_strategy(S1_PARTITIONED_THRESHOLD - 1, False, 4)
    assert_equal(d.strategy, STRATEGY_S1_MINIMAP)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)  # alias check


def test_choose_strategy_s1_partitioned_at_threshold() raises:
    """Estimate == S1_PARTITIONED_THRESHOLD -> S1_PARTITIONED (Path 2).
    The threshold comparison is >=."""
    var d = choose_strategy(S1_PARTITIONED_THRESHOLD, False, 4)
    assert_equal(d.strategy, STRATEGY_S1_PARTITIONED)


def test_choose_strategy_s1_partitioned_above_threshold() raises:
    """Large cardinality, non-presorted -> S1_PARTITIONED."""
    var d = choose_strategy(6_000_000, False, 4)
    assert_equal(d.strategy, STRATEGY_S1_PARTITIONED)


def test_s1_partitioned_threshold_value() raises:
    """Guard the threshold value. The principled value is 5M."""
    assert_equal(S1_PARTITIONED_THRESHOLD, 5_000_000)


def test_choose_strategy_1m_groups_routes_radix() raises:
    """~1M distinct groups route to S1_RADIX.

    The NDV estimate must merge HLL register state across row groups. Summing
    per-row-group distinct counts over-counts a ~1M-distinct column (49 row
    groups of ~115K) to ~5.68M, which would cross the 5M threshold into
    S1_PARTITIONED and lose the single-hash-table cache locality. With the
    honest ~1M estimate the route is S1_RADIX (single-HT + scatter), the
    structurally-correct path for ~1M-group workloads.
    """
    var d = choose_strategy(1_000_000, False, 4)
    assert_equal(d.strategy, STRATEGY_S1_RADIX)
    assert_true(1_000_000 < S1_PARTITIONED_THRESHOLD)


def test_is_s3_eligible_needs_all_three() raises:
    """True only for presorted AND cardinality < S3_SORTED_THRESHOLD AND one
    worker; dropping any one precondition (or the strict bound) goes red."""
    assert_true(is_s3_eligible(0, True, 1))
    assert_true(is_s3_eligible(S3_SORTED_THRESHOLD - 1, True, 1))
    assert_true(not is_s3_eligible(S3_SORTED_THRESHOLD, True, 1))
    assert_true(not is_s3_eligible(10, False, 1))
    assert_true(not is_s3_eligible(10, True, 2))
    assert_true(not is_s3_eligible(10, True, 0))


def main() raises:
    print("=" * 72)
    print("agg_strategy tests")
    print("=" * 72)

    test_hll_constants()
    print("  PASS test_hll_constants")
    test_hll_small_cardinality_exact()
    print("  PASS test_hll_small_cardinality_exact")
    test_hll_large_cardinality_estimate_within_20pct()
    print("  PASS test_hll_large_cardinality_estimate_within_20pct")
    test_choose_strategy_s1_default()
    print("  PASS test_choose_strategy_s1_default")
    test_choose_strategy_s3_presorted_single_worker_small()
    print("  PASS test_choose_strategy_s3_presorted_single_worker_small")
    test_choose_strategy_s3_downgraded_if_too_many_groups()
    print("  PASS test_choose_strategy_s3_downgraded_if_too_many_groups")
    test_choose_strategy_s3_downgraded_if_unsorted()
    print("  PASS test_choose_strategy_s3_downgraded_if_unsorted")
    test_choose_strategy_s3_downgraded_if_multiworker()
    print("  PASS test_choose_strategy_s3_downgraded_if_multiworker")
    test_choose_strategy_s2_deferred_stays_s1_partitioned()
    print("  PASS test_choose_strategy_s2_deferred_stays_s1_partitioned")
    test_s1_minimap_alias_of_radix()
    print("  PASS test_s1_minimap_alias_of_radix")
    test_choose_strategy_s1_minimap_below_threshold()
    print("  PASS test_choose_strategy_s1_minimap_below_threshold")
    test_choose_strategy_s1_partitioned_at_threshold()
    print("  PASS test_choose_strategy_s1_partitioned_at_threshold")
    test_choose_strategy_s1_partitioned_above_threshold()
    print("  PASS test_choose_strategy_s1_partitioned_above_threshold")
    test_s1_partitioned_threshold_value()
    print("  PASS test_s1_partitioned_threshold_value")
    test_choose_strategy_1m_groups_routes_radix()
    print("  PASS test_choose_strategy_1m_groups_routes_radix")

    test_is_s3_eligible_needs_all_three()
    print("  PASS test_is_s3_eligible_needs_all_three")

    print("")
    print("All agg_strategy tests passed.")

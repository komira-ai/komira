# =============================================================================
# Unit tests for DynamicJoinFilter (bloom-pushdown Phase 3.5)
# =============================================================================
#
# v0.3 spec source: komira-engine/src/morsel_join.rs:434-488 (struct +
# DynamicJoinFilter wiring); 906-976 (build_dynamic_filter helper).
#
# Aggregate of the three tiers:
#   * In-list filter (tier 1, Optional)
#   * Range filter   (tier 2, always present for INT64 single-key)
#   * Bloom filter   (tier 3, always present for total_rows > 0)
#
# Phase 3.5 implements `build_int64_from_list(keys)` which mirrors
# v0.3 `build_dynamic_filter` for the Int64 single-key path (TPC-H Q18 shape).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_morsel.dynamic_join_filter import DynamicJoinFilter


# -----------------------------------------------------------------------------
# Build from a tiny key set -> in-list activated; range tight; bloom present.
# -----------------------------------------------------------------------------
def test_build_tiny_set_activates_in_list() raises:
    var keys = List[Int64]()
    keys.append(1)
    keys.append(2)
    keys.append(3)
    keys.append(2)
    keys.append(1)

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    assert_true(maybe.__bool__())
    var df = maybe.take()
    # In-list should be activated for 3 distinct keys (<=128).
    assert_true(df.has_in_list())
    assert_equal(df.in_list_size(), 3)
    # Range: [1, 3].
    assert_true(df.has_range())
    assert_equal(Int(df.range_min_int64()), 1)
    assert_equal(Int(df.range_max_int64()), 3)
    # Bloom: present.
    assert_true(df.has_bloom())


# -----------------------------------------------------------------------------
# Build from a large key set -> in-list NOT activated (>128 distinct).
# -----------------------------------------------------------------------------
def test_build_large_set_skips_in_list() raises:
    var keys = List[Int64]()
    for i in range(1024):
        keys.append(Int64(i))

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    assert_true(maybe.__bool__())
    var df = maybe.take()
    # In-list rejected at >128 distinct.
    assert_false(df.has_in_list())
    # Range and bloom always present.
    assert_true(df.has_range())
    assert_true(df.has_bloom())
    assert_equal(Int(df.range_min_int64()), 0)
    assert_equal(Int(df.range_max_int64()), 1023)


# -----------------------------------------------------------------------------
# Empty build side -> None (no useful filter).
# v0.3: bloom_filter.rs:912-914 (early-return when total_rows == 0).
# -----------------------------------------------------------------------------
def test_empty_build_returns_none() raises:
    var keys = List[Int64]()
    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    assert_false(maybe.__bool__())


# -----------------------------------------------------------------------------
# Single-row build -> Phase 2.A ConstantFilter activates; InListFilter
# is SKIPPED (mutually exclusive — a 1-element in-list is strictly more
# expensive than the constant tier's scalar compare). Range collapses to
# a degenerate range [42,42] (kept inert; cascade short-circuits at the
# constant tier above it).
#
# Before Phase 2.A, the InListFilter activated at size 1
# and was the cheapest tier. The Phase 2.A ConstantFilter tier replaces
# it for the distinct==1 fast path; see `test_constant_filter.mojo` for
# the activation tests.
# -----------------------------------------------------------------------------
def test_single_row_build() raises:
    var keys = List[Int64]()
    keys.append(42)

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    assert_true(maybe.__bool__())
    var df = maybe.take()
    # Phase 2.A: ConstantFilter active, InListFilter skipped (mutually
    # exclusive).
    assert_true(df.has_constant())
    assert_equal(Int(df.constant_value_int64()), 42)
    assert_false(df.has_in_list())
    # Range still built (degenerate [42, 42] — inert but present).
    assert_true(df.has_range())
    assert_equal(Int(df.range_min_int64()), 42)
    assert_equal(Int(df.range_max_int64()), 42)
    assert_true(df.has_bloom())


# -----------------------------------------------------------------------------
# Probe-side check via the aggregate `might_contain_int64` helper.
# Combines all three tiers AND-style: returns False as soon as any tier
# rejects. (For the Phase 3.5 unit test we only check positive-side
# correctness; the no-false-negative guarantee comes from each tier.)
# -----------------------------------------------------------------------------
def test_might_contain_int64_positive() raises:
    var keys = List[Int64]()
    keys.append(10)
    keys.append(20)
    keys.append(30)

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    var df = maybe.take()
    assert_true(df.might_contain_int64(10))
    assert_true(df.might_contain_int64(20))
    assert_true(df.might_contain_int64(30))


# -----------------------------------------------------------------------------
# Probe rejection: out-of-range fails range tier first (cheapest).
# -----------------------------------------------------------------------------
def test_might_contain_int64_out_of_range() raises:
    var keys = List[Int64]()
    keys.append(10)
    keys.append(20)
    keys.append(30)

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    var df = maybe.take()
    assert_false(df.might_contain_int64(0))    # below range
    assert_false(df.might_contain_int64(100))  # above range


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

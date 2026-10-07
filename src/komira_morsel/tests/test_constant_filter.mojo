# =============================================================================
# Unit tests for ConstantFilter (Phase 2.A — synthesis-memo ConstantFilter tier)
# =============================================================================
#
# DuckDB precedent: `duckdb/src/include/duckdb/planner/filter/
# constant_filter.hpp` (column = constant TableFilter variant). The single-
# distinct-value fast path: when the build side has exactly one distinct
# key, probe rows match iff `probe_key == constant`.
#
# This file is split across two checkpoints:
#   * Checkpoint (a) — ConstantFilter struct in isolation
#       (test_constant_filter_basic_match,
#        test_constant_filter_has_null_rejects_all,
#        test_constant_filter_boundary_values)
#   * Checkpoint (b) — DynamicJoinFilter integration
#       (test_dynamic_join_filter_single_distinct_activates_constant,
#        test_dynamic_join_filter_cascade_constant_first,
#        test_dynamic_join_filter_multi_distinct_skips_constant,
#        test_constant_and_in_list_mutually_exclusive,
#        test_constant_filter_many_repeats)
#
# The DynamicJoinFilter integration tests are added in checkpoint (b)
# alongside the DynamicJoinFilter extension that wires the new
# `_constant: Optional[ConstantFilter]` field + `has_constant` /
# `constant_value_int64` accessors + cascade rewire in
# `might_contain_int64`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_dynamic_filter.constant_filter import ConstantFilter
from komira_morsel.dynamic_join_filter import DynamicJoinFilter


# -----------------------------------------------------------------------------
# (a) Basic positive / negative matches on a single value.
# -----------------------------------------------------------------------------
def test_constant_filter_basic_match() raises:
    var cf = ConstantFilter(Int64(42))
    assert_true(cf.matches_int64(Int64(42)))
    assert_false(cf.matches_int64(Int64(43)))
    assert_false(cf.matches_int64(Int64(0)))
    assert_false(cf.matches_int64(Int64(-1)))
    assert_equal(Int(cf.value_int64()), 42)
    assert_false(cf.has_null())


# -----------------------------------------------------------------------------
# (b) has_null=True rejects everything (SQL: NULL != anything).
# -----------------------------------------------------------------------------
def test_constant_filter_has_null_rejects_all() raises:
    var cf = ConstantFilter(Int64(42), has_null=True)
    assert_false(cf.matches_int64(Int64(42)))   # NULL != 42
    assert_false(cf.matches_int64(Int64(0)))
    assert_false(cf.matches_int64(Int64(-1)))
    assert_true(cf.has_null())


# -----------------------------------------------------------------------------
# (c) Boundary values: Int64 min / max + zero match correctly.
# -----------------------------------------------------------------------------
def test_constant_filter_boundary_values() raises:
    var cf_zero = ConstantFilter(Int64(0))
    assert_true(cf_zero.matches_int64(Int64(0)))
    assert_false(cf_zero.matches_int64(Int64(1)))

    var cf_min = ConstantFilter(Int64.MIN)
    assert_true(cf_min.matches_int64(Int64.MIN))
    assert_false(cf_min.matches_int64(Int64.MIN + 1))

    var cf_max = ConstantFilter(Int64.MAX)
    assert_true(cf_max.matches_int64(Int64.MAX))
    assert_false(cf_max.matches_int64(Int64.MAX - 1))


# -----------------------------------------------------------------------------
# (d) DynamicJoinFilter built from a single-distinct-value build side
#     activates ConstantFilter and SKIPS the InListFilter tier (the
#     two are mutually exclusive — a 1-element in-list is strictly more
#     expensive than a scalar equality compare).
# -----------------------------------------------------------------------------
def test_dynamic_join_filter_single_distinct_activates_constant() raises:
    var keys = List[Int64]()
    keys.append(Int64(7))
    keys.append(Int64(7))
    keys.append(Int64(7))
    keys.append(Int64(7))

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    assert_true(maybe.__bool__())
    var df = maybe.take()
    # ConstantFilter activated for 1 distinct key.
    assert_true(df.has_constant())
    assert_equal(Int(df.constant_value_int64()), 7)
    # InListFilter SKIPPED — redundant against the constant tier.
    assert_false(df.has_in_list())
    # Range collapses to a degenerate range [7,7] — still present, but
    # the cascade short-circuits at the constant tier above it.
    assert_true(df.has_range())
    assert_equal(Int(df.range_min_int64()), 7)
    assert_equal(Int(df.range_max_int64()), 7)


# -----------------------------------------------------------------------------
# (e) DynamicJoinFilter cascade with ConstantFilter active returns the
#     constant's verdict, skipping the in_list / range / bloom checks.
# -----------------------------------------------------------------------------
def test_dynamic_join_filter_cascade_constant_first() raises:
    var keys = List[Int64]()
    keys.append(Int64(99))

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    var df = maybe.take()
    # ConstantFilter SHOULD be active.
    assert_true(df.has_constant())
    # might_contain_int64 cascade: constant tier returns the answer first.
    assert_true(df.might_contain_int64(Int64(99)))
    assert_false(df.might_contain_int64(Int64(98)))
    assert_false(df.might_contain_int64(Int64(100)))
    assert_false(df.might_contain_int64(Int64(0)))


# -----------------------------------------------------------------------------
# (f) Multi-distinct keys (>1) do NOT activate ConstantFilter — they fall
#     through to the existing 3-tier behavior.
# -----------------------------------------------------------------------------
def test_dynamic_join_filter_multi_distinct_skips_constant() raises:
    var keys = List[Int64]()
    keys.append(Int64(1))
    keys.append(Int64(2))
    keys.append(Int64(3))

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    var df = maybe.take()
    # ConstantFilter NOT active.
    assert_false(df.has_constant())
    # InListFilter activates for distinct <= 128.
    assert_true(df.has_in_list())
    assert_equal(df.in_list_size(), 3)


# -----------------------------------------------------------------------------
# (g) Mutually-exclusive invariant: when ConstantFilter is active, the
#     InListFilter tier is absent (this is the cascade ordering contract).
# -----------------------------------------------------------------------------
def test_constant_and_in_list_mutually_exclusive() raises:
    # Distinct == 1 -> ConstantFilter only.
    var keys_one = List[Int64]()
    keys_one.append(Int64(5))
    keys_one.append(Int64(5))
    var maybe_one = DynamicJoinFilter.build_int64_from_list(keys_one)
    var df_one = maybe_one.take()
    assert_true(df_one.has_constant())
    assert_false(df_one.has_in_list())

    # Distinct > 1, <= 128 -> InListFilter only (no constant).
    var keys_two = List[Int64]()
    keys_two.append(Int64(5))
    keys_two.append(Int64(6))
    var maybe_two = DynamicJoinFilter.build_int64_from_list(keys_two)
    var df_two = maybe_two.take()
    assert_false(df_two.has_constant())
    assert_true(df_two.has_in_list())


# -----------------------------------------------------------------------------
# (h) Many repeats of the same value still produce ConstantFilter (the
#     distinct-count == 1 detect must dedup the list).
# -----------------------------------------------------------------------------
def test_constant_filter_many_repeats() raises:
    var keys = List[Int64]()
    for _ in range(1024):
        keys.append(Int64(123))

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    var df = maybe.take()
    assert_true(df.has_constant())
    assert_equal(Int(df.constant_value_int64()), 123)
    assert_true(df.might_contain_int64(Int64(123)))
    assert_false(df.might_contain_int64(Int64(124)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

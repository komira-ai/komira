# =============================================================================
# CB20-DEAD-DYNFILTER — above `DYNAMIC_FILTER_BUILD_CAP`,
# `DynamicJoinFilter.build_int64_from_list` builds NOTHING.
# =============================================================================
#
# ⚠ THE FILENAME IS HISTORICAL. It is kept only so this guard does not churn
# an internal test + the generated `test_areas.bzl` / `_suites/*` (a
# documented multi-agent conflict point). The behaviour it now pins is the
# OPPOSITE of what the name says, and that inversion is the point of the file.
#
# WHAT CHANGED
# ------------
# Q13-OUTER-JOIN-COMPLETENESS-V0.4 Phase A made an above-cap build
# emit a `DynamicJoinFilter` carrying ONLY the RangeFilter tier, explicitly as a
# "producer foundation" whose consumer-side gate was deferred to a Phase B. That
# Phase B never landed. Re-enumerated, EVERY consumer of the range
# tier is unreachable for such an object:
#
#   * `range_ref()`   -> ONE caller (`parquet_source.mojo:3239`), inside
#                        `if apply_tier12:` where `apply_tier12 =
#                        df.has_in_list()` (:3222) — False above the cap.
#   * `in_list_ref()` -> same branch (:3273).
#   * `has_bloom()`   -> `parquet_source.mojo:3302` — False above the cap.
#   * `has_range()` / `range_min_int64()` / `range_max_int64()` -> ZERO
#                        production callers.
#   * `might_contain_int64()` (the aggregate, which DOES consult range) -> only
#                        caller is `dyn_filter_apply.apply_dyn_filter_int64`,
#                        which has ZERO callers repo-wide.
#
# So the range-only object filtered nothing. Worse than inert: installing it
# sets `has_dyn_filter` in the parquet source, forcing late-materialisation and
# disabling four decode fast paths. The arm is deleted; the refusal now happens
# in `dynamic_filter_admits_build` BEFORE the caller materialises a key list
# (on cb20 that list was 18,295,832 elements / 146 MB).
#
# ⭐ WHY THIS FILE IS THE FALSIFIER FOR A BYTE-IDENTICAL MUTANT.
# Reinstating the above-cap arm changes NO query's output — nothing consumed it.
# A row-count or value oracle cannot see the difference. The only observable is
# whether the object EXISTS, which is exactly what T1/T2/T3/T5 assert.
#
# FAILS ON CURRENT CODE (pre-fix): T1/T2/T3/T5 assert `maybe` is None; pre-fix
# `build_int64_from_list` returned Some(range-only) for every one of them.
#
# Tests:
#   T1: 100K keys (above the 65_536 cap) -> None.
#   T2: 1M keys                          -> None.
#   T3: 10M keys                         -> None.
#   T4: 30K keys (below cap) -> UNCHANGED: all applicable tiers still built.
#       Guards the opposite failure — a gate widened until it swallows the
#       builds the filter actually pays for.
#   T5: the exact cap boundary — 65_536 -> Some, 65_537 -> None.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_morsel.dynamic_join_filter import DYNAMIC_FILTER_BUILD_CAP
from komira_morsel.dynamic_join_filter import (
    DynamicJoinFilter,
    dynamic_filter_admits_build,
)


# Synthesize a key list of `n` Int64 values with a known [min, max] and
# >128 distinct values. Pattern: keys[i] = base + (i % cycle), giving
# `cycle` distinct values across `n` rows. Choose `cycle` > 128 to keep
# InListFilter inactive (which is the natural mode for above-cap builds).
def _gen_keys_with_distinct(n: Int, base: Int64, cycle: Int) -> List[Int64]:
    var keys = List[Int64](capacity=n)
    for i in range(n):
        keys.append(base + Int64(i % cycle))
    return keys^


# -----------------------------------------------------------------------------
# T1: 100K keys above the 65_536 cap -> NO filter at all.
# -----------------------------------------------------------------------------
def test_t1_above_cap_100k_builds_nothing() raises:
    # 100K rows, 1024 distinct (> 128 InList threshold), keys in [1, 1024].
    var keys = _gen_keys_with_distinct(100_000, Int64(1), 1024)
    assert_false(dynamic_filter_admits_build(len(keys)))

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)

    # PRE-FIX this was Some(range-only): range present, in_list/bloom/constant
    # all absent. Nothing consumed those, so the ONLY way to see the difference
    # is right here, on the Optional itself.
    assert_false(maybe.__bool__())


# -----------------------------------------------------------------------------
# T2: 1M keys -> None, and no bloom bit-table / no in-list dedup pass is even
# reachable. (At 1M the pre-fix arm still ran the O(n) range min/max scan; the
# gate now refuses before touching the keys.)
# -----------------------------------------------------------------------------
def test_t2_above_cap_1m_builds_nothing() raises:
    var keys = _gen_keys_with_distinct(1_000_000, Int64(10), 2048)
    assert_false(dynamic_filter_admits_build(len(keys)))

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    assert_false(maybe.__bool__())


# -----------------------------------------------------------------------------
# T3: 10M keys -> None. This is cb20's order of magnitude (its build is
# 18,295,832 keys); the pre-fix path copied and scanned every one of them.
# -----------------------------------------------------------------------------
def test_t3_above_cap_10m_builds_nothing() raises:
    var keys = _gen_keys_with_distinct(10_000_000, Int64(100), 4096)
    assert_false(dynamic_filter_admits_build(len(keys)))

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    assert_false(maybe.__bool__())


# -----------------------------------------------------------------------------
# T4: REGRESSION — 30K keys below the cap, every applicable tier still built.
# This is the leg that fails if the gate is widened into the range where the
# filter genuinely pays. Asserts VALUES (the range bounds, the in-list size),
# not merely that something non-None came back.
#
# - In-list: 50 distinct (<=128) -> ACTIVE.
# - Range: present (always) with the exact synthesized bounds.
# - Bloom: present (n > BLOOM_FILTER_THRESHOLD=0).
# - Constant: NOT active (distinct > 1).
# -----------------------------------------------------------------------------
def test_t4_below_cap_30k_all_tiers_unchanged() raises:
    # 30_000 rows, 50 distinct values (well under both the 65_536 cap
    # AND the 128 InListFilter threshold). Keys in [1000, 1049].
    var keys = _gen_keys_with_distinct(30_000, Int64(1000), 50)
    assert_true(dynamic_filter_admits_build(len(keys)))

    var maybe = DynamicJoinFilter.build_int64_from_list(keys)
    assert_true(maybe.__bool__())
    var df = maybe.take()

    # Range: present with expected bounds.
    assert_true(df.has_range())
    assert_equal(Int(df.range_min_int64()), 1000)
    assert_equal(Int(df.range_max_int64()), 1000 + 50 - 1)

    # In-list: ACTIVE (50 distinct <= 128).
    assert_true(df.has_in_list())
    assert_equal(df.in_list_size(), 50)

    # Bloom: present (n > 0 > BLOOM_FILTER_THRESHOLD=0).
    assert_true(df.has_bloom())

    # Constant: NOT active (distinct > 1).
    assert_false(df.has_constant())

    # Membership still exact at the boundaries of the synthesized set.
    assert_true(df.might_contain_int64(1000))
    assert_true(df.might_contain_int64(1049))
    assert_false(df.might_contain_int64(999))
    assert_false(df.might_contain_int64(1050))


# -----------------------------------------------------------------------------
# T5: the boundary is `<= CAP`, inclusive, and one key past it refuses. An
# off-by-one here is invisible in every query's output, so it is pinned
# directly. Also pins the empty-build refusal (n == 0), which shares the gate.
# -----------------------------------------------------------------------------
def test_t5_cap_boundary_is_inclusive() raises:
    assert_equal(DYNAMIC_FILTER_BUILD_CAP, 65_536)

    assert_false(dynamic_filter_admits_build(0))
    assert_true(dynamic_filter_admits_build(1))
    assert_true(dynamic_filter_admits_build(DYNAMIC_FILTER_BUILD_CAP))
    assert_false(dynamic_filter_admits_build(DYNAMIC_FILTER_BUILD_CAP + 1))

    # Exactly at the cap: still built, and the range tier carries the real
    # bounds (256 distinct > 128, so in-list stays inactive here by design).
    var at_cap = _gen_keys_with_distinct(
        DYNAMIC_FILTER_BUILD_CAP, Int64(7), 256
    )
    var maybe_at = DynamicJoinFilter.build_int64_from_list(at_cap)
    assert_true(maybe_at.__bool__())
    var df_at = maybe_at.take()
    assert_equal(Int(df_at.range_min_int64()), 7)
    assert_equal(Int(df_at.range_max_int64()), 7 + 256 - 1)
    assert_false(df_at.has_in_list())
    assert_true(df_at.has_bloom())

    # One key past the cap: nothing.
    var over_cap = _gen_keys_with_distinct(
        DYNAMIC_FILTER_BUILD_CAP + 1, Int64(7), 256
    )
    var maybe_over = DynamicJoinFilter.build_int64_from_list(over_cap)
    assert_false(maybe_over.__bool__())

    # Empty build: nothing (v0.3:912-914), same gate.
    var empty = List[Int64]()
    var maybe_empty = DynamicJoinFilter.build_int64_from_list(empty)
    assert_false(maybe_empty.__bool__())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

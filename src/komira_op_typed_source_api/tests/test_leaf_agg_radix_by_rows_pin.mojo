# =============================================================================
# test_leaf_agg_radix_by_rows_pin.mojo
#
# Pins the leaf aggregation's RADIX-by-rows decision
# (`typed_source._leaf_agg_radix_by_rows_decision`) and its group-cardinality
# decline guard (`_leaf_agg_group_estimate_declines`).
#
# The single-integer-key domain gate cannot fire for a composite-key or a
# filtered leaf (for example `sum(l_quantity) GROUP BY (l_partkey, l_suppkey)`
# under a ship-date filter, about 800k groups). The by-rows gate engages the
# RADIX parallel combine for such a leaf from the footer's total row count.
# These pins hold the decision so that an edit cannot silently drop the
# engagement, and they hold the engaged default, so that turning it off is a
# deliberate, reviewed change.
#
# Rows over-estimate groups, so the rows proxy alone admits a large-row,
# low-cardinality single-key leaf (10 groups over 6M rows), which pays the
# 64-way move-stash for nothing. The decision therefore takes a
# `group_estimate` (-1 when unknown) and declines RADIX when the group count
# is provably low (`0 <= estimate < min_groups`, default 5000, the single-key
# crossover), while -1 stays admitted.
#
# The thresholds are parameters with the shipped defaults; the boundary tests
# pass them explicitly. Nothing here reads or writes the process environment.
#
# Mutants each test was seen to catch (planted one at a time):
#   - the decision ignores `min_rows`          -> test_default_on_boundary_at_threshold
#   - `declines` ignores `min_groups`          -> test_group_estimate_decline_boundary
#   - `total_rows >= min_rows` becomes `>`     -> test_default_on_boundary_at_threshold
#   - `group_estimate >= 0` is dropped         -> test_default_is_engaged_on
#   - the decision drops its `min_groups`      -> test_group_estimate_decline_boundary
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_op_typed_source_api.typed_source import (
    _leaf_agg_radix_by_rows_decision,
    _leaf_agg_radix_min_rows,
    _leaf_agg_radix_min_groups,
    _leaf_agg_group_estimate_declines,
    _LEAF_AGG_RADIX_MIN_ROWS_DEFAULT,
    _UNTYPED_AGG_RADIX_DOMAIN_CROSSOVER,
)

# The group estimate a composite or filtered leaf supplies: the true group
# count is not provable at the leaf, so the caller passes -1 (unknown), which
# the guard must admit.
comptime _UNKNOWN_GROUPS = -1
# A single-integer key whose footer range-domain is 10.
comptime _LOW_CARD_GROUPS = 10
# A high group count; it exercises the admit arm of the group gate.
comptime _HIGH_CARD_GROUPS = 800_000


def test_default_is_engaged_on() raises:
    """With the default thresholds, a 6M-row leaf with an unknown (composite)
    group estimate engages RADIX, and a sub-threshold leaf stays FLAT."""
    assert_true(
        _leaf_agg_radix_by_rows_decision(6_000_000, _UNKNOWN_GROUPS),
        "default -> a 6M-row composite (unknown-groups) leaf engages RADIX",
    )
    assert_false(
        _leaf_agg_radix_by_rows_decision(
            _LEAF_AGG_RADIX_MIN_ROWS_DEFAULT - 1, _UNKNOWN_GROUPS
        ),
        "default -> a sub-threshold leaf stays FLAT (rows proxy intact)",
    )
    assert_equal(
        _leaf_agg_radix_min_rows(),
        _LEAF_AGG_RADIX_MIN_ROWS_DEFAULT,
        "default rows threshold == 500_000 (in sync with the in-memory proxy)",
    )


def test_lowcard_large_rows_declines() raises:
    """A provably low group estimate (10 < 5000) declines RADIX even at 6M
    rows, while an unknown (-1) and a high estimate stay admitted, and the
    group gate never overrides the rows floor."""
    assert_false(
        _leaf_agg_radix_by_rows_decision(6_000_000, _LOW_CARD_GROUPS),
        "6M rows, 10 groups -> DECLINE RADIX (stay FLAT)",
    )
    assert_true(
        _leaf_agg_radix_by_rows_decision(6_000_000, _UNKNOWN_GROUPS),
        "6M rows, unknown groups -> ADMIT RADIX",
    )
    assert_true(
        _leaf_agg_radix_by_rows_decision(6_000_000, _HIGH_CARD_GROUPS),
        "large rows + high (>=5000) group estimate -> ADMIT RADIX",
    )
    assert_false(
        _leaf_agg_radix_by_rows_decision(1000, _HIGH_CARD_GROUPS),
        "sub-threshold rows -> FLAT even with a high group estimate",
    )


def test_group_estimate_decline_boundary() raises:
    """The group-cardinality floor is exact at `_leaf_agg_radix_min_groups()`
    (the default, `_UNTYPED_AGG_RADIX_DOMAIN_CROSSOVER`, 5000): estimate < floor
    declines, estimate == floor admits, -1 admits. A caller-supplied
    `min_groups` moves the floor."""
    var floor = _leaf_agg_radix_min_groups()
    assert_equal(
        floor,
        _UNTYPED_AGG_RADIX_DOMAIN_CROSSOVER,
        "default group floor == the single-key domain crossover (5000)",
    )
    assert_true(
        _leaf_agg_group_estimate_declines(floor - 1),
        "est == floor-1 -> DECLINE (provably low cardinality)",
    )
    assert_false(
        _leaf_agg_group_estimate_declines(floor),
        "est == floor -> ADMIT (>= floor)",
    )
    assert_false(
        _leaf_agg_group_estimate_declines(_UNKNOWN_GROUPS),
        "est == -1 (unknown) -> ADMIT (never decline an unprovable leaf)",
    )
    assert_true(
        _leaf_agg_group_estimate_declines(0),
        "est == 0 -> DECLINE (0 < floor; a 0-group leaf gains nothing)",
    )
    # The default floor declines 10 groups; a floor of 5 admits them.
    assert_true(
        _leaf_agg_group_estimate_declines(_LOW_CARD_GROUPS),
        "default floor -> 10 groups DECLINE",
    )
    assert_false(
        _leaf_agg_group_estimate_declines(_LOW_CARD_GROUPS, min_groups=5),
        "floor lowered to 5 -> 10 groups ADMIT (>= 5)",
    )
    # The decision forwards its `min_groups` to the guard.
    assert_true(
        _leaf_agg_radix_by_rows_decision(
            6_000_000, _LOW_CARD_GROUPS, min_groups=5
        ),
        "decision with floor 5 -> 6M rows, 10 groups ADMIT RADIX",
    )


def test_default_on_boundary_at_threshold() raises:
    """The rows-proxy boundary is exact: with `min_rows=1000`, rows == 1000
    engages (>=) and rows == 999 does not. The group estimate is unknown (-1),
    so only the rows proxy is under test."""
    assert_true(
        _leaf_agg_radix_by_rows_decision(1000, _UNKNOWN_GROUPS, min_rows=1000),
        "rows == threshold -> RADIX",
    )
    assert_true(
        _leaf_agg_radix_by_rows_decision(
            6_000_000, _UNKNOWN_GROUPS, min_rows=1000
        ),
        "6M rows -> RADIX",
    )
    assert_false(
        _leaf_agg_radix_by_rows_decision(999, _UNKNOWN_GROUPS, min_rows=1000),
        "rows == threshold-1 -> FLAT",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_default_is_engaged_on]()
    suite.test[test_lowcard_large_rows_declines]()
    suite.test[test_group_estimate_decline_boundary]()
    suite.test[test_default_on_boundary_at_threshold]()
    suite^.run()

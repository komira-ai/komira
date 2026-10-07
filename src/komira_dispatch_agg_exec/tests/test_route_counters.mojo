"""The two route reachability counters: each counts its own firings, reads
back what it counted, resets to zero, and shares nothing with the other.

The counters are process-global slots keyed by name, so a test that only
increments one could pass with both functions reading one shared slot. The
cross-checks below are what rule that out.
"""

from std.testing import assert_equal

from komira_dispatch_agg_exec.computed_project_agg_route_counter import (
    computed_project_agg_route_fire_count,
    computed_project_agg_route_fire_incr,
    reset_computed_project_agg_route_fire_count,
)
from komira_dispatch_agg_exec.semi_count_only_route_counter import (
    reset_semi_count_only_fire_count,
    semi_count_only_fire_count,
    semi_count_only_fire_incr,
)


def test_each_counter_counts_its_own_firings() raises:
    """Three computed-project firings and one count-only firing read back as
    3 and 1.
    MUTANT: key both `_Global` slots with the same name and each reads 4."""
    reset_computed_project_agg_route_fire_count()
    reset_semi_count_only_fire_count()
    assert_equal(computed_project_agg_route_fire_count(), 0)
    assert_equal(semi_count_only_fire_count(), 0)
    computed_project_agg_route_fire_incr()
    computed_project_agg_route_fire_incr()
    computed_project_agg_route_fire_incr()
    semi_count_only_fire_incr()
    assert_equal(computed_project_agg_route_fire_count(), 3)
    assert_equal(semi_count_only_fire_count(), 1)


def test_reset_clears_only_its_own_counter() raises:
    """Resetting one counter leaves the other's count alone, and a reset
    counter counts up from zero again.
    MUTANT: a reset that stores into the other slot (or a shared slot) turns
    the untouched counter's assertion red."""
    reset_computed_project_agg_route_fire_count()
    reset_semi_count_only_fire_count()
    computed_project_agg_route_fire_incr()
    computed_project_agg_route_fire_incr()
    semi_count_only_fire_incr()
    semi_count_only_fire_incr()
    reset_computed_project_agg_route_fire_count()
    assert_equal(computed_project_agg_route_fire_count(), 0)
    assert_equal(semi_count_only_fire_count(), 2)
    computed_project_agg_route_fire_incr()
    assert_equal(computed_project_agg_route_fire_count(), 1)
    reset_semi_count_only_fire_count()
    assert_equal(semi_count_only_fire_count(), 0)
    assert_equal(computed_project_agg_route_fire_count(), 1)


def test_a_fresh_slot_reads_zero() raises:
    """Run FIRST, before anything has touched either slot: the first read
    creates the slot through its init, which must write the zero, and reading
    does not change the count.
    MUTANT: an init that skips the zero write reads whatever the allocator
    returned; a read that increments reads 1 the second time."""
    assert_equal(computed_project_agg_route_fire_count(), 0)
    assert_equal(computed_project_agg_route_fire_count(), 0)
    assert_equal(semi_count_only_fire_count(), 0)
    assert_equal(semi_count_only_fire_count(), 0)


def main() raises:
    # First: it needs both slots untouched.
    test_a_fresh_slot_reads_zero()
    test_each_counter_counts_its_own_firings()
    test_reset_clears_only_its_own_counter()
    print("All 3 route counter tests passed.")

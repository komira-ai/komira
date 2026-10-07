"""The package's process-global counters: the build-key extraction pair
(`hbs_key_share_counter`), the mark-kernel firing count
(`mark_semi_anti_route_counter`) and the two gather-loop counters
(`join_gather_unrolled`). Each counts its own events, reads back what it
counted, resets where it has a reset, and shares no slot with another.

Every counter is a `_Global` slot keyed by a string, so a test that drives one
counter at a time could pass with two functions reading one shared slot. The
cross-checks below drive several counters by different amounts in one test so
that a shared or swapped slot reads the wrong number.
"""

from std.testing import assert_equal

from komira_dispatch_join_kernels.hbs_key_share_counter import (
    hbs_key_decline_shape_count,
    hbs_key_decline_shape_incr,
    hbs_key_share_count,
    hbs_key_share_incr,
)
from komira_dispatch_join_kernels.join_gather_unrolled import (
    join_gather_rolled_colrows,
    join_gather_unrolled_colrows,
    note_gather_rolled,
    note_gather_unrolled,
    reset_join_gather_counters,
)
from komira_dispatch_join_kernels.mark_semi_anti_route_counter import (
    mark_semi_anti_fire_count,
    mark_semi_anti_fire_incr,
    reset_mark_semi_anti_fire_count,
)


def test_a_fresh_slot_reads_zero() raises:
    """Run FIRST, before anything has touched a slot: the first read creates
    the slot through its init, which must write the zero, and a read does not
    change the count.
    MUTANT: an init that skips the zero write reads whatever the allocator
    returned; a read that also increments reads 1 the second time."""
    for _ in range(2):
        assert_equal(hbs_key_share_count(), 0)
        assert_equal(hbs_key_decline_shape_count(), 0)
        assert_equal(mark_semi_anti_fire_count(), 0)
        assert_equal(join_gather_unrolled_colrows(), 0)
        assert_equal(join_gather_rolled_colrows(), 0)


def test_the_build_key_pair_counts_each_arm_apart() raises:
    """Three SHARE events and two SHAPE declines read back as 3 and 2, and each
    increment adds exactly one.
    MUTANT: both `_Global` keys made equal: each reads 5."""
    var share0 = hbs_key_share_count()
    var shape0 = hbs_key_decline_shape_count()
    hbs_key_share_incr()
    hbs_key_share_incr()
    hbs_key_share_incr()
    hbs_key_decline_shape_incr()
    hbs_key_decline_shape_incr()
    assert_equal(hbs_key_share_count() - share0, 3)
    assert_equal(hbs_key_decline_shape_count() - shape0, 2)


def test_the_mark_counter_counts_and_resets() raises:
    """Four firings read 4; a reset reads 0 and counting restarts from there.
    MUTANT: a reset that stores 1, or stores nothing, reads 1 or 4 after it."""
    reset_mark_semi_anti_fire_count()
    assert_equal(mark_semi_anti_fire_count(), 0)
    for _ in range(4):
        mark_semi_anti_fire_incr()
    assert_equal(mark_semi_anti_fire_count(), 4)
    reset_mark_semi_anti_fire_count()
    assert_equal(mark_semi_anti_fire_count(), 0)
    mark_semi_anti_fire_incr()
    assert_equal(mark_semi_anti_fire_count(), 1)


def test_the_gather_counters_add_column_rows_and_reset_together() raises:
    """The two gather counters add the column-row count they are given (not
    one per call), keep apart, and one reset clears both.
    MUTANT: `fetch_add(Int64(colrows))` changed to `fetch_add(1)` reads 2 and
    1; `reset_join_gather_counters` that skips the rolled slot leaves 7."""
    reset_join_gather_counters()
    note_gather_unrolled(100)
    note_gather_unrolled(23)
    note_gather_rolled(7)
    assert_equal(join_gather_unrolled_colrows(), 123)
    assert_equal(join_gather_rolled_colrows(), 7)
    reset_join_gather_counters()
    assert_equal(join_gather_unrolled_colrows(), 0)
    assert_equal(join_gather_rolled_colrows(), 0)


def test_no_counter_moves_another() raises:
    """Each family's events leave every other family's count alone.
    MUTANT: any two families keyed by one name: the untouched one moves."""
    reset_mark_semi_anti_fire_count()
    reset_join_gather_counters()
    var share0 = hbs_key_share_count()
    var shape0 = hbs_key_decline_shape_count()
    mark_semi_anti_fire_incr()
    note_gather_rolled(5)
    assert_equal(hbs_key_share_count(), share0)
    assert_equal(hbs_key_decline_shape_count(), shape0)
    assert_equal(join_gather_unrolled_colrows(), 0)
    hbs_key_share_incr()
    assert_equal(mark_semi_anti_fire_count(), 1)
    assert_equal(join_gather_rolled_colrows(), 5)
    assert_equal(hbs_key_decline_shape_count(), shape0)


def main() raises:
    # First: it needs every slot untouched.
    test_a_fresh_slot_reads_zero()
    test_the_build_key_pair_counts_each_arm_apart()
    test_the_mark_counter_counts_and_resets()
    test_the_gather_counters_add_column_rows_and_reset_together()
    test_no_counter_moves_another()
    print("All 5 route counter tests passed.")

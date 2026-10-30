# The timers with the define KOMIRA_PHASE_TIMERS=1 (test_defines of the
# `komira_phase_timers_on` target).
#
# What each test proves, and the defect it would catch:
# - test_intervals_sum_and_keep_the_longest: two intervals of 3 and 5 ns on a
#   phase read as sum 8, longest 5, 2 calls, on one lane. Catches a sum that
#   overwrites, a longest that is the last, or a call count that is off.
# - test_a_stamp_is_stored_not_added: two stamps leave the second clock value,
#   not their sum, and no call is counted. Catches a stamp that accumulates.
# - test_wake_and_join_tails_follow_the_fork: after `pt_mark_fork` and a task
#   end stamp, `pt_record_wake` and `pt_record_join_tails` each count one
#   interval. Catches a join tail that counts lanes which did not run in the
#   segment, or a wake measured from nothing.
# - test_reset_zeroes_the_counters_and_keeps_the_lane: after `pt_reset` every
#   counter reads 0 and the thread is still lane 0. Catches a reset that forgets
#   the thread table (the next run would register the same thread twice).
#
# The tests share one process-global slab and run in this order in one
# process; each one resets first.

from std.testing import TestSuite, assert_equal, assert_true

from komira_phase_timers.phase_timers import (
    FIELD_CALLS,
    FIELD_MAX,
    FIELD_SUM,
    PH_COUNT,
    PH_END_STAMP,
    PH_FILTER,
    PH_JOIN_TAIL,
    PH_WAKE,
    pt_enabled,
    pt_get,
    pt_lane_count,
    pt_mark_fork,
    pt_now,
    pt_record_join_tails,
    pt_record_ns,
    pt_record_wake,
    pt_reset,
    pt_stamp,
)


def test_intervals_sum_and_keep_the_longest() raises:
    assert_true(pt_enabled())
    assert_true(pt_now() > 0)
    pt_reset()
    pt_record_ns[PH_FILTER](3)
    pt_record_ns[PH_FILTER](5)
    assert_equal(pt_lane_count(), 1)
    assert_equal(pt_get(0, PH_FILTER, FIELD_SUM), 8)
    assert_equal(pt_get(0, PH_FILTER, FIELD_MAX), 5)
    assert_equal(pt_get(0, PH_FILTER, FIELD_CALLS), 2)


def test_a_stamp_is_stored_not_added() raises:
    pt_reset()
    pt_stamp[PH_END_STAMP]()
    var first = pt_get(0, PH_END_STAMP, FIELD_SUM)
    assert_true(first > 0)
    pt_stamp[PH_END_STAMP]()
    var second = pt_get(0, PH_END_STAMP, FIELD_SUM)
    assert_true(second >= first)
    assert_true(second < 2 * first)
    assert_equal(pt_get(0, PH_END_STAMP, FIELD_CALLS), 0)


def test_wake_and_join_tails_follow_the_fork() raises:
    pt_reset()
    # A stale stamp from before the fork must not count as a task of this one.
    pt_stamp[PH_END_STAMP]()
    pt_mark_fork()
    pt_record_wake()
    assert_equal(pt_get(0, PH_WAKE, FIELD_CALLS), 1)
    pt_record_join_tails()
    assert_equal(pt_get(0, PH_JOIN_TAIL, FIELD_CALLS), 0)
    pt_stamp[PH_END_STAMP]()
    pt_record_join_tails()
    assert_equal(pt_get(0, PH_JOIN_TAIL, FIELD_CALLS), 1)
    assert_true(pt_get(0, PH_JOIN_TAIL, FIELD_SUM) >= 0)


def test_reset_zeroes_the_counters_and_keeps_the_lane() raises:
    pt_record_ns[PH_FILTER](7)
    pt_reset()
    for phase in range(PH_COUNT):
        for field in range(FIELD_CALLS + 1):
            assert_equal(pt_get(0, phase, field), 0)
    assert_equal(pt_lane_count(), 1)
    pt_record_ns[PH_FILTER](2)
    assert_equal(pt_lane_count(), 1)
    assert_equal(pt_get(0, PH_FILTER, FIELD_SUM), 2)


def main() raises:
    var suite = TestSuite()
    suite.test[test_intervals_sum_and_keep_the_longest]()
    suite.test[test_a_stamp_is_stored_not_added]()
    suite.test[test_wake_and_join_tails_follow_the_fork]()
    suite.test[test_reset_zeroes_the_counters_and_keeps_the_lane]()
    suite^.run()

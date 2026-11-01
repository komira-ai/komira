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
# - test_a_lane_is_keyed_by_the_kernel_thread_id: on Linux the first lane's
#   thread id is the calling thread's `gettid`, and a lane that is not in use
#   reads 0. Catches a lane keyed by a value that a later thread can inherit
#   (a `pthread_t` is handed again after its thread ends), which would book a
#   new thread's time to a dead thread's lane and mislabel it for any reader
#   that matches lanes to `/proc/self/task`.
# - test_forgetting_threads_frees_every_lane: after a record, when the lane
#   is dropped with `pt_forget_threads`, no lane is in use and every counter
#   reads 0, and the next record takes lane 0 again. Catches a table that
#   never empties (a long probe would run out of lanes and lose the threads of
#   its later contexts) and counters that outlive their thread.
# - test_thread_usage_counts_this_threads_switches_and_faults: a usage bracket
#   around a sleep and a 32 MiB fill reads at least 1 voluntary context switch
#   and 1 minor fault (counts, never times) on this thread's lane and phase, a
#   second bracket adds to the first, another phase stays 0, and a reset zeroes
#   the usage counters. Catches a bracket that reads the process instead of the
#   thread, one that overwrites instead of adding, one that books to the wrong
#   phase, and a reset that leaves usage behind.
# - test_an_end_without_its_begin_records_nothing_and_is_counted: a usage end
#   with no begin leaves every usage counter 0 and adds 1 to the overflow
#   count; a matched pair is taken without a count; a second end is refused
#   again. Catches an end that subtracts a stale start (the case of a failed
#   begin sample) or one that is dropped without a trace.
# - test_more_threads_than_lanes_are_counted_not_silent: with more thread ids
#   than lanes, the lanes fill to PT_LANES, each dropped record adds one to
#   `pt_overflow_count`, a thread that has a lane still records, and a calling
#   thread without a lane adds one for each of `pt_record_ns`, `pt_stamp`,
#   `pt_ru_begin` and `pt_ru_end` and writes into no lane. `pt_reset` and
#   `pt_forget_threads` clear the count. Catches a silent drop on any record
#   path, a scan past the table, a write into another thread's lane, or a
#   count that is not reset.
#
# The tests share one process-global slab and run in this order in one
# process; each one resets first.

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true
from std.time import sleep

from komira_phase_timers.phase_timers import (
    FIELD_CALLS,
    FIELD_MAX,
    FIELD_RU_END,
    FIELD_RU_MINFLT,
    FIELD_RU_VOL,
    FIELD_SUM,
    PH_COUNT,
    PH_END_STAMP,
    PH_FILTER,
    PH_JOIN_TAIL,
    PH_SINK,
    PH_WAKE,
    PT_LANES,
    pt_enabled,
    pt_get,
    pt_lane_count,
    pt_forget_threads,
    pt_lane_tid,
    pt_mark_fork,
    pt_overflow_count,
    pt_record_ns_as,
    pt_now,
    pt_record_join_tails,
    pt_record_ns,
    pt_record_wake,
    pt_reset,
    pt_ru_available,
    pt_ru_begin,
    pt_ru_end,
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
    var a = pt_now()
    pt_stamp[PH_END_STAMP]()
    var b = pt_now()
    var first = pt_get(0, PH_END_STAMP, FIELD_SUM)
    assert_true(a <= first and first <= b)
    pt_stamp[PH_END_STAMP]()
    var c = pt_now()
    var second = pt_get(0, PH_END_STAMP, FIELD_SUM)
    # The stored value is a clock reading between the two reads around the
    # stamp; a sum of two stamps would lie above the later read.
    assert_true(b <= second and second <= c)
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


def test_thread_usage_counts_this_threads_switches_and_faults() raises:
    # pt_ru_available makes one real getrusage(RUSAGE_THREAD) call. It is
    # False only where the syscall is refused (a filter in a sandbox) or the
    # target is not Linux; there the counters cannot be read and the probe's
    # JSON says so (`thread_usage_available`), so this test has nothing to
    # check and returns.
    if not pt_ru_available():
        return
    pt_reset()
    pt_ru_begin[PH_FILTER]()
    sleep(0.001)
    var buf = List[UInt8](length=32 * 1024 * 1024, fill=1)
    pt_ru_end[PH_FILTER]()
    assert_equal(Int(buf[1000]), 1)
    # Counts, not times: a sleep always blocks (a voluntary switch) and the
    # fill touches fresh pages (minor faults, fewer when pages are huge).
    var vol = pt_get(0, PH_FILTER, FIELD_RU_VOL)
    assert_true(vol >= 1)
    assert_true(pt_get(0, PH_FILTER, FIELD_RU_MINFLT) >= 1)
    pt_ru_begin[PH_FILTER]()
    sleep(0.001)
    pt_ru_end[PH_FILTER]()
    assert_true(pt_get(0, PH_FILTER, FIELD_RU_VOL) >= vol + 1)
    for field in range(FIELD_RU_VOL, FIELD_RU_END):
        assert_equal(pt_get(0, PH_SINK, field), 0)
    pt_reset()
    for field in range(FIELD_RU_VOL, FIELD_RU_END):
        for phase in range(PH_COUNT):
            assert_equal(pt_get(0, phase, field), 0)


def test_a_lane_is_keyed_by_the_kernel_thread_id() raises:
    pt_reset()
    pt_record_ns[PH_FILTER](1)
    comptime if CompilationTarget.is_linux():
        assert_equal(pt_lane_tid(0), Int(external_call["gettid", Int32]()))
    assert_equal(pt_lane_tid(pt_lane_count()), 0)
    assert_equal(pt_lane_tid(-1), 0)


def test_forgetting_threads_frees_every_lane() raises:
    pt_reset()
    pt_record_ns[PH_FILTER](9)
    assert_equal(pt_lane_count(), 1)
    pt_forget_threads()
    assert_equal(pt_lane_count(), 0)
    assert_equal(pt_lane_tid(0), 0)
    for phase in range(PH_COUNT):
        for field in range(FIELD_CALLS + 1):
            assert_equal(pt_get(0, phase, field), 0)
    pt_record_ns[PH_FILTER](4)
    assert_equal(pt_lane_count(), 1)
    assert_equal(pt_get(0, PH_FILTER, FIELD_SUM), 4)


def test_an_end_without_its_begin_records_nothing_and_is_counted() raises:
    if not pt_ru_available():
        return
    pt_reset()
    pt_ru_end[PH_SINK]()
    assert_equal(pt_overflow_count(), 1)
    for field in range(FIELD_RU_VOL, FIELD_RU_END):
        assert_equal(pt_get(0, PH_SINK, field), 0)
    # A matched pair afterwards is taken, and a second end is refused again.
    pt_ru_begin[PH_SINK]()
    pt_ru_end[PH_SINK]()
    assert_equal(pt_overflow_count(), 1)
    pt_ru_end[PH_SINK]()
    assert_equal(pt_overflow_count(), 2)
    pt_reset()


def test_more_threads_than_lanes_are_counted_not_silent() raises:
    # Synthetic thread ids stand in for threads (pt_record_ns_as). This test
    # fills the lane table for good, so it runs last in the process.
    pt_forget_threads()
    pt_reset()
    # Far above any kernel thread id (pid_max is at most 2^22), so no id
    # below collides with the calling thread's.
    var base_id = 1000000000
    var extra = 45
    for i in range(PT_LANES + extra):
        pt_record_ns_as[PH_FILTER](base_id + i, 1)
    assert_equal(pt_lane_count(), PT_LANES)
    assert_equal(pt_overflow_count(), extra)
    # A thread that already has a lane keeps recording once the table is full.
    pt_record_ns_as[PH_FILTER](base_id, 1)
    assert_equal(pt_overflow_count(), extra)
    assert_equal(pt_get(0, PH_FILTER, FIELD_CALLS), 2)
    # The dropped records left no lane behind: the last lane is the last id
    # that fitted, and no lane beyond PT_LANES is readable.
    assert_equal(pt_get(PT_LANES - 1, PH_FILTER, FIELD_CALLS), 1)
    assert_equal(pt_get(PT_LANES, PH_FILTER, FIELD_CALLS), 0)
    # The calling thread has no lane now: every path that needs one counts a
    # drop, and none writes to a lane of another thread.
    pt_record_ns[PH_FILTER](1)
    assert_equal(pt_overflow_count(), extra + 1)
    pt_stamp[PH_END_STAMP]()
    assert_equal(pt_overflow_count(), extra + 2)
    pt_ru_begin[PH_FILTER]()
    assert_equal(pt_overflow_count(), extra + 3)
    pt_ru_end[PH_FILTER]()
    assert_equal(pt_overflow_count(), extra + 4)
    for lane in range(PT_LANES):
        assert_equal(pt_get(lane, PH_END_STAMP, FIELD_SUM), 0)
        for field in range(FIELD_RU_VOL, FIELD_RU_END):
            assert_equal(pt_get(lane, PH_FILTER, field), 0)
    # Reset clears the count, not the lanes.
    pt_reset()
    assert_equal(pt_overflow_count(), 0)
    assert_equal(pt_lane_count(), PT_LANES)
    # Forgetting the threads clears the count too and frees the lanes.
    pt_record_ns_as[PH_FILTER](base_id + PT_LANES + 1, 1)
    assert_equal(pt_overflow_count(), 1)
    pt_forget_threads()
    assert_equal(pt_overflow_count(), 0)
    assert_equal(pt_lane_count(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_intervals_sum_and_keep_the_longest]()
    suite.test[test_a_stamp_is_stored_not_added]()
    suite.test[test_wake_and_join_tails_follow_the_fork]()
    suite.test[test_reset_zeroes_the_counters_and_keeps_the_lane]()
    suite.test[test_a_lane_is_keyed_by_the_kernel_thread_id]()
    suite.test[test_forgetting_threads_frees_every_lane]()
    suite.test[test_thread_usage_counts_this_threads_switches_and_faults]()
    suite.test[test_an_end_without_its_begin_records_nothing_and_is_counted]()
    suite.test[test_more_threads_than_lanes_are_counted_not_silent]()
    suite^.run()

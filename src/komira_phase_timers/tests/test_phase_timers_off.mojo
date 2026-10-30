# The timers with the define KOMIRA_PHASE_TIMERS absent (the default build).
#
# What each test proves, and the defect it would catch:
# - test_the_timers_are_off_by_default: `pt_enabled` is False and `pt_now`
#   is the constant 0. Catches a default build that compiles the timers in.
# - test_every_entry_point_records_nothing: after a call to each recording
#   entry point no thread has registered a lane and every counter reads 0.
#   Catches an entry point whose body is not behind the compile-time flag
#   (one that would register a thread or write a counter in a production
#   build).
# - test_thread_usage_is_not_taken: `pt_ru_begin` and `pt_ru_end` make no
#   system call and register no thread, `pt_ru_available` is False, and every
#   resource-usage counter reads 0 after a sleep that would have cost a
#   voluntary context switch. Catches a usage bracket outside the compile-time
#   flag (a getrusage call on every row group of a production build).

from std.testing import TestSuite, assert_equal, assert_false
from std.time import sleep

from komira_phase_timers.phase_timers import (
    FIELD_CALLS,
    FIELD_RU_END,
    FIELD_RU_VOL,
    PH_COUNT,
    PH_END_STAMP,
    PH_FILTER,
    PH_SINK,
    pt_enabled,
    pt_get,
    pt_lane_count,
    pt_mark_fork,
    pt_now,
    pt_record,
    pt_record_join_tails,
    pt_record_ns,
    pt_record_wake,
    pt_forget_threads,
    pt_reset,
    pt_ru_available,
    pt_ru_begin,
    pt_ru_end,
    pt_stamp,
)


def test_the_timers_are_off_by_default() raises:
    assert_false(pt_enabled())
    assert_equal(pt_now(), 0)


def test_every_entry_point_records_nothing() raises:
    var t0 = pt_now()
    pt_mark_fork()
    pt_record_wake()
    pt_record[PH_FILTER](t0)
    pt_record_ns[PH_SINK](12345)
    pt_stamp[PH_END_STAMP]()
    pt_record_join_tails()
    pt_reset()
    pt_forget_threads()
    assert_equal(pt_lane_count(), 0)
    for lane in range(4):
        for phase in range(PH_COUNT):
            for field in range(FIELD_CALLS + 1):
                assert_equal(pt_get(lane, phase, field), 0)


def test_thread_usage_is_not_taken() raises:
    assert_false(pt_ru_available())
    pt_ru_begin[PH_FILTER]()
    sleep(0.001)
    pt_ru_end[PH_FILTER]()
    assert_equal(pt_lane_count(), 0)
    for field in range(FIELD_RU_VOL, FIELD_RU_END):
        for phase in range(PH_COUNT):
            assert_equal(pt_get(0, phase, field), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_timers_are_off_by_default]()
    suite.test[test_every_entry_point_records_nothing]()
    suite.test[test_thread_usage_is_not_taken]()
    suite^.run()

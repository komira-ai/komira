# The per-thread census of the probe (thread_census.mojo).
#
# What each test proves, and the defect it would catch:
# - test_parse_status_reads_name_and_both_switch_counts: a `status` text gives
#   the thread's name, 123 voluntary and 5 involuntary switches, the 5 not
#   mistaken for the voluntary count (its key is a suffix of the other), and a
#   name with a quote or a backslash is made safe for JSON. Catches a parser
#   that matches the wrong line or writes a name that breaks the document.
# - test_base_name_drops_trailing_digits: "Thread12" and "Thread3" share the
#   name "Thread", "io" stays "io", and digits inside a name stay. Catches
#   threads of one pool listed as one group each.
# - test_parse_schedstat_reads_run_and_wait: "123456 789 4" gives 123456 ns on
#   a CPU and 789 ns waiting; text that is not numbers gives zeros. Catches
#   the two columns swapped or a parser that fails on odd input.
# - test_the_live_census_lists_this_thread: on Linux the census holds at least
#   one thread with a name and a positive id; elsewhere it is empty. Catches a
#   reader that never finds the process's threads.
# - test_delta_splits_threads_into_driver_workers_and_rest: with a driver
#   (id 10), task workers (20, 21) and other threads (30 and 31 named "idle1"
#   and "idle2", 32 named "io" and absent before), the change of each group, the largest of
#   one thread, the threads with a voluntary switch, a thread that is new
#   counted from zero, a thread that ended not counted, and the other threads
#   grouped by name. Catches a thread in the wrong group, a delta taken from
#   the wrong snapshot, and a name group that merges or drops threads.

from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from komira_bench_q6_phases.thread_census import (
    GROUP_DRIVER,
    GROUP_OTHER,
    GROUP_WORKER,
    ThreadStat,
    base_name,
    census_delta,
    parse_schedstat,
    parse_status,
    thread_census,
)


def _stat(tid: Int, name: String, vol: Int, invol: Int, run_ns: Int, wait_ns: Int) -> ThreadStat:
    var s = ThreadStat()
    s.tid = tid
    s.name = name.copy()
    s.vol = vol
    s.invol = invol
    s.run_ns = run_ns
    s.wait_ns = wait_ns
    return s^


def test_parse_status_reads_name_and_both_switch_counts() raises:
    var text = String(
        "Name:\tworker-3\nState:\tS (sleeping)\nTgid:\t7\n"
        "voluntary_ctxt_switches:\t123\nnonvoluntary_ctxt_switches:\t5"
    )
    var s = parse_status(text)
    assert_equal(s.name, "worker-3")
    assert_equal(s.vol, 123)
    assert_equal(s.invol, 5)
    var odd = parse_status(String('Name:\ta"b\\c\nvoluntary_ctxt_switches:\t1\n'))
    assert_equal(odd.name, "a_b_c")
    assert_equal(odd.vol, 1)
    assert_equal(odd.invol, 0)


def test_base_name_drops_trailing_digits() raises:
    assert_equal(base_name("Thread12"), "Thread")
    assert_equal(base_name("Thread3"), "Thread")
    assert_equal(base_name("io"), "io")
    assert_equal(base_name("a1b"), "a1b")
    assert_equal(base_name("123"), "")


def test_parse_schedstat_reads_run_and_wait() raises:
    var run = -1
    var wait = -1
    parse_schedstat(String("123456 789 4\n"), run, wait)
    assert_equal(run, 123456)
    assert_equal(wait, 789)
    parse_schedstat(String("not numbers"), run, wait)
    assert_equal(run, 0)
    assert_equal(wait, 0)


def test_the_live_census_lists_this_thread() raises:
    var threads = thread_census()
    comptime if CompilationTarget.is_linux():
        assert_true(len(threads) >= 1)
        var named = False
        for i in range(len(threads)):
            assert_true(threads[i].tid > 0)
            if threads[i].name.byte_length() > 0:
                named = True
        assert_true(named)
    else:
        assert_equal(len(threads), 0)


def test_delta_splits_threads_into_driver_workers_and_rest() raises:
    var before = List[ThreadStat]()
    before.append(_stat(10, "main", 100, 1, 1000, 10))
    before.append(_stat(20, "w", 50, 0, 2000, 20))
    before.append(_stat(21, "w", 60, 2, 3000, 30))
    before.append(_stat(30, "idle1", 7, 0, 100, 0))
    before.append(_stat(31, "idle2", 9, 0, 100, 0))
    before.append(_stat(99, "gone", 5, 5, 5, 5))
    var after = List[ThreadStat]()
    after.append(_stat(10, "main", 103, 1, 1500, 10))
    after.append(_stat(20, "w", 58, 1, 2600, 25))
    after.append(_stat(21, "w", 60, 4, 3900, 80))
    after.append(_stat(30, "idle1", 17, 0, 400, 0))
    after.append(_stat(31, "idle2", 9, 3, 100, 0))
    after.append(_stat(32, "io", 4, 0, 50, 1))
    var drivers = List[Int]()
    drivers.append(10)
    var workers = List[Int]()
    workers.append(20)
    workers.append(21)
    var d = census_delta(before, after, drivers, workers)
    ref drv = d.groups[GROUP_DRIVER]
    assert_equal(drv.threads, 1)
    assert_equal(drv.vol_sum, 3)
    assert_equal(drv.run_ns, 500)
    ref wk = d.groups[GROUP_WORKER]
    assert_equal(wk.threads, 2)
    assert_equal(wk.active_threads, 1)
    assert_equal(wk.vol_sum, 8)
    assert_equal(wk.vol_max, 8)
    assert_equal(wk.invol_sum, 1 + 2)
    assert_equal(wk.run_ns, 600 + 900)
    assert_equal(wk.wait_ns, 5 + 50)
    assert_equal(wk.wait_ns_max, 50)
    ref ot = d.groups[GROUP_OTHER]
    assert_equal(ot.threads, 3)
    assert_equal(ot.active_threads, 2)
    assert_equal(ot.vol_sum, 10 + 0 + 4)
    assert_equal(ot.vol_max, 10)
    assert_equal(ot.invol_sum, 3)
    assert_equal(len(d.other_names), 2)
    assert_equal(d.other_names[0], "idle")
    assert_equal(d.other_name_threads[0], 2)
    assert_equal(d.other_name_vol[0], 10)
    assert_equal(d.other_names[1], "io")
    assert_equal(d.other_name_threads[1], 1)
    assert_equal(d.other_name_vol[1], 4)
    assert_equal(d.other_name_run_ns[1], 50)


def main() raises:
    var suite = TestSuite()
    suite.test[test_parse_status_reads_name_and_both_switch_counts]()
    suite.test[test_base_name_drops_trailing_digits]()
    suite.test[test_parse_schedstat_reads_run_and_wait]()
    suite.test[test_the_live_census_lists_this_thread]()
    suite.test[test_delta_splits_threads_into_driver_workers_and_rest]()
    suite^.run()

# =============================================================================
# test_spawn_join.mojo -- the fork-join helper the ring's thread tests stand on
# =============================================================================
#
# `spawn_join` (`_test_threads.mojo`) is what every concurrency test of the ring
# trusts to start real threads and to return only after all of them exited. If
# it ran a body twice, handed two threads one tid, returned early or swallowed
# a body's error, those tests would pass on a broken ring. This file pins its
# contract on its own:
#
#   1.  n < 0 raises and names n; no body runs.
#   2.  n == 0 returns at once and runs no body.
#   3.  n == 1 runs the body once, with tid 0.
#   4.  n == 5 runs each tid 0..4 exactly once (no tid twice, none missing).
#   5.  The join is a barrier: a body that is still busy when the others have
#       finished has finished when spawn_join returns.
#   6.  One body raising: spawn_join raises that body's message, verbatim, after
#       every other body ran to the end.
#   7.  Two bodies raising: the lowest tid's message wins, with the suffix
#       "(2 of 4 workers failed)".
#
# The pthread_create failure path (a thread that cannot start) is in
# test_spawn_join_start_failure.mojo: it needs a fresh process.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_atomic_alias import AtomicI64
from komira_spsc_ring._test_threads import SpawnJoinBody, spawn_join


struct _Tally(Movable):
    """How often each tid ran, one byte per tid (tid k counts in bits 8k..8k+7,
    so tids 0..6 fit), and how many bodies finished."""

    var runs: AtomicI64
    var finished: AtomicI64

    def __init__(out self):
        self.runs = AtomicI64(Int64(0))
        self.finished = AtomicI64(Int64(0))

    def of(self, tid: Int) -> Int:
        return Int(self.runs.load() >> Int64(8 * tid)) & 0xFF

    def total(self) -> Int:
        var t = 0
        for i in range(7):
            t += self.of(i)
        return t


struct _CountBody[o: MutOrigin](SpawnJoinBody):
    """Counts the run of each tid. `slow_tid` busy-waits 50 ms before it
    counts itself finished; `fail_mask` bit k makes tid k raise "fault <k>"
    after it has counted its run and its finish."""

    var tally: Pointer[_Tally, Self.o]
    var slow_tid: Int
    var fail_mask: Int

    def __init__(
        out self, tally: Pointer[_Tally, Self.o], slow_tid: Int, fail_mask: Int
    ):
        self.tally = tally
        self.slow_tid = slow_tid
        self.fail_mask = fail_mask

    def run(self, tid: Int) raises:
        _ = self.tally[].runs.fetch_add(Int64(1) << Int64(8 * tid))
        if tid == self.slow_tid:
            var t0 = perf_counter_ns()
            while Int(perf_counter_ns() - t0) < 50_000_000:
                pass
        _ = self.tally[].finished.fetch_add(Int64(1))
        if (self.fail_mask >> tid) & 1 == 1:
            raise Error("fault " + String(tid))


def test_negative_n_raises_and_runs_nothing() raises:
    var tally = _Tally()
    var body = _CountBody(Pointer(to=tally), -1, 0)
    var msg = String("")
    try:
        spawn_join(body, -1)
    except e:
        msg = String(e)
    assert_equal(msg, String("spawn_join: n must be >= 0, got -1"))
    assert_equal(tally.total(), 0, "no body ran")
    print("  test_negative_n_raises_and_runs_nothing PASS")


def test_zero_threads_is_a_no_op() raises:
    var tally = _Tally()
    var body = _CountBody(Pointer(to=tally), -1, 0)
    spawn_join(body, 0)
    assert_equal(tally.total(), 0, "no body ran")
    assert_equal(tally.finished.load(), Int64(0))
    print("  test_zero_threads_is_a_no_op PASS")


def test_one_thread_runs_tid_zero_once() raises:
    var tally = _Tally()
    var body = _CountBody(Pointer(to=tally), -1, 0)
    spawn_join(body, 1)
    assert_equal(tally.of(0), 1, "tid 0 ran once")
    assert_equal(tally.total(), 1, "and nothing else ran")
    print("  test_one_thread_runs_tid_zero_once PASS")


def test_each_tid_runs_exactly_once() raises:
    var tally = _Tally()
    var body = _CountBody(Pointer(to=tally), -1, 0)
    spawn_join(body, 5)
    for i in range(5):
        assert_equal(tally.of(i), 1, "tid " + String(i) + " ran once")
    assert_equal(tally.total(), 5, "no tid past n - 1")
    print("  test_each_tid_runs_exactly_once PASS")


def test_join_waits_for_the_slowest_body() raises:
    var tally = _Tally()
    var body = _CountBody(Pointer(to=tally), 2, 0)
    spawn_join(body, 3)
    # tid 2 spends 50 ms before it counts itself finished; the others finish
    # at once. Read with no wait: only a real join makes this 3.
    assert_equal(tally.finished.load(), Int64(3), "every body finished")
    print("  test_join_waits_for_the_slowest_body PASS")


def test_one_failing_body_raises_its_message() raises:
    var tally = _Tally()
    var body = _CountBody(Pointer(to=tally), 0, 1 << 1)
    var msg = String("")
    try:
        spawn_join(body, 3)
    except e:
        msg = String(e)
    assert_equal(msg, String("fault 1"), "the message verbatim, no suffix")
    assert_equal(tally.total(), 3, "the other bodies still ran")
    assert_equal(tally.finished.load(), Int64(3), "and were joined first")
    print("  test_one_failing_body_raises_its_message PASS")


def test_two_failing_bodies_lowest_tid_wins() raises:
    var tally = _Tally()
    # tids 1 and 3 fail; tid 1 is slow, so it is likely the LAST to fail: the
    # report must still be by tid, not by time.
    var body = _CountBody(Pointer(to=tally), 1, (1 << 1) | (1 << 3))
    var msg = String("")
    try:
        spawn_join(body, 4)
    except e:
        msg = String(e)
    assert_equal(msg, String("fault 1 (2 of 4 workers failed)"))
    assert_equal(tally.total(), 4, "every body ran")
    print("  test_two_failing_bodies_lowest_tid_wins PASS")


def main() raises:
    print("test_spawn_join")
    print("===============")
    test_negative_n_raises_and_runs_nothing()
    test_zero_threads_is_a_no_op()
    test_one_thread_runs_tid_zero_once()
    test_each_tid_runs_exactly_once()
    test_join_waits_for_the_slowest_body()
    test_one_failing_body_raises_its_message()
    test_two_failing_bodies_lowest_tid_wins()
    print()
    print("ALL TESTS PASS")

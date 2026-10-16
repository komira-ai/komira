# =============================================================================
# test_spawn_join_start_failure.mojo -- spawn_join when a thread cannot start
# =============================================================================
#
# `spawn_join` promises: if `pthread_create` fails after `k` threads started,
# those `k` are joined and it raises "spawn_join: pthread_create failed (rc=..),
# started k of n". These tests make the k-th start fail through the fault seam
# (`spawn_join_with_fault`): the seam names the thread index that fails and the
# return code `pthread_create` would have given. Nothing here depends on memory
# limits, load, CPU placement or time.
#
# What this does not cover: that the OS really refuses a thread. The mapping
# from a nonzero return code to the error is covered with injected codes
# (EAGAIN, the code glibc returns when a thread cannot be created); the
# success path of the real pthread_create is covered by test_spawn_join.mojo.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from komira_atomic_alias import AtomicI64
from komira_spsc_ring._test_threads import (
    SpawnFault,
    SpawnJoinBody,
    spawn_join_with_fault,
)

comptime _EAGAIN: Int32 = 11
comptime _ENOMEM: Int32 = 12


struct _FailAt(SpawnFault):
    """Thread `index` fails to start with `rc`; the others start for real."""

    var index: Int
    var rc: Int32

    def __init__(out self, index: Int, rc: Int32):
        self.index = index
        self.rc = rc

    def fail_rc(self, index: Int) -> Int32:
        if index == self.index:
            return self.rc
        return Int32(0)


struct _Tally(Movable):
    var runs: AtomicI64
    var finished: AtomicI64

    def __init__(out self):
        self.runs = AtomicI64(Int64(0))
        self.finished = AtomicI64(Int64(0))


struct _Body[o: MutOrigin](SpawnJoinBody):
    """Counts each run; tid `raise_tid` raises after counting itself done."""

    var tally: Pointer[_Tally, Self.o]
    var raise_tid: Int

    def __init__(out self, tally: Pointer[_Tally, Self.o], raise_tid: Int):
        self.tally = tally
        self.raise_tid = raise_tid

    def run(self, tid: Int) raises:
        _ = self.tally[].runs.fetch_add(Int64(1))
        _ = self.tally[].finished.fetch_add(Int64(1))
        if tid == self.raise_tid:
            raise Error("fault " + String(tid))


def _run[
    o: MutOrigin
](mut body: _Body[o], n: Int, at: Int, rc: Int32) raises -> String:
    """spawn_join_with_fault with thread `at` failing with `rc`; returns the
    error text ("" if it returned)."""
    try:
        spawn_join_with_fault(body, n, _FailAt(at, rc))
    except e:
        return String(e)
    return String("")


def _expect(msg: String, rc: Int32, started: Int, n: Int) raises:
    var want = (
        "spawn_join: pthread_create failed (rc="
        + String(Int(rc))
        + "), started "
        + String(started)
        + " of "
        + String(n)
    )
    assert_equal(msg, want)


def test_first_thread_cannot_start() raises:
    var tally = _Tally()
    var body = _Body(Pointer(to=tally), -1)
    _expect(_run(body, 2, 0, _EAGAIN), _EAGAIN, 0, 2)
    assert_equal(tally.runs.load(), Int64(0), "no body ran")


def test_later_thread_cannot_start_and_the_started_are_joined() raises:
    var tally = _Tally()
    var body = _Body(Pointer(to=tally), -1)
    _expect(_run(body, 5, 3, _EAGAIN), _EAGAIN, 3, 5)
    # The barrier: all three started bodies had completed when the error left.
    assert_equal(tally.runs.load(), Int64(3), "tids 0..2 ran")
    assert_equal(tally.finished.load(), Int64(3), "all three were joined")


def test_start_failure_wins_over_a_started_body_error() raises:
    var tally = _Tally()
    var body = _Body(Pointer(to=tally), 0)
    _expect(_run(body, 3, 1, _EAGAIN), _EAGAIN, 1, 3)
    assert_equal(tally.finished.load(), Int64(1), "tid 0 was joined first")


def test_the_returned_code_is_reported() raises:
    var tally = _Tally()
    var body = _Body(Pointer(to=tally), -1)
    _expect(_run(body, 2, 1, _ENOMEM), _ENOMEM, 1, 2)
    assert_equal(tally.runs.load(), Int64(1), "tid 0 ran")


def test_a_fault_past_the_last_thread_changes_nothing() raises:
    var tally = _Tally()
    var body = _Body(Pointer(to=tally), -1)
    assert_equal(_run(body, 3, 3, _EAGAIN), "", "no start fails")
    assert_equal(tally.runs.load(), Int64(3), "all three ran")


def main() raises:
    print("test_spawn_join_start_failure")
    print("=============================")
    test_first_thread_cannot_start()
    test_later_thread_cannot_start_and_the_started_are_joined()
    test_start_failure_wins_over_a_started_body_error()
    test_the_returned_code_is_reported()
    test_a_fault_past_the_last_thread_changes_nothing()
    print()
    print("ALL TESTS PASS")

# =============================================================================
# test_spawn_join.mojo -- spawn_join: N threads, one body, joined before return
# =============================================================================
#
# Verifies:
#   1. Every tid 0..n-1 runs exactly once (a per-tid cell is bumped by exactly
#      one thread) and the shared atomic sum is the sum of all tids.
#   2. The body really runs on distinct threads, not serially on the caller:
#      each thread records its own pthread identity and the set has n members.
#      Without that, a serial fallback would pass 1.
#   3. n == 0 runs nothing and returns; n == 1 runs tid 0 once; n < 0 raises.
#   4. A raising body: every thread still ran (all joined), and the error is
#      the one the failing tid raised.
#   5. Two raising bodies: the LOWEST tid's error is rethrown with the failure
#      count appended.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_equal, assert_true, assert_false
from std.time import sleep

from komira_atomic_alias import AtomicI64
from komira_spawn_join import SpawnJoinBody, spawn_join
from komira_spawn_join._pthread import pthread_self_id as thread_self


comptime MAX_THREADS = 16


struct _Cells(Movable):
    """Per-tid run counters and recorded thread identities, plus a shared sum.

    Owned by the test; the body reaches it through a Pointer.
    """

    var sum: AtomicI64
    var runs: List[AtomicI64]
    var idents: List[UInt64]

    def __init__(out self, n: Int):
        self.sum = AtomicI64(Int64(0))
        self.runs = List[AtomicI64]()
        self.idents = List[UInt64]()
        for _ in range(n):
            self.runs.append(AtomicI64(Int64(0)))
            self.idents.append(UInt64(0))


struct _Body[o: MutOrigin](SpawnJoinBody):
    var cells: Pointer[_Cells, Self.o]
    # tids >= fail_from raise; fail_from = -1 means nobody raises.
    var fail_from: Int

    def __init__(out self, cells: Pointer[_Cells, Self.o], fail_from: Int = -1):
        self.cells = cells
        self.fail_from = fail_from

    def run(self, tid: Int) raises:
        ref c = self.cells[]
        _ = c.runs[tid].fetch_add(Int64(1))
        _ = c.sum.fetch_add(Int64(tid))
        c.idents[tid] = thread_self()
        # Hold every thread alive a moment so a serial schedule cannot hide.
        sleep(0.010)
        if self.fail_from >= 0 and tid >= self.fail_from:
            raise Error("body failed on tid " + String(tid))


def test_each_tid_once_and_distinct_threads() raises:
    var n = 8
    var cells = _Cells(n)
    var body = _Body(Pointer(to=cells))
    spawn_join(body, n)
    var expect = 0
    for t in range(n):
        assert_equal(cells.runs[t].load(), Int64(1), "tid ran exactly once")
        expect += t
    assert_equal(cells.sum.load(), Int64(expect), "shared sum")
    var distinct = 0
    for i in range(n):
        var seen = False
        for j in range(i):
            if cells.idents[j] == cells.idents[i]:
                seen = True
        assert_true(cells.idents[i] != UInt64(0), "identity recorded")
        if not seen:
            distinct += 1
    assert_equal(distinct, n, "every tid ran on its own thread")
    assert_true(cells.idents[0] != thread_self(), "not on the caller's thread")
    print("  test_each_tid_once_and_distinct_threads PASS")


def test_zero_one_negative() raises:
    var cells = _Cells(4)
    var body = _Body(Pointer(to=cells))
    spawn_join(body, 0)
    assert_equal(cells.sum.load(), Int64(0), "n=0 runs nothing")
    for t in range(4):
        assert_equal(cells.runs[t].load(), Int64(0), "n=0 ran no tid")
    spawn_join(body, 1)
    assert_equal(cells.runs[0].load(), Int64(1), "n=1 runs tid 0")
    assert_equal(cells.runs[1].load(), Int64(0), "n=1 runs only tid 0")
    var raised = False
    try:
        spawn_join(body, -1)
    except e:
        raised = True
        assert_true("n must be >= 0" in String(e), "names the cause")
    assert_true(raised, "negative n raises")
    print("  test_zero_one_negative PASS")


def test_one_raising_body_joins_all_then_raises() raises:
    var n = 6
    var cells = _Cells(n)
    var body = _Body(Pointer(to=cells), 3)
    var raised = False
    try:
        spawn_join(body, n)
    except e:
        raised = True
        # tids 3, 4 and 5 raise; the lowest wins and the count is appended.
        assert_true("body failed on tid 3" in String(e), "lowest tid's error")
        assert_true("3 of 6 workers failed" in String(e), "count appended")
    assert_true(raised, "a raising body raises out of spawn_join")
    for t in range(n):
        assert_equal(cells.runs[t].load(), Int64(1), "every thread still ran")
    print("  test_one_raising_body_joins_all_then_raises PASS")


def test_single_failure_has_no_count_suffix() raises:
    var n = 4
    var cells = _Cells(n)
    var body = _Body(Pointer(to=cells), 3)
    var raised = False
    try:
        spawn_join(body, n)
    except e:
        raised = True
        assert_equal(String(e), String("body failed on tid 3"), "plain message")
    assert_true(raised, "raises")
    print("  test_single_failure_has_no_count_suffix PASS")


def test_two_raising_bodies_lowest_tid_wins() raises:
    var n = 5
    var cells = _Cells(n)
    var body = _Body(Pointer(to=cells), 3)  # tids 3 and 4
    var raised = False
    try:
        spawn_join(body, n)
    except e:
        raised = True
        var msg = String(e)
        assert_true("body failed on tid 3" in msg, "tid 3 beats tid 4")
        assert_false("body failed on tid 4" in msg, "tid 4 is not reported")
        assert_true("2 of 5 workers failed" in msg, "both failures counted")
    assert_true(raised, "raises")
    print("  test_two_raising_bodies_lowest_tid_wins PASS")


def main() raises:
    print("test_spawn_join")
    print("===============")
    test_each_tid_once_and_distinct_threads()
    test_zero_one_negative()
    test_one_raising_body_joins_all_then_raises()
    test_single_failure_has_no_count_suffix()
    test_two_raising_bodies_lowest_tid_wins()
    print()
    print("ALL TESTS PASS")

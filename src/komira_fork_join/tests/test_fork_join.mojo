# =============================================================================
# test_fork_join.mojo -- fork_join: N threads, one body, joined before return
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
#   6. A failed thread start (Linux): with the process-wide default thread
#      stack size set larger than the address space, `pthread_create` fails
#      on the first thread; `fork_join` raises "pthread_create failed (rc=..),
#      started 0 of n" with a non-zero rc, runs no body, and once the default
#      is restored the next `fork_join` runs normally.
# =============================================================================

from std.ffi import external_call
from std.memory import Pointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false
from std.time import sleep

from komira_atomic_alias import AtomicI64
from komira_fork_join import ForkJoinBody, fork_join
from komira_fork_join._pthread import pthread_self_id as thread_self


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


struct _Body[o: MutOrigin](ForkJoinBody):
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
    fork_join(body, n)
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
    fork_join(body, 0)
    assert_equal(cells.sum.load(), Int64(0), "n=0 runs nothing")
    for t in range(4):
        assert_equal(cells.runs[t].load(), Int64(0), "n=0 ran no tid")
    fork_join(body, 1)
    assert_equal(cells.runs[0].load(), Int64(1), "n=1 runs tid 0")
    assert_equal(cells.runs[1].load(), Int64(0), "n=1 runs only tid 0")
    var raised = False
    try:
        fork_join(body, -1)
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
        fork_join(body, n)
    except e:
        raised = True
        # tids 3, 4 and 5 raise; the lowest wins and the count is appended.
        assert_true("body failed on tid 3" in String(e), "lowest tid's error")
        assert_true("3 of 6 workers failed" in String(e), "count appended")
    assert_true(raised, "a raising body raises out of fork_join")
    for t in range(n):
        assert_equal(cells.runs[t].load(), Int64(1), "every thread still ran")
    print("  test_one_raising_body_joins_all_then_raises PASS")


def test_single_failure_has_no_count_suffix() raises:
    var n = 4
    var cells = _Cells(n)
    var body = _Body(Pointer(to=cells), 3)
    var raised = False
    try:
        fork_join(body, n)
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
        fork_join(body, n)
    except e:
        raised = True
        var msg = String(e)
        assert_true("body failed on tid 3" in msg, "tid 3 beats tid 4")
        assert_false("body failed on tid 4" in msg, "tid 4 is not reported")
        assert_true("2 of 5 workers failed" in msg, "both failures counted")
    assert_true(raised, "raises")
    print("  test_two_raising_bodies_lowest_tid_wins PASS")


# A `pthread_attr_t` is 56 bytes on x86-64 glibc and 64 on aarch64; the
# buffer is the larger, so either layout fits.
comptime _ATTR_BYTES = 64
# 1 PiB: past any 47- or 48-bit user address space, so the stack mmap fails.
comptime _HUGE_STACK = 1 << 50


def _attr_call(name: StaticString, mut attr: List[UInt8]) -> Int32:
    # FFI-BOUNDARY: pthread attribute calls take a `pthread_attr_t *`; the
    # buffer is owned by the caller and outlives the call.
    if name == "init":
        return external_call["pthread_attr_init", Int32](attr.unsafe_ptr())
    if name == "destroy":
        return external_call["pthread_attr_destroy", Int32](attr.unsafe_ptr())
    if name == "get_default":
        return external_call["pthread_getattr_default_np", Int32](
            attr.unsafe_ptr()
        )
    return external_call["pthread_setattr_default_np", Int32](
        attr.unsafe_ptr()
    )


def test_failed_thread_start_joins_and_raises() raises:
    comptime if not CompilationTarget.is_linux():
        # pthread_setattr_default_np is a glibc extension; without it there is
        # no in-process way to make pthread_create fail on demand.
        print("  test_failed_thread_start_joins_and_raises SKIP (not Linux)")
        return
    var saved = List[UInt8](length=_ATTR_BYTES, fill=UInt8(0))
    var huge = List[UInt8](length=_ATTR_BYTES, fill=UInt8(0))
    assert_equal(_attr_call("get_default", saved), Int32(0), "save default")
    assert_equal(_attr_call("init", huge), Int32(0), "attr init")
    assert_equal(
        external_call["pthread_attr_setstacksize", Int32](
            huge.unsafe_ptr(), _HUGE_STACK
        ),
        Int32(0),
        "huge stack size accepted",
    )
    assert_equal(_attr_call("set_default", huge), Int32(0), "set huge default")

    var n = 3
    var cells = _Cells(n)
    var body = _Body(Pointer(to=cells))
    var message = String()
    try:
        fork_join(body, n)
    except e:
        message = String(e)
    # Restore before asserting, so a failed assertion cannot leak the huge
    # default into later tests.
    var restored = _attr_call("set_default", saved)
    _ = _attr_call("destroy", huge)
    _ = _attr_call("destroy", saved)
    assert_equal(restored, Int32(0), "default restored")

    assert_true(message != "", "a failed thread start raises")
    assert_true(
        "fork_join: pthread_create failed (rc=" in message, "names the cause"
    )
    assert_false("(rc=0)" in message, "reports the non-zero return code")
    assert_true(message.endswith("), started 0 of 3"), "started 0 of 3")
    for t in range(n):
        assert_equal(cells.runs[t].load(), Int64(0), "no body ran")

    # The default is back: the same call now runs every tid once.
    fork_join(body, n)
    for t in range(n):
        assert_equal(cells.runs[t].load(), Int64(1), "runs after restore")
    print("  test_failed_thread_start_joins_and_raises PASS")


def main() raises:
    print("test_fork_join")
    print("===============")
    test_each_tid_once_and_distinct_threads()
    test_zero_one_negative()
    test_one_raising_body_joins_all_then_raises()
    test_single_failure_has_no_count_suffix()
    test_two_raising_bodies_lowest_tid_wins()
    test_failed_thread_start_joins_and_raises()
    print()
    print("ALL TESTS PASS")

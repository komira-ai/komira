# =============================================================================
# test_spawn_join_start_failure.mojo -- spawn_join when a thread cannot start
# =============================================================================
#
# `spawn_join` promises: if `pthread_create` fails after `k` threads started,
# those `k` are joined and it raises "spawn_join: pthread_create failed (rc=..),
# started k of n". A thread cannot start when its stack cannot be mapped, so
# this file lowers the soft address-space limit (RLIMIT_AS, Linux) to just
# above what the process has mapped, calls spawn_join, and restores the limit
# before it asserts anything. The hard limit is never touched, so the restore
# needs no privilege.
#
# Order matters and is why this is a file (a process) of its own: glibc keeps
# the stack of a joined thread and hands it to the next thread, which then
# needs no new mapping.
#   1.  First, no thread has ever exited: under the limit the first
#       pthread_create fails: "started 0 of 2", no body ran.
#   2.  Then one thread runs and exits, leaving one cached stack. Under the
#       limit the next spawn_join of 3 starts tid 0 on that stack and fails on
#       tid 1: "started 1 of 3". tid 0 is slow (50 ms) and also raises: the
#       raise is after a join (tid 0 finished), and when a thread failed to
#       start AND a started body raised, the start failure is the one reported.
#
# macOS does not bound mmap by RLIMIT_AS, so there the tests print SKIP and
# say why.
# =============================================================================

from std.ffi import external_call
from std.memory import Pointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_atomic_alias import AtomicI64
from komira_spsc_ring._test_threads import SpawnJoinBody, spawn_join

comptime _RLIMIT_AS_LINUX: Int32 = 9
comptime _HEADROOM_BYTES: UInt64 = 256 * 1024  # far below one thread stack


struct _Tally(Movable):
    var runs: AtomicI64
    var finished: AtomicI64

    def __init__(out self):
        self.runs = AtomicI64(Int64(0))
        self.finished = AtomicI64(Int64(0))


struct _Body[o: MutOrigin](SpawnJoinBody):
    """Counts each run; tid `slow_tid` busy-waits 50 ms and then raises."""

    var tally: Pointer[_Tally, Self.o]
    var slow_tid: Int

    def __init__(out self, tally: Pointer[_Tally, Self.o], slow_tid: Int):
        self.tally = tally
        self.slow_tid = slow_tid

    def run(self, tid: Int) raises:
        _ = self.tally[].runs.fetch_add(Int64(1))
        if tid == self.slow_tid:
            var t0 = perf_counter_ns()
            while Int(perf_counter_ns() - t0) < 50_000_000:
                pass
            _ = self.tally[].finished.fetch_add(Int64(1))
            raise Error("fault " + String(tid))
        _ = self.tally[].finished.fetch_add(Int64(1))


def _mapped_bytes() raises -> UInt64:
    """The process's mapped address space (VmSize in /proc/self/status)."""
    var text: String
    with open("/proc/self/status", "r") as f:
        text = f.read()
    for line in text.split("\n"):
        if line.startswith("VmSize:"):
            var kb = String(line[byte=7:]).replace("kB", "").strip()
            return UInt64(atol(kb)) * 1024
    raise Error("no VmSize line in /proc/self/status")


def _spawn_join_under_limit[
    o: MutOrigin
](mut body: _Body[o], n: Int) raises -> String:
    """spawn_join(body, n) with the soft RLIMIT_AS a little above what is
    mapped now; the limit is restored before this returns. Returns the error
    text ("" if spawn_join returned)."""
    var saved = InlineArray[UInt64, 2](fill=UInt64(0))
    # SAFETY: `saved` is a local two-word rlimit the call fills synchronously.
    var rc = external_call["getrlimit", Int32](_RLIMIT_AS_LINUX, saved.unsafe_ptr())
    assert_equal(rc, Int32(0), "getrlimit")
    var tight = InlineArray[UInt64, 2](fill=UInt64(0))
    tight[0] = _mapped_bytes() + _HEADROOM_BYTES
    tight[1] = saved[1]
    var msg = String("")
    # SAFETY: `tight` is a local two-word rlimit the call reads synchronously.
    rc = external_call["setrlimit", Int32](_RLIMIT_AS_LINUX, tight.unsafe_ptr())
    if rc != Int32(0):
        raise Error("setrlimit(RLIMIT_AS) failed")
    try:
        spawn_join(body, n)
    except e:
        msg = String(e)
    # SAFETY: as above; restores the limit before any assertion can raise.
    rc = external_call["setrlimit", Int32](_RLIMIT_AS_LINUX, saved.unsafe_ptr())
    assert_equal(rc, Int32(0), "the limit is restored")
    return msg


def _check_start_failure(msg: String, started: Int, n: Int) raises:
    var prefix = String("spawn_join: pthread_create failed (rc=")
    var suffix = "), started " + String(started) + " of " + String(n)
    assert_true(msg.startswith(prefix), "a start failure: " + msg)
    assert_true(msg.endswith(suffix), "names started and n: " + msg)
    var code = String(msg[byte = prefix.byte_length() : msg.byte_length() - suffix.byte_length()])
    assert_true(atol(code) != 0, "carries the nonzero return code: " + msg)


def test_first_thread_cannot_start() raises:
    var tally = _Tally()
    var body = _Body(Pointer(to=tally), -1)
    var msg = _spawn_join_under_limit(body, 2)
    _check_start_failure(msg, 0, 2)
    assert_equal(tally.runs.load(), Int64(0), "no body ran")
    print("  test_first_thread_cannot_start PASS")


def test_second_thread_cannot_start_and_the_first_is_joined() raises:
    # One thread runs and exits; its stack stays cached for the next one.
    var warm_tally = _Tally()
    var warm = _Body(Pointer(to=warm_tally), -1)
    spawn_join(warm, 1)
    assert_equal(warm_tally.runs.load(), Int64(1), "the warm-up ran")

    var tally = _Tally()
    var body = _Body(Pointer(to=tally), 0)
    var msg = _spawn_join_under_limit(body, 3)
    _check_start_failure(msg, 1, 3)
    assert_equal(tally.runs.load(), Int64(1), "only tid 0 ran")
    assert_equal(
        tally.finished.load(), Int64(1), "tid 0 was joined before the raise"
    )
    print("  test_second_thread_cannot_start_and_the_first_is_joined PASS")


def main() raises:
    print("test_spawn_join_start_failure")
    print("=============================")
    comptime if CompilationTarget.is_linux():
        test_first_thread_cannot_start()
        test_second_thread_cannot_start_and_the_first_is_joined()
    else:
        print("  SKIP: RLIMIT_AS does not bound thread stacks off Linux")
    print()
    print("ALL TESTS PASS")

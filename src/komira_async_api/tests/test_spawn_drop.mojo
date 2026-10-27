# =============================================================================
# spawn_drop: deferred-deallocation primitive for steal_merge
# =============================================================================
#
# The Mojo equivalent of `std::thread::spawn(move || drop(to_drop))`.
#
# Test contract:
#   We construct a ThreadStampSentinel whose destructor records the id of the
#   thread it runs on (`pthread_self`) and then sets a `done` flag. The driver
#   calls `spawn_drop` and waits for `done`; the destructor must have run
#   exactly once, on a thread other than the driver's.
#
# A synchronous drop (the primitive's fallback when `pthread_create` fails, or
# a regression that drops in place) runs the destructor on the driver's own
# thread: the recorded id equals the driver's and the test fails at once, with
# no wait. The primitive hands the sentinel to a detached pthread, so the
# recorded id differs.
#
# Nothing here reads a clock: the evidence is the thread id, and the only wait
# is for the background thread's `done` flag (an event; the hang limit armed in
# `main` kills a run whose destructor never happens).
# =============================================================================

from std.ffi import external_call
from komira_atomic_alias import AtomicI64
from std.memory import alloc, ArcPointer, OwnedPointer
from std.testing import assert_equal, assert_true

from komira_async_api.spawn_drop import spawn_drop


def _new_counter() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    # SAFETY: a fresh allocation we own; ownership moves to the OwnedPointer.
    raw[] = AtomicI64(Int64(0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _this_thread() -> Int64:
    """An identifier of the calling thread (`pthread_self`), never 0."""
    return Int64(external_call["pthread_self", UInt64]())


struct _Stamps(Movable, Deinitable):
    """Heap-stable atomics shared (through an `ArcPointer`) between the test and
    the sentinel: `done` counts destructor runs, `tid` is the thread id the
    destructor ran on."""

    var done: OwnedPointer[AtomicI64]
    var tid: OwnedPointer[AtomicI64]

    def __init__(out self):
        self.done = _new_counter()
        self.tid = _new_counter()


struct ThreadStampSentinel(Movable, Deinitable):
    """A test sentinel whose destructor records its thread, then counts a run.
    The stamps outlive the sentinel: the test holds its own reference, so the
    background thread's last write is never to freed memory."""

    var stamps: ArcPointer[_Stamps]

    def __init__(out self, var stamps: ArcPointer[_Stamps]):
        self.stamps = stamps^

    def __deinit__(deinit self):
        # tid first: `done` is the flag the driver waits on.
        self.stamps[].tid[].store(_this_thread())
        _ = self.stamps[].done[].fetch_add(Int64(1))


def test_spawn_drop_runs_the_destructor_on_another_thread() raises:
    """The destructor runs once, and not on the thread that called
    `spawn_drop`."""
    var stamps = ArcPointer[_Stamps](_Stamps())
    var sentinel = ThreadStampSentinel(ArcPointer[_Stamps](copy=stamps))
    var driver = _this_thread()
    assert_true(driver != Int64(0))

    spawn_drop[ThreadStampSentinel](sentinel^)

    # Wait for the destructor, wherever it ran: a drop in place has finished by
    # now, a drop on the background thread finishes when that thread gets there.
    while stamps[].done[].load() == Int64(0):
        pass
    assert_equal(Int(stamps[].done[].load()), 1, "the destructor ran once")
    assert_true(
        stamps[].tid[].load() != driver,
        "spawn_drop ran the destructor on the calling thread: the primitive is"
        " synchronous",
    )


# Hang limit. A library's tests run as build actions, which have no timeout, and
# the wait in this file has no deadline of its own (it waits on an event, not on
# a clock). A regression that loses the event would hold a worker with no
# verdict, so the process arms SIGALRM once, far above any run: its default
# action kills the process (exit 142) and the build action fails. No test reads
# this limit; a run that completes never meets it.
comptime _HANG_LIMIT_S: Int = 600


def _arm_hang_limit():
    _ = external_call["alarm", UInt32](UInt32(_HANG_LIMIT_S))


def main() raises:
    _arm_hang_limit()
    test_spawn_drop_runs_the_destructor_on_another_thread()
    print("PASS komira_async_api spawn_drop")

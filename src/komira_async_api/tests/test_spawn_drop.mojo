# =============================================================================
# spawn_drop: deferred-deallocation primitive for steal_merge
# =============================================================================
#
# The Mojo equivalent of `std::thread::spawn(move || drop(to_drop))`.
#
# Test contract:
#   We construct a GatedDropSentinel whose destructor blocks on a gate the
#   test owns, then sets a `done` flag. The driver calls `spawn_drop`, which
#   must RETURN while the destructor is still blocked on the gate: `done` is
#   still 0 at that point. The driver then opens the gate and waits for
#   `done` to become 1, which proves the destructor ran after the call
#   returned.
#
# A synchronous drop would run the destructor inside `spawn_drop` (or at the
# end of the calling function), where it would wait on a gate that only the
# caller can open: the test would hang. The primitive hands the sentinel to a
# detached pthread, so the caller returns, opens the gate, and the destructor
# finishes on the background thread.
#
# Nothing here reads a clock: the ordering comes from the gate and the flag.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import alloc, ArcPointer, OwnedPointer
from std.testing import assert_equal

from komira_async_api.spawn_drop import spawn_drop


def _new_counter() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    # SAFETY: a fresh allocation we own; ownership moves to the OwnedPointer.
    raw[] = AtomicI64(Int64(0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


struct _Latch(Movable, Deinitable):
    """Two heap-stable atomics shared (through an `ArcPointer`) between the
    test and the sentinel: `gate` (the test opens it) and `done` (the
    destructor sets it)."""

    var gate: OwnedPointer[AtomicI64]
    var done: OwnedPointer[AtomicI64]

    def __init__(out self):
        self.gate = _new_counter()
        self.done = _new_counter()


struct GatedDropSentinel(Movable, Deinitable):
    """A test sentinel whose destructor blocks until the gate opens, then sets
    `done`. The latch outlives the sentinel: the test holds its own
    reference, so the background thread's last write is never to freed
    memory."""

    var latch: ArcPointer[_Latch]

    def __init__(out self, var latch: ArcPointer[_Latch]):
        self.latch = latch^

    def __deinit__(deinit self):
        # No deadline: the gate is opened by the test once `spawn_drop` has
        # returned. A synchronous drop never sees it opened and hangs.
        while self.latch[].gate[].load() == Int64(0):
            pass
        _ = self.latch[].done[].fetch_add(Int64(1))


def test_spawn_drop_returns_before_destructor() raises:
    """`spawn_drop` returns while the destructor is still blocked on the gate
    (`done == 0`); after the gate opens the destructor runs to completion on
    the background thread (`done == 1`)."""
    var latch = ArcPointer[_Latch](_Latch())
    var sentinel = GatedDropSentinel(ArcPointer[_Latch](copy=latch))

    # After this call the destructor is running (blocked on the gate) on a
    # detached pthread; the driver continues here.
    spawn_drop[GatedDropSentinel](sentinel^)

    # The destructor cannot have finished: the gate is still closed.
    assert_equal(
        Int(latch[].done[].load()),
        0,
        "spawn_drop returned but the destructor already finished: the"
        " primitive is synchronous",
    )

    # Open the gate, then wait (no deadline) for the destructor to finish.
    _ = latch[].gate[].fetch_add(Int64(1))
    while latch[].done[].load() == Int64(0):
        pass
    assert_equal(
        Int(latch[].done[].load()),
        1,
        "the destructor ran exactly once, on the background thread",
    )


def main() raises:
    test_spawn_drop_returns_before_destructor()

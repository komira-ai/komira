# =============================================================================
# spawn_drop: deferred-deallocation primitive for steal_merge
# =============================================================================
#
# The Mojo equivalent of `std::thread::spawn(move || drop(to_drop))`.
#
# Test contract:
#   We construct a SlowDropSentinel whose destructor sleeps 50ms and
#   stamps an Atomic[Int64] timestamp. The driver records its OWN
#   timestamp immediately after `spawn_drop` returns. The expected
#   ordering is `driver_return_ts << destructor_finished_ts`.
#
# A synchronous drop would run the destructor at the end of the function
# (when the local var dropped), so `driver_return_ts >=
# destructor_finished_ts`.
#
# With `spawn_drop`: it hands the sentinel to a detached
# pthread. The destructor runs on the background thread; the driver
# returns immediately. We therefore observe `driver_return_ts <
# destructor_finished_ts` (with the 50ms sleep providing the gap).
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import alloc, UnsafePointer, OwnedPointer
from std.testing import assert_true
from std.time import perf_counter_ns, sleep

from komira_core.concurrency.spawn_drop import spawn_drop


# -----------------------------------------------------------------------------
# SlowDropSentinel — Movable + Deinitable. Carries an
# OwnedPointer[Atomic[Int64]] to a heap slot the test reads after
# expecting the drop to have completed.
# -----------------------------------------------------------------------------


struct SlowDropSentinel(Movable, Deinitable):
    """A test sentinel whose destructor sleeps 50ms then writes
    `perf_counter_ns()` into a heap-resident Atomic[Int64] the test
    can poll.

    The OwnedPointer[Atomic[DType.int64]] hands ownership of the
    timestamp slot from the test driver to the sentinel; the
    destructor publishes the timestamp before the slot drops.
    """
    var ts_slot: OwnedPointer[AtomicI64]

    def __init__(out self, var ts_slot: OwnedPointer[AtomicI64]):
        self.ts_slot = ts_slot^

    def __deinit__(deinit self):
        # Sleep 50ms (50_000_000 ns) on the executing thread before
        # publishing the timestamp. The driver's read of the timestamp
        # AFTER the spawn_drop call should still see Int64(0) because
        # the driver returns ahead of this destructor.
        sleep(0.050)
        AtomicI64.store(
            UnsafePointer(to=self.ts_slot[]).unsafe_bitcast[Scalar[DType.int64]](),
            Int64(perf_counter_ns()),
        )


# -----------------------------------------------------------------------------
# Driver helper: build sentinel pointing at a stable Atomic slot.
# -----------------------------------------------------------------------------


def _new_ts_slot() -> OwnedPointer[AtomicI64]:
    """Heap-allocate a single Atomic[Int64] slot, init to 0."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Int64(0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


# -----------------------------------------------------------------------------
# Test 1 — spawn_drop returns BEFORE the destructor finishes.
#
# We aliased the timestamp slot via a second OwnedPointer that survives
# the move (the sentinel takes one OwnedPointer; we keep an aliasing
# read-only pointer that we constructed from the SAME raw pointer). To
# avoid double-free, we pass `unsafe_from_raw_pointer` to the sentinel
# and `unsafe_from_raw_pointer=...` for the read-only alias is NOT used
# — instead we hand-thread the raw pointer separately.
# -----------------------------------------------------------------------------


def test_spawn_drop_returns_before_destructor() raises:
    """Sentinel's destructor sleeps 50ms; spawn_drop must return well
    before that. We assert (a) the timestamp slot is still 0 when we
    capture `driver_return_ts`, and (b) after a 200ms wait it is
    non-zero.
    """
    # Build a stable raw pointer to the timestamp slot. The sentinel
    # holds an OwnedPointer over this raw pointer. We keep a SECOND
    # raw pointer for read-only polling — read-only alias is sound
    # because Atomic[Int64].store/load is thread-safe and the slot is
    # not freed until the OwnedPointer (held by the sentinel) drops on
    # the background thread; we wait beyond that drop time before
    # exiting the test.
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Int64(0))
    var read_alias = raw  # alias; same address

    var owned_for_sentinel = OwnedPointer[AtomicI64](
        unsafe_from_raw_pointer=raw
    )
    var sentinel = SlowDropSentinel(owned_for_sentinel^)

    # Hand the sentinel to spawn_drop. After this call the destructor
    # is running on a detached pthread; the driver continues here.
    spawn_drop[SlowDropSentinel](sentinel^)
    var driver_return_ts = Int64(perf_counter_ns())

    # Immediately after spawn_drop returns, the destructor's 50ms sleep
    # has barely started. The slot should still be 0.
    var ts_at_return = AtomicI64.load(
        read_alias.unsafe_bitcast[Scalar[DType.int64]]()
    )
    assert_true(
        ts_at_return == Int64(0),
        "spawn_drop returned but destructor already finished — primitive is synchronous",
    )

    # Wait long enough for the destructor's sleep + slot-write to
    # happen. 200ms is 4x the destructor's 50ms sleep, leaves headroom
    # for thread scheduling jitter.
    sleep(0.200)

    var ts_after_wait = AtomicI64.load(
        read_alias.unsafe_bitcast[Scalar[DType.int64]]()
    )
    # Destructor must have published a non-zero timestamp by now (it
    # ran during the 200ms sleep). Combined with the assert above
    # (`ts_at_return == 0`), this proves the destructor ran
    # AFTER spawn_drop returned: at the return point the slot was
    # still 0; after waiting it is non-zero. NB: `perf_counter_ns()`
    # values can differ between parent and pthread-spawned child on
    # macOS / Apple Silicon (the clock base is not necessarily the
    # same), so we don't compare absolute ns values across threads
    # — we use the slot's monotonic 0 → non-zero transition as the
    # ordering signal.
    _ = driver_return_ts  # silence "never used" (kept for diagnostics)
    assert_true(
        ts_after_wait > Int64(0),
        "destructor never published timestamp — spawn_drop did not run the drop",
    )

    # NB: `raw` (and thus `read_alias`) was freed on the background
    # thread when the sentinel's OwnedPointer dropped. We do NOT free
    # `raw` here. The 200ms wait above ensures the free has happened
    # before the test exits, avoiding a leaked allocation report from
    # any sanitizer.


def main() raises:
    test_spawn_drop_returns_before_destructor()

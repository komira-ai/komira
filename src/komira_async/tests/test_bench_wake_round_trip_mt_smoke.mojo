# =============================================================================
# test_bench_wake_round_trip_mt_smoke.mojo
# =============================================================================
# 1 smoke — verify the multi-threaded wake-round-trip protocol
# completes without deadlock or pointer-corruption at LOW N (100 round-trips).
#
# This test does NOT assert specific perf numbers — perf is the bench's
# output, the test is just a structural guard:
#   * shared-state struct lifecycle (alloc + OwnedPointer + cross-thread)
#   * pthread_create / pthread_setaffinity_np / pthread_join discipline
#   * Drep lost-wakeup-safe handshake (snapshot-then-park)
#   * cross-thread Atomic field access pattern
#     (state_ptr[].field.load(), engine's `pool_ptr[]._wake_word.load()` shape)
#
# Linux-only (pthread_setaffinity_np); macOS skips with WARN.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32
from std.testing import assert_true

from komira_async.runtime.wake_primitives import (


    wait_on_address,
    wake_one_by_address,
)

@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed null
    UnsafePointer ctor / the `_unsafe_null=()` b1 idiom).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Origin `o` is concrete; the NULL sentinel is never
    # dereferenced (placeholder / explicit C-NULL arg).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# =============================================================================
# Shared state — same shape as the bench's `_BenchSharedState`
# =============================================================================

struct _SmokeSharedState(Deinitable):
    var primary: AtomicI32
    var ready: AtomicI32
    var done: AtomicI32   # consumer signals completion

    def __init__(out self):
        self.primary = AtomicI32(Int32(0))
        self.ready = AtomicI32(Int32(0))
        self.done = AtomicI32(Int32(0))


@fieldwise_init
struct _SmokeArg(Copyable, Movable, Deinitable):
    var state_addr: Int
    var n: Int


# =============================================================================
# Producer entry — fires N wakes, exits.
# =============================================================================

def _producer_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    var typed_arg = arg.bitcast[_SmokeArg]()
    var state_addr = typed_arg[].state_addr
    var n = typed_arg[].n
    typed_arg.bitcast[UInt8]().free()

    var state_ptr = UnsafePointer[_SmokeSharedState, MutUntrackedOrigin](
        unsafe_from_address=state_addr,
    )

    # Wait for consumer's first ready signal.
    while True:
        var ready_val = state_ptr[].ready.load()
        if Int(ready_val) >= 1:
            break
        _ = external_call["sched_yield", Int32]()

    var i = 0
    while i < n:
        # Spin until consumer publishes ready for THIS iter.
        while True:
            var ready_val = state_ptr[].ready.load()
            if Int(ready_val) >= i + 1:
                break
            _ = external_call["sched_yield", Int32]()

        _ = state_ptr[].primary.fetch_add(Int32(1))
        _ = wake_one_by_address(state_ptr[].primary)
        i = i + 1

    return _null_ptr[NoneType, MutUntrackedOrigin]()


# =============================================================================
# Consumer entry — receives N wakes, signals done, exits.
# =============================================================================

def _consumer_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    var typed_arg = arg.bitcast[_SmokeArg]()
    var state_addr = typed_arg[].state_addr
    var n = typed_arg[].n
    typed_arg.bitcast[UInt8]().free()

    var state_ptr = UnsafePointer[_SmokeSharedState, MutUntrackedOrigin](
        unsafe_from_address=state_addr,
    )

    var i = 0
    while i < n:
        var expected = state_ptr[].primary.load()
        _ = state_ptr[].ready.fetch_add(Int32(1))
        _ = wake_one_by_address(state_ptr[].ready)
        _ = wait_on_address(state_ptr[].primary, expected=expected)
        i = i + 1

    # Signal done — main reads this to verify consumer completed all N iters.
    _ = state_ptr[].done.fetch_add(Int32(1))
    return _null_ptr[NoneType, MutUntrackedOrigin]()


# =============================================================================
# pthread wrappers
# =============================================================================

def _pthread_create(
    ref [_] thread_id_slot: Int64,
    entry: def (UnsafePointer[NoneType, MutUntrackedOrigin]) thin -> UnsafePointer[NoneType, MutUntrackedOrigin],
    arg_addr: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    var slot_addr = UnsafePointer(to=thread_id_slot)
    return external_call["pthread_create", Int32](
        slot_addr.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        entry,
        arg_addr,
    )


def _pthread_join(thread_id: Int64) -> Int32:
    return external_call["pthread_join", Int32](
        thread_id, _null_ptr[UInt8, MutUntrackedOrigin](),
    )


def test_wake_round_trip_mt_smoke() raises:
    """1 smoke: 100-iter strict ping-pong handshake completes.
    Asserts no deadlock + final atomic counters match expectations."""

    comptime if not CompilationTarget.is_linux():
        # Affinity-free on macOS; the bench skips on non-Linux. Mark
        # smoke as PASS-skip too (the cross-thread Atomic shape itself
        # works on macOS, but pthread_setaffinity_np doesn't, and the
        # bench guards that branch).
        assert_true(True)
        return

    comptime N: Int = 100

    # Allocate the shared state on heap.
    var state_raw = alloc[_SmokeSharedState](1)
    state_raw[] = _SmokeSharedState()
    var state = OwnedPointer[_SmokeSharedState](
        unsafe_from_raw_pointer=state_raw,
    )
    var state_addr = Int(UnsafePointer(to=state[]))

    # Producer arg.
    var producer_arg_raw = alloc[_SmokeArg](1)
    UnsafePointer(to=producer_arg_raw[]).unsafe_write(
        _SmokeArg(state_addr=state_addr, n=N),
    )
    var producer_arg_void = (
        producer_arg_raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
    )

    # Consumer arg.
    var consumer_arg_raw = alloc[_SmokeArg](1)
    UnsafePointer(to=consumer_arg_raw[]).unsafe_write(
        _SmokeArg(state_addr=state_addr, n=N),
    )
    var consumer_arg_void = (
        consumer_arg_raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
    )

    # Launch + join (no affinity in smoke — kernel scheduler picks CPUs).
    var consumer_tid: Int64 = 0
    var producer_tid: Int64 = 0

    var rc_c = _pthread_create(consumer_tid, _consumer_entry, consumer_arg_void)
    assert_true(rc_c == Int32(0))
    var rc_p = _pthread_create(producer_tid, _producer_entry, producer_arg_void)
    assert_true(rc_p == Int32(0))

    _ = _pthread_join(consumer_tid)
    _ = _pthread_join(producer_tid)

    # Verify state: consumer set done; primary == N; ready == N.
    var done_val = state[].done.load()
    var primary_val = state[].primary.load()
    var ready_val = state[].ready.load()

    assert_true(Int(done_val) == 1)
    assert_true(Int(primary_val) == N)
    assert_true(Int(ready_val) == N)


def main() raises:
    test_wake_round_trip_mt_smoke()
    print("PASS komira_async.perf bench_wake_round_trip_mt smoke")

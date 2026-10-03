# =============================================================================
# test_bench_mutex_contention_smoke.mojo
# =============================================================================
# 4b smoke — verify the multi-threaded mutex contention protocol
# completes without deadlock or pointer-corruption at LOW N.
#
# This test does NOT assert specific perf numbers — perf is the bench's
# output, the test is just a structural guard:
#   * heap-stashed AsyncMutex (intentionally leaked)
#   * cross-thread AsyncMutex.lock() via wildcard-origin direct
#     reconstruction (NOT through a struct wrap — see bench file header)
#   * MutexGuard scope discipline (drop releases lock + wakes one waiter)
#   * pthread_create / pthread_join discipline
#
# Linux-only.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.testing import assert_true

from komira_async.sync.async_mutex import AsyncMutex

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



@fieldwise_init
struct _SmokeMutexArg(Copyable, Movable, Deinitable):
    var mutex_addr: Int
    var n_cycles: Int


def _worker_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    var typed_arg = arg.bitcast[_SmokeMutexArg]()
    var mutex_addr = typed_arg[].mutex_addr
    var n_cycles = typed_arg[].n_cycles
    typed_arg.bitcast[UInt8]().free()

    var mutex_ptr = UnsafePointer[AsyncMutex[Int], MutUntrackedOrigin](
        unsafe_from_address=mutex_addr,
    )

    var i = 0
    while i < n_cycles:
        try:
            var guard = mutex_ptr[].lock()
            var cur = guard.data()
            guard.set_data(cur + 1)
            _ = guard^
        except:
            return _null_ptr[NoneType, MutUntrackedOrigin]()
        i = i + 1

    return _null_ptr[NoneType, MutUntrackedOrigin]()


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


def test_mutex_contention_smoke() raises:
    """4b smoke: 2 threads × 50 cycles each on shared mutex."""

    comptime if not CompilationTarget.is_linux():
        assert_true(True)
        return

    comptime N_THREADS: Int = 2
    comptime N_CYCLES: Int = 50
    comptime EXPECTED_FINAL: Int = N_THREADS * N_CYCLES

    # Heap-stash mutex (intentionally leaked).
    var mutex_raw = alloc[AsyncMutex[Int]](1)
    UnsafePointer(to=mutex_raw[]).unsafe_write(AsyncMutex[Int].new(0))
    var mutex_addr = Int(mutex_raw)

    var thread_args = List[UnsafePointer[NoneType, MutUntrackedOrigin]]()
    var thread_tids = List[Int64](capacity=N_THREADS)
    var t = 0
    while t < N_THREADS:
        var arg_raw = alloc[_SmokeMutexArg](1)
        UnsafePointer(to=arg_raw[]).unsafe_write(
            _SmokeMutexArg(mutex_addr=mutex_addr, n_cycles=N_CYCLES),
        )
        var arg_void = arg_raw.bitcast[NoneType]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        thread_args.append(arg_void)
        thread_tids.append(Int64(0))
        t = t + 1

    t = 0
    while t < N_THREADS:
        var rc = _pthread_create(thread_tids[t], _worker_entry, thread_args[t])
        assert_true(rc == Int32(0))
        t = t + 1

    t = 0
    while t < N_THREADS:
        _ = _pthread_join(thread_tids[t])
        t = t + 1

    # Final value: take a guard, read data, release.
    var mutex_ptr = UnsafePointer[AsyncMutex[Int], MutUntrackedOrigin](
        unsafe_from_address=mutex_addr,
    )
    var final_guard = mutex_ptr[].lock()
    var final_value = final_guard.data()
    _ = final_guard^

    assert_true(Int(final_value) == EXPECTED_FINAL)


def main() raises:
    test_mutex_contention_smoke()
    print("PASS komira_async.perf bench_mutex_contention smoke")

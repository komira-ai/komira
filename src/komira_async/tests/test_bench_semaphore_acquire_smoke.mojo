# =============================================================================
# test_bench_semaphore_acquire_smoke.mojo
# =============================================================================
# 4c smoke — verify the multi-threaded semaphore acquire protocol
# completes without deadlock or pointer-corruption at LOW N.
#
# Linux-only.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.testing import assert_true

from komira_async.sync.semaphore import Semaphore

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
struct _SmokeSemArg(Copyable, Movable, Deinitable):
    var sem_addr: Int
    var n_cycles: Int


def _worker_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    var typed_arg = arg.bitcast[_SmokeSemArg]()
    var sem_addr = typed_arg[].sem_addr
    var n_cycles = typed_arg[].n_cycles
    typed_arg.bitcast[UInt8]().free()

    var sem_ptr = UnsafePointer[Semaphore, MutUntrackedOrigin](
        unsafe_from_address=sem_addr,
    )

    var i = 0
    while i < n_cycles:
        try:
            var permit = sem_ptr[].acquire()
            # Tiny "work" — yield to give other threads a chance.
            _ = external_call["sched_yield", Int32]()
            _ = permit^
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


def test_semaphore_acquire_smoke() raises:
    """4c smoke: 4 acquirers × 5 cycles each, 2 permits."""

    comptime if not CompilationTarget.is_linux():
        assert_true(True)
        return

    comptime N_PERMITS: Int = 2
    comptime N_ACQUIRERS: Int = 4
    comptime N_CYCLES: Int = 5

    var sem_raw = alloc[Semaphore](1)
    UnsafePointer(to=sem_raw[]).unsafe_write(Semaphore.new(UInt(N_PERMITS)))
    var sem_addr = Int(sem_raw)

    var thread_args = List[UnsafePointer[NoneType, MutUntrackedOrigin]]()
    var thread_tids = List[Int64](capacity=N_ACQUIRERS)
    var t = 0
    while t < N_ACQUIRERS:
        var arg_raw = alloc[_SmokeSemArg](1)
        UnsafePointer(to=arg_raw[]).unsafe_write(
            _SmokeSemArg(sem_addr=sem_addr, n_cycles=N_CYCLES),
        )
        var arg_void = arg_raw.bitcast[NoneType]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        thread_args.append(arg_void)
        thread_tids.append(Int64(0))
        t = t + 1

    t = 0
    while t < N_ACQUIRERS:
        var rc = _pthread_create(thread_tids[t], _worker_entry, thread_args[t])
        assert_true(rc == Int32(0))
        t = t + 1

    t = 0
    while t < N_ACQUIRERS:
        _ = _pthread_join(thread_tids[t])
        t = t + 1

    # After all threads finish, the semaphore should have all permits back.
    var sem_ptr = UnsafePointer[Semaphore, MutUntrackedOrigin](
        unsafe_from_address=sem_addr,
    )
    var available = sem_ptr[].available_permits()
    assert_true(Int(available) == N_PERMITS)


def main() raises:
    test_semaphore_acquire_smoke()
    print("PASS komira_async.perf bench_semaphore_acquire smoke")

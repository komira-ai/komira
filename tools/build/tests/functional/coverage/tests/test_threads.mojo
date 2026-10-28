# Test 47: N_THREADS threads each call quarter(i) for i in [0, N_CALLS), all
# at once, so every profile counter of quarter is incremented by several
# threads concurrently. The test checks what quarter returned; the counts
# the profile must hold are checked by :branch_counts_threads (BUCK).
#
# Mojo 1.0.0 ships no threading module, so the threads are raw
# pthread_create and pthread_join over std.ffi.external_call.
from std.ffi import external_call
from std.memory import UnsafePointer, alloc
from std.testing import assert_equal

from branchmt import quarter


comptime N_THREADS: Int = 8
comptime N_CALLS: Int = 1_000_000

# SAFETY: the C `void*` of pthread's start routine; used only at that FFI call.
comptime _VoidPtr = UnsafePointer[NoneType, MutUntrackedOrigin]


# SAFETY: returns NULL, used only as an FFI NULL argument.
@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    var none: Optional[UnsafePointer[T, o]] = None
    # SAFETY: `None` is the all-zero bit pattern of the pointer it wraps.
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


def _worker(arg: _VoidPtr) -> _VoidPtr:
    """pthread start routine: the sum of quarter(i) over [0, N_CALLS),
    written to this thread's own slot.

    # SAFETY: FFI-BOUNDARY. `arg` is this thread's slot of a heap block the
    # test allocates before pthread_create and frees after pthread_join.
    """
    var s = 0
    for i in range(N_CALLS):
        s += quarter(i)
    # SAFETY: this thread's own Int slot, alive until after the join.
    arg.bitcast[Int]()[] = s
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def main() raises:
    # SAFETY: freed after the join below; each index < N_THREADS.
    var slots = alloc[Int](N_THREADS)
    for t in range(N_THREADS):
        (slots + t).unsafe_write(-1)
    # SAFETY: the untracked copy goes only to pthread_create, before the free.
    var slots_u = slots.unsafe_origin_cast[MutUntrackedOrigin]()
    var tids = List[Int64]()
    for _t in range(N_THREADS):
        tids.append(Int64(0))
    var started = 0
    var rc = Int32(0)
    for t in range(N_THREADS):
        # SAFETY: `tids[t]` and the slot outlive the thread (joined below).
        rc = external_call["pthread_create", Int32](
            UnsafePointer(to=tids[t]).bitcast[UInt8](),
            _null_ptr[UInt8, MutUntrackedOrigin](),
            _worker,
            # SAFETY: slot t is in bounds and freed only after the join.
            (slots_u + t).bitcast[NoneType](),
        )
        if rc != Int32(0):
            break
        started += 1
    for t in range(started):
        _ = external_call["pthread_join", Int32](
            tids[t], _null_ptr[UInt8, MutUntrackedOrigin]()
        )
    var sums = List[Int]()
    for t in range(N_THREADS):
        sums.append(slots_u[t])
    slots.free()
    assert_equal(started, N_THREADS, "pthread_create failed")
    # Per thread: N_CALLS / 4 calls return 2, N_CALLS / 4 return 1.
    for t in range(N_THREADS):
        assert_equal(sums[t], 3 * (N_CALLS // 4), "a thread's sum")

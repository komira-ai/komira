# =============================================================================
# fork_join -- run one body on N threads and join them all
# =============================================================================
#
# The fork-join shape every multi-threaded test and bench in the tree wants:
# `n` threads each call `body.run(tid)` with their own index `0..n-1`, and
# `fork_join` returns only after every thread has exited.
#
#     struct Work(ForkJoinBody):
#         var total: Pointer[AtomicI64, origin]
#         def run(self, tid: Int) raises:
#             ...
#
#     fork_join(work, 4)
#
# Safety shape: the body is shared by reference. Each thread reaches it
# through a `Pointer[B, o]` held in its own slot, so the borrow checker keeps
# `body` alive for the whole call, and no address is rebuilt from an integer.
# The one raw pointer is the opaque `void *` the C thread API requires; it
# points at the thread's own slot, which `fork_join` owns and frees only
# after the join barrier.
#
# `body` is borrowed immutably and is shared by all `n` threads at once, so
# state the threads mutate must live behind atomics or per-thread cells the
# body points to.
#
# Failure rules:
#   * every thread that started is joined before anything is raised;
#   * if bodies raise, the error of the LOWEST tid is rethrown, with the
#     number of failed workers appended when more than one failed;
#   * if `pthread_create` fails after `k` threads started, the `k` are joined
#     and `fork_join` raises "started k of n".
# =============================================================================

from std.memory import Pointer, UnsafePointer

from ._pthread import (
    FFI_ORIGIN,
    FfiHandle,
    ffi_null,
    pthread_create_thread,
    pthread_join_thread,
)


trait ForkJoinBody(Movable):
    """A unit of work run once per thread by `fork_join`."""

    def run(self, tid: Int) raises:
        """Run this thread's share. `tid` is in `0..n-1`, unique per thread."""
        ...


struct _Slot[B: ForkJoinBody, o: Origin](Movable):
    """One thread's private record. Only that thread writes it while it runs."""

    var body: Pointer[Self.B, Self.o]
    var tid: Int
    var failed: Bool
    var message: String

    def __init__(out self, body: Pointer[Self.B, Self.o], tid: Int):
        self.body = body
        self.tid = tid
        self.failed = False
        self.message = String()


def _entry[B: ForkJoinBody, o: Origin](arg: FfiHandle) -> FfiHandle:
    """pthread start routine: run the body for this thread's slot.

    # SAFETY: FFI-BOUNDARY. `arg` is the address of this thread's `_Slot`,
    # which lives in a `List` that `fork_join` neither grows nor frees until
    # every started thread is joined. Slots are distinct per thread, so no two
    # threads write the same slot.
    """
    var slot = arg.bitcast[_Slot[B, o]]().unsafe_mut_cast[True]()
    try:
        slot[].body[].run(slot[].tid)
    except e:
        var text = String(e)
        slot[].failed = True
        slot[].message = text^
    return ffi_null()


def fork_join[
    B: ForkJoinBody, o: Origin
](ref [o] body: B, n: Int) raises:
    """Run `body.run(tid)` on `n` threads (`tid` = 0..n-1) and join them all.

    Raises for `n < 0`, for a failed thread start (after joining the threads
    that did start), or with the lowest-tid error if a body raised.
    """
    if n < 0:
        raise Error("fork_join: n must be >= 0, got " + String(n))
    if n == 0:
        return

    var slots = List[_Slot[B, o]](capacity=n)
    for i in range(n):
        slots.append(_Slot[B, o](Pointer[B, o](to=body), i))
    var tids = List[UInt64](length=n, fill=UInt64(0))

    var started = 0
    var rc = Int32(0)
    var entry = _entry[B, o]
    for i in range(n):
        # SAFETY: `slots` has its final capacity, so this address is stable
        # until `slots` is dropped, which happens after the join loop below.
        var arg = (
            UnsafePointer(to=slots[i])
            .bitcast[NoneType]()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[FFI_ORIGIN]()
        )
        rc = pthread_create_thread(tids[i], entry, arg)
        if rc != Int32(0):
            break
        started += 1

    # THE BARRIER: join every thread that started, before reading any slot or
    # freeing anything.
    for i in range(started):
        _ = pthread_join_thread(tids[i])

    if rc != Int32(0):
        raise Error(
            "fork_join: pthread_create failed (rc="
            + String(Int(rc))
            + "), started "
            + String(started)
            + " of "
            + String(n)
        )

    var failures = 0
    var first = -1
    for i in range(n):
        if slots[i].failed:
            failures += 1
            if first < 0:
                first = i
    if failures > 0:
        var msg = slots[first].message
        if failures > 1:
            msg += " (" + String(failures) + " of " + String(n) + " workers failed)"
        raise Error(msg)

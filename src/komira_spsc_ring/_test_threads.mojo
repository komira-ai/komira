# =============================================================================
# _test_threads.mojo -- fork-join over pthreads, for this package's tests
# =============================================================================
#
# INTERIM. The ring's concurrency tests need `n` threads that run at the same
# time and a join. Nothing in the tree offers that yet: `spawn_drop` is
# detached and the stdlib build used here has no `parallelize`. When the shared
# libc binding of pthread_create/pthread_join exists, this file is replaced by an
# import of it. Not part of the ring's API; used only by the tests and the bench.
#
# `n` threads each call `body.run(tid)` with their own index `0..n-1`, and
# `spawn_join` returns only after every thread has exited. If bodies raise, the
# error of the lowest tid is rethrown; if `pthread_create` fails after `k`
# threads started, those `k` are joined and `spawn_join` raises.
#
# Fault seam: `spawn_join_with_fault` takes a `SpawnFault`, whose `fail_rc(i)`
# is asked before thread `i` is started. 0 means "start it with pthread_create";
# nonzero means "do not call pthread_create, treat that value as its return
# code". `spawn_join` passes `_NoFault`, a zero-sized type whose answer is the
# constant 0, so the check folds away. The seam carries no pointer and no
# global state, so tests make the k-th start fail without touching memory
# limits, load or CPU placement.
# =============================================================================

from std.ffi import external_call
from std.memory import Pointer, UnsafePointer

# Canonical FFI origin (FFI-BOUNDARY: pthread). A concrete (non-wildcard)
# origin; the `void *` args and returns are opaque and cross the ABI by value.
comptime FFI_ORIGIN = ImmStaticOrigin
comptime FfiHandle = UnsafePointer[NoneType, FFI_ORIGIN]
comptime FfiByte = UnsafePointer[UInt8, FFI_ORIGIN]
comptime ThreadEntry = def (FfiHandle) thin -> FfiHandle


@always_inline
def ffi_null() -> FfiHandle:
    """A NULL opaque handle (the stdlib has no null pointer constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer; `None` is the all-zero NULL bit pattern. No removed null
    # constructor and no `unsafe_from_address`.
    """
    var none: Optional[FfiHandle] = None
    return UnsafePointer(to=none).bitcast[FfiHandle]()[]


@always_inline
def pthread_create_thread(
    mut tid: UInt64, entry: ThreadEntry, arg: FfiHandle
) -> Int32:
    """Start a joinable thread running `entry(arg)`; the handle goes to `tid`.

    Returns the `pthread_create` return code (0 on success).
    """
    return external_call["pthread_create", Int32](
        UnsafePointer(to=tid).bitcast[UInt8](),
        ffi_null().bitcast[UInt8](),
        entry,
        arg,
    )


@always_inline
def pthread_join_thread(tid: UInt64) -> Int32:
    """Block until thread `tid` exits; the thread's return value is dropped."""
    return external_call["pthread_join", Int32](
        tid, ffi_null().bitcast[UInt8]()
    )


trait SpawnJoinBody(Movable):
    """A unit of work run once per thread by `spawn_join`."""

    def run(self, tid: Int) raises:
        """Run this thread's share. `tid` is in `0..n-1`, unique per thread."""
        ...


trait SpawnFault(Movable):
    """Decides, per thread index, whether its start is made to fail."""

    def fail_rc(self, index: Int) -> Int32:
        """0: start thread `index` for real. Nonzero: skip pthread_create and
        report this value as its return code."""
        ...


struct _NoFault(SpawnFault):
    """The production answer: every thread is started for real."""

    def __init__(out self):
        pass

    @always_inline
    def fail_rc(self, index: Int) -> Int32:
        return Int32(0)


struct _Slot[B: SpawnJoinBody, o: Origin](Movable):
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


def _entry[B: SpawnJoinBody, o: Origin](arg: FfiHandle) -> FfiHandle:
    """pthread start routine: run the body for this thread's slot.

    # SAFETY: FFI-BOUNDARY. `arg` is the address of this thread's `_Slot`,
    # which lives in a `List` that `spawn_join` neither grows nor frees until
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


def spawn_join[
    B: SpawnJoinBody, o: Origin
](ref [o] body: B, n: Int) raises:
    """Run `body.run(tid)` on `n` threads (`tid` = 0..n-1) and join them all.

    Raises for `n < 0`, for a failed thread start (after joining the threads
    that did start), or with the lowest-tid error if a body raised.
    """
    spawn_join_with_fault(body, n, _NoFault())


def spawn_join_with_fault[
    B: SpawnJoinBody, o: Origin, F: SpawnFault
](ref [o] body: B, n: Int, fault: F) raises:
    """`spawn_join` with a fault seam: before starting thread `i`, a nonzero
    `fault.fail_rc(i)` stands in for a failing `pthread_create`."""
    if n < 0:
        raise Error("spawn_join: n must be >= 0, got " + String(n))
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
        rc = fault.fail_rc(i)
        if rc == Int32(0):
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
            "spawn_join: pthread_create failed (rc="
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

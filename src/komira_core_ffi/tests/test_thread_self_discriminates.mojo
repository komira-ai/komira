# =============================================================================
# src/komira_core_ffi/tests/test_thread_self_discriminates.mojo
#
# Guards `komira_core_ffi.posix._thread_self()` — the driver-vs-pool-worker
# attribution primitive behind tid-stamped phase traces.
#
# WHY THIS TEST EXISTS AND WHAT IT MUST KILL
#
# The whole point of `_thread_self()` is to settle "is this region on the serial
# driver or on the pool?" from a RUN, because a profile SHARE can mis-attribute
# work (an inlined worker body reads as overhead on its caller). A trace built
# on a broken tid primitive would be WORSE than no trace: it would look like
# evidence and read like a profile share.
#
# The failure mode that matters is therefore NOT "returns 0" — it is
# "returns THE SAME VALUE on every thread", which would make every region look
# like it runs on the driver and would silently confirm whatever the reader
# already believed. A single-threaded assertion (non-zero, self-consistent)
# CANNOT see that. So the test must observe the value from more than one live
# thread at once.
#
# THE DISCRIMINATOR
#   test_thread_self_differs_across_threads: assert_equal on an EXACT distinct
#   count. N REAL OS threads run concurrently, so {main tid} u {worker tids}
#   must contain at least two distinct values. A constant-returning mutant
#   collapses that set to size 1 and the assert_equal on `>= 2` fails.
#
# ⚠ MOJO 1.0.0 ships no threading module (`std.algorithm.parallelize` is
# gone), so the fork-join below is raw `pthread_create` + `pthread_join` over
# `std.ffi.external_call`. A SERIAL LOOP IS NOT AN OPTION: this test's entire
# claim is that `_thread_self()` returns DIFFERENT values on DIFFERENT threads.
# Run the worker body serially and `distinct` collapses to 1 on a CORRECT
# primitive — the test would not merely prove less, it would report the
# mutant's answer.
# Real OS threads are the only faithful replacement.
#
# WHY `>= 2` AND NOT `== N+1`: `pthread_create` guarantees N NEW threads, so
# `>= 2` is a WEAKER statement than what actually holds. It is deliberate:
# `>= 2` is exactly the property a constant-returning mutant violates.
#
# MUTANT THAT DISCRIMINATES:
#   `return external_call["pthread_self", UInt64]()` -> `return UInt64(0xDEADBEEF)`
#   A NON-ZERO constant is deliberately chosen over `UInt64(0)`: a zero mutant
#   is also caught by the `a != 0` assertion in the stability test, so it would
#   not prove the cross-thread check is load-bearing. `0xDEADBEEF` passes BOTH the
#   stability assertion AND the non-zero assertion, and is killed ONLY by
#   `distinct >= 2` collapsing to `distinct == 1`. That is what makes the
#   discriminator non-vacuous.
#   Expected: MUTANT -> 1 FAIL / 1 PASS. CONTROL -> 2 PASS.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.testing import TestSuite, assert_equal, assert_true

from komira_core_ffi.posix import _thread_self


comptime N_WORKERS: Int = 8

comptime _VoidPtr = UnsafePointer[NoneType, MutUntrackedOrigin]


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (Mojo has no null
    UnsafePointer constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. FFI NULL args only.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


def _entry_record_tid(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine.

    Each thread gets its OWN slot pointer, so no two threads write the same
    address and the recorded set needs no lock.

    # SAFETY: FFI-BOUNDARY. `arg` is `slots + i` for this thread's `i`, from a
    # heap block the calling frame allocates before `pthread_create` and frees
    # only AFTER the join barrier, so it strictly outlives every reader.
    """
    arg.bitcast[UInt64]()[] = _thread_self()
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_thread_self_stable_on_one_thread() raises:
    """Two calls on the SAME thread return the SAME value.

    Necessary (a tid that changed under a thread would make every trace
    unreadable) but NOT sufficient — a constant-returning mutant also passes
    this. See `test_thread_self_differs_across_threads` for the discriminator.
    """
    var a = _thread_self()
    var b = _thread_self()
    assert_equal(a, b)
    # A live thread never has a null pthread_t on either supported platform.
    assert_true(a != UInt64(0))


def test_thread_self_differs_across_threads() raises:
    """THE DISCRIMINATOR: the tid set observed across a real fork-join has >1
    distinct value.

    A raw pthread fork-join is used deliberately instead of a production
    dispatcher: the primitive under test is a thread-identity FFI, so the test
    wants the cheapest construct that puts more than one thread on the CPU at
    once, with no engine state in the way.
    """
    var main_tid = _thread_self()

    # One heap slot per worker, zero-initialised. Each thread receives a
    # pointer to ITS OWN slot, so the writes never alias.
    var slots = alloc[UInt64](N_WORKERS)
    for i in range(N_WORKERS):
        (slots + i).unsafe_write(UInt64(0))
    var slots_u = slots.unsafe_origin_cast[MutUntrackedOrigin]()

    var tids = List[Int64]()
    for _i in range(N_WORKERS):
        tids.append(Int64(0))

    var started = 0
    var rc = Int32(0)
    for i in range(N_WORKERS):
        rc = external_call["pthread_create", Int32](
            UnsafePointer(to=tids[i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_record_tid,  # start_routine (DIRECT thin-fn reference)
            (slots_u + i).bitcast[NoneType](),  # arg = this worker's slot
        )
        if rc != Int32(0):
            break
        started += 1

    # THE BARRIER. Join every thread that actually started, THEN read the
    # slots, THEN free them — in that order, so no live thread outlives the
    # memory it writes.
    for i in range(started):
        _ = external_call["pthread_join", Int32](
            tids[i], _null_ptr[UInt8, MutUntrackedOrigin]()
        )

    var seen = List[UInt64]()
    for i in range(N_WORKERS):
        seen.append(slots_u[i])
    slots.free()

    # A thread that never STARTED must never be silently mistaken for a thread
    # that did no work — that is the one failure mode that would turn this
    # discriminator green while testing nothing.
    if rc != Int32(0):
        raise Error(
            "pthread_create failed (rc="
            + String(Int(rc))
            + ") after "
            + String(started)
            + " of "
            + String(N_WORKERS)
            + " workers -- the cross-thread discriminator did not run"
        )

    # Every worker must have written SOMETHING (0 means the worker body never
    # ran, which would make the distinct-count assertion vacuous).
    for w in range(N_WORKERS):
        assert_true(seen[w] != UInt64(0))

    # Distinct count over {main} u {workers}.
    var distinct = List[UInt64]()
    distinct.append(main_tid)
    for w in range(N_WORKERS):
        var found = False
        for d in range(len(distinct)):
            if distinct[d] == seen[w]:
                found = True
                break
        if not found:
            distinct.append(seen[w])

    # >= 2 (not == N_WORKERS+1): `>= 2` is the property that actually matters
    # and is the property a constant-returning mutant violates; see the header
    # note.
    assert_true(
        len(distinct) >= 2,
        String(
            "_thread_self() returned the SAME value on the driver and on every"
            " one of "
        )
        + String(N_WORKERS)
        + String(
            " worker threads. It does not discriminate threads, so every"
            " tid-based trace built on it is"
            " meaningless. distinct="
        )
        + String(len(distinct)),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

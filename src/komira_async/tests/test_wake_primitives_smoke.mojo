# =============================================================================
# test_wake_primitives_smoke.mojo
# =============================================================================
# wake-by-address / wait-on-address smoke.
#
# Single-thread smoke: verify wait_on_address with a stale `expected` value
# returns immediately (-EAGAIN equivalent), and wake_all_by_address on an
# unwaited word returns success (no waiters → no-op kernel-side).
#
# Cross-thread test (real park + wake) gated on (pthread launch).
#
# Mac port: the no-waiters return value differs by kernel:
#   - Linux futex(FUTEX_WAKE) returns 0 (number of woken waiters; valid >=0).
#   - Darwin __ulock_wake with ULF_NO_ERRNO returns -ENOENT (-2) when no
#     waiters are parked on the address — this is success semantics on
#     Darwin (the call did its job; there was nothing to wake).
# Both indicate "operation completed without error in a meaningful way";
# the assertion below accepts both shapes. Asserting `rc >= 0` is a
# Linux-only assumption that is incorrect on osx-arm64.
# =============================================================================

from std.sys.info import CompilationTarget

from std.memory import OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32
from std.testing import assert_true

from komira_async.runtime.wake_primitives import (
    cpu_pause,
    wait_on_address,
    wake_all_by_address,
    wake_one_by_address,
)


def _wake_no_waiters_ok(rc: Int32) -> Bool:
    """Cross-platform predicate for "wake_*_by_address succeeded with
    no waiters parked on the address".

    - Linux futex(FUTEX_WAKE): rc == 0 (number of woken waiters).
    - Darwin __ulock_wake | ULF_NO_ERRNO: rc == -2 (-ENOENT) when no
      waiters are parked. ULF_NO_ERRNO returns -errno via the syscall
      return; ENOENT here means "address has no parked threads",
      which is a meaningful no-op success on Darwin.
    """

    comptime if CompilationTarget.is_macos():
        # Accept Darwin's -ENOENT no-waiter shape AND any non-negative
        # return (defensive: future xnu kernels may report 0 here).
        return rc >= Int32(0) or rc == Int32(-2)
    else:
        return rc >= Int32(0)


def test_wake_all_no_waiters_no_op() raises:
    """wake_all_by_address on a word with no waiters returns
    a kernel-defined success value (Linux: 0; Darwin: -ENOENT). Either
    is a valid no-op."""
    var raw = alloc[AtomicI32](1)
    raw[] = AtomicI32(Int32(0))
    var word = OwnedPointer[AtomicI32](unsafe_from_raw_pointer=raw)
    var rc = wake_all_by_address(word[])
    assert_true(
        _wake_no_waiters_ok(rc),
        "wake_all_by_address with no waiters should return 0 (Linux) or -2 (Darwin)",
    )


def test_wake_one_no_waiters_no_op() raises:
    """wake_one_by_address on a word with no waiters returns
    a kernel-defined success value (Linux: 0; Darwin: -ENOENT)."""
    var raw = alloc[AtomicI32](1)
    raw[] = AtomicI32(Int32(0))
    var word = OwnedPointer[AtomicI32](unsafe_from_raw_pointer=raw)
    var rc = wake_one_by_address(word[])
    assert_true(
        _wake_no_waiters_ok(rc),
        "wake_one_by_address with no waiters should return 0 (Linux) or -2 (Darwin)",
    )


def test_wait_on_address_stale_expected_returns_immediately() raises:
    """wait_on_address with `expected` != current value returns
    immediately with -EAGAIN (or equivalent); we just verify it doesn't park
    forever. We bump the word + then call wait with the OLD value — kernel
    sees mismatch + returns immediately."""
    var raw = alloc[AtomicI32](1)
    raw[] = AtomicI32(Int32(0))
    var word = OwnedPointer[AtomicI32](unsafe_from_raw_pointer=raw)
    # Bump word from 0 to 5. Use static form (the canonical shape) — instance
    # `.store()` on Atomic[DType.int32] takes `mut self` which conflicts
    # with the OwnedPointer[]= deref form here.
    AtomicI32.store(UnsafePointer(to=word[]).unsafe_bitcast[Scalar[DType.int32]](), Int32(5))
    # Wait with `expected=0` — kernel sees 5 != 0 + returns immediately.
    var rc = wait_on_address(word[], expected=Int32(0))
    # rc < 0 (EAGAIN) or 0 (already-woken) — either is acceptable; we
    # mainly care that the call didn't block.
    _ = rc  # Unused; the return is informational.
    # If we got here, the call returned synchronously.
    assert_true(True)


def test_cpu_pause_returns() raises:
    """cpu_pause() returns without crashing. Hot-path hint
    used by spin loops; current impl is sched_yield()."""
    cpu_pause()
    assert_true(True)


def main() raises:
    test_wake_all_no_waiters_no_op()
    test_wake_one_no_waiters_no_op()
    test_wait_on_address_stale_expected_returns_immediately()
    test_cpu_pause_returns()
    print("PASS komira_async.runtime.wake_primitives smoke")

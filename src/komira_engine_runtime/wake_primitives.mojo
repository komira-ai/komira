# =============================================================================
# FFI-BOUNDARY: cross-platform wake-by-address + wait-on-address primitives
# =============================================================================
# Library:
#   * Darwin: libSystem — `__ulock_wake` / `__ulock_wait` (Apple-private,
#     stable since macOS 10.12). Used internally by libpthread,
#     libdispatch, and Foundation; will not be removed without breaking
#     every Apple framework. Apple's app review forbids App Store apps
#     from calling __ulock_*, but server / SDK code (us) is unaffected.
#   * Linux: glibc — `syscall(SYS_futex, ...)`. INT_MAX wakes ALL
#     waiters; FUTEX_PRIVATE_FLAG = process-private (we never share
#     futex words across processes).
#
# This module mirrors libdispatch's own `_dispatch_wake_by_address`
# cross-platform shim at `apple/swift-corelibs-libdispatch/src/shims/
# lock.c:569-582`. ONE conceptual primitive (wake-all-waiters-by-
# address), comptime-branched at the syscall layer ONLY. The call sites
# in `worker_pool.mojo` are platform-agnostic.
#
# Test-scope (per maintainer directive on Task #121 + #122): macOS arm64
# verified GREEN in Spike D.1 (40-run sweep, max wake latency 36-106us
# for 10 workers parked on `__ulock_wait`). Linux x86_64 code path
# written as production code with verified syscall numbers, op codes,
# and arg ordering — confirmed against `man 2 futex` and
# `libdispatch/src/shims/lock.c:436`. Linux runtime verification gated
# on a Linux runner being available (per Workstream C).
#
# SAFETY: every wildcard origin in this file is correct because:
#   (a) the syscall ABI is C — no Mojo-side ASAP destruction tracking
#       across the syscall is desired or expected;
#   (b) the kernel does NOT retain the address pointer past the syscall
#       return — every futex/ulock syscall does its address access
#       under the syscall's own lock and returns;
#   (c) the address is always a `&Atomic[DType.int32].value` field on a
#       pool-owned struct (WorkerPool) whose lifetime is bound by
#       pthread_join — workers cannot be parked after the pool teardown
#       barrier completes.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI32
from std.sys.info import CompilationTarget


# -----------------------------------------------------------------------------
# Canonical Komira b2 FFI origin (FFI-BOUNDARY: futex / __ulock syscalls).
#
# Mojo removed the `UnsafePointer[T]()` null ctor + Boolable. The prior
# `MutExternalOrigin` wildcard is REPLACED here by
# `StaticConstantOrigin`, a CONCRETE (non-wildcard) origin valid for the syscall
# ABI boundary. The kernel does NOT retain the address pointer past the syscall
# (see the SAFETY block above), so an immutable static origin is sound for the
# unused NULL timeout/uaddr2 args; the live futex-word address is coerced to the
# same origin from its caller-held Atomic storage in the helpers below.
# -----------------------------------------------------------------------------
comptime _FFI_ORIGIN = ImmStaticOrigin
comptime _FfiByte = UnsafePointer[UInt8, _FFI_ORIGIN]


@always_inline
def _ffi_null() -> UnsafePointer[NoneType, _FFI_ORIGIN]:
    """Raw NULL opaque-handle (replaces the b2-removed null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (modular/mojo/proposals/non-null-pointer.md); `None` is
    # the all-zero NULL bit pattern. No removed null ctor, no banned
    # `unsafe_from_address=Int(0)`.
    """
    var none: Optional[UnsafePointer[NoneType, _FFI_ORIGIN]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[NoneType, _FFI_ORIGIN]]()[]


# =============================================================================
# Linux syscall numbers (comptime, per-arch)
# =============================================================================
# SYS_futex on Linux:
#   - x86_64:  202
#   - aarch64: 422
# We comptime-select. Other Linux arches not supported by Komira.

comptime SYS_FUTEX_X86_64: Int64 = 202
comptime SYS_FUTEX_AARCH64: Int64 = 422


# =============================================================================
# Linux futex op codes
# =============================================================================
# FUTEX_WAIT = 0; FUTEX_WAKE = 1; FUTEX_PRIVATE_FLAG = 128.
# FUTEX_WAIT_PRIVATE = 0 | 128 = 128.
# FUTEX_WAKE_PRIVATE = 1 | 128 = 129.
# Reference: man 2 futex; libdispatch/src/shims/lock.c:484-488.

comptime FUTEX_WAIT_PRIVATE: Int32 = 128
comptime FUTEX_WAKE_PRIVATE: Int32 = 129
comptime FUTEX_INT_MAX: Int32 = 0x7FFFFFFF   # INT_MAX → wake all waiters


# =============================================================================
# macOS ulock op codes
# =============================================================================
# Operation flags for __ulock_wake / __ulock_wait, packed into the first
# arg as a single UInt32. Reference: <sys/ulock.h> (Apple-private but
# stable since 10.12).
#
# UL_COMPARE_AND_WAIT     = 0x1        — operation type: wait/wake on uint32
# ULF_WAKE_ALL            = 0x100      — wake ALL waiters (vs default 1)
# ULF_NO_ERRNO            = 0x01000000 — return -errno directly (skip errno
#                                       slot — needed because we don't
#                                       link libSystem's errno helpers)
#
# Wake op = UL_COMPARE_AND_WAIT | ULF_WAKE_ALL | ULF_NO_ERRNO
# Wait op = UL_COMPARE_AND_WAIT | ULF_NO_ERRNO  (NOT ULF_WAKE_ALL)

comptime ULOCK_WAKE_ALL_OP: UInt32 = 0x01000101
comptime ULOCK_WAIT_OP: UInt32 = 0x01000001


# =============================================================================
# wake_all_by_address — wake EVERY waiter parked on a 32-bit word
# =============================================================================
#
# Mirrors libdispatch's `_dispatch_wake_by_address` (lock.c:569-582).
# ONE syscall wakes all parked waiters regardless of count. Cost is
# essentially constant in N: kernel acquires the runqueue lock once,
# marks every waiter on the address's hash bucket runnable.
#
# Caller MUST update the word (e.g. `fetch_add(1)`) BEFORE calling this
# function — the value-comparison protocol in `wait_on_address` relies
# on observing a value change to avoid the lost-wakeup race.
#
# `word` is borrowed for the duration of the syscall only. The kernel
# does not retain the address; once the syscall returns, every reference
# is gone.
#
# SAFETY: `word` is a borrowed ref to an Atomic field. We launder the
# inner-storage pointer into MutExternalOrigin via `UnsafePointer(to=
# word.value)` for the FFI carve-out. The kernel reads (does not write)
# the address; the Atomic's storage outlives the syscall by the
# lifetime of the borrow.

@always_inline
def wake_all_by_address(ref [_] word: AtomicI32) -> Int32:
    """Wake ALL pthreads parked on `word` via `wait_on_address`. Returns
    the syscall's raw rc (>= 0 = success; < 0 = -errno).

    macOS: __ulock_wake(ULOCK_WAKE_ALL_OP, &word, 0)
    Linux: syscall(SYS_futex, &word, FUTEX_WAKE_PRIVATE, INT_MAX, 0,0,0)
    """
    # SAFETY: coerce the caller-held typed Atomic-storage pointer to the
    # concrete static FFI origin (NOT a wildcard, NOT via the banned
    # `unsafe_from_address=Int`). The syscall does not retain the address;
    # `word` is borrowed for the syscall's duration.
    var addr = (
        UnsafePointer(to=word).unsafe_bitcast[Scalar[DType.int32]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )

    comptime if CompilationTarget.is_macos():
        return external_call["__ulock_wake", Int32](
            ULOCK_WAKE_ALL_OP,
            addr,
            UInt64(0),
        )
    else:
        # Linux: comptime-select syscall number per arch.
        comptime if CompilationTarget.is_x86():
            return Int32(external_call["syscall", Int64](
                SYS_FUTEX_X86_64,
                addr,
                FUTEX_WAKE_PRIVATE,
                FUTEX_INT_MAX,
                _ffi_null().bitcast[UInt8](),  # timeout (ignored)
                _ffi_null().bitcast[UInt8](),  # uaddr2 (ignored)
                Int32(0),                                    # val3 (ignored)
            ))
        else:
            return Int32(external_call["syscall", Int64](
                SYS_FUTEX_AARCH64,
                addr,
                FUTEX_WAKE_PRIVATE,
                FUTEX_INT_MAX,
                _ffi_null().bitcast[UInt8](),
                _ffi_null().bitcast[UInt8](),
                Int32(0),
            ))


# =============================================================================
# wait_on_address — park caller until *word changes from `expected`
# =============================================================================
#
# Canonical lost-wakeup-safe wait protocol (Drepper "Futexes Are
# Tricky" §3): block IFF *word == expected at the time of the syscall;
# otherwise return -EAGAIN immediately (the dispatcher already fired).
#
# `timeout_ns == 0` means "wait forever"; a positive value bounds the wait
# (a relative timeout: a `timespec` to futex on Linux, microseconds to
# __ulock_wait on macOS).
#
# Returns 0 on a normal wake; <0 on error/timeout/race. The
# common error returns are:
#   -EAGAIN — *word != expected at syscall entry (race; benign)
#   -EINTR  — wait was signaled (e.g. by a Mojo signal handler; benign)
# Both are indistinguishable from a normal wake from the caller's POV
# — the caller's outer loop should re-check the wake-target counter.
#
# SAFETY: identical to `wake_all_by_address`. `word` is borrowed for the
# syscall's duration; the kernel does not retain the address.

@always_inline
def wait_on_address(
    ref [_] word: AtomicI32,
    expected: Int32,
    timeout_ns: Int64 = 0,
) -> Int32:
    """Park the calling thread on `word` until *word != expected, or
    until `wake_all_by_address` fires. Returns 0 on wake, <0 on
    error/timeout."""
    # SAFETY: coerce the caller-held typed Atomic-storage pointer to the
    # concrete static FFI origin (NOT a wildcard, NOT via the banned
    # `unsafe_from_address=Int`). The syscall does not retain the address.
    var addr = (
        UnsafePointer(to=word).unsafe_bitcast[Scalar[DType.int32]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )

    comptime if CompilationTarget.is_macos():
        # __ulock_wait(operation, addr, value, timeout_us).
        # timeout_us = 0 means forever.
        var timeout_us = UInt32(0)
        if timeout_ns > Int64(0):
            # Convert ns -> us, clamp to UInt32.
            var us = timeout_ns // Int64(1000)
            if us > Int64(0xFFFFFFFF):
                timeout_us = UInt32(0xFFFFFFFF)
            else:
                timeout_us = UInt32(Int(us))
        return external_call["__ulock_wait", Int32](
            ULOCK_WAIT_OP,
            addr,
            UInt64(expected),
            timeout_us,
        )
    else:
        # Linux: a relative `struct timespec { tv_sec; tv_nsec }` (two 64-bit
        # words on x86_64 and aarch64), or NULL to wait forever.
        var ts = InlineArray[Int64, 2](fill=0)
        var tsp = _ffi_null().bitcast[UInt8]()
        if timeout_ns > Int64(0):
            ts[0] = timeout_ns // Int64(1_000_000_000)
            ts[1] = timeout_ns % Int64(1_000_000_000)
            # SAFETY: `ts` is a local read again after the syscall, so it
            # outlives it; the kernel only reads it during the call.
            tsp = (
                UnsafePointer(to=ts).bitcast[UInt8]()
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[_FFI_ORIGIN]()
            )
        comptime sys_futex = (
            SYS_FUTEX_X86_64 if CompilationTarget.is_x86() else SYS_FUTEX_AARCH64
        )
        var rc = Int32(external_call["syscall", Int64](
            sys_futex,
            addr,
            FUTEX_WAIT_PRIVATE,
            expected,
            tsp,                           # timeout (NULL = forever)
            _ffi_null().bitcast[UInt8](),  # uaddr2 (ignored)
            Int32(0),                      # val3 (ignored)
        ))
        _ = ts[0]  # keeps `ts` alive across the syscall
        return rc


# =============================================================================
# cpu_pause — CPU hint for tight spin loops
# =============================================================================
#
# Tells the CPU "I'm spinning; don't burn power, don't fight the
# pipeline":
#   - x86_64: PAUSE instruction (0xF3 0x90). Reduces speculation pressure
#             on partner SMT thread; ~10ns per call. Reference: Intel
#             Optimization Manual §11.4.4.
#   - ARM (incl. Apple Silicon): YIELD instruction. Hint to the core
#             that we're not making progress; cheap and equivalent to
#             a NOP if the core has no SMT.
#
# Mojo doesn't expose either of these via stdlib intrinsics. We
# fall back to `sched_yield` on both platforms — slightly heavier than
# PAUSE/YIELD but always available. The cost (~50ns) is below our
# spin-loop iteration cost target.
#
# Future improvement (Phase D.5): use llvm.x86.sse2.pause / llvm.aarch64.
# yield once Mojo exposes them as `external_call` targets.

@always_inline
def cpu_pause() -> None:
    """CPU hint for spin loops. Falls back to sched_yield on both
    platforms (Mojo does not expose PAUSE/YIELD intrinsics)."""
    _ = external_call["sched_yield", Int32]()

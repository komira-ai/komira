# =============================================================================
# komira_async.runtime.wake_primitives — futex / __ulock_wait shim
# =============================================================================
# Cross-platform "wake-by-address" / "wait-on-address" primitives. Mirror of
# libdispatch's `_dispatch_wake_by_address` (apple/swift-corelibs-libdispatch
# /src/shims/lock.c:569-582). ONE conceptual primitive (wake-N-waiters-on-
# address), comptime-branched at the syscall layer.
#
#   * Linux (x86_64 / aarch64):
#       - SYS_futex syscall numbers: x86_64=202, aarch64=422
#       - FUTEX_WAIT_PRIVATE = 128, FUTEX_WAKE_PRIVATE = 129
#       - INT_MAX (0x7FFFFFFF) for wake-all
#   * macOS (arm64 / x86_64):
#       - __ulock_wait / __ulock_wake (Apple-private, stable since 10.12)
#       - UL_COMPARE_AND_WAIT | ULF_NO_ERRNO; ULF_WAKE_ALL for wake-all
#
# The FFI shape is verified GREEN on macOS arm64 and exercised on Linux
# x86_64 through this package's own tests and the engine's runs.
#
# Pointer discipline:
#   - Public API takes `ref [_] Atomic[DType.int32] word` — no UnsafePointer
#     in public signatures.
#   - FFI carve-out: `UnsafePointer[Int32, MutExternalOrigin](unsafe_from_address=
#     Int(typed_ptr))` is the documented FFI laundering pattern, confined to
#     this file. SAFETY block annotates the kernel-call boundary.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32
from std.sys.intrinsics import llvm_intrinsic
from std.sys.info import CompilationTarget

# Mac kqueue cross-thread wake (EVFILT_USER + NOTE_TRIGGER). Free fn imported
# here so WorkerWakeHandle.wake() compiles on darwin without an
# `_ = self._ident` placeholder.
from komira_async.reactor.kqueue_subsystem import kevent_user_wake


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed
    `_null_ptr[T, o]()` null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Used only for NULL syscall arguments below.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# Linux syscall numbers, comptime-selected per arch.
comptime SYS_FUTEX_X86_64: Int64 = 202
comptime SYS_FUTEX_AARCH64: Int64 = 422


# Linux futex op codes.
comptime FUTEX_WAIT_PRIVATE: Int32 = 128
comptime FUTEX_WAKE_PRIVATE: Int32 = 129
comptime FUTEX_INT_MAX: Int32 = 0x7FFFFFFF


# macOS ulock op codes.
# UL_COMPARE_AND_WAIT = 0x1; ULF_WAKE_ALL = 0x100; ULF_NO_ERRNO = 0x01000000.
comptime ULOCK_WAKE_ALL_OP: UInt32 = 0x01000101  # WAIT|WAKE_ALL|NO_ERRNO
comptime ULOCK_WAKE_ONE_OP: UInt32 = 0x01000001  # WAIT|NO_ERRNO (default = wake one)
comptime ULOCK_WAIT_OP: UInt32 = 0x01000001      # WAIT|NO_ERRNO


@always_inline
def wake_all_by_address(ref [_] word: AtomicI32) -> Int32:
    """Wake EVERY pthread parked on `word` via wait_on_address. ONE syscall
    wakes all parked waiters regardless of count.

    Caller MUST update the word (e.g. `fetch_add(1)`) BEFORE calling this
    function — the value-comparison protocol in `wait_on_address` relies on
    observing a value change to avoid the lost-wakeup race.

    Returns syscall raw rc:
      - Linux futex(FUTEX_WAKE):  >= 0 = number of woken waiters; < 0 = -errno.
      - Darwin __ulock_wake|ULF_NO_ERRNO:  0 = success and >0 woken; < 0 = -errno.
        The Darwin kernel reports -ENOENT (-2) when there are no parked
        waiters at the address — semantically a successful no-op (the
        wake-up sweep ran; the queue was empty). Callers that care about
        "did the syscall succeed" should treat both `rc >= 0` (Linux) and
        `rc == -2` (Darwin no-waiter no-op) as success.

    SAFETY: `word` is borrowed for the syscall's duration only. The kernel
    does not retain the address; once the syscall returns, every reference
    is gone. The Atomic-storage pointer is laundered into MutExternalOrigin
    via UnsafePointer(unsafe_from_address=Int(typed_ptr)) for the FFI
    carve-out (the documented FFI pattern).
    """
    # SAFETY: launder typed Atomic-storage pointer into the FFI carve-out.
    # The kernel reads (does not write) the address; the Atomic's storage
    # outlives the syscall by the lifetime of the borrow.
    var typed_ptr = UnsafePointer(to=word).unsafe_bitcast[Scalar[DType.int32]]()
    var addr = UnsafePointer[Int32, MutUntrackedOrigin](
        unsafe_from_address=Int(typed_ptr)
    )

    comptime if CompilationTarget.is_macos():
        return external_call["__ulock_wake", Int32](
            ULOCK_WAKE_ALL_OP, addr, UInt64(0),
        )
    else:
        comptime if CompilationTarget.is_x86():
            return Int32(external_call["syscall", Int64](
                SYS_FUTEX_X86_64,
                addr,
                FUTEX_WAKE_PRIVATE,
                FUTEX_INT_MAX,
                _null_ptr[UInt8, MutUntrackedOrigin](),
                _null_ptr[UInt8, MutUntrackedOrigin](),
                Int32(0),
            ))
        else:
            return Int32(external_call["syscall", Int64](
                SYS_FUTEX_AARCH64,
                addr,
                FUTEX_WAKE_PRIVATE,
                FUTEX_INT_MAX,
                _null_ptr[UInt8, MutUntrackedOrigin](),
                _null_ptr[UInt8, MutUntrackedOrigin](),
                Int32(0),
            ))


@always_inline
def wake_one_by_address(ref [_] word: AtomicI32) -> Int32:
    """Wake ONE pthread parked on `word` (vs wake_all). Used by SPSC channel
    + JoinHandle.join wake-up paths where exactly one waiter is parked.

    Same SAFETY rationale as wake_all_by_address.
    """
    var typed_ptr = UnsafePointer(to=word).unsafe_bitcast[Scalar[DType.int32]]()
    var addr = UnsafePointer[Int32, MutUntrackedOrigin](
        unsafe_from_address=Int(typed_ptr)
    )

    comptime if CompilationTarget.is_macos():
        return external_call["__ulock_wake", Int32](
            ULOCK_WAKE_ONE_OP, addr, UInt64(0),
        )
    else:
        comptime if CompilationTarget.is_x86():
            return Int32(external_call["syscall", Int64](
                SYS_FUTEX_X86_64,
                addr,
                FUTEX_WAKE_PRIVATE,
                Int32(1),
                _null_ptr[UInt8, MutUntrackedOrigin](),
                _null_ptr[UInt8, MutUntrackedOrigin](),
                Int32(0),
            ))
        else:
            return Int32(external_call["syscall", Int64](
                SYS_FUTEX_AARCH64,
                addr,
                FUTEX_WAKE_PRIVATE,
                Int32(1),
                _null_ptr[UInt8, MutUntrackedOrigin](),
                _null_ptr[UInt8, MutUntrackedOrigin](),
                Int32(0),
            ))


@always_inline
def wait_on_address(
    ref [_] word: AtomicI32,
    expected: Int32,
    timeout_ns: Int64 = 0,
) -> Int32:
    """Park calling thread on `word` until *word != expected (compare-fails)
    or wake_all_by_address fires (compare passes; producer woke us).

    Drepper "Futexes Are Tricky" lost-wakeup-safe pattern: caller
    snapshots `expected` (e.g., `gen_word.load(Acquire)`), rechecks all
    sources of work, then calls wait_on_address(word, expected); if a
    producer fires `fetch_add(1)` between the snapshot and the syscall,
    the kernel's value-compare returns -EAGAIN immediately (no lost wake).

    `timeout_ns == 0` means "wait forever".

    ⚠ READ BEFORE TOUCHING THE TIMEOUT PLUMBING.
    Non-zero timeouts are honoured on Linux as well as macOS, and callers
    depend on it: `async_mutex`, `async_rwlock` (x2), `semaphore`, `notify`,
    `select` (x2), `join_handle`, `task_scope`, `connection_registry`, and
    `LocalDispatcher._drain_in_flight_barrier` all pass
    `timeout_ns=1_000_000` and are written as a "re-check / poll-cancel
    every 1 ms" loop. If the Linux arm passed a NULL timespec, each of them
    would be an INDEFINITE park — one missed wake away from a permanent hang
    instead of a 1 ms delay, with an outer re-check loop that never runs.

    That is not a latent nicety: it is the difference between a self-healing
    park and a wedge: an unbounded park is how a fork-join dispatch barrier can
    stick forever. A bounded futex wait does NOT paper over a
    missing wake — the caller's loop still has to re-check — but it does mean a
    lost wake costs a millisecond instead of the process.

    The timeout is passed RELATIVE, which is what `FUTEX_WAIT` (as opposed to
    `FUTEX_WAIT_BITSET`) expects.

    Returns 0 on a normal wake; <0 on error/timeout/race. Common errors:
       -EAGAIN    — *word != expected at syscall entry (race; benign)
       -EINTR     — wait was signaled (benign)
       -ETIMEDOUT — the (now real) timeout elapsed (benign)
    All three are indistinguishable from a normal wake to the caller; the
    caller's outer loop re-checks the wake-target counter.

    SAFETY: same as wake_all_by_address.
    """
    var typed_ptr = UnsafePointer(to=word).unsafe_bitcast[Scalar[DType.int32]]()
    var addr = UnsafePointer[Int32, MutUntrackedOrigin](
        unsafe_from_address=Int(typed_ptr)
    )

    comptime if CompilationTarget.is_macos():
        var timeout_us = UInt32(0)
        if timeout_ns > Int64(0):
            var us = timeout_ns // Int64(1000)
            if us > Int64(0xFFFFFFFF):
                timeout_us = UInt32(0xFFFFFFFF)
            else:
                timeout_us = UInt32(Int(us))
        return external_call["__ulock_wait", Int32](
            ULOCK_WAIT_OP, addr, UInt64(expected), timeout_us,
        )
    else:
        comptime FUTEX_NR = (
            SYS_FUTEX_X86_64
            if CompilationTarget.is_x86()
            else SYS_FUTEX_AARCH64
        )
        if timeout_ns > Int64(0):
            # `struct timespec { long tv_sec; long tv_nsec; }` — two 64-bit
            # words on both LP64 targets, so a 2-lane int64 SIMD is a
            # layout-exact stand-in (same idiom as the reactor's nanosleep).
            var ts = SIMD[DType.int64, 2](
                timeout_ns // Int64(1_000_000_000),
                timeout_ns % Int64(1_000_000_000),
            )
            # SAFETY: arg5 points at the
            # stack-local `ts`. It is formed with `UnsafePointer(to=ts)` — the
            # NATURAL origin, deliberately NOT an erased/FFI origin — because an
            # erased origin lets ASAP-destruction reuse the stack slot while the
            # syscall is still reading it (see
            # `feedback_ffi_local_scratch_natural_origin`). The explicit `_ = ts`
            # read after the call holds it live across the syscall.
            var rc = Int32(external_call["syscall", Int64](
                FUTEX_NR,
                addr,
                FUTEX_WAIT_PRIVATE,
                expected,
                UnsafePointer(to=ts).bitcast[UInt8](),
                _null_ptr[UInt8, MutUntrackedOrigin](),
                Int32(0),
            ))
            _ = ts
            return rc
        return Int32(external_call["syscall", Int64](
            FUTEX_NR,
            addr,
            FUTEX_WAIT_PRIVATE,
            expected,
            _null_ptr[UInt8, MutUntrackedOrigin](),
            _null_ptr[UInt8, MutUntrackedOrigin](),
            Int32(0),
        ))


@always_inline
def cpu_pause() -> None:
    """CPU hint for spin loops. Falls back to sched_yield on both platforms.
    Use this for outer spins where pthread starvation is the real risk
    (e.g. JoinHandle.join wait). For tight inner spins inside the worker
    park-loop where we WANT to hold the time-slice, use `pause_intrinsic`
    below.
    """
    _ = external_call["sched_yield", Int32]()


@always_inline
def pause_intrinsic() -> None:
    """Pure CPU pause hint — no syscall. Holds the time-slice.

    For spin loops INSIDE the worker park loop where we want to
    minimize busy-wait CPU consumption WITHOUT releasing the
    time-slice (releasing risks the producer's wake racing past
    us into a worker that's been preempted).

    Companion to `cpu_pause()` (sched_yield). Use:
      - `pause_intrinsic()` for in-loop spin (worker park loop).
      - `cpu_pause()` for outer spin where pthread starvation is
        the real risk (JoinHandle.join wait).

    The aarch64 `llvm_intrinsic` shape is
    UNVERIFIED on Mojo 0.26.3. The implementation falls back to
    `cpu_pause` on aarch64 to avoid blocking on an unverified
    intrinsic shape. x86_64 uses `llvm.x86.sse2.pause` (well-known
    void-return intrinsic).
    """
    comptime if CompilationTarget.is_x86():
        llvm_intrinsic["llvm.x86.sse2.pause", NoneType]()
    else:
        # aarch64 / unknown — fallback to sched_yield to avoid the
        # unverified `llvm.aarch64.isb` intrinsic shape. This matches
        # mitigation: SPIN_LIMIT=4 + sched_yield. The
        # SPIN_LIMIT constant in worker.mojo is the knob; this fn
        # provides a safe fallback regardless.
        _ = external_call["sched_yield", Int32]()


# =============================================================================
# _SleepingFlag + WorkerWakeHandle — typed wake elision
# =============================================================================
# The sleeping flag is a typed ArcPointer<_SleepingFlag>, NOT a
# `_sleeping_addr: Int` + `UnsafePointer[Atomic[..], MutExternalOrigin](
# unsafe_from_address=...)` shape (the pointer rules ban both the wildcard
# origin and the Int laundering).
#
# Why the wrapper: Atomic[DType.int32] is non-Movable on Mojo 0.26.3 and
# ArcPointer requires `T: Movable`. _SleepingFlag is a Movable shell around
# OwnedPointer[Atomic[Int32]] — the same shape as _AtomicSlot, _SpawnSlot,
# _InflightCounter, etc.
#
# Cross-package boundary: lives in `runtime/wake_primitives.mojo` (NOT in
# `reactor.mojo`) so dispatcher/spawner can import the type without
# importing from `reactor` — preserves the acyclic dependency direction.


# Sentinel op_id used to register the eventfd with epoll. The worker's
# epoll_wait_decode loop recognizes this op_id and routes to the eventfd
# drain path instead of the WakerSink path. Int64(-1) is unreachable by
# Reactor.alloc_op_id (monotone fetch_add starting at 0); collision risk
# bounded by future-author error (lint-time check at wake-handle creation).
comptime OP_ID_WAKE_EVENTFD: Int64 = -1


# sentinel cookie used by `Reactor.park_on_fds`
# when it transiently registers in-flight streaming-drain fds for a one-shot
# epoll park. Distinct from OP_ID_WAKE_EVENTFD and from any alloc_op_id value
# (monotone fetch_add from 0), so a park event is never mis-decoded as a
# _wakers op_id. park_on_fds deregisters its fds before returning, so this
# cookie is never observed by a run_once loop in practice; the distinct value
# keeps the contract explicit.
comptime OP_ID_IO_PARK: Int64 = -2


# eventfd flags. Linux <sys/eventfd.h>.
comptime EFD_NONBLOCK: Int32 = 0o4000      # O_NONBLOCK
comptime EFD_CLOEXEC: Int32 = 0o2000000    # O_CLOEXEC


struct _SleepingFlag(Movable, Deinitable):
    """Movable wrapper around OwnedPointer[Atomic[DType.int32]] so it can
    live inside ArcPointer (which requires `T: Movable`).
    Atomic[DType.int32] is non-Movable on Mojo 0.26.3, so we go through
    the OwnedPointer indirection that 9 in-tree precedents already use
    (`_AtomicSlot` in cancellation/token.mojo, `_SpawnSlot` /
    `_InflightCounter` in spawner/local_spawner.mojo, the `_WakeWord` in
    join_handle.mojo, etc.).

    The single OwnedPointer field is a POD 8-byte handle; moving
    _SleepingFlag is just moving the handle (the heap allocation stays
    put, which is exactly the stable-address property the park-bracket
    relies on).

    Typed shape: no `_sleeping_addr: Int` Int-laundered address.
    """

    var _atomic: OwnedPointer[AtomicI32]

    def __init__(out self):
        var raw = alloc[AtomicI32](1)
        # SAFETY: raw is a fresh allocation we own. Atomic ctor accepts a
        # Scalar value. Ownership transfers to OwnedPointer; __del__ runs
        # free.
        raw[] = AtomicI32(Int32(0))
        self._atomic = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw,
        )

    def load(self) -> Int32:
        """Bare-form atomic load per Mojo 0.26.3 stdlib. Maps to seq_cst
        on x86 / LDAR on ARM (sufficient for the wake-elision lost-
        wakeup-safe pattern; see async_mutex.mojo for the bare-form
        precedent)."""
        return self._atomic[].load()

    def store(mut self, value: Int32):
        """Bare-form atomic store per Mojo 0.26.3 stdlib (same precedent
        as load())."""
        AtomicI32.store(
            UnsafePointer(to=self._atomic[]).unsafe_bitcast[Scalar[DType.int32]](), value,
        )


struct WorkerWakeHandle(Copyable, Movable, Deinitable):
    """Producer-side handle to a Worker's wake mechanism.

    Carries:
    - `_wake_fd`: POD fd for the eventfd (Linux) or kqueue EVFILT_USER
      ident (macOS). Used for the actual wake syscall when elision misses.
    - `_ident`: macOS EVFILT_USER ident (unused on Linux; kept for the
      kqueue path that sketched).
    - `_sleeping_arc`: ArcPointer[_SleepingFlag] — refcount-tracked shared
      ownership of the worker's sleeping flag. The Worker and every
      producer hold their own clone; the underlying _SleepingFlag (and
      its inner Atomic) is freed when the last clone drops.

    Lifetime contract:
      Each producer that wants to wake this Worker registers ONCE at
      attach time + receives a clone of WorkerWakeHandle (which clones
      the underlying ArcPointer). The clone increments the refcount;
      the Worker's drop + every producer's drop decrements. The Atomic
      survives until the last drop. `Worker-outlives-producer` is NOT
      required; the producer's clone keeps the Atomic alive even if the
      Worker has gone away.

    Pointer discipline:
      ZERO wildcard origins; ZERO Int laundering. Every read of the
      sleeping flag goes through the typed ArcPointer deref → Atomic
      deref. Lifetime is refcount-tracked.

    Cost analysis:
      Clone: one atomic increment (~80 ns x86 / ~50 ns ARM). Paid ONCE
        per producer registration, NOT per wake call.
      Drop: one atomic decrement + maybe-free. Paid ONCE on producer
        shutdown.
      Wake-elision read path: one ArcPointer deref + one OwnedPointer
        deref + one Atomic.load(). One extra OwnedPointer indirection
        vs an Int-laundered address — negligible vs the syscall savings
        (the syscall costs ~1µs; the OwnedPointer indirection costs
        ~1 ns).
    """

    var _wake_fd: Int32                       # eventfd or kqueue fd
    var _ident: UInt64                        # macOS EVFILT_USER ident; unused on Linux
    var _sleeping_arc: ArcPointer[_SleepingFlag]  # typed shape

    @staticmethod
    def make(
        wake_fd: Int32,
        ident: UInt64,
        var sleeping_arc: ArcPointer[_SleepingFlag],
    ) -> WorkerWakeHandle:
        """Factory constructor. Consumes `sleeping_arc` (caller can
        `ArcPointer[_SleepingFlag](copy=existing)` before passing if they
        want to retain a clone)."""
        return WorkerWakeHandle(
            _wake_fd=wake_fd,
            _ident=ident,
            _sleeping_arc=sleeping_arc^,
        )

    @staticmethod
    def make_disconnected(wake_fd: Int32, ident: UInt64) -> WorkerWakeHandle:
        """Factory for a self-owned WorkerWakeHandle whose sleeping arc is
        a fresh, dummy _SleepingFlag (always reports awake=0). Used at the
        Reactor boundary to compose a baseline handle BEFORE the Worker
        injects the real arc; also used for the MOCK / sentinel path
        where wake() is a no-op anyway.

        The dummy arc's `load()` always returns Int32(0) (the Worker is
        not parked through this arc), so `wake_with_elision()` will
        ALWAYS elide the syscall — which is the safe / correct behavior
        when no real worker exists to wake.
        """
        return WorkerWakeHandle(
            _wake_fd=wake_fd,
            _ident=ident,
            _sleeping_arc=ArcPointer[_SleepingFlag](_SleepingFlag()),
        )

    @staticmethod
    def from_parts(
        var base: WorkerWakeHandle,
        var sleeping_arc: ArcPointer[_SleepingFlag],
    ) -> WorkerWakeHandle:
        """Replace `base`'s sleeping_arc with a different one. Used by
        Worker.wake_handle() to splice the real Worker-owned sleeping
        arc onto the Reactor-built base handle."""
        return WorkerWakeHandle(
            _wake_fd=base._wake_fd,
            _ident=base._ident,
            _sleeping_arc=sleeping_arc^,
        )

    def __init__(
        out self,
        _wake_fd: Int32,
        _ident: UInt64,
        var _sleeping_arc: ArcPointer[_SleepingFlag],
    ):
        """Fieldwise-init shape preserved for the canonical 3-arg form."""
        self._wake_fd = _wake_fd
        self._ident = _ident
        self._sleeping_arc = _sleeping_arc^

    def copy(self) -> Self:
        """Explicit clone: refcount-bumps the ArcPointer; POD fields copy
        bitwise. Used at producer-attach time to fan out per-producer
        clones of the wake handle."""
        return WorkerWakeHandle(
            _wake_fd=self._wake_fd,
            _ident=self._ident,
            _sleeping_arc=ArcPointer[_SleepingFlag](copy=self._sleeping_arc),
        )

    @always_inline
    def wake(self):
        """Cross-thread wake. Lock-free. Returns void. Best-effort on EBADF
        / EAGAIN — silently ignored.

        Inlines libc's eventfd_write helper to avoid an extra function-call
        layer on the producer hot path. eventfd_write takes the 8-byte
        value BY VALUE so the FFI signature is trivially typed-scalar —
        no UnsafePointer at this site.

        NOTE: this is the unconditional wake (always writes eventfd). Use
        `wake_with_elision()` to skip the write when the worker is awake.
        """
        comptime if CompilationTarget.is_linux():
            if self._wake_fd >= 0:
                var rc = external_call["eventfd_write", Int32](
                    self._wake_fd, UInt64(1),
                )
                _ = rc   # ignore: best-effort (EBADF/EAGAIN swallowed)
        elif CompilationTarget.is_macos():
            # macOS: kqueue EVFILT_USER NOTE_TRIGGER. `_wake_fd` carries the kq_fd (set by
            # Reactor.wake_handle on darwin); `_ident` carries the
            # EVFILT_USER cookie registered at Reactor construction.
            #
            # `kevent_user_wake` is best-effort and idempotent: closed
            # kq_fd returns EBADF (silently); already-pending NOTE_TRIGGER
            # collapses (kqueue auto-resets via EV_CLEAR per
            # kevent_register_user_wake). Same EBADF-silent contract as
            # the Linux eventfd_write branch above.
            if self._wake_fd >= 0:
                kevent_user_wake(self._wake_fd, self._ident)

    @always_inline
    def wake_with_elision(self) -> Bool:
        """Seastar `_sleeping` flag elision (typed v1).

        Returns True if a wake syscall was actually issued; False if the
        wake was elided (the Worker was already awake).

        SAFETY: ArcPointer keeps the _SleepingFlag (and its
        OwnedPointer-wrapped Atomic) alive for the entire lifetime of
        this handle. Read is fully typed; no wildcard origins; no Int
        laundering. Bare-form atomic per Mojo 0.26.3 stdlib (maps to
        seq_cst on x86 / LDAR on ARM — sufficient for the lost-wakeup-
        safe protocol).

        Memory ordering:
          1. Producer enqueued an item into the worker's MPSC inbox
             BEFORE this call (caller responsibility).
          2. seq_cst fence — ensures the inbox-write is globally visible
             BEFORE the sleeping-flag load.
          3. load _sleeping (bare-form acquire) — read the worker's flag.
          4. If sleeping == 0: return False (wake elided; worker is
             awake and will see the inbox item on its next iteration).
          5. If sleeping == 1: actually issue the eventfd_write
             (Linux) / kqueue_user_trigger (macOS).

        The worker-side back-stop — re-check work
        queues AFTER setting sleeping=1 — closes any race window where
        a producer's load saw sleeping=0 but the worker was just about
        to park (Drepper's futex protocol).
        """
        # StoreLoad fence (seq_cst). Without this, the compiler / CPU
        # could reorder the load to before the inbox-write, causing a
        # lost wakeup race per Drepper "Futexes Are Tricky"
        #
        # close the ARM64 hole. Pre-fix, only
        # x86 emitted `mfence`; ARM64 had no fence here, so on Apple
        # Silicon (and any aarch64 Linux) the inbox-write store could
        # reorder past the sleeping-flag load → producer sees stale
        # `_sleeping=0`, elides the wake, worker stays parked → lost
        # wakeup. ARM64 LDAR/STLR alone do NOT close the StoreLoad hole;
        # an explicit `dmb ish` (inner-shareable) is required.
        # (the store-load hole between the sleeping flag and the
        # work check).
        comptime if CompilationTarget.is_x86():
            llvm_intrinsic[
                "llvm.x86.sse2.mfence", NoneType, has_side_effect=True,
            ]()
        else:
            # aarch64 inner-shareable data memory barrier.
            # 0xb = ish (StoreLoad order, inner-shareable domain).
            # Empirically verified to compile + lower correctly on Mojo
            # 0.26.3.0.dev2026040216 / aarch64-darwin (Apple Silicon).
            llvm_intrinsic[
                "llvm.aarch64.dmb", NoneType, has_side_effect=True,
            ](Int32(0xb))
        # SAFETY: typed deref through ArcPointer; no wildcard origins,
        # no Int laundering. The ArcPointer keeps the _SleepingFlag (and
        # its inner Atomic) alive for this handle's lifetime.
        var sleeping = self._sleeping_arc[].load()
        if sleeping == Int32(0):
            # Worker is awake — elide the wake syscall.
            return False
        # Worker is parked on epoll_wait — actually issue the wake.
        self.wake()
        return True

    @always_inline
    def fd(self) -> Int32:
        """Diagnostic accessor — returns the underlying fd. Used by tests
        and the standalone-Worker eventfd lifecycle test (Issue 2.B)."""
        return self._wake_fd

    @always_inline
    def ident(self) -> UInt64:
        """Diagnostic accessor — returns the kqueue ident (macOS only)."""
        return self._ident

    @always_inline
    def sleeping_flag_load(self) -> Int32:
        """Diagnostic accessor — returns the current value of the
        sleeping flag via the typed ArcPointer deref. Used by tests to
        verify the producer side observes the worker's flag transitions
        without going through the launder."""
        return self._sleeping_arc[].load()


# =============================================================================
# Eventfd FFI primitives — Linux only.
# =============================================================================
# All take/return typed scalars; UnsafePointer is internal to this module
# only (confined to the FFI thunks below). No module-boundary crossing.


def create_eventfd() raises -> Int32:
    """Create a Linux eventfd with EFD_NONBLOCK | EFD_CLOEXEC flags.

    Returns the eventfd fd. Raises on syscall error.

    Wrong-OS callers raise. The macOS path uses kqueue EVFILT_USER;
    this is the Linux primitive only.
    """
    comptime if CompilationTarget.is_linux():
        var fd = external_call["eventfd", Int32](
            UInt32(0),                             # initial counter value
            EFD_NONBLOCK | EFD_CLOEXEC,            # flags
        )
        if fd < 0:
            raise Error("eventfd() syscall failed")
        return fd
    else:
        raise Error("create_eventfd: Linux only")


def close_eventfd(fd: Int32):
    """Close an eventfd. Idempotent if fd < 0 (already closed sentinel).
    Best-effort: the close rc is ignored (mirrors epoll_close semantics).
    """
    comptime if CompilationTarget.is_linux():
        if fd >= 0:
            _ = external_call["close", Int32](fd)


def drain_eventfd(fd: Int32):
    """Drain an eventfd by reading the 8-byte counter. Resets the counter
    to zero. Best-effort: returns silently on EAGAIN (NONBLOCK flag means
    a counter that's already zero returns -1/EAGAIN, which is benign).

    SAFETY: val is a stack-local 8-byte buffer; the libc helper writes 8
    bytes via the kernel (or -1 + EAGAIN with no write). UnsafePointer
    never crosses the module boundary.

    Uses libc's `eventfd_read(int fd, uint64_t *value)` helper (glibc
    ≥ 2.7) — sidesteps the Mojo stdlib's builtin `read` symbol that
    collides with the generic external_call shape.
    """
    comptime if CompilationTarget.is_linux():
        if fd >= 0:
            var val: UInt64 = 0
            var typed_ptr = UnsafePointer(to=val)
            # SAFETY: launder typed pointer through MutExternalOrigin
            # FFI carve-out (matches existing wake_primitives futex shim).
            var raw_ptr = UnsafePointer[UInt64, MutUntrackedOrigin](
                unsafe_from_address=Int(typed_ptr)
            )
            var rc = external_call["eventfd_read", Int32](fd, raw_ptr)
            _ = rc   # ignore: EAGAIN is benign


def write_eventfd(fd: Int32):
    """Write 1 to an eventfd to signal a wake. Best-effort: returns silently
    on EBADF (closed fd) or EAGAIN (counter overflow — practically
    unreachable; see design).

    Uses libc's `eventfd_write(int fd, uint64_t value)` helper (glibc
    ≥ 2.7) — sidesteps the Mojo stdlib's builtin `write` symbol that
    collides with the generic external_call shape. eventfd_write takes
    the 8-byte value BY VALUE (not by pointer), making the FFI
    signature trivially typed-scalar — no UnsafePointer in this thunk.
    """
    comptime if CompilationTarget.is_linux():
        if fd >= 0:
            var rc = external_call["eventfd_write", Int32](fd, UInt64(1))
            _ = rc   # ignore: EBADF/EAGAIN swallowed

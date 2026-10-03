# =============================================================================
# komira_async.spawner.join_handle — JoinHandle[T] + Mechanism D park
# =============================================================================
# Slab-allocated wake-words.
#
# Result-bearing handle returned by Spawner.spawn. NOT Copyable — a
# result is owned by exactly one joiner.
#
# Park semantics: join() parks on a heap-stable
# wake-word via Mechanism D's wake-by-address shim. Production code uses
# `__ulock_wait` on macOS, `futex` on Linux. The wake-word lives on a
# heap-allocated `_SpawnSlot[T]` shared via ArcPointer with the producer
# (the worker thread that runs the spawned closure).
#
# Why ArcPointer-shared `_SpawnSlot[T]`? The result + wake-word + error
# need to be accessible from BOTH the JoinHandle (joiner side) AND the
# task body's completer code (producer side). Producer writes
# result/error then bumps wake-word + calls wake_one_by_address; joiner
# parks on wake-word until non-zero; reads result.
#
# DROP = CANCEL. JoinHandle.__del__ cancels its task's token.
# Cascades through token tree. #1 first-day gotcha for users
# porting from sync code or from tokio (where Drop on tokio's JoinHandle
# DETACHES — opposite default).
#
# 2 scope (this commit):
#   * `_SpawnSlot[T]`: heap-allocated wake-word + result + error slot.
#   * `JoinHandle[T]` real impl: holds ArcPointer[_SpawnSlot[T]] + token.
#     join() parks via Mechanism D; cancel(); detach(); is_finished();
#     __del__ cancel.
#   * `complete_slot[T]` / `complete_slot_err` static helpers: producer-
#     side API to publish result + wake.
#
# ForkJoinSpawner and LocalSpawner (multi-worker pthread launch) are
# built around this.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, alloc
from komira_atomic_alias import AtomicI32

from komira_async.cancellation.token import CancellationToken
from komira_async.runtime.wake_primitives import (
    cpu_pause,
    pause_intrinsic,
    wait_on_address,
    wake_one_by_address,
)


# =============================================================================
# Spawn-slot wake-word constants
# =============================================================================
# wake_word transitions:
#   0 — pending (joiner parks here)
#   1 — completed (result populated)
#   2 — completed-with-error (err populated)
#   3 — cancelled (joiner exits with CancelledError)

comptime _SLOT_PENDING: Int32 = 0
comptime _SLOT_READY: Int32 = 1
comptime _SLOT_ERR: Int32 = 2
comptime _SLOT_CANCELLED: Int32 = 3


struct _SpawnSlot[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Heap-allocated shared state between JoinHandle (joiner) and the
    spawned task's body (producer).

    Shared via ArcPointer[_SpawnSlot[T]] — both sides hold a reference;
    refcount drops to 0 when both sides have completed.

    OwnedPointer[Atomic[int32]] indirection for wake_word: Atomic is non-
    Movable on 0.26.3; ArcPointer requires T: Movable; so we wrap the
    Atomic. Same shape as CancellationToken._AtomicSlot.
    """

    var _wake_word: OwnedPointer[AtomicI32]
    var _result: Optional[Self.T]
    var _err: String

    def __init__(out self):
        var raw = alloc[AtomicI32](1)
        # SAFETY: raw is a fresh allocation we own. Atomic ctor accepts a
        # Scalar value. Ownership transfers to OwnedPointer.
        raw[] = AtomicI32(_SLOT_PENDING)
        self._wake_word = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw
        )
        self._result = Optional[Self.T]()
        self._err = String("")


# =============================================================================
# JoinHandle[T] — result-bearing one-shot handle
# =============================================================================


struct JoinHandle[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Result-bearing handle returned by
    Spawner.spawn. NOT Copyable.

    2 field set:
      var _shared_slot: ArcPointer[_SpawnSlot[T]]   # shared wake-word + result
      var _op_id: Int64                              # diagnostics
      var _token: CancellationToken
      var _joined: Bool

    Field naming convention:
    every ArcPointer-typed field carries the `_shared_*` prefix to make
    the audit-grep cheap. `_shared_slot` is the JoinHandle case; the
    convention is enforced by review.

    Park semantics (Mechanism D wake-by-address): join() parks via
    `wait_on_address(slot.wake_word, expected=_SLOT_PENDING)`; producer
    writes slot.result then `wake_word.store(_SLOT_READY)` +
    `wake_one_by_address(slot.wake_word)`.
    """

    # `_shared_*` prefix marks ArcPointer fields.
    # The single legitimate ArcPointer in this package — shared between
    # JoinHandle (consumer side) and the spawn trampoline (producer side)
    # to carry the wake-word + result + error slot across worker pthreads.
    var _shared_slot: ArcPointer[_SpawnSlot[Self.T]]
    var _op_id: Int64
    var _token: CancellationToken
    var _joined: Bool

    def __init__(
        out self,
        var slot: ArcPointer[_SpawnSlot[Self.T]],
        op_id: Int64,
        var token: CancellationToken,
    ):
        self._shared_slot = slot^
        self._op_id = op_id
        self._token = token^
        self._joined = False

    def op_id(self) -> Int64:
        """Diagnostics-only spawn-keyspace ID."""
        return self._op_id

    def is_finished(self) -> Bool:
        """True if the slot's wake-word has been
        set to a terminal state (READY / ERR / CANCELLED)."""
        return self._shared_slot[]._wake_word[].load() != _SLOT_PENDING

    # Tier 1: implicit token from worker-local state.
    def join(var self) raises -> Self.T:
        """Park until task completes.
        Returns by COPY (T: ImplicitlyCopyable).

        Raises if:
          * already joined (double-join).
          * slot ended in _SLOT_ERR (raises Error with the slot's err msg).
          * slot ended in _SLOT_CANCELLED OR self._token.is_cancelled()
            (raises Error("CancelledError: ...")).

        Park protocol:
          1. spin briefly (up to SPIN_BUDGET iterations) checking the
             wake_word; if non-pending, jump straight to terminal-state
             handling without a syscall. This avoids futex roundtrip on
             the fast path where the worker drains within ~1 µs (the
             common case under the per-core async runtime where the
             worker is in busy-poll mode after the first iteration).
          2. snapshot wake_word = load(Acquire)
          3. if non-pending → terminal; skip park.
          4. if self._token.is_cancelled() → cancel + raise.
          5. wait_on_address(wake_word, expected=_SLOT_PENDING)
          6. loop back to step 2.
        """
        if self._joined:
            raise Error("JoinHandle.join: handle already consumed")
        self._joined = True

        # Fast-path spin: avoid the futex syscall when the
        # worker drains within ~1 µs (steady-state busy-poll mode).
        #
        # cpu_pause (sched_yield) here would trigger
        # ~256 syscalls per spawn — under heavy spawn+join
        # load this denies the scheduler the ability to keep tcmalloc's
        # per-CPU cache state coherent and can surface as occasional heap
        # corruption. Use pause_intrinsic (CPU PAUSE on x86; sched_yield
        # fallback on aarch64) for the inner spin — much cheaper, no
        # syscall churn, and the worker pthread runs on a separate core
        # so we don't need to actively yield to give it time.
        var spin_budget = 64
        var spins = 0
        while spins < spin_budget:
            var state_fast = self._shared_slot[]._wake_word[].load()
            if state_fast != _SLOT_PENDING:
                break
            pause_intrinsic()
            spins = spins + 1

        # Park loop. Re-checks state on every iteration.
        while True:
            var state = self._shared_slot[]._wake_word[].load()
            if state == _SLOT_READY:
                if self._shared_slot[]._result.__bool__():
                    return self._shared_slot[]._result.value()
                raise Error("JoinHandle.join: slot READY but result missing (internal)")
            if state == _SLOT_ERR:
                raise Error("JoinHandle.join: " + self._shared_slot[]._err)
            if state == _SLOT_CANCELLED:
                raise Error("CancelledError: spawned task cancelled")
            if self._token.is_cancelled():
                # Token cancelled (probably by JoinHandle drop or scope
                # cancel). Mark slot cancelled + raise.
                AtomicI32.store(
                    UnsafePointer(to=self._shared_slot[]._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](),
                    _SLOT_CANCELLED,
                )
                raise Error("CancelledError: " + self._token.reason())
            # state == _SLOT_PENDING — park.
            _ = wait_on_address(
                self._shared_slot[]._wake_word[],
                expected=_SLOT_PENDING,
                timeout_ns=Int64(1_000_000),  # 1ms timeout = poll cancel every ms
            )

    # Tier 2: explicit token (escape hatch).
    def join_with_token(var self, var token: CancellationToken) raises -> Self.T:
        """Override the implicit token with
        an explicit one. Useful for select / with_timeout combinators.

        drop the explicit token after consuming (we keep the
        implicit one set during construction). A fuller implementation
        would CAS the explicit token in place; current shape is fine for
        the exposed signatures.
        """
        # Drop the override token; current impl uses self._token.
        _ = token^
        return self^.join()

    def cancel(mut self):
        """Signal cancellation; does NOT
        park. The task observes cancellation on its next poll boundary.
        Idempotent."""
        self._token.cancel(String("JoinHandle.cancel"))
        # Also bump wake-word so any current wait_on_address returns.
        AtomicI32.store(
            UnsafePointer(to=self._shared_slot[]._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](), _SLOT_CANCELLED,
        )
        _ = wake_one_by_address(self._shared_slot[]._wake_word[])

    def detach(var self) -> CancellationToken:
        """Consume the handle WITHOUT
        cancelling the task. Returns the task's CancellationToken so the
        caller may cancel later if needed. The result becomes inaccessible.

        Marks _joined=True so the destructor doesn't try to cancel.
        """
        self._joined = True
        return self._token.clone()

    def __deinit__(deinit self):
        """Drop = cancel.

        If _joined == False, cancel the task's token. Cascades through
        token tree. Drop after join / detach is a no-op.

        SAFER default vs tokio (which detaches on drop): forgetting to
        join silently leaks a background task whose result was needed;
        cancelling makes the task body's cancel-observation point raise +
        the task exit. spawn_drop is the explicit opt-in for detached
        tasks.
        """
        if not self._joined:
            self._token.cancel(String("JoinHandle dropped without join"))
            # Bump wake-word so any active joiner returns.
            AtomicI32.store(
                UnsafePointer(to=self._shared_slot[]._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](), _SLOT_CANCELLED,
            )
            _ = wake_one_by_address(self._shared_slot[]._wake_word[])


# =============================================================================
# Producer-side helpers: complete_slot / complete_slot_err / cancel_slot
# =============================================================================
# These are the API the spawned task body (or its trampoline) calls to
# publish a result. Same module as JoinHandle so we can access _SpawnSlot's
# fields without cross-module unsafe-cast gymnastics.


def complete_slot[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](ref [_] slot: ArcPointer[_SpawnSlot[T]], value: T):
    """Producer-side: publish a successful result + wake the joiner.

    Takes `slot` by REFERENCE (not consuming) so the producer can keep
    its Arc handle for cleanup. The pattern is: producer holds Arc;
    consumer holds another Arc; both die when refcount → 0.

    Order of operations:
      1. write result (Optional[T] field)
      2. store wake_word = _SLOT_READY (Release fence implicit via store)
      3. wake_one_by_address(wake_word)
    """
    slot[]._result = Optional[T](value)
    AtomicI32.store(
        UnsafePointer(to=slot[]._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](), _SLOT_READY,
    )
    _ = wake_one_by_address(slot[]._wake_word[])


def complete_slot_err[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](ref [_] slot: ArcPointer[_SpawnSlot[T]], err: String):
    """Producer-side: publish an error + wake the joiner."""
    slot[]._err = err
    AtomicI32.store(
        UnsafePointer(to=slot[]._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](), _SLOT_ERR,
    )
    _ = wake_one_by_address(slot[]._wake_word[])


def cancel_slot[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](ref [_] slot: ArcPointer[_SpawnSlot[T]]):
    """Producer-side: mark slot cancelled (rarely needed; usually the
    JoinHandle's __del__ cancels via its own path)."""
    AtomicI32.store(
        UnsafePointer(to=slot[]._wake_word[]).unsafe_bitcast[Scalar[DType.int32]](), _SLOT_CANCELLED,
    )
    _ = wake_one_by_address(slot[]._wake_word[])


def make_spawn_slot[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
]() -> ArcPointer[_SpawnSlot[T]]:
    """Producer + consumer-side: allocate a fresh _SpawnSlot[T] in an
    ArcPointer. Caller clones into JoinHandle on consumer side; into the
    task trampoline on producer side."""
    return ArcPointer[_SpawnSlot[T]](_SpawnSlot[T]())

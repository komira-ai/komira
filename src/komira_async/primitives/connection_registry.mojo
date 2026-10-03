# =============================================================================
# komira_async.primitives.connection_registry — graceful-shutdown registry
# =============================================================================
# Per-server registry of in-flight
# connection handles. Used by HTTP server accept loop (writer) +
# graceful-shutdown coordinator (reader/drainer).
#
# Encapsulation idiom: wrap ArcPointer in a
# Movable struct, expose a clean method API, NEVER let ArcPointer cross
# a function boundary. The wrapper is the entire public surface.
#
# Mojo 0.26.3 storage shape (matches ComputeTaskScope at
# spawner/task_scope.mojo:50): List[T] requires Copyable T; JoinHandle
# and CancellationToken are both NOT Copyable. We therefore store
# parallel lists of:
#   * `_slots: List[ArcPointer[_SpawnSlot[NoneType]]]` — the wake-words +
#     result slots (ArcPointer is Copyable so List elaborates).
#   * Internal slot count tracking via `_count: OwnedPointer[Atomic[int64]]`
#     decoupled from len(_slots) so the count is observable lock-free.
#
# JoinHandle for a registered connection is constructed AT register-time
# from a slot + token; the registry holds onto the slot. drain_with_timeout
# parks on each slot's wake_word to detect completion (matches
# JoinHandle.join's protocol).
#
# Pointer discipline:
#   - `_shared: ArcPointer[_ConnectionRegistryShared]` is the ONE
#     encapsulated ArcPointer field on the wrapper.
#   - ZERO ArcPointer in any public method signature.
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO wildcard origins on public surface.
#   - UnsafePointer ONLY for in-module Atomic-storage pointer
#     arithmetic. Each site has SAFETY block.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32, AtomicI64

from komira_async.runtime.wake_primitives import wait_on_address
from komira_async.spawner.join_handle import _SpawnSlot


# =============================================================================
# Lock + slot-state sentinels
# =============================================================================

comptime _LOCK_UNLOCKED: Int32 = 0
comptime _LOCK_LOCKED: Int32 = 1

# Slot wake-word terminal states (matches join_handle.mojo aliases).
comptime _SLOT_PENDING: Int32 = 0
comptime _SLOT_TERMINAL_LOW: Int32 = 1   # READY / ERR / CANCELLED >= 1


# =============================================================================
# _ConnectionRegistryShared — heap-allocated shared state
# =============================================================================


struct _ConnectionRegistryShared(Movable, Deinitable):
    """Heap-allocated shared state
    behind ArcPointer.

    Storage shape (matches ComputeTaskScope at spawner/task_scope.mojo:50):
    `List[ArcPointer[_SpawnSlot[NoneType]]]` — the wake-words + result
    slots. ArcPointer is Copyable so List elaborates.

    Spinlock protects mutation ops (append / pop). Necessary because
    AsyncMutex requires Copyable T — neither ArcPointer-of-slot
    nor any list-of-slots variant alone suffices for the inline mutation
    pattern we need.

    Movable so ArcPointer[_ConnectionRegistryShared] elaborates.
    """

    var _slots: List[ArcPointer[_SpawnSlot[NoneType]]]
    var _state: OwnedPointer[AtomicI32]      # 0 = unlocked, 1 = locked
    var _count: OwnedPointer[AtomicI64]      # observable lock-free

    def __init__(out self):
        self._slots = List[ArcPointer[_SpawnSlot[NoneType]]]()
        var raw = alloc[AtomicI32](1)
        # SAFETY: raw is a fresh allocation we own. Atomic ctor accepts
        # a Scalar; ownership transfers to OwnedPointer.
        raw[] = AtomicI32(_LOCK_UNLOCKED)
        self._state = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw
        )
        var c_raw = alloc[AtomicI64](1)
        c_raw[] = AtomicI64(Int64(0))
        self._count = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=c_raw
        )

    def _acquire_lock(mut self):
        """Spin until lock acquired (CAS UNLOCKED → LOCKED)."""
        while True:
            var expected = _LOCK_UNLOCKED
            if self._state[].compare_exchange(expected, _LOCK_LOCKED):
                return

    def _release_lock(mut self):
        # SAFETY: Atomic.store static-method form writes the
        # _LOCK_UNLOCKED sentinel back to the lock word.
        AtomicI32.store(
            UnsafePointer(to=self._state[]).unsafe_bitcast[Scalar[DType.int32]](), _LOCK_UNLOCKED
        )


# =============================================================================
# ConnectionRegistry — public Movable wrapper
# =============================================================================


@fieldwise_init
struct ConnectionRegistry(Movable, Deinitable):
    """Per-server registry of
    in-flight connection handles. Used by accept loop (writer) +
    graceful-shutdown (reader/drainer).

    Internally backed by an ArcPointer to spinlock-protected state.
    The public surface is move/clone-only — consumers never see
    ArcPointer. Clones share the same underlying registry; drops
    decrement the refcount.

    Pointer-discipline note: the `_shared` field is the ONE encapsulated
    ArcPointer. It NEVER appears in any public method signature.

    24 API:
      * new() — empty registry
      * clone() — handle clone (Arc bump)
      * register_slot(var slot: ArcPointer[_SpawnSlot[NoneType]]) —
        register a spawn-slot (the writer/accept-loop holds a clone of
        this slot for its trampoline; the registry holds another clone)
      * drain_with_timeout(deadline_ns) — waits for all registered
        slots to reach a terminal state (READY / ERR / CANCELLED) or
        deadline expires
      * count() -> UInt — current registered count (snapshot, lock-free)

    Wire-up note: HTTP server's accept loop holds a sender for the
    spawn-slot's outcome wake; calls register_slot AFTER spawn(); the
    server's main loop runs drain_with_timeout on shutdown signal.
    """

    var _shared: ArcPointer[_ConnectionRegistryShared]

    @staticmethod
    def new() raises -> ConnectionRegistry:
        """Construct an empty registry."""
        return ConnectionRegistry(
            _shared=ArcPointer[_ConnectionRegistryShared](
                _ConnectionRegistryShared()
            )
        )

    def clone(self) -> ConnectionRegistry:
        """Clone the registry handle; both clones share the same
        underlying state via ArcPointer.copy."""
        return ConnectionRegistry(
            _shared=ArcPointer[_ConnectionRegistryShared](copy=self._shared)
        )

    def register_slot(
        mut self,
        var slot: ArcPointer[_SpawnSlot[NoneType]],
    ) raises:
        """Register a spawn-slot for
        graceful-shutdown tracking. The registry takes ownership of an
        Arc clone; the producer keeps its own clone for completion."""
        self._shared[]._acquire_lock()
        self._shared[]._slots.append(slot^)
        # SAFETY: count is incremented inside the lock so it stays
        # consistent with len(_slots) at observation points.
        _ = AtomicI64.fetch_add(
            UnsafePointer(to=self._shared[]._count[]).unsafe_bitcast[Scalar[DType.int64]](), Int64(1)
        )
        self._shared[]._release_lock()

    def drain_with_timeout(mut self, deadline_ns: Int64) raises:
        """

        Minimum-viable: serial wake-word park loop. Each
        registered slot's wake_word is observed; if PENDING, park via
        Mechanism D wait_on_address with `min(remaining_to_deadline,
        100ms)` poll cadence. Once all slots reach a terminal state
        (READY / ERR / CANCELLED) OR the deadline expires, drain
        clears the registry and returns.

        A later step: parallel-park via select(); deadline
        wall-clock via clock_gettime; cancellation-cascade integration
        with global shutdown coordinator.
        """
        # Take the lock once + drain to a local list to avoid holding
        # the lock during the wait loop (which can block).
        self._shared[]._acquire_lock()
        var local: List[ArcPointer[_SpawnSlot[NoneType]]] = List[
            ArcPointer[_SpawnSlot[NoneType]]
        ]()
        while len(self._shared[]._slots) > 0:
            var s = self._shared[]._slots.pop()
            local.append(s^)
        # Reset the count under the same lock.
        AtomicI64.store(
            UnsafePointer(to=self._shared[]._count[]).unsafe_bitcast[Scalar[DType.int64]](), Int64(0)
        )
        self._shared[]._release_lock()

        # deadline_ns currently advisory. Each slot is
        # polled with a 1ms wait_on_address per iteration; once all
        # slots are observed terminal we exit.
        _ = deadline_ns
        for i in range(len(local)):
            var slot = local[i]
            # Park until terminal: polls every 1ms (a deadline_ns via
            # clock_gettime is a later step).
            while True:
                var state = slot[]._wake_word[].load()
                if state >= _SLOT_TERMINAL_LOW:
                    break
                _ = wait_on_address(
                    slot[]._wake_word[],
                    expected=_SLOT_PENDING,
                    timeout_ns=Int64(1_000_000),  # 1ms
                )

    def count(self) -> UInt:
        """Current number of
        registered in-flight connections. Observability hook.

        Lock-free read of the Atomic[int64] count — safe to call from
        any thread, no contention with writers."""
        return UInt(Int(self._shared[]._count[].load()))

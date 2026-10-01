# =============================================================================
# komira_async.runtime.parked_morsel_slab — ParkedMorselSlab[State]
# =============================================================================
# The per-worker data structure that holds morsel
# state for IO-parked morsels, keyed by op_id. The worker's morsel-step
# trampoline catches `StepResult.parked(op_id)` from operator step calls
# and inserts the morsel state here; on `Reactor.poll_completions`
# returning a Completion for that op_id, the worker drains the slab and
# resumes the morsel.
#
# The data structure is a standalone primitive (testable +
# verifiable in isolation). The worker-loop integration (advance_morsel
# trampoline + completion-driven resume) builds on it; its design depends
# on the operator step trait's final shape. Shipping the slab separately
# lets engine /
# operator authors prototype against the canonical store without waiting
# for the full trampoline.
#
# Field set:
#   * `_op_ids: List[Int64]` — keys, one per parked morsel. Int64 is
#     trivially Copyable so List[Int64] is the right primitive.
#   * `_states: Slab[Self.State]` — values. Slab supports Movable T
#     natively (no Copyable bound); same primitive used by Worker's
#     `_ready_cache: Slab[OpHandle]` and AggregateBuilder's slot table.
#
# Why Slab[State] not List[State]:
#   - Mojo 0.26.3's stdlib List[T] requires `T: Copyable`. State is
#     `Movable + KeepAlive` only; can't go in a
#     List directly.
#   - Slab[T] is the engine's canonical Movable-T container, and it
#     ships with `take_at(idx)` (the move-out-with-shift primitive we
#     need on resume).
#
# Why parallel arrays not Dict[Int64, State]:
#   - Mojo 0.26.3 Dict has a non-trivial copy / partial-move shape that
#     interacts poorly with Movable-only State types.
#   - Same shape as Reactor._wakers (List[WakerSlot]) — established pattern.
#
# Demux scaling:
#   - The original `take` / `contains` LINEAR-SCANNED `_op_ids`, scoped
#     in-comment to "<100 in-flight/worker". The streaming gap (thousands
#     of idle parked streams) makes every wakeup O(n) -> O(n^2) under a
#     wake storm. We now hold a POD `OpIdIndexMap` (op_id -> dense index)
#     alongside the parallel arrays so lookup / contains / take are O(1)
#     amortized. The payload arrays stay DENSE via SWAP-REMOVE (move the
#     last element into the freed slot) so a removal patches AT MOST ONE
#     other key's map entry — the whole take path is O(1) amortized.
#   - The map is ALL POD (Int64 keys + Int indices); safe across destroy-recreate by
#     construction even though `ParkedMorselSlab` is a `Movable` struct.
#
# Pointer discipline:
#   * ZERO `UnsafePointer` in any public method signature.
#   * ZERO wildcard origins.
#   * State is taken in by VALUE (var state); on resume it is extracted
#     via Slab.swap_remove — an O(1) Movable-T move-out primitive.
#     No partial-move via `UnsafePointer(to=...).take_pointee()`.
# =============================================================================

from komira_async.runtime.op_id_index_map import OpIdIndexMap
from komira_core.collections.slab import Slab


struct ParkedMorselSlab[
    State: Movable & Deinitable,
](Movable, Deinitable):
    """Per-worker store of parked-morsel state, keyed by op_id.

    Lifecycle:
      1. Worker's morsel-step trampoline calls operator.step(state, ctx),
         which internally calls io_block.try_io_handle(...).
      2. If try_io returns StepResult.parked(op_id), the trampoline calls
         this slab's `park(op_id, state)` to take ownership of the state.
      3. On the next iteration, the worker calls
         `reactor.poll_completions(0 or -1)` and walks the returned
         Completions; for each completion whose op_id is in this slab,
         the trampoline calls `take(op_id)` to retrieve the state and
         re-runs operator.step with it.

    NOT thread-safe by design — each Worker owns its own slab; the only
    accesses are from the worker's own pthread (single-consumer +
    single-producer = no synchronization needed).
    """

    var _op_ids: List[Int64]
    var _states: Slab[Self.State]
    # op_id -> dense index into _op_ids / _states. O(1) demux.
    # ALL POD (Int64 -> Int); safe across destroy-recreate by construction.
    var _index: OpIdIndexMap

    def __init__(out self):
        """Construct an empty slab."""
        self._op_ids = List[Int64]()
        self._states = Slab[Self.State](capacity=4)
        self._index = OpIdIndexMap()

    def __init__(out self, capacity: Int):
        """Construct with reserved capacity (avoids early growth under
        burst-load workloads). Same-shape as Reactor's WakerSlot list."""
        self._op_ids = List[Int64](capacity=capacity)
        self._states = Slab[Self.State](capacity=capacity)
        self._index = OpIdIndexMap(capacity_hint=capacity)

    def park(mut self, op_id: Int64, var state: Self.State):
        """Insert a parked morsel. Takes ownership of `state` by VALUE
        (no partial-move via take_pointee). The slab grows as needed.

        Caller contract: `op_id` MUST be unique within this slab at the
        time of insertion. The index map is keyed by op_id; a duplicate
        park OVERWRITES the prior op_id's index in the map (the prior
        payload slot is then unreachable via the map — a caller bug, since
        reactors monotonically allocate op_ids). O(1) amortized."""
        var idx = len(self._op_ids)
        self._op_ids.append(op_id)
        self._states.append(state^)
        self._index.insert(op_id, idx)

    def take(mut self, op_id: Int64) -> Optional[Self.State]:
        """Find the slot for `op_id` and extract the state. Returns
        None if no slot matches.

        Slot extraction (O(1) amortized —):
          1. O(1) map lookup for the dense payload index.
          2. SWAP-REMOVE: take the State via Slab.swap_remove(idx) (moves
             the LAST slot into the freed one; O(1), no tail shift).
          3. Mirror the swap in _op_ids (move the last op_id into the
             freed slot, pop the tail).
          4. Patch the map: tombstone the removed op_id; if the swap moved
             another op_id into `idx`, update its map entry to `idx`.

        Returns the extracted State by VALUE (Movable transfer)."""
        var idx = self._index.lookup(op_id)
        if idx < 0:
            return Optional[Self.State]()
        var last = len(self._op_ids) - 1
        # Take the State via Slab.swap_remove (moves the last slot into idx).
        var s = self._states.swap_remove(idx)
        # Mirror the swap in _op_ids: move the last key into the freed slot.
        var moved_op_id = self._op_ids[last]
        if idx != last:
            self._op_ids[idx] = moved_op_id
        _ = self._op_ids.pop()
        # Patch the index map.
        _ = self._index.remove(op_id)
        if idx != last:
            # The element formerly at `last` now lives at `idx`.
            self._index.update(moved_op_id, idx)
        return Optional[Self.State](s^)

    def contains(self, op_id: Int64) -> Bool:
        """Predicate: does the slab hold a morsel for `op_id`? O(1)
        amortized. Used by
        worker-loop completion dispatch to decide whether a Completion
        belongs to a parked morsel (vs an IoOp's ready_cache, vs a
        cancelled / dropped op)."""
        return self._index.contains(op_id)

    def len(self) -> Int:
        """Number of parked morsels currently held."""
        return len(self._op_ids)

    def op_id_at(self, i: Int) -> Int64:
        """The op_id key of the i-th parked slot (insertion order). Used by the
        demux test to read which biased op_id a frame parked on. Caller bounds
        `i < len()`."""
        return self._op_ids[i]

    def is_empty(self) -> Bool:
        """True when no morsels are parked."""
        return len(self._op_ids) == 0

    # ---- demux sub-linearity instruments ----

    def probe_contains(mut self, op_id: Int64) -> Bool:
        """Like `contains` but counts the map probe steps into the internal
        instrument (drained via `probe_steps`). The sub-linearity scaling test
        drives N membership checks through this and asserts the total probe count
        stays O(N), not O(N^2). Production uses the un-instrumented `contains`."""
        return self._index.probe_lookup(op_id) >= 0

    def reset_probe_counter(mut self):
        """Zero the internal map's cumulative probe counter (test instrument)."""
        self._index.reset_probe_counter()

    def probe_steps(self) -> Int:
        """Cumulative map probe steps since construction / last reset (test
        instrument)."""
        return self._index.probe_steps()

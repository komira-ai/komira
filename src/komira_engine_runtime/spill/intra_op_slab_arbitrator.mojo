# =============================================================================
# intra_op_slab_arbitrator.mojo — IntraOpSlabArbitrator[T, S]
# =============================================================================
#
# # Role
#
# Intra-operator spill arbitrator over a homogeneous `Slab[T]`. The Slab
# is OWNED BY THE CALLER (typically the per-Local sink state, e.g.
# `FlatHashAggLocal.flushed_partitions`). The arbitrator does NOT take
# ownership; it operates on a `mut`-ref derived per call. This is the
# canonical shape for dense-uniform homogeneous spill cohorts
# (FlatHashPartitionFlush × 256/Local; SortRun × N; JoinBuildBlock × N) —
# the variadic `*Ops` pack at `SpillArbitrator[S, *Ops]` is the wrong
# abstraction for this case because:
#
#   1. Arity is RUNTIME (`num_partitions = sink._num_partitions = 256` is
#      a per-sink-construction value, not a comptime literal).
#   2. All entries are the same type T — the heterogeneity that the
#      variadic pack exists to support is absent.
#   3. The Slab is already heap-owned by the consume path; moving
#      partitions into the arbitrator forces a different ownership model
#      on the perf-critical consume scatter loop.
#
# # Why NOT additive parallel API
#
# `IntraOpSlabArbitrator[T, S]` (intra-op homogeneous) and
# `SpillArbitrator[S, *Ops]` (inter-op heterogeneous, P-1.C) encode
# DIFFERENT scopes; the rule against parallel `_v2` APIs applies to the SAME
# scope only.
#
# # Why the suggested `SpillableOpHandle` vtable was REJECTED
#
# The carve-out (a) for fn-ptr fields permits the **code pointer** (no
# heap). The companion **data pointer** to the partition slot is a heap
# pointer — and a borrowed-non-owning heap pointer at that. A
# "borrowed pointer nulled between uses" field on a destroy-recreate struct
# is not an accepted carve-out.
# The arbitrator is per-Local-scope; the partition Slab is also per-
# Local-scope but they tear down together. A vtable carrying a borrowed
# data-ptr would re-introduce the exact dangling-handle hazard the
# carve-out removal forbids — see `WorkerPool._state_ptr` as the
# canonical instance of the banned pattern.
#
# v0.6's resolution: pass the Slab in per call (via `ref [o_slab]
# Slab[T]` with concrete origin from the caller's stack frame). The
# arbitrator has no field that survives across the call boundary; the
# lifetime hazard is eliminated by construction, not by runtime
# convention.
#
# # Lifetime
#
# Owned by the per-Local sink state (FlatHashAggLocal in P-1.D.1.b). The
# arbitrator carries the SpillStorage backend by value (`_storage: S`);
# the Slab[T] is borrowed per call via `ref [o_slab] Slab[T]`. The
# `_storage` field's lifetime is tied to the arbitrator's own lifetime —
# dropped when the Local drops.
#
# # Threading
#
# Single-arbitrator-per-Local + single-threaded-arbitrate-call (one
# worker per Local; the consume hot path is wid-disjoint). Caller
# serializes pressure_check calls.
#
# # Encapsulation rule
#
# - Public method surface uses `Int64`, `Bool`, `ArbitratorPolicy`, and
#   `ref [o_slab] Slab[Self.T]`. NO `UnsafePointer` at the boundary. NO
#   wildcard origins on any field.
# - The `_storage: Self.S` field is owned-by-value; the Slab carries its
#   own concrete origin from the caller's stack frame on every call.
# =============================================================================

from komira_collections.slab import Slab

from .policies import ArbitratorPolicy
from .spill_storage import SpillStorage
from .spillable_op import SpillableOp


# Sentinel for "no victim chosen this pass" — same shape as
# `spill_arbitrator.mojo`'s `_NO_VICTIM_INDEX`.

comptime _NO_VICTIM_INDEX: Int = -1


# =============================================================================
# IntraOpSlabArbitrator[T, S]
# =============================================================================


struct IntraOpSlabArbitrator[T: SpillableOp, S: SpillStorage](
    Movable, Deinitable
):
    """Intra-operator spill arbitrator over a homogeneous `Slab[T]`.

    The Slab is CALLER-OWNED (typically per-Local sink state, e.g.
    `FlatHashAggLocal.flushed_partitions`). The arbitrator does NOT take
    ownership; it operates on a `mut`-ref derived per call. See module
    docstring for the rationale + the lifetime contract.

    # Fields

        _storage:       the SpillStorage backend, OWNED by the
                        arbitrator. The victim's `spill_to_storage[S]`
                        receives this `mut`-ref and routes its THSPILL2
                        bytes through.
        _budget_bytes:  shared byte budget. Pressure fires strictly GT.
        _policy:        victim-pick rule (default OLDEST_FIRST).
        _spill_event_count: telemetry — number of times
                        `pressure_check_and_arbitrate` actually invoked
                        a spill (i.e. bytes_freed > 0).
        _no_victim_count: telemetry — number of pressure-firing
                        arbitrate passes that found no spillable
                        candidate (returned 0 bytes_freed).

    NOTE: there is NO `_ops` / `_slab` field. The slab is passed in per
    call via the `pressure_check_and_arbitrate` mut-ref arg. This is the
    structural difference from `SpillArbitrator[S, *Ops]` — and the
    reason this arbitrator composes with caller-owned partition slabs.
    """

    var _storage: Self.S
    var _budget_bytes: Int64
    var _policy: ArbitratorPolicy
    var _spill_event_count: Int64
    var _no_victim_count: Int64

    def __init__(
        out self,
        var storage: Self.S,
        budget_bytes: Int64,
        policy: ArbitratorPolicy = ArbitratorPolicy.oldest_first(),
    ):
        """Construct an intra-op arbitrator over the caller's slab.

        Args:
            storage:      `SpillStorage` backend the arbitrator hands to
                          each spill victim's `spill_to_storage` call.
                          Consumed.
            budget_bytes: Shared byte budget across every slot in the
                          caller-owned Slab. Pressure fires strictly
                          GREATER-than (`>`), not `>=`, so a request
                          that exactly fills the budget does NOT trigger
                          spill (matches the existing
                          `MemoryReservation.try_grow` and
                          `SpillArbitrator` semantics).
            policy:       Victim-pick policy. Default OLDEST_FIRST; v0.6
                          P-1.D.1.a only OLDEST_FIRST works at runtime —
                          LARGEST_FIRST / PROPORTIONAL_RESERVATION raise
                          from `pressure_check_and_arbitrate`.
        """
        self._storage = storage^
        self._budget_bytes = budget_bytes
        self._policy = policy
        self._spill_event_count = Int64(0)
        self._no_victim_count = Int64(0)

    # =========================================================================
    # Telemetry accessors
    # =========================================================================

    @always_inline
    def budget_bytes(self) -> Int64:
        """The shared spill budget (Int64; bytes)."""
        return self._budget_bytes

    @always_inline
    def policy(self) -> ArbitratorPolicy:
        """The currently-selected victim-pick policy."""
        return self._policy

    @always_inline
    def spill_event_count(self) -> Int64:
        """How many arbitrate passes successfully spilled a victim
        (bytes_freed > 0). Production telemetry / test assertion."""
        return self._spill_event_count

    @always_inline
    def no_victim_count(self) -> Int64:
        """How many arbitrate passes fired under pressure but found no
        spillable candidate (bytes_freed == 0). Production telemetry /
        test assertion."""
        return self._no_victim_count

    @always_inline
    def storage_ref(ref self) -> ref [self._storage] Self.S:
        """Borrow the underlying `SpillStorage`. Used by tests + future
        wiring that needs to inspect `nbytes_in_use()` outside an
        arbitrate pass. Symmetric to `SpillArbitrator.storage_ref`."""
        return self._storage

    @always_inline
    def storage_mut(mut self) -> ref [self._storage] Self.S:
        """Borrow the underlying `SpillStorage` mutably so callers can
        write/read chunks directly (LARGEST-FIRST fallback path, or any
        forced-abandon spill that bypasses the policy-driven victim
        pick). Used by `FlatHashAggLocal._handle_budget_exceeded_spill`
        (P-1.D.1.b) and the finalize-time restore in
        `_rehydrate_spilled_partitions`.
        """
        return self._storage

    @always_inline
    def bump_spill_event_count(mut self):
        """Telemetry hook: bump `_spill_event_count` from an external
        caller that performed a manual spill via `storage_mut()`.
        Keeps the arbitrator's event count accurate when the sink-side
        LARGEST-FIRST fallback spills outside of
        `pressure_check_and_arbitrate`.
        """
        self._spill_event_count += Int64(1)

    # =========================================================================
    # Read-only Slab accounting
    # =========================================================================

    def total_resident_bytes[
        o_slab: Origin
    ](
        self,
        ref [o_slab] slab: Slab[Self.T],
        slab_len: Int,
    ) -> Int64:
        """Sum `memory_usage_bytes()` over `slab[0..slab_len)`.

        Exposed publicly for test assertions + potential telemetry
        callers; the hot path uses `_total_resident_bytes` internally
        (same shape).

        `slab_len` is passed explicitly because the Slab's "logical
        length" is caller-owned (FlatHashAggLocal uses
        `sink._num_partitions` as the active-slot count; the slab's
        physical len may exceed that for capacity reasons).
        """
        return self._total_resident_bytes(slab, slab_len)

    @always_inline
    def _total_resident_bytes[
        o_slab: Origin
    ](
        self,
        ref [o_slab] slab: Slab[Self.T],
        slab_len: Int,
    ) -> Int64:
        var total: Int64 = 0
        for i in range(slab_len):
            # b2 trait-resolution: `slab[i]` types to `Slab`'s `Deinitable`
            # bound, which lacks SpillableOp methods. Re-bind to `Self.T` so the
            # caller's `T: SpillableOp` conformance (and its methods) is visible.
            ref e: Self.T = slab[i]
            total += e.memory_usage_bytes()
        return total

    # =========================================================================
    # pressure_check_and_arbitrate — the hot path entry
    # =========================================================================

    def pressure_check_and_arbitrate[
        o_slab: Origin[mut=True]
    ](
        mut self,
        ref [o_slab] slab: Slab[Self.T],
        slab_len: Int,
        grow_bytes: Int64,
    ) raises -> Int64:
        """Check pressure across `slab[0..slab_len)`; spill ONE victim
        if so. Returns bytes freed.

        Shape:
          1. Sum every live slot's `memory_usage_bytes` → `current`.
          2. If `current + grow_bytes <= _budget_bytes`: return 0
             (fast path; no pressure).
          3. OLDEST_FIRST: scan `can_spill() == True` slots, pick the
             smallest `age_ticks`. (Other policies reserved per
             the design / §10.10.6.)
          4. Call `slab[victim_idx].spill_to_storage(self._storage)`.
          5. Return bytes_freed (telemetry-bump on `>0`).

        `slab_len` is passed explicitly because the Slab's "logical
        length" is caller-owned (FlatHashAggLocal uses
        `sink._num_partitions` as the active-slot count; the slab's
        physical len may exceed that for capacity reasons).

        Args:
            slab:       Caller-owned Slab[T] borrowed per call. The
                        arbitrator does NOT retain a reference past
                        return.
            slab_len:   Number of live slots to consider (caller-owned
                        active-slot count).
            grow_bytes: Requested additional allocation, in bytes.
                        Strict-GT pressure check matches
                        `SpillArbitrator.pressure_check_and_arbitrate`.

        Returns:
            Bytes freed by the spill (0 if no pressure OR no spillable
            candidate found OR a non-OLDEST_FIRST policy raised).

        Raises:
            * From the victim's `spill_to_storage` (e.g. storage EIO).
            * From the arbitrator's policy arm when an unimplemented
              policy (LARGEST_FIRST / PROPORTIONAL_RESERVATION) is
              selected.
        """
        # Happy path: under budget. ZERO scan cost if the empty-slab
        # case is also covered (`current` collapses to 0 trivially).
        var current = self._total_resident_bytes(slab, slab_len)
        if current + grow_bytes <= self._budget_bytes:
            return 0

        # Pressure fired. Policy dispatch.
        if self._policy.is_oldest_first():
            return self._spill_oldest_first(slab, slab_len)
        elif self._policy.is_largest_first():
            raise Error(
                "IntraOpSlabArbitrator: LARGEST_FIRST policy not yet"
                " implemented"
            )
        elif self._policy.is_proportional_reservation():
            raise Error(
                "IntraOpSlabArbitrator: PROPORTIONAL_RESERVATION policy"
                " not yet implemented"
            )
        else:
            raise Error(
                "IntraOpSlabArbitrator: unknown ArbitratorPolicy tag="
                + String(Int(self._policy.tag()))
            )

    def _spill_oldest_first[
        o_slab: Origin[mut=True]
    ](
        mut self,
        ref [o_slab] slab: Slab[Self.T],
        slab_len: Int,
    ) raises -> Int64:
        """OLDEST_FIRST policy: scan can_spill() == True slots, pick the
        smallest `age_ticks`, spill that slot. Returns bytes freed.

        Internal helper called from `pressure_check_and_arbitrate` after
        pressure is established.

        Implementation: TWO-PASS — first to find `(victim_idx,
        victim_age)`; second to invoke `spill_to_storage` on the chosen
        index. The two-pass shape mirrors `SpillArbitrator
        ._spill_oldest_first` and avoids holding a `mut`-ref to a slab
        slot across the can_spill / age_ticks reads on subsequent
        slots.
        """
        # Pass 1: find the oldest can_spill victim.
        var victim_idx: Int = _NO_VICTIM_INDEX
        var victim_age: UInt64 = 0  # gated by victim_idx == _NO_VICTIM_INDEX

        for i in range(slab_len):
            # b2 trait-resolution: re-bind to Self.T so SpillableOp methods resolve.
            ref e: Self.T = slab[i]
            if e.can_spill():
                var age = e.age_ticks()
                if (victim_idx == _NO_VICTIM_INDEX) or (age < victim_age):
                    victim_idx = i
                    victim_age = age

        # No spillable slot — best-effort: return 0 (matches docstring).
        if victim_idx == _NO_VICTIM_INDEX:
            self._no_victim_count += Int64(1)
            return Int64(0)

        # Pass 2: invoke spill_to_storage on the chosen index.
        # b2 trait-resolution: re-bind to Self.T so SpillableOp methods resolve.
        ref victim: Self.T = slab[victim_idx]
        var bytes_freed = victim.spill_to_storage[Self.S](
            self._storage
        )
        if bytes_freed > Int64(0):
            self._spill_event_count += Int64(1)
        return bytes_freed

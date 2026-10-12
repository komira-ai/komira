# =============================================================================
# op_coordinator.mojo — SpillableOpCoordinator[T, S]
# =============================================================================
#
# # Role
#
# One-operator wrapper that CONFORMS `SpillableOp` so a per-operator pack
# can be packed into `SpillArbitrator[S, *Coords]` for inter-operator
# arbitration. Each coordinator owns the per-operator `IntraOpSlabArbitrator[T,
# S]` + consolidated `Slab[T]` BY VALUE (the consolidated state is drained
# from the operator's per-Local arbitrators + slabs at combine — see RFC
# §10.11.4 option (a)).
#
# # Why a new conformer
#
# `SpillableOpCoordinator[T, S]` is NOT an additive-parallel-API replacement
# of `IntraOpSlabArbitrator[T, S]`. They encode DIFFERENT scopes:
#
#   * `IntraOpSlabArbitrator[T, S]` — intra-operator homogeneous-slab
#     arbitration. Owned by the operator's per-Local state (e.g.
#     `FlatHashAggLocal._arbitrator`). Per-Local lifetime.
#   * `SpillableOpCoordinator[T, S]` — inter-operator integration: ONE
#     coordinator per operator wraps the consolidated intra-op arbitrator
#     + slab and feeds into the `SpillArbitrator[S, *Coords]` pack.
#
# The coordinator USES the intra-op arbitrator as substrate; it does NOT
# replicate its surface (one trait, multiple conformers; not
# parallel APIs over the same scope).
#
# # Why ownership is BY VALUE
#
# The coordinator owns its `_arbitrator: IntraOpSlabArbitrator[T, S]` +
# `_slab: Slab[T]` BY VALUE. No borrowed `Pointer[..., o_global]` field.
#
# Rationale (consolidation):
# the operator's Global state is KeepAlive non-Movable — taking a borrowed
# pointer INTO Global to hold the arbitrator / slab would re-introduce the
# borrowed-nulled-between-uses pattern banned by design review.
# Consolidating at combine gives the coordinator owned-by-value state that
# the type system tracks correctly.
#
# # Lifetime
#
# Per-segment. The coordinator is constructed by the operator's
# `register_for_inter_op_arbitration` method AFTER combine has produced
# the consolidated state. The coordinator then lives inside the per-segment
# `SpillArbitrator[S, *Coords]` (built by `build_segment_arbitrator` in
# `komira_engine_dispatch.segment_arbitrator`) until segment teardown.
#
# # Storage clone-sharing convention
#
# The coordinator's `_arbitrator._storage` is a CLONE of the EngineContext-
# owned `LocalDiskSpillStorage`. The inter-op `SpillArbitrator`'s `_storage`
# is ALSO a clone. Both clones reference the SAME root dir + chunk-ID
# namespace per the P-1.A `LocalDiskSpillStorage.with_unlimited(root_dir)`
# contract — chunks written via either clone are readable by either clone.
#
# # Encapsulation rule
#
# - Public method surface uses `Int64`, `UInt64`, `Bool`, parametric
#   `S2: SpillStorage`, and `ref [self._slab] Slab[Self.T]` / `ref
#   [self._arbitrator] IntraOpSlabArbitrator[Self.T, Self.S]`. NO
#   `UnsafePointer` at the boundary. NO wildcard origins on any field.
# =============================================================================

from komira_collections.slab import Slab

from .intra_op_slab_arbitrator import IntraOpSlabArbitrator
from .spill_storage import SpillStorage
from .spillable_op import SpillableOp


# =============================================================================
# SpillableOpCoordinator[T, S]
# =============================================================================


struct SpillableOpCoordinator[T: SpillableOp, S: SpillStorage](
    SpillableOp, Movable, Deinitable
):
    """One-operator wrapper conforming `SpillableOp` for inclusion in
    `SpillArbitrator[S, *Coords].Ops`.

    # Ownership

    Owns the per-operator `IntraOpSlabArbitrator[T, S]` BY VALUE and the
    per-operator consolidated `Slab[T]` BY VALUE. After combine (Q4=(a)
    consolidation), each operator's per-Local
    arbitrators + slabs merge into ONE coordinator. The coordinator
    then lives inside the per-segment SpillArbitrator until segment
    teardown.

    # No borrowed-pointer fields

    The coordinator does NOT hold a borrowed `Pointer` to any external
    Slab or Global. Storage + slab are owned-by-value (Movable +
    Deinitable). The
    `T: SpillableOp` parametric binding is comptime-monomorphized; no
    fn-ptr / data-ptr vtable.

    # Why not borrow Global?

    A `Pointer[Global, o_seg]` field would re-introduce the
    "borrowed-non-owning-pointer-field on a destroy-recreate struct"
    pattern banned by design review. Globals are KeepAlive
    non-Movable and DO have stable heap addresses, but the coordinator's
    lifetime must outlive any single Global's slot in the dispatch
    pipeline — consolidating at combine gives the coordinator owned-by-
    value state that the type system tracks correctly.

    # Fields

        _arbitrator: per-operator intra-op arbitrator (consolidates each
                     per-Local arbitrator into one at combine). Owned by-
                     value. Carries the SpillStorage clone backing the
                     operator's spill chunks.
        _slab:       per-operator consolidated `Slab[T]`. Owned by-value
                     (drained from each per-Local slab at combine).
        _slab_len:   active-slot count. Sum of per-Local active counts
                     observed at combine.
        _op_age_base: monotonic UInt64 baseline used by the inter-op
                     arbitrator's OLDEST_FIRST scan. Set at construction time to
                     `_unix_micros_now() // 1000`. Earlier-constructed
                     coordinator = oldest = preferred victim.
        _can_spill_gate: True when this coordinator is in a spillable
                     state (always True post-combine pre-finalize; can
                     be flipped via `set_can_spill(False)` at finalize
                     boundaries by the operator's sink).
    """

    var _arbitrator: IntraOpSlabArbitrator[Self.T, Self.S]
    var _slab: Slab[Self.T]
    var _slab_len: Int
    var _op_age_base: UInt64
    var _can_spill_gate: Bool

    def __init__(
        out self,
        var arbitrator: IntraOpSlabArbitrator[Self.T, Self.S],
        var slab: Slab[Self.T],
        slab_len: Int,
        op_age_base: UInt64,
    ):
        """Construct a coordinator from the operator's consolidated
        intra-op arbitrator + consolidated slab.

        Args:
            arbitrator:    The per-operator IntraOpSlabArbitrator[T, S]
                           consolidated at combine. Consumed.
            slab:          The per-operator consolidated Slab[T]
                           consolidated at combine. Consumed.
            slab_len:      Number of active slots in the consolidated
                           slab (the sum of per-Local active counts).
            op_age_base:   Monotonic UInt64 baseline for the inter-op
                           OLDEST_FIRST scan. Typical value:
                           `_unix_micros_now() // 1000` at register-for-
                           inter-op-arbitration time. Smaller value =
                           older = preferred victim.
        """
        self._arbitrator = arbitrator^
        self._slab = slab^
        self._slab_len = slab_len
        self._op_age_base = op_age_base
        self._can_spill_gate = True

    # =========================================================================
    # SpillableOp trait conformance (delegates to intra-op arbitrator)
    # =========================================================================

    @always_inline
    def memory_usage_bytes(self) -> Int64:
        """Sum of `memory_usage_bytes()` across the coordinator's
        consolidated slab live range. Delegates to the intra-op
        arbitrator's `total_resident_bytes` scan.

        Cost: O(slab_len) — one method call per active slot. For
        FlatHashAgg this is 256 (num_partitions); for Sort/JoinBuild
        bounded by per-operator slab capacity.
        """
        return self._arbitrator.total_resident_bytes(
            self._slab, self._slab_len
        )

    @always_inline
    def age_ticks(self) -> UInt64:
        """Inter-op OLDEST_FIRST scans coordinator-level age. Returns
        `_op_age_base` (set at construction time). Per-partition age
        within the operator is irrelevant for the inter-op scope —
        the inter-op policy picks WHICH OPERATOR to spill; the operator's
        own intra-op arbitrator picks WHICH PARTITION within it.

        Inter-op + intra-op OLDEST_FIRST compose
        to "oldest partition of oldest operator" — minimum surprise,
        least thrash, most predictable.
        """
        return self._op_age_base

    @always_inline
    def can_spill(self) -> Bool:
        """True while the coordinator's operator is in a spillable
        phase. Defaults True at construction. The operator's sink
        toggles via `set_can_spill(False)` at finalize-mid-restore
        boundaries (mirrors `FlatHashPartitionFlush._finalize_in_progress`
        semantics but at coordinator (operator) grain).
        """
        return self._can_spill_gate

    def spill_to_storage[
        S2: SpillStorage
    ](mut self, mut storage: S2) raises -> Int64:
        """Inter-op-arbitrator-driven spill. Delegates to the intra-op
        arbitrator's `pressure_check_and_arbitrate` with a synthetic
        large `grow_bytes` value that forces a victim pick.

        # Why force-pick rather than honor `storage`

        The trait surface's `spill_to_storage[S2]` is parametric over
        `S2: SpillStorage` to permit future heterogeneous storage
        policies. v0.7 RESOLVES the runtime semantic by enforcing
        `S2 == Self.S` at the call site (the segment-arbitrator builder
        clones the SESSION storage into the inter-op arbitrator AND
        each coordinator clones it into its intra-op arbitrator at
        register-time; both clones reference the SAME backing disk via
        the storage backend's chunk-naming). Concretely:
        `LocalDiskSpillStorage` clones share a chunk-namespace; chunks
        written by the coordinator's INNER intra-op arbitrator are
        readable by the OUTER storage (and by ANY clone the inter-op
        arbitrator might also write to).

        The `storage: S2` argument is intentionally ignored — the
        intra-op arbitrator's own owned storage is the canonical write
        destination. This preserves the storage clone-sharing contract
        end-to-end without coupling the coordinator's surface to a
        heterogeneous-storage runtime decision.

        # Spill semantic

        Forces ONE victim per call via the intra-op arbitrator's
        OLDEST_FIRST scan over the consolidated slab. The caller (the
        inter-op SpillArbitrator) may re-invoke if more bytes are
        needed; each re-invocation spills the next-oldest partition.

        Returns: bytes freed by the spill (0 if no spillable candidate
        found or pressure relief impossible).

        Raises:
            From the victim's `spill_to_storage` (e.g. storage EIO).
        """
        # Force-spill: pass grow_bytes = budget + 1 so the intra-op
        # arbitrator's strict-GT pressure check fires unconditionally.
        # The intra-op arbitrator picks ONE victim under OLDEST_FIRST
        # and spills it via the inner storage.
        var freed = self._arbitrator.pressure_check_and_arbitrate(
            self._slab,
            self._slab_len,
            self._arbitrator.budget_bytes() + Int64(1),
        )
        # Suppress unused-parameter warning while documenting the
        # storage-clone-sharing convention (the inter-op storage handle
        # IS a clone of the operator's intra-op storage; chunks land
        # on the same disk under the same namespace).
        _ = storage
        return freed

    def restore_from_storage[
        S2: SpillStorage
    ](mut self, mut storage: S2) raises:
        """Finalize-time restore — the inter-op arbitrator's optional
        `restore_all` would invoke this on every coordinator. Per-
        operator restore logic lives in the operator's sink finalize
        path (e.g. `_rehydrate_spilled_partitions` for FlatHashAgg).
        The coordinator should NOT be called for restore directly
        because the operator's finalize path already drives restore
        at the right point in the merge sequence — and the per-
        partition full-fp override cross-check (P-1.D.1.b) is operator-
        grain, not coordinator-grain.

        v0.7: this method raises a not-implemented error.
        `SpillArbitrator.restore_all` is RESERVED for future single-
        restore-pass policies; P-1.E does NOT invoke it.

        Suppresses the unused `storage` argument by `_ = storage`
        (matches the trait signature without engaging the storage
        side-effect).
        """
        _ = storage
        raise Error(
            "SpillableOpCoordinator.restore_from_storage: inter-op restore"
            " is not invoked directly. Operator's sink finalize drives"
            " restore via its own per-partition path."
        )

    # =========================================================================
    # Public accessors for the operator's sink finalize + tests
    # =========================================================================

    @always_inline
    def set_can_spill(mut self, b: Bool):
        """Operator sink toggles the can_spill gate at finalize-boundary.
        Mirrors `FlatHashPartitionFlush._finalize_in_progress` semantics
        but at coordinator (operator) grain.
        """
        self._can_spill_gate = b

    @always_inline
    def slab_len(self) -> Int:
        """Active-slot count in the coordinator's consolidated slab."""
        return self._slab_len

    @always_inline
    def op_age_base(self) -> UInt64:
        """The monotonic baseline used by the inter-op OLDEST_FIRST
        scan. Set at construction time and never mutated.
        """
        return self._op_age_base

    @always_inline
    def spill_event_count(self) -> Int64:
        """Telemetry passthrough: the inner intra-op arbitrator's
        cumulative spill_event_count. Used by tests + production
        observability to confirm inter-op spills are firing.
        """
        return self._arbitrator.spill_event_count()

    @always_inline
    def no_victim_count(self) -> Int64:
        """Telemetry passthrough: the inner intra-op arbitrator's
        cumulative no_victim_count.
        """
        return self._arbitrator.no_victim_count()

    @always_inline
    def arbitrator_ref(ref self) -> ref [self._arbitrator] IntraOpSlabArbitrator[
        Self.T, Self.S
    ]:
        """Borrow the inner intra-op arbitrator. Used by the operator's
        sink finalize to drive per-partition restore via the intra-op
        substrate (the sink keeps the same restore semantics as P-1.D.1
        without going through the coordinator's restore_from_storage).
        """
        return self._arbitrator

    @always_inline
    def arbitrator_mut(mut self) -> ref [self._arbitrator] IntraOpSlabArbitrator[
        Self.T, Self.S
    ]:
        """Mutable borrow of the inner intra-op arbitrator. Used by
        the operator's sink finalize when it needs `storage_mut()`
        (e.g. to drive a per-partition restore call that bypasses the
        coordinator's restore_from_storage gate).
        """
        return self._arbitrator

    @always_inline
    def slab_ref(ref self) -> ref [self._slab] Slab[Self.T]:
        """Borrow the consolidated slab. Used by tests to inspect
        post-spill state of individual partitions.
        """
        return self._slab

    @always_inline
    def slab_mut(mut self) -> ref [self._slab] Slab[Self.T]:
        """Mutable borrow of the consolidated slab. Used by the
        operator's sink finalize to drain into output and to perform
        restore via per-partition `restore_from_storage_with_expected_fingerprint`.
        """
        return self._slab

# =============================================================================
# spillable_op.mojo — `SpillableOp` trait: the arbitrator-visible surface.
# =============================================================================
#
# Implemented by every breaker that participates in spill arbitration:
#
#   * HashAggUntyped (lands in P-1.D)        — spills hash table partition.
#   * SortExternal   (lands in P-1.E)        — spills sort buffer.
#   * JoinBuildUntyped (lands in P-1.E)      — spills build-side table.
#
# v0.4 P-1.C ships the trait surface only; production conformers land in
# the P-1.D / P-1.E sub-slots. Mock conformers under
# `tests/engine/test_spill_arbitrator.mojo` exercise the trait + the
# arbitrator's victim-pick policy end-to-end.
#
# # Method-vs-property choice
#
# All four query methods (`memory_usage_bytes`, `age_ticks`, `can_spill`,
# soon-to-add fingerprint) are O(1) functions, not stored fields. The
# arbitrator's hot path (per `pressure_check_and_arbitrate` invocation)
# fans across every registered op via `@parameter for` and reads these
# methods on each — function-shape lets the conformer choose between a
# cached `self._cached_bytes` accessor (HashAggUntyped) and a derived
# `len(self._batches) * self._row_stride` formula (JoinBuildUntyped)
# without churning the trait surface.
#
# # Why parametric over S (NOT `dyn`)
#
# Mojo's `dyn` existential support is limited, with no
# verified `dyn Trait` composition for storage-handle plumbing. Parametric
# `[S: SpillStorage]` monomorphizes at the call site — each operator
# picks the storage at construction (today: LocalDiskSpillStorage).
#
# # Encapsulation rule
#
# - Public trait surface uses `Int64`, `UInt64`, `Bool`, `ChunkId` and
#   parametric `S: SpillStorage`. NO `UnsafePointer` at the trait
#   boundary. NO wildcard origins.
# - Conformers (HashAggUntyped, etc.) are free to use internal
#   `UnsafePointer` arithmetic inside `spill_to_storage` /
#   `restore_from_storage` — bounded to one method body each, guarded by
#   `# SAFETY:` comments.
# =============================================================================

from .spill_storage import ChunkId, SpillStorage


# =============================================================================
# SpillableOp trait
# =============================================================================


trait SpillableOp(Movable, Deinitable):
    """Arbitrator-visible surface every breaker exposes for spill.

    # Hot-path discipline

    `pressure_check_and_arbitrate` is called by `MemoryReservation.try_grow`
    (P-1.D wiring) BEFORE allocating new bytes. The arbitrator iterates
    every registered op via `@parameter for`, reads
    `memory_usage_bytes()` + `age_ticks()` + `can_spill()`, picks a
    victim per policy, and calls `spill_to_storage` on the victim.

    Per-row hot-path code MUST NOT call any SpillableOp method directly.
    Only the arbitrator does.

    # Method contracts

    * `memory_usage_bytes()` — resident bytes attributable to this op,
      counted in a O(1)-cheap shape (cached field accessor or simple
      `len * stride` arithmetic). Returned as `Int64` (matches
      `SpillStorage.nbytes_in_use` shape).

    * `age_ticks()` — monotonic UInt64 counter. The arbitrator's
      OLDEST_FIRST policy picks the spillable op with the SMALLEST
      `age_ticks`. Conformers MUST bump this counter on every state-
      mutating operation (insert, merge, batch ingest) so a long-idle op
      is preferred for spill over a freshly-active one. Tick frequency
      is up to the conformer (one-per-batch is the typical shape).

    * `can_spill()` — guard predicate. False during finalize / drain /
      restore (any phase where partial spill would corrupt the in-flight
      operation). The arbitrator SKIPS ops returning False and moves on
      to the next candidate; if NO op can spill, the arbitrate pass
      returns 0 bytes-freed (best-effort; no error).

    * `spill_to_storage[S: SpillStorage]` — serialize state to `storage`
      via THSPILL2. Returns BYTES FREED (a non-negative Int64). After
      return, `memory_usage_bytes()` MUST be near zero (only the
      chunk_id + restore metadata remains). The conformer is responsible
      for stashing the `ChunkId` (typically as a `List[ChunkId]` field)
      so `restore_from_storage` can find the spilled bytes.

    * `restore_from_storage[S: SpillStorage]` — inverse, called when the
      op needs the spilled state back (typically at finalize). Reads
      every stashed ChunkId, decodes via THSPILL2, rebuilds the in-memory
      state. Raises if the storage backend raises (EIO, etc.) or if the
      chunk's schema_fingerprint mismatches the conformer's expected
      schema.

    # Lifetime contract (P-1.D handoff)

    The arbitrator holds ops via the variadic-pack pattern (single
    pack block). v0.4 P-1.C's
    skeleton owns the ops by value (`Tuple[*Self.Ops]`). P-1.D will
    re-evaluate whether ops register as borrowed refs (per-op
    `Pointer[OpType, origin]`) once the production reservation wiring
    forces the choice.
    """

    def memory_usage_bytes(self) -> Int64:
        """Currently-resident bytes attributable to this op. O(1)."""
        ...

    def age_ticks(self) -> UInt64:
        """Monotonic counter bumped on state mutation. OLDEST_FIRST picks
        the smallest value."""
        ...

    def can_spill(self) -> Bool:
        """True if this op is in a spillable state (NOT mid-finalize /
        mid-restore). False makes the arbitrator skip this op."""
        ...

    def spill_to_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises -> Int64:
        """Spill the op's resident state to `storage`. Return bytes
        freed (non-negative). After return, `memory_usage_bytes()` is
        near zero."""
        ...

    def restore_from_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises:
        """Restore previously-spilled state (called at finalize). The
        op consults its own stashed ChunkIds; `storage` is the source.
        """
        ...

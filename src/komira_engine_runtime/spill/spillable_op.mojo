# =============================================================================
# spillable_op.mojo: the `SpillableOp` trait, the surface a spill arbitrator
# sees of a breaker or of one of its partitions.
# =============================================================================
#
# The query methods (`memory_usage_bytes`, `age_ticks`, `can_spill`) are
# methods rather than fields so a conformer can answer from a cached field or
# compute the answer; the arbitrators call them on every registered op in each
# pressure check, so each should be cheap. Nothing else calls them per row.
#
# `spill_to_storage` and `restore_from_storage` are generic over the storage
# type, so no storage handle is type-erased. No pointer appears in the trait.
# =============================================================================

from .spill_storage import SpillStorage


trait SpillableOp(Movable, Deinitable):
    """What a spill arbitrator needs of a spillable breaker or partition.

    * `memory_usage_bytes()`: the resident bytes attributable to this op.
    * `age_ticks()`: a counter the conformer advances on every state
      mutation. The oldest-first policy picks the smallest value, so an idle
      op is spilled before a recently active one.
    * `can_spill()`: False while spilling would corrupt work in flight (for
      example during finalize or restore, or once already spilled). The
      arbitrator skips such an op; when no op can spill, an arbitration pass
      frees 0 bytes and does not raise.
    * `spill_to_storage(storage)`: write the resident state to `storage` and
      return the bytes freed, which is not negative. The conformer keeps the
      `ChunkId`s it needs to restore.
    * `restore_from_storage(storage)`: read the conformer's own chunks back.
      It raises when the storage raises or a chunk does not match the
      conformer's schema.
    """

    def memory_usage_bytes(self) -> Int64:
        """The resident bytes attributable to this op."""
        ...

    def age_ticks(self) -> UInt64:
        """A counter advanced on each state mutation; oldest-first picks the
        smallest."""
        ...

    def can_spill(self) -> Bool:
        """True when this op may be spilled now."""
        ...

    def spill_to_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises -> Int64:
        """Spill the resident state to `storage`; return the bytes freed."""
        ...

    def restore_from_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises:
        """Read the previously spilled state back from `storage`."""
        ...

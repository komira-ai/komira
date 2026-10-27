# =============================================================================
# op_coordinator.mojo: `SpillableOpCoordinator[T, S]`, one operator seen as a
# single `SpillableOp`.
# =============================================================================
#
# The coordinator owns an operator's `IntraOpSlabArbitrator[T, S]` and its
# `Slab[T]` of partitions, both by value, and conforms to `SpillableOp` so
# several operators can be packed into one `SpillArbitrator[S, *Coordinators]`.
# The two levels compose: the outer arbitrator picks which operator spills (the
# one with the smallest `op_age_base`), the coordinator then spills that
# operator's oldest partition. The result is the oldest partition of the oldest
# operator.
#
# `spill_to_storage` spills exactly one partition per call, whether or not the
# operator is over its own budget, and writes it through the inner
# arbitrator's storage. The `storage` argument is not used: the inner and
# outer storages are expected to be clones that share one chunk namespace.
# `restore_from_storage` raises: restoring is the operator's own job, one
# partition at a time.
#
# One thread at a time; no pointer appears in the public surface.
# =============================================================================

from komira_collections.slab import Slab

from .intra_op_slab_arbitrator import IntraOpSlabArbitrator
from .spill_storage import SpillStorage
from .spillable_op import SpillableOp


struct SpillableOpCoordinator[T: SpillableOp, S: SpillStorage](
    SpillableOp, Movable, Deinitable
):
    """One operator as a `SpillableOp`: it owns the operator's partitions and
    their intra-operator arbitrator by value.

    Fields:
        _arbitrator:     The operator's intra-operator arbitrator; its
                         storage receives the spilled chunks.
        _slab:           The operator's partitions.
        _slab_len:       How many slots of `_slab` are live.
        _op_age_base:    The age this operator reports to the outer
                         arbitrator; the smallest is spilled first.
        _can_spill_gate: False while the operator must not be spilled.
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
        """A coordinator that starts spillable.

        Args:
            arbitrator:  The operator's intra-operator arbitrator. Consumed.
            slab:        The operator's partitions. Consumed.
            slab_len:    How many slots of `slab` are live.
            op_age_base: The age the outer arbitrator sees; an earlier
                         (smaller) value is spilled first.
        """
        self._arbitrator = arbitrator^
        self._slab = slab^
        self._slab_len = slab_len
        self._op_age_base = op_age_base
        self._can_spill_gate = True

    @always_inline
    def memory_usage_bytes(self) -> Int64:
        """The resident bytes of the live partitions (a scan of `slab_len`
        slots)."""
        return self._arbitrator.total_resident_bytes(
            self._slab, self._slab_len
        )

    @always_inline
    def age_ticks(self) -> UInt64:
        """The operator's age for the outer arbitrator: `op_age_base`, fixed
        at construction. Ages of the partitions inside are only used by the
        inner arbitrator."""
        return self._op_age_base

    @always_inline
    def can_spill(self) -> Bool:
        """True when the gate (`set_can_spill`, open at construction) is open
        and some live partition can still spill. An operator with nothing
        left to spill is skipped by the outer arbitrator rather than picked
        again."""
        return self._can_spill_gate and self._arbitrator.has_spillable(
            self._slab, self._slab_len
        )

    def spill_to_storage[
        S2: SpillStorage
    ](mut self, mut storage: S2) raises -> Int64:
        """Spill this operator's oldest spillable partition, whether or not
        the operator is over its own budget.

        The partition is written through the inner arbitrator's storage;
        `storage` is not used. Call again to spill the next partition.

        Returns:
            The bytes freed; 0 when no partition can spill.

        Raises:
            What the partition's `spill_to_storage` raises.
        """
        _ = storage
        return self._arbitrator.spill_oldest(self._slab, self._slab_len)

    def restore_from_storage[
        S2: SpillStorage
    ](mut self, mut storage: S2) raises:
        """Always raises: restoring is done by the operator itself, partition
        by partition, through `arbitrator_mut()` and `slab_mut()`."""
        _ = storage
        raise Error(
            "SpillableOpCoordinator.restore_from_storage: inter-op restore"
            " is not invoked directly. The operator restores its own"
            " partitions."
        )

    @always_inline
    def set_can_spill(mut self, b: Bool):
        """Open or close the spill gate, for example around a finalize."""
        self._can_spill_gate = b

    @always_inline
    def slab_len(self) -> Int:
        """How many slots of the slab are live."""
        return self._slab_len

    @always_inline
    def op_age_base(self) -> UInt64:
        """The age this operator reports to the outer arbitrator."""
        return self._op_age_base

    @always_inline
    def spill_event_count(self) -> Int64:
        """The inner arbitrator's spill event count."""
        return self._arbitrator.spill_event_count()

    @always_inline
    def no_victim_count(self) -> Int64:
        """The inner arbitrator's no-victim count."""
        return self._arbitrator.no_victim_count()

    @always_inline
    def arbitrator_ref(
        ref self,
    ) -> ref [self._arbitrator] IntraOpSlabArbitrator[Self.T, Self.S]:
        """Borrow the inner arbitrator."""
        return self._arbitrator

    @always_inline
    def arbitrator_mut(
        mut self,
    ) -> ref [self._arbitrator] IntraOpSlabArbitrator[Self.T, Self.S]:
        """Borrow the inner arbitrator mutably."""
        return self._arbitrator

    @always_inline
    def slab_ref(ref self) -> ref [self._slab] Slab[Self.T]:
        """Borrow the partitions."""
        return self._slab

    @always_inline
    def slab_mut(mut self) -> ref [self._slab] Slab[Self.T]:
        """Borrow the partitions mutably."""
        return self._slab

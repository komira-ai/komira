# =============================================================================
# intra_op_slab_arbitrator.mojo: `IntraOpSlabArbitrator[T, S]`, spill
# arbitration over the partitions of one operator, held in a `Slab[T]`.
# =============================================================================
#
# The operator owns the slab; the arbitrator never does. The slab is passed in
# on each call as a borrowed `ref`, so the arbitrator holds nothing that
# outlives a call and cannot dangle. The arbitrator owns only its storage and
# two counters.
#
# This is the arbitrator for partitions of one type whose count is known at run
# time. `SpillArbitrator[S, *Ops]` is the one for a fixed pack of ops of
# different types.
#
# `pressure_check_and_arbitrate(slab, slab_len, grow_bytes)` sums the resident
# bytes of `slab[0..slab_len)`. If `grow_bytes` more would pass the budget
# (strictly: an exact fit is not pressure), the oldest-first policy spills the
# one partition with the smallest `age_ticks` among those whose `can_spill()`
# is True, and returns the bytes it freed. Without pressure, or when no
# partition can spill, it returns 0. The other two policies raise.
# `spill_oldest` does the victim pick and the spill without the pressure test.
#
# One thread at a time: the arbitrator takes no lock and the caller serializes
# calls. No pointer appears in the public surface.
# =============================================================================

from komira_collections.slab import Slab

from .policies import ArbitratorPolicy, exceeds_budget
from .spill_storage import SpillStorage
from .spillable_op import SpillableOp


# The victim index when no partition can spill.
comptime _NO_VICTIM_INDEX: Int = -1


struct IntraOpSlabArbitrator[T: SpillableOp, S: SpillStorage](
    Movable, Deinitable
):
    """Spill arbitration over a caller-owned `Slab[T]` of one operator's
    partitions.

    Fields:
        _storage:           The spill storage, owned; the victim's
                            `spill_to_storage` receives it.
        _budget_bytes:      The byte budget over `slab[0..slab_len)`.
        _policy:            The victim policy.
        _spill_event_count: How many spills freed more than 0 bytes.
        _no_victim_count:   How many passes under pressure found no
                            partition that can spill.
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
        """An arbitrator over the caller's partitions.

        Args:
            storage:      The spill storage. Consumed.
            budget_bytes: The byte budget over the whole slab, not negative.
                          A request that exactly fills it is not pressure.
            policy:       The victim policy; only oldest-first runs.
        """
        self._storage = storage^
        self._budget_bytes = budget_bytes
        self._policy = policy
        self._spill_event_count = Int64(0)
        self._no_victim_count = Int64(0)

    @always_inline
    def budget_bytes(self) -> Int64:
        """The byte budget."""
        return self._budget_bytes

    @always_inline
    def policy(self) -> ArbitratorPolicy:
        """The victim policy."""
        return self._policy

    @always_inline
    def spill_event_count(self) -> Int64:
        """How many spills freed more than 0 bytes."""
        return self._spill_event_count

    @always_inline
    def no_victim_count(self) -> Int64:
        """How many passes found no partition that can spill."""
        return self._no_victim_count

    @always_inline
    def storage_ref(ref self) -> ref [self._storage] Self.S:
        """Borrow the spill storage, for example to read
        `num_live_chunks()`."""
        return self._storage

    @always_inline
    def storage_mut(mut self) -> ref [self._storage] Self.S:
        """Borrow the spill storage mutably, to read or write chunks
        directly or to clean it up."""
        return self._storage

    def total_resident_bytes[
        o_slab: Origin
    ](self, ref [o_slab] slab: Slab[Self.T], slab_len: Int) -> Int64:
        """The sum of `memory_usage_bytes()` over `slab[0..slab_len)`.

        `slab_len` is explicit because the live slot count belongs to the
        caller and may be less than the slab's capacity.
        """
        var total: Int64 = 0
        for i in range(slab_len):
            # `slab[i]` is typed by the slab's own bound; re-bind to `Self.T`
            # to see the `SpillableOp` methods.
            ref e: Self.T = slab[i]
            total += e.memory_usage_bytes()
        return total

    def has_spillable[
        o_slab: Origin
    ](self, ref [o_slab] slab: Slab[Self.T], slab_len: Int) -> Bool:
        """True when some partition in `slab[0..slab_len)` can spill."""
        for i in range(slab_len):
            ref e: Self.T = slab[i]
            if e.can_spill():
                return True
        return False

    def pressure_check_and_arbitrate[
        o_slab: Origin[mut=True]
    ](
        mut self,
        ref [o_slab] slab: Slab[Self.T],
        slab_len: Int,
        grow_bytes: Int64,
    ) raises -> Int64:
        """Spill one partition if `grow_bytes` more would pass the budget.

        Args:
            slab:       The caller's partitions, borrowed for this call.
            slab_len:   How many slots of `slab` are live.
            grow_bytes: The additional bytes about to be allocated.

        Returns:
            The bytes the victim freed; 0 without pressure or when no
            partition can spill.

        Raises:
            What the victim's `spill_to_storage` raises, or an error naming
            the policy when it is not implemented.
        """
        var current = self.total_resident_bytes(slab, slab_len)
        if not exceeds_budget(current, grow_bytes, self._budget_bytes):
            return 0
        return self.spill_oldest(slab, slab_len)

    def spill_oldest[
        o_slab: Origin[mut=True]
    ](
        mut self, ref [o_slab] slab: Slab[Self.T], slab_len: Int
    ) raises -> Int64:
        """Spill the victim the policy picks, with no pressure test.

        Oldest-first scans `slab[0..slab_len)` for the spillable partition
        with the smallest `age_ticks` (the lowest index wins a tie), spills
        it, and counts a spill event when it freed more than 0 bytes. With no
        spillable partition it counts a no-victim pass and returns 0.

        Returns:
            The bytes the victim freed.

        Raises:
            What the victim's `spill_to_storage` raises, or an error naming
            the policy when it is not implemented.
        """
        if self._policy.is_largest_first():
            raise Error(
                "IntraOpSlabArbitrator: LARGEST_FIRST policy not yet"
                " implemented"
            )
        elif self._policy.is_proportional_reservation():
            raise Error(
                "IntraOpSlabArbitrator: PROPORTIONAL_RESERVATION policy"
                " not yet implemented"
            )
        elif not self._policy.is_oldest_first():
            raise Error(
                "IntraOpSlabArbitrator: unknown ArbitratorPolicy tag="
                + String(Int(self._policy.tag()))
            )

        var victim_idx: Int = _NO_VICTIM_INDEX
        var victim_age: UInt64 = 0

        for i in range(slab_len):
            ref e: Self.T = slab[i]
            if e.can_spill():
                var age = e.age_ticks()
                if (victim_idx == _NO_VICTIM_INDEX) or (age < victim_age):
                    victim_idx = i
                    victim_age = age

        if victim_idx == _NO_VICTIM_INDEX:
            self._no_victim_count += Int64(1)
            return Int64(0)

        ref victim: Self.T = slab[victim_idx]
        var bytes_freed = victim.spill_to_storage[Self.S](self._storage)
        if bytes_freed > Int64(0):
            self._spill_event_count += Int64(1)
        return bytes_freed

# =============================================================================
# spill_arbitrator.mojo: `SpillArbitrator[S, *Ops]`, one arbitrator over a
# fixed pack of `SpillableOp`s (possibly of different types) sharing a budget.
# =============================================================================
#
# `pressure_check_and_arbitrate(grow_bytes)` sums the ops' resident bytes. If
# `grow_bytes` more would pass the budget (strictly: an exact fit is not
# pressure), the oldest-first policy picks the op with the smallest
# `age_ticks` among those whose `can_spill()` is True, calls its
# `spill_to_storage` with the arbitrator's storage, and returns the bytes
# freed. Without pressure, or when no op can spill, it returns 0. The other
# two policies raise.
#
# The arbitrator owns its ops by value, as `Tuple[*Ops]`. A `*Ops` pack is the
# only variadic parameter a struct constructor may take, so the pack arrives
# wrapped in `SpillableOpBlock` and is lifted out with `Optional.take()`. The
# pack is walked with `comptime for`, so each element is called as its own
# concrete type.
#
# One thread at a time: the arbitrator takes no lock and the caller serializes
# calls. No pointer appears in the public surface.
# =============================================================================

from .policies import ArbitratorPolicy, exceeds_budget
from .spill_storage import SpillStorage
from .spillable_op import SpillableOp


struct SpillableOpBlock[*Ops: SpillableOp](Movable):
    """The `SpillableOp` pack, wrapped so a `SpillArbitrator` constructor can
    take it next to its other arguments. The pack lifts out once, by
    `take()`."""

    var _ops: Optional[Tuple[*Self.Ops]]

    def __init__(out self, var *ops: *Self.Ops):
        self._ops = Tuple(*ops^)

    @always_inline
    def take(mut self) -> Tuple[*Self.Ops]:
        """Lift the ops out of the block (`Optional.take`); a second call is
        a precondition violation."""
        return self._ops.take()


# The victim index when no op can spill.
comptime _NO_VICTIM_INDEX: Int = -1


struct SpillArbitrator[S: SpillStorage, *Ops: SpillableOp](
    Movable, Deinitable
):
    """Coordinates spill across a fixed pack of `SpillableOp`s under one
    byte budget.

    Parameters:
        S:   The spill storage; the arbitrator owns it and hands it to the
             victim's `spill_to_storage`.
        Ops: The registered ops, one entry per breaker.
    """

    var _storage: Self.S
    var _budget_bytes: Int64
    var _ops: Tuple[*Self.Ops]
    var _policy: ArbitratorPolicy

    def __init__(
        out self,
        var storage: Self.S,
        budget_bytes: Int64,
        var ops_block: SpillableOpBlock[*Self.Ops],
        policy: ArbitratorPolicy = ArbitratorPolicy.oldest_first(),
    ):
        """An arbitrator for the ops in `ops_block`, sharing `budget_bytes`.

        Args:
            storage:      The spill storage. Consumed.
            budget_bytes: The shared byte budget, not negative. A request
                          that exactly fills it is not pressure.
            ops_block:    The ops, in `SpillableOpBlock[*Ops](op0, op1, ...)`.
                          Consumed.
            policy:       The victim policy; only oldest-first runs.
        """
        self._storage = storage^
        self._budget_bytes = budget_bytes
        self._ops = ops_block.take()
        self._policy = policy

    @staticmethod
    @always_inline
    def op_arity() -> Int:
        """How many ops are registered."""
        return Self.Ops.__len__()

    @always_inline
    def budget_bytes(self) -> Int64:
        """The shared byte budget."""
        return self._budget_bytes

    @always_inline
    def policy(self) -> ArbitratorPolicy:
        """The victim policy."""
        return self._policy

    def total_resident_bytes(self) -> Int64:
        """The sum of `memory_usage_bytes()` over every registered op."""
        var total: Int64 = 0

        comptime for i in range(Self.Ops.__len__()):
            total += self._ops[i].memory_usage_bytes()
        return total

    def pressure_check_and_arbitrate(
        mut self, grow_bytes: Int64
    ) raises -> Int64:
        """Spill one victim if `grow_bytes` more would pass the budget.

        Args:
            grow_bytes: The additional bytes about to be allocated.

        Returns:
            The bytes the victim freed; 0 without pressure or when no op can
            spill.

        Raises:
            What the victim's `spill_to_storage` raises, or an error naming
            the policy when it is not implemented.
        """
        var current = self.total_resident_bytes()
        if not exceeds_budget(current, grow_bytes, self._budget_bytes):
            return 0

        if self._policy.is_oldest_first():
            return self._spill_oldest_first()
        elif self._policy.is_largest_first():
            raise Error(
                "SpillArbitrator: LARGEST_FIRST policy not yet implemented"
            )
        elif self._policy.is_proportional_reservation():
            raise Error(
                "SpillArbitrator: PROPORTIONAL_RESERVATION policy not yet"
                " implemented"
            )
        else:
            raise Error(
                "SpillArbitrator: unknown ArbitratorPolicy tag="
                + String(Int(self._policy.tag()))
            )

    def _spill_oldest_first(mut self) raises -> Int64:
        """Spill the spillable op with the smallest `age_ticks`; 0 when none
        can spill.

        Each pack element is its own type inside `comptime for`, so the
        victim is found in one pass (by index) and spilled in a second pass
        that runs only the chosen index.
        """
        var victim_idx: Int = _NO_VICTIM_INDEX
        var victim_age: UInt64 = 0

        comptime for i in range(Self.Ops.__len__()):
            if self._ops[i].can_spill():
                var age = self._ops[i].age_ticks()
                if (victim_idx == _NO_VICTIM_INDEX) or (age < victim_age):
                    victim_idx = i
                    victim_age = age

        if victim_idx == _NO_VICTIM_INDEX:
            return 0

        var bytes_freed: Int64 = 0

        comptime for i in range(Self.Ops.__len__()):
            if i == victim_idx:
                bytes_freed = self._ops[i].spill_to_storage(self._storage)

        return bytes_freed

    def restore_all(mut self) raises:
        """Call `restore_from_storage` on every op, in pack order.

        Raises:
            What an op's `restore_from_storage` raises; the ops after it are
            not restored.
        """

        comptime for i in range(Self.Ops.__len__()):
            self._ops[i].restore_from_storage(self._storage)

    @always_inline
    def storage_ref(ref self) -> ref [self._storage] Self.S:
        """Borrow the spill storage, for example to read
        `num_live_chunks()`."""
        return self._storage

    @always_inline
    def storage_mut(mut self) -> ref [self._storage] Self.S:
        """Borrow the spill storage mutably, for example to clean it up."""
        return self._storage

    @always_inline
    def op_memory_usage_bytes[i: Int](self) -> Int64:
        """The `memory_usage_bytes()` of op `i` (a comptime index)."""
        return self._ops[i].memory_usage_bytes()

    @always_inline
    def op_age_ticks[i: Int](self) -> UInt64:
        """The `age_ticks()` of op `i` (a comptime index)."""
        return self._ops[i].age_ticks()

    @always_inline
    def op_can_spill[i: Int](self) -> Bool:
        """The `can_spill()` of op `i` (a comptime index)."""
        return self._ops[i].can_spill()

# =============================================================================
# MemoryReservation: a per-segment memory accountant
# =============================================================================
#
# `MorselSink.combine` takes `ref [o_mem] reservation: MemoryReservation`, and
# a sink may also keep one per worker for its consume path. The reservation is
# a byte tally against an optional budget:
#
#   * `MemoryReservation()` has no budget: `try_grow` always succeeds and the
#     tally is kept for inspection only.
#   * `MemoryReservation.with_budget(b)` refuses a grow that would take the
#     tally past `b` bytes; each refusal is counted, and the caller decides
#     what to do (spill, for a sink that can).
#
# The budget is a value the caller passes. Nothing here reads the environment
# or the host: a sink that wants a budget receives it as an argument from the
# plan or its caller.
#
# `Movable` and not `KeepAlive`: the trait passes the reservation by reference,
# and it holds no atomic field, so it needs no stable address.
#
# Threading: one reservation belongs to one segment's combine, or to one
# worker's local state. Nothing here is shared between workers.
# =============================================================================


# The budget value meaning "no budget". Negative, so it can never be a byte
# count.
comptime BUDGET_UNSET: Int = -1


struct MemoryReservation(Movable):
    """A byte tally against an optional budget.

    `try_grow(n)` adds `n` to the tally and returns True when the tally stays
    within the budget (always, when there is none). Otherwise it leaves the
    tally unchanged, counts the refusal and returns False. `release(n)` takes
    `n` back off the tally.
    """

    var _held_bytes: Int
    """The bytes grown and not yet released."""

    var _budget_bytes: Int
    """The budget, or `BUDGET_UNSET`. Fixed at construction."""

    var _try_grow_denied_count: Int
    """How many `try_grow` calls returned False."""

    def __init__(out self):
        """A reservation with no budget."""
        self._held_bytes = 0
        self._budget_bytes = BUDGET_UNSET
        self._try_grow_denied_count = 0

    @staticmethod
    def with_budget(budget_bytes: Int) -> Self:
        """A reservation that refuses to hold more than `budget_bytes`.

        A negative `budget_bytes` gives a reservation with no budget; it does
        not raise, because sinks construct one per worker per dispatch.

        Args:
            budget_bytes: The most bytes the tally may reach.
        """
        var r = Self()
        if budget_bytes >= 0:
            r._budget_bytes = budget_bytes
        return r^

    def try_grow(mut self, n_bytes: Int) -> Bool:
        """Grows the tally by `n_bytes` if it fits in the budget.

        Call it per batch, not per row.

        Args:
            n_bytes: The bytes to add.

        Returns:
            True when the tally grew; False (tally unchanged, refusal counted)
            when it would pass the budget.
        """
        if self._budget_bytes == BUDGET_UNSET:
            self._held_bytes += n_bytes
            return True
        if self._held_bytes + n_bytes > self._budget_bytes:
            self._try_grow_denied_count += 1
            return False
        self._held_bytes += n_bytes
        return True

    def release(mut self, n_bytes: Int):
        """Takes `n_bytes` off the tally.

        The caller releases no more than it grew; the tally is not clamped, so
        an over-release shows up as a negative `held_bytes()`.

        Args:
            n_bytes: The bytes to release.
        """
        self._held_bytes -= n_bytes

    def held_bytes(self) -> Int:
        """The bytes grown and not yet released."""
        return self._held_bytes

    def budget_bytes(self) -> Int:
        """The budget, or `BUDGET_UNSET` when there is none."""
        return self._budget_bytes

    def try_grow_denied_count(self) -> Int:
        """How many `try_grow` calls returned False."""
        return self._try_grow_denied_count

    def has_budget(self) -> Bool:
        """True when the reservation has a budget."""
        return self._budget_bytes != BUDGET_UNSET

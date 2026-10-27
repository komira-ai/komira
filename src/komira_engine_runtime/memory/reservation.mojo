# =============================================================================
# MemoryReservation: a breaker's memory accountant
# =============================================================================
#
# A breaker grows its reservation before it buffers more input and releases it
# when it frees memory. `try_grow` returns False when the grow would pass the
# budget; a spill-capable breaker answers by spilling (spill arbitration lives
# in `komira_engine_runtime.spill`), and the denial is counted
# (`try_grow_denied_count`).
#
# The budget is a value handed in at construction: `for_host` takes it from
# the host profile (`HostProfile.memory_budget_bytes`, which the host sets
# from its flags once per process), `with_budget` takes an explicit byte
# count, and the default constructor has no budget. Nothing here reads the
# environment or parses configuration.
#
# Threading: a reservation has one writer. Each worker of a breaker holds its
# own; nothing is shared across workers.
# =============================================================================

from komira_engine_runtime.host_profile import HostProfile


# Sentinel for "no budget" (infinite quota). Any negative value is out of band
# for a byte count.
comptime _BUDGET_UNSET: Int = -1


struct MemoryReservation(Movable):
    """A breaker's memory accountant.

    `try_grow(n)` adds `n` to the held tally and returns True when the tally
    stays within the budget; otherwise it changes nothing, counts the denial
    and returns False. `release(n)` takes `n` back off. With no budget
    (`MemoryReservation()`), every grow succeeds and the tally is kept for
    observation only.
    """

    var _held_bytes: Int
    """Bytes granted by `try_grow` and not yet released."""

    var _budget_bytes: Int
    """The budget in bytes, or `_BUDGET_UNSET` for none. Set at construction."""

    var _try_grow_denied_count: Int
    """How many `try_grow` calls returned False."""

    def __init__(out self):
        """A reservation with no budget: every grow succeeds."""
        self._held_bytes = 0
        self._budget_bytes = _BUDGET_UNSET
        self._try_grow_denied_count = 0

    @staticmethod
    def with_budget(budget_bytes: Int) -> Self:
        """A reservation with a budget of `budget_bytes`.

        A negative value means no budget (the same as `MemoryReservation()`);
        0 is a real budget that denies every positive grow.
        """
        var r = Self()
        if budget_bytes >= 0:
            r._budget_bytes = budget_bytes
        return r^

    @staticmethod
    def for_host(profile: HostProfile) -> Self:
        """A reservation whose budget is the host's memory budget
        (`HostProfile.memory_budget_bytes`, at least 1 by construction)."""
        return Self.with_budget(profile.memory_budget_bytes)

    def try_grow(mut self, n_bytes: Int) -> Bool:
        """Grow the held tally by `n_bytes` if it stays within the budget.

        Returns True and adds `n_bytes` when there is no budget or when
        `held_bytes() + n_bytes <= budget_bytes()`. Otherwise returns False,
        leaves the tally unchanged and counts the denial. A negative
        `n_bytes` is refused the same way (a grow cannot free memory; use
        `release`). The budget test is `n_bytes > budget - held`, which
        cannot wrap. Call per batch, not per row.
        """
        if n_bytes < 0:
            self._try_grow_denied_count += 1
            return False
        if self._budget_bytes == _BUDGET_UNSET:
            self._held_bytes += n_bytes
            return True
        if n_bytes > self._budget_bytes - self._held_bytes:
            self._try_grow_denied_count += 1
            return False
        self._held_bytes += n_bytes
        return True

    def release(mut self, n_bytes: Int):
        """Take `n_bytes` off the held tally. The caller releases only what it
        was granted; the tally is not clamped, so an over-release shows up as
        a negative `held_bytes()` rather than being hidden."""
        self._held_bytes -= n_bytes

    def held_bytes(self) -> Int:
        """Bytes granted and not yet released."""
        return self._held_bytes

    def budget_bytes(self) -> Int:
        """The budget in bytes, or a negative value when there is none."""
        return self._budget_bytes

    def try_grow_denied_count(self) -> Int:
        """How many `try_grow` calls returned False."""
        return self._try_grow_denied_count

    def has_budget(self) -> Bool:
        """True when a budget is set."""
        return self._budget_bytes != _BUDGET_UNSET

# =============================================================================
# policies.mojo: the victim-pick policy and the pressure predicate shared by
# the spill arbitrators.
# =============================================================================
#
# `ArbitratorPolicy` is a small value type wrapping one `UInt8` tag. Only
# `OLDEST_FIRST` is implemented: the arbitrators raise when asked to run
# `LARGEST_FIRST` or `PROPORTIONAL_RESERVATION`. The two are named so a caller
# can pass them through and the arbitrator is the one place that refuses them.
# The default-constructed policy is `OLDEST_FIRST` (tag 0).
#
# `exceeds_budget` is the pressure test both arbitrators apply. It is written
# as `grow > budget - current`, so a huge `grow_bytes` cannot wrap the way
# `current + grow` would.
# =============================================================================


def exceeds_budget(
    current_bytes: Int64, grow_bytes: Int64, budget_bytes: Int64
) -> Bool:
    """True when growing by `grow_bytes` on top of `current_bytes` resident
    bytes would pass `budget_bytes`.

    The test is strict: a request that exactly fills the budget is not over
    it. A negative `grow_bytes` counts as 0, so it signals pressure only when
    `current_bytes` is already over the budget. `current_bytes` and
    `budget_bytes` are non-negative byte counts, so `budget_bytes -
    current_bytes` cannot wrap.
    """
    var grow = grow_bytes
    if grow < 0:
        grow = 0
    return grow > budget_bytes - current_bytes


struct ArbitratorPolicy(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Victim-pick policy for the spill arbitrators.

      * `OLDEST_FIRST`: pick the spillable op with the smallest `age_ticks`.
        The only policy that runs.
      * `LARGEST_FIRST`: pick the spillable op with the largest
        `memory_usage_bytes`. Not implemented; the arbitrators raise.
      * `PROPORTIONAL_RESERVATION`: a fair share per op. Not implemented; the
        arbitrators raise.
    """

    comptime OLDEST_FIRST_TAG: UInt8 = 0
    comptime LARGEST_FIRST_TAG: UInt8 = 1
    comptime PROPORTIONAL_RESERVATION_TAG: UInt8 = 2

    var _value: UInt8

    def __init__(out self):
        """The default policy: `OLDEST_FIRST`."""
        self._value = Self.OLDEST_FIRST_TAG

    def __init__(out self, value: UInt8):
        """A policy from a raw tag; prefer the named constructors."""
        self._value = value

    @staticmethod
    @always_inline
    def oldest_first() -> Self:
        """The `OLDEST_FIRST` policy."""
        return Self(Self.OLDEST_FIRST_TAG)

    @staticmethod
    @always_inline
    def largest_first() -> Self:
        """The `LARGEST_FIRST` policy. It can be constructed, but an
        arbitrator that has to pick a victim with it raises."""
        return Self(Self.LARGEST_FIRST_TAG)

    @staticmethod
    @always_inline
    def proportional_reservation() -> Self:
        """The `PROPORTIONAL_RESERVATION` policy. It can be constructed, but
        an arbitrator that has to pick a victim with it raises."""
        return Self(Self.PROPORTIONAL_RESERVATION_TAG)

    @always_inline
    def tag(self) -> UInt8:
        """The raw tag."""
        return self._value

    @always_inline
    def is_oldest_first(self) -> Bool:
        return self._value == Self.OLDEST_FIRST_TAG

    @always_inline
    def is_largest_first(self) -> Bool:
        return self._value == Self.LARGEST_FIRST_TAG

    @always_inline
    def is_proportional_reservation(self) -> Bool:
        return self._value == Self.PROPORTIONAL_RESERVATION_TAG

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value

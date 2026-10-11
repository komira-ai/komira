# =============================================================================
# policies.mojo — ArbitratorPolicy enum for SpillArbitrator.
# =============================================================================
#
# The SpillArbitrator's victim-pick rule lives here as a small enum-shaped
# value type. v0.4 P-1.C ships the canonical default `OLDEST_FIRST`. Two
# additional values are reserved (`LARGEST_FIRST`, `PROPORTIONAL_RESERVATION`)
# but their dispatch arms in `SpillArbitrator.pressure_check_and_arbitrate`
# raise "policy not yet implemented" — they're declared here so future v0.5+
# work can flip them on without churning every callsite that names the policy.
#
# # Why not a Mojo trait
#
# A trait-shaped Policy (e.g. `trait SpillPolicyTrait` with a `pick_victim`
# method) would let third-party callers plug in custom policies. But:
#
#   1. v0.4's three reserved policies span the relevant design space
#      already (oldest-first, largest-first, fair-share).
#   2. Adding a trait introduces a `*Ops`-pack to `SpillPolicyTrait.pick_victim`
#      — heterogeneous-pack lifetimes leak into a new layer.
#   3. The arbitrator's hot path (per-arbitrate-pass) compares ALL ops; a
#      trait-method call per comparison would obscure the simple value-typed
#      enum dispatch.
#
# Keeping `ArbitratorPolicy` as a flat-int newtype lets the arbitrator
# `if self._policy == ArbitratorPolicy.OLDEST_FIRST: ...` branch comptime-
# fold under inlining and gives future v0.5+ work a single grep point.
#
# # Encapsulation rule
#
# - Pure value type; NO `UnsafePointer`; NO wildcard origins; no fields
#   that own heap.
# =============================================================================


# =============================================================================
# ArbitratorPolicy newtype
# =============================================================================
#
# Implemented as a struct wrapping a single `UInt8` discriminator (vs a Mojo
# `@value`-decorated enum) for two reasons:
#   1. Stable wire-shape: future versions of this enum will land additional
#      cases without breaking the layout (the `_value` field is the source of
#      truth; all comparators dispatch through it).
#   2. Explicit factory constructors (`.oldest_first()`, etc.) document
#      intent at call sites better than a bare enum-member token.


struct ArbitratorPolicy(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Victim-pick policy for `SpillArbitrator.pressure_check_and_arbitrate`.

    v0.4 P-1.C ships ONE active arm:

      * `OLDEST_FIRST` — pick the spillable op with the smallest age_ticks.

    Two arms reserved for v0.5+:

      * `LARGEST_FIRST` — pick the spillable op with the largest
        memory_usage_bytes. the design case behind future
        telemetry; its arm in the arbitrator raises today.
      * `PROPORTIONAL_RESERVATION` — DuckDB TemporaryMemoryManager-style
        fair-share. Requires breakers to expose `set_reservation(bytes)`
        (not part of v0.4 SpillableOp trait). the design reserved.

    Fields:
        _value: UInt8 discriminator. PRIVATE — accessed via the `tag()`
                method and the policy-named accessor helpers.

    The default arm OLDEST_FIRST is enum tag 0 so the EngineContext-level
    default-construction `ArbitratorPolicy()` lands on the correct value
    without any explicit init step.
    """

    comptime OLDEST_FIRST_TAG: UInt8 = 0
    comptime LARGEST_FIRST_TAG: UInt8 = 1
    comptime PROPORTIONAL_RESERVATION_TAG: UInt8 = 2

    var _value: UInt8

    def __init__(out self):
        """Default-construct: OLDEST_FIRST (the v0.4 ship default)."""
        self._value = Self.OLDEST_FIRST_TAG

    def __init__(out self, value: UInt8):
        """Construct from raw tag value. Used by the factory helpers below;
        external callers should prefer `oldest_first()` / `largest_first()` /
        `proportional_reservation()` for self-documenting call sites.
        """
        self._value = value

    @staticmethod
    @always_inline
    def oldest_first() -> Self:
        """Construct the OLDEST_FIRST policy (v0.4 default)."""
        return Self(Self.OLDEST_FIRST_TAG)

    @staticmethod
    @always_inline
    def largest_first() -> Self:
        """Construct the LARGEST_FIRST policy (reserved, v0.5+).

        Construction is allowed but `SpillArbitrator
        .pressure_check_and_arbitrate` will raise when this policy is
        selected. The constructor is provided so callers can pass the value
        through; the arbitrator is the single enforcement point.
        """
        return Self(Self.LARGEST_FIRST_TAG)

    @staticmethod
    @always_inline
    def proportional_reservation() -> Self:
        """Construct the PROPORTIONAL_RESERVATION policy (reserved, v0.5+).

        Construction is allowed but `SpillArbitrator
        .pressure_check_and_arbitrate` will raise when this policy is
        selected — the cooperative-reservation flow requires per-op
        `set_reservation(bytes)`, not part of v0.4 `SpillableOp`.
        """
        return Self(Self.PROPORTIONAL_RESERVATION_TAG)

    @always_inline
    def tag(self) -> UInt8:
        """Raw discriminator value. The arbitrator's
        `pressure_check_and_arbitrate` dispatches on `tag()`.
        """
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

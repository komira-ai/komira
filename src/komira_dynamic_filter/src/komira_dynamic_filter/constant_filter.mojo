# =============================================================================
# ConstantFilter -- single-distinct-value filter (tier 0 dynamic-filter)
# =============================================================================
#
# DuckDB precedent:
#   * `src/include/duckdb/planner/filter/constant_filter.hpp`
#     (ConstantFilter -- TableFilter variant for predicates of the form
#     `column = constant`).
#   * `src/execution/operator/join/physical_hash_join.cpp`
#     (when a build side reduces to a single distinct value, DuckDB emits
#     a ConstantFilter via `LegacyConstantFilter` / its dynamic-filter
#     pushdown -- the in-list machinery skips because a 1-element in-list
#     is strictly more expensive than scalar equality).
#
# When the build side of a hash join has exactly ONE distinct key, the
# correct probe-side test is `probe_key == constant`. This is strictly
# cheaper than every other tier:
#   * vs InListFilter (Dict lookup):  1 compare beats 1 hash + 1 probe.
#   * vs RangeFilter  (>= && <=):     1 compare beats 2 compares.
#   * vs BloomFilter  (hash + bit):   1 compare beats hash + bit-test.
#
# It slots in BEFORE the other three tiers in the DynamicJoinFilter
# cascade ordering, and when it fires the other tiers are skipped entirely.
#
# Build-side activation: detect distinct count == 1 at construction
# time (inside `DynamicJoinFilter.build_int64_from_list`). When active,
# the in_list / range / bloom tiers are skipped (redundant — a 1-element
# in-list is strictly more expensive than this scalar compare).
#
# Pointer rules:
#   - Pure POD struct (Movable + Copyable + Deinitable).
#   - No UnsafePointer in public API; no heap allocations.
#   - Suitable for storage in Optional inside the (Movable-only)
#     DynamicJoinFilter aggregate.
# =============================================================================


# =============================================================================
# ConstantFilter (Int64 specialization)
# =============================================================================


struct ConstantFilter(Copyable, Movable, Deinitable):
    """Single-distinct-value filter -- the cheapest dynamic-filter tier.

    Holds one INT64 constant + a build-side null sentinel. Per-row check
    is one scalar equality compare.

    Fields:
        _value: the single distinct build-side key.
        _has_null: True if the build side was all-NULL. SQL semantics:
            NULL never equi-joins anything (NULL != anything), so when
            `has_null` is True, every probe row is rejected. The typed
            builder does not currently surface NULL build keys
            (`DynamicJoinFilter.build_int64_from_list` takes
            `List[Int64]`), but the field is preserved for forward
            compatibility with a nullable typed builder.
    """

    var _value: Int64
    var _has_null: Bool

    def __init__(out self, value: Int64):
        """Build a ConstantFilter from a single non-null distinct value.

        The common case: build side has exactly one distinct, non-null
        key.
        """
        self._value = value
        self._has_null = False

    def __init__(out self, value: Int64, has_null: Bool):
        """Build a ConstantFilter with an explicit null sentinel.

        When `has_null` is True, no probe row matches (build side was
        all-NULL, NULL != anything in equi-join semantics). The `value`
        is ignored in that case.
        """
        self._value = value
        self._has_null = has_null

    @always_inline
    def matches_int64(self, value: Int64) -> Bool:
        """Per-row test: returns True iff `value == self._value` AND the
        build side was not all-NULL.

        Args:
            value: The probe-side key.

        Returns:
            True if the probe value equals the build's single distinct
            constant. False on mismatch, or if the build was all-NULL.
        """
        if self._has_null:
            return False
        return value == self._value

    @always_inline
    def value_int64(self) -> Int64:
        """Accessor for the constant (for testing / introspection)."""
        return self._value

    @always_inline
    def has_null(self) -> Bool:
        """Accessor for the null sentinel."""
        return self._has_null

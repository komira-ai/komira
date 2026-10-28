# =============================================================================
# RangeFilter -- min/max range filter (tier 2 dynamic-filter)
# =============================================================================
#
# Tier 2 of the three-tier dynamic-filter hierarchy:
#   - InListFilter  (tier 1) -- explicit set, zero false positives
#   - RangeFilter   (tier 2) -- min/max range, single comparison
#   - BloomFilter   (tier 3) -- probabilistic, ~1% FPR
#
# Always generated for single-key joins. Already used for row-group
# pruning by Parquet stats; this primitive extends it to per-batch
# probe-side filtering.
#
# Only the Int64 path exists; other dtypes follow when columnar
# dispatch needs them.
# =============================================================================


# =============================================================================
# RangeFilter (Int64 specialization)
# =============================================================================


struct RangeFilter(Copyable, Movable):
    """Min/max range filter over INT64 keys.

    Holds a single `[_min, _max]` inclusive range. Per-row check is one
    `>=` plus one `<=` — single comparison cost when SIMD-vectorized.

    Fields:
        _min, _max: inclusive bounds. min == max is allowed (degenerate
            single-element range).
    """

    var _min: Int64
    var _max: Int64

    def __init__(out self, min: Int64, max: Int64):
        """Private; public callers use `new_int64` / `try_from_int64`."""
        self._min = min
        self._max = max

    @staticmethod
    def new_int64(min: Int64, max: Int64) -> RangeFilter:
        """Construct the range filter.

        Construct a range filter with explicit (min, max). Caller has
        already computed the build-side bounds.
        """
        return RangeFilter(min, max)

    @staticmethod
    def try_from_int64(values: List[Int64]) -> Optional[RangeFilter]:
        """Build a range filter from a build-side INT64 key list.

        Computes min/max in one pass.

        Returns:
            Some(RangeFilter) if the list is non-empty, None otherwise.
        """
        if len(values) == 0:
            return None
        var lo = values[0]
        var hi = values[0]
        for i in range(1, len(values)):
            var v = values[i]
            if v < lo:
                lo = v
            if v > hi:
                hi = v
        return RangeFilter(lo, hi)

    @always_inline
    def contains_int64(self, value: Int64) -> Bool:
        """Evaluate the filter (Int64).

        Inclusive `_min <= value <= _max` test.
        """
        return value >= self._min and value <= self._max

    @always_inline
    def min_int64(self) -> Int64:
        """Build-side min."""
        return self._min

    @always_inline
    def max_int64(self) -> Int64:
        """Build-side max."""
        return self._max

    @always_inline
    def is_degenerate(self) -> Bool:
        """True when min == max — the columnar path skips
        the range stage in this case because it's redundant against the
        in-list (size-1) filter.
        """
        return self._min == self._max

# =============================================================================
# InListFilter -- explicit set membership filter (tier 1 dynamic-filter)
# =============================================================================
#
# For tiny build sides (<= IN_LIST_THRESHOLD distinct keys), an explicit
# hash set check provides:
#   - Zero false positives.
#   - Cheaper per-row cost than the bloom filter for small sets.
#
# Only the Int64 path exists; Int32 and Utf8 follow when columnar
# dynamic-filter dispatch needs them.
#
# Pointer rules:
#   - No UnsafePointer in public API; uses stdlib `Dict[Int64, Bool]`.
#   - Public API exposes typed values only.
#   - Movable + Copyable so the filter can flow through Optional /
#     ArcPointer for ownership transfer to probe-side scan.
# =============================================================================


# Maximum distinct keys for in-list activation. 128 covers typical
# HAVING / aggregate output sizes.
comptime IN_LIST_THRESHOLD: Int = 128


# =============================================================================
# InListFilter (Int64 specialization)
# =============================================================================


struct InListFilter(Copyable, Movable):
    """Explicit set-membership filter for tiny build sides.

    Holds up to IN_LIST_THRESHOLD distinct INT64 keys for O(1) lookup
    with zero false positives. Used as Tier 1 of the three-tier
    dynamic-filter hierarchy (in-list -> range -> bloom).

    Fields:
        _keys: stdlib Dict used as a hash set (value = True sentinel).

    Construction goes through `try_from_int64(values)` which returns
    `None` if the input has more than IN_LIST_THRESHOLD distinct keys
    OR is empty (an empty in-list is meaningless
    because every probe row would fail).
    """

    var _keys: Dict[Int64, Bool]

    def __init__(out self):
        """Empty (private) ctor. Public callers go through `try_from_int64`."""
        self._keys = Dict[Int64, Bool]()

    @staticmethod
    def try_from_int64(values: List[Int64]) -> Optional[InListFilter]:
        """Build an in-list filter from an INT64 key list.

        Returns:
            Some(InListFilter) if 1 <= distinct(values) <= IN_LIST_THRESHOLD,
            None otherwise.
        """
        var f = InListFilter()
        for i in range(len(values)):
            f._keys[values[i]] = True
            if len(f._keys) > IN_LIST_THRESHOLD:
                return None
        if len(f._keys) == 0:
            return None
        return f^

    @always_inline
    def contains_int64(self, value: Int64) -> Bool:
        """Test membership.

        Args:
            value: The probe-side key to test.

        Returns:
            True if `value` is in the build-side key set, False otherwise.
        """
        return value in self._keys

    @always_inline
    def size(self) -> Int:
        """Number of distinct values in the set.
        """
        return len(self._keys)

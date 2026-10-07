# =============================================================================
# int_stats_sum — the IntegerStatistics.sum accumulator with overflow.
# =============================================================================
#
# Apache ORC's Java writer (IntegerStatisticsImpl) adds each value to `sum`
# with Math.addExact. The first overflow sets a flag and summing stops; a
# merge ORs the two flags, then (if still clear) adds the other sum with
# addExact, which can set the flag too. The serialized IntegerStatistics
# carries field 3 (sum) only while the flag is clear. These helpers do the
# same: the sum is an `Optional[Int64]`, `None` once any step overflowed.
# Overflow is decided before the add, so no addition ever wraps.


@always_inline
def checked_add_i64(a: Int64, b: Int64) -> Optional[Int64]:
    """`a + b`, or `None` when the exact sum is outside the Int64 range."""
    if b > 0 and a > Int64.MAX - b:
        return None
    if b < 0 and a < Int64.MIN - b:
        return None
    return a + b


@always_inline
def add_to_int_sum(mut sum: Optional[Int64], v: Int64):
    """Add `v` to a running sum; an overflowed (`None`) sum stays `None`."""
    if sum:
        sum = checked_add_i64(sum.value(), v)


@always_inline
def merge_int_sum(mut acc: Optional[Int64], other: Optional[Int64]):
    """Merge `other` into `acc`: `None` if either side overflowed or the
    merged sum does."""
    if not other:
        acc = None
    elif acc:
        acc = checked_add_i64(acc.value(), other.value())

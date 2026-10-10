# =============================================================================
# temporal_range — Int64 range checks shared by the temporal cell parsers.
# =============================================================================
#
# A timestamp or duration whose value does not fit in Int64 nanoseconds is
# refused (the parser returns None and the cell becomes null); it is never
# wrapped. The scalar parsers (temporal_parsers.mojo) and the SIMD
# Timestamp[ns] fast path (cell_parsers_simd.mojo) both call
# `epoch_seconds_to_ns`, so the two accept exactly the same cells.
#
# Int64 nanoseconds span
#   Int64.MIN = -9223372036854775808 ns = 1677-09-21T00:12:43.145224192
#   Int64.MAX =  9223372036854775807 ns = 2262-04-11T23:47:16.854775807
# =============================================================================

comptime _NS_PER_S: Int = 1_000_000_000
comptime _INT64_MAX: Int64 = 9223372036854775807
# Int64.MAX ns = 9223372036 s + 854775807 ns.
comptime _MAX_EPOCH_S: Int = 9223372036
comptime _MAX_EPOCH_FRAC_NS: Int = 854775807
# Int64.MIN ns = -9223372037 s + 145224192 ns.
comptime _MIN_EPOCH_S: Int = -9223372037
comptime _MIN_EPOCH_FRAC_NS: Int = 145224192


def epoch_seconds_to_ns(secs: Int, frac_ns: Int) -> Optional[Int64]:
    """Return `secs * 1e9 + frac_ns` as Int64 nanoseconds-since-epoch.

    `frac_ns` is the sub-second part, in [0, 1e9). Returns None when the
    instant lies outside the Int64 nanosecond range (before
    1677-09-21T00:12:43.145224192 or after 2262-04-11T23:47:16.854775807).
    `secs` is any whole-second count a 'YYYY-MM-DD' date can produce, so
    the comparisons below cannot overflow.
    """
    if secs > _MAX_EPOCH_S or (
        secs == _MAX_EPOCH_S and frac_ns > _MAX_EPOCH_FRAC_NS
    ):
        return None
    if secs < _MIN_EPOCH_S or (
        secs == _MIN_EPOCH_S and frac_ns < _MIN_EPOCH_FRAC_NS
    ):
        return None
    if secs < 0:
        # (secs + 1) * 1e9 fits where secs * 1e9 would not at secs = -9223372037.
        return Optional[Int64](
            Int64((secs + 1) * _NS_PER_S + (frac_ns - _NS_PER_S))
        )
    return Optional[Int64](Int64(secs * _NS_PER_S + frac_ns))


def checked_mul_add(value: Int64, mul: Int64, add: Int64) -> Optional[Int64]:
    """Return `value * mul + add`, or None if it exceeds Int64.MAX.

    Every operand must be non-negative and `mul` positive (the ISO
    duration parser accumulates magnitudes and applies the sign last).
    """
    if value > (_INT64_MAX - add) // mul:
        return None
    return Optional[Int64](value * mul + add)


def div_toward_zero(value: Int64, divisor: Int64) -> Int64:
    """Divide, rounding toward zero (`-1500 / 1000 = -1`), for `divisor > 0`.

    Mojo's `//` rounds toward negative infinity; this corrects the quotient
    of a negative dividend that is not an exact multiple.
    """
    var q = value // divisor
    if value < 0 and q * divisor != value:
        q = q + 1
    return q

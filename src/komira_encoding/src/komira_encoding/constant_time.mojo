# =============================================================================
# komira_encoding/constant_time.mojo -- branch-free byte classification.
# =============================================================================
#
# Every helper here computes its answer with arithmetic and bit masks over
# UInt32: no comparison feeds a branch, and no value indexes memory. A "mask"
# is 0x00000000 (false) or 0xFFFFFFFF (true). The inputs are always below
# 2^31 (a byte, a symbol value, a small constant), which is what makes the
# borrow-bit comparison in `ct_lt` exact.
#
# This is the technique of BoringSSL's constant-time base64 decoder
# (`constant_time_lt_8`, `constant_time_in_range_8`, `constant_time_select_8`
# in crypto/internal.h), restated over UInt32.
# =============================================================================


@always_inline
def ct_lt(a: UInt32, b: UInt32) -> UInt32:
    """All-ones if `a < b`, else zero. Requires `a, b < 2^31`."""
    return UInt32(0) - ((a - b) >> 31)


@always_inline
def ct_ge(a: UInt32, b: UInt32) -> UInt32:
    """All-ones if `a >= b`, else zero. Requires `a, b < 2^31`."""
    return ~ct_lt(a, b)


@always_inline
def ct_in_range(c: UInt32, lo: UInt32, hi: UInt32) -> UInt32:
    """All-ones if `lo <= c <= hi`, else zero."""
    return ct_ge(c, lo) & ct_lt(c, hi + 1)


@always_inline
def ct_eq(a: UInt32, b: UInt32) -> UInt32:
    """All-ones if `a == b`, else zero."""
    var x = a ^ b
    # (x | -x) has its top bit set exactly when x != 0.
    return ((x | (UInt32(0) - x)) >> 31) - 1


@always_inline
def ct_select(mask: UInt32, a: UInt32, b: UInt32) -> UInt32:
    """`a` where `mask` is all-ones, `b` where it is zero."""
    return (mask & a) | (~mask & b)


@always_inline
def ct_select_u64(mask: UInt64, a: UInt64, b: UInt64) -> UInt64:
    """`ct_select` over UInt64 (used to record an input position)."""
    return (mask & a) | (~mask & b)

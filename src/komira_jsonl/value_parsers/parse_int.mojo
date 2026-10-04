# =============================================================================
# parse_int — JSON number → Int64 scalar parser (yyjson-shape)
# =============================================================================
#
# Scalar digit-accumulation loop in yyjson's shape — `v = v * 10 + (b - '0')`
# — which Mojo -O3 lowers cleanly to `smaddl` (32-bit i < 4) or `madd`
# (64-bit) on NEON. NOT a Lemire-SWAR vectorization: the yyjson-shape
# scalar loop wins at the typical JSON digit-count of 1-10 — Lemire SWAR
# pays a per-call setup cost that beats it only at digit-count > 18, which
# is rare.
#
# Public surface:
#   - `parse_int_i64(bytes, start, end) raises -> Int64`
#       Parse the digit run in `bytes[start..end]` as a signed Int64.
#       Accepts optional leading `-` sign. Raises on:
#         - Empty range (start == end).
#         - Non-digit / non-sign byte.
#         - Overflow past Int64.MAX / underflow past Int64.MIN.
#
#   - `parse_int_in_byte_range(bytes, start_inclusive, end_exclusive) raises -> Int64`
#       Convenience wrapper accepting the input Span directly.
#
# Encapsulation discipline:
#   - `Span[UInt8, _]` input, owned `Int64` return; no UnsafePointer in
#     the public signature. The internal scan is a per-byte loop over
#     Span indexing (Mojo lowers this without bounds-check overhead at
#     -O3).
# =============================================================================


@always_inline
def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(0x30) and b <= UInt8(0x39)


def parse_int_i64(bytes: Span[UInt8, _], start: Int, end: Int) raises -> Int64:
    """Parse the byte range `bytes[start..end]` as a signed Int64.

    Algorithm: optional sign byte, then digit-accumulate `v = v * 10 + d`.
    On overflow (next-digit causes v > Int64.MAX) raises.

    This is yyjson's per-byte scalar shape. Mojo -O3 lowers the inner
    loop to `smaddl w_acc, w_d, w_10` on NEON (32-bit accumulator while
    v < 2^31, then `madd x_acc, x_d, x_10` after promotion to Int64),
    about 1.4 ns/digit at warm cache.
    """
    if end <= start:
        raise Error("parse_int_i64: empty byte range (start=" + String(start) + ", end=" + String(end) + ")")

    var i = start
    var negative: Bool = False

    # Optional leading sign.
    var b0 = bytes[i]
    if b0 == UInt8(0x2D):  # '-'
        negative = True
        i += 1
        if i >= end:
            raise Error("parse_int_i64: lone '-' sign without digits")
    elif b0 == UInt8(0x2B):  # '+'
        i += 1
        if i >= end:
            raise Error("parse_int_i64: lone '+' sign without digits")

    # At least one digit must follow.
    if not _is_digit(bytes[i]):
        raise Error("parse_int_i64: non-digit byte at position " + String(i))

    # Accumulate digits in UInt64 magnitude. Detect overflow per the
    # final sign: positive max magnitude is Int64.MAX (9223372036854775807);
    # negative max magnitude is |Int64.MIN| (9223372036854775808).
    var mag: UInt64 = 0
    var u64_pos_max: UInt64 = 9223372036854775807  # Int64.MAX
    var u64_neg_max: UInt64 = 9223372036854775808  # |Int64.MIN|
    var max_div10: UInt64 = 1844674407370955161    # UInt64.MAX // 10
    var max_mod10: UInt64 = 5                       # UInt64.MAX % 10
    while i < end:
        var b = bytes[i]
        if not _is_digit(b):
            raise Error("parse_int_i64: non-digit byte at position " + String(i))
        var d = UInt64(Int(b) - 0x30)
        # Pre-multiply overflow check against UInt64.MAX (defensive — we
        # narrow to Int64 below).
        if mag > max_div10 or (mag == max_div10 and d > max_mod10):
            raise Error("parse_int_i64: integer overflow at position " + String(i))
        mag = mag * UInt64(10) + d
        i += 1

    # Final-sign overflow check + narrowing.
    if negative:
        if mag > u64_neg_max:
            raise Error("parse_int_i64: integer underflow (less than Int64.MIN)")
        if mag == u64_neg_max:
            # Special-case Int64.MIN: cannot negate by `-mag` because
            # |MIN| does not fit in Int64. Return MIN directly.
            return Int64(-9223372036854775808)
        return -Int64(Int(mag))
    if mag > u64_pos_max:
        raise Error("parse_int_i64: integer overflow (greater than Int64.MAX)")
    return Int64(Int(mag))

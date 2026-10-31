# =============================================================================
# decimal_to_double: a stored DECIMAL value as the DOUBLE a comparison with a
# DOUBLE literal sees
# =============================================================================
#
# DuckDB compares a DECIMAL column with a DOUBLE in DOUBLE, so each stored value
# c (an integer at scale s) goes through its cast, and so does a decimal literal
# of at most 38 digits that meets a DOUBLE operand. The cast is DuckDB's, not
# the correctly rounded one, and the pinned DuckDB's doubles are the test
# (komira_decimal_compare_conformance, double_sweep.tsv, 1000 values bit for
# bit):
#
#   * A 128-bit integer h is `double(low word) + double(high word) * 2^64`, two
#     roundings and a product; when the high word is -1 (a negative value
#     within 2^64 of zero) it is `-double(UINT64_MAX - low word) - 1`. It is
#     not the correctly rounded value: 2^117 + 2^64 + 1 reads as 2^117 + 2^65.
#   * A value within 2^53, or at scale 0, is that double over 10^s (a
#     correctly rounded division); a larger one is converted by parts, the
#     double of the integer part `c / 10^s` plus the double of the fraction part
#     `c % 10^s` over 10^s, both truncating toward zero.
#
# The tokenizer (komira_sql/sql_token.mojo, `_decimal_value`) holds the same
# conversion for the literal: komira_sql does not depend on this package, and
# the same sweep checks both.
# =============================================================================

from komira_scalar_arithmetic.decimal_arith import I128, pow10_i256


def hugeint_to_double(h: I128) -> Float64:
    """DuckDB's double of a 128-bit integer (see the header)."""
    var low = h.cast[DType.uint64]()
    var high = (h >> I128(64)).cast[DType.int64]()
    if high == Int64(-1):
        return -(UInt64.MAX - low).cast[DType.float64]() - 1.0
    return low.cast[DType.float64]() + high.cast[DType.float64]() * 18446744073709551616.0


def decimal_to_double(c: I128, scale: Int) raises -> Float64:
    """`c / 10^scale` as DuckDB's cast of a DECIMAL to DOUBLE gives it."""
    var scale_i128 = pow10_i256(scale).cast[DType.int128]()
    var divisor = scale_i128.cast[DType.float64]()
    var two53 = I128(9007199254740992)
    if scale == 0 or (c <= two53 and c >= -two53):
        return hugeint_to_double(c) / divisor
    var whole = c / scale_i128
    var fraction = c - whole * scale_i128
    return hugeint_to_double(whole) + hugeint_to_double(fraction) / divisor

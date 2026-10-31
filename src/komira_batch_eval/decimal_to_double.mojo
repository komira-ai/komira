# =============================================================================
# decimal_to_double: a stored DECIMAL value as the DOUBLE a comparison with a
# DOUBLE literal sees
# =============================================================================
#
# DuckDB compares a DECIMAL column with a DOUBLE in DOUBLE, so each stored value
# c (an integer at scale s) goes through its cast. A value within 2^53, or at
# scale 0, is one division by 10^s; a larger one is converted by parts, its
# integer part and its fraction part over 10^s, added.
# =============================================================================

from komira_scalar_arithmetic.decimal_arith import I128, pow10_i256


def decimal_to_double(c: I128, scale: Int) raises -> Float64:
    """`c / 10^scale` as DuckDB's cast of a DECIMAL to DOUBLE gives it."""
    var scale_i128 = pow10_i256(scale).cast[DType.int128]()
    var divisor = scale_i128.cast[DType.float64]()
    var two53 = I128(9007199254740992)
    if scale == 0 or (c <= two53 and c >= -two53):
        return c.cast[DType.float64]() / divisor
    var whole = c / scale_i128
    var fraction = c - whole * scale_i128
    return whole.cast[DType.float64]() + fraction.cast[DType.float64]() / divisor

# =============================================================================
# DECIMAL128 COMPARISON — scale-aligned, on the unscaled value, in i256
# =============================================================================
#
# To compare D(p1,s1) <op> D(p2,s2): rescale the lower-scale side to
# s = max(s1, s2) IN i256 (10^38 * 10^38 ~= 10^76 < 2^255 — fits with a
# hair to spare; this dodges the "rescale overflows i128" trap), then a
# signed int256 comparison.  The rescaled-but-scale-aligned value IS the
# number, so signed comparison is the correct answer.
# =============================================================================

from komira_scalar_arith.decimal_arith import I128, pow10_i256

comptime DEC_CMP_LT: UInt8 = 0
comptime DEC_CMP_LE: UInt8 = 1
comptime DEC_CMP_GT: UInt8 = 2
comptime DEC_CMP_GE: UInt8 = 3
comptime DEC_CMP_EQ: UInt8 = 4
comptime DEC_CMP_NE: UInt8 = 5


@always_inline
def decimal_cmp_i128(a: I128, s1: Int, b: I128, s2: Int, op: UInt8) raises -> Bool:
    """Compare a (scale s1) <op> b (scale s2).  `op` is one of DEC_CMP_*."""
    var s = max(s1, s2)
    var a256 = a.cast[DType.int256]() * pow10_i256(s - s1)
    var b256 = b.cast[DType.int256]() * pow10_i256(s - s2)
    if op == DEC_CMP_LT:
        return a256 < b256
    elif op == DEC_CMP_LE:
        return a256 <= b256
    elif op == DEC_CMP_GT:
        return a256 > b256
    elif op == DEC_CMP_GE:
        return a256 >= b256
    elif op == DEC_CMP_EQ:
        return a256 == b256
    elif op == DEC_CMP_NE:
        return a256 != b256
    else:
        raise Error("decimal_cmp_i128: unknown op " + String(Int(op)))

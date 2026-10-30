# =============================================================================
# decimal_literal -- DECIMAL literals the way DuckDB reads and folds them
# =============================================================================
#
# Two jobs, one set of rules:
#
#   * `decimal_from_literal_text`: the type and value of a literal's text.
#     DuckDB reads `0.06` as DECIMAL(3, 2): the precision is the number of
#     digits (the leading zero counts), the scale the digits after the point.
#     `0.060` is DECIMAL(4, 3) and `100.00` DECIMAL(5, 2). A literal of more
#     than 38 digits is not a DECIMAL there (a DOUBLE) and has no type here.
#
#   * `decimal_fold_binary` / `decimal_negate`: the type and value of `a + b`,
#     `a - b`, `a * b` and `-a` over such literals, and over a decimal and an
#     integer literal. An integer literal takes part as DECIMAL(10, 0) when it
#     fits INT32 and DECIMAL(19, 0) when it does not (DuckDB's INTEGER and
#     BIGINT). `+` and `-`: scale max(s1, s2), precision
#     max(p1 - s1, p2 - s2) + max(s1, s2) + 1. `*`: scale s1 + s2, precision
#     p1 + p2. A result of more than 38 digits is not folded.
#
# The expected types below are DuckDB's, from `typeof(<expr>)`:
#   0.06 - 0.01 -> DECIMAL(4, 2)   0.06 * 0.01 -> DECIMAL(6, 4)
#   1 - 0.94    -> DECIMAL(13, 2)  2 * 0.025   -> DECIMAL(14, 3)
#   24 + 0.5    -> DECIMAL(12, 1)  3000000000 * 0.5 -> DECIMAL(21, 1)
# (`komira_decimal_compare_conformance` runs DuckDB to write them.)
#
# Every function is total: an input it does not type gives `None`, and the
# caller keeps the expression (or the float literal) it had.
# =============================================================================

from komira_plan_expr.expr import BIN_ADD, BIN_SUB, BIN_MUL
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128, I256


# The most digits a DECIMAL literal or a folded constant holds.
comptime DECIMAL_LITERAL_MAX_PRECISION = 38

comptime _INT32_MIN = -2147483648
comptime _INT32_MAX = 2147483647


def _pow10(n: Int) -> I256:
    """10^n for 0 <= n <= 76, as a 256-bit integer."""
    var r = I256(1)
    var ten = I256(10)
    for _ in range(n):
        r = r * ten
    return r


def decimal_from_literal_text(text: String) -> Optional[ScalarValue]:
    """The DECIMAL a literal's text denotes: `['-'] digits '.' digits`.

    The precision is the number of digits, the scale the digits after the
    point. `None` for text of another shape, with no digit after the point, or
    with more than 38 digits.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    var i = 0
    var negative = False
    if i < n and Int(bytes[i]) == ord("-"):
        negative = True
        i += 1
    var digits = 0
    var scale = 0
    var seen_point = False
    var value = I256(0)
    var ten = I256(10)
    while i < n:
        var c = Int(bytes[i])
        if c == ord("."):
            if seen_point:
                return None
            seen_point = True
        elif c >= ord("0") and c <= ord("9"):
            digits += 1
            if digits > DECIMAL_LITERAL_MAX_PRECISION:
                return None
            if seen_point:
                scale += 1
            value = value * ten + I256(c - ord("0"))
        else:
            return None
        i += 1
    if not seen_point or scale == 0:
        return None
    if negative:
        value = -value
    return Optional[ScalarValue](
        ScalarValue.decimal128_i128(
            value.cast[DType.int128](), digits, scale
        )
    )


struct _Operand(Copyable, Movable):
    """A literal as DuckDB types it for arithmetic: its unscaled value, precision
    and scale."""

    var value: I128
    var precision: Int
    var scale: Int

    def __init__(out self, value: I128, precision: Int, scale: Int):
        self.value = value
        self.precision = precision
        self.scale = scale


def _operand(v: ScalarValue) -> Optional[_Operand]:
    if v.is_decimal128():
        var p = v.dec128_precision
        var s = v.dec128_scale
        if p < 1 or p > DECIMAL_LITERAL_MAX_PRECISION or s < 0 or s > p:
            return None
        return Optional[_Operand](_Operand(v.decimal_value_i128(), p, s))
    if v.is_int():
        var x = Int(v.int_val)
        var p = 10
        if x < _INT32_MIN or x > _INT32_MAX:
            p = 19
        return Optional[_Operand](_Operand(I128(x), p, 0))
    return None


def decimal_fold_binary(
    op: UInt8, a: ScalarValue, b: ScalarValue
) -> Optional[ScalarValue]:
    """`a <op> b` for `+`, `-` and `*` where at least one of `a`, `b` is a
    DECIMAL literal and the other a DECIMAL or an integer literal.

    `None` when the pair is not that (two integers, a float, a typeless
    decimal), when `op` is another operator, or when the result needs more than
    38 digits or does not fit the precision it would be given.
    """
    if not (a.is_decimal128() or b.is_decimal128()):
        return None
    if op != BIN_ADD and op != BIN_SUB and op != BIN_MUL:
        return None
    var xo = _operand(a)
    var yo = _operand(b)
    if not xo or not yo:
        return None
    ref x = xo.value()
    ref y = yo.value()
    var precision: Int
    var scale: Int
    var r: I256
    if op == BIN_MUL:
        precision = x.precision + y.precision
        scale = x.scale + y.scale
        if precision > DECIMAL_LITERAL_MAX_PRECISION:
            return None
        r = x.value.cast[DType.int256]() * y.value.cast[DType.int256]()
    else:
        scale = max(x.scale, y.scale)
        precision = max(x.precision - x.scale, y.precision - y.scale) + scale + 1
        if precision > DECIMAL_LITERAL_MAX_PRECISION:
            return None
        var lhs = x.value.cast[DType.int256]() * _pow10(scale - x.scale)
        var rhs = y.value.cast[DType.int256]() * _pow10(scale - y.scale)
        if op == BIN_ADD:
            r = lhs + rhs
        else:
            r = lhs - rhs
    var bound = _pow10(precision)
    if r >= bound or r <= -bound:
        return None
    return Optional[ScalarValue](
        ScalarValue.decimal128_i128(r.cast[DType.int128](), precision, scale)
    )


def decimal_negate(a: ScalarValue) -> Optional[ScalarValue]:
    """`-a` for a DECIMAL literal, with its type; `None` for anything else."""
    var xo = _operand(a)
    if not xo or not a.is_decimal128():
        return None
    ref x = xo.value()
    return Optional[ScalarValue](
        ScalarValue.decimal128_i128(-x.value, x.precision, x.scale)
    )

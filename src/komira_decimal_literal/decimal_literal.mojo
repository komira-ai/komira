# =============================================================================
# decimal_literal -- DECIMAL literals the way DuckDB reads and folds them
# =============================================================================
#
# Two jobs, one set of rules:
#
#   * `decimal_from_literal_text`: the type and value of a literal's text.
#     DuckDB reads `0.06` as DECIMAL(3, 2): the precision is the number of
#     digits (the leading zero counts), the scale the digits after the point.
#     `0.060` is DECIMAL(4, 3), `100.00` DECIMAL(5, 2), `5.` DECIMAL(1, 0) and
#     `.5` DECIMAL(1, 1). A literal of more than 38 digits is not a DECIMAL
#     there (a DOUBLE) and has no type here; neither has a literal with an
#     exponent (`1e-2` is a DOUBLE).
#
#   * `decimal_fold_binary` / `decimal_negate`: the type and value of `a + b`,
#     `a - b`, `a * b` and `-a` over such literals, and over a decimal and an
#     integer literal. An integer literal takes part as DECIMAL(10, 0) when it
#     fits INT32 and DECIMAL(19, 0) when it does not (DuckDB's INTEGER and
#     BIGINT). The result type follows DuckDB's arithmetic binder:
#       `+` and `-`: scale max(s1, s2), width max(p1 - s1, p2 - s2) +
#         max(s1, s2) + 1;
#       `*`: scale s1 + s2, width p1 + p2; a scale past 38 is an error;
#     and then, for both, a width past 18 digits from operands that are both 18
#     digits or fewer is cut to 18 (for `*` only when the scale is below 18),
#     and a width past 38 is cut to 38; a cut result is checked, and a value
#     that does not fit the cut width is an error ("Overflow in addition of
#     DECIMAL(18)"). A result that was not cut always fits the width it has.
#
# The expected types below are DuckDB's, from `typeof(<expr>)`:
#   0.06 - 0.01 -> DECIMAL(4, 2)   0.06 * 0.01 -> DECIMAL(6, 4)
#   1 - 0.94    -> DECIMAL(13, 2)  2 * 0.025   -> DECIMAL(14, 3)
#   24 + 0.5    -> DECIMAL(12, 1)  3000000000 * 0.5 -> DECIMAL(21, 1)
#   2 + 1234567890123456.78 -> DECIMAL(18, 2)  (cut: 19 would be the width)
#   0.000000001 * 0.000000001 -> DECIMAL(20, 18)  (scale 18: not cut)
#   0.1234567890123456789012345678901234567 + 1 -> DECIMAL(38, 37)  (cut)
# (`komira_decimal_compare_conformance` runs DuckDB to write them, and to say
# which constants it raises on.)
#
# `decimal_fold_binary` raises for what DuckDB raises on, and returns `None`
# for a pair this rule does not own (two integers, a float, a typeless
# decimal, another operator). `decimal_from_literal_text` and `decimal_negate`
# are total. A caller that cannot raise (the optimizer's constant folding)
# keeps the expression it had; the SQL binder refuses the query.
# =============================================================================

from komira_plan_expr.expr import BIN_ADD, BIN_SUB, BIN_MUL
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128, I256


# The most digits a DECIMAL literal or a folded constant holds.
comptime DECIMAL_LITERAL_MAX_PRECISION = 38

# The widest DECIMAL stored in 64 bits: DuckDB keeps the result of arithmetic
# on operands of this width or less in it.
comptime _INT64_PRECISION = 18

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
    """The DECIMAL a literal's text denotes: `['-'] digits '.' digits`, with
    the digits before or after the point possibly none (`5.`, `.5`).

    The precision is the number of digits, the scale the digits after the
    point. `None` for text of another shape (no point, no digit at all, an
    exponent) or with more than 38 digits.
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
    if not seen_point or digits == 0:
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


def _decimal_text(unscaled: I256, scale: Int) -> String:
    """`unscaled / 10^scale` as DuckDB prints a DECIMAL: digits, a point before
    the last `scale` of them, a leading minus when negative."""
    var negative = unscaled < I256(0)
    var n = unscaled
    if negative:
        n = -n
    var ten = I256(10)
    var digits = List[UInt8]()
    while n > I256(0) or len(digits) <= scale:
        digits.append(UInt8(ord("0") + Int((n % ten).cast[DType.int64]())))
        n = n / ten
    var out = String("-") if negative else String("")
    for i in range(len(digits) - 1, -1, -1):
        out += chr(Int(digits[i]))
        if i == scale and scale > 0:
            out += "."
    return out^


def _overflow_error(
    what: String, symbol: String, precision: Int, lhs: I256, rhs: I256
) -> Error:
    """DuckDB's message for a sum, difference or product that does not fit
    the width it was cut to, with the operands as it prints them (unscaled)."""
    return Error(
        "Out of Range Error: Overflow in "
        + what
        + " of DECIMAL("
        + String(precision)
        + ") ("
        + _decimal_text(lhs, 0)
        + " "
        + symbol
        + " "
        + _decimal_text(rhs, 0)
        + "). You might want to add an explicit cast to a bigger decimal."
    )


def _cast_error(value: I256, scale: Int, precision: Int) -> Error:
    """DuckDB's message for an operand that does not fit the type a cut sum or
    difference was given: it casts both operands to it first."""
    return Error(
        "Conversion Error: Could not cast value "
        + _decimal_text(value, scale)
        + " to DECIMAL("
        + String(precision)
        + ","
        + String(scale)
        + ")"
    )


def decimal_fold_binary(
    op: UInt8, a: ScalarValue, b: ScalarValue
) raises -> Optional[ScalarValue]:
    """`a <op> b` for `+`, `-` and `*` where at least one of `a`, `b` is a
    DECIMAL literal and the other a DECIMAL or an integer literal, with the
    type and value DuckDB gives it (see the header).

    `None` when the pair is not that (two integers, a float, a typeless
    decimal) or `op` is another operator, or when an operand holds more digits
    than its precision says (so the result type would be wrong).

    Raises:
        What DuckDB raises: the value (or, for a sum or difference, an operand
        at the result's scale) does not fit the width the result was cut to
        (18 or 38 digits), or a product has a scale past 38.
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
    var max_width = max(x.precision, y.precision)
    var precision: Int
    var scale: Int
    var r: I256
    var lhs: I256
    var rhs: I256
    var cut = False
    if op == BIN_MUL:
        scale = x.scale + y.scale
        if scale > DECIMAL_LITERAL_MAX_PRECISION:
            raise Error(
                "Out of Range Error: Needed scale "
                + String(scale)
                + " to accurately represent the multiplication result, but"
                " this is out of range of the DECIMAL type. Max scale is "
                + String(DECIMAL_LITERAL_MAX_PRECISION)
                + "; could not perform an accurate multiplication. Either add"
                " a cast to DOUBLE, or add an explicit cast to a decimal with"
                " a lower scale."
            )
        precision = x.precision + y.precision
        # Operands that fit 64 bits keep a product of small scale in 64 bits.
        if (
            precision > _INT64_PRECISION
            and max_width <= _INT64_PRECISION
            and scale < _INT64_PRECISION
        ):
            precision = _INT64_PRECISION
            cut = True
        lhs = x.value.cast[DType.int256]()
        rhs = y.value.cast[DType.int256]()
        r = lhs * rhs
    else:
        scale = max(x.scale, y.scale)
        precision = max(x.precision - x.scale, y.precision - y.scale) + scale + 1
        if precision > _INT64_PRECISION and max_width <= _INT64_PRECISION:
            precision = _INT64_PRECISION
            cut = True
        lhs = x.value.cast[DType.int256]() * _pow10(scale - x.scale)
        rhs = y.value.cast[DType.int256]() * _pow10(scale - y.scale)
        if op == BIN_ADD:
            r = lhs + rhs
        else:
            r = lhs - rhs
    if precision > DECIMAL_LITERAL_MAX_PRECISION:
        precision = DECIMAL_LITERAL_MAX_PRECISION
        cut = True
    var bound = _pow10(precision)
    if cut and op != BIN_MUL:
        # DuckDB casts both operands to the cut type before it adds them.
        if lhs >= bound or lhs <= -bound:
            raise _cast_error(lhs, scale, precision)
        if rhs >= bound or rhs <= -bound:
            raise _cast_error(rhs, scale, precision)
    if r >= bound or r <= -bound:
        if not cut:
            # An operand holds more digits than its declared precision: the
            # type computed from the precisions is not the value's.
            return None
        if op == BIN_MUL:
            raise _overflow_error("multiplication", "*", precision, lhs, rhs)
        if op == BIN_ADD:
            raise _overflow_error("addition", "+", precision, lhs, rhs)
        raise _overflow_error("subtraction", "-", precision, lhs, rhs)
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

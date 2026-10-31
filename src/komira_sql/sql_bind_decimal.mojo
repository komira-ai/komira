# =============================================================================
# komira_sql/sql_bind_decimal.mojo
#   A number literal facing a DECIMAL column binds as a DECIMAL.
# =============================================================================
#
# DuckDB reads `0.06` as DECIMAL(3, 2) and compares a DECIMAL column with it as
# decimals, exactly. This binder reads every number literal with a point as
# FLOAT64, so `l_discount >= 0.06 - 0.01` compared a DECIMAL(15, 2) column with
# a float, after folding the bounds in floating point to 0.049999999999999996
# and 0.06999999999999999; and `x < 0.065` rounded the literal to the column's
# scale before comparing, keeping the rows that DuckDB drops.
#
# THE RULE. A comparison (= <> < <= > >=) whose one operand is a column of a
# DECIMAL type and whose other operand is a CONSTANT built from number literals
# (at least one with a point), unary minus and `+ - *` binds that constant as
# one DECIMAL literal, folded here with DuckDB's result type
# (`komira_decimal_literal`). A number constant on the left is flipped to the right
# (`0.065 > x` is `x < 0.065`, and so is `24 > x`), because the evaluator
# compares a column with a literal on its right exactly, and takes a literal on
# the left through a different path (`swap_decimal_comparison`).
#
# EVERYTHING ELSE IS UNCHANGED, on purpose. A number literal faces a FLOAT64 or
# integer column, sits in a select list, or is an operand of arithmetic keeps
# its FLOAT64 type: the evaluators have no DECIMAL-literal arm for those, and a
# DECIMAL literal there would be read as a different value. A literal of more
# than 38 digits, a literal with an exponent (`1e-2`), and a constant that
# holds a division are DOUBLE in DuckDB and stay FLOAT64 here too. A sum or
# product DuckDB raises on (it overflows the 18 or 38 digits its result is cut
# to, or its scale is past 38) is refused, with DuckDB's words.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_decimal_literal.decimal_literal import (
    decimal_fold_binary,
    decimal_from_literal_text,
    decimal_negate,
    INTEGER_FOLD_IDIV,
    integer_fold_binary,
    integer_negate,
)
from komira_plan_expr.expr import BIN_ADD, BIN_MOD, BIN_MUL, BIN_SUB, Expr
from komira_plan_expr.expr_walk import PlanColRefFields, walk_expr_field
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128, I256
from komira_sql.sql_ast import (
    SX_BINARY,
    SX_COLUMN,
    SX_FLOAT,
    SX_INT,
    SX_UNARY,
    SXOP_ADD,
    SXOP_EQ,
    SXOP_GE,
    SXOP_GT,
    SXOP_LE,
    SXOP_LT,
    SXOP_IDIV,
    SXOP_MOD,
    SXOP_MUL,
    SXOP_NE,
    SXOP_SUB,
    SXUN_NEGATE,
    SqlExpr,
)
from komira_sql.sql_bind_ops import _bind_sql_operator
from komira_sql.sql_bind_scope import BindScope, _resolve_col


def _hugeint_max() -> I256:
    """HUGEINT's maximum, 2^127 - 1, as the 256-bit integer the digits of an
    integer literal are read into."""
    return (I256(1) << I256(127)) - I256(1)


def _has_decimal_leaf(sx: SqlExpr) -> Bool:
    """True iff a number literal with a point (`0.5`, `5.`) or an integer past
    BIGINT is among the leaves of `sx`: the leaves this rule types as DECIMAL.
    An integer that fits BIGINT keeps its integer type."""
    if sx.tag == SX_FLOAT:
        return True
    if sx.tag == SX_INT:
        return sx.text.byte_length() > 0
    if sx.tag == SX_BINARY:
        return _has_decimal_leaf(sx._binary.value().left[]) or _has_decimal_leaf(
            sx._binary.value().right[]
        )
    if sx.tag == SX_UNARY:
        return _has_decimal_leaf(sx._agg.value().arg[])
    return False


def _big_integer(digits: String) -> Optional[ScalarValue]:
    """An integer past BIGINT as DuckDB types it, HUGEINT (DECIMAL(38, 0) in
    arithmetic and against a DECIMAL column); None when it is past HUGEINT's
    maximum 2^127 - 1 (DuckDB reads it as a DOUBLE)."""
    var n = I256(0)
    var ten = I256(10)
    var limit = _hugeint_max()
    for b in digits.as_bytes():
        n = n * ten + I256(Int(b - UInt8(ord("0"))))
        if n > limit:
            return None
    return Optional[ScalarValue](
        ScalarValue.decimal128_i128(n.cast[DType.int128](), 38, 0)
    )


struct _Const(Copyable, Movable):
    """A folded constant: its value, and whether it is integer-typed (an
    INTEGER, BIGINT or HUGEINT, carried as a scale-0 decimal of precision 10,
    19 or 38) so that `+ - *` over two of them stays an integer, as in DuckDB,
    rather than becoming a decimal."""

    var value: ScalarValue
    var integer: Bool

    def __init__(out self, var value: ScalarValue, integer: Bool):
        self.value = value^
        self.integer = integer


def _constant(sx: SqlExpr) raises -> Optional[_Const]:
    """The folded value of `sx` when it is a constant of number literals,
    unary minus and `+ - *` whose every step has an exact type, DECIMAL or
    integer; `None` for a constant DuckDB types DOUBLE (a literal with an
    exponent or of more than 38 digits, an integer past HUGEINT, a division),
    which keeps its float binding.

    Raises:
        What DuckDB raises folding the constant: a sum or product that does
        not fit the width it is cut to (18 or 38 digits), a product with a
        scale past 38, an integer sum, difference or product outside its
        INTEGER, BIGINT or HUGEINT range.
    """
    if sx.tag == SX_FLOAT:
        var parsed = decimal_from_literal_text(sx.text)
        if not parsed:
            return None
        return Optional[_Const](_Const(parsed.take(), False))
    if sx.tag == SX_INT:
        # An integer past BIGINT carries its digits in `text`: DuckDB types it
        # HUGEINT, which is DECIMAL(38, 0) beside a DECIMAL column.
        if sx.text.byte_length() > 0:
            var big = _big_integer(sx.text)
            if not big:
                return None
            return Optional[_Const](_Const(big.take(), True))
        # INTEGER when the literal's magnitude fits it, else BIGINT: the minus
        # of `-2147483648` applies to the BIGINT 2147483648.
        var x = Int(sx.int_val)
        var precision = 10
        if x <= -2147483648 or x > 2147483647:
            precision = 19
        return Optional[_Const](
            _Const(
                ScalarValue.decimal128_i128(I128(x), precision, 0), True
            )
        )
    if sx.tag == SX_UNARY and sx.op == SXUN_NEGATE:
        var inner = _constant(sx._agg.value().arg[])
        if not inner:
            return None
        if inner.value().integer:
            return Optional[_Const](
                _Const(integer_negate(inner.value().value), True)
            )
        # A constant that is not integer-typed is a DECIMAL (a parsed literal
        # or a fold of one), which `decimal_negate` always negates.
        var negated = decimal_negate(inner.value().value)
        return Optional[_Const](_Const(negated.take(), False))
    if sx.tag == SX_BINARY and (
        sx.op == SXOP_ADD
        or sx.op == SXOP_SUB
        or sx.op == SXOP_MUL
        or sx.op == SXOP_MOD
        or sx.op == SXOP_IDIV
    ):
        var left = _constant(sx._binary.value().left[])
        var right = _constant(sx._binary.value().right[])
        if not left or not right:
            return None
        var op = BIN_ADD
        if sx.op == SXOP_SUB:
            op = BIN_SUB
        elif sx.op == SXOP_MUL:
            op = BIN_MUL
        elif sx.op == SXOP_MOD:
            op = BIN_MOD
        elif sx.op == SXOP_IDIV:
            op = INTEGER_FOLD_IDIV
        if op == BIN_MOD or op == INTEGER_FOLD_IDIV:
            if not (left.value().integer and right.value().integer):
                # DuckDB's % over a DECIMAL is exact decimal arithmetic (and
                # // over one is a DOUBLE): not folded, and not left to floats.
                raise Error(
                    "SQL not supported: % and // over a decimal number in a"
                    " constant compared with a DECIMAL column; write the"
                    " operands as integers"
                )
        if left.value().integer and right.value().integer:
            return Optional[_Const](
                _Const(
                    integer_fold_binary(
                        op, left.value().value, right.value().value
                    ),
                    True,
                )
            )
        # At least one operand is a DECIMAL here (two integers folded above),
        # and every constant carries a precision and scale that agree with its
        # digits, so the fold has a result or raises.
        var folded = decimal_fold_binary(op, left.value().value, right.value().value)
        return Optional[_Const](_Const(folded.take(), False))
    return None


def _decimal_column(
    sx: SqlExpr, schema: Schema, scope: BindScope
) raises -> Optional[Expr]:
    """The column reference `sx` (an SX_COLUMN, as both callers check) when it
    names a column of a DECIMAL type."""
    var name = _resolve_col(sx, schema, scope)
    var column = Expr.col_ref(name)
    var missing = String("")
    var field = walk_expr_field[PlanColRefFields](column, schema, missing)
    if missing.byte_length() > 0 or field.arrow_type != ArrowType.DECIMAL128:
        return None
    return Optional[Expr](column^)


def _flipped(op: UInt8) -> UInt8:
    """The comparison that reads the same with its operands swapped."""
    if op == SXOP_LT:
        return SXOP_GT
    if op == SXOP_LE:
        return SXOP_GE
    if op == SXOP_GT:
        return SXOP_LT
    if op == SXOP_GE:
        return SXOP_LE
    return op


def _is_comparison(op: UInt8) -> Bool:
    return (
        op == SXOP_EQ
        or op == SXOP_NE
        or op == SXOP_LT
        or op == SXOP_LE
        or op == SXOP_GT
        or op == SXOP_GE
    )


def _is_number_constant(sx: SqlExpr) -> Bool:
    """True iff `sx` is a number literal, or unary minus and `+ - * % //` over them
    (no column, no other function). The same shape `_constant` folds, without
    the DECIMAL typing: an integer or a number past BIGINT is one too."""
    if sx.tag == SX_FLOAT or sx.tag == SX_INT:
        return True
    if sx.tag == SX_UNARY and sx.op == SXUN_NEGATE:
        return _is_number_constant(sx._agg.value().arg[])
    if sx.tag == SX_BINARY and (
        sx.op == SXOP_ADD
        or sx.op == SXOP_SUB
        or sx.op == SXOP_MUL
        or sx.op == SXOP_MOD
        or sx.op == SXOP_IDIV
    ):
        return _is_number_constant(
            sx._binary.value().left[]
        ) and _is_number_constant(sx._binary.value().right[])
    return False


def swap_decimal_comparison(
    sx: SqlExpr, schema: Schema, scope: BindScope
) raises -> Optional[SqlExpr]:
    """`sx` with its operands swapped (and the operator flipped) when it is a
    comparison of a number constant on the left with a DECIMAL column on the
    right: `0.065 > x` is `x < 0.065`, `24 > x` is `x < 24`.

    The evaluator compares a column with a literal on its right exactly; a
    literal on the left is broadcast to a column and compared as two columns,
    which is a different (and for an integer past BIGINT, a wrong) path. The
    caller binds the swapped comparison, so the column-on-the-left rules apply
    to it. None when `sx` is not that shape.
    """
    if sx.tag != SX_BINARY or not _is_comparison(sx.op):
        return None
    ref left = sx._binary.value().left[]
    ref right = sx._binary.value().right[]
    if right.tag != SX_COLUMN or not _is_number_constant(left):
        return None
    if not _decimal_column(right, schema, scope):
        return None
    var swapped = SqlExpr.binary(_flipped(sx.op), right.copy(), left.copy())
    swapped.text = String(sx.text)
    return Optional[SqlExpr](swapped^)


def bind_decimal_comparison(
    sx: SqlExpr, schema: Schema, scope: BindScope
) raises -> Optional[Expr]:
    """The bound comparison `sx` when it is a comparison of a DECIMAL column on
    the left with a DECIMAL constant on the right (see the header); None when
    the rule does not apply and the caller binds `sx` as it did."""
    if sx.tag != SX_BINARY or not _is_comparison(sx.op):
        return None
    ref left = sx._binary.value().left[]
    ref right = sx._binary.value().right[]
    if left.tag != SX_COLUMN or right.tag == SX_COLUMN or not _has_decimal_leaf(right):
        return None
    var column = _decimal_column(left, schema, scope)
    if not column:
        return None
    var constant = _constant(right)
    if not constant:
        return None
    var folded = constant.take()
    return Optional[Expr](
        _bind_sql_operator(
            sx.op,
            column.take(),
            Expr.literal(folded.value.copy()),
            schema,
        )
    )

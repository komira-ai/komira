# The DECIMAL type rule of `EXPR_ROUND_DIGITS`, shared by the field walk and
# the evaluators so both name the same output type.
#
# `round(x, d)` and `trunc(x, d)` over DECIMAL(w, s) (DuckDB's rule):
#   d >= s      -> DECIMAL(w, s), value unchanged
#   0 <= d < s  -> DECIMAL(w, d)
#   d < 0       -> DECIMAL(w, 0); when -d >= w - s every row is 0, NULL rows
#                  included, so the column is non-nullable.
# `RDG_ROUND_HALF_EVEN` has no DECIMAL rule: the type is the input's and the
# evaluator refuses the node.

from plan_expr.expr import RDG_ROUND, RDG_TRUNC


def round_digits_decimal_scale(op: UInt8, scale: Int, digits: Int) -> Int:
    """The output scale of `op` over a DECIMAL of scale `scale`."""
    if op != RDG_ROUND and op != RDG_TRUNC:
        return scale
    if digits >= scale:
        return scale
    if digits >= 0:
        return digits
    return 0


def round_digits_decimal_all_zero(
    op: UInt8, precision: Int, scale: Int, digits: Int
) -> Bool:
    """True iff every row of the result is 0, NULL rows included: a negative
    `digits` with `-digits >= precision - scale` under `RDG_ROUND` or
    `RDG_TRUNC`."""
    if op != RDG_ROUND and op != RDG_TRUNC:
        return False
    return digits < 0 and -digits >= precision - scale

# =============================================================================
# col_expr_division — what `ColExpr`'s `/` and `//` MEAN, decided in ONE place
# =============================================================================
#
# The Mojo untyped door (`PlanCarrier` + `ColExpr`) answers like SQL / DuckDB,
# so its two division operators are DuckDB v1.5.3's two, MEASURED:
#
#     expression                 DuckDB v1.5.3            BIN_DIV (this engine)
#     7 / 2        (int, int)    3.5      DOUBLE          3      (truncates)
#     -7 / 2                     -3.5     DOUBLE          -3
#     i / 0        (int col)     inf      DOUBLE          NULL
#     1.5::DECIMAL(4,1) / 2      0.75     DOUBLE          decimal division
#     1.5::REAL / 2              0.75     FLOAT           float division
#     7 // 2                     3        INTEGER         3      (the same op)
#     -7 // 2                    -3       (truncates)     -3
#     i // 0                     NULL                     NULL
#     7.5 // 2     (a double)    3.75     (NOT a floor)   3.75
#
# so `/` is TRUE division and `//` is exactly the engine's `BIN_DIV`.
#
# ⚠ `//` IS **NOT** POLARS' `//`. polars (and pandas, and Python) FLOOR:
# `-7 // 2 == -4`. The python skins answer like their libraries and floor
# (`pl.Expr.__floordiv__`, `_plan._FLOOR_ARITH`); this door answers like DuckDB
# and truncates. The two agree on every non-negative pair and on every exact
# division, and differ on a negative operand that does not divide exactly.
#
# ★ THE CAST IS WHAT THE PYTHON SKINS ALREADY EMIT. `_ops._resolve_division`
# wraps the LEFT operand of an all-integral `/` in `CAST(... AS FLOAT64)`.
# The engine's `BIN_DIV` on two integers keeps truncating — it is the
# operator `//` needs, and changing its result type would change every
# integer arithmetic expression (`komira_column_kernels/arithmetic.mojo`).
#
# ⚠ WHY THE RULE IS "STATICALLY FLOATING", NOT "BOTH INTEGRAL". A skin decides
# at the VERB, where it has the frame's schema. `ColExpr` is UNBOUND: `col("v")`
# does not know what `v` is, and the verb receives a plain `Expr` in which the
# difference between `/` and `//` is already gone. So the decision is made
# here, from what the expression itself PROVES: when either operand is provably
# floating (a float literal, a cast to a float, arithmetic over one) the
# division is already true division and the plan is left exactly as it was;
# otherwise the left operand is cast. Over a FLOAT64 column the cast is an
# identity, and both evaluators elide it (`compiler_eval_column`'s cast matrix
# lists F64 -> F64 as a no-op; `lower_untyped_expr`'s cast arm emits the child
# verbatim for an F64-family child).
#
# ★ THE VERB RE-DECIDES IT (`col_expr_bind`). Each division
# built here records that it was decided unbound (`BinaryOpData.
# division_intent`), and `PlanCarrier.select` / `with_columns` / `filter`
# re-decide it over their input schema, as DuckDB types it: a FLOAT operand's
# `/` and `//` answer FLOAT (MEASURED: `col("f") / 3` over float32 answered
# DOUBLE -0.8333333333333334 unbound, DuckDB and polars -0.8333333134651184), a
# DOUBLE ratio carries no identity cast, a DECIMAL (or any non-integer) `//` is
# `/` with a zero divisor NULL (the bare `BIN_DIV` raises `unsupported type 18`
# on a DECIMAL, and answers +-inf for `x // 0` over a DOUBLE where DuckDB
# answers NULL).
#
# ⚠ THE RESIDUAL OF BEING TYPE-BLIND, stated rather than hidden — what the
# tree built HERE still means wherever no schema-aware verb re-decides it (the
# SQL binder's unbound fallback, a hand-built plan -- the typed door's verbs
# bind over their DECLARED schema, `komira_pplan_chain`), and inside a carrier
# verb where `col_expr_bind` declines:
#   * a DECIMAL left operand is cast too. That IS DuckDB's answer (DOUBLE), but
#     the post-breaker translator (`lower_untyped_expr`) admits only the
#     I64/F64 -> F64 cast, so a decimal ratio computed over an aggregate REFUSES
#     there by name instead of answering.
#   * a FLOAT32 left operand answers DOUBLE where DuckDB answers FLOAT, and
#     `lit(120) / col(<float32>)` is refused by the engine ("float64 and
#     float32"). At a carrier verb only a quotient that IS a column's value is
#     narrowed to FLOAT; nested in more arithmetic or in a predicate it keeps
#     this tree (`col_expr_bind`'s header).
#   * a non-integer operand under `//` is the bare `BIN_DIV`: a DECIMAL
#     raises (type 18) and a float divides with +-inf at a zero divisor.
#   * a STRING left operand is parsed by the strict cast; DuckDB refuses
#     `VARCHAR / INTEGER` at bind. No customer spelling divides a string.
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    EXPR_LITERAL, EXPR_CAST, EXPR_BINARY_OP, EXPR_ALIAS,
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_MOD,
)


def is_statically_floating(e: Expr) -> Bool:
    """True iff `e`'s VALUE is provably a float, whatever the columns are.

    Conservative on purpose: `False` means "not proven", never "integral". A
    wrong `True` would skip the cast and answer integer division; a wrong
    `False` only costs an identity cast. So a node this does not understand
    (a column, a function call, a CASE) is `False`.
    """
    if e.tag == EXPR_LITERAL:
        return e.literal_value().is_float()
    if e.tag == EXPR_CAST:
        var t = e.cast_target()
        return t == DType.float64 or t == DType.float32
    if e.tag == EXPR_ALIAS:
        return is_statically_floating(e.alias_child_ref())
    if e.tag == EXPR_BINARY_OP:
        var op = e.binary_op()
        if (
            op == BIN_ADD
            or op == BIN_SUB
            or op == BIN_MUL
            or op == BIN_DIV
            or op == BIN_MOD
        ):
            # The engine promotes an arithmetic result to float when EITHER
            # side is float (`walk_expr_field`), so one proven side settles it.
            return is_statically_floating(
                e.binary_left_ref()
            ) or is_statically_floating(e.binary_right_ref())
    return False


# ★ WHO DECIDED — `BinaryOpData.division_intent`.
# `true_divide` / `integer_divide` decide WITHOUT the operands' types, so each
# records that it did, and which operator was asked. The node they build is a
# complete division either way (every consumer that ignores the field gets
# exactly the tree the header describes); a consumer that HAS the schema —
# `PlanCarrier`'s verbs and the typed door's (`komira_pplan_chain`),
# through `col_expr_bind.bind_unbound_expr` — re-decides
# it as DuckDB would from the real operand types. Without the record the two
# operators are indistinguishable there: `col("f") / 2` over a float32 is
# `BIN_DIV(CAST(f AS DOUBLE), 2)`, byte-identical to the user's own
# `col("f").cast(DType.float64) / 2`, and DuckDB answers FLOAT for one and
# DOUBLE for the other.
comptime DIVISION_TRUE: UInt8 = 1  # `/`, operands as written (one PROVED floating)
comptime DIVISION_TRUE_CAST_LEFT: UInt8 = 2  # `/`, the LEFT operand wrapped in the unbound CAST AS DOUBLE
comptime DIVISION_INTEGER: UInt8 = 3  # `//`, the bare BIN_DIV


def true_divide(var left: Expr, var right: Expr) -> Expr:
    """DuckDB's `/`: `7 / 2 == 3.5`. See the module header."""
    if is_statically_floating(left) or is_statically_floating(right):
        return Expr.binary_with_division_intent(
            BIN_DIV, left^, right^, DIVISION_TRUE
        )
    return Expr.binary_with_division_intent(
        BIN_DIV, Expr.cast(left^, DType.float64), right^,
        DIVISION_TRUE_CAST_LEFT,
    )


def integer_divide(var left: Expr, var right: Expr) -> Expr:
    """DuckDB's `//`: `-7 // 2 == -3` (truncates), `x // 0` is NULL. It is
    the engine's `BIN_DIV` unchanged. See the module header."""
    return Expr.binary_with_division_intent(
        BIN_DIV, left^, right^, DIVISION_INTEGER
    )

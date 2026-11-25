# =============================================================================
# sql/sql_bind_ops.mojo
#   Operator lowering: unary and binary operator maps, division, LIKE, NULL
#   comparisons, big integer literals and the integer-cast comparison unwrap.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import (
    Field, Schema, SchemaBuilder,
)
from column_kernels.unicode_case import unicode_lower_bytes
from plan_expr.agg_expr import (
    AGG_COUNT, AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM,
)
from plan_expr.col_expr_division import true_divide
from plan_expr.expr import (
    BIN_ADD, BIN_AND, BIN_DIV, BIN_EQ, BIN_GE, BIN_GT, BIN_LE, BIN_LT, BIN_MOD, BIN_MUL,
    BIN_NE, BIN_OR, BIN_SUB, EXPR_BINARY_OP, EXPR_CAST,
    EXPR_CORRELATED_SUBQUERY, EXPR_LITERAL, EXPR_UNARY_OP, Expr, MATH2_POW, STRFN_LOWER, STR_LIKE,
    STR_STARTS_WITH, UN_ABS, UN_IS_NOT_NULL, UN_IS_NULL, UN_NEGATE, UN_NOT,
    WhenCaseData,
)
from plan_expr.expr_walk import (
    PlanColRefFields, walk_expr_field,
)
from plan_expr.scalar_value import ScalarValue
from plan_ir.corr_subquery import corr_data_inner_plan_ref
from plan_ir.logical_plan import (
    AggExprArray, _infer_agg_field,
)
from sql.sql_ast import (
    SXAGG_AVG, SXAGG_COUNT, SXAGG_MAX, SXAGG_MIN, SXAGG_SUM, SXLIKE_ILIKE, SXOP_ADD,
    SXOP_AND, SXOP_CONCAT, SXOP_DIV, SXOP_DISTINCT, SXOP_EQ, SXOP_GE, SXOP_GT, SXOP_IDIV, SXOP_LE,
    SXOP_LT, SXOP_MOD, SXOP_MUL, SXOP_NE, SXOP_NOT_DISTINCT, SXOP_OR, SXOP_POW, SXOP_STARTS_WITH, SXOP_SUB,
    SXUN_ABS, SXUN_IS_FALSE, SXUN_IS_NOT_FALSE, SXUN_IS_NOT_NULL, SXUN_IS_NOT_TRUE,
    SXUN_IS_NULL, SXUN_IS_TRUE, SXUN_NEGATE, SXUN_NOT, SX_BINARY, SX_CALL,
    SX_COLUMN, SX_INT, SX_NULL, SX_STRING, SX_UNARY, SqlExpr,
)
from sql.sql_bind_scope import (
    BindScope, _resolve_col,
)
from sql.sql_fn_table import CAST_DESUGAR_NAME


def _map_unop(op: UInt8) raises -> UInt8:
    """SXUN_* -> the IR's UN_*.

    It raises on an unknown code rather than defaulting: a fallthrough to one
    operator would bind, say, `IS NOT NULL` as `IS NULL` and invert an answer
    with no diagnostic."""
    if op == SXUN_NOT:
        return UN_NOT
    if op == SXUN_IS_NULL:
        return UN_IS_NULL
    if op == SXUN_IS_NOT_NULL:
        return UN_IS_NOT_NULL
    if op == SXUN_NEGATE:
        # `-x` over an expression: the node `negate()` / the 1-argument
        # `subtract()` row lower to, type-preserving.
        return UN_NEGATE
    if op == SXUN_ABS:
        # prefix `@x` = `abs(x)`, the `FNK_UNARY_NUM` row's node.
        return UN_ABS
    raise Error(
        "SQL internal error: unknown unary operator code " + String(Int(op))
    )


comptime _BOOL_TEST_REFUSAL = (
    "SQL not supported: `IS [NOT] TRUE` / `IS [NOT] FALSE` over an operand that"
    " is not a BOOLEAN. DuckDB casts the operand to BOOLEAN first (`1 IS TRUE`"
    " is true), and this engine has no cast to BOOLEAN, so only a BOOLEAN"
    " operand is served; a column of another type can be compared instead"
    " (`i <> 0`). An operand whose type is not known here, such as an"
    " outer-query column inside a subquery, is refused too."
)


def _sxun_is_bool_test(op: UInt8) -> Bool:
    """`op` is one of `IS [NOT] TRUE` / `IS [NOT] FALSE`."""
    return (
        op == SXUN_IS_TRUE or op == SXUN_IS_NOT_TRUE
        or op == SXUN_IS_FALSE or op == SXUN_IS_NOT_FALSE
    )


def _lower_null_safe(sx: SqlExpr) -> Optional[SqlExpr]:
    """The SQL tree an `IS [NOT] DISTINCT FROM` node, or a boolean test of a
    NULL literal, stands for; None for every other node. Every binder site
    that walks SX_BINARY / SX_UNARY calls this first and binds the result
    instead, so no later step sees a distinct operator.

    `a IS NOT DISTINCT FROM b` is true when both are NULL, false when exactly
    one is, and `a = b` when neither is:
    `(a IS NULL AND b IS NULL) OR ((a IS NOT NULL AND b IS NOT NULL) AND a = b)`.
    Each disjunct is never NULL (the `=` is only reached beside two non-NULL
    operands, and Kleene `false AND NULL` is false), so the whole is never
    NULL. `IS DISTINCT FROM` is its NOT. The comparison is the ordinary `=`,
    so int-width, DECIMAL and string operands behave as they do under `=`.

    A NULL literal operand is folded here, since a bare NULL cannot be bound:
    `x IS DISTINCT FROM NULL` (either side) is `x IS NOT NULL` and
    `x IS NOT DISTINCT FROM NULL` is `x IS NULL`; two NULL literals are the
    constant false (`IS DISTINCT FROM`) or true (`IS NOT DISTINCT FROM`).
    `NULL IS TRUE` / `NULL IS FALSE` are the constant false, `NULL IS NOT
    TRUE` / `NULL IS NOT FALSE` the constant true."""
    if sx.tag == SX_UNARY:
        if not _sxun_is_bool_test(sx.op) or sx._agg.value().arg[].tag != SX_NULL:
            return None
        return Optional[SqlExpr](
            SqlExpr.bool_lit(sx.op == SXUN_IS_NOT_TRUE or sx.op == SXUN_IS_NOT_FALSE)
        )
    if sx.tag != SX_BINARY or (sx.op != SXOP_DISTINCT and sx.op != SXOP_NOT_DISTINCT):
        return None
    var same = sx.op == SXOP_NOT_DISTINCT
    ref left = sx._binary.value().left[]
    ref right = sx._binary.value().right[]
    if left.tag == SX_NULL and right.tag == SX_NULL:
        return Optional[SqlExpr](SqlExpr.bool_lit(same))
    if left.tag == SX_NULL or right.tag == SX_NULL:
        var other = right.copy() if left.tag == SX_NULL else left.copy()
        return Optional[SqlExpr](
            SqlExpr.unary(SXUN_IS_NULL if same else SXUN_IS_NOT_NULL, other^)
        )
    var both_null = SqlExpr.binary(
        SXOP_AND,
        SqlExpr.unary(SXUN_IS_NULL, left.copy()),
        SqlExpr.unary(SXUN_IS_NULL, right.copy()),
    )
    var both_present = SqlExpr.binary(
        SXOP_AND,
        SqlExpr.unary(SXUN_IS_NOT_NULL, left.copy()),
        SqlExpr.unary(SXUN_IS_NOT_NULL, right.copy()),
    )
    var values_equal = SqlExpr.binary(
        SXOP_AND, both_present^, SqlExpr.binary(SXOP_EQ, left.copy(), right.copy())
    )
    var is_same = SqlExpr.binary(SXOP_OR, both_null^, values_equal^)
    if same:
        return Optional[SqlExpr](is_same^)
    return Optional[SqlExpr](SqlExpr.unary(SXUN_NOT, is_same^))


def _bind_sql_unary(op: UInt8, var child: Expr, typing: Schema) raises -> Expr:
    """Every SX_UNARY site's LAST step: `child` is already bound by that
    site's own walker. A boolean test is built from AND / OR / NOT and the NULL
    tests, with Kleene logic making each never NULL:
    `x IS TRUE` = `x IS NOT NULL AND x`, `x IS FALSE` = `x IS NOT NULL AND NOT x`,
    `x IS NOT TRUE` = `x IS NULL OR NOT x`, `x IS NOT FALSE` = `x IS NULL OR x`.
    Any other operator is its IR node. A boolean test over a non-BOOLEAN
    operand is refused by name (`_BOOL_TEST_REFUSAL`)."""
    if not _sxun_is_bool_test(op):
        return Expr.unary(_map_unop(op), child^)
    if _operand_type(child, typing) != ArrowType.BOOL:
        raise Error(_BOOL_TEST_REFUSAL)
    if op == SXUN_IS_TRUE:
        return Expr.binary(
            BIN_AND, Expr.unary(UN_IS_NOT_NULL, child.copy()), child^
        )
    if op == SXUN_IS_FALSE:
        return Expr.binary(
            BIN_AND,
            Expr.unary(UN_IS_NOT_NULL, child.copy()),
            Expr.unary(UN_NOT, child^),
        )
    if op == SXUN_IS_NOT_TRUE:
        return Expr.binary(
            BIN_OR, Expr.unary(UN_IS_NULL, child.copy()), Expr.unary(UN_NOT, child^)
        )
    return Expr.binary(BIN_OR, Expr.unary(UN_IS_NULL, child.copy()), child^)


def _map_binop(op: UInt8) raises -> UInt8:
    if op == SXOP_EQ:
        return BIN_EQ
    if op == SXOP_NE:
        return BIN_NE
    if op == SXOP_LT:
        return BIN_LT
    if op == SXOP_LE:
        return BIN_LE
    if op == SXOP_GT:
        return BIN_GT
    if op == SXOP_GE:
        return BIN_GE
    if op == SXOP_AND:
        return BIN_AND
    if op == SXOP_OR:
        return BIN_OR
    if op == SXOP_ADD:
        return BIN_ADD
    if op == SXOP_SUB:
        return BIN_SUB
    if op == SXOP_MUL:
        return BIN_MUL
    if op == SXOP_MOD:
        # `%` IS `mod()`: truncated remainder, sign of the dividend
        # (-7 % 2 = -1, MEASURED v1.5.3), x % 0 NULL over integers.
        return BIN_MOD
    if op == SXOP_DIV or op == SXOP_IDIV:
        # Neither division maps to a bare `BIN_DIV` here: `/` over two
        # integers must not truncate, and `//` over a float needs its
        # zero-divisor guard. Every SX_BINARY site routes both through
        # `_bind_sql_division` before reaching here.
        raise Error(
            "SQL internal: a division operator reached the plain operator map;"
            " it must be bound by `_bind_sql_division` (DuckDB's `/` is TRUE"
            " division and its `//` is `divide()`)"
        )
    if op == SXOP_POW or op == SXOP_CONCAT or op == SXOP_STARTS_WITH:
        # ⛔ None of the three is an EXPR_BINARY_OP: `^` is a math node,
        # `^@` a string predicate and `||` has no node (see
        # `_bind_sql_operator`). A site that reached here skipped that router.
        raise Error(
            "SQL internal: a `^` / `^@` / `||` operator reached the plain"
            " operator map; it must be bound by `_bind_sql_operator`"
        )
    raise Error("SQL bind error: unsupported binary operator")


# =============================================================================
# `/` is DuckDB's true division; `//` and `%` are its integer ones.
# =============================================================================
#
# DuckDB v1.5.3 (BIGINT columns a, b; `z` all zero):
#
#   a / b        7/2 = 3.5, -7/2 = -3.5      DOUBLE      a / z = +-inf, 0/0 nan
#   a // b       7//2 = 3, -7//2 = -3        BIGINT      a // z = NULL  (truncates)
#   a % b        7%2 = 1, -7%2 = -1, 7%-2=1  BIGINT      a % z = NULL   (sign of a)
#   f / 2        DOUBLE     f // 2 = 3.75    DOUBLE: `//` over a float is not a
#                                            floor; it is `divide()` (7.5 // 0 NULL)
#   sum(a) / count(*)  DOUBLE
#
# `//` and `%` are the `divide()` / `mod()` rows of `sql_fn_table`
# (FNK_BINARY_OP).
#
# The `/` rule: cast the left operand to DOUBLE unless the binder can prove an
# operand non-integral, which is what `col_expr_division.true_divide` builds,
# so a `/` built through either door is the same tree. The binder has the
# operands' types (`walk_expr_field` over the relation schema, or over the
# aggregate output for a `/` above an aggregate), so a FLOAT or DECIMAL operand
# keeps a plain division with no cast added. Where a type is not visible (an
# outer reference inside a correlated subquery), `true_divide` decides, which
# casts unless an operand is statically floating.
#
# The `//` rule: `BIN_DIV`, which is DuckDB's integer division over integers,
# except that over a FLOAT or DECIMAL operand DuckDB's `//` is plain division
# whose zero divisor is NULL, not +-inf (`7.5::DOUBLE // 0` is NULL; `f / 0.0`
# is inf). So a provably non-integer `//` is
# `CASE WHEN rhs = 0 THEN NULL ELSE lhs / rhs END`. The `divide()` row binds
# through the same helper.


def _integral_tri(e: Expr, typing: Schema) -> Int:
    """1 = `e`'s value is an INTEGER, 0 = provably NOT one, -1 = the binder
    cannot see its type here (an unresolved name -- e.g. an outer reference in
    a correlated subquery -- types as `ArrowType.NULL`)."""
    var missing = String("")
    var t = walk_expr_field[PlanColRefFields](e, typing, missing).arrow_type
    if missing.byte_length() > 0 or t == ArrowType.NULL:
        return -1
    if t.is_integer():
        return 1
    return 0


def _is_float_typed(e: Expr, typing: Schema) -> Bool:
    """`e`'s value is PROVABLY a float (float16/32/64) over `typing`."""
    var missing = String("")
    var t = walk_expr_field[PlanColRefFields](e, typing, missing).arrow_type
    return missing.byte_length() == 0 and t.is_floating()


def _is_decimal_typed(e: Expr, typing: Schema) -> Bool:
    """`e`'s value is PROVABLY a DECIMAL128 over `typing`."""
    var missing = String("")
    var t = walk_expr_field[PlanColRefFields](e, typing, missing).arrow_type
    return missing.byte_length() == 0 and t == ArrowType.DECIMAL128


def _is_integer_valued_decimal(e: Expr, typing: Schema) -> Bool:
    """`e`'s value is PROVABLY a DECIMAL128 of scale 0 over `typing`: the type
    an integer `sum()` is declared (DECIMAL(38, 0), DuckDB's HUGEINT)."""
    var missing = String("")
    var f = walk_expr_field[PlanColRefFields](e, typing, missing)
    return (
        missing.byte_length() == 0
        and f.arrow_type == ArrowType.DECIMAL128
        and f.decimal_scale == 0
    )


def _bind_sql_division(op: UInt8, var lhs: Expr, var rhs: Expr, typing: Schema) raises -> Expr:
    """DuckDB's `/` (`op == SXOP_DIV`) or `//` (`SXOP_IDIV`, also the
    `divide()` row) over two bound operands. See the section header.

    An operand that is a DECIMAL of scale 0 is an integer `sum()` (HUGEINT in
    DuckDB), and DuckDB's `/` over it is DOUBLE, like `/` over any integer: it
    is cast to DOUBLE here, so `sum(a) / count(*)` answers 3.5 and not the
    engine's DECIMAL division (`3.5000`, rounded to four places). `//` over it
    is DuckDB's integer division, which this engine has no 128-bit kernel
    for, and the DECIMAL division it would fall to answers 3.5 for `7 // 2`:
    it is refused by name rather than answered wrong."""
    var lhs_big = _is_integer_valued_decimal(lhs, typing)
    var rhs_big = _is_integer_valued_decimal(rhs, typing)
    if (lhs_big or rhs_big) and op == SXOP_IDIV:
        raise Error(
            "SQL not supported: `//` / divide() over the sum of an integer"
            " column (DuckDB's HUGEINT, here DECIMAL(38, 0)). Integer division"
            " over a 128-bit operand has no kernel in this engine, and DECIMAL"
            " division would answer `7 // 2` as 3.5. CAST the sum to BIGINT"
            " first if its value fits 64 bits"
        )
    if lhs_big or rhs_big:
        # Cast the DECIMAL operand to DOUBLE: the division is then over a
        # floating operand, DuckDB's `/`, exactly the tree `true_divide`
        # builds for an integer numerator.
        if lhs_big:
            lhs = Expr.cast(lhs^, DType.float64)
        if rhs_big:
            rhs = Expr.cast(rhs^, DType.float64)
        return Expr.binary(BIN_DIV, lhs^, rhs^)
    if op == SXOP_IDIV:
        # A DECIMAL operand takes the float rule too: DuckDB 1.5.3's `//` over
        # a DECIMAL is its `/` (DOUBLE) with a zero divisor NULL, so the
        # division is guarded the same way.
        if (
            _is_float_typed(lhs, typing) or _is_float_typed(rhs, typing)
            or _is_decimal_typed(lhs, typing) or _is_decimal_typed(rhs, typing)
        ):
            var zero = Expr.literal(ScalarValue.from_float(0.0))
            if not _is_float_typed(rhs, typing):
                # The predicate reads the COLUMN's tag, so an integer divisor
                # is compared against an integer zero.
                zero = Expr.literal(ScalarValue.from_int64(0))
            var guard = List[WhenCaseData]()
            guard.append(
                WhenCaseData(
                    Expr.binary(BIN_EQ, rhs.copy(), zero^),
                    Expr.literal(ScalarValue.null(DType.float64)),
                )
            )
            return Expr.when(guard^, Expr.binary(BIN_DIV, lhs^, rhs^))
        return Expr.binary(BIN_DIV, lhs^, rhs^)
    if _integral_tri(lhs, typing) == 0 or _integral_tri(rhs, typing) == 0:
        # A FLOAT or DECIMAL operand: the engine already divides in that type,
        # and the plan stays byte-identical to what it was.
        return Expr.binary(BIN_DIV, lhs^, rhs^)
    # Both integral, or at least one not visible here: the untyped door's own
    # operator (it casts the left operand unless one is statically floating).
    return true_divide(lhs^, rhs^)


# =============================================================================
# The operator spellings of served functions.
# =============================================================================
#
# DuckDB v1.5.3:
#
#   a ^ b     = pow(a, b)          DOUBLE even over integers (2 ^ 10 = 1024.0),
#                                  left-associative (2 ^ 3 ^ 2 = 64.0)
#   s ^@ p    = starts_with(s, p)  BOOLEAN, case-sensitive
#   @x        = abs(x)             the operand's own type
#   -x        = negate(x)          the operand's own type
#   a || b    NULL-propagating concatenation (`'a' || NULL` is NULL, where
#             `concat('a', NULL)` is 'a'), casting a non-string operand to
#             VARCHAR.
#
# The first four build the node their function builds, so each answers what
# the function answers (the fn-table rows `pow` / `starts_with` / `abs` /
# 1-argument `subtract`). `-x` and `@x` are SX_UNARY (`_map_unop`) because
# every walker recurses through a unary node, which lets `-sum(a)` and
# `@(max(a) - min(a))` hoist their aggregates.
#
# `||` is refused by name. Binding it to the NULL-skipping `concat()` would
# answer 'a' for `'a' || NULL` where DuckDB answers NULL. Propagating the NULL
# needs a STRING-typed NULL value, and this IR has none (the same gap refuses
# `nullif()` over strings; see `_bind_nullif`).

comptime _CONCAT_OP_REFUSAL = (
    "SQL not supported: the `||` string-concatenation operator. DuckDB's `||`"
    " PROPAGATES NULL (`'a' || NULL` is NULL) where this engine's only"
    " concatenation, `concat()`, SKIPS a NULL operand (`concat('a', NULL)` is"
    " 'a'), and answering one for the other would be wrong on every row with a"
    " NULL. The missing primitive is a STRING-typed NULL value in the plan"
    " (the CASE that would propagate the NULL has no string NULL to return)."
    " `concat(a, b)` is served for the NULL-skipping answer, and is EXACT"
    " wherever neither operand can be NULL."
)


def _bind_sql_operator(op: UInt8, var lhs: Expr, var rhs: Expr, typing: Schema) raises -> Expr:
    """Every SX_BINARY site's LAST step: the two operands are already bound by
    that site's own walker (so an aggregate operand is already hoisted), and
    this decides what the OPERATOR builds. One router, so a new operator is one
    arm here and not three copies that can drift — the division pair already
    taught that (`_map_binop`'s refusal arm)."""
    if op == SXOP_DIV or op == SXOP_IDIV:
        return _bind_sql_division(op, lhs^, rhs^, typing)
    if op == SXOP_POW:
        return Expr.math_fn2(MATH2_POW, lhs^, rhs^)
    if op == SXOP_STARTS_WITH:
        if rhs.tag != EXPR_LITERAL or not rhs.literal_value().is_string():
            # The same narrowing `starts_with()` states (`FNK_STRING_PRED`):
            # the predicate node carries its pattern as a plan-time string.
            raise Error(
                "SQL not supported: the `^@` (starts-with) operator's right"
                " operand must be a string literal — a per-row prefix is a"
                " different operation this predicate node cannot express"
            )
        return Expr.string_op(
            STR_STARTS_WITH, lhs^, rhs.literal_value().string_val.copy()
        )
    if op == SXOP_CONCAT:
        raise Error(_CONCAT_OP_REFUSAL)
    if (
        op == SXOP_EQ or op == SXOP_NE or op == SXOP_LT or op == SXOP_LE
        or op == SXOP_GT or op == SXOP_GE
    ):
        return _bind_comparison(_map_binop(op), lhs^, rhs^, typing)
    return Expr.binary(_map_binop(op), lhs^, rhs^)


# =============================================================================
# A DECIMAL compared with a float
# =============================================================================
#
# DuckDB compares a DECIMAL with a FLOAT or DOUBLE in the float's own type: it
# casts the DECIMAL (MEASURED v1.5.3: `0.1::DECIMAL(2,1) = 0.1::DOUBLE` is
# true, `l_quantity < 0.2 * avg(l_quantity)` in TPC-H Q17 compares a DECIMAL
# column with the DOUBLE `avg` gives). The plan's comparison refuses that pair
# (`batch_eval`: frontends disagree on it), so the SQL binder writes DuckDB's
# cast. A scalar subquery operand is typed by its body's one output column,
# which `walk_expr_field` does not see into.


def _subquery_free(e: Expr, mut fields: List[Field]) raises -> Expr:
    """`e` with each scalar subquery replaced by a column `__sq<i>`, its
    output field appended to `fields`, through binary, unary and CAST nodes,
    so `walk_expr_field` can type the result."""
    if e.tag == EXPR_CORRELATED_SUBQUERY:
        var f = corr_data_inner_plan_ref(e._corr_subq.value()[]).output_schema.field_at_unchecked(0)
        f.name = "__sq" + String(len(fields))
        var ref_ = Expr.col_ref(f.name)
        fields.append(f^)
        return ref_^
    if e.tag == EXPR_BINARY_OP:
        var l = _subquery_free(e.binary_left_ref(), fields)
        var r = _subquery_free(e.binary_right_ref(), fields)
        return Expr.binary_with_division_intent(
            e.binary_op(), l^, r^, e.binary_division_intent()
        )
    if e.tag == EXPR_UNARY_OP:
        return Expr.unary(e.unary_op(), _subquery_free(e.unary_child_ref(), fields))
    if e.tag == EXPR_CAST:
        return Expr.cast_preserving_arrow(_subquery_free(e.cast_child_ref(), fields), e)
    return e.copy()


def _operand_type(e: Expr, typing: Schema) raises -> ArrowType:
    """The Arrow type of `e` over `typing`, a scalar subquery operand typed by
    its body; NULL when it cannot be typed."""
    var fields = List[Field]()
    var free = _subquery_free(e, fields)
    var sb = SchemaBuilder()
    for i in range(typing.num_columns()):
        sb.add_field(typing.field_at_unchecked(i))
    for i in range(len(fields)):
        sb.add_field(fields[i].copy())
    var missing = String("")
    var t = walk_expr_field[PlanColRefFields](free, sb.build(), missing).arrow_type
    if missing.byte_length() != 0:
        return ArrowType.NULL
    return t


def _is_constant(e: Expr) -> Bool:
    """Whether `e` is literals under binary, unary and CAST nodes only."""
    if e.tag == EXPR_LITERAL:
        return True
    if e.tag == EXPR_BINARY_OP:
        return _is_constant(e.binary_left_ref()) and _is_constant(e.binary_right_ref())
    if e.tag == EXPR_UNARY_OP:
        return _is_constant(e.unary_child_ref())
    if e.tag == EXPR_CAST:
        return _is_constant(e.cast_child_ref())
    return False


def _float_dtype(t: ArrowType) -> DType:
    """The DType of float Arrow type `t` (FLOAT32 is float32, any other
    float64)."""
    if t == ArrowType.FLOAT32:
        return DType.float32
    return DType.float64


def _bind_comparison(op: UInt8, var lhs: Expr, var rhs: Expr, typing: Schema) raises -> Expr:
    """`lhs <op> rhs`, the DECIMAL side cast to the float's type when the other
    side is a float that is not a constant (see the section header).

    Two non-constant BOOLEAN operands of `=` / `<>` are bound through the
    boolean operators, since the plan's column-vs-column comparison has no
    boolean pair: `a = b` is `(a AND b) OR (NOT a AND NOT b)` and `a <> b` its
    NOT. Under Kleene logic that is NULL exactly when an operand is NULL, as
    DuckDB's `=` is. `IS [NOT] DISTINCT FROM` over two boolean columns reaches
    this through its `=`. A boolean against a constant keeps the plain
    comparison, which the literal kernels serve."""
    var lt = _operand_type(lhs, typing)
    var rt = _operand_type(rhs, typing)
    if (
        (op == BIN_EQ or op == BIN_NE) and lt == ArrowType.BOOL and rt == ArrowType.BOOL
        and not _is_constant(lhs) and not _is_constant(rhs)
    ):
        var both_true = Expr.binary(BIN_AND, lhs.copy(), rhs.copy())
        var both_false = Expr.binary(
            BIN_AND, Expr.unary(UN_NOT, lhs^), Expr.unary(UN_NOT, rhs^)
        )
        var equal = Expr.binary(BIN_OR, both_true^, both_false^)
        if op == BIN_NE:
            return Expr.unary(UN_NOT, equal^)
        return equal^
    # A float constant is left as it is: the optimizer folds it to a literal,
    # and the comparison kernels serve a DECIMAL against a float literal.
    if lt == ArrowType.DECIMAL128 and rt.is_floating() and not _is_constant(rhs):
        lhs = Expr.cast(lhs^, _float_dtype(rt))
    elif rt == ArrowType.DECIMAL128 and lt.is_floating() and not _is_constant(lhs):
        rhs = Expr.cast(rhs^, _float_dtype(lt))
    return Expr.binary(op, lhs^, rhs^)


def _bind_like(sx: SqlExpr, var child: Expr) -> Expr:
    """An SX_LIKE node over its already-bound `child` (each walker binds the
    child its own way). `LIKE` matches the pattern as written; `ILIKE` folds
    both sides with `lower()`.

    That is DuckDB's own definition: v1.5.3 lower-cases the string and the
    pattern and runs LIKE (`'ÄBC' ILIKE 'ä%'` is TRUE, `'ß' ILIKE 'SS'` FALSE:
    no full case folding). The column side is `STRFN_LOWER` and the pattern
    side is `unicode_lower_bytes`, the function that kernel applies per row,
    so the two folds agree. `%` and `_` have no case and pass through the fold
    unchanged."""
    var c = child^
    var pat = String(sx.text)
    if sx.op == SXLIKE_ILIKE:
        c = Expr.string_fn(STRFN_LOWER, c^)
        var folded = unicode_lower_bytes(pat)
        pat = String(StringSlice(unsafe_from_utf8=Span(folded)))
    var so = Expr.string_op(STR_LIKE, c^, pat)
    if sx.like_negate:
        return Expr.unary(UN_NOT, so^)
    return so^


def _post_agg_typing_schema(input_schema: Schema, agg_exprs: AggExprArray) -> Schema:
    """The schema a post-aggregate scalar (a SELECT item or HAVING over
    `sum(a)`, `count(*)`, a group key) is typed against: every aggregate's
    output field under its bound name, then the input columns (a group key is
    one). Aggregates first, because an output may reuse an input's name
    (`sum(v) AS v`) and above the aggregate the name means the aggregate."""
    var sb = SchemaBuilder()
    for i in range(len(agg_exprs)):
        sb.add_field(_infer_agg_field(agg_exprs[i], input_schema))
    for j in range(input_schema.num_columns()):
        sb.add_field(input_schema.field_at_unchecked(j))
    return sb.build()


# =============================================================================
# The NULL literal (`SX_NULL`).
# =============================================================================
#
# Served as a comparison operand (`x = NULL`, `x <> NULL`, `x < NULL`, ...),
# which is also every IN-list member, because the parser desugars `x IN (a, b)`
# to `x = a OR x = b` and `x NOT IN (...)` to `x <> a AND ...`. Bound as the
# comparison against a typed NULL literal on the right, whatever side it was
# written on (every comparison with a NULL is NULL, so the operand order
# carries no meaning). Kleene AND / OR / NOT then give DuckDB 1.5.3's answers:
#
#   k IN (1, NULL)       k = 1 -> true,  otherwise NULL
#   k NOT IN (1, NULL)   k = 1 -> false, otherwise NULL (a WHERE selects nothing)
#
# The literal's type is int64, and that is not a claim about the column: a
# comparison with a NULL operand is NULL whatever the column's type.
#
# Refused by name everywhere else: a projected `NULL`, `NOT NULL`, `NULL =
# NULL`, a function argument, arithmetic. DuckDB answers each with a NULL of
# the context's type; this IR has no untyped NULL value, and a guessed type
# would be a wrong answer's shape. A CASE's ELSE takes an explicit `ELSE NULL`
# as the omitted ELSE it is.
#
# Two positions whose context type is knowable are served: a COALESCE / IFNULL
# argument is dropped (a NULL can never be the first non-NULL, so the answer
# and its type are the other arguments'), and a CASE `THEN NULL` becomes the
# typed NULL of its INT64 / FLOAT64 siblings (`_bind_case`). A CASE or
# COALESCE whose every value is NULL keeps the refusal: DuckDB's type there is
# NULL itself.

comptime _BARE_NULL_REFUSAL = (
    "SQL not supported: a NULL literal is served as a comparison operand (`x ="
    " NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN"
    " (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64"
    " or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one;"
    " anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other"
    " function argument, arithmetic, a CASE or COALESCE whose EVERY value is"
    " NULL) it needs a typed NULL value this engine's plan does not carry"
)


def _sxop_is_comparison(op: UInt8) -> Bool:
    return (
        op == SXOP_EQ or op == SXOP_NE or op == SXOP_LT
        or op == SXOP_LE or op == SXOP_GT or op == SXOP_GE
    )



# =============================================================================
# An integer literal past BIGINT.
# =============================================================================
# A literal past Int64.MAX reaches the binder with its digits in `sx.text`
# (`sql_token.tokenize`). DuckDB types it HUGEINT (UHUGEINT past 2^127), a type
# this engine has no literal or column for, so it is served in one shape only:
# an operand of a comparison (= <> < <= > >=) whose other operand is a plain
# column, when the value fits UBIGINT. There it binds as a UINT64-tagged
# literal, which a comparison reads by its exact value against every numeric
# column, the answer DuckDB's HUGEINT comparison gives
# (`WHERE u64 = 18446744073709551615` selects the row holding that value).
# Everywhere else it is refused by name: an arithmetic or projection of it
# would need the HUGEINT result type.


def _sx_is_big_int(sx: SqlExpr) -> Bool:
    """An integer literal PAST Int64.MAX (its digits ride in `text`)."""
    return sx.tag == SX_INT and sx.text.byte_length() > 0


def _big_int_literal_refusal(sx: SqlExpr) -> String:
    return (
        "SQL not supported: the integer literal " + sx.text
        + " is past BIGINT (9223372036854775807). DuckDB types it HUGEINT, a"
        " type this engine has no literal or column for; it is served only as"
        " one side of a comparison (= <> < <= > >=) against a plain column,"
        " when it fits UBIGINT (<= 18446744073709551615)."
    )


def _big_int_cmp_serves(sx: SqlExpr) -> Bool:
    """`sx` (an SX_BINARY) is a comparison with a big-literal operand facing a
    plain column -- the one shape `_bind_big_int_uint64` serves."""
    if not (
        sx.op == SXOP_EQ or sx.op == SXOP_NE or sx.op == SXOP_LT
        or sx.op == SXOP_LE or sx.op == SXOP_GT or sx.op == SXOP_GE
    ):
        return False
    ref l = sx._binary.value().left[]
    ref r = sx._binary.value().right[]
    return (_sx_is_big_int(l) and r.tag == SX_COLUMN) or (
        _sx_is_big_int(r) and l.tag == SX_COLUMN
    )


def _bind_big_int_uint64(sx: SqlExpr) raises -> Expr:
    """The big literal `sx` as a UINT64-TAGGED literal, or a refusal by name
    when its value is past UBIGINT too."""
    var b = sx.text.as_bytes()
    var v: UInt64 = 0
    for i in range(len(b)):
        var d = UInt64(Int(b[i]) - Int(ord("0")))
        if v > UInt64.MAX // 10 or (v == UInt64.MAX // 10 and d > UInt64.MAX % 10):
            raise Error(_big_int_literal_refusal(sx))
        v = v * 10 + d
    return Expr.literal(ScalarValue.from_uint64(v))



# =============================================================================
# `CAST(<int column> AS <signed int>) <cmp> <int literal that fits>` unwraps,
# which is DuckDB 1.5.3's own rule.
# =============================================================================
# Over BIGINT ib = [5, -3, 3000000000, NULL], DuckDB answers
# `WHERE CAST(ib AS INTEGER) > 0` with [1, 3] (EXPLAIN: `Filters: ib>0`), and
# the projection `SELECT CAST(ib AS INTEGER) > 0` likewise: the cast is dropped
# whenever the constant fits the target type, where evaluating it would raise a
# Conversion Error at 3000000000. DuckDB still raises when the constant does
# not fit (`< 3000000000`), is not an integer (`> 0.5`), or for `IS NULL`;
# none of those reach this rule, so they keep the cast and its error.
# Served here: a signed-integer column (INT8..INT64), a signed-integer target
# (TINYINT / SMALLINT / INTEGER / BIGINT and their aliases), an in-range
# non-big integer literal on the other side. `IN (...)` and `[NOT] BETWEEN`
# reach this rule too (the parser desugars them into these comparisons), which
# matches DuckDB; `NOT IN` / `NOT (x IN (...))` must not (DuckDB keeps the cast
# there; see `_int_cast_cmp_side`). A nested int cast
# (`CAST(CAST(ib AS INTEGER) AS BIGINT) > 0`) and a constant added to or
# subtracted from the cast (`CAST(ib AS INTEGER) + 1 > 0` -> `... > -1`,
# `_int_cast_arith_cmp`) are served too, as DuckDB's optimizer serves them, in
# a comparison only: under an IN list DuckDB moves no constant and strips one
# cast level, so a comparison the parser marks "in" does the same.
# Not served: a multiplied cast (DuckDB answers `CAST(ib AS INTEGER) * 2 > 0`
# as well), `c1 - CAST(...)` (DuckDB flips it), and the correlated and
# post-aggregate binders, which never call this.

def _signed_int_cast_bits(ty: String) -> Int:
    """The width in bits of a signed-integer CAST target name (lower-folded),
    or 0 when the name is not one."""
    if ty == "tinyint" or ty == "int1":
        return 8
    if ty == "smallint" or ty == "int2" or ty == "short":
        return 16
    if ty == "integer" or ty == "int" or ty == "int4" or ty == "int32" or ty == "signed":
        return 32
    if ty == "bigint" or ty == "int8" or ty == "int64" or ty == "long":
        return 64
    return 0


def _sx_unwrappable_int_cast(
    cast_sx: SqlExpr,
    lit_sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    allow_nested: Bool = True,
) raises -> Bool:
    """`cast_sx` is `CAST(<signed-int column> AS <signed int>)` and `lit_sx` an
    integer literal inside the target's range. `allow_nested=False` (an IN
    list's comparison, see the header) accepts ONE cast level only."""
    if cast_sx.tag != SX_CALL or cast_sx.text != CAST_DESUGAR_NAME:
        return False
    if lit_sx.tag != SX_INT or lit_sx.text.byte_length() > 0:
        return False
    ref cargs = cast_sx._call.value().args
    if len(cargs) != 2 or cargs[1].tag != SX_STRING:
        return False
    var bits = _signed_int_cast_bits(String(cargs[1].text))
    if bits == 0:
        return False
    if bits < 64:
        var hi = (Int64(1) << Int64(bits - 1)) - 1
        var lo = -hi - 1
        if lit_sx.int_val < lo or lit_sx.int_val > hi:
            return False
    if cargs[0].tag == SX_CALL:
        if not allow_nested:
            # An IN list strips one cast in DuckDB 1.5.3:
            # `CAST(CAST(ib AS INTEGER) AS BIGINT) IN (5, 7)` raises.
            return False
        # A nested int cast: DuckDB 1.5.3 applies the same rule to the inner
        # cast once the outer one is gone: `CAST(CAST(ib AS INTEGER) AS
        # BIGINT) > 0` answers [1, 3] over ib = [5, -3, 3000000000, NULL].
        return _sx_unwrappable_int_cast(cargs[0], lit_sx, schema, scope)
    if cargs[0].tag != SX_COLUMN:
        return False
    var name = _resolve_col(cargs[0], schema, scope)
    var target = name.lower()
    for i in range(schema.num_columns()):
        if schema.field_name(i).lower() == target:
            var at = schema.field_at(i).arrow_type
            return (
                at == ArrowType.INT8 or at == ArrowType.INT16
                or at == ArrowType.INT32 or at == ArrowType.INT64
            )
    return False


def _int_cast_base_column(sx: SqlExpr) -> SqlExpr:
    """The column under an unwrappable (possibly nested) int-cast chain -- the
    operand the unwrap binds in place of the cast (see `_sx_unwrappable_int_cast`)."""
    if sx.tag == SX_CALL and sx.text == CAST_DESUGAR_NAME:
        return _int_cast_base_column(sx._call.value().args[0])
    return sx.copy()


def _int_cast_arith_cmp(
    sx: SqlExpr, schema: Schema, scope: BindScope
) raises -> Optional[SqlExpr]:
    """`CAST(col AS <int>) + c1 <cmp> c2` (or `- c1`, or `c1 + CAST(...)`,
    either side of the comparison) -> the same comparison with the constant
    moved: `CAST(col AS <int>) <cmp> c2 - c1`, which the int-cast unwrap then
    serves. DuckDB 1.5.3's optimizer moves the constant first:
    `CAST(ib AS INTEGER) + 1 > 0` answers [1, 3] over
    ib = [5, -3, 3000000000, NULL] where evaluating the cast would raise.
    Returns the rewritten comparison, or None when the shape is not this one,
    the moved constant overflows Int64, or it leaves the cast's range (the
    unwrap then declines and the cast keeps its error, as DuckDB's does)."""
    if not (
        sx.op == SXOP_EQ or sx.op == SXOP_NE or sx.op == SXOP_LT
        or sx.op == SXOP_LE or sx.op == SXOP_GT or sx.op == SXOP_GE
    ):
        return None
    if sx.text == "not in" or sx.text == "in":
        # Not under an IN list: DuckDB 1.5.3 moves constants in a comparison,
        # never in IN, so `CAST(ib AS INTEGER) + 1 IN (6, 7)` raises the cast's
        # Conversion Error over ib = 3000000000.
        return None
    ref l = sx._binary.value().left[]
    ref r = sx._binary.value().right[]
    var arith_left = l.tag == SX_BINARY and r.tag == SX_INT
    var arith_right = r.tag == SX_BINARY and l.tag == SX_INT
    if not arith_left and not arith_right:
        return None
    var ar: SqlExpr
    var c2: SqlExpr
    if arith_left:
        ar = l.copy()
        c2 = r.copy()
    else:
        ar = r.copy()
        c2 = l.copy()
    if c2.text.byte_length() > 0:
        return None
    var is_add = ar.op == SXOP_ADD
    if not is_add and ar.op != SXOP_SUB:
        return None
    var al = ar._binary.value().left[].copy()
    var arr = ar._binary.value().right[].copy()
    var cast_on_left = al.tag == SX_CALL and arr.tag == SX_INT
    # `c1 - CAST(...)` would flip the comparison; only `c1 + CAST(...)` commutes.
    var cast_on_right = arr.tag == SX_CALL and al.tag == SX_INT and is_add
    if not cast_on_left and not cast_on_right:
        return None
    var cast_sx: SqlExpr
    var c1: SqlExpr
    if cast_on_left:
        cast_sx = al.copy()
        c1 = arr.copy()
    else:
        cast_sx = arr.copy()
        c1 = al.copy()
    if c1.text.byte_length() > 0:
        return None
    var moved: Int64
    if is_add:
        if (c1.int_val > 0 and c2.int_val < Int64.MIN + c1.int_val) or (
            c1.int_val < 0 and c2.int_val > Int64.MAX + c1.int_val
        ):
            return None
        moved = c2.int_val - c1.int_val
    else:
        if (c1.int_val > 0 and c2.int_val > Int64.MAX - c1.int_val) or (
            c1.int_val < 0 and c2.int_val < Int64.MIN - c1.int_val
        ):
            return None
        moved = c2.int_val + c1.int_val
    var lit = SqlExpr.int_lit(moved)
    if not _sx_unwrappable_int_cast(cast_sx, lit, schema, scope):
        return None
    var out: SqlExpr
    if arith_left:
        out = SqlExpr.binary(sx.op, cast_sx.copy(), lit^)
    else:
        out = SqlExpr.binary(sx.op, lit^, cast_sx.copy())
    out.text = sx.text.copy()
    return Optional(out^)


def _int_cast_cmp_side(sx: SqlExpr, schema: Schema, scope: BindScope) raises -> Int:
    """For an SX_BINARY comparison: 1 when its LEFT is an unwrappable int cast,
    2 when its RIGHT is, 0 otherwise (see the header above)."""
    if not (
        sx.op == SXOP_EQ or sx.op == SXOP_NE or sx.op == SXOP_LT
        or sx.op == SXOP_LE or sx.op == SXOP_GT or sx.op == SXOP_GE
    ):
        return 0
    # NOT IN keeps the cast: DuckDB 1.5.3 raises the cast's Conversion Error
    # for `CAST(ib AS INTEGER) NOT IN (5, 7)` and `NOT (CAST(ib AS INTEGER) IN
    # (5, 7))` over ib = 3000000000 (its IN simplification rewrites IN, never
    # NOT IN). The parser marks those comparisons.
    if sx.text == "not in":
        return 0
    ref l = sx._binary.value().left[]
    ref r = sx._binary.value().right[]
    # An IN list's comparison unwraps ONE cast level (see the header).
    var nested_ok = sx.text != "in"
    if _sx_unwrappable_int_cast(l, r, schema, scope, nested_ok):
        return 1
    if _sx_unwrappable_int_cast(r, l, schema, scope, nested_ok):
        return 2
    return 0


def _is_null_comparison(sx: SqlExpr) -> Bool:
    """`sx` is a comparison with a NULL literal on either side."""
    if sx.tag != SX_BINARY or not _sxop_is_comparison(sx.op):
        return False
    return (
        sx._binary.value().left[].tag == SX_NULL
        or sx._binary.value().right[].tag == SX_NULL
    )


def _null_comparison(op: UInt8, var other: Expr) raises -> Expr:
    """`other OP NULL`, the NULL typed and on the RIGHT (see the block above)."""
    return Expr.binary(
        _map_binop(op), other^, Expr.literal(ScalarValue.null(DType.int64))
    )


def _map_aggfunc(func: UInt8) raises -> UInt8:
    if func == SXAGG_SUM:
        return AGG_SUM
    if func == SXAGG_COUNT:
        return AGG_COUNT
    if func == SXAGG_MIN:
        return AGG_MIN
    if func == SXAGG_MAX:
        return AGG_MAX
    if func == SXAGG_AVG:
        return AGG_MEAN
    raise Error("SQL bind error: unsupported aggregate function")



# =============================================================================
# ColExpr — user-facing expression builder with operator overloading
# =============================================================================
#
# ColExpr wraps an Expr and provides the full operator overloading API that
# makes col("age") > 25 work naturally. The Mojo compiler resolves overloads
# at compile time based on argument type — zero runtime dispatch.
#
# Entry points:
#   col("name")       -> ColExpr wrapping ColRef
#   lit(42)           -> ColExpr wrapping Literal(Int)
#   lit(3.14)         -> ColExpr wrapping Literal(Float64)
#   lit("hello")      -> ColExpr wrapping Literal(String)
#   lit(True)         -> ColExpr wrapping Literal(Bool)
#
# Comparison operators (>, <, ==, !=, >=, <=) return Expr (terminal — used
# in filter predicates). Arithmetic operators (+, -, *, /, //) return ColExpr
# (chainable — for projection expressions). `/` is TRUE division and `//` is
# DuckDB's truncating integer division (`col_expr_division`).
# =============================================================================

from std.memory import OwnedPointer

from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.col_expr_name import ColExprNames
from komira_plan_expr.col_expr_division import true_divide, integer_divide, is_statically_floating
from komira_plan_expr.scalar_desugar import (
    coalesce_of, greatest_least_of, float_class_of, fill_nan_of, even_of,
    between_of, year_derived_of, nanosecond_of, days_in_month_of,
    promote_int_literal_to_float,
    YEAR_DERIVED_CENTURY, YEAR_DERIVED_DECADE, YEAR_DERIVED_MILLENNIUM,
    YEAR_DERIVED_ERA,
    FLOAT_CLASS_FINITE, FLOAT_CLASS_INFINITE, FLOAT_CLASS_NAN,
    BETWEEN_BOTH, BETWEEN_LEFT, BETWEEN_RIGHT, BETWEEN_NONE,
)
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_MOD,
    BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE,
    BIN_AND, BIN_OR,
    UN_NOT, UN_NEGATE, UN_IS_NULL, UN_IS_NOT_NULL,
    UN_ABS, UN_SIGN, UN_TRUNC, UN_ROUND,
    STR_CONTAINS, STR_STARTS_WITH, STR_ENDS_WITH, STR_LIKE,
    STRFN_UPPER,
    STRFNN_CONCAT,
    STRFNN_REPLACE,
    STRFNN_LPAD,
    STRFNN_RPAD,
    STRFNN_REPEAT,
    STRFNN_STRPOS,
    STRFNN_LEVENSHTEIN,
    STRFNN_TRANSLATE,
    STRFNN_DAMERAU_LEVENSHTEIN,
    STRFNN_HAMMING,
    STRFN_LOWER,
    STRFN_TRIM,
    STRFN_LTRIM,
    STRFN_RTRIM,
    STRFN_LENGTH,
    STRFN_REVERSE,
    STRFN_ASCII,
    STRFN_UNICODE,
    STRFN_STRLEN,
    STRFN_BIT_LENGTH,
    STRFN_HEX,
    STRFN_BIN,
    STRFN_URL_ENCODE,
    STRFN_URL_DECODE,
    STRFN_REGEXP_ESCAPE,
    STRFN_MD5,
    STRFN_SHA1,
    STRFN_SHA256,
    MATH_CEIL,
    MATH_FLOOR,
    MATH_LN,
    MATH_EXP,
    MATH_LOG10,
    MATH_LOG2,
    MATH_TAN,
    MATH_ATAN,
    MATH_ACOS,
    MATH_COT,
    MATH_DEGREES,
    MATH_CBRT,
    MATH_SINH,
    MATH_COSH,
    MATH_TANH,
    MATH_ACOSH,
    MATH_ASINH,
    MATH_ATANH,
    MATH_GAMMA,
    MATH2_POW,
    WhenCaseData,
    EXTRACT_DAYOFWEEK, EXTRACT_ISODOW, EXTRACT_DAYOFYEAR,
    EXTRACT_WEEK, EXTRACT_ISOYEAR, EXTRACT_YEARWEEK,
    EXTRACT_MILLISECOND, EXTRACT_MICROSECOND,
    EXTRACT_TRUNC_YEAR, EXTRACT_TRUNC_QUARTER, EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_WEEK, EXTRACT_TRUNC_DAY, EXTRACT_TRUNC_HOUR,
    EXTRACT_TRUNC_MINUTE, EXTRACT_TRUNC_SECOND,
    EXTRACT_TRUNC_MILLISECOND, EXTRACT_TRUNC_MICROSECOND,
)
from komira_plan_expr.partition_expr import (
    PartitionFrame,
    PF_ROW_NUMBER, PF_RANK, PF_DENSE_RANK,
    PF_PERCENT_RANK, PF_CUME_DIST, PF_NTILE,
    PF_LAG, PF_LEAD, PF_FIRST_VALUE, PF_LAST_VALUE, PF_NTH_VALUE,
    PF_SUM, PF_AVG, PF_COUNT, PF_MIN, PF_MAX,
    FRAME_UNITS_ROWS,
    FRAME_BOUND_PRECEDING, FRAME_BOUND_CURRENT_ROW,
)


# =============================================================================
# Free functions — entry points for users
# =============================================================================

@always_inline
def col(name: String) -> ColExpr:
    """Create a column reference expression. Primary entry point for users.

    Returns a `ColExpr` — chain comparison (`> < == !=`), arithmetic
    (`+ - * /`), boolean (`& |`), and `.alias(...)` operators to build the
    `Expr` that `df.filter(...)` / `df.with_column(...)` consume.

    Examples:
        ```mojo
        from komira_sdk import col, lit
        var adults = ctx.materialize(df^.filter(col("age") > 25)^)
        # arithmetic composes; .alias() turns the ColExpr into a named Expr:
        var out = ctx.materialize(
            df2^.with_column((col("price") * col("quantity")).alias("total"))^
        )
        ```
    """
    return ColExpr(Expr.col_ref(name))


@always_inline
def lit(value: Int) -> ColExpr:
    """Create a literal integer expression.

    Examples:
        ```mojo
        from komira_sdk import col, lit
        var out = ctx.materialize(df^.filter(col("age") > lit(25))^)
        ```
    """
    return ColExpr(Expr.literal(ScalarValue.from_int(value)))


@always_inline
def lit(value: Float64) -> ColExpr:
    """Create a literal float expression.

    Examples:
        ```mojo
        from komira_sdk import col, lit
        var out = ctx.materialize(df^.filter(col("price") <= lit(50.0))^)
        ```
    """
    return ColExpr(Expr.literal(ScalarValue.from_float(value)))


@always_inline
def lit(value: String) -> ColExpr:
    """Create a literal string expression.

    Examples:
        ```mojo
        from komira_sdk import col, lit
        var out = ctx.materialize(df^.filter(col("status") == lit("shipped"))^)
        ```
    """
    return ColExpr(Expr.literal(ScalarValue.from_string(value)))


@always_inline
def lit(value: Bool) -> ColExpr:
    """Create a literal boolean expression.

    Examples:
        ```mojo
        from komira_sdk import lit
        var yes = lit(True)
        ```
    """
    return ColExpr(Expr.literal(ScalarValue.from_bool(value)))


# =============================================================================
# Scalar math free functions
# =============================================================================
#
# Free-function form of the scalar math ops so they compose naturally over
# arithmetic sub-expressions: `sqrt(col("a") * col("a") + col("b") * col("b"))`.
# Each takes and returns a ColExpr so the FLOAT64 result stays chainable
# (ColExpr exposes the +/-/*//  operators that Expr does not). These are the
# surface the `haversine` example builds the great-circle formula from.

@always_inline
def sin(x: ColExpr) -> ColExpr:
    """`sin(x)` -> FLOAT64. Sine (radians) of a numeric expression."""
    return ColExpr(Expr.sin(x.copy_expr()))


@always_inline
def cos(x: ColExpr) -> ColExpr:
    """`cos(x)` -> FLOAT64. Cosine (radians) of a numeric expression."""
    return ColExpr(Expr.cos(x.copy_expr()))


@always_inline
def sqrt(x: ColExpr) -> ColExpr:
    """`sqrt(x)` -> FLOAT64. Square root of a numeric expression."""
    return ColExpr(Expr.sqrt(x.copy_expr()))


@always_inline
def asin(x: ColExpr) -> ColExpr:
    """`asin(x)` -> FLOAT64. Arcsine (radians) of a numeric expression."""
    return ColExpr(Expr.asin(x.copy_expr()))


@always_inline
def radians(x: ColExpr) -> ColExpr:
    """`radians(x)` -> FLOAT64. Convert degrees to radians."""
    return ColExpr(Expr.radians(x.copy_expr()))


# The DOUBLE-returning math names, in the same
# free-function form as the five above so they compose over arithmetic
# sub-expressions. ⛔ `abs` / `round` / `sign` are NOT here and may not be added:
# DuckDB PRESERVES their input type, and `EXPR_MATH_FN` is always FLOAT64.

@always_inline
def ceil(x: ColExpr) -> ColExpr:
    """`ceil(x)` -> FLOAT64. Round a numeric expression UP to an integral value."""
    return ColExpr(Expr.math_fn(MATH_CEIL, x.copy_expr()))


@always_inline
def floor(x: ColExpr) -> ColExpr:
    """`floor(x)` -> FLOAT64. Round a numeric expression DOWN to an integral value."""
    return ColExpr(Expr.math_fn(MATH_FLOOR, x.copy_expr()))


# =============================================================================
# The TYPE-PRESERVING numeric free functions.
# =============================================================================
#
# ⚠ READ THE RETURN TYPES ABOVE AND BELOW TOGETHER. `ceil`/`floor` return
# FLOAT64 for EVERY input, because they ride `EXPR_MATH_FN`, whose contract is
# always-FLOAT64 — and that MATCHES DuckDB v1.5.3, where `ceil(BIGINT)` really
# is DOUBLE (measured; `ceil` has no integer overload at all). The four below
# return the OPERAND's type, which also matches DuckDB, where `abs(BIGINT)` is
# BIGINT. Same file, same shape, two different and both-correct rules — which
# is why the rule lives per-op in `walk_expr_field` and not per-tag.


@always_inline
def abs(x: ColExpr) -> ColExpr:
    """`abs(x)` -> THE OPERAND'S TYPE. Absolute value.

    `abs(-0.0)` is `+0.0` and `abs(INT64_MIN)` RAISES an out-of-range error,
    both matching DuckDB v1.5.3. It is NOT `CASE WHEN x < 0 THEN -x ELSE x`,
    which gets both of those wrong silently."""
    return ColExpr(Expr.unary(UN_ABS, x.copy_expr()))


@always_inline
def sign(x: ColExpr) -> ColExpr:
    """`sign(x)` -> **INT8** (DuckDB TINYINT) for every numeric operand.

    The one member of this family whose output type does not follow the
    operand. `sign(-0.0)` and `sign(nan)` are both `0`."""
    return ColExpr(Expr.unary(UN_SIGN, x.copy_expr()))


@always_inline
def trunc(x: ColExpr) -> ColExpr:
    """`trunc(x)` -> THE OPERAND'S TYPE. Round toward zero; an integer operand
    is returned unchanged. `trunc(-0.5)` is `-0.0`, not `0.0`."""
    return ColExpr(Expr.unary(UN_TRUNC, x.copy_expr()))


@always_inline
def round(x: ColExpr) -> ColExpr:
    """`round(x)` -> THE OPERAND'S TYPE. Round HALF AWAY FROM ZERO (so
    `round(2.5)` is 3, not the banker's-rounding 2); an integer operand is
    returned unchanged.

    ⚠ ONE ARGUMENT. DuckDB's `round(x, digits)` is not expressible on a unary
    node and is refused by name at the SQL door."""
    return ColExpr(Expr.unary(UN_ROUND, x.copy_expr()))


@always_inline
def ln(x: ColExpr) -> ColExpr:
    """`ln(x)` -> FLOAT64. Natural logarithm of a numeric expression."""
    return ColExpr(Expr.math_fn(MATH_LN, x.copy_expr()))


@always_inline
def exp(x: ColExpr) -> ColExpr:
    """`exp(x)` -> FLOAT64. e raised to a numeric expression."""
    return ColExpr(Expr.math_fn(MATH_EXP, x.copy_expr()))


@always_inline
def log10(x: ColExpr) -> ColExpr:
    """`log10(x)` -> FLOAT64. Base-10 logarithm (DuckDB spells this `log` too)."""
    return ColExpr(Expr.math_fn(MATH_LOG10, x.copy_expr()))


@always_inline
def log2(x: ColExpr) -> ColExpr:
    """`log2(x)` -> FLOAT64. Base-2 logarithm of a numeric expression."""
    return ColExpr(Expr.math_fn(MATH_LOG2, x.copy_expr()))


@always_inline
def tan(x: ColExpr) -> ColExpr:
    """`tan(x)` -> FLOAT64. Tangent (radians) of a numeric expression."""
    return ColExpr(Expr.math_fn(MATH_TAN, x.copy_expr()))


@always_inline
def atan(x: ColExpr) -> ColExpr:
    """`atan(x)` -> FLOAT64. Arctangent of a numeric expression, in radians."""
    return ColExpr(Expr.math_fn(MATH_ATAN, x.copy_expr()))


@always_inline
def acos(x: ColExpr) -> ColExpr:
    """`acos(x)` -> FLOAT64. Arccosine, in radians. Domain [-1, 1]; NaN outside."""
    return ColExpr(Expr.math_fn(MATH_ACOS, x.copy_expr()))


@always_inline
def cot(x: ColExpr) -> ColExpr:
    """`cot(x)` -> FLOAT64. Cotangent, `1/tan`, of a numeric expression."""
    return ColExpr(Expr.math_fn(MATH_COT, x.copy_expr()))


@always_inline
def degrees(x: ColExpr) -> ColExpr:
    """`degrees(x)` -> FLOAT64. Convert radians to degrees."""
    return ColExpr(Expr.math_fn(MATH_DEGREES, x.copy_expr()))


@always_inline
def cbrt(x: ColExpr) -> ColExpr:
    """`cbrt(x)` -> FLOAT64. Cube root; defined for NEGATIVE input, unlike `x ** (1/3)`."""
    return ColExpr(Expr.math_fn(MATH_CBRT, x.copy_expr()))


@always_inline
def sinh(x: ColExpr) -> ColExpr:
    """`sinh(x)` -> FLOAT64. Hyperbolic sine of a numeric expression."""
    return ColExpr(Expr.math_fn(MATH_SINH, x.copy_expr()))


@always_inline
def cosh(x: ColExpr) -> ColExpr:
    """`cosh(x)` -> FLOAT64. Hyperbolic cosine of a numeric expression."""
    return ColExpr(Expr.math_fn(MATH_COSH, x.copy_expr()))


@always_inline
def tanh(x: ColExpr) -> ColExpr:
    """`tanh(x)` -> FLOAT64. Hyperbolic tangent of a numeric expression."""
    return ColExpr(Expr.math_fn(MATH_TANH, x.copy_expr()))


@always_inline
def acosh(x: ColExpr) -> ColExpr:
    """`acosh(x)` -> FLOAT64. Inverse hyperbolic cosine. NaN for `x < 1`."""
    return ColExpr(Expr.math_fn(MATH_ACOSH, x.copy_expr()))


@always_inline
def asinh(x: ColExpr) -> ColExpr:
    """`asinh(x)` -> FLOAT64. Inverse hyperbolic sine; total on the reals."""
    return ColExpr(Expr.math_fn(MATH_ASINH, x.copy_expr()))


@always_inline
def atanh(x: ColExpr) -> ColExpr:
    """`atanh(x)` -> FLOAT64. Inverse hyperbolic tangent.

    ⚠ `|x| > 1` is NaN here and an ERROR in DuckDB — the same libm-vs-raise
    convention this engine already uses for `sqrt(-1)` and `ln(0)`.
    """
    return ColExpr(Expr.math_fn(MATH_ATANH, x.copy_expr()))


@always_inline
def gamma(x: ColExpr) -> ColExpr:
    """`gamma(x)` -> FLOAT64. The gamma function (libm `tgamma`), NOT `lgamma`.

    `gamma(n) = (n-1)!` for a positive integer `n`, so `gamma(5.0)` = 24.0.
    """
    return ColExpr(Expr.math_fn(MATH_GAMMA, x.copy_expr()))


@always_inline
def atan2(y: ColExpr, x: ColExpr) -> ColExpr:
    """`atan2(y, x)` -> FLOAT64. Two-argument arctangent (radians)."""
    return ColExpr(Expr.atan2(y.copy_expr(), x.copy_expr()))


# =============================================================================
# NULL-IGNORING combinators — `coalesce`, `greatest` / `least`
# =============================================================================
#
# ★ ONE BUILDER, TWO DOORS. The trees are `scalar_desugar`'s, which the SQL
# binder calls for `coalesce(...)` / `greatest(a, b)` / `least(a, b)` too, so
# the untyped Mojo door and the SQL door lower these names to the SAME plan.
# Type unification (the CASE executor's one-dtype rule) is decided from what
# the arguments PROVE, as `/` is (`_unify_case_args`).


def _unify_case_args(var args: List[Expr]) -> List[Expr]:
    """If any argument PROVABLY floats, turn the integer LITERALS into float
    literals — the CASE rule the SQL binder applies from the schema. A column
    of unknown type proves nothing here, so `coalesce(col("f"), lit(0))` keeps
    its integer ELSE in the tree this builds; `PlanCarrier`'s
    `select` / `with_columns` / `filter` re-unify the literal from the real
    column type (`col_expr_bind`: DOUBLE over a float64, FLOAT over a
    float32). Where no carrier verb binds the tree (the typed door's
    `EmitScan`), the engine refuses the mixed branch by name."""
    var any_float = False
    for i in range(len(args)):
        if is_statically_floating(args[i]):
            any_float = True
    if not any_float:
        return args^
    var out = List[Expr]()
    for i in range(len(args)):
        out.append(promote_int_literal_to_float(args[i].copy()))
    return out^


def coalesce(*args: ColExpr) raises -> ColExpr:
    """`coalesce(a, b, ..., z)` — the first non-NULL argument, else the LAST
    (unguarded: `coalesce(NULL, NULL)` is NULL). DuckDB's `coalesce`, polars'
    `pl.coalesce`. One argument is that argument. RAISES on zero.

    Examples:
        ```mojo
        from komira_plan_expr.col_expr import coalesce, col, lit
        var e = coalesce(col("nick"), col("name"), lit("?")).alias("who")
        ```
    """
    if len(args) == 0:
        raise Error("coalesce() expects at least 1 argument — got 0")
    var exprs = List[Expr]()
    for a in args:
        exprs.append(a.copy_expr())
    return ColExpr(coalesce_of(_unify_case_args(exprs^)))


def greatest(a: ColExpr, b: ColExpr) -> ColExpr:
    """`greatest(a, b)` — the larger operand, IGNORING a NULL one
    (`greatest(1, NULL)` = 1, DuckDB v1.5.3). Two operands, by construction:
    the tree mentions each four times, so a variadic fold would square it.
    polars' `max_horizontal(a, b)` is the same function."""
    var u = List[Expr]()
    u.append(a.copy_expr())
    u.append(b.copy_expr())
    u = _unify_case_args(u^)
    return ColExpr(greatest_least_of(True, u[0].copy(), u[1].copy()))


def least(a: ColExpr, b: ColExpr) -> ColExpr:
    """`least(a, b)` — the smaller operand, IGNORING a NULL one. See
    `greatest`; polars' `min_horizontal(a, b)`."""
    var u = List[Expr]()
    u.append(a.copy_expr())
    u.append(b.copy_expr())
    u = _unify_case_args(u^)
    return ColExpr(greatest_least_of(False, u[0].copy(), u[1].copy()))


def max_horizontal(a: ColExpr, b: ColExpr) -> ColExpr:
    """polars' name for `greatest(a, b)` — null-ignoring, two operands."""
    return greatest(a, b)


def min_horizontal(a: ColExpr, b: ColExpr) -> ColExpr:
    """polars' name for `least(a, b)` — null-ignoring, two operands."""
    return least(a, b)


def sum_horizontal(*args: ColExpr) raises -> ColExpr:
    """polars `sum_horizontal(a, b, ...)`: the row-wise sum IGNORING NULLs —
    `coalesce(a, 0) + coalesce(b, 0) + ...`, so an all-NULL row is 0, not
    NULL (MEASURED, polars 1.44.2: `[NULL, NULL] -> 0`, `[1, NULL] -> 1`).
    DuckDB has no such function; the SQL door asks the same question with
    that expression. The zero is `0.0` where an operand PROVES it is floating
    (`_unify_case_args`, the `fill_null` rule) and `0` otherwise; over an
    UNPROVEN float column a `PlanCarrier` verb re-unifies it from the schema
    (`col_expr_bind`) — a DOUBLE sum over float64 columns. ⛔ Over
    a FLOAT (float32) column — `sum_horizontal(f, f)` and the mixed
    `sum_horizontal(f, x)` alike — the CASEs sit under `+`, where the engine
    has no float32 CASE or sum, and the run raises the engine's UNNAMED
    "PipelineCompiler: CASE/WHEN THEN type mismatch at case 0: expected
    int64, got float32" (MEASURED; polars answers Float32 / Float64). Not
    refused by name yet. RAISES on zero operands."""
    if len(args) == 0:
        raise Error("sum_horizontal() expects at least 1 argument — got 0")
    var acc = Optional[Expr]()
    for a in args:
        var pair = List[Expr]()
        pair.append(a.copy_expr())
        pair.append(Expr.literal(ScalarValue.from_int(0)))
        var term = coalesce_of(_unify_case_args(pair^))
        if acc:
            acc = Expr.binary(BIN_ADD, acc.take(), term^)
        else:
            acc = term^
    return ColExpr(acc.take())


def when_then_else(var condition: Expr, var then_val: Expr, var else_val: Expr) -> Expr:
    """Create a simple CASE WHEN condition THEN then_val ELSE else_val expression.

    Args:
        condition: The WHEN condition.
        then_val: The value when condition is true.
        else_val: The value when condition is false.

    Returns:
        An Expr representing the CASE/WHEN expression.

    Examples:
        ```mojo
        from komira_sdk import col, lit, when_then_else
        # tag rows big/small, materialized as a new column
        var flag = when_then_else(col("x") > 10, lit(1).take_expr(), lit(0).take_expr())
        var out = ctx.materialize(df^.with_column(Expr.alias(flag^, "is_big"))^)
        ```
    """
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(condition^, then_val^))
    return Expr.when(cases^, else_val^)


def when(var condition: Expr, result_int: Int) -> WhenBuilder:
    """Start building a CASE WHEN expression with an integer result.

    Chain `.when(cond, val)` for more branches, finish with `.otherwise(val)`
    (which returns the `Expr`). The builder mutates in place (`.when` returns a
    ref to self), so use an intermediate `var`.

    Args:
        condition: The condition for the first WHEN clause.
        result_int: The integer value to return when condition is true.

    Returns:
        A WhenBuilder for chaining additional WHEN clauses or OTHERWISE.

    Examples:
        ```mojo
        from komira_sdk import col, when
        # bucket into 3 / 2 / 1
        var wb = when(col("x") > 10, 3)
        _ = wb.when(col("x") > 5, 2)
        var bucket = wb.otherwise(1)      # -> Expr
        var out = ctx.materialize(df^.with_column(Expr.alias(bucket^, "bucket"))^)
        ```
    """
    var result_expr = Expr.literal(ScalarValue.from_int(result_int))
    return WhenBuilder(condition^, result_expr^)


def when_expr(var condition: Expr, var result: Expr) -> WhenBuilder:
    """Start building a CASE WHEN expression with an Expr result.

    Like `when(...)` but the THEN branch is an arbitrary `Expr` (e.g. a
    computed column) rather than an integer literal.

    Args:
        condition: The condition for the first WHEN clause.
        result: The Expr value to return when condition is true.

    Returns:
        A WhenBuilder for chaining additional WHEN clauses or OTHERWISE.

    Examples:
        ```mojo
        from komira_sdk import col, lit, when_expr
        var wb = when_expr(col("x") > 10, (col("x") * lit(2)).alias("hi"))
        var e = wb.otherwise(lit(0).take_expr())
        ```
    """
    return WhenBuilder(condition^, result^)


struct WhenBuilder(Movable):
    """Builder for CASE WHEN expressions. Chain .when() calls, finish with .otherwise().

    Stores cases on the heap inside an OwnedPointer[List[WhenCaseData]]. The
    smart pointer handles allocation, destruction, and move semantics so no
    manual alloc/free or UnsafePointer bookkeeping is required.
    """

    var _cases: OwnedPointer[List[WhenCaseData]]

    def __init__(out self, var condition: Expr, var result: Expr):
        """Create with the first WHEN clause."""
        var cases = List[WhenCaseData]()
        cases.append(WhenCaseData(condition^, result^))
        self._cases = OwnedPointer(cases^)

    def when(mut self, var condition: Expr, result_int: Int) -> ref [self] Self:
        """Add another WHEN clause with integer result."""
        var result_expr = Expr.literal(ScalarValue.from_int(result_int))
        self._cases[].append(WhenCaseData(condition^, result_expr^))
        return self

    def when(mut self, var condition: Expr, var result: Expr) -> ref [self] Self:
        """Add another WHEN clause with Expr result."""
        self._cases[].append(WhenCaseData(condition^, result^))
        return self

    def otherwise(mut self, default_int: Int) -> Expr:
        """Finish the CASE expression with an integer ELSE value.

        Swaps `self._cases` with a fresh empty OwnedPointer so the original
        owned storage can be taken while leaving `self` in a valid (empty)
        state -- the caller typically drops `wb` right after this call.
        """
        var default_expr = Expr.literal(ScalarValue.from_int(default_int))
        var empty = OwnedPointer(List[WhenCaseData]())
        var owned = self._cases^
        self._cases = empty^
        var cases = owned^.into_inner()
        return Expr.when(cases^, default_expr^)

    def otherwise(mut self, var default: Expr) -> Expr:
        """Finish the CASE expression with an Expr ELSE value."""
        var empty = OwnedPointer(List[WhenCaseData]())
        var owned = self._cases^
        self._cases = empty^
        var cases = owned^.into_inner()
        return Expr.when(cases^, default^)


# =============================================================================
# ColExpr struct
# =============================================================================

struct ColExpr(Movable, Writable):
    """User-facing expression builder with operator overloading.

    Wraps an Expr and provides overloaded operators for natural expression
    building. Comparison operators return Expr (terminal), arithmetic
    operators return ColExpr (chainable).
    """

    var _expr: Expr

    def __init__(out self, var expr: Expr):
        """Wrap an existing Expr."""
        self._expr = expr^

    def take_expr(self) -> Expr:
        """Return the inner Expr (copy — Mojo forbids partial moves)."""
        return self._expr.copy()

    @always_inline
    def copy_expr(self) -> Expr:
        """Return a deep copy of the inner Expr."""
        return self._expr.copy()

    # =========================================================================
    # Comparison operators — return Expr (terminal, used in filter predicates)
    # =========================================================================

    # --- __gt__ ---

    def __gt__(self, other: Int) -> Expr:
        return Expr.binary(BIN_GT, self._expr.copy(), Expr.literal(ScalarValue.from_int(other)))

    def __gt__(self, other: Float64) -> Expr:
        return Expr.binary(BIN_GT, self._expr.copy(), Expr.literal(ScalarValue.from_float(other)))

    def __gt__(self, other: String) -> Expr:
        return Expr.binary(BIN_GT, self._expr.copy(), Expr.literal(ScalarValue.from_string(other)))

    def __gt__(self, other: ColExpr) -> Expr:
        return Expr.binary(BIN_GT, self._expr.copy(), other._expr.copy())

    def __gt__(self, other: Expr) -> Expr:
        """`col("x") > <Expr>` (e.g. agg-fn result)."""
        return Expr.binary(BIN_GT, self._expr.copy(), other.copy())

    # --- __lt__ ---

    def __lt__(self, other: Int) -> Expr:
        return Expr.binary(BIN_LT, self._expr.copy(), Expr.literal(ScalarValue.from_int(other)))

    def __lt__(self, other: Float64) -> Expr:
        return Expr.binary(BIN_LT, self._expr.copy(), Expr.literal(ScalarValue.from_float(other)))

    def __lt__(self, other: String) -> Expr:
        return Expr.binary(BIN_LT, self._expr.copy(), Expr.literal(ScalarValue.from_string(other)))

    def __lt__(self, other: ColExpr) -> Expr:
        return Expr.binary(BIN_LT, self._expr.copy(), other._expr.copy())

    def __lt__(self, other: Expr) -> Expr:
        """`col("x") < <Expr>` (e.g. agg-fn result)."""
        return Expr.binary(BIN_LT, self._expr.copy(), other.copy())

    # --- __eq__ ---

    def __eq__(self, other: Int) -> Expr:
        return Expr.binary(BIN_EQ, self._expr.copy(), Expr.literal(ScalarValue.from_int(other)))

    def __eq__(self, other: Float64) -> Expr:
        return Expr.binary(BIN_EQ, self._expr.copy(), Expr.literal(ScalarValue.from_float(other)))

    def __eq__(self, other: String) -> Expr:
        return Expr.binary(BIN_EQ, self._expr.copy(), Expr.literal(ScalarValue.from_string(other)))

    def __eq__(self, other: ColExpr) -> Expr:
        return Expr.binary(BIN_EQ, self._expr.copy(), other._expr.copy())

    def __eq__(self, other: Expr) -> Expr:
        """Equality against an Expr (e.g.
        `col("x") == col("x").max()` where `.max()` returns Expr)."""
        return Expr.binary(BIN_EQ, self._expr.copy(), other.copy())

    # --- __ne__ ---

    def __ne__(self, other: Int) -> Expr:
        return Expr.binary(BIN_NE, self._expr.copy(), Expr.literal(ScalarValue.from_int(other)))

    def __ne__(self, other: Float64) -> Expr:
        return Expr.binary(BIN_NE, self._expr.copy(), Expr.literal(ScalarValue.from_float(other)))

    def __ne__(self, other: String) -> Expr:
        return Expr.binary(BIN_NE, self._expr.copy(), Expr.literal(ScalarValue.from_string(other)))

    def __ne__(self, other: ColExpr) -> Expr:
        return Expr.binary(BIN_NE, self._expr.copy(), other._expr.copy())

    def __ne__(self, other: Expr) -> Expr:
        """`col("x") != <Expr>`."""
        return Expr.binary(BIN_NE, self._expr.copy(), other.copy())

    # --- __ge__ ---

    def __ge__(self, other: Int) -> Expr:
        return Expr.binary(BIN_GE, self._expr.copy(), Expr.literal(ScalarValue.from_int(other)))

    def __ge__(self, other: Float64) -> Expr:
        return Expr.binary(BIN_GE, self._expr.copy(), Expr.literal(ScalarValue.from_float(other)))

    def __ge__(self, other: String) -> Expr:
        return Expr.binary(BIN_GE, self._expr.copy(), Expr.literal(ScalarValue.from_string(other)))

    def __ge__(self, other: ColExpr) -> Expr:
        return Expr.binary(BIN_GE, self._expr.copy(), other._expr.copy())

    def __ge__(self, other: Expr) -> Expr:
        """`col("x") >= <Expr>`."""
        return Expr.binary(BIN_GE, self._expr.copy(), other.copy())

    # --- __le__ ---

    def __le__(self, other: Int) -> Expr:
        return Expr.binary(BIN_LE, self._expr.copy(), Expr.literal(ScalarValue.from_int(other)))

    def __le__(self, other: Float64) -> Expr:
        return Expr.binary(BIN_LE, self._expr.copy(), Expr.literal(ScalarValue.from_float(other)))

    def __le__(self, other: String) -> Expr:
        return Expr.binary(BIN_LE, self._expr.copy(), Expr.literal(ScalarValue.from_string(other)))

    def __le__(self, other: ColExpr) -> Expr:
        return Expr.binary(BIN_LE, self._expr.copy(), other._expr.copy())

    def __le__(self, other: Expr) -> Expr:
        """`col("x") <= <Expr>`."""
        return Expr.binary(BIN_LE, self._expr.copy(), other.copy())

    # =========================================================================
    # Arithmetic operators — return ColExpr (chainable)
    # =========================================================================

    # --- __add__ ---

    def __add__(self, other: Int) -> ColExpr:
        return ColExpr(Expr.binary(BIN_ADD, self._expr.copy(), Expr.literal(ScalarValue.from_int(other))))

    def __add__(self, other: Float64) -> ColExpr:
        return ColExpr(Expr.binary(BIN_ADD, self._expr.copy(), Expr.literal(ScalarValue.from_float(other))))

    def __add__(self, other: ColExpr) -> ColExpr:
        return ColExpr(Expr.binary(BIN_ADD, self._expr.copy(), other._expr.copy()))

    # --- __sub__ ---

    def __sub__(self, other: Int) -> ColExpr:
        return ColExpr(Expr.binary(BIN_SUB, self._expr.copy(), Expr.literal(ScalarValue.from_int(other))))

    def __sub__(self, other: Float64) -> ColExpr:
        return ColExpr(Expr.binary(BIN_SUB, self._expr.copy(), Expr.literal(ScalarValue.from_float(other))))

    def __sub__(self, other: ColExpr) -> ColExpr:
        return ColExpr(Expr.binary(BIN_SUB, self._expr.copy(), other._expr.copy()))

    # --- __mul__ ---

    def __mul__(self, other: Int) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MUL, self._expr.copy(), Expr.literal(ScalarValue.from_int(other))))

    def __mul__(self, other: Float64) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MUL, self._expr.copy(), Expr.literal(ScalarValue.from_float(other))))

    def __mul__(self, other: ColExpr) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MUL, self._expr.copy(), other._expr.copy()))

    # --- __truediv__ / __floordiv__ — DuckDB's `/` and `//` --------------
    # `/` is TRUE division (`7 / 2 == 3.5`); `//` is DuckDB's integer division,
    # which TRUNCATES (`-7 // 2 == -3`) — NOT polars' floor. Both are decided in
    # `col_expr_division`, whose header carries the measured table. ⛔ A bare
    # `BIN_DIV` for `/` would make `col("i") / 2` over integers answer 3
    # where DuckDB, polars and pandas all answer 3.5.

    def __truediv__(self, other: Int) -> ColExpr:
        return ColExpr(true_divide(self._expr.copy(), Expr.literal(ScalarValue.from_int(other))))

    def __truediv__(self, other: Float64) -> ColExpr:
        return ColExpr(true_divide(self._expr.copy(), Expr.literal(ScalarValue.from_float(other))))

    def __truediv__(self, other: ColExpr) -> ColExpr:
        return ColExpr(true_divide(self._expr.copy(), other._expr.copy()))

    def __floordiv__(self, other: Int) -> ColExpr:
        return ColExpr(integer_divide(self._expr.copy(), Expr.literal(ScalarValue.from_int(other))))

    def __floordiv__(self, other: Float64) -> ColExpr:
        return ColExpr(integer_divide(self._expr.copy(), Expr.literal(ScalarValue.from_float(other))))

    def __floordiv__(self, other: ColExpr) -> ColExpr:
        return ColExpr(integer_divide(self._expr.copy(), other._expr.copy()))

    # --- __mod__ — DuckDB's `%`, which TRUNCATES --------------
    # `-7 % 2 == -1` on DuckDB v1.5.3 and here (`BIN_MOD`, the sign of the
    # dividend); `x % 0` is NULL. ⚠ NOT polars' `%`, which FLOORS (`-7 % 2 ==
    # 1`) — the same split as `//`, for the same reason: this door answers like
    # DuckDB. The two agree whenever the dividend is non-negative.

    def __mod__(self, other: Int) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MOD, self._expr.copy(), Expr.literal(ScalarValue.from_int(other))))

    def __mod__(self, other: Float64) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MOD, self._expr.copy(), Expr.literal(ScalarValue.from_float(other))))

    def __mod__(self, other: ColExpr) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MOD, self._expr.copy(), other._expr.copy()))

    def mod(self, other: Int) -> ColExpr:
        """polars' method spelling of `%` — with DuckDB's TRUNCATING meaning."""
        return self % other

    def mod(self, other: Float64) -> ColExpr:
        return self % other

    def mod(self, other: ColExpr) -> ColExpr:
        return self % other

    # --- pow / `**` — DuckDB's `pow`, a DOUBLE -----------------
    # `MATH2_POW`, the node the SQL binder builds for `pow` / `power` / `**`.
    # ⚠ DuckDB answers DOUBLE for `2 ** 3`; polars keeps an integer base's
    # dtype. This door answers like DuckDB.

    def pow(self, exponent: Int) -> ColExpr:
        return ColExpr(Expr.math_fn2(MATH2_POW, self._expr.copy(), Expr.literal(ScalarValue.from_int(exponent))))

    def pow(self, exponent: Float64) -> ColExpr:
        return ColExpr(Expr.math_fn2(MATH2_POW, self._expr.copy(), Expr.literal(ScalarValue.from_float(exponent))))

    def pow(self, exponent: ColExpr) -> ColExpr:
        return ColExpr(Expr.math_fn2(MATH2_POW, self._expr.copy(), exponent._expr.copy()))

    def __pow__(self, exponent: Int) -> ColExpr:
        return self.pow(exponent)

    def __pow__(self, exponent: Float64) -> ColExpr:
        return self.pow(exponent)

    def __pow__(self, exponent: ColExpr) -> ColExpr:
        return self.pow(exponent)

    # --- REFLECTED operators — the SCALAR on the LEFT ---------
    # `100 - col("v")`, `2.0 * col("x")`, `1 / col("v")`, `2 ** col("v")`:
    # Mojo tries `Int.__sub__(ColExpr)` first, finds none, and lands here. Each
    # builds EXACTLY the tree `lit(100) - col("v")` builds, literal on the
    # left — so TPC-H q1's `(1 - l_discount)` needs no `lit(...)`
    # wrapper. `/`, `//` and `%` keep their DuckDB meanings with the operands
    # swapped.

    def __radd__(self, other: Int) -> ColExpr:
        return ColExpr(Expr.binary(BIN_ADD, Expr.literal(ScalarValue.from_int(other)), self._expr.copy()))

    def __radd__(self, other: Float64) -> ColExpr:
        return ColExpr(Expr.binary(BIN_ADD, Expr.literal(ScalarValue.from_float(other)), self._expr.copy()))

    def __rsub__(self, other: Int) -> ColExpr:
        return ColExpr(Expr.binary(BIN_SUB, Expr.literal(ScalarValue.from_int(other)), self._expr.copy()))

    def __rsub__(self, other: Float64) -> ColExpr:
        return ColExpr(Expr.binary(BIN_SUB, Expr.literal(ScalarValue.from_float(other)), self._expr.copy()))

    def __rmul__(self, other: Int) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MUL, Expr.literal(ScalarValue.from_int(other)), self._expr.copy()))

    def __rmul__(self, other: Float64) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MUL, Expr.literal(ScalarValue.from_float(other)), self._expr.copy()))

    def __rtruediv__(self, other: Int) -> ColExpr:
        return ColExpr(true_divide(Expr.literal(ScalarValue.from_int(other)), self._expr.copy()))

    def __rtruediv__(self, other: Float64) -> ColExpr:
        return ColExpr(true_divide(Expr.literal(ScalarValue.from_float(other)), self._expr.copy()))

    def __rfloordiv__(self, other: Int) -> ColExpr:
        return ColExpr(integer_divide(Expr.literal(ScalarValue.from_int(other)), self._expr.copy()))

    def __rfloordiv__(self, other: Float64) -> ColExpr:
        return ColExpr(integer_divide(Expr.literal(ScalarValue.from_float(other)), self._expr.copy()))

    def __rmod__(self, other: Int) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MOD, Expr.literal(ScalarValue.from_int(other)), self._expr.copy()))

    def __rmod__(self, other: Float64) -> ColExpr:
        return ColExpr(Expr.binary(BIN_MOD, Expr.literal(ScalarValue.from_float(other)), self._expr.copy()))

    def __rpow__(self, base: Int) -> ColExpr:
        return ColExpr(Expr.math_fn2(MATH2_POW, Expr.literal(ScalarValue.from_int(base)), self._expr.copy()))

    def __rpow__(self, base: Float64) -> ColExpr:
        return ColExpr(Expr.math_fn2(MATH2_POW, Expr.literal(ScalarValue.from_float(base)), self._expr.copy()))

    # =========================================================================
    # Boolean combinators — return Expr (terminal)
    # =========================================================================

    def __and__(self, other: Expr) -> Expr:
        """Combine with AND. Used as: (col("x") > 5) & (col("y") < 10)."""
        return Expr.binary(BIN_AND, self._expr.copy(), other.copy())

    def __or__(self, other: Expr) -> Expr:
        """Combine with OR. Used as: (col("x") > 5) | (col("y") < 10)."""
        return Expr.binary(BIN_OR, self._expr.copy(), other.copy())

    # =========================================================================
    # Utility methods
    # =========================================================================

    @always_inline
    def alias(self, name: String) -> Expr:
        """Rename the output column."""
        return Expr.alias(self._expr.copy(), name)

    @always_inline
    def cast(self, target: DType) -> ColExpr:
        """Cast to a different type. Returns ColExpr for chaining."""
        return ColExpr(Expr.cast(self._expr.copy(), target))

    @always_inline
    def field(self, name: String) -> ColExpr:
        """Project a named
        sub-column out of a STRUCT-typed column.

        Example:
            col("addr").field("city")    # extracts the `city` child of `addr`

        The parent expression must evaluate to a STRUCT Column at runtime.
        Returns a ColExpr so that the result can be chained (e.g.
        `col("addr").field("city").alias("c")`). Field resolution is
        by-name at eval time (not resolved to a field index at plan time).
        """
        return ColExpr(Expr.struct_field(self._expr.copy(), name))

    @always_inline
    def get(self, key: ColExpr) -> ColExpr:
        """Project a MAP
        value by per-row key lookup.

        Example:
            col("metadata").get(lit("city"))         # constant key
            col("metadata").get(col("which_key"))    # per-row key column

        The parent expression must evaluate to a MAP Column at runtime;
        the key expression must produce a column of the Map's key type
        (per-row).  Returns a ColExpr so the result can be chained
        (e.g. `col("metadata").get(lit("city")).alias("c")`).

        Null propagation: parent-null row -> NULL output; key-not-found
        -> NULL output.
        """
        return ColExpr(Expr.map_get(self._expr.copy(), key._expr.copy()))

    @always_inline
    def is_null(self) -> Expr:
        """Check if the column value is NULL."""
        return Expr.unary(UN_IS_NULL, self._expr.copy())

    @always_inline
    def is_not_null(self) -> Expr:
        """Check if the column value is not NULL."""
        return Expr.unary(UN_IS_NOT_NULL, self._expr.copy())

    # --- fills, the NaN tests, is_between ----------------------
    # Trees from `scalar_desugar`, shared with the SQL binder's `coalesce` /
    # `isnan` / `isinf` / `isfinite` (one builder, two doors).

    def fill_null(self, value: Int) -> ColExpr:
        """`coalesce(self, value)` — polars `fill_null(value)`. See
        `_unify_case_args` for the literal's type."""
        return self._fill_null(Expr.literal(ScalarValue.from_int(value)))

    def fill_null(self, value: Float64) -> ColExpr:
        return self._fill_null(Expr.literal(ScalarValue.from_float(value)))

    def fill_null(self, value: String) -> ColExpr:
        return self._fill_null(Expr.literal(ScalarValue.from_string(value)))

    def fill_null(self, value: ColExpr) -> ColExpr:
        return self._fill_null(value._expr.copy())

    def _fill_null(self, var value: Expr) -> ColExpr:
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(value^)
        return ColExpr(coalesce_of(_unify_case_args(args^)))

    def fill_nan(self, value: Float64) -> ColExpr:
        """polars `fill_nan(value)`: a NaN becomes `value`, a NULL STAYS NULL,
        +-inf are kept. DuckDB has no `fill_nan`; see `fill_nan_of`."""
        return ColExpr(fill_nan_of(self._expr.copy(), Expr.literal(ScalarValue.from_float(value))))

    def fill_nan(self, value: ColExpr) -> ColExpr:
        return ColExpr(fill_nan_of(self._expr.copy(), value._expr.copy()))

    def is_nan(self) -> Expr:
        """DuckDB `isnan(x)`, polars `is_nan()`: TRUE for NaN only, NULL for
        NULL. Comparisons against +-inf, NOT `x <> x` (DuckDB orders NaN equal
        to itself) — see `float_class_of`."""
        return float_class_of(FLOAT_CLASS_NAN, self._expr.copy())

    def is_not_nan(self) -> Expr:
        """polars `is_not_nan()` = `NOT isnan(x)`: NULL stays NULL (Kleene)."""
        return Expr.unary(UN_NOT, float_class_of(FLOAT_CLASS_NAN, self._expr.copy()))

    def is_finite(self) -> Expr:
        """DuckDB `isfinite(x)`, polars `is_finite()`: FALSE for NaN / +-inf."""
        return float_class_of(FLOAT_CLASS_FINITE, self._expr.copy())

    def is_infinite(self) -> Expr:
        """DuckDB `isinf(x)`, polars `is_infinite()`: TRUE for +-inf only."""
        return float_class_of(FLOAT_CLASS_INFINITE, self._expr.copy())

    # ★ polars `is_in(values)` — SQL's
    # `x IN (v1, .., vN)`, built by `Expr.in_list`: the OR chain of `=` the SQL
    # parser desugars an IN list to, so a NULL `x` answers NULL (3VL) at both
    # doors. Empty list -> FALSE; more than 64 members RAISES (the factory's
    # limit). The static form is `Expr.in_list(expr, List[ScalarValue])`.
    def is_in(self, values: List[Int]) raises -> Expr:
        var sv = List[ScalarValue]()
        for i in range(len(values)):
            sv.append(ScalarValue.from_int(values[i]))
        return Expr.in_list(self._expr.copy(), sv^)

    def is_in(self, values: List[Float64]) raises -> Expr:
        var sv = List[ScalarValue]()
        for i in range(len(values)):
            sv.append(ScalarValue.from_float(values[i]))
        return Expr.in_list(self._expr.copy(), sv^)

    def is_in(self, values: List[String]) raises -> Expr:
        var sv = List[ScalarValue]()
        for i in range(len(values)):
            sv.append(ScalarValue.from_string(values[i]))
        return Expr.in_list(self._expr.copy(), sv^)

    def is_between(self, lower: Int, upper: Int, closed: String = "both") raises -> Expr:
        """polars `is_between(lower, upper, closed="both")`; `closed="both"` is
        SQL's `x BETWEEN lower AND upper`, the tree `sql_parser` builds
        (`x >= lower AND x <= upper`). `closed` is `both` / `left` / `right` /
        `none`, and anything else RAISES naming the four."""
        return between_of(
            self._expr.copy(), Expr.literal(ScalarValue.from_int(lower)),
            Expr.literal(ScalarValue.from_int(upper)), _between_closed(closed),
        )

    def is_between(self, lower: Float64, upper: Float64, closed: String = "both") raises -> Expr:
        return between_of(
            self._expr.copy(), Expr.literal(ScalarValue.from_float(lower)),
            Expr.literal(ScalarValue.from_float(upper)), _between_closed(closed),
        )

    def is_between(self, lower: String, upper: String, closed: String = "both") raises -> Expr:
        return between_of(
            self._expr.copy(), Expr.literal(ScalarValue.from_string(lower)),
            Expr.literal(ScalarValue.from_string(upper)), _between_closed(closed),
        )

    def is_between(self, lower: ColExpr, upper: ColExpr, closed: String = "both") raises -> Expr:
        return between_of(
            self._expr.copy(), lower._expr.copy(), upper._expr.copy(),
            _between_closed(closed),
        )

    def even(self) -> ColExpr:
        """DuckDB `even(x)`: round AWAY FROM ZERO to the next even integer, a
        DOUBLE (`even(1.0)` = 2, `even(-0.5)` = -2). Not banker's rounding."""
        return ColExpr(even_of(self._expr.copy()))

    @always_inline
    def abs(self) -> Expr:
        """`abs(col)` -> THE COLUMN'S OWN TYPE. See the free function `abs`."""
        return Expr.unary(UN_ABS, self._expr.copy())

    @always_inline
    def sign(self) -> Expr:
        """`sign(col)` -> INT8 (DuckDB TINYINT), whatever the column's type."""
        return Expr.unary(UN_SIGN, self._expr.copy())

    @always_inline
    def trunc(self) -> Expr:
        """`trunc(col)` -> THE COLUMN'S OWN TYPE. Round toward zero."""
        return Expr.unary(UN_TRUNC, self._expr.copy())

    @always_inline
    def round(self) -> Expr:
        """`round(col)` -> THE COLUMN'S OWN TYPE. Half away from zero."""
        return Expr.unary(UN_ROUND, self._expr.copy())

    # =========================================================================
    # Aggregate-as-expression in filter context
    # =========================================================================
    #
    # User-facing factories for `EXPR_AGG_FN` (tag 12). Only meaningful
    # inside `.filter(...)` / `.having(...)` after a `.group_by(...).agg(...)`.
    # The optimizer's `optimizer_scalar_broadcast` rule detects
    # `Filter(<predicate referencing col.agg()>)` over `Aggregate(group_by)`
    # and rewrites by eagerly executing the inner Aggregate sub-plan,
    # extracting the scalar via the agg-fn applied to the materialized
    # batch, and substituting `Expr.literal(scalar_value)` for this
    # `EXPR_AGG_FN` node in the outer filter.
    #
    # Outside that context (in `.with_column(...)` or `.agg(...)` itself),
    # use the existing `agg.max(col("x"))` factory from `agg_expr.mojo`.
    #
    # Hardcoded AGG_* constants (mirror of `agg_expr.mojo`) to avoid a
    # circular import — agg_expr depends on col_expr, so col_expr cannot
    # depend on agg_expr. The values are comptime UInt8 constants that
    # change only in a coordinated refactor; keeping them in sync here is
    # mechanical.

    @always_inline
    def max(self) -> Expr:
        """Aggregate-as-expression: max of this column over the whole input.

        Returns an Expr (not ColExpr) because the result is terminal —
        used inside a filter predicate. Optimizer-consumed at
        plan-compile time.
        """
        # AGG_MAX = 3 (mirrors agg_expr.mojo)
        return Expr.agg_fn(UInt8(3), self._expr.copy())

    @always_inline
    def min(self) -> Expr:
        """Aggregate-as-expression: min of this column over the whole input."""
        # AGG_MIN = 2
        return Expr.agg_fn(UInt8(2), self._expr.copy())

    @always_inline
    def sum(self) -> Expr:
        """Aggregate-as-expression: sum of this column over the whole input."""
        # AGG_SUM = 0
        return Expr.agg_fn(UInt8(0), self._expr.copy())

    @always_inline
    def avg(self) -> Expr:
        """Aggregate-as-expression: mean of this column over the whole input."""
        # AGG_MEAN = 4
        return Expr.agg_fn(UInt8(4), self._expr.copy())

    def name(self) -> ColExprNames:
        """polars' `.name` namespace — `col("v").name().suffix("_x")` is
        `v AS v_x`. See `col_expr_name`."""
        return ColExprNames(self._expr.copy())

    @always_inline
    def mean(self) -> Expr:
        """polars' name for `avg()` (AGG_MEAN). ★ Its reason to exist is the
        GROUP BROADCAST `col("v").mean().over("g")` — SQL `avg(v) OVER
        (PARTITION BY g)`, see `Expr.with_window_spec`."""
        return Expr.agg_fn(UInt8(4), self._expr.copy())

    @always_inline
    def count(self) -> Expr:
        """Aggregate-as-expression: count of this column over the whole input."""
        # AGG_COUNT = 1
        return Expr.agg_fn(UInt8(1), self._expr.copy())

    # =========================================================================
    # Window-fn-as-expression factories
    # =========================================================================
    #
    # Polars-shape API: `col("x").rank().over("g")`,
    # `col("x").rolling_mean(7).over("g", order_by=["ts"])`, etc.
    # Each factory below produces an `EXPR_WINDOW_FN` Expr (terminal --
    # `.over(...)` chains on the returned Expr). The lowering happens
    # via `dataframe.with_column(...)` which detects the window-fn tag
    # and emits a PARTITION_BY plan node directly.
    #
    # `_col_name(self)` extracts the wrapped column name for value-fn
    # factories (lag/lead/cum_*/rolling_*/first_value/...). Ranking
    # factories (rank/row_number/dense_rank/percent_rank/cume_dist/ntile)
    # use empty string -- the SQL `RANK()` etc. take no column arg.
    # =========================================================================

    @always_inline
    def _col_name(self) raises -> String:
        """Extract column name when self wraps EXPR_COL_REF; raise otherwise."""
        if not self._expr.is_col_ref():
            raise Error(
                "ColExpr window-fn factory requires the receiver to be a"
                " plain `col(name)` reference; complex expressions are"
                " not yet supported."
            )
        return self._expr.col_ref_name()

    # --- Ranking (no input column required) -------------------------------

    @always_inline
    def rank(self) -> Expr:
        """SQL `RANK()` window function.

        Chain `.over(partition_by[, order_by])` to bind the window, then
        `.alias(...)` and feed to `.with_column(...)`. Note: the untyped
        fluent `.over()` surface is plan-shape verified (the PARTITION_BY node
        is emitted and fused correctly); value oracles live in the typed-row
        window tests.

        Examples:
            ```mojo
            from komira_sdk import col
            # dense per-group ranking, added as a new column
            var out = ctx.materialize(
                df^.with_column(col("v").rank().over("g").alias("rk"))^
            )
            ```
        """
        return Expr.window_fn(PF_RANK, String(""), 0, PartitionFrame.default_ordered())

    @always_inline
    def row_number(self) -> Expr:
        """SQL `ROW_NUMBER()` window function.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(
                df^.with_column(col("v").row_number().over("g").alias("rn"))^
            )
            ```
        """
        return Expr.window_fn(PF_ROW_NUMBER, String(""), 0, PartitionFrame.default_ordered())

    @always_inline
    def dense_rank(self) -> Expr:
        """SQL `DENSE_RANK()` window function.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(
                df^.with_column(col("v").dense_rank().over("g").alias("dr"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_DENSE_RANK, String(""), 0, PartitionFrame.default_ordered())

    @always_inline
    def percent_rank(self) -> Expr:
        """SQL `PERCENT_RANK()` window function.

        Examples:
            ```mojo
            from komira_sdk import col
            # rank in [0, 1]: (rank - 1) / (rows_in_partition - 1)
            var out = ctx.materialize(
                df^.with_column(col("v").percent_rank().over("g").alias("pr"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_PERCENT_RANK, String(""), 0, PartitionFrame.default_ordered())

    @always_inline
    def cume_dist(self) -> Expr:
        """SQL `CUME_DIST()` window function.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(
                df^.with_column(col("v").cume_dist().over("g").alias("cd"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_CUME_DIST, String(""), 0, PartitionFrame.default_ordered())

    @always_inline
    def ntile(self, buckets: Int) -> Expr:
        """SQL `NTILE(buckets)` window function — split each partition into
        `buckets` roughly-equal groups, numbered 1..buckets.

        Examples:
            ```mojo
            from komira_sdk import col
            # quartile label per group
            var out = ctx.materialize(
                df^.with_column(col("v").ntile(4).over("g").alias("quartile"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_NTILE, String(""), buckets, PartitionFrame.default_ordered())

    # --- Offset (LAG / LEAD / SHIFT) --------------------------------------

    def lag(self, offset: Int = 1) raises -> Expr:
        """SQL `LAG(col, offset)` -- value of `col` `offset` rows before
        the current row, in order_by sort order.

        The receiver must be a plain `col(name)` reference. Bind ordering
        with `.over(partition_by, order_by)` so the offset is well-defined.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["user_id"]
            var ok: List[String] = ["ts"]
            # previous reading per user, in timestamp order
            var out = ctx.materialize(
                df^.with_column(col("value").lag().over(pk^, ok^).alias("prev"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_LAG, self._col_name(), offset, PartitionFrame.default_ordered())

    def lead(self, offset: Int = 1) raises -> Expr:
        """SQL `LEAD(col, offset)` -- value of `col` `offset` rows after
        the current row.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["user_id"]
            var ok: List[String] = ["ts"]
            var out = ctx.materialize(
                df^.with_column(col("value").lead(1).over(pk^, ok^).alias("next"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_LEAD, self._col_name(), offset, PartitionFrame.default_ordered())

    def shift(self, offset: Int) raises -> Expr:
        """Polars `shift(n)`: positive = LAG, negative = LEAD.

        `shift(1)` = LAG(1); `shift(-1)` = LEAD(1).

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            # shift(1) == lag(1): the prior row's value
            var out = ctx.materialize(
                df^.with_column(col("v").shift(1).over(pk^, ok^).alias("prev"))^
            )
            ```
        (example not yet doctest-verified)
        """
        if offset >= 0:
            return Expr.window_fn(PF_LAG, self._col_name(), offset, PartitionFrame.default_ordered())
        else:
            return Expr.window_fn(PF_LEAD, self._col_name(), -offset, PartitionFrame.default_ordered())

    # --- First / last / nth value -----------------------------------------

    def first_value(self) raises -> Expr:
        """SQL `FIRST_VALUE(col)` over the (partition+order) frame.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            # first value in each group, broadcast to every row
            var out = ctx.materialize(
                df^.with_column(col("v").first_value().over(pk^, ok^).alias("f"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_FIRST_VALUE, self._col_name(), 0, PartitionFrame.running_range())

    def last_value(self) raises -> Expr:
        """SQL `LAST_VALUE(col)` over the (partition+order) frame.

        ⚠ SQL'S DEFAULT FRAME, AND THEREFORE NOT POLARS' `last().over(...)`.
        With an ORDER BY the frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND
        CURRENT ROW`, so each row answers its own last PEER (the current row
        when the order key does not tie) -- DuckDB v1.5.3's answer, which this
        door follows. polars' `last().over(g)` and pandas'
        `groupby().transform('last')` are WHOLE-group; the whole partition is
        what this answers only when `.over(pk, [])` has no order keys.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            var out = ctx.materialize(
                df^.with_column(col("v").last_value().over(pk^, ok^).alias("l"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_LAST_VALUE, self._col_name(), 0, PartitionFrame.running_range())

    def nth_value(self, n: Int) raises -> Expr:
        """SQL `NTH_VALUE(col, n)` over the (partition+order) frame.

        ⚠ SQL'S DEFAULT FRAME: with an ORDER BY a row sees the partition only
        up to its last PEER, so the rows before the n-th answer NULL (DuckDB
        v1.5.3). NULL too when the frame is shorter than n, or n < 1. Not
        polars' `get(n).over(g)`, which is whole-group.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            # the 2nd value (1-based) in each ordered group
            var out = ctx.materialize(
                df^.with_column(col("v").nth_value(2).over(pk^, ok^).alias("n2"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_NTH_VALUE, self._col_name(), n, PartitionFrame.running_range())

    # --- Cumulative (running aggregate; default_ordered frame) ------------

    def cum_sum(self) raises -> Expr:
        """Polars `cum_sum()` -- running sum (SUM OVER ROWS UNBOUNDED PRECEDING TO CURRENT ROW).

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["user_id"]
            var ok: List[String] = ["ts"]
            # running total per user, in time order
            var out = ctx.materialize(
                df^.with_column(col("value").cum_sum().over(pk^, ok^).alias("running"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_SUM, self._col_name(), 0, PartitionFrame.default_ordered())

    def cum_max(self) raises -> Expr:
        """Polars `cum_max()` -- running max.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            var out = ctx.materialize(
                df^.with_column(col("v").cum_max().over(pk^, ok^).alias("hwm"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_MAX, self._col_name(), 0, PartitionFrame.default_ordered())

    def cum_min(self) raises -> Expr:
        """Polars `cum_min()` -- running min.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            var out = ctx.materialize(
                df^.with_column(col("v").cum_min().over(pk^, ok^).alias("lwm"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_MIN, self._col_name(), 0, PartitionFrame.default_ordered())

    def cum_count(self) raises -> Expr:
        """Polars `cum_count()` -- running count of non-null values.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            var out = ctx.materialize(
                df^.with_column(col("v").cum_count().over(pk^, ok^).alias("seen"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_COUNT, self._col_name(), 0, PartitionFrame.default_ordered())

    # --- Rolling (sliding-frame; ROWS BETWEEN N-1 PRECEDING AND CURRENT ROW)

    def _rolling_frame(self, n: Int) -> PartitionFrame:
        """Polars-style ROLLING(N): ROWS BETWEEN N-1 PRECEDING AND CURRENT ROW."""
        return PartitionFrame(
            FRAME_UNITS_ROWS,
            FRAME_BOUND_PRECEDING, Int64(n - 1),
            FRAME_BOUND_CURRENT_ROW, 0,
        )

    def rolling_sum(self, n: Int) raises -> Expr:
        """Polars `rolling_sum(N)` -- sliding-window sum over the prior N rows
        (inclusive of current row).

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["user_id"]
            var ok: List[String] = ["ts"]
            var out = ctx.materialize(
                df^.with_column(col("value").rolling_sum(7).over(pk^, ok^).alias("sum7"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_SUM, self._col_name(), n, self._rolling_frame(n))

    def rolling_mean(self, n: Int) raises -> Expr:
        """Polars `rolling_mean(N)` -- sliding-window mean.

        Examples:
            ```mojo
            from komira_sdk import col, read, local_parquet_source
            var pk: List[String] = ["user_id"]
            var ok: List[String] = ["ts"]
            var sk: List[String] = ["user_id", "ts"]
            var sd: List[Bool] = [False, False]
            var df = read(ctx, local_parquet_source("win_timeseries.parquet"))
            # 7-row trailing average per user, sorted for a stable read-out
            var rb = ctx.materialize(
                df^.with_column(
                    col("value").rolling_mean(7).over(pk^, ok^).alias("rolling_mean_7")
                )^.sort_multi(sk^, sd^)^
            )
            ```
        """
        return Expr.window_fn(PF_AVG, self._col_name(), n, self._rolling_frame(n))

    def rolling_min(self, n: Int) raises -> Expr:
        """Polars `rolling_min(N)` -- sliding-window min.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            var out = ctx.materialize(
                df^.with_column(col("v").rolling_min(3).over(pk^, ok^).alias("min3"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_MIN, self._col_name(), n, self._rolling_frame(n))

    def rolling_max(self, n: Int) raises -> Expr:
        """Polars `rolling_max(N)` -- sliding-window max.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            var out = ctx.materialize(
                df^.with_column(col("v").rolling_max(3).over(pk^, ok^).alias("max3"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.window_fn(PF_MAX, self._col_name(), n, self._rolling_frame(n))

    # =========================================================================
    # String operations — return Expr (terminal, used in filter predicates)
    # =========================================================================

    @always_inline
    def contains(self, pattern: String) -> Expr:
        """Check if the string column contains the given substring.

        Type safety: if the column isn't String type, this raises an error
        at plan validation time (with schema) or execution time (without).
        No .str namespace needed — the method is directly on ColExpr.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.filter(col("name").contains("alice"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.string_op(STR_CONTAINS, self._expr.copy(), pattern)

    @always_inline
    def upper(self) -> Expr:
        """`upper(col)` — upper-case of a string column -> a string column.

        This is THE reason the builtin exists: a
        case-insensitive match needs no callback, no UDF and no GIL —
        `col("name").upper() == "ACME"` is one columnar node.

        ⭐ FULL UNICODE, exact against DuckDB v1.5.3 on every codepoint
        (`upper('héllo')` = `'HÉLLO'`, not an ASCII-only `'HéLLO'`). NULL in
        -> NULL out.

        ⚠ SIMPLE case mapping, so `upper('straße')` is `'STRAẞE'` and not
        `'STRASSE'`, and it is NOT an inverse of `.lower()` — see `STRFN_UPPER`
        / `STRFN_LOWER` in `expr.mojo` for the round-trip trap.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.filter(col("name").upper() == "ALICE")^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.string_fn(STRFN_UPPER, self._expr.copy())

    # The rest of the unary string family.
    # Each is one `EXPR_STRING_FN` node, evaluated columnar: no callback, no
    # UDF, no GIL. What each one PROMISES is stated on its `STRFN_*` constant
    # in `expr.mojo`, measured against DuckDB v1.5.3; the short forms here do
    # not restate it, except where the surprise is the point.

    @always_inline
    def lower(self) -> Expr:
        """`lower(col)` — lower-case of a string column -> a string column.

        ⭐ FULL UNICODE, the mirror of `.upper()`: exact against DuckDB v1.5.3
        on every codepoint (`lower('HÉLLO')` = `'héllo'`, not an ASCII-only
        `'hÉllo'`). NULL in -> NULL out.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.filter(col("name").lower() == "alice")^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.string_fn(STRFN_LOWER, self._expr.copy())

    @always_inline
    def trim(self) -> Expr:
        """`trim(col)` — strip leading AND trailing SPACES -> a string column.

        ⛔ SPACES (0x20), NOT "whitespace". DuckDB v1.5.3's one-argument `trim`
        leaves tabs and newlines in place (measured), and this matches it. The
        two-argument `trim(s, chars)` is a different function and is not this.

        Examples:
            ```mojo
            from komira_sdk import col
            # the CSV-ingest shape: a join key that silently misses on padding
            var out = ctx.materialize(df^.with_column(col("k").trim().alias("k"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.string_fn(STRFN_TRIM, self._expr.copy())

    @always_inline
    def ltrim(self) -> Expr:
        """`ltrim(col)` — strip LEADING spaces. Space-only; see `.trim()`."""
        return Expr.string_fn(STRFN_LTRIM, self._expr.copy())

    @always_inline
    def rtrim(self) -> Expr:
        """`rtrim(col)` — strip TRAILING spaces. Space-only; see `.trim()`."""
        return Expr.string_fn(STRFN_RTRIM, self._expr.copy())

    @always_inline
    def length(self) -> Expr:
        """`length(col)` — the CHARACTER count -> an INT64 column.

        ⛔ CHARACTERS, NOT BYTES: `length('héllo')` is 5, matching DuckDB
        v1.5.3's `length` (its `strlen`, which is 6, is a different function
        this surface does not expose). NULL in -> NULL out.

        ⚠ THE ONLY MEMBER OF THIS FAMILY THAT IS NOT A STRING COLUMN, which is
        why the family's output type is answered per-op by
        `expr.string_fn_returns_int` rather than per-tag.
        """
        return Expr.string_fn(STRFN_LENGTH, self._expr.copy())

    @always_inline
    def reverse(self) -> Expr:
        """`reverse(col)` — reverse CODEPOINT order -> a string column.

        ⛔ CODEPOINTS, NOT BYTES: `reverse('héllo')` is `olléh` with `é`'s two
        bytes still in order. A byte reverse would emit invalid UTF-8.
        """
        return Expr.string_fn(STRFN_REVERSE, self._expr.copy())

    # -- the STRING -> INT bucket -----------
    #
    # ⛔ THREE LENGTH-SHAPED NAMES, THREE DIFFERENT ANSWERS, ALL EQUAL ON
    # ASCII. `length('héllo')` = 5 (characters), `.strlen()` = 6 (bytes),
    # `.bit_length()` = 48 (bytes * 8). Reach for the one you mean by what it
    # counts, not by which reads best.

    @always_inline
    def ascii(self) -> Expr:
        """`ascii(col)` — the CODEPOINT of the first character -> INT64.

        ⛔ A CODEPOINT DESPITE THE NAME: `ascii('é')` is 233 and `ascii('😀')`
        is 128512, matching DuckDB v1.5.3. `ascii('')` is **0**.

        ⚠ `.unicode()` IS THE SAME NUMBER EXCEPT ON THE EMPTY STRING, where it
        answers -1. That single row is the whole difference between them.
        """
        return Expr.string_fn(STRFN_ASCII, self._expr.copy())

    @always_inline
    def unicode(self) -> Expr:
        """`unicode(col)` / SQL `ord(col)` — first CODEPOINT -> INT64.

        `unicode('')` is **-1** where `.ascii()` answers 0; on every non-empty
        input the two agree. Both measured against DuckDB v1.5.3.
        """
        return Expr.string_fn(STRFN_UNICODE, self._expr.copy())

    @always_inline
    def strlen(self) -> Expr:
        """`strlen(col)` — the UTF-8 BYTE count -> INT64.

        ⛔ NOT `.length()`, WHICH COUNTS CHARACTERS. `strlen('héllo')` = 6 and
        `length('héllo')` = 5; `strlen('😀')` = 4 and `length('😀')` = 1.
        """
        return Expr.string_fn(STRFN_STRLEN, self._expr.copy())

    @always_inline
    def bit_length(self) -> Expr:
        """`bit_length(col)` — the UTF-8 byte count times eight -> INT64.

        Exactly `8 * strlen(col)` for a string column; `bit_length('héllo')` =
        48. (DuckDB's `octet_length` has NO VARCHAR overload — it is declared
        over BIT and BLOB and `octet_length('abc'::BLOB)` = 3, so it is a
        missing OVERLOAD there, not a missing function. `strlen` is the byte
        count for a VARCHAR.)
        """
        return Expr.string_fn(STRFN_BIT_LENGTH, self._expr.copy())

    # -- the BYTE-TRANSFORM members -----------
    #
    # ⭐ THE ONLY STRING MEMBERS ON THIS DOOR THAT ARE EXACT AGAINST DuckDB ON
    # NON-ASCII INPUT. `.upper()` / `.lower()` / `.reverse()` above each carry
    # a stated Unicode divergence; these five are defined on the UTF-8 BYTES in
    # DuckDB too, so there is nothing to diverge about.

    @always_inline
    def hex(self) -> Expr:
        """`hex(col)` / SQL `to_hex(col)` — two UPPERCASE hex digits per byte.

        `hex('abc')` = `'616263'`, `hex('é')` = `'C3A9'` (the two UTF-8 bytes),
        `hex('')` = `''`.

        ⛔ THE INTEGER OVERLOAD IS A DIFFERENT FUNCTION AND IS NOT THIS ONE:
        `to_hex(255)` is `'FF'` in DuckDB while `hex('255')` is `'323535'`.
        This reads a STRING column.

        ⚠ UPPERCASE. `md5`/`sha256` emit LOWERCASE hex in the same engine, so
        the case is per-function and not a house style.
        """
        return Expr.string_fn(STRFN_HEX, self._expr.copy())

    @always_inline
    def bin(self) -> Expr:
        """`bin(col)` — EIGHT binary digits per UTF-8 byte, no separator.

        `bin('abc')` = `'011000010110001001100011'` — 24 digits for 3 bytes,
        so the leading zero of `a` (0x61) is KEPT.

        ⛔ DuckDB's INTEGER overload DOES strip leading zeros (`bin(5)` =
        `'101'`) and is not this function.
        """
        return Expr.string_fn(STRFN_BIN, self._expr.copy())

    @always_inline
    def url_encode(self) -> Expr:
        """`url_encode(col)` — RFC 3986 percent-encoding, UPPERCASE hex.

        Unreserved set is exactly `A-Z a-z 0-9 - . _ ~` (derived by measuring
        every printable ASCII byte through DuckDB v1.5.3). A space is `%20`
        and `+` is itself encoded as `%2B` — URI encoding, not form encoding.
        """
        return Expr.string_fn(STRFN_URL_ENCODE, self._expr.copy())

    @always_inline
    def url_decode(self) -> Expr:
        """`url_decode(col)` — decode `%XX`, everything else verbatim.

        ⛔ `+` IS NOT A SPACE (`url_decode('a+b')` = `'a+b'`), a MALFORMED
        escape is left alone rather than raising (`'a%zz'`, `'a%2'`, `'100%'`),
        and an escape that decodes to INVALID UTF-8 RAISES at execution — all
        three measured on DuckDB v1.5.3 and all three implemented.
        """
        return Expr.string_fn(STRFN_URL_DECODE, self._expr.copy())

    @always_inline
    def regexp_escape(self) -> Expr:
        """`regexp_escape(col)` — RE2 `QuoteMeta`.

        ⚠ ESCAPES EVERYTHING THAT IS NOT `[A-Za-z0-9_]`, not just the
        metacharacters — space, `/`, `:`, `@`, `-` and the C0 controls all come
        back backslash-prefixed (measured over bytes 1..127). Bytes >= 0x80 are
        left verbatim.

        ⛔ IT IS A UNARY STRING TRANSFORM, NOT A MEMBER OF THE `.regexp_*()`
        FAMILY: it compiles no pattern and takes no flags.
        """
        return Expr.string_fn(STRFN_REGEXP_ESCAPE, self._expr.copy())

    # -- the three cryptographic-digest members ------
    #
    # ⛔ ALL THREE RETURN LOWERCASE HEX, where `.hex()` on this same object is
    # UPPERCASE. They are neighbours in the eval ladder and share nothing else.

    @always_inline
    def md5(self) -> Expr:
        """`md5(col)` — RFC 1321, lowercase hex, 32 characters.

        ⛔ OVER THE UTF-8 BYTES, NOT THE CODEPOINTS: `md5('é')` is the digest
        of the two bytes C3 A9 (measured '66ddcd97cfdeabb2f6fb8a999b4bc76f' on
        DuckDB v1.5.3).
        """
        return Expr.string_fn(STRFN_MD5, self._expr.copy())

    @always_inline
    def sha1(self) -> Expr:
        """`sha1(col)` — RFC 3174, lowercase hex, 40 characters."""
        return Expr.string_fn(STRFN_SHA1, self._expr.copy())

    @always_inline
    def sha256(self) -> Expr:
        """`sha256(col)` — FIPS 180-2, lowercase hex, 64 characters."""
        return Expr.string_fn(STRFN_SHA256, self._expr.copy())

    # -- the MULTI-ARGUMENT string family ------
    #
    # ⚠ EVERY ARGUMENT IS AN `Expr`, INCLUDING THE COUNTS. `lit(3)` is as legal
    # as `col("width")`, which is what DuckDB does too — `lpad(s, n, p)`'s `n`
    # is an ordinary INTEGER expression there, not a constant. A `count: Int`
    # parameter would have read more nicely and would have made the column form
    # inexpressible from this door.

    @always_inline
    def concat(self, var other: Expr) -> Expr:
        """`concat(col, other)` — string concatenation.

        ⛔ NULL ARGUMENTS ARE SKIPPED, NOT PROPAGATED, matching DuckDB v1.5.3's
        `concat` — `concat('a', NULL)` is `'a'` and `concat(NULL, NULL)` is the
        EMPTY STRING. ⚠ THAT IS **NOT** SQL `||`, which IS null-propagating;
        this engine has no `||` at all, so there is nothing here to confuse it
        with, but a reader arriving from SQL will expect the other rule.

        ⚠ TWO OPERANDS ONLY, FROM THIS DOOR. The node itself is variadic
        (`Expr.concat(args)` takes any number); a fluent method has one
        receiver and one argument, and chaining `.concat(a).concat(b)` nests
        rather than flattening — which is CORRECT here precisely because
        `concat` is associative and null-skipping, so the nested form and the
        flat form agree on every input.
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(other^)
        return Expr.string_fn_n(STRFNN_CONCAT, args^)

    @always_inline
    def replace(self, var source: Expr, var target: Expr) -> Expr:
        """`replace(col, source, target)` — non-overlapping, left to right.

        ⚠ NOT `regexp_replace`, which is a DIFFERENT method on this type and a
        different IR tag: `source` here is a LITERAL SUBSTRING, never a
        pattern. `replace('a.c', '.', 'X')` is `'aXc'`; the regexp form would
        be `'XXX'`.

        NULL in ANY of the three -> NULL out. An empty `source` matches nothing
        and returns the input unchanged (measured against DuckDB v1.5.3).
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(source^)
        args.append(target^)
        return Expr.string_fn_n(STRFNN_REPLACE, args^)

    @always_inline
    def lpad(self, var count: Expr, var pad: Expr) -> Expr:
        """`lpad(col, count, pad)` — pad on the LEFT to `count` CHARACTERS.

        ⚠ IT ALSO TRUNCATES: `count` below the input's length yields the FIRST
        `count` characters. `count <= 0` yields the empty string.

        ⛔ AN EMPTY `pad` RAISES AT EXECUTION when padding is actually needed —
        `Insufficient padding in LPAD.`, DuckDB's own message — and does NOT
        pass the value through. It does not raise when no padding is needed.
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(count^)
        args.append(pad^)
        return Expr.string_fn_n(STRFNN_LPAD, args^)

    @always_inline
    def rpad(self, var count: Expr, var pad: Expr) -> Expr:
        """`rpad(col, count, pad)` — the right-hand twin of `.lpad()`.

        ⚠ TRUNCATION TAKES THE **FIRST** `count` CHARACTERS FOR BOTH, which is
        the surprise: `rpad('abc', 2, 'x')` is `'ab'`, not `'bc'`. Measured
        against DuckDB v1.5.3.
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(count^)
        args.append(pad^)
        return Expr.string_fn_n(STRFNN_RPAD, args^)

    @always_inline
    def repeat(self, var count: Expr) -> Expr:
        """`repeat(col, count)` — `count <= 0` yields the empty string.

        ⚠ THE OUTPUT SIZE IS SET BY DATA, not by the plan, so the kernel
        REFUSES a per-row result over `STRING_FN_N_REPEAT_MAX_BYTES` rather
        than attempting the allocation. It is a refusal, never a silent clamp.
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(count^)
        return Expr.string_fn_n(STRFNN_REPEAT, args^)

    @always_inline
    def strpos(self, var needle: Expr) -> Expr:
        """`strpos(col, needle)` — 1-based CHARACTER position, 0 if absent.

        ⛔ A POSITION, NOT AN INDEX, and ⛔ CHARACTERS, NOT BYTES:
        `strpos('Straße','e')` is 6 where the byte offset is 7. An empty needle
        is found at 1. NULL in either -> NULL out. Aliased `instr`/`position`
        at the SQL door; INT64-returning, the only member of this family that
        is.
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(needle^)
        return Expr.string_fn_n(STRFNN_STRPOS, args^)

    # -- translate -----------------------------------------

    @always_inline
    def translate(self, var from_set: Expr, var to_set: Expr) -> Expr:
        """`translate(col, from, to)` — per-CHARACTER substitution.

        ⛔ CHARACTERS, NOT BYTES — the only member of this family that is.
        `translate('héllo','é','e')` = 'hello' (measured, DuckDB v1.5.3).
        A shorter `to` DELETES rather than pads, and a duplicate in `from`
        takes the first mapping.
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(from_set^)
        args.append(to_set^)
        return Expr.string_fn_n(STRFNN_TRANSLATE, args^)

    # -- the EDIT-DISTANCE family ----------
    #
    # ⛔ ALL THREE COMPARE **BYTES**, NOT CHARACTERS, MEASURED against DuckDB
    # v1.5.3: `levenshtein('é','')` = 2 and `hamming('é','e')` RAISES
    # "unequal length" even though both operands are one character. That is
    # DuckDB's behaviour, not a shortcut taken here.

    @always_inline
    def levenshtein(self, var other: Expr) -> Expr:
        """`levenshtein(col, other)` — BYTE edit distance -> an INT64 column.

        ⛔ NO TRANSPOSITION: `levenshtein('ab','ba')` = 2. Use
        `.damerau_levenshtein()` for the variant that counts a swap as one
        edit. SQL alias `editdist3`. NULL in either -> NULL out; empty strings
        are legal and answer the other operand's byte length.
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(other^)
        return Expr.string_fn_n(STRFNN_LEVENSHTEIN, args^)

    @always_inline
    def damerau_levenshtein(self, var other: Expr) -> Expr:
        """`damerau_levenshtein(col, other)` — UNRESTRICTED Damerau-Levenshtein
        over BYTES -> an INT64 column.

        ⛔ THE UNRESTRICTED VARIANT, NOT THE OPTIMAL STRING ALIGNMENT ONE that
        most libraries ship under this name. MEASURED on DuckDB v1.5.3:
        `damerau_levenshtein('ca','abc')` = 2, where OSA answers 3. The two
        agree on `('ab','ba')` = 1 and on most short inputs.
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(other^)
        return Expr.string_fn_n(STRFNN_DAMERAU_LEVENSHTEIN, args^)

    @always_inline
    def hamming(self, var other: Expr) -> Expr:
        """`hamming(col, other)` — differing BYTE positions -> an INT64 column.

        ⛔ RAISES rather than answering, on TWO inputs the rest of this family
        accepts and DuckDB v1.5.3 also rejects: UNEQUAL LENGTHS, and TWO EMPTY
        STRINGS. `levenshtein('','')` is 0; `hamming('','')` is an error.
        SQL alias `mismatches`. NULL in either -> NULL out, unchecked.
        """
        var args = List[Expr]()
        args.append(self._expr.copy())
        args.append(other^)
        return Expr.string_fn_n(STRFNN_HAMMING, args^)

    @always_inline
    def starts_with(self, prefix: String) -> Expr:
        """Check if the string column starts with the given prefix.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.filter(col("name").starts_with("Al"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.string_op(STR_STARTS_WITH, self._expr.copy(), prefix)

    @always_inline
    def ends_with(self, suffix: String) -> Expr:
        """Check if the string column ends with the given suffix.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.filter(col("name").ends_with("son"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.string_op(STR_ENDS_WITH, self._expr.copy(), suffix)

    @always_inline
    def like(self, pattern: String) -> Expr:
        """SQL LIKE pattern matching. % = any chars, _ = one char.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.filter(col("name").like("%ali%"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.string_op(STR_LIKE, self._expr.copy(), pattern)

    # =========================================================================
    # Regular-expression operations. Each method builds an `EXPR_REGEXP` node (the
    # engine carries a pure-Mojo Thompson-NFA matcher — see
    # `komira_column_kernels/regexp_nfa.mojo`). Dialect: POSIX ERE + the
    # RE2/`regex`-crate Perl-ish subset (linear-time; no pattern backrefs, no
    # lookaround). `flags` is the RE2 flags string: `i` (case-insensitive),
    # `g` (replace-all — `regexp_replace` only), `m` (multiline anchors),
    # `s` (dotall), `x` (extended/verbose); inline `(?i)` etc. also work.
    #
    # The SQL `~` / `!~` / `~*` operators are NOT exposed as Mojo binary
    # operators — Mojo has no binary `~` dunder (`__invert__` is unary `~x`).
    # The method form is the surface: `s ~ p` == `col("s").regexp_like(p)`,
    # `s !~ p` == `~col("s").regexp_like(p)` (which doesn't compose either —
    # use `(col("s").regexp_like(p)) == False`, or build it explicitly), and
    # `s ~* p` == `col("s").regexp_like(p, "i")`. A SQL frontend would lower
    # the operators to these methods.
    # =========================================================================

    @always_inline
    def regexp_like(self, pattern: String, flags: String = "") -> Expr:
        """`regexp_like(s, pattern[, flags])` -> Bool. True if `pattern` matches
        anywhere in the string (UNANCHORED — PG/DuckDB-compatible). The
        lowering target for the SQL `~` operator.

        Examples:
            ```mojo
            from komira_sdk import col
            # keep rows whose s starts with a or b
            var out = ctx.materialize(df^.filter(col("s").regexp_like("^[ab]"))^)
            # case-insensitive: matches "ABC" too
            var ci = ctx.materialize(df2^.filter(col("s").regexp_like("abc", "i"))^)
            ```
        """
        return Expr.regexp_like(self._expr.copy(), pattern, flags)

    @always_inline
    def regexp_matches(self, pattern: String, flags: String = "") -> Expr:
        """Alias of `regexp_like` (DuckDB's `regexp_matches` name) -> Bool.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.filter(col("s").regexp_matches("\\\\d+"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.regexp_like(self._expr.copy(), pattern, flags)

    @always_inline
    def regexp_extract(self, pattern: String, group: Int = 0, flags: String = "") -> Expr:
        """`regexp_extract(s, pattern[, group])` -> Utf8. The substring matched
        by capture `group` (`group` defaults to 0 = the whole match). No match
        / non-participating group -> ''. NULL input row -> NULL.

        Examples:
            ```mojo
            from komira_sdk import col
            # first \\w+ run of each string, as a new column
            var out = ctx.materialize(
                df^.with_column(col("s").regexp_extract("(\\\\w+)", 1).alias("first_word"))^
            )
            ```
        """
        return Expr.regexp_extract(self._expr.copy(), pattern, group, flags)

    @always_inline
    def regexp_extract(self, pattern: String, *, group_name: String, flags: String = "") -> Expr:
        """`regexp_extract(s, pattern, group="name")` -> Utf8. The substring
        matched by the `(?P<name>...)` capture group. Referencing a name that
        is not in `pattern` raises at execution time. No match -> ''.

        Examples:
            ```mojo
            from komira_sdk import col
            # pull the year out of a YYYY-MM string by named group
            var out = ctx.materialize(
                df^.with_column(
                    col("s").regexp_extract("(?P<y>\\\\d+)-(?P<m>\\\\d+)", group_name="y").alias("yr")
                )^
            )
            ```
        (example not yet doctest-verified)
        """
        return Expr.regexp_extract_named(self._expr.copy(), pattern, group_name, flags)

    @always_inline
    def regexp_match(self, pattern: String, flags: String = "") -> Expr:
        """`regexp_match(s, pattern[, flags])` -> List<Utf8>. The list of
        capture-group substrings of the first match (`[whole_match]` if the
        pattern has no groups); NULL list element on no match. NULL input -> NULL.

        Examples:
            ```mojo
            from komira_sdk import col
            # each row -> [group1, group2] of the first "N-N" match
            var out = ctx.materialize(
                df^.with_column(col("s").regexp_match("(\\\\d+)-(\\\\d+)").alias("parts"))^
            )
            ```
        """
        return Expr.regexp_match(self._expr.copy(), pattern, flags)

    @always_inline
    def regexp_replace(self, pattern: String, replacement: String, flags: String = "") -> Expr:
        """`regexp_replace(s, pattern, replacement[, flags])` -> Utf8. Replaces
        the FIRST match by default; ALL non-overlapping matches when `flags`
        contains `g`. Replacement uses RE2/PostgreSQL `\\N` backref syntax
        (`\\0` = whole match, `\\1`..`\\9` = capture groups, `\\\\` = literal
        backslash) — NOT `$N`. An invalid template -> input unchanged (DuckDB).
        NULL input row -> NULL.

        Examples:
            ```mojo
            from komira_sdk import col
            # replace every "a" with "X" (g = global)
            var out = ctx.materialize(
                df^.with_column(col("s").regexp_replace("a", "X", "g").alias("masked"))^
            )
            ```
        """
        return Expr.regexp_replace(self._expr.copy(), pattern, replacement, flags)

    @always_inline
    def regexp_split_to_array(self, pattern: String, flags: String = "") -> Expr:
        """`regexp_split_to_array(s, pattern[, flags])` -> List<Utf8>. The
        between-match substrings of the (non-overlapping) matches. NULL input
        row -> NULL list.

        Examples:
            ```mojo
            from komira_sdk import col
            # split each string on commas into a list column
            var out = ctx.materialize(
                df^.with_column(col("s").regexp_split_to_array(",").alias("tokens"))^
            )
            ```
        """
        return Expr.regexp_split_to_array(self._expr.copy(), pattern, flags)

    @always_inline
    def regexp_extract_all(self, pattern: String, group: Int = 0, flags: String = "") -> Expr:
        """`regexp_extract_all(s, pattern[, group])` -> List<Utf8>. The captured
        substring of `group` for every (non-overlapping) match; `group` defaults
        to 0 (= whole match). No matches -> empty list (not NULL). NULL input
        row -> NULL list.

        Examples:
            ```mojo
            from komira_sdk import col
            # every digit in each string, as a list column
            var out = ctx.materialize(
                df^.with_column(col("s").regexp_extract_all("[0-9]", 0).alias("digits"))^
            )
            ```
        """
        return Expr.regexp_extract_all(self._expr.copy(), pattern, group, flags)

    @always_inline
    def regexp_count(self, pattern: String, flags: String = "") -> Expr:
        """`regexp_count(s, pattern[, flags])` -> Int64. Number of non-overlapping
        matches (PostgreSQL semantics; no match -> 0). NULL input row -> NULL.

        Examples:
            ```mojo
            from komira_sdk import col
            # how many "a"s in each string
            var out = ctx.materialize(
                df^.with_column(col("s").regexp_count("a").alias("n_a"))^
            )
            ```
        """
        return Expr.regexp_count(self._expr.copy(), pattern, flags)

    @always_inline
    def regexp_instr(self, pattern: String, flags: String = "") -> Expr:
        """`regexp_instr(s, pattern[, flags])` -> Int64. 1-based byte position of
        the first match (0 if no match; PostgreSQL semantics). NULL input -> NULL.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(
                df^.with_column(col("s").regexp_instr("b").alias("pos_b"))^
            )
            ```
        """
        return Expr.regexp_instr(self._expr.copy(), pattern, flags)

    @always_inline
    def regexp_substr(self, pattern: String, flags: String = "") -> Expr:
        """`regexp_substr(s, pattern[, flags])` -> Utf8. The first matched
        substring (NULL if no match — PostgreSQL/Oracle semantics; note this
        differs from `regexp_extract` which returns ''). NULL input row -> NULL.

        Examples:
            ```mojo
            from komira_sdk import col
            # first lowercase run of each string
            var out = ctx.materialize(
                df^.with_column(col("s").regexp_substr("[a-z]+").alias("word"))^
            )
            ```
        """
        return Expr.regexp_substr(self._expr.copy(), pattern, flags)

    @always_inline
    def regexp_full_match(self, pattern: String, flags: String = "") -> Expr:
        """`regexp_full_match(s, pattern[, flags])` -> Bool. True iff the ENTIRE
        string matches `pattern` (anchored both ends — `\\A(?:...)\\z`; DuckDB
        semantics). NULL input row -> NULL.

        Examples:
            ```mojo
            from komira_sdk import col
            # keep only rows that fully match "a.*"
            var out = ctx.materialize(df^.filter(col("s").regexp_full_match("a.*"))^)
            ```
        """
        return Expr.regexp_full_match(self._expr.copy(), pattern, flags)

    # =========================================================================
    # Temporal field extract
    # =========================================================================
    #
    # Per-row calendar / clock field extraction on DATE32 (`Int32 days
    # since 1970-01-01`) or TIMESTAMP_* (`Int64 ticks since 1970-01-01`)
    # columns.  Calendar fields use Hinnant's branch-free civil_from_days
    # formula; clock fields use pure arithmetic.  See `Expr.year(...)` /
    # `Expr.month(...)` / ... for the free factory equivalents.

    @always_inline
    def year(self) -> Expr:
        """`year(s)` -> Int32. Extract the calendar year from a DATE32 or
        TIMESTAMP_* column.  Null in -> null out.

        Examples:
            ```mojo
            from komira_sdk import col, lit
            # filter on a derived year instead of a pre-baked o_orderyear column
            var out = ctx.materialize(df^.filter(col("o_orderdate").year() >= lit(1995))^)
            # or project it as a new column
            var out2 = ctx.materialize(
                df2^.with_column(col("o_orderdate").year().alias("yr"))^
            )
            ```
        """
        return Expr.year(self._expr.copy())

    @always_inline
    def month(self) -> Expr:
        """`month(s)` -> Int32 [1..12].

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("d").month().alias("mo"))^)
            ```
        """
        return Expr.month(self._expr.copy())

    @always_inline
    def day(self) -> Expr:
        """`day(s)` -> Int32 [1..31] (day-of-month).

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("d").day().alias("dom"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.day(self._expr.copy())

    @always_inline
    def hour(self) -> Expr:
        """`hour(s)` -> Int32 [0..23] from a TIMESTAMP_* column.  Raises
        at eval-time when called on DATE32 (no sub-day field).

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("ts").hour().alias("hr"))^)
            ```
        """
        return Expr.hour(self._expr.copy())

    @always_inline
    def minute(self) -> Expr:
        """`minute(s)` -> Int32 [0..59].

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("ts").minute().alias("min"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.minute(self._expr.copy())

    @always_inline
    def second(self) -> Expr:
        """`second(s)` -> Int32 [0..59].

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("ts").second().alias("sec"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.second(self._expr.copy())

    @always_inline
    def quarter(self) -> Expr:
        """`quarter(s)` -> Int32 [1..4] from month.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("d").quarter().alias("q"))^)
            ```
        """
        return Expr.quarter(self._expr.copy())

    # -- the DAY-INDEX doors ---------
    #
    # ⭐ THESE EXIST SO THE UNITS ARE NOT REACHABLE FROM SQL ALONE. A unit
    # that is fully implemented but has no door on some surface is
    # unreachable there; a unit that only SQL text can name is that defect
    # one door smaller.
    #
    # ⚠ THEY CALL `Expr.extract` DIRECTLY RATHER THAN A NAMED `Expr.dayofweek`
    # FACTORY, AND THAT IS DELIBERATE. `Expr.year` / `.month` / `.day` /
    # `.quarter` predate the general factory and each is a one-line alias of
    # it; three more would add three names carrying no information the unit
    # constant does not already carry. `Expr.extract(unit, child)` IS the
    # engine's door and is what the SQL binder calls.

    @always_inline
    def dayofweek(self) -> Expr:
        """`dayofweek(s)` -> Int64. **Sunday = 0** … Saturday = 6.

        ⛔ NOT `isodow`. MEASURED on DuckDB v1.5.3: for 2026-09-13 (a Sunday)
        this answers 0 and `isodow()` answers 7; on the other six days of the
        week the two are the same number. DuckDB spells this one `dayofweek`
        and `weekday`.

        Examples:
            ```mojo
            from komira_sdk import col, lit
            # weekend rows only
            var out = ctx.materialize_plan(
                carrier.filter(col("d").dayofweek() == lit(Int64(0))).take_plan()
            )
            ```
        """
        return Expr.extract(EXTRACT_DAYOFWEEK, self._expr.copy())

    @always_inline
    def isodow(self) -> Expr:
        """`isodow(s)` -> Int64. ISO-8601: **Monday = 1** … **Sunday = 7**.

        ⛔ NOT `dayofweek() + 1` — that would answer 1 for Sunday, not 7.
        """
        return Expr.extract(EXTRACT_ISODOW, self._expr.copy())

    @always_inline
    def dayofyear(self) -> Expr:
        """`dayofyear(s)` -> Int64 [1..366]. 1 on January 1st (ONE-based, not
        zero-based — measured: `dayofyear(DATE '1970-01-01')` = 1), and
        leap-aware (2000-02-29 -> 60)."""
        return Expr.extract(EXTRACT_DAYOFYEAR, self._expr.copy())

    @always_inline
    def week(self) -> Expr:
        """`week(s)` -> Int64 [1..53]. The **ISO-8601** week number.

        ⛔ NOT `dayofyear() / 7`, and it can be 52 or 53 on a JANUARY date:
        `week(DATE '2027-01-01')` = 53, because that Friday
        belongs to ISO week 53 of 2026. DuckDB spells it `week` and
        `weekofyear`."""
        return Expr.extract(EXTRACT_WEEK, self._expr.copy())

    @always_inline
    def isoyear(self) -> Expr:
        """`isoyear(s)` -> Int64. The ISO week-numbering year.

        ⛔ NOT `year()`. They differ on up to three days at each end of every
        year: `isoyear(DATE '2027-01-01')` = 2026 and `isoyear(DATE
        '2029-12-31')` = 2030. Pair it with `week()`; pairing
        `year()` with `week()` produces a (year, week) tuple that names a week
        in the wrong year on those days."""
        return Expr.extract(EXTRACT_ISOYEAR, self._expr.copy())

    @always_inline
    def yearweek(self) -> Expr:
        """`yearweek(s)` -> Int64, `isoyear * 100 + week`.

        `yearweek(DATE '2027-01-01')` = 202653 — the ISO year, not
        the civil one."""
        return Expr.extract(EXTRACT_YEARWEEK, self._expr.copy())

    @always_inline
    def millisecond(self) -> Expr:
        """`millisecond(s)` -> Int64, **with the seconds folded in**.

        ⛔ NOT the fractional part. MEASURED v1.5.3:
        `millisecond(TIMESTAMP '2026-09-13 13:45:30.123456')` = **30123**, i.e.
        `second * 1000 + ms`, not 123. Over a DATE it is 0."""
        return Expr.extract(EXTRACT_MILLISECOND, self._expr.copy())

    @always_inline
    def microsecond(self) -> Expr:
        """`microsecond(s)` -> Int64, **with the seconds folded in**.

        MEASURED: 30123456 for `...:30.123456`, not 123456."""
        return Expr.extract(EXTRACT_MICROSECOND, self._expr.copy())

    # --- the year-derived names + nanosecond + days_in_month ---
    # DuckDB's closed forms over `year()` / `month()` / `microsecond()`, built
    # by `scalar_desugar` — the SAME trees the SQL binder builds for these
    # names. polars spells four of them `dt.century()` / `dt.millennium()` /
    # `dt.nanosecond()` / `dt.days_in_month()`; `decade` and `era` are DuckDB's.

    def century(self) -> Expr:
        """DuckDB `century(x)`: no century 0 (1 AD..100 AD is 1, 44 BC is -1)."""
        return year_derived_of(YEAR_DERIVED_CENTURY, self._expr.copy())

    def decade(self) -> Expr:
        """DuckDB `decade(x)` = `year / 10`, truncating at every sign."""
        return year_derived_of(YEAR_DERIVED_DECADE, self._expr.copy())

    def millennium(self) -> Expr:
        """DuckDB `millennium(x)`: no millennium 0, like `century`."""
        return year_derived_of(YEAR_DERIVED_MILLENNIUM, self._expr.copy())

    def era(self) -> Expr:
        """DuckDB `era(x)`: 1 for AD, 0 for BC, NULL for NULL."""
        return year_derived_of(YEAR_DERIVED_ERA, self._expr.copy())

    def nanosecond(self) -> Expr:
        """DuckDB `nanosecond(x)` = `microsecond(x) * 1000` — seconds folded in."""
        return nanosecond_of(self._expr.copy())

    def days_in_month(self) -> Expr:
        """DuckDB `days_in_month(x)`, Gregorian (Feb 1900 = 28, 2000 = 29)."""
        return days_in_month_of(self._expr.copy())

    def date_trunc(self, unit: String) raises -> Expr:
        """`date_trunc(unit, s)` — round each row down to the start of the
        period.  `unit` is one of: year, quarter, month, week, day, hour,
        minute, second, millisecond, microsecond (case-insensitive;
        common aliases — yr / mo / d / hr / min / sec / ms / us).

        Output type matches the input (DATE32 stays DATE32; TIMESTAMP_*
        stays in the same unit).

        Examples:
            ```mojo
            from komira_sdk import col
            # bucket every row down to the first of its year
            var out = ctx.materialize(
                df^.with_column(col("d").date_trunc("year").alias("year_start"))^
            )
            ```
        """
        var u = _parse_extract_trunc_unit(unit)
        return Expr.date_trunc(u, self._expr.copy())

    # =========================================================================
    # Scalar math functions
    # =========================================================================
    #
    # Element-wise floating-point math over numeric columns.  All return a
    # FLOAT64 result (null in -> null out).  These are the surface the
    # `haversine` example uses for the great-circle distance formula.
    # `atan2` is a free function (`atan2(y, x)`) since it is binary.

    @always_inline
    def sin(self) -> Expr:
        """`sin(s)` -> FLOAT64. Sine of a numeric column (radians).

        Method form of the free `sin(col("x"))`; both build the same Expr.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("x").sin().alias("s"))^)
            ```
        """
        return Expr.sin(self._expr.copy())

    @always_inline
    def cos(self) -> Expr:
        """`cos(s)` -> FLOAT64. Cosine of a numeric column (radians).

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("x").cos().alias("c"))^)
            ```
        """
        return Expr.cos(self._expr.copy())

    @always_inline
    def sqrt(self) -> Expr:
        """`sqrt(s)` -> FLOAT64. Square root of a numeric column.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("x").sqrt().alias("q"))^)
            ```
        """
        return Expr.sqrt(self._expr.copy())

    @always_inline
    def asin(self) -> Expr:
        """`asin(s)` -> FLOAT64. Arcsine (radians) of a numeric column.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(df^.with_column(col("x").asin().alias("a"))^)
            ```
        """
        return Expr.asin(self._expr.copy())

    @always_inline
    def radians(self) -> Expr:
        """`radians(s)` -> FLOAT64. Convert degrees to radians.

        Examples:
            ```mojo
            from komira_sdk import col
            # radians is the first step of the haversine great-circle formula
            var out = ctx.materialize(df^.with_column(col("lat").radians().alias("rad"))^)
            ```
        (example not yet doctest-verified)
        """
        return Expr.radians(self._expr.copy())

    # The DOUBLE-returning math names.
    # Every one of these is FLOAT64-out in DuckDB v1.5.3 over INTEGER and
    # DOUBLE input alike (measured), so the always-FLOAT64 tag is exact.
    # ⚠ TWO SCOPED EXCEPTIONS, both on DECIMAL input: `ceil` / `floor` over a
    # DECIMAL column return DECIMAL in DuckDB and FLOAT64 here. The other
    # thirteen are DOUBLE in DuckDB over decimal too.
    # ⛔ `abs` / `round` / `sign` ARE NOT HERE and may not be added: DuckDB
    # PRESERVES their input type, so this always-FLOAT64 tag would be a
    # silent type divergence — the right number under the wrong type.

    @always_inline
    def ceil(self) -> Expr:
        """`ceil(s)` -> FLOAT64. Round a numeric column UP to an integral value."""
        return Expr.math_fn(MATH_CEIL, self._expr.copy())

    @always_inline
    def floor(self) -> Expr:
        """`floor(s)` -> FLOAT64. Round a numeric column DOWN to an integral value."""
        return Expr.math_fn(MATH_FLOOR, self._expr.copy())

    @always_inline
    def ln(self) -> Expr:
        """`ln(s)` -> FLOAT64. Natural logarithm of a numeric column."""
        return Expr.math_fn(MATH_LN, self._expr.copy())

    @always_inline
    def exp(self) -> Expr:
        """`exp(s)` -> FLOAT64. e raised to a numeric column."""
        return Expr.math_fn(MATH_EXP, self._expr.copy())

    @always_inline
    def log10(self) -> Expr:
        """`log10(s)` -> FLOAT64. Base-10 logarithm. ⚠ DuckDB spells this `log` TOO."""
        return Expr.math_fn(MATH_LOG10, self._expr.copy())

    @always_inline
    def log2(self) -> Expr:
        """`log2(s)` -> FLOAT64. Base-2 logarithm of a numeric column."""
        return Expr.math_fn(MATH_LOG2, self._expr.copy())

    @always_inline
    def tan(self) -> Expr:
        """`tan(s)` -> FLOAT64. Tangent of a numeric column (radians)."""
        return Expr.math_fn(MATH_TAN, self._expr.copy())

    @always_inline
    def atan(self) -> Expr:
        """`atan(s)` -> FLOAT64. Arctangent of a numeric column, in radians."""
        return Expr.math_fn(MATH_ATAN, self._expr.copy())

    @always_inline
    def acos(self) -> Expr:
        """`acos(s)` -> FLOAT64. Arccosine, in radians. ⚠ DOMAIN [-1, 1]; NaN outside it."""
        return Expr.math_fn(MATH_ACOS, self._expr.copy())

    @always_inline
    def cot(self) -> Expr:
        """`cot(s)` -> FLOAT64. Cotangent, `1/tan`, of a numeric column."""
        return Expr.math_fn(MATH_COT, self._expr.copy())

    @always_inline
    def degrees(self) -> Expr:
        """`degrees(s)` -> FLOAT64. Convert a radians column to degrees."""
        return Expr.math_fn(MATH_DEGREES, self._expr.copy())

    @always_inline
    def cbrt(self) -> Expr:
        """`cbrt(s)` -> FLOAT64. Cube root. ⚠ Defined for NEGATIVE input, unlike `x ** (1/3)`."""
        return Expr.math_fn(MATH_CBRT, self._expr.copy())

    @always_inline
    def sinh(self) -> Expr:
        """`sinh(s)` -> FLOAT64. Hyperbolic sine of a numeric column."""
        return Expr.math_fn(MATH_SINH, self._expr.copy())

    @always_inline
    def cosh(self) -> Expr:
        """`cosh(s)` -> FLOAT64. Hyperbolic cosine of a numeric column."""
        return Expr.math_fn(MATH_COSH, self._expr.copy())

    @always_inline
    def tanh(self) -> Expr:
        """`tanh(s)` -> FLOAT64. Hyperbolic tangent of a numeric column."""
        return Expr.math_fn(MATH_TANH, self._expr.copy())

    @always_inline
    def acosh(self) -> Expr:
        """`acosh(s)` -> FLOAT64. Inverse hyperbolic cosine of a numeric column."""
        return Expr.math_fn(MATH_ACOSH, self._expr.copy())

    @always_inline
    def asinh(self) -> Expr:
        """`asinh(s)` -> FLOAT64. Inverse hyperbolic sine of a numeric column."""
        return Expr.math_fn(MATH_ASINH, self._expr.copy())

    @always_inline
    def atanh(self) -> Expr:
        """`atanh(s)` -> FLOAT64. Inverse hyperbolic tangent of a numeric column."""
        return Expr.math_fn(MATH_ATANH, self._expr.copy())

    @always_inline
    def gamma(self) -> Expr:
        """`gamma(s)` -> FLOAT64. Gamma function (libm `tgamma`) of a numeric column."""
        return Expr.math_fn(MATH_GAMMA, self._expr.copy())


    # =========================================================================
    # Writable
    # =========================================================================

    def write_to[W: Writer](self, mut writer: W):
        """Delegate to inner Expr's write_to."""
        self._expr.write_to(writer)


# =============================================================================
# date_to_days — convert a calendar date to days since epoch (1970-01-01)
# =============================================================================
#
# Parquet stores DATE columns as Int32 (days since 1970-01-01). TPC-H uses
# predicates like WHERE l_shipdate <= DATE '1998-09-02'. To evaluate these,
# we convert the date literal to an integer and compare with the Int32 column
# using the existing eval_gt/lt/eq infrastructure.
#
# Algorithm: compute days from civil date to epoch using a well-known formula
# derived from the Gregorian calendar. Handles leap years correctly.
# =============================================================================


@always_inline
def _between_closed(closed: String) raises -> UInt8:
    """polars' `closed=` vocabulary -> `scalar_desugar.BETWEEN_*`, or RAISE
    naming the four accepted words (polars raises on an unknown one too)."""
    if closed == "both":
        return BETWEEN_BOTH
    if closed == "left":
        return BETWEEN_LEFT
    if closed == "right":
        return BETWEEN_RIGHT
    if closed == "none":
        return BETWEEN_NONE
    raise Error(
        "is_between: `closed` must be one of 'both', 'left', 'right', 'none'"
        " — got '" + closed + "'"
    )


def _is_leap_year(year: Int) -> Bool:
    """Return True if year is a leap year in the Gregorian calendar."""
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)


@always_inline
def _days_in_month(year: Int, month: Int) -> Int:
    """Return the number of days in the given month of the given year."""
    if month == 2:
        if _is_leap_year(year):
            return 29
        return 28
    elif month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    else:
        return 31


@always_inline
def date_to_days(year: Int, month: Int, day: Int) -> Int:
    """Convert a date to days since 1970-01-01 (Unix epoch).

    Parquet DATE columns store values as Int32 days since epoch. This function
    converts a human-readable date to that integer for use in filter predicates.

    Example:
        date_to_days(1970, 1, 1)  == 0
        date_to_days(1998, 9, 2)  == 10471
        df.filter(col("shipdate") <= date_to_days(1998, 9, 2))

    Algorithm: the closed-form Howard Hinnant `days_from_civil` formula
    (chrono-compatible, proleptic Gregorian). This is O(1) — NO year loop — so
    it is both faster at runtime than an accumulating loop AND
    constant-folds when all three args are comptime-known literals (the common
    case in filter predicates). The result is BYTE-IDENTICAL to a
    year-by-year accumulation loop for every valid date (pinned by
    `komira_plan_expr/tests/test_date_to_days_closed_form.mojo`, which sweeps BC
    years as well as the leap-year edges).

    `year` is an ASTRONOMICAL year number (proleptic Gregorian, ISO 8601):
    1 BC is `year = 0` and 45 BC is `year = -44`. The result is correct at
    EVERY sign -- both for pre-epoch AD dates and for year <= 0.

    ⚠ A NEGATIVE YEAR IS NOT THE SAME CLAIM AS A NEGATIVE RESULT: a negative
    RESULT (any date before 1970) is easy, while a negative YEAR is where a
    mis-derived era is short by exactly one day — see the era comment in the
    body for the root cause and the measurement.

    Reference: H. Hinnant, "chrono-Compatible Low-Level Date Algorithms",
    `days_from_civil`. The era/year-of-era decomposition makes the leap-year
    arithmetic exact for all years (the classic source of date bugs).

    Args:
        year: The year (e.g., 1998).
        month: The month (1-12).
        day: The day of month (1-31).

    Returns:
        Number of days since 1970-01-01. Negative for dates before the epoch.
    """
    # Howard Hinnant days_from_civil — closed-form, no loop, comptime-foldable.
    # Shift the year back by one for Jan/Feb so that the leap day (Feb 29) lands
    # at the END of the shifted year, removing the month-length special-case.
    var y = year
    if month <= 2:
        y -= 1
    # era = the 400-year cycle index. THIS IS A PLAIN FLOORING DIVIDE.
    #
    # ⛔⛔ DO NOT "RESTORE" THE C IDIOM `(y if y >= 0 else y - 399) // 400`
    # HERE, however familiar it looks. That spelling recovers a FLOOR from a
    # division that TRUNCATES, which is what C's `/` does. Mojo's `//` ALREADY
    # FLOORS, so the correction subtracts a SECOND era. MEASURED on this
    # toolchain with a standalone `mojo run` probe:
    #       -401 // 400 == -2      (floor; a truncating divide answers -1)
    #         -7 //   2 == -4      (floor; a truncating divide answers -3)
    # With the idiom, y_adj = -2 answered era = -2 where floor(-2/400) is -1;
    # `yoe` then left its [0, 399] domain and the leap-day term
    # `yoe // 4 - yoe // 100` under-counted by exactly one day, because
    # Hinnant omits the `yoe // 400` term that is zero ONLY while yoe < 400.
    #
    # MEASURED COST OF THE IDIOM: the round trip
    # `date_to_days(civil_from_days(d))` fails for 11,453 of the 118,572
    # day counts sampled over [-800000, 30000) -- EVERY ONE OF THEM BC and ZERO
    # of the AD ones, which is why an AD-only fixture never sees it. Against
    # duckdb v1.5.3 `-0044-01-01` is day -735599; the idiom answers -735600.
    #
    # ⚠ AD IS UNAFFECTED: for y >= 0 both spellings evaluate `y // 400`. The
    # sibling `komira_eval/temporal_extract._days_from_civil` uses the same
    # plain flooring divide.
    var era = y // 400
    # yoe = year-of-era, in [0, 399].
    var yoe = y - era * 400
    # doy = day-of-year for the SHIFTED year (Mar=0 .. Feb=last). The
    # `(153 * mp + 2) // 5` term is the exact cumulative-month-length formula
    # for the Mar-anchored month index `mp`.
    var mp = month + 9 if month <= 2 else month - 3
    var doy = (153 * mp + 2) // 5 + (day - 1)
    # doe = day-of-era, in [0, 146096].
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    # Days from 1970-01-01: era*146097 + doe shifts the H.H. epoch
    # (0000-03-01) to the Unix epoch (1970-01-01) via the -719468 constant.
    return era * 146097 + doe - 719468


# =============================================================================
# Temporal extract — date_trunc unit-string -> EXTRACT_TRUNC_* helper
# =============================================================================
#
# Used by
# `ColExpr.date_trunc(unit: String)`.  Accepts canonical SQL unit names
# (case-insensitive) and common aliases.


def _parse_extract_trunc_unit(unit: String) raises -> UInt8:
    var u = unit.lower()
    if u == "year" or u == "years" or u == "yr":
        return EXTRACT_TRUNC_YEAR
    elif u == "quarter" or u == "quarters" or u == "q":
        return EXTRACT_TRUNC_QUARTER
    elif u == "month" or u == "months" or u == "mo":
        return EXTRACT_TRUNC_MONTH
    elif u == "week" or u == "weeks" or u == "w":
        return EXTRACT_TRUNC_WEEK
    elif u == "day" or u == "days" or u == "d":
        return EXTRACT_TRUNC_DAY
    elif u == "hour" or u == "hours" or u == "hr":
        return EXTRACT_TRUNC_HOUR
    elif u == "minute" or u == "minutes" or u == "min":
        return EXTRACT_TRUNC_MINUTE
    elif u == "second" or u == "seconds" or u == "sec":
        return EXTRACT_TRUNC_SECOND
    elif u == "millisecond" or u == "milliseconds" or u == "ms":
        return EXTRACT_TRUNC_MILLISECOND
    elif u == "microsecond" or u == "microseconds" or u == "us":
        return EXTRACT_TRUNC_MICROSECOND
    raise Error("col_expr.date_trunc: unrecognized unit '" + unit + "'")

# =============================================================================
# scalar_desugar — the scalar functions this engine has NO NODE for, built as
# trees of the nodes it does have, in ONE place for EVERY door that names them
# =============================================================================
#
# `coalesce`, `greatest` / `least`, `isfinite` / `isinf` / `isnan`, `even`,
# `days_in_month`, `century` / `decade` / `millennium` / `era` and
# `nanosecond` are DuckDB functions with no `EXPR_*` tag, no kernel and no wire
# member here: each is a CASE / comparison / arithmetic tree over nodes that
# already exist. Both the SQL binder (`komira_sdk.sql_binder`, one `_bind_*`
# per `FNK_DESUGAR` row) and the untyped Mojo door (`ColExpr`) need a NAME for
# each of them.
#
# ★ ONE BUILDER, TWO DOORS. The SQL binder binds its arguments and calls
# the function below; `ColExpr.fill_null` / `coalesce(...)` / `.is_nan()` /
# `.century()` / ... call the SAME function. A second copy of these trees in
# `col_expr.mojo` would be two statements of one semantics that nothing keeps
# in agreement (the same reason the SQL name table, `sql_fn_table`, is one
# table over one namespace). The MEASURED DuckDB v1.5.3 tables that justify
# each shape are on the SQL binder's `_bind_*` docstrings; each builder here
# states its formula.
#
# ⚠ TYPE UNIFICATION IS THE CALLER'S, NOT THIS FILE'S. The engine's CASE
# executor takes its output dtype from the ELSE and requires every THEN to
# agree, so `coalesce(<float>, 0)` must see its `0` as `0.0`. The SQL binder
# decides that from the SCHEMA (`_bound_expr_is_float`); `ColExpr` is unbound
# and decides it from what the expression PROVES (`col_expr_division.
# is_statically_floating`). Both promote BEFORE calling here, so the tree built
# below is the same tree for the same unified arguments.
# =============================================================================

from std.math import inf

from ..arrow.arrow_types import ArrowType
from .scalar_value import ScalarValue
from .expr import (
    Expr,
    WhenCaseData,
    EXPR_LITERAL,
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV,
    BIN_EQ, BIN_LT, BIN_LE, BIN_GT, BIN_GE,
    BIN_AND, BIN_OR,
    UN_NOT, UN_IS_NULL, UN_IS_NOT_NULL,
    MATH_CEIL, MATH_FLOOR,
    EXTRACT_YEAR, EXTRACT_MONTH, EXTRACT_MICROSECOND,
)


# ---- selectors (the SQL binder maps its `DSG_*` onto these) -----------------

comptime YEAR_DERIVED_CENTURY: UInt8 = 0
comptime YEAR_DERIVED_DECADE: UInt8 = 1
comptime YEAR_DERIVED_MILLENNIUM: UInt8 = 2
comptime YEAR_DERIVED_ERA: UInt8 = 3

comptime FLOAT_CLASS_FINITE: UInt8 = 0
comptime FLOAT_CLASS_INFINITE: UInt8 = 1
comptime FLOAT_CLASS_NAN: UInt8 = 2

comptime BETWEEN_BOTH: UInt8 = 0
comptime BETWEEN_LEFT: UInt8 = 1
comptime BETWEEN_RIGHT: UInt8 = 2
comptime BETWEEN_NONE: UInt8 = 3


# =============================================================================
# NULL handling
# =============================================================================


def promote_int_literal_to_float(var e: Expr) -> Expr:
    """An INTEGER literal becomes the equal FLOAT64 literal; anything else is
    returned unchanged. The CASE branch-unification rule: the engine's CASE
    executor takes its dtype from the ELSE and requires every THEN to agree,
    so `... THEN <float> ELSE 0` must make the `0` a `0.0`. Deciding WHETHER to
    promote is the caller's (see the header)."""
    if e.tag == EXPR_LITERAL and e.literal_value().is_int():
        return Expr.literal(
            ScalarValue.from_float(Float64(e.literal_value().int_val))
        )
    return e^


def coalesce_of(var args: List[Expr]) -> Expr:
    """`coalesce(a, b, ..., z)` = `CASE WHEN a IS NOT NULL THEN a ... ELSE z`.

    The LAST argument is the ELSE and is NOT guarded: `coalesce(a, b)` is `b`
    even when `b` is NULL (DuckDB: `coalesce(NULL::INT, NULL::INT) IS NULL`).
    One argument is that argument, with no CASE at all (DuckDB `coalesce(7)` =
    7). Every guarded argument is evaluated twice — once as the condition, once
    as the value — which is the price of the desugar, not a semantics note.
    Measured table: `sql_binder._bind_coalesce`.

    ⚠ ZERO ARGUMENTS IS THE CALLER'S TO REFUSE, BY NAME — both callers do
    (`sql_binder._bind_coalesce`, `col_expr.coalesce`), so this stays
    non-raising for `ColExpr.fill_null`. Reached anyway, it answers a NULL
    literal rather than inventing a value.
    """
    var n = len(args)
    if n < 1:
        return Expr.literal(ScalarValue.null(DType.int64))
    if n == 1:
        return args[0].copy()
    var cases = List[WhenCaseData]()
    for i in range(n - 1):
        cases.append(
            WhenCaseData(
                Expr.unary(UN_IS_NOT_NULL, args[i].copy()), args[i].copy()
            )
        )
    return Expr.when(cases^, args[n - 1].copy())


def greatest_least_of(greatest: Bool, var a: Expr, var b: Expr) -> Expr:
    """`greatest(a, b)` / `least(a, b)` — NULL-IGNORING, as DuckDB's are.

        CASE WHEN a IS NULL THEN b
             WHEN b IS NULL THEN a
             WHEN a > b THEN a        (`<` for least)
             ELSE b END

    ⛔ The two NULL branches ARE the function: `greatest(1, NULL)` is 1 on
    DuckDB v1.5.3, where a bare comparison CASE answers NULL. Two operands
    only — the tree mentions each four times, so a fold would square it (the
    SQL binder refuses a third argument by name for that reason).
    """
    var cmp_op = BIN_GT if greatest else BIN_LT
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.unary(UN_IS_NULL, a.copy()), b.copy()))
    cases.append(WhenCaseData(Expr.unary(UN_IS_NULL, b.copy()), a.copy()))
    cases.append(
        WhenCaseData(Expr.binary(cmp_op, a.copy(), b.copy()), a.copy())
    )
    return Expr.when(cases^, b^)


# =============================================================================
# float classification — comparisons correct under BOTH float orderings
# =============================================================================


def float_class_of(which: UInt8, var x: Expr) -> Expr:
    """`isfinite` / `isinf` / `isnan` as pure comparisons against +-inf.

        isfinite(x) == x > -inf AND x < inf
        isinf(x)    == x  =  inf OR  x  = -inf
        isnan(x)    == NOT isfinite(x) AND NOT isinf(x)

    ⛔ NOT `x <> x`: DuckDB orders floats TOTALLY (`nan = nan` is TRUE there),
    so the IEEE idiom answers FALSE for a NaN on the parity target. These forms
    are right under BOTH orderings. NULL in, NULL out. Measured table:
    `sql_binder._bind_float_class`.
    """
    var pos_inf = Expr.literal(ScalarValue.from_float(inf[DType.float64]()))
    var neg_inf = Expr.literal(ScalarValue.from_float(-inf[DType.float64]()))
    if which == FLOAT_CLASS_FINITE:
        return Expr.binary(
            BIN_AND,
            Expr.binary(BIN_GT, x.copy(), neg_inf^),
            Expr.binary(BIN_LT, x^, pos_inf^),
        )
    if which == FLOAT_CLASS_INFINITE:
        return Expr.binary(
            BIN_OR,
            Expr.binary(BIN_EQ, x.copy(), pos_inf^),
            Expr.binary(BIN_EQ, x^, neg_inf^),
        )
    # FLOAT_CLASS_NAN — built from the two above so the three cannot drift.
    var fin = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_GT, x.copy(), neg_inf.copy()),
        Expr.binary(BIN_LT, x.copy(), pos_inf.copy()),
    )
    var infn = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_EQ, x.copy(), pos_inf^),
        Expr.binary(BIN_EQ, x^, neg_inf^),
    )
    return Expr.binary(
        BIN_AND, Expr.unary(UN_NOT, fin^), Expr.unary(UN_NOT, infn^)
    )


def fill_nan_of(var x: Expr, var value: Expr) -> Expr:
    """polars `fill_nan(value)`: a NaN becomes `value`; NULL STAYS NULL; +-inf
    are kept.

        CASE WHEN x IS NULL OR NOT isnan(x) THEN x ELSE value END

    ⚠ The NULL arm is what separates it from `fill_null`: `isnan(NULL)` is
    NULL, so without it a NULL row would reach the ELSE and be filled. DuckDB
    has no `fill_nan`; the corpus element `proj_fill_nan` asks exactly this
    tree at every door.
    """
    var keep = Expr.binary(
        BIN_OR,
        Expr.unary(UN_IS_NULL, x.copy()),
        Expr.unary(UN_NOT, float_class_of(FLOAT_CLASS_NAN, x.copy())),
    )
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(keep^, x^))
    return Expr.when(cases^, value^)


# =============================================================================
# numeric
# =============================================================================


def even_of(var x: Expr) -> Expr:
    """DuckDB `even(x)`: round AWAY FROM ZERO to the next EVEN integer.

        CASE WHEN x >= 0 THEN ceil(x / 2.0) * 2.0 ELSE floor(x / 2.0) * 2.0 END

    over `CAST(x AS DOUBLE)`. ⛔ Not banker's rounding: `even(1.0)` = 2 and
    `even(-0.5)` = -2 (measured v1.5.3, `sql_binder._bind_even`). The cast is
    DuckDB's only overload and is what keeps `x / 2` from truncating over an
    integer column. NULL falls out through the ELSE.
    """
    var ex = Expr.cast_to_arrow(x^, ArrowType.FLOAT64)
    var two = Expr.literal(ScalarValue.from_float(2.0))
    var pos = Expr.binary(
        BIN_MUL,
        Expr.math_fn(MATH_CEIL, Expr.binary(BIN_DIV, ex.copy(), two.copy())),
        two.copy(),
    )
    var neg = Expr.binary(
        BIN_MUL,
        Expr.math_fn(MATH_FLOOR, Expr.binary(BIN_DIV, ex.copy(), two.copy())),
        two.copy(),
    )
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.binary(BIN_GE, ex^, Expr.literal(ScalarValue.from_float(0.0))),
            pos^,
        )
    )
    return Expr.when(cases^, neg^)


def between_of(var x: Expr, var lo: Expr, var hi: Expr, closed: UInt8) -> Expr:
    """`x BETWEEN lo AND hi` and polars' `is_between(lo, hi, closed=...)`.

    `BETWEEN_BOTH` is SQL's `BETWEEN` and polars' default — exactly the tree
    `sql_parser` desugars `BETWEEN` into, `(x >= lo) AND (x <= hi)`; the other
    three change only the two comparison operators. ⚠ `EXPR_BETWEEN` is NOT
    used: that tag carries no payload and no evaluator walks it.
    """
    var lo_op = BIN_GE
    var hi_op = BIN_LE
    if closed == BETWEEN_LEFT:
        hi_op = BIN_LT
    elif closed == BETWEEN_RIGHT:
        lo_op = BIN_GT
    elif closed == BETWEEN_NONE:
        lo_op = BIN_GT
        hi_op = BIN_LT
    return Expr.binary(
        BIN_AND,
        Expr.binary(lo_op, x.copy(), lo^),
        Expr.binary(hi_op, x^, hi^),
    )


# =============================================================================
# temporal — closed forms over EXTRACT_YEAR / EXTRACT_MONTH / EXTRACT_MICROSECOND
# =============================================================================


def year_derived_of(which: UInt8, var child: Expr) -> Expr:
    """`century` / `decade` / `millennium` / `era` over `year(child)`.

        decade     = year / 10                              (truncating, every sign)
        century    = CASE WHEN y > 0  THEN (y - 1) / 100  + 1
                          WHEN y <= 0 THEN  y      / 100  - 1 ELSE NULL END
        millennium = the same at 1000
        era        = CASE WHEN y > 0 THEN 1 WHEN y <= 0 THEN 0 ELSE NULL END

    ⛔ DuckDB's century/millennium numbering has NO ZERO (… -1, 1 …), so no
    single division — truncating or flooring — produces it; and the third,
    NULL, branch is what keeps `era(NULL)` NULL instead of 0. The measured
    table (44 BC, 2000, 2001, …) is in the comments below.
    """
    var ybase = Expr.extract(EXTRACT_YEAR, child^)
    if which == YEAR_DERIVED_DECADE:
        return Expr.binary(
            BIN_DIV, ybase^, Expr.literal(ScalarValue.from_int64(10))
        )
    if which == YEAR_DERIVED_ERA:
        # ⛔⛔ THREE BRANCHES, NOT TWO, AND THE THIRD IS THE NULL ONE. The
        # two-branch form `CASE WHEN year(x) > 0 THEN 1 ELSE 0 END` answers
        # **0** for a NULL input — `year(NULL) > 0` is NULL, so the condition
        # is not true, so the ELSE fires. DuckDB's `era(NULL)` is NULL, and
        # only a fixture with NULL rows can see the difference.
        #
        # ⚠ A TYPED NULL LITERAL IS EXPRESSIBLE HERE AND ONLY BECAUSE THE
        # BRANCHES ARE INT64. `broadcast_scalar`'s null arm has exactly two
        # types — float64 and int64 — so the same shape is NOT available to a
        # string-valued CASE, which is why `dayname`/`monthname` are still
        # unbound (they need `CASE ... ELSE <string NULL>`).
        var ecases = List[WhenCaseData]()
        ecases.append(
            WhenCaseData(
                Expr.binary(
                    BIN_GT, ybase.copy(), Expr.literal(ScalarValue.from_int64(0))
                ),
                Expr.literal(ScalarValue.from_int64(1)),
            )
        )
        ecases.append(
            WhenCaseData(
                Expr.binary(
                    BIN_LE, ybase^, Expr.literal(ScalarValue.from_int64(0))
                ),
                Expr.literal(ScalarValue.from_int64(0)),
            )
        )
        # Both conditions are NULL for a NULL year, so the ELSE is reached
        # only there — and it must be a NULL, not a 0.
        return Expr.when(ecases^, Expr.literal(ScalarValue.null(DType.int64)))
    # ⛔⛔ century / millennium — THE SAME SHAPE AT TWO SCALES, AND THE SHAPE
    # IS A **CASE**, BECAUSE DuckDB'S NUMBERING SKIPS ZERO.
    #
    # There is no century 0 and no millennium 0: the sequence runs
    # ... -2, -1, 1, 2 ... So no single division — truncating OR flooring —
    # can produce it, and a one-line "use a flooring divide" fix is WRONG.
    # MEASURED v1.5.3, over
    # `make_timestamp(y,3,15,12,0,0.0)`:
    #
    #     y      -2001  -1000   -44    -1     0     1   1999  2000  2001
    #     cent     -21    -11    -1    -1    -1     1     20    20    21
    #     mil       -3     -2    -1    -1    -1     1      2     2     3
    #
    # `floor((y-1)/100)+1` answers **0** for y = -44 and y = 0 — a century
    # that does not exist — so flooring trades one wrong answer for another.
    # The AD arm is `(y-1)/S + 1` and the BC arm is `y/S - 1`, each a
    # TRUNCATING divide, and the two are selected by the sign of the year:
    #
    #     y  > 0 :  (y - 1) / S + 1     19xx -> 20, 2000 -> 20, 2001 -> 21
    #     y <= 0 :   y      / S - 1     0 -> -1, -44 -> -1, -100 -> -2
    #
    # ⚠ THE BC ARM IS REACHABLE. The engine's DATE32 cannot represent a BC
    # date — but a TIMESTAMP built from raw int64 microseconds CAN, and every
    # derived name here reads `EXTRACT_YEAR`, which decodes that instant
    # correctly. The AD form ALONE answers **1** for 44 BC (DuckDB: -1) and
    # **0** for 1000 BC's millennium (DuckDB: -2) — zero being a value the
    # parity target never returns for either name.
    #
    # ⚠ THE THIRD BRANCH IS THE NULL ONE, for the reason `era` states above:
    # both conditions are NULL for a NULL year, so neither fires and the ELSE
    # must be a typed NULL rather than a number. A plain arithmetic form gets
    # NULL for free from arithmetic propagation; a CASE does not.
    #
    # ⭐ THE CASE ROOT ALSO WIDENS THE IN-MEM ENVELOPE. `compute_project`
    # matches an overlay family at the TOP of an output expression; an
    # `EXPR_EXTRACT` under arithmetic is declined and an `EXPR_WHEN` is
    # matched — the same reason `era` runs there. `decade` keeps its bare
    # `BIN_DIV` root (it is a plain truncating divide at every sign, measured
    # above) and therefore the narrower envelope.
    var yscale: Int64 = 100 if which == YEAR_DERIVED_CENTURY else 1000
    var ycases = List[WhenCaseData]()
    ycases.append(
        WhenCaseData(
            Expr.binary(
                BIN_GT, ybase.copy(), Expr.literal(ScalarValue.from_int64(0))
            ),
            Expr.binary(
                BIN_ADD,
                Expr.binary(
                    BIN_DIV,
                    Expr.binary(
                        BIN_SUB,
                        ybase.copy(),
                        Expr.literal(ScalarValue.from_int64(1)),
                    ),
                    Expr.literal(ScalarValue.from_int64(yscale)),
                ),
                Expr.literal(ScalarValue.from_int64(1)),
            ),
        )
    )
    ycases.append(
        WhenCaseData(
            Expr.binary(
                BIN_LE, ybase.copy(), Expr.literal(ScalarValue.from_int64(0))
            ),
            Expr.binary(
                BIN_SUB,
                Expr.binary(
                    BIN_DIV, ybase^, Expr.literal(ScalarValue.from_int64(yscale))
                ),
                Expr.literal(ScalarValue.from_int64(1)),
            ),
        )
    )
    return Expr.when(ycases^, Expr.literal(ScalarValue.null(DType.int64)))


def nanosecond_of(var child: Expr) -> Expr:
    """DuckDB `nanosecond(x)` = `microsecond(x) * 1000` — the whole family
    FOLDS THE SECONDS IN (`12:30:45.123456` -> 45123456000), and this engine's
    timestamp resolution is microseconds. See `sql_binder._bind_nanosecond`."""
    return Expr.binary(
        BIN_MUL,
        Expr.extract(EXTRACT_MICROSECOND, child^),
        Expr.literal(ScalarValue.from_int64(1000)),
    )


def _dim_divisible(y: Expr, n: Int64) -> Expr:
    """`year % n == 0`, WRITTEN WITHOUT `%`.

    ⚠ `BIN_MOD` IS AVAILABLE, AND THIS SPELLING IS DELIBERATE. The
    `compiler_eval_column` `BIN_MOD` arm computes `a - trunc(a/b)*b` — THIS
    IDENTITY, one level down. Rewriting the
    chain below as `y % n = 0` would therefore buy nothing at all: the same
    three kernels run either way, and the rewrite would cost the two extra
    evaluations of `y` that going through the generic arm implies. It is kept
    as the explicit identity for that reason, not because `%` is unavailable.

    ⚠ `BIN_DIV` OVER I64 TRUNCATES TOWARD ZERO, so this identity is the
    TRUNCATED remainder — which has the SIGN of `y` and is therefore NOT
    Python's `%` for a negative year. ⭐ IT IS STILL THE RIGHT PREDICATE HERE,
    and that is measured rather than assumed: the caller only ever asks
    `remainder == 0`, and a truncated remainder is zero on exactly the same
    inputs a floored one is. MEASURED against v1.5.3 over BC Februaries —
    `days_in_month` at years -400 / -100 / -44 / -45 / -1 / 0 is
    29 / 28 / 29 / 28 / 28 / 29, which is this chain's answer at every row.

    ⛔ SO DO NOT "SCOPE THIS TO NON-NEGATIVE YEARS" on the grounds that DATE32
    cannot represent a BC year: a TIMESTAMP built from raw int64 microseconds
    carries a BC instant and `EXTRACT_YEAR` decodes it (see `century` above).

    ⚠ AND DO NOT MAKE IT FLOOR-BASED "FOR SAFETY" — `y - floor(y/n)*n` is also
    zero exactly when `n | y`, so the change would buy nothing and would cost
    the `BIN_MOD`-shaped node this comment exists to avoid.
    """
    var quotient = Expr.binary(
        BIN_DIV, y.copy(), Expr.literal(ScalarValue.from_int64(n))
    )
    var product = Expr.binary(
        BIN_MUL, quotient^, Expr.literal(ScalarValue.from_int64(n))
    )
    var remainder = Expr.binary(BIN_SUB, y.copy(), product^)
    return Expr.binary(
        BIN_EQ, remainder^, Expr.literal(ScalarValue.from_int64(0))
    )


def _dim_month_is(m: Expr, k: Int) -> Expr:
    """`month(x) = k` — one branch condition of `days_in_month`'s outer CASE."""
    return Expr.binary(
        BIN_EQ, m.copy(), Expr.literal(ScalarValue.from_int64(Int64(k)))
    )


def days_in_month_of(var child: Expr) -> Expr:
    """DuckDB `days_in_month(x)`: twelve `month(x) = k` branches and an
    `ELSE NULL`; February is the Gregorian rule as an ORDERED chain
    (`% 400` -> 29, `% 100` -> 28, `% 4` -> 29, else 28).

    ⛔ Not `year % 4`: February 1900 / 2100 are 28 on DuckDB v1.5.3. ⛔ The
    outer ELSE is NULL, not 31 — `days_in_month(NULL)` is NULL. Measured table
    and the reconstruction note: `sql_binder._bind_days_in_month`.
    """
    var dyear = Expr.extract(EXTRACT_YEAR, child.copy())
    var dmonth = Expr.extract(EXTRACT_MONTH, child^)
    var fcases = List[WhenCaseData]()
    fcases.append(
        WhenCaseData(
            _dim_divisible(dyear, 400), Expr.literal(ScalarValue.from_int64(29))
        )
    )
    fcases.append(
        WhenCaseData(
            _dim_divisible(dyear, 100), Expr.literal(ScalarValue.from_int64(28))
        )
    )
    fcases.append(
        WhenCaseData(
            _dim_divisible(dyear, 4), Expr.literal(ScalarValue.from_int64(29))
        )
    )
    var feb = Expr.when(fcases^, Expr.literal(ScalarValue.from_int64(28)))
    # ⚠ February is appended OUTSIDE the loop: `feb` is move-only, and moving
    # it inside a `for` body is a use-after-move on the second iteration.
    var mcases = List[WhenCaseData]()
    mcases.append(
        WhenCaseData(
            _dim_month_is(dmonth, 1), Expr.literal(ScalarValue.from_int64(31))
        )
    )
    mcases.append(WhenCaseData(_dim_month_is(dmonth, 2), feb^))
    var lengths: List[Int64] = [31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    for i in range(10):
        mcases.append(
            WhenCaseData(
                _dim_month_is(dmonth, i + 3),
                Expr.literal(ScalarValue.from_int64(lengths[i])),
            )
        )
    return Expr.when(mcases^, Expr.literal(ScalarValue.null(DType.int64)))

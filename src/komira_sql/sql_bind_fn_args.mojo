# =============================================================================
# komira_sql/sql_bind_fn_args.mojo
#   Scalar functions that desugar at bind time: greatest / least, coalesce,
#   date_part, date_trunc, left / right, substring, the year-derived parts,
#   nanosecond, the float classes and string_split.
# =============================================================================

from komira_arrow.schema import Schema
from komira_column_kernels.regexp_functions import regexp_escape_str
from komira_plan_expr.expr import (
    EXPR_LITERAL, Expr, REGEXP_SPLIT_TO_ARRAY,
)
from komira_plan_expr.scalar_desugar import (
    FLOAT_CLASS_FINITE, FLOAT_CLASS_INFINITE, FLOAT_CLASS_NAN, YEAR_DERIVED_CENTURY,
    YEAR_DERIVED_DECADE, YEAR_DERIVED_ERA, YEAR_DERIVED_MILLENNIUM, coalesce_of,
    float_class_of, greatest_least_of, nanosecond_of, year_derived_of,
)
from komira_sql.sql_ast import (
    SX_DATE, SX_NULL, SX_STRING, SqlExpr,
)
from komira_sql.sql_bind_call import _regexp_literal_string
from komira_sql.sql_bind_expr import (
    _bound_expr_is_float, _promote_int_literal_to_float, _bind_scalar,
)
from komira_sql.sql_bind_ops import _BARE_NULL_REFUSAL
from komira_sql.sql_bind_scope import (
    CteScope, _date_to_days, BindScope,
)
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_fn_table import (
    DSG_DECADE, DSG_ERA, DSG_GREATEST, DSG_IFNULL, DSG_ISFINITE, DSG_ISINF, DSG_LEFT,
    DSG_MILLENNIUM, FNK_BINARY_OP, FNK_CONST, FNK_EXTRACT_FIELD, FNK_MATH_FN,
    FNK_MATH_FN2, FNK_STRING_FN, FNK_STRING_PRED, FNK_UNARY_NUM, sql_date_part_desugar,
    sql_date_part_supported_summary, sql_date_part_unit, sql_date_trunc_unit,
)


def _date_diff_days(sx: SqlExpr) raises -> Int64:
    """Constant-fold `date_diff('day', DATE d0, DATE d1)` to the integer day
    difference `days(d1) - days(d0)`. Raises for a unit other than `'day'` or
    an operand that is not a DATE literal."""
    ref args = sx._call.value().args
    if len(args) != 3:
        raise Error("SQL bind error: date_diff expects 3 arguments (unit, start, end)")
    ref unit = args[0]
    if unit.tag != SX_STRING or unit.text.lower() != "day":
        raise Error(
            "SQL not supported: only date_diff('day', ...) is supported"
            + " (got unit that is not the constant 'day')"
        )
    ref d0 = args[1]
    ref d1 = args[2]
    if d0.tag != SX_DATE or d1.tag != SX_DATE:
        # The one caller that reaches this line is `_bind_corr_scalar`, the
        # correlated-subquery predicate binder, which has no `BindScope` and so
        # can only constant-fold: `_bind_date_diff` routes two DATE literals
        # here and everything else to `_bind_date_delta`.
        raise Error(
            "SQL not supported: date_diff('day', a, b) requires constant DATE"
            + " literal operands INSIDE A CORRELATED SUBQUERY PREDICATE."
            + " ⚠ THIS IS A LIMIT OF THIS POSITION, NOT OF date_diff: in an"
            + " ordinary projection or filter it reads DATE columns."
            + " The correlated-predicate binder binds no column operand here"
            + " and can only constant-fold"
        )
    return Int64(Int(_date_to_days(d1.text)) - Int(_date_to_days(d0.text)))


def _bind_greatest_least(sx: SqlExpr, dsg: UInt8, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`greatest(a, b)` / `least(a, b)` -> the equivalent `EXPR_WHEN`.

    A PURE BINDER DESUGAR, like `_bind_coalesce` — no new tag, no kernel, no
    pinned counter:

        greatest(a, b) ==
            CASE WHEN a IS NULL THEN b
                 WHEN b IS NULL THEN a
                 WHEN a > b     THEN a
                 ELSE b END

    (`least` is the same with `<`.)

    ⛔ THE FIRST TWO BRANCHES ARE THE WHOLE FUNCTION AND A `MAX(a,b)` READING
    OMITS THEM. DuckDB v1.5.3's `greatest` IGNORES NULLs — measured:
    `greatest(1, NULL)` = 1, `least(NULL, 2)` = 2 — where a bare
    `CASE WHEN a > b THEN a ELSE b END` answers NULL for the first (the
    comparison is UNKNOWN, so the ELSE wins and the ELSE is the null one) and
    NULL for the second. Two silent wrong answers of the shape "the value
    disappeared", which no non-null fixture can show. `greatest(NULL, NULL)`
    is still NULL and falls out: branch 1 fires and its result is the other
    null.

    ⛔ EXACTLY TWO ARGUMENTS, AND MORE IS REFUSED BY NAME RATHER THAN FOLDED.
    DuckDB's form is variadic and the obvious lowering is a left fold
    (`greatest(a,b,c)` = `greatest(greatest(a,b),c)`) — but this desugar
    mentions each operand FOUR times, so a fold squares the tree at every
    step: 3 arguments is 16 copies of `a`, 4 is 64, and the plan the optimizer
    then walks is exponential in the argument count. A refusal that names the
    reason is better than a plan that compiles for three arguments and hangs
    on six. Lifting the cap needs a real N-ary node, not a smarter fold.

    Type unification is the CASE rule again (see `_bind_coalesce`): any float
    argument promotes the integer-literal ones, since every arm must share one
    dtype.
    """
    ref gargs = sx._call.value().args
    if len(gargs) != 2:
        raise Error(
            "SQL not supported: " + sx.text + "() takes exactly 2 arguments"
            " here — got " + String(len(gargs)) + ". It desugars to a CASE"
            " that mentions each operand four times, so folding a third"
            " argument would square the plan"
        )
    var ga = _bind_scalar(gargs[0], schema, scope, catalog, cte_scope, prebound)
    var gb = _bind_scalar(gargs[1], schema, scope, catalog, cte_scope, prebound)
    if _bound_expr_is_float(ga, schema) or _bound_expr_is_float(gb, schema):
        ga = _promote_int_literal_to_float(ga^)
        gb = _promote_int_literal_to_float(gb^)

    # The tree is `scalar_desugar.greatest_least_of`, the builder the
    # dataframe `greatest` / `least` use too.
    return greatest_least_of(dsg == DSG_GREATEST, ga^, gb^)


def _bind_coalesce(sx: SqlExpr, dsg: UInt8, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`coalesce(a, b, ..., z)` / `ifnull(a, b)` -> the equivalent `EXPR_WHEN`.

    `coalesce(a, b, c)` binds to

        CASE WHEN a IS NOT NULL THEN a
             WHEN b IS NOT NULL THEN b
             ELSE c END

    The last argument is the ELSE and is not guarded: `coalesce(a, b)` returns
    `b` even when `b` is itself NULL.

    Arity: `coalesce` is variadic with a 1-argument minimum, and `coalesce(x)`
    is `x` (DuckDB: `coalesce(7)` = 7), returned with no CASE wrapper.
    `ifnull` is exactly 2 arguments in DuckDB and any other count is refused.

    Each guarded argument appears twice in the tree, as the `IS NOT NULL`
    condition and as the `THEN` value; no expression this binder builds has a
    side effect, so that is a cost, not a semantic difference.

    Type unification is the CASE rule: if any argument is float-typed, the
    integer-literal ones are promoted to float literals, so `coalesce(f, 0)`
    binds to an all-float CASE, DuckDB's common type for that pair.
    """
    ref cargs = sx._call.value().args
    var n = len(cargs)
    if dsg == DSG_IFNULL:
        if n != 2:
            raise Error(
                "SQL bind error: ifnull() expects exactly 2 arguments — got "
                + String(n)
            )
    elif n < 1:
        raise Error("SQL bind error: coalesce() expects at least 1 argument")

    # A NULL literal argument is dropped: COALESCE returns its first non-NULL
    # argument, so a NULL literal is never the answer and never changes which
    # argument is (`coalesce(NULL, x)` is `x`, `ifnull(x, NULL)` is `x`), and
    # the result's type is the surviving arguments' (DuckDB v1.5.3:
    # `typeof(coalesce(NULL, a))` is a's type). The arity check above counts
    # the arguments as written. All-NULL (`coalesce(NULL, NULL)`) is refused:
    # DuckDB types it NULL, a column type this engine cannot produce.
    var bound = List[Expr]()
    for i in range(n):
        if cargs[i].tag == SX_NULL:
            continue
        bound.append(_bind_scalar(cargs[i], schema, scope, catalog, cte_scope, prebound))
    if len(bound) == 0:
        raise Error(_BARE_NULL_REFUSAL)
    if len(bound) == 1:
        return bound[0].copy()

    var any_float = False
    for i in range(len(bound)):
        if _bound_expr_is_float(bound[i], schema):
            any_float = True
    if any_float:
        var promoted = List[Expr]()
        for i in range(len(bound)):
            promoted.append(_promote_int_literal_to_float(bound[i].copy()))
        bound = promoted^

    # The tree is `scalar_desugar.coalesce_of`, the builder the dataframe
    # `coalesce` uses too.
    return coalesce_of(bound^)


def _unit_literal_text(sx: SqlExpr, fn_name: String) raises -> String:
    """The lower-folded UNIT string of a `date_part` / `date_trunc` first
    argument, or a clean Error.

    ⚠ THE UNIT MUST BE A CONSTANT AND THAT IS NOT A CONVENIENCE. The unit
    picks the `EXTRACT_*` selector baked into the IR node at BIND time; there
    is no per-row unit dispatch in the engine and inventing one to serve
    `date_part(some_column, ts)` would be a new node, not a name-table row. A
    non-literal unit is refused BY NAME rather than being coerced to whatever
    the expression's text happens to look like.
    """
    if sx.tag != SX_STRING:
        raise Error(
            "SQL not supported: " + fn_name + "() requires a constant string"
            + " unit as its first argument (a column or expression there is not"
            + " supported — the unit selects the IR node at bind time)"
        )
    return sx.text.lower()


def _fn_arity_msg(name: String, kind: UInt8, n: Int) -> String:
    """The arity message the LOWERING FAMILY `kind` states, for a call to `name`
    with `n` arguments.

    ⚠ THE MESSAGE IS A PROPERTY OF THE FAMILY, NOT OF THE NAME, WHICH IS WHY
    THE TABLE CARRIES NUMBERS AND THIS CARRIES WORDS. Every member of a family
    is bound the same way, so a member of a family cannot need a different
    explanation of what its arguments are for. The four texts below are the
    four the pre-table ladder emitted, BYTE FOR BYTE — this function is where a
    behaviour-preserving refactor of thirteen separate arity checks had to put
    them, and a change to any of these strings is a user-visible change.

    ⛔ THE `pow()` LITERAL IS A PRESERVED QUIRK, NOT AN OVERSIGHT. The pre-table
    binder hard-coded `pow()` in this message, so `power(1)` has always been
    told about `pow()`, and it says so under both spellings and at BOTH call
    sites (`_bind_scalar_call` and the post-aggregate path). Fixing it is a
    one-word edit and a DIFFERENT commit from the one that moved it.
    """
    if kind == FNK_MATH_FN2:
        return String("SQL bind error: pow() expects exactly 2 arguments (base, exponent)")
    if kind == FNK_STRING_PRED:
        return (
            String("SQL bind error: ") + name + "() expects exactly 2 arguments"
            + " (string, pattern) — got " + String(n)
        )
    if kind == FNK_EXTRACT_FIELD:
        return (
            String("SQL bind error: ") + name + "() expects exactly 1 argument"
            + " (a DATE or TIMESTAMP expression) — got " + String(n)
        )
    if kind == FNK_STRING_FN or kind == FNK_MATH_FN:
        return (
            String("SQL bind error: ") + name + "() expects exactly 1 argument"
            + " — got " + String(n)
        )
    if kind == FNK_BINARY_OP:
        # ⚠ TWO DIFFERENT SHAPES UNDER ONE FAMILY, so this message states the
        # SHAPE and lets the row state the COUNT. `add`/`subtract` accept 1 or
        # 2 arguments on v1.5.3 and `multiply`/`divide`/`mod` accept only 2;
        # a family message that named a single number would be wrong for one
        # half of the family whichever number it named.
        return (
            String("SQL bind error: ") + name + "() is the function spelling"
            + " of an arithmetic operator and takes 2 arguments (add() and"
            + " subtract() also take 1) — got " + String(n)
        )
    if kind == FNK_CONST:
        # ⚠ THE SHAPE, AND THE ROW STATES THE COUNT — the `FNK_BINARY_OP`
        # precedent, for the same reason: this family has FIVE distinct arities
        # (0, 1, 2..3, 3..4) that DuckDB declares per name, so a family message
        # naming a single number would be wrong for most of its members.
        #
        # ⚠ AND IT SAYS THE ARGUMENTS ARE IGNORED, because that is the fact a
        # caller who miscounted needs: MEASURED v1.5.3, `has_table_privilege(
        # nope, alsonope)` over a table with no such columns returns `true` —
        # the body is a constant and never binds its parameters. Somebody told
        # "wrong number of arguments" about a function that ignores its
        # arguments will otherwise assume the count is ignored too, and DuckDB
        # enforces it (`pg_table_is_visible(1,2)` is a Binder Error there).
        return (
            String("SQL bind error: ") + name + "() is a PostgreSQL"
            + " compatibility constant — its DuckDB v1.5.3 body is a fixed"
            + " value that IGNORES the arguments, but the declared argument"
            + " COUNT is still enforced (DuckDB refuses a miscounted call by"
            + " name, and so does this engine) — got " + String(n)
            + ". See the row in `sql_fn_table.mojo` for the count this name"
            + " declares."
        )
    if kind == FNK_UNARY_NUM:
        # Its own message: the two-argument call is a real DuckDB function
        # (`round(x, 2)`, `trunc(x, 2)`), a digit count this engine cannot
        # carry on a unary node, and dropping the digits would answer a
        # zero-digit round.
        return (
            String("SQL bind error: ") + name + "() takes exactly 1 argument"
            + " here — got " + String(n)
            + ". DuckDB also has a 2-argument round(x, digits) / trunc(x,"
            + " digits); this engine lowers the 1-argument form onto a UNARY"
            + " node that has no slot for a digit count, so the 2-argument"
            + " form is REFUSED rather than rounded to zero digits."
        )
    # A NEW LOWERING KIND WITH NO ARITY MESSAGE MUST SAY SO RATHER THAN INHERIT
    # ONE. Falling through to the "exactly 1 argument" text would hand a future
    # three-argument family a confidently wrong explanation.
    return (
        String("SQL internal: no arity message for lowering kind ")
        + String(Int(kind)) + " (function '" + name + "', " + String(n)
        + " argument(s))"
    )


def _bind_date_part(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`date_part('<unit>', <temporal>)` -> `EXPR_EXTRACT`.

    The parser lowers `EXTRACT(<field> FROM <expr>)` into exactly this shape,
    so both spellings land on this one arm and cannot diverge.

    The unit comes from `sql_date_part_unit` (the specifier namespace), not
    from the function table: `date_part('dow', x)` binds while `dow(x)` is a
    Catalog Error in DuckDB v1.5.3, so the two namespaces differ.
    (`dayofmonth` is in both: a function, a specifier and a `date_trunc`
    period.)
    """
    ref pargs = sx._call.value().args
    if len(pargs) != 2:
        raise Error(
            "SQL bind error: " + sx.text + "() expects (unit, temporal) —"
            + " got " + String(len(pargs)) + " arguments"
        )
    var punit = _unit_literal_text(pargs[0], sx.text)
    var pu = sql_date_part_unit(punit)
    if pu:
        return Expr.extract(
            pu.value(),
            _bind_scalar(pargs[1], schema, scope, catalog, cte_scope, prebound),
        )
    # ⭐ NAMESPACE (2b) — the specifiers that lower to a DESUGAR rather than to
    # a wire unit. Tried SECOND and never merged into the unit lookup: the two
    # tables return tags from different vocabularies (`EXTRACT_*` goes on the
    # wire, `DSG_*` never does) and both are UInt8, so a merged table would
    # encode a desugar id as an extract unit and type-check while doing it.
    var pd = sql_date_part_desugar(punit)
    if pd:
        return _year_derived_over(
            pd.value(),
            _bind_scalar(pargs[1], schema, scope, catalog, cte_scope, prebound),
        )
    # The message's lists are derived: `sql_date_part_supported_summary()`
    # asks `sql_date_part_unit` and `sql_date_part_desugar` about every
    # spelling and renders the served and refused halves from the answers.
    raise Error(
        "SQL not supported: date part '" + punit + "' — "
        + sql_date_part_supported_summary()
    )


def _bind_date_trunc(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`date_trunc('<period>', <temporal>)` -> `EXPR_EXTRACT` with a TRUNC unit.

    ⚠ NAMESPACE (3), which is NOT namespace (2): `date_trunc('millisecond', t)`
    works and `date_part('millisecond', t)` is refused by name.
    """
    ref dargs = sx._call.value().args
    if len(dargs) != 2:
        raise Error(
            "SQL bind error: " + sx.text + "() expects (unit, temporal) —"
            + " got " + String(len(dargs)) + " arguments"
        )
    var dunit = _unit_literal_text(dargs[0], sx.text)
    var du = sql_date_trunc_unit(dunit)
    if not du:
        raise Error(
            "SQL not supported: date_trunc unit '" + dunit + "' — the"
            + " supported periods are year, quarter, month, week, day, hour,"
            + " minute, second, millisecond and microsecond, each with its"
            + " DuckDB aliases (including the field-named periods dayofweek /"
            + " dow / weekday / isodow / dayofyear / doy / julian, which"
            + " truncate to the DAY; weekofyear / yearweek, which truncate to"
            + " the WEEK; and epoch, which truncates to the SECOND)."
            + " (decade / century / millennium / isoyear are real DuckDB"
            + " periods with no unit on this engine's wire; they are refused"
            + " rather than rounded to the nearest period that exists;"
            + " isoyear especially, since 2021-01-01 falls in isoyear 2020)"
        )
    return Expr.date_trunc(
        du.value(),
        _bind_scalar(dargs[1], schema, scope, catalog, cte_scope, prebound),
    )


def _bind_left_right(sx: SqlExpr, dsg: UInt8, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """★ `left` / `right` DESUGAR TO `EXPR_SUBSTRING` — no new tag, no kernel,
    no wire member, no pinned counter. Both are pure index arithmetic over a
    node that already exists, and the arithmetic is MEASURED against DuckDB
    v1.5.3 rather than derived:

        left(s, n)  n >= 0 -> substring(s, 1, n)
        right(s, n) n >  0 -> substring(s, -n)     (a negative start
        right(s, n) n == 0 -> substring(s, 1, 0)    counts from the END)
        right(s, n) n <  0 -> substring(s, 1 - n)

    Verified end to end, INCLUDING the out-of-range and multi-byte cells:
    right('hello',9) = 'hello' = substring('hello',-9); right('Straße',3) =
    'aße' = substring('Straße',-3); right('hello',-4) = 'o' =
    substring('hello',5).

    A negative `n` means "all but", not "nothing": DuckDB's left('hello', -2)
    is 'hel', every character except the last two, which is
    substring(s, 1, length(s) - 2), a run-time length. `right` has no such
    problem, because "all but the first |n|" is substring(s, 1 - n), a
    constant start.

        left(s, n)  n <  0 -> substring(s, 1, n - 1)   <- the shortfall form

    The node carries the shortfall instead: EXPR_SUBSTRING reads a `length` of
    -k (k >= 2) as "to the end, dropping k-1 trailing characters". That
    sentinel family is internal and is not DuckDB's negative-length
    semantics, so `_bind_substring` keeps refusing a negative length literal
    (a user's `substring(s, 3, -1)` would otherwise get this meaning).
    """
    ref lrargs = sx._call.value().args
    if len(lrargs) != 2:
        raise Error(
            "SQL bind error: " + sx.text + "() expects exactly 2 arguments"
            + " (string, count) — got " + String(len(lrargs))
        )
    var lr_child = _bind_scalar(lrargs[0], schema, scope, catalog, cte_scope, prebound)
    var lr_n_e = _bind_scalar(lrargs[1], schema, scope, catalog, cte_scope, prebound)
    if lr_n_e.tag != EXPR_LITERAL or not lr_n_e.literal_value().is_int():
        raise Error(
            "SQL not supported: " + sx.text + "() count must be an integer"
            " literal"
        )
    var lr_n = Int(lr_n_e.literal_value().int_val)
    if dsg == DSG_LEFT:
        if lr_n < 0:
            # `left(s, -n)` = "all but the last |n| characters" (DuckDB
            # v1.5.3's `left('abc', -1)` is `'ab'`). The node carries the
            # shortfall: `length = lr_n - 1` is the sentinel family
            # EXPR_SUBSTRING reads as "to the end, dropping k-1 trailing
            # characters" (-2 -> drop 1, -3 -> drop 2; -1 stays "to end" and
            # is unreachable here because lr_n < 0 makes lr_n - 1 <= -2).
            #
            # Characters, not bytes: DuckDB gives `left('Ünïcodé', -1)` =
            # `'Ünïcod'`, dropping one codepoint. Shorter than |n| is the
            # empty string, not an error: `left('a', -1)` = `''` in v1.5.3.
            return Expr.substring(lr_child^, 1, lr_n - 1)
        return Expr.substring(lr_child^, 1, lr_n)
    if lr_n > 0:
        return Expr.substring(lr_child^, -lr_n, -1)
    if lr_n == 0:
        return Expr.substring(lr_child^, 1, 0)
    return Expr.substring(lr_child^, 1 - lr_n, -1)


def _bind_substring(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """SQL `substring(s, start[, length])` -> EXPR_SUBSTRING over a string child
    (1-based start; omitted length = to end). `start` / `length` must be
    integer literals (`substring(c_phone, 1, 2)`); a non-literal position
    raises. The messages say `substring()` under both spellings, `substr`
    included.
    """
    ref sargs = sx._call.value().args
    if len(sargs) != 2 and len(sargs) != 3:
        raise Error(
            "SQL bind error: substring() expects (string, start[, length]) —"
            + " got " + String(len(sargs)) + " arguments"
        )
    var s_child = _bind_scalar(sargs[0], schema, scope, catalog, cte_scope, prebound)
    var start_e = _bind_scalar(sargs[1], schema, scope, catalog, cte_scope, prebound)
    if start_e.tag != EXPR_LITERAL or not start_e.literal_value().is_int():
        raise Error("SQL not supported: substring() start position must be an integer literal")
    var start = Int(start_e.literal_value().int_val)
    var length = -1
    if len(sargs) == 3:
        var len_e = _bind_scalar(sargs[2], schema, scope, catalog, cte_scope, prebound)
        if len_e.tag != EXPR_LITERAL or not len_e.literal_value().is_int():
            raise Error("SQL not supported: substring() length must be an integer literal")
        length = Int(len_e.literal_value().int_val)
        if length < 0:
            raise Error("SQL bind error: substring() length must be non-negative")
    return Expr.substring(s_child^, start, length)



def _bind_year_derived(sx: SqlExpr, dsg: UInt8, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`century(x)` / `decade(x)` / `millennium(x)` / `era(x)` -> arithmetic
    over `EXPR_EXTRACT(EXTRACT_YEAR, x)`.

    A PURE BINDER DESUGAR: no `EXTRACT_*` unit, no kernel, no wire member, no
    pinned counter. Each of the four is a closed form over the YEAR field this
    engine already extracts.

        century(x)    == CASE WHEN year(x) > 0 THEN (year(x) - 1) / 100  + 1
                              WHEN year(x) <= 0 THEN year(x) / 100  - 1 END
        millennium(x) == CASE WHEN year(x) > 0 THEN (year(x) - 1) / 1000 + 1
                              WHEN year(x) <= 0 THEN year(x) / 1000 - 1 END
        decade(x)     ==  year(x)       / 10
        era(x)        == CASE WHEN year(x) > 0 THEN 1 ELSE 0 END

    ⛔ `century` IS NOT `year / 100` AND `decade` IS NOT `(year - 1) / 10 + 1`.
    The two rules are genuinely different and MEASURED on v1.5.3, not guessed:
    `century(2000-01-01)` = 20 and `century(2100-03-03)` = 21 (so the boundary
    is at ...01, hence the -1/+1), while `decade(2000-01-01)` = 200 and
    `decade(0001-01-01)` = 0 (so decade is the plain truncating divide, and the
    -1/+1 form would answer 201 and 1). Using either rule for all three names
    is wrong for roughly a third of all years, and right for the other two
    thirds — which is why no fixture of nearby dates can discriminate them.

    The BC branch is reachable: a TIMESTAMP built from raw int64 microseconds
    carries a BC instant, `EXTRACT_YEAR` decodes it, and every name here is a
    function of that year (`century` of 44 BC is -1 in DuckDB).

    ⚠ THE DIVISION IS `BIN_DIV` OVER I64, i.e. TRUNCATING TOWARD ZERO, and
    that is CORRECT AT EVERY SIGN for `decade`: measured v1.5.3,
    `decade` over years -2001/-1000/-44/-1 is -200/-100/-4/0, which is exactly
    truncation. ⛔ DO NOT "FIX" `decade` TO A FLOORING DIVIDE — flooring
    answers -201/-100/-5/-1 and is wrong on three of those four rows.
    `century`/`millennium` are the ones that need a branch, and they need it
    because DuckDB's numbering has no zero, not because of a rounding mode;
    the full argument and the measured table are on `_year_derived_over`.

    ⚠ `era` USES `EXPR_WHEN`, WHICH TAKES ITS OUTPUT DTYPE FROM THE `ELSE`
    COLUMN and requires every `THEN` to agree — both branches here are INT64
    literals, so the rule is satisfied by construction. DuckDB's `era` is 1 for
    AD and 0 for BC (measured on all six probe dates: all 1). Writing it as the
    literal 1 would be green on every fixture and would be a fact about this
    engine's DATE range rather than about `era`.
    """
    ref yargs = sx._call.value().args
    if len(yargs) != 1:
        raise Error(
            "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            " (a DATE or TIMESTAMP expression) — got " + String(len(yargs))
        )
    return _year_derived_over(
        dsg, _bind_scalar(yargs[0], schema, scope, catalog, cte_scope, prebound)
    )


def _year_derived_over(dsg: UInt8, var child: Expr) raises -> Expr:
    """The closed form ITSELF, over an ALREADY-BOUND temporal child.

    ★ SPLIT OUT OF `_bind_year_derived` SO THE SPECIFIER SPELLING CANNOT
    DRIFT FROM THE FUNCTION SPELLING. `century(v)` and `date_part('century',
    v)` are the same DuckDB value (measured on six dates), so they must be the
    same lowering — and the way to guarantee that is for there to be ONE
    lowering, reached from two arities, rather than two call sites that agree
    today. `_bind_year_derived` keeps the arity check because its message names
    a 1-argument function; `_bind_date_part` has already checked its own 2.
    """
    # The trees are `scalar_desugar.year_derived_of`, the builder the dataframe
    # `.century()` / `.decade()` / `.millennium()` / `.era()` use too.
    var which = YEAR_DERIVED_CENTURY
    if dsg == DSG_DECADE:
        which = YEAR_DERIVED_DECADE
    elif dsg == DSG_MILLENNIUM:
        which = YEAR_DERIVED_MILLENNIUM
    elif dsg == DSG_ERA:
        which = YEAR_DERIVED_ERA
    return year_derived_of(which, child^)



def _bind_nanosecond(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`nanosecond(x)` -> `EXPR_EXTRACT(EXTRACT_MICROSECOND, x) * 1000`.

    It is not "the nanosecond field": in DuckDB v1.5.3, on
    `2021-09-04 12:30:45.123456`, `second` = 45, `millisecond` = 45123,
    `microsecond` = 45123456 and `nanosecond` = 45123456000. The family folds
    the seconds in, so `nanosecond` is `microsecond * 1000`. A TIMESTAMP's
    resolution is microseconds here as in DuckDB, so the three trailing zeros
    are DuckDB's too.
    """
    ref nargs = sx._call.value().args
    if len(nargs) != 1:
        raise Error(
            "SQL bind error: nanosecond() expects exactly 1 argument"
            " (a DATE or TIMESTAMP expression) — got " + String(len(nargs))
        )
    # The tree is `scalar_desugar.nanosecond_of`, the builder the dataframe
    # `nanosecond()` uses too.
    return nanosecond_of(
        _bind_scalar(nargs[0], schema, scope, catalog, cte_scope, prebound)
    )



def _bind_float_class(sx: SqlExpr, dsg: UInt8, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`isfinite(x)` / `isinf(x)` / `isnan(x)` -> pure COMPARISONS.

    A PURE BINDER DESUGAR: no op, no kernel, no wire member, no pinned counter.

        isfinite(x) == x > -inf AND x < inf
        isinf(x)    == x  =  inf OR  x  = -inf
        isnan(x)    == NOT isfinite(x) AND NOT isinf(x)

    Verified against DuckDB v1.5.3 over {1.5, nan, inf, -inf, 0.0, -1e308,
    NULL} — all seven rows, all three functions, EXACT, NULL included.

    ⛔⛔ THE OBVIOUS `isnan(x) == x <> x` IS WRONG AGAINST DuckDB. MEASURED:
    `'nan'::double = 'nan'::double` is **TRUE** there and `'nan'::double >
    'inf'::double` is **TRUE** — DuckDB orders floats TOTALLY (NaN equals
    itself and sorts above +inf) rather than by IEEE-754. So the C/Python
    idiom every reader reaches for answers FALSE for a NaN on the parity
    target, and is green on any fixture that has no NaN in it.

    ⭐ THE FORMS ABOVE ARE THE ONES THAT ARE CORRECT UNDER **BOTH** ORDERINGS,
    which is why they are written this way and not more directly. `x > -inf
    AND x < inf` is false for a NaN under IEEE (both comparisons false) AND
    false under a total order (`nan < inf` is false), so whichever model this
    engine's own float comparison follows, the answer is DuckDB's. A desugar
    whose correctness depends on an unstated comparison model is a bet.

    ⚠ `isnan` MENTIONS ITS OPERAND FOUR TIMES (twice via `isfinite`, twice via
    `isinf`) and that is a FIXED cost, not a fold: unlike `greatest`, there is
    no variadic form to square it. `isinf` mentions it twice, `isfinite` twice.

    ⛔ `signbit` IS NOT HERE AND CANNOT BE. It reads the SIGN BIT, which no
    comparison can see — `-0.0 = 0.0` is TRUE, so `x < 0` is FALSE for a
    negative zero. That is the same blindness that made the `abs` CASE-desugar
    wrong (see `UN_ABS`), and it needs a real kernel.
    """
    ref cargs = sx._call.value().args
    if len(cargs) != 1:
        raise Error(
            "SQL bind error: " + sx.text + "() expects exactly 1 argument"
            " (a numeric expression) — got " + String(len(cargs))
        )
    var cx = _bind_scalar(cargs[0], schema, scope, catalog, cte_scope, prebound)
    # The trees are `scalar_desugar.float_class_of`, the builder the dataframe
    # `.is_finite()` / `.is_infinite()` / `.is_nan()` use too.
    if dsg == DSG_ISFINITE:
        return float_class_of(FLOAT_CLASS_FINITE, cx^)
    if dsg == DSG_ISINF:
        return float_class_of(FLOAT_CLASS_INFINITE, cx^)
    return float_class_of(FLOAT_CLASS_NAN, cx^)



def _bind_string_split(sx: SqlExpr, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`string_split(s, sep)` -> `EXPR_REGEXP(REGEXP_SPLIT_TO_ARRAY, s,
    regexp_escape(sep))`.

    The op is `regexp_split_to_array`'s, whose separator is a pattern;
    `string_split`'s is a literal, and the escape is the only difference. In
    DuckDB v1.5.3, including the edges:
      `string_split('a.b.c','.')` = ['a','b','c']  (the escape is why: an
          unescaped `.` splits on every character)
      `string_split('abc','')`    = ['a','b','c']  — and the regexp form with
          an empty pattern gives the SAME answer, so the empty separator needs
          no special case
      `string_split('abc','x')`   = ['abc']        — no match is ONE part
      `string_split('','x')`      = ['']           — one EMPTY part, not []
      `string_split(NULL,'.')`    = NULL

    The escape is `regexp_escape_str` in `komira_column_kernels`, the function
    behind `regexp_escape` itself: it escapes everything that is not
    `[A-Za-z0-9_]`.

    ⚠ THE SEPARATOR MUST BE A PLAN-TIME LITERAL. That is `EXPR_REGEXP`'s own
    envelope (`RegexpData.pattern` is a `String`, not an `Expr`, because the
    NFA compiles once per batch), not a shortcut taken here — the same rule
    `regexp_split_to_array` states.
    """
    ref sargs = sx._call.value().args
    if len(sargs) != 2:
        raise Error(
            "SQL bind error: " + sx.text + "() expects exactly 2 arguments"
            " (string, separator) — got " + String(len(sargs))
        )
    var subject = _bind_scalar(sargs[0], schema, scope, catalog, cte_scope, prebound)
    var sep_expr = _bind_scalar(sargs[1], schema, scope, catalog, cte_scope, prebound)
    var sep = _regexp_literal_string(sep_expr^, sx.text, String("separator"))
    return Expr.regexp(
        REGEXP_SPLIT_TO_ARRAY, subject^, regexp_escape_str(sep)
    )



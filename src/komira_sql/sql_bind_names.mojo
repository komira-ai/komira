# =============================================================================
# komira_sql/sql_bind_names.mojo
#   Group-key matching and the DuckDB-style output names of aggregates and
#   expressions.
# =============================================================================

from komira_arrow.schema import Schema
from komira_sql.sql_ast import (
    SXAGG_COUNT, SXAGG_MAX, SXAGG_MIN, SXAGG_SUM, SXLIKE_ILIKE, SXOP_ADD, SXOP_AND,
    SXOP_CONCAT, SXOP_EQ, SXOP_GE, SXOP_GT, SXOP_IDIV, SXOP_LE, SXOP_LT, SXOP_MOD,
    SXOP_MUL, SXOP_NE, SXOP_OR, SXOP_POW, SXOP_STARTS_WITH, SXOP_SUB, SXUN_ABS,
    SXUN_IS_NOT_NULL, SXUN_IS_NULL, SXUN_NEGATE, SX_AGG, SX_BINARY, SX_BOOL, SX_CALL,
    SX_CASE, SX_COLUMN, SX_DATE, SX_FLOAT, SX_INT, SX_LIKE, SX_NULL, SX_STAR, SX_STRING,
    SX_SUBQUERY, SX_TIMESTAMP, SX_UNARY, SelectStmt, SqlExpr, TSLIT_AWARE,
)
from komira_sql.sql_bind_ops import _sx_is_big_int
from komira_sql.sql_bind_scope import _schema_has_col
from komira_sql.sql_fn_table import (
    CAST_DESUGAR_NAME, POSITION_IN_DESUGAR_NAME, TRY_CAST_DESUGAR_NAME,
)


@always_inline
def _group_has(group_names: List[String], name: String) -> Bool:
    var t = name.lower()
    for i in range(len(group_names)):
        if group_names[i].lower() == t:
            return True
    return False


def _group_spelling(group_names: List[String], name: String) -> String:
    """`_group_has`'s question, answered with the MATCHED spelling instead of a
    Bool ("" when there is no match). See `_schema_col_spelling` for why a keyed
    join needs the spelling and not the predicate."""
    var t = name.lower()
    for i in range(len(group_names)):
        if group_names[i].lower() == t:
            return String(group_names[i])
    return String("")


# =============================================================================
# The SQL surface's name for an unaliased aggregate or expression
# =============================================================================
#
# The SQL standard does not decide this: a `<derived column>` that is not a
# bare `<column reference>` and carries no `<as clause>` gets an
# implementation-dependent name. For `SELECT count(DISTINCT user_id) FROM t`:
#
#     DuckDB 1.5.3      -> count(DISTINCT user_id)   canonical deparse
#     PostgreSQL 18.4   -> count                     the function name
#     SQLite 3.53.3     -> count(distinct user_id)   the raw source text
#     polars 1.43.2 SQL -> user_id                   the input column
#
# This surface follows DuckDB: SQL queries here are written against DuckDB
# semantics, and its rule is collision-free across distinct expressions
# (`min(v)` vs `min(user_id)` differ on their own, where PostgreSQL emits `min`
# twice). The plan carries the name; each surface authors its own.
# =============================================================================


def _sxop_text(op: UInt8) -> StaticString:
    """The operator token DuckDB's expression printer emits for a SX_BINARY.

    These are DuckDB v1.5.3's output strings, not the input grammar's; `<>`
    prints as `!=`:

        SELECT max(a <> b)          -> max((a != b))
        SELECT max(a = 1 AND b = 2) -> max(((a = 1) AND (b = 2)))
        SELECT sum(a + b)           -> sum((a + b))

    Returns `StaticString` (a `-> String` function returning three or more
    literals is a shape this tree avoids)."""
    if op == SXOP_EQ:
        return "="
    if op == SXOP_NE:
        return "!="
    if op == SXOP_LT:
        return "<"
    if op == SXOP_LE:
        return "<="
    if op == SXOP_GT:
        return ">"
    if op == SXOP_GE:
        return ">="
    if op == SXOP_AND:
        return "AND"
    if op == SXOP_OR:
        return "OR"
    if op == SXOP_ADD:
        return "+"
    if op == SXOP_SUB:
        return "-"
    if op == SXOP_MUL:
        return "*"
    if op == SXOP_IDIV:
        return "//"
    if op == SXOP_MOD:
        return "%"
    # DuckDB v1.5.3 prints `(a ^ 2)`, `(s || 'x')`, `(s ^@ 'a')` as written.
    if op == SXOP_POW:
        return "^"
    if op == SXOP_CONCAT:
        return "||"
    if op == SXOP_STARTS_WITH:
        return "^@"
    return "/"


def _sxagg_text(op: UInt8) -> StaticString:
    """The function name DuckDB prints for a SX_AGG, by code: the fallback.
    `_duckdb_agg_text` prefers the source spelling the parser carries on the
    node (`SqlExpr.agg(..., spelling=name)`), because a code may have two
    spellings (`mean` is `avg`'s alias) and DuckDB prints the one written. In
    DuckDB v1.5.3, over a column:

        SELECT avg(v)   -> column `avg(v)`
        SELECT mean(v)  -> column `mean(v)`
        SELECT MEAN(v)  -> column `mean(v)`     (function lower-folded)
        SELECT SUM(A)   -> column `sum(A)`      (argument case preserved)

    This map answers for a node built by anything other than the parser. It
    returns `StaticString` (a `-> String` function returning three or more
    literals is a shape this tree avoids)."""
    if op == SXAGG_SUM:
        return "sum"
    if op == SXAGG_COUNT:
        return "count"
    if op == SXAGG_MIN:
        return "min"
    if op == SXAGG_MAX:
        return "max"
    return "avg"


comptime _DK_STAR: UInt8 = 0
comptime _DK_TRUE: UInt8 = 1
comptime _DK_FALSE: UInt8 = 2
comptime _DK_SUBQUERY: UInt8 = 3
comptime _DK_UNNAMED: UInt8 = 4


def _duckdb_const_text(kind: UInt8) -> StaticString:
    """The five deparse arms whose answer is a constant, kept out of
    `_duckdb_expr_text` so that function returns no literal itself (a
    `-> String` function returning three or more literals is a shape this
    tree avoids; `-> StaticString` is the safe one).

    In DuckDB v1.5.3:

        max(true)           -> max(CAST('t' AS BOOLEAN))    BOOLEAN unquoted,
        max(false)          -> max(CAST('f' AS BOOLEAN))      where DATE is not

    `*` never appears alone (count(*) is `count_star()`); `(SELECT ...)` and
    `?column?` are the two fallbacks not taken from DuckDB (see
    `_duckdb_expr_text`)."""
    if kind == _DK_STAR:
        return "*"
    if kind == _DK_TRUE:
        return "CAST('t' AS BOOLEAN)"
    if kind == _DK_FALSE:
        return "CAST('f' AS BOOLEAN)"
    if kind == _DK_SUBQUERY:
        return "(SELECT ...)"
    return "?column?"


def _duckdb_agg_text(sx: SqlExpr) raises -> String:
    """The output column name DuckDB gives an UNALIASED aggregate call.

    In DuckDB v1.5.3:

        SELECT count(*)             -> count_star()   ⚠ NOT `count(*)`
        SELECT count(a)             -> count(a)
        SELECT count(DISTINCT a)    -> count(DISTINCT a)
        SELECT COUNT( DISTINCT  a ) -> count(DISTINCT a)   ws normalised
        SELECT sum(a)               -> sum(a)
        SELECT min(DISTINCT a)      -> min(DISTINCT a)

    ★ `count(*)` IS THE ONE THAT IS NOT `fn(arg)`. DuckDB has a distinct
    `count_star` function and prints its CALL form, parentheses and all. Getting
    this wrong is silent — `count(*)` looks right, and is in fact what SQLite
    returns.

    The function name is the source token, not the code's canonical spelling:
    `sql_agg_code` maps both `avg` and its DuckDB alias `mean` onto
    `SXAGG_AVG`, and DuckDB v1.5.3 names a `SELECT mean(v)` column
    `mean(v)`. An empty `text` (a node not built by the parser) falls back to
    the code's spelling. `count(*)` composes: the token is `count` and the
    star arm appends `_star()`."""
    var fname: String
    if sx.text.byte_length() != 0:
        fname = sx.text.copy()
    else:
        fname = String(_sxagg_text(sx.op))
    ref arg = sx._agg.value().arg[]
    if arg.tag == SX_STAR:
        # COUNT(*). Written as a SHAPE test rather than `sx.op == SXAGG_COUNT`
        # because the parser admits the STAR sentinel after any `_agg_code`
        # name, so the shape is the thing that is actually true here.
        fname += "_star()"
        return fname^
    var inner = _duckdb_expr_text(arg)
    if sx.agg_distinct:
        fname += "(DISTINCT " + inner + ")"
        return fname^
    fname += "(" + inner + ")"
    return fname^


def _duckdb_expr_text(sx: SqlExpr) raises -> String:
    """DuckDB's canonical printed form of a scalar expression.

    A deparse, not an echo of the source text (echoing is SQLite's rule,
    which SQLite documents as unspecified). DuckDB v1.5.3 (argument shapes;
    the call wrapper is `_duckdb_agg_text` above):

        count(a)                    -> count(a)
        sum(t.a)                    -> sum(t.a)              qualifier kept
        SUM(A)                      -> sum(A)                arg case kept
        sum(a + b)                  -> sum((a + b))          parens added
        sum(a * (1 - b))            -> sum((a * (1 - b)))
        max(a <> b)                 -> max((a != b))
        max(a = 1 AND b = 2)        -> max(((a = 1) AND (b = 2)))
        max(a IS NULL)              -> max((a IS NULL))
        max(a IS NOT NULL)          -> max((a IS NOT NULL))
        max(s LIKE 'x%')            -> max((s ~~ 'x%'))
        max(s NOT LIKE 'x%')        -> max((s !~~ 'x%'))
        sum(1.5)                    -> sum(1.5)
        sum(abs(a))                 -> sum(abs(a))
        min(date '1995-03-15')      -> min(CAST('1995-03-15' AS "DATE"))
        max(true)                   -> max(CAST('t' AS BOOLEAN))

    Not byte-exact with DuckDB:

      * `NOT x`: DuckDB folds `NOT (a = 1)` to `(a != 1)` at parse time; this
        writes `(NOT x)`.
      * SX_CASE: DuckDB prints `CASE  WHEN ((c)) THEN (r) ELSE e END`; the
        form below is close but not claimed byte-exact.
      * SX_SUBQUERY: written as `(SELECT ...)`.

    In each of those the name is still deterministic and contains the
    expression."""
    if sx.tag == SX_COLUMN:
        if sx.qualifier != "":
            return sx.qualifier + "." + sx.text
        return sx.text.copy()
    if sx.tag == SX_INT:
        if _sx_is_big_int(sx):
            return sx.text.copy()
        return String(sx.int_val)
    if sx.tag == SX_FLOAT:
        return String(sx.float_val)
    if sx.tag == SX_STRING:
        return "'" + sx.text + "'"
    if sx.tag == SX_DATE:
        # DuckDB: `min(date '1995-03-15')` -> `min(CAST('1995-03-15' AS "DATE"))`
        # — DuckDB QUOTES the type name here.
        return "CAST('" + sx.text + "' AS \"DATE\")"
    if sx.tag == SX_TIMESTAMP:
        # DuckDB v1.5.3 spells the two keywords differently:
        #   min(TIMESTAMP   '...')  -> min(CAST('...' AS TIMESTAMP))
        #   typeof(TIMESTAMPTZ '...') -> typeof(CAST('...' AS "TIMESTAMP WITH TIME ZONE"))
        # i.e. TIMESTAMP is unquoted where DATE is quoted, and the tz form is
        # not spelled `TIMESTAMPTZ`.
        if sx.op == TSLIT_AWARE:
            return "CAST('" + sx.text + "' AS \"TIMESTAMP WITH TIME ZONE\")"
        return "CAST('" + sx.text + "' AS TIMESTAMP)"
    if sx.tag == SX_NULL:
        return String("NULL")
    if sx.tag == SX_BOOL:
        # DuckDB: `max(true)` -> `max(CAST('t' AS BOOLEAN))` — and BOOLEAN is
        # UNQUOTED where DATE above is quoted. DuckDB's own inconsistency,
        # reproduced rather than tidied.
        if sx.int_val != 0:
            return String(_duckdb_const_text(_DK_TRUE))
        return String(_duckdb_const_text(_DK_FALSE))
    if sx.tag == SX_STAR:
        return String(_duckdb_const_text(_DK_STAR))
    if sx.tag == SX_BINARY:
        var lhs = _duckdb_expr_text(sx._binary.value().left[])
        var rhs = _duckdb_expr_text(sx._binary.value().right[])
        var bout = String("(")
        bout += lhs + " " + String(_sxop_text(sx.op)) + " " + rhs + ")"
        return bout^
    if sx.tag == SX_LIKE:
        var lchild = _duckdb_expr_text(sx._agg.value().arg[])
        var lout = String("(")
        lout += lchild
        # DuckDB v1.5.3: ILIKE prints `~~*`, NOT ILIKE `!~~*`.
        var star = String("*") if sx.op == SXLIKE_ILIKE else String("")
        if sx.like_negate:
            lout += " !~~" + star + " '"
        else:
            lout += " ~~" + star + " '"
        lout += sx.text + "')"
        return lout^
    if sx.tag == SX_UNARY:
        var uchild = _duckdb_expr_text(sx._agg.value().arg[])
        var uout = String("(")
        if sx.op == SXUN_IS_NULL:
            uout += uchild + " IS NULL)"
        elif sx.op == SXUN_IS_NOT_NULL:
            uout += uchild + " IS NOT NULL)"
        elif sx.op == SXUN_NEGATE:
            # DuckDB v1.5.3: `-a` prints `-(a)`, `-(a + 1)` prints
            # `-((a + 1))` — the prefix and then the operand's own parens.
            return "-(" + uchild + ")"
        elif sx.op == SXUN_ABS:
            # DuckDB v1.5.3: `@a` prints `@(a)`, `@ -3 + 1` `@((-3 + 1))`.
            return "@(" + uchild + ")"
        else:
            uout += "NOT " + uchild + ")"
        return uout^
    if sx.tag == SX_CALL:
        # The two CAST desugars render as cast syntax, not as a call: both
        # `CAST(x AS T)` and `x::T` name the column `CAST(v AS DOUBLE)` in
        # DuckDB v1.5.3, while the generic arm below would print the desugar's
        # internal name (`cast as(v, double)`). The parser builds two
        # arguments; a malformed node falls back to the generic shape.
        if sx.text == CAST_DESUGAR_NAME or sx.text == TRY_CAST_DESUGAR_NAME:
            ref kargs = sx._call.value().args
            var kw = String("TRY_CAST(") if sx.text == TRY_CAST_DESUGAR_NAME else String("CAST(")
            if len(kargs) == 2 and kargs[1].tag == SX_STRING:
                kw += _duckdb_expr_text(kargs[0]) + " AS " + kargs[1].text.upper() + ")"
                return kw^
        if sx.text == POSITION_IN_DESUGAR_NAME:
            # DuckDB v1.5.3: `POSITION('b' IN s)` prints
            # `main."position"(s, 'b')`, haystack first, the order the parser
            # stored.
            ref pargs = sx._call.value().args
            var pout = String('main."position"(')
            for pi in range(len(pargs)):
                if pi > 0:
                    pout += ", "
                pout += _duckdb_expr_text(pargs[pi])
            pout += ")"
            return pout^
        var cout = sx.text.copy()
        cout += "("
        ref cargs = sx._call.value().args
        for i in range(len(cargs)):
            if i > 0:
                cout += ", "
            cout += _duckdb_expr_text(cargs[i])
        cout += ")"
        return cout^
    if sx.tag == SX_AGG:
        return _duckdb_agg_text(sx)
    if sx.tag == SX_CASE:
        ref cd = sx._case.value()
        var kout = String("CASE ")
        for i in range(len(cd.conds)):
            kout += " WHEN (" + _duckdb_expr_text(cd.conds[i]) + ") THEN ("
            kout += _duckdb_expr_text(cd.results[i]) + ")"
        if len(cd.otherwise) > 0:
            kout += " ELSE " + _duckdb_expr_text(cd.otherwise[0])
        kout += " END"
        return kout^
    if sx.tag == SX_SUBQUERY:
        return String(_duckdb_const_text(_DK_SUBQUERY))
    # PostgreSQL's placeholder for an expression it will not name — a
    # deliberately RECOGNISABLE last resort, not a silent empty string.
    return String(_duckdb_const_text(_DK_UNNAMED))


def _unaliased_agg_out_name(
    sx: SqlExpr, group_names: List[String], taken: List[String]
) raises -> String:
    """The output name for a bare aggregate SELECT item that carries no `AS`:
    DuckDB's name, the deparse `_duckdb_expr_text` gives (`count_star()`,
    `sum(a)`, `count(DISTINCT x)`, `median(q)`, `stddev(q)`; the name follows
    the source token, so `stddev(q)` does not become `stddev_samp(q)`).

    The binder still forces an alias, and it must be unique: the
    post-aggregate reorder Project references each aggregate by name, so two
    `col_ref("sum(a)")` would both resolve to the first column. So an exact
    duplicate gets `_1`, `_2`, ... (DuckDB itself names both columns of
    `SELECT sum(a), sum(a)` `sum(a)`); distinct expressions are distinct
    names on their own.

    `taken` must already hold every name that is spoken for: the GROUP BY
    columns and the aggregate names assigned so far.

    It deparses through `_duckdb_expr_text`, the tag dispatcher, because the
    aggregates ride two grammars: `sum(q)` is an `SX_AGG` and `median(q)` an
    `SX_CALL`.
    """
    var base = _duckdb_expr_text(sx)
    var candidate = base.copy()
    var n = 1
    while _group_has(group_names, candidate) or _group_has(taken, candidate):
        candidate = base + "_" + String(n)
        n += 1
    return candidate^


def _select_alias_index(stmt: SelectStmt, name: String) -> Int:
    """Index of the SELECT item whose `AS` alias is `name`, else -1.

    ⛔ THIS IS A FALLBACK, NEVER AN OVERRIDE. Its ONE caller consults it only
    after establishing that NO INPUT COLUMN answers `name`, because SQL gives
    the input column precedence — see `_bind_aggregate`'s group-key loop.

    First match wins on a duplicated alias, which is the only reading available
    for `SELECT a AS x, b AS x ... GROUP BY x`."""
    var t = name.lower()
    for i in range(len(stmt.select_items)):
        ref it = stmt.select_items[i]
        if it.out_alias:
            if String(it.out_alias.value()).lower() == t:
                return i
    return -1


def _canon_index(canons: List[String], is_col: List[Bool], canon: String, col: Bool) -> Int:
    """Index of the group key whose canonical form is `canon`, else -1.

    Column keys compare CASE-INSENSITIVELY (matching `_schema_has_col` and the
    `_group_has` this replaces, so `SELECT K ... GROUP BY k` still matches);
    expression keys compare EXACTLY, because a deparsed expression carries
    string literals whose case is DATA — `CASE WHEN s = 'A'` and
    `CASE WHEN s = 'a'` are different keys, not two spellings of one."""
    for i in range(len(canons)):
        if is_col[i] != col:
            continue
        if col:
            if canons[i].lower() == canon.lower():
                return i
        elif canons[i] == canon:
            return i
    return -1


@always_inline
def _sx_is_literal(sx: SqlExpr) -> Bool:
    """True iff `sx` is a LITERAL SCALAR node — a value written out in the query
    text, not an expression that happens to evaluate to one.

    The test is on the tag: `1 + 1` arrives as `SX_BINARY` (this frontend does
    no constant folding), and its one caller elides a GROUP BY key on this
    answer.

    No NULL arm: a literal NULL key would partition nothing either, but the
    key's computed-key path binds it through `_bind_scalar`, which refuses a
    bare NULL by name.

    `SX_DATE`, `SX_TIMESTAMP` and `SX_BOOL` are literals even though the
    parser reaches them through its identifier arm (`date '1995-03-15'`,
    `timestamp '2021-01-01 00:00:00'`, `true`)."""
    return (
        sx.tag == SX_INT
        or sx.tag == SX_FLOAT
        or sx.tag == SX_STRING
        or sx.tag == SX_DATE
        or sx.tag == SX_TIMESTAMP
        or sx.tag == SX_BOOL
    )


def _gb_const_canon(stmt: SelectStmt, gsx: SqlExpr, schema: Schema) raises -> String:
    """The canonical form of a GROUP BY term that is a LITERAL CONSTANT, or ""
    if the term is not one.

    ⛔⛔ THE ORDINAL IS RESOLVED **FIRST**, AND THAT ORDER IS THE WHOLE
    CORRECTNESS ARGUMENT. `GROUP BY 1` is an ORDINAL naming select item 1; the
    constant 1 cannot be spelled as a bare integer in a GROUP BY at all. The two
    arrive as the SAME `SX_INT` node — different things that look identical — so
    classifying the TERM instead of the item it names would read

        SELECT url, count(*) FROM hits GROUP BY 1, referer

    as (constant, referer), elide the "constant", and group by `referer` ALONE.
    This mirrors step (1) of `_bind_aggregate`'s own loop deliberately, with the
    same precedence: an INPUT COLUMN beats a SELECT alias, so the alias table is
    consulted only for a name no column answers.

    ⚠ `""` IS AN UNAMBIGUOUS "NOT A CONSTANT": no literal deparses to the empty
    string. `_duckdb_expr_text` writes `''` (two bytes) for the empty string
    literal, digits for numbers, and `CAST('...' AS ...)` for DATE/BOOLEAN.

    ⚠ AN OUT-OF-RANGE ORDINAL RETURNS `""` RATHER THAN RAISING. The range
    diagnostic belongs to the loop that already reports it; raising it from a
    function whose name says nothing about ordinals would move the message away
    from the code that owns it."""
    var sel = -1
    if gsx.tag == SX_INT:
        # A literal past BIGINT carries wrapped bits in `int_val`: read it as
        # out of range, never as the wrapped ordinal.
        var ordn = -1 if _sx_is_big_int(gsx) else Int(gsx.int_val)
        if ordn < 1 or ordn > len(stmt.select_items):
            return String("")
        sel = ordn - 1
    elif gsx.tag == SX_COLUMN and gsx.qualifier == "" and not _schema_has_col(schema, gsx.text):
        sel = _select_alias_index(stmt, gsx.text)
    if sel >= 0:
        ref it = stmt.select_items[sel]
        if it.is_star or not _sx_is_literal(it.expr):
            return String("")
        return _duckdb_expr_text(it.expr)
    if not _sx_is_literal(gsx):
        return String("")
    return _duckdb_expr_text(gsx)



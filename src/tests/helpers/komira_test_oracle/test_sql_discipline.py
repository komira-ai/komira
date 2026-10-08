"""sql_discipline.py refuses each rule a query breaks, and only those.

Each refused query breaks one rule, and the test requires the refusal to
name the place DuckDB's parse keeps the offence (`.arg_orders[0]`,
`.sample`, `.limit.`...), so a check that refuses for some other reason
does not pass for it. Each ORDER BY and literal query is also accepted with
its rule kept, so a check that refuses everything near the offence is
caught too.
`json_serialize_sql` only parses: no table is created or read (the list
check reads DuckDB's function catalog, `duckdb_functions()`).

What it proves, and the defect it catches:

- ORDER BY: a key of the query, of a window's OVER clause and of a window
  function's own argument ordering (`first_value(x ORDER BY y) OVER ()`,
  `string_agg(x ORDER BY y) OVER ()`, which DuckDB keeps in `arg_orders`,
  not `orders`) must state ASC or DESC and NULLS FIRST or NULLS LAST.
  Catches a check that reads `orders` only.
- literals: an uncast literal is refused; a literal that is the LIMIT or
  OFFSET count is not; a literal inside a subquery computing the count is.
  Catches an exemption inherited by everything below the LIMIT.
  The count `(SELECT a FROM t WHERE a = 2)` reaches its literal through
  dicts only, so it catches an exemption inherited below the LIMIT even
  when every list still resets it.
- randomness and clocks: random(), now(), ICU's current_localtime() and
  current_localtimestamp() and a sample (`USING SAMPLE`, `TABLESAMPLE`, at
  the SELECT and at the table reference) are refused. Catches a random rule
  that looks only at function calls.
- built-in macros and session reads: `ago()`, `pg_postmaster_start_time()`
  and `pg_conf_load_time()` (macros over `current_timestamp`),
  `current_schema()`, a `duckdb_`/`pragma_` table function and a one-argument
  `age()` are refused; two-argument `age()` is accepted. Catches a list that
  names the clock functions but not the macros DuckDB expands into them.
- the list is DuckDB's own: every function the running DuckDB marks VOLATILE
  or CONSISTENT_WITHIN_QUERY in `duckdb_functions()` (but `error`), and
  every macro whose `macro_definition` reaches one of those, a value keyword
  that binds to one, or a `duckdb_`/`pragma_` function, directly or through
  another macro, must be in `_UNSTABLE` (or carry a session prefix). Catches
  a missing name today and a DuckDB upgrade that adds one.
- SQL value keywords: each of the eleven names DuckDB's binder maps to a
  call (`current_timestamp`, `localtime`, `user`...), lowercase and
  uppercase, quoted, qualified by `alias` (and by `ALIAS`: DuckDB compares
  the qualifier without case), in a WHERE, inside a table function's
  argument and inside a `COLUMNS(...)` expression, is refused; the same
  names qualified by a table (`t.current_date`, `t."current_timestamp"`) and
  names that only begin or end like one are accepted. Catches a clock rule
  that reads FUNCTION nodes only (the keywords are COLUMN_REFs in the
  parse), a missing name, a missed binding place, and a rule that refuses
  every column so named.
- one SELECT: two statements and a DELETE are refused (the DELETE by
  `json_serialize_sql` itself, which serializes only SELECTs).
"""

import json

import duckdb

import sql_discipline

FAILURES = []

# Every name DuckDB v1.5.6's GetSQLValueFunctionName maps, and the call it
# makes, in DuckDB's lowercase and in the SQL standard's uppercase.
_MAP = [
    ("current_catalog", "current_catalog"),
    ("current_date", "current_date"),
    ("current_role", "current_role"),
    ("current_schema", "current_schema"),
    ("current_time", "get_current_time"),
    ("current_timestamp", "get_current_timestamp"),
    ("current_user", "current_user"),
    ("localtime", "current_localtime"),
    ("localtimestamp", "current_localtimestamp"),
    ("session_user", "session_user"),
    ("user", "user"),
]
KEYWORDS = _MAP + [(name.upper(), target) for name, target in _MAP]

# (query, a fragment, or a tuple of fragments, the refusal must contain)
REFUSED = [
    # ORDER BY of the query.
    ("SELECT a FROM t ORDER BY a ASC", "orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    ("SELECT a FROM t ORDER BY a NULLS LAST", "orders[0]: an ORDER BY key without ASC or DESC"),
    # A window's OVER clause.
    ("SELECT row_number() OVER (ORDER BY a ASC) FROM t",
     "orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    # A window function's own ORDER BY: `arg_orders`.
    ("SELECT first_value(a ORDER BY b ASC) OVER (ORDER BY id ASC NULLS LAST) FROM t",
     "arg_orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    ("SELECT first_value(a ORDER BY b NULLS FIRST) OVER (ORDER BY id ASC NULLS LAST) FROM t",
     "arg_orders[0]: an ORDER BY key without ASC or DESC"),
    ("SELECT string_agg(s ORDER BY s DESC) OVER () FROM t",
     "arg_orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    # An aggregate's ORDER BY (an ORDER_MODIFIER under the function).
    ("SELECT string_agg(s ORDER BY s DESC) FROM t",
     "orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    # Literals.
    ("SELECT a FROM t WHERE a = 2", "where_clause.right: a literal that is not the operand of a CAST"),
    ("SELECT a FROM t LIMIT (SELECT 2)", ".limit."),
    ("SELECT a FROM t LIMIT CAST(2 AS BIGINT) OFFSET (SELECT 1)", ".offset."),
    # Reached through dicts only (no list resets the exemption on the way):
    # the `limit`/`offset` key test alone keeps it from the subquery.
    ("SELECT a FROM t LIMIT (SELECT a FROM t WHERE a = 2)",
     (".limit.", "where_clause.right: a literal that is not the operand of a CAST")),
    # Clocks and randomness.
    ("SELECT random() FROM t", "random() depends on when the query runs"),
    ("SELECT now() FROM t", "now() depends on when the query runs"),
    # ICU's spellings of LOCALTIME and LOCALTIMESTAMP, called by name.
    ("SELECT current_localtime() FROM t", "current_localtime() depends on when the query runs"),
    ("SELECT current_localtimestamp() FROM t", "current_localtimestamp() depends on when the query runs"),
    ("SELECT a FROM t USING SAMPLE 10%", ".sample: USING SAMPLE or TABLESAMPLE"),
    ("SELECT a FROM t TABLESAMPLE 10%", ".sample: USING SAMPLE or TABLESAMPLE"),
    ("SELECT a FROM t USING SAMPLE reservoir(10%) REPEATABLE (7)", ".sample: USING SAMPLE or TABLESAMPLE"),
] + [
    # SQL value keywords: a COLUMN_REF in the parse, a call after binding.
    ("SELECT %s FROM t" % spelling,
     "select_list[0]: %s is a SQL value keyword; DuckDB binds it to %s()" % (spelling, target))
    for spelling, target in KEYWORDS
] + [
    # Quoted: the same COLUMN_REF, so still the function when no column is
    # named so.
    ('SELECT "current_date" FROM t', "select_list[0]: current_date is a SQL value keyword"),
    ('SELECT "LocalTimestamp" FROM t', "select_list[0]: LocalTimestamp is a SQL value keyword"),
    # Qualified by `alias`: IsPotentialAlias, so the binder still tries the
    # map. It compares the qualifier without case (CIEquals).
    ("SELECT alias.current_timestamp FROM t", "select_list[0]: alias.current_timestamp is a SQL value keyword"),
    ("SELECT ALIAS.current_timestamp FROM t", "select_list[0]: ALIAS.current_timestamp is a SQL value keyword"),
    # Outside the select list.
    ("SELECT a FROM t WHERE b < current_date",
     "where_clause.right: current_date is a SQL value keyword"),
    # A table function's argument: TableFunctionBinder maps the last part
    # of a qualified name too.
    ("SELECT * FROM range(x.current_timestamp)",
     (".from_table.function.", "x.current_timestamp is a SQL value keyword")),
    # A COLUMNS star's expression: bound by TableFunctionBinder too, so a
    # qualified name maps; the regex it makes is computed at bind time.
    ("SELECT COLUMNS(x.current_schema) FROM t",
     "select_list[0].expr: x.current_schema is a SQL value keyword"),
    ("SELECT COLUMNS(CAST(x.current_date AS VARCHAR)[CAST(10 AS BIGINT)]) FROM t",
     (".select_list[0].expr.", "x.current_date is a SQL value keyword")),
    # Built-in macros over current_timestamp (default_functions.cpp).
    ("SELECT ago(CAST('1 day' AS INTERVAL)) FROM t", "ago() depends on when the query runs"),
    ("SELECT pg_postmaster_start_time() FROM t", "pg_postmaster_start_time() depends on when the query runs"),
    ("SELECT pg_catalog.pg_conf_load_time() FROM t", "pg_conf_load_time() depends on when the query runs"),
    # A session read DuckDB marks CONSISTENT_WITHIN_QUERY.
    ("SELECT current_schema() FROM t", "current_schema() depends on when the query runs"),
    # A catalog or settings table function.
    ("SELECT name FROM duckdb_settings()", "duckdb_settings() reads the session's catalog, settings or storage"),
    ("SELECT * FROM pragma_database_size()", "pragma_database_size() reads the session's catalog"),
    # age with one argument subtracts from today's midnight; also as a
    # method call, which parses to the same one-child FUNCTION.
    ("SELECT age(CAST('2026-10-01' AS TIMESTAMP)) FROM t", "age() with one argument"),
    ("SELECT CAST('2026-10-01' AS TIMESTAMP).age() FROM t", "age() with one argument"),
    # One SELECT.
    ("SELECT a FROM t; SELECT b FROM t", "2 statements, not one"),
    # DuckDB's serializer refuses it before check() reads a node type.
    ("DELETE FROM t", "Only SELECT statements can be serialized"),
]

# The ORDER BY and literal queries above, their rule kept.
ACCEPTED = [
    "SELECT a FROM t ORDER BY a ASC NULLS LAST",
    "SELECT row_number() OVER (ORDER BY a DESC NULLS FIRST) FROM t",
    "SELECT first_value(a ORDER BY b ASC NULLS LAST) OVER (ORDER BY id ASC NULLS LAST) FROM t",
    "SELECT string_agg(s ORDER BY s DESC NULLS FIRST) OVER () FROM t",
    "SELECT string_agg(s ORDER BY s DESC NULLS FIRST) FROM t",
    "SELECT a FROM t WHERE a = CAST(2 AS BIGINT)",
    "SELECT a FROM t ORDER BY a ASC NULLS LAST LIMIT 2 OFFSET 1",
    "SELECT a FROM t LIMIT (SELECT CAST(2 AS BIGINT))",
    "SELECT a FROM t",
    # A column named like a value keyword, qualified by its table: the
    # binder resolves it as a column (or refuses it), never as the call.
    "SELECT t.current_date FROM t",
    'SELECT t."current_timestamp", t.user FROM t',
    "SELECT a FROM t WHERE t.localtime IS NULL",
    # Names that only begin or end like a keyword.
    "SELECT current_dates, my_user, localtime_x FROM t",
    # A COLUMNS star whose expression reads no clock, and a qualified
    # keyword-named column outside one.
    "SELECT COLUMNS(CAST('a' AS VARCHAR)) FROM t",
    "SELECT COLUMNS(*) FROM t",
    # REPLACE's expressions are bound in the select list, not by
    # TableFunctionBinder: a table-qualified name there is the column.
    "SELECT * REPLACE (t.current_date AS a) FROM t",
    # age of two timestamps reads no clock.
    "SELECT age(CAST('2026-10-01' AS TIMESTAMP), CAST('2026-09-15' AS TIMESTAMP)) FROM t",
]

# DuckDB marks `error` VOLATILE so the optimizer never folds it; its answer
# is its own argument, read at no particular time.
_STABLE_VOLATILE = frozenset(["error"])
_NOT_FUNCTIONS = ("current_time", "current_timestamp", "localtime", "localtimestamp")


def _reached(con, body, params):
    """The function names a macro body calls, and the functions the value
    keywords in it bind to; `params` are the macro's own parameter names."""
    text = con.execute("SELECT json_serialize_sql(CAST(? AS VARCHAR))", [body]).fetchone()[0]
    tree = json.loads(text)
    if tree.get("error"):
        raise ValueError(tree.get("error_message"))
    names = set()
    stack = [tree]
    while stack:
        node = stack.pop()
        if isinstance(node, list):
            stack.extend(node)
            continue
        if not isinstance(node, dict):
            continue
        if node.get("class") == "FUNCTION":
            names.add(str(node.get("function_name", "")).lower())
        if node.get("class") == "COLUMN_REF":
            cols = node.get("column_names") or []
            if not (len(cols) == 1 and str(cols[0]).lower() in params):
                target = sql_discipline._value_keyword(node, False)
                if target is not None:
                    names.add(target)
        stack.extend(node.values())
    return names


def check_list_is_duckdbs(con):
    """Every function the running DuckDB marks unstable, and every built-in
    macro that reaches one, is in `_UNSTABLE`."""
    rows = con.execute(
        "SELECT DISTINCT lower(function_name), function_type, stability, macro_definition, parameters "
        "FROM duckdb_functions()").fetchall()
    known = {r[0] for r in rows}
    for name in _NOT_FUNCTIONS:
        if name in known:
            FAILURES.append("%s is a function in this DuckDB; the comment in _UNSTABLE says it is not" % name)
    unstable = {r[0] for r in rows if r[1] in ("scalar", "aggregate") and r[2] not in (None, "CONSISTENT")}
    unstable -= _STABLE_VOLATILE
    for name in sorted(unstable - sql_discipline._UNSTABLE):
        FAILURES.append("DuckDB marks %s() unstable; _UNSTABLE does not list it" % name)
    macros = []
    for name, ftype, _, body, params in rows:
        if ftype not in ("macro", "table_macro") or body is None:
            continue
        sql = body if ftype == "table_macro" else "SELECT " + body
        try:
            macros.append((name, _reached(con, sql, {str(p).lower() for p in params or []})))
        except ValueError as e:
            FAILURES.append("macro %s: DuckDB does not parse its definition: %s" % (name, e))
    bad = set(unstable) | set(sql_discipline._UNSTABLE)
    changed = True
    while changed:
        changed = False
        for name, reached in macros:
            if name in bad:
                continue
            if any(r in bad or r.startswith(sql_discipline._SESSION_PREFIXES) for r in reached):
                bad.add(name)
                changed = True
                if not name.startswith(sql_discipline._SESSION_PREFIXES) and name not in sql_discipline._UNSTABLE:
                    FAILURES.append("macro %s reaches %s; _UNSTABLE does not list it"
                                    % (name, sorted(r for r in reached if r in bad or r.startswith(sql_discipline._SESSION_PREFIXES))))


def main():
    con = duckdb.connect()
    check_list_is_duckdbs(con)
    for sql in ACCEPTED:
        try:
            sql_discipline.check(con, sql)
        except sql_discipline.DisciplineError as e:
            FAILURES.append("refused %r: %s" % (sql, e))
    for sql, want in REFUSED:
        try:
            sql_discipline.check(con, sql)
        except sql_discipline.DisciplineError as e:
            wants = want if isinstance(want, tuple) else (want,)
            if not all(w in str(e) for w in wants):
                FAILURES.append("refused %r for %s, want a refusal containing %r" % (sql, e, want))
            continue
        tree = con.execute("SELECT json_serialize_sql(CAST(? AS VARCHAR))", [sql]).fetchone()[0]
        FAILURES.append("accepted %r, want a refusal containing %r; DuckDB's parse:\n%s" % (sql, want, tree))
    if FAILURES:
        for f in FAILURES:
            print("FAIL", f)
        raise SystemExit("test_sql_discipline: %d failures" % len(FAILURES))
    print("test_sql_discipline: %d refused, %d accepted, all as expected" % (len(REFUSED), len(ACCEPTED)))


main()

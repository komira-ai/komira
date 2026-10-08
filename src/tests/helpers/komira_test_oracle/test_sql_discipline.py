"""sql_discipline.py refuses each rule a query breaks, and only those.

Each refused query breaks one rule, and the test requires the refusal to
name the place DuckDB's parse keeps the offence (`.arg_orders[0]`,
`.sample`, `.limit.`...), so a check that refuses for some other reason
does not pass for it. Each ORDER BY and literal query is also accepted with
its rule kept, so a check that refuses everything near the offence is
caught too.
`json_serialize_sql` only parses: no table is created or read (the list
check reads DuckDB's function catalog, `duckdb_functions()`). The queries
may name the tables `TABLES` (`t`, `groups`), passed to check() as
gen_expected.py passes the ones it registers.

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
- the list is DuckDB's own: every scalar or aggregate function the running
  DuckDB marks VOLATILE or CONSISTENT_WITHIN_QUERY in `duckdb_functions()`
  (but `error`) must be in `_UNSTABLE`, and `_MACROS` must be exactly the
  built-in scalar macros (no session prefix) whose `macro_definition`
  reaches one of those, a hand-listed name, a value keyword that binds to
  one, a `duckdb_`/`pragma_` function, a table or a table function outside
  `_TABLE_FUNCTIONS`, directly or through another macro: nine in v1.5.6.
  A value keyword in a macro's table function argument binds even
  qualified, as at the call site. `_reached` is also run on bodies spelt
  here, for the branches no v1.5.6 macro exercises. Each name in
  `_TABLE_FUNCTIONS` must be a built-in table function and not a table
  macro. Table functions and table macros are outside the derivation: the
  FROM allowlist refuses every one it does not name. Catches a missing or
  stale name today and a DuckDB upgrade that adds one.
- session settings and variables: `current_setting()` and `getvariable()`,
  listed by hand, are refused. Catches either name dropped from the list.
- FROM, by allowlist: a table function that runs SQL text (`query`,
  `query_table`, `json_execute_serialized_sql`) or reads the worker's files
  (`read_text`, `read_blob`, `glob`), or an allowed one qualified; a catalog
  view, bare (`duckdb_tables`, `duckdb_databases`, `duckdb_logs`) or
  qualified (`pg_catalog.pg_settings`); a registered table qualified by a
  schema or a catalog; a quoted file path (a replacement scan); a PIVOT
  (UNPIVOT) or SHOW_REF (SUMMARIZE) reference; each refused at a join's
  side, in a FROM subquery, in a WHERE subquery and in a table function's
  argument; a CTE read outside the query that defines it, and in its own
  body, is refused. Accepted: the registered tables in any case, joined
  and unioned; no FROM; VALUES; range, generate_series and unnest; a CTE
  named like a dataset or a catalog view, one read by the next CTE or from
  a subquery, and the recursive half of WITH RECURSIVE. Catches a table or
  table function allowlist that is off or skipped below the first
  reference, a qualifier or replacement-scan rule that is off, a CTE scope
  that is shared, global or given to the CTE's own body, and one that is
  never opened (over-strict).
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
    # The session's settings and variables: listed by hand, as
    # duckdb_functions() does not mark them unstable.
    ("SELECT current_setting(CAST('threads' AS VARCHAR)) FROM t", "current_setting() depends on when the query runs"),
    ("SELECT getvariable(CAST('x' AS VARCHAR)) FROM t", "getvariable() depends on when the query runs"),
    # FROM: a table function that runs SQL text, which the parse holds as
    # a string literal no rule here reads.
    ("SELECT CAST(n AS VARCHAR) FROM query(CAST('SELECT now() AS n' AS VARCHAR))",
     "statement.node.from_table: query() is not a table function the oracle allows"),
    ("SELECT * FROM query(CAST('SELECT random()' AS VARCHAR))",
     "statement.node.from_table: query() is not a table function the oracle allows"),
    ("SELECT * FROM json_execute_serialized_sql(CAST('{}' AS VARCHAR))",
     "statement.node.from_table: json_execute_serialized_sql() is not a table function the oracle allows"),
    ("SELECT * FROM query_table(CAST('t' AS VARCHAR))",
     "statement.node.from_table: query_table() is not a table function the oracle allows"),
    # A table function that reads the worker's files.
    ("SELECT content FROM read_text(CAST('/etc/hostname' AS VARCHAR))",
     "statement.node.from_table: read_text() is not a table function the oracle allows"),
    ("SELECT last_modified FROM read_blob(CAST('x' AS VARCHAR))",
     "statement.node.from_table: read_blob() is not a table function the oracle allows"),
    ("SELECT * FROM glob(CAST('/proc/*' AS VARCHAR))",
     "statement.node.from_table: glob() is not a table function the oracle allows"),
    # An allowed name, qualified: refused like any qualified function.
    ("SELECT * FROM main.range(CAST(3 AS BIGINT))",
     "statement.node.from_table: range() is not a table function the oracle allows"),
    # A catalog view is a BASE_TABLE, not a FUNCTION: the duckdb_ prefix
    # rule never sees it. Qualified, and bare.
    ("SELECT name, setting FROM pg_catalog.pg_settings",
     "statement.node.from_table: pg_catalog.pg_settings names a schema or catalog"),
    ("SELECT * FROM duckdb_tables",
     "statement.node.from_table: duckdb_tables is neither a table the oracle registers nor a CTE in scope"),
    ("SELECT * FROM duckdb_databases",
     "statement.node.from_table: duckdb_databases is neither a table the oracle registers"),
    ("SELECT * FROM duckdb_logs",
     "statement.node.from_table: duckdb_logs is neither a table the oracle registers"),
    # A registered table, qualified by a schema and by a catalog: the
    # oracle registers its tables bare, so a qualifier only reaches others.
    ("SELECT k FROM main.groups", "statement.node.from_table: main.groups names a schema or catalog"),
    ("SELECT k FROM temp.main.groups", "statement.node.from_table: temp.main.groups names a schema or catalog"),
    # A replacement scan: a quoted path parses to a BASE_TABLE.
    ("SELECT * FROM 'x.parquet'", "statement.node.from_table: x.parquet is a file path"),
    ("SELECT * FROM '/data/rows.csv'", "statement.node.from_table: /data/rows.csv is a file path"),
    # Every table reference, not only the first: a join's side, a FROM
    # subquery, a subquery in WHERE, a table function's argument.
    ("SELECT a FROM t, duckdb_tables", "from_table.right: duckdb_tables is neither"),
    ("SELECT a FROM (SELECT a FROM duckdb_tables) AS s", "from_table.subquery.node.from_table: duckdb_tables is neither"),
    ("SELECT a FROM t WHERE a IN (SELECT a FROM unknown_t)", "from_table: unknown_t is neither"),
    ("SELECT * FROM range((SELECT CAST(count(*) AS BIGINT) FROM duckdb_tables))",
     ".from_table.function.children[0]."),
    # CTE scope: a CTE is not in scope outside the query that defines it,
    # nor in its own body (there the name is the catalog's view).
    ("SELECT a FROM (WITH c AS (SELECT a FROM t) SELECT a FROM c) AS s, c",
     "from_table.right: c is neither a table the oracle registers nor a CTE in scope"),
    ("WITH duckdb_tables AS (SELECT * FROM duckdb_tables) SELECT * FROM duckdb_tables",
     ".cte_map.map[0].value.query.node.from_table: duckdb_tables is neither"),
    # A kind of table reference not on the list.
    ("SELECT * FROM t UNPIVOT (v FOR k IN (a, b))", "statement.node.from_table: a PIVOT in FROM"),
    ("SUMMARIZE t", "a SHOW_REF in FROM"),
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
    # FROM: the registered tables (in any case, as DuckDB's catalog
    # compares), joined and unioned; no FROM; VALUES; each allowed table
    # function.
    "SELECT t.a FROM t JOIN groups ON t.a = groups.k",
    "SELECT k FROM GROUPS",
    "SELECT a FROM t UNION ALL SELECT k FROM groups",
    "SELECT CAST(1 AS BIGINT) AS one",
    "SELECT x FROM (VALUES (CAST(1 AS BIGINT))) AS v(x)",
    "SELECT * FROM range(CAST(3 AS BIGINT))",
    "SELECT * FROM generate_series(CAST(1 AS BIGINT), CAST(3 AS BIGINT))",
    "SELECT * FROM unnest([CAST(1 AS BIGINT), CAST(2 AS BIGINT)])",
    # CTEs: one named like a dataset or a catalog view (DuckDB binds the
    # CTE); one read by the CTE after it; one read from a subquery of the
    # query that defines it; the recursive half of WITH RECURSIVE.
    "WITH groups AS (SELECT CAST(1 AS BIGINT) AS k) SELECT k FROM groups",
    "WITH duckdb_tables AS (SELECT a FROM t) SELECT a FROM duckdb_tables",
    "WITH c AS (SELECT a FROM t), d AS (SELECT a FROM c) SELECT a FROM d",
    "WITH c AS (SELECT a FROM t) SELECT a FROM t WHERE a IN (SELECT a FROM c)",
    "WITH RECURSIVE r(n) AS (SELECT CAST(1 AS BIGINT) UNION ALL "
    "SELECT n + CAST(1 AS BIGINT) FROM r WHERE n < CAST(3 AS BIGINT)) SELECT n FROM r",
]

# The tables the queries above may name, as gen_expected.py passes its own.
TABLES = ("t", "groups")

# DuckDB marks `error` VOLATILE so the optimizer never folds it; its answer
# is its own argument, read at no particular time.
_STABLE_VOLATILE = frozenset(["error"])
_NOT_FUNCTIONS = ("current_time", "current_timestamp", "localtime", "localtimestamp")


def _reached(con, body, params):
    """What a scalar macro body reaches: the names of the functions it
    calls (table functions included) and of the functions the value
    keywords in it bind to, and a `FROM <name>` entry for each table it
    reads and each table function outside `_TABLE_FUNCTIONS` it calls;
    `params` are the macro's own parameter names. A value keyword inside a
    table function's arguments or a COLUMNS star's expression binds even
    qualified, as in sql_discipline.py. Any table counts, CTE or not: no
    built-in scalar macro has a WITH, and counting one only adds a name."""
    text = con.execute("SELECT json_serialize_sql(CAST(? AS VARCHAR))", [body]).fetchone()[0]
    tree = json.loads(text)
    if tree.get("error"):
        raise ValueError(tree.get("error_message"))
    names = set()

    def walk(node, in_table_fn):
        if isinstance(node, list):
            for item in node:
                walk(item, in_table_fn)
            return
        if not isinstance(node, dict):
            return
        cls = node.get("class")
        if cls == "FUNCTION":
            names.add(str(node.get("function_name", "")).lower())
        if cls == "COLUMN_REF":
            cols = node.get("column_names") or []
            if not (len(cols) == 1 and str(cols[0]).lower() in params):
                target = sql_discipline._value_keyword(node, in_table_fn)
                if target is not None:
                    names.add(target)
        if cls is None and node.get("type") == "BASE_TABLE":
            names.add("FROM " + str(node.get("table_name")))
        table_fn = cls is None and node.get("type") == "TABLE_FUNCTION"
        if table_fn:
            fname = str((node.get("function") or {}).get("function_name", "")).lower()
            if fname not in sql_discipline._TABLE_FUNCTIONS:
                names.add("FROM " + fname + "()")
        for key, value in node.items():
            walk(value, in_table_fn or (table_fn and key == "function") or (cls == "STAR" and key == "expr"))

    walk(tree, False)
    return names


def check_reached(con):
    """_reached on bodies spelt here, for what no v1.5.6 macro exercises: a
    qualified value keyword in a table function's argument, a table, a
    table function outside the allowlist and one in it, a parameter named
    like a keyword."""
    cases = [
        ("SELECT (SELECT CAST(r AS DATE) FROM range(x.current_date) AS g(r))", set(), "current_date", True),
        ("SELECT x.current_date", set(), "current_date", False),
        ("SELECT (SELECT max(a) FROM some_view)", set(), "FROM some_view", True),
        ("SELECT (SELECT content FROM read_text(p))", {"p"}, "FROM read_text()", True),
        ("SELECT (SELECT max(r) FROM range(n) AS g(r))", {"n"}, "FROM range()", False),
        ("SELECT user || 'x'", {"user"}, "user", False),
        ("SELECT user || 'x'", set(), "user", True),
    ]
    for body, params, name, want in cases:
        got = _reached(con, body, params)
        if (name in got) != want:
            FAILURES.append("_reached(%r, %s) = %s: want %s %s" % (body, sorted(params), sorted(got), name, "in it" if want else "absent"))


def _is_bad(name, bad):
    return name in bad or name.startswith(sql_discipline._SESSION_PREFIXES) or name.startswith("FROM ")


def check_list_is_duckdbs(con):
    """Every scalar or aggregate function the running DuckDB marks
    unstable is in `_UNSTABLE`, `_MACROS` is exactly the built-in scalar
    macros that reach an unstable function, a session function, a table or
    a table function outside `_TABLE_FUNCTIONS`, and each name in
    `_TABLE_FUNCTIONS` is a built-in table function, not a table macro.
    Table functions and table macros are outside the derivation: the FROM
    allowlist refuses every one it does not name, so none need be listed."""
    rows = con.execute(
        "SELECT DISTINCT lower(function_name), function_type, stability, macro_definition, parameters "
        "FROM duckdb_functions()").fetchall()
    known = {r[0] for r in rows}
    for name in _NOT_FUNCTIONS:
        if name in known:
            FAILURES.append("%s is a function in this DuckDB; the comment in _UNSTABLE says it is not" % name)
    kinds = {}
    for r in rows:
        kinds.setdefault(r[0], set()).add(r[1])
    for name in sorted(sql_discipline._TABLE_FUNCTIONS):
        if "table" not in kinds.get(name, set()) or "table_macro" in kinds.get(name, set()):
            FAILURES.append("_TABLE_FUNCTIONS lists %s, which is not a built-in table function alone: %s"
                            % (name, sorted(kinds.get(name, set()))))
    unstable = {r[0] for r in rows if r[1] in ("scalar", "aggregate") and r[2] not in (None, "CONSISTENT")}
    unstable -= _STABLE_VOLATILE
    for name in sorted(unstable - sql_discipline._UNSTABLE):
        FAILURES.append("DuckDB marks %s() unstable; _UNSTABLE does not list it" % name)
    macros = []
    for name, ftype, _, body, params in rows:
        if ftype != "macro" or body is None:
            continue
        try:
            macros.append((name, _reached(con, "SELECT " + body, {str(p).lower() for p in params or []})))
        except ValueError as e:
            FAILURES.append("macro %s: DuckDB does not parse its definition: %s" % (name, e))
    # Start from what is unstable without the macros, so that each name in
    # _MACROS must be derived again.
    bad = set(unstable) | (sql_discipline._UNSTABLE - sql_discipline._MACROS)
    derived = {}
    changed = True
    while changed:
        changed = False
        for name, reached in macros:
            if name in bad:
                continue
            why = sorted(r for r in reached if _is_bad(r, bad))
            if why:
                bad.add(name)
                changed = True
                if not name.startswith(sql_discipline._SESSION_PREFIXES):
                    derived[name] = why
    for name in sorted(set(derived) - sql_discipline._MACROS):
        FAILURES.append("macro %s reaches %s; _MACROS does not list it" % (name, derived[name]))
    for name in sorted(sql_discipline._MACROS - set(derived)):
        FAILURES.append("_MACROS lists %s, which is no built-in macro reaching anything unstable" % name)


def main():
    con = duckdb.connect()
    check_reached(con)
    check_list_is_duckdbs(con)
    for sql in ACCEPTED:
        try:
            sql_discipline.check(con, sql, TABLES)
        except sql_discipline.DisciplineError as e:
            FAILURES.append("refused %r: %s" % (sql, e))
    for sql, want in REFUSED:
        try:
            sql_discipline.check(con, sql, TABLES)
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

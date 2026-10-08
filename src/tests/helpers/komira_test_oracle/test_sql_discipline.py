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
- the functions DuckDB leaves CONSISTENT whose answer reads more than
  their arguments, listed by hand, each refused by a call:
  `json_serialize_plan` (its SQL text is bound and optimized, so
  `optimize := true` folds `now()` into the answer), `json_serialize_sql`,
  `json_deserialize_sql`, `make_type`, `parse_duckdb_log_message`,
  `st_setcrs`, `version` and `vector_type`; each hand-listed name must be
  a function of the running DuckDB. Catches any one name dropped from the
  list, and a name DuckDB renames on an upgrade. `list_aggregate` (and
  `aggregate`, `list_aggr`, `array_aggregate`, `array_aggr`) calls the
  aggregate its string argument names, which no rule here reads; it is
  not refused (`list_sum` and some forty other built-in macros call it with
  a fixed name), so the test requires instead that DuckDB mark no
  aggregate unstable. Catches a DuckDB upgrade that makes an aggregate
  reachable by name past the list.
- FROM, by allowlist: a table function that runs SQL text (`query`,
  `query_table`, `json_execute_serialized_sql`) or reads the worker's files
  (`read_text`, `read_blob`, `glob`), or an allowed one qualified; a catalog
  view, bare (`duckdb_tables`, `duckdb_databases`, `duckdb_logs`) or
  qualified (`pg_catalog.pg_settings`); a registered table qualified by a
  schema or a catalog; a quoted file path (a replacement scan); a PIVOT
  (UNPIVOT) or SHOW_REF (SUMMARIZE) reference; each refused at a join's
  side, in a FROM subquery, in a WHERE subquery and in a table function's
  argument; a CTE read outside the query that defines it, and in its own
  body, is refused; a registered table read with `AT (VERSION => ...)` or
  `AT (TIMESTAMP => ...)` (time travel), alone and at a join's side, is
  refused. Accepted: the registered tables in any case, joined
  and unioned; no FROM; VALUES; range, generate_series and unnest; a CTE
  named like a dataset or a catalog view, one read by the next CTE or from
  a subquery, and the recursive half of WITH RECURSIVE. Catches a table or
  table function allowlist that is off or skipped below the first
  reference, a FROM rule that admits a registered table by name without
  looking at its AT clause, a qualifier or replacement-scan rule that is off, a CTE scope
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
- row order: each aggregate on `_ORDER_SENSITIVE` (`list`, `first`,
  `arg_max`, `mode`...) is refused with no ORDER BY of its own, as a plain
  aggregate and as a window function (an OVER clause's ORDER BY is not
  its own), schema-qualified and upper case too, and accepted with one;
  its ORDER BY key is held to the ASC/DESC and NULLS rule. JSON's
  `json_group_array` and its kin are refused with an ORDER BY or without.
  Catches the rule off, a list missing a name, a check that reads
  `order_bys` but not a window's `arg_orders`, and one that refuses the
  aggregate even ordered. The list is the running DuckDB's: every
  aggregate `duckdb_functions()` holds must be on `_ORDER_SENSITIVE`, on
  `sql_discipline._HISTOGRAMS` or on `_ORDER_FREE` here (each group with
  the reason its answer is the same in any order), never two, and every
  name on any must be an aggregate;
  `_ORDER_MACROS` must be exactly the built-in macros that reach a listed
  aggregate with no ORDER BY, directly or through another macro. Catches a
  name dropped, misspelt or renamed, and a DuckDB upgrade that adds an
  aggregate or such a macro. DuckDB lists its window functions as
  aggregates too: each on `_WINDOW_ORDERED` (`row_number`, `lead`,
  `first_value`...) is refused with an empty OVER clause (and
  `row_number()` with only a PARTITION BY) and accepted with an ORDER BY
  in its OVER clause or of its own; the rank family, order-free, is
  accepted with an empty OVER clause. Catches a window rule that reads
  only `arg_orders` or only `orders`.
- row-order frames and modifiers: a window over a ROWS frame not
  unbounded on both sides with no ORDER BY in its OVER clause is refused,
  bounded at its start, at its end, at both, in a PARTITION BY, through a
  named window, in a subquery, and with an ORDER BY of the function's own
  (which orders inside the frame, not the frame); accepted with an OVER
  ORDER BY, unbounded on both sides (with EXCLUDE CURRENT ROW too), and as
  a RANGE or GROUPS frame (every row a peer). A LIMIT, an OFFSET alone and
  a LIMIT percent with no ORDER BY in the same query are refused, at the
  top, after a UNION ALL, in a FROM subquery under an outer ORDER BY and in
  a WHERE subquery; accepted with the ORDER BY. DISTINCT ON with no ORDER
  BY is refused; with one, and plain DISTINCT, accepted. Catches each rule
  off, a frame rule that reads only `start` or only `end`, takes
  `arg_orders` for the OVER clause's ORDER BY or refuses RANGE and GROUPS
  frames, a LIMIT rule that forgets LIMIT percent or OFFSET or takes an
  ORDER BY of another query node, and a DISTINCT rule that refuses plain
  DISTINCT.
- histograms: one-argument `histogram` is refused with no CAST, with a
  CAST to DOUBLE, FLOAT8, REAL or a type name the parse leaves unbound,
  with TRY_CAST, and as a window function; accepted with a CAST to BIGINT,
  VARCHAR, a list or a struct of DOUBLE. `histogram` with bins and
  `histogram_exact` are refused when the bins read a column, also inside
  a subquery, and accepted with constant bins, over a DOUBLE too, and with
  a subquery that reads no column. Both names are
  `sql_discipline._HISTOGRAMS`, on neither row-order list. Catches the
  rule off, a key list missing DOUBLE, FLOAT or an unbound name, a rule
  that takes any CAST, a bins rule off, blind inside a subquery or
  refusing every subquery, and a rule that refuses a safe key type.
- list sorts: `list_sort` (`array_sort`) and `list_grade_up`
  (`array_grade_up`, `grade_up`) are refused with no direction, with a
  direction but no NULL placement, with `DEFAULT` or `ORDER_DEFAULT` for
  either, with a column for either, and as a method call; accepted with
  both as cast literals in either of DuckDB's spellings and any case.
  `list_reverse_sort` (`array_reverse_sort`) is refused even with its NULL
  placement. The premise is run, not only parsed: under `default_order`
  ASC and DESC and `default_null_order` NULLS_FIRST and NULLS_LAST, one-
  argument `list_sort` and `list_reverse_sort` change their answer while
  the accepted spellings do not. Catches the rule off, `DEFAULT` taken for
  a direction, only the argument count checked, and a premise DuckDB no
  longer holds.
- collations: a COLLATE in the select list, an ORDER BY key, a WHERE, a
  GROUP BY and a FROM subquery is refused; a column named `collation` and
  the words in a string literal are accepted. Catches the rule off, or
  read from the text.
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
    ("SELECT a FROM t ORDER BY a ASC NULLS LAST LIMIT (SELECT 2)", ".limit."),
    ("SELECT a FROM t ORDER BY a ASC NULLS LAST LIMIT CAST(2 AS BIGINT) OFFSET (SELECT 1)", ".offset."),
    # Reached through dicts only (no list resets the exemption on the way):
    # the `limit`/`offset` key test alone keeps it from the subquery.
    ("SELECT a FROM t ORDER BY a ASC NULLS LAST LIMIT (SELECT a FROM t WHERE a = 2)",
     (".limit.", "where_clause.right: a literal that is not the operand of a CAST")),
    # Clocks and randomness.
    ("SELECT random() FROM t", "random() depends on when, where or in which session the query runs"),
    ("SELECT now() FROM t", "now() depends on when, where or in which session the query runs"),
    # ICU's spellings of LOCALTIME and LOCALTIMESTAMP, called by name.
    ("SELECT current_localtime() FROM t",
     "current_localtime() depends on when, where or in which session the query runs"),
    ("SELECT current_localtimestamp() FROM t",
     "current_localtimestamp() depends on when, where or in which session the query runs"),
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
    ("SELECT ago(CAST('1 day' AS INTERVAL)) FROM t", "ago() depends on when, where or in which session the query runs"),
    ("SELECT pg_postmaster_start_time() FROM t",
     "pg_postmaster_start_time() depends on when, where or in which session the query runs"),
    ("SELECT pg_catalog.pg_conf_load_time() FROM t",
     "pg_conf_load_time() depends on when, where or in which session the query runs"),
    # A session read DuckDB marks CONSISTENT_WITHIN_QUERY.
    ("SELECT current_schema() FROM t", "current_schema() depends on when, where or in which session the query runs"),
    # A catalog or settings table function.
    ("SELECT name FROM duckdb_settings()", "duckdb_settings() reads the session's catalog, settings or storage"),
    ("SELECT * FROM pragma_database_size()", "pragma_database_size() reads the session's catalog"),
    # age with one argument subtracts from today's midnight; also as a
    # method call, which parses to the same one-child FUNCTION.
    ("SELECT age(CAST('2026-10-01' AS TIMESTAMP)) FROM t", "age() with one argument"),
    ("SELECT CAST('2026-10-01' AS TIMESTAMP).age() FROM t", "age() with one argument"),
    # The session's settings and variables: listed by hand, as
    # duckdb_functions() does not mark them unstable.
    ("SELECT current_setting(CAST('threads' AS VARCHAR)) FROM t",
     "current_setting() depends on when, where or in which session the query runs"),
    ("SELECT getvariable(CAST('x' AS VARCHAR)) FROM t",
     "getvariable() depends on when, where or in which session the query runs"),
    # Functions DuckDB leaves CONSISTENT whose answer reads more than their
    # arguments, listed by hand. json_serialize_plan binds and optimizes
    # its SQL text, so this answer is the clock's.
    ("SELECT json_serialize_plan(CAST('SELECT now()' AS VARCHAR), optimize := CAST(true AS BOOLEAN))",
     "select_list[0]: json_serialize_plan() depends on when, where or in which session"),
    ("SELECT json_serialize_sql(CAST('SELECT 1' AS VARCHAR)) FROM t", "json_serialize_sql() depends on"),
    ("SELECT json_deserialize_sql(CAST('{}' AS JSON)) FROM t", "json_deserialize_sql() depends on"),
    ("SELECT make_type(CAST('main.mood' AS VARCHAR)) FROM t", "make_type() depends on"),
    ("SELECT parse_duckdb_log_message(CAST('FileSystem' AS VARCHAR), s) FROM t",
     "parse_duckdb_log_message() depends on"),
    ("SELECT st_setcrs(g, CAST('EPSG:4326' AS VARCHAR)) FROM t", "st_setcrs() depends on"),
    ("SELECT version() FROM t", "version() depends on"),
    ("SELECT vector_type(a) FROM t", "vector_type() depends on"),
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
    # Time travel: a registered table read at another version.
    ("SELECT a FROM t AT (VERSION => CAST(1 AS BIGINT))",
     "statement.node.from_table.at_clause: t AT (...) reads another version"),
    ("SELECT t.a FROM groups JOIN t AT (TIMESTAMP => CAST('2026-10-01' AS TIMESTAMP)) ON t.a = groups.k",
     "from_table.right.at_clause: t AT (...) reads another version"),
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

# Row order: each order-sensitive aggregate, unordered, plain and as a
# window function; JSON's macros over string_agg, ordered or not; list sorts
# that leave their direction or NULL placement to the session.
REFUSED += [
    ("SELECT %s(a) FROM t" % name,
     "select_list[0]: %s() with no ORDER BY of its own depends on the order rows reach it" % name)
    for name in sorted(sql_discipline._ORDER_SENSITIVE)
] + [
    ("SELECT %s(a) OVER (ORDER BY id ASC NULLS LAST) FROM t" % name,
     "select_list[0]: %s() with no ORDER BY of its own" % name)
    for name in ("list", "first", "arg_max")
] + [
    # Qualified and upper case: the name is compared without case.
    ("SELECT %s(a) OVER () FROM t" % name,
     "select_list[0]: %s() with no ORDER BY in its OVER clause or of its own" % name)
    for name in sorted(sql_discipline._WINDOW_ORDERED)
] + [
    ("SELECT row_number() OVER (PARTITION BY k) FROM t",
     "select_list[0]: row_number() with no ORDER BY in its OVER clause or of its own"),
    ("SELECT main.FIRST(a) FROM t", ("select_list[0]: ", "() with no ORDER BY of its own")),
    ("SELECT k FROM groups GROUP BY k HAVING CAST(string_agg(v, CAST(',' AS VARCHAR)) AS VARCHAR) <> CAST('' AS VARCHAR)",
     "having.left.child: string_agg() with no ORDER BY of its own"),
    ("SELECT list(a ORDER BY b ASC) FROM t",
     "order_bys.orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    ("SELECT json_group_array(a) FROM t", "select_list[0]: json_group_array() is a macro over an aggregate"),
    ("SELECT json_group_object(k, v ORDER BY k ASC NULLS LAST) FROM t",
     "select_list[0]: json_group_object() is a macro over an aggregate"),
    ("SELECT json_group_structure(a) FROM t", "select_list[0]: json_group_structure() is a macro over an aggregate"),
    ("SELECT list_sort(l) FROM t", "select_list[0]: list_sort() without a direction and a NULL placement"),
    ("SELECT l.list_sort() FROM t", "select_list[0]: list_sort() without a direction"),
    ("SELECT list_sort(l, CAST('ASC' AS VARCHAR)) FROM t", "select_list[0]: list_sort() without a direction"),
    ("SELECT list_sort(l, CAST('DEFAULT' AS VARCHAR), CAST('NULLS LAST' AS VARCHAR)) FROM t",
     "select_list[0]: list_sort() without a direction"),
    ("SELECT array_sort(l, CAST('DESC' AS VARCHAR), CAST('ORDER_DEFAULT' AS VARCHAR)) FROM t",
     "select_list[0]: array_sort() without a direction"),
    ("SELECT list_sort(l, s, CAST('NULLS LAST' AS VARCHAR)) FROM t", "select_list[0]: list_sort() without a direction"),
    ("SELECT grade_up(l) FROM t", "select_list[0]: grade_up() without a direction"),
    ("SELECT list_grade_up(l, CAST('ASC' AS VARCHAR), CAST('DEFAULT' AS VARCHAR)) FROM t",
     "select_list[0]: list_grade_up() without a direction"),
    ("SELECT array_grade_up(l, CAST('ASC' AS VARCHAR), CAST(NULL AS VARCHAR)) FROM t",
     "select_list[0]: array_grade_up() without a direction"),
    ("SELECT list_reverse_sort(l, CAST('NULLS LAST' AS VARCHAR)) FROM t",
     "select_list[0]: list_reverse_sort() sorts against the session's default_order"),
    ("SELECT array_reverse_sort(l) FROM t",
     "select_list[0]: array_reverse_sort() sorts against the session's default_order"),
]

# Frames, LIMIT, OFFSET and DISTINCT ON that keep rows by the order they
# arrive; histograms whose answer follows it.
_ROWS = "over a ROWS frame (%s to %s) with no ORDER BY in its OVER clause"
_LIMIT = "a LIMIT or OFFSET with no ORDER BY in the same query"
_HIST = "of an argument that is not a CAST to a type other than FLOAT or DOUBLE (%s)"
_BINS = "with bins that read a column"
REFUSED += [
    ("SELECT count(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM groups",
     "select_list[0]: count() " + _ROWS % ("UNBOUNDED_PRECEDING", "CURRENT_ROW_ROWS")),
    ("SELECT sum(v) OVER (PARTITION BY k ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM groups",
     "select_list[0]: sum() " + _ROWS % ("UNBOUNDED_PRECEDING", "CURRENT_ROW_ROWS")),
    # Bounded at the start only, at the end only.
    ("SELECT sum(v) OVER (ROWS BETWEEN CAST(1 AS BIGINT) PRECEDING AND UNBOUNDED FOLLOWING) FROM groups",
     "select_list[0]: sum() " + _ROWS % ("EXPR_PRECEDING_ROWS", "UNBOUNDED_FOLLOWING")),
    ("SELECT sum(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND CAST(1 AS BIGINT) FOLLOWING) FROM groups",
     "select_list[0]: sum() " + _ROWS % ("UNBOUNDED_PRECEDING", "EXPR_FOLLOWING_ROWS")),
    # The function's own ORDER BY orders inside the frame, not the frame.
    ("SELECT sum(v ORDER BY id ASC NULLS LAST) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM groups",
     "select_list[0]: sum() " + _ROWS % ("UNBOUNDED_PRECEDING", "CURRENT_ROW_ROWS")),
    ("SELECT first_value(v ORDER BY id ASC NULLS LAST) OVER (ROWS CAST(1 AS BIGINT) PRECEDING) FROM groups",
     "select_list[0]: first_value() " + _ROWS % ("EXPR_PRECEDING_ROWS", "CURRENT_ROW_ROWS")),
    # A named window: the parse copies it into the call.
    ("SELECT count(v) OVER w FROM groups WINDOW w AS (ROWS CAST(1 AS BIGINT) PRECEDING)",
     "select_list[0]: count() " + _ROWS % ("EXPR_PRECEDING_ROWS", "CURRENT_ROW_ROWS")),
    ("SELECT s FROM (SELECT sum(v) OVER (ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS s FROM groups) AS q",
     "from_table.subquery.node.select_list[0]: sum() " + _ROWS % ("CURRENT_ROW_ROWS", "CURRENT_ROW_ROWS")),
    # LIMIT, OFFSET alone, LIMIT percent; after a UNION ALL; in a FROM
    # subquery whose outer query has the ORDER BY; in a WHERE subquery.
    ("SELECT id FROM groups LIMIT 1", "statement.node.modifiers[0]: " + _LIMIT),
    ("SELECT id FROM groups OFFSET 1", "statement.node.modifiers[0]: " + _LIMIT),
    ("SELECT id FROM groups LIMIT 50%", "statement.node.modifiers[0]: " + _LIMIT),
    ("SELECT id FROM groups UNION ALL SELECT k FROM groups LIMIT 1", "statement.node.modifiers[0]: " + _LIMIT),
    ("SELECT id FROM (SELECT id FROM groups LIMIT 1) AS s ORDER BY id ASC NULLS LAST",
     "from_table.subquery.node.modifiers[0]: " + _LIMIT),
    ("SELECT id FROM groups WHERE k IN (SELECT k FROM groups LIMIT 1) ORDER BY id ASC NULLS LAST",
     "subquery.node.modifiers[0]: " + _LIMIT),
    ("SELECT DISTINCT ON (k) k, id FROM groups",
     "statement.node.modifiers[0]: DISTINCT ON with no ORDER BY in the same query"),
    # One-argument histogram: no CAST, DOUBLE and its spellings, an unbound
    # name, TRY_CAST, a window function.
    ("SELECT histogram(f64_special) AS h FROM t", "select_list[0]: histogram() " + _HIST % "no CAST"),
    ("SELECT histogram(CAST(f AS DOUBLE)) FROM t", "select_list[0]: histogram() " + _HIST % "DOUBLE"),
    ("SELECT histogram(CAST(f AS FLOAT8)) FROM t", "select_list[0]: histogram() " + _HIST % "DOUBLE"),
    ("SELECT histogram(CAST(f AS REAL)) FROM t", "select_list[0]: histogram() " + _HIST % "FLOAT"),
    ("SELECT histogram(CAST(f AS main.f8)) FROM t", "select_list[0]: histogram() " + _HIST % "UNBOUND"),
    ("SELECT histogram(TRY_CAST(s AS DOUBLE)) FROM t", "select_list[0]: histogram() " + _HIST % "DOUBLE"),
    # Upper case: the parse keeps a window function's name lowercased.
    ("SELECT HISTOGRAM(f) OVER () FROM t", "select_list[0]: histogram() " + _HIST % "no CAST"),
    # Bins from a column, from a column inside a subquery.
    ("SELECT histogram(id, CASE WHEN id < CAST(3 AS BIGINT) THEN [CAST(1 AS BIGINT)] ELSE [CAST(5 AS BIGINT)] END) FROM groups",
     "select_list[0]: histogram() " + _BINS),
    ("SELECT histogram_exact(id, [k]) FROM groups", "select_list[0]: histogram_exact() " + _BINS),
    ("SELECT histogram(id, (SELECT [max(k)] FROM groups)) FROM groups",
     "select_list[0]: histogram() " + _BINS),
]

# A collation ties strings that differ: in the select list, an ORDER BY
# key, a WHERE, a GROUP BY and a FROM subquery.
_COLL = "COLLATE %s compares strings that differ as equal"
REFUSED += [
    ("SELECT s COLLATE nocase AS s FROM t ORDER BY s ASC NULLS LAST", "statement.node.select_list[0]: " + _COLL % "nocase"),
    ("SELECT s FROM t ORDER BY s COLLATE noaccent ASC NULLS LAST",
     "statement.node.modifiers[0].orders[0].expression: " + _COLL % "noaccent"),
    ("SELECT s FROM t WHERE s COLLATE nocase = CAST('A' AS VARCHAR)", ("where_clause", _COLL % "nocase")),
    ("SELECT count(*) FROM t GROUP BY s COLLATE nocase", "group_expressions[0]: " + _COLL % "nocase"),
    ("SELECT s FROM (SELECT s COLLATE nocase AS s FROM t) AS q",
     "from_table.subquery.node.select_list[0]: " + _COLL % "nocase"),
]

# The ORDER BY and literal queries above, their rule kept.
ACCEPTED = [
    # A column named collation and the word as a string: the rule reads
    # the parse's COLLATE nodes, not the text.
    "SELECT t.collation, CAST('COLLATE nocase' AS VARCHAR) AS c FROM t ORDER BY s ASC NULLS LAST",
    "SELECT a FROM t ORDER BY a ASC NULLS LAST",
    "SELECT row_number() OVER (ORDER BY a DESC NULLS FIRST) FROM t",
    "SELECT first_value(a ORDER BY b ASC NULLS LAST) OVER (ORDER BY id ASC NULLS LAST) FROM t",
    "SELECT string_agg(s ORDER BY s DESC NULLS FIRST) OVER () FROM t",
    "SELECT string_agg(s ORDER BY s DESC NULLS FIRST) FROM t",
    "SELECT a FROM t WHERE a = CAST(2 AS BIGINT)",
    "SELECT a FROM t ORDER BY a ASC NULLS LAST LIMIT 2 OFFSET 1",
    "SELECT a FROM t ORDER BY a ASC NULLS LAST LIMIT (SELECT CAST(2 AS BIGINT))",
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

# Row order kept: each order-sensitive aggregate with its own ORDER BY,
# plain and as a window function; the order-free aggregates unordered; list
# sorts naming direction and NULL placement in either spelling and case.
ACCEPTED += [
    "SELECT %s(a ORDER BY b ASC NULLS LAST) FROM t" % name for name in sorted(sql_discipline._ORDER_SENSITIVE)
] + [
    "SELECT list(a ORDER BY b DESC NULLS FIRST) OVER (ORDER BY id ASC NULLS LAST) FROM t",
    "SELECT first(a ORDER BY b ASC NULLS LAST) OVER () FROM t",
] + [
    "SELECT %s(a) OVER (ORDER BY b ASC NULLS LAST) FROM t" % name for name in sorted(sql_discipline._WINDOW_ORDERED)
] + [
    "SELECT lead(a ORDER BY b ASC NULLS LAST) OVER () FROM t",
    "SELECT rank() OVER (), dense_rank() OVER (), percent_rank() OVER (), cume_dist() OVER () FROM t",
    "SELECT count(a), sum(a), min(a), max(a), histogram(CAST(a AS BIGINT)), bitstring_agg(a), avg(a) FROM t",
    "SELECT list_sort(l, CAST('ASC' AS VARCHAR), CAST('NULLS LAST' AS VARCHAR)) FROM t",
    "SELECT array_sort(l, CAST('DESCENDING' AS VARCHAR), CAST('NULLS_FIRST' AS VARCHAR)) FROM t",
    "SELECT array_grade_up(l, CAST('desc' AS VARCHAR), CAST('nulls first' AS VARCHAR)) FROM t",
    "SELECT list_sort(list(a ORDER BY b ASC NULLS LAST), CAST('ASC' AS VARCHAR), CAST('NULLS LAST' AS VARCHAR)) FROM t",
]

# Frames, LIMIT, OFFSET, DISTINCT ON and histograms with the rule kept; RANGE
# and GROUPS frames, whose rows are all peers with no ORDER BY.
ACCEPTED += [
    "SELECT count(v) OVER (ORDER BY id ASC NULLS LAST ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM groups",
    "SELECT sum(v) OVER (PARTITION BY k ORDER BY id DESC NULLS FIRST ROWS CAST(1 AS BIGINT) PRECEDING) FROM groups",
    "SELECT count(v) OVER w FROM groups WINDOW w AS (ORDER BY id ASC NULLS LAST ROWS CAST(1 AS BIGINT) PRECEDING)",
    "SELECT count(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM groups",
    "SELECT count(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW) FROM groups",
    "SELECT count(v) OVER (RANGE BETWEEN CURRENT ROW AND CURRENT ROW) FROM groups",
    "SELECT count(v) OVER (GROUPS BETWEEN CAST(1 AS BIGINT) PRECEDING AND CURRENT ROW) FROM groups",
    "SELECT sum(v) OVER (PARTITION BY k) FROM groups",
    "SELECT id FROM groups ORDER BY id ASC NULLS LAST OFFSET 1",
    "SELECT id FROM groups ORDER BY id ASC NULLS LAST LIMIT 50%",
    "SELECT id FROM groups UNION ALL SELECT k FROM groups ORDER BY id ASC NULLS LAST LIMIT 1",
    "SELECT id FROM (SELECT id FROM groups ORDER BY id DESC NULLS LAST LIMIT 1) AS s",
    "SELECT DISTINCT ON (k) k, id FROM groups ORDER BY k ASC NULLS LAST, id ASC NULLS LAST",
    "SELECT DISTINCT k FROM groups",
    "SELECT histogram(CAST(f AS VARCHAR)), histogram(CAST(a AS BIGINT)) FROM t",
    "SELECT histogram(CAST(f AS DOUBLE[])), histogram(TRY_CAST(f AS STRUCT(x DOUBLE))) FROM t",
    "SELECT histogram(CAST(k AS BIGINT)) OVER (PARTITION BY k) FROM groups",
    "SELECT histogram(f, [CAST(0 AS DOUBLE), CAST(1 AS DOUBLE)]), histogram_exact(a, [CAST(1 AS BIGINT)]) FROM t",
    "SELECT histogram(id, (SELECT [CAST(count(*) AS BIGINT)] FROM groups)) FROM groups",
]

# The tables the queries above may name, as gen_expected.py passes its own.
TABLES = ("t", "groups")

# DuckDB marks `error` VOLATILE so the optimizer never folds it; its answer
# is its own argument, read at no particular time.
_STABLE_VOLATILE = frozenset(["error"])
_NOT_FUNCTIONS = ("current_time", "current_timestamp", "localtime", "localtimestamp")
# The names sql_discipline.py lists by hand (DuckDB marks them CONSISTENT):
# each must be a function of the running DuckDB, so a rename on an upgrade
# is seen.
_HAND = (
    "current_localtime", "current_localtimestamp", "current_setting", "getvariable",
    "json_deserialize_sql", "json_serialize_plan", "json_serialize_sql", "make_type",
    "parse_duckdb_log_message", "st_setcrs", "vector_type", "version",
)


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
    for name in _HAND:
        if name not in known:
            FAILURES.append("_UNSTABLE lists %s by hand, which is no function in this DuckDB" % name)
    kinds = {}
    for r in rows:
        kinds.setdefault(r[0], set()).add(r[1])
    for name in sorted(sql_discipline._TABLE_FUNCTIONS):
        if "table" not in kinds.get(name, set()) or "table_macro" in kinds.get(name, set()):
            FAILURES.append("_TABLE_FUNCTIONS lists %s, which is not a built-in table function alone: %s"
                            % (name, sorted(kinds.get(name, set()))))
    unstable = {r[0] for r in rows if r[1] in ("scalar", "aggregate") and r[2] not in (None, "CONSISTENT")}
    unstable -= _STABLE_VOLATILE
    # list_aggregate(l, 'name') calls an aggregate by a string no rule
    # reads: it is safe only while no aggregate is unstable.
    for name in sorted(n for n in unstable if "aggregate" in kinds.get(n, set())):
        FAILURES.append("DuckDB marks aggregate %s() unstable; list_aggregate(l, '%s') reaches it by a string"
                        % (name, name))
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


# Every other aggregate of DuckDB v1.5.6, and why its answer is the same in
# any order of the same rows (rounding aside, which a case's `float` policy
# is for). test_sql_discipline requires this and _ORDER_SENSITIVE to cover
# duckdb_functions()'s aggregates, apart.
_ORDER_FREE = frozenset([
    # Counts, extremes, logic and bits: commutative and associative.
    "bit_and", "bit_or", "bit_xor", "bool_and", "bool_or", "count", "count_if", "count_star",
    "countif", "max", "min",
    # Integer and decimal sums are exact; float sums, products and moments
    # differ only by rounding.
    "avg", "corr", "covar_pop", "covar_samp", "favg", "fsum", "kahan_sum", "kurtosis",
    "kurtosis_pop", "mean", "product", "regr_avgx", "regr_avgy", "regr_count", "regr_intercept",
    "regr_r2", "regr_slope", "regr_sxx", "regr_sxy", "regr_syy", "sem", "skewness", "stddev",
    "stddev_pop", "stddev_samp", "sum", "sum_no_overflow", "sumkahan", "var_pop", "var_samp",
    "variance",
    # Order statistics of the multiset; a HyperLogLog's registers are
    # maxima; counts per value.
    "approx_count_distinct", "entropy", "mad", "median", "quantile", "quantile_cont", "quantile_disc",
    # Bits set by value (bitstring_agg). histogram and histogram_exact are
    # sql_discipline._HISTOGRAMS: order-free only under its rule.
    "bitstring_agg",
    # Window functions DuckDB lists as aggregates: with no ORDER BY every
    # row is a peer, so each row ranks 1 (percent_rank 0, cume_dist 1).
    "cume_dist", "dense_rank", "percent_rank", "rank", "rank_dense",
])


def _unordered_calls(con, body):
    """The names of the calls in a macro body that carry no ORDER BY of
    their own."""
    text = con.execute("SELECT json_serialize_sql(CAST(? AS VARCHAR))", [body]).fetchone()[0]
    tree = json.loads(text)
    if tree.get("error"):
        raise ValueError(tree.get("error_message"))
    names = set()

    def walk(node):
        if isinstance(node, list):
            for item in node:
                walk(item)
            return
        if not isinstance(node, dict):
            return
        cls = node.get("class")
        if cls in ("FUNCTION", "WINDOW") and not sql_discipline._own_orders(node, cls):
            names.add(str(node.get("function_name", "")).lower())
        for value in node.values():
            walk(value)

    walk(tree)
    return names


def check_order_lists(con):
    """_ORDER_SENSITIVE, _WINDOW_ORDERED, _HISTOGRAMS and _ORDER_FREE split the running
    DuckDB's aggregates (window functions included) between them, and _ORDER_MACROS is exactly the built-in
    macros that reach an order-sensitive aggregate with no ORDER BY."""
    rows = con.execute(
        "SELECT DISTINCT lower(function_name), function_type, macro_definition FROM duckdb_functions()").fetchall()
    aggregates = {r[0] for r in rows if r[1] == "aggregate"}
    sensitive = sql_discipline._ORDER_SENSITIVE | sql_discipline._WINDOW_ORDERED
    for name in sorted(sql_discipline._ORDER_SENSITIVE & sql_discipline._WINDOW_ORDERED):
        FAILURES.append("%s is on both _ORDER_SENSITIVE and _WINDOW_ORDERED" % name)
    for name in sorted(sql_discipline._HISTOGRAMS & (sensitive | _ORDER_FREE)):
        FAILURES.append("%s is on _HISTOGRAMS and on another row-order list" % name)
    listed = sensitive | sql_discipline._HISTOGRAMS
    for name in sorted(sensitive & _ORDER_FREE):
        FAILURES.append("aggregate %s is on both _ORDER_SENSITIVE and _ORDER_FREE" % name)
    for name in sorted((listed | _ORDER_FREE) - aggregates):
        FAILURES.append("%s is listed as an aggregate, which this DuckDB does not have" % name)
    for name in sorted(aggregates - listed - _ORDER_FREE):
        FAILURES.append("aggregate %s is on neither _ORDER_SENSITIVE, _HISTOGRAMS nor _ORDER_FREE" % name)
    macros = []
    for name, ftype, body in rows:
        if ftype == "macro" and body is not None:
            try:
                macros.append((name, _unordered_calls(con, "SELECT " + body)))
            except ValueError as e:
                FAILURES.append("macro %s: DuckDB does not parse its definition: %s" % (name, e))
    bad = set(sensitive)
    derived = set()
    changed = True
    while changed:
        changed = False
        for name, calls in macros:
            if name not in bad and calls & bad:
                bad.add(name)
                derived.add(name)
                changed = True
    for name in sorted(derived - sql_discipline._ORDER_MACROS):
        FAILURES.append("macro %s reaches an order-sensitive aggregate unordered; _ORDER_MACROS does not list it" % name)
    for name in sorted(sql_discipline._ORDER_MACROS - derived):
        FAILURES.append("_ORDER_MACROS lists %s, which is no built-in macro reaching one" % name)


def check_sort_premise():
    """Run, not only parsed: a list sort with no direction follows
    default_order and default_null_order, list_reverse_sort follows
    default_order whatever its argument, and the spellings check() accepts
    do not."""
    con = duckdb.connect()
    lst = "[CAST(2 AS BIGINT), CAST(NULL AS BIGINT), CAST(1 AS BIGINT)]"
    queries = {
        "list_sort(l)": "SELECT list_sort(%s)" % lst,
        "list_reverse_sort(l, NULLS LAST)": "SELECT list_reverse_sort(%s, CAST('NULLS LAST' AS VARCHAR))" % lst,
        "list_sort(l, ASC, NULLS LAST)":
            "SELECT list_sort(%s, CAST('ASC' AS VARCHAR), CAST('NULLS LAST' AS VARCHAR))" % lst,
        "array_grade_up(l, desc, nulls_first)":
            "SELECT array_grade_up(%s, CAST('desc' AS VARCHAR), CAST('nulls_first' AS VARCHAR))" % lst,
    }
    seen = {k: set() for k in queries}
    for order in ("ASC", "DESC"):
        for nulls in ("NULLS_FIRST", "NULLS_LAST"):
            con.execute("SET default_order = '%s'" % order)
            con.execute("SET default_null_order = '%s'" % nulls)
            for key, sql in queries.items():
                seen[key].add(repr(con.execute(sql).fetchone()[0]))
    con.close()
    for key in ("list_sort(l)", "list_reverse_sort(l, NULLS LAST)"):
        if len(seen[key]) < 2:
            FAILURES.append("%s answers %s under every default_order and default_null_order; "
                            "the rule that refuses it rests on a premise this DuckDB does not hold" % (key, seen[key]))
    for key in ("list_sort(l, ASC, NULLS LAST)", "array_grade_up(l, desc, nulls_first)"):
        if len(seen[key]) != 1:
            FAILURES.append("%s answers %s, varying with the session's defaults; check() accepts it" % (key, sorted(seen[key])))
        try:
            sql_discipline.check(duckdb.connect(), queries[key], ())
        except sql_discipline.DisciplineError as e:
            FAILURES.append("check() refuses the run spelling %s: %s" % (key, e))


def main():
    con = duckdb.connect()
    check_reached(con)
    check_list_is_duckdbs(con)
    check_order_lists(con)
    check_sort_premise()
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

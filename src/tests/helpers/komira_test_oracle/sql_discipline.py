"""The oracle's rules for an ORACLE case's SQL, checked on DuckDB's own parse.

An expected answer is only as good as the query that computed it, so
gen_expected.py refuses, before it runs a query, one that leaves its
semantics to DuckDB's defaults or to the moment it runs, or that reads
anything but the tables the oracle registers:

- every `ORDER BY` key (of the query, a subquery or a window) states its
  direction (ASC or DESC) and its NULL placement (NULLS FIRST or NULLS
  LAST). DuckDB's `default_null_order` is NULLS LAST, the same as the plan's
  default (query semantics §4.1), so a key that relies on it computes the
  same rows today: nothing but this check notices the placement was never
  stated. A window function's own ORDER BY (`first_value(x ORDER BY y)
  OVER (...)`) is held to the same rule: DuckDB keeps it in the window's
  `arg_orders`, beside the OVER clause's `orders`;
- every literal is the operand of a CAST (query semantics, preamble: the
  oracle casts every literal to the plan literal's type), except a literal
  that is itself the count of a LIMIT or an OFFSET, which is a plan
  constant and not a typed value (a literal inside a subquery that computes
  the count is not exempt). An
  uncast `2` beside a BIGINT column computes the same answer, so again only
  this check notices;
- FROM reads only what the oracle hands DuckDB, by allowlist (below): a
  table the caller registered or a CTE in scope, a subquery, a join, a
  VALUES list, no FROM at all, or a table function in `_TABLE_FUNCTIONS`;
- no call to a function in `_UNSTABLE` (below), to a function whose
  name begins `duckdb_` or `pragma_` (each reads the session's catalog,
  settings, logs or storage), or to `age` with one argument (it subtracts
  from today's midnight; `age(a, b)` reads no clock); no SQL value keyword
  that DuckDB's binder may turn into a call (below); and no `USING SAMPLE`
  or `TABLESAMPLE` (a sample is not a function call: DuckDB keeps it in a
  `sample` key of the SELECT or the table reference);
- exactly one statement, a SELECT.

FROM. Every table reference (a SELECT's `from_table` and each side of a
join, at any depth) is one of six kinds; any other (PIVOT, UNPIVOT, a
`DESCRIBE` or `SUMMARIZE` in FROM) is refused. A table named in FROM (a
BASE_TABLE in the parse, which is also how a catalog view such as
`duckdb_tables` or `pg_catalog.pg_settings` parses) must be bare, with no
schema or catalog: the oracle registers its tables unqualified. Its name
must not be a file path (`.`, `/`, `\\` or `:` in it: `FROM 'x.parquet'`
is a BASE_TABLE that DuckDB reads by a replacement scan). And it must be a
CTE in scope or one of the names the caller passes to `check()`, compared
without case as DuckDB's catalog compares them. A CTE is in scope in the
query that defines it (its FROM, its subqueries at any depth, the CTEs
after it in the same WITH) and nowhere else; a CTE's own body does not see
it, except the recursive half (`right`) of a `WITH RECURSIVE` union. A CTE
name is compared with its case: a reference spelt otherwise is held to the
registered names, which can only refuse more than DuckDB would. A table
function (`FROM f(...)`) must be unqualified and in `_TABLE_FUNCTIONS`;
DuckDB's others run SQL text (`query`, `query_table`,
`json_execute_serialized_sql`), read the worker's files (`read_text`,
`read_blob`, `glob`, `read_csv`...) or its catalog.

SQL value keywords. DuckDB's grammar has no CURRENT_DATE keyword: `SELECT
current_timestamp FROM t` parses to a COLUMN_REF named `current_timestamp`,
and only the binder, finding no column of that name, calls the function the
name maps to (`GetSQLValueFunctionName`, bind_columnref_expression.cpp).
Quoting changes nothing: `"current_date"` parses to the same COLUMN_REF, so
it is the function unless a table in scope has such a column. The parse
alone cannot tell which, so a COLUMN_REF whose last name is one of
`_VALUE_KEYWORDS` (all eleven names the map knows: the five clock keywords
and the six that read the session's user, role, catalog or schema) is
refused in each of the four places the binder would try the map: a
one-part name; a two-part name qualified by `alias`, in any case
(`IsPotentialAlias`); any name inside a table function's arguments; and any
name inside the expression of a `COLUMNS(...)` star. The last two are bound
by TableFunctionBinder, which tries the map on the last part of a qualified
name too, so `COLUMNS(x.current_date)` is the clock (a subquery there is
held to this rule as well, more than DuckDB needs). A column of that name is
read qualified by its table, `t.current_date`, which the binder resolves to
the column or refuses.

`_UNSTABLE` holds every scalar or aggregate function DuckDB v1.5.6 itself
marks VOLATILE or CONSISTENT_WITHIN_QUERY (`duckdb_functions().stability`),
except `error` (VOLATILE only so that it is never folded; its answer is its
argument); ICU's current_localtime and current_localtimestamp, which read
the clock but keep the default CONSISTENT; `current_setting` and
`getvariable`, which read the session's settings and variables (these four
are listed by hand: `duckdb_functions()` does not mark them unstable); and
`_MACROS`, every built-in scalar macro whose body reaches any of these, a
`duckdb_`/`pragma_` function, a table or a table function outside
`_TABLE_FUNCTIONS`, directly or through another macro (`ago` is
`current_timestamp - i::interval`). test_sql_discipline.py derives the
unstable functions and `_MACROS` from the running DuckDB's
`duckdb_functions()` and fails if a function is missing here or `_MACROS`
differs from the macros it derives. Table functions and table macros are
outside that derivation: the FROM allowlist refuses every one not named.

The check walks the JSON DuckDB's `json_serialize_sql` makes of the
statement, not the text, so a comment, a string literal or a line break
cannot hide or fake a keyword.
"""

import json

# Built-in scalar macros that reach an unstable function, a duckdb_/pragma_
# function, a table or a table function not allowed below
# (default_functions.cpp); test_sql_discipline.py requires this set to be
# exactly the one it derives.
_MACROS = frozenset([
    "ago",
    "current_catalog",
    "format_type",
    "get_block_size",
    "pg_conf_load_time",
    "pg_get_constraintdef",
    "pg_get_viewdef",
    "pg_postmaster_start_time",
    "pg_sleep",
])

# Functions whose answer depends on when, where or in which session the
# query runs (the module docstring says how the list is derived).
_UNSTABLE = frozenset([
    # DuckDB marks these CONSISTENT_WITHIN_QUERY: a clock or the session.
    "current_database",
    "current_date",
    "current_schema",
    "current_schemas",
    "get_current_time",
    "get_current_timestamp",
    "in_search_path",
    "now",
    "today",
    "transaction_timestamp",
    "txid_current",
    # DuckDB marks these VOLATILE.
    "current_connection_id",
    "current_query",
    "current_query_id",
    "current_transaction_id",
    "currval",
    "gen_random_uuid",
    "nextval",
    "random",
    "setseed",
    "sleep_ms",
    "stats",
    "uuid",
    "uuidv4",
    "uuidv7",
    "write_log",
    # ICU's clock readers that DuckDB leaves CONSISTENT; the session's
    # settings and variables.
    "current_localtime",
    "current_localtimestamp",
    "current_setting",
    "getvariable",
    # Not functions in v1.5.6, kept so a parse that calls them by these
    # names (`current_time()`, `localtime()`) is refused too.
    "current_time",
    "current_timestamp",
    "localtime",
    "localtimestamp",
]) | _MACROS

# Function names that read the session's catalog, settings, logs or storage.
_SESSION_PREFIXES = ("duckdb_", "pragma_")

# The table functions a query may call in FROM. Each computes its rows from
# its arguments alone, and the arguments are held to every rule here. No
# ORACLE case calls one today; these are the row sources a plan case needs
# that no dataset holds.
_TABLE_FUNCTIONS = frozenset([
    # The integers (or instants) from a start to a stop by a step, the stop
    # included.
    "generate_series",
    # As generate_series, the stop excluded.
    "range",
    # The elements of a list (or the fields of a struct) given as argument.
    "unnest",
])

# The kinds of table reference FROM may hold (TableReferenceType). Not
# PIVOT (`IN <enum>` reads a type from the catalog; PIVOT and UNPIVOT are
# no plan's), SHOW_REF (`DESCRIBE`, `SUMMARIZE`), or a kind DuckDB adds.
_FROM_KINDS = frozenset([
    "BASE_TABLE",
    "EMPTY",
    "EXPRESSION_LIST",
    "JOIN",
    "SUBQUERY",
    "TABLE_FUNCTION",
])

# A table name holding one of these is a path DuckDB's replacement scans
# read (`FROM 'x.parquet'`, `FROM '/dir/*.csv'`); no registered name does.
_PATH_CHARS = "./\\:"


# GetSQLValueFunctionName's map in DuckDB v1.5.6: a column name the binder
# cannot resolve, lowercased, and the function it calls instead.
_VALUE_KEYWORDS = {
    "current_catalog": "current_catalog",
    "current_date": "current_date",
    "current_role": "current_role",
    "current_schema": "current_schema",
    "current_time": "get_current_time",
    "current_timestamp": "get_current_timestamp",
    "current_user": "current_user",
    "localtime": "current_localtime",
    "localtimestamp": "current_localtimestamp",
    "session_user": "session_user",
    "user": "user",
}


class DisciplineError(ValueError):
    pass


_ORDER_KEYS = ("orders", "arg_orders")
_LIMIT_MODIFIERS = ("LIMIT_MODIFIER", "LIMIT_PERCENT_MODIFIER")


def _value_keyword(node, in_table_fn):
    """The function a COLUMN_REF `node` may bind to, or None."""
    names = node.get("column_names") or []
    if not names:
        return None
    target = _VALUE_KEYWORDS.get(str(names[-1]).lower())
    if target is None:
        return None
    if len(names) == 1 or in_table_fn:
        return target
    if len(names) == 2 and str(names[0]).lower() == "alias":
        return target
    return None


def _ctes(node):
    """The (name, info) pairs of the WITH of query node `node`, in order."""
    cte_map = node.get("cte_map")
    if not isinstance(cte_map, dict):
        return []
    return [(str(e.get("key")), e.get("value")) for e in cte_map.get("map") or []]


def _check_ref(node, path, scope, tables, problems):
    """Hold the table reference `node` to the FROM allowlist; `scope` is
    the CTE names in scope, `tables` the registered names (lowercase)."""
    kind = node.get("type")
    if kind not in _FROM_KINDS:
        problems.append("%s: a %s in FROM; it may hold a table, a CTE, a subquery, a join, VALUES or %s()"
                        % (path, kind, "(), ".join(sorted(_TABLE_FUNCTIONS))))
    elif kind == "BASE_TABLE":
        name = str(node.get("table_name", ""))
        qualifier = [str(node.get(k)) for k in ("catalog_name", "schema_name") if node.get(k)]
        if qualifier:
            problems.append("%s: %s names a schema or catalog; the oracle's tables are named bare"
                            % (path, ".".join(qualifier + [name])))
        elif any(c in name for c in _PATH_CHARS):
            problems.append("%s: %s is a file path, which DuckDB reads by a replacement scan" % (path, name))
        elif name not in scope and name.lower() not in tables:
            problems.append("%s: %s is neither a table the oracle registers nor a CTE in scope" % (path, name))
    elif kind == "TABLE_FUNCTION":
        fn = node.get("function") or {}
        fname = str(fn.get("function_name", ""))
        if fn.get("catalog") or fn.get("schema") or fname.lower() not in _TABLE_FUNCTIONS:
            problems.append("%s: %s() is not a table function the oracle allows (%s())"
                            % (path, fname, "(), ".join(sorted(_TABLE_FUNCTIONS))))


class _Ctx:
    def __init__(self, tables):
        self.tables = tables
        self.problems = []


def _walk(node, path, in_cast, is_count, in_table_fn, is_ref, scope, ctx):
    """`in_cast`: `node` is a CAST's operand; `is_count`: `node` is the
    count of a LIMIT or an OFFSET; `is_ref`: `node` is a table reference.
    None of the three is inherited below `node`.
    `in_table_fn`: `node` is inside a table function's arguments or a
    COLUMNS star's expression (both bound by TableFunctionBinder); it is
    inherited by everything below. `scope`: the CTE names in scope."""
    problems = ctx.problems
    if isinstance(node, list):
        for i, item in enumerate(node):
            _walk(item, "%s[%d]" % (path, i), False, False, in_table_fn, False, scope, ctx)
        return
    if not isinstance(node, dict):
        return
    cls = node.get("class")
    if is_ref:
        _check_ref(node, path, scope, ctx.tables, problems)
    if cls == "CONSTANT" and not in_cast and not is_count:
        problems.append("%s: a literal that is not the operand of a CAST: %s" % (path, json.dumps(node.get("value"))))
    if cls == "FUNCTION":
        fname = str(node.get("function_name", "")).lower()
        if fname in _UNSTABLE:
            problems.append("%s: %s() depends on when the query runs" % (path, node["function_name"]))
        elif fname.startswith(_SESSION_PREFIXES):
            problems.append("%s: %s() reads the session's catalog, settings or storage" % (path, node["function_name"]))
        elif fname == "age" and len(node.get("children") or []) == 1:
            problems.append("%s: age() with one argument subtracts from today's midnight" % path)
    if cls == "COLUMN_REF":
        target = _value_keyword(node, in_table_fn)
        if target is not None:
            problems.append("%s: %s is a SQL value keyword; DuckDB binds it to %s() unless a column of that name is in scope"
                            % (path, ".".join(node["column_names"]), target))
    if node.get("sample") is not None:
        problems.append("%s.sample: USING SAMPLE or TABLESAMPLE draws rows at random" % path)
    for key in _ORDER_KEYS:
        for i, order in enumerate(node.get(key) or []):
            where = "%s.%s[%d]" % (path, key, i)
            if order.get("type") not in ("ASCENDING", "DESCENDING"):
                problems.append("%s: an ORDER BY key without ASC or DESC (%s)" % (where, order.get("type")))
            if order.get("null_order") not in ("NULLS FIRST", "NULLS LAST"):
                problems.append("%s: an ORDER BY key without NULLS FIRST or NULLS LAST (%s)" % (where, order.get("null_order")))
    # A WITH: each CTE's body sees the CTEs before it, the rest of the node
    # all of them.
    for i, (name, info) in enumerate(_ctes(node)):
        _walk(info, "%s.cte_map.map[%d].value" % (path, i), False, False, in_table_fn, False, scope, ctx)
        scope = scope | {name}
    limit = node.get("type") in _LIMIT_MODIFIERS
    table_fn = node.get("type") == "TABLE_FUNCTION"
    join = is_ref and node.get("type") == "JOIN"
    recursive = node.get("type") == "RECURSIVE_CTE_NODE"
    for key in sorted(node):
        if key == "cte_map":
            continue
        # A CTE's recursive half reads the CTE itself.
        inner = scope | {str(node.get("cte_name"))} if recursive and key == "right" else scope
        # A CAST's operand is its `child`, a limit modifier's counts its
        # `limit` and `offset`; anything deeper is neither. A table
        # function's arguments are under its `function`, a COLUMNS star's
        # expression under its `expr`. A SELECT's table reference is its
        # `from_table`, a join's its `left` and `right`.
        _walk(node[key], path + "." + key, cls == "CAST" and key == "child",
              limit and key in ("limit", "offset"),
              in_table_fn or (table_fn and key == "function") or (cls == "STAR" and key == "expr"),
              key == "from_table" or (join and key in ("left", "right")),
              inner, ctx)


def check(con, sql, tables):
    """Raise DisciplineError listing every rule `sql` breaks; `con` is a
    DuckDB connection (its parser serializes the statement), `tables` the
    names of the tables the caller registered on the connection that runs
    `sql`, the only tables its FROM may name besides its CTEs."""
    text = con.execute("SELECT json_serialize_sql(CAST(? AS VARCHAR))", [sql]).fetchone()[0]
    tree = json.loads(text)
    if tree.get("error"):
        raise DisciplineError("DuckDB does not parse the query: %s" % tree.get("error_message"))
    statements = tree.get("statements") or []
    if len(statements) != 1:
        raise DisciplineError("%d statements, not one" % len(statements))
    node = statements[0].get("node") or {}
    if node.get("type") not in ("SELECT_NODE", "SET_OPERATION_NODE"):
        raise DisciplineError("the statement is a %s, not a SELECT" % node.get("type"))
    ctx = _Ctx(frozenset(str(t).lower() for t in tables))
    _walk(statements[0], "statement", False, False, False, False, frozenset(), ctx)
    if ctx.problems:
        raise DisciplineError("; ".join(ctx.problems))

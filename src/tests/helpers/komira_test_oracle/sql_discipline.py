"""The oracle's rules for an ORACLE case's SQL, checked on DuckDB's own parse.

An expected answer is only as good as the query that computed it, so
gen_expected.py refuses, before it runs a query, one that leaves its
semantics to DuckDB's defaults or to the moment it runs:

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
- no call to a function in `_UNSTABLE` (below), to a function whose
  name begins `duckdb_` or `pragma_` (each reads the session's catalog,
  settings, logs or storage), or to `age` with one argument (it subtracts
  from today's midnight; `age(a, b)` reads no clock); no SQL value keyword
  that DuckDB's binder may turn into a call (below); and no `USING SAMPLE`
  or `TABLESAMPLE` (a sample is not a function call: DuckDB keeps it in a
  `sample` key of the SELECT or the table reference);
- exactly one statement, a SELECT.

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

`_UNSTABLE` holds every function DuckDB v1.5.6 itself marks VOLATILE or
CONSISTENT_WITHIN_QUERY (`duckdb_functions().stability`), except `error`
(VOLATILE only so that it is never folded; its answer is its argument);
ICU's current_localtime and current_localtimestamp, which read the clock
but keep the default CONSISTENT; `current_setting` and `getvariable`, which
read the session's settings and variables; and every built-in macro whose
body reaches any of these or a `duckdb_`/`pragma_` table function, directly
or through another macro (`ago` is `current_timestamp - i::interval`).
test_sql_discipline.py derives that set from the running DuckDB's
`duckdb_functions()` and fails if a name is missing here.

The check walks the JSON DuckDB's `json_serialize_sql` makes of the
statement, not the text, so a comment, a string literal or a line break
cannot hide or fake a keyword.
"""

import json

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
    # Built-in macros that reach one of the above or a duckdb_/pragma_
    # table function (default_functions.cpp, default_table_functions.cpp).
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

# Function names that read the session's catalog, settings, logs or storage.
_SESSION_PREFIXES = ("duckdb_", "pragma_")


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


def _walk(node, path, in_cast, is_count, in_table_fn, problems):
    """`in_cast`: `node` is a CAST's operand; `is_count`: `node` is the
    count of a LIMIT or an OFFSET. Neither is inherited below `node`.
    `in_table_fn`: `node` is inside a table function's arguments or a
    COLUMNS star's expression (both bound by TableFunctionBinder); it is
    inherited by everything below."""
    if isinstance(node, list):
        for i, item in enumerate(node):
            _walk(item, "%s[%d]" % (path, i), False, False, in_table_fn, problems)
        return
    if not isinstance(node, dict):
        return
    cls = node.get("class")
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
    limit = node.get("type") in _LIMIT_MODIFIERS
    table_fn = node.get("type") == "TABLE_FUNCTION"
    for key in sorted(node):
        # A CAST's operand is its `child`, a limit modifier's counts its
        # `limit` and `offset`; anything deeper is neither. A table
        # function's arguments are under its `function`, a COLUMNS star's
        # expression under its `expr`.
        _walk(node[key], path + "." + key, cls == "CAST" and key == "child",
              limit and key in ("limit", "offset"),
              in_table_fn or (table_fn and key == "function") or (cls == "STAR" and key == "expr"),
              problems)


def check(con, sql):
    """Raise DisciplineError listing every rule `sql` breaks; `con` is a
    DuckDB connection (its parser serializes the statement)."""
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
    problems = []
    _walk(statements[0], "statement", False, False, False, problems)
    if problems:
        raise DisciplineError("; ".join(problems))

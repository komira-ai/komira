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
- no function that reads a clock or draws a random number, and no
  `USING SAMPLE` or `TABLESAMPLE` (a sample is not a function call: DuckDB
  keeps it in a `sample` key of the SELECT or the table reference);
- exactly one statement, a SELECT.

The check walks the JSON DuckDB's `json_serialize_sql` makes of the
statement, not the text, so a comment, a string literal or a line break
cannot hide or fake a keyword.
"""

import json

# Functions whose answer depends on when or where the query runs.
_UNSTABLE = frozenset([
    "current_date",
    "current_time",
    "current_timestamp",
    "get_current_time",
    "get_current_timestamp",
    "gen_random_uuid",
    "localtime",
    "localtimestamp",
    "now",
    "random",
    "setseed",
    "today",
    "transaction_timestamp",
    "uuid",
    "uuidv4",
    "uuidv7",
])


class DisciplineError(ValueError):
    pass


_ORDER_KEYS = ("orders", "arg_orders")
_LIMIT_MODIFIERS = ("LIMIT_MODIFIER", "LIMIT_PERCENT_MODIFIER")


def _walk(node, path, in_cast, is_count, problems):
    """`in_cast`: `node` is a CAST's operand; `is_count`: `node` is the
    count of a LIMIT or an OFFSET. Neither is inherited below `node`."""
    if isinstance(node, list):
        for i, item in enumerate(node):
            _walk(item, "%s[%d]" % (path, i), False, False, problems)
        return
    if not isinstance(node, dict):
        return
    cls = node.get("class")
    if cls == "CONSTANT" and not in_cast and not is_count:
        problems.append("%s: a literal that is not the operand of a CAST: %s" % (path, json.dumps(node.get("value"))))
    if cls == "FUNCTION" and str(node.get("function_name", "")).lower() in _UNSTABLE:
        problems.append("%s: %s() depends on when the query runs" % (path, node["function_name"]))
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
    for key in sorted(node):
        # A CAST's operand is its `child`, a limit modifier's counts its
        # `limit` and `offset`; anything deeper is neither.
        _walk(node[key], path + "." + key, cls == "CAST" and key == "child",
              limit and key in ("limit", "offset"), problems)


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
    _walk(statements[0], "statement", False, False, problems)
    if problems:
        raise DisciplineError("; ".join(problems))

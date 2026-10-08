"""The oracle's rules for an ORACLE case's SQL, checked on DuckDB's own parse.

An expected answer is only as good as the query that computed it, so
gen_expected.py refuses, before it runs a query, one that leaves its
semantics to DuckDB's defaults or to the moment it runs:

- every `ORDER BY` key (of the query, a subquery or a window) states its
  direction (ASC or DESC) and its NULL placement (NULLS FIRST or NULLS
  LAST). DuckDB's `default_null_order` is NULLS LAST, the same as the plan's
  default (query semantics §4.1), so a key that relies on it computes the
  same rows today: nothing but this check notices the placement was never
  stated;
- every literal is the operand of a CAST (query semantics, preamble: the
  oracle casts every literal to the plan literal's type), except the counts
  of LIMIT and OFFSET, which are plan constants and not typed values. An
  uncast `2` beside a BIGINT column computes the same answer, so again only
  this check notices;
- no function that reads a clock or draws a random number;
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


def _walk(node, path, in_cast, in_limit, problems):
    if isinstance(node, list):
        for i, item in enumerate(node):
            _walk(item, "%s[%d]" % (path, i), in_cast, in_limit, problems)
        return
    if not isinstance(node, dict):
        return
    cls = node.get("class")
    if cls == "CONSTANT" and not in_cast and not in_limit:
        problems.append("%s: a literal that is not the operand of a CAST: %s" % (path, json.dumps(node.get("value"))))
    if cls == "FUNCTION" and str(node.get("function_name", "")).lower() in _UNSTABLE:
        problems.append("%s: %s() depends on when the query runs" % (path, node["function_name"]))
    if node.get("type") == "ORDER_MODIFIER" or "orders" in node:
        for i, order in enumerate(node.get("orders") or []):
            where = "%s.orders[%d]" % (path, i)
            if order.get("type") not in ("ASCENDING", "DESCENDING"):
                problems.append("%s: an ORDER BY key without ASC or DESC (%s)" % (where, order.get("type")))
            if order.get("null_order") not in ("NULLS FIRST", "NULLS LAST"):
                problems.append("%s: an ORDER BY key without NULLS FIRST or NULLS LAST (%s)" % (where, order.get("null_order")))
    limit = in_limit or node.get("type") in ("LIMIT_MODIFIER", "LIMIT_PERCENT_MODIFIER")
    for key in sorted(node):
        child = node[key]
        # A CAST's operand is its `child`; anything deeper is not cast.
        _walk(child, path + "." + key, cls == "CAST" and key == "child", limit, problems)


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

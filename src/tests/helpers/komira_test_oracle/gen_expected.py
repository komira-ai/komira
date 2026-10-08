"""The expected answers of the ORACLE cases, computed by DuckDB.

    gen_expected.py <output directory> <data directory>

A `python_oracle` script (tools/build/python/README.md, Oracles). The data
directory holds the cases, `<shard>/<case>.sql`, staged from `oracle/`. Each
file is one SELECT, after a header of `--` lines:

    -- order: total | none | keys=<c1>,<c2>     (required)
    -- float: ulps=<n> | rel=<x>                 (optional; ulps=0)
    -- not null: <c1>, <c2>                      (optional; every other
                                                  column is nullable)

`order` and `float` are the comparison policy the expected file carries.
`not null` declares the columns the plan declares non-nullable (query
semantics §8, preamble: declared nullability is hand-derived, never read
from DuckDB, whose result types carry none); render.py refuses the
declaration if the column holds a NULL.

The tables a query names are the datasets of datasets.py (`types`, `nulls`,
`join_left`, `join_right`) and the HAND twins' inputs of twin_inputs.py
(`bool_pairs`, `ints_nullable`, `groups`, `sort_rows`), each built in Python
from its seed or its rows and handed to DuckDB as a pyarrow table: no file
is read back, and nothing komira wrote is an input.

DuckDB runs with `threads = 1`, no extension autoloaded or autoinstalled,
no external access (CONFIG, set when the database opens), `TimeZone =
'UTC'` and `Calendar = 'gregorian'` (set right after, before any query) and
its defaults otherwise (query semantics, preamble): ICU takes its default
TimeZone and Calendar from the process's TZ and locale, so both are pinned. Each query is first held to
sql_discipline.py (every ORDER BY key states ASC/DESC and NULLS FIRST/LAST,
every literal is CAST, no function on its list of those reading more than
their arguments (a clock, a random draw, the session, SQL text, the running
DuckDB), no aggregate whose answer depends on the order rows reach it
(`list`, `string_agg`, `first`...) without an ORDER BY of its own, no
window ROWS frame without an OVER ORDER BY, no LIMIT, OFFSET or DISTINCT
ON without an ORDER BY in its query, no FLOAT or DOUBLE histogram, no
`list_sort` that leaves its direction or NULL placement to the session,
no COLLATE, and FROM names only the tables registered here, with no AT
clause, its own CTEs and the allowed table functions), on the exact text
that is then run,
and to its policy (sql_discipline.check_order_policy: under `order:
total` the outermost query has an ORDER BY, under `keys=<cols>` one that
leads with exactly those columns), so that no file freezes the order
DuckDB happens to write the rows in; the tie check below holds every
ORDER BY in the query to fixing whatever order the answer shows.

Then the row-order check (row_order_diffs): the case runs again once per
order of case_order_set(), on a connection of its own that registers the
tables the case names again with their rows in that order (register()),
and each answer must equal the first under the case's policy
(canon.compare: a multiset under `order: none`, row for row under
`total`, key order with runs of equal keys as multisets under `keys`;
floats within the tolerance). A table's orders are each of its
rotations and the reverse of each (permutation(), table_orders()), so
every row of the table arrives first in one and last in another, and so
does every row of any subset of it (the rows a WHERE keeps, a group). A
case naming one table runs under each of that table's orders; one naming
two or more runs under every combination of their tables' own orders
(the joint scheme), when there are at most JOINT_BUDGET combinations.
The check then sees any answer that depends on which row of each table
arrives first or last, whatever the other tables' order, the sign of a
zero that min, max, a GROUP BY or DISTINCT key or a LIMIT over tied keys
keeps included. Above the budget a case runs under row_orders() of its
largest table, every table rotated by one shared i modulo its own size
(the shared scheme), and its file carries a `# row-order check: ...`
line saying so: there a dependence on a combination of two tables'
orders that no shared i gives is not seen. Neither scheme sees every
dependence on the order of rows in the middle (all n! orders), nor an
order an inner sort (a subquery's or a CTE's ORDER BY, a window's sort)
fixes whatever the tables' order: that is the tie check's.

Then the tie check (order_ties): an ORDER BY whose keys tie leaves the
tied rows in the order they reached it, which an inner sort fixes
whatever the tables' order, so the row-order check cannot see it.
tie_sites() finds every ORDER BY of the query whose ties can show in
its answer, and each gets tiebreak keys that tell apart every row its
reader can: a query node's ORDER BY (the outermost, a subquery's, a
CTE's, a set operation's or a branch's) every output column of that
node, by position; a window's OVER ORDER BY, when its function reads
row positions (sql_discipline._WINDOW_ORDERED) or its frame counts rows,
`row(*COLUMNS(*))` (with a GROUP BY, the group expressions, and
grouping() under grouping sets); a window function's own ORDER BY, the
same keys as its OVER ORDER BY; an aggregate's own ORDER BY, the
function's arguments. The case runs again with each
ORDER BY's keys appended ascending, then descending, one ORDER BY at a
time and, with two or more, all at once each way (tie_variants()), and
is refused unless every run equals the first under the case's policy
(as the row-order check compares), every float zero taken as 0.0
(DuckDB 1.5.6 returns a column it sorts on by position with -0.0 turned
into 0.0). Not seen: a dependence only on an order between the two
extremes, or on two ORDER BYs turned opposite ways at once; two
windows over rows equal in every column of their FROM, which no key
tells apart; a tie between -0.0 and 0.0; an order an aggregate with no ORDER BY reads
that sql_discipline.py accepts (a float sum's rounding). A collation
would make the keys tie strings that differ: sql_discipline.py refuses
COLLATE. Under `total`, rows equal in every column but the sign of a
zero tie in every sort; two such rows next to each other are refused
too, even where a key the output does not hold tells them apart.

The result is rendered by render.py to

    <output directory>/expect/<shard>/<case>.tsv

with, after the policy lines, the line
`# GENERATED by gen_expected.py (duckdb <version>, pyarrow <version>) from oracle/<shard>/<case>.sql`.
"""

import copy
import itertools
import json
import os
import re
import sys

import duckdb
import pyarrow as pa
import pyarrow.compute as pc

import canon
import datasets
import oracle_case
import render
import sql_discipline
import twin_inputs


# Every table connect() registers: the only tables a case's FROM may name.
TABLES = list(datasets.NAMES) + list(twin_inputs.NAMES)


# Fixed when the database opens, before the first query. DuckDB 1.5.6 loads
# an extension it knows (inet's html_escape(), the INET type, a `.sqlite`
# path) the first time a query names something it holds, unless
# autoload_known_extensions is off, and downloads it first unless
# autoinstall_known_extensions is off; with enable_external_access off it
# loads no extension by any path and reads no file and no Python variable
# a query names, and a running database refuses to turn it back on. What
# answers a case is then the wheel and the tables registered here.
CONFIG = {
    "threads": 1,
    "autoload_known_extensions": False,
    "autoinstall_known_extensions": False,
    "enable_external_access": False,
}


# The kinds of order of the row-order check (row_order_diffs): a table's
# order is (kind, i), its rows rotated by i, and that rotation reversed.
# An order of the check is one such pair applied to every table (the
# shared scheme), or a dict naming each table's own (the joint scheme).
ORDER_KINDS = ("rotated", "reversed")

# The most joint orders the row-order check runs for one case: above it,
# the case falls back to the shared scheme and its file says so
# (case_order_set). On the farm an order costs 4 to 6.5 ms: a join of
# join_left and join_right (40 and 30 rows, 4799 joint orders) about 20 s
# for a count and 31 s for its rows, in each of the action's two runs,
# against 0.6 s for its 79 shared orders.
JOINT_BUDGET = 5000

_BUILT = {}


def tables():
    """Every table connect() registers, by name, each built once per process."""
    if not _BUILT:
        for name in datasets.NAMES:
            _BUILT[name] = datasets.build(name).table
        for name in twin_inputs.NAMES:
            if name in _BUILT:
                raise oracle_case.CaseError("table %s is both a dataset and a twin input" % name)
            _BUILT[name] = twin_inputs.build(name)
    return _BUILT


def permutation(n, order):
    """The row indices of a table of `n` rows in row order `order`, a
    (kind, i) pair: ("rotated", i) is rows i mod n to n - 1, then 0 to
    i mod n - 1; ("reversed", i) is that, reversed."""
    kind, i = order
    if kind not in ORDER_KINDS:
        raise ValueError("row order %r is not one of %s" % (kind, ORDER_KINDS))
    k = i % n if n else 0
    idx = list(range(k, n)) + list(range(k))
    if kind == "reversed":
        idx.reverse()
    return idx


def row_orders(n):
    """The orders of the row-order check for tables of at most `n` rows:
    every rotation but the identity, and the reverse of every rotation,
    2n - 1 orders. Over i < n every table of m <= n rows takes each of its
    m rotations: row r arrives first rotated by r and last rotated by r +
    1, and the reverse of each rotation runs the other way round."""
    return [("rotated", i) for i in range(1, n)] + [("reversed", i) for i in range(n)]


def table_orders(n):
    """Every order of one table of `n` rows in the joint scheme: each
    rotation (rotation 0 is the as-built order) and its reverse, 2n
    orders; the as-built order alone for an empty table."""
    if n == 0:
        return [("rotated", 0)]
    return [("rotated", i) for i in range(n)] + [("reversed", i) for i in range(n)]


def order_name(order):
    if isinstance(order, dict):
        return ", ".join("%s %s" % (name, order_name(order[name])) for name in sorted(order))
    kind, i = order
    return "rotated by %d" % i if kind == "rotated" else "rotated by %d and reversed" % i


def _order_of(order, name):
    return order.get(name) if isinstance(order, dict) else order


def case_order_set(con, sql):
    """The orders under which the row-order check runs `sql`, and a note
    for its file or None. A query naming at most one table: row_orders()
    of it. Naming two or more: every combination of each table's own
    table_orders() but the as-built one (the joint scheme), when there are
    at most JOINT_BUDGET; above that, row_orders() of the largest, every
    table rotated by one shared i (the shared scheme), and a note saying
    so."""
    built = tables()
    names = sorted(t for t in sql_discipline.tables_read(con, sql) if t in built)
    sizes = [built[t].num_rows for t in names]
    shared = row_orders(max(sizes + [0]))
    if len(names) < 2:
        return shared, None
    per = [table_orders(n) for n in sizes]
    count = 1
    for p in per:
        count *= len(p)
    count -= 1
    if count > JOINT_BUDGET:
        return shared, ("row-order check: the %d joint orders of %s exceed the budget of %d; every table "
                        "rotated by one shared i instead (%d orders)" % (count, ", ".join(names), JOINT_BUDGET,
                                                                         len(shared)))
    return [dict(zip(names, combo)) for combo in itertools.islice(itertools.product(*per), 1, None)], None


def case_orders(con, sql):
    """The orders of case_order_set()."""
    return case_order_set(con, sql)[0]


def connect(order=None, names=None):
    """The oracle's connection, every table registered (with `names`,
    those tables only); with `order` (a (kind, i) pair, permutation(), or
    a dict of them by table name), each table holds the same rows in that
    order."""
    con = duckdb.connect(config=CONFIG)
    con.execute("SET threads = 1")
    # ICU (in the wheel) takes its default TimeZone from the process's TZ
    # and its default Calendar from its locale when it loads
    # (icu_extension.cpp, LoadInternal): under LC_ALL=th_TH.UTF-8 the
    # Calendar is `buddhist`, and date_part('year', ...) of a TIMESTAMPTZ in
    # 2026 answers 2569. Both are set here, before the first query: the
    # wheel refuses `Calendar` in the config DuckDB opens with ("options
    # were not recognized").
    con.execute("SET TimeZone = 'UTC'")
    con.execute("SET Calendar = 'gregorian'")
    register(con, order, names)
    return con


def register(con, order=None, names=None):
    """Register on `con` every table (with `names`, those tables only), with
    `order` (a (kind, i) pair, permutation(), applied to every table; or a
    dict of them by table name, a table it does not name as built) in
    that row order. A name
    registered before is replaced (duckdb-python's RegisterPythonObject
    creates the view with replace set when it registered the name), so the
    row-order check reorders one connection rather than opening one per
    order, which costs tens of milliseconds each."""
    for name, table in tables().items():
        if names is not None and name not in names:
            continue
        own = _order_of(order, name) if order is not None else None
        if own is not None:
            table = table.take(pa.array(permutation(table.num_rows, own), type=pa.int64()))
        con.register(name, table)


def execute(con, sql):
    """Run `sql` as it is, unchecked; the result as a pyarrow Table."""
    res = con.execute(sql)
    if hasattr(res, "to_arrow_table"):
        table = res.to_arrow_table()
    else:
        table = res.fetch_arrow_table()
    if isinstance(table, pa.RecordBatchReader):
        table = table.read_all()
    return table


def run_query(con, sql):
    """Check `sql` and run that same text; the result as a pyarrow Table."""
    sql_discipline.check(con, sql, TABLES)
    return execute(con, sql)


def row_order_diffs(orders, sql, policy, not_null, text):
    """Every difference between `text` (the case's answer, rendered) and
    the answer of the same `sql` with the tables it names registered in
    each order of `orders` in turn (register(), on one connection of its
    own), compared as
    canon.compare compares a result with its expectation under the case's
    `policy`: as a multiset (`none`), row for row (`total`), or in key
    order with each run of equal keys as a multiset (`keys`), floats
    within the policy's tolerance. [] when every order gives the same
    answer."""
    want = canon.parse(text)
    con = connect(names=())
    names = sql_discipline.tables_read(con, sql)
    diffs = []
    held = {}
    try:
        for order in orders:
            # Re-register only the tables whose order changed: in the joint
            # scheme the last table's order changes at every step, the
            # first's once per round of the others.
            changed = {n for n in names if n not in held or held[n] != _order_of(order, n)}
            register(con, order, changed)
            held.update((n, _order_of(order, n)) for n in changed)
            got = canon.parse(render.render_table(execute(con, sql), policy, (), not_null))
            diffs += ["rows %s: %s" % (order_name(order), d) for d in canon.compare(want, got)]
    finally:
        con.close()
    return diffs


def _serialize(con, sql):
    return json.loads(con.execute("SELECT json_serialize_sql(CAST(? AS VARCHAR))", [sql]).fetchone()[0])


def _deserialize(con, statement):
    tree = {"error": False, "statements": [statement]}
    return con.execute("SELECT json_deserialize_sql(CAST(? AS JSON))", [json.dumps(tree)]).fetchone()[0]


# The functions in a select list that may write more than one column: a
# star (`*`, `COLUMNS(...)`, `*COLUMNS(...)`, `s.*`) is a STAR node, and
# unnest of a struct writes one column per field.
_MULTI_COLUMN_FUNCTIONS = ("unnest", "unlist")

# DuckDB 1.5.6's binder error for an ORDER BY position past the last
# output column (CreateOrderExpression, bind_select_node.cpp), which
# names how many there are.
_OUT_OF_RANGE = re.compile(r"ORDER term out of range - should be between 1 and (\d+)")
_PAST_THE_END = 1 << 30


def _may_write_many(node):
    if isinstance(node, list):
        return any(_may_write_many(item) for item in node)
    if not isinstance(node, dict):
        return False
    if node.get("class") == "STAR":
        return True
    if node.get("class") == "FUNCTION" and str(node.get("function_name", "")).lower() in _MULTI_COLUMN_FUNCTIONS:
        return True
    return any(_may_write_many(value) for value in node.values())


def _at(tree, path):
    for step in path:
        tree = tree[step]
    return tree


def _path_text(path):
    text = "statement"
    for step in path:
        text += "[%d]" % step if isinstance(step, int) else "." + step
    return text


class _Site:
    """One ORDER BY of a query: `path` leads from the statement to its list
    of keys; `what` names it in a refusal; `keys(direction)` are the
    tiebreak keys appended to it (each a parse-tree order entry)."""

    def __init__(self, path, what, keys):
        self.path = path
        self.what = what
        self.keys = keys


class _Spelling:
    """Parse-tree pieces the tiebreak keys are built from, spelt by DuckDB."""

    def __init__(self, con):
        def order_entry(direction):
            sql = "SELECT 1 ORDER BY 1 " + direction
            return _serialize(con, sql)["statements"][0]["node"]["modifiers"][0]["orders"][0]

        self.entries = {"ASC": order_entry("ASC NULLS LAST"), "DESC": order_entry("DESC NULLS FIRST")}
        select = _serialize(con, "SELECT row(*COLUMNS(*)), grouping(x) FROM x")["statements"][0]["node"]
        self.whole_row = select["select_list"][0]
        self.grouping = select["select_list"][1]

    def key(self, direction, expression):
        entry = copy.deepcopy(self.entries[direction])
        entry["expression"] = copy.deepcopy(expression)
        return entry

    def position(self, direction, c):
        entry = copy.deepcopy(self.entries[direction])
        entry["expression"]["value"]["value"] = c
        return entry


def _output_width(con, statement, path, node, spell):
    """How many columns query node `node` writes (its ORDER BY's keys are
    at `path` in `statement`): its select list's length, when nothing in
    it may write more than one column; else DuckDB's own count, read from
    the binder's refusal of a position past the last."""
    if node.get("type") == "SELECT_NODE" and not _may_write_many(node.get("select_list")):
        return len(node["select_list"])
    probe = copy.deepcopy(statement)
    _at(probe, path).append(spell.position("ASC", _PAST_THE_END))
    try:
        con.execute(_deserialize(con, probe))
    except duckdb.Error as e:
        found = _OUT_OF_RANGE.search(str(e))
        if found:
            return int(found.group(1))
        raise oracle_case.CaseError("the tie check could not count the columns of the query at %s: %s"
                                    % (_path_text(path[:-3]), e))
    raise oracle_case.CaseError("the tie check could not count the columns of the query at %s: DuckDB took "
                                "ORDER BY position %d" % (_path_text(path[:-3]), _PAST_THE_END))


def _window_input_keys(select, spell):
    """Expressions whose values tell apart every row that reaches a window
    of query node `select`: its GROUP BY expressions (each group is one
    row), with grouping() of all of them under grouping sets; with no
    GROUP BY, the whole row of its FROM, `row(*COLUMNS(*))`. None when
    the node has no FROM (one row)."""
    groups = select.get("group_expressions") or []
    if groups:
        keys = [copy.deepcopy(g) for g in groups]
        if len(select.get("group_sets") or []) > 1:
            grouping = copy.deepcopy(spell.grouping)
            grouping["children"] = [copy.deepcopy(g) for g in groups]
            keys.append(grouping)
        return keys
    if select.get("aggregate_handling") == "FORCE_AGGREGATES":
        raise oracle_case.CaseError("the tie check cannot name the groups of a GROUP BY ALL")
    if (select.get("from_table") or {}).get("type") == "EMPTY":
        return None
    return [spell.whole_row]


def tie_sites(con, statement):
    """Every ORDER BY of `statement` (a parse tree, json_serialize_sql's
    statement) whose ties can decide the answer, as _Sites:

    - a query node's ORDER BY (the outermost query's, a subquery's, a
      CTE's, a set operation's or its branch's): keys are every output
      column of that node, by position, which is all a reader of the node
      sees (ORDER BY ALL, already every output column, is skipped);
    - a window's OVER ORDER BY when its function reads row positions
      (sql_discipline._WINDOW_ORDERED: row_number, lag, first_value...) or
      its frame counts rows (a ROWS bound): keys tell apart every row that
      reaches the window (_window_input_keys). Not the rank family and
      not a RANGE or GROUPS aggregate: they answer the same for every
      peer, and a tiebreak would split the peers;
    - a window function's own ORDER BY (`arg_orders`): the same keys as
      an OVER ORDER BY (_window_input_keys), every row that reaches the
      window told apart. Its arguments are not enough: row_number() has
      none, `lag(k ORDER BY k)` reads which row comes before the current
      one, not only k, and lag's offset and default are not among its
      arguments (`children`);
    - an aggregate's own ORDER BY (`order_bys`): keys are the function's
      arguments, all it reads of a row (a `*` argument, count(*)'s, is
      not one)."""
    spell = _Spelling(con)
    sites = []

    def walk(node, path, select):
        if isinstance(node, list):
            for i, item in enumerate(node):
                walk(item, path + (i,), select)
            return
        if not isinstance(node, dict):
            return
        if node.get("type") == "SELECT_NODE":
            select = node
        for m, mod in enumerate(node.get("modifiers") or []):
            orders = mod.get("orders") if isinstance(mod, dict) and mod.get("type") == "ORDER_MODIFIER" else None
            if not orders or (len(orders) == 1 and (orders[0].get("expression") or {}).get("class") == "STAR"):
                continue
            where = path + ("modifiers", m, "orders")
            width = _output_width(con, statement, where, node, spell)
            sites.append(_Site(where, "the ORDER BY at %s" % _path_text(path + ("modifiers", m)),
                               lambda d, n=width: [spell.position(d, c) for c in range(1, n + 1)]))
        cls = node.get("class")
        fname = str(node.get("function_name", "")).lower()
        if cls == "WINDOW" and node.get("orders") and (
                fname in sql_discipline._WINDOW_ORDERED or node.get("start") in sql_discipline._ROWS_BOUNDS
                or node.get("end") in sql_discipline._ROWS_BOUNDS):
            keys = _window_input_keys(select or {}, spell)
            if keys is not None:
                sites.append(_Site(path + ("orders",), "%s()'s OVER ORDER BY at %s" % (fname, _path_text(path)),
                                   lambda d, ks=keys: [spell.key(d, k) for k in ks]))
        own = None
        if cls == "WINDOW" and node.get("arg_orders"):
            own = path + ("arg_orders",)
            own_keys = _window_input_keys(select or {}, spell)
        elif cls == "FUNCTION" and (node.get("order_bys") or {}).get("orders"):
            own = path + ("order_bys", "orders")
            own_keys = [a for a in node.get("children") or []
                        if not (isinstance(a, dict) and a.get("class") == "STAR")]
        if own is not None and own_keys:
            sites.append(_Site(own, "%s()'s own ORDER BY at %s" % (fname, _path_text(path)),
                               lambda d, ks=own_keys: [spell.key(d, k) for k in ks]))
        for key in node:
            walk(node[key], path + (key,), select)

    walk(statement, (), None)
    return sites


def tie_variants(con, sql):
    """The runs of the tie check: (name, SQL) for each ORDER BY of
    tie_sites() with its tiebreak keys appended ascending (NULLS LAST),
    then descending (NULLS FIRST), the others as written; with two or
    more, every ORDER BY's keys appended at once, ascending, then
    descending. Each spelt by DuckDB from its own parse
    (json_deserialize_sql), so the query is otherwise the same."""
    statement = _serialize(con, sql)["statements"][0]
    sites = tie_sites(con, statement)
    plans = [([site], d) for site in sites for d in ("ASC", "DESC")]
    if len(sites) > 1:
        plans += [(sites, d) for d in ("ASC", "DESC")]
    variants = []
    for chosen, d in plans:
        tree = copy.deepcopy(statement)
        for site in chosen:
            _at(tree, site.path).extend(site.keys(d))
        name = ("every ORDER BY" if len(chosen) > 1 else chosen[0].what) + (
            " with tiebreak keys %s" % ("ascending" if d == "ASC" else "descending"))
        variants.append((name, _deserialize(con, tree)))
    return variants


def _zeros_positive(table):
    """`table` with every float -0.0 written 0.0 (top-level columns): the
    value a sort sees, -0.0 tying 0.0. DuckDB 1.5.6 returns a float column
    it sorts on by position with -0.0 turned into 0.0."""
    columns = []
    for col in table.columns:
        if pa.types.is_floating(col.type):
            zero = pa.scalar(0, col.type)
            col = pc.if_else(pc.fill_null(pc.equal(col, zero), False), zero, col)
        columns.append(col)
    return pa.table(columns, names=table.column_names)


def _rows(table):
    columns = [render.render_column(col.combine_chunks()) for col in table.columns]
    return [tuple(c[r] for c in columns) for r in range(table.num_rows)]


def order_ties(con, sql, table, policy):
    """None when no ORDER BY of `sql` leaves a tie its answer `table` depends
    on; else how one does. Each run of tie_variants() must give `table`,
    compared under the case's `policy` as row_order_diffs() compares
    (canon.compare: a multiset under `none`, row for row under `total`,
    runs of equal keys as multisets under `keys`), every float zero taken
    as 0.0: if an ORDER BY's keys tie two rows its reader can tell apart,
    the ascending and descending runs order them opposite ways, and if the
    answer depends on that order one of them differs. Under `total`, rows
    equal in every column but the sign of a zero tie in every sort, so two
    such rows next to each other in `table` are refused too, even where a
    key outside the output (`ORDER BY id` over `SELECT f`) does tell them
    apart."""
    def text(t):
        return canon.parse(render.render_table(_zeros_positive(t), policy, (), ()))

    want = text(table)
    for name, variant in tie_variants(con, sql):
        try:
            got = text(execute(con, variant))
        except duckdb.Error as e:
            raise oracle_case.CaseError("the tie check's run with %s failed (%s): %s"
                                        % (name, e, variant)) from e
        diffs = canon.compare(want, got)
        if diffs:
            return "with %s, %s" % (name, diffs[0])
    if policy.order == "total":
        rows = _rows(table)
        plain = _rows(_zeros_positive(table))
        for r in range(1, len(rows)):
            if plain[r] == plain[r - 1] and rows[r] != rows[r - 1]:
                return ("rows %d and %d are equal but for the sign of a zero, which no sort tells apart: output a "
                        "column that does" % (r, r + 1))
    return None


def generated_line(rel):
    return "GENERATED by gen_expected.py (duckdb %s, pyarrow %s) from oracle/%s" % (duckdb.__version__, pa.__version__, rel)


def cases(data):
    found = []
    for shard in sorted(os.listdir(data)):
        for f in sorted(os.listdir(os.path.join(data, shard))):
            if not f.endswith(".sql"):
                raise oracle_case.CaseError("%s/%s is not a .sql case" % (shard, f))
            found.append(shard + "/" + f)
    return found


def main(out, data):
    con = connect()
    for rel in cases(data):
        with open(os.path.join(data, rel), encoding="utf-8") as f:
            sql = f.read()
        try:
            policy, not_null = oracle_case.read_header(sql)
            sql_discipline.check_order_policy(con, sql, policy.order, policy.keys)
            table = run_query(con, sql)
            orders, note = case_order_set(con, sql)
            comments = [generated_line(rel)] + ([note] if note else [])
            text = render.render_table(table, policy, comments, not_null)
            diffs = row_order_diffs(orders, sql, policy, not_null, text)
            if diffs:
                raise oracle_case.CaseError("the answer depends on the order of the tables' rows, not only on "
                                            "their contents: " + "; ".join(diffs))
            tie = order_ties(con, sql, table, policy)
            if tie:
                raise oracle_case.CaseError("an ORDER BY does not fix the order of rows the answer depends on: "
                                            + tie)
        except Exception as e:
            raise oracle_case.CaseError("oracle/%s: %s" % (rel, e)) from e
        dest = os.path.join(out, "expect", rel[: -len(".sql")] + ".tsv")
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

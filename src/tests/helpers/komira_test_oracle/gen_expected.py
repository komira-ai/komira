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
and FROM names only the tables registered here, with no AT clause, its own
CTEs and the allowed table functions), on the exact text that is then run,
and to its policy (sql_discipline.check_order_policy: under `order:
total` the outermost query has an ORDER BY, under `keys=<cols>` one that
leads with exactly those columns), so that no file freezes the order
DuckDB happens to write the rows in; the tie check below holds a `total`
case's ORDER BY to fixing the order.

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
dependence on the order of rows in the middle (all n! orders).

Then, under `order: total`, the tie check (order_ties): the outermost
ORDER BY must fix the order of the rows. An inner ORDER BY (a subquery's,
a CTE's, a window's sort) fixes the order rows reach the outer sort in
whatever the tables' order, so the row-order check cannot see a tie
behind it; the tie check runs the query again with every output column
added, by position, after the outermost ORDER BY's keys, ascending and
then descending (with_tiebreak()), and refuses the case unless both
answers equal the first: keys that tie two rows differing in any column
order them opposite ways in the two runs. Rows equal in every column but
the sign of a zero tie in every sort; two such rows next to each other
are refused too, even where a key the output does not hold tells them
apart. Under `keys=` no tie check is needed: a run of equal keys is
compared as a multiset, so the order within it is never compared.

The result is rendered by render.py to

    <output directory>/expect/<shard>/<case>.tsv

with, after the policy lines, the line
`# GENERATED by gen_expected.py (duckdb <version>, pyarrow <version>) from oracle/<shard>/<case>.sql`.
"""

import copy
import itertools
import json
import os
import sys

import duckdb
import pyarrow as pa

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


def with_tiebreak(con, sql, ncols, descending):
    """`sql` with every one of its `ncols` output columns, by position,
    added after the keys of its outermost ORDER BY: ASC NULLS LAST, or
    DESC NULLS FIRST, the exact reverse. Spelt by DuckDB from its own
    parse (json_deserialize_sql), so the query is otherwise the same."""
    template = "SELECT 1 ORDER BY 1 " + ("DESC NULLS FIRST" if descending else "ASC NULLS LAST")
    entry = _serialize(con, template)["statements"][0]["node"]["modifiers"][0]["orders"][0]
    tree = _serialize(con, sql)
    node = tree["statements"][0]["node"]
    mods = [m for m in node.get("modifiers") or [] if m.get("type") == "ORDER_MODIFIER"]
    if len(mods) != 1:
        raise oracle_case.CaseError("the outermost query has %d ORDER BY clauses, not one" % len(mods))
    for c in range(1, ncols + 1):
        key = copy.deepcopy(entry)
        key["expression"]["value"]["value"] = c
        mods[0]["orders"].append(key)
    return con.execute("SELECT json_deserialize_sql(CAST(? AS JSON))", [json.dumps(tree)]).fetchone()[0]


def _rows(table, zero_sign=True):
    """The rendered cells of each row of `table`; without `zero_sign`, every
    float zero rendered as 0.0 (the value a sort sees, -0.0 tying 0.0)."""
    columns = []
    for col in table.columns:
        arr = col.combine_chunks()
        cells = render.render_column(arr)
        if not zero_sign and pa.types.is_floating(arr.type):
            zero = render.float_cell(0, arr.type.bit_width)
            cells = [zero if v is not None and v == 0 else cell for v, cell in zip(arr.to_pylist(), cells)]
        columns.append(cells)
    return [tuple(c[r] for c in columns) for r in range(table.num_rows)]


def order_ties(con, sql, table):
    """None when the outermost ORDER BY of `sql` fixes the order of its
    answer `table`'s rows; else how it does not. The query runs again with
    every output column added after its keys, ascending and then
    descending (with_tiebreak()): if its keys tie two rows that differ in
    any column, the two runs order them opposite ways, so one differs from
    `table`. The runs are compared with every float zero taken as 0.0:
    DuckDB 1.5.6 returns a float column it sorts on with -0.0 turned into
    0.0. Rows equal in every column but the sign of a zero tie in every
    sort, so two such rows next to each other in `table` are refused too,
    even where a key outside the output (`ORDER BY id` over `SELECT f`)
    does tell them apart."""
    rows = _rows(table)
    if len(rows) < 2:
        return None
    plain = _rows(table, zero_sign=False)
    for descending in (False, True):
        other = _rows(execute(con, with_tiebreak(con, sql, table.num_columns, descending)), zero_sign=False)
        if other != plain:
            n = min(len(plain), len(other))
            r = next((r for r in range(n) if plain[r] != other[r]), n)
            return ("with every output column added after its keys, %s, row %d is %r, not %r: its keys tie rows "
                    "that differ" % ("descending" if descending else "ascending", r + 1,
                                     "\t".join(other[r]) if r < len(other) else None,
                                     "\t".join(plain[r]) if r < len(plain) else None))
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
            if policy.order == "total":
                tie = order_ties(con, sql, table)
                if tie:
                    raise oracle_case.CaseError("order: total, but the outermost ORDER BY does not fix the order "
                                                "of the rows: " + tie)
        except Exception as e:
            raise oracle_case.CaseError("oracle/%s: %s" % (rel, e)) from e
        dest = os.path.join(out, "expect", rel[: -len(".sql")] + ".tsv")
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

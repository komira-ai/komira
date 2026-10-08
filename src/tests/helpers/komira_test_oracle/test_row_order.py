"""gen_expected.py's row-order check sees an answer that follows the order of the tables' rows.

    test_row_order.py

On gen_expected.connect()'s connection and the connections
gen_expected.connect(order) makes for each of gen_expected.ROW_ORDERS (the
tables' rows reversed, and shuffled by a fixed seed), in a process of its
own:

0. Each reordered connection holds each table's rows in that order: every
   table read back equals the as-built read taken through
   gen_expected.permutation(); the shuffle of a table of three rows or more
   is neither the as-built order nor its reverse. Catches connect(order)
   registering the as-built table, and a shuffle that is a no-op.
1. row_order_diffs() reports each query below that DuckDB answers by the
   rows' order (each confirmed so on these tables): the four the static
   rules of sql_discipline.py refuse (a FLOAT/DOUBLE histogram over NaN, a
   ROWS frame with no OVER ORDER BY, plain and partitioned, a LIMIT and a
   DISTINCT ON with no ORDER BY) and a histogram whose bins are a column's,
   each also required refused by sql_discipline.check(); and the ties
   sql_discipline.py does not see, each required accepted by check(): a
   LIMIT whose ORDER BY ties at the cut, min/max and a GROUP BY key over
   -0.0 and 0.0 (the first to arrive), and a median over them, which only
   the shuffle changes (the reversal is required to miss it, so a check
   that drops the shuffle is caught). Catches row_order_diffs() off, a
   check that runs on the as-built connection, and a shuffle dropped.
2. The comparison is the case's policy: `SELECT id FROM groups` (no ORDER
   BY) is reported under `order: total` and not under `order: none`; rows
   whose ORDER BY key ties are reported under `total` and not under
   `keys=<key>`. Catches a check that compares every case as a multiset,
   or every case row for row.
3. Queries whose answer is the rows' contents are not reported: RANGE and
   GROUPS frames and EXCLUDE with no ORDER BY (every row a peer), a ROWS
   frame with an OVER ORDER BY, a histogram of the same NaN column cast to
   VARCHAR, constant bins over a DOUBLE, LIMIT and DISTINCT ON under an
   ORDER BY without ties. Catches a check that reports every difference
   it could imagine (a comparison of the as-built rows' order under
   `order: none`).
4. main() runs the check: on a data directory holding a case that passes
   sql_discipline.py but answers by the rows' order (`order: total` over
   `SELECT id FROM groups`), it raises CaseError naming the case and the
   row order; the same query under `order: none` writes its file. Catches
   main() not calling the check.
"""

import os
import tempfile

import pyarrow as pa

import gen_expected
import oracle_case
import render
import sql_discipline

FAILURES = []

base = gen_expected.connect()
others = [(order, gen_expected.connect(order)) for order in gen_expected.ROW_ORDERS]


def flagged(sql, order="none", keys=()):
    """The row orders under which `sql` answers otherwise, and the diffs."""
    policy = render.Policy(order, keys)
    text = render.render_table(gen_expected.execute(base, sql), policy)
    diffs = gen_expected.row_order_diffs(others, sql, policy, set(), text)
    return {d.split(":", 1)[0][len("rows "):] for d in diffs}, diffs


def refused(sql):
    try:
        sql_discipline.check(base, sql, gen_expected.TABLES)
    except sql_discipline.DisciplineError:
        return True
    return False


# 0. The reordered connections. Columns are compared as Arrow arrays, a
# float by its bits (Arrow's equality takes NaN for unequal), so -0.0, NaN
# and every instant are compared without a conversion to Python.
def _column(table, i):
    col = table.column(i).combine_chunks()
    if pa.types.is_floating(col.type):
        col = col.view(pa.int64() if col.type.bit_width == 64 else pa.int32() if col.type.bit_width == 32 else pa.int16())
    return col


for name in sorted(gen_expected.tables()):
    rows = gen_expected.execute(base, 'SELECT * FROM "%s"' % name)
    for order, con in others:
        perm = gen_expected.permutation(rows.num_rows, order)
        want = rows.take(pa.array(perm, type=pa.int64()))
        got = gen_expected.execute(con, 'SELECT * FROM "%s"' % name)
        if got.schema != want.schema or any(not _column(got, i).equals(_column(want, i)) for i in range(got.num_columns)):
            FAILURES.append("%s %s: the rows read back are not the as-built rows in that order" % (name, order))
    shuffle = gen_expected.permutation(rows.num_rows, "shuffled")
    if rows.num_rows >= 3 and shuffle in (list(range(rows.num_rows)), list(reversed(range(rows.num_rows)))):
        FAILURES.append("%s: the shuffle of %d rows is the as-built order or its reverse" % (name, rows.num_rows))

_H = "SELECT CAST(histogram(%s) AS VARCHAR) AS h FROM %s"
_BINS = ("histogram(id, CASE WHEN id < CAST(3 AS BIGINT) THEN [CAST(1 AS BIGINT), CAST(2 AS BIGINT)] "
         "ELSE [CAST(5 AS BIGINT)] END)")

# 1. (query, the orders that must report it, at least or exactly, refused
# by sql_discipline.check()).
ORDER_DEPENDENT = [
    (_H % ("f64_special", "types"), {"reversed"}, "at least", True),
    ("SELECT id, count(*) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS c FROM groups",
     {"reversed", "shuffled"}, "at least", True),
    ("SELECT id, CAST(sum(v) OVER (PARTITION BY k ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS BIGINT) AS s "
     "FROM groups", {"reversed", "shuffled"}, "at least", True),
    ("SELECT id FROM groups LIMIT 1", {"reversed", "shuffled"}, "at least", True),
    ("SELECT DISTINCT ON (k) k, id FROM groups", {"reversed", "shuffled"}, "at least", True),
    ("SELECT CAST(%s AS VARCHAR) AS h FROM groups" % _BINS, {"reversed", "shuffled"}, "at least", True),
    # Ties sql_discipline.py does not see. groups' k = 1 holds ids 1 and 2.
    ("SELECT id FROM groups ORDER BY k ASC NULLS LAST LIMIT 1", {"reversed"}, "at least", False),
    ("SELECT min(f64) AS lo, max(f64) AS hi FROM types WHERE f64 = CAST(0.0 AS DOUBLE)", {"reversed"}, "at least", False),
    ("SELECT f64 FROM types WHERE f64 = CAST(0.0 AS DOUBLE) GROUP BY f64", {"reversed"}, "at least", False),
    # sort_rows' zeros arrive 0.0, -0.0, 0.0 as built and reversed alike.
    ("SELECT median(f) AS m FROM sort_rows WHERE f = CAST(0.0 AS DOUBLE)", {"shuffled"}, "exactly", False),
]
for sql, want, how, static in ORDER_DEPENDENT:
    got, diffs = flagged(sql)
    if (how == "exactly" and got != want) or (how == "at least" and not want <= got):
        FAILURES.append("row_order_diffs(%r) is reported under %s, want %s %s: %s"
                        % (sql, sorted(got), how, sorted(want), diffs[:2]))
    if refused(sql) != static:
        FAILURES.append("sql_discipline.check(%r) %s it, want %s" % (sql, "refuses" if not static else "accepts",
                                                                     "refused" if static else "accepted"))

# 2. The case's policy decides what differs.
POLICY = [
    ("SELECT id FROM groups", "total", (), True),
    ("SELECT id FROM groups", "none", (), False),
    ("SELECT id, a FROM sort_rows ORDER BY a ASC NULLS LAST", "total", (), True),
    ("SELECT id, a FROM sort_rows ORDER BY a ASC NULLS LAST", "keys", ("a",), False),
]
for sql, order, keys, want in POLICY:
    got, diffs = flagged(sql, order, keys)
    if bool(got) != want:
        FAILURES.append("row_order_diffs(%r) under order %s %s: reported %s, want %s"
                        % (sql, order, list(keys), sorted(got), "reported" if want else "none"))

# 3. Order-free.
ORDER_FREE = [
    "SELECT id, count(*) OVER (RANGE BETWEEN CURRENT ROW AND CURRENT ROW) AS c FROM groups",
    "SELECT id, count(*) OVER (GROUPS BETWEEN CAST(1 AS BIGINT) PRECEDING AND CURRENT ROW) AS c, "
    "count(*) OVER (PARTITION BY k GROUPS BETWEEN CAST(1 AS BIGINT) FOLLOWING AND UNBOUNDED FOLLOWING) AS d FROM groups",
    "SELECT id, count(*) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW) AS c, "
    "count(*) OVER (PARTITION BY k RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW EXCLUDE TIES) AS d FROM groups",
    "SELECT id, CAST(sum(v) OVER (PARTITION BY k ORDER BY id ASC NULLS LAST ROWS BETWEEN CAST(1 AS BIGINT) PRECEDING "
    "AND CURRENT ROW) AS BIGINT) AS s FROM groups",
    _H % ("CAST(f64_special AS VARCHAR)", "types"),
    "SELECT CAST(histogram(f64_special, [CAST(0 AS DOUBLE), CAST(1 AS DOUBLE)]) AS VARCHAR) AS h FROM types",
    "SELECT id FROM groups ORDER BY id ASC NULLS LAST LIMIT 2",
    "SELECT DISTINCT ON (k) k, id FROM groups ORDER BY k ASC NULLS LAST, id ASC NULLS LAST",
]
for sql in ORDER_FREE:
    got, diffs = flagged(sql)
    if got:
        FAILURES.append("row_order_diffs(%r) reports an order-free query: %s" % (sql, diffs[:2]))
    if refused(sql):
        FAILURES.append("sql_discipline.check(%r) refuses an order-free query" % sql)


# 4. main() runs the check.
def run_main(sql):
    data = tempfile.mkdtemp()
    os.makedirs(os.path.join(data, "plant"))
    with open(os.path.join(data, "plant", "case.sql"), "w", encoding="utf-8") as f:
        f.write(sql)
    out = tempfile.mkdtemp()
    try:
        gen_expected.main(out, data)
    except oracle_case.CaseError as e:
        return str(e), out
    return None, out


err, _ = run_main("-- order: total\n-- not null: id\nSELECT id FROM groups\n")
if err is None or "oracle/plant/case.sql" not in err or "depends on the order of the tables' rows" not in err:
    FAILURES.append("main() over an order: total case with no ORDER BY: %r, want a CaseError naming the case and "
                    "the row order" % err)
err, out = run_main("-- order: none\n-- not null: id\nSELECT id FROM groups\n")
if err is not None or not os.path.exists(os.path.join(out, "expect", "plant", "case.tsv")):
    FAILURES.append("main() over an order: none case: %r, want its file written" % err)

if FAILURES:
    for f in FAILURES:
        print("FAIL", f)
    raise SystemExit("test_row_order: %d failures" % len(FAILURES))
print("test_row_order: %d order-dependent, %d policy, %d order-free queries and main(), all as expected"
      % (len(ORDER_DEPENDENT), len(POLICY), len(ORDER_FREE)))

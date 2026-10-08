"""gen_expected.py's row-order check sees an answer that follows the order of the tables' rows.

    test_row_order.py

On gen_expected.connect()'s connection and the connections
gen_expected.connect(order) makes for the orders of
gen_expected.row_orders() (each table rotated by i modulo its size, and
each rotation reversed), in a process of its own:

0. The order set: for every table size the tables have and every size up
   to 12, each order is a permutation, and over row_orders(n) every row of
   a table of m <= n rows arrives first under some rotation and last under
   some rotation, and the same under the reversed rotations;
   case_orders() is row_orders() of the largest table a query names. Each
   reordered table holds its rows in its order: every table read back
   under four orders (rotated by 1 and by m - 1, reversed, and reversed
   after a rotation by 2), on a connection connect(order) opens and on one connection register() reorders in turn, as
   row_order_diffs() does, equals the as-built read taken through
   gen_expected.permutation(). Catches an order set that leaves a row
   never first or never last (the old reversal and one shuffle), one sized
   by the wrong table, connect(order) or register() leaving the as-built
   or the previous order in place, a rotation or reversal that is a
   no-op.
1. row_order_diffs() reports each query below that DuckDB answers by the
   rows' order (each confirmed so on these tables): the four the static
   rules of sql_discipline.py refuse (a FLOAT/DOUBLE histogram over NaN, a
   ROWS frame with no OVER ORDER BY, plain and partitioned, a LIMIT and a
   DISTINCT ON with no ORDER BY) and a histogram whose bins are a column's,
   each also required refused by sql_discipline.check(); and the ties
   sql_discipline.py does not see, each required accepted by check(): a
   LIMIT whose ORDER BY ties at the cut, min/max and a GROUP BY key over
   `types`' -0.0 and 0.0, and over `sort_rows`' zeros (ids 2, 3 and 6 hold
   0.0, -0.0 and 0.0) min/max, a GROUP BY key, a DISTINCT key, an ORDER BY
   ... LIMIT 1 and a median, each of which keeps the -0.0 only when id 3
   arrives first (or, the median, at its selection's position). Those five
   are also required not reported under the plain reversal alone, which
   keeps a 0.0 first, so the test fails if the check ever relies on the
   reversal for them. Catches row_order_diffs() off, a check that runs on
   the as-built connection, an order set where id 3 never comes first.
2. The comparison is the case's policy: `SELECT id FROM groups` (no ORDER
   BY) is reported under `order: total` and not under `order: none`; rows
   whose ORDER BY key ties are reported under `total` and not under
   `keys=<key>`. Catches a check that compares every case as a multiset,
   or every case row for row.
3. Queries whose answer is the rows' contents are not reported: RANGE and
   GROUPS frames and EXCLUDE with no ORDER BY (every row a peer), a ROWS
   frame with an OVER ORDER BY, a histogram of the same NaN column cast to
   VARCHAR, constant bins over a DOUBLE, LIMIT and DISTINCT ON under an
   ORDER BY without ties, and a count over `nulls`, the largest table (its
   1999 orders). Catches a check that reports every difference it could
   imagine (a comparison of the as-built rows' order under `order: none`).
4. main() runs the check: on a data directory holding a case that passes
   sql_discipline.py and its policy rule but answers by the rows' order
   (`order: total` over `sort_rows` ordered by `a`, which ties), it raises
   CaseError naming the case and the row order; the same query under
   `order: keys=a` writes its file. Catches main() not calling the check.
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
REVERSAL = [("reversed", 0)]


def flagged(sql, order="none", keys=(), orders=None):
    """The diffs of `sql` under the row-order check (`orders`, else the
    case's own, case_orders())."""
    policy = render.Policy(order, keys)
    text = render.render_table(gen_expected.execute(base, sql), policy)
    if orders is None:
        orders = gen_expected.case_orders(base, sql)
    return gen_expected.row_order_diffs(orders, sql, policy, set(), text)


def refused(sql):
    try:
        sql_discipline.check(base, sql, gen_expected.TABLES)
    except sql_discipline.DisciplineError:
        return True
    return False


# 0. The order set.
SIZES = sorted({t.num_rows for t in gen_expected.tables().values()} | set(range(13)))
for n in SIZES:
    orders = gen_expected.row_orders(n)
    if len(orders) != max(2 * n - 1, 0):
        FAILURES.append("row_orders(%d) holds %d orders, want %d" % (n, len(orders), max(2 * n - 1, 0)))
    for m in [s for s in SIZES if 0 < s <= n and (s <= 12 or s == n)]:
        for kind in gen_expected.ORDER_KINDS:
            perms = [gen_expected.permutation(m, o) for o in orders if o[0] == kind]
            if kind == "rotated":
                perms.append(list(range(m)))
            if any(sorted(p) != list(range(m)) for p in perms):
                FAILURES.append("row_orders(%d) %s: an order of %d rows is not a permutation" % (n, kind, m))
            for end, at in (("first", 0), ("last", -1)):
                seen = {p[at] for p in perms}
                if seen != set(range(m)):
                    FAILURES.append("row_orders(%d) %s: rows %s of a table of %d rows never arrive %s"
                                    % (n, kind, sorted(set(range(m)) - seen)[:5], m, end))
_SIZE = {name: t.num_rows for name, t in gen_expected.tables().items()}
for sql, n in [("SELECT g.id FROM groups AS g, bool_pairs AS b WHERE g.id = b.id", max(_SIZE["groups"], _SIZE["bool_pairs"])),
               ("SELECT count(*) AS n FROM nulls", _SIZE["nulls"]),
               ("WITH t AS (SELECT id FROM join_left) SELECT id FROM t", _SIZE["join_left"]),
               ("SELECT CAST(1 AS BIGINT) AS one", 0)]:
    if gen_expected.case_orders(base, sql) != gen_expected.row_orders(n):
        FAILURES.append("case_orders(%r) is not row_orders(%d)" % (sql, n))


# Columns are compared as Arrow arrays, a float by its bits (Arrow's
# equality takes NaN for unequal), so -0.0, NaN and every instant are
# compared without a conversion to Python.
def _column(table, i):
    col = table.column(i).combine_chunks()
    if pa.types.is_floating(col.type):
        col = col.view(pa.int64() if col.type.bit_width == 64 else pa.int32() if col.type.bit_width == 32 else pa.int16())
    return col


# connect(order) opens a connection in an order; register() reorders the
# one connection row_order_diffs() reuses, in turn.
reused = gen_expected.connect()
for order_at in [("rotated", 1), ("rotated", -1), ("reversed", 0), ("reversed", 2)]:
    fresh = gen_expected.connect(order_at)
    for name in sorted(gen_expected.tables()):
        rows = gen_expected.execute(base, 'SELECT * FROM "%s"' % name)
        m = rows.num_rows
        order = (order_at[0], order_at[1] % m)
        gen_expected.register(reused, order, {name})
        perm = gen_expected.permutation(m, order)
        if m >= 3 and perm == list(range(m)):
            FAILURES.append("%s %s: the order of %d rows is the as-built order" % (name, order, m))
        want = rows.take(pa.array(perm, type=pa.int64()))
        for how, con in (("connect", fresh), ("register", reused)):
            got = gen_expected.execute(con, 'SELECT * FROM "%s"' % name)
            if got.schema != want.schema or any(not _column(got, i).equals(_column(want, i))
                                                for i in range(got.num_columns)):
                FAILURES.append("%s %s by %s: the rows read back are not the as-built rows in that order"
                                % (name, order, how))
    fresh.close()
reused.close()

_H = "SELECT CAST(histogram(%s) AS VARCHAR) AS h FROM %s"
_BINS = ("histogram(id, CASE WHEN id < CAST(3 AS BIGINT) THEN [CAST(1 AS BIGINT), CAST(2 AS BIGINT)] "
         "ELSE [CAST(5 AS BIGINT)] END)")
_ZEROS = "FROM sort_rows WHERE f = CAST(0.0 AS DOUBLE)"

# 1. (query, refused by sql_discipline.check(), required missed by the
# plain reversal alone).
ORDER_DEPENDENT = [
    (_H % ("f64_special", "types"), True, False),
    ("SELECT id, count(*) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS c FROM groups", True, False),
    ("SELECT id, CAST(sum(v) OVER (PARTITION BY k ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS BIGINT) AS s "
     "FROM groups", True, False),
    ("SELECT id FROM groups LIMIT 1", True, False),
    ("SELECT DISTINCT ON (k) k, id FROM groups", True, False),
    ("SELECT CAST(%s AS VARCHAR) AS h FROM groups" % _BINS, True, False),
    # Ties sql_discipline.py does not see. groups' k = 1 holds ids 1 and 2.
    ("SELECT id FROM groups ORDER BY k ASC NULLS LAST LIMIT 1", False, False),
    ("SELECT min(f64) AS lo, max(f64) AS hi FROM types WHERE f64 = CAST(0.0 AS DOUBLE)", False, False),
    ("SELECT f64 FROM types WHERE f64 = CAST(0.0 AS DOUBLE) GROUP BY f64", False, False),
    # sort_rows' zeros arrive 0.0, -0.0, 0.0 as built and reversed alike.
    ("SELECT min(f) AS lo, max(f) AS hi " + _ZEROS, False, True),
    ("SELECT f " + _ZEROS + " GROUP BY f", False, True),
    ("SELECT DISTINCT f " + _ZEROS, False, True),
    ("SELECT f " + _ZEROS + " ORDER BY f ASC NULLS LAST LIMIT 1", False, True),
    ("SELECT median(f) AS m " + _ZEROS, False, True),
]
for sql, static, reversal_misses in ORDER_DEPENDENT:
    if not flagged(sql):
        FAILURES.append("row_order_diffs(%r) reports nothing under its %d orders"
                        % (sql, len(gen_expected.case_orders(base, sql))))
    if reversal_misses:
        diffs = flagged(sql, orders=REVERSAL)
        if diffs:
            FAILURES.append("row_order_diffs(%r) under the reversal alone: %s; the case no longer shows that the "
                            "check needs more than the reversal" % (sql, diffs[:2]))
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
    diffs = flagged(sql, order, keys)
    if bool(diffs) != want:
        FAILURES.append("row_order_diffs(%r) under order %s %s: %s, want %s"
                        % (sql, order, list(keys), diffs[:2] or "none", "reported" if want else "none"))

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
    "SELECT count(*) AS n, count(b1) AS nb, sum(v) AS s FROM nulls",
]
for sql in ORDER_FREE:
    diffs = flagged(sql)
    if diffs:
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


_TIED = "SELECT id, a FROM sort_rows ORDER BY a ASC NULLS LAST\n"
err, _ = run_main("-- order: total\n-- not null: id\n" + _TIED)
if err is None or "oracle/plant/case.sql" not in err or "depends on the order of the tables' rows" not in err:
    FAILURES.append("main() over an order: total case whose ORDER BY ties: %r, want a CaseError naming the case and "
                    "the row order" % err)
err, out = run_main("-- order: keys=a\n-- not null: id\n" + _TIED)
if err is not None or not os.path.exists(os.path.join(out, "expect", "plant", "case.tsv")):
    FAILURES.append("main() over the same case under order: keys=a: %r, want its file written" % err)

if FAILURES:
    for f in FAILURES:
        print("FAIL", f)
    raise SystemExit("test_row_order: %d failures" % len(FAILURES))
print("test_row_order: %d order-dependent, %d policy, %d order-free queries and main(), all as expected"
      % (len(ORDER_DEPENDENT), len(POLICY), len(ORDER_FREE)))

"""An ORACLE case's `-- order:` policy is held to its query's outermost ORDER BY, and under `total` that ORDER BY fixes the order.

    test_order_policy.py

sql_discipline.check_order_policy() and gen_expected.main() (its tie
check, gen_expected.order_ties()), in a process of its own:

1. Refused: under `order: total`, a query whose rows come out in an order
   no outermost ORDER BY asked for: a window's partition order
   (`row_number() OVER (PARTITION BY k ORDER BY id ...)` with no top-level
   ORDER BY), a subquery's ORDER BY under a SELECT that has none, a UNION
   ALL whose branches each have one and the union none; under
   `order: keys=<cols>`: the same subquery under `keys=id`, an ORDER BY
   that leads with another column, one with fewer keys than the policy,
   the keys in another order, a qualified key (`s.a`) and an expression
   (`a + 0`). Each refusal names the policy. Catches the `total` half off,
   a `keys` half that accepts any ORDER BY, compares the keys as a set or
   by their prefix only, or looks at an ORDER BY below the outermost
   query.
2. Accepted: under `total` an outermost ORDER BY over a table, a CTE, a
   UNION ALL and the window query above; under `keys` the subquery above
   ordered on the outside by id, `keys=a,b` led by a then b with a third
   key after them, and a CTE; under `none` a query with no ORDER BY at
   all. Catches a rule that refuses a kept policy (a `keys` rule that
   wants exactly the policy's keys, no more; a `total` rule that looks
   into the CTE or a branch rather than the outermost node).
3. main() holds every case to it: each of the three queries the review
   found accepted (the window under `total`, the subquery under `total`
   and under `keys=id`) is refused with a CaseError naming the case and
   the policy, before anything is written; the accepted window query and
   the subquery under `keys=id` with an outermost ORDER BY write their
   files. Catches main() not calling the check.
4. The tie check: main() refuses, with a CaseError naming the case and
   saying the ORDER BY does not fix the order, `total` cases whose
   outermost ORDER BY passes the rule above but ties rows that differ
   behind an inner sort, which the row-order check cannot see (the inner
   sort fixes the order rows reach the outer one in, whatever the tables'
   order): a constant key over a subquery ordered by id DESC, `ORDER BY
   a` over that subquery and over the same CTE (a = 3 ties ids 1, 4, 7),
   over a subquery ordered by id ASC (the ascending tiebreak's own order),
   the subquery's columns swapped so the tied rows differ in the second
   output column only,
   `ORDER BY k` over a window's rank() sort, a LIMIT tied at its cut,
   sort_rows' zeros differing only in sign under a constant key, and the
   same zeros under `ORDER BY id` with id not in the output (the
   documented over-refusal). It writes a second key that breaks the tie,
   tied rows that are the same row, a UNION ALL, neg_zero_ties_zero's
   expression key over -0.0 and 0.0 with id after it, a LIMIT with no tie
   at its cut, and the tied subquery under `keys=a` (a run of equal keys
   is a multiset). Catches the tie check off, run ascending or descending
   only, adding only the first output column, comparing the zero signs DuckDB rewrites in a sorted column,
   without its zero-sign rule, or applied under `keys=`.
"""

import os
import tempfile

import duckdb

import gen_expected
import oracle_case
import sql_discipline

FAILURES = []
con = duckdb.connect()

_WINDOW = ("SELECT id, k, CAST(row_number() OVER (PARTITION BY k ORDER BY id ASC NULLS LAST) AS BIGINT) AS rn "
           "FROM groups")
_SUB = "SELECT id FROM (SELECT id FROM groups ORDER BY id DESC NULLS LAST) AS t"
_ORD = " ORDER BY id ASC NULLS LAST"

# (query, order, keys)
REFUSED = [
    (_WINDOW, "total", ()),
    (_SUB, "total", ()),
    ("(SELECT id FROM groups ORDER BY id ASC NULLS LAST) UNION ALL (SELECT id FROM sort_rows ORDER BY id ASC NULLS LAST)",
     "total", ()),
    (_SUB, "keys", ("id",)),
    ("SELECT id, a FROM sort_rows ORDER BY id ASC NULLS LAST, a ASC NULLS LAST", "keys", ("a",)),
    ("SELECT id, a, b FROM sort_rows ORDER BY a ASC NULLS LAST", "keys", ("a", "b")),
    ("SELECT id, a, b FROM sort_rows ORDER BY b ASC NULLS LAST, a ASC NULLS LAST", "keys", ("a", "b")),
    ("SELECT s.a FROM sort_rows AS s ORDER BY s.a ASC NULLS LAST", "keys", ("a",)),
    ("SELECT a FROM sort_rows ORDER BY a + CAST(0 AS BIGINT) ASC NULLS LAST", "keys", ("a",)),
    ("SELECT a FROM sort_rows", "keys", ("a",)),
]
ACCEPTED = [
    ("SELECT id FROM groups" + _ORD, "total", ()),
    ("WITH t AS (SELECT id FROM groups) SELECT id FROM t ORDER BY id DESC NULLS LAST", "total", ()),
    ("SELECT id FROM groups UNION ALL SELECT id FROM sort_rows" + _ORD, "total", ()),
    (_WINDOW + _ORD, "total", ()),
    (_SUB + _ORD, "keys", ("id",)),
    ("SELECT id, a, b FROM sort_rows ORDER BY a ASC NULLS FIRST, b DESC NULLS LAST, id ASC NULLS LAST", "keys",
     ("a", "b")),
    ("WITH t AS (SELECT a FROM sort_rows ORDER BY a DESC NULLS LAST) SELECT a FROM t ORDER BY a ASC NULLS LAST",
     "keys", ("a",)),
    ("SELECT id FROM groups", "none", ()),
    (_SUB, "none", ()),
]

for sql, order, keys in REFUSED:
    try:
        sql_discipline.check_order_policy(con, sql, order, keys)
    except sql_discipline.DisciplineError as e:
        if ("order: %s" % order) not in str(e):
            FAILURES.append("refused %r under %s %s for %s, want a refusal naming the policy" % (sql, order, keys, e))
        continue
    FAILURES.append("accepted %r under order %s %s, want it refused" % (sql, order, list(keys)))
for sql, order, keys in ACCEPTED:
    try:
        sql_discipline.check_order_policy(con, sql, order, keys)
    except sql_discipline.DisciplineError as e:
        FAILURES.append("refused %r under order %s %s: %s" % (sql, order, list(keys), e))


def run_main(sql):
    """main() over a data directory holding `sql` as plant/case.sql: its
    CaseError text or None, and whether it wrote the file."""
    with tempfile.TemporaryDirectory() as data, tempfile.TemporaryDirectory() as out:
        os.makedirs(os.path.join(data, "plant"))
        with open(os.path.join(data, "plant", "case.sql"), "w", encoding="utf-8") as f:
            f.write(sql)
        try:
            gen_expected.main(out, data)
        except oracle_case.CaseError as e:
            err = str(e)
        else:
            err = None
        return err, os.path.exists(os.path.join(out, "expect", "plant", "case.tsv"))


for header, sql in [("-- order: total", _WINDOW), ("-- order: total", _SUB), ("-- order: keys=id", _SUB)]:
    err, wrote = run_main(header + "\n-- not null: id\n" + sql + "\n")
    if err is None or "oracle/plant/case.sql" not in err or header[3:] not in err:
        FAILURES.append("main() over %r: %r, want a CaseError naming the case and the policy" % (header + " " + sql, err))
    if wrote:
        FAILURES.append("main() over %r wrote its file" % (header + " " + sql))
for header, sql in [("-- order: total", _WINDOW + _ORD), ("-- order: keys=id", _SUB + _ORD)]:
    err, wrote = run_main(header + "\n-- not null: id\n" + sql + "\n")
    if err is not None or not wrote:
        FAILURES.append("main() over %r: %r, want its file written" % (header + " " + sql, err))

# 4. Under `total`, the outermost ORDER BY must fix the order of the rows:
# an inner sort fixes the order rows reach the outer one in, whatever the
# tables' order, so the row-order check cannot see a tie behind it.
_DESC = "(SELECT id, a FROM sort_rows ORDER BY id DESC NULLS LAST) AS t"
_ZEROS = "(SELECT id, f FROM sort_rows WHERE f = CAST(0.0 AS DOUBLE) ORDER BY id DESC NULLS LAST) AS t"
TIES_REFUSED = [
    # A constant key ties every row; the file would hold the subquery's order.
    "SELECT id, a FROM " + _DESC + " ORDER BY CAST(0 AS BIGINT) ASC NULLS LAST",
    # a = 3 ties ids 1, 4 and 7, and a NULL ids 2 and 5.
    "SELECT id, a FROM " + _DESC + " ORDER BY a ASC NULLS LAST",
    "WITH t AS (SELECT id, a FROM sort_rows ORDER BY id DESC NULLS LAST) SELECT id, a FROM t ORDER BY a ASC NULLS LAST",
    # The same over a subquery ordered by id ASC: the frozen order is the
    # ascending tiebreak's, so only the descending run sees the tie.
    "SELECT id, a FROM (SELECT id, a FROM sort_rows ORDER BY id ASC NULLS LAST) AS t ORDER BY a ASC NULLS LAST",
    # The same, the tied rows differing only in the second column.
    "SELECT a, id FROM " + _DESC + " ORDER BY a ASC NULLS LAST",
    # The window's sort fixes the rows' order; k ties ids.
    "SELECT id, k FROM (SELECT id, k, rank() OVER (PARTITION BY k ORDER BY id DESC NULLS LAST) AS r FROM groups) "
    "AS t ORDER BY k ASC NULLS LAST",
    # The tie at a LIMIT's cut: which a = 3 rows are kept.
    "SELECT id, a FROM " + _DESC + " ORDER BY a ASC NULLS LAST LIMIT CAST(3 AS BIGINT)",
    # 0.0, -0.0, 0.0: equal but for the sign of a zero, tied by every
    # sort. (Not `ORDER BY f`: DuckDB 1.5.6 then returns every zero as 0.0.)
    "SELECT f FROM " + _ZEROS + " ORDER BY CAST(0 AS BIGINT) ASC NULLS LAST",
    # Refused though id tells them apart: id is not in the output (the
    # documented over-refusal).
    "SELECT f FROM sort_rows WHERE f = CAST(0.0 AS DOUBLE) ORDER BY id ASC NULLS LAST",
]
TIES_ACCEPTED = [
    ("total", "SELECT id, a FROM " + _DESC + " ORDER BY a ASC NULLS LAST, id ASC NULLS LAST"),
    # The tied rows are the same row: no order to fix.
    ("total", "SELECT a FROM " + _DESC + " ORDER BY a ASC NULLS LAST"),
    ("total", "SELECT id FROM groups UNION ALL SELECT id FROM sort_rows ORDER BY id ASC NULLS LAST"),
    # An expression key (neg_zero_ties_zero's) over -0.0 and 0.0, id after it.
    ("total", "SELECT id, f FROM " + _ZEROS + " ORDER BY f + CAST(0.0 AS DOUBLE) ASC NULLS LAST, id ASC NULLS LAST"),
    ("total", "SELECT id, a FROM " + _DESC + " ORDER BY a DESC NULLS FIRST, id DESC NULLS LAST LIMIT CAST(4 AS BIGINT)"),
    # Under keys= a run of equal keys is a multiset: the frozen order
    # within it is not compared, so the same tie is written.
    ("keys=a", "SELECT id, a FROM " + _DESC + " ORDER BY a ASC NULLS LAST"),
]
for sql in TIES_REFUSED:
    err, wrote = run_main("-- order: total\n" + sql + "\n")
    if err is None or "oracle/plant/case.sql" not in err or "ORDER BY does not fix the order" not in err:
        FAILURES.append("main() over %r: %r, want a CaseError naming the case and saying the ORDER BY does not fix "
                        "the order" % (sql, err))
    if wrote:
        FAILURES.append("main() over %r wrote its file" % sql)
for order, sql in TIES_ACCEPTED:
    err, wrote = run_main("-- order: %s\n%s\n" % (order, sql))
    if err is not None or not wrote:
        FAILURES.append("main() over %r under order: %s: %r, want its file written" % (sql, order, err))

if FAILURES:
    for f in FAILURES:
        print("FAIL", f)
    raise SystemExit("test_order_policy: %d failures" % len(FAILURES))
print("test_order_policy: %d refused, %d accepted, main() refuses 3 and writes 2; %d ties refused, %d accepted, "
      "all as expected" % (len(REFUSED), len(ACCEPTED), len(TIES_REFUSED), len(TIES_ACCEPTED)))

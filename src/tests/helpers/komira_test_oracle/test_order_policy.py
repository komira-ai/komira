"""An ORACLE case's `-- order:` policy is held to its query's outermost ORDER BY, and every ORDER BY fixes the order the answer shows.

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
   without its zero-sign rule, or comparing a `keys=` case row for row.
5. Every ORDER BY, not only the outermost: main() refuses, under `total`
   and under `none`, queries whose answer depends on a tie an inner sort
   resolves (gen_expected.tie_sites()): row_number() over a tied key fed
   by a subquery ordered by id DESC, and fed by an unused rank() over id
   DESC; string_agg() and arg_max() whose own ORDER BY ties within a
   group; an inner LIMIT tied at its cut, and the same through stars
   with the tied rows differing only in the column the select list's
   length does not count; a window with a constant key over GROUP BY
   groups; a window over ROLLUP groups that only grouping() tells
   apart; two inner LIMITs whose ties show only when both turn the same
   way; a window function's own ORDER BY tied over that subquery,
   `row_number(ORDER BY k) OVER ()` (no arguments), `lag(k ORDER BY k)`
   (it reads the row before) and `lag(k, 1, id ORDER BY k)` (offset and
   default are not arguments). It writes each with a unique inner key,
   the rank family and a RANGE sum over a tied key (peers answer
   alike), ORDER BY ALL, and under `none` the tied subquery whose order
   is not compared. Catches the tie check on the outermost ORDER BY
   only, the window, ordered aggregate or inner LIMIT perturbation off,
   a window function's own ORDER BY given its arguments as keys (or
   none when it has none), a GROUP BY window keyed by the whole row
   (DuckDB refuses it) or with no keys, grouping() left out, the output
   width taken from a select list holding a star, the all-at-once runs
   left out, a tiebreak that splits the rank family's peers, ORDER BY ALL given keys (DuckDB then expands its star over the
   FROM), and a check comparing a `none` case row for row.
6. main() refuses a COLLATE query (sql_discipline.check) before writing
   it. Catches the COLLATE rule off.
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

# 5. Every ORDER BY, not only the outermost: an inner sort (a subquery's
# ORDER BY, a window's) fixes the order rows reach a window, an ordered
# aggregate or an inner LIMIT in, whatever the tables' order, so neither
# the row-order check nor a tiebreak on the outermost ORDER BY sees a tie
# there. Each query below is refused under `total` and under `none`.
_U = "(SELECT id, k FROM groups ORDER BY id DESC NULLS LAST) AS u"
_RN = "CAST(row_number() OVER (ORDER BY k ASC NULLS LAST%s) AS BIGINT) AS rn"
_BY_ID = " ORDER BY id ASC NULLS LAST"
_ALL = " ORDER BY ALL ASC NULLS LAST"
_TWO = ("SELECT CAST(x.id = CAST(2 AS BIGINT) AND y.id = CAST(2 AS BIGINT) AS BOOLEAN) AS both_second FROM "
        "(SELECT id FROM (SELECT id, k FROM groups WHERE k = CAST(1 AS BIGINT) ORDER BY id ASC NULLS LAST) AS u "
        "ORDER BY k ASC NULLS LAST LIMIT CAST(1 AS BIGINT)) AS x, "
        "(SELECT id FROM (SELECT id, k FROM groups WHERE k = CAST(1 AS BIGINT) ORDER BY id ASC NULLS LAST) AS u "
        "ORDER BY k ASC NULLS LAST LIMIT CAST(1 AS BIGINT)) AS y ORDER BY ALL ASC NULLS LAST")
# A window function's own ORDER BY over that subquery: row_number() has
# no arguments, lag() reads the row before, and lag's offset and default
# (id) are not among its arguments, so argument keys leave the tie.
_OWN = "SELECT id, k, w FROM (SELECT id, k, %s AS w FROM " + _U + ") AS q" + _BY_ID
_OWN_FUNCS = [
    "row_number(ORDER BY k ASC NULLS LAST%s) OVER ()",
    "lag(k ORDER BY k ASC NULLS LAST%s) OVER ()",
    "lag(k, CAST(1 AS BIGINT), id ORDER BY k ASC NULLS LAST%s) OVER ()",
]
_ROLLUP = ("SELECT k, v, CAST(count(*) AS BIGINT) AS n, "
           "CAST(row_number() OVER (ORDER BY k ASC NULLS LAST, v ASC NULLS LAST%s) AS BIGINT) AS rn "
           "FROM groups GROUP BY ROLLUP (k, v) ORDER BY ALL ASC NULLS LAST")
INNER_REFUSED = [
    # row_number() over k, ties by the order the subquery's id DESC fixes.
    "SELECT id, rn FROM (SELECT id, " + _RN % "" + " FROM " + _U + ") AS t" + _BY_ID,
    # The same with an unused rank() over id DESC fixing that order.
    "SELECT id, rn FROM (SELECT id, " + _RN % "" + " FROM (SELECT id, k, CAST(rank() OVER (ORDER BY id DESC NULLS "
    "LAST) AS BIGINT) AS r FROM groups) AS u) AS t" + _BY_ID,
    # An ordered aggregate whose ORDER BY ties within each group.
    "SELECT k, string_agg(CAST(id AS VARCHAR), CAST(',' AS VARCHAR) ORDER BY k ASC NULLS LAST) AS s FROM " + _U +
    " GROUP BY k ORDER BY k ASC NULLS LAST",
    # arg_max over equal values keeps the first row its ORDER BY reaches.
    "SELECT arg_max(id, CAST(0 AS BIGINT) ORDER BY k ASC NULLS LAST) AS m FROM " + _U + _ALL,
    # An inner LIMIT tied at its cut (k = 2 holds ids 5 and 6).
    "SELECT id FROM (SELECT id, k FROM " + _U + " ORDER BY k ASC NULLS LAST LIMIT CAST(3 AS BIGINT)) AS t" + _BY_ID,
    # The same through stars: the tied rows differ only in the second
    # column a star writes, which the select list's length does not count.
    "SELECT * FROM (SELECT * FROM (SELECT k, id FROM groups ORDER BY id DESC NULLS LAST) AS u ORDER BY k ASC "
    "NULLS LAST LIMIT CAST(3 AS BIGINT)) AS t" + _BY_ID,
    # A window over GROUP BY groups with a constant key: the order the
    # groups leave the aggregate in, which the subquery's order fixes.
    "SELECT k, CAST(row_number() OVER (ORDER BY CAST(0 AS BIGINT) ASC NULLS LAST) AS BIGINT) AS rn FROM " + _U +
    " GROUP BY k ORDER BY k ASC NULLS LAST",
    # Grouping sets: (2, NULL) is a group and a subtotal, (NULL, NULL) a
    # group, a subtotal and the total; only grouping() tells them apart.
    _ROLLUP % "",
    # Two inner LIMITs whose ties matter only together: each run that
    # turns one tiebreak around keeps the other's first row.
    _TWO,
] + [_OWN % (f % "") for f in _OWN_FUNCS]
INNER_ACCEPTED = [
    # The same with unique inner keys: the tiebreak changes nothing.
    "SELECT id, rn FROM (SELECT id, " + _RN % ", id ASC NULLS LAST" + " FROM " + _U + ") AS t" + _BY_ID,
    "SELECT id, rn FROM (SELECT id, " + _RN % ", id ASC NULLS LAST" + " FROM (SELECT id, k, CAST(rank() OVER (ORDER "
    "BY id DESC NULLS LAST) AS BIGINT) AS r FROM groups) AS u) AS t" + _BY_ID,
    "SELECT k, string_agg(CAST(id AS VARCHAR), CAST(',' AS VARCHAR) ORDER BY k ASC NULLS LAST, id ASC NULLS LAST) "
    "AS s FROM " + _U + " GROUP BY k ORDER BY k ASC NULLS LAST",
    "SELECT arg_max(id, CAST(0 AS BIGINT) ORDER BY k ASC NULLS LAST, id DESC NULLS LAST) AS m FROM " + _U + _ALL,
    "SELECT id FROM (SELECT id, k FROM " + _U + " ORDER BY k ASC NULLS LAST, id ASC NULLS LAST LIMIT "
    "CAST(3 AS BIGINT)) AS t" + _BY_ID,
    "SELECT * FROM (SELECT * FROM (SELECT k, id FROM groups ORDER BY id DESC NULLS LAST) AS u ORDER BY k ASC "
    "NULLS LAST, id ASC NULLS LAST LIMIT CAST(3 AS BIGINT)) AS t" + _BY_ID,
    "SELECT k, CAST(row_number() OVER (ORDER BY k ASC NULLS LAST) AS BIGINT) AS rn FROM " + _U + " GROUP BY k "
    "ORDER BY k ASC NULLS LAST",
    _ROLLUP % ", grouping(k, v) ASC NULLS LAST",
    # The rank family and a RANGE frame answer the same for every peer: a
    # tie in their ORDER BY is no tie in the answer, and is not split.
    "SELECT id, CAST(rank() OVER (ORDER BY k ASC NULLS LAST) AS BIGINT) AS r, CAST(sum(v) OVER (ORDER BY k ASC "
    "NULLS LAST) AS BIGINT) AS s FROM (SELECT id, k, v FROM groups ORDER BY id DESC NULLS LAST) AS u" + _BY_ID,
    # ORDER BY ALL orders by every output column (k, then id) already.
    "SELECT k, id FROM " + _U + " ORDER BY ALL ASC NULLS LAST",
    # The tied subquery under `none` with no LIMIT: the order is not
    # compared.
    "SELECT id, a FROM " + _DESC + " ORDER BY a ASC NULLS LAST",
] + [_OWN % (f % ", id ASC NULLS LAST") for f in _OWN_FUNCS]
for order in ("total", "none"):
    for sql in INNER_REFUSED:
        err, wrote = run_main("-- order: %s\n%s\n" % (order, sql))
        if err is None or "oracle/plant/case.sql" not in err or "ORDER BY does not fix the order" not in err:
            FAILURES.append("main() over %r under order: %s: %r, want a CaseError naming the case and saying the "
                            "ORDER BY does not fix the order" % (sql, order, err))
        if wrote:
            FAILURES.append("main() over %r under order: %s wrote its file" % (sql, order))
    for sql in INNER_ACCEPTED:
        if order == "total" and sql.endswith(" ORDER BY a ASC NULLS LAST"):
            continue
        err, wrote = run_main("-- order: %s\n%s\n" % (order, sql))
        if err is not None or not wrote:
            FAILURES.append("main() over %r under order: %s: %r, want its file written" % (sql, order, err))

# 6. A collation ties strings that differ, and the tiebreak keys sort
# under it: main() refuses the COLLATE (sql_discipline.check) before the
# tie check runs.
_NOCASE = ("SELECT s COLLATE nocase AS s FROM (VALUES (CAST('a' AS VARCHAR)), (CAST('A' AS VARCHAR)), "
           "(CAST('a' AS VARCHAR))) AS v(s) ORDER BY s ASC NULLS LAST")
err, wrote = run_main("-- order: total\n" + _NOCASE + "\n")
if err is None or "COLLATE nocase" not in err or wrote:
    FAILURES.append("main() over %r: %r (wrote %s), want a CaseError naming the COLLATE" % (_NOCASE, err, wrote))

if FAILURES:
    for f in FAILURES:
        print("FAIL", f)
    raise SystemExit("test_order_policy: %d failures" % len(FAILURES))
print("test_order_policy: %d refused, %d accepted, main() refuses 3 and writes 2; %d ties refused, %d accepted; "
      "%d inner ties refused and %d accepted under total and none; COLLATE refused; all as expected"
      % (len(REFUSED), len(ACCEPTED), len(TIES_REFUSED), len(TIES_ACCEPTED), len(INNER_REFUSED),
         len(INNER_ACCEPTED)))

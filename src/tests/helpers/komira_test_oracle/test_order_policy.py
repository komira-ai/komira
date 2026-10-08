"""An ORACLE case's `-- order:` policy is held to its query's outermost ORDER BY.

    test_order_policy.py

sql_discipline.check_order_policy() and gen_expected.main(), in a process
of its own:

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


written = os.path.join("expect", "plant", "case.tsv")
for header, sql in [("-- order: total", _WINDOW), ("-- order: total", _SUB), ("-- order: keys=id", _SUB)]:
    err, out = run_main(header + "\n-- not null: id\n" + sql + "\n")
    if err is None or "oracle/plant/case.sql" not in err or header[3:] not in err:
        FAILURES.append("main() over %r: %r, want a CaseError naming the case and the policy" % (header + " " + sql, err))
    if os.path.exists(os.path.join(out, written)):
        FAILURES.append("main() over %r wrote its file" % (header + " " + sql))
for header, sql in [("-- order: total", _WINDOW + _ORD), ("-- order: keys=id", _SUB + _ORD)]:
    err, out = run_main(header + "\n-- not null: id\n" + sql + "\n")
    if err is not None or not os.path.exists(os.path.join(out, written)):
        FAILURES.append("main() over %r: %r, want its file written" % (header + " " + sql, err))

if FAILURES:
    for f in FAILURES:
        print("FAIL", f)
    raise SystemExit("test_order_policy: %d failures" % len(FAILURES))
print("test_order_policy: %d refused, %d accepted, main() refuses 3 and writes 2, all as expected"
      % (len(REFUSED), len(ACCEPTED)))

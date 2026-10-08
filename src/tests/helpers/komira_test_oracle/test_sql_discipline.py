"""sql_discipline.py refuses each rule a query breaks, and only those.

Each refused query breaks one rule, and the test requires the refusal to
name the place DuckDB's parse keeps the offence (`.arg_orders[0]`,
`.sample`, `.limit.`...), so a check that refuses for some other reason
does not pass for it. Each ORDER BY and literal query is also accepted with
its rule kept, so a check that refuses everything near the offence is
caught too.
`json_serialize_sql` only parses: no table is created or read.

What it proves, and the defect it catches:

- ORDER BY: a key of the query, of a window's OVER clause and of a window
  function's own argument ordering (`first_value(x ORDER BY y) OVER ()`,
  `string_agg(x ORDER BY y) OVER ()`, which DuckDB keeps in `arg_orders`,
  not `orders`) must state ASC or DESC and NULLS FIRST or NULLS LAST.
  Catches a check that reads `orders` only.
- literals: an uncast literal is refused; a literal that is the LIMIT or
  OFFSET count is not; a literal inside a subquery computing the count is.
  Catches an exemption inherited by everything below the LIMIT.
- randomness and clocks: random(), now() and a sample (`USING SAMPLE`,
  `TABLESAMPLE`, at the SELECT and at the table reference) are refused.
  Catches a random rule that looks only at function calls.
- one SELECT: two statements and a DELETE are refused (the DELETE by
  `json_serialize_sql` itself, which serializes only SELECTs).
"""

import duckdb

import sql_discipline

FAILURES = []

# (query, a fragment the refusal must contain)
REFUSED = [
    # ORDER BY of the query.
    ("SELECT a FROM t ORDER BY a ASC", "orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    ("SELECT a FROM t ORDER BY a NULLS LAST", "orders[0]: an ORDER BY key without ASC or DESC"),
    # A window's OVER clause.
    ("SELECT row_number() OVER (ORDER BY a ASC) FROM t",
     "orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    # A window function's own ORDER BY: `arg_orders`.
    ("SELECT first_value(a ORDER BY b ASC) OVER (ORDER BY id ASC NULLS LAST) FROM t",
     "arg_orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    ("SELECT first_value(a ORDER BY b NULLS FIRST) OVER (ORDER BY id ASC NULLS LAST) FROM t",
     "arg_orders[0]: an ORDER BY key without ASC or DESC"),
    ("SELECT string_agg(s ORDER BY s DESC) OVER () FROM t",
     "arg_orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    # An aggregate's ORDER BY (an ORDER_MODIFIER under the function).
    ("SELECT string_agg(s ORDER BY s DESC) FROM t",
     "orders[0]: an ORDER BY key without NULLS FIRST or NULLS LAST"),
    # Literals.
    ("SELECT a FROM t WHERE a = 2", "where_clause.right: a literal that is not the operand of a CAST"),
    ("SELECT a FROM t LIMIT (SELECT 2)", ".limit."),
    ("SELECT a FROM t LIMIT CAST(2 AS BIGINT) OFFSET (SELECT 1)", ".offset."),
    # Clocks and randomness.
    ("SELECT random() FROM t", "random() depends on when the query runs"),
    ("SELECT now() FROM t", "now() depends on when the query runs"),
    ("SELECT a FROM t USING SAMPLE 10%", ".sample: USING SAMPLE or TABLESAMPLE"),
    ("SELECT a FROM t TABLESAMPLE 10%", ".sample: USING SAMPLE or TABLESAMPLE"),
    ("SELECT a FROM t USING SAMPLE reservoir(10%) REPEATABLE (7)", ".sample: USING SAMPLE or TABLESAMPLE"),
    # One SELECT.
    ("SELECT a FROM t; SELECT b FROM t", "2 statements, not one"),
    # DuckDB's serializer refuses it before check() reads a node type.
    ("DELETE FROM t", "Only SELECT statements can be serialized"),
]

# The ORDER BY and literal queries above, their rule kept.
ACCEPTED = [
    "SELECT a FROM t ORDER BY a ASC NULLS LAST",
    "SELECT row_number() OVER (ORDER BY a DESC NULLS FIRST) FROM t",
    "SELECT first_value(a ORDER BY b ASC NULLS LAST) OVER (ORDER BY id ASC NULLS LAST) FROM t",
    "SELECT string_agg(s ORDER BY s DESC NULLS FIRST) OVER () FROM t",
    "SELECT string_agg(s ORDER BY s DESC NULLS FIRST) FROM t",
    "SELECT a FROM t WHERE a = CAST(2 AS BIGINT)",
    "SELECT a FROM t ORDER BY a ASC NULLS LAST LIMIT 2 OFFSET 1",
    "SELECT a FROM t LIMIT (SELECT CAST(2 AS BIGINT))",
    "SELECT a FROM t",
]


def main():
    con = duckdb.connect()
    for sql in ACCEPTED:
        try:
            sql_discipline.check(con, sql)
        except sql_discipline.DisciplineError as e:
            FAILURES.append("refused %r: %s" % (sql, e))
    for sql, want in REFUSED:
        try:
            sql_discipline.check(con, sql)
        except sql_discipline.DisciplineError as e:
            if want not in str(e):
                FAILURES.append("refused %r for %s, want a refusal containing %r" % (sql, e, want))
            continue
        tree = con.execute("SELECT json_serialize_sql(CAST(? AS VARCHAR))", [sql]).fetchone()[0]
        FAILURES.append("accepted %r, want a refusal containing %r; DuckDB's parse:\n%s" % (sql, want, tree))
    if FAILURES:
        for f in FAILURES:
            print("FAIL", f)
        raise SystemExit("test_sql_discipline: %d failures" % len(FAILURES))
    print("test_sql_discipline: %d refused, %d accepted, all as expected" % (len(REFUSED), len(ACCEPTED)))


main()

# =============================================================================
# Direct tests of the DuckDB-style names the binder gives unaliased output
# columns (sql_bind_names._duckdb_expr_text)
# =============================================================================
#
# Each expression is parsed as `SELECT <expr> FROM t` and deparsed. The
# names are DuckDB v1.5.3's where it prints one (see the module's docstring
# for the three shapes that are not claimed byte-exact). What each test
# proves, and the defect (mutant) it would catch:
#   1. Leaves: a column keeps its qualifier, literals print as DuckDB's
#      CASTs (DATE quoted, TIMESTAMP and BOOLEAN not), NULL, a big integer's
#      digits.
#   2. Operators: each binary operator prints DuckDB's output token (`<>` as
#      `!=`, LIKE as `~~`, ILIKE as `~~*`), parenthesised; unary minus and
#      `@` print a prefix and the operand's parens.
#      (mutant: `_sxop_text` prints `<>`)
#   3. Calls: the CAST desugars print as CAST syntax, POSITION as DuckDB's
#      internal call, aggregates by their source token (`mean`, not `avg`),
#      `count(*)` as `count_star()`; a window prints `?column?`, a subquery
#      `(SELECT ...)`.

from std.testing import TestSuite, assert_equal

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_bind_names import _duckdb_expr_text


def _name(expr: String) raises -> String:
    var st = parse_sql(tokenize("SELECT " + expr + " FROM t"))
    return _duckdb_expr_text(st.query.select_items[0].expr)


def _n(expr: String, want: String) raises:
    assert_equal(_name(expr), want, expr)


def test_leaves() raises:
    _n("k", "k")
    _n("t.k", "t.k")
    _n("18446744073709551615", "18446744073709551615")
    _n("42", "42")
    _n("1.5", "1.5")
    _n("'x'", "'x'")
    _n("DATE '1995-03-15'", "CAST('1995-03-15' AS \"DATE\")")
    _n("TIMESTAMP '2021-01-01 00:00:00'", "CAST('2021-01-01 00:00:00' AS TIMESTAMP)")
    _n("TIMESTAMPTZ '2021-01-01 00:00:00+00'", "CAST('2021-01-01 00:00:00+00' AS \"TIMESTAMP WITH TIME ZONE\")")
    _n("NULL", "NULL")
    _n("true", "CAST('t' AS BOOLEAN)")
    _n("false", "CAST('f' AS BOOLEAN)")
    _n("*", "*")


def test_operators() raises:
    _n("k = 1", "(k = 1)")
    _n("k <> 1", "(k != 1)")
    _n("k < 1", "(k < 1)")
    _n("k <= 1", "(k <= 1)")
    _n("k > 1", "(k > 1)")
    _n("k >= 1", "(k >= 1)")
    _n("b AND b", "(b AND b)")
    _n("b OR b", "(b OR b)")
    _n("k + 1", "(k + 1)")
    _n("k - 1", "(k - 1)")
    _n("k * 2", "(k * 2)")
    _n("k / 2", "(k / 2)")
    _n("k // 2", "(k // 2)")
    _n("k % 2", "(k % 2)")
    _n("k ^ 2", "(k ^ 2)")
    _n("s || 'x'", "(s || 'x')")
    _n("s ^@ 'a'", "(s ^@ 'a')")
    _n("s LIKE 'x%'", "(s ~~ 'x%')")
    _n("s NOT LIKE 'x%'", "(s !~~ 'x%')")
    _n("s ILIKE 'x%'", "(s ~~* 'x%')")
    _n("s NOT ILIKE 'x%'", "(s !~~* 'x%')")
    _n("k IS NULL", "(k IS NULL)")
    _n("k IS NOT NULL", "(k IS NOT NULL)")
    _n("-k", "-(k)")
    _n("-(k + 1)", "-((k + 1))")
    _n("@k", "@(k)")
    _n("NOT b", "(NOT b)")


def test_calls_aggregates_and_fallbacks() raises:
    _n("abs(k)", "abs(k)")
    _n("concat(s, 'a', s)", "concat(s, 'a', s)")
    _n("CAST(v AS DOUBLE)", "CAST(v AS DOUBLE)")
    _n("TRY_CAST(k AS DOUBLE)", "TRY_CAST(k AS DOUBLE)")
    _n("k::BIGINT", "CAST(k AS BIGINT)")
    _n("position('b' IN s)", "main.\"position\"(s, 'b')")
    _n("sum(k)", "sum(k)")
    _n("count(*)", "count_star()")
    _n("count(DISTINCT k)", "count(DISTINCT k)")
    _n("mean(v)", "mean(v)")
    _n("MEAN(v)", "mean(v)")
    _n("median(v)", "median(v)")
    _n("CASE WHEN k > 1 THEN 1 ELSE 0 END", "CASE  WHEN ((k > 1)) THEN (1) ELSE 0 END")
    _n("CASE WHEN k > 1 THEN 1 END", "CASE  WHEN ((k > 1)) THEN (1) END")
    _n("(SELECT max(w) FROM u)", "(SELECT ...)")
    _n("rank() OVER (ORDER BY k)", "?column?")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# Direct tests of the DuckDB-style names the binder gives unaliased output
# columns (sql_bind_names._duckdb_expr_text)
# =============================================================================
#
# Each expression is parsed as `SELECT <expr> FROM t` and deparsed. The
# names are DuckDB v1.5.3's (v1.5.5's for windows) where it prints one (see
# the module docstrings for the shapes that are not claimed byte-exact). What
# each test proves:
#   1. Leaves: a column keeps its qualifier, literals print as DuckDB's
#      CASTs (DATE quoted, TIMESTAMP and BOOLEAN not), NULL, a big integer's
#      digits.
#   2. Operators: each binary operator prints DuckDB's output token (`<>` as
#      `!=`, LIKE as `~~`, ILIKE as `~~*`), parenthesised; unary minus and
#      `@` print a prefix and the operand's parens.
#   3. Calls: the CAST desugars print as CAST syntax, POSITION as DuckDB's
#      internal call, aggregates by their source token (`mean`, not `avg`),
#      `count(*)` as `count_star()`, a subquery `(SELECT ...)`.
#   4. Windows print as DuckDB v1.5.5 prints them: each function's name and
#      arguments (COUNT(*) as `count()`, LAG / LEAD's offset and DEFAULT of
#      each literal kind), PARTITION BY, ORDER BY with DESC and a written
#      NULLS placement, a frame unless it is the default RANGE one; inside an
#      expression too. The hidden column a nested window is computed under
#      spells every field: the default frame, an offset of 1, a string
#      DEFAULT by its bytes.

from std.testing import TestSuite, assert_equal

from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_bind_names import _duckdb_expr_text
from sql.sql_window_text import window_hidden_name


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


def test_windows_print_as_duckdb() raises:
    _n("rank() OVER (ORDER BY k)", "rank() OVER (ORDER BY k)")
    _n("row_number() OVER (PARTITION BY g ORDER BY k DESC)", "row_number() OVER (PARTITION BY g ORDER BY k DESC)")
    _n("dense_rank() OVER (PARTITION BY g)", "dense_rank() OVER (PARTITION BY g)")
    _n("percent_rank() OVER (ORDER BY k)", "percent_rank() OVER (ORDER BY k)")
    _n("cume_dist() OVER (ORDER BY k)", "cume_dist() OVER (ORDER BY k)")
    _n("ntile(3) OVER (ORDER BY k)", "ntile(3) OVER (ORDER BY k)")
    _n("sum(n) OVER (PARTITION BY g)", "sum(n) OVER (PARTITION BY g)")
    _n("count(*) OVER ()", "count() OVER ()")
    _n("count(k) OVER ()", "count(k) OVER ()")
    _n("avg(t.n) OVER (PARTITION BY t.g)", "avg(t.n) OVER (PARTITION BY t.g)")
    _n("mean(n) OVER ()", "avg(n) OVER ()")
    _n(
        "min(n) OVER (ORDER BY k ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)",
        "min(n) OVER (ORDER BY k ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)",
    )
    _n(
        "max(n) OVER (ORDER BY t.k ROWS 2 PRECEDING)",
        "max(n) OVER (ORDER BY t.k ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)",
    )
    _n(
        "sum(n) OVER (ORDER BY k RANGE BETWEEN 2 PRECEDING AND 1 FOLLOWING)",
        "sum(n) OVER (ORDER BY k RANGE BETWEEN 2 PRECEDING AND 1 FOLLOWING)",
    )
    _n(
        "sum(n) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)",
        "sum(n) OVER (ORDER BY k)",
    )
    _n(
        "sum(n) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)",
        "sum(n) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)",
    )
    _n(
        "sum(n) OVER (RANGE BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING)",
        "sum(n) OVER (RANGE BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING)",
    )
    _n(
        "sum(n) OVER (ORDER BY k RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)",
        "sum(n) OVER (ORDER BY k RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)",
    )
    _n("sum(n) OVER (ORDER BY k ASC)", "sum(n) OVER (ORDER BY k)")
    _n("sum(n) OVER (ORDER BY k DESC NULLS FIRST, g)", "sum(n) OVER (ORDER BY k DESC NULLS FIRST, g)")
    _n("sum(n) OVER (ORDER BY k NULLS LAST)", "sum(n) OVER (ORDER BY k NULLS LAST)")
    _n("lag(n) OVER (ORDER BY k)", "lag(n) OVER (ORDER BY k)")
    _n("lag(n, 1) OVER (ORDER BY k)", "lag(n) OVER (ORDER BY k)")
    _n("lead(n, -1) OVER (ORDER BY k)", "lead(n, -1) OVER (ORDER BY k)")
    _n("lag(n, 2, 0) OVER (ORDER BY k)", "lag(n, 2, 0) OVER (ORDER BY k)")
    _n("lag(n, 1, 2.5) OVER (ORDER BY k)", "lag(n, 1, 2.5) OVER (ORDER BY k)")
    _n("lead(s, 1, 'z') OVER (ORDER BY k)", "lead(s, 1, 'z') OVER (ORDER BY k)")
    _n(
        "lag(d, 1, DATE '2027-01-01') OVER (ORDER BY k)",
        "lag(d, 1, CAST('2027-01-01' AS \"DATE\")) OVER (ORDER BY k)",
    )
    _n(
        "first_value(n) OVER (PARTITION BY g, k ORDER BY k ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)",
        "first_value(n) OVER (PARTITION BY g, k ORDER BY k ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)",
    )
    _n("last_value(n) OVER (ORDER BY k)", "last_value(n) OVER (ORDER BY k)")
    _n("nth_value(n, 2) OVER (ORDER BY k)", "nth_value(n, 2) OVER (ORDER BY k)")
    _n(
        "n * 100.0 / sum(n) OVER (PARTITION BY g)",
        "((n * 100.0) / sum(n) OVER (PARTITION BY g))",
    )
    _n(
        "CASE WHEN sum(n) OVER (PARTITION BY g) > 10 THEN 1 ELSE 0 END",
        "CASE  WHEN ((sum(n) OVER (PARTITION BY g) > 10)) THEN (1) ELSE 0 END",
    )
    _n("abs(sum(n) OVER ())", "abs(sum(n) OVER ())")


def _hidden(expr: String) raises -> String:
    var st = parse_sql(tokenize("SELECT " + expr + " FROM t"))
    return window_hidden_name(st.query.select_items[0].expr)


def test_hidden_window_names_spell_every_field() raises:
    assert_equal(
        _hidden("sum(n) OVER (PARTITION BY g)"),
        "__window sum(n) OVER (PARTITION BY g)",
    )
    assert_equal(_hidden("lag(n) OVER (ORDER BY k)"), "__window lag(n, 1) OVER (ORDER BY k)")
    assert_equal(
        _hidden("lag(s, 1, 'Ab') OVER (ORDER BY k)"),
        "__window lag(s, 1, x'4162') OVER (ORDER BY k)",
    )
    assert_equal(
        _hidden("sum(n) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)"),
        "__window sum(n) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

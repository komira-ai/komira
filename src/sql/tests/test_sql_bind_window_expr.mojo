# =============================================================================
# Direct tests of window functions inside expressions and beside a star,
# through the statement binder (sql_binder.bind_statement)
# =============================================================================
#
# Every query binds against parquet tables registered with a given schema
# (`add_parquet` opens no file) and `NoParquetFooters`. The test compares the
# plan text, the result's column names, or the binder's message. What each
# test proves:
#   1. `n * 100.0 / sum(n) OVER (PARTITION BY g)` computes the window once,
#      under its hidden name, and the expression divides by that column; the
#      Project names only the SELECT list.
#   2. Two windows in one expression are two PARTITION BY nodes; one window
#      written twice, in one item or two, is one node.
#   3. A window binds nested in a CASE (condition, result and ELSE), in a
#      function's argument, under IS NULL and under LIKE.
#   4. An unaliased item holding a window is named as DuckDB names it.
#   5. `*` beside a window is the table's columns in order, then the window
#      column, or the window first when it is written first; `*` beside a
#      plain expression expands the same way.
#   6. `q.*` is the columns of the relation `q` names, under their own names,
#      beside a window, alone, and under a LIMIT; an unknown or ambiguous `q`
#      and the right side's key of a USING join are refused by name.
#   7. ORDER BY a window expression carries it as a hidden key pruned after
#      the sort; beside a window, ORDER BY an unselected column or an
#      expression is carried too, and an expression a SELECT item holds sorts
#      by that item, also when a `*` or `q.*` before the item expands to
#      several columns.
#   8. A window in WHERE, a join's ON, GROUP BY, HAVING, or an aggregate's
#      argument is refused with DuckDB's reason; a nested window beside GROUP
#      BY is refused as a window beside aggregation.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder

from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_catalog import SqlCatalog
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_binder import bind_statement


def _catalog() -> SqlCatalog:
    """t(k, g, n, v, s), u(k, h)."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("g"), ArrowType.STRING, True))
    t.add_field(Field(String("n"), ArrowType.INT64, True))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, False))
    u.add_field(Field(String("h"), ArrowType.STRING, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    return cat^


def _plan(sql: String) raises -> String:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    var plan = bound.take_plan()
    return String(plan)


def _names(sql: String) raises -> String:
    """The result's column names, joined by `|`."""
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    var plan = bound.take_plan()
    var out = String("")
    for i in range(plan.output_schema.num_columns()):
        if i > 0:
            out += "|"
        out += plan.output_schema.field_name(i)
    return out^


def _err(sql: String) raises -> String:
    var cat = _catalog()
    try:
        _ = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


def _count(text: String, needle: String) -> Int:
    return text.count(needle)


def test_percent_of_partition_total_reads_one_hidden_window() raises:
    assert_equal(
        _plan("SELECT k, n * 100.0 / sum(n) OVER (PARTITION BY g) AS pct FROM t"),
        "Project(exprs=[ColRef(k), Alias(BinaryOp(DIV, BinaryOp(MUL, ColRef(n), Literal(ScalarValue(float64, 100.0))), ColRef(__window sum(n) OVER (PARTITION BY g))), \"pct\")])\n"
        "  PartitionBy(partition=[g], order=[], funcs=[SUM(n, offset=0, frame=ROWS[0:0..4:0]) AS __window sum(n) OVER (PARTITION BY g)])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_two_windows_in_one_expression_and_one_window_written_twice() raises:
    var two = _plan(
        "SELECT max(n) OVER (PARTITION BY g) - min(n) OVER (PARTITION BY g) AS spread,"
        " n - max(n) OVER (PARTITION BY g) AS gap FROM t"
    )
    assert_equal(_count(two, "PartitionBy("), 2, two)
    assert_true(
        two.startswith(
            "Project(exprs=[Alias(BinaryOp(SUB, ColRef(__window max(n) OVER (PARTITION BY g)),"
            " ColRef(__window min(n) OVER (PARTITION BY g))), \"spread\"),"
            " Alias(BinaryOp(SUB, ColRef(n), ColRef(__window max(n) OVER (PARTITION BY g))), \"gap\")])\n"
        ),
        two,
    )
    var twice = _plan(
        "SELECT rank() OVER (ORDER BY k) * 2 + rank() OVER (ORDER BY k) AS r3 FROM t"
    )
    assert_equal(_count(twice, "PartitionBy("), 1, twice)


def test_window_nested_in_case_functions_and_predicates() raises:
    var case_ = _plan(
        "SELECT CASE WHEN row_number() OVER (PARTITION BY g ORDER BY k) = 1"
        " THEN n ELSE sum(n) OVER () - lag(n, 2, 0) OVER (ORDER BY k) END AS c,"
        " CASE WHEN k > 1 THEN count(*) OVER () END AS c2 FROM t"
    )
    assert_equal(_count(case_, "PartitionBy("), 4, case_)
    assert_true("AS __window row_number() OVER (PARTITION BY g ORDER BY k)]" in case_, case_)
    assert_true("AS __window lag(n, 2, 0) OVER (ORDER BY k)]" in case_, case_)
    assert_true("AS __window count() OVER ()]" in case_, case_)
    var fns = _plan(
        "SELECT abs(n - avg(n) OVER ()) AS dev,"
        " coalesce(lag(n) OVER (ORDER BY k), 0) AS prev,"
        " rank() OVER (ORDER BY k) IS NULL AS no_rank,"
        " lag(s) OVER (ORDER BY k) LIKE 'a%' AS lag_a FROM t"
    )
    assert_equal(_count(fns, "PartitionBy("), 4, fns)
    assert_true("AS __window lag(n, 1) OVER (ORDER BY k)]" in fns, fns)
    assert_true("AS __window lag(s, 1) OVER (ORDER BY k)]" in fns, fns)


def test_unaliased_window_expression_takes_duckdbs_name() raises:
    assert_equal(
        _names("SELECT k, n * 100.0 / sum(n) OVER (PARTITION BY g) FROM t"),
        "k|((n * 100.0) / sum(n) OVER (PARTITION BY g))",
    )
    assert_equal(
        _names("SELECT abs(sum(n) OVER ()) FROM t"),
        "abs(sum(n) OVER ())",
    )
    # An unaliased item with no window keeps the name a projection gives it.
    var plain = _plan("SELECT k + 1, rank() OVER (ORDER BY k) AS r FROM t")
    assert_true(
        plain.startswith(
            "Project(exprs=[BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), ColRef(r)])\n"
        ),
        plain,
    )


def test_star_beside_a_window_is_the_columns_then_the_window() raises:
    assert_equal(
        _names("SELECT *, sum(n) OVER (PARTITION BY g) AS tot FROM t"),
        "k|g|n|v|s|tot",
    )
    assert_equal(
        _names("SELECT sum(n) OVER (PARTITION BY g) AS tot, * FROM t"),
        "tot|k|g|n|v|s",
    )
    assert_equal(
        _names("SELECT *, n * 100.0 / sum(n) OVER (PARTITION BY g) AS pct FROM t"),
        "k|g|n|v|s|pct",
    )
    assert_equal(_names("SELECT *, k + 1 AS kp FROM t"), "k|g|n|v|s|kp")


def test_qualified_star_is_its_relations_columns() raises:
    assert_equal(
        _names("SELECT u.*, count(*) OVER (PARTITION BY t.g) AS cnt FROM t, u"),
        "k|h|cnt",
    )
    assert_equal(
        _names("SELECT x.k, T.*, rank() OVER (ORDER BY x.k) AS r FROM t, u AS x"),
        "k|k|g|n|v|s|r",
    )
    assert_equal(_names("SELECT t.* FROM t, u"), "k|g|n|v|s")
    assert_equal(_names("SELECT u.* FROM t, u LIMIT 2"), "k|h")
    assert_equal(_names("SELECT t.*, u.h FROM t JOIN u USING (k)"), "k|g|n|v|s|h")
    assert_equal(
        _err("SELECT x.* FROM t"),
        "SQL bind error: Referenced table \"x\" not found",
    )
    assert_equal(
        _err("SELECT z.*, rank() OVER (ORDER BY k) AS r FROM t AS z, u AS z"),
        "SQL bind error: Ambiguous reference to table \"z\" (duplicate alias"
        " \"z\", explicitly alias one of the tables using \"AS my_alias\")",
    )
    assert_equal(
        _err("SELECT u.* FROM t LEFT JOIN u USING (k)"),
        "SQL not supported: `u.*` over a NATURAL / USING join: its key `k` is"
        " the one coalesced column here, which holds the left side's value,"
        " and DuckDB gives `u.k` this relation's own value (NULL on a row it"
        " did not match). Name the columns, or join with ON.",
    )


def test_order_by_a_window_and_carries_beside_a_window() raises:
    assert_equal(
        _plan("SELECT k FROM t ORDER BY sum(n) OVER (PARTITION BY g) DESC, k"),
        "Project(exprs=[ColRef(k)])\n"
        "  Sort(keys=[__order_key_0 DESC, k ASC])\n"
        "    Project(exprs=[ColRef(k), Alias(ColRef(__window sum(n) OVER (PARTITION BY g)), \"__order_key_0\")])\n"
        "      PartitionBy(partition=[g], order=[], funcs=[SUM(n, offset=0, frame=ROWS[0:0..4:0]) AS __window sum(n) OVER (PARTITION BY g)])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )
    var by_col = _plan(
        "SELECT k, rank() OVER (ORDER BY k) AS r FROM t ORDER BY n, n, r"
    )
    assert_true(
        by_col.startswith(
            "Project(exprs=[ColRef(k), ColRef(r)])\n"
            "  Sort(keys=[n ASC, n ASC, r ASC])\n"
            "    Project(exprs=[ColRef(k), ColRef(r), ColRef(n)])\n"
        ),
        by_col,
    )
    var by_expr = _plan("SELECT k, rank() OVER (ORDER BY k) AS r FROM t ORDER BY -k")
    assert_true("Sort(keys=[__order_key_0 ASC])" in by_expr, by_expr)
    var by_item = _plan(
        "SELECT n - avg(n) OVER () AS d FROM t ORDER BY n - avg(n) OVER ()"
    )
    assert_true(by_item.startswith("Sort(keys=[d ASC])\n"), by_item)
    # After a star, an ORDER BY expression that a later item holds sorts by
    # that item's output column, past the columns the star expands to.
    var after_star = _plan("SELECT *, k + 1 AS kp FROM t ORDER BY k + 1")
    assert_true(after_star.startswith("Sort(keys=[kp ASC])\n"), after_star)
    var after_qstar = _plan(
        "SELECT u.*, n - avg(n) OVER () AS d FROM t, u ORDER BY n - avg(n) OVER ()"
    )
    assert_true("Sort(keys=[d ASC])" in after_qstar, after_qstar)
    assert_equal(
        _err("SELECT k, rank() OVER (ORDER BY k) AS r FROM t ORDER BY zz"),
        "SQL bind error: unknown ORDER BY column 'zz'",
    )


def test_windows_where_duckdb_refuses_them_are_refused_with_its_reason() raises:
    var where_ = String("SQL bind error: WHERE clause cannot contain window functions")
    assert_equal(_err("SELECT k FROM t WHERE rank() OVER (ORDER BY k) > 1"), where_)
    assert_equal(
        _err("SELECT t.k FROM t JOIN u ON t.k = u.k AND sum(n) OVER () > 1"), where_
    )
    assert_equal(
        _err("SELECT t.k FROM t LEFT JOIN u ON t.k = u.k AND sum(n) OVER () > 1"),
        where_,
    )
    assert_equal(
        _err("SELECT count(*) FROM t GROUP BY n - sum(n) OVER ()"),
        "SQL bind error: GROUP BY clause cannot contain window functions",
    )
    assert_equal(
        _err("SELECT g, count(*) FROM t GROUP BY g HAVING count(*) > rank() OVER (ORDER BY g)"),
        "SQL bind error: HAVING clause cannot contain window functions",
    )
    var wrapped = String(
        "SQL bind error: aggregate function calls cannot contain window function calls"
    )
    assert_equal(_err("SELECT sum(rank() OVER (ORDER BY k)) FROM t"), wrapped)
    assert_equal(_err("SELECT median(rank() OVER (ORDER BY k)) FROM t"), wrapped)
    assert_equal(_err("SELECT sum(rank() OVER (ORDER BY k)) + 1 FROM t"), wrapped)
    assert_equal(_err("SELECT k + 1 - sum(lag(n) OVER (ORDER BY k)) FROM t"), wrapped)
    assert_equal(_err("SELECT sum(rank() OVER (ORDER BY k)) IS NULL FROM t"), wrapped)
    assert_equal(_err("SELECT abs(max(lag(n) OVER (ORDER BY k))) FROM t"), wrapped)
    assert_equal(
        _err("SELECT CASE WHEN max(rank() OVER (ORDER BY k)) > 1 THEN 1 END FROM t"),
        wrapped,
    )
    assert_equal(
        _err("SELECT CASE WHEN k > 1 THEN min(rank() OVER (ORDER BY k)) END FROM t"),
        wrapped,
    )
    assert_equal(
        _err("SELECT CASE WHEN k > 1 THEN 1 ELSE max(rank() OVER (ORDER BY k)) END FROM t"),
        wrapped,
    )
    assert_equal(
        _err("SELECT *, k FROM t ORDER BY max(rank() OVER (ORDER BY k))"), wrapped
    )
    assert_equal(
        _err("SELECT k + rank() OVER (ORDER BY k) AS x, count(*) FROM t GROUP BY k"),
        "SQL not supported: a window function combined with GROUP BY /"
        " aggregation in the same SELECT",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

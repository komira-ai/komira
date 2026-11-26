# =============================================================================
# Direct tests of window functions in a SELECT that aggregates
# (sql_bind_window_group, through sql_binder.bind_statement)
# =============================================================================
#
# Every query binds against parquet tables registered with a given schema
# (`add_parquet` opens no file) and `NoParquetFooters`. A plan is checked by
# the lines it must hold, in the order the plan prints them (the root first).
#   1. A window ordered by `count(*)` runs over the groups: the aggregate
#      computes the SELECT items, the window's column and the computed key
#      under hidden names, the window orders by those names, and the SELECT
#      list is projected under its own names. A second window naming the same
#      column reads the same hidden column.
#   2. Each column a window names (its argument, a PARTITION BY and an ORDER
#      BY column, a qualified one apart from the bare one) is one hidden
#      column, and an aggregate PARTITION BY key is a computed key.
#   3. A column a window names must be a group key, with the SELECT item's
#      message.
#   4. GROUP BY ordinals and aliases name the SELECT items as written: an
#      ordinal or alias of a plain item groups by it, one of a window item is
#      refused, an ordinal out of range or past BIGINT is refused.
#   5. With no GROUP BY, an aggregate window key makes one group; a SELECT of
#      windows that name no column gets a count(*) so each group is a row,
#      with a GROUP BY and with only a HAVING.
#   6. Output names: an aliased item keeps its alias in the aggregate, so a
#      HAVING can name it, and a repeated alias falls back to a hidden name;
#      an unaliased column is named as the input spells it (a qualified one
#      by its column), an unaliased aggregate by DuckDB's text, a repeated
#      one with `_1`.
#   7. A statement-level ORDER BY sorts the projected output.
#   8. Refused by name: `*` beside a window (grouped or not) and a window
#      function used as a window's key.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder

from sql.sql_binder import bind_statement
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _catalog() -> SqlCatalog:
    """t(k BIGINT, v DOUBLE, s VARCHAR, g BIGINT)."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field(String("g"), ArrowType.INT64, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    return cat^


def _plan(sql: String) raises -> String:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    var plan = bound.take_plan()
    return String(plan)


def _err(sql: String) raises -> String:
    var cat = _catalog()
    try:
        _ = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


def _in_order(plan: String, parts: List[String]) raises:
    """Each of `parts` is in `plan`, each after the one before it."""
    var at = 0
    for i in range(len(parts)):
        var found = plan.find(parts[i], at)
        assert_true(found >= 0, "missing, in order: " + parts[i] + "\n" + plan)
        at = found + parts[i].byte_length()


def test_a_window_ordered_by_count_star_runs_over_the_groups() raises:
    var plan = _plan(
        "SELECT g, count(*) AS n, rank() OVER (ORDER BY count(*) DESC, g) AS rk,"
        " row_number() OVER (ORDER BY g) AS rn FROM t GROUP BY g"
    )
    _in_order(plan, [
        String("Project(exprs=[Alias(ColRef(__sel_0), \"g\"), ColRef(n), ColRef(rk), ColRef(rn)])"),
        String("PartitionBy(partition=[], order=[__wcol_0 ASC], funcs=[ROW_NUMBER("),
        String("PartitionBy(partition=[], order=[__window_key_0 DESC, __wcol_0 ASC], funcs=[RANK("),
        String("Alias(ColRef(g), \"__sel_0\")"),
        String("Alias(ColRef(g), \"__wcol_0\")"),
        String("Aggregate(group_by=[ColRef(g)], aggs=[COUNT(*).alias(\"n\"), COUNT(*).alias(\"__window_key_0\")])"),
        String("Scan(path=\"t.parquet\""),
    ])


def test_each_column_a_window_names_is_one_hidden_column() raises:
    # sum(k) and max(k) share `__wcol_0`; `s` is `__wcol_1`; the qualified
    # `t.k` is `__wcol_2`; `min(v)` is the computed key `__window_key_0`.
    var plan = _plan(
        "SELECT s, sum(k) OVER (PARTITION BY s ORDER BY t.k) AS sk,"
        " max(k) OVER (PARTITION BY min(v)) AS mk FROM t GROUP BY k, s"
    )
    _in_order(plan, [
        String("PartitionBy(partition=[__window_key_0], order=[], funcs=[MAX(__wcol_0, offset=0"),
        String("PartitionBy(partition=[__wcol_1], order=[__wcol_2 ASC], funcs=[SUM(__wcol_0, offset=0"),
        String("Alias(ColRef(k), \"__wcol_0\"), Alias(ColRef(s), \"__wcol_1\"), Alias(ColRef(k), \"__wcol_2\")"),
        String("Aggregate(group_by=[ColRef(k), ColRef(s)], aggs=[MIN(ColRef(v)).alias(\"__window_key_0\")])"),
    ])


def test_a_column_a_window_names_must_be_a_group_key() raises:
    assert_equal(
        _err("SELECT s, rank() OVER (ORDER BY v) AS r FROM t GROUP BY s"),
        "SQL bind error: SELECT column 'v' must appear in GROUP BY",
    )
    assert_equal(
        _err("SELECT s, rank() OVER (PARTITION BY g ORDER BY count(*)) AS r FROM t GROUP BY s"),
        "SQL bind error: SELECT column 'g' must appear in GROUP BY",
    )


def test_group_by_ordinals_and_aliases_name_the_items_as_written() raises:
    var by_ordinal = _plan(
        "SELECT rank() OVER (ORDER BY count(*)) AS r, s AS ss FROM t GROUP BY 2"
    )
    assert_true("Aggregate(group_by=[ColRef(s)]" in by_ordinal, by_ordinal)
    var by_alias = _plan(
        "SELECT rank() OVER (ORDER BY count(*)) AS r, s AS ss FROM t GROUP BY ss"
    )
    assert_true("Aggregate(group_by=[ColRef(s)]" in by_alias, by_alias)
    var window = String("SQL bind error: GROUP BY clause cannot contain window functions")
    assert_equal(
        _err("SELECT rank() OVER (ORDER BY count(*)) AS r, s FROM t GROUP BY 1"),
        window,
    )
    assert_equal(
        _err("SELECT rank() OVER (ORDER BY count(*)) AS r, s FROM t GROUP BY r"),
        window,
    )
    assert_equal(
        _err("SELECT rank() OVER (ORDER BY count(*)) AS r, s FROM t GROUP BY 3"),
        "SQL bind error: GROUP BY term out of range - should be between 1 and 2",
    )
    assert_equal(
        _err("SELECT rank() OVER (ORDER BY count(*)) AS r, s FROM t GROUP BY 0"),
        "SQL bind error: GROUP BY term out of range - should be between 1 and 2",
    )
    var big = _err(
        "SELECT rank() OVER (ORDER BY count(*)) AS r, s FROM t"
        " GROUP BY 99999999999999999999"
    )
    assert_true(
        big.startswith(
            "SQL bind error: the GROUP BY ordinal 99999999999999999999 is out"
            " of range for BIGINT"
        ),
        big,
    )


def test_an_aggregate_key_alone_makes_one_group() raises:
    var plan = _plan("SELECT rank() OVER (ORDER BY count(*)) AS r FROM t")
    _in_order(plan, [
        String("PartitionBy(partition=[], order=[__window_key_0 ASC], funcs=[RANK("),
        String("Aggregate(group_by=[], aggs=[COUNT(*).alias(\"__window_key_0\")])"),
    ])


def test_windows_that_name_no_column_still_get_one_row_per_group() raises:
    var grouped = _plan("SELECT row_number() OVER () AS rn FROM t GROUP BY s")
    _in_order(grouped, [
        String("PartitionBy(partition=[], order=[], funcs=[ROW_NUMBER("),
        String("Aggregate(group_by=[ColRef(s)], aggs=[COUNT(*).alias(\"__group_rows\")])"),
    ])
    var having = _plan(
        "SELECT row_number() OVER () AS rn FROM t HAVING count(*) > 1"
    )
    _in_order(having, [
        String("PartitionBy(partition=[], order=[], funcs=[ROW_NUMBER("),
        String("Filter(predicate="),
        String("Aggregate(group_by=[], aggs=[COUNT(*).alias(\"__group_rows\")"),
    ])


def test_output_names_follow_the_aggregate_binder() raises:
    var plan = _plan(
        "SELECT t.k, count(*), count(*), rank() OVER (ORDER BY k) AS r FROM t"
        " GROUP BY k"
    )
    _in_order(plan, [
        String("Alias(ColRef(__sel_0), \"k\"), Alias(ColRef(__sel_1), \"count_star()\"),"
        " Alias(ColRef(__sel_2), \"count_star()_1\"), ColRef(r)"),
        String("PartitionBy(partition=[], order=[__wcol_0 ASC], funcs=[RANK("),
    ])


def test_a_having_can_name_a_select_alias_beside_a_window() raises:
    var plan = _plan(
        "SELECT s, count(*) AS n, rank() OVER (ORDER BY count(*)) AS r FROM t"
        " GROUP BY s HAVING n > 1"
    )
    _in_order(plan, [
        String("Project(exprs=[Alias(ColRef(__sel_0), \"s\"), ColRef(n), ColRef(r)])"),
        String("PartitionBy(partition=[], order=[__window_key_0 ASC], funcs=[RANK("),
        String("Filter(predicate=BinaryOp(GT, ColRef(n)"),
        String("Aggregate(group_by=[ColRef(s)]"),
    ])
    # The first item of a repeated alias keeps it; the second is hidden and
    # aliased back above the windows.
    var twice = _plan(
        "SELECT s AS x, count(*) AS x, rank() OVER (ORDER BY s) AS r FROM t"
        " GROUP BY s"
    )
    assert_true(
        "Project(exprs=[ColRef(x), Alias(ColRef(__sel_1), \"x\"), ColRef(r)])" in twice,
        twice,
    )


def test_a_statement_order_by_sorts_the_projected_output() raises:
    var plan = _plan(
        "SELECT s, count(*) AS n, rank() OVER (ORDER BY count(*) DESC) AS r"
        " FROM t GROUP BY s ORDER BY r, s"
    )
    _in_order(plan, [
        String("Sort(keys=[r ASC, s ASC])"),
        String("Project(exprs=[Alias(ColRef(__sel_0), \"s\"), ColRef(n), ColRef(r)])"),
        String("PartitionBy(partition=[], order=[__window_key_0 DESC], funcs=[RANK("),
        String("Aggregate(group_by=[ColRef(s)]"),
    ])


def test_star_and_a_window_key_that_is_a_window_are_refused() raises:
    var star = String("SQL not supported: SELECT * alongside a window function")
    assert_equal(
        _err("SELECT *, rank() OVER (ORDER BY count(*)) AS r FROM t GROUP BY k"),
        star,
    )
    assert_equal(_err("SELECT *, rank() OVER (ORDER BY k) AS r FROM t"), star)
    assert_equal(
        _err(
            "SELECT s, rank() OVER (ORDER BY rank() OVER (ORDER BY s)) AS r"
            " FROM t GROUP BY s"
        ),
        "SQL not supported: a window function as a window's PARTITION BY or"
        " ORDER BY key",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

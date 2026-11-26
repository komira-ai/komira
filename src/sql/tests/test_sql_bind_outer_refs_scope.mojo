# =============================================================================
# A correlated subquery's qualified outer references (sql_bind_subquery)
# =============================================================================
#
# A qualified column in an EXISTS / IN / NOT IN body that the body's own
# relation does not answer is an outer reference, and it resolves in the FROM
# scope of the statement whose WHERE holds the subquery, as a select item
# there would (`BindScope.resolve_qualified`). Each check binds one statement
# against parquet tables registered with a given schema (no file is opened)
# and compares the plan's text, or the binder's error, with the exact
# expected string; the plan render prints the outer references as a count
# (`_corr`: `outer_refs=#N`). What each test proves:
#   1. A qualified outer reference in a subquery no WHERE holds (HAVING,
#      CASE) is refused by name. Otherwise the error would be an unknown column.
#   2. Nested subqueries: the outer scope is the immediately enclosing FROM;
#      a qualifier only a FROM two levels out answers to is unknown there.
#
# Kept apart from test_sql_bind_outer_refs.mojo:
# Mojo 1.2.0 does not finish compiling the two as one file, while each
# compiles in minutes.

from std.testing import TestSuite, assert_equal

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from plan_ir.logical_plan import LogicalPlan

from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_catalog import SqlCatalog
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_binder import bind_statement


def _two(
    mut cat: SqlCatalog,
    name: String,
    c0: String,
    t0: ArrowType,
    c1: String,
    t1: ArrowType,
):
    """Register parquet table `name`(c0 NOT NULL, c1 NULL)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, t0, False))
    sb.add_field(Field(c1, t1, True))
    cat.add_parquet(name, name + ".parquet", sb.build())


def _catalog() -> SqlCatalog:
    """t(k, v), u(k, w), kk(k, a), mm(k, b): parquet tables with given
    schemas (no file is opened)."""
    var cat = SqlCatalog()
    _two(cat, "t", "k", ArrowType.INT64, "v", ArrowType.FLOAT64)
    _two(cat, "u", "k", ArrowType.INT64, "w", ArrowType.INT64)
    _two(cat, "kk", "k", ArrowType.INT64, "a", ArrowType.INT64)
    _two(cat, "mm", "k", ArrowType.INT64, "b", ArrowType.INT64)
    return cat^


def _plan(sql: String) raises -> LogicalPlan:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    return bound.take_plan()


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    try:
        return String(_plan(sql))
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


comptime _T = "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _U = "Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"


def _corr(kind: Int, n: Int) -> String:
    return (
        "CorrelatedSubquery(kind=" + String(kind) + ", outer_refs=#" + String(n)
        + ", inner_tag=1)"
    )


def test_a_qualified_outer_reference_outside_a_where_is_refused() raises:
    var tail = String(
        "` in a subquery that is not an AND / OR / NOT / comparison operand of a WHERE clause"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING EXISTS (SELECT 1 FROM mm WHERE mm.k = t.k)",
        "ERR: SQL not supported: a qualified outer reference `t.k" + tail,
    )
    _check(
        "SELECT k FROM t WHERE CASE WHEN EXISTS (SELECT 1 FROM mm WHERE mm.k = t.k) THEN true ELSE false END",
        "ERR: SQL not supported: a qualified outer reference `t.k" + tail,
    )


def test_nested_subqueries_use_the_enclosing_from() raises:
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE EXISTS (SELECT 1 FROM mm WHERE mm.k = u.k))",
        "Project(exprs=[ColRef(k)])\n  Filter(predicate=" + _corr(0, 0) + ")\n    " + _T,
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE EXISTS (SELECT 1 FROM mm WHERE mm.k = t.k))",
        "ERR: SQL bind error: unknown column 't.k'",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

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
# expected string; the plan render prints the outer references as a count,
# so `_refs` reads their names from the bound Expr. What each test proves,
# and the defect (mutant) it would catch:
#   1. `u.k` over `FROM t, u` is the outer output column `k_right` (u's k),
#      for EXISTS, NOT EXISTS, IN and NOT IN, case-insensitively, and in a
#      derived table's body. (defect: the outer reference kept its bare
#      name `k`, which is t's k: a wrong result; mutant: the bare name
#      recorded instead of the resolved one)
#   2. An unknown, hidden (`t.k` over `FROM t AS x`) or ambiguous (`FROM t,
#      t`) outer qualifier is refused with the select-scope text. (defect:
#      all three bound silently)
#   3. The inner relation shadows the outer: a qualifier the inner relation
#      answers to with the column is inner; one it answers to without the
#      column is looked up outside (DuckDB binds a column in the innermost
#      scope where it resolves), and refused when the outer FROM does not
#      answer to it. (mutants: the inner-column test dropped; the
#      not-answered-outside refusal dropped)
#   4. A qualified outer reference in a subquery no WHERE holds (HAVING,
#      CASE) is refused by name. (mutant: the refusal dropped, which reports
#      an unknown column instead)
#   5. Nested subqueries: the outer scope is the immediately enclosing FROM;
#      a qualifier only a FROM two levels out answers to is unknown there.

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import (
    EXPR_BINARY_OP, EXPR_CORRELATED_SUBQUERY, EXPR_UNARY_OP, Expr,
)
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_FILTER, PLAN_PROJECT

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import NoParquetFooters
from komira_sql.sql_binder import bind_statement


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


def _expr_refs(e: Expr) -> String:
    """The outer-reference names of the first correlated subquery under `e`'s
    AND / OR / comparison and NOT nodes, joined by `,`; "<none>" when `e`
    holds no correlated subquery."""
    if e.tag == EXPR_CORRELATED_SUBQUERY:
        var r = e.corr_subq_outer_refs()
        var s = String("")
        for i in range(len(r)):
            if i > 0:
                s += ","
            s += r[i]
        return s^
    if e.tag == EXPR_BINARY_OP:
        var l = _expr_refs(e.binary_left_ref())
        if l != "<none>":
            return l^
        return _expr_refs(e.binary_right_ref())
    if e.tag == EXPR_UNARY_OP:
        return _expr_refs(e.unary_child_ref())
    return String("<none>")


def _plan_refs(p: LogicalPlan) -> String:
    """`_expr_refs` of the first Filter's predicate under a Project chain."""
    if p.tag == PLAN_FILTER:
        return _expr_refs(p.filter_data_ref().predicate)
    if p.tag == PLAN_PROJECT:
        return _plan_refs(p.project_data_ref().child[])
    return String("<no filter>")


def _refs(sql: String) raises -> String:
    return _plan_refs(_plan(sql))


comptime _T = "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _U = "Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"


def _tu() -> String:
    return String("Join(type=CROSS, on=[])\n      ") + _T + "      " + _U


def _corr(kind: Int, n: Int) -> String:
    return (
        "CorrelatedSubquery(kind=" + String(kind) + ", outer_refs=#" + String(n)
        + ", inner_tag=1)"
    )


def test_a_qualified_outer_reference_names_the_outer_relation() raises:
    var exists = String("SELECT t.k FROM t, u WHERE EXISTS (SELECT 1 FROM mm WHERE mm.k = u.k)")
    _check(
        exists,
        "Project(exprs=[ColRef(k)])\n  Filter(predicate=" + _corr(0, 1) + ")\n    " + _tu(),
    )
    assert_equal(_refs(exists), "k_right")
    assert_equal(
        _refs("SELECT t.k FROM t, u WHERE EXISTS (SELECT 1 FROM mm WHERE mm.k = U.K)"),
        "k_right",
    )
    var not_exists = String(
        "SELECT t.k FROM t, u WHERE NOT EXISTS (SELECT 1 FROM mm WHERE mm.k = u.k)"
    )
    _check(
        not_exists,
        "Project(exprs=[ColRef(k)])\n  Filter(predicate=" + _corr(1, 1) + ")\n    " + _tu(),
    )
    assert_equal(_refs(not_exists), "k_right")
    var in_sql = String("SELECT t.k FROM t, u WHERE w IN (SELECT b FROM mm WHERE mm.k = u.k)")
    _check(
        in_sql,
        "Project(exprs=[ColRef(k)])\n  Filter(predicate=" + _corr(0, 2) + ")\n    " + _tu(),
    )
    assert_equal(_refs(in_sql), "k_right,w")
    var not_in = String("SELECT t.k FROM t, u WHERE w NOT IN (SELECT b FROM mm WHERE mm.k = u.k)")
    _check(
        not_in,
        "Project(exprs=[ColRef(k)])\n  Filter(predicate=BinaryOp(AND, " + _corr(1, 2)
        + ", BinaryOp(AND, " + _corr(1, 1) + ", " + _corr(1, 2) + ")))\n    " + _tu(),
    )
    assert_equal(_refs(not_in), "k_right,w")
    # In a derived table's body: the scope is that body's FROM.
    var derived = String(
        "SELECT * FROM (SELECT t.k FROM t, u WHERE EXISTS (SELECT 1 FROM mm WHERE mm.k = u.k)) AS d"
    )
    _check(
        derived,
        "Project(exprs=[ColRef(k)])\n  Filter(predicate=" + _corr(0, 1) + ")\n    " + _tu(),
    )
    assert_equal(_refs(derived), "k_right")


def test_an_unknown_hidden_or_ambiguous_outer_qualifier_is_refused() raises:
    _check(
        "SELECT k FROM t AS x WHERE EXISTS (SELECT 1 FROM mm WHERE mm.k = t.k)",
        "ERR: SQL bind error: unknown column 't.k'",
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM mm WHERE mm.k = nosuch.k)",
        "ERR: SQL bind error: unknown column 'nosuch.k'",
    )
    _check(
        "SELECT 1 FROM t, t WHERE EXISTS (SELECT 1 FROM mm WHERE mm.k = t.k)",
        "ERR: SQL bind error: ambiguous reference to table `t`: more than one"
        " relation answers to `t` and has a column `k`. Give one of them a"
        " distinct alias (`AS my_alias`).",
    )


def test_the_inner_relation_shadows_the_outer() raises:
    var inner = String("SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u AS t WHERE t.k = 1)")
    _check(
        inner,
        "Project(exprs=[ColRef(k)])\n  Filter(predicate=" + _corr(0, 0) + ")\n    " + _T,
    )
    assert_equal(_refs(inner), "")
    var outer = String("SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u AS t WHERE t.v = 1.5)")
    _check(
        outer,
        "Project(exprs=[ColRef(k)])\n  Filter(predicate=" + _corr(0, 1) + ")\n    " + _T,
    )
    assert_equal(_refs(outer), "v")
    _check(
        "SELECT k FROM kk WHERE EXISTS (SELECT 1 FROM u AS t WHERE t.v = 1)",
        "ERR: SQL bind error: unknown column 'v' in correlated subquery",
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

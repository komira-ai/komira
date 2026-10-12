# =============================================================================
# Which FROM relation a qualifier names (sql_parser, sql_bind_scope,
# sql_bind_join, sql_bind_subquery, sql_binder)
# =============================================================================
#
# Each check binds one statement against parquet tables registered with a
# given schema (no file is opened) and compares the plan's text, or the
# binder's error, with the exact expected string. The plan render prints a
# correlated subquery's outer references as a count only, so `_refs` reads
# their names from the bound Expr. What each test proves, and the defect
# (mutant) it would catch:
#   1. Two derived tables aliased `d` at two SELECT levels are two relations:
#      the outer `d` reads the inner SELECT (with its `a + 1`), exactly as
#      when the inner one is aliased `e`.
#      (mutant: every aliased derived table keyed `<alias>#0`, which makes
#      the outer FROM read the innermost body)
#   2. A column qualified by a derived table's alias resolves in each
#      qualifier resolver: a select item (`BindScope`), the right side of a
#      SEMI JOIN's ON, both sides of a LEFT JOIN's ON, and the FROM of a
#      correlated EXISTS body, where `d.k` is an inner column (no outer
#      reference).
#      (mutants: the derived alias left out of the select scope, of the SEMI
#      right side's qualifiers, of the LEFT JOIN's alias sets, of the
#      correlated body's inner set; the last one turns `d.k` into an outer
#      reference to t.k)
#   3. An alias hides the table name, in every resolver: `mm.k` over
#      `FROM mm AS z, kk AS mm` is kk's k (`k_right`) in a select item, in a
#      JOIN ... ON folded into WHERE, in a LEFT JOIN ON and in a SEMI JOIN
#      ON (with and without a relation before the aliased one); `t.k` inside
#      `EXISTS (SELECT 1 FROM t AS x WHERE x.k = t.k)` is the OUTER t's k,
#      and so it is under NOT IN with a nullable y (the three-anti-join
#      lowering; mutants: the alias-and-name set at the NOT IN inner plan,
#      or at its equi-correlation check, each alone);
#      `t.k` over `FROM t AS x` is an unknown column; and a derived table
#      named like an aliased table's hidden name binds.
#      (defect: an aliased relation also answered to its table name, so the
#      first relation by name won: `mm.k` read mm's k, the join became
#      `k = k`, and the EXISTS lost its correlation)

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


comptime _INMEM = "Scan(path=\"__in_memory__\", type=IN_MEMORY, inmem_id=1605317327532927430, source_kind=COLUMNAR)\n"
comptime _T = "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _U = "Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _KK = "Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _MM = "Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _ONE_AS_A = "Project(exprs=[Alias(Literal(ScalarValue(int64, 1)), \"a\")])\n"


def test_same_alias_derived_tables_at_two_levels_are_two_relations() raises:
    var want = String(
        "Project(exprs=[Alias(BinaryOp(ADD, ColRef(a), Literal(ScalarValue(int64, 1))), \"a\")])\n"
        "  " + _ONE_AS_A + "    " + _INMEM
    )
    _check("SELECT * FROM (SELECT a + 1 AS a FROM (SELECT 1 AS a) AS d) AS d", want)
    _check("SELECT * FROM (SELECT a + 1 AS a FROM (SELECT 1 AS a) AS e) AS d", want)


def test_a_derived_alias_qualifies_a_select_item() raises:
    _check(
        "SELECT d.a FROM (SELECT 1 AS a) AS d",
        "Project(exprs=[ColRef(a)])\n  " + _ONE_AS_A + "    " + _INMEM,
    )


def test_a_derived_alias_qualifies_a_semi_join_right_side() raises:
    _check(
        "SELECT kk.a FROM kk SEMI JOIN (SELECT k FROM mm) AS d ON kk.k = d.k",
        "Project(exprs=[ColRef(a)])\n"
        "  Join(type=SEMI, on=[k=k])\n"
        "    " + _KK
        + "    Project(exprs=[ColRef(k)])\n"
        "      " + _MM,
    )


def test_a_derived_alias_qualifies_a_left_join_side() raises:
    _check(
        "SELECT * FROM kk LEFT JOIN (SELECT k FROM mm) AS d ON kk.k = d.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\")])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    " + _KK
        + "    Project(exprs=[ColRef(k)])\n"
        "      " + _MM,
    )
    _check(
        "SELECT * FROM (SELECT k FROM mm) AS d LEFT JOIN kk ON d.k = kk.k",
        "Project(exprs=[ColRef(k), Alias(ColRef(k_right), \"k\"), ColRef(a)])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Project(exprs=[ColRef(k)])\n"
        "      " + _MM
        + "    " + _KK,
    )


def test_a_derived_alias_in_a_correlated_body_is_inner() raises:
    var sql = String(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM (SELECT b AS k FROM mm) AS d WHERE d.k = 1)"
    )
    _check(
        sql,
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#0, inner_tag=1))\n"
        "    " + _T,
    )
    assert_equal(_refs(sql), "")


def test_an_alias_hides_the_table_name_in_a_select_item() raises:
    _check(
        "SELECT mm.k FROM mm AS z, kk AS mm",
        "Project(exprs=[Alias(ColRef(k_right), \"k\")])\n"
        "  Project(exprs=[ColRef(k_right)])\n"
        "    Join(type=CROSS, on=[])\n"
        "      " + _MM + "      " + _KK,
    )
    _check("SELECT t.k FROM t AS x", "ERR: SQL bind error: unknown column 't.k'")
    # A derived table named like the aliased table's hidden name.
    _check(
        "SELECT t.a, x.k FROM t AS x, (SELECT 1 AS a) AS t",
        "Project(exprs=[ColRef(a), ColRef(k)])\n"
        "  Join(type=CROSS, on=[])\n"
        "    " + _T + "    " + _ONE_AS_A + "      " + _INMEM,
    )


def test_an_alias_hides_the_table_name_in_a_join_on() raises:
    _check(
        "SELECT * FROM mm AS z JOIN kk AS mm ON mm.k = z.k",
        "Project(exprs=[ColRef(k), ColRef(b), Alias(ColRef(k_right), \"k\"), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(k_right), ColRef(k)))\n"
        "    Join(type=CROSS, on=[])\n"
        "      " + _MM + "      " + _KK,
    )
    _check(
        "SELECT * FROM mm AS z LEFT JOIN kk AS mm ON mm.k = z.k",
        "Project(exprs=[ColRef(k), ColRef(b), Alias(ColRef(k_right), \"k\"), ColRef(a)])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    " + _MM + "    " + _KK,
    )
    # The right relation's NAME is the left one's alias: `mm.k` is the left
    # (kk) side, since the right mm answers to `z` only.
    _check(
        "SELECT * FROM kk AS mm LEFT JOIN mm AS z ON mm.k = z.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    " + _KK + "    " + _MM,
    )


def test_an_alias_hides_the_table_name_in_a_semi_join_on() raises:
    _check(
        "SELECT * FROM mm AS z SEMI JOIN kk AS mm ON mm.k = z.k",
        "Join(type=SEMI, on=[k=k])\n"
        "  " + _MM + "  " + _KK,
    )
    # The aliased table after a cross-joined one: its qualifiers reach the
    # SEMI JOIN through the accumulated left set.
    _check(
        "SELECT * FROM u CROSS JOIN mm AS z SEMI JOIN kk AS mm ON mm.k = z.k",
        "Project(exprs=[ColRef(k), ColRef(w), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=SEMI, on=[k_right=k])\n"
        "    Join(type=CROSS, on=[])\n"
        "      " + _U + "      " + _MM
        + "    " + _KK,
    )


def test_an_alias_hides_the_table_name_in_a_correlated_body() raises:
    var sql = String("SELECT k FROM t WHERE EXISTS (SELECT 1 FROM t AS x WHERE x.k = t.k)")
    _check(
        sql,
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    " + _T,
    )
    assert_equal(_refs(sql), "k")
    # The same body under NOT IN, whose y (`v`) may hold NULLs: the
    # correlated lowering (three anti joins, `k` an outer reference) binds
    # the body through `_not_in_inner_plan` and checks its equi correlation
    # through `_body_has_equi_correlation`, each with this qualifier set.
    var not_in = String("SELECT k FROM t WHERE v NOT IN (SELECT v FROM t AS x WHERE x.k = t.k)")
    _check(
        not_in,
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#2, inner_tag=1),"
        " BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1),"
        " CorrelatedSubquery(kind=1, outer_refs=#2, inner_tag=1))))\n"
        "    " + _T,
    )
    assert_equal(_refs(not_in), "k,v")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

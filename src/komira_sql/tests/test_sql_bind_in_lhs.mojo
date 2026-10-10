# =============================================================================
# The left column of `x [NOT] IN (subquery)`: which relation it names, and
# the NOT IN null-freedom proof's owner match (sql_parser, sql_binder,
# sql_bind_subquery)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch. The plan
# render prints a correlated subquery's outer references as a count only,
# so `_refs` reads their names from the bound Expr.
#   1. A qualified left column binds through the FROM scope of the SELECT
#      whose WHERE holds the IN: over `FROM t, u`, `u.k` is the join output
#      `k_right` (t.k takes `k`). For NOT IN that is the membership equi's
#      outer reference and the run-time `x IS NOT NULL` check (u.k holds 5
#      NULLs, t.k none); for IN the outer reference. The IN is found on
#      either side of AND and under NOT, and in a derived table's or a
#      UNION ALL branch's WHERE.
#      (defect: the parser drops the qualifier and `u.k` binds as t.k;
#      mutants: each side of the AND search dropped, the NOT arm dropped,
#      the index compare made always-true, the body search's WHERE test
#      dropped)
#   2. A qualified left column that names no scope column is refused by
#      name (an unknown column, a SEMI-joined relation, an outer relation
#      from inside a correlated body); one outside a WHERE's AND / OR / NOT /
#      comparison operands (HAVING, CASE) is refused as such.
#   3. The NOT IN proof's owner match: case-insensitive (`k` against up's
#      `K` proves it; `k` against up's `K` and kk's `k` is ambiguous and
#      keeps the check), the owner mapped to its `from_tables` index past a
#      SEMI-joined relation the scope skips, and a column no relation owns
#      keeps the check.
#      (mutants: the match made exact; the owner taken as the scope index;
#      the `owner < 0` test moved to `owner < -1`)

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import (
    EXPR_BINARY_OP, EXPR_CORRELATED_SUBQUERY, EXPR_UNARY_OP, Expr,
)
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_FILTER, PLAN_PROJECT

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import SqlParquetFooters
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
    """t(k, v), u(k, w, s), kk(k, a), mm(k, b), up(K, B): parquet tables
    with given schemas (no file is opened)."""
    var cat = SqlCatalog()
    _two(cat, "t", "k", ArrowType.INT64, "v", ArrowType.FLOAT64)
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, False))
    u.add_field(Field(String("w"), ArrowType.INT64, True))
    u.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    _two(cat, "kk", "k", ArrowType.INT64, "a", ArrowType.INT64)
    _two(cat, "mm", "k", ArrowType.INT64, "b", ArrowType.INT64)
    _two(cat, "up", "K", ArrowType.INT64, "B", ArrowType.INT64)
    return cat^


@fieldwise_init
struct _FootersUk(SqlParquetFooters):
    """A footer reader whose only NULLs are 5 in `u.parquet`'s `k`; every
    other column of every path holds none."""

    def footer_schema(self, path: String) raises -> Schema:
        var sb = SchemaBuilder()
        sb.add_field(Field(String("k"), ArrowType.INT64, False))
        sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
        return sb.build()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        if path == "u.parquet" and column == "k":
            return 5
        return 0


def _plan(sql: String) raises -> LogicalPlan:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, _FootersUk())
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
    AND / OR / comparison and NOT / IS NULL nodes that has any, joined by
    `,`; "" when none has."""
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
        if l != "":
            return l^
        return _expr_refs(e.binary_right_ref())
    if e.tag == EXPR_UNARY_OP:
        return _expr_refs(e.unary_child_ref())
    return String("")


def _plan_refs(p: LogicalPlan) -> String:
    """`_expr_refs` of the first Filter's predicate under a Project chain."""
    if p.tag == PLAN_FILTER:
        return _expr_refs(p.filter_data_ref().predicate)
    if p.tag == PLAN_PROJECT:
        return _plan_refs(p.project_data_ref().child[])
    return String("")


def _refs(sql: String) raises -> String:
    return _plan_refs(_plan(sql))


comptime _TU = (
    "    Join(type=CROSS, on=[])\n"
    "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
)
comptime _CHECK_K_RIGHT = (
    "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k_right)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
)
comptime _OUTSIDE = "` of `IN (subquery)` that is not an AND / OR / NOT / comparison operand of a WHERE clause"


def test_not_in_qualified_lhs_binds_the_named_relation() raises:
    # u.k holds 5 NULLs and is `k_right`: the run-time check stays on
    # k_right. Before the fix `u.k` bound as t.k (no NULL) and the check went.
    _check(
        "SELECT k FROM t, u WHERE u.k NOT IN (SELECT b FROM mm)",
        "Project(exprs=[ColRef(k)])\n" + _CHECK_K_RIGHT + _TU,
    )
    assert_equal(_refs("SELECT k FROM t, u WHERE u.k NOT IN (SELECT b FROM mm)"), "k_right")
    # `t.k` is t's `k`: no NULL, so only the anti join remains.
    _check(
        "SELECT k FROM t, u WHERE t.k NOT IN (SELECT b FROM mm)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n" + _TU,
    )
    assert_equal(_refs("SELECT k FROM t, u WHERE t.k NOT IN (SELECT b FROM mm)"), "k")


def test_in_qualified_lhs_binds_the_named_relation() raises:
    # IN's plan text is the same for t.k and u.k; the outer reference
    # names the column the membership equi compares.
    _check(
        "SELECT k FROM t, u WHERE u.k IN (SELECT b FROM mm)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n" + _TU,
    )
    assert_equal(_refs("SELECT k FROM t, u WHERE u.k IN (SELECT b FROM mm)"), "k_right")
    assert_equal(_refs("SELECT k FROM t, u WHERE t.k IN (SELECT b FROM mm)"), "k")


def test_in_lhs_right_of_and() raises:
    assert_equal(_refs("SELECT k FROM t, u WHERE w > 0 AND u.k IN (SELECT b FROM mm)"), "k_right")


def test_in_lhs_left_of_and() raises:
    assert_equal(_refs("SELECT k FROM t, u WHERE u.k IN (SELECT b FROM mm) AND w > 0"), "k_right")


def test_in_lhs_under_not() raises:
    _check(
        "SELECT k FROM t, u WHERE NOT (u.k IN (SELECT b FROM mm))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=UnaryOp(NOT, CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1)))\n" + _TU,
    )
    assert_equal(_refs("SELECT k FROM t, u WHERE NOT (u.k IN (SELECT b FROM mm))"), "k_right")


def test_qualified_lhs_in_a_derived_table() raises:
    # The IN sits in a derived table's WHERE; the IN body's own WHERE
    # (`b > 0`) comes first in the subquery table and does not hold it.
    _check(
        "SELECT k FROM (SELECT k FROM t, u WHERE u.k NOT IN (SELECT b FROM mm WHERE b > 0)) AS d",
        "Project(exprs=[ColRef(k)])\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k_right)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_qualified_lhs_in_a_union_branch() raises:
    # The top statement's WHERE holds subquery 0; the branch's NOT IN is
    # subquery 1 and resolves against the branch's `FROM t, u`.
    _check(
        "SELECT k FROM t WHERE k IN (SELECT b FROM mm) UNION ALL SELECT k FROM t, u WHERE u.k NOT IN (SELECT b FROM mm)",
        "Union(branches=2)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k_right)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_qualified_lhs_refusals() raises:
    _check(
        "SELECT k FROM t, u WHERE u.zz IN (SELECT b FROM mm)",
        "ERR: SQL bind error: unknown column 'u.zz'",
    )
    # A SEMI-joined relation is not in the WHERE's scope.
    _check(
        "SELECT a FROM kk SEMI JOIN mm ON kk.k = mm.k WHERE mm.k IN (SELECT w FROM u)",
        "ERR: SQL bind error: unknown column 'mm.k'",
    )
    # Inside an EXISTS body the scope is the body's FROM (u).
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE t.k IN (SELECT b FROM mm))",
        "ERR: SQL bind error: unknown column 't.k'",
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING t.k NOT IN (SELECT k FROM u)",
        "ERR: SQL not supported: a qualified left column `t.k" + _OUTSIDE,
    )
    _check(
        "SELECT k FROM t, u WHERE CASE WHEN u.k IN (SELECT b FROM mm) THEN true ELSE false END",
        "ERR: SQL not supported: a qualified left column `u.k" + _OUTSIDE,
    )
    # A CTE body is bound before the subqueries and refuses the IN first.
    _check(
        "WITH c AS (SELECT k FROM t, u WHERE u.k IN (SELECT b FROM mm)) SELECT k FROM c",
        "ERR: SQL bind error: dangling scalar-subquery index",
    )


def test_not_in_proof_owner_case_insensitive() raises:
    # `k` matches up's `K` case-insensitively; up.parquet's K holds no NULL,
    # so the check goes. (mutant: exact match finds no owner, check stays)
    _check(
        "SELECT K FROM up WHERE k NOT IN (SELECT b FROM mm)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"up.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_not_in_proof_owner_ambiguous_by_case() raises:
    # `k` matches up's `K` and kk's `k`: ambiguous, the check stays.
    # (mutant: exact match proves kk.k alone and drops it)
    _check(
        "SELECT a FROM up, kk WHERE k NOT IN (SELECT b FROM mm)",
        "Project(exprs=[ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Scan(path=\"up.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


comptime _SEMI_PLAN = (
    "Project(exprs=[ColRef(a)])\n"
    "  Filter(predicate=BinaryOp(AND, BinaryOp(EQ, ColRef(k_right), ColRef(k)), BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k_right)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
    "    Join(type=CROSS, on=[])\n"
    "      Join(type=SEMI, on=[k=k])\n"
    "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
)


def test_not_in_proof_owner_past_a_semi_join() raises:
    # mm is SEMI-joined, so u is scope relation 1 but `from_tables[2]`.
    # `k_right` (and `u.k`) is u.k, 5 NULLs: the check stays. (mutant: the
    # owner taken as the scope index proves mm.k and drops it)
    _check(
        "SELECT a FROM kk SEMI JOIN mm ON kk.k = mm.k JOIN u ON u.k = kk.k WHERE k_right NOT IN (SELECT b FROM mm)",
        _SEMI_PLAN,
    )
    _check(
        "SELECT a FROM kk SEMI JOIN mm ON kk.k = mm.k JOIN u ON u.k = kk.k WHERE u.k NOT IN (SELECT b FROM mm)",
        _SEMI_PLAN,
    )


def test_not_in_proof_no_owner() raises:
    # No relation owns `zz`: the check stays. (mutant: `owner < 0` moved to
    # `owner < -1` indexes `from_tables[-1]`, out of bounds: the binary aborts)
    _check(
        "SELECT k FROM t WHERE zz NOT IN (SELECT b FROM mm)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(zz)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

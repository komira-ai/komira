# =============================================================================
# Two FROM relations that answer to one qualifier (sql_bind_scope,
# sql_bind_join, sql_parser)
# =============================================================================
#
# DuckDB v1.5.3 accepts two relations with the same qualifier in one FROM
# (`FROM mm AS z, kk AS z`, `FROM kk AS mm, mm`, `FROM t, t`) and binds a
# qualified column per reference (`BindContext::GetBinding`): over every
# relation answering to the qualifier, the one that has the column, and
# `Ambiguous reference to table` when more than one has it. Each check binds
# one statement against parquet tables registered with a given schema (no
# file is opened; `read_parquet` gets its schema from a fixed reader) and
# compares the plan's text, or the binder's error, with the exact expected
# string. What each test proves, and the defect (mutant) it would catch:
#   1-3. A select item or WHERE column qualified by a duplicate alias, by an
#      alias that is another table's name, or by a table listed twice:
#      refused when both relations have the column, bound to the one that
#      has it otherwise; `count(*)` over `FROM t, t` binds.
#      (defect: the first relation answering to the qualifier won, so
#      `z.k` read mm's k; mutants: the second-hit raise dropped or moved to
#      `hit_r > 0`)
#   4. The same per-column rule for every pairing of a base table, a CTE, a
#      `read_parquet` relation, a derived table and the synthetic
#      `unnamed_subquery` name (the parser no longer refuses a derived
#      table's qualifier that another relation answers to).
#   5. Inside a derived-table body and a scalar-subquery body.
#   6. A JOIN ... ON folded into WHERE.
#   7. A LEFT / FULL JOIN ON whose qualifier both sides answer to is decided
#      by the column, either operand order, refused when both sides have it,
#      unknown when neither does, with a residual on the right relation.
#      (mutants: `_classify_side` preferring the right side as before; its
#      `has_r and has_l` made `or`; either single-side arm dropped; the
#      left / right / ON scope slices moved by one)
#   8. An outer join's ON sees its two inputs only, so a relation joined
#      later with the same alias is not ambiguous there, and a column only
#      that later relation has is unknown. (mutants: the ON bound against
#      the whole FROM scope; the right slice one relation wider)
#   9. The same for a SEMI / ANTI JOIN ON, and a conjunct both sides have.
#   10. A one-sided SEMI conjunct whose qualifier two LEFT relations answer
#      to, both with the column, is refused, not filed on the right side.
#      (mutant: the left bind's ambiguity error swallowed with the rest)
#   11. A SEMI JOIN ON sees the relations before it only. (mutant: its left
#      side bound against the whole FROM scope)
#   12. `BindScope` called directly: `resolve_qualified` and
#      `source_name_of` refuse an ambiguous reference, `has_qualified`,
#      `answers_to`, and `slice` keeps exactly FROM positions lo..hi-1.
#      (mutants: each bound of `slice` moved by one and each side dropped;
#      `source_name_of` returning the first match)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import LogicalPlan

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import ParquetFacts, SqlParquetFooters
from komira_sql.sql_bind_scope import CteScope, _build_bind_scope
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
    """t(k, v), u(k, w), kk(k, a), mm(k, b), unnamed_subquery(k, z):
    parquet tables with given schemas (no file is opened)."""
    var cat = SqlCatalog()
    _two(cat, "t", "k", ArrowType.INT64, "v", ArrowType.FLOAT64)
    _two(cat, "u", "k", ArrowType.INT64, "w", ArrowType.INT64)
    _two(cat, "kk", "k", ArrowType.INT64, "a", ArrowType.INT64)
    _two(cat, "mm", "k", ArrowType.INT64, "b", ArrowType.INT64)
    _two(cat, "unnamed_subquery", "k", ArrowType.INT64, "z", ArrowType.INT64)
    return cat^


@fieldwise_init
struct _Footers(SqlParquetFooters):
    """Every `read_parquet` path has schema (k INT64, x INT64); no null
    count is known."""

    def footer_schema(self, path: String) raises -> Schema:
        var sb = SchemaBuilder()
        sb.add_field(Field(String("k"), ArrowType.INT64, False))
        sb.add_field(Field(String("x"), ArrowType.INT64, True))
        return sb.build()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        return None


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, _Footers())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


def _amb(q: String, col: String) -> String:
    return (
        "ERR: SQL bind error: ambiguous reference to table `" + q + "`: more"
        + " than one relation answers to `" + q + "` and has a column `" + col
        + "`. Give one of them a distinct alias (`AS my_alias`)."
    )


comptime _INMEM = "Scan(path=\"__in_memory__\", type=IN_MEMORY, inmem_id=1605317327532927430, source_kind=COLUMNAR)\n"
comptime _T = "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _U = "Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _KK = "Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _MM = "Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _CROSS = "Join(type=CROSS, on=[])\n"


def test_a_duplicate_alias_binds_per_column() raises:
    _check("SELECT z.k FROM mm AS z, kk AS z", _amb("z", "k"))
    _check(
        "SELECT z.b, z.a FROM mm AS z, kk AS z",
        "Project(exprs=[ColRef(b), ColRef(a)])\n  " + _CROSS + "    " + _MM + "    " + _KK,
    )
    _check("SELECT 1 FROM mm AS z, kk AS z WHERE z.k = 1", _amb("z", "k"))


def test_an_alias_that_is_another_tables_name_binds_per_column() raises:
    _check("SELECT mm.k FROM kk AS mm, mm", _amb("mm", "k"))
    _check(
        "SELECT mm.a, mm.b FROM kk AS mm, mm",
        "Project(exprs=[ColRef(a), ColRef(b)])\n  " + _CROSS + "    " + _KK + "    " + _MM,
    )


def test_the_same_table_twice() raises:
    _check("SELECT t.k FROM t, t", _amb("t", "k"))
    _check(
        "SELECT count(*) FROM t, t",
        "Project(exprs=[ColRef(count_star())])\n"
        "  Aggregate(group_by=[], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    " + _CROSS + "      " + _T + "      " + _T,
    )


def test_every_relation_kind_pairing() raises:
    # Base table and derived table.
    _check("SELECT t.k FROM t, (SELECT 1 AS k) AS t", _amb("t", "k"))
    _check(
        "SELECT t.v, t.a FROM t, (SELECT 1 AS a) AS t",
        "Project(exprs=[ColRef(v), ColRef(a)])\n  " + _CROSS + "    " + _T
        + "    Project(exprs=[Alias(Literal(ScalarValue(int64, 1)), \"a\")])\n      " + _INMEM,
    )
    # CTE and base table.
    _check("WITH c AS (SELECT k, a FROM kk) SELECT c.k FROM c, mm AS c", _amb("c", "k"))
    _check(
        "WITH c AS (SELECT k, a FROM kk) SELECT c.a, c.b FROM c, mm AS c",
        "Project(exprs=[ColRef(a), ColRef(b)])\n  " + _CROSS
        + "    Project(exprs=[ColRef(k), ColRef(a)])\n      " + _KK + "    " + _MM,
    )
    # read_parquet and base table.
    _check("SELECT z.k FROM read_parquet('p.parquet') AS z, mm AS z", _amb("z", "k"))
    _check(
        "SELECT z.x, z.b FROM read_parquet('p.parquet') AS z, mm AS z",
        "Project(exprs=[ColRef(x), ColRef(b)])\n  " + _CROSS
        + "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n    " + _MM,
    )
    # Two derived tables (the qualifier is case-insensitive).
    _check("SELECT d.a FROM (SELECT 1 AS a) AS d, (SELECT 2 AS a) AS d", _amb("d", "a"))
    _check(
        "SELECT d.a, d.b FROM (SELECT 1 AS a) AS d, (SELECT 2 AS b) AS D",
        "Project(exprs=[ColRef(a), ColRef(b)])\n  " + _CROSS
        + "    Project(exprs=[Alias(Literal(ScalarValue(int64, 1)), \"a\")])\n      " + _INMEM
        + "    Project(exprs=[Alias(Literal(ScalarValue(int64, 2)), \"b\")])\n      " + _INMEM,
    )
    # A table named like the synthetic name of an unaliased derived table:
    # `unnamed_subquery.z` is the table's, `.a` the subquery's (DuckDB v1.5.3
    # measured), `.k` both.
    _check(
        "SELECT unnamed_subquery.z, unnamed_subquery.a FROM (SELECT 1 AS a), unnamed_subquery",
        "Project(exprs=[ColRef(z), ColRef(a)])\n  " + _CROSS
        + "    Project(exprs=[Alias(Literal(ScalarValue(int64, 1)), \"a\")])\n      " + _INMEM
        + "    Scan(path=\"unnamed_subquery.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )
    _check(
        "SELECT unnamed_subquery.k FROM (SELECT 1 AS k), unnamed_subquery",
        _amb("unnamed_subquery", "k"),
    )


def test_inside_a_derived_table_and_a_scalar_subquery() raises:
    _check("SELECT * FROM (SELECT d.k FROM u AS d, (SELECT 5 AS k) AS d) AS x", _amb("d", "k"))
    _check("SELECT (SELECT max(d.k) FROM u AS d, (SELECT 5 AS k) AS d) FROM t", _amb("d", "k"))
    _check(
        "SELECT * FROM (SELECT d.w FROM u AS d, (SELECT 5 AS k) AS d) AS x",
        "Project(exprs=[ColRef(w)])\n  " + _CROSS + "    " + _U
        + "    Project(exprs=[Alias(Literal(ScalarValue(int64, 5)), \"k\")])\n      " + _INMEM,
    )


def test_an_inner_join_on() raises:
    _check("SELECT * FROM mm AS z JOIN kk AS z ON z.k = z.k", _amb("z", "k"))
    _check(
        "SELECT * FROM mm AS z JOIN kk AS z ON z.b = z.a",
        "Project(exprs=[ColRef(k), ColRef(b), Alias(ColRef(k_right), \"k\"), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(b), ColRef(a)))\n"
        "    " + _CROSS + "      " + _MM + "      " + _KK,
    )


def test_an_outer_join_on_is_decided_by_the_column() raises:
    var left_ba = String(
        "Project(exprs=[ColRef(b)])\n  Join(type=LEFT, on=[b=a])\n    " + _MM + "    " + _KK
    )
    _check("SELECT z.b FROM mm AS z LEFT JOIN kk AS z ON z.b = z.a", left_ba)
    _check("SELECT z.b FROM mm AS z LEFT JOIN kk AS z ON z.a = z.b", left_ba)


def test_a_full_join_on_is_decided_by_the_column() raises:
    _check(
        "SELECT z.a FROM mm AS z FULL JOIN kk AS z ON z.b = z.a",
        "Project(exprs=[ColRef(a)])\n  Join(type=FULL, on=[b=a])\n    " + _MM + "    " + _KK,
    )


def test_an_outer_join_on_refuses_a_column_both_sides_have() raises:
    _check("SELECT * FROM mm AS z LEFT JOIN kk AS z ON z.k = z.a", _amb("z", "k"))
    _check("SELECT * FROM mm AS z LEFT JOIN kk AS z ON z.a = z.k", _amb("z", "k"))
    _check("SELECT * FROM kk AS mm LEFT JOIN mm ON mm.k = mm.a", _amb("mm", "k"))


def test_an_outer_join_residual_binds_against_its_inputs() raises:
    # A residual on the right relation's column.
    _check(
        "SELECT z.b FROM mm AS z LEFT JOIN kk AS z ON z.b = z.a AND z.a > 1",
        "Project(exprs=[ColRef(b)])\n"
        "  Join(type=LEFT, on=[b=a], residual=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 1))))\n"
        "    " + _MM + "    " + _KK,
    )
    _check("SELECT * FROM mm AS z LEFT JOIN kk AS z ON z.b = z.a AND z.k > 1", _amb("z", "k"))
    _check(
        "SELECT * FROM mm AS z LEFT JOIN kk AS z ON z.b = z.a AND z.w > 1",
        "ERR: SQL bind error: unknown column 'z.w'",
    )


def test_an_outer_join_on_sees_its_two_inputs_only() raises:
    _check(
        "SELECT kk.a FROM mm AS z LEFT JOIN kk ON z.k = kk.k, u AS z",
        "Project(exprs=[ColRef(a)])\n  " + _CROSS
        + "    Join(type=LEFT, on=[k=k])\n      " + _MM + "      " + _KK
        + "    Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(w)])\n      " + _U,
    )
    _check(
        "SELECT * FROM mm AS z LEFT JOIN kk AS z ON z.b = z.w CROSS JOIN u AS z",
        "ERR: SQL bind error: unknown column 'z.w'",
    )


def test_a_semi_or_anti_join_on_is_decided_by_the_column() raises:
    var semi = String("Join(type=SEMI, on=[b=a])\n  " + _MM + "  " + _KK)
    _check("SELECT * FROM mm AS z SEMI JOIN kk AS z ON z.b = z.a", semi)
    _check("SELECT * FROM mm AS z SEMI JOIN kk AS z ON z.a = z.b", semi)
    _check(
        "SELECT * FROM mm AS z ANTI JOIN kk AS z ON z.b = z.a",
        "Join(type=ANTI, on=[b=a])\n  " + _MM + "  " + _KK,
    )
    _check("SELECT * FROM mm AS z SEMI JOIN kk AS z ON z.k = z.k", _amb("z", "k"))
    _check(
        "SELECT * FROM mm AS z SEMI JOIN kk AS z ON z.b = z.a AND z.k > 1",
        "ERR: SQL not supported: a SEMI JOIN ON conjunct is ambiguous — a column"
        " it reads, unqualified or qualified by a name both sides answer to,"
        " exists on BOTH sides. Qualify it with the table name or a distinct"
        " alias of the side it belongs to.",
    )


def test_a_semi_join_left_ambiguity_is_not_filed_on_the_right() raises:
    _check(
        "SELECT * FROM kk AS z, mm AS z SEMI JOIN u AS z ON z.w = z.a AND z.k > 1",
        _amb("z", "k"),
    )


def test_a_semi_join_on_sees_the_relations_before_it_only() raises:
    _check(
        "SELECT * FROM mm AS z SEMI JOIN kk ON z.k = kk.k CROSS JOIN u AS z",
        "Project(exprs=[ColRef(k), ColRef(b), Alias(ColRef(k_right), \"k\"), ColRef(w)])\n  "
        + _CROSS + "    Join(type=SEMI, on=[k=k])\n      " + _MM + "      " + _KK
        + "    " + _U,
    )


def test_bind_scope_helpers() raises:
    var cat = _catalog()
    var cte = CteScope(ParquetFacts())
    var st = parse_sql(tokenize("SELECT 1 FROM mm AS z, kk AS z, u"))
    var scope = _build_bind_scope(st.query.from_tables, st.query.joins, cat, cte)
    var msg = String("")
    try:
        _ = scope.source_name_of("Z", "K")
    except e:
        msg = String(e)
    assert_equal("ERR: " + msg, _amb("z", "k"))
    msg = String("")
    try:
        _ = scope.resolve_qualified("z", "k")
    except e:
        msg = String(e)
    assert_equal("ERR: " + msg, _amb("z", "k"))
    assert_equal(scope.source_name_of("z", "A"), "a")
    assert_equal(scope.resolve_qualified("z", "a"), "a")
    assert_equal(scope.resolve_qualified("u", "k"), "k_right_2")
    assert_true(scope.has_qualified("Z", "b"))
    assert_false(scope.has_qualified("z", "w"))
    assert_true(scope.answers_to("U"))
    assert_false(scope.answers_to("kk"))
    # slice(lo, hi) keeps FROM positions lo..hi-1: here the second z only.
    var mid = scope.slice(1, 2)
    assert_equal(mid.resolve_qualified("z", "k"), "k_right")
    assert_false(mid.answers_to("u"))
    assert_false(mid.has_qualified("z", "b"))
    var head = scope.slice(0, 1)
    assert_equal(head.resolve_qualified("z", "k"), "k")
    assert_false(head.has_qualified("z", "a"))
    assert_true(scope.slice(2, 3).answers_to("u"))
    assert_false(scope.slice(2, 2).answers_to("u"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# Direct tests of subquery binding: the NOT IN null-freedom proof
# (sql_bind_subquery, sql_binder)
# =============================================================================
#
# What each test proves:
#   1. The NOT IN null-freedom proof (with footer readers giving null
#      counts) keeps the run-time `x IS NOT NULL` check when x is a
#      join-renamed output column whose source holds NULLs, under a LEFT,
#      RIGHT or FULL join, in a UNION ALL branch, and when a CTE or derived
#      table shadows a catalog parquet table's name; it drops the check when
#      the renamed column's source holds none.
#
# Kept apart from test_sql_bind_subquery.mojo:
# Mojo 1.2.0 does not finish compiling the two as one file, while each
# compiles in minutes.

from std.testing import TestSuite, assert_equal

from arrow.arrow_types import ArrowType
from arrow.record_batch import RecordBatch
from arrow.schema import Field, Schema, SchemaBuilder

from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_catalog import SqlCatalog
from scan_source.parquet_source import ParquetSource
from sql.sql_bind_parquet import NoParquetFooters, SqlParquetFooters
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


def _catalog() raises -> SqlCatalog:
    """t(k, v, s, g, d, ts, i32, dc, b, f32, u64, j), u(k, w, s), kk(k, a),
    mm(k, b), up(K, B), kk2(k, k_right): parquet tables with given schemas
    (no file is opened); mem(k, v): an empty in-memory table."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field(String("g"), ArrowType.INT64, True))
    t.add_field(Field(String("d"), ArrowType.DATE32, True))
    t.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String(""), True))
    t.add_field(Field(String("i32"), ArrowType.INT32, True))
    t.add_field(Field.decimal128(String("dc"), 12, 2, True))
    t.add_field(Field(String("b"), ArrowType.BOOL, True))
    t.add_field(Field(String("f32"), ArrowType.FLOAT32, True))
    t.add_field(Field(String("u64"), ArrowType.UINT64, True))
    t.add_field(Field(String("j"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, False))
    u.add_field(Field(String("w"), ArrowType.INT64, True))
    u.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    _two(cat, "kk", "k", ArrowType.INT64, "a", ArrowType.INT64)
    _two(cat, "mm", "k", ArrowType.INT64, "b", ArrowType.INT64)
    _two(cat, "up", "K", ArrowType.INT64, "B", ArrowType.INT64)
    _two(cat, "kk2", "k", ArrowType.INT64, "k_right", ArrowType.INT64)
    cat.add_in_memory(String("mem"), RecordBatch.empty_from_schema(_kv()))
    return cat^


def _kv() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    return sb.build()


@fieldwise_init
struct _Footers(SqlParquetFooters):
    """A footer reader with fixed answers: every path but `missing.parquet`
    has schema (k INT64, v FLOAT64); `k` holds no NULL and `v` holds 3; a
    path named `bad.parquet` raises for null counts."""

    def footer_schema(self, path: String) raises -> Schema:
        if path == "missing.parquet":
            raise Error("no such file: " + path)
        return _kv()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        if path == "bad.parquet":
            raise Error("unreadable statistics")
        if column == "k":
            return 0
        if column == "v":
            return 3
        return None

    def parquet_relation(
        self, path: String, hive_partitioning: UInt8
    ) raises -> ParquetSource:
        return ParquetSource(String(path), self.footer_schema(path), None)


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _gotp(sql: String) raises -> String:
    """`_got` with the `_Footers` reader."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, _Footers())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


def _checkp(sql: String, want: String) raises:
    assert_equal(_gotp(sql), want, sql)


@fieldwise_init
struct _FootersUk(SqlParquetFooters):
    """A footer reader whose only NULLs are 5 in `u.parquet`'s `k`; every
    other column of every path holds none. Schemas as `_Footers`."""

    def footer_schema(self, path: String) raises -> Schema:
        return _kv()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        if path == "u.parquet" and column == "k":
            return 5
        return 0

    def parquet_relation(
        self, path: String, hive_partitioning: UInt8
    ) raises -> ParquetSource:
        return ParquetSource(String(path), self.footer_schema(path), None)


def _checku(sql: String, want: String) raises:
    """`_check` with the `_FootersUk` reader."""
    var cat = _catalog()
    var got: String
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, _FootersUk())
        got = String(bound.take_plan())
    except e:
        got = String("ERR: ") + String(e)
    assert_equal(got, want, sql)


def test_not_in_null_freedom_proof_edges() raises:
    # The NOT IN proof needs the NOT IN in the statement's own WHERE, no outer
    # join, and one relation owning the column; a column no relation has is
    # refused when the query binds.
    _check(
        "SELECT k FROM t GROUP BY k HAVING k NOT IN (SELECT k FROM u)",
        "ERR: SQL not supported: an EXISTS or IN subquery in a HAVING clause or in the"
        " SELECT list of a grouped query (a scalar subquery is served there; a"
        " predicate subquery is served as a WHERE conjunct)"
    )
    _check(
        "SELECT kk.k FROM kk LEFT JOIN mm ON kk.k = mm.k WHERE kk.k NOT IN (SELECT k FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Join(type=LEFT, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE zz NOT IN (SELECT k FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(zz)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM mem)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM missing_table)",
        "ERR: SQL bind error: unknown table 'missing_table'"
    )
    _checkp(
        "SELECT v FROM read_parquet('p.parquet') AS o WHERE v NOT IN (SELECT k FROM read_parquet('q.parquet') AS i WHERE i.v = o.v)",
        "Project(exprs=[ColRef(v)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1)))\n"
        "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT k FROM read_parquet('p.parquet') AS o WHERE k NOT IN (SELECT v FROM read_parquet('q.parquet') AS i WHERE i.k = o.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1)))\n"
        "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT k FROM read_parquet('p.parquet') AS o WHERE k NOT IN (SELECT k FROM read_parquet('q.parquet') AS i WHERE i.v = o.v)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#2, inner_tag=1))\n"
        "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT k FROM read_parquet('p.parquet'), read_parquet('q.parquet') WHERE k NOT IN (SELECT k FROM read_parquet('r.parquet'))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"q.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT k FROM read_parquet('p.parquet') WHERE k NOT IN (SELECT zz FROM read_parquet('q.parquet'))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0)))))\n"
        "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_not_in_lhs_owner_is_the_scope_output_column() raises:
    # In `FROM t, u, kk2` the outer WHERE's `k_right` is u.k (t.k takes `k`),
    # and kk2.k is renamed `k_right_2`. The proof follows the output name to
    # its relation and source column: u.k holds 5 NULLs here, so the run-time
    # `x IS NOT NULL` check stays. The owner is found through the
    # output name, not the raw schema name (kk2 has its own `k_right`).
    _checku(
        "SELECT k FROM t, u, kk2 WHERE k_right NOT IN (SELECT b FROM mm)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k_right)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(k_right)])\n"
        "        Scan(path=\"kk2.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    # The same FROM, an output name whose source column holds no NULL: kk2.k
    # behind `k_right_2`, t.k behind `k`. Both checks go.
    _checku(
        "SELECT k FROM t, u, kk2 WHERE k_right_2 NOT IN (SELECT b FROM mm)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(k_right)])\n"
        "        Scan(path=\"kk2.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checku(
        "SELECT k FROM t, u, kk2 WHERE k NOT IN (SELECT b FROM mm)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(k_right)])\n"
        "        Scan(path=\"kk2.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_not_in_proof_ambiguous_or_unbound_lhs() raises:
    # NATURAL JOIN coalesces kk.k and mm.k onto one output `k`: two relations
    # own it, so the proof gives up and the check stays. An unknown outer
    # table makes the scope raise inside the proof, which answers False; the
    # binding then refuses the table by name.
    _checkp(
        "SELECT k FROM kk NATURAL JOIN mm WHERE k NOT IN (SELECT k FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Project(exprs=[ColRef(k), ColRef(a), ColRef(b)])\n"
        "      Join(type=INNER, on=[k=k])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT k FROM nope WHERE k NOT IN (SELECT k FROM u)",
        "ERR: SQL bind error: unknown table 'nope'"
    )


def test_not_in_proof_outer_join_guard() raises:
    # kk.k holds no NULL in its file, but an outer join can null-extend it, so
    # the `x IS NOT NULL` check stays for LEFT, RIGHT and FULL (RIGHT and FULL
    # null-extend kk).
    _checkp(
        "SELECT kk.k FROM kk LEFT JOIN mm ON kk.k = mm.k WHERE kk.k NOT IN (SELECT k FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Join(type=LEFT, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT kk.k FROM kk RIGHT JOIN mm ON kk.k = mm.k WHERE kk.k NOT IN (SELECT k FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Join(type=RIGHT, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT kk.k FROM kk FULL JOIN mm ON kk.k = mm.k WHERE kk.k NOT IN (SELECT k FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Join(type=FULL, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_not_in_proof_needs_a_top_level_conjunct() raises:
    # The NOT IN sits in the second UNION ALL branch; the top statement's own
    # FROM is t, whose k holds no NULL. The branch reads u.k (5 NULLs), so the
    # check stays. The branch's x is not
    # proved against t.
    _checku(
        "SELECT k FROM t WHERE k > 0 UNION ALL SELECT k FROM u WHERE k NOT IN (SELECT k FROM mm)",
        "Union(branches=2)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 0))))\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_not_in_proof_cte_and_derived_shadow_a_catalog_table() raises:
    # A CTE or a derived table named `t` is not the catalog's t.parquet, whose
    # k holds no NULL: its rows come from u.k (5 NULLs), so the check on that
    # side stays. The shadowing name must
    # not borrow t.parquet's count.
    _checku(
        "WITH t AS (SELECT k FROM u) SELECT k FROM kk WHERE k NOT IN (SELECT k FROM t)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0)))))\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checku(
        "SELECT k FROM (SELECT k FROM u) AS t WHERE k NOT IN (SELECT k FROM mm)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Project(exprs=[ColRef(k)])\n"
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

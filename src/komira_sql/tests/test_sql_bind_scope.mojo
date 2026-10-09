# =============================================================================
# Direct tests of the binder's statement entry and FROM scope
# (sql_binder, sql_bind_scope)
# =============================================================================
#
# Each check binds one statement against parquet tables registered with a
# given schema (no file is opened) and compares the plan's text, or the
# binder's error, with the exact expected string. What each test proves, and
# the defect (mutant) it would catch:
#   1. COPY and CREATE TABLE AS bind their query; a query result renames a
#      join's `_right` columns back to their source names, a COPY / CTAS
#      result keeps the plan's names.
#      (mutant: `result_names` passed as True for every kind)
#   2. FROM-less SELECTs bind over the one-row relation; `SELECT *` there,
#      an unknown table and an unknown qualified column are refused by name.
#   3. CTEs bind in order, may reference earlier CTEs, shadow a catalog
#      table, and a duplicate name is refused; a derived table binds through
#      the same scope, its column list renames positionally (a count mismatch
#      is refused), and its alias may not collide with a CTE.
#      (mutant: `CteScope.find` compares without lower-casing)
#   4. UNION ALL builds one node over every branch with the first branch's
#      schema; a branch with a different width or column type is refused.
#      (mutant: the type comparison dropped from `_union_branch_schema_check`)
#   5. Join output names: a third relation's colliding column becomes
#      `<name>_right_2` (so `K2.k` and `M.k` are different columns), and a
#      right column whose `_right` name the left already has is renamed too.
#      (mutant: `_join_out_name` returns `cn_right` unconditionally)
#   6. The result rename sits at the root, directly under a LIMIT, or inside
#      the ORDER BY prune; a bare `SELECT *` under a LIMIT keeps the engine
#      names; two items of one name under DISTINCT or an ORDER BY carry are
#      refused.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import NoParquetFooters, SqlParquetFooters
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

def test_copy_and_ctas_bind_their_query_and_keep_engine_names() raises:
    _check(
        "COPY (SELECT k FROM t) TO 'out.parquet'",
        "Project(exprs=[ColRef(k)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "CREATE TABLE z AS SELECT k FROM t",
        "Project(exprs=[ColRef(k)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM t LEFT JOIN u ON t.k = u.k",
        "Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j), Alias(ColRef(k_right), \"k\"), ColRef(w), Alias(ColRef(s_right), \"s\")])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_from_less_selects_and_unknown_names() raises:
    _check(
        "SELECT 1 AS x",
        "Project(exprs=[Alias(Literal(ScalarValue(int64, 1)), \"x\")])\n"
        "  Scan(path=\"__in_memory__\", type=IN_MEMORY, inmem_id=1605317327532927430, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT 1 AS a, 'b' AS b",
        "Project(exprs=[Alias(Literal(ScalarValue(int64, 1)), \"a\"), Alias(Literal(ScalarValue(utf8, \"b\")), \"b\")])\n"
        "  Scan(path=\"__in_memory__\", type=IN_MEMORY, inmem_id=1605317327532927430, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT 1 + 2 AS x",
        "Project(exprs=[Alias(BinaryOp(ADD, Literal(ScalarValue(int64, 1)), Literal(ScalarValue(int64, 2))), \"x\")])\n"
        "  Scan(path=\"__in_memory__\", type=IN_MEMORY, inmem_id=1605317327532927430, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT *",
        "ERR: SQL bind error: * expression without FROM clause (a FROM-less SELECT has no columns to expand)"
    )
    _check(
        "SELECT * FROM missing_table",
        "ERR: SQL bind error: unknown table 'missing_table'"
    )
    _check(
        "SELECT zzz FROM t",
        "ERR: SQL bind error: unknown column 'zzz'"
    )
    _check(
        "SELECT t.zz FROM t",
        "ERR: SQL bind error: unknown column 't.zz'"
    )
    _check(
        "SELECT zz.k FROM t",
        "ERR: SQL bind error: unknown column 'zz.k'"
    )
    _check(
        "SELECT t.k, t.v FROM t",
        "Project(exprs=[ColRef(k), ColRef(v)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT x.k FROM t AS x",
        "Project(exprs=[ColRef(k)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_ctes_bind_in_order_and_shadow_tables() raises:
    _check(
        "WITH c AS (SELECT k, v FROM t) SELECT * FROM c",
        "Project(exprs=[ColRef(k), ColRef(v)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "WITH c AS (SELECT k FROM t), d AS (SELECT k FROM c) SELECT k FROM d",
        "Project(exprs=[ColRef(k)])\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Project(exprs=[ColRef(k)])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "WITH c AS (SELECT k FROM t), c AS (SELECT k FROM t) SELECT k FROM c",
        "ERR: SQL bind error: duplicate CTE name 'c'"
    )
    _check(
        "WITH t AS (SELECT k FROM u) SELECT * FROM t",
        "Project(exprs=[ColRef(k)])\n"
        "  Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_derived_tables_bind_through_the_scope() raises:
    _check(
        "SELECT * FROM (SELECT k, v FROM t) d",
        "Project(exprs=[ColRef(k), ColRef(v)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM (SELECT k, v FROM t) d (a, b)",
        "Project(exprs=[Alias(ColRef(k), \"a\"), Alias(ColRef(v), \"b\")])\n"
        "  Project(exprs=[ColRef(k), ColRef(v)])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM (SELECT k, v FROM t) d (a)",
        "ERR: SQL bind error: derived-table 'd' column list has 1 names but its SELECT produces 2 columns"
    )
    _check(
        "WITH d AS (SELECT k FROM t) SELECT * FROM (SELECT k FROM u) d",
        "ERR: SQL bind error: derived-table alias 'd' collides with a CTE or earlier derived table"
    )


def test_union_all_is_one_node_with_the_first_branch_schema() raises:
    _check(
        "SELECT k FROM t UNION ALL SELECT k FROM u",
        "Union(branches=2)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t UNION ALL SELECT k FROM u UNION ALL SELECT w FROM u",
        "Union(branches=3)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Project(exprs=[ColRef(w)])\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t UNION ALL SELECT k, w FROM u",
        "ERR: SQL bind error: UNION ALL branch 2 produces 2 column(s) but the first branch produces 1. Every branch of a UNION ALL must produce the same number of columns, in the same order."
    )
    _check(
        "SELECT k FROM t UNION ALL SELECT s FROM u",
        "ERR: SQL not supported: UNION ALL over branches whose column 1 differs in TYPE — the first branch has int64 and branch 2 has string. ⚠ DuckDB v1.5.3 COERCES the branches to a common type here; this engine's PLAN_UNION node does not coerce (it concatenates batches that must already share a schema), so admitting the query would hand the executor two different physical layouts under one advertised schema and return reinterpreted bytes rather than an error. CAST both branches to the same type explicitly."
    )


def test_join_output_names_never_collide() raises:
    _check(
        "SELECT * FROM kk JOIN mm ON kk.k = mm.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT kk.k, mm.k FROM kk JOIN mm ON kk.k = mm.k",
        "Project(exprs=[ColRef(k), Alias(ColRef(k_right), \"k\")])\n"
        "  Project(exprs=[ColRef(k), ColRef(k_right)])\n"
        "    Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT mm.k FROM kk JOIN mm ON kk.k = mm.k",
        "Project(exprs=[Alias(ColRef(k_right), \"k\")])\n"
        "  Project(exprs=[ColRef(k_right)])\n"
        "    Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk JOIN mm ON kk.k = mm.k JOIN kk AS k2 ON k2.k = mm.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b), Alias(ColRef(k_right_2), \"k\"), Alias(ColRef(a_right), \"a\")])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(EQ, ColRef(k), ColRef(k_right)), BinaryOp(EQ, ColRef(k_right_2), ColRef(k_right))))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(a)])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk JOIN kk2 ON kk.k = kk2.k JOIN kk AS k3 ON k3.k = kk2.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right_2), \"k\"), ColRef(k_right), Alias(ColRef(k_right_3), \"k\"), Alias(ColRef(a_right), \"a\")])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(EQ, ColRef(k), ColRef(k_right_2)), BinaryOp(EQ, ColRef(k_right_3), ColRef(k_right_2))))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(k_right)])\n"
        "          Scan(path=\"kk2.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Project(exprs=[Alias(ColRef(k), \"k_right_3\"), ColRef(a)])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk JOIN mm ON kk.k = mm.k JOIN mm AS m2 ON m2.k = kk.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b), Alias(ColRef(k_right_2), \"k\"), Alias(ColRef(b_right), \"b\")])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(EQ, ColRef(k), ColRef(k_right)), BinaryOp(EQ, ColRef(k_right_2), ColRef(k))))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(b)])\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k LEFT JOIN mm AS m2 ON m2.k = kk.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b), Alias(ColRef(k_right_2), \"k\"), Alias(ColRef(b_right), \"b\")])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Join(type=LEFT, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(b)])\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk JOIN mm USING (k) JOIN kk AS k3 ON k3.k = mm.k",
        "Project(exprs=[ColRef(k), ColRef(a), ColRef(b), Alias(ColRef(k_right), \"k\"), Alias(ColRef(a_right), \"a\")])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(k_right), ColRef(k)))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Project(exprs=[ColRef(k), ColRef(a), ColRef(b)])\n"
        "        Join(type=INNER, on=[k=k])\n"
        "          Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "          Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk, mm",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=CROSS, on=[])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk CROSS JOIN mm",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=CROSS, on=[])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_result_rename_placement() raises:
    _check(
        "SELECT * FROM kk JOIN mm ON kk.k = mm.k LIMIT 1",
        "Limit(n=1)\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT kk.k, mm.k FROM kk JOIN mm ON kk.k = mm.k LIMIT 1",
        "Limit(n=1)\n"
        "  Project(exprs=[ColRef(k), Alias(ColRef(k_right), \"k\")])\n"
        "    Project(exprs=[ColRef(k), ColRef(k_right)])\n"
        "      Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "        Join(type=CROSS, on=[])\n"
        "          Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "          Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk JOIN mm ON kk.k = mm.k ORDER BY a LIMIT 2",
        "Limit(n=2)\n"
        "  Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "    Sort(keys=[a ASC])\n"
        "      Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "        Join(type=CROSS, on=[])\n"
        "          Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "          Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT DISTINCT * FROM kk LEFT JOIN mm ON kk.k = mm.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Distinct(all)\n"
        "    Join(type=LEFT, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT DISTINCT * FROM kk JOIN mm ON kk.k = mm.k LIMIT 2",
        "Limit(n=2)\n"
        "  Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "    Distinct(all)\n"
        "      Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "        Join(type=CROSS, on=[])\n"
        "          Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "          Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT kk.k, mm.k FROM kk LEFT JOIN mm ON kk.k = mm.k ORDER BY a",
        "Project(exprs=[ColRef(k), Alias(ColRef(k_right), \"k\")])\n"
        "  Sort(keys=[a ASC])\n"
        "    Project(exprs=[ColRef(k), ColRef(k_right), ColRef(a)])\n"
        "      Join(type=LEFT, on=[k=k])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT kk.k, mm.k FROM kk LEFT JOIN mm ON kk.k = mm.k ORDER BY a LIMIT 2",
        "Project(exprs=[ColRef(k), Alias(ColRef(k_right), \"k\")])\n"
        "  Limit(n=2)\n"
        "    Sort(keys=[a ASC])\n"
        "      Project(exprs=[ColRef(k), ColRef(k_right), ColRef(a)])\n"
        "        Join(type=LEFT, on=[k=k])\n"
        "          Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "          Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT DISTINCT kk.k AS k, mm.k AS k FROM kk LEFT JOIN mm ON kk.k = mm.k",
        "ERR: SQL not supported: SELECT DISTINCT over two items both named `k`. The distinct resolves its columns by NAME, so the second would be answered with the first's values. Give the two items distinct aliases."
    )
    _check(
        "SELECT kk.k AS k, mm.k AS k FROM kk LEFT JOIN mm ON kk.k = mm.k ORDER BY a",
        "ERR: SQL not supported: two SELECT items are both named `k` and ORDER BY sorts by a column the SELECT list does not produce. The sort's extra column is pruned by NAME, which cannot tell the two apart, so the second would be answered with the first's values. Give the two items distinct aliases, or ORDER BY a selected column."
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

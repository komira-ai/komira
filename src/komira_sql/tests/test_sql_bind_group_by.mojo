# =============================================================================
# Direct tests of GROUP BY resolution and the grouped SELECT list
# (sql_bind_aggregate, sql_bind_names)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. An ordinal names a SELECT item (range-checked; a literal past BIGINT
#      refused); an alias is consulted only when no input column has the
#      name; a computed key is materialised by a Project below the
#      aggregate; a repeated key is one key.
#      (mutant: `_select_alias_index` consulted before the input columns)
#   2. A literal constant key is elided when a non-constant key remains,
#      and the SELECT item naming it is re-projected as the literal; an
#      all-constant GROUP BY keeps its key.
#      (mutant: the `n_other > 0` guard removed)
#   3. A non-aggregate SELECT item must match a group key (column keys
#      case-insensitively, expression keys exactly); an unbindable item
#      reports its own error first; aggregates and windows in GROUP BY and
#      `*` with aggregation are refused.
#   4. An ORDER BY a group key that is not selected is carried and pruned;
#      an ORDER BY over an aggregate expression is hoisted.

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

def test_group_by_ordinals_and_aliases() raises:
    _check(
        "SELECT k AS kk, count(*) FROM t GROUP BY kk",
        "Project(exprs=[Alias(ColRef(k), \"kk\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k AS g, sum(v) FROM t GROUP BY g",
        "ERR: SQL bind error: SELECT column 'k' must appear in GROUP BY"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY 1",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY 3",
        "ERR: SQL bind error: GROUP BY term out of range - should be between 1 and 2"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY 0",
        "ERR: SQL bind error: GROUP BY term out of range - should be between 1 and 2"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY -1",
        "ERR: SQL bind error: GROUP BY term out of range - should be between 1 and 2"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY 18446744073709551617",
        "ERR: SQL bind error: the GROUP BY ordinal 18446744073709551617 is out of range for BIGINT (DuckDB v1.5.3 raises a Conversion Error: the value is out of range for the destination type INT64)"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY 18446744073709551617, k",
        "ERR: SQL bind error: the GROUP BY ordinal 18446744073709551617 is out of range for BIGINT (DuckDB v1.5.3 raises a Conversion Error: the value is out of range for the destination type INT64)"
    )
    _check(
        "SELECT count(*) FROM t GROUP BY 1",
        "ERR: SQL bind error: GROUP BY clause cannot contain aggregates"
    )
    _check(
        "SELECT t.k, count(*) FROM t GROUP BY t.k",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT u.k, count(*) FROM t JOIN u ON t.k = u.k GROUP BY u.k",
        "Project(exprs=[Alias(ColRef(k_right), \"k\"), ColRef(count_star())])\n"
        "  Project(exprs=[ColRef(k_right), ColRef(count_star())])\n"
        "    Aggregate(group_by=[ColRef(k_right)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "      Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "        Join(type=CROSS, on=[])\n"
        "          Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "          Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT K, count(*) FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k AS x, count(*) FROM t GROUP BY x, 1",
        "Project(exprs=[Alias(ColRef(k), \"x\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_computed_and_repeated_keys() raises:
    _check(
        "SELECT k + 1, count(*) FROM t GROUP BY k + 1",
        "Project(exprs=[Alias(ColRef(__grp_key_0), \"(k + 1)\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(__grp_key_0)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j), Alias(BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), \"__grp_key_0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k + 1 AS kp, count(*) FROM t GROUP BY 1",
        "Project(exprs=[Alias(ColRef(__grp_key_0), \"kp\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(__grp_key_0)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j), Alias(BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), \"__grp_key_0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY k, k",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k + 1, count(*) FROM t GROUP BY 1, 1",
        "Project(exprs=[Alias(ColRef(__grp_key_0), \"(k + 1)\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(__grp_key_0)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j), Alias(BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), \"__grp_key_0\"), Alias(BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), \"__grp_key_1\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN s = 'A' THEN 1 ELSE 0 END AS c, count(*) FROM t GROUP BY CASE WHEN s = 'A' THEN 1 ELSE 0 END",
        "Project(exprs=[Alias(ColRef(__grp_key_0), \"c\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(__grp_key_0)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j), Alias(When(WHEN BinaryOp(EQ, ColRef(s), Literal(ScalarValue(utf8, \"A\"))) THEN Literal(ScalarValue(int64, 1)), ELSE Literal(ScalarValue(int64, 0))), \"__grp_key_0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CASE WHEN s = 'A' THEN 1 ELSE 0 END, count(*) FROM t GROUP BY CASE WHEN s = 'a' THEN 1 ELSE 0 END",
        "ERR: SQL not supported: non-aggregate SELECT item must be a GROUP BY column"
    )


def test_constant_keys() raises:
    _check(
        "SELECT k, count(*) FROM t GROUP BY k, 'x'",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT 1, k, count(*) FROM t GROUP BY 1, k",
        "Project(exprs=[Alias(Literal(ScalarValue(int64, 1)), \"1\"), ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT 1 AS lit, count(*) FROM t GROUP BY 1",
        "Project(exprs=[Alias(ColRef(__grp_key_0), \"lit\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(__grp_key_0)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j), Alias(Literal(ScalarValue(int64, 1)), \"__grp_key_0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT 'x' AS c, k, count(*) FROM t GROUP BY c, k",
        "Project(exprs=[Alias(Literal(ScalarValue(utf8, \"x\")), \"c\"), ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT 'x', count(*) FROM t GROUP BY 'x', k",
        "Project(exprs=[Alias(Literal(ScalarValue(utf8, \"x\")), \"'x'\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT d, count(*) FROM t GROUP BY DATE '2021-01-01', d",
        "Project(exprs=[ColRef(d), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(d)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT 1, 2, count(*) FROM t GROUP BY 1, 2",
        "Project(exprs=[Alias(ColRef(__grp_key_0), \"1\"), Alias(ColRef(__grp_key_1), \"2\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(__grp_key_0), ColRef(__grp_key_1)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j), Alias(Literal(ScalarValue(int64, 1)), \"__grp_key_0\"), Alias(Literal(ScalarValue(int64, 2)), \"__grp_key_1\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT -1 AS m, k, count(*) FROM t GROUP BY 1, k",
        "Project(exprs=[Alias(Literal(ScalarValue(int64, -1)), \"m\"), ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT 1.5 AS f, k, count(*) FROM t GROUP BY f, k",
        "Project(exprs=[Alias(Literal(ScalarValue(float64, 1.5)), \"f\"), ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT 'x' AS s, k, count(*) FROM t GROUP BY s, k",
        "ERR: SQL not supported: non-aggregate SELECT item must be a GROUP BY column"
    )
    _check(
        "SELECT TIMESTAMP '2021-01-01 00:00:00' AS c, true AS b2, k, count(*) FROM t GROUP BY 1, 2, k",
        "Project(exprs=[Alias(Literal(ScalarValue(timestamp[us], 1609459200000000)), \"c\"), Alias(Literal(ScalarValue(bool, true)), \"b2\"), ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, 1 FROM t GROUP BY k",
        "ERR: SQL not supported: non-aggregate SELECT item must be a GROUP BY column"
    )


def test_grouped_select_list_refusals() raises:
    _check(
        "SELECT * FROM t GROUP BY k",
        "ERR: SQL not supported: SELECT * with aggregation"
    )
    _check(
        "SELECT *, count(*) FROM t GROUP BY 2",
        "ERR: SQL bind error: GROUP BY clause cannot contain aggregates"
    )
    _check(
        "SELECT *, count(*) FROM t GROUP BY 1",
        "ERR: SQL bind error: GROUP BY term names a '*' SELECT item"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY sum(v)",
        "ERR: SQL bind error: GROUP BY clause cannot contain aggregates"
    )
    _check(
        "SELECT sum(v) AS sv, count(*) FROM t GROUP BY 1",
        "ERR: SQL bind error: GROUP BY clause cannot contain aggregates"
    )
    _check(
        "SELECT rank() OVER (ORDER BY k) AS r FROM t GROUP BY 1",
        "ERR: SQL not supported: a window function combined with GROUP BY / aggregation in the same SELECT"
    )
    _check(
        "SELECT k FROM t GROUP BY rank() OVER (ORDER BY k)",
        "ERR: SQL bind error: GROUP BY clause cannot contain window functions"
    )
    _check(
        "SELECT v, count(*) FROM t GROUP BY k",
        "ERR: SQL bind error: SELECT column 'v' must appear in GROUP BY"
    )
    _check(
        "SELECT k + 1, count(*) FROM t GROUP BY k",
        "ERR: SQL not supported: non-aggregate SELECT item must be a GROUP BY column"
    )
    _check(
        "SELECT nosuchfn(v), count(*) FROM t GROUP BY k",
        "ERR: SQL not supported: scalar function 'nosuchfn'. No UDFs are declared on this catalog either — declare one with `catalog.declare_udf(f)`"
    )
    _check(
        "SELECT k AS kk, count(*) FROM t GROUP BY k",
        "Project(exprs=[Alias(ColRef(k), \"kk\"), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT sum(v) FROM t GROUP BY g",
        "Project(exprs=[ColRef(sum(v))])\n"
        "  Aggregate(group_by=[ColRef(g)], aggs=[SUM(ColRef(v)).alias(\"sum(v)\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT DISTINCT k, count(*) FROM t GROUP BY k",
        "Distinct(all)\n"
        "  Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_grouped_order_by() raises:
    _check(
        "SELECT k, sum(v) FROM t GROUP BY k, g ORDER BY g",
        "Project(exprs=[ColRef(k), ColRef(sum(v))])\n"
        "  Sort(keys=[g ASC])\n"
        "    Project(exprs=[ColRef(k), ColRef(sum(v)), ColRef(g)])\n"
        "      Aggregate(group_by=[ColRef(k), ColRef(g)], aggs=[SUM(ColRef(v)).alias(\"sum(v)\")])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) FROM t GROUP BY k ORDER BY v",
        "ERR: SQL bind error: unknown ORDER BY column 'v'"
    )
    _check(
        "SELECT g FROM t GROUP BY g ORDER BY count(*) DESC, g",
        "Project(exprs=[ColRef(g)])\n"
        "  Sort(keys=[__order_key_0 DESC, g ASC])\n"
        "    Project(exprs=[ColRef(g), Alias(ColRef(_agg_x0), \"__order_key_0\")])\n"
        "      Aggregate(group_by=[ColRef(g)], aggs=[COUNT(*).alias(\"_agg_x0\")])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY k ORDER BY 2 DESC",
        "Sort(keys=[count_star() DESC])\n"
        "  Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) AS c FROM t GROUP BY k ORDER BY c",
        "Sort(keys=[c ASC])\n"
        "  Project(exprs=[ColRef(k), ColRef(c)])\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"c\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY k ORDER BY count(*)",
        "Sort(keys=[count_star() ASC])\n"
        "  Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) AS n FROM t GROUP BY k ORDER BY n DESC, k",
        "Sort(keys=[n DESC, k ASC])\n"
        "  Project(exprs=[ColRef(k), ColRef(n)])\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"n\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY k ORDER BY sum(v) + 1",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Sort(keys=[__order_key_0 ASC])\n"
        "    Project(exprs=[ColRef(k), ColRef(count_star()), Alias(BinaryOp(ADD, ColRef(_agg_x0), Literal(ScalarValue(int64, 1))), \"__order_key_0\")])\n"
        "      Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\"), SUM(ColRef(v)).alias(\"_agg_x0\")])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY k ORDER BY -k",
        "ERR: SQL not supported: unary minus over a GROUP BY / aggregate result (`-sum(v)`, `ORDER BY -count(*)`). The engine does not lower unary minus above an aggregate yet; `sum(v) * -1` is served."
    )
    _check(
        "SELECT k, sum(v) AS s FROM t GROUP BY k ORDER BY s * 2",
        "Project(exprs=[ColRef(k), ColRef(s)])\n"
        "  Sort(keys=[__order_key_0 ASC])\n"
        "    Project(exprs=[ColRef(k), ColRef(s), Alias(BinaryOp(MUL, ColRef(s), Literal(ScalarValue(int64, 2))), \"__order_key_0\")])\n"
        "      Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"s\")])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY k HAVING count(*) > 1 ORDER BY count(*) DESC LIMIT 3",
        "Limit(n=3)\n"
        "  Sort(keys=[count_star() DESC])\n"
        "    Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "      Filter(predicate=BinaryOp(GT, ColRef(count_star()), Literal(ScalarValue(int64, 1))))\n"
        "        Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "          Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY 1 HAVING count(*) > 1",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(count_star()), Literal(ScalarValue(int64, 1))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_unknown_group_key() raises:
    _check(
        "SELECT k, count(*) FROM t GROUP BY zz",
        "ERR: SQL bind error: unknown column 'zz'"
    )
    _check(
        "SELECT k FROM t WHERE k > 0 GROUP BY k HAVING k = 1 ORDER BY k LIMIT 1 OFFSET 0",
        "Limit(n=1)\n"
        "  Sort(keys=[k ASC])\n"
        "    Project(exprs=[ColRef(k)])\n"
        "      Filter(predicate=BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 1))))\n"
        "        Aggregate(group_by=[ColRef(k)], aggs=[])\n"
        "          Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 0))))\n"
        "            Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) FROM t GROUP BY k HAVING k > 0 AND sum(v) > (SELECT max(w) FROM u)",
        "ERR: SQL bind error: unsupported expression"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

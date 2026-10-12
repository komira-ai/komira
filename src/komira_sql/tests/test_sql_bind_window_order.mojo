# =============================================================================
# Direct tests of window functions, ORDER BY, LIMIT / OFFSET and DISTINCT
# (sql_bind_window_order, sql_binder)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. Each window function lowers to one PARTITION BY node with its own
#      `PF_*` function; with no ORDER BY the default frame is the whole
#      partition and with one it is RANGE ... CURRENT ROW; a written frame is
#      kept; value windows carry their offset and DEFAULT; an unknown
#      column, a window beside GROUP BY or `*`, and a missing argument are
#      refused.
#      (mutant: the ordered default frame spelled `default_ordered()` (ROWS))
#   2. A window named like an input column is computed under an internal
#      name; a qualified window column resolves through the join scope.
#   3. ORDER BY: a column key, an ordinal (range-checked), a SELECT item's
#      expression or alias, and an expression carried as a hidden column
#      and pruned at the root; refusals for non-integer literals, hidden keys
#      under DISTINCT or a window, and a key two items share.
#      (mutant: `_order_output_column`'s range test off by one)
#   4. NULLS FIRST / LAST: the placement list is built only when a key asks,
#      a key that does not ask gets the derived default.
#   5. LIMIT / OFFSET bind one limit node; OFFSET without LIMIT is refused.

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

def test_window_functions() raises:
    _check(
        "SELECT k, row_number() OVER (PARTITION BY g ORDER BY v) AS rn FROM t",
        "Project(exprs=[ColRef(k), ColRef(rn)])\n"
        "  PartitionBy(partition=[g], order=[v ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS rn])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT rank() OVER (ORDER BY k), dense_rank() OVER (ORDER BY k), percent_rank() OVER (ORDER BY k), cume_dist() OVER (ORDER BY k), ntile(4) OVER (ORDER BY k) FROM t",
        "Project(exprs=[ColRef(_w0), ColRef(_w1), ColRef(_w2), ColRef(_w3), ColRef(_w4)])\n"
        "  PartitionBy(partition=[], order=[k ASC], funcs=[NTILE(, offset=4, frame=RANGE[0:0..2:0]) AS _w4])\n"
        "    PartitionBy(partition=[], order=[k ASC], funcs=[CUME_DIST(, offset=0, frame=RANGE[0:0..2:0]) AS _w3])\n"
        "      PartitionBy(partition=[], order=[k ASC], funcs=[PERCENT_RANK(, offset=0, frame=RANGE[0:0..2:0]) AS _w2])\n"
        "        PartitionBy(partition=[], order=[k ASC], funcs=[DENSE_RANK(, offset=0, frame=RANGE[0:0..2:0]) AS _w1])\n"
        "          PartitionBy(partition=[], order=[k ASC], funcs=[RANK(, offset=0, frame=RANGE[0:0..2:0]) AS _w0])\n"
        "            Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT sum(v) OVER (PARTITION BY g) AS s1, sum(v) OVER (PARTITION BY g ORDER BY k) AS s2, count(*) OVER () AS c, avg(v) OVER (ORDER BY k ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS a, min(v) OVER (), max(v) OVER () FROM t",
        "Project(exprs=[ColRef(s1), ColRef(s2), ColRef(c), ColRef(a), ColRef(_w4), ColRef(_w5)])\n"
        "  PartitionBy(partition=[], order=[], funcs=[MAX(v, offset=0, frame=ROWS[0:0..4:0]) AS _w5])\n"
        "    PartitionBy(partition=[], order=[], funcs=[MIN(v, offset=0, frame=ROWS[0:0..4:0]) AS _w4])\n"
        "      PartitionBy(partition=[], order=[k ASC], funcs=[AVG(v, offset=0, frame=ROWS[1:1..2:0]) AS a])\n"
        "        PartitionBy(partition=[], order=[], funcs=[COUNT(, offset=0, frame=ROWS[0:0..4:0]) AS c])\n"
        "          PartitionBy(partition=[g], order=[k ASC], funcs=[SUM(v, offset=0, frame=RANGE[0:0..2:0]) AS s2])\n"
        "            PartitionBy(partition=[g], order=[], funcs=[SUM(v, offset=0, frame=ROWS[0:0..4:0]) AS s1])\n"
        "              Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT lag(v) OVER (ORDER BY k) AS l1, lead(v, 2, 0) OVER (ORDER BY k) AS l2, lag(s, 1, 'x') OVER (ORDER BY k) AS l3, lag(d, 1, DATE '2021-01-01') OVER (ORDER BY k) AS l4, lag(v, 1, 1.5) OVER (ORDER BY k) AS l5, first_value(v) OVER (ORDER BY k) AS f, last_value(v) OVER (ORDER BY k) AS la, nth_value(v, 2) OVER (ORDER BY k) AS n FROM t",
        "Project(exprs=[ColRef(l1), ColRef(l2), ColRef(l3), ColRef(l4), ColRef(l5), ColRef(f), ColRef(la), ColRef(n)])\n"
        "  PartitionBy(partition=[], order=[k ASC], funcs=[NTH_VALUE(v, offset=2, frame=RANGE[0:0..2:0]) AS n])\n"
        "    PartitionBy(partition=[], order=[k ASC], funcs=[LAST_VALUE(v, offset=0, frame=RANGE[0:0..2:0]) AS la])\n"
        "      PartitionBy(partition=[], order=[k ASC], funcs=[FIRST_VALUE(v, offset=0, frame=RANGE[0:0..2:0]) AS f])\n"
        "        PartitionBy(partition=[], order=[k ASC], funcs=[LAG(v, offset=1, default=ScalarValue(float64, 1.5), frame=RANGE[0:0..2:0]) AS l5])\n"
        "          PartitionBy(partition=[], order=[k ASC], funcs=[LAG(d, offset=1, default=ScalarValue(date32, 18628), frame=RANGE[0:0..2:0]) AS l4])\n"
        "            PartitionBy(partition=[], order=[k ASC], funcs=[LAG(s, offset=1, default=ScalarValue(utf8, \"x\"), frame=RANGE[0:0..2:0]) AS l3])\n"
        "              PartitionBy(partition=[], order=[k ASC], funcs=[LEAD(v, offset=2, default=ScalarValue(int64, 0), frame=RANGE[0:0..2:0]) AS l2])\n"
        "                PartitionBy(partition=[], order=[k ASC], funcs=[LAG(v, offset=1, frame=RANGE[0:0..2:0]) AS l1])\n"
        "                  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT sum(v) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS a, sum(v) OVER (ORDER BY k ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS b, sum(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS c FROM t",
        "Project(exprs=[ColRef(a), Alias(ColRef(_w_shadow_1_b), \"b\"), ColRef(c)])\n"
        "  PartitionBy(partition=[], order=[], funcs=[SUM(v, offset=0, frame=ROWS[0:0..4:0]) AS c])\n"
        "    PartitionBy(partition=[], order=[k ASC], funcs=[SUM(v, offset=0, frame=ROWS[1:2..3:2]) AS _w_shadow_1_b])\n"
        "      PartitionBy(partition=[], order=[k ASC], funcs=[SUM(v, offset=0, frame=RANGE[0:0..2:0]) AS a])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT count(k) OVER (PARTITION BY g ORDER BY k DESC) AS c FROM t",
        "Project(exprs=[ColRef(c)])\n"
        "  PartitionBy(partition=[g], order=[k DESC], funcs=[COUNT(k, offset=0, frame=RANGE[0:0..2:0]) AS c])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT lag(v, -1) OVER (ORDER BY k) AS l FROM t",
        "Project(exprs=[ColRef(l)])\n"
        "  PartitionBy(partition=[], order=[k ASC], funcs=[LAG(v, offset=-1, frame=RANGE[0:0..2:0]) AS l])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, row_number() OVER (ORDER BY k) FROM t",
        "Project(exprs=[ColRef(k), ColRef(_w0)])\n"
        "  PartitionBy(partition=[], order=[k ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS _w0])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k + 1 AS kp, rank() OVER (ORDER BY k) AS r FROM t",
        "Project(exprs=[Alias(BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), \"kp\"), ColRef(r)])\n"
        "  PartitionBy(partition=[], order=[k ASC], funcs=[RANK(, offset=0, frame=RANGE[0:0..2:0]) AS r])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_window_refusals() raises:
    _check(
        "SELECT sum(zz) OVER () FROM t",
        "ERR: SQL bind error: unknown window aggregate column 'zz'"
    )
    _check(
        "SELECT lag(zz) OVER (ORDER BY k) FROM t",
        "ERR: SQL bind error: unknown window function column 'zz'"
    )
    _check(
        "SELECT sum(v) OVER (PARTITION BY zz) FROM t",
        "ERR: SQL bind error: unknown PARTITION BY column 'zz'"
    )
    _check(
        "SELECT sum(v) OVER (ORDER BY zz) FROM t",
        "ERR: SQL bind error: unknown ORDER BY column 'zz' in OVER clause"
    )
    _check(
        "SELECT *, rank() OVER (ORDER BY k) FROM t",
        "ERR: SQL not supported: SELECT * alongside a window function"
    )
    _check(
        "SELECT k, sum(v) OVER () FROM t GROUP BY k",
        "ERR: SQL not supported: a window function combined with GROUP BY / aggregation in the same SELECT"
    )
    _check(
        "SELECT lag(v, 1, DATE '2021-02-30') OVER (ORDER BY k) FROM t",
        "ERR: SQL bind error: date out of range '2021-02-30'"
    )


def test_window_names_and_join_scope() raises:
    _check(
        "SELECT max(v) OVER (PARTITION BY g) AS v FROM t",
        "Project(exprs=[Alias(ColRef(_w_shadow_0_v), \"v\")])\n"
        "  PartitionBy(partition=[g], order=[], funcs=[MAX(v, offset=0, frame=ROWS[0:0..4:0]) AS _w_shadow_0_v])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT count(*) OVER (PARTITION BY mm.k) AS c FROM kk LEFT JOIN mm ON kk.k = mm.k",
        "Project(exprs=[ColRef(c)])\n"
        "  PartitionBy(partition=[k_right], order=[], funcs=[COUNT(, offset=0, frame=ROWS[0:0..4:0]) AS c])\n"
        "    Join(type=LEFT, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT sum(mm.b) OVER (), lag(mm.k) OVER (ORDER BY kk.k) FROM kk LEFT JOIN mm ON kk.k = mm.k",
        "Project(exprs=[ColRef(_w0), ColRef(_w1)])\n"
        "  PartitionBy(partition=[], order=[k ASC], funcs=[LAG(k_right, offset=1, frame=RANGE[0:0..2:0]) AS _w1])\n"
        "    PartitionBy(partition=[], order=[], funcs=[SUM(b, offset=0, frame=ROWS[0:0..4:0]) AS _w0])\n"
        "      Join(type=LEFT, on=[k=k])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT sum(zz.b) OVER () FROM kk LEFT JOIN mm ON kk.k = mm.k",
        "ERR: SQL bind error: unknown column 'zz.b'"
    )
    _check(
        "SELECT k AS r, rank() OVER (ORDER BY k) AS r FROM t",
        "Project(exprs=[Alias(ColRef(k), \"r\"), ColRef(r)])\n"
        "  PartitionBy(partition=[], order=[k ASC], funcs=[RANK(, offset=0, frame=RANGE[0:0..2:0]) AS r])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_order_by_keys() raises:
    _check(
        "SELECT k, v FROM t WHERE k > 1 ORDER BY v DESC LIMIT 3",
        "Limit(n=3)\n"
        "  Sort(keys=[v DESC])\n"
        "    Project(exprs=[ColRef(k), ColRef(v)])\n"
        "      Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))))\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, v FROM t ORDER BY 2, 1",
        "Sort(keys=[v ASC, k ASC])\n"
        "  Project(exprs=[ColRef(k), ColRef(v)])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, v FROM t ORDER BY 0",
        "ERR: SQL bind error: ORDER term out of range - should be between 1 and 2"
    )
    _check(
        "SELECT k, v FROM t ORDER BY 3",
        "ERR: SQL bind error: ORDER term out of range - should be between 1 and 2"
    )
    _check(
        "SELECT k, v FROM t ORDER BY 1.5",
        "ERR: SQL bind error: ORDER BY non-integer literal has no effect. (DuckDB v1.5.3 refuses it with this sentence: only an INTEGER literal is an ordinal, and a constant key orders nothing.)"
    )
    _check(
        "SELECT k, v FROM t ORDER BY 'x'",
        "ERR: SQL bind error: ORDER BY non-integer literal has no effect. (DuckDB v1.5.3 refuses it with this sentence: only an INTEGER literal is an ordinal, and a constant key orders nothing.)"
    )
    _check(
        "SELECT k, v FROM t ORDER BY 18446744073709551617",
        "ERR: SQL bind error: the ORDER BY ordinal 18446744073709551617 is out of range for BIGINT (DuckDB v1.5.3 raises a Conversion Error: the value is out of range for the destination type INT64)"
    )
    _check(
        "SELECT k, v FROM t ORDER BY -k",
        "Project(exprs=[ColRef(k), ColRef(v)])\n"
        "  Sort(keys=[__order_key_0 ASC])\n"
        "    Project(exprs=[ColRef(k), ColRef(v), Alias(UnaryOp(NEGATE, ColRef(k)), \"__order_key_0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, v FROM t ORDER BY abs(k - 3)",
        "Project(exprs=[ColRef(k), ColRef(v)])\n"
        "  Sort(keys=[__order_key_0 ASC])\n"
        "    Project(exprs=[ColRef(k), ColRef(v), Alias(UnaryOp(ABS, BinaryOp(SUB, ColRef(k), Literal(ScalarValue(int64, 3)))), \"__order_key_0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k AS a, v AS k FROM t ORDER BY -k",
        "Project(exprs=[ColRef(a), ColRef(k)])\n"
        "  Sort(keys=[__order_key_0 ASC])\n"
        "    Project(exprs=[Alias(ColRef(k), \"a\"), Alias(ColRef(v), \"k\"), Alias(UnaryOp(NEGATE, ColRef(k)), \"__order_key_0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k AS a, v AS k FROM t ORDER BY k",
        "Sort(keys=[k ASC])\n"
        "  Project(exprs=[Alias(ColRef(k), \"a\"), Alias(ColRef(v), \"k\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k * 2 AS b FROM t ORDER BY b * 2",
        "Project(exprs=[ColRef(b)])\n"
        "  Sort(keys=[__order_key_0 ASC])\n"
        "    Project(exprs=[Alias(BinaryOp(MUL, ColRef(k), Literal(ScalarValue(int64, 2))), \"b\"), Alias(BinaryOp(MUL, ColRef(b), Literal(ScalarValue(int64, 2))), \"__order_key_0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, k + 1 FROM t ORDER BY k + 1",
        "Sort(keys=[expr ASC])\n"
        "  Project(exprs=[ColRef(k), BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1)))])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t ORDER BY zz",
        "ERR: SQL bind error: unknown ORDER BY column 'zz'"
    )
    _check(
        "SELECT * FROM t ORDER BY -k",
        "Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j)])\n"
        "  Sort(keys=[__order_key_0 ASC])\n"
        "    Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j), Alias(UnaryOp(NEGATE, ColRef(k)), \"__order_key_0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM t ORDER BY v",
        "Sort(keys=[v ASC])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT v FROM t ORDER BY k",
        "Project(exprs=[ColRef(v)])\n"
        "  Sort(keys=[k ASC])\n"
        "    Project(exprs=[ColRef(v), ColRef(k)])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT v AS k FROM t ORDER BY k DESC",
        "Sort(keys=[k DESC])\n"
        "  Project(exprs=[Alias(ColRef(v), \"k\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k AS x, v AS x FROM t ORDER BY 1",
        "ERR: SQL not supported: ORDER BY 1 names the output column `x`, and another SELECT item has the same name. The sort resolves its key by NAME, so it could order by the wrong one. Give the items distinct aliases."
    )
    _check(
        "SELECT mm.k FROM kk LEFT JOIN mm ON kk.k = mm.k ORDER BY mm.k",
        "Project(exprs=[Alias(ColRef(k_right), \"k\")])\n"
        "  Sort(keys=[k_right ASC])\n"
        "    Project(exprs=[ColRef(k_right), ColRef(k_right)])\n"
        "      Join(type=LEFT, on=[k=k])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT kk.k FROM kk LEFT JOIN mm ON kk.k = mm.k ORDER BY zz.k",
        "Sort(keys=[k ASC])\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Join(type=LEFT, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_order_by_under_distinct_and_windows() raises:
    _check(
        "SELECT DISTINCT k FROM t ORDER BY v",
        "ERR: SQL bind error: unknown ORDER BY column 'v'"
    )
    _check(
        "SELECT DISTINCT k FROM t ORDER BY k",
        "Sort(keys=[k ASC])\n"
        "  Distinct(all)\n"
        "    Project(exprs=[ColRef(k)])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT DISTINCT k FROM t ORDER BY -k",
        "ERR: SQL not supported: ORDER BY an expression that no SELECT item produces, under SELECT DISTINCT. The key would be a hidden column, which would widen the DISTINCT key and change the row count. Select the expression (and ORDER BY its position or alias), or order by a column."
    )
    _check(
        "SELECT DISTINCT k, k + 1 FROM t ORDER BY k + 1",
        "Sort(keys=[expr ASC])\n"
        "  Distinct(all)\n"
        "    Project(exprs=[ColRef(k), BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1)))])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, rank() OVER (ORDER BY k) AS r FROM t ORDER BY -k",
        "ERR: SQL not supported: ORDER BY an expression that no SELECT item produces, under a window function. The key would be a hidden column, which the window projection has no carry for. Select the expression (and ORDER BY its position or alias), or order by a column."
    )
    _check(
        "SELECT k, rank() OVER (ORDER BY k) AS r FROM t ORDER BY r",
        "Sort(keys=[r ASC])\n"
        "  Project(exprs=[ColRef(k), ColRef(r)])\n"
        "    PartitionBy(partition=[], order=[k ASC], funcs=[RANK(, offset=0, frame=RANGE[0:0..2:0]) AS r])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, s, row_number() OVER (ORDER BY k) AS rn FROM t ORDER BY 3",
        "Sort(keys=[rn ASC])\n"
        "  Project(exprs=[ColRef(k), ColRef(s), ColRef(rn)])\n"
        "    PartitionBy(partition=[], order=[k ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS rn])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, row_number() OVER (ORDER BY k) AS rn FROM t ORDER BY rn DESC LIMIT 1",
        "Limit(n=1)\n"
        "  Sort(keys=[rn DESC])\n"
        "    Project(exprs=[ColRef(k), ColRef(rn)])\n"
        "      PartitionBy(partition=[], order=[k ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS rn])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT DISTINCT k, row_number() OVER (ORDER BY k) AS rn FROM t",
        "Distinct(all)\n"
        "  Project(exprs=[ColRef(k), ColRef(rn)])\n"
        "    PartitionBy(partition=[], order=[k ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS rn])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_nulls_placement_limit_offset() raises:
    _check(
        "SELECT k FROM t ORDER BY k NULLS LAST, v",
        "Project(exprs=[ColRef(k)])\n"
        "  Sort(keys=[k ASC, v ASC])\n"
        "    Project(exprs=[ColRef(k), ColRef(v)])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t ORDER BY k DESC NULLS FIRST",
        "Sort(keys=[k DESC NULLS FIRST])\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t ORDER BY k ASC",
        "Sort(keys=[k ASC])\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t LIMIT 2 OFFSET 1",
        "Limit(n=2, offset=1)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t OFFSET 1",
        "ERR: SQL not supported: OFFSET without LIMIT — this dialect honours an OFFSET only as part of a row window, so write `LIMIT <n> OFFSET 1` with an explicit row count. (Refused rather than ignored: silently dropping the OFFSET would return every row.)"
    )
    _check(
        "SELECT k, v FROM t ORDER BY k LIMIT 5 OFFSET 2",
        "Limit(n=5, offset=2)\n"
        "  Sort(keys=[k ASC])\n"
        "    Project(exprs=[ColRef(k), ColRef(v)])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM t ORDER BY k LIMIT 2",
        "Limit(n=2)\n"
        "  Sort(keys=[k ASC])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT DISTINCT k FROM t",
        "Distinct(all)\n"
        "  Project(exprs=[ColRef(k)])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_window_star_arguments_and_order_alias_refs() raises:
    _check(
        "SELECT sum(*) OVER () FROM t",
        "ERR: SQL bind error: window aggregate requires an argument column (only COUNT(*) OVER may omit it)"
    )
    _check(
        "SELECT max(*) OVER (ORDER BY k) FROM t",
        "ERR: SQL bind error: window aggregate requires an argument column (only COUNT(*) OVER may omit it)"
    )
    _check(
        "SELECT k * 2 AS dbl FROM t ORDER BY dbl * 2",
        "ERR: SQL not supported: the ORDER BY expression names the SELECT alias `dbl`, which is not an input column. DuckDB substitutes the aliased expression; this binder does not yet. Repeat the aliased expression in ORDER BY, or order by the alias alone (`ORDER BY dbl`)."
    )
    _check(
        "SELECT k * 2 AS dbl FROM t ORDER BY -dbl",
        "ERR: SQL not supported: the ORDER BY expression names the SELECT alias `dbl`, which is not an input column. DuckDB substitutes the aliased expression; this binder does not yet. Repeat the aliased expression in ORDER BY, or order by the alias alone (`ORDER BY dbl`)."
    )
    _check(
        "SELECT k * 2 AS dbl FROM t ORDER BY abs(dbl)",
        "ERR: SQL not supported: the ORDER BY expression names the SELECT alias `dbl`, which is not an input column. DuckDB substitutes the aliased expression; this binder does not yet. Repeat the aliased expression in ORDER BY, or order by the alias alone (`ORDER BY dbl`)."
    )
    _check(
        "SELECT k * 2 AS dbl FROM t ORDER BY CASE WHEN dbl > 1 THEN 1 ELSE 0 END",
        "ERR: SQL not supported: the ORDER BY expression names the SELECT alias `dbl`, which is not an input column. DuckDB substitutes the aliased expression; this binder does not yet. Repeat the aliased expression in ORDER BY, or order by the alias alone (`ORDER BY dbl`)."
    )
    _check(
        "SELECT k * 2 AS dbl FROM t ORDER BY CASE WHEN k > 1 THEN dbl ELSE 0 END",
        "ERR: SQL not supported: the ORDER BY expression names the SELECT alias `dbl`, which is not an input column. DuckDB substitutes the aliased expression; this binder does not yet. Repeat the aliased expression in ORDER BY, or order by the alias alone (`ORDER BY dbl`)."
    )
    _check(
        "SELECT k * 2 AS dbl FROM t ORDER BY CASE WHEN k > 1 THEN 1 ELSE dbl END",
        "ERR: SQL not supported: the ORDER BY expression names the SELECT alias `dbl`, which is not an input column. DuckDB substitutes the aliased expression; this binder does not yet. Repeat the aliased expression in ORDER BY, or order by the alias alone (`ORDER BY dbl`)."
    )
    _check(
        "SELECT k * 2 AS dbl FROM t ORDER BY k + 1, CASE WHEN k > 1 THEN 1 ELSE 0 END",
        "Project(exprs=[ColRef(dbl)])\n"
        "  Sort(keys=[__order_key_0 ASC, __order_key_1 ASC])\n"
        "    Project(exprs=[Alias(BinaryOp(MUL, ColRef(k), Literal(ScalarValue(int64, 2))), \"dbl\"), Alias(BinaryOp(ADD, ColRef(k), Literal(ScalarValue(int64, 1))), \"__order_key_0\"), Alias(When(WHEN BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(int64, 1)), ELSE Literal(ScalarValue(int64, 0))), \"__order_key_1\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k * 2 AS dbl FROM t ORDER BY abs(k), k - 1",
        "Project(exprs=[ColRef(dbl)])\n"
        "  Sort(keys=[__order_key_0 ASC, __order_key_1 ASC])\n"
        "    Project(exprs=[Alias(BinaryOp(MUL, ColRef(k), Literal(ScalarValue(int64, 2))), \"dbl\"), Alias(UnaryOp(ABS, ColRef(k)), \"__order_key_0\"), Alias(BinaryOp(SUB, ColRef(k), Literal(ScalarValue(int64, 1))), \"__order_key_1\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k * 2 AS dbl FROM t ORDER BY k * 2 + dbl",
        "ERR: SQL not supported: the ORDER BY expression names the SELECT alias `dbl`, which is not an input column. DuckDB substitutes the aliased expression; this binder does not yet. Repeat the aliased expression in ORDER BY, or order by the alias alone (`ORDER BY dbl`)."
    )
    _check(
        "SELECT max(k) FROM t ORDER BY max(k)",
        "Sort(keys=[max(k) ASC])\n"
        "  Project(exprs=[ColRef(max(k))])\n"
        "    Aggregate(group_by=[], aggs=[MAX(ColRef(k)).alias(\"max(k)\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k AS w, count(*) FROM t GROUP BY k ORDER BY w * 2",
        "ERR: SQL not supported: the ORDER BY expression names the SELECT alias `w`, which is not an input column. DuckDB substitutes the aliased expression; this binder does not yet. Repeat the aliased expression in ORDER BY, or order by the alias alone (`ORDER BY w`)."
    )
    _check(
        "SELECT k, rank() OVER (ORDER BY k) AS r FROM t ORDER BY 2",
        "Sort(keys=[r ASC])\n"
        "  Project(exprs=[ColRef(k), ColRef(r)])\n"
        "    PartitionBy(partition=[], order=[k ASC], funcs=[RANK(, offset=0, frame=RANGE[0:0..2:0]) AS r])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT s, k FROM t ORDER BY 2 LIMIT 3",
        "Limit(n=3)\n"
        "  Sort(keys=[k ASC])\n"
        "    Project(exprs=[ColRef(s), ColRef(k)])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

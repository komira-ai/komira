# =============================================================================
# Direct tests of subquery binding: scalar, [NOT] EXISTS, [NOT] IN
# (sql_bind_subquery, sql_binder)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. A scalar subquery binds to an uncorrelated CORR_KIND_SCALAR (kind=2)
#      expression; one projecting two columns is refused.
#   2. EXISTS binds to CORR_KIND_EXISTS (kind=0), NOT EXISTS to
#      CORR_KIND_NOT_EXISTS (kind=1), IN to EXISTS with the membership equi
#      folded in; the outer references are recorded (`outer_refs=#n`).
#      (mutant: CORR_KIND_EXISTS and CORR_KIND_NOT_EXISTS swapped)
#   3. NOT IN is NULL-aware: an uncorrelated body adds the "no NULL y" and
#      "S is empty" scalar checks, a correlated one the two extra anti
#      joins; a body correlated only by a non-equality is refused.
#      (mutant: the `y_null_free and lhs_null_free` early return taken
#      unconditionally)
#   4. The correlated-predicate binder: inner vs outer columns by
#      qualifier, the operators it binds, the constant-folded date_diff,
#      and its refusals (another function, an aggregate, `*`, a dangling
#      index); body-shape refusals (multi-table FROM, GROUP BY / ORDER BY /
#      LIMIT / OFFSET, an IN body not projecting one bare column).

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

def test_scalar_subqueries() raises:
    _check(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(v), CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2)))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u) + 1",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(v), BinaryOp(ADD, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 1)))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE (SELECT count(*) FROM u) > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT (SELECT max(w) FROM u) AS mx FROM t",
        "Project(exprs=[Alias(CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), \"mx\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k = (SELECT max(w) FROM u WHERE u.k = 1)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(k), CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2)))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k = (SELECT k, w FROM u)",
        "ERR: SQL bind error: a scalar subquery must project exactly one column (got 2)"
    )
    _check(
        "SELECT k FROM t WHERE (SELECT max(w) FROM u WHERE u.k = t.k) > 1",
        "ERR: SQL bind error: unknown column 't.k'"
    )


def test_exists_and_in() raises:
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE NOT EXISTS (SELECT 1 FROM u WHERE u.k = t.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k IN (SELECT k FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k IN (SELECT k FROM u WHERE u.w = t.g)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#2, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k IN (SELECT k FROM u WHERE u.w IN (SELECT w FROM u))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u x WHERE x.k = t.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t AS o WHERE EXISTS (SELECT 1 FROM u WHERE u.k = o.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM t WHERE t.k = 1)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#0, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.k = t.g)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#2, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT * FROM u WHERE u.k = t.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "WITH c AS (SELECT k FROM t WHERE k IN (SELECT k FROM u)) SELECT k FROM c",
        "ERR: SQL bind error: dangling scalar-subquery index"
    )


def test_not_in_is_null_aware() raises:
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT w FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM u WHERE u.w = t.g)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#2, inner_tag=1), BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), CorrelatedSubquery(kind=1, outer_refs=#2, inner_tag=1))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM u WHERE u.w = t.g AND u.s = t.s)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#3, inner_tag=1), BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#2, inner_tag=1), CorrelatedSubquery(kind=1, outer_refs=#3, inner_tag=1))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM u WHERE u.k = t.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM u WHERE u.w > t.g)",
        "ERR: SQL not supported: `x NOT IN (SELECT y ...)` whose subquery is correlated only by a NON-EQUALITY predicate (e.g. `R.rv > L.lv`). NOT IN is NULL-aware — a NULL y, or a NULL x, changes the answer for that outer row — and this engine checks both per row with anti joins keyed on an EQUALITY correlation (`R.a = L.b`), which this subquery does not have. Add one, or — if neither column can hold a NULL — write `NOT EXISTS (SELECT 1 FROM ... WHERE ... AND y = x)`, which is the same query exactly when there are no NULLs (NOT EXISTS is not NULL-aware)."
    )
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM u) AND g NOT IN (SELECT w FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))), BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(g)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE NOT (k IN (SELECT k FROM u))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=UnaryOp(NOT, CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1)))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM u) OR k = 1",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(OR, BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))), BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 1)))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t, u WHERE t.k NOT IN (SELECT k FROM kk)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT t.k FROM t, u WHERE t.k NOT IN (SELECT k FROM kk) AND t.k = u.k",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))), BinaryOp(EQ, ColRef(k), ColRef(k_right))))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT s FROM t WHERE s NOT IN (SELECT s FROM u)",
        "Project(exprs=[ColRef(s)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(s)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_correlated_predicate_binder() raises:
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.w > t.v)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.s LIKE 'a%' AND u.k = t.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.s ILIKE 'a%')",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE date_diff('day', DATE '2021-01-01', DATE '2021-02-01') > u.w AND u.k = t.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.w > (SELECT max(w) FROM u))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE NOT (u.k = t.k))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.w IS NULL)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.w / 2 > 1)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#0, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.w = 1.5 AND u.s = 'x' AND true)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.w > DATE '2021-01-01')",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.w > TIMESTAMP '2021-01-01')",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND -u.w > 1)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.w * 2 > t.g)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#2, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.w = 18446744073709551615)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.w = NULL)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_correlated_predicate_refusals() raises:
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE upper(u.s) = 'A' AND u.k = t.k)",
        "ERR: SQL not supported: scalar function 'upper' inside a correlated subquery predicate"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE sum(u.w) > 1 AND u.k = t.k)",
        "ERR: SQL not supported: aggregate inside a correlated subquery predicate"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND u.zz = 1)",
        "ERR: SQL bind error: unknown column 'zz' in correlated subquery"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND CASE WHEN u.w > 1 THEN true ELSE false END)",
        "ERR: SQL bind error: unsupported expression in correlated subquery"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u, kk WHERE u.k = t.k)",
        "ERR: SQL not supported: a predicate subquery must have a single-table FROM"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k ORDER BY k)",
        "ERR: SQL not supported: GROUP BY / HAVING / ORDER BY / LIMIT / OFFSET / DISTINCT inside a predicate subquery"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k LIMIT 1)",
        "ERR: SQL not supported: GROUP BY / HAVING / ORDER BY / LIMIT / OFFSET / DISTINCT inside a predicate subquery"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k GROUP BY u.k)",
        "ERR: SQL not supported: GROUP BY / HAVING / ORDER BY / LIMIT / OFFSET / DISTINCT inside a predicate subquery"
    )
    _check(
        "SELECT k FROM t WHERE k IN (SELECT k FROM u OFFSET 3)",
        "ERR: SQL not supported: GROUP BY / HAVING / ORDER BY / LIMIT / OFFSET / DISTINCT inside a predicate subquery"
    )
    _check(
        "SELECT k FROM t WHERE k IN (SELECT k, w FROM u)",
        "ERR: SQL bind error: an IN subquery must project exactly one column"
    )
    _check(
        "SELECT k FROM t WHERE k IN (SELECT k + 1 FROM u)",
        "ERR: SQL bind error: an IN subquery must project a single bare column"
    )
    _check(
        "SELECT k FROM t WHERE k IN (SELECT * FROM u)",
        "ERR: SQL bind error: an IN subquery must project a single bare column"
    )


def test_correlated_predicate_edges() raises:
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.w / t.g > 1 AND u.k = t.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#2, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.w + 18446744073709551615 > 0 AND u.k = t.k)",
        "ERR: SQL not supported: the integer literal 18446744073709551615 is past BIGINT (9223372036854775807). DuckDB types it HUGEINT, a type this engine has no literal or column for; it is served only as one side of a comparison (= <> < <= > >=) against a plain column, when it fits UBIGINT (<= 18446744073709551615)."
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.w + NULL > 0 AND u.k = t.k)",
        "ERR: SQL not supported: a NULL literal is served as a comparison operand (`x = NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64 or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one; anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other function argument, arithmetic, a CASE or COALESCE whose EVERY value is NULL) it needs a typed NULL value this engine's plan does not carry"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE NULL = u.w AND u.k = t.k)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE NULL = NULL AND u.k = t.k)",
        "ERR: SQL not supported: a NULL literal is served as a comparison operand (`x = NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64 or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one; anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other function argument, arithmetic, a CASE or COALESCE whose EVERY value is NULL) it needs a typed NULL value this engine's plan does not carry"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k AND * = 1)",
        "ERR: SQL bind error: '*' not allowed in a correlated subquery predicate"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#0, inner_tag=0))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE date_diff('day', DATE '2021-01-01') > u.w AND u.k = t.k)",
        "ERR: SQL bind error: date_diff expects 3 arguments (unit, start, end)"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE date_diff('month', DATE '2021-01-01', DATE '2021-02-01') > u.w AND u.k = t.k)",
        "ERR: SQL not supported: only date_diff('day', ...) is supported (got unit that is not the constant 'day')"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE date_diff('day', DATE '2021-01-01', t.d) > u.w AND u.k = t.k)",
        "ERR: SQL not supported: date_diff('day', a, b) requires constant DATE literal operands INSIDE A CORRELATED SUBQUERY PREDICATE. ⚠ THIS IS A LIMIT OF THIS POSITION, NOT OF date_diff: in an ordinary projection or filter it reads DATE columns. The correlated-predicate binder binds no column operand here and can only constant-fold"
    )
    _check(
        "SELECT * FROM t WHERE k IN (SELECT k FROM u) AND v > (SELECT max(w) FROM u)",
        "Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1), BinaryOp(GT, ColRef(v), CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2))))\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_not_in_null_freedom_proof_edges() raises:
    # The NOT IN proof needs the NOT IN in the statement's own WHERE, no outer
    # join, and one relation owning the column; a column no relation has is
    # refused when the query binds.
    _check(
        "SELECT k FROM t GROUP BY k HAVING k NOT IN (SELECT k FROM u)",
        "ERR: SQL bind error: unsupported expression"
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
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# Direct tests of declared-UDF calls and of the bound statement
# (sql_bind_call, sql_binder)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. A call to a declared UDF binds to an `EXPR_UDF_CALL` carrying the
#      UDF's name, handle and both types, over any argument expression; a
#      UDF declared under a name the function table refuses resolves in
#      place of the refusal.
#      (mutant: the UDF step keyed on `kind == FNK_NONE`, so `nextafter`
#      keeps raising its refusal)
#   2. A UDF call with two arguments, or an argument of another type, is
#      refused by name; the unknown-function error lists the declared UDFs.
#      (mutant: the argument-type check removed, so `affine(v)` binds)
#   3. `BoundStatement` carries the statement kind, a COPY's destination and
#      format, and a CTAS's table name.
#      (mutant: STMT_COPY's `dest_path` not passed through)
#   4. Shapes the parser never builds (an empty COPY destination or CTAS
#      name, an unknown join kind, a SELECT with no FROM relation) are
#      refused by name.

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
from komira_plan_expr.declared_scalar_udf import DeclaredScalarUdf
from komira_sql.sql_ast import STMT_COPY, STMT_CREATE_TABLE_AS, STMT_QUERY, SqlStatement


@fieldwise_init
struct _Udf(DeclaredScalarUdf):
    """A declared-UDF stand-in: INT64 -> FLOAT64, a name and a handle."""

    comptime IN_TYPE: ArrowType = ArrowType.INT64
    comptime OUT_TYPE: ArrowType = ArrowType.FLOAT64

    var _name: String
    var _handle: Int

    def handle(self) -> Int:
        return self._handle

    def name(self) -> String:
        return self._name.copy()


def _udf_got(sql: String) raises -> String:
    """`_got` over a catalog declaring `affine` and `nextafter` (a name the
    function table refuses) as UDFs."""
    var cat = _catalog()
    cat.declare_udf(_Udf(String("affine"), 7))
    cat.declare_udf(_Udf(String("nextafter"), 9))
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _bind_err(var stmt: SqlStatement) raises -> String:
    var cat = _catalog()
    try:
        _ = bind_statement(stmt, cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal")


def test_declared_udfs_bind_to_udf_calls() raises:
    assert_equal(
        _udf_got("SELECT affine(k) AS y FROM t"),
        "Project(exprs=[Alias(UdfCall(name=affine, h=7, in=5, out=12, ColRef(k)), \"y\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )
    # The argument's type is read off any expression, not only a column.
    assert_equal(
        _udf_got("SELECT affine(k + 1) FROM t"),
        "Project(exprs=[UdfCall(name=affine, h=7, in=5, out=12, BinaryOp(ADD,"
        " ColRef(k), Literal(ScalarValue(int64, 1))))])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )
    # A UDF declared under a name the function table refuses resolves.
    assert_equal(
        _udf_got("SELECT nextafter(k) FROM t"),
        "Project(exprs=[UdfCall(name=nextafter, h=9, in=5, out=12, ColRef(k))])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_udf_refusals() raises:
    assert_equal(
        _udf_got("SELECT affine(k, k) FROM t"),
        "ERR: SQL bind error: UDF 'affine' takes exactly 1 argument, got 2. A"
        " declared scalar UDF is unary (it has one argument type), so there is"
        " no form of this UDF that could accept 2.",
    )
    assert_equal(
        _udf_got("SELECT affine(v) FROM t"),
        "ERR: SQL bind error: UDF 'affine' is registered for an argument of"
        " type int64 but was applied to an expression of type float64. ⛔"
        " REFUSED RATHER THAN COERCED: the per-batch UDF ABI is byte-oriented"
        " and carries no schema, so passing these bytes would REINTERPRET them"
        " as int64 rather than fail — a wrong answer with a success code. Add"
        " an explicit CAST if that is what you meant.",
    )
    # The unknown-function error lists the declared UDFs.
    assert_equal(
        _udf_got("SELECT nosuch(k) FROM t"),
        "ERR: SQL not supported: scalar function 'nosuch'. It is not a"
        " built-in and no UDF is declared under that name. Declared UDFs:"
        " affine, nextafter",
    )
    assert_equal(
        _udf_got("SELECT k, affine(sum(k)) FROM t GROUP BY k"),
        "ERR: SQL not supported: scalar function 'affine' applied to an"
        " aggregate result. The aggregate itself is allowed in this position —"
        " `HAVING SUM(v) > 10` binds; what this engine cannot lower yet is a"
        " call WRAPPING one, outside the math families whose aggregate"
        " arguments it hoists",
    )
    assert_equal(
        _udf_got("SELECT k, affine(k) FROM t GROUP BY k"),
        "ERR: SQL not supported: non-aggregate SELECT item must be a GROUP BY"
        " column",
    )


def test_bound_statement_carries_its_kind_and_targets() raises:
    var cat = _catalog()
    var q = bind_statement(
        parse_sql(tokenize("SELECT k FROM t")), cat, NoParquetFooters()
    )
    assert_equal(Int(q.kind), Int(STMT_QUERY))
    assert_equal(q.dest_path, "")
    assert_equal(q.register_as, "")
    var c = bind_statement(
        parse_sql(tokenize("COPY (SELECT k FROM t) TO 'out.parquet'")),
        cat,
        NoParquetFooters(),
    )
    assert_equal(Int(c.kind), Int(STMT_COPY))
    assert_equal(c.dest_path, "out.parquet")
    assert_equal(Int(c.fmt), 0)
    assert_equal(Int(c.codec), 0)
    assert_equal(c.register_as, "")
    var z = bind_statement(
        parse_sql(tokenize("CREATE TABLE z AS SELECT k FROM t")),
        cat,
        NoParquetFooters(),
    )
    assert_equal(Int(z.kind), Int(STMT_CREATE_TABLE_AS))
    assert_equal(z.dest_path, "")
    assert_equal(z.register_as, "z")
    assert_equal(
        String(z.take_plan()),
        "Project(exprs=[ColRef(k)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_statement_shapes_the_parser_never_builds() raises:
    var c = parse_sql(tokenize("COPY (SELECT k FROM t) TO 'out.parquet'"))
    c.dest_path = String("")
    assert_equal(
        _bind_err(c^), "SQL bind error: COPY ... TO requires a destination path"
    )
    var z = parse_sql(tokenize("CREATE TABLE z AS SELECT k FROM t"))
    z.target_table = String("")
    assert_equal(
        _bind_err(z^),
        "SQL bind error: CREATE TABLE AS requires a target table name",
    )
    var j = parse_sql(tokenize("SELECT * FROM kk JOIN mm ON kk.k = mm.k"))
    j.query.joins[0].kind = 99
    assert_equal(
        _bind_err(j^),
        "SQL not supported: join kind 99 has no lowering in _bind_select —"
        " this is a binder gap, not a query error. Every JK_* kind must name"
        " its arm.",
    )
    var f = parse_sql(tokenize("SELECT k FROM t"))
    f.query.from_tables.clear()
    assert_equal(_bind_err(f^), "SQL bind error: FROM clause has no tables")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

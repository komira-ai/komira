# =============================================================================
# Tests of declared scalar UDF calls (sql_bind_call)
# =============================================================================
#
# The catalog declares `affine` and `nextafter` (a name the function table
# refuses) as INT64 -> FLOAT64 UDFs. Each query is parsed and its select items
# and WHERE predicate are bound with `_bind_scalar`.
#   1. A call binds to a UDF node carrying the declared handle and types; the
#      argument's type is read off any expression, not only a column; a UDF
#      declared under a refused name resolves in place of the refusal.
#   2. A wrong argument count, an argument of another type, an unknown name
#      (listing the declared UDFs) and an aggregate call in a scalar position
#      are refused by name.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.declared_scalar_udf import DeclaredScalarUdf
from komira_plan_expr.expr import Expr

from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_parquet import ParquetFacts
from komira_sql.sql_bind_scope import CteScope, _build_bind_scope
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


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
    (no file is opened)."""
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
    return cat^


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


def _got(sql: String) raises -> String:
    """Parse `sql` (one SELECT over one table), bind every select item and
    the WHERE predicate with `_bind_scalar` against the table's schema, and
    return the Project / Filter / Scan text of the result, or `ERR: ` and the
    binder's message."""
    var cat = _catalog()
    cat.declare_udf(_Udf(String("affine"), 7))
    cat.declare_udf(_Udf(String("nextafter"), 9))
    try:
        var st = parse_sql(tokenize(sql))
        var scope = _build_bind_scope(
            st.query.from_tables, st.query.joins, cat, CteScope(ParquetFacts())
        )
        var prebound = List[Expr]()
        var items = String("")
        for i in range(len(st.query.select_items)):
            ref item = st.query.select_items[i]
            var e = _bind_scalar(
                item.expr, scope.out_schema, scope, cat, CteScope(ParquetFacts()), prebound
            )
            if item.out_alias:
                e = Expr.alias(e^, item.out_alias.value())
            if i > 0:
                items += ", "
            items += String(e)
        var out = "Project(exprs=[" + items + "])\n"
        var pad = String("  ")
        if st.query.where_pred:
            var p = _bind_scalar(
                st.query.where_pred.value(), scope.out_schema, scope, cat,
                CteScope(ParquetFacts()), prebound,
            )
            out += pad + "Filter(predicate=" + String(p) + ")\n"
            pad += "  "
        return out + pad + "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


def test_declared_udfs_bind_to_udf_calls() raises:
    _check(
        "SELECT affine(k) AS y FROM t",
        "Project(exprs=[Alias(UdfCall(name=affine, h=7, in=5, out=12, ColRef(k)), \"y\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )
    _check(
        "SELECT affine(k + 1) FROM t",
        "Project(exprs=[UdfCall(name=affine, h=7, in=5, out=12, BinaryOp(ADD,"
        " ColRef(k), Literal(ScalarValue(int64, 1))))])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )
    _check(
        "SELECT nextafter(k) FROM t",
        "Project(exprs=[UdfCall(name=nextafter, h=9, in=5, out=12, ColRef(k))])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_udf_refusals() raises:
    _check(
        "SELECT affine(k, k) FROM t",
        "ERR: SQL bind error: UDF 'affine' takes exactly 1 argument, got 2. A"
        " declared scalar UDF is unary (it has one argument type), so there is"
        " no form of this UDF that could accept 2.",
    )
    _check(
        "SELECT affine(v) FROM t",
        "ERR: SQL bind error: UDF 'affine' is registered for an argument of"
        " type int64 but was applied to an expression of type float64."
        " REFUSED RATHER THAN COERCED: the per-batch UDF ABI is byte-oriented"
        " and carries no schema, so passing these bytes would REINTERPRET them"
        " as int64 rather than fail — a wrong answer with a success code. Add"
        " an explicit CAST if that is what you meant.",
    )
    _check(
        "SELECT nosuch(k) FROM t",
        "ERR: SQL not supported: scalar function 'nosuch'. It is not a"
        " built-in and no UDF is declared under that name. Declared UDFs:"
        " affine, nextafter",
    )
    _check(
        "SELECT sum(k) FROM t WHERE affine(k) > 1.0",
        "ERR: SQL bind error: aggregate function not allowed in this position",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

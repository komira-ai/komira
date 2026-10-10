# =============================================================================
# Direct tests of komira_sql's parser (sql_parser), table catalog
# (sql_catalog) and UDF catalog (sql_udf_catalog)
# =============================================================================
#
# What each test proves, and the defect (mutant) it catches:
#   1. parse_sql turns `LEFT JOIN ... ON` into a JK_LEFT JoinClause that keeps
#      its ON predicate (nothing folded into WHERE), a plain `JOIN ... ON` into
#      JK_CROSS with the ON folded into WHERE, `SEMI JOIN ... ON` into JK_SEMI
#      with the predicate kept, and `JOIN ... USING (k, j)` into a keyed
#      JK_CROSS clause whose `using_cols` are the listed names.
#      (mutant caught: the LEFT arm sets JK_CROSS, so the ON is folded into
#      WHERE and the clause reads JK_CROSS)
#   2. parse_sql raises a `SQL syntax error` on an unclosed parenthesis and
#      on a FROM with no table. `SELECT FROM t` is NOT a syntax error here:
#      it parses as the column `from` aliased `t` over the FROM-less relation
#      (the binder refuses the unknown column later); the test pins that.
#   3. SqlCatalog.add_parquet(name, path, schema) with a given schema opens
#      no file: has(), schema_of() and table_of() resolve the name in any
#      case, an unknown table raises `unknown table`, and build_scan() is a
#      parquet scan whose output schema is the registered one.
#      (mutant caught: SqlCatalog._find compares `name` without `.lower()`)
#   4. SqlUdfCatalog.declare: `My_Fn` resolves as `my_fn` and keeps its
#      display name, handle and both types; re-declaring the folded name
#      replaces the entry (num_declared stays 1); `upper`, a builtin that
#      lowers, is refused and leaves the catalog unchanged; `nextafter`, a
#      refusal row of the function table, is declarable.
#      (mutants caught: refuse_undeclarable_udf_name tests
#      `kind != FNK_NONE` instead of `lowers_to_a_node`, which refuses
#      `nextafter`; declare() appends instead of replacing, so num_declared
#      reads 2)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.declared_scalar_udf import DeclaredScalarUdf

from komira_sql.sql_token import tokenize
from komira_sql.sql_ast import (
    SqlStatement,
    FROM_LESS_RELATION,
    JK_CROSS,
    JK_LEFT,
    JK_SEMI,
    SXOP_EQ,
    SX_BINARY,
    SX_COLUMN,
)
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_fn_table import sql_scalar_fn_spec, FNK_REFUSED
from komira_sql.sql_udf_catalog import SqlUdfCatalog
from komira_sql.sql_catalog import SqlCatalog


@fieldwise_init
struct _TestUdf(DeclaredScalarUdf):
    """A registered-UDF stand-in: the trait's four facts, nothing else."""

    comptime IN_TYPE: ArrowType = ArrowType.INT64
    comptime OUT_TYPE: ArrowType = ArrowType.FLOAT64

    var _name: String
    var _handle: Int

    def handle(self) -> Int:
        return self._handle

    def name(self) -> String:
        return self._name.copy()


def _parse(sql: String) raises -> SqlStatement:
    return parse_sql(tokenize(sql))


def _err(sql: String) raises -> String:
    try:
        _ = _parse(sql)
    except e:
        return String(e)
    raise Error("parsed, expected a refusal: " + sql)


def _schema_kv() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.STRING, True))
    return sb.build()


def _assert_kv(s: Schema) raises:
    assert_equal(s.num_columns(), 2)
    assert_equal(s.field_name(0), "k")
    assert_equal(s.field_name(1), "v")
    assert_true(s.field_arrow_type(0) == ArrowType.INT64)
    assert_true(s.field_arrow_type(1) == ArrowType.STRING)
    assert_false(s.field_nullable(0))
    assert_true(s.field_nullable(1))


def test_join_kinds_on_and_using_parse_to_their_clauses() raises:
    # LEFT JOIN ... ON: the predicate stays on the clause, WHERE stays empty.
    var left = _parse("SELECT * FROM a LEFT JOIN b ON a.k = b.k")
    assert_equal(len(left.query.from_tables), 2)
    assert_equal(left.query.from_tables[1].name, "b")
    assert_equal(len(left.query.joins), 1)
    assert_equal(Int(left.query.joins[0].kind), Int(JK_LEFT))
    assert_true(Bool(left.query.joins[0].on_pred))
    ref on = left.query.joins[0].on_pred.value()
    assert_equal(Int(on.tag), Int(SX_BINARY))
    assert_equal(Int(on.op), Int(SXOP_EQ))
    assert_equal(on._binary.value().left[].qualifier, "a")
    assert_equal(on._binary.value().right[].qualifier, "b")
    assert_false(Bool(left.query.where_pred))
    # Plain JOIN ... ON: JK_CROSS with the ON folded into WHERE.
    var plain = _parse("SELECT * FROM a JOIN b ON a.k = b.k")
    assert_equal(Int(plain.query.joins[0].kind), Int(JK_CROSS))
    assert_false(Bool(plain.query.joins[0].on_pred))
    assert_true(Bool(plain.query.where_pred))
    assert_equal(Int(plain.query.where_pred.value().op), Int(SXOP_EQ))
    # SEMI JOIN ... ON: JK_SEMI, the predicate kept on the clause.
    var semi = _parse("SELECT * FROM a SEMI JOIN b ON a.k = b.k")
    assert_equal(Int(semi.query.joins[0].kind), Int(JK_SEMI))
    assert_true(Bool(semi.query.joins[0].on_pred))
    assert_false(Bool(semi.query.where_pred))
    assert_false(semi.query.joins[0].natural)
    # JOIN ... USING (k, j): a keyed JK_CROSS clause, nothing in WHERE.
    var using = _parse("SELECT * FROM a JOIN b USING (k, j)")
    assert_equal(Int(using.query.joins[0].kind), Int(JK_CROSS))
    assert_equal(len(using.query.joins[0].using_cols), 2)
    assert_equal(using.query.joins[0].using_cols[0], "k")
    assert_equal(using.query.joins[0].using_cols[1], "j")
    assert_false(Bool(using.query.joins[0].on_pred))
    assert_false(Bool(using.query.where_pred))


def test_syntax_errors_raise_and_select_from_t_is_a_column() raises:
    var unclosed = _err("SELECT (a FROM t")
    assert_true(unclosed.startswith("SQL syntax error"), unclosed)
    assert_true("expected ')'" in unclosed, unclosed)
    var no_table = _err("SELECT a FROM")
    assert_true(no_table.startswith("SQL syntax error"), no_table)
    assert_true("expected table name in FROM" in no_table, no_table)
    # `SELECT FROM t`: `from` is an ordinary identifier in the select list
    # and `t` its implicit alias; the select list then ends the body, so
    # the relation is the FROM-less one.
    var st = _parse("SELECT FROM t")
    assert_equal(len(st.query.select_items), 1)
    assert_equal(Int(st.query.select_items[0].expr.tag), Int(SX_COLUMN))
    assert_equal(st.query.select_items[0].expr.text, "from")
    assert_equal(st.query.select_items[0].out_alias.value(), "t")
    assert_equal(st.query.from_tables[0].name, String(FROM_LESS_RELATION))


def test_catalog_add_parquet_resolves_case_insensitively() raises:
    var cat = SqlCatalog()
    cat.add_parquet(String("Orders"), String("data/orders.parquet"), _schema_kv())
    assert_true(cat.has(String("orders")))
    assert_true(cat.has(String("ORDERS")))
    assert_true(cat.has(String("Orders")))
    assert_false(cat.has(String("lineitem")))
    _assert_kv(cat.schema_of(String("oRdErS")))
    var t = cat.table_of(String("ORDERS"))
    assert_equal(t.name, "orders")
    _assert_kv(t.schema)
    assert_equal(t.source.kind_name(), "parquet")
    try:
        _ = cat.schema_of(String("lineitem"))
        raise Error("schema_of resolved an unknown table")
    except e:
        assert_true("unknown table 'lineitem'" in String(e), String(e))
    try:
        _ = cat.table_of(String("nope"))
        raise Error("table_of resolved an unknown table")
    except e:
        assert_true("unknown table 'nope'" in String(e), String(e))
    try:
        _ = cat.build_scan(String("nope"))
        raise Error("build_scan resolved an unknown table")
    except e:
        assert_true("unknown table 'nope'" in String(e), String(e))
    var plan = cat.build_scan(String("ORDERS"))
    assert_true(plan.is_scan())
    _assert_kv(plan.output_schema)
    assert_equal(plan.scan_data_ref().source.kind_name(), "parquet")
    _assert_kv(plan.scan_data_ref().source.schema())


def test_udf_catalog_folds_replaces_and_refuses_only_lowering_names() raises:
    var udfs = SqlUdfCatalog()
    assert_equal(udfs.num_declared(), 0)
    udfs.declare(_TestUdf(String("My_Fn"), 11))
    assert_equal(udfs.num_declared(), 1)
    assert_true(udfs.has(String("my_fn")))
    assert_true(udfs.has(String("MY_FN")))
    var e = udfs.resolve(String("my_fn"))
    assert_true(Bool(e))
    assert_equal(e.value().name, "my_fn")
    assert_equal(e.value().display_name, "My_Fn")
    assert_equal(e.value().handle, 11)
    assert_true(e.value().in_type == ArrowType.INT64)
    assert_true(e.value().out_type == ArrowType.FLOAT64)
    # Re-declaring the folded name replaces the entry in place.
    udfs.declare(_TestUdf(String("MY_FN"), 12))
    assert_equal(udfs.num_declared(), 1)
    assert_equal(udfs.resolve(String("My_Fn")).value().handle, 12)
    assert_equal(udfs.resolve(String("My_Fn")).value().display_name, "MY_FN")
    # `upper` lowers to an expression node: refused, nothing recorded.
    assert_true(sql_scalar_fn_spec(String("upper")).lowers_to_a_node)
    try:
        udfs.declare(_TestUdf(String("Upper"), 13))
        raise Error("declared a name the binder lowers")
    except err:
        var m = String(err)
        assert_true("'Upper' is a built-in scalar function THE BINDER LOWERS" in m, m)
    assert_equal(udfs.num_declared(), 1)
    assert_false(udfs.has(String("upper")))
    # `nextafter` is a refusal row: it has a row but lowers to nothing.
    var nx = sql_scalar_fn_spec(String("nextafter"))
    assert_equal(Int(nx.kind), Int(FNK_REFUSED))
    assert_false(nx.lowers_to_a_node)
    udfs.declare(_TestUdf(String("nextafter"), 14))
    assert_equal(udfs.num_declared(), 2)
    var names = udfs.declared_names()
    assert_equal(len(names), 2)
    assert_equal(names[0], "MY_FN")
    assert_equal(names[1], "nextafter")
    assert_false(Bool(udfs.resolve(String("no_such_udf"))))
    assert_false(udfs.has(String("no_such_udf")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

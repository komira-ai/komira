# =============================================================================
# sql_frontend: statement kinds and refusals from SQL text
# =============================================================================
#
# Every statement binds against a catalog of parquet tables registered with a
# given schema (`add_parquet` opens no file), so no test reads a file. What
# each test proves:
#   * test_statement_kinds_from_text: `statement_from_sql` gives a query
#     STMT_QUERY, `COPY (query) TO 'out.csv' (FORMAT csv)` STMT_COPY with its
#     destination, and `CREATE TABLE x AS query` STMT_CREATE_TABLE_AS with its
#     table name, each with the source query's plan.
#   * test_plan_from_sql_refuses_a_write_by_name: `plan_from_sql` refuses a
#     COPY and a CREATE TABLE AS with the whole STATEMENT_NOT_A_QUERY message,
#     and `query_plan` gives the same refusal over a bound COPY and the plan of
#     a bound query.
#   * test_lex_and_parse_failures_raise_their_own_message: a misspelt keyword,
#     an unterminated string, an empty text and a trailing token raise the
#     tokenizer's or parser's `SQL syntax error`.
#   * test_bind_failures_raise_their_own_message: an unknown table, column and
#     function raise the binder's whole message, unchanged by the entry; a
#     CAST of a column to DECIMAL and a CAST over an aggregate are refused by
#     name.
#   * test_the_footer_reader_is_the_callers: a `read_parquet` relation takes
#     its schema from the reader the caller passes, the reader's own failure is
#     the statement's failure, and `NoParquetFooters` refuses the relation by
#     name.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.write_target import WFMT_CSV

from sql.sql_ast import STMT_COPY, STMT_CREATE_TABLE_AS, STMT_QUERY
from sql.sql_bind_parquet import NoParquetFooters, SqlParquetFooters
from sql.sql_catalog import SqlCatalog
from scan_source.parquet_source import ParquetSource
from sql.sql_frontend import (
    STATEMENT_NOT_A_QUERY,
    plan_from_sql,
    query_plan,
    statement_from_sql,
)

comptime _NOT_A_QUERY = (
    "STATEMENT_NOT_A_QUERY: only a query has a query plan; COPY and CREATE"
    " TABLE AS bind to a write"
)
comptime _SCAN_T = "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"


def _catalog() -> SqlCatalog:
    """t(k INT64 not null, v FLOAT64, s STRING)."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    return cat^


@fieldwise_init
struct _Footers(SqlParquetFooters):
    """A footer reader with fixed answers: `p.parquet` has schema
    (a INT32, b STRING); every other path raises `no such file: <path>`."""

    def footer_schema(self, path: String) raises -> Schema:
        if path != "p.parquet":
            raise Error("no such file: " + path)
        var sb = SchemaBuilder()
        sb.add_field(Field(String("a"), ArrowType.INT32, True))
        sb.add_field(Field(String("b"), ArrowType.STRING, True))
        return sb.build()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        return None

    def parquet_relation(
        self, path: String, hive_partitioning: UInt8
    ) raises -> ParquetSource:
        return ParquetSource(String(path), self.footer_schema(path), None)


def _plan_err(sql: String) raises -> String:
    """The message `plan_from_sql` raises for `sql`; fails if it binds."""
    var cat = _catalog()
    try:
        _ = plan_from_sql(sql, cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


def test_statement_kinds_from_text() raises:
    var cat = _catalog()
    var query = statement_from_sql("SELECT k FROM t", cat, NoParquetFooters())
    assert_equal(Int(query.kind), Int(STMT_QUERY))
    assert_equal(query.dest_path, "")
    assert_equal(query.register_as, "")
    assert_equal(
        String(query.take_plan()), "Project(exprs=[ColRef(k)])\n  " + _SCAN_T
    )

    var copy = statement_from_sql(
        "COPY (SELECT k, s FROM t) TO 'out.csv' (FORMAT csv)",
        cat,
        NoParquetFooters(),
    )
    assert_equal(Int(copy.kind), Int(STMT_COPY))
    assert_equal(copy.dest_path, "out.csv")
    assert_equal(Int(copy.fmt), Int(WFMT_CSV))
    assert_equal(copy.register_as, "")
    assert_equal(
        String(copy.take_plan()),
        "Project(exprs=[ColRef(k), ColRef(s)])\n  " + _SCAN_T,
    )

    var ctas = statement_from_sql(
        "CREATE TABLE x AS SELECT v FROM t", cat, NoParquetFooters()
    )
    assert_equal(Int(ctas.kind), Int(STMT_CREATE_TABLE_AS))
    assert_equal(ctas.register_as, "x")
    assert_equal(ctas.dest_path, "")
    assert_equal(
        String(ctas.take_plan()), "Project(exprs=[ColRef(v)])\n  " + _SCAN_T
    )


def test_plan_from_sql_refuses_a_write_by_name() raises:
    assert_equal(
        _plan_err("COPY (SELECT k FROM t) TO 'out.csv' (FORMAT csv)"),
        _NOT_A_QUERY,
    )
    assert_equal(_plan_err("CREATE TABLE x AS SELECT k FROM t"), _NOT_A_QUERY)
    assert_true(String(_NOT_A_QUERY).startswith(String(STATEMENT_NOT_A_QUERY)))

    var cat = _catalog()
    var refused = False
    try:
        _ = query_plan(
            statement_from_sql(
                "COPY (SELECT k FROM t) TO 'out.csv' (FORMAT csv)",
                cat,
                NoParquetFooters(),
            )
        )
    except e:
        refused = True
        assert_equal(String(e), _NOT_A_QUERY)
    assert_true(refused, "query_plan gave a plan for a COPY")

    var plan = query_plan(
        statement_from_sql("SELECT s FROM t", cat, NoParquetFooters())
    )
    assert_equal(String(plan), "Project(exprs=[ColRef(s)])\n  " + _SCAN_T)


def test_lex_and_parse_failures_raise_their_own_message() raises:
    for sql in [
        String("selec k frm t"),
        String("SELECT 'unterminated FROM t"),
        String(""),
        String("SELECT k FROM t t2 t3"),
    ]:
        var msg = _plan_err(sql)
        assert_true(
            msg.startswith("SQL syntax error"),
            "'" + sql + "' raised '" + msg + "'",
        )


def test_bind_failures_raise_their_own_message() raises:
    assert_equal(
        _plan_err("SELECT k FROM nowhere"),
        "SQL bind error: unknown table 'nowhere'",
    )
    assert_equal(
        _plan_err("SELECT zzz FROM t"), "SQL bind error: unknown column 'zzz'"
    )
    assert_equal(
        _plan_err("SELECT nosuchfn(k) FROM t"),
        "SQL not supported: scalar function 'nosuchfn'. No UDFs are declared"
        " on this catalog either — declare one with `catalog.declare_udf(f)`",
    )
    # A cast DuckDB answers and this engine refuses by name rather than
    # answer differently: a column to DECIMAL.
    assert_true(
        _plan_err("SELECT CAST(v AS DECIMAL(10,2)) AS vd FROM t").startswith(
            "SQL not supported: CAST to DECIMAL"
        )
    )
    var over_agg = _plan_err("SELECT CAST(max(k) AS VARCHAR) AS mk FROM t")
    assert_true(over_agg.startswith("SQL not supported: scalar function '"), over_agg)
    assert_true(over_agg.find("' applied to an aggregate result.") >= 0, over_agg)


def test_the_footer_reader_is_the_callers() raises:
    var cat = SqlCatalog()
    var plan = plan_from_sql(
        "SELECT b, a FROM read_parquet('p.parquet')", cat, _Footers()
    )
    assert_equal(plan.output_schema.num_columns(), 2)
    assert_equal(plan.output_schema.field_name(0), "b")
    assert_true(plan.output_schema.field_arrow_type(0) == ArrowType.STRING)
    assert_equal(plan.output_schema.field_name(1), "a")
    assert_true(plan.output_schema.field_arrow_type(1) == ArrowType.INT32)

    var missing = False
    try:
        _ = plan_from_sql(
            "SELECT a FROM read_parquet('q.parquet')", cat, _Footers()
        )
    except e:
        missing = True
        assert_true(String(e).find("no such file: q.parquet") >= 0, String(e))
    assert_true(missing, "a reader that raises gave a plan")

    var none = False
    try:
        _ = plan_from_sql(
            "SELECT a FROM read_parquet('p.parquet')", cat, NoParquetFooters()
        )
    except e:
        none = True
        assert_true(
            String(e).find(
                "read_parquet('p.parquet') needs a parquet footer reader"
            )
            >= 0,
            String(e),
        )
    assert_true(none, "NoParquetFooters gave a schema")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

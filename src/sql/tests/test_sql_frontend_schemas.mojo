# =============================================================================
# sql_frontend: the result schema of a query plan from SQL text
# =============================================================================
#
# Every query binds through `plan_from_sql` against a catalog of parquet tables
# registered with a given schema (no file is opened). A column is written
# `name:type`, a DECIMAL128 with `(precision,scale)`, and `?` when nullable.
# The types are DuckDB's for the same SQL, with its one Arrow departure here: a
# sum of integers is HUGEINT in DuckDB, which Arrow cannot hold, and is
# DECIMAL(38,0). Each test also checks that `infer_schema` (plan_ir's schema
# propagation, which re-derives a schema from the plan's nodes) agrees with the
# schema the plan carries. What each test proves:
#   * test_projected_columns_and_expressions: selected columns keep their
#     type and nullability, `*` expands in table order, and an arithmetic, a
#     comparison and a string function give BIGINT, BOOLEAN and VARCHAR (an
#     arithmetic result is declared nullable even over NOT NULL operands).
#   * test_grouped_aggregates: count is a BIGINT that is never NULL; a sum of
#     INTEGER is DECIMAL(38,0), of DOUBLE DOUBLE, of DECIMAL(12,2)
#     DECIMAL(38,2); avg is DOUBLE; min and max keep their argument's type;
#     every aggregate but count is nullable.
#   * test_a_whole_table_aggregate_is_nullable_even_over_a_not_null_column:
#     max over a NOT NULL column is nullable (an empty table gives NULL), count
#     is not.
#   * test_cast_outputs: CAST to VARCHAR, INTEGER, BIGINT and DOUBLE gives
#     that type with the operand's nullability. (The casts the binder refuses
#     by name are in test_sql_frontend_refusals.)
#   * test_union_all_and_derived_tables_keep_the_first_branchs_names: a UNION
#     ALL is named by its first branch (and `infer_schema` has a UNION arm),
#     and a derived table's column list
#     renames the columns without changing their types.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_ir.schema_propagation import infer_schema

from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_catalog import SqlCatalog
from sql.sql_frontend import plan_from_sql


def _catalog() raises -> SqlCatalog:
    """t(k BIGINT NOT NULL, i INTEGER, v DOUBLE, s VARCHAR, d DECIMAL(12,2),
    b BOOLEAN)."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("i"), ArrowType.INT32, True))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field.decimal128(String("d"), 12, 2, True))
    t.add_field(Field(String("b"), ArrowType.BOOL, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    return cat^


def _render(schema: Schema) -> String:
    """`name:type[(p,s)][?]` per column, joined by `, `."""
    var out = String("")
    for c in range(schema.num_columns()):
        if c > 0:
            out += ", "
        out += schema.field_name(c) + ":" + String(schema.field_arrow_type(c))
        if schema.field_arrow_type(c) == ArrowType.DECIMAL128:
            out += (
                "("
                + String(schema.field_decimal_precision(c))
                + ","
                + String(schema.field_decimal_scale(c))
                + ")"
            )
        if schema.field_nullable(c):
            out += "?"
    return out


def _schema_of(sql: String) raises -> String:
    """The rendered result schema of `sql`, after checking that
    `infer_schema` re-derives the same one from the plan."""
    var cat = _catalog()
    var plan = plan_from_sql(sql, cat, NoParquetFooters())
    var carried = _render(plan.output_schema)
    assert_equal(_render(infer_schema(plan)), carried, sql)
    return carried


def test_projected_columns_and_expressions() raises:
    assert_equal(_schema_of("SELECT s, k FROM t"), "s:string?, k:int64")
    assert_equal(
        _schema_of("SELECT * FROM t"),
        "k:int64, i:int32?, v:float64?, s:string?, d:decimal128(12,2)?,"
        " b:bool?",
    )
    assert_equal(
        _schema_of(
            "SELECT k + 1 AS k1, i > 0 AS pos, upper(s) AS us FROM t"
        ),
        "k1:int64?, pos:bool?, us:string?",
    )


def test_grouped_aggregates() raises:
    assert_equal(
        _schema_of(
            "SELECT k, count(*) AS n, count(i) AS ni, sum(i) AS si,"
            " sum(v) AS sv, sum(d) AS sd, avg(i) AS ai, min(s) AS ms,"
            " max(d) AS md FROM t GROUP BY k"
        ),
        "k:int64, n:int64, ni:int64, si:decimal128(38,0)?, sv:float64?,"
        " sd:decimal128(38,2)?, ai:float64?, ms:string?, md:decimal128(12,2)?",
    )


def test_a_whole_table_aggregate_is_nullable_even_over_a_not_null_column() raises:
    assert_equal(
        _schema_of("SELECT count(*) AS n, max(k) AS mk FROM t"),
        "n:int64, mk:int64?",
    )


def test_cast_outputs() raises:
    assert_equal(
        _schema_of(
            "SELECT CAST(k AS VARCHAR) AS ks, CAST(v AS INTEGER) AS vi,"
            " CAST(i AS BIGINT) AS ib, CAST(i AS DOUBLE) AS idbl FROM t"
        ),
        "ks:string, vi:int32?, ib:int64?, idbl:float64?",
    )


def test_union_all_and_derived_tables_keep_the_first_branchs_names() raises:
    assert_equal(
        _schema_of("SELECT k AS a, s FROM t UNION ALL SELECT k, s FROM t"),
        "a:int64, s:string?",
    )
    assert_equal(
        _schema_of("SELECT x, y FROM (SELECT k, s FROM t) AS q(x, y)"),
        "x:int64, y:string?",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

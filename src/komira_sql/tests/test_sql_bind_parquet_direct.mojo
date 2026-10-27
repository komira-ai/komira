# =============================================================================
# Direct tests of the parquet facts the binder reads (sql_bind_parquet)
# =============================================================================
#
# A fake footer reader stands in for the caller: it answers from the path and
# column names alone, so each test reads exactly what `collect_parquet_facts`
# asked of it.
#   1. path_has_glob / is_parquet_tvf_kind: `*`, `?` and `[` mark a glob; only
#      the CSV, JSON and Avro readers are not parquet.
#   2. ParquetFacts keeps the first schema and the first null count recorded
#      for a path (and for a path and column); an unrecorded schema raises,
#      an unrecorded count reads as unknown.
#   3. A `read_parquet` relation's footer schema is collected without any
#      null count unless the statement holds a NOT IN subquery.
#   4. With a NOT IN subquery every column of a non-glob parquet relation gets
#      a count; a count the reader cannot give (it raises, or returns None) is
#      recorded as unknown; a glob path gets a schema and no counts.
#   5. A parquet catalog table's counts are collected per file path under NOT
#      IN, and none without it.
#   6. A CSV relation never reaches the footer reader; relations inside a CTE
#      body and a subquery body are collected too.
#   7. NoParquetFooters refuses a `read_parquet` relation by name and reports
#      every null count as unknown.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_sql.sql_ast import TVF_AVRO, TVF_CSV, TVF_JSON
from komira_sql.sql_bind_parquet import (
    NoParquetFooters,
    ParquetFacts,
    SqlParquetFooters,
    collect_parquet_facts,
    is_parquet_tvf_kind,
    path_has_glob,
)
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("b"), ArrowType.INT64, True))
    sb.add_field(Field(String("boom"), ArrowType.INT64, True))
    sb.add_field(Field(String("unk"), ArrowType.INT64, True))
    return sb.build()


struct _Footers(SqlParquetFooters):
    """`a` has no NULL, `b` has seven, `boom` raises, `unk` is unknown; a path
    named `x.csv` has no footer."""

    def __init__(out self):
        pass

    def footer_schema(self, path: String) raises -> Schema:
        if path == "x.csv":
            raise Error("no footer for " + path)
        return _schema()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        if column == "boom":
            raise Error("unreadable statistics")
        if column == "unk":
            return None
        if column == "b":
            return 7
        return 0


def _facts(sql: String, catalog: SqlCatalog) raises -> ParquetFacts:
    return collect_parquet_facts(parse_sql(tokenize(sql)), catalog, _Footers())


def test_glob_and_kind_predicates() raises:
    assert_true(path_has_glob("data/*.parquet"))
    assert_true(path_has_glob("data/f?.parquet"))
    assert_true(path_has_glob("data/f[0-9].parquet"))
    assert_false(path_has_glob("data/f.parquet"))
    assert_false(is_parquet_tvf_kind(TVF_CSV))
    assert_false(is_parquet_tvf_kind(TVF_JSON))
    assert_false(is_parquet_tvf_kind(TVF_AVRO))
    assert_true(is_parquet_tvf_kind(UInt8(250)))


def test_facts_keep_the_first_record() raises:
    var f = ParquetFacts()
    assert_false(f.has_schema("p"))
    assert_false(f.has_null_count("p", "a"))
    assert_false(f.null_count("p", "a").__bool__())
    f.add_schema("p", _schema())
    var other = SchemaBuilder()
    other.add_field(Field(String("z"), ArrowType.INT64, True))
    f.add_schema("p", other.build())
    assert_equal(f.schema_of("p").num_columns(), 4)
    f.add_null_count("p", "a", Optional[Int](3))
    f.add_null_count("p", "a", Optional[Int](9))
    f.add_null_count("p", "b", Optional[Int]())
    assert_equal(f.null_count("p", "a").value(), 3)
    assert_true(f.has_null_count("p", "b"))
    assert_false(f.null_count("p", "b").__bool__())
    assert_false(f.has_null_count("q", "a"))
    var raised = False
    try:
        _ = f.schema_of("q")
    except e:
        raised = True
        assert_true(String(e).find("no parquet footer was read for 'q'") >= 0)
    assert_true(raised)


def test_schema_is_collected_and_counts_wait_for_not_in() raises:
    var f = _facts("SELECT a FROM read_parquet('p.parquet')", SqlCatalog())
    assert_true(f.has_schema("p.parquet"))
    assert_equal(f.schema_of("p.parquet").field_name(1), "b")
    assert_false(f.has_null_count("p.parquet", "a"))


def test_not_in_collects_counts_and_records_unknowns() raises:
    var f = _facts(
        "SELECT a FROM read_parquet('p.parquet') WHERE a NOT IN (SELECT a FROM read_parquet('q.parquet'))",
        SqlCatalog(),
    )
    assert_equal(f.null_count("p.parquet", "a").value(), 0)
    assert_equal(f.null_count("p.parquet", "b").value(), 7)
    # A raising reader and a None answer are both "unknown", and recorded so
    # the binder keeps its run-time NULL checks rather than reading nothing.
    assert_true(f.has_null_count("p.parquet", "boom"))
    assert_false(f.null_count("p.parquet", "boom").__bool__())
    assert_true(f.has_null_count("p.parquet", "unk"))
    assert_false(f.null_count("p.parquet", "unk").__bool__())
    assert_true(f.has_schema("q.parquet"))
    assert_equal(f.null_count("q.parquet", "b").value(), 7)


def test_glob_path_gets_a_schema_and_no_counts() raises:
    var f = _facts(
        "SELECT a FROM read_parquet('d/*.parquet') WHERE a NOT IN (SELECT a FROM read_parquet('d/*.parquet'))",
        SqlCatalog(),
    )
    assert_true(f.has_schema("d/*.parquet"))
    assert_false(f.has_null_count("d/*.parquet", "a"))
    assert_false(f.has_null_count("d/*.parquet", "b"))


def test_parquet_catalog_table_counts_under_not_in_only() raises:
    var cat = SqlCatalog()
    cat.add_parquet("pt", "t1.parquet", _schema())
    var plain = _facts("SELECT a FROM pt", cat)
    assert_false(plain.has_schema("t1.parquet"))
    assert_false(plain.has_null_count("t1.parquet", "a"))
    var f = _facts("SELECT a FROM pt WHERE a NOT IN (SELECT a FROM pt)", cat)
    # A catalog table's schema is its declared one, so no footer is read.
    assert_false(f.has_schema("t1.parquet"))
    assert_equal(f.null_count("t1.parquet", "b").value(), 7)
    assert_equal(f.null_count("t1.parquet", "a").value(), 0)
    assert_false(f.null_count("t1.parquet", "unk").__bool__())


def test_csv_is_skipped_and_nested_bodies_are_walked() raises:
    # `x.csv` has no footer in the fake: asking for one would raise.
    var csv = _facts("SELECT a FROM read_csv('x.csv')", SqlCatalog())
    assert_false(csv.has_schema("x.csv"))
    var f = _facts(
        "WITH c AS (SELECT a FROM read_parquet('c.parquet')) "
        "SELECT a FROM c WHERE a IN (SELECT a FROM read_parquet('s.parquet'))",
        SqlCatalog(),
    )
    assert_true(f.has_schema("c.parquet"))
    assert_true(f.has_schema("s.parquet"))


def test_no_footers_reader_refuses_by_name() raises:
    var raised = False
    try:
        _ = collect_parquet_facts(
            parse_sql(tokenize("SELECT a FROM read_parquet('p.parquet')")),
            SqlCatalog(),
            NoParquetFooters(),
        )
    except e:
        raised = True
        assert_true(String(e).find("read_parquet('p.parquet') needs a parquet footer reader") >= 0)
    assert_true(raised)
    assert_false(NoParquetFooters().column_null_count("p", "a").__bool__())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

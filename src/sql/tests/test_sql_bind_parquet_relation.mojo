# =============================================================================
# Parquet relations of several files and Hive partition columns, bound off a
# fake footer reader
# =============================================================================
#
# The fake reader answers `parquet_relation` from the path text alone:
# `hive/*.parquet` is two files `hive/y=1/a.parquet` and `hive/y=2/a.parquet`
# with an INT64 partition column `y` (none under `hive_partitioning = false`),
# `bad/*.parquet` is two plain files of which `bad/b.parquet` holds 3 NULLs in
# `k`, and any other path is one file. Data columns are (k INT64 NOT NULL,
# v FLOAT64).
#   1. A `read_parquet` glob scans the source the reader resolved: its files,
#      its partition columns and values, and a scan schema of the data columns
#      then the partition columns.
#   2. The mode in the call picks the source: OFF has no partition column, ON
#      and AUTO have one.
#   3. ParquetFacts holds one source per (path, mode).
#   4. Under NOT IN, null counts are recorded per file of the resolved source
#      and none for the glob text.
#   5. A column is known NULL-free only when every file records 0 and it is
#      not a partition column, for `read_parquet` relations and for catalog
#      tables of several files.
#   6. `add_parquet_source` registers a table whose schema is the data columns
#      then the partition columns and whose source is the one given.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder

from scan_source.parquet_source import ParquetSource
from sql.sql_ast import (
    HIVE_PARTITIONING_AUTO,
    HIVE_PARTITIONING_OFF,
    HIVE_PARTITIONING_ON,
)
from sql.sql_bind_parquet import (
    ParquetFacts,
    SqlParquetFooters,
    collect_parquet_facts,
    parquet_relation_schema,
)
from sql.sql_bind_scope import CteScope, _relation_scan, _relation_schema
from sql.sql_binder import bind_statement
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _kv() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    return sb.build()


def _y() -> List[Field]:
    var cols = List[Field]()
    cols.append(Field(String("y"), ArrowType.INT64, False))
    return cols^


def _hive_source(hive: Bool) raises -> ParquetSource:
    var paths = List[String]()
    paths.append(String("hive/y=1/a.parquet"))
    paths.append(String("hive/y=2/a.parquet"))
    var values = List[List[String]]()
    var cols = List[Field]()
    if hive:
        cols = _y()
        var v1 = List[String]()
        v1.append(String("1"))
        values.append(v1^)
        var v2 = List[String]()
        v2.append(String("2"))
        values.append(v2^)
    return ParquetSource.partitioned(paths^, _kv(), cols^, values^, None)


def _bad_source() raises -> ParquetSource:
    var paths = List[String]()
    paths.append(String("bad/a.parquet"))
    paths.append(String("bad/b.parquet"))
    return ParquetSource.partitioned(
        paths^, _kv(), List[Field](), List[List[String]](), None
    )


struct _Footers(SqlParquetFooters):
    def __init__(out self):
        pass

    def footer_schema(self, path: String) raises -> Schema:
        return _kv()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        if path == "bad/b.parquet" and column == "k":
            return 3
        return 0

    def parquet_relation(
        self, path: String, hive_partitioning: UInt8
    ) raises -> ParquetSource:
        if path == "hive/*.parquet":
            return _hive_source(hive_partitioning != HIVE_PARTITIONING_OFF)
        if path == "bad/*.parquet":
            return _bad_source()
        return ParquetSource(String(path), _kv(), None)


def _facts(sql: String, catalog: SqlCatalog) raises -> ParquetFacts:
    return collect_parquet_facts(parse_sql(tokenize(sql)), catalog, _Footers())


def _scan_of(sql: String) raises -> ParquetSource:
    """The parquet source of the first FROM relation's scan."""
    var st = parse_sql(tokenize(sql))
    var cat = SqlCatalog()
    var cte = CteScope(collect_parquet_facts(st, cat, _Footers()))
    var scan = _relation_scan(st.query.from_tables[0], cat, cte)
    return scan.scan_data_ref().source._parquet.value().copy()


def _plan(sql: String, cat: SqlCatalog) raises -> String:
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, _Footers())
    return String(bound.take_plan())


def test_glob_scan_is_the_resolved_partitioned_source() raises:
    var src = _scan_of("SELECT k FROM read_parquet('hive/*.parquet')")
    assert_equal(len(src.paths), 2)
    assert_equal(src.paths[1], "hive/y=2/a.parquet")
    assert_equal(len(src.partition_cols), 1)
    assert_equal(src.partition_cols[0].name, "y")
    assert_equal(src.partition_values[0][0], "1")
    assert_equal(src.partition_values[1][0], "2")
    var st = parse_sql(tokenize("SELECT k FROM read_parquet('hive/*.parquet')"))
    var cat = SqlCatalog()
    var cte = CteScope(collect_parquet_facts(st, cat, _Footers()))
    var scan = _relation_scan(st.query.from_tables[0], cat, cte)
    assert_equal(scan.output_schema.num_columns(), 3)
    assert_equal(scan.output_schema.field_name(0), "k")
    assert_equal(scan.output_schema.field_name(1), "v")
    assert_equal(scan.output_schema.field_name(2), "y")
    var schema = _relation_schema(st.query.from_tables[0], cat, cte)
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(2), "y")
    # The partition column is selectable by the binder.
    _ = _plan("SELECT k, y FROM read_parquet('hive/*.parquet') WHERE y = 2", cat)


def test_the_mode_in_the_call_picks_the_source() raises:
    var off = _scan_of(
        "SELECT k FROM read_parquet('hive/*.parquet', hive_partitioning = false)"
    )
    assert_equal(len(off.paths), 2)
    assert_equal(len(off.partition_cols), 0)
    var on = _scan_of(
        "SELECT k FROM read_parquet('hive/*.parquet', hive_partitioning = true)"
    )
    assert_equal(len(on.partition_cols), 1)
    var plain = _scan_of("SELECT k FROM read_parquet('one.parquet')")
    assert_equal(len(plain.paths), 1)
    assert_equal(plain.path, "one.parquet")
    assert_equal(len(plain.partition_cols), 0)


def test_facts_hold_one_source_per_path_and_mode() raises:
    var f = _facts(
        "SELECT a.k FROM read_parquet('hive/*.parquet') AS a,"
        " read_parquet('hive/*.parquet', hive_partitioning = false) AS b",
        SqlCatalog(),
    )
    assert_true(f.has_relation("hive/*.parquet", HIVE_PARTITIONING_AUTO))
    assert_true(f.has_relation("hive/*.parquet", HIVE_PARTITIONING_OFF))
    assert_false(f.has_relation("hive/*.parquet", HIVE_PARTITIONING_ON))
    assert_equal(f.schema_of("hive/*.parquet", HIVE_PARTITIONING_AUTO).num_columns(), 3)
    assert_equal(f.schema_of("hive/*.parquet", HIVE_PARTITIONING_OFF).num_columns(), 2)
    var raised = False
    try:
        _ = f.source_of("hive/*.parquet", HIVE_PARTITIONING_ON)
    except e:
        raised = True
        assert_equal(
            String(e),
            "SQL bind error: no parquet footer was read for 'hive/*.parquet'",
        )
    assert_true(raised)


def test_null_counts_are_recorded_per_file() raises:
    var f = _facts(
        "SELECT k FROM read_parquet('bad/*.parquet') WHERE k NOT IN"
        " (SELECT k FROM read_parquet('hive/*.parquet'))",
        SqlCatalog(),
    )
    assert_equal(f.null_count("bad/a.parquet", "k").value(), 0)
    assert_equal(f.null_count("bad/b.parquet", "k").value(), 3)
    assert_equal(f.null_count("hive/y=1/a.parquet", "v").value(), 0)
    assert_equal(f.null_count("hive/y=2/a.parquet", "k").value(), 0)
    assert_false(f.has_null_count("hive/*.parquet", "k"))
    # A partition column is in no file, so no file records a count for it.
    assert_false(f.has_null_count("hive/y=1/a.parquet", "y"))


def test_null_free_needs_every_file_and_no_partition_column() raises:
    var cat = SqlCatalog()
    # Every file of the subquery's relation records 0: the run-time NULL
    # checks are dropped, leaving only the anti-join subquery.
    var free = _plan(
        "SELECT k FROM read_parquet('one.parquet') WHERE k NOT IN"
        " (SELECT k FROM read_parquet('hive/*.parquet'))",
        cat,
    )
    assert_false(free.find("kind=2") >= 0)
    # One file of the two holds NULLs in `k`: the checks stay.
    var some = _plan(
        "SELECT k FROM read_parquet('one.parquet') WHERE k NOT IN"
        " (SELECT k FROM read_parquet('bad/*.parquet'))",
        cat,
    )
    assert_true(some.find("kind=2") >= 0)
    # A partition column is never known NULL-free.
    var part = _plan(
        "SELECT k FROM read_parquet('one.parquet') WHERE k NOT IN"
        " (SELECT y FROM read_parquet('hive/*.parquet'))",
        cat,
    )
    assert_true(part.find("kind=2") >= 0)


def test_add_parquet_source_registers_data_then_partition_columns() raises:
    var cat = SqlCatalog()
    cat.add_parquet_source(String("HC"), _hive_source(True))
    cat.add_parquet_source(String("bc"), _bad_source())
    var schema = cat.schema_of("hc")
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(0), "k")
    assert_equal(schema.field_name(2), "y")
    assert_false(schema.field_nullable(2))
    var t = cat.table_of("hc")
    assert_equal(t.name, "hc")
    assert_equal(len(t.source._parquet.value().paths), 2)
    assert_equal(len(t.source._parquet.value().partition_values), 2)
    var scan = cat.build_scan("hc")
    assert_equal(scan.output_schema.num_columns(), 3)
    assert_equal(
        parquet_relation_schema(_hive_source(False)).num_columns(), 2
    )
    # A catalog table of several files is null-free only when every one of
    # its files is, and never in a partition column.
    var free = _plan(
        "SELECT k FROM read_parquet('one.parquet') WHERE k NOT IN"
        " (SELECT k FROM hc)",
        cat,
    )
    assert_false(free.find("kind=2") >= 0)
    var some = _plan(
        "SELECT k FROM read_parquet('one.parquet') WHERE k NOT IN"
        " (SELECT k FROM bc)",
        cat,
    )
    assert_true(some.find("kind=2") >= 0)
    var part = _plan(
        "SELECT k FROM read_parquet('one.parquet') WHERE k NOT IN"
        " (SELECT y FROM hc)",
        cat,
    )
    assert_true(part.find("kind=2") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

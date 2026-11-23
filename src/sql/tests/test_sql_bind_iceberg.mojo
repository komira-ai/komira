# =============================================================================
# Iceberg relations bound off a fake table reader
# =============================================================================
#
# The fake reader answers `iceberg_relation` from its arguments alone: the
# path `t` is a binding of kind `komira.iceberg.table` over (id INT64 NOT NULL,
# name STRING), with a third column `moved` when `allow_moved_paths` is set and
# the snapshot id as the binding's snapshot token; the path `missing` raises.
# `parquet_relation` answers a one-file source over (k INT64 NOT NULL).
#   1. test_an_iceberg_relation_scans_the_source_the_reader_returned: the scan
#      of `iceberg_scan('t')` is the binding the reader built, with its schema,
#      as an unprojected scan leaf.
#   2. test_the_options_in_the_call_pick_the_source: allow_moved_paths and
#      snapshot_from_id reach the reader, and the schema the binder sees is the
#      source's own.
#   3. test_facts_hold_one_source_per_path_and_options: ParquetFacts records
#      one source per (path, moved, snapshot), keeps the first of a repeated
#      key, and refuses an unrecorded key by name.
#   4. test_a_reader_without_iceberg_support_refuses_by_name: a reader that does
#      not override `iceberg_relation` refuses `iceberg_scan('t')` at fact
#      collection with the trait's own message.
#   5. test_a_reader_error_ends_the_bind: the reader's error text reaches the
#      caller unchanged.
#   6. test_iceberg_relations_are_found_in_ctes_and_subqueries: relations in a
#      CTE body and in a subquery body are asked of the reader.
#   7. test_add_source_registers_a_table_under_its_own_schema: a source added
#      to the catalog by name is found case-insensitively with the source's
#      schema, scans as the same binding, and binds in a query.
#   8. test_an_iceberg_column_is_never_known_null_free: a NOT IN over an
#      iceberg_scan relation keeps the run-time NULL checks.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder

from scan_source.parquet_source import ParquetSource
from scan_source.pushdown_gate import PushdownGate
from scan_source.scan_binding import (
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_PINNED,
    ScanBinding,
    scan_kind_id,
)
from scan_source.scan_params import ScanParams
from scan_source.source_variant import SourceVariant
from sql.sql_bind_parquet import (
    NoParquetFooters,
    ParquetFacts,
    SqlParquetFooters,
    collect_parquet_facts,
)
from sql.sql_bind_scope import CteScope, _relation_scan, _relation_schema
from sql.sql_binder import bind_statement
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize

comptime _KIND: String = "komira.iceberg.table"


def _table_schema(moved: Bool) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("id"), ArrowType.INT64, False))
    sb.add_field(Field(String("name"), ArrowType.STRING, True))
    if moved:
        sb.add_field(Field(String("moved"), ArrowType.INT64, True))
    return sb.build()


def _k() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    return sb.build()


def _binding(path: String, moved: Bool, snapshot: Optional[Int64]) -> ScanBinding:
    var params = ScanParams()
    params.put_str(String("metadata_path"), path)
    params.put_bool(String("allow_moved_paths"), moved)
    var token = UInt64(0)
    if snapshot:
        token = UInt64(snapshot.value())
    return ScanBinding(
        kind_id=scan_kind_id(String(_KIND)),
        kind_name=String(_KIND),
        name=String(path),
        params=params^,
        schema=_table_schema(moved),
        fingerprint=UInt64(7),
        structural_id=UInt64(7),
        gate=PushdownGate.conjunctive_comparison(False),
        snapshot_policy=SNAPSHOT_PINNED,
        snapshot_token=token,
        orientation=SCAN_ORIENTATION_COLUMNAR,
    )


struct _Footers(SqlParquetFooters):
    def __init__(out self):
        pass

    def footer_schema(self, path: String) raises -> Schema:
        return _k()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        return 0

    def parquet_relation(
        self, path: String, hive_partitioning: UInt8
    ) raises -> ParquetSource:
        return ParquetSource(String(path), _k(), None)

    def iceberg_relation(
        self,
        path: String,
        allow_moved_paths: Bool,
        snapshot_id: Optional[Int64],
    ) raises -> SourceVariant:
        if path == "missing":
            raise Error("ICEBERG_METADATA_INVALID: no table at 'missing'")
        return SourceVariant.from_binding(
            _binding(path, allow_moved_paths, snapshot_id)
        )


def _facts(sql: String, catalog: SqlCatalog) raises -> ParquetFacts:
    return collect_parquet_facts(parse_sql(tokenize(sql)), catalog, _Footers())


def _plan(sql: String, cat: SqlCatalog) raises -> String:
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, _Footers())
    return String(bound.take_plan())


def test_an_iceberg_relation_scans_the_source_the_reader_returned() raises:
    var st = parse_sql(tokenize("SELECT id FROM iceberg_scan('t')"))
    var cat = SqlCatalog()
    var cte = CteScope(collect_parquet_facts(st, cat, _Footers()))
    var scan = _relation_scan(st.query.from_tables[0], cat, cte)
    ref source = scan.scan_data_ref().source
    assert_true(source.is_binding_backed())
    assert_equal(source.binding_ref().kind_name, String(_KIND))
    assert_equal(source.binding_ref().name, "t")
    assert_equal(scan.output_schema.num_columns(), 2)
    assert_equal(scan.output_schema.field_name(0), "id")
    assert_equal(scan.output_schema.field_name(1), "name")
    var schema = _relation_schema(st.query.from_tables[0], cat, cte)
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(1), "name")
    assert_false(schema.field_nullable(0))
    assert_true(schema.field_nullable(1))
    # The binder selects and filters its columns.
    _ = _plan("SELECT id, name FROM iceberg_scan('t') WHERE id > 1", cat)


def test_the_options_in_the_call_pick_the_source() raises:
    var st = parse_sql(
        tokenize(
            "SELECT id FROM iceberg_scan('t', allow_moved_paths = true,"
            " snapshot_from_id = 5)"
        )
    )
    var cat = SqlCatalog()
    var cte = CteScope(collect_parquet_facts(st, cat, _Footers()))
    var scan = _relation_scan(st.query.from_tables[0], cat, cte)
    ref binding = scan.scan_data_ref().source.binding_ref()
    assert_true(binding.params.get_bool(String("allow_moved_paths")))
    assert_equal(Int(binding.snapshot_token), 5)
    assert_equal(scan.output_schema.num_columns(), 3)
    assert_equal(scan.output_schema.field_name(2), "moved")
    var schema = _relation_schema(st.query.from_tables[0], cat, cte)
    assert_equal(schema.num_columns(), 3)
    _ = _plan(
        "SELECT moved FROM iceberg_scan('t', allow_moved_paths = true)", cat
    )


def test_facts_hold_one_source_per_path_and_options() raises:
    var f = _facts(
        "SELECT a.id FROM iceberg_scan('t') AS a,"
        " iceberg_scan('t', allow_moved_paths = true) AS b,"
        " iceberg_scan('t', snapshot_from_id = 9) AS c,"
        " iceberg_scan('t') AS d",
        SqlCatalog(),
    )
    var none: Optional[Int64] = None
    var nine: Optional[Int64] = Int64(9)
    assert_true(f.has_iceberg("t", False, none))
    assert_true(f.has_iceberg("t", True, none))
    assert_true(f.has_iceberg("t", False, nine))
    assert_false(f.has_iceberg("t", True, nine))
    assert_false(f.has_iceberg("u", False, none))
    assert_equal(f.iceberg_source_of("t", False, none).schema().num_columns(), 2)
    assert_equal(f.iceberg_source_of("t", True, none).schema().num_columns(), 3)
    assert_equal(
        Int(f.iceberg_source_of("t", False, nine).binding_ref().snapshot_token),
        9,
    )
    # A key already recorded keeps its first source.
    f.add_iceberg("t", False, none, SourceVariant.from_binding(_binding("t", True, none)))
    assert_equal(f.iceberg_source_of("t", False, none).schema().num_columns(), 2)
    var raised = False
    try:
        _ = f.iceberg_source_of("t", True, nine)
    except e:
        raised = True
        assert_equal(
            String(e), "SQL bind error: no Iceberg table was read for 't'"
        )
    assert_true(raised)
    # Iceberg relations are not parquet relations.
    assert_false(f.has_relation("t", 0))
    # A key differs by its snapshot id: none is not an id, and one id is not
    # another.
    var pinned = _facts(
        "SELECT id FROM iceberg_scan('s', snapshot_from_id = 9)", SqlCatalog()
    )
    assert_true(pinned.has_iceberg("s", False, nine))
    assert_false(pinned.has_iceberg("s", False, none))
    assert_false(pinned.has_iceberg("s", False, Optional[Int64](10)))


def test_a_reader_without_iceberg_support_refuses_by_name() raises:
    var raised = False
    try:
        _ = collect_parquet_facts(
            parse_sql(tokenize("SELECT id FROM iceberg_scan('db/t')")),
            SqlCatalog(),
            NoParquetFooters(),
        )
    except e:
        raised = True
        assert_equal(
            String(e),
            "SQL bind error: iceberg_scan('db/t') needs a binder that reads"
            " Iceberg tables",
        )
    assert_true(raised)
    var direct = False
    try:
        _ = NoParquetFooters().iceberg_relation("p", False, None)
    except e:
        direct = True
        assert_equal(
            String(e),
            "SQL bind error: iceberg_scan('p') needs a binder that reads"
            " Iceberg tables",
        )
    assert_true(direct)


def test_a_reader_error_ends_the_bind() raises:
    var raised = False
    try:
        _ = _plan("SELECT id FROM iceberg_scan('missing')", SqlCatalog())
    except e:
        raised = True
        assert_equal(
            String(e), "ICEBERG_METADATA_INVALID: no table at 'missing'"
        )
    assert_true(raised)


def test_iceberg_relations_are_found_in_ctes_and_subqueries() raises:
    var f = _facts(
        "WITH c AS (SELECT id FROM iceberg_scan('in_cte'))"
        " SELECT id FROM c WHERE id IN"
        " (SELECT id FROM iceberg_scan('in_subquery'))",
        SqlCatalog(),
    )
    assert_true(f.has_iceberg("in_cte", False, None))
    assert_true(f.has_iceberg("in_subquery", False, None))
    assert_false(f.has_iceberg("c", False, None))
    _ = _plan(
        "WITH c AS (SELECT id FROM iceberg_scan('in_cte'))"
        " SELECT id FROM c WHERE id IN"
        " (SELECT id FROM iceberg_scan('in_subquery'))",
        SqlCatalog(),
    )


def test_add_source_registers_a_table_under_its_own_schema() raises:
    var cat = SqlCatalog()
    cat.add_source(
        String("Orders"), SourceVariant.from_binding(_binding("o", True, None))
    )
    assert_true(cat.has("orders"))
    var schema = cat.schema_of("ORDERS")
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(2), "moved")
    var t = cat.table_of("orders")
    assert_equal(t.name, "orders")
    assert_true(t.source.is_binding_backed())
    var scan = cat.build_scan("orders")
    assert_equal(scan.output_schema.num_columns(), 3)
    assert_equal(
        scan.scan_data_ref().source.binding_ref().kind_name, String(_KIND)
    )
    _ = _plan("SELECT id, moved FROM orders WHERE id = 3", cat)


def test_an_iceberg_column_is_never_known_null_free() raises:
    var cat = SqlCatalog()
    var sql = String(
        "SELECT k FROM read_parquet('one.parquet') WHERE k NOT IN"
        " (SELECT id FROM iceberg_scan('t'))"
    )
    var plan = _plan(sql, cat)
    assert_true(plan.find("kind=2") >= 0)
    var f = _facts(sql, cat)
    assert_true(f.has_null_count("one.parquet", "k"))
    assert_false(f.has_null_count("t", "id"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

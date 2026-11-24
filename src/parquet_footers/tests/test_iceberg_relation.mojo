# =============================================================================
# ParquetFooters.iceberg_relation: an Iceberg table resolved from its metadata
# =============================================================================
#
# Tables are written under `test_tmpdir()`: a format-version 2 `metadata.json`
# with six columns and no snapshot (so no manifest, and no Avro, is needed),
# optionally with the `version-hint.text` that names the version to read.
#
# What each test proves:
#   * test_a_table_directory_is_resolved_through_its_version_hint: the source
#     of `<dir>` is a binding of kind `komira.iceberg.table` that names the
#     metadata file `<dir>/metadata/v1.metadata.json`, the table root, the
#     columns of the table's schema in order, each nullable, and no snapshot
#     (-1) for a table without one.
#   * test_a_metadata_file_is_resolved_directly: a path to the metadata file
#     resolves to the same columns, with the table root two levels up.
#   * test_allow_moved_paths_reaches_the_binding: the option is recorded in the
#     binding's parameters, and a relation with it and one without it are two
#     different bindings.
#   * test_a_bind_of_iceberg_scan_reads_the_table_through_the_footers: binding
#     `SELECT id FROM iceberg_scan('<dir>')` with this reader gives a scan of
#     the binding, and a column the table lacks is refused at bind.
#   * test_a_table_without_a_version_hint_is_refused: a directory with a
#     `metadata/` directory and no hint is `ICEBERG_TABLE_VERSION_UNKNOWN`
#     naming the directory.
#   * test_a_missing_table_is_refused: a path that is neither a metadata file
#     nor a directory raises an error naming the path.
#   * test_a_snapshot_the_table_lacks_is_refused: `snapshot_from_id` of an id no
#     snapshot has is `ICEBERG_SNAPSHOT_NOT_FOUND`.
# =============================================================================

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from parquet_footers.parquet_footers import ParquetFooters
from runtime_paths import test_tmpdir
from scan_source.source_variant import SourceVariant
from sql.sql_binder import bind_statement
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize

comptime _KIND: String = "komira.iceberg.table"

comptime _METADATA: String = (
    '{\n'
    '  "format-version": 2,\n'
    '  "table-uuid": "7d3c2f6e-0000-4000-8000-000000000001",\n'
    '  "location": "file:///warehouse/db/orders",\n'
    '  "last-sequence-number": 0,\n'
    '  "last-updated-ms": 1790000000000,\n'
    '  "last-column-id": 6,\n'
    '  "current-schema-id": 0,\n'
    '  "schemas": [{"type": "struct", "schema-id": 0, "fields": [\n'
    '    {"id": 1, "name": "id", "required": true, "type": "long"},\n'
    '    {"id": 2, "name": "name", "required": false, "type": "string"},\n'
    '    {"id": 3, "name": "amount", "required": false, "type": "double"},\n'
    '    {"id": 4, "name": "active", "required": false, "type": "boolean"},\n'
    '    {"id": 5, "name": "day", "required": false, "type": "date"},\n'
    '    {"id": 6, "name": "qty", "required": false, "type": "int"}]}],\n'
    '  "default-spec-id": 0,\n'
    '  "partition-specs": [{"spec-id": 0, "fields": []}],\n'
    '  "last-partition-id": 999,\n'
    '  "default-sort-order-id": 0,\n'
    '  "sort-orders": [{"order-id": 0, "fields": []}],\n'
    '  "properties": {},\n'
    '  "current-snapshot-id": -1,\n'
    '  "snapshots": [],\n'
    '  "snapshot-log": [],\n'
    '  "metadata-log": []\n'
    '}\n'
)


def _put(path: String, text: String) raises:
    var fh = open(path, "w")
    fh.write(text)
    fh.close()


def _table(name: String, with_hint: Bool) raises -> String:
    """A table directory `<tmp>/ice_<name>` holding `metadata/v1.metadata.json`
    and, when `with_hint`, `metadata/version-hint.text` naming version 1."""
    var dir = test_tmpdir() + "/ice_" + name
    makedirs(dir + "/metadata", exist_ok=True)
    _put(dir + "/metadata/v1.metadata.json", String(_METADATA))
    if with_hint:
        _put(dir + "/metadata/version-hint.text", "1")
    return dir^


def _refusal(path: String, moved: Bool = False, snapshot: Optional[Int64] = None) -> String:
    """The error text of resolving `path`, or "" when it resolved."""
    try:
        _ = ParquetFooters().iceberg_relation(path, moved, snapshot)
    except e:
        return String(e)
    return String("")


def _assert_columns(source: SourceVariant) raises:
    var schema = source.schema()
    assert_equal(schema.num_columns(), 6)
    var names: List[String] = ["id", "name", "amount", "active", "day", "qty"]
    for i in range(len(names)):
        assert_equal(schema.field_name(i), names[i])
        assert_true(schema.field_nullable(i), names[i])
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(1) == ArrowType.STRING)
    assert_true(schema.field_arrow_type(2) == ArrowType.FLOAT64)
    assert_true(schema.field_arrow_type(3) == ArrowType.BOOL)
    assert_true(schema.field_arrow_type(4) == ArrowType.DATE32)
    assert_true(schema.field_arrow_type(5) == ArrowType.INT32)


def test_a_table_directory_is_resolved_through_its_version_hint() raises:
    var dir = _table("hinted", True)
    var source = ParquetFooters().iceberg_relation(dir, False, None)
    assert_true(source.is_binding_backed())
    ref binding = source.binding_ref()
    assert_equal(binding.kind_name, String(_KIND))
    assert_equal(binding.name, dir + "/metadata/v1.metadata.json")
    assert_equal(
        binding.params.get_str(String("metadata_path")),
        dir + "/metadata/v1.metadata.json",
    )
    assert_equal(binding.params.get_str(String("table_root")), dir)
    assert_false(binding.params.get_bool(String("allow_moved_paths")))
    assert_equal(Int(binding.params.get_i64(String("snapshot_id"))), -1)
    assert_equal(Int(binding.params.get_i64(String("schema_id"))), 0)
    _assert_columns(source)


def test_a_metadata_file_is_resolved_directly() raises:
    var dir = _table("direct", False)
    var file = dir + "/metadata/v1.metadata.json"
    var source = ParquetFooters().iceberg_relation(file, False, None)
    ref binding = source.binding_ref()
    assert_equal(binding.params.get_str(String("metadata_path")), file)
    assert_equal(binding.params.get_str(String("table_root")), dir)
    _assert_columns(source)


def test_allow_moved_paths_reaches_the_binding() raises:
    var dir = _table("moved", True)
    var footers = ParquetFooters()
    var plain = footers.iceberg_relation(dir, False, None)
    var moved = footers.iceberg_relation(dir, True, None)
    assert_true(moved.binding_ref().params.get_bool(String("allow_moved_paths")))
    assert_false(plain.binding_ref().params.get_bool(String("allow_moved_paths")))
    assert_true(plain.fingerprint() != moved.fingerprint())


def test_a_bind_of_iceberg_scan_reads_the_table_through_the_footers() raises:
    var dir = _table("bound", True)
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    var bound = bind_statement(
        parse_sql(
            tokenize("SELECT id, qty FROM iceberg_scan('" + dir + "') WHERE id > 1")
        ),
        catalog,
        footers,
    )
    var plan = bound.take_plan()
    assert_equal(plan.output_schema.num_columns(), 2)
    assert_equal(plan.output_schema.field_name(0), "id")
    assert_equal(plan.output_schema.field_name(1), "qty")
    var refused = False
    try:
        _ = bind_statement(
            parse_sql(
                tokenize("SELECT nope FROM iceberg_scan('" + dir + "')")
            ),
            catalog,
            footers,
        )
    except e:
        refused = True
    assert_true(refused)


def test_a_table_without_a_version_hint_is_refused() raises:
    var dir = _table("unhinted", False)
    var m = _refusal(dir)
    assert_true(m.startswith("ICEBERG_TABLE_VERSION_UNKNOWN: "), m)
    assert_true(dir in m, m)


def test_a_missing_table_is_refused() raises:
    var path = test_tmpdir() + "/ice_does_not_exist"
    var m = _refusal(path)
    assert_true(m.byte_length() > 0)
    assert_true(path in m, m)


def test_a_snapshot_the_table_lacks_is_refused() raises:
    var dir = _table("snapshots", True)
    var m = _refusal(dir, False, Int64(42))
    assert_true(m.startswith("ICEBERG_SNAPSHOT_NOT_FOUND: "), m)
    assert_true("42" in m, m)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# run_sql over an Iceberg table with no snapshot: iceberg_scan and registration
# =============================================================================
#
# Covers: run_sql over an Iceberg table written in the test (format version 2,
# three columns, no snapshot): iceberg_scan of a table directory and of its
# metadata file answers the schema and no row, under a projection, a filter, an
# ORDER BY and count(*); allow_moved_paths is accepted; a snapshot the table
# lacks, a directory with no version hint and an s3:// path are named refusals
# at step bind; every other DuckDB option is refused at step parse by its exact
# message; register_iceberg_table over a StorageBasedCatalog (a bare path and a
# file:/// URI) is queried by name without regard to case, passes
# allow_moved_paths, and refuses an unknown table and a location off the local
# file system by exact message; an Iceberg and a Parquet table join in either
# order; the kind name lowering cuts an Iceberg scan by is the binding's.
#
# Each test writes a format-version 2 table under `test_tmpdir()` (a directory
# of its own per test) that has three columns (id BIGINT, name VARCHAR, amount
# DOUBLE) and no snapshot, so it holds no file and needs no manifest. Tables
# with files, deletes and pruning, and the comparison with DuckDB, are
# `komira_iceberg_scan_conformance`'s.
#
# What each test proves:
#   * test_a_table_with_no_snapshot_has_its_schema_and_no_rows: `SELECT *` over
#     `iceberg_scan('<dir>')` answers the three columns in schema order with
#     their types and no row; a projection, a filter on a column, an ORDER BY
#     and `count(*)` answer no row and 0.
#   * test_a_metadata_file_and_allow_moved_paths_are_read: the path of the metadata
#     file (no version hint needed) and `allow_moved_paths = true | false` are
#     accepted and answer the same empty table.
#   * test_a_snapshot_the_table_lacks_is_refused_at_bind: ICEBERG_SNAPSHOT_NOT_FOUND.
#   * test_options_duckdb_has_but_this_engine_lacks_are_refused_at_parse: a
#     refusal at step `parse` with the message that names the option.
#   * test_a_table_without_a_version_hint_is_refused_at_bind: a table directory
#     with no hint is ICEBERG_TABLE_VERSION_UNKNOWN naming the directory.
#   * test_an_s3_path_is_refused_at_bind: ICEBERG_PATH_UNSUPPORTED.
#   * test_a_table_registered_through_a_storage_based_catalog_is_queried_by_name:
#     a bare metadata path and a `file:///` URI register under two names, found
#     without regard to case, answering the schema and no row.
#   * test_registration_options_and_refusals: allow_moved_paths reaches the
#     scan; a table the catalog does not know and a metadata location off the
#     local file system register nothing and are refused by exact message.
#   * test_an_iceberg_table_and_a_parquet_table_in_one_query: a join of a
#     registered Parquet table with an `iceberg_scan` relation answers 0 rows,
#     each scan with its own facts.
#   * test_the_cutters_kind_name_is_the_bindings: the kind name `lowering` spells
#     for an Iceberg scan is the one `iceberg_scan` gives its binding.
# =============================================================================

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from iceberg_catalog import StorageBasedCatalog
from iceberg_scan.table_ref import ICEBERG_SCAN_KIND_NAME
from lowering.cut_scan import ICEBERG_TABLE_KIND_NAME
from parquet_writer.record_batch_writer import write_record_batch_to_parquet_bytes
from runtime_paths import test_tmpdir
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_iceberg import register_iceberg_table
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import SqlOutcome, STEP_BIND, STEP_PARSE, run_sql

comptime _METADATA: String = (
    '{\n'
    '  "format-version": 2,\n'
    '  "table-uuid": "7d3c2f6e-0000-4000-8000-000000000002",\n'
    '  "location": "file:///warehouse/db/orders",\n'
    '  "last-sequence-number": 0,\n'
    '  "last-updated-ms": 1790000000000,\n'
    '  "last-column-id": 3,\n'
    '  "current-schema-id": 0,\n'
    '  "schemas": [{"type": "struct", "schema-id": 0, "fields": [\n'
    '    {"id": 1, "name": "id", "required": true, "type": "long"},\n'
    '    {"id": 2, "name": "name", "required": false, "type": "string"},\n'
    '    {"id": 3, "name": "amount", "required": false, "type": "double"}]}],\n'
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

comptime _TAIL: String = (
    " It is REJECTED rather than ignored — an ignored option can change the"
    " result silently."
)


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def _put(path: String, text: String) raises:
    var fh = open(path, "w")
    fh.write(text)
    fh.close()


def _table(name: String, with_hint: Bool = True) raises -> String:
    """A table directory `<tmp>/ice_<name>`; its path."""
    var dir = test_tmpdir() + "/ice_" + name
    makedirs(dir + "/metadata", exist_ok=True)
    _put(dir + "/metadata/v1.metadata.json", String(_METADATA))
    if with_hint:
        _put(dir + "/metadata/version-hint.text", "1")
    return dir^


def _run(mut ctx: EngineContext, sql: String) raises -> SqlOutcome:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason + " -- " + sql,
        )
    return out^


def _rows(ref out: SqlOutcome) -> Int:
    var n = 0
    for b in range(len(out.batches)):
        n += out.batches[b].num_rows()
    return n


def _count(mut ctx: EngineContext, sql: String) raises -> Int:
    var out = _run(ctx, sql)
    assert_equal(len(out.batches), 1, sql)
    assert_equal(out.batches[0].num_rows(), 1, sql)
    return Int(out.batches[0].column_at(0).as_primitive[DType.int64]().get(0))


def _refusal_of(mut ctx: EngineContext, sql: String, step: String) raises -> String:
    """The reason `run_sql` refuses `sql` at `step`; fails on any other
    outcome."""
    var out = run_sql(ctx, sql)
    assert_false(out.ok(), "expected a refusal: " + sql)
    assert_equal(out.refusal.value().step, step, sql)
    assert_equal(len(out.batches), 0)
    return String(out.refusal.value().reason)


def test_a_table_with_no_snapshot_has_its_schema_and_no_rows() raises:
    var dir = _table("schema")
    var ctx = _new_context()
    var full = _run(ctx, "SELECT * FROM iceberg_scan('" + dir + "')")
    assert_equal(_rows(full), 0)
    assert_equal(len(full.batches), 1)
    ref schema = full.batches[0].schema
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(0), "id")
    assert_equal(schema.field_name(1), "name")
    assert_equal(schema.field_name(2), "amount")
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(1) == ArrowType.STRING)
    assert_true(schema.field_arrow_type(2) == ArrowType.FLOAT64)
    var cut = _run(
        ctx,
        "SELECT name, id FROM iceberg_scan('" + dir
        + "') WHERE id > 5 ORDER BY id",
    )
    assert_equal(_rows(cut), 0)
    assert_equal(cut.batches[0].schema.num_columns(), 2)
    assert_equal(cut.batches[0].schema.field_name(0), "name")
    assert_equal(cut.batches[0].schema.field_name(1), "id")
    assert_equal(_count(ctx, "SELECT count(*) FROM iceberg_scan('" + dir + "')"), 0)
    assert_equal(
        _count(
            ctx,
            "SELECT count(*) FROM iceberg_scan('" + dir + "') WHERE amount < 1.5",
        ),
        0,
    )


def test_a_metadata_file_and_allow_moved_paths_are_read() raises:
    var dir = _table("options", False)
    var file = dir + "/metadata/v1.metadata.json"
    var ctx = _new_context()
    assert_equal(
        _count(ctx, "SELECT count(*) FROM iceberg_scan('" + file + "')"), 0
    )
    assert_equal(
        _count(
            ctx,
            "SELECT count(*) FROM iceberg_scan('" + file
            + "', allow_moved_paths = true)",
        ),
        0,
    )
    assert_equal(
        _count(
            ctx,
            "SELECT count(*) FROM iceberg_scan('" + file
            + "', allow_moved_paths = false)",
        ),
        0,
    )


def test_a_snapshot_the_table_lacks_is_refused_at_bind() raises:
    var dir = _table("no_snapshot_42")
    var ctx = _new_context()
    var reason = _refusal_of(
        ctx,
        "SELECT * FROM iceberg_scan('" + dir + "', snapshot_from_id = 42)",
        STEP_BIND,
    )
    assert_true(reason.startswith("ICEBERG_SNAPSHOT_NOT_FOUND: "), reason)
    assert_true("42" in reason, reason)


def test_options_duckdb_has_but_this_engine_lacks_are_refused_at_parse() raises:
    var dir = _table("unknown_options")
    var ctx = _new_context()
    var names: List[String] = [
        "version", "version_name_format", "mode", "metadata_compression_codec",
        "skip_schema_inference", "snapshot_from_timestamp",
    ]
    for i in range(len(names)):
        assert_equal(
            _refusal_of(
                ctx,
                "SELECT * FROM iceberg_scan('" + dir + "', " + names[i]
                + " = 'x')",
                STEP_PARSE,
            ),
            "SQL not supported: iceberg_scan option '" + names[i]
            + "' is not implemented." + _TAIL,
        )


def test_a_table_without_a_version_hint_is_refused_at_bind() raises:
    var dir = _table("unhinted", False)
    var ctx = _new_context()
    var reason = _refusal_of(
        ctx, "SELECT * FROM iceberg_scan('" + dir + "')", STEP_BIND
    )
    assert_true(reason.startswith("ICEBERG_TABLE_VERSION_UNKNOWN: "), reason)
    assert_true(dir in reason, reason)


def test_an_s3_path_is_refused_at_bind() raises:
    var ctx = _new_context()
    assert_equal(
        _refusal_of(
            ctx, "SELECT * FROM iceberg_scan('s3://bucket/db/orders')", STEP_BIND
        ),
        "ICEBERG_PATH_UNSUPPORTED: 's3://bucket/db/orders' has the scheme 's3';"
        " only local files (a bare path or a file: URI) are read",
    )


def test_a_table_registered_through_a_storage_based_catalog_is_queried_by_name() raises:
    var dir = _table("registered")
    var catalog = StorageBasedCatalog()
    catalog.register("db", "bare", dir + "/metadata/v1.metadata.json")
    catalog.register("db", "uri", "file://" + dir + "/metadata/v1.metadata.json")
    var ctx = _new_context()
    register_iceberg_table(ctx, "Orders", catalog, "db", "bare")
    register_iceberg_table(ctx, "orders_uri", catalog, "db", "uri")
    assert_true(ctx.catalog.has("orders"))
    assert_true(ctx.catalog.has("ORDERS_URI"))
    assert_equal(len(ctx.tables), 0)
    var full = _run(ctx, "SELECT * FROM orders")
    assert_equal(_rows(full), 0)
    assert_equal(full.batches[0].schema.num_columns(), 3)
    assert_equal(full.batches[0].schema.field_name(1), "name")
    assert_equal(_count(ctx, "SELECT count(*) FROM ORDERS WHERE id = 1"), 0)
    assert_equal(_count(ctx, "SELECT count(*) FROM orders_uri"), 0)


def test_registration_options_and_refusals() raises:
    var dir = _table("registration")
    var catalog = StorageBasedCatalog()
    catalog.register("db", "t", dir + "/metadata/v1.metadata.json")
    catalog.register("db", "remote", "s3://bucket/db/remote/metadata/v1.metadata.json")
    var ctx = _new_context()
    register_iceberg_table(ctx, "plain", catalog, "db", "t")
    register_iceberg_table(ctx, "moved", catalog, "db", "t", True)
    assert_false(
        ctx.catalog.table_of("plain").source.binding_ref().params.get_bool(
            String("allow_moved_paths")
        )
    )
    assert_true(
        ctx.catalog.table_of("moved").source.binding_ref().params.get_bool(
            String("allow_moved_paths")
        )
    )
    var unknown = String("")
    try:
        register_iceberg_table(ctx, "nope", catalog, "db", "nope")
    except e:
        unknown = String(e)
    assert_equal(
        unknown,
        "IcebergCatalogError: no table registered for 'db.nope'"
        " (StorageBasedCatalog)",
    )
    assert_false(ctx.catalog.has("nope"))
    var remote = String("")
    try:
        register_iceberg_table(ctx, "remote", catalog, "db", "remote")
    except e:
        remote = String(e)
    assert_equal(
        remote,
        "ICEBERG_PATH_UNSUPPORTED: 's3://bucket/db/remote/metadata/v1.metadata.json'"
        " has the scheme 's3'; only local files (a bare path or a file: URI)"
        " are read",
    )
    assert_false(ctx.catalog.has("remote"))
    catalog.register("db", "host", "file://example/db/host/v1.metadata.json")
    var host = String("")
    try:
        register_iceberg_table(ctx, "host", catalog, "db", "host")
    except e:
        host = String(e)
    assert_equal(
        host,
        "ICEBERG_PATH_UNSUPPORTED: 'file://example/db/host/v1.metadata.json'"
        " names a host; only local files are read",
    )
    assert_false(ctx.catalog.has("host"))


def _ids(first: Int, n: Int) raises -> RecordBatch:
    var ids = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        ids.set(i, Int64(first + i))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](ids^))
    return rb.build(sb.build())


def test_an_iceberg_table_and_a_parquet_table_in_one_query() raises:
    var dir = _table("with_parquet")
    var pq_dir = test_tmpdir() + "/ice_with_parquet_files"
    makedirs(pq_dir, exist_ok=True)
    var bytes = write_record_batch_to_parquet_bytes(_ids(1, 5))
    var fh = open(pq_dir + "/p.parquet", "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    var ctx = _new_context()
    register_parquet(ctx, "p", pq_dir + "/p.parquet")
    assert_equal(_count(ctx, "SELECT count(*) FROM p"), 5)
    assert_equal(
        _count(
            ctx,
            "SELECT count(*) FROM p JOIN iceberg_scan('" + dir
            + "') AS i ON p.id = i.id",
        ),
        0,
    )
    assert_equal(
        _count(
            ctx,
            "SELECT count(*) FROM iceberg_scan('" + dir
            + "') AS i JOIN p ON p.id = i.id",
        ),
        0,
    )


def test_the_cutters_kind_name_is_the_bindings() raises:
    assert_equal(String(ICEBERG_TABLE_KIND_NAME), String(ICEBERG_SCAN_KIND_NAME))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

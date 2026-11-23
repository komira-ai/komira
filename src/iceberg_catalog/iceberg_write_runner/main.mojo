# =============================================================================
# iceberg_write_runner -- write three Iceberg tables through write_table, into
#   a directory, for a foreign reader (DuckDB's iceberg extension) to read back
# =============================================================================
#
# The program behind the `:iceberg_write_komira` build action
# (iceberg_write_cases.bzl), whose files `:iceberg_readback_oracle` and
# `test_iceberg_foreign_readback` read.
#
#   iceberg_write_runner --out-dir <dir>
#
# It creates `<dir>`, an in-process catalog with the namespace `db`, and a
# LocalFsConditionalStore rooted at `<dir>/store` that serves `s3://wh`. Every
# id comes from SequenceCommitIds: write k (counting from 1, across all the
# tables below, in this order) draws the uuid `00000000-0000-7000-8000-<2k-1>`
# for its files, then the snapshot id `100 + k`, then the commit id
# `00000000-0000-7000-8000-<2k>`; the clock is a ManualCommitClock. The tables
# hold id long (required, field id 10), name string, amount double, flag
# boolean, day date and qty int (field ids 11 to 15), all but id optional:
#
#   db.appended    write 1  append  3 rows (ids 1 to 3, the second with null
#                                   name, amount, flag, day and qty)
#                  write 2  append  2 rows (ids 10 and 11)
#   db.overwritten write 3  append  3 rows (ids 1 to 3, the second with nulls)
#                  write 4  overwrite with 2 rows (ids 100, with nulls, and 101)
#   db.emptied     write 5  append  2 rows (ids 1 and 2)
#                  write 6  overwrite with an empty batch
#
# Row v has name `n<v>`, amount v + 0.5, flag v is even, day 20800 + v (days
# since 1970-01-01) and qty 2 * v. Each table is created by a staged create
# and one commit, so after its two writes its metadata is `v3.metadata.json`.
# A table's files are named by the table location `s3://wh/db/<table>`: data
# files `data/<uuid>-0.parquet`, manifests `metadata/<uuid>-m0.avro`, lists
# `metadata/snap-<snapshot id>-0-<uuid>.avro`.
#
# After the writes the current metadata JSON of each table is put at its
# metadata location, and every object of the store is written as a plain file
# at `<dir>/<key>` (the store's own files are flat, with encoded names), so
# `<dir>/db/<table>/metadata/v3.metadata.json` and the files it names lie in a
# table directory a reader can open. A refused write, or a flag missing, ends
# the program with an error naming it, so the build action fails.

from std.os import makedirs
from std.sys import argv

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.string_array import StringArray
from containers.slab import Slab
from fs.atomic_write import write_file_atomic
from json import JsonValue, parse_json_value
from objectstore.local_fs_conditional_store import LocalFsConditionalStore
from objectstore.path import Path

from iceberg_catalog.iceberg_commit import ManualCommitClock, SequenceCommitIds
from iceberg_catalog.iceberg_rest_catalog_client import (
    COMMIT_APPLIED,
    IcebergRestCatalog,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_rest_test_catalog import (
    InMemoryIcebergRestCatalog,
)
from iceberg_catalog.iceberg_table_changes import (
    CreateTableRequest,
    TableRequirement,
    TableUpdate,
    commit_table_body,
)
from iceberg_catalog.iceberg_table_files import TableFiles
from iceberg_catalog.iceberg_write_sink import write_table


comptime _Client = IcebergRestCatalog[
    InMemoryIcebergRestCatalog, StaticBearerToken
]
comptime _Files = TableFiles[LocalFsConditionalStore]

comptime _T0: Int64 = 1795132800000

comptime _SIX: String = (
    '{"id":10,"name":"id","required":true,"type":"long"},'
    '{"id":11,"name":"name","required":false,"type":"string"},'
    '{"id":12,"name":"amount","required":false,"type":"double"},'
    '{"id":13,"name":"flag","required":false,"type":"boolean"},'
    '{"id":14,"name":"day","required":false,"type":"date"},'
    '{"id":15,"name":"qty","required":false,"type":"int"}'
)


def _flag(name: String) raises -> String:
    var args = argv()
    for i in range(1, len(args) - 1):
        if String(args[i]) == name:
            return String(args[i + 1])
    raise Error("iceberg_write_runner: missing " + name + " <value>")


def _schema_value() raises -> JsonValue:
    return parse_json_value(
        String('{"type":"struct","fields":[') + _SIX + String("]}")
    )


def _create_table(mut client: _Client, name: String) raises:
    """A staged create, then the commit that makes the table appear."""
    var staged = client.create_table(
        String("db"),
        CreateTableRequest(
            String(name), _schema_value(), stage_create=True
        ),
    )
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_create())
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.assign_uuid(String(staged.metadata.table_uuid)))
    ups.append(TableUpdate.upgrade_format_version(2))
    ups.append(TableUpdate.add_schema(_schema_value()))
    ups.append(TableUpdate.set_current_schema(-1))
    ups.append(
        TableUpdate.add_spec(
            parse_json_value(String('{"spec-id":0,"fields":[]}'))
        )
    )
    ups.append(TableUpdate.set_default_spec(-1))
    ups.append(
        TableUpdate.add_sort_order(
            parse_json_value(String('{"order-id":0,"fields":[]}'))
        )
    )
    ups.append(TableUpdate.set_default_sort_order(-1))
    ups.append(TableUpdate.set_location(String(staged.metadata.location)))
    var resp = client.commit_table(
        String("db"), name, commit_table_body(reqs, ups), String("")
    )
    if resp.kind != COMMIT_APPLIED:
        raise Error(
            "iceberg_write_runner: creating db." + name + " was not applied: "
            + resp.message
        )


def _six_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("name", ArrowType.STRING, True))
    sb.add_field(Field("amount", ArrowType.FLOAT64, True))
    sb.add_field(Field("flag", ArrowType.BOOL, True))
    sb.add_field(Field("day", ArrowType.DATE32, True))
    sb.add_field(Field("qty", ArrowType.INT32, True))
    return sb.build()


def _batch(n: Int, base: Int, null_at: Int) raises -> RecordBatch:
    """Row `base + i` is the row of the module header; row `null_at` has null
    name, amount, flag, day and qty (none when `null_at` is -1)."""
    var id = PrimitiveArray[DType.int64].allocate(n)
    var names = List[String]()
    var valid = List[Bool]()
    var amount = PrimitiveArray[DType.float64].allocate_nullable(n)
    var flag = BooleanArray.allocate_nullable(n)
    var day = PrimitiveArray[DType.int32].allocate_nullable(n)
    var qty = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        var v = base + i
        id.set(i, Int64(v))
        names.append(String("n") + String(v))
        valid.append(i != null_at)
        if i == null_at:
            amount._set_null(i)
            flag._set_null(i)
            day._set_null(i)
            qty._set_null(i)
        else:
            amount.set(i, Float64(v) + 0.5)
            flag.set(i, v % 2 == 0)
            day.set(i, Int32(20800 + v))
            qty.set(i, Int32(2 * v))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](id))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(names, valid))
    )
    rb.add_column(Column.from_primitive[DType.float64](amount))
    rb.add_column(Column.from_boolean(flag))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](day, ArrowType.DATE32)
    )
    rb.add_column(Column.from_primitive[DType.int32](qty))
    return rb.build(_six_schema())


def _write(
    mut client: _Client,
    files: _Files,
    mut clock: ManualCommitClock,
    mut ids: SequenceCommitIds,
    table: String,
    var batch: RecordBatch,
    overwrite: Bool,
) raises:
    var batches = Slab[RecordBatch]()
    batches.append(batch^)
    var outcome = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        table,
        batches,
        overwrite,
        List[Int64](),
    )
    if not outcome.committed:
        raise Error(
            "iceberg_write_runner: a write to db." + table + " failed: "
            + outcome.message
        )


def _put_metadata(
    mut client: _Client, files: _Files, table: String
) raises:
    """Put the table's current metadata JSON at its metadata location."""
    var loaded = client.load_table(String("db"), table)
    files.put(loaded.metadata_location, List[UInt8](loaded.metadata.as_bytes()))


def _publish(store: LocalFsConditionalStore, out_dir: String) raises:
    """Write every object of `store` as a plain file at `<out_dir>/<key>`."""
    var listed = store.list_with_delimiter(Path.parse(String("")))
    for i in range(len(listed.objects)):
        var key = String(listed.objects[i].location)
        var bytes = store.get(Path.parse(key))
        var slash = key.rfind("/")
        if slash > 0:
            makedirs(out_dir + "/" + String(key[byte = 0 : slash]), exist_ok=True)
        write_file_atomic(out_dir + "/" + key, Span(bytes))


def main() raises:
    var out_dir = _flag("--out-dir")
    makedirs(out_dir, exist_ok=True)
    var store = LocalFsConditionalStore(out_dir + "/store")
    var files = _Files(store.clone(), String("s3://wh"))
    var cat = InMemoryIcebergRestCatalog(String(""), String("s3://wh"))
    cat.create_namespace(String("db"))
    var client = _Client(
        String("catalog.example.com"), cat^, StaticBearerToken(String(""))
    )
    var clock = ManualCommitClock(_T0)
    var snapshot_ids = List[Int64]()
    for k in range(1, 7):
        snapshot_ids.append(Int64(100 + k))
    var ids = SequenceCommitIds(snapshot_ids^)

    _create_table(client, String("appended"))
    _create_table(client, String("overwritten"))
    _create_table(client, String("emptied"))

    _write(client, files, clock, ids, String("appended"), _batch(3, 1, 1), False)
    _write(client, files, clock, ids, String("appended"), _batch(2, 10, -1), False)

    _write(client, files, clock, ids, String("overwritten"), _batch(3, 1, 1), False)
    _write(client, files, clock, ids, String("overwritten"), _batch(2, 100, 0), True)

    _write(client, files, clock, ids, String("emptied"), _batch(2, 1, -1), False)
    _write(
        client,
        files,
        clock,
        ids,
        String("emptied"),
        RecordBatch.empty_from_schema(_six_schema()),
        True,
    )

    _put_metadata(client, files, String("appended"))
    _put_metadata(client, files, String("overwritten"))
    _put_metadata(client, files, String("emptied"))
    _publish(store, out_dir)

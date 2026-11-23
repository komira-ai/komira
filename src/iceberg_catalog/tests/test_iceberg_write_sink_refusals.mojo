# =============================================================================
# test_iceberg_write_sink_refusals.mojo — what write_table refuses, by exact
#   message, and what it cleans up when a statement fails before the commit.
# =============================================================================
#
# Each refusal asserts the whole message, that the statement did not commit
# or post, and that the catalog and the store are as they were (or, for a
# failure after some data files were written, that exactly those files were
# deleted):
#
#   * a v1 table, a missing table, a table without columns;
#   * a batch with another column count (the second of two batches named), a
#     column of another type, an Arrow type the writer does not write, a table
#     type outside the first slice;
#   * a data path or a metadata path outside the table's location, an unknown
#     codec;
#   * a null in a required column after an earlier batch's file was written;
#   * a store that does not serve the file's URI, and one that does not serve
#     the manifest's (the data file is deleted);
#   * a store whose put fails after the first file, and whose delete fails
#     (reported in `delete_failures`, the outcome unchanged).
# The helpers `table_schema_json`, `table_data_path`, `table_metadata_path` and
# `table_parquet_codec` are tested directly.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from arrow.string_array import StringArray
from containers.slab import Slab
from json import JsonValue, parse_json_value
from objectstore.path import Path
from objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)
from parquet_api.types import CompressionCodec

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
from iceberg_catalog.iceberg_table_metadata import (
    SchemaField,
    TableMetadata,
    TableSchema,
)
from iceberg_catalog.iceberg_write_sink import (
    TableWriteOutcome,
    table_data_path,
    table_metadata_path,
    table_parquet_codec,
    table_schema_json,
    write_table,
)


comptime _Client = IcebergRestCatalog[
    InMemoryIcebergRestCatalog, StaticBearerToken
]
comptime _Files = TableFiles[SharedInMemoryConditionalStore]

comptime _T0: Int64 = 1795132800000

comptime _SIX: String = (
    '{"id":10,"name":"id","required":true,"type":"long"},'
    '{"id":11,"name":"name","required":false,"type":"string"},'
    '{"id":12,"name":"amount","required":false,"type":"double"},'
    '{"id":13,"name":"flag","required":false,"type":"boolean"},'
    '{"id":14,"name":"day","required":false,"type":"date"},'
    '{"id":15,"name":"qty","required":false,"type":"int"}'
)

comptime _DECIMAL: String = (
    '{"id":1,"name":"amount","required":false,"type":"decimal(9,2)"}'
)


# -----------------------------------------------------------------------------
# a store whose put and delete can be made to fail.
# -----------------------------------------------------------------------------


struct _FaultStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """A SharedInMemoryConditionalStore whose `put` raises for a key that
    contains `fail_put_containing` (when non-empty) and whose `delete` raises
    when `fail_delete`."""

    var inner: SharedInMemoryConditionalStore
    var fail_put_containing: String
    var fail_delete: Bool

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var fail_put_containing: String,
        fail_delete: Bool,
    ):
        self.inner = inner^
        self.fail_put_containing = fail_put_containing^
        self.fail_delete = fail_delete

    def clone(self) -> Self:
        return Self(
            self.inner.clone(),
            String(self.fail_put_containing),
            self.fail_delete,
        )

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        if (
            self.fail_put_containing.byte_length() > 0
            and path.raw().find(self.fail_put_containing) >= 0
        ):
            raise Error(String("fault store: put refused: ") + path.raw())
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        if self.fail_delete:
            raise Error(String("fault store: delete refused: ") + path.raw())
        self.inner.delete(path)


comptime _FaultFiles = TableFiles[_FaultStore]


# -----------------------------------------------------------------------------
# the catalog, its tables and the batches.
# -----------------------------------------------------------------------------


def _uuid(n: Int) -> String:
    """The n-th uuid `SequenceCommitIds` hands out."""
    var digits = String(n)
    var pad = String("")
    for _ in range(12 - digits.byte_length()):
        pad += "0"
    return String("00000000-0000-7000-8000-") + pad + digits


def _schema_value(fields: String) raises -> JsonValue:
    return parse_json_value(
        String('{"type":"struct","fields":[') + fields + String("]}")
    )


def _new_client() -> _Client:
    var cat = InMemoryIcebergRestCatalog(String(""), String("s3://wh"))
    cat.create_namespace(String("db"))
    return _Client(
        String("catalog.example.com"), cat^, StaticBearerToken(String(""))
    )


def _create_table(
    mut client: _Client,
    name: String,
    fields: String,
    format_version: Int,
    props: List[String],
) raises:
    """A staged create, then the commit that makes the table appear. `props`
    is [name, value, name, value, ...]."""
    var staged = client.create_table(
        String("db"),
        CreateTableRequest(
            String(name), _schema_value(fields), stage_create=True
        ),
    )
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_create())
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.assign_uuid(String(staged.metadata.table_uuid)))
    ups.append(TableUpdate.upgrade_format_version(format_version))
    ups.append(TableUpdate.add_schema(_schema_value(fields)))
    ups.append(TableUpdate.set_current_schema(-1))
    ups.append(
        TableUpdate.add_spec(parse_json_value(String('{"spec-id":0,"fields":[]}')))
    )
    ups.append(TableUpdate.set_default_spec(-1))
    ups.append(
        TableUpdate.add_sort_order(
            parse_json_value(String('{"order-id":0,"fields":[]}'))
        )
    )
    ups.append(TableUpdate.set_default_sort_order(-1))
    ups.append(TableUpdate.set_location(String(staged.metadata.location)))
    if len(props) > 0:
        var names = List[String]()
        var values = List[String]()
        for i in range(0, len(props), 2):
            names.append(String(props[i]))
            values.append(String(props[i + 1]))
        ups.append(TableUpdate.set_properties(names^, values^))
    var resp = client.commit_table(
        String("db"), name, commit_table_body(reqs, ups), String("")
    )
    assert_equal(resp.kind, COMMIT_APPLIED)


def _props(name: String, value: String) -> List[String]:
    var p = List[String]()
    p.append(String(name))
    p.append(String(value))
    return p^


def _table(mut client: _Client, name: String) raises:
    _create_table(client, name, _SIX, 2, List[String]())


def _batch(
    n: Int, base: Int, id_null_at: Int, qty_kind: Int
) raises -> RecordBatch:
    """Six columns, `n` rows `base`, `base + 1`, ...: id, name, amount, flag,
    day and qty, the last an int32 (`qty_kind` 0), an int64 (1) or an int8
    (2). Row `id_null_at` has a null id."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("name", ArrowType.STRING, True))
    sb.add_field(Field("amount", ArrowType.FLOAT64, True))
    sb.add_field(Field("flag", ArrowType.BOOL, True))
    sb.add_field(Field("day", ArrowType.DATE32, True))
    if qty_kind == 1:
        sb.add_field(Field("qty", ArrowType.INT64, True))
    elif qty_kind == 2:
        sb.add_field(Field("qty", ArrowType.INT8, True))
    else:
        sb.add_field(Field("qty", ArrowType.INT32, True))
    var id = PrimitiveArray[DType.int64].allocate_nullable(n)
    var names = List[String]()
    var valid = List[Bool]()
    var amount = PrimitiveArray[DType.float64].allocate(n)
    var flag = BooleanArray.allocate(n)
    var day = PrimitiveArray[DType.int32].allocate(n)
    for i in range(n):
        if i == id_null_at:
            id._set_null(i)
        else:
            id.set(i, Int64(base + i))
        names.append(String("n") + String(base + i))
        valid.append(True)
        amount.set(i, Float64(base + i))
        flag.set(i, True)
        day.set(i, Int32(19000 + base + i))
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
    if qty_kind == 1:
        var q = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            q.set(i, Int64(i))
        rb.add_column(Column.from_primitive[DType.int64](q))
    elif qty_kind == 2:
        var q = PrimitiveArray[DType.int8].allocate(n)
        for i in range(n):
            q.set(i, Int8(i))
        rb.add_column(Column.from_primitive[DType.int8](q))
    else:
        var q = PrimitiveArray[DType.int32].allocate(n)
        for i in range(n):
            q.set(i, Int32(i))
        rb.add_column(Column.from_primitive[DType.int32](q))
    return rb.build(sb.build())


def _one_column(n: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    var id = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        id.set(i, Int64(i))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](id))
    return rb.build(sb.build())


def _slab(var a: RecordBatch) -> Slab[RecordBatch]:
    var s = Slab[RecordBatch]()
    s.append(a^)
    return s^


def _slab2(var a: RecordBatch, var b: RecordBatch) -> Slab[RecordBatch]:
    var s = Slab[RecordBatch]()
    s.append(a^)
    s.append(b^)
    return s^


def _write(
    mut client: _Client,
    files: _Files,
    table: String,
    batches: Slab[RecordBatch],
) -> TableWriteOutcome:
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(List[Int64]())
    return write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        table,
        batches,
        False,
        List[Int64](),
    )


def _write_fault(
    mut client: _Client,
    files: _FaultFiles,
    table: String,
    batches: Slab[RecordBatch],
) -> TableWriteOutcome:
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(List[Int64]())
    return write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        table,
        batches,
        False,
        List[Int64](),
    )


def _object_count(store: SharedInMemoryConditionalStore) raises -> Int:
    var listed = store.list_with_delimiter(Path.parse(String("")))
    return len(listed.objects)


def _data_uri(table: String, index: Int) -> String:
    return (
        String("s3://wh/db/")
        + table
        + String("/data/")
        + _uuid(1)
        + String("-")
        + String(index)
        + String(".parquet")
    )


def _assert_refused(
    o: TableWriteOutcome,
    message: String,
    store: SharedInMemoryConditionalStore,
    client: _Client,
    applied: Int,
) raises:
    """The statement failed with `message` before it posted, deleted nothing
    (it wrote nothing) and left the store and the catalog as they were."""
    assert_false(o.committed)
    assert_equal(o.message, message)
    assert_equal(o.posts, 0)
    assert_equal(o.rows_written, 0)
    assert_equal(o.files_written, 0)
    assert_equal(len(o.deleted), 0)
    assert_equal(len(o.delete_failures), 0)
    assert_equal(_object_count(store), 0)
    assert_equal(client.transport_ref().applied_commits, applied)


def test_a_v1_table_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _create_table(client, String("v1"), _SIX, 1, List[String]())
    var applied = client.transport_ref().applied_commits
    var o = _write(
        client,
        _Files(store.clone(), String("s3://wh")),
        String("v1"),
        _slab(_batch(2, 1, -1, 0)),
    )
    _assert_refused(
        o,
        String(
            "ICEBERG_WRITE_FORMAT_UNSUPPORTED: table 'db.v1' is format version"
            " 1; komira writes version 2 only"
        ),
        store,
        client,
        applied,
    )


def test_a_missing_table_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    var o = _write(
        client,
        _Files(store.clone(), String("s3://wh")),
        String("nope"),
        _slab(_batch(2, 1, -1, 0)),
    )
    _assert_refused(
        o,
        String(
            "ICEBERG_TABLE_NOT_FOUND: loadTable 'db.nope': HTTP 404:"
            " NoSuchTableException: Table does not exist: db.nope"
        ),
        store,
        client,
        0,
    )


def test_a_table_without_columns_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _create_table(client, String("empty"), String(""), 2, List[String]())
    var applied = client.transport_ref().applied_commits
    var o = _write(
        client,
        _Files(store.clone(), String("s3://wh")),
        String("empty"),
        Slab[RecordBatch](),
    )
    _assert_refused(
        o,
        String(
            "ICEBERG_SCHEMA_INCOMPATIBLE: table 'db.empty' has no columns"
        ),
        store,
        client,
        applied,
    )


def test_a_batch_with_another_column_count_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _table(client, String("t"))
    var applied = client.transport_ref().applied_commits
    var files = _Files(store.clone(), String("s3://wh"))
    var first = _write(client, files, String("t"), _slab(_one_column(1)))
    _assert_refused(
        first,
        String(
            "ICEBERG_SCHEMA_INCOMPATIBLE: table 'db.t' has 6 column(s), batch"
            " 0 has 1"
        ),
        store,
        client,
        applied,
    )
    # The second batch is the one named, and the first is not written.
    var second = _write(
        client,
        files,
        String("t"),
        _slab2(_batch(2, 1, -1, 0), _one_column(1)),
    )
    _assert_refused(
        second,
        String(
            "ICEBERG_SCHEMA_INCOMPATIBLE: table 'db.t' has 6 column(s), batch"
            " 1 has 1"
        ),
        store,
        client,
        applied,
    )


def test_a_column_of_another_type_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _table(client, String("t"))
    var applied = client.transport_ref().applied_commits
    var o = _write(
        client,
        _Files(store.clone(), String("s3://wh")),
        String("t"),
        _slab(_batch(2, 1, -1, 1)),
    )
    _assert_refused(
        o,
        String(
            "ICEBERG_SCHEMA_INCOMPATIBLE: table 'db.t': column 'qty' is int in"
            " the table, the batch holds long"
        ),
        store,
        client,
        applied,
    )


def test_an_arrow_type_the_writer_does_not_write_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _table(client, String("t"))
    var applied = client.transport_ref().applied_commits
    var o = _write(
        client,
        _Files(store.clone(), String("s3://wh")),
        String("t"),
        _slab(_batch(2, 1, -1, 2)),
    )
    _assert_refused(
        o,
        String(
            "ICEBERG_TYPE_UNSUPPORTED: column qty has Arrow type int8, which"
            " the Iceberg writer does not write yet"
        ),
        store,
        client,
        applied,
    )


def test_a_table_type_outside_the_first_slice_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _create_table(client, String("dec"), _DECIMAL, 2, List[String]())
    var applied = client.transport_ref().applied_commits
    var o = _write(
        client,
        _Files(store.clone(), String("s3://wh")),
        String("dec"),
        _slab(_one_column(2)),
    )
    _assert_refused(
        o,
        String(
            "ICEBERG_TYPE_UNSUPPORTED: column amount has Iceberg type"
            " decimal(9,2), which the Iceberg writer does not write yet"
        ),
        store,
        client,
        applied,
    )


def test_a_path_outside_the_table_location_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _create_table(
        client,
        String("d1"),
        _SIX,
        2,
        _props(String("write.data.path"), String("s3://elsewhere/data")),
    )
    _create_table(
        client,
        String("m1"),
        _SIX,
        2,
        _props(
            String("write.metadata.path"), String("s3://wh/db/other/metadata")
        ),
    )
    var applied = client.transport_ref().applied_commits
    var files = _Files(store.clone(), String("s3://wh"))
    _assert_refused(
        _write(client, files, String("d1"), _slab(_batch(2, 1, -1, 0))),
        String(
            "ICEBERG_LOCATION_REFUSED: table 'db.d1': data path"
            " s3://elsewhere/data is not under the table location"
            " s3://wh/db/d1"
        ),
        store,
        client,
        applied,
    )
    _assert_refused(
        _write(client, files, String("m1"), _slab(_batch(2, 1, -1, 0))),
        String(
            "ICEBERG_LOCATION_REFUSED: table 'db.m1': metadata path"
            " s3://wh/db/other/metadata is not under the table location"
            " s3://wh/db/m1"
        ),
        store,
        client,
        applied,
    )


def test_an_unknown_codec_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _create_table(
        client,
        String("c1"),
        _SIX,
        2,
        _props(String("write.parquet.compression-codec"), String("brotli")),
    )
    var applied = client.transport_ref().applied_commits
    var o = _write(
        client,
        _Files(store.clone(), String("s3://wh")),
        String("c1"),
        _slab(_batch(2, 1, -1, 0)),
    )
    _assert_refused(
        o,
        String(
            "ICEBERG_WRITE_FORMAT_UNSUPPORTED: table 'db.c1' property"
            " write.parquet.compression-codec is 'brotli'; komira writes zstd,"
            " snappy, gzip, uncompressed or lz4"
        ),
        store,
        client,
        applied,
    )


def test_a_null_in_a_required_column_deletes_the_files_already_written() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _table(client, String("t"))
    var applied = client.transport_ref().applied_commits

    var o = _write(
        client,
        _Files(store.clone(), String("s3://wh")),
        String("t"),
        _slab2(_batch(2, 1, -1, 0), _batch(3, 10, 1, 0)),
    )

    assert_false(o.committed)
    assert_equal(
        o.message,
        String(
            "ICEBERG_NULL_IN_REQUIRED_COLUMN: column id is required and the"
            " rows hold 1 null(s)"
        ),
    )
    assert_equal(o.posts, 0)
    assert_equal(len(o.deleted), 1)
    assert_equal(o.deleted[0], _data_uri(String("t"), 0))
    assert_equal(len(o.delete_failures), 0)
    assert_equal(_object_count(store), 0)
    assert_equal(client.transport_ref().applied_commits, applied)


def test_a_store_that_does_not_serve_the_file_uri_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _table(client, String("t"))
    var applied = client.transport_ref().applied_commits
    var o = _write(
        client,
        _Files(store.clone(), String("s3://other")),
        String("t"),
        _slab(_batch(2, 1, -1, 0)),
    )
    _assert_refused(
        o,
        String("ICEBERG_LOCATION_REFUSED: ")
        + _data_uri(String("t"), 0)
        + String(" is not under s3://other, the store this write was given"),
        store,
        client,
        applied,
    )


def test_a_store_that_does_not_serve_the_manifest_uri_loses_the_data_file() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _table(client, String("t"))
    var applied = client.transport_ref().applied_commits

    var o = _write(
        client,
        _Files(store.clone(), String("s3://wh/db/t/data")),
        String("t"),
        _slab(_batch(2, 1, -1, 0)),
    )

    assert_false(o.committed)
    assert_equal(
        o.message,
        String(
            "ICEBERG_LOCATION_REFUSED: s3://wh/db/t/metadata/"
        )
        + _uuid(1)
        + String(
            "-m0.avro is not under s3://wh/db/t/data, the store this write was"
            " given"
        ),
    )
    assert_equal(o.posts, 0)
    assert_equal(len(o.deleted), 1)
    assert_equal(o.deleted[0], _data_uri(String("t"), 0))
    assert_equal(_object_count(store), 0)
    assert_equal(client.transport_ref().applied_commits, applied)


def test_a_failed_put_deletes_the_files_already_written() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _table(client, String("t"))
    var applied = client.transport_ref().applied_commits
    var files = _FaultFiles(
        _FaultStore(store.clone(), String("-1.parquet"), False),
        String("s3://wh"),
    )

    var o = _write_fault(
        client,
        files,
        String("t"),
        _slab2(_batch(2, 1, -1, 0), _batch(2, 10, -1, 0)),
    )

    assert_false(o.committed)
    assert_equal(
        o.message,
        String("fault store: put refused: db/t/data/")
        + _uuid(1)
        + String("-1.parquet"),
    )
    assert_equal(o.posts, 0)
    # The first file landed; the second one's put raised, and a put that
    # raises may have landed, so both are deleted (deleting an absent object
    # succeeds).
    assert_equal(len(o.deleted), 2)
    assert_equal(o.deleted[0], _data_uri(String("t"), 0))
    assert_equal(o.deleted[1], _data_uri(String("t"), 1))
    assert_equal(_object_count(store), 0)
    assert_equal(client.transport_ref().applied_commits, applied)


def test_a_failed_delete_is_reported_and_does_not_replace_the_outcome() raises:
    var store = SharedInMemoryConditionalStore()
    var client = _new_client()
    _table(client, String("t"))
    var files = _FaultFiles(
        _FaultStore(store.clone(), String(""), True), String("s3://wh")
    )

    var o = _write_fault(
        client,
        files,
        String("t"),
        _slab2(_batch(2, 1, -1, 0), _batch(3, 10, 1, 0)),
    )

    assert_false(o.committed)
    assert_equal(
        o.message,
        String(
            "ICEBERG_NULL_IN_REQUIRED_COLUMN: column id is required and the"
            " rows hold 1 null(s)"
        ),
    )
    assert_equal(len(o.deleted), 0)
    assert_equal(len(o.delete_failures), 1)
    assert_equal(
        o.delete_failures[0],
        _data_uri(String("t"), 0)
        + String(": fault store: delete refused: db/t/data/")
        + _uuid(1)
        + String("-0.parquet"),
    )
    # The file is still there: the delete failed.
    assert_equal(_object_count(store), 1)


def _metadata(location: String) -> TableMetadata:
    var md = TableMetadata()
    md.location = String(location)
    return md^


def test_the_schema_json_is_the_tables_own() raises:
    var fields = List[SchemaField]()
    fields.append(SchemaField(1, String("id"), True, String("long")))
    fields.append(SchemaField(2, String('a"b'), False, String("string")))
    assert_equal(
        table_schema_json(TableSchema(4, fields^)),
        String(
            '{"type":"struct","schema-id":4,"fields":['
            '{"id":1,"name":"id","required":true,"type":"long"},'
            '{"id":2,"name":"a\\"b","required":false,"type":"string"}]}'
        ),
    )
    assert_equal(
        table_schema_json(TableSchema(0, List[SchemaField]())),
        String('{"type":"struct","schema-id":0,"fields":[]}'),
    )


def test_the_data_and_metadata_paths_default_and_follow_the_properties() raises:
    var md = _metadata(String("s3://wh/db/t/"))
    assert_equal(table_data_path(md, String("db.t")), String("s3://wh/db/t/data"))
    assert_equal(
        table_metadata_path(md, String("db.t")), String("s3://wh/db/t/metadata")
    )
    md.property_names.append(String("write.data.path"))
    md.property_values.append(String("s3://wh/db/t/files//"))
    md.property_names.append(String("write.metadata.path"))
    md.property_values.append(String("s3://wh/db/t/meta"))
    assert_equal(
        table_data_path(md, String("db.t")), String("s3://wh/db/t/files")
    )
    assert_equal(
        table_metadata_path(md, String("db.t")), String("s3://wh/db/t/meta")
    )

    # A directory that is the location itself, or a sibling whose name starts
    # with it, is not under it.
    var same = _metadata(String("s3://wh/db/t"))
    same.property_names.append(String("write.data.path"))
    same.property_values.append(String("s3://wh/db/t"))
    var sibling = _metadata(String("s3://wh/db/t"))
    sibling.property_names.append(String("write.data.path"))
    sibling.property_values.append(String("s3://wh/db/t2/data"))
    var messages = List[String]()
    for i in range(2):
        try:
            if i == 0:
                _ = table_data_path(same, String("db.t"))
            else:
                _ = table_data_path(sibling, String("db.t"))
        except e:
            messages.append(String(e))
    assert_equal(len(messages), 2)
    assert_equal(
        messages[0],
        String(
            "ICEBERG_LOCATION_REFUSED: table 'db.t': data path s3://wh/db/t"
            " is not under the table location s3://wh/db/t"
        ),
    )
    assert_equal(
        messages[1],
        String(
            "ICEBERG_LOCATION_REFUSED: table 'db.t': data path"
            " s3://wh/db/t2/data is not under the table location s3://wh/db/t"
        ),
    )


def _codec_of(value: String) raises -> CompressionCodec:
    var md = _metadata(String("s3://wh/db/t"))
    md.property_names.append(String("write.parquet.compression-codec"))
    md.property_values.append(String(value))
    return table_parquet_codec(md, String("db.t"))


def test_the_codec_property_names_the_parquet_codec() raises:
    assert_true(
        table_parquet_codec(_metadata(String("s3://wh/db/t")), String("db.t"))
        == CompressionCodec.ZSTD
    )
    assert_true(_codec_of(String("zstd")) == CompressionCodec.ZSTD)
    assert_true(_codec_of(String("snappy")) == CompressionCodec.SNAPPY)
    assert_true(_codec_of(String("gzip")) == CompressionCodec.GZIP)
    assert_true(
        _codec_of(String("uncompressed")) == CompressionCodec.UNCOMPRESSED
    )
    assert_true(_codec_of(String("lz4")) == CompressionCodec.LZ4_RAW)
    var message = String("")
    try:
        _ = _codec_of(String("ZSTD"))
    except e:
        message = String(e)
    assert_equal(
        message,
        String(
            "ICEBERG_WRITE_FORMAT_UNSUPPORTED: table 'db.t' property"
            " write.parquet.compression-codec is 'ZSTD'; komira writes zstd,"
            " snappy, gzip, uncompressed or lz4"
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

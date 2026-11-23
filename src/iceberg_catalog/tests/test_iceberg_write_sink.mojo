# =============================================================================
# test_iceberg_write_sink.mojo — write_table end to end: Arrow batches become
#   data files, a manifest and manifest lists in an object store and a commit
#   in the in-process catalog, read back from the catalog's metadata.
# =============================================================================
#
#   * test_append_append_overwrite_read_back_through_the_metadata: two appends
#     and an overwrite. After each the table's rows, read through the catalog
#     metadata -> manifest list -> manifests -> Parquet files with komira's
#     readers, are exactly the live rows; every file's footer carries the
#     table's field ids; the summaries (added, deleted, removed, total) and the
#     object names are exact.
#   * test_a_table_without_rows_to_write_sends_no_commit: no batches, or only
#     an empty batch, writes nothing and commits nothing.
#   * test_a_zero_row_overwrite_empties_the_table: the table has no rows after
#     it, through an empty list and an empty batch, and the summary counts
#     what left.
#   * test_the_table_properties_choose_the_paths_and_codec: write.data.path,
#     write.metadata.path and write.parquet.compression-codec.
#   * test_a_float_column_is_written_and_read_back: a table with a float
#     (Arrow float32) column takes a batch and returns its values.
#   The commit-time cases (a 409, a conflict, an unknown outcome, a foreign
#   base list) are in test_iceberg_write_sink_commit.mojo.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.boolean_array import BooleanArray
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.byte_view import ByteView
from containers.slab import Slab
from iceberg import read_manifest_entries, read_manifest_list
from json import JsonValue, parse_json_value
from objectstore.path import Path
from objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from parquet.file_decode import decode_parquet_file_from_bytes
from parquet.metadata_parser import parse_full_metadata
from parquet_api.metadata import FileMetaData

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
comptime _Files = TableFiles[SharedInMemoryConditionalStore]

comptime _T0: Int64 = 1795132800000

# id long required (10), name string, amount double, flag boolean, day date,
# qty int: field ids 10 to 15, not 1 to 6, so a positional bug and an id bug
# cannot cancel.
comptime _SIX: String = (
    '{"id":10,"name":"id","required":true,"type":"long"},'
    '{"id":11,"name":"name","required":false,"type":"string"},'
    '{"id":12,"name":"amount","required":false,"type":"double"},'
    '{"id":13,"name":"flag","required":false,"type":"boolean"},'
    '{"id":14,"name":"day","required":false,"type":"date"},'
    '{"id":15,"name":"qty","required":false,"type":"int"}'
)


def _uuid(n: Int) -> String:
    """The n-th uuid `SequenceCommitIds` hands out."""
    var digits = String(n)
    var pad = String("")
    for _ in range(12 - digits.byte_length()):
        pad += "0"
    return String("00000000-0000-7000-8000-") + pad + digits


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _footer(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))


# -----------------------------------------------------------------------------
# the catalog and its tables.
# -----------------------------------------------------------------------------


def _new_client() -> _Client:
    var cat = InMemoryIcebergRestCatalog(String(""), String("s3://wh"))
    cat.create_namespace(String("db"))
    return _Client(
        String("catalog.example.com"), cat^, StaticBearerToken(String(""))
    )


def _schema_value(fields: String) raises -> JsonValue:
    return parse_json_value(
        String('{"type":"struct","fields":[') + fields + String("]}")
    )


def _create_table(
    mut client: _Client, name: String, fields: String, props: List[String]
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
    ups.append(TableUpdate.upgrade_format_version(2))
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


def _plain_table(mut client: _Client, name: String) raises:
    _create_table(client, name, _SIX, List[String]())


# -----------------------------------------------------------------------------
# the rows: row `base + i` of a batch is
#   id base+i, name "n<base+i>", amount base+i+0.5, flag (base+i) even,
#   day 19000+base+i, qty 2*(base+i)
# and row `null_at` has null name, amount, flag, day and qty.
# -----------------------------------------------------------------------------


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
            day.set(i, Int32(19000 + v))
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


def _one(var batch: RecordBatch) -> Slab[RecordBatch]:
    var s = Slab[RecordBatch]()
    s.append(batch^)
    return s^


def _none() -> Slab[RecordBatch]:
    return Slab[RecordBatch]()


def _bool_text(b: Bool) -> String:
    if b:
        return String("true")
    return String("false")


def _expected(base: Int, n: Int, null_at: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        var v = base + i
        var row = String(v) + String("|")
        if i == null_at:
            row += String("null|null|null|null|null")
        else:
            row += (
                String("n")
                + String(v)
                + String("|")
                + String(Float64(v) + 0.5)
                + String("|")
                + _bool_text(v % 2 == 0)
                + String("|")
                + String(19000 + v)
                + String("|")
                + String(2 * v)
            )
        out.append(row^)
    return out^


def _sorted(var rows: List[String]) -> List[String]:
    for i in range(1, len(rows)):
        var j = i
        while j > 0 and rows[j - 1] > rows[j]:
            var tmp = String(rows[j - 1])
            rows[j - 1] = String(rows[j])
            rows[j] = tmp^
            j -= 1
    return rows^


def _join(var a: List[String], b: List[String]) -> List[String]:
    for i in range(len(b)):
        a.append(String(b[i]))
    return a^


def _assert_strings(actual: List[String], expected: List[String]) raises:
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i])


# -----------------------------------------------------------------------------
# reading a table back.
# -----------------------------------------------------------------------------


def _append_rows(file: List[UInt8], mut rows: List[String]) raises:
    var back = decode_parquet_file_from_bytes(_view(Span(file)))
    var id = back.column_as_primitive[DType.int64](0)
    var name = back.column_as_string(1)
    var amount = back.column_as_primitive[DType.float64](2)
    var flag = back.column_as_boolean(3)
    var day = back.column_as_primitive[DType.int32](4)
    var qty = back.column_as_primitive[DType.int32](5)
    assert_true(back.schema.field_arrow_type(4) == ArrowType.DATE32)
    for r in range(back.num_rows()):
        var row = String(Int(id.get(r))) + String("|")
        if name.is_null(r):
            row += String("null|null|null|null|null")
        else:
            row += (
                name.get(r)
                + String("|")
                + String(amount.get(r))
                + String("|")
                + _bool_text(flag.get(r))
                + String("|")
                + String(Int(day.get(r)))
                + String("|")
                + String(Int(qty.get(r)))
            )
        rows.append(row^)


def _assert_field_ids(file: List[UInt8]) raises:
    """The footer's leaves carry the table's ids 10..15 in order; the root has
    none."""
    var footer = _footer(file)
    ref schema = footer.schema
    assert_equal(len(schema), 7)
    assert_false(Bool(schema[0].field_id))
    for c in range(6):
        assert_equal(schema[c + 1].field_id.value(), 10 + c)


def _read_back(
    client: _Client, files: _Files, name: String
) raises -> List[String]:
    """The rows of the table's `main` snapshot, by the catalog's metadata, the
    snapshot's manifest list, each manifest and each data file."""
    var md = client.transport_ref().metadata(String("db"), name)
    var rows = List[String]()
    if not md.main_snapshot_id:
        return rows^
    var i = md.snapshot_index(md.main_snapshot_id.value())
    var listed = read_manifest_list(files.get(md.snapshots[i].manifest_list))
    for m in range(len(listed)):
        var entries = read_manifest_entries(files.get(listed[m].manifest_path))
        for e in range(len(entries)):
            var bytes = files.get(entries[e].file_path)
            _assert_field_ids(bytes)
            _append_rows(bytes, rows)
    return _sorted(rows^)


def _object_count(store: SharedInMemoryConditionalStore) raises -> Int:
    var listed = store.list_with_delimiter(Path.parse(String("")))
    return len(listed.objects)


def _size_of(files: _Files, uri: String) raises -> Int:
    return len(files.get(uri))


def _append_names() -> List[String]:
    var n = List[String]()
    n.append(String("operation"))
    n.append(String("added-data-files"))
    n.append(String("added-records"))
    n.append(String("added-files-size"))
    n.append(String("total-data-files"))
    n.append(String("total-records"))
    n.append(String("total-files-size"))
    n.append(String("total-delete-files"))
    n.append(String("total-position-deletes"))
    n.append(String("total-equality-deletes"))
    n.append(String("komira.commit-id"))
    return n^


def _append_values(
    af: Int, ar: Int, asz: Int, tf: Int, tr: Int, tsz: Int, commit_id: String
) -> List[String]:
    var v = List[String]()
    v.append(String("append"))
    v.append(String(af))
    v.append(String(ar))
    v.append(String(asz))
    v.append(String(tf))
    v.append(String(tr))
    v.append(String(tsz))
    v.append(String("0"))
    v.append(String("0"))
    v.append(String("0"))
    v.append(String(commit_id))
    return v^


def _overwrite_names() -> List[String]:
    var n = List[String]()
    n.append(String("operation"))
    n.append(String("added-data-files"))
    n.append(String("added-records"))
    n.append(String("added-files-size"))
    n.append(String("deleted-data-files"))
    n.append(String("deleted-records"))
    n.append(String("removed-files-size"))
    n.append(String("total-data-files"))
    n.append(String("total-records"))
    n.append(String("total-files-size"))
    n.append(String("total-delete-files"))
    n.append(String("total-position-deletes"))
    n.append(String("total-equality-deletes"))
    n.append(String("komira.commit-id"))
    return n^


def _overwrite_values(
    af: Int, ar: Int, asz: Int, df: Int, dr: Int, dsz: Int, commit_id: String
) -> List[String]:
    var v = List[String]()
    v.append(String("overwrite"))
    v.append(String(af))
    v.append(String(ar))
    v.append(String(asz))
    v.append(String(df))
    v.append(String(dr))
    v.append(String(dsz))
    v.append(String(af))
    v.append(String(ar))
    v.append(String(asz))
    v.append(String("0"))
    v.append(String("0"))
    v.append(String("0"))
    v.append(String(commit_id))
    return v^


def _data_uri(table: String, uuid_n: Int, index: Int) -> String:
    return (
        String("s3://wh/db/")
        + table
        + String("/data/")
        + _uuid(uuid_n)
        + String("-")
        + String(index)
        + String(".parquet")
    )


def _manifest_uri(table: String, uuid_n: Int) -> String:
    return (
        String("s3://wh/db/")
        + table
        + String("/metadata/")
        + _uuid(uuid_n)
        + String("-m0.avro")
    )


def _list_uri(table: String, snapshot_id: Int, attempt: Int, uuid_n: Int) -> String:
    return (
        String("s3://wh/db/")
        + table
        + String("/metadata/snap-")
        + String(snapshot_id)
        + String("-")
        + String(attempt)
        + String("-")
        + _uuid(uuid_n)
        + String(".avro")
    )


def _ids(a: Int64, b: Int64, c: Int64) -> SequenceCommitIds:
    var l = List[Int64]()
    l.append(a)
    l.append(b)
    l.append(c)
    return SequenceCommitIds(l^)


def test_append_append_overwrite_read_back_through_the_metadata() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _Files(store.clone(), String("s3://wh"))
    var client = _new_client()
    _plain_table(client, String("t"))
    var clock = ManualCommitClock(_T0)
    var ids = _ids(101, 102, 103)

    # First append: three rows, one with nulls in every optional column.
    var o1 = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _one(_batch(3, 1, 1)),
        False,
        List[Int64](),
    )
    assert_equal(o1.message, String(""))
    assert_true(o1.committed)
    assert_equal(o1.rows_written, 3)
    assert_equal(o1.files_written, 1)
    assert_equal(o1.snapshot_id, 101)
    assert_equal(o1.commit_id, _uuid(2))
    assert_equal(o1.landed_snapshot_id.value(), 101)
    assert_equal(o1.manifest_list, _list_uri(String("t"), 101, 0, 1))
    assert_equal(o1.posts, 1)
    assert_equal(len(o1.deleted), 0)
    assert_equal(len(o1.delete_failures), 0)
    var size1 = _size_of(files, _data_uri(String("t"), 1, 0))
    _assert_strings(_read_back(client, files, String("t")), _sorted(_expected(1, 3, 1)))

    # Second append: two more rows; the table now holds both statements' rows.
    var o2 = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _one(_batch(2, 10, -1)),
        False,
        List[Int64](),
    )
    assert_equal(o2.message, String(""))
    assert_true(o2.committed)
    assert_equal(o2.snapshot_id, 102)
    assert_equal(o2.commit_id, _uuid(4))
    assert_equal(o2.manifest_list, _list_uri(String("t"), 102, 0, 3))
    var size2 = _size_of(files, _data_uri(String("t"), 3, 0))
    _assert_strings(
        _read_back(client, files, String("t")),
        _sorted(_join(_expected(1, 3, 1), _expected(10, 2, -1))),
    )
    var listed = read_manifest_list(files.get(o2.manifest_list))
    assert_equal(len(listed), 2)
    assert_equal(listed[0].manifest_path, _manifest_uri(String("t"), 1))
    assert_equal(listed[0].sequence_number, 1)
    assert_equal(listed[0].added_snapshot_id, 101)
    assert_equal(listed[1].manifest_path, _manifest_uri(String("t"), 3))
    assert_equal(listed[1].sequence_number, 2)
    assert_equal(listed[1].added_snapshot_id, 102)

    # An overwrite: only its own rows are live.
    var o3 = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _one(_batch(2, 100, 0)),
        True,
        List[Int64](),
    )
    assert_equal(o3.message, String(""))
    assert_true(o3.committed)
    assert_equal(o3.rows_written, 2)
    assert_equal(o3.snapshot_id, 103)
    assert_equal(o3.commit_id, _uuid(6))
    var size3 = _size_of(files, _data_uri(String("t"), 5, 0))
    _assert_strings(
        _read_back(client, files, String("t")), _sorted(_expected(100, 2, 0))
    )
    assert_equal(len(read_manifest_list(files.get(o3.manifest_list))), 1)

    # The summaries of the three snapshots and the operations.
    var md = client.transport_ref().metadata(String("db"), String("t"))
    assert_equal(len(md.snapshots), 3)
    assert_equal(md.snapshots[0].summary(String("operation")).value(), String("append"))
    _assert_strings(md.snapshots[0].summary_names, _append_names())
    _assert_strings(
        md.snapshots[0].summary_values,
        _append_values(1, 3, size1, 1, 3, size1, _uuid(2)),
    )
    _assert_strings(
        md.snapshots[1].summary_values,
        _append_values(1, 2, size2, 2, 5, size1 + size2, _uuid(4)),
    )
    assert_equal(md.snapshots[2].summary(String("operation")).value(), String("overwrite"))
    _assert_strings(md.snapshots[2].summary_names, _overwrite_names())
    _assert_strings(
        md.snapshots[2].summary_values,
        _overwrite_values(1, 2, size3, 2, 5, size1 + size2, _uuid(6)),
    )
    assert_equal(md.main_snapshot_id.value(), 103)

    # Nothing was deleted: three data files, three manifests, three lists.
    assert_equal(_object_count(store), 9)


def test_a_table_without_rows_to_write_sends_no_commit() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _Files(store.clone(), String("s3://wh"))
    var client = _new_client()
    _plain_table(client, String("t"))
    var clock = ManualCommitClock(_T0)
    var ids = _ids(101, 102, 103)
    var applied = client.transport_ref().applied_commits

    var none = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _none(),
        False,
        List[Int64](),
    )
    assert_true(none.committed)
    assert_equal(none.message, String(""))
    assert_equal(none.posts, 0)
    assert_equal(none.rows_written, 0)
    assert_equal(none.files_written, 0)
    assert_false(Bool(none.landed_snapshot_id))

    var empty = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _one(RecordBatch.empty_from_schema(_six_schema())),
        False,
        List[Int64](),
    )
    assert_true(empty.committed)
    assert_equal(empty.posts, 0)
    assert_equal(empty.files_written, 0)

    var emptied = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _none(),
        True,
        List[Int64](),
    )
    assert_true(emptied.committed)
    assert_equal(emptied.posts, 0)

    assert_equal(_object_count(store), 0)
    assert_equal(client.transport_ref().applied_commits, applied)


def test_a_zero_row_overwrite_empties_the_table() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _Files(store.clone(), String("s3://wh"))
    var client = _new_client()
    _plain_table(client, String("t"))
    var clock = ManualCommitClock(_T0)
    var ids = _ids(101, 102, 103)
    var o1 = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _one(_batch(3, 1, -1)),
        False,
        List[Int64](),
    )
    assert_true(o1.committed)
    var size1 = _size_of(files, _data_uri(String("t"), 1, 0))

    var o2 = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _one(RecordBatch.empty_from_schema(_six_schema())),
        True,
        List[Int64](),
    )

    assert_equal(o2.message, String(""))
    assert_true(o2.committed)
    assert_equal(o2.posts, 1)
    assert_equal(o2.rows_written, 0)
    assert_equal(o2.files_written, 0)
    assert_equal(o2.landed_snapshot_id.value(), 102)
    assert_equal(len(_read_back(client, files, String("t"))), 0)
    assert_equal(len(read_manifest_list(files.get(o2.manifest_list))), 0)
    var md = client.transport_ref().metadata(String("db"), String("t"))
    _assert_strings(
        md.snapshots[1].summary_values,
        _overwrite_values(0, 0, 0, 1, 3, size1, _uuid(4)),
    )
    # The old rows are still in the store: no snapshot lists them, and
    # deleting them is the table maintainer's.
    assert_equal(_object_count(store), 4)


def test_the_table_properties_choose_the_paths_and_codec() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _Files(store.clone(), String("s3://wh"))
    var client = _new_client()
    var props = List[String]()
    props.append(String("write.data.path"))
    props.append(String("s3://wh/db/p/files/"))
    props.append(String("write.metadata.path"))
    props.append(String("s3://wh/db/p/meta"))
    props.append(String("write.parquet.compression-codec"))
    props.append(String("uncompressed"))
    _create_table(client, String("p"), _SIX, props)
    var clock = ManualCommitClock(_T0)
    var ids = _ids(101, 102, 103)

    var o = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("p"),
        _one(_batch(3, 1, 2)),
        False,
        List[Int64](),
    )

    assert_equal(o.message, String(""))
    assert_true(o.committed)
    assert_equal(
        o.manifest_list,
        String("s3://wh/db/p/meta/snap-101-0-") + _uuid(1) + String(".avro"),
    )
    var listed = read_manifest_list(files.get(o.manifest_list))
    assert_equal(
        listed[0].manifest_path,
        String("s3://wh/db/p/meta/") + _uuid(1) + String("-m0.avro"),
    )
    var entries = read_manifest_entries(files.get(listed[0].manifest_path))
    assert_equal(
        entries[0].file_path,
        String("s3://wh/db/p/files/") + _uuid(1) + String("-0.parquet"),
    )
    _assert_strings(
        _read_back(client, files, String("p")), _sorted(_expected(1, 3, 2))
    )


def test_a_float_column_is_written_and_read_back() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _Files(store.clone(), String("s3://wh"))
    var client = _new_client()
    _create_table(
        client,
        String("f"),
        String(
            '{"id":1,"name":"id","required":true,"type":"long"},'
            '{"id":2,"name":"ratio","required":false,"type":"float"}'
        ),
        List[String](),
    )
    var clock = ManualCommitClock(_T0)
    var ids = _ids(101, 102, 103)

    var id = PrimitiveArray[DType.int64].allocate(2)
    id.set(0, 1)
    id.set(1, 2)
    var ratio = PrimitiveArray[DType.float32].allocate_nullable(2)
    ratio.set(0, Float32(1.5))
    ratio._set_null(1)
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](id))
    rb.add_column(Column.from_primitive[DType.float32](ratio))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("ratio", ArrowType.FLOAT32, True))

    var o = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("f"),
        _one(rb.build(sb.build())),
        False,
        List[Int64](),
    )

    assert_equal(o.message, String(""))
    assert_true(o.committed)
    assert_equal(o.rows_written, 2)
    var listed = read_manifest_list(files.get(o.manifest_list))
    var entries = read_manifest_entries(files.get(listed[0].manifest_path))
    var back = decode_parquet_file_from_bytes(
        _view(Span(files.get(entries[0].file_path)))
    )
    var got = back.column_as_primitive[DType.float32](1)
    assert_equal(back.num_rows(), 2)
    assert_false(got.is_null(0))
    assert_equal(got.get(0), Float32(1.5))
    assert_true(got.is_null(1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

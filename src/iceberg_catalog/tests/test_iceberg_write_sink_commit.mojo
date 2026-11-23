# =============================================================================
# test_iceberg_write_sink_commit.mojo — write_table when the commit meets
#   another writer: a 409 and its rebuilt list, a statement that read its
#   target, an unknown outcome, and a base list komira did not write.
# =============================================================================
#
#   * test_a_409_rebuilds_the_list_on_the_new_base_and_keeps_the_manifest_once:
#     the retried list carries the other writer's manifests and the same
#     manifest, written once; the first list is deleted.
#   * test_a_statement_that_read_its_target_deletes_its_files_on_conflict: the
#     exact conflict, and exactly the statement's data file, manifest and
#     list deleted.
#   * test_an_unknown_outcome_deletes_nothing: the objects stay.
#   * test_a_foreign_base_list_refuses_an_append_and_not_an_overwrite: the
#     exact ICEBERG_MANIFEST_LIST_UNSUPPORTED message, the statement's files
#     deleted; an overwrite over the same table lands.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.string_array import StringArray
from containers.slab import Slab
from iceberg import (
    ManifestFileEntry,
    build_manifest_list,
    read_manifest_list,
)
from json import JsonValue, parse_json_value
from objectstore.path import Path
from objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from iceberg_catalog.iceberg_commit import ManualCommitClock, SequenceCommitIds
from iceberg_catalog.iceberg_rest_catalog_client import (
    COMMIT_APPLIED,
    IcebergRestCatalog,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_rest_errors import (
    ICEBERG_COMMIT_STATE_UNKNOWN,
    error_has_token,
)
from iceberg_catalog.iceberg_rest_test_catalog import (
    CommitFault,
    InMemoryIcebergRestCatalog,
)
from iceberg_catalog.iceberg_table_changes import (
    CreateTableRequest,
    NewSnapshot,
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
# qty int: field ids 10 to 15.
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


def _other_body(
    parent: Int64, sequence: Int64, id: Int64, list_uri: String
) raises -> String:
    """Another writer's append: snapshot `id` on `parent`, whose manifest list
    is `list_uri`."""
    var names = List[String]()
    var values = List[String]()
    names.append(String("total-data-files"))
    values.append(String("5"))
    names.append(String("total-records"))
    values.append(String("50"))
    names.append(String("total-files-size"))
    values.append(String("5000"))
    var snap = NewSnapshot(
        id,
        Optional[Int64](parent),
        sequence,
        _T0 + 50,
        0,
        String(list_uri),
        String("append"),
        names^,
        values^,
    )
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.add_snapshot(snap^))
    ups.append(TableUpdate.set_branch(String("main"), id))
    return commit_table_body(List[TableRequirement](), ups)


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


def _object_count(store: SharedInMemoryConditionalStore) raises -> Int:
    var listed = store.list_with_delimiter(Path.parse(String("")))
    return len(listed.objects)


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


def test_a_409_rebuilds_the_list_on_the_new_base_and_keeps_the_manifest_once() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _Files(store.clone(), String("s3://wh"))
    var client = _new_client()
    _plain_table(client, String("t"))
    var clock = ManualCommitClock(_T0)
    var ids = _ids(101, 102, 103)
    var first = write_table(
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
    assert_true(first.committed)

    # Another komira statement lands between this one's load and its commit.
    var other_list = String("s3://wh/db/t/metadata/snap-8001-0-other.avro")
    var other_entries = List[ManifestFileEntry]()
    other_entries.append(
        ManifestFileEntry(
            String("s3://wh/db/t/metadata/other-m0.avro"),
            999,
            1,
            Int64(5),
            0,
            Int64(2),
            Int64(8001),
            0,
        )
    )
    files.put(other_list, build_manifest_list(Int64(8001), Int64(2), other_entries))
    client.transport_ref().before_next_commit(_other_body(101, 2, 8001, other_list))
    var puts_before = store.n_put()

    var o = write_table(
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

    assert_equal(o.message, String(""))
    assert_true(o.committed)
    assert_equal(o.posts, 2)
    assert_equal(len(clock.waits), 1)
    assert_equal(clock.waits[0], 100)
    assert_equal(o.manifest_list, _list_uri(String("t"), 102, 1, 3))
    # One data file, one manifest, and two lists: the manifest once.
    assert_equal(store.n_put() - puts_before, 4)
    var listed = read_manifest_list(files.get(o.manifest_list))
    assert_equal(len(listed), 2)
    assert_equal(listed[0].manifest_path, String("s3://wh/db/t/metadata/other-m0.avro"))
    assert_equal(listed[1].manifest_path, _manifest_uri(String("t"), 3))
    assert_equal(listed[1].sequence_number, 3)
    assert_equal(listed[1].added_snapshot_id, 102)
    # The list of the first attempt was superseded and is deleted.
    assert_equal(len(o.deleted), 1)
    assert_equal(o.deleted[0], _list_uri(String("t"), 102, 0, 3))
    assert_equal(len(o.delete_failures), 0)
    var md = client.transport_ref().metadata(String("db"), String("t"))
    assert_equal(md.main_snapshot_id.value(), 102)
    assert_equal(md.snapshots[2].parent_id.value(), 8001)


def test_a_statement_that_read_its_target_deletes_its_files_on_conflict() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _Files(store.clone(), String("s3://wh"))
    var client = _new_client()
    _plain_table(client, String("t"))
    var clock = ManualCommitClock(_T0)
    var ids = _ids(101, 102, 103)
    assert_true(
        write_table(
            client,
            files,
            clock,
            ids,
            String("db"),
            String("t"),
            _one(_batch(3, 1, -1)),
            False,
            List[Int64](),
        ).committed
    )
    client.transport_ref().before_next_commit(
        _other_body(101, 2, 8001, String("s3://wh/db/t/metadata/other.avro"))
    )
    var before = _object_count(store)
    var pins = List[Int64]()
    pins.append(101)

    var o = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _one(_batch(2, 10, -1)),
        False,
        pins,
    )

    assert_false(o.committed)
    assert_equal(
        o.message,
        String(
            "ICEBERG_COMMIT_CONFLICT: commit to 'db.t': the statement read the"
            " table at snapshot 101, and main is now 8001"
        ),
    )
    assert_equal(o.rows_written, 0)
    assert_equal(o.files_written, 0)
    assert_equal(o.posts, 1)
    assert_equal(len(o.deleted), 3)
    assert_equal(o.deleted[0], _data_uri(String("t"), 3, 0))
    assert_equal(o.deleted[1], _manifest_uri(String("t"), 3))
    assert_equal(o.deleted[2], _list_uri(String("t"), 102, 0, 3))
    assert_equal(len(o.delete_failures), 0)
    assert_equal(_object_count(store), before)


def test_an_unknown_outcome_deletes_nothing() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _Files(store.clone(), String("s3://wh"))
    var client = _new_client()
    _plain_table(client, String("t"))
    var clock = ManualCommitClock(_T0)
    var ids = _ids(101, 102, 103)
    assert_true(
        write_table(
            client,
            files,
            clock,
            ids,
            String("db"),
            String("t"),
            _one(_batch(3, 1, -1)),
            False,
            List[Int64](),
        ).committed
    )
    var before = _object_count(store)
    client.transport_ref().fault_next_commit(
        CommitFault(
            500,
            apply_first=False,
            then_body=_other_body(
                101, 2, 8001, String("s3://wh/db/t/metadata/other.avro")
            ),
        )
    )

    var o = write_table(
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

    assert_false(o.committed)
    assert_true(error_has_token(o.message, ICEBERG_COMMIT_STATE_UNKNOWN))
    assert_true(
        o.message.find(
            String("snapshot 102, commit id ")
            + _uuid(4)
            + String(", manifest list ")
            + _list_uri(String("t"), 102, 0, 3)
        )
        >= 0
    )
    assert_true(o.message.find(String("main moved from 101 to 8001")) >= 0)
    assert_equal(len(o.deleted), 0)
    assert_equal(len(o.delete_failures), 0)
    # The statement's data file, manifest and list are all still there.
    assert_equal(_object_count(store), before + 3)


def test_a_foreign_base_list_refuses_an_append_and_not_an_overwrite() raises:
    var store = SharedInMemoryConditionalStore()
    var files = _Files(store.clone(), String("s3://wh"))
    var client = _new_client()
    _plain_table(client, String("t"))
    var foreign = String("s3://wh/db/t/metadata/snap-8001-0-foreign.avro")
    var junk = List[UInt8]()
    junk.append(1)
    junk.append(2)
    files.put(foreign, junk)
    # Another engine's commit puts its own list under `main`.
    var ups = List[TableUpdate]()
    var names = List[String]()
    var values = List[String]()
    var snap = NewSnapshot(
        8001, None, 1, _T0, 0, String(foreign), String("append"), names^, values^
    )
    ups.append(TableUpdate.add_snapshot(snap^))
    ups.append(TableUpdate.set_branch(String("main"), 8001))
    var landed = client.commit_table(
        String("db"),
        String("t"),
        commit_table_body(List[TableRequirement](), ups),
        String(""),
    )
    assert_equal(landed.kind, COMMIT_APPLIED)
    var clock = ManualCommitClock(_T0)
    var ids = _ids(101, 102, 103)
    var before = _object_count(store)

    var refused = write_table(
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

    assert_false(refused.committed)
    assert_equal(
        refused.message,
        String(
            "ICEBERG_MANIFEST_LIST_UNSUPPORTED: manifest list "
            "s3://wh/db/t/metadata/snap-8001-0-foreign.avro of snapshot 8001"
            " was not written by komira; this write appends only to manifest"
            " lists it wrote"
        ),
    )
    assert_equal(refused.posts, 0)
    assert_equal(len(refused.deleted), 1)
    assert_equal(refused.deleted[0], _data_uri(String("t"), 1, 0))
    assert_equal(_object_count(store), before)

    var over = write_table(
        client,
        files,
        clock,
        ids,
        String("db"),
        String("t"),
        _one(_batch(2, 10, -1)),
        True,
        List[Int64](),
    )
    assert_equal(over.message, String(""))
    assert_true(over.committed)
    assert_equal(len(read_manifest_list(files.get(over.manifest_list))), 1)
    assert_equal(over.files_written, 1)
    assert_equal(over.rows_written, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

# =============================================================================
# test_iceberg_commit_base_checks.mojo — the base checks of commit_append: table uuid, format version, written
#   columns and their types.
# =============================================================================
#
# Each case names what it would catch:
#   * Another table uuid is ICEBERG_TABLE_REPLACED; format versions 1 and 3
#     are ICEBERG_WRITE_FORMAT_UNSUPPORTED.
#   * A dropped written column and an incompatible type are
#     ICEBERG_SCHEMA_INCOMPATIBLE; an added column, a rename and the
#     promotions (int to long, float to double, a wider decimal) pass.
#   * A schema change between load and commit that drops a written column
#     fails on the retry's check, after the wait.
#   * check_append_base and type_reads_as, every branch, by exact message.
# No sockets; time is a ManualCommitClock whose waits are asserted exactly.
# =============================================================================


from std.testing import assert_equal, assert_true, assert_false

from json import JsonValue, parse_json_value

from iceberg_catalog.iceberg_commit import (
    AppendCommit,
    AppendCommitOutcome,
    AppendSnapshotWriter,
    CommitRetryBudget,
    ManualCommitClock,
    RandomCommitIds,
    SequenceCommitIds,
    SystemCommitClock,
    check_append_base,
    commit_append,
    type_reads_as,
)
from iceberg_catalog.iceberg_rest_catalog_client import (
    COMMIT_APPLIED,
    IcebergRestCatalog,
    LoadedTable,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_rest_test_catalog import (
    CommitFault,
    InMemoryIcebergRestCatalog,
)
from iceberg_catalog.iceberg_rest_transport import ScriptedIcebergRestTransport
from iceberg_catalog.iceberg_table_changes import (
    CreateTableRequest,
    NewSnapshot,
    TableRequirement,
    TableUpdate,
    commit_table_body,
)
from iceberg_catalog.iceberg_table_metadata import (
    SchemaField,
    TableMetadata,
    TableSchema,
)


comptime _Client = IcebergRestCatalog[
    InMemoryIcebergRestCatalog, StaticBearerToken
]


comptime _T0: Int64 = 1795132800000


comptime _U1: String = "00000000-0000-4000-8000-000000000001"


comptime _C1: String = "00000000-0000-7000-8000-000000000001"


struct _Writer(AppendSnapshotWriter, Movable):
    """Records each call and returns `snap-<S>-<attempt>-x.avro`."""

    var snapshot_ids: List[Int64]
    var attempts: List[Int]
    var parents: List[Int64]
    var sequences: List[Int64]

    def __init__(out self):
        self.snapshot_ids = List[Int64]()
        self.attempts = List[Int]()
        self.parents = List[Int64]()
        self.sequences = List[Int64]()

    def write_manifest_list(
        mut self,
        snapshot_id: Int64,
        attempt: Int,
        base: TableMetadata,
        sequence_number: Int64,
    ) raises -> String:
        self.snapshot_ids.append(snapshot_id)
        self.attempts.append(attempt)
        if base.main_snapshot_id:
            self.parents.append(base.main_snapshot_id.value())
        else:
            self.parents.append(-1)
        self.sequences.append(sequence_number)
        return _ml(snapshot_id, attempt)


def _ml(snapshot_id: Int64, attempt: Int) -> String:
    return (
        String("s3://wh/db/t/metadata/snap-")
        + String(snapshot_id)
        + String("-")
        + String(attempt)
        + String("-x.avro")
    )


def _s0() -> List[String]:
    return List[String]()


def _s1(a: String) -> List[String]:
    var l = List[String]()
    l.append(String(a))
    return l^


def _i0() -> List[Int64]:
    return List[Int64]()


def _i1(a: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    return l^


def _assert_strings(actual: List[String], expected: List[String]) raises:
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i])


def _assert_i64s(actual: List[Int64], expected: List[Int64]) raises:
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i])


def _new_client(idempotent: Bool) -> _Client:
    var cat = InMemoryIcebergRestCatalog(String(""), String("s3://wh"))
    cat.create_namespace(String("db"))
    if idempotent:
        cat.advertise_idempotency()
    return _Client(
        String("catalog.example.com"), cat^, StaticBearerToken(String(""))
    )


def _col(id: Int, name: String, type_name: String) -> SchemaField:
    return SchemaField(id, name, id == 1, type_name)


def _cols() -> List[SchemaField]:
    var c = List[SchemaField]()
    c.append(_col(1, String("id"), String("long")))
    c.append(_col(2, String("name"), String("string")))
    c.append(_col(3, String("amount"), String("decimal(9,2)")))
    return c^


def _schema_json(cols: List[SchemaField]) raises -> JsonValue:
    var text = String('{"type":"struct","fields":[')
    for i in range(len(cols)):
        if i > 0:
            text += ","
        text += (
            String('{"id":')
            + String(cols[i].id)
            + String(',"name":"')
            + cols[i].name
            + String('","required":')
            + (String("true") if cols[i].required else String("false"))
            + String(',"type":"')
            + cols[i].type_name
            + String('"}')
        )
    text += "]}"
    return parse_json_value(text)


def _create_table(
    mut client: _Client,
    name: String,
    cols: List[SchemaField],
    format_version: Int,
    props: List[String],
) raises:
    """A staged create, then the commit with `assert-create` that makes the
    table appear. `props` is [name, value, name, value, ...]."""
    var req = CreateTableRequest(
        String(name), _schema_json(cols), stage_create=True
    )
    var staged = client.create_table(String("db"), req)
    _commit_staged(client, staged, name, cols, format_version, props)


def _commit_staged(
    mut client: _Client,
    staged: LoadedTable,
    name: String,
    cols: List[SchemaField],
    format_version: Int,
    props: List[String],
) raises:
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_create())
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.assign_uuid(String(staged.metadata.table_uuid)))
    ups.append(TableUpdate.upgrade_format_version(format_version))
    ups.append(TableUpdate.add_schema(_schema_json(cols)))
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


def _plain_table(mut client: _Client) raises:
    _create_table(client, String("t"), _cols(), 2, _s0())


def _statement(
    table: String,
    uuid: String,
    var cols: List[SchemaField],
    var pins: List[Int64],
    files: Int64,
    records: Int64,
    size: Int64,
) -> AppendCommit:
    return AppendCommit(
        String("db"),
        String(table),
        String(uuid),
        cols^,
        pins^,
        files,
        records,
        size,
    )


def _append(uuid: String) -> AppendCommit:
    return _statement(String("t"), uuid, _cols(), _i0(), 2, 10, 1000)


def _assert_outcome(
    o: AppendCommitOutcome,
    committed: Bool,
    message: String,
    snapshot_id: Int64,
    commit_id: String,
    landed: Int64,
    manifest_list: String,
    delete_files: Bool,
    to_delete: List[String],
    posts: Int,
) raises:
    """`landed` is -1 for None."""
    assert_equal(o.committed, committed)
    assert_equal(o.message, message)
    assert_equal(o.snapshot_id, snapshot_id)
    assert_equal(o.commit_id, commit_id)
    if landed == -1:
        assert_false(Bool(o.landed_snapshot_id))
    else:
        assert_true(Bool(o.landed_snapshot_id))
        assert_equal(o.landed_snapshot_id.value(), landed)
    assert_equal(o.manifest_list, manifest_list)
    assert_equal(o.delete_statement_files, delete_files)
    _assert_strings(o.manifest_lists_to_delete, to_delete)
    assert_equal(o.posts, posts)


def _post_count(client: _Client) -> Int:
    var n = 0
    ref cat = client.transport_ref()
    for i in range(len(cat.request_methods)):
        if cat.request_methods[i] == String("POST"):
            n += 1
    return n


def _metadata(
    format_version: Int,
    uuid: String,
    schema_id: Int,
    var fields: List[SchemaField],
) -> TableMetadata:
    var md = TableMetadata()
    md.format_version = format_version
    md.table_uuid = String(uuid)
    md.current_schema_id = schema_id
    md.schemas.append(TableSchema(0, fields^))
    return md^


def test_another_table_uuid_is_table_replaced() raises:
    var client = _new_client(False)
    _plain_table(client)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var other = String("00000000-0000-4000-8000-0000000000ff")
    var o = commit_append(client, writer, clock, ids, _append(other))
    _assert_outcome(
        o,
        False,
        String("ICEBERG_TABLE_REPLACED: table 'db.t' has uuid ")
        + _U1
        + String(", the statement was planned on ")
        + other,
        0,
        String(""),
        -1,
        String(""),
        True,
        _s0(),
        0,
    )
    assert_equal(len(writer.attempts), 0)
    # Only the staged create and the commit that creates the table were sent.
    assert_equal(_post_count(client), 2)


def test_format_versions_1_and_3_are_refused() raises:
    var versions = List[Int]()
    versions.append(1)
    versions.append(3)
    for i in range(len(versions)):
        var client = _new_client(False)
        _create_table(client, String("t"), _cols(), versions[i], _s0())
        var writer = _Writer()
        var clock = ManualCommitClock(_T0)
        var ids = SequenceCommitIds(_i1(7001))
        var o = commit_append(client, writer, clock, ids, _append(_U1))
        _assert_outcome(
            o,
            False,
            String("ICEBERG_WRITE_FORMAT_UNSUPPORTED: table 'db.t' is format version ")
            + String(versions[i])
            + String("; komira writes version 2 only"),
            0,
            String(""),
            -1,
            String(""),
            True,
            _s0(),
            0,
        )
        assert_equal(len(writer.attempts), 0)


def test_dropped_column_and_incompatible_type_are_schema_incompatible() raises:
    var client = _new_client(False)
    var narrow = List[SchemaField]()
    narrow.append(_col(1, String("id"), String("long")))
    narrow.append(_col(2, String("name"), String("string")))
    _create_table(client, String("t"), narrow, 2, _s0())
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var o = commit_append(client, writer, clock, ids, _append(_U1))
    _assert_outcome(
        o,
        False,
        String(
            "ICEBERG_SCHEMA_INCOMPATIBLE: table 'db.t': column 'amount'"
            " (field id 3) was dropped"
        ),
        0,
        String(""),
        -1,
        String(""),
        True,
        _s0(),
        0,
    )

    var client2 = _new_client(False)
    var retyped = List[SchemaField]()
    retyped.append(_col(1, String("id"), String("long")))
    retyped.append(_col(2, String("name"), String("string")))
    retyped.append(_col(3, String("amount"), String("string")))
    _create_table(client2, String("t"), retyped, 2, _s0())
    var o2 = commit_append(client2, writer, clock, ids, _append(_U1))
    _assert_outcome(
        o2,
        False,
        String(
            "ICEBERG_SCHEMA_INCOMPATIBLE: table 'db.t': column 'amount'"
            " (field id 3) is now string, the statement writes decimal(9,2)"
        ),
        0,
        String(""),
        -1,
        String(""),
        True,
        _s0(),
        0,
    )
    assert_equal(len(writer.attempts), 0)


def test_added_column_rename_and_promotions_pass() raises:
    var client = _new_client(False)
    var table = List[SchemaField]()
    table.append(_col(1, String("id"), String("long")))
    table.append(_col(2, String("name"), String("string")))
    table.append(_col(3, String("amount"), String("decimal(12,2)")))
    table.append(_col(4, String("extra"), String("string")))
    table.append(_col(5, String("score"), String("double")))
    _create_table(client, String("t"), table, 2, _s0())
    var written = List[SchemaField]()
    written.append(_col(1, String("id"), String("int")))
    written.append(_col(2, String("old_name"), String("string")))
    written.append(_col(3, String("amount"), String("decimal(9,2)")))
    written.append(_col(5, String("score"), String("float")))
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var o = commit_append(
        client,
        writer,
        clock,
        ids,
        _statement(String("t"), _U1, written^, _i0(), 1, 3, 30),
    )
    _assert_outcome(
        o, True, String(""), 7001, _C1, 7001, _ml(7001, 0), False, _s0(), 1
    )


def test_schema_change_between_load_and_commit_fails_on_the_retry_check() raises:
    var client = _new_client(False)
    _plain_table(client)
    var narrow = List[SchemaField]()
    narrow.append(_col(1, String("id"), String("long")))
    narrow.append(_col(2, String("name"), String("string")))
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.add_schema(_schema_json(narrow)))
    ups.append(TableUpdate.set_current_schema(1))
    client.transport_ref().before_next_commit(
        commit_table_body(List[TableRequirement](), ups)
    )
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))

    var o = commit_append(client, writer, clock, ids, _append(_U1))

    _assert_outcome(
        o,
        False,
        String(
            "ICEBERG_SCHEMA_INCOMPATIBLE: table 'db.t': column 'amount'"
            " (field id 3) was dropped"
        ),
        7001,
        _C1,
        -1,
        String(""),
        True,
        _s1(_ml(7001, 0)),
        1,
    )
    _assert_i64s(clock.waits, _i1(100))
    assert_equal(len(writer.attempts), 1)


def test_check_append_base_every_branch() raises:
    var stmt = _append(_U1)
    assert_equal(check_append_base(stmt, _metadata(2, _U1, 0, _cols())), String(""))
    # Extra columns in the table do not stop the write.
    var wide = _cols()
    wide.append(_col(9, String("later"), String("string")))
    assert_equal(check_append_base(stmt, _metadata(2, _U1, 0, wide^)), String(""))

    assert_equal(
        check_append_base(stmt, _metadata(2, String("other"), 0, _cols())),
        String("ICEBERG_TABLE_REPLACED: table 'db.t' has uuid other, the statement was planned on ")
        + _U1,
    )
    assert_equal(
        check_append_base(stmt, _metadata(1, _U1, 0, _cols())),
        String(
            "ICEBERG_WRITE_FORMAT_UNSUPPORTED: table 'db.t' is format version 1;"
            " komira writes version 2 only"
        ),
    )
    assert_equal(
        check_append_base(stmt, _metadata(3, _U1, 0, _cols())),
        String(
            "ICEBERG_WRITE_FORMAT_UNSUPPORTED: table 'db.t' is format version 3;"
            " komira writes version 2 only"
        ),
    )
    assert_equal(
        check_append_base(stmt, _metadata(2, _U1, 7, _cols())),
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: table 'db.t' has no schema with"
            " its current-schema-id 7"
        ),
    )
    var no_amount = List[SchemaField]()
    no_amount.append(_col(1, String("id"), String("long")))
    no_amount.append(_col(2, String("name"), String("string")))
    assert_equal(
        check_append_base(stmt, _metadata(2, _U1, 0, no_amount^)),
        String(
            "ICEBERG_SCHEMA_INCOMPATIBLE: table 'db.t': column 'amount'"
            " (field id 3) was dropped"
        ),
    )
    var narrowed = List[SchemaField]()
    narrowed.append(_col(1, String("id"), String("int")))
    narrowed.append(_col(2, String("name"), String("string")))
    narrowed.append(_col(3, String("amount"), String("decimal(9,2)")))
    var long_stmt = _statement(String("t"), _U1, _cols(), _i0(), 1, 1, 1)
    assert_equal(
        check_append_base(long_stmt, _metadata(2, _U1, 0, narrowed^)),
        String(
            "ICEBERG_SCHEMA_INCOMPATIBLE: table 'db.t': column 'id'"
            " (field id 1) is now int, the statement writes long"
        ),
    )
    # The uuid is checked before the format version, which is checked
    # before the schema.
    assert_equal(
        check_append_base(stmt, _metadata(1, String("other"), 7, _cols())),
        String("ICEBERG_TABLE_REPLACED: table 'db.t' has uuid other, the statement was planned on ")
        + _U1,
    )


def test_type_reads_as_every_branch() raises:
    assert_true(type_reads_as(String("long"), String("long")))
    assert_true(type_reads_as(String("string"), String("string")))
    assert_true(type_reads_as(String("int"), String("long")))
    assert_false(type_reads_as(String("long"), String("int")))
    assert_true(type_reads_as(String("float"), String("double")))
    assert_false(type_reads_as(String("double"), String("float")))
    assert_false(type_reads_as(String("int"), String("double")))
    assert_false(type_reads_as(String("string"), String("long")))
    # Decimals: the same scale and a precision at least as wide.
    assert_true(type_reads_as(String("decimal(9,2)"), String("decimal(9,2)")))
    assert_true(type_reads_as(String("decimal(9,2)"), String("decimal(12,2)")))
    assert_false(type_reads_as(String("decimal(12,2)"), String("decimal(9,2)")))
    assert_false(type_reads_as(String("decimal(9,2)"), String("decimal(12,3)")))
    assert_true(type_reads_as(String("decimal(9, 2)"), String("decimal( 12 , 2 )")))
    # One side a decimal, the other not.
    assert_false(type_reads_as(String("decimal(9,2)"), String("long")))
    assert_false(type_reads_as(String("int"), String("decimal(9,2)")))
    # Malformed decimals read as nothing.
    assert_false(type_reads_as(String("decimal(9)"), String("decimal(12,2)")))
    assert_false(type_reads_as(String("decimal(9,2)"), String("decimal(12)")))
    assert_false(type_reads_as(String("decimal(a,b)"), String("decimal(12,2)")))
    assert_false(type_reads_as(String("decimal(9,2"), String("decimal(12,2)")))
    assert_false(type_reads_as(String("decimal(9,2)"), String("decimal(12,x)")))


def main() raises:
    test_another_table_uuid_is_table_replaced()
    test_format_versions_1_and_3_are_refused()
    test_dropped_column_and_incompatible_type_are_schema_incompatible()
    test_added_column_rename_and_promotions_pass()
    test_schema_change_between_load_and_commit_fails_on_the_retry_check()
    test_check_append_base_every_branch()
    test_type_reads_as_every_branch()
    print("test_iceberg_commit_base_check: ALL PASS")

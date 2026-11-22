# =============================================================================
# test_iceberg_commit_append.mojo — commit_append against the in-process test catalog: a staged create, the
#   first and second append, a concurrent writer, the statement that read
#   its target, the idempotency key, and the id and clock conformers.
# =============================================================================
#
# Each case names what it would catch:
#   * Staged create: a staged create stores nothing, and the table appears
#     only with the commit that carries `assert-create`. A client that stored
#     the table at the staged create would show it before the commit.
#   * First and second append: the snapshot's parent, sequence number,
#     timestamp, summary (added counts, totals from the parent, the commit id)
#     and `main`, and the exact request body. A committer that restarted the
#     totals at the added counts, or lost the parent, fails. The timestamp is
#     the clock's, or the parent's plus one when the clock is behind.
#   * Zero added files sends no commit.
#   * A concurrent append between load and commit: the first POST is
#     answered 409, the committer reloads, waits the minimum, rewrites the
#     manifest list for attempt 1 on the new parent and sequence number, and
#     lands with both snapshots in `main`'s history; only the superseded list
#     is listed for deletion.
#   * A statement that read its target never rebases: it fails with the pins
#     and the new `main` named, and every list it wrote may be deleted.
#   * The idempotency key is sent only when the catalog advertises it.
#   * RandomCommitIds are positive and uuid-shaped; the system clock is
#     positive; SequenceCommitIds and ManualCommitClock are exact.
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


comptime _C2: String = "00000000-0000-7000-8000-000000000002"


comptime _TOKEN_CONFLICT: String = "ICEBERG_COMMIT_CONFLICT"


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


def _i2(a: Int64, b: Int64) -> List[Int64]:
    var l = _i1(a)
    l.append(b)
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


def _other_writer_body(
    parent: Optional[Int64], sequence: Int64, id: Int64, ts: Int64
) raises -> String:
    """Another writer's append: a snapshot whose summary carries only the
    three totals of the data files, records and file size (5, 50, 5000)."""
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
        parent,
        sequence,
        ts,
        0,
        String("s3://wh/db/t/metadata/other-") + String(id) + String(".avro"),
        String("append"),
        names^,
        values^,
    )
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.add_snapshot(snap^))
    ups.append(TableUpdate.set_branch(String("main"), id))
    return commit_table_body(List[TableRequirement](), ups)


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


def _summary_names() -> List[String]:
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


def _summary_values(
    added_files: Int,
    added_records: Int,
    added_size: Int,
    total_files: Int,
    total_records: Int,
    total_size: Int,
    commit_id: String,
) -> List[String]:
    var v = List[String]()
    v.append(String("append"))
    v.append(String(added_files))
    v.append(String(added_records))
    v.append(String(added_size))
    v.append(String(total_files))
    v.append(String(total_records))
    v.append(String(total_size))
    v.append(String("0"))
    v.append(String("0"))
    v.append(String("0"))
    v.append(String(commit_id))
    return v^


def _is_lower_hex(c: UInt8) -> Bool:
    return (c >= 0x30 and c <= 0x39) or (c >= 0x61 and c <= 0x66)


def test_staged_create_appears_only_at_the_commit() raises:
    var client = _new_client(False)
    var req = CreateTableRequest(
        String("t"), _schema_json(_cols()), stage_create=True
    )
    var staged = client.create_table(String("db"), req)
    assert_equal(staged.metadata_location, String(""))
    assert_equal(staged.metadata.table_uuid, _U1)
    assert_equal(staged.metadata.location, String("s3://wh/db/t"))
    assert_false(client.transport_ref().has_table(String("db"), String("t")))
    assert_equal(client.transport_ref().applied_commits, 0)

    _commit_staged(client, staged, String("t"), _cols(), 2, _s0())
    assert_true(client.transport_ref().has_table(String("db"), String("t")))
    assert_equal(client.transport_ref().applied_commits, 1)
    var loaded = client.load_table_metadata(String("db"), String("t"))
    assert_equal(
        loaded.metadata_location,
        String("s3://wh/db/t/metadata/v1.metadata.json"),
    )
    assert_equal(loaded.metadata.table_uuid, _U1)
    assert_equal(loaded.metadata.format_version, 2)
    assert_equal(loaded.metadata.current_schema_id, 0)
    assert_equal(len(loaded.metadata.schemas), 1)
    assert_equal(len(loaded.metadata.schemas[0].fields), 3)
    assert_equal(len(loaded.metadata.snapshots), 0)
    assert_false(Bool(loaded.metadata.main_snapshot_id))


def test_first_append_lands_snapshot_with_exact_summary_and_request() raises:
    var client = _new_client(False)
    _plain_table(client)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i2(7001, 7002))
    var before = client.transport_ref().request_count()

    var o = commit_append(client, writer, clock, ids, _append(_U1))

    _assert_outcome(
        o, True, String(""), 7001, _C1, 7001, _ml(7001, 0), False, _s0(), 1
    )
    _assert_i64s(clock.waits, _i0())
    _assert_i64s(writer.snapshot_ids, _i1(7001))
    assert_equal(len(writer.attempts), 1)
    assert_equal(writer.attempts[0], 0)
    _assert_i64s(writer.parents, _i1(-1))
    _assert_i64s(writer.sequences, _i1(1))

    ref cat = client.transport_ref()
    var md = cat.metadata(String("db"), String("t"))
    assert_equal(len(md.snapshots), 1)
    ref s = md.snapshots[0]
    assert_equal(s.snapshot_id, 7001)
    assert_false(Bool(s.parent_id))
    assert_equal(s.sequence_number, 1)
    assert_equal(s.timestamp_ms, _T0)
    assert_equal(s.manifest_list, _ml(7001, 0))
    _assert_strings(s.summary_names, _summary_names())
    _assert_strings(
        s.summary_values, _summary_values(2, 10, 1000, 2, 10, 1000, _C1)
    )
    assert_equal(md.main_snapshot_id.value(), 7001)
    assert_equal(md.last_sequence_number, 1)

    assert_equal(cat.request_count() - before, 2)
    assert_equal(cat.request_methods[before], String("GET"))
    assert_equal(
        cat.request_paths[before], String("/v1/namespaces/db/tables/t")
    )
    assert_equal(cat.request_methods[before + 1], String("POST"))
    assert_equal(
        cat.request_paths[before + 1], String("/v1/namespaces/db/tables/t")
    )
    assert_equal(
        cat.request_bodies[before + 1],
        String(
            '{"requirements":[{"type":"assert-table-uuid","uuid":"'
        )
        + _U1
        + String(
            '"},{"type":"assert-ref-snapshot-id","ref":"main","snapshot-id":null},'
            '{"type":"assert-current-schema-id","current-schema-id":0}],'
            '"updates":[{"action":"add-snapshot","snapshot":{"snapshot-id":7001,'
            '"sequence-number":1,"timestamp-ms":1795132800000,"schema-id":0,'
            '"manifest-list":"'
        )
        + _ml(7001, 0)
        + String(
            '","summary":{"operation":"append","added-data-files":"2",'
            '"added-records":"10","added-files-size":"1000",'
            '"total-data-files":"2","total-records":"10",'
            '"total-files-size":"1000","total-delete-files":"0",'
            '"total-position-deletes":"0","total-equality-deletes":"0",'
            '"komira.commit-id":"'
        )
        + _C1
        + String(
            '"}}},{"action":"set-snapshot-ref","ref-name":"main",'
            '"type":"branch","snapshot-id":7001}]}'
        ),
    )


def test_second_append_totals_add_to_the_first() raises:
    var client = _new_client(False)
    _plain_table(client)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var first = commit_append(client, writer, clock, ids, _append(_U1))
    assert_true(first.committed)

    var writer2 = _Writer()
    var clock2 = ManualCommitClock(_T0 + 5000)
    var ids2 = SequenceCommitIds(_i1(7002))
    var o = commit_append(
        client,
        writer2,
        clock2,
        ids2,
        _statement(String("t"), _U1, _cols(), _i0(), 3, 7, 400),
    )

    _assert_outcome(
        o, True, String(""), 7002, _C1, 7002, _ml(7002, 0), False, _s0(), 1
    )
    _assert_i64s(writer2.parents, _i1(7001))
    _assert_i64s(writer2.sequences, _i1(2))
    ref cat = client.transport_ref()
    var md = cat.metadata(String("db"), String("t"))
    assert_equal(len(md.snapshots), 2)
    ref s = md.snapshots[1]
    assert_equal(s.snapshot_id, 7002)
    assert_equal(s.parent_id.value(), 7001)
    assert_equal(s.sequence_number, 2)
    assert_equal(s.timestamp_ms, _T0 + 5000)
    _assert_strings(
        s.summary_values, _summary_values(3, 7, 400, 5, 17, 1400, _C1)
    )
    assert_equal(md.main_snapshot_id.value(), 7002)
    assert_equal(md.last_sequence_number, 2)
    _assert_i64s(md.main_ancestry(), _i2(7002, 7001))


def test_timestamp_is_the_clock_or_the_parents_plus_one() raises:
    var client = _new_client(False)
    _plain_table(client)
    var writer = _Writer()
    var clock = ManualCommitClock(1000)
    var ids = SequenceCommitIds(_i1(7001))
    assert_true(commit_append(client, writer, clock, ids, _append(_U1)).committed)

    # Equal to the parent's timestamp: one more than it.
    var clock2 = ManualCommitClock(1000)
    var ids2 = SequenceCommitIds(_i1(7002))
    assert_true(commit_append(client, writer, clock2, ids2, _append(_U1)).committed)
    # Behind the parent's timestamp: one more than it.
    var clock3 = ManualCommitClock(500)
    var ids3 = SequenceCommitIds(_i1(7003))
    assert_true(commit_append(client, writer, clock3, ids3, _append(_U1)).committed)
    # Ahead of it: the clock's time.
    var clock4 = ManualCommitClock(5000)
    var ids4 = SequenceCommitIds(_i1(7004))
    assert_true(commit_append(client, writer, clock4, ids4, _append(_U1)).committed)

    var md = client.transport_ref().metadata(String("db"), String("t"))
    assert_equal(len(md.snapshots), 4)
    assert_equal(md.snapshots[0].timestamp_ms, 1000)
    assert_equal(md.snapshots[1].timestamp_ms, 1001)
    assert_equal(md.snapshots[2].timestamp_ms, 1002)
    assert_equal(md.snapshots[3].timestamp_ms, 5000)


def test_zero_added_files_sends_no_commit() raises:
    var client = _new_client(False)
    _plain_table(client)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var before = client.transport_ref().request_count()
    var o = commit_append(
        client,
        writer,
        clock,
        ids,
        _statement(String("t"), _U1, _cols(), _i0(), 0, 0, 0),
    )
    _assert_outcome(o, True, String(""), 0, String(""), -1, String(""), False, _s0(), 0)
    assert_equal(len(writer.attempts), 0)
    ref cat = client.transport_ref()
    assert_equal(cat.request_count() - before, 1)
    assert_equal(cat.request_methods[before], String("GET"))
    assert_equal(cat.applied_commits, 1)


def test_concurrent_append_rebases_after_wait_and_keeps_both_snapshots() raises:
    var client = _new_client(False)
    _plain_table(client)
    client.transport_ref().before_next_commit(
        _other_writer_body(None, 1, 8001, _T0 + 50)
    )
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var before = client.transport_ref().request_count()

    var o = commit_append(client, writer, clock, ids, _append(_U1))

    _assert_outcome(
        o,
        True,
        String(""),
        7001,
        _C1,
        7001,
        _ml(7001, 1),
        False,
        _s1(_ml(7001, 0)),
        2,
    )
    _assert_i64s(clock.waits, _i1(100))
    # The manifest list was written twice: attempt 0 on the empty table,
    # attempt 1 on the other writer's snapshot and the next sequence number.
    _assert_i64s(writer.snapshot_ids, _i2(7001, 7001))
    assert_equal(writer.attempts[0], 0)
    assert_equal(writer.attempts[1], 1)
    _assert_i64s(writer.parents, _i2(-1, 8001))
    _assert_i64s(writer.sequences, _i2(1, 2))

    ref cat = client.transport_ref()
    var md = cat.metadata(String("db"), String("t"))
    _assert_i64s(md.main_ancestry(), _i2(7001, 8001))
    assert_equal(md.main_snapshot_id.value(), 7001)
    assert_equal(md.last_sequence_number, 2)
    assert_equal(md.snapshots[1].parent_id.value(), 8001)
    assert_equal(md.snapshots[1].sequence_number, 2)
    # The clock moved by the wait, after the other writer's timestamp.
    assert_equal(md.snapshots[1].timestamp_ms, _T0 + 100)
    assert_equal(md.snapshots[1].manifest_list, _ml(7001, 1))
    # Totals come from the other writer's summary; the totals it lacks are
    # omitted.
    var names = List[String]()
    names.append(String("operation"))
    names.append(String("added-data-files"))
    names.append(String("added-records"))
    names.append(String("added-files-size"))
    names.append(String("total-data-files"))
    names.append(String("total-records"))
    names.append(String("total-files-size"))
    names.append(String("komira.commit-id"))
    _assert_strings(md.snapshots[1].summary_names, names)
    var values = List[String]()
    values.append(String("append"))
    values.append(String("2"))
    values.append(String("10"))
    values.append(String("1000"))
    values.append(String("7"))
    values.append(String("60"))
    values.append(String("6000"))
    values.append(_C1)
    _assert_strings(md.snapshots[1].summary_values, values)
    assert_equal(cat.applied_commits, 3)

    assert_equal(cat.request_count() - before, 4)
    assert_equal(cat.request_methods[before], String("GET"))
    assert_equal(cat.request_methods[before + 1], String("POST"))
    assert_equal(cat.request_methods[before + 2], String("GET"))
    assert_equal(cat.request_methods[before + 3], String("POST"))
    var first_body = cat.request_bodies[before + 1]
    var retry_body = cat.request_bodies[before + 3]
    assert_true(
        first_body.find(
            String('{"type":"assert-ref-snapshot-id","ref":"main","snapshot-id":null}')
        )
        >= 0
    )
    assert_true(first_body.find(String('"sequence-number":1,')) >= 0)
    assert_true(first_body.find(_ml(7001, 0)) >= 0)
    assert_true(
        retry_body.find(
            String('{"type":"assert-ref-snapshot-id","ref":"main","snapshot-id":8001}')
        )
        >= 0
    )
    assert_true(
        retry_body.find(
            String('"snapshot-id":7001,"parent-snapshot-id":8001,"sequence-number":2,')
        )
        >= 0
    )
    assert_true(retry_body.find(_ml(7001, 1)) >= 0)
    assert_equal(retry_body.find(_ml(7001, 0)), -1)


def test_statement_that_read_its_target_fails_on_conflict() raises:
    var client = _new_client(False)
    _plain_table(client)
    var writer0 = _Writer()
    var clock0 = ManualCommitClock(_T0)
    var ids0 = SequenceCommitIds(_i1(7001))
    assert_true(commit_append(client, writer0, clock0, ids0, _append(_U1)).committed)
    client.transport_ref().before_next_commit(
        _other_writer_body(Optional[Int64](7001), 2, 8001, _T0 + 50)
    )

    var writer = _Writer()
    var clock = ManualCommitClock(_T0 + 100)
    var ids = SequenceCommitIds(_i1(7002))
    var o = commit_append(
        client,
        writer,
        clock,
        ids,
        _statement(String("t"), _U1, _cols(), _i2(7001, 6000), 2, 10, 1000),
    )

    _assert_outcome(
        o,
        False,
        String(_TOKEN_CONFLICT)
        + String(
            ": commit to 'db.t': the statement read the table at snapshot"
            " 7001, 6000, and main is now 8001"
        ),
        7002,
        _C1,
        -1,
        String(""),
        True,
        _s1(_ml(7002, 0)),
        1,
    )
    _assert_i64s(clock.waits, _i0())
    assert_equal(len(writer.attempts), 1)
    var md = client.transport_ref().metadata(String("db"), String("t"))
    assert_equal(md.main_snapshot_id.value(), 8001)
    assert_equal(len(md.snapshots), 2)


def test_idempotency_key_is_sent_only_when_advertised() raises:
    var plain = _new_client(False)
    _plain_table(plain)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var before = plain.transport_ref().request_count()
    assert_true(commit_append(plain, writer, clock, ids, _append(_U1)).committed)
    ref cat = plain.transport_ref()
    assert_equal(cat.request_methods[before + 1], String("POST"))
    assert_equal(cat.request_keys[before + 1], String(""))

    var keyed = _new_client(True)
    _plain_table(keyed)
    var writer2 = _Writer()
    var clock2 = ManualCommitClock(_T0)
    var ids2 = SequenceCommitIds(_i1(7001))
    var before2 = keyed.transport_ref().request_count()
    assert_true(commit_append(keyed, writer2, clock2, ids2, _append(_U1)).committed)
    ref cat2 = keyed.transport_ref()
    assert_equal(cat2.request_methods[before2 + 1], String("POST"))
    assert_equal(cat2.request_keys[before2 + 1], _C2)


def test_random_commit_ids_are_positive_and_uuid_shaped() raises:
    var ids = RandomCommitIds()
    var seen = List[Int64]()
    for _ in range(20):
        var id = ids.snapshot_id()
        assert_true(id > 0)
        for j in range(len(seen)):
            assert_true(seen[j] != id)
        seen.append(id)
    var first = ids.uuid()
    var second = ids.uuid()
    assert_true(first != second)
    var b = first.as_bytes()
    assert_equal(len(b), 36)
    for i in range(36):
        if i == 8 or i == 13 or i == 18 or i == 23:
            assert_equal(b[i], UInt8(0x2D))
        else:
            assert_true(_is_lower_hex(b[i]))
    assert_equal(b[14], UInt8(0x37))


def test_system_clock_now_is_positive() raises:
    var clock = SystemCommitClock()
    assert_true(clock.now_ms() > 0)
    clock.sleep_ms(0)


def test_sequence_ids_and_manual_clock() raises:
    var ids = SequenceCommitIds(_i2(500, 600))
    assert_equal(ids.snapshot_id(), 500)
    assert_equal(ids.snapshot_id(), 600)
    assert_equal(ids.snapshot_id(), 1)
    assert_equal(ids.snapshot_id(), 2)
    assert_equal(ids.uuid(), _C1)
    assert_equal(ids.uuid(), _C2)
    var clock = ManualCommitClock(10)
    assert_equal(clock.now_ms(), 10)
    clock.sleep_ms(5)
    clock.sleep_ms(7)
    assert_equal(clock.now_ms(), 22)
    _assert_i64s(clock.waits, _i2(5, 7))


def main() raises:
    test_staged_create_appears_only_at_the_commit()
    test_first_append_lands_snapshot_with_exact_summary_and_request()
    test_second_append_totals_add_to_the_first()
    test_timestamp_is_the_clock_or_the_parents_plus_one()
    test_zero_added_files_sends_no_commit()
    test_concurrent_append_rebases_after_wait_and_keeps_both_snapshots()
    test_statement_that_read_its_target_fails_on_conflict()
    test_idempotency_key_is_sent_only_when_advertised()
    test_random_commit_ids_are_positive_and_uuid_shaped()
    test_system_clock_now_is_positive()
    test_sequence_ids_and_manual_clock()
    print("test_iceberg_commit_appen: ALL PASS")

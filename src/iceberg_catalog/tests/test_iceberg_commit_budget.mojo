# =============================================================================
# test_iceberg_commit_budget.mojo — commit_append's retry budget, snapshot ids and base load: waits, caps and
#   timeouts from the table's properties, used snapshot ids, and a load
#   that fails.
# =============================================================================
#
# Each case names what it would catch:
#   * Waits double from the minimum and stop at the maximum; a retry count,
#     a minimum, a maximum and a total timeout come from the table's
#     properties; a total timeout stops retries early, and a wait that ends
#     exactly at it is allowed; an invalid property fails before any commit.
#   * A snapshot id the table already has is drawn again; 64 used ids fail.
#   * A missing table is a definite failure; a load answered 5xx is retried
#     within the budget and fails with its token when the budget is spent.
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


def _s2(a: String, b: String) -> List[String]:
    var l = _s1(a)
    l.append(String(b))
    return l^


def _s3(a: String, b: String, c: String) -> List[String]:
    var l = _s2(a, b)
    l.append(String(c))
    return l^


def _s4(a: String, b: String, c: String, d: String) -> List[String]:
    var l = _s3(a, b, c)
    l.append(String(d))
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


def _fault_conflicts(mut client: _Client, count: Int):
    ref cat = client.transport_ref()
    for _ in range(count):
        cat.fault_next_commit(CommitFault(409, apply_first=False))


def _exhausted_message(attempts: Int) -> String:
    return (
        String(_TOKEN_CONFLICT)
        + String(": commit to 'db.t': the table changed under each of ")
        + String(attempts)
        + String(" attempts and the retry budget is spent; main is now none")
    )


def _all_lists(count: Int) -> List[String]:
    var l = List[String]()
    for i in range(count):
        l.append(_ml(7001, i))
    return l^


def _budget_error(name: String, value: String) -> String:
    var md = TableMetadata()
    md.property_names.append(String(name))
    md.property_values.append(String(value))
    try:
        _ = CommitRetryBudget.from_properties(md)
    except e:
        return String(e)
    return String("")


comptime _SCRIPTED_TABLE: String = (
    '{"metadata-location":"s3://wh/db/t/metadata/v1.metadata.json",'
    '"metadata":{"format-version":2,"table-uuid":"00000000-0000-4000-8000-000000000001",'
    '"location":"s3://wh/db/t","current-schema-id":0,'
    '"schemas":[{"schema-id":0,"fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"name","required":false,"type":"string"},'
    '{"id":3,"name":"amount","required":false,"type":"decimal(9,2)"}]}]}}'
)


def _scripted_client(
    var t: ScriptedIcebergRestTransport,
) -> IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken]:
    return IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken](
        String("catalog.example.com"), t^, StaticBearerToken(String(""))
    )


def test_conflict_on_every_attempt_exhausts_the_default_budget() raises:
    var client = _new_client(False)
    _plain_table(client)
    _fault_conflicts(client, 5)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))

    var o = commit_append(client, writer, clock, ids, _append(_U1))

    _assert_outcome(
        o,
        False,
        _exhausted_message(5),
        7001,
        _C1,
        -1,
        String(""),
        True,
        _all_lists(5),
        5,
    )
    var waits = List[Int64]()
    waits.append(100)
    waits.append(200)
    waits.append(400)
    waits.append(800)
    _assert_i64s(clock.waits, waits)
    assert_equal(client.transport_ref().applied_commits, 1)


def test_wait_is_capped_by_the_max_wait_property() raises:
    var client = _new_client(False)
    _create_table(
        client,
        String("t"),
        _cols(),
        2,
        _s2(String("commit.retry.max-wait-ms"), String("250")),
    )
    _fault_conflicts(client, 5)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))

    var o = commit_append(client, writer, clock, ids, _append(_U1))

    _assert_outcome(
        o,
        False,
        _exhausted_message(5),
        7001,
        _C1,
        -1,
        String(""),
        True,
        _all_lists(5),
        5,
    )
    var waits = List[Int64]()
    waits.append(100)
    waits.append(200)
    waits.append(250)
    waits.append(250)
    _assert_i64s(clock.waits, waits)


def test_retry_count_and_min_wait_come_from_the_table_properties() raises:
    var client = _new_client(False)
    var props = _s4(
        String("commit.retry.num-retries"),
        String("1"),
        String("commit.retry.min-wait-ms"),
        String("30"),
    )
    _create_table(client, String("t"), _cols(), 2, props)
    _fault_conflicts(client, 2)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))

    var o = commit_append(client, writer, clock, ids, _append(_U1))

    _assert_outcome(
        o,
        False,
        _exhausted_message(2),
        7001,
        _C1,
        -1,
        String(""),
        True,
        _all_lists(2),
        2,
    )
    _assert_i64s(clock.waits, _i1(30))


def test_zero_retries_fail_on_the_first_conflict() raises:
    var client = _new_client(False)
    _create_table(
        client,
        String("t"),
        _cols(),
        2,
        _s2(String("commit.retry.num-retries"), String("0")),
    )
    _fault_conflicts(client, 1)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var o = commit_append(client, writer, clock, ids, _append(_U1))
    _assert_outcome(
        o, False, _exhausted_message(1), 7001, _C1, -1, String(""), True, _all_lists(1), 1
    )
    _assert_i64s(clock.waits, _i0())


def test_total_timeout_stops_retries_early() raises:
    var client = _new_client(False)
    _create_table(
        client,
        String("t"),
        _cols(),
        2,
        _s2(String("commit.retry.total-timeout-ms"), String("250")),
    )
    _fault_conflicts(client, 5)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))

    var o = commit_append(client, writer, clock, ids, _append(_U1))

    # 100 ms fits; the next wait of 200 would end at 300 ms, past 250.
    _assert_outcome(
        o,
        False,
        _exhausted_message(2),
        7001,
        _C1,
        -1,
        String(""),
        True,
        _all_lists(2),
        2,
    )
    _assert_i64s(clock.waits, _i1(100))


def test_total_timeout_allows_a_wait_that_ends_exactly_at_it() raises:
    var client = _new_client(False)
    _create_table(
        client,
        String("t"),
        _cols(),
        2,
        _s2(String("commit.retry.total-timeout-ms"), String("300")),
    )
    _fault_conflicts(client, 5)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))

    var o = commit_append(client, writer, clock, ids, _append(_U1))

    _assert_outcome(
        o,
        False,
        _exhausted_message(3),
        7001,
        _C1,
        -1,
        String(""),
        True,
        _all_lists(3),
        3,
    )
    var waits = List[Int64]()
    waits.append(100)
    waits.append(200)
    _assert_i64s(clock.waits, waits)


def test_invalid_budget_property_fails_before_any_commit() raises:
    var client = _new_client(False)
    _create_table(
        client,
        String("t"),
        _cols(),
        2,
        _s2(String("commit.retry.num-retries"), String("abc")),
    )
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var o = commit_append(client, writer, clock, ids, _append(_U1))
    _assert_outcome(
        o,
        False,
        String(
            "ICEBERG_CATALOG_RESPONSE_INVALID: table property"
            " 'commit.retry.num-retries' is not a non-negative integer: 'abc'"
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
    # Only the staged create and the commit that creates the table were sent.
    assert_equal(_post_count(client), 2)


def test_budget_properties_defaults_and_invalid_values() raises:
    var b = CommitRetryBudget.from_properties(TableMetadata())
    assert_equal(b.num_retries, 4)
    assert_equal(b.min_wait_ms, 100)
    assert_equal(b.max_wait_ms, 60000)
    assert_equal(b.total_timeout_ms, 1800000)

    var md = TableMetadata()
    md.property_names.append(String("commit.retry.num-retries"))
    md.property_values.append(String("7"))
    md.property_names.append(String("commit.retry.min-wait-ms"))
    md.property_values.append(String("11"))
    md.property_names.append(String("commit.retry.max-wait-ms"))
    md.property_values.append(String("999999999999999999"))
    md.property_names.append(String("commit.retry.total-timeout-ms"))
    md.property_values.append(String("0"))
    var c = CommitRetryBudget.from_properties(md)
    assert_equal(c.num_retries, 7)
    assert_equal(c.min_wait_ms, 11)
    assert_equal(c.max_wait_ms, 999999999999999999)
    assert_equal(c.total_timeout_ms, 0)

    var names = _s4(
        String("commit.retry.num-retries"),
        String("commit.retry.min-wait-ms"),
        String("commit.retry.max-wait-ms"),
        String("commit.retry.total-timeout-ms"),
    )
    for i in range(len(names)):
        assert_equal(
            _budget_error(names[i], String("x1")),
            String("ICEBERG_CATALOG_RESPONSE_INVALID: table property '")
            + names[i]
            + String("' is not a non-negative integer: 'x1'"),
        )
    var bad = _s4(
        String(""),
        String("-1"),
        String("12.5"),
        String("1234567890123456789"),
    )
    for i in range(len(bad)):
        assert_equal(
            _budget_error(String("commit.retry.min-wait-ms"), bad[i]),
            String(
                "ICEBERG_CATALOG_RESPONSE_INVALID: table property"
                " 'commit.retry.min-wait-ms' is not a non-negative integer: '"
            )
            + bad[i]
            + String("'"),
        )


def test_used_snapshot_id_is_drawn_again() raises:
    var client = _new_client(False)
    _plain_table(client)
    var writer0 = _Writer()
    var clock0 = ManualCommitClock(_T0)
    var ids0 = SequenceCommitIds(_i1(7001))
    assert_true(commit_append(client, writer0, clock0, ids0, _append(_U1)).committed)

    var writer = _Writer()
    var clock = ManualCommitClock(_T0 + 10)
    var drawn = List[Int64]()
    drawn.append(7001)
    drawn.append(7001)
    drawn.append(7002)
    var ids = SequenceCommitIds(drawn^)
    var o = commit_append(client, writer, clock, ids, _append(_U1))
    _assert_outcome(
        o, True, String(""), 7002, _C1, 7002, _ml(7002, 0), False, _s0(), 1
    )
    _assert_i64s(writer.snapshot_ids, _i1(7002))


def test_sixty_four_used_snapshot_ids_fail() raises:
    var client = _new_client(False)
    _plain_table(client)
    var writer0 = _Writer()
    var clock0 = ManualCommitClock(_T0)
    var ids0 = SequenceCommitIds(_i1(7001))
    assert_true(commit_append(client, writer0, clock0, ids0, _append(_U1)).committed)

    var writer = _Writer()
    var clock = ManualCommitClock(_T0 + 10)
    var drawn = List[Int64]()
    for _ in range(70):
        drawn.append(7001)
    var ids = SequenceCommitIds(drawn^)
    var before = _post_count(client)
    var o = commit_append(client, writer, clock, ids, _append(_U1))
    _assert_outcome(
        o,
        False,
        String(_TOKEN_CONFLICT)
        + String(": commit to 'db.t': no unused snapshot id after 64 draws"),
        7001,
        String(""),
        -1,
        String(""),
        True,
        _s0(),
        0,
    )
    assert_equal(len(writer.attempts), 0)
    assert_equal(_post_count(client), before)


def test_missing_table_load_is_a_definite_failure() raises:
    var client = _new_client(False)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var o = commit_append(
        client,
        writer,
        clock,
        ids,
        _statement(String("missing"), _U1, _cols(), _i0(), 1, 1, 1),
    )
    _assert_outcome(
        o,
        False,
        String(
            "ICEBERG_TABLE_NOT_FOUND: loadTable 'db.missing': HTTP 404:"
            " NoSuchTableException: Table does not exist: db.missing"
        ),
        0,
        String(""),
        -1,
        String(""),
        True,
        _s0(),
        0,
    )
    _assert_i64s(clock.waits, _i0())
    assert_equal(len(writer.attempts), 0)


def test_load_answered_5xx_is_retried_within_the_budget() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String("{}"))
    t.queue_response(503, String(""))
    t.queue_response(503, String(""))
    t.queue_response(200, String(_SCRIPTED_TABLE))
    var client = _scripted_client(t^)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var o = commit_append(
        client,
        writer,
        clock,
        ids,
        _statement(String("t"), _U1, _cols(), _i0(), 0, 0, 0),
    )
    _assert_outcome(o, True, String(""), 0, String(""), -1, String(""), False, _s0(), 0)
    var waits = List[Int64]()
    waits.append(100)
    waits.append(200)
    _assert_i64s(clock.waits, waits)
    assert_equal(client.transport_ref().call_count(), 4)


def test_load_answered_5xx_every_time_fails_after_the_budget() raises:
    var t = ScriptedIcebergRestTransport()
    t.queue_response(200, String("{}"))
    for _ in range(5):
        t.queue_response(503, String(""))
    var client = _scripted_client(t^)
    var writer = _Writer()
    var clock = ManualCommitClock(_T0)
    var ids = SequenceCommitIds(_i1(7001))
    var o = commit_append(client, writer, clock, ids, _append(_U1))
    _assert_outcome(
        o,
        False,
        String("ICEBERG_CATALOG_UNAVAILABLE: loadTable 'db.t': HTTP 503"),
        0,
        String(""),
        -1,
        String(""),
        True,
        _s0(),
        0,
    )
    var waits = List[Int64]()
    waits.append(100)
    waits.append(200)
    waits.append(400)
    waits.append(800)
    _assert_i64s(clock.waits, waits)


def main() raises:
    test_conflict_on_every_attempt_exhausts_the_default_budget()
    test_wait_is_capped_by_the_max_wait_property()
    test_retry_count_and_min_wait_come_from_the_table_properties()
    test_zero_retries_fail_on_the_first_conflict()
    test_total_timeout_stops_retries_early()
    test_total_timeout_allows_a_wait_that_ends_exactly_at_it()
    test_invalid_budget_property_fails_before_any_commit()
    test_budget_properties_defaults_and_invalid_values()
    test_used_snapshot_id_is_drawn_again()
    test_sixty_four_used_snapshot_ids_fail()
    test_missing_table_load_is_a_definite_failure()
    test_load_answered_5xx_is_retried_within_the_budget()
    test_load_answered_5xx_every_time_fails_after_the_budget()
    print("test_iceberg_commit_budge: ALL PASS")

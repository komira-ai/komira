# =============================================================================
# test_iceberg_rest_test_catalog_scripting.mojo — the in-process REST catalog's
#   idempotency keys and its scripted commit behaviour.
# =============================================================================
#
#   * idempotency: a key seen before is answered with the stored response and
#     nothing is applied twice; keys are ignored when not advertised; a
#     request with no key is never replayed.
#   * before_next_commit: another writer's commit lands ahead of the next
#     commit request, one body per request, in FIFO order.
#   * CommitFault: status 0 raises; other statuses answer a scripted error;
#     apply_first lands the commit before the failure; rewrite_snapshot_id,
#     then_body and then_expire act after it; faults are consumed in FIFO
#     order by commit requests only.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from json import JsonValue, parse_json_value

from iceberg_catalog.iceberg_rest_catalog_client import (
    COMMIT_APPLIED,
    COMMIT_CONFLICT,
    COMMIT_UNKNOWN,
    IcebergRestCatalog,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_rest_errors import (
    ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED,
)
from iceberg_catalog.iceberg_rest_test_catalog import (
    CommitFault,
    InMemoryIcebergRestCatalog,
)
from iceberg_catalog.iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
)
from iceberg_catalog.iceberg_table_changes import (
    CreateTableRequest,
    NewSnapshot,
    TableRequirement,
    TableUpdate,
    commit_table_body,
)


comptime _SCHEMA: String = (
    '{"type":"struct","fields":[{"id":1,"name":"id","required":true,'
    '"type":"long"},{"id":2,"name":"v","required":false,"type":"string"}]}'
)
comptime _TABLES: String = "/v1/p/namespaces/db/tables"
comptime _TABLE: String = "/v1/p/namespaces/db/tables/t"
comptime _Client = IcebergRestCatalog[
    InMemoryIcebergRestCatalog, StaticBearerToken
]


# =============================================================================
# helpers.
# =============================================================================


def _catalog() -> InMemoryIcebergRestCatalog:
    var c = InMemoryIcebergRestCatalog(String("p"), String("s3://wh"))
    c.create_namespace(String("db"))
    return c^


def _get(path: String) -> IcebergRestRequest:
    return IcebergRestRequest(
        String("catalog.example.com"),
        443,
        String(path),
        List[String](),
        List[String](),
    )


def _post(
    path: String, body: String, key: String = String("")
) -> IcebergRestRequest:
    var names = List[String]()
    var values = List[String]()
    if key.byte_length() > 0:
        names.append(String("Idempotency-Key"))
        values.append(String(key))
    return IcebergRestRequest.post(
        String("catalog.example.com"),
        443,
        String(path),
        names^,
        values^,
        String(body),
    )


def _create_body(
    name: String,
    stage: Bool = False,
    location: String = String(""),
    properties: String = String(""),
) -> String:
    var s = String('{"name":"') + name + String('","schema":') + _SCHEMA
    if location.byte_length() > 0:
        s += String(',"location":"') + location + String('"')
    if properties.byte_length() > 0:
        s += String(',"properties":') + properties
    if stage:
        s += String(',"stage-create":true}')
    else:
        s += String(',"stage-create":false}')
    return s^


def _create(mut c: InMemoryIcebergRestCatalog, name: String) raises:
    var r = c.send(_post(_TABLES, _create_body(name)))
    assert_equal(r.status, 200)


def _seeded() raises -> InMemoryIcebergRestCatalog:
    var c = _catalog()
    _create(c, String("t"))
    return c^


def _error_line(r: IcebergRestResponse) raises -> String:
    """`<status> <type>: <message>`, after checking the envelope's code is the
    status."""
    var e = parse_json_value(r.body).get(String("error"))
    assert_equal(e.get(String("code")).as_int64(), Int64(r.status))
    return (
        String(r.status)
        + String(" ")
        + e.get(String("type")).as_string()
        + String(": ")
        + e.get(String("message")).as_string()
    )


def _md(c: InMemoryIcebergRestCatalog) raises -> JsonValue:
    return parse_json_value(c.metadata_json(String("db"), String("t")))


def _location(r: IcebergRestResponse) raises -> String:
    return parse_json_value(r.body).get(String("metadata-location")).as_string()


def _props_body(name: String, value: String) -> String:
    return (
        String('{"requirements":[],"updates":[{"action":"set-properties",')
        + String('"updates":{"')
        + name
        + String('":"')
        + value
        + String('"}}]}')
    )


def _snapshot(id: Int64, seq: Int64) -> TableUpdate:
    return TableUpdate.add_snapshot(
        NewSnapshot(
            id,
            None,
            seq,
            1000,
            0,
            String("s3://wh/m.avro"),
            String("append"),
            List[String](),
            List[String](),
        )
    )


def _snapshot_body(id: Int64, seq: Int64) raises -> String:
    var ups = List[TableUpdate]()
    ups.append(_snapshot(id, seq))
    ups.append(TableUpdate.set_branch(String("main"), id))
    return commit_table_body(List[TableRequirement](), ups)


def _one(s: String) -> List[String]:
    var l = List[String]()
    l.append(String(s))
    return l^


def _raise_text_send(
    mut c: InMemoryIcebergRestCatalog, var req: IcebergRestRequest
) -> String:
    """The message `send` raised, or "" when it answered."""
    try:
        _ = c.send(req)
    except e:
        return String(e)
    return String("")


# =============================================================================
# idempotency.
# =============================================================================


def test_reused_key_replays_the_stored_response_and_applies_nothing() raises:
    var c = _seeded()
    c.advertise_idempotency()
    var body = _props_body(String("k"), String("v"))
    var first = c.send(_post(_TABLE, body, String("K")))
    assert_equal(first.status, 200)
    assert_equal(
        _location(first), String("s3://wh/db/t/metadata/v2.metadata.json")
    )
    var second = c.send(_post(_TABLE, body, String("K")))
    assert_equal(second.status, 200)
    assert_equal(second.body, first.body)
    assert_equal(c.applied_commits, 1)
    assert_equal(c.request_count(), 3)
    assert_equal(
        _location(c.send(_get(_TABLE))),
        String("s3://wh/db/t/metadata/v2.metadata.json"),
    )
    # The key is answered even when the body differs: nothing is applied.
    var other = c.send(
        _post(_TABLE, _props_body(String("k"), String("changed")), String("K"))
    )
    assert_equal(other.body, first.body)
    assert_equal(c.applied_commits, 1)
    assert_equal(
        c.metadata(String("db"), String("t")).property(String("k")).value(),
        String("v"),
    )


def test_distinct_keys_each_apply() raises:
    var c = _seeded()
    c.advertise_idempotency()
    var a = c.send(
        _post(_TABLE, _props_body(String("a"), String("1")), String("K1"))
    )
    var b = c.send(
        _post(_TABLE, _props_body(String("b"), String("2")), String("K2"))
    )
    assert_equal(a.status, 200)
    assert_equal(b.status, 200)
    assert_equal(c.applied_commits, 2)
    assert_equal(
        _location(b), String("s3://wh/db/t/metadata/v3.metadata.json")
    )


def test_keys_are_ignored_when_not_advertised() raises:
    var c = _seeded()
    var body = _props_body(String("k"), String("v"))
    var first = c.send(_post(_TABLE, body, String("K")))
    var second = c.send(_post(_TABLE, body, String("K")))
    assert_equal(
        _location(first), String("s3://wh/db/t/metadata/v2.metadata.json")
    )
    assert_equal(
        _location(second), String("s3://wh/db/t/metadata/v3.metadata.json")
    )
    assert_equal(c.applied_commits, 2)


def test_a_request_without_a_key_is_never_replayed() raises:
    var c = _seeded()
    c.advertise_idempotency()
    var body = _props_body(String("k"), String("v"))
    _ = c.send(_post(_TABLE, body))
    _ = c.send(_post(_TABLE, body))
    assert_equal(c.applied_commits, 2)


def test_create_with_a_reused_key_replays_instead_of_conflicting() raises:
    var c = _catalog()
    c.advertise_idempotency()
    var first = c.send(_post(_TABLES, _create_body(String("t")), String("C")))
    var second = c.send(_post(_TABLES, _create_body(String("t")), String("C")))
    assert_equal(first.status, 200)
    assert_equal(second.status, 200)
    assert_equal(second.body, first.body)
    var third = c.send(_post(_TABLES, _create_body(String("t")), String("D")))
    assert_equal(third.status, 409)


def test_a_dropped_commit_that_applied_is_replayed_under_its_key() raises:
    var c = _seeded()
    c.advertise_idempotency()
    c.fault_next_commit(CommitFault(503, apply_first=True))
    var body = _props_body(String("k"), String("v"))
    var lost = c.send(_post(_TABLE, body, String("K")))
    assert_equal(
        _error_line(lost),
        String("503 ServiceFailureException: scripted failure"),
    )
    assert_equal(c.applied_commits, 1)
    var retry = c.send(_post(_TABLE, body, String("K")))
    assert_equal(retry.status, 200)
    assert_equal(
        _location(retry), String("s3://wh/db/t/metadata/v2.metadata.json")
    )
    assert_equal(c.applied_commits, 1)


# =============================================================================
# scripting: before_next_commit.
# =============================================================================


def test_before_next_commit_lands_ahead_of_the_next_commit() raises:
    var c = _seeded()
    c.before_next_commit(_snapshot_body(11, 1))
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_ref_snapshot_id(String("main"), None))
    var mine = c.send(
        _post(_TABLE, commit_table_body(reqs, List[TableUpdate]()))
    )
    assert_equal(
        _error_line(mine),
        String(
            "409 CommitFailedException: Requirement failed: ref main exists"
        ),
    )
    assert_equal(c.applied_commits, 1)
    assert_equal(c.metadata(String("db"), String("t")).main_snapshot_id.value(), Int64(11))


def test_before_next_commit_is_consumed_one_per_commit_in_fifo_order() raises:
    var c = _seeded()
    c.before_next_commit(_props_body(String("order"), String("first")))
    c.before_next_commit(_props_body(String("order"), String("second")))
    var a = c.send(_post(_TABLE, _props_body(String("a"), String("1"))))
    assert_equal(a.status, 200)
    assert_equal(c.applied_commits, 2)
    assert_equal(
        c.metadata(String("db"), String("t")).property(String("order")).value(),
        String("first"),
    )
    var b = c.send(_post(_TABLE, _props_body(String("b"), String("2"))))
    assert_equal(b.status, 200)
    assert_equal(c.applied_commits, 4)
    assert_equal(
        c.metadata(String("db"), String("t")).property(String("order")).value(),
        String("second"),
    )
    var after = c.send(_post(_TABLE, _props_body(String("c"), String("3"))))
    assert_equal(after.status, 200)
    assert_equal(c.applied_commits, 5)
    assert_equal(
        _location(after), String("s3://wh/db/t/metadata/v6.metadata.json")
    )


def test_before_next_commit_waits_for_a_commit_request() raises:
    var c = _seeded()
    c.before_next_commit(_props_body(String("other"), String("1")))
    var got = c.send(_get(_TABLE))
    assert_equal(got.status, 200)
    assert_equal(c.applied_commits, 0)
    assert_false(
        Bool(c.metadata(String("db"), String("t")).property(String("other")))
    )


# =============================================================================
# scripting: CommitFault.
# =============================================================================


def test_fault_status_zero_raises_and_applies_nothing() raises:
    var c = _seeded()
    c.fault_next_commit(CommitFault(0, apply_first=False))
    var msg = _raise_text_send(
        c, _post(_TABLE, _props_body(String("k"), String("v")))
    )
    assert_equal(msg, String("InMemoryIcebergRestCatalog: connection dropped"))
    assert_equal(c.applied_commits, 0)
    assert_equal(c.request_count(), 2)
    assert_equal(
        _location(c.send(_get(_TABLE))),
        String("s3://wh/db/t/metadata/v1.metadata.json"),
    )


def test_fault_status_zero_after_apply_raises_but_the_commit_landed() raises:
    var c = _seeded()
    c.fault_next_commit(CommitFault(0, apply_first=True))
    var msg = _raise_text_send(
        c, _post(_TABLE, _props_body(String("k"), String("v")))
    )
    assert_equal(msg, String("InMemoryIcebergRestCatalog: connection dropped"))
    assert_equal(c.applied_commits, 1)
    assert_equal(
        c.metadata(String("db"), String("t")).property(String("k")).value(),
        String("v"),
    )


def test_fault_409_answers_a_scripted_conflict() raises:
    var c = _seeded()
    c.fault_next_commit(CommitFault(409, apply_first=False))
    var r = c.send(_post(_TABLE, _props_body(String("k"), String("v"))))
    assert_equal(
        _error_line(r),
        String("409 CommitFailedException: scripted conflict"),
    )
    assert_equal(c.applied_commits, 0)


def test_fault_other_statuses_answer_a_scripted_service_failure() raises:
    var statuses = List[Int]()
    statuses.append(500)
    statuses.append(503)
    statuses.append(404)
    for i in range(len(statuses)):
        var c = _seeded()
        c.fault_next_commit(CommitFault(statuses[i], apply_first=False))
        var r = c.send(_post(_TABLE, _props_body(String("k"), String("v"))))
        assert_equal(
            _error_line(r),
            String(statuses[i])
            + String(" ServiceFailureException: scripted failure"),
        )
        assert_equal(c.applied_commits, 0)
        assert_false(
            Bool(c.metadata(String("db"), String("t")).property(String("k")))
        )


def test_fault_apply_first_lands_the_commit_before_the_failure() raises:
    var c = _seeded()
    c.fault_next_commit(CommitFault(503, apply_first=True))
    var r = c.send(_post(_TABLE, _props_body(String("k"), String("v"))))
    assert_equal(r.status, 503)
    assert_equal(c.applied_commits, 1)
    assert_equal(
        c.metadata(String("db"), String("t")).property(String("k")).value(),
        String("v"),
    )


def test_fault_rewrite_snapshot_id_stores_the_snapshot_under_the_new_id() raises:
    var c = _seeded()
    c.fault_next_commit(
        CommitFault(503, apply_first=True, rewrite_snapshot_id=555)
    )
    var ups = List[TableUpdate]()
    ups.append(
        TableUpdate.set_properties(_one(String("k")), _one(String("v")))
    )
    ups.append(_snapshot(100, 1))
    ups.append(TableUpdate.set_branch(String("main"), 100))
    var r = c.send(
        _post(_TABLE, commit_table_body(List[TableRequirement](), ups))
    )
    assert_equal(r.status, 503)
    var md = c.metadata(String("db"), String("t"))
    assert_equal(len(md.snapshots), 1)
    assert_equal(md.snapshots[0].snapshot_id, Int64(555))
    assert_equal(md.snapshots[0].manifest_list, String("s3://wh/m.avro"))
    assert_equal(
        md.snapshots[0].summary(String("operation")).value(), String("append")
    )
    assert_equal(md.main_snapshot_id.value(), Int64(555))
    assert_equal(md.property(String("k")).value(), String("v"))
    assert_equal(
        _md(c).get(String("refs")).get(String("main"))
        .get(String("snapshot-id")).as_int64(),
        Int64(555),
    )


def test_fault_rewrite_without_apply_first_changes_nothing() raises:
    var c = _seeded()
    c.fault_next_commit(
        CommitFault(503, apply_first=False, rewrite_snapshot_id=555)
    )
    _ = c.send(_post(_TABLE, _snapshot_body(100, 1)))
    assert_equal(len(c.metadata(String("db"), String("t")).snapshots), 0)


def test_fault_then_body_applies_another_writers_commit_after() raises:
    var c = _seeded()
    c.fault_next_commit(
        CommitFault(
            409,
            apply_first=False,
            then_body=_props_body(String("later"), String("1")),
        )
    )
    var r = c.send(_post(_TABLE, _props_body(String("mine"), String("1"))))
    assert_equal(r.status, 409)
    assert_equal(c.applied_commits, 1)
    var md = c.metadata(String("db"), String("t"))
    assert_equal(md.property(String("later")).value(), String("1"))
    assert_false(Bool(md.property(String("mine"))))


def test_fault_then_body_follows_an_applied_commit() raises:
    var c = _seeded()
    c.fault_next_commit(
        CommitFault(
            503,
            apply_first=True,
            then_body=_props_body(String("later"), String("1")),
        )
    )
    _ = c.send(_post(_TABLE, _props_body(String("mine"), String("1"))))
    assert_equal(c.applied_commits, 2)
    assert_equal(
        _location(c.send(_get(_TABLE))),
        String("s3://wh/db/t/metadata/v3.metadata.json"),
    )


def test_fault_then_expire_removes_a_snapshot_afterwards() raises:
    var c = _seeded()
    _ = c.send(_post(_TABLE, _snapshot_body(11, 1)))
    c.fault_next_commit(
        CommitFault(503, apply_first=True, then_expire=11)
    )
    _ = c.send(_post(_TABLE, _snapshot_body(12, 2)))
    var md = c.metadata(String("db"), String("t"))
    assert_equal(len(md.snapshots), 1)
    assert_equal(md.snapshots[0].snapshot_id, Int64(12))


def test_fault_then_body_runs_before_then_expire() raises:
    var c = _seeded()
    c.fault_next_commit(
        CommitFault(
            503,
            apply_first=False,
            then_body=_snapshot_body(21, 1),
            then_expire=21,
        )
    )
    _ = c.send(_post(_TABLE, _props_body(String("k"), String("v"))))
    var md = c.metadata(String("db"), String("t"))
    assert_equal(len(md.snapshots), 0)
    assert_equal(md.last_sequence_number, Int64(1))


def test_faults_are_consumed_in_fifo_order_then_commits_apply_normally() raises:
    var c = _seeded()
    c.fault_next_commit(CommitFault(409, apply_first=False))
    c.fault_next_commit(CommitFault(503, apply_first=False))
    var first = c.send(_post(_TABLE, _props_body(String("k"), String("1"))))
    var second = c.send(_post(_TABLE, _props_body(String("k"), String("2"))))
    var third = c.send(_post(_TABLE, _props_body(String("k"), String("3"))))
    assert_equal(
        _error_line(first),
        String("409 CommitFailedException: scripted conflict"),
    )
    assert_equal(
        _error_line(second),
        String("503 ServiceFailureException: scripted failure"),
    )
    assert_equal(third.status, 200)
    assert_equal(c.applied_commits, 1)


def test_a_fault_is_consumed_by_a_commit_not_by_a_load_or_create() raises:
    var c = _catalog()
    c.fault_next_commit(CommitFault(503, apply_first=False))
    _create(c, String("t"))
    assert_equal(c.send(_get(_TABLE)).status, 200)
    var r = c.send(_post(_TABLE, _props_body(String("k"), String("v"))))
    assert_equal(r.status, 503)


def test_before_next_commit_runs_ahead_of_a_fault() raises:
    var c = _seeded()
    c.before_next_commit(_props_body(String("other"), String("1")))
    c.fault_next_commit(CommitFault(409, apply_first=False))
    var r = c.send(_post(_TABLE, _props_body(String("mine"), String("1"))))
    assert_equal(r.status, 409)
    assert_equal(c.applied_commits, 1)
    assert_equal(
        c.metadata(String("db"), String("t")).property(String("other")).value(),
        String("1"),
    )


def test_client_sees_a_dropped_or_failed_commit_as_unknown_and_a_409_as_conflict() raises:
    var c = _seeded()
    c.fault_next_commit(CommitFault(0, apply_first=True))
    c.fault_next_commit(CommitFault(409, apply_first=False))
    var cl = _Client(String("h"), c^, StaticBearerToken(String("")))
    var body = _props_body(String("k"), String("v"))
    var dropped = cl.commit_table(String("db"), String("t"), body, String(""))
    assert_equal(dropped.kind, COMMIT_UNKNOWN)
    assert_equal(dropped.status, 0)
    var conflict = cl.commit_table(String("db"), String("t"), body, String(""))
    assert_equal(conflict.kind, COMMIT_CONFLICT)
    var ok = cl.commit_table(String("db"), String("t"), body, String(""))
    assert_equal(ok.kind, COMMIT_APPLIED)
    assert_equal(
        ok.table.value().metadata_location,
        String("s3://wh/db/t/metadata/v3.metadata.json"),
    )
    ref rec = cl.transport_ref()
    assert_equal(rec.applied_commits, 2)


def main() raises:
    test_reused_key_replays_the_stored_response_and_applies_nothing()
    test_distinct_keys_each_apply()
    test_keys_are_ignored_when_not_advertised()
    test_a_request_without_a_key_is_never_replayed()
    test_create_with_a_reused_key_replays_instead_of_conflicting()
    test_a_dropped_commit_that_applied_is_replayed_under_its_key()
    test_before_next_commit_lands_ahead_of_the_next_commit()
    test_before_next_commit_is_consumed_one_per_commit_in_fifo_order()
    test_before_next_commit_waits_for_a_commit_request()
    test_fault_status_zero_raises_and_applies_nothing()
    test_fault_status_zero_after_apply_raises_but_the_commit_landed()
    test_fault_409_answers_a_scripted_conflict()
    test_fault_other_statuses_answer_a_scripted_service_failure()
    test_fault_apply_first_lands_the_commit_before_the_failure()
    test_fault_rewrite_snapshot_id_stores_the_snapshot_under_the_new_id()
    test_fault_rewrite_without_apply_first_changes_nothing()
    test_fault_then_body_applies_another_writers_commit_after()
    test_fault_then_body_follows_an_applied_commit()
    test_fault_then_expire_removes_a_snapshot_afterwards()
    test_fault_then_body_runs_before_then_expire()
    test_faults_are_consumed_in_fifo_order_then_commits_apply_normally()
    test_a_fault_is_consumed_by_a_commit_not_by_a_load_or_create()
    test_before_next_commit_runs_ahead_of_a_fault()
    test_client_sees_a_dropped_or_failed_commit_as_unknown_and_a_409_as_conflict()
    print("test_iceberg_rest_test_catalog_scripting: ALL PASS")

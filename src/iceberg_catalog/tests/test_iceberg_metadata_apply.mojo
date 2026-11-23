# =============================================================================
# test_iceberg_metadata_apply.mojo — a catalog's side of a commit, requirements
#   and missing tables, through the in-process REST catalog.
# =============================================================================
#
# Each case names the behaviour it holds; each refusal is asserted by its exact
# status, type and message.
#   * requirements: each kind passes against matching metadata and answers
#     409 CommitFailedException with its own message against a mismatch; a
#     failing requirement applies nothing, not even the updates before it.
#   * missing tables: a commit without `assert-create` is a 404; with it the
#     commit creates the table, and a failed update creates nothing.
# The update rules are in test_iceberg_metadata_updates.mojo.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from json import JsonValue, parse_json_value

from iceberg_catalog.iceberg_metadata_apply import (
    ApplyState,
    BAD_REQUEST,
    COMMIT_FAILED,
    apply_update,
    check_requirement,
    empty_table_metadata,
    int_member,
    member_index,
    put_member,
    ref_snapshot_id,
    remove_member,
    remove_snapshot,
    unpartitioned_spec,
    unsorted_order,
)
from iceberg_catalog.iceberg_rest_test_catalog import InMemoryIcebergRestCatalog
from iceberg_catalog.iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
)
from iceberg_catalog.iceberg_table_changes import (
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
comptime _UUID: String = "00000000-0000-4000-8000-000000000001"


# =============================================================================
# helpers.
# =============================================================================


def _post(path: String, body: String) -> IcebergRestRequest:
    return IcebergRestRequest.post(
        String("catalog.example.com"),
        443,
        String(path),
        List[String](),
        List[String](),
        String(body),
    )


def _seeded() raises -> InMemoryIcebergRestCatalog:
    var c = InMemoryIcebergRestCatalog(String("p"), String("s3://wh"))
    c.create_namespace(String("db"))
    var r = c.send(
        _post(
            _TABLES,
            String('{"name":"t","schema":')
            + _SCHEMA
            + String(',"stage-create":false}'),
        )
    )
    assert_equal(r.status, 200)
    return c^


def _error_line(r: IcebergRestResponse) raises -> String:
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


def _int(v: JsonValue, key: String) raises -> Int64:
    return v.get(key).as_int64()


def _commit(
    mut c: InMemoryIcebergRestCatalog,
    var reqs: List[TableRequirement],
    var ups: List[TableUpdate],
) raises -> IcebergRestResponse:
    return c.send(_post(_TABLE, commit_table_body(reqs, ups)))


def _strs(s: String) -> List[String]:
    var l = List[String]()
    l.append(String(s))
    return l^


def _ups(var u: TableUpdate) -> List[TableUpdate]:
    var l = List[TableUpdate]()
    l.append(u^)
    return l^


def _reqs(var r: TableRequirement) -> List[TableRequirement]:
    var l = List[TableRequirement]()
    l.append(r^)
    return l^


def _no_reqs() -> List[TableRequirement]:
    return List[TableRequirement]()


def _no_ups() -> List[TableUpdate]:
    return List[TableUpdate]()


def _raw(
    mut c: InMemoryIcebergRestCatalog, reqs: String, ups: String
) raises -> IcebergRestResponse:
    return c.send(
        _post(
            _TABLE,
            String('{"requirements":')
            + reqs
            + String(',"updates":')
            + ups
            + String("}"),
        )
    )


def _snap(id: Int64, seq: Int64) -> TableUpdate:
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


def _with_main(mut c: InMemoryIcebergRestCatalog, id: Int64, seq: Int64) raises:
    var ups = List[TableUpdate]()
    ups.append(_snap(id, seq))
    ups.append(TableUpdate.set_branch(String("main"), id))
    var r = _commit(c, _no_reqs(), ups^)
    assert_equal(r.status, 200)


def _requirement_error(
    var req: TableRequirement,
) raises -> String:
    var c = _seeded()
    var r = _commit(c, _reqs(req^), _no_ups())
    assert_equal(c.applied_commits, 0)
    return _error_line(r)


def _requirement_holds(var req: TableRequirement) raises:
    var c = _seeded()
    var r = _commit(c, _reqs(req^), _no_ups())
    assert_equal(r.status, 200)
    assert_equal(c.applied_commits, 1)


def _json(text: String) raises -> JsonValue:
    return parse_json_value(text)


# =============================================================================
# requirements.
# =============================================================================


def test_assert_create_on_an_existing_table_is_409() raises:
    assert_equal(
        _requirement_error(TableRequirement.assert_create()),
        String(
            "409 CommitFailedException: Requirement failed: the table already"
            " exists"
        ),
    )


def test_assert_table_uuid_passes_and_fails() raises:
    _requirement_holds(TableRequirement.assert_table_uuid(String(_UUID)))
    assert_equal(
        _requirement_error(TableRequirement.assert_table_uuid(String("other"))),
        String(
            "409 CommitFailedException: Requirement failed: table uuid is not"
            " other"
        ),
    )


def test_assert_ref_snapshot_id_none_passes_without_the_ref() raises:
    _requirement_holds(
        TableRequirement.assert_ref_snapshot_id(String("main"), None)
    )


def test_assert_ref_snapshot_id_none_fails_when_the_ref_exists() raises:
    var c = _seeded()
    _with_main(c, 11, 1)
    var r = _commit(
        c,
        _reqs(TableRequirement.assert_ref_snapshot_id(String("main"), None)),
        _no_ups(),
    )
    assert_equal(
        _error_line(r),
        String(
            "409 CommitFailedException: Requirement failed: ref main exists"
        ),
    )
    assert_equal(c.applied_commits, 1)


def test_assert_ref_snapshot_id_with_an_id_passes_and_fails() raises:
    var c = _seeded()
    _with_main(c, 11, 1)
    var ok = _commit(
        c,
        _reqs(
            TableRequirement.assert_ref_snapshot_id(
                String("main"), Optional[Int64](11)
            )
        ),
        _no_ups(),
    )
    assert_equal(ok.status, 200)
    var wrong = _commit(
        c,
        _reqs(
            TableRequirement.assert_ref_snapshot_id(
                String("main"), Optional[Int64](12)
            )
        ),
        _no_ups(),
    )
    assert_equal(
        _error_line(wrong),
        String(
            "409 CommitFailedException: Requirement failed: ref main is not at"
            " snapshot 12"
        ),
    )
    var absent = _commit(
        c,
        _reqs(
            TableRequirement.assert_ref_snapshot_id(
                String("dev"), Optional[Int64](11)
            )
        ),
        _no_ups(),
    )
    assert_equal(
        _error_line(absent),
        String(
            "409 CommitFailedException: Requirement failed: ref dev is not at"
            " snapshot 11"
        ),
    )


def test_assert_ref_snapshot_id_without_an_id_member_means_no_ref() raises:
    var c = _seeded()
    var ok = _raw(
        c, String('[{"type":"assert-ref-snapshot-id","ref":"main"}]'), String("[]")
    )
    assert_equal(ok.status, 200)
    _with_main(c, 11, 1)
    var bad = _raw(
        c, String('[{"type":"assert-ref-snapshot-id","ref":"main"}]'), String("[]")
    )
    assert_equal(
        _error_line(bad),
        String(
            "409 CommitFailedException: Requirement failed: ref main exists"
        ),
    )


def test_assert_current_schema_id_passes_and_fails() raises:
    _requirement_holds(TableRequirement.assert_current_schema_id(0))
    assert_equal(
        _requirement_error(TableRequirement.assert_current_schema_id(7)),
        String(
            "409 CommitFailedException: Requirement failed: current-schema-id"
            " is not 7"
        ),
    )


def test_assert_last_assigned_field_id_passes_and_fails() raises:
    _requirement_holds(TableRequirement.assert_last_assigned_field_id(2))
    assert_equal(
        _requirement_error(TableRequirement.assert_last_assigned_field_id(9)),
        String(
            "409 CommitFailedException: Requirement failed: last-column-id is"
            " not 9"
        ),
    )


def test_assert_default_spec_id_passes_and_fails() raises:
    _requirement_holds(TableRequirement.assert_default_spec_id(0))
    assert_equal(
        _requirement_error(TableRequirement.assert_default_spec_id(3)),
        String(
            "409 CommitFailedException: Requirement failed: default-spec-id is"
            " not 3"
        ),
    )


def test_assert_last_assigned_partition_id_passes_and_fails() raises:
    _requirement_holds(TableRequirement.assert_last_assigned_partition_id(999))
    assert_equal(
        _requirement_error(
            TableRequirement.assert_last_assigned_partition_id(5)
        ),
        String(
            "409 CommitFailedException: Requirement failed:"
            " last-partition-id is not 5"
        ),
    )


def test_an_unknown_requirement_type_is_409() raises:
    var c = _seeded()
    var r = _raw(c, String('[{"type":"assert-frobnicated"}]'), String("[]"))
    assert_equal(
        _error_line(r),
        String(
            "409 CommitFailedException: Requirement failed: unknown"
            " requirement assert-frobnicated"
        ),
    )
    assert_equal(c.applied_commits, 0)


def test_a_failing_requirement_applies_none_of_the_updates() raises:
    var c = _seeded()
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_current_schema_id(0))
    reqs.append(TableRequirement.assert_default_spec_id(4))
    var r = _commit(
        c,
        reqs^,
        _ups(
            TableUpdate.set_properties(
                _strs(String("k")), _strs(String("v"))
            )
        ),
    )
    assert_equal(r.status, 409)
    assert_equal(c.applied_commits, 0)
    assert_false(Bool(c.metadata(String("db"), String("t")).property(String("k"))))
    assert_equal(
        _location(
            c.send(
                IcebergRestRequest(
                    String("h"), 443, String(_TABLE), List[String](), List[String]()
                )
            )
        ),
        String("s3://wh/db/t/metadata/v1.metadata.json"),
    )


def test_every_requirement_kind_holds_together() raises:
    var c = _seeded()
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_table_uuid(String(_UUID)))
    reqs.append(TableRequirement.assert_ref_snapshot_id(String("main"), None))
    reqs.append(TableRequirement.assert_current_schema_id(0))
    reqs.append(TableRequirement.assert_last_assigned_field_id(2))
    reqs.append(TableRequirement.assert_default_spec_id(0))
    reqs.append(TableRequirement.assert_last_assigned_partition_id(999))
    var r = _commit(c, reqs^, _no_ups())
    assert_equal(r.status, 200)


# =============================================================================
# a commit on a missing table.
# =============================================================================


def test_commit_on_a_missing_table_without_assert_create_is_404() raises:
    var expect = String(
        "404 NoSuchTableException: Table does not exist: db.t"
    )
    var c0 = InMemoryIcebergRestCatalog(String("p"), String("s3://wh"))
    c0.create_namespace(String("db"))
    var none = _commit(c0, _no_reqs(), _no_ups())
    assert_equal(_error_line(none), expect)
    var with_req = _commit(
        c0, _reqs(TableRequirement.assert_table_uuid(String(_UUID))), _no_ups()
    )
    assert_equal(_error_line(with_req), expect)
    assert_false(c0.has_table(String("db"), String("t")))
    assert_equal(c0.applied_commits, 0)


def test_assert_create_after_a_requirement_on_a_missing_table_is_404() raises:
    var c = InMemoryIcebergRestCatalog(String("p"), String("s3://wh"))
    c.create_namespace(String("db"))
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_table_uuid(String(_UUID)))
    reqs.append(TableRequirement.assert_create())
    var r = _commit(c, reqs^, _no_ups())
    assert_equal(
        _error_line(r),
        String("404 NoSuchTableException: Table does not exist: db.t"),
    )


def test_another_requirement_after_assert_create_on_a_missing_table_is_409() raises:
    var c = InMemoryIcebergRestCatalog(String("p"), String("s3://wh"))
    c.create_namespace(String("db"))
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_create())
    reqs.append(TableRequirement.assert_table_uuid(String(_UUID)))
    var r = _commit(c, reqs^, _no_ups())
    assert_equal(
        _error_line(r),
        String(
            "409 CommitFailedException: Requirement failed: the table does not"
            " exist"
        ),
    )
    assert_false(c.has_table(String("db"), String("t")))


def test_assert_create_on_a_missing_table_creates_it() raises:
    var c = InMemoryIcebergRestCatalog(String("p"), String("s3://wh"))
    c.create_namespace(String("db"))
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.assign_uuid(String(_UUID)))
    ups.append(TableUpdate.add_schema(_json(_SCHEMA)))
    ups.append(TableUpdate.set_current_schema(-1))
    ups.append(TableUpdate.add_spec(_json(String('{"fields":[]}'))))
    ups.append(TableUpdate.set_default_spec(-1))
    ups.append(TableUpdate.add_sort_order(_json(String('{"fields":[]}'))))
    ups.append(TableUpdate.set_default_sort_order(-1))
    ups.append(TableUpdate.set_location(String("s3://wh/db/t")))
    var r = _commit(c, _reqs(TableRequirement.assert_create()), ups^)
    assert_equal(r.status, 200)
    assert_equal(
        _location(r), String("s3://wh/db/t/metadata/v1.metadata.json")
    )
    assert_true(c.has_table(String("db"), String("t")))
    assert_equal(c.applied_commits, 1)
    var md = c.metadata(String("db"), String("t"))
    assert_equal(md.table_uuid, String(_UUID))
    assert_equal(md.current_schema_id, 0)
    assert_equal(md.last_column_id, 2)
    assert_equal(md.default_spec_id, 0)
    var next = _commit(c, _no_reqs(), _no_ups())
    assert_equal(
        _location(next), String("s3://wh/db/t/metadata/v2.metadata.json")
    )
    var again = _commit(c, _reqs(TableRequirement.assert_create()), _no_ups())
    assert_equal(
        _error_line(again),
        String(
            "409 CommitFailedException: Requirement failed: the table already"
            " exists"
        ),
    )


def test_a_failed_update_on_a_new_table_creates_nothing() raises:
    var c = InMemoryIcebergRestCatalog(String("p"), String("s3://wh"))
    c.create_namespace(String("db"))
    var r = _commit(
        c,
        _reqs(TableRequirement.assert_create()),
        _ups(TableUpdate.set_branch(String("main"), 5)),
    )
    assert_equal(r.status, 400)
    assert_false(c.has_table(String("db"), String("t")))


def main() raises:
    test_assert_create_on_an_existing_table_is_409()
    test_assert_table_uuid_passes_and_fails()
    test_assert_ref_snapshot_id_none_passes_without_the_ref()
    test_assert_ref_snapshot_id_none_fails_when_the_ref_exists()
    test_assert_ref_snapshot_id_with_an_id_passes_and_fails()
    test_assert_ref_snapshot_id_without_an_id_member_means_no_ref()
    test_assert_current_schema_id_passes_and_fails()
    test_assert_last_assigned_field_id_passes_and_fails()
    test_assert_default_spec_id_passes_and_fails()
    test_assert_last_assigned_partition_id_passes_and_fails()
    test_an_unknown_requirement_type_is_409()
    test_a_failing_requirement_applies_none_of_the_updates()
    test_every_requirement_kind_holds_together()
    test_commit_on_a_missing_table_without_assert_create_is_404()
    test_assert_create_after_a_requirement_on_a_missing_table_is_404()
    test_another_requirement_after_assert_create_on_a_missing_table_is_409()
    test_assert_create_on_a_missing_table_creates_it()
    test_a_failed_update_on_a_new_table_creates_nothing()
    print("test_iceberg_metadata_apply: ALL PASS")

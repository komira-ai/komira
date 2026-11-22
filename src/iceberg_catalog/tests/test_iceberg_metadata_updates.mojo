# =============================================================================
# test_iceberg_metadata_updates.mojo — a catalog's side of a commit, the
#   updates, and the pure functions of iceberg_metadata_apply.mojo.
# =============================================================================
#
# Each case names the behaviour it holds; each refusal is asserted by its exact
# status, type and message.
#   * updates: ids are assigned (next above the highest, -1 forms meaning the
#     one added last), counters only rise, an unsorted order is order 0,
#     properties merge, snapshots need a sequence number above the last and a
#     new id, `main` keeps `current-snapshot-id` in step, an unknown update
#     is a 400, and an update that fails leaves the table as it was.
#   * the metadata location's version advances with each applied commit and
#     only with those.
#   * the module functions, on metadata the catalog never produces (no
#     arrays, no refs, null members).
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
# updates.
# =============================================================================


def test_add_schema_assigns_the_next_id_and_raises_last_column_id() raises:
    var c = _seeded()
    var wide = _json(
        String(
            '{"type":"struct","fields":[{"id":7,"name":"x","required":false,'
            '"type":"int"}]}'
        )
    )
    var r = _commit(c, _no_reqs(), _ups(TableUpdate.add_schema(wide^)))
    assert_equal(r.status, 200)
    var md = _md(c)
    assert_equal(md.get(String("schemas")).array_len(), 2)
    assert_equal(
        _int(md.get(String("schemas")).element_at(1), String("schema-id")),
        Int64(1),
    )
    assert_equal(_int(md, String("last-column-id")), Int64(7))
    assert_equal(_int(md, String("current-schema-id")), Int64(0))
    var narrow = _json(
        String(
            '{"type":"struct","fields":[{"id":3,"name":"y","required":false,'
            '"type":"int"}]}'
        )
    )
    var r2 = _commit(c, _no_reqs(), _ups(TableUpdate.add_schema(narrow^)))
    assert_equal(r2.status, 200)
    var md2 = _md(c)
    assert_equal(
        _int(md2.get(String("schemas")).element_at(2), String("schema-id")),
        Int64(2),
    )
    assert_equal(_int(md2, String("last-column-id")), Int64(7))


def test_set_current_schema_takes_the_schema_added_last_for_minus_one() raises:
    var c = _seeded()
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.add_schema(_json(_SCHEMA)))
    ups.append(TableUpdate.add_schema(_json(_SCHEMA)))
    ups.append(TableUpdate.set_current_schema(-1))
    var r = _commit(c, _no_reqs(), ups^)
    assert_equal(r.status, 200)
    assert_equal(_int(_md(c), String("current-schema-id")), Int64(2))
    var back = _commit(c, _no_reqs(), _ups(TableUpdate.set_current_schema(1)))
    assert_equal(back.status, 200)
    assert_equal(_int(_md(c), String("current-schema-id")), Int64(1))


def test_add_spec_assigns_the_next_id_and_raises_last_partition_id() raises:
    var c = _seeded()
    var spec = _json(
        String(
            '{"fields":[{"source-id":1,"field-id":1003,"name":"p",'
            '"transform":"identity"}]}'
        )
    )
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.add_spec(spec^))
    ups.append(TableUpdate.set_default_spec(-1))
    var r = _commit(c, _no_reqs(), ups^)
    assert_equal(r.status, 200)
    var md = _md(c)
    assert_equal(md.get(String("partition-specs")).array_len(), 2)
    assert_equal(
        _int(md.get(String("partition-specs")).element_at(1), String("spec-id")),
        Int64(1),
    )
    assert_equal(_int(md, String("default-spec-id")), Int64(1))
    assert_equal(_int(md, String("last-partition-id")), Int64(1003))
    var lower = _json(
        String(
            '{"fields":[{"source-id":2,"field-id":1001,"name":"q",'
            '"transform":"identity"}]}'
        )
    )
    var r2 = _commit(c, _no_reqs(), _ups(TableUpdate.add_spec(lower^)))
    assert_equal(r2.status, 200)
    assert_equal(_int(_md(c), String("last-partition-id")), Int64(1003))
    var empty = _commit(
        c, _no_reqs(), _ups(TableUpdate.add_spec(_json(String('{"fields":[]}'))))
    )
    assert_equal(empty.status, 200)
    assert_equal(_int(_md(c), String("last-partition-id")), Int64(1003))
    var explicit = _commit(
        c, _no_reqs(), _ups(TableUpdate.set_default_spec(0))
    )
    assert_equal(explicit.status, 200)
    assert_equal(_int(_md(c), String("default-spec-id")), Int64(0))


def test_an_unsorted_order_is_order_zero_and_is_not_added_twice() raises:
    var c = _seeded()
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.add_sort_order(_json(String('{"fields":[]}'))))
    ups.append(TableUpdate.set_default_sort_order(-1))
    var r = _commit(c, _no_reqs(), ups^)
    assert_equal(r.status, 200)
    var md = _md(c)
    assert_equal(md.get(String("sort-orders")).array_len(), 1)
    assert_equal(_int(md, String("default-sort-order-id")), Int64(0))


def test_sorted_orders_get_ids_above_the_highest() raises:
    var c = _seeded()
    var order = String(
        '{"fields":[{"source-id":1,"transform":"identity","direction":"asc",'
        '"null-order":"nulls-first"}]}'
    )
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.add_sort_order(_json(order)))
    ups.append(TableUpdate.set_default_sort_order(-1))
    var r = _commit(c, _no_reqs(), ups^)
    assert_equal(r.status, 200)
    var md = _md(c)
    assert_equal(md.get(String("sort-orders")).array_len(), 2)
    assert_equal(
        _int(md.get(String("sort-orders")).element_at(1), String("order-id")),
        Int64(1),
    )
    assert_equal(_int(md, String("default-sort-order-id")), Int64(1))
    var more = _commit(
        c, _no_reqs(), _ups(TableUpdate.add_sort_order(_json(order)))
    )
    assert_equal(more.status, 200)
    var md2 = _md(c)
    assert_equal(
        _int(md2.get(String("sort-orders")).element_at(2), String("order-id")),
        Int64(2),
    )
    var back = _commit(
        c, _no_reqs(), _ups(TableUpdate.set_default_sort_order(0))
    )
    assert_equal(back.status, 200)
    assert_equal(_int(_md(c), String("default-sort-order-id")), Int64(0))


def test_set_properties_merges_replacing_and_adding() raises:
    var c = _seeded()
    var names = List[String]()
    var values = List[String]()
    names.append(String("a"))
    values.append(String("1"))
    names.append(String("b"))
    values.append(String("2"))
    var first = _commit(
        c, _no_reqs(), _ups(TableUpdate.set_properties(names^, values^))
    )
    assert_equal(first.status, 200)
    var names2 = List[String]()
    var values2 = List[String]()
    names2.append(String("b"))
    values2.append(String("two"))
    names2.append(String("c"))
    values2.append(String("3"))
    var second = _commit(
        c, _no_reqs(), _ups(TableUpdate.set_properties(names2^, values2^))
    )
    assert_equal(second.status, 200)
    assert_equal(
        _md(c).get(String("properties")).serialize(),
        String('{"a":"1","b":"two","c":"3"}'),
    )


def test_assign_uuid_format_version_and_location_updates_take_effect() raises:
    var c = _seeded()
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.assign_uuid(String("new-uuid")))
    ups.append(TableUpdate.upgrade_format_version(3))
    ups.append(TableUpdate.set_location(String("s3://moved/t")))
    var r = _commit(c, _no_reqs(), ups^)
    assert_equal(r.status, 200)
    var md = c.metadata(String("db"), String("t"))
    assert_equal(md.table_uuid, String("new-uuid"))
    assert_equal(md.format_version, 3)
    assert_equal(md.location, String("s3://moved/t"))
    assert_equal(
        _location(r), String("s3://moved/t/metadata/v2.metadata.json")
    )


def test_add_snapshot_advances_the_last_sequence_number() raises:
    var c = _seeded()
    assert_equal(
        _commit(c, _no_reqs(), _ups(_snap(11, 1))).status, 200
    )
    assert_equal(c.metadata(String("db"), String("t")).last_sequence_number, Int64(1))
    assert_equal(
        _commit(c, _no_reqs(), _ups(_snap(12, 5))).status, 200
    )
    var md = c.metadata(String("db"), String("t"))
    assert_equal(md.last_sequence_number, Int64(5))
    assert_equal(len(md.snapshots), 2)
    assert_equal(md.snapshots[1].snapshot_id, Int64(12))
    assert_equal(md.snapshots[1].sequence_number, Int64(5))


def test_add_snapshot_refuses_a_sequence_number_not_above_the_last() raises:
    var c = _seeded()
    _ = _commit(c, _no_reqs(), _ups(_snap(11, 3)))
    var equal = _commit(c, _no_reqs(), _ups(_snap(12, 3)))
    assert_equal(
        _error_line(equal),
        String(
            "400 BadRequestException: BadRequestException: sequence number 3"
            " is not above last-sequence-number 3"
        ),
    )
    var lower = _commit(c, _no_reqs(), _ups(_snap(12, 2)))
    assert_equal(
        _error_line(lower),
        String(
            "400 BadRequestException: BadRequestException: sequence number 2"
            " is not above last-sequence-number 3"
        ),
    )
    var first = _seeded()
    var zero = _commit(first, _no_reqs(), _ups(_snap(1, 0)))
    assert_equal(
        _error_line(zero),
        String(
            "400 BadRequestException: BadRequestException: sequence number 0"
            " is not above last-sequence-number 0"
        ),
    )
    assert_equal(len(c.metadata(String("db"), String("t")).snapshots), 1)


def test_add_snapshot_refuses_an_id_the_table_already_has() raises:
    var c = _seeded()
    _ = _commit(c, _no_reqs(), _ups(_snap(11, 1)))
    var r = _commit(c, _no_reqs(), _ups(_snap(11, 2)))
    assert_equal(
        _error_line(r),
        String("400 BadRequestException: BadRequestException: snapshot 11 exists"),
    )
    assert_equal(c.metadata(String("db"), String("t")).last_sequence_number, Int64(1))
    assert_equal(c.applied_commits, 1)


def test_set_snapshot_ref_to_an_unknown_snapshot_is_400() raises:
    var c = _seeded()
    var r = _commit(
        c, _no_reqs(), _ups(TableUpdate.set_branch(String("main"), 99))
    )
    assert_equal(
        _error_line(r),
        String(
            "400 BadRequestException: BadRequestException: cannot set ref main"
            " to unknown snapshot 99"
        ),
    )
    assert_equal(_int(_md(c), String("current-snapshot-id")), Int64(-1))


def test_main_keeps_current_snapshot_id_in_step() raises:
    var c = _seeded()
    _with_main(c, 11, 1)
    var md = _md(c)
    assert_equal(_int(md, String("current-snapshot-id")), Int64(11))
    assert_equal(
        md.get(String("refs")).get(String("main")).serialize(),
        String('{"snapshot-id":11,"type":"branch"}'),
    )
    _with_main(c, 12, 2)
    var md2 = _md(c)
    assert_equal(_int(md2, String("current-snapshot-id")), Int64(12))
    assert_equal(
        c.metadata(String("db"), String("t")).main_snapshot_id.value(),
        Int64(12),
    )


def test_a_branch_other_than_main_leaves_current_snapshot_id_alone() raises:
    var c = _seeded()
    _with_main(c, 11, 1)
    var ups = List[TableUpdate]()
    ups.append(_snap(12, 2))
    ups.append(TableUpdate.set_branch(String("dev"), 12))
    assert_equal(_commit(c, _no_reqs(), ups^).status, 200)
    var md = _md(c)
    assert_equal(_int(md, String("current-snapshot-id")), Int64(11))
    assert_equal(
        _int(md.get(String("refs")).get(String("dev")), String("snapshot-id")),
        Int64(12),
    )
    var gone = _commit(
        c, _no_reqs(), _ups(TableUpdate.remove_snapshot_ref(String("dev")))
    )
    assert_equal(gone.status, 200)
    var md2 = _md(c)
    assert_false(md2.get(String("refs")).has(String("dev")))
    assert_true(md2.get(String("refs")).has(String("main")))
    assert_equal(_int(md2, String("current-snapshot-id")), Int64(11))


def test_remove_snapshot_ref_main_clears_current_snapshot_id() raises:
    var c = _seeded()
    _with_main(c, 11, 1)
    var r = _commit(
        c, _no_reqs(), _ups(TableUpdate.remove_snapshot_ref(String("main")))
    )
    assert_equal(r.status, 200)
    var md = _md(c)
    assert_equal(_int(md, String("current-snapshot-id")), Int64(-1))
    assert_false(md.get(String("refs")).has(String("main")))
    assert_equal(md.get(String("snapshots")).array_len(), 1)
    assert_false(
        Bool(c.metadata(String("db"), String("t")).main_snapshot_id)
    )
    var absent = _commit(
        c, _no_reqs(), _ups(TableUpdate.remove_snapshot_ref(String("nope")))
    )
    assert_equal(absent.status, 200)


def test_an_unknown_update_is_400() raises:
    var c = _seeded()
    var r = _raw(c, String("[]"), String('[{"action":"frobnicate"}]'))
    assert_equal(
        _error_line(r),
        String(
            "400 BadRequestException: BadRequestException: unknown update"
            " frobnicate"
        ),
    )
    assert_equal(c.applied_commits, 0)


def test_a_failing_update_leaves_the_earlier_updates_unapplied() raises:
    var c = _seeded()
    var ups = List[TableUpdate]()
    ups.append(
        TableUpdate.set_properties(_strs(String("k")), _strs(String("v")))
    )
    ups.append(TableUpdate.set_branch(String("main"), 99))
    var r = _commit(c, _no_reqs(), ups^)
    assert_equal(r.status, 400)
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


def test_the_metadata_location_version_advances_with_applied_commits_only() raises:
    var c = _seeded()
    var versions = List[String]()
    for i in range(3):
        var r = _commit(c, _no_reqs(), _no_ups())
        versions.append(_location(r))
        var failed = _commit(
            c, _reqs(TableRequirement.assert_default_spec_id(9)), _no_ups()
        )
        assert_equal(failed.status, 409)
    assert_equal(versions[0], String("s3://wh/db/t/metadata/v2.metadata.json"))
    assert_equal(versions[1], String("s3://wh/db/t/metadata/v3.metadata.json"))
    assert_equal(versions[2], String("s3://wh/db/t/metadata/v4.metadata.json"))
    assert_equal(c.applied_commits, 3)


# =============================================================================
# the module functions on metadata the catalog never produces.
# =============================================================================


def test_member_helpers() raises:
    var o = _json(String('{"a":1,"b":null,"c":"x"}'))
    assert_equal(member_index(o, String("a")), 0)
    assert_equal(member_index(o, String("c")), 2)
    assert_equal(member_index(o, String("z")), -1)
    assert_equal(int_member(o, String("a"), 9), Int64(1))
    assert_equal(int_member(o, String("b"), 9), Int64(9))
    assert_equal(int_member(o, String("z"), 9), Int64(9))
    put_member(o, String("a"), JsonValue.from_i64(5))
    put_member(o, String("d"), JsonValue.from_i64(6))
    assert_equal(o.serialize(), String('{"a":5,"b":null,"c":"x","d":6}'))
    remove_member(o, String("b"))
    remove_member(o, String("z"))
    assert_equal(o.serialize(), String('{"a":5,"c":"x","d":6}'))


def test_ref_snapshot_id_without_refs_or_without_the_ref_is_none() raises:
    assert_false(Bool(ref_snapshot_id(_json(String("{}")), String("main"))))
    assert_false(
        Bool(ref_snapshot_id(_json(String('{"refs":{}}')), String("main")))
    )
    assert_equal(
        ref_snapshot_id(
            _json(String('{"refs":{"main":{"snapshot-id":4}}}')), String("main")
        ).value(),
        Int64(4),
    )
    assert_equal(
        ref_snapshot_id(
            _json(String('{"refs":{"main":{}}}')), String("main")
        ).value(),
        Int64(-1),
    )


def test_check_requirement_directly() raises:
    var md = empty_table_metadata()
    assert_equal(
        check_requirement(md, False, _json(String('{"type":"assert-create"}'))),
        String(""),
    )
    assert_equal(
        check_requirement(md, True, _json(String('{"type":"assert-create"}'))),
        String("the table already exists"),
    )
    assert_equal(
        check_requirement(md, False, _json(String('{"type":"assert-whatever"}'))),
        String("the table does not exist"),
    )
    assert_equal(
        check_requirement(md, True, _json(String('{"type":"assert-whatever"}'))),
        String("unknown requirement assert-whatever"),
    )
    assert_equal(
        check_requirement(
            md,
            True,
            _json(String('{"type":"assert-ref-snapshot-id","ref":"main","snapshot-id":null}')),
        ),
        String(""),
    )
    assert_equal(
        check_requirement(
            md,
            True,
            _json(String('{"type":"assert-current-schema-id","current-schema-id":-1}')),
        ),
        String(""),
    )
    assert_equal(
        check_requirement(
            md,
            True,
            _json(String('{"type":"assert-last-assigned-partition-id","last-assigned-partition-id":999}')),
        ),
        String(""),
    )
    assert_equal(COMMIT_FAILED, String("CommitFailedException"))
    assert_equal(BAD_REQUEST, String("BadRequestException"))


def test_apply_update_creates_missing_arrays_and_objects() raises:
    var md = _json(String("{}"))
    var st = ApplyState()
    assert_equal(st.last_schema, Int64(-1))
    assert_equal(st.last_spec, Int64(-1))
    assert_equal(st.last_order, Int64(-1))
    apply_update(
        md,
        st,
        _json(
            String(
                '{"action":"add-schema","schema":{"fields":[{"id":4,"name":"a"}]}}'
            )
        ),
    )
    apply_update(
        md,
        st,
        _json(
            String(
                '{"action":"add-spec","spec":{"fields":[{"field-id":1000}]}}'
            )
        ),
    )
    apply_update(
        md,
        st,
        _json(
            String(
                '{"action":"add-sort-order","sort-order":{"fields":[{"source-id":1}]}}'
            )
        ),
    )
    apply_update(
        md,
        st,
        _json(String('{"action":"set-properties","updates":{"k":"v"}}')),
    )
    apply_update(md, st, _json(String('{"action":"set-current-schema","schema-id":-1}')))
    apply_update(md, st, _json(String('{"action":"set-default-spec","spec-id":-1}')))
    apply_update(md, st, _json(String('{"action":"set-default-sort-order","sort-order-id":-1}')))
    assert_equal(
        md.serialize(),
        String(
            '{"schemas":[{"fields":[{"id":4,"name":"a"}],"schema-id":0}],'
            '"last-column-id":4,'
            '"partition-specs":[{"fields":[{"field-id":1000}],"spec-id":0}],'
            '"last-partition-id":1000,'
            '"sort-orders":[{"fields":[{"source-id":1}],"order-id":1}],'
            '"properties":{"k":"v"},'
            '"current-schema-id":0,"default-spec-id":0,'
            '"default-sort-order-id":1}'
        ),
    )
    assert_equal(st.last_schema, Int64(0))
    assert_equal(st.last_spec, Int64(0))
    assert_equal(st.last_order, Int64(1))


def test_apply_update_minus_one_without_an_add_in_the_commit_stays_minus_one() raises:
    var md = _json(String("{}"))
    var st = ApplyState()
    apply_update(md, st, _json(String('{"action":"set-current-schema","schema-id":-1}')))
    assert_equal(_int(md, String("current-schema-id")), Int64(-1))


def test_apply_update_creates_snapshots_and_refs_when_absent() raises:
    var md = _json(String("{}"))
    var st = ApplyState()
    apply_update(
        md,
        st,
        _json(
            String(
                '{"action":"add-snapshot","snapshot":{"snapshot-id":7,"sequence-number":1}}'
            )
        ),
    )
    apply_update(
        md,
        st,
        _json(
            String('{"action":"set-snapshot-ref","ref-name":"main","snapshot-id":7}')
        ),
    )
    assert_equal(
        md.serialize(),
        String(
            '{"snapshots":[{"snapshot-id":7,"sequence-number":1}],'
            '"last-sequence-number":1,'
            '"refs":{"main":{"snapshot-id":7,"type":"branch"}},'
            '"current-snapshot-id":7}'
        ),
    )
    var bare = _json(String("{}"))
    apply_update(
        bare,
        st,
        _json(String('{"action":"remove-snapshot-ref","ref-name":"main"}')),
    )
    assert_equal(
        bare.serialize(), String('{"refs":{},"current-snapshot-id":-1}')
    )


def test_remove_snapshot_of_an_absent_id_leaves_the_snapshots_alone() raises:
    var md = _json(String("{}"))
    remove_snapshot(md, 5)
    assert_equal(md.serialize(), String('{"snapshots":[]}'))
    var with_two = _json(
        String('{"snapshots":[{"snapshot-id":1},{"snapshot-id":2}],"refs":{"main":{"snapshot-id":1}}}')
    )
    remove_snapshot(with_two, 9)
    assert_equal(with_two.get(String("snapshots")).array_len(), 2)
    remove_snapshot(with_two, 1)
    assert_equal(
        with_two.serialize(),
        String('{"snapshots":[{"snapshot-id":2}],"refs":{"main":{"snapshot-id":1}}}'),
    )


def test_the_starting_values_of_a_new_table() raises:
    assert_equal(
        empty_table_metadata().serialize(),
        String(
            '{"format-version":2,"table-uuid":"","location":"",'
            '"last-sequence-number":0,"last-column-id":0,'
            '"current-schema-id":-1,"schemas":[],"default-spec-id":0,'
            '"partition-specs":[],"last-partition-id":999,'
            '"default-sort-order-id":0,"sort-orders":[],"properties":{},'
            '"current-snapshot-id":-1,"snapshots":[],"refs":{}}'
        ),
    )
    assert_equal(
        unpartitioned_spec().serialize(), String('{"spec-id":0,"fields":[]}')
    )
    assert_equal(
        unsorted_order().serialize(), String('{"order-id":0,"fields":[]}')
    )


def main() raises:
    test_add_schema_assigns_the_next_id_and_raises_last_column_id()
    test_set_current_schema_takes_the_schema_added_last_for_minus_one()
    test_add_spec_assigns_the_next_id_and_raises_last_partition_id()
    test_an_unsorted_order_is_order_zero_and_is_not_added_twice()
    test_sorted_orders_get_ids_above_the_highest()
    test_set_properties_merges_replacing_and_adding()
    test_assign_uuid_format_version_and_location_updates_take_effect()
    test_add_snapshot_advances_the_last_sequence_number()
    test_add_snapshot_refuses_a_sequence_number_not_above_the_last()
    test_add_snapshot_refuses_an_id_the_table_already_has()
    test_set_snapshot_ref_to_an_unknown_snapshot_is_400()
    test_main_keeps_current_snapshot_id_in_step()
    test_a_branch_other_than_main_leaves_current_snapshot_id_alone()
    test_remove_snapshot_ref_main_clears_current_snapshot_id()
    test_an_unknown_update_is_400()
    test_a_failing_update_leaves_the_earlier_updates_unapplied()
    test_the_metadata_location_version_advances_with_applied_commits_only()
    test_member_helpers()
    test_ref_snapshot_id_without_refs_or_without_the_ref_is_none()
    test_check_requirement_directly()
    test_apply_update_creates_missing_arrays_and_objects()
    test_apply_update_minus_one_without_an_add_in_the_commit_stays_minus_one()
    test_apply_update_creates_snapshots_and_refs_when_absent()
    test_remove_snapshot_of_an_absent_id_leaves_the_snapshots_alone()
    test_the_starting_values_of_a_new_table()
    print("test_iceberg_metadata_updates: ALL PASS")

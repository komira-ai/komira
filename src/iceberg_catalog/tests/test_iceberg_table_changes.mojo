# =============================================================================
# test_iceberg_table_changes.mojo — the exact JSON of every commit
#   requirement and update, and of the create and commit request bodies.
# =============================================================================
#
# Each case names the defect it would catch:
#   * A requirement or update that spells a member, an action or a type
#     differently from the REST OpenAPI, or writes members in another order
#     (the committer resends byte-identical bodies under one idempotency key).
#   * assert-ref-snapshot-id with None must send `"snapshot-id":null`, never
#     omit the member or send 0 or -1.
#   * A snapshot's parent written when it has none, or summary members
#     reordered, or `operation` not first.
#   * The create body's location written when empty, or properties dropped.
# =============================================================================

from std.testing import assert_equal

from json import JsonValue, parse_json_value

from iceberg_catalog.iceberg_table_changes import (
    CreateTableRequest,
    NewSnapshot,
    TableRequirement,
    TableUpdate,
    commit_table_body,
)


def _names(a: String, b: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    return l^


def _snapshot(parent: Optional[Int64]) -> NewSnapshot:
    return NewSnapshot(
        Int64(20),
        parent,
        Int64(2),
        Int64(1700),
        0,
        String("s3://wh/t/m20.avro"),
        String("append"),
        _names(String("added-data-files"), String("added-records")),
        _names(String("1"), String("5")),
    )


def test_requirement_json_for_every_constructor() raises:
    assert_equal(
        TableRequirement.assert_create().to_json().serialize(),
        String('{"type":"assert-create"}'),
    )
    assert_equal(
        TableRequirement.assert_table_uuid(String("u-1")).to_json().serialize(),
        String('{"type":"assert-table-uuid","uuid":"u-1"}'),
    )
    assert_equal(
        TableRequirement.assert_current_schema_id(3).to_json().serialize(),
        String('{"type":"assert-current-schema-id","current-schema-id":3}'),
    )
    assert_equal(
        TableRequirement.assert_last_assigned_field_id(9)
        .to_json()
        .serialize(),
        String(
            '{"type":"assert-last-assigned-field-id","last-assigned-field-id":9}'
        ),
    )
    assert_equal(
        TableRequirement.assert_default_spec_id(2).to_json().serialize(),
        String('{"type":"assert-default-spec-id","default-spec-id":2}'),
    )
    assert_equal(
        TableRequirement.assert_last_assigned_partition_id(1001)
        .to_json()
        .serialize(),
        String(
            '{"type":"assert-last-assigned-partition-id",'
            '"last-assigned-partition-id":1001}'
        ),
    )


def test_assert_ref_snapshot_id_with_an_id_and_with_none() raises:
    assert_equal(
        TableRequirement.assert_ref_snapshot_id(
            String("main"), Optional[Int64](Int64(10))
        )
        .to_json()
        .serialize(),
        String(
            '{"type":"assert-ref-snapshot-id","ref":"main","snapshot-id":10}'
        ),
    )
    assert_equal(
        TableRequirement.assert_ref_snapshot_id(String("main"), None)
        .to_json()
        .serialize(),
        String(
            '{"type":"assert-ref-snapshot-id","ref":"main","snapshot-id":null}'
        ),
    )


def test_requirement_kind_is_the_rest_type() raises:
    assert_equal(
        TableRequirement.assert_create().kind, String("assert-create")
    )
    assert_equal(
        TableRequirement.assert_default_spec_id(0).kind,
        String("assert-default-spec-id"),
    )


def test_update_json_for_scalar_constructors() raises:
    assert_equal(
        TableUpdate.assign_uuid(String("u-9")).to_json().serialize(),
        String('{"action":"assign-uuid","uuid":"u-9"}'),
    )
    assert_equal(
        TableUpdate.upgrade_format_version(2).to_json().serialize(),
        String('{"action":"upgrade-format-version","format-version":2}'),
    )
    assert_equal(
        TableUpdate.set_current_schema(-1).to_json().serialize(),
        String('{"action":"set-current-schema","schema-id":-1}'),
    )
    assert_equal(
        TableUpdate.set_default_spec(4).to_json().serialize(),
        String('{"action":"set-default-spec","spec-id":4}'),
    )
    assert_equal(
        TableUpdate.set_default_sort_order(-1).to_json().serialize(),
        String('{"action":"set-default-sort-order","sort-order-id":-1}'),
    )
    assert_equal(
        TableUpdate.set_location(String("s3://wh/new")).to_json().serialize(),
        String('{"action":"set-location","location":"s3://wh/new"}'),
    )
    assert_equal(
        TableUpdate.remove_snapshot_ref(String("tag1")).to_json().serialize(),
        String('{"action":"remove-snapshot-ref","ref-name":"tag1"}'),
    )
    assert_equal(
        TableUpdate.set_branch(String("main"), Int64(20)).to_json().serialize(),
        String(
            '{"action":"set-snapshot-ref","ref-name":"main","type":"branch",'
            '"snapshot-id":20}'
        ),
    )


def test_update_json_carries_schema_spec_and_sort_order_as_given() raises:
    var schema = parse_json_value(
        String('{"type":"struct","fields":[{"id":1,"name":"a","type":"long"}]}')
    )
    assert_equal(
        TableUpdate.add_schema(schema^).to_json().serialize(),
        String(
            '{"action":"add-schema","schema":{"type":"struct","fields":'
            '[{"id":1,"name":"a","type":"long"}]}}'
        ),
    )
    var spec = parse_json_value(String('{"spec-id":1,"fields":[]}'))
    assert_equal(
        TableUpdate.add_spec(spec^).to_json().serialize(),
        String('{"action":"add-spec","spec":{"spec-id":1,"fields":[]}}'),
    )
    var order = parse_json_value(String('{"order-id":1,"fields":[]}'))
    assert_equal(
        TableUpdate.add_sort_order(order^).to_json().serialize(),
        String(
            '{"action":"add-sort-order","sort-order":{"order-id":1,"fields":[]}}'
        ),
    )


def test_set_properties_json_keeps_order() raises:
    assert_equal(
        TableUpdate.set_properties(
            _names(String("b"), String("a")), _names(String("2"), String("1"))
        )
        .to_json()
        .serialize(),
        String('{"action":"set-properties","updates":{"b":"2","a":"1"}}'),
    )
    assert_equal(
        TableUpdate.set_properties(List[String](), List[String]())
        .to_json()
        .serialize(),
        String('{"action":"set-properties","updates":{}}'),
    )


def test_add_snapshot_json_with_parent_and_summary_members() raises:
    assert_equal(
        TableUpdate.add_snapshot(_snapshot(Optional[Int64](Int64(10))))
        .to_json()
        .serialize(),
        String(
            '{"action":"add-snapshot","snapshot":{"snapshot-id":20,'
            '"parent-snapshot-id":10,"sequence-number":2,'
            '"timestamp-ms":1700,"schema-id":0,'
            '"manifest-list":"s3://wh/t/m20.avro","summary":{"operation":'
            '"append","added-data-files":"1","added-records":"5"}}}'
        ),
    )


def test_add_snapshot_json_without_parent_omits_the_member() raises:
    assert_equal(
        NewSnapshot(
            Int64(1),
            None,
            Int64(1),
            Int64(5),
            3,
            String("s3://m"),
            String("append"),
            List[String](),
            List[String](),
        )
        .to_json()
        .serialize(),
        String(
            '{"snapshot-id":1,"sequence-number":1,"timestamp-ms":5,'
            '"schema-id":3,"manifest-list":"s3://m",'
            '"summary":{"operation":"append"}}'
        ),
    )


def test_update_action_is_the_rest_action() raises:
    assert_equal(
        TableUpdate.add_snapshot(_snapshot(None)).action,
        String("add-snapshot"),
    )
    assert_equal(
        TableUpdate.set_branch(String("main"), Int64(1)).action,
        String("set-snapshot-ref"),
    )


def test_commit_body_of_empty_lists() raises:
    assert_equal(
        commit_table_body(List[TableRequirement](), List[TableUpdate]()),
        String('{"requirements":[],"updates":[]}'),
    )


def test_commit_body_of_the_append_shape() raises:
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_table_uuid(String("u-1")))
    reqs.append(
        TableRequirement.assert_ref_snapshot_id(
            String("main"), Optional[Int64](Int64(10))
        )
    )
    reqs.append(TableRequirement.assert_current_schema_id(0))
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.add_snapshot(_snapshot(Optional[Int64](Int64(10)))))
    ups.append(TableUpdate.set_branch(String("main"), Int64(20)))
    assert_equal(
        commit_table_body(reqs, ups),
        String(
            '{"requirements":[{"type":"assert-table-uuid","uuid":"u-1"},'
            '{"type":"assert-ref-snapshot-id","ref":"main","snapshot-id":10},'
            '{"type":"assert-current-schema-id","current-schema-id":0}],'
            '"updates":[{"action":"add-snapshot","snapshot":{"snapshot-id":20,'
            '"parent-snapshot-id":10,"sequence-number":2,'
            '"timestamp-ms":1700,"schema-id":0,'
            '"manifest-list":"s3://wh/t/m20.avro","summary":{"operation":'
            '"append","added-data-files":"1","added-records":"5"}}},'
            '{"action":"set-snapshot-ref","ref-name":"main","type":"branch",'
            '"snapshot-id":20}]}'
        ),
    )


def test_commit_body_of_a_first_append_asserts_no_main() raises:
    var reqs = List[TableRequirement]()
    reqs.append(TableRequirement.assert_ref_snapshot_id(String("main"), None))
    var ups = List[TableUpdate]()
    ups.append(TableUpdate.set_branch(String("main"), Int64(1)))
    assert_equal(
        commit_table_body(reqs, ups),
        String(
            '{"requirements":[{"type":"assert-ref-snapshot-id","ref":"main",'
            '"snapshot-id":null}],"updates":[{"action":"set-snapshot-ref",'
            '"ref-name":"main","type":"branch","snapshot-id":1}]}'
        ),
    )


def test_create_body_without_location_or_properties() raises:
    var schema = parse_json_value(String('{"type":"struct","fields":[]}'))
    var r = CreateTableRequest(String("t"), schema^, stage_create=False)
    assert_equal(
        r.body(),
        String(
            '{"name":"t","schema":{"type":"struct","fields":[]},'
            '"stage-create":false,"properties":{}}'
        ),
    )


def test_create_body_with_location_and_properties_in_order() raises:
    var schema = parse_json_value(String('{"type":"struct","fields":[]}'))
    var r = CreateTableRequest(String("t"), schema^, stage_create=True)
    r.location = String("s3://wh/t")
    r.set_property(String("z"), String("1"))
    r.set_property(String("a"), String("2"))
    assert_equal(
        r.body(),
        String(
            '{"name":"t","location":"s3://wh/t","schema":{"type":"struct",'
            '"fields":[]},"stage-create":true,"properties":{"z":"1","a":"2"}}'
        ),
    )


def main() raises:
    test_requirement_json_for_every_constructor()
    test_assert_ref_snapshot_id_with_an_id_and_with_none()
    test_requirement_kind_is_the_rest_type()
    test_update_json_for_scalar_constructors()
    test_update_json_carries_schema_spec_and_sort_order_as_given()
    test_set_properties_json_keeps_order()
    test_add_snapshot_json_with_parent_and_summary_members()
    test_add_snapshot_json_without_parent_omits_the_member()
    test_update_action_is_the_rest_action()
    test_commit_body_of_empty_lists()
    test_commit_body_of_the_append_shape()
    test_commit_body_of_a_first_append_asserts_no_main()
    test_create_body_without_location_or_properties()
    test_create_body_with_location_and_properties_in_order()
    print("test_iceberg_table_changes: ALL PASS")

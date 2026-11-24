# =============================================================================
# test_iceberg_table_metadata.mojo — the typed table metadata the committer
#   reads from a REST response, over v2 and v1 documents, and every
#   ICEBERG_CATALOG_RESPONSE_INVALID message by exact equality.
# =============================================================================
#
# Each case names the defect it would catch:
#   * Where `main` points: `refs.main` wins over `current-snapshot-id`; a
#     `refs` without `main` is no main (never the current-snapshot-id); no
#     `refs` falls back to `current-snapshot-id`; -1 and null mean none.
#   * Schemas: v2's `schemas` list and v1's single `schema`; a missing
#     `current-schema-id` is the first schema's id; `required` defaults to
#     false; a nested type keeps its JSON text.
#   * Strings only: properties and summary members that are not strings are
#     dropped, never turned into text.
#   * Ancestry: newest first, stops at an expired parent, bounded on a parent
#     cycle; membership and summary lookups follow the same walk.
#   * Every invalid-response message, so a changed or reworded message, or a
#     member read with the wrong kind, is caught.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from json import parse_json_value

from iceberg_catalog.iceberg_rest_errors import ICEBERG_CATALOG_RESPONSE_INVALID
from iceberg_catalog.iceberg_table_metadata import (
    TableMetadata,
    parse_table_metadata,
    parse_table_metadata_text,
)


comptime _P: String = "ICEBERG_CATALOG_RESPONSE_INVALID: "

comptime _V2: String = (
    '{"format-version":2,"table-uuid":"u-1","location":"s3://wh/t",'
    '"last-sequence-number":3,"last-column-id":3,"current-schema-id":1,'
    '"default-spec-id":4,"last-partition-id":1005,'
    '"schemas":[{"schema-id":0,"fields":[{"id":1,"name":"a",'
    '"required":true,"type":"long"}]},'
    '{"schema-id":1,"fields":[{"id":1,"name":"a","required":true,'
    '"type":"long"},{"id":2,"name":"b","type":"decimal(9,2)"},'
    '{"id":3,"name":"c","required":false,'
    '"type":{"type":"list","element-id":4,"element":"int",'
    '"element-required":true}}]}],'
    '"properties":{"k":"v","n":5,"w":"x"},'
    '"snapshots":['
    '{"snapshot-id":10,"sequence-number":1,"timestamp-ms":1000,'
    '"manifest-list":"s3://wh/t/m10.avro",'
    '"summary":{"operation":"append","job":"a","n":7}},'
    '{"snapshot-id":20,"parent-snapshot-id":10,"sequence-number":2,'
    '"timestamp-ms":2000,"manifest-list":"s3://wh/t/m20.avro",'
    '"summary":{"operation":"append","job":"a"}},'
    '{"snapshot-id":30,"parent-snapshot-id":20,"sequence-number":3,'
    '"timestamp-ms":3000,"manifest-list":"s3://wh/t/m30.avro",'
    '"summary":{"operation":"overwrite","job":"b"}},'
    '{"snapshot-id":40,"parent-snapshot-id":null,"timestamp-ms":4000,'
    '"manifest-list":"s3://wh/t/m40.avro"}],'
    '"current-snapshot-id":40,'
    '"refs":{"main":{"snapshot-id":30,"type":"branch"}}}'
)


def _err(text: String) -> String:
    """The message parse_table_metadata_text raised, or "" when it parsed."""
    try:
        var _m = parse_table_metadata_text(text)
    except e:
        return String(e)
    return String("")


def _doc(extra: String) -> String:
    """A minimal valid document with `extra` members appended."""
    return String('{"format-version":2') + extra + String("}")


def test_v2_document_scalars_and_counters() raises:
    var m = parse_table_metadata_text(String(_V2))
    assert_equal(m.format_version, 2)
    assert_equal(m.table_uuid, String("u-1"))
    assert_equal(m.location, String("s3://wh/t"))
    assert_equal(m.last_sequence_number, Int64(3))
    assert_equal(m.last_column_id, 3)
    assert_equal(m.current_schema_id, 1)
    assert_equal(m.default_spec_id, 4)
    assert_equal(m.last_partition_id, 1005)


def test_parse_table_metadata_takes_a_json_value() raises:
    var m = parse_table_metadata(parse_json_value(String(_V2)))
    assert_equal(m.table_uuid, String("u-1"))
    assert_equal(len(m.snapshots), 4)


def test_v2_schemas_fields_and_types() raises:
    var m = parse_table_metadata_text(String(_V2))
    assert_equal(len(m.schemas), 2)
    assert_equal(m.schemas[0].schema_id, 0)
    assert_equal(len(m.schemas[0].fields), 1)
    assert_equal(m.schemas[1].schema_id, 1)
    assert_equal(len(m.schemas[1].fields), 3)
    ref f = m.schemas[1].fields
    assert_equal(f[0].name, String("a"))
    assert_true(f[0].required)
    assert_equal(f[0].type_name, String("long"))
    assert_equal(f[1].name, String("b"))
    assert_false(f[1].required)
    assert_equal(f[1].type_name, String("decimal(9,2)"))
    assert_false(f[2].required)
    assert_equal(
        f[2].type_name,
        String(
            '{"type":"list","element-id":4,"element":"int",'
            '"element-required":true}'
        ),
    )


def test_field_by_id_and_schema_index() raises:
    var m = parse_table_metadata_text(String(_V2))
    assert_equal(m.schemas[1].field_by_id(2), 1)
    assert_equal(m.schemas[1].field_by_id(3), 2)
    assert_equal(m.schemas[1].field_by_id(99), -1)
    assert_equal(m.schema_index(0), 0)
    assert_equal(m.schema_index(1), 1)
    assert_equal(m.schema_index(7), -1)


def test_properties_keep_only_string_members() raises:
    var m = parse_table_metadata_text(String(_V2))
    assert_equal(len(m.property_names), 2)
    var k = m.property(String("k"))
    assert_true(Bool(k))
    assert_equal(k.value(), String("v"))
    var w = m.property(String("w"))
    assert_true(Bool(w))
    assert_equal(w.value(), String("x"))
    assert_false(Bool(m.property(String("n"))))
    assert_false(Bool(m.property(String("absent"))))


def test_snapshots_fields_parent_and_sequence_defaults() raises:
    var m = parse_table_metadata_text(String(_V2))
    assert_equal(len(m.snapshots), 4)
    assert_equal(m.snapshots[0].snapshot_id, Int64(10))
    assert_false(Bool(m.snapshots[0].parent_id))
    assert_equal(m.snapshots[0].sequence_number, Int64(1))
    assert_equal(m.snapshots[0].timestamp_ms, Int64(1000))
    assert_equal(m.snapshots[0].manifest_list, String("s3://wh/t/m10.avro"))
    assert_true(Bool(m.snapshots[1].parent_id))
    assert_equal(m.snapshots[1].parent_id.value(), Int64(10))
    # A null parent is no parent; an absent sequence number is 0; an absent
    # summary has no members.
    assert_false(Bool(m.snapshots[3].parent_id))
    assert_equal(m.snapshots[3].sequence_number, Int64(0))
    assert_equal(len(m.snapshots[3].summary_names), 0)
    assert_equal(m.snapshot_index(30), 2)
    assert_equal(m.snapshot_index(31), -1)


def test_snapshot_summary_keeps_only_string_members_in_order() raises:
    var m = parse_table_metadata_text(String(_V2))
    ref s = m.snapshots[0]
    assert_equal(len(s.summary_names), 2)
    assert_equal(s.summary_names[0], String("operation"))
    assert_equal(s.summary_values[0], String("append"))
    assert_equal(s.summary_names[1], String("job"))
    assert_equal(s.summary_values[1], String("a"))
    var op = s.summary(String("operation"))
    assert_true(Bool(op))
    assert_equal(op.value(), String("append"))
    assert_false(Bool(s.summary(String("n"))))


def test_main_is_refs_main_over_current_snapshot_id() raises:
    var m = parse_table_metadata_text(String(_V2))
    assert_true(Bool(m.main_snapshot_id))
    assert_equal(m.main_snapshot_id.value(), Int64(30))


def test_refs_without_main_is_no_main() raises:
    var m = parse_table_metadata_text(
        _doc(String(',"current-snapshot-id":5,"refs":{"tag1":{"snapshot-id":5}}'))
    )
    assert_false(Bool(m.main_snapshot_id))


def test_no_refs_falls_back_to_current_snapshot_id() raises:
    var m = parse_table_metadata_text(_doc(String(',"current-snapshot-id":5')))
    assert_equal(m.main_snapshot_id.value(), Int64(5))


def test_minus_one_null_and_absent_current_snapshot_id_are_none() raises:
    var a = parse_table_metadata_text(_doc(String(',"current-snapshot-id":-1')))
    assert_false(Bool(a.main_snapshot_id))
    var b = parse_table_metadata_text(_doc(String(',"current-snapshot-id":null')))
    assert_false(Bool(b.main_snapshot_id))
    var c = parse_table_metadata_text(_doc(String("")))
    assert_false(Bool(c.main_snapshot_id))


def test_v1_single_schema_and_defaults() raises:
    var m = parse_table_metadata_text(
        String(
            '{"format-version":1,"schema":{"schema-id":7,"fields":'
            '[{"id":1,"name":"x","type":"int"}]},'
            '"snapshots":[{"snapshot-id":9,"timestamp-ms":5,'
            '"manifest-list":"s3://m"}],"current-snapshot-id":9}'
        )
    )
    assert_equal(m.format_version, 1)
    assert_equal(len(m.schemas), 1)
    assert_equal(m.schemas[0].schema_id, 7)
    # No current-schema-id: the first schema's id.
    assert_equal(m.current_schema_id, 7)
    assert_equal(m.table_uuid, String(""))
    assert_equal(m.location, String(""))
    assert_equal(m.last_sequence_number, Int64(0))
    assert_equal(m.snapshots[0].sequence_number, Int64(0))
    assert_equal(m.main_snapshot_id.value(), Int64(9))


def test_no_schema_and_no_current_schema_id_is_zero() raises:
    var m = parse_table_metadata_text(_doc(String("")))
    assert_equal(len(m.schemas), 0)
    assert_equal(m.current_schema_id, 0)


def test_schema_without_fields_or_id_is_empty_schema_zero() raises:
    var m = parse_table_metadata_text(_doc(String(',"schemas":[{}]')))
    assert_equal(m.schemas[0].schema_id, 0)
    assert_equal(len(m.schemas[0].fields), 0)


def test_main_ancestry_newest_first() raises:
    var m = parse_table_metadata_text(String(_V2))
    var anc = m.main_ancestry()
    assert_equal(len(anc), 3)
    assert_equal(anc[0], Int64(30))
    assert_equal(anc[1], Int64(20))
    assert_equal(anc[2], Int64(10))


def test_main_ancestry_is_empty_without_main() raises:
    var m = TableMetadata()
    assert_equal(len(m.main_ancestry()), 0)
    assert_false(m.in_main_ancestry(1))
    assert_false(Bool(m.find_in_main_ancestry(String("a"), String("b"))))


def test_main_ancestry_stops_at_an_expired_parent() raises:
    var m = parse_table_metadata_text(
        _doc(
            String(
                ',"snapshots":[{"snapshot-id":50,"parent-snapshot-id":49}],'
                '"refs":{"main":{"snapshot-id":50}}'
            )
        )
    )
    var anc = m.main_ancestry()
    assert_equal(len(anc), 2)
    assert_equal(anc[0], Int64(50))
    assert_equal(anc[1], Int64(49))


def test_main_ancestry_is_bounded_on_a_parent_cycle() raises:
    var m = parse_table_metadata_text(
        _doc(
            String(
                ',"snapshots":[{"snapshot-id":1,"parent-snapshot-id":2},'
                '{"snapshot-id":2,"parent-snapshot-id":1}],'
                '"refs":{"main":{"snapshot-id":1}}'
            )
        )
    )
    var anc = m.main_ancestry()
    assert_equal(len(anc), 3)
    assert_equal(anc[0], Int64(1))
    assert_equal(anc[1], Int64(2))
    assert_equal(anc[2], Int64(1))


def test_main_ancestry_of_a_main_not_listed_is_just_main() raises:
    var m = parse_table_metadata_text(
        _doc(String(',"refs":{"main":{"snapshot-id":77}}'))
    )
    var anc = m.main_ancestry()
    assert_equal(len(anc), 1)
    assert_equal(anc[0], Int64(77))


def test_in_main_ancestry_membership() raises:
    var m = parse_table_metadata_text(String(_V2))
    assert_true(m.in_main_ancestry(30))
    assert_true(m.in_main_ancestry(20))
    assert_true(m.in_main_ancestry(10))
    # Listed but on no path from main.
    assert_false(m.in_main_ancestry(40))
    # Not listed at all.
    assert_false(m.in_main_ancestry(49))


def test_in_main_ancestry_is_false_for_an_expired_id() raises:
    var m = parse_table_metadata_text(
        _doc(
            String(
                ',"snapshots":[{"snapshot-id":50,"parent-snapshot-id":49}],'
                '"refs":{"main":{"snapshot-id":50}}'
            )
        )
    )
    assert_true(m.in_main_ancestry(50))
    assert_false(m.in_main_ancestry(49))


def test_find_in_main_ancestry_returns_the_newest_match() raises:
    var m = parse_table_metadata_text(String(_V2))
    var a = m.find_in_main_ancestry(String("job"), String("a"))
    assert_true(Bool(a))
    assert_equal(a.value(), Int64(20))
    var b = m.find_in_main_ancestry(String("job"), String("b"))
    assert_equal(b.value(), Int64(30))
    assert_false(Bool(m.find_in_main_ancestry(String("job"), String("zz"))))
    assert_false(Bool(m.find_in_main_ancestry(String("nope"), String("a"))))


def test_find_in_main_ancestry_skips_an_expired_parent() raises:
    var m = parse_table_metadata_text(
        _doc(
            String(
                ',"snapshots":[{"snapshot-id":50,"parent-snapshot-id":49,'
                '"summary":{"job":"a"}}],'
                '"refs":{"main":{"snapshot-id":50}}'
            )
        )
    )
    assert_equal(
        m.find_in_main_ancestry(String("job"), String("a")).value(), Int64(50)
    )
    assert_false(Bool(m.find_in_main_ancestry(String("job"), String("b"))))


def test_empty_metadata_defaults() raises:
    var m = TableMetadata()
    assert_equal(m.format_version, 2)
    assert_equal(m.table_uuid, String(""))
    assert_equal(len(m.snapshots), 0)
    assert_false(Bool(m.main_snapshot_id))
    assert_equal(m.snapshot_index(1), -1)
    assert_equal(m.schema_index(0), -1)
    assert_false(Bool(m.property(String("k"))))


def test_invalid_top_level_messages() raises:
    assert_equal(
        _err(String("not json")), _P + String("table metadata is not JSON")
    )
    assert_equal(
        _err(String("[1]")),
        _P + String("table metadata is not a JSON object"),
    )
    var raised = False
    try:
        var _m = parse_table_metadata(parse_json_value(String('"s"')))
    except e:
        raised = True
        assert_equal(
            String(e), _P + String("table metadata is not a JSON object")
        )
    assert_true(raised)
    assert_equal(
        String(ICEBERG_CATALOG_RESPONSE_INVALID),
        String("ICEBERG_CATALOG_RESPONSE_INVALID"),
    )


def test_invalid_scalar_members() raises:
    assert_equal(_err(String("{}")), _P + String("'format-version' is missing"))
    assert_equal(
        _err(String('{"format-version":"2"}')),
        _P + String("'format-version' has the wrong JSON type"),
    )
    assert_equal(
        _err(String('{"format-version":2.5}')),
        _P + String("'format-version' is not a 64-bit integer"),
    )
    assert_equal(
        _err(String('{"format-version":99999999999999999999}')),
        _P + String("'format-version' is not a 64-bit integer"),
    )
    assert_equal(
        _err(_doc(String(',"table-uuid":5'))),
        _P + String("'table-uuid' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"location":null'))),
        _P + String("'location' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"last-sequence-number":"3"'))),
        _P + String("'last-sequence-number' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"last-column-id":true'))),
        _P + String("'last-column-id' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"default-spec-id":[]'))),
        _P + String("'default-spec-id' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"last-partition-id":{}'))),
        _P + String("'last-partition-id' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"current-schema-id":"0"'))),
        _P + String("'current-schema-id' has the wrong JSON type"),
    )


def test_invalid_schema_members() raises:
    assert_equal(
        _err(_doc(String(',"schemas":{}'))),
        _P + String("'schemas' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"schemas":[1]'))),
        _P + String("a schema is not a JSON object"),
    )
    assert_equal(
        _err(_doc(String(',"schema":[]'))),
        _P + String("'schema' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"schemas":[{"schema-id":"x"}]'))),
        _P + String("'schema-id' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"schemas":[{"fields":{}}]'))),
        _P + String("'fields' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"schemas":[{"fields":[3]}]'))),
        _P + String("a schema field is not a JSON object"),
    )
    assert_equal(
        _err(_doc(String(',"schemas":[{"fields":[{"id":1,"name":"a"}]}]'))),
        _P + String("a schema field has no type"),
    )
    assert_equal(
        _err(
            _doc(String(',"schemas":[{"fields":[{"id":1,"name":"a","type":3}]}]'))
        ),
        _P + String("a schema field has no type"),
    )
    assert_equal(
        _err(_doc(String(',"schemas":[{"fields":[{"name":"a","type":"int"}]}]'))),
        _P + String("'id' is missing"),
    )
    assert_equal(
        _err(
            _doc(
                String(',"schemas":[{"fields":[{"id":1,"name":2,"type":"int"}]}]')
            )
        ),
        _P + String("'name' has the wrong JSON type"),
    )


def test_invalid_properties_and_snapshot_members() raises:
    assert_equal(
        _err(_doc(String(',"properties":[]'))),
        _P + String("'properties' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"snapshots":{}'))),
        _P + String("'snapshots' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"snapshots":["s"]'))),
        _P + String("a snapshot is not a JSON object"),
    )
    assert_equal(
        _err(_doc(String(',"snapshots":[{}]'))),
        _P + String("'snapshot-id' is missing"),
    )
    assert_equal(
        _err(_doc(String(',"snapshots":[{"snapshot-id":"1"}]'))),
        _P + String("'snapshot-id' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"snapshots":[{"snapshot-id":1.5}]'))),
        _P + String("'snapshot-id' is not a 64-bit integer"),
    )
    assert_equal(
        _err(_doc(String(',"snapshots":[{"snapshot-id":1,"parent-snapshot-id":"p"}]'))),
        _P + String("'parent-snapshot-id' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"snapshots":[{"snapshot-id":1,"summary":[]}]'))),
        _P + String("'summary' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"snapshots":[{"snapshot-id":1,"timestamp-ms":"t"}]'))),
        _P + String("'timestamp-ms' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"snapshots":[{"snapshot-id":1,"manifest-list":4}]'))),
        _P + String("'manifest-list' has the wrong JSON type"),
    )


def test_invalid_refs_and_current_snapshot_members() raises:
    assert_equal(
        _err(_doc(String(',"refs":[]'))),
        _P + String("'refs' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"refs":{"main":3}'))),
        _P + String("'main' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"refs":{"main":{}}'))),
        _P + String("'snapshot-id' is missing"),
    )
    assert_equal(
        _err(_doc(String(',"current-snapshot-id":"7"'))),
        _P + String("'current-snapshot-id' has the wrong JSON type"),
    )
    assert_equal(
        _err(_doc(String(',"current-snapshot-id":1.5'))),
        _P + String("'current-snapshot-id' is not a 64-bit integer"),
    )


def main() raises:
    test_v2_document_scalars_and_counters()
    test_parse_table_metadata_takes_a_json_value()
    test_v2_schemas_fields_and_types()
    test_field_by_id_and_schema_index()
    test_properties_keep_only_string_members()
    test_snapshots_fields_parent_and_sequence_defaults()
    test_snapshot_summary_keeps_only_string_members_in_order()
    test_main_is_refs_main_over_current_snapshot_id()
    test_refs_without_main_is_no_main()
    test_no_refs_falls_back_to_current_snapshot_id()
    test_minus_one_null_and_absent_current_snapshot_id_are_none()
    test_v1_single_schema_and_defaults()
    test_no_schema_and_no_current_schema_id_is_zero()
    test_schema_without_fields_or_id_is_empty_schema_zero()
    test_main_ancestry_newest_first()
    test_main_ancestry_is_empty_without_main()
    test_main_ancestry_stops_at_an_expired_parent()
    test_main_ancestry_is_bounded_on_a_parent_cycle()
    test_main_ancestry_of_a_main_not_listed_is_just_main()
    test_in_main_ancestry_membership()
    test_in_main_ancestry_is_false_for_an_expired_id()
    test_find_in_main_ancestry_returns_the_newest_match()
    test_find_in_main_ancestry_skips_an_expired_parent()
    test_empty_metadata_defaults()
    test_invalid_top_level_messages()
    test_invalid_scalar_members()
    test_invalid_schema_members()
    test_invalid_properties_and_snapshot_members()
    test_invalid_refs_and_current_snapshot_members()
    print("test_iceberg_table_metadata: ALL PASS")

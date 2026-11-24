# =============================================================================
# parse_iceberg_metadata: the metadata.json of any writer
# =============================================================================
#
# What each test proves:
#   * test_a_pretty_printed_v2_table_parses: Iceberg Java's layout (spaces after
#     colons, nested objects, `refs.main`) parses to the format version, the
#     location, the schema with spaces removed from `decimal(9, 2)`, the
#     partition spec, the snapshots with their sequence numbers, schema ids
#     and manifest lists, the current snapshot and the name mapping property.
#   * test_a_v1_table_parses: `schema` and `partition-spec` read as schema 0 and
#     spec 0, sequence numbers are 0, a snapshot lists its manifests inline,
#     and a table with no spec at all has one empty spec.
#   * test_the_current_snapshot_follows_refs_then_current_snapshot_id:
#     `refs.main` beats `current-snapshot-id`, a `refs` without `main` falls
#     back to it, and -1, null and absence are no snapshot.
#   * test_format_version_three_and_above_is_refused_by_name: 3 and 4 are
#     OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED naming the version; 0 and a missing
#     version are ICEBERG_METADATA_INVALID.
#   * test_lookups_name_what_is_missing: schema, spec and snapshot lookups of an
#     id the table lacks are refused with the id.
#   * test_a_nested_type_keeps_its_json_text: a struct-typed column's
#     `type_name` is its JSON, which a later use refuses.
#   * test_malformed_documents_are_refused_by_message: text that is not JSON,
#     a document that is not an object, a member of the wrong JSON type or
#     not an integer, and a field or snapshot or spec that is no object are each
#     ICEBERG_METADATA_INVALID with the reason.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from iceberg_scan.table_fixture import (
    fixture_metadata_json,
    fixture_snapshot_json,
)
from iceberg_scan.table_metadata import parse_iceberg_metadata


comptime _FIELDS = String(
    '{"id": 1, "name": "id", "required": true, "type": "long"}, '
    '{"id": 2, "name": "price", "required": false, "type": "decimal(9, 2)"}, '
    '{"id": 3, "name": "tags", "required": false, "type": '
    '{"type": "list", "element-id": 4, "element": "string", "element-required": true}}'
)
comptime _SPEC = String(
    '{"name": "id_bucket", "transform": "bucket[16]", "source-id": 1, "field-id": 1000}, '
    '{"name": "price", "transform": "identity", "source-id": 2, "field-id": 1001}'
)


def _error_of(text: String) -> String:
    try:
        _ = parse_iceberg_metadata(text)
    except e:
        return String(e)
    return String("(accepted)")


def _doc(body: String) -> String:
    return String('{"format-version": 2, ') + body + String("}")


def test_a_pretty_printed_v2_table_parses() raises:
    var snaps = List[String]()
    snaps.append(fixture_snapshot_json(11, 1, "file:///w/t/metadata/snap-11.avro", 0))
    snaps.append(fixture_snapshot_json(12, 2, "file:///w/t/metadata/snap-12.avro", 0))
    var text = fixture_metadata_json("file:///w/t", _FIELDS, _SPEC, snaps, 12)
    var md = parse_iceberg_metadata(text)
    assert_equal(md.format_version, 2)
    assert_equal(md.location, "file:///w/t")
    assert_equal(md.current_schema_id, 0)
    assert_equal(md.default_spec_id, 0)
    var schema = md.schema_by_id(0)
    assert_equal(len(schema.fields), 3)
    assert_equal(schema.fields[0].id, 1)
    assert_equal(schema.fields[0].name, "id")
    assert_true(schema.fields[0].required)
    assert_equal(schema.fields[0].type_name, "long")
    assert_false(schema.fields[1].required)
    assert_equal(schema.fields[1].type_name, "decimal(9,2)")
    var spec = md.spec_by_id(0)
    assert_equal(len(spec.fields), 2)
    assert_equal(spec.fields[0].source_id, 1)
    assert_equal(spec.fields[0].field_id, 1000)
    assert_equal(spec.fields[0].name, "id_bucket")
    assert_equal(spec.fields[0].transform, "bucket[16]")
    assert_equal(spec.fields[1].transform, "identity")
    assert_equal(len(md.snapshots), 2)
    var s = md.snapshot_by_id(12)
    assert_equal(s.sequence_number, 2)
    assert_equal(s.schema_id.value(), 0)
    assert_equal(s.manifest_list, "file:///w/t/metadata/snap-12.avro")
    assert_equal(len(s.manifests), 0)
    assert_equal(md.current_snapshot_id.value(), 12)
    assert_equal(md.name_mapping, "")

    var mapped = _doc(
        '"location": "/t", "properties": {"schema.name-mapping.default": "[]",'
        ' "write.parquet.row-group-size-bytes": 8, "other": "x"}'
    )
    assert_equal(parse_iceberg_metadata(mapped).name_mapping, "[]")
    var numeric = _doc('"properties": {"schema.name-mapping.default": 5}')
    assert_equal(parse_iceberg_metadata(numeric).name_mapping, "")


def test_a_v1_table_parses() raises:
    var text = String(
        '{"format-version": 1, "location": "/warehouse/t", '
        '"schema": {"type": "struct", "fields": ['
        '{"id": 1, "name": "a", "required": true, "type": "int"}]}, '
        '"partition-spec": [{"name": "a", "transform": "identity", "source-id": 1}], '
        '"snapshots": [{"snapshot-id": 5, "timestamp-ms": 1788300000000, '
        '"manifests": ["/warehouse/t/metadata/m1.avro", "/warehouse/t/metadata/m2.avro"]}], '
        '"current-snapshot-id": 5}'
    )
    var md = parse_iceberg_metadata(text)
    assert_equal(md.format_version, 1)
    assert_equal(md.current_schema_id, 0)
    assert_equal(md.schema_by_id(0).fields[0].type_name, "int")
    var spec = md.spec_by_id(0)
    assert_equal(len(spec.fields), 1)
    assert_equal(spec.fields[0].field_id, 1000)
    var s = md.snapshot_by_id(5)
    assert_equal(s.sequence_number, 0)
    assert_false(Bool(s.schema_id))
    assert_equal(s.manifest_list, "")
    assert_equal(len(s.manifests), 2)
    assert_equal(s.manifests[1], "/warehouse/t/metadata/m2.avro")
    assert_equal(md.current_snapshot_id.value(), 5)

    var bare = parse_iceberg_metadata(
        '{"format-version": 1, "default-spec-id": 3, "schema": {"fields": []}}'
    )
    assert_equal(len(bare.specs), 1)
    assert_equal(bare.spec_by_id(3).spec_id, 3)
    assert_equal(len(bare.spec_by_id(3).fields), 0)
    assert_false(Bool(bare.current_snapshot_id))

    # A spec with no `fields` is empty; a `required` that is no boolean is false.
    var sparse = parse_iceberg_metadata(
        _doc(
            '"partition-specs": [{"spec-id": 5}],'
            ' "schemas": [{"fields": [{"id": 1, "name": "a", "type": "int", "required": "yes"}]}]'
        )
    )
    assert_equal(len(sparse.spec_by_id(5).fields), 0)
    assert_false(sparse.schema_by_id(0).fields[0].required)


def test_the_current_snapshot_follows_refs_then_current_snapshot_id() raises:
    var both = _doc(
        '"current-snapshot-id": 1, "refs": {"main": {"snapshot-id": 2, "type": "branch"}}'
    )
    assert_equal(parse_iceberg_metadata(both).current_snapshot_id.value(), 2)
    var tags_only = _doc(
        '"current-snapshot-id": 1, "refs": {"v1": {"snapshot-id": 2, "type": "tag"}}'
    )
    assert_equal(parse_iceberg_metadata(tags_only).current_snapshot_id.value(), 1)
    assert_false(Bool(parse_iceberg_metadata(_doc('"current-snapshot-id": -1')).current_snapshot_id))
    assert_false(Bool(parse_iceberg_metadata(_doc('"current-snapshot-id": null')).current_snapshot_id))
    assert_false(Bool(parse_iceberg_metadata(_doc('"location": "/t"')).current_snapshot_id))


def test_format_version_three_and_above_is_refused_by_name() raises:
    assert_equal(
        _error_of('{"format-version": 3}'),
        "OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: format-version 3",
    )
    assert_equal(
        _error_of('{"format-version": 4, "location": "/t"}'),
        "OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: format-version 4",
    )
    assert_equal(
        _error_of('{"format-version": 0}'),
        "ICEBERG_METADATA_INVALID: format-version 0",
    )
    assert_equal(
        _error_of('{"location": "/t"}'),
        "ICEBERG_METADATA_INVALID: 'format-version' is missing",
    )


def test_lookups_name_what_is_missing() raises:
    var md = parse_iceberg_metadata(_doc('"location": "/t"'))
    try:
        _ = md.schema_by_id(9)
        assert_true(False, "a missing schema was found")
    except e:
        assert_equal(String(e), "ICEBERG_METADATA_INVALID: the table has no schema 9")
    try:
        _ = md.spec_by_id(9)
        assert_true(False, "a missing spec was found")
    except e:
        assert_equal(
            String(e), "ICEBERG_METADATA_INVALID: the table has no partition spec 9"
        )
    try:
        _ = md.snapshot_by_id(99)
        assert_true(False, "a missing snapshot was found")
    except e:
        assert_equal(
            String(e), "ICEBERG_SNAPSHOT_NOT_FOUND: the table has no snapshot 99"
        )


def test_a_nested_type_keeps_its_json_text() raises:
    var snaps = List[String]()
    var md = parse_iceberg_metadata(
        fixture_metadata_json("/t", _FIELDS, _SPEC, snaps, -1)
    )
    var tags = md.schema_by_id(0).fields[2].type_name
    assert_true(tags.startswith("{"))
    assert_true(tags.find("\"list\"") >= 0)
    assert_true(tags.find("\"element\"") >= 0)
    assert_false(Bool(md.current_snapshot_id))


def test_malformed_documents_are_refused_by_message() raises:
    assert_true(_error_of("{not json").startswith("ICEBERG_METADATA_INVALID: not JSON: "))
    assert_equal(
        _error_of("[1]"), "ICEBERG_METADATA_INVALID: the document is not a JSON object"
    )
    assert_equal(
        _error_of(_doc('"location": 5')),
        "ICEBERG_METADATA_INVALID: 'location' has the wrong JSON type",
    )
    assert_equal(
        _error_of(_doc('"schemas": 3')),
        "ICEBERG_METADATA_INVALID: 'schemas' has the wrong JSON type",
    )
    assert_equal(
        _error_of(_doc('"schemas": [3]')),
        "ICEBERG_METADATA_INVALID: a schema is not a JSON object",
    )
    assert_equal(
        _error_of(_doc('"schemas": [{"fields": [7]}]')),
        "ICEBERG_METADATA_INVALID: a schema field is not a JSON object",
    )
    assert_equal(
        _error_of(_doc('"schemas": [{"fields": [{"id": 1, "name": "a"}]}]')),
        "ICEBERG_METADATA_INVALID: a schema field has no type",
    )
    assert_equal(
        _error_of(_doc('"schemas": [{"fields": [{"name": "a", "type": "int"}]}]')),
        "ICEBERG_METADATA_INVALID: 'id' is missing",
    )
    assert_equal(
        _error_of(_doc('"partition-specs": [4]')),
        "ICEBERG_METADATA_INVALID: a partition spec is not a JSON object",
    )
    assert_equal(
        _error_of(_doc('"partition-specs": [{"spec-id": 0, "fields": [4]}]')),
        "ICEBERG_METADATA_INVALID: a partition field is not a JSON object",
    )
    assert_equal(
        _error_of(_doc('"snapshots": [4]')),
        "ICEBERG_METADATA_INVALID: a snapshot is not a JSON object",
    )
    assert_equal(
        _error_of(_doc('"snapshots": [{"snapshot-id": 1.5}]')),
        "ICEBERG_METADATA_INVALID: 'snapshot-id' is not a 64-bit integer",
    )
    assert_equal(
        _error_of(_doc('"snapshots": [{"snapshot-id": 1, "manifests": [3]}]')),
        "ICEBERG_METADATA_INVALID: a manifest path is not a string",
    )
    assert_equal(
        _error_of(_doc('"refs": {"main": {"type": "branch"}}')),
        "ICEBERG_METADATA_INVALID: 'snapshot-id' is missing",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_pretty_printed_v2_table_parses]()
    suite.test[test_a_v1_table_parses]()
    suite.test[test_the_current_snapshot_follows_refs_then_current_snapshot_id]()
    suite.test[test_format_version_three_and_above_is_refused_by_name]()
    suite.test[test_lookups_name_what_is_missing]()
    suite.test[test_a_nested_type_keeps_its_json_text]()
    suite.test[test_malformed_documents_are_refused_by_message]()
    suite^.run()

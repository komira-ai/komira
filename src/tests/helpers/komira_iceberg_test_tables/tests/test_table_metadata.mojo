# The table's JSON: schema, partition spec, name mapping and metadata.json.
#
#   * test_json_strings_escape_quotes_and_backslashes.
#   * test_compact_fragments_are_exact: the one-line schema, the partition spec
#     fields (empty, then identity fields numbered from 1000) and the name
#     mapping, by equality.
#   * test_the_metadata_of_a_table_with_no_snapshot: refs empty, current
#     snapshot -1, last sequence number 0, last-partition-id 999, no metadata
#     log for version 1.
#   * test_the_metadata_of_a_partitioned_table_lists_every_snapshot: the
#     partition spec, refs.main on the last snapshot, a snapshot with and one
#     without a parent, summary, manifest list, the snapshot log and a metadata
#     log naming the earlier versions.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_iceberg_test_tables.table_metadata import (
    compact_schema_json,
    json_string,
    name_mapping_json,
    partition_fields_json,
    schema_json,
    table_metadata_json,
    timestamp_ms,
)
from komira_iceberg_test_tables.table_model import (
    TT_LONG,
    TT_STRING,
    SnapshotRecord,
    TableColumn,
)


def _columns() -> List[TableColumn]:
    var out = List[TableColumn]()
    out.append(TableColumn(1, "id", TT_LONG, True))
    out.append(TableColumn(3, "re\"gion", TT_STRING, False))
    return out^


def _has(text: String, part: String) -> Bool:
    return text.find(part) >= 0


def test_json_strings_escape_quotes_and_backslashes() raises:
    assert_equal(json_string("plain"), "\"plain\"")
    assert_equal(json_string("a\"b\\c"), "\"a\\\"b\\\\c\"")


def test_compact_fragments_are_exact() raises:
    assert_equal(
        compact_schema_json(_columns(), 0),
        '{"type":"struct","schema-id":0,"fields":[{"id":1,"name":"id","required":true,"type":"long"},'
        '{"id":3,"name":"re\\"gion","required":false,"type":"string"}]}',
    )
    assert_equal(partition_fields_json(List[TableColumn]()), "[]")
    var partition = List[TableColumn]()
    partition.append(TableColumn(3, "region", TT_STRING, False))
    partition.append(TableColumn(1, "id", TT_LONG, True))
    assert_equal(
        partition_fields_json(partition),
        '[{"name":"region","transform":"identity","source-id":3,"field-id":1000},'
        '{"name":"id","transform":"identity","source-id":1,"field-id":1001}]',
    )
    assert_equal(
        name_mapping_json(_columns()),
        '[{"field-id":1,"names":["id"]},{"field-id":3,"names":["re\\"gion"]}]',
    )
    assert_equal(Int(timestamp_ms(0)), 1_790_000_000_000)
    assert_equal(Int(timestamp_ms(2)), 1_790_000_120_000)


def test_the_schema_is_pretty_printed_at_its_indent() raises:
    var text = schema_json(_columns(), 0, "  ")
    assert_true(text.startswith("{\n    \"type\" : \"struct\","), text)
    assert_true(_has(text, '    "schema-id" : 0,\n'), text)
    assert_true(_has(text, '      "required" : true,\n'), text)
    assert_true(_has(text, '      "required" : false,\n'), text)
    assert_true(text.endswith("  }"), text)


def test_the_metadata_of_a_table_with_no_snapshot() raises:
    var text = table_metadata_json(
        "file:///w/t", _columns(), List[TableColumn](), List[SnapshotRecord](), 1
    )
    assert_true(_has(text, '"format-version" : 2,'), text)
    assert_true(_has(text, '"location" : "file:///w/t",'), text)
    assert_true(_has(text, '"last-sequence-number" : 0,'), text)
    assert_true(_has(text, '"current-snapshot-id" : -1,'), text)
    assert_true(_has(text, '"refs" : { },'), text)
    assert_true(_has(text, '"last-partition-id" : 999,'), text)
    assert_true(_has(text, '"snapshots" : [  ],'), text)
    assert_true(_has(text, '"metadata-log" : [  ]'), text)
    assert_true(_has(text, '"last-column-id" : 3,'), text)
    assert_true(
        _has(
            text,
            '"schema.name-mapping.default" : "[{\\"field-id\\":1,\\"names\\":[\\"id\\"]},',
        ),
        text,
    )


def test_the_metadata_of_a_partitioned_table_lists_every_snapshot() raises:
    var snapshots = List[SnapshotRecord]()
    snapshots.append(
        SnapshotRecord(
            Int64(11), Int64(-1), Int64(1), Int64(1_790_000_060_000),
            "file:///w/t/metadata/snap-11.avro", "append", 2, 0, Int64(9),
        )
    )
    snapshots.append(
        SnapshotRecord(
            Int64(12), Int64(11), Int64(2), Int64(1_790_000_120_000),
            "file:///w/t/metadata/snap-12.avro", "overwrite", 0, 1, Int64(0),
        )
    )
    var partition = List[TableColumn]()
    partition.append(TableColumn(3, "region", TT_STRING, False))
    var text = table_metadata_json("file:///w/t", _columns(), partition, snapshots, 3)
    assert_true(_has(text, '"last-sequence-number" : 2,'), text)
    assert_true(_has(text, '"current-snapshot-id" : 12,'), text)
    assert_true(
        _has(
            text,
            '"refs" : {\n    "main" : {\n      "snapshot-id" : 12,\n      "type" : "branch"\n    }\n  },',
        ),
        text,
    )
    assert_true(_has(text, '"last-partition-id" : 1000,'), text)
    assert_true(_has(text, '"fields" : [{"name":"region","transform":"identity","source-id":3,"field-id":1000}]'), text)
    assert_true(_has(text, '"snapshot-id" : 11,\n    "timestamp-ms" : 1790000060000,'), text)
    assert_true(_has(text, '"snapshot-id" : 12,\n    "parent-snapshot-id" : 11,'), text)
    assert_true(_has(text, '"operation" : "overwrite",'), text)
    assert_true(_has(text, '"added-records" : "9"'), text)
    assert_true(_has(text, '"manifest-list" : "file:///w/t/metadata/snap-12.avro",'), text)
    assert_true(_has(text, '"metadata-file" : "file:///w/t/metadata/v1.metadata.json"'), text)
    assert_true(_has(text, '"metadata-file" : "file:///w/t/metadata/v2.metadata.json"'), text)
    assert_false(_has(text, "v3.metadata.json"), text)
    assert_true(_has(text, '"last-updated-ms" : 1790000180000,'), text)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

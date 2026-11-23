# =============================================================================
# table_metadata.mojo -- the table's JSON: metadata.json, and the schema and
# partition spec fragments the manifests repeat in their headers.
# =============================================================================
#
# The metadata is laid out as Iceberg Java writes a version-2 table: pretty
# printed with `"key" : value`, `refs.main` naming the current snapshot, every
# snapshot with its manifest list and summary, a snapshot log and a metadata
# log. The table's properties carry `schema.name-mapping.default`, the name
# mapping of every column, as tables converted from files without ids carry it;
# the Parquet files the builder writes do carry ids, so a reader binds by id.
# =============================================================================

from .table_model import (
    PARTITION_FIELD_ID_START,
    SnapshotRecord,
    TableColumn,
    iceberg_type_name,
)

comptime TABLE_UUID: String = "5c0f7c1e-6b3a-4d8e-9a41-0c2f7d9e1b11"

# The table's clock: every timestamp is this plus a minute per commit.
comptime CLOCK_START_MS: Int = 1_790_000_000_000
comptime CLOCK_STEP_MS: Int = 60_000


def timestamp_ms(commit: Int) -> Int64:
    """The timestamp of commit number `commit` (the metadata of version n is
    that of commit n)."""
    return Int64(CLOCK_START_MS + CLOCK_STEP_MS * commit)


def json_string(text: String) -> String:
    """`text` as a JSON string literal (quotes and backslashes escaped)."""
    var escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return String('"') + escaped + '"'


def _bool_text(v: Bool) -> String:
    var out = String()
    if v:
        out += "true"
    else:
        out += "false"
    return out^


def schema_json(columns: List[TableColumn], schema_id: Int, indent: String) raises -> String:
    """The schema object (`type`, `schema-id`, `fields`), written with the
    lines after the first indented by `indent`."""
    var out = String("{\n")
    out += indent + '  "type" : "struct",\n'
    out += indent + '  "schema-id" : ' + String(schema_id) + ",\n"
    out += indent + '  "fields" : [ '
    for i in range(len(columns)):
        ref col = columns[i]
        if i > 0:
            out += ", "
        out += "{\n"
        out += indent + '    "id" : ' + String(col.id) + ",\n"
        out += indent + '    "name" : ' + json_string(col.name) + ",\n"
        out += indent + '    "required" : ' + _bool_text(col.required) + ",\n"
        out += indent + '    "type" : "' + iceberg_type_name(col.type_tag) + '"\n'
        out += indent + "  }"
    out += " ]\n"
    out += indent + "}"
    return out^


def compact_schema_json(columns: List[TableColumn], schema_id: Int) raises -> String:
    """The schema object on one line, as a manifest header holds it."""
    var out = String('{"type":"struct","schema-id":') + String(schema_id)
    out += ',"fields":['
    for i in range(len(columns)):
        ref col = columns[i]
        if i > 0:
            out += ","
        out += '{"id":' + String(col.id) + ',"name":' + json_string(col.name)
        out += ',"required":' + _bool_text(col.required)
        out += ',"type":"' + iceberg_type_name(col.type_tag) + '"}'
    out += "]}"
    return out^


def partition_fields_json(partition_columns: List[TableColumn]) -> String:
    """The partition spec's fields on one line (identity transforms), as a
    manifest header holds them: `[]` for an unpartitioned table."""
    var out = String("[")
    for i in range(len(partition_columns)):
        ref col = partition_columns[i]
        if i > 0:
            out += ","
        out += '{"name":' + json_string(col.name) + ',"transform":"identity"'
        out += ',"source-id":' + String(col.id)
        out += ',"field-id":' + String(PARTITION_FIELD_ID_START + i) + "}"
    out += "]"
    return out^


def name_mapping_json(columns: List[TableColumn]) -> String:
    """The default name mapping: each column's field id and name."""
    var out = String("[")
    for i in range(len(columns)):
        if i > 0:
            out += ","
        out += '{"field-id":' + String(columns[i].id) + ',"names":['
        out += json_string(columns[i].name) + "]}"
    out += "]"
    return out^


def _last_column_id(columns: List[TableColumn]) -> Int:
    var last = 0
    for i in range(len(columns)):
        if columns[i].id > last:
            last = columns[i].id
    return last


def table_metadata_json(
    location: String,
    columns: List[TableColumn],
    partition_columns: List[TableColumn],
    snapshots: List[SnapshotRecord],
    version: Int,
) raises -> String:
    """The metadata.json of table version `version`, after
    `len(snapshots)` commits; the current snapshot is the last."""
    var last_seq = Int64(0)
    var current = Int64(-1)
    if len(snapshots) > 0:
        last_seq = snapshots[len(snapshots) - 1].sequence_number
        current = snapshots[len(snapshots) - 1].snapshot_id
    var out = String("{\n")
    out += '  "format-version" : 2,\n'
    out += '  "table-uuid" : "' + TABLE_UUID + '",\n'
    out += '  "location" : ' + json_string(location) + ",\n"
    out += '  "last-sequence-number" : ' + String(last_seq) + ",\n"
    out += '  "last-updated-ms" : ' + String(timestamp_ms(version)) + ",\n"
    out += '  "last-column-id" : ' + String(_last_column_id(columns)) + ",\n"
    out += '  "current-schema-id" : 0,\n'
    out += '  "schemas" : [ ' + schema_json(columns, 0, "  ") + " ],\n"
    out += '  "default-spec-id" : 0,\n'
    out += '  "partition-specs" : [ {\n'
    out += '    "spec-id" : 0,\n'
    out += '    "fields" : ' + partition_fields_json(partition_columns) + "\n"
    out += "  } ],\n"
    out += '  "last-partition-id" : ' + String(PARTITION_FIELD_ID_START + len(partition_columns) - 1) + ",\n"
    out += '  "default-sort-order-id" : 0,\n'
    out += '  "sort-orders" : [ {\n    "order-id" : 0,\n    "fields" : [ ]\n  } ],\n'
    out += '  "properties" : {\n'
    out += '    "schema.name-mapping.default" : ' + json_string(name_mapping_json(columns)) + ",\n"
    out += '    "write.format.default" : "parquet"\n'
    out += "  },\n"
    out += '  "current-snapshot-id" : ' + String(current) + ",\n"
    if len(snapshots) > 0:
        out += '  "refs" : {\n    "main" : {\n'
        out += '      "snapshot-id" : ' + String(current) + ",\n"
        out += '      "type" : "branch"\n'
        out += "    }\n  },\n"
    else:
        out += '  "refs" : { },\n'
    out += '  "snapshots" : [ '
    for i in range(len(snapshots)):
        ref s = snapshots[i]
        if i > 0:
            out += ", "
        out += "{\n"
        out += '    "sequence-number" : ' + String(s.sequence_number) + ",\n"
        out += '    "snapshot-id" : ' + String(s.snapshot_id) + ",\n"
        if s.parent_snapshot_id >= 0:
            out += '    "parent-snapshot-id" : ' + String(s.parent_snapshot_id) + ",\n"
        out += '    "timestamp-ms" : ' + String(s.timestamp_ms) + ",\n"
        out += '    "summary" : {\n'
        out += '      "operation" : "' + s.operation + '",\n'
        out += '      "added-data-files" : "' + String(s.added_data_files) + '",\n'
        out += '      "added-delete-files" : "' + String(s.added_delete_files) + '",\n'
        out += '      "added-records" : "' + String(s.added_records) + '"\n'
        out += "    },\n"
        out += '    "manifest-list" : ' + json_string(s.manifest_list_uri) + ",\n"
        out += '    "schema-id" : 0\n'
        out += "  }"
    out += " ],\n"
    out += '  "statistics" : [ ],\n'
    out += '  "partition-statistics" : [ ],\n'
    out += '  "snapshot-log" : [ '
    for i in range(len(snapshots)):
        if i > 0:
            out += ", "
        out += '{\n    "timestamp-ms" : ' + String(snapshots[i].timestamp_ms) + ",\n"
        out += '    "snapshot-id" : ' + String(snapshots[i].snapshot_id) + "\n  }"
    out += " ],\n"
    out += '  "metadata-log" : [ '
    for v in range(1, version):
        if v > 1:
            out += ", "
        out += '{\n    "timestamp-ms" : ' + String(timestamp_ms(v)) + ",\n"
        out += '    "metadata-file" : ' + json_string(location + "/metadata/v" + String(v) + ".metadata.json") + "\n  }"
    out += " ]\n"
    out += "}\n"
    return out^

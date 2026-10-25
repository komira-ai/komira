# =============================================================================
# iceberg_metadata_json.mojo — Iceberg v2 table metadata.json + the schema /
#                              partition-spec JSON sub-documents.
# =============================================================================
#
# The table metadata.json is the ROOT of an Iceberg table: it carries the
# format-version, table-uuid, location, the schema list, the partition spec
# list, the snapshot list (each pointing at a manifest-list file), and the
# current-snapshot-id. A catalog-free reader (pyiceberg StaticTable.from_metadata,
# DuckDB iceberg_scan) reads THIS file and walks: metadata.json -> current
# snapshot -> manifest-list -> manifest file(s) -> Parquet data files.
#
# This module builds that JSON document (+ the reusable schema / spec
# sub-documents the manifests ALSO embed) by direct String concatenation via
# the `json_*` primitives in iceberg_types.mojo. The structure is FIXED + small;
# a direct builder is the correct, spec-faithful shape.
#
# v2 SCOPE: a single schema, a single partition spec, a single sort order (id 0,
# unsorted), and a snapshot list the writer appends to. The `schemas` array
# holds the current schema only.
#
# Encapsulation: every function takes owned/borrowed typed values and returns
# an owned String. ZERO UnsafePointer; ZERO wildcard origins.
# =============================================================================

from .iceberg_types import (
    IcebergSchema,
    iceberg_type_name,
    json_escape_string,
    json_kv_str,
    json_kv_int,
    json_kv_int64,
    json_kv_bool,
    json_kv_raw,
)
from .iceberg_partition import (
    PartitionSpec,
    transform_name,
)


# =============================================================================
# Schema JSON sub-document (embedded in metadata.json AND in each manifest).
# =============================================================================


def schema_json(schema: IcebergSchema) raises -> String:
    """The Iceberg schema JSON: `{type:"struct", schema-id, fields:[...]}`.

    Each field is `{id, name, required, type}` with the spec-assigned field-id.
    This SAME string is embedded both in metadata.json's `schemas` array and as
    the manifest OCF's `schema` key-value metadata (a reader binds columns by
    field-id from here)."""
    var out = String("{")
    out += json_kv_str("type", String("struct")) + ","
    out += json_kv_int("schema-id", schema.schema_id) + ","
    out += '"fields":['
    for i in range(len(schema.fields)):
        ref f = schema.fields[i]
        if i > 0:
            out += ","
        out += "{"
        out += json_kv_int("id", f.field_id) + ","
        out += json_kv_str("name", f.name) + ","
        out += json_kv_bool("required", f.required) + ","
        out += json_kv_str("type", iceberg_type_name(f.type_tag))
        out += "}"
    out += "]}"
    return out^


# =============================================================================
# Partition spec JSON (empty / unpartitioned) + sort order JSON (unsorted).
# =============================================================================


def unpartitioned_spec_json() -> String:
    """The empty (unpartitioned) partition spec: `{spec-id:0, fields:[]}`.

    Embedded in metadata.json's `partition-specs` array."""
    return String('{"spec-id":0,"fields":[]}')


def partition_spec_fields_json(spec: PartitionSpec) raises -> String:
    """The FIELDS array of a partition spec:
    `[{name, transform, source-id, field-id}, ...]` (`[]` when unpartitioned).

    This is the form a manifest file's `partition-spec` header key carries (the
    table spec's "JSON fields representation"); `partition_spec_json` wraps it
    with the spec id for metadata.json."""
    var out = String("[")
    for i in range(len(spec.fields)):
        ref pf = spec.fields[i]
        if i > 0:
            out += ","
        out += "{"
        out += json_kv_str("name", pf.name) + ","
        out += (
            json_kv_str("transform", transform_name(pf.transform, pf.param))
            + ","
        )
        out += json_kv_int("source-id", pf.source_field_id) + ","
        out += json_kv_int("field-id", pf.field_id)
        out += "}"
    out += "]"
    return out^


def partition_spec_json(spec: PartitionSpec) raises -> String:
    """The Iceberg partition-spec JSON for `spec`:
    `{spec-id, fields:[{name, transform, source-id, field-id}]}`.

    Each partition field emits the spec's four attributes:
      * name       — the partition field name (e.g. "id_bucket").
      * transform  — "identity" / "bucket[N]" (from `transform_name`).
      * source-id  — the SCHEMA field-id this partitions on.
      * field-id   — the PARTITION field-id (>= 1000, stable).
    Embedded in metadata.json's `partition-specs` array (a manifest header
    carries only the fields array, `partition_spec_fields_json`). For an
    unpartitioned spec of id 0 this coincides byte-for-byte with
    `unpartitioned_spec_json()`."""
    var out = String("{")
    out += json_kv_int("spec-id", spec.spec_id) + ","
    out += json_kv_raw("fields", partition_spec_fields_json(spec))
    out += "}"
    return out^


def delete_spec_of(spec: PartitionSpec) -> PartitionSpec:
    """The partition spec the DELETE manifests of a table partitioned by `spec`
    are written under: an unpartitioned spec with its own id (`spec.spec_id +
    1`). Delete files here carry no partition tuple, so they apply to the whole
    table (the spec: a delete file written under an unpartitioned spec is a
    global delete). They cannot share the table spec's id, because a manifest
    list entry names its spec by id and the table spec has partition fields.
    An unpartitioned table's delete manifests use its own spec."""
    if spec.is_unpartitioned():
        return PartitionSpec(spec.spec_id)
    return PartitionSpec(spec.spec_id + 1)


def unsorted_order_json() -> String:
    """The default unsorted sort order: `{order-id:0, fields:[]}`."""
    return String('{"order-id":0,"fields":[]}')


# =============================================================================
# Name mapping (schema.name-mapping.default).
# =============================================================================
#
# LOAD-BEARING for cross-engine read of data files WITHOUT embedded field-ids.
# The komira Parquet writer does not stamp the `PARQUET:field_id` per-column
# metadata, so a reader (pyiceberg / DuckDB) cannot bind a data file's columns
# to the table's field-ids by id. Iceberg's fallback is the table property
# `schema.name-mapping.default`: a JSON array of `{field-id, names:[col]}` that
# maps each data-file column NAME to its Iceberg field-id. Without it, pyiceberg
# raises "Parquet file does not have field-ids and the Iceberg table does not
# have 'schema.name-mapping.default' defined". We emit it from the schema so
# the data files (column names == schema field names) bind correctly.


def name_mapping_json(schema: IcebergSchema) raises -> String:
    """The `schema.name-mapping.default` value: a JSON ARRAY (as a STRING,
    since Iceberg table properties are string-valued) of `{field-id, names}`
    entries, one per top-level column."""
    var out = String("[")
    for i in range(len(schema.fields)):
        ref f = schema.fields[i]
        if i > 0:
            out += ","
        out += "{"
        out += json_kv_int("field-id", f.field_id) + ","
        out += '"names":[' + json_escape_string(f.name) + "]"
        out += "}"
    out += "]"
    return out^


# =============================================================================
# Snapshot summary extra key/value (an ingest process's position stamp).
# =============================================================================
#
# The Iceberg snapshot `summary` map is spec-defined as an arbitrary string->
# string map (a required `operation` key + engine-specific extras). The shipped
# writer emits the conventional count metrics. An ingest process can stamp the
# last-applied per-shard stream position INTO the summary so the resume point
# rides the SAME atomic commit as the data (no separate checkpoint store).
# `SummaryKV`
# carries one such extra entry; the caller passes a `List[SummaryKV]` to
# `commit_with_summary`, and the reader recovers them via
# `read_current_snapshot_summary`.


@fieldwise_init
struct SummaryKV(Copyable, Movable, Deinitable):
    """One extra `summary` map entry (string key -> string value). Used by the
    ingest process to stamp the per-shard stream position into the snapshot
    summary so the resume point is committed atomically with the data.

    A plain owned-field struct (two `String`s), only ever stored in a plain
    `List[SummaryKV]`: no pointer field, no byte slab."""

    var key: String
    var value: String

    def copy(self) -> Self:
        return Self(String(self.key), String(self.value))


# =============================================================================
# Snapshot JSON.
# =============================================================================


struct SnapshotInfo(Copyable, Movable, Deinitable):
    """One snapshot of the table.

    Fields:
      var snapshot_id: Int64       — unique snapshot id.
      var sequence_number: Int64   — v2 monotonic sequence number.
      var timestamp_ms: Int64      — commit time (epoch ms).
      var manifest_list: String    — object key of this snapshot's manifest list.
      var added_files: Int         — # data files added (summary).
      var added_records: Int64     — # rows added (summary).
      var total_files: Int         — total data files (cumulative summary).
      var total_records: Int64     — total rows (cumulative summary).
      var schema_id: Int           — the schema this snapshot was written with.
      var parent_snapshot_id: Int64 — parent snapshot id (-1 == no parent).
      var extra_summary: List[SummaryKV] — extra `summary` map entries (default
                                     empty; an ingest process stamps the
                                     per-shard stream position here so the resume
                                     point rides the same atomic commit).
      var operation: String        — the summary's `operation`: "append" (the
                                     default), "overwrite" or "delete" (the
                                     spec's operations that remove rows).
    """

    var snapshot_id: Int64
    var sequence_number: Int64
    var timestamp_ms: Int64
    var manifest_list: String
    var added_files: Int
    var added_records: Int64
    var total_files: Int
    var total_records: Int64
    var schema_id: Int
    var parent_snapshot_id: Int64
    var extra_summary: List[SummaryKV]
    var operation: String

    def __init__(
        out self,
        snapshot_id: Int64,
        sequence_number: Int64,
        timestamp_ms: Int64,
        var manifest_list: String,
        added_files: Int,
        added_records: Int64,
        total_files: Int,
        total_records: Int64,
        schema_id: Int,
        parent_snapshot_id: Int64,
        var extra_summary: List[SummaryKV] = List[SummaryKV](),
        var operation: String = String("append"),
    ):
        """Construct a snapshot record. `extra_summary` defaults to empty so the
        shipped writer call sites (positional, 10 args) are byte-identical — the
        emitted summary is unchanged when empty."""
        self.snapshot_id = snapshot_id
        self.sequence_number = sequence_number
        self.timestamp_ms = timestamp_ms
        self.manifest_list = manifest_list^
        self.added_files = added_files
        self.added_records = added_records
        self.total_files = total_files
        self.total_records = total_records
        self.schema_id = schema_id
        self.parent_snapshot_id = parent_snapshot_id
        self.extra_summary = extra_summary^
        self.operation = operation^

    def copy(self) -> Self:
        var ex = List[SummaryKV]()
        for i in range(len(self.extra_summary)):
            ex.append(self.extra_summary[i].copy())
        return Self(
            self.snapshot_id,
            self.sequence_number,
            self.timestamp_ms,
            String(self.manifest_list),
            self.added_files,
            self.added_records,
            self.total_files,
            self.total_records,
            self.schema_id,
            self.parent_snapshot_id,
            ex^,
            String(self.operation),
        )


def snapshot_json(snap: SnapshotInfo) raises -> String:
    """One snapshot object for metadata.json's `snapshots` array.

    Carries `snapshot-id`, `sequence-number`, `timestamp-ms`, `manifest-list`,
    `schema-id`, a summary with the `operation` and row/file counts (+ any
    `extra_summary` KV entries), and the `parent-snapshot-id` when present."""
    var out = String("{")
    out += json_kv_int64("snapshot-id", snap.snapshot_id) + ","
    if snap.parent_snapshot_id >= 0:
        out += (
            json_kv_int64("parent-snapshot-id", snap.parent_snapshot_id) + ","
        )
    out += json_kv_int64("sequence-number", snap.sequence_number) + ","
    out += json_kv_int64("timestamp-ms", snap.timestamp_ms) + ","
    # summary (operation is REQUIRED; the rest are conventional metrics + any
    # stamped position KVs). The count fields are emitted FIRST (byte-stable
    # with the shipped path); the extra KVs follow.
    var summary = String("{")
    summary += json_kv_str("operation", snap.operation) + ","
    summary += json_kv_str("added-data-files", String(snap.added_files)) + ","
    summary += json_kv_str("added-records", String(snap.added_records)) + ","
    summary += json_kv_str("total-data-files", String(snap.total_files)) + ","
    summary += json_kv_str("total-records", String(snap.total_records))
    for i in range(len(snap.extra_summary)):
        summary += "," + json_kv_str(
            snap.extra_summary[i].key, snap.extra_summary[i].value
        )
    summary += "}"
    out += json_kv_raw("summary", summary) + ","
    out += json_kv_str("manifest-list", snap.manifest_list) + ","
    out += json_kv_int("schema-id", snap.schema_id)
    out += "}"
    return out^


# =============================================================================
# Full table metadata.json.
# =============================================================================


def build_table_metadata_json(
    table_uuid: String,
    location: String,
    schema: IcebergSchema,
    snapshots: List[SnapshotInfo],
    current_snapshot_id: Int64,
    last_sequence_number: Int64,
    last_updated_ms: Int64,
    spec: PartitionSpec = PartitionSpec(0),
    prior_schemas: List[String] = List[String](),
) raises -> String:
    """Assemble the complete Iceberg v2 table metadata.json document.

    Emits every field a catalog-free reader needs: format-version=2,
    table-uuid, location, last-sequence-number, last-updated-ms,
    last-column-id, the schemas array (+ current-schema-id), the
    partition-specs array (+ default-spec-id + last-partition-id), the
    sort-orders array (+ default-sort-order-id), properties, the snapshots
    array (+ current-snapshot-id), and the snapshot-log / metadata-log.

    `spec` (default unpartitioned) is emitted as the default partition spec,
    first in `partition-specs`; `default-spec-id` = its spec-id and
    `last-partition-id` its highest partition field-id (999 for the
    unpartitioned base). A partitioned `spec` is followed by the unpartitioned
    spec of `delete_spec_of(spec)`, which the delete manifests name.

    `prior_schemas` (default none) are the raw JSON objects of earlier schemas
    to keep in the `schemas` array ahead of the current one, so a snapshot
    written under an older schema still names a schema the table holds.

    `current_snapshot_id` of -1 means "no current snapshot" (an empty table)
    — the field is then emitted as -1 which pyiceberg/DuckDB treat as none."""
    var out = String("{")
    out += json_kv_int("format-version", 2) + ","
    out += json_kv_str("table-uuid", table_uuid) + ","
    out += json_kv_str("location", location) + ","
    out += json_kv_int64("last-sequence-number", last_sequence_number) + ","
    out += json_kv_int64("last-updated-ms", last_updated_ms) + ","
    out += json_kv_int("last-column-id", schema.last_column_id()) + ","

    # schemas + current-schema-id.
    # `prior_schemas` are the raw JSON objects of the schemas earlier snapshots
    # were written with (their `schema-id`s must stay resolvable); the current
    # schema comes last.
    var sj = schema_json(schema)
    var schemas = String("")
    for i in range(len(prior_schemas)):
        schemas += prior_schemas[i] + ","
    out += '"schemas":[' + schemas + sj + "],"
    out += json_kv_int("current-schema-id", schema.schema_id) + ","

    # partition-specs + default-spec-id + last-partition-id.
    # Unpartitioned: last-partition-id is the spec base 999 (the Iceberg
    # convention for the partition-field id base — no partition fields assigned).
    # Partitioned: the highest partition field-id (1000-based).
    var specs = partition_spec_json(spec)
    if not spec.is_unpartitioned():
        # The unpartitioned spec the delete manifests are written under.
        specs += "," + partition_spec_json(delete_spec_of(spec))
    out += '"partition-specs":[' + specs + "],"
    out += json_kv_int("default-spec-id", spec.spec_id) + ","
    out += json_kv_int("last-partition-id", spec.last_partition_id()) + ","

    # properties — carries `schema.name-mapping.default` (LOAD-BEARING: lets a
    # reader bind the data files' columns to field-ids by NAME, since the
    # Parquet files do not embed field-ids). The property VALUE is the
    # name-mapping JSON array serialized as a (JSON-escaped) string.
    var nm = name_mapping_json(schema)
    var props = String("{")
    props += json_kv_str("schema.name-mapping.default", nm)
    props += "}"
    out += json_kv_raw("properties", props) + ","

    # current-snapshot-id, and the `main` branch ref the spec requires to name
    # the same snapshot (v2: "current-snapshot-id must be the id of the main
    # branch in refs").
    out += json_kv_int64("current-snapshot-id", current_snapshot_id) + ","
    if current_snapshot_id >= 0:
        var main_ref = String("{")
        main_ref += json_kv_int64("snapshot-id", current_snapshot_id) + ","
        main_ref += json_kv_str("type", String("branch"))
        main_ref += "}"
        out += json_kv_raw("refs", '{"main":' + main_ref + "}") + ","

    # snapshots array.
    out += '"snapshots":['
    for i in range(len(snapshots)):
        if i > 0:
            out += ","
        out += snapshot_json(snapshots[i])
    out += "],"

    # snapshot-log: one entry per snapshot ({timestamp-ms, snapshot-id}).
    out += '"snapshot-log":['
    for i in range(len(snapshots)):
        if i > 0:
            out += ","
        out += "{"
        out += (
            json_kv_int64("timestamp-ms", snapshots[i].timestamp_ms) + ","
        )
        out += json_kv_int64("snapshot-id", snapshots[i].snapshot_id)
        out += "}"
    out += "],"

    # metadata-log: empty (the version-hint / pointer mechanism tracks
    # prior metadata files; an explicit metadata-log is optional).
    out += json_kv_raw("metadata-log", String("[]")) + ","

    # sort-orders + default-sort-order-id.
    out += '"sort-orders":[' + unsorted_order_json() + "],"
    out += json_kv_int("default-sort-order-id", 0)

    out += "}"
    return out^

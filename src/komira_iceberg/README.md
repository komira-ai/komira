# komira_iceberg

A file-based Apache Iceberg v2 table writer and reader. A set of Parquet data
files becomes a table any Iceberg engine reads by pointing at the object store;
there is no catalog service. A commit is a create-if-absent write of the next
metadata file, so concurrent writers never overwrite each other.

This part holds the metadata layer on top of the table model. The data-file and
delete-file writers, the reader and the table writer follow in later parts.

## What it holds

| module | what |
|---|---|
| `iceberg_types` | the column type tags and their spec names, `IcebergSchema` (field ids 1..N in column order), `add-column` evolution, `DataFileInfo` and `ColumnBound`, the JSON escaper |
| `iceberg_bounds` | single-value serialization (table spec Appendix D) and the min/max scan of an Arrow column, null and NaN aware |
| `iceberg_partition` | `PartitionSpec` with the `identity` and `bucket[N]` transforms, the murmur3 bucket hash, per-row partition values, a path-safe partition key, routing rows to partitions |
| `iceberg_metadata_json` | the table `metadata.json`, the schema and partition-spec documents, snapshot objects and the `schema.name-mapping.default` property |
| `iceberg_avro_manifest`, `iceberg_avro_manifest_read` | the manifest list and manifest file (Avro) encoders with the spec's field ids, and decoders for the manifests this package writes |
| `iceberg_row_value` | the Avro row form of a typed cell, and the encode-boundary type check |
| `iceberg_summary` | reading the current snapshot's `summary` map back |
| `iceberg_version` | which metadata version is current: the `version-hint.text` number, then every higher `v<N>.metadata.json` that exists |
| `iceberg_json_scan` | byte-exact scanners over the `metadata.json` this package writes |

## Against the spec

Checked against the Apache Iceberg table spec, format version 2:

- `metadata.json` carries every required field; `refs.main` names
  `current-snapshot-id` whenever there is a current snapshot; the `schemas`
  array can keep earlier schemas.
- A partitioned table also lists an unpartitioned spec (`spec-id` + 1), which
  its delete manifests are written under: a delete file carries no partition
  tuple, so it applies to the whole table (a global delete).
- The manifest-entry and manifest-list Avro schemas carry the spec's names and
  field ids (`manifest_entry` 0-4, `data_file` 100-140, `manifest_file` 500-518).
- A manifest header carries `schema`, `schema-id`, `partition-spec` (the fields
  array), `partition-spec-id`, `format-version` and `content`.
- Bounds are the spec's single-value bytes; a NaN is never a bound.
- `bucket[N]` is `(murmur3_x86_32(bytes) & 0x7FFFFFFF) % N`, with an int hashed
  as a long.

Where it does not follow the spec, or does less:

- Types: boolean, int, long, float, double and string only. No decimal, date,
  time, timestamp, uuid, fixed, binary or nested types.
- Transforms: `identity` and `bucket[N]` (int, long and string sources). No
  `truncate`, `year`, `month`, `day`, `hour` or `void`.
- Partition fields are written as required Avro values, not `["null", T]`
  unions, so a partition value cannot be null.
- `nan_value_counts`, `column_sizes`, `split_offsets`, `key_metadata` and
  `sort_order_id` are written as null; the manifest list's `partitions`
  summary is null.
- One sort order (unsorted). `metadata-log` is empty: the current version is
  found from the hint and the metadata files themselves.
- A snapshot's summary carries `operation` and the added-file and record counts
  (and what a caller stamps); the cumulative delete totals (`total-delete-files`,
  `total-position-deletes`, `total-equality-deletes`) and `total-files-size` are
  not written.
- The manifest decoders read the manifests this package writes, positionally.
  They do not resolve another writer's schema, and they do not skip entries
  whose status is DELETED (this package never writes one).
- The Avro row form is required-only: a null cell encodes as its type's zero
  value.

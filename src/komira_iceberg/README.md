# komira_iceberg

A file-based Apache Iceberg v2 table writer and reader. A set of Parquet data
files becomes a table any Iceberg engine reads by pointing at the object store;
there is no catalog service. A commit is a create-if-absent write of the next
metadata file, so concurrent writers never overwrite each other.

This part holds the Parquet data leg, the delete files and the reader on top of
the metadata layer and the table model. The table writer follows in a later part.

## What it holds

| module | what |
|---|---|
| `iceberg_types` | the column type tags and their spec names, `IcebergSchema` (field ids 1..N in column order), `add-column` evolution, `DataFileInfo` and `ColumnBound`, the JSON escaper |
| `iceberg_bounds` | single-value serialization (table spec Appendix D) and the min/max scan of an Arrow column, null and NaN aware |
| `iceberg_partition` | `PartitionSpec` with the `identity` and `bucket[N]` transforms, the murmur3 bucket hash, per-row partition values, a path-safe partition key, routing rows to partitions |
| `iceberg_metadata_json` | the table `metadata.json`, the schema and partition-spec documents, snapshot objects and the `schema.name-mapping.default` property |
| `iceberg_avro_manifest`, `iceberg_avro_manifest_read` | the manifest list and manifest file (Avro) encoders with the spec's field ids, and decoders for the manifests this package writes |
| `iceberg_parquet_data` | typed rows to a Parquet data file (bytes in memory, no file opened) and back, in file-absolute row order |
| `iceberg_delete_writer` | the equality-delete and position-delete files (Avro) and their decoders |
| `iceberg_reader` | the merge-on-read reader: current metadata version -> manifest list -> manifests -> data and delete files, equality deletes by key and position deletes by (path, position) honoring sequence numbers |
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

- Locations are object-store keys, not URIs. `location` is one string that is
  both the key prefix the files are written under and the `location` in
  `metadata.json`; it is recorded verbatim (JSON-escaped, non-ASCII intact),
  and every key is built from it by joining with `/`. The spec asks for full
  URIs with a filesystem scheme (`s3://bucket/prefix`); a URI given as the
  location is not understood by this package's own store access, which
  normalises `//` in a key. An engine therefore reads a table written here only
  where its warehouse root maps to the store root, or after rewriting paths.
  Writing absolute URIs needs a base URI separate from the store prefix; it is
  not done yet.
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
- Delete files are Avro (the spec allows any file format). The position-delete
  schema is the spec's (`file_path` id 2147483546, `pos` id 2147483545), but an
  engine that reads only Parquet delete files will not apply them. Equality
  delete files carry the table's field ids with the column named `f<id>`.
- Data files carry no `PARQUET:field_id` column metadata: a reader binds the
  columns to field ids through the `schema.name-mapping.default` table
  property.
- Equality deletes on a nullable column are refused by the writer (null
  equality-key semantics are not implemented in the merge predicate).
- The reader honors the sequence-number rules (equality: strictly lower data
  sequence; position: data sequence <= delete sequence) but loads every data
  file and compares each row with every delete key: it is a reference reader,
  not a scan engine, and does not prune by partition or bounds.
- The manifest decoders read the manifests this package writes, positionally.
  They do not resolve another writer's schema, and they do not skip entries
  whose status is DELETED (this package never writes one).
- The Avro row form is required-only: a null cell encodes as its type's zero
  value.

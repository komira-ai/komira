# komira_iceberg

A file-based Apache Iceberg v2 table writer and reader. A set of Parquet data
files becomes a table any Iceberg engine reads by pointing at the object store;
there is no catalog service. A commit is a create-if-absent write of the next
metadata file, so concurrent writers never overwrite each other.


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
| `iceberg_writer`, `iceberg_writer_state` | `IcebergTableWriter`: appends data files and delete files as snapshots (the commit below); unique table and snapshot ids from a UUIDv7; the prior state a commit builds on |
| `iceberg_row_value` | the Avro row form of a typed cell, and the encode-boundary type check |
| `iceberg_summary` | reading the current snapshot's `summary` map back |
| `iceberg_version` | which metadata version is current: the `version-hint.text` number, then every higher `v<N>.metadata.json` that exists |
| `iceberg_json_scan` | byte-exact scanners over the `metadata.json` this package writes |

## The commit

`commit` writes the data and delete manifests and the manifest list (uuid-named,
create-if-absent), then creates `v<N+1>.metadata.json` with create-if-absent:
that create is the linearization point, so exactly one writer owns each
version. A loser gets an `iceberg commit conflict` error (re-read the table and
retry); the create is never tolerated, whatever the other file holds.
`version-hint.text` is then moved by compare-and-swap from the etag read before
the version was, never backwards (a swap that loses ends when the hint already
names this version or a later one). The current version is the hint's number and
every higher metadata file that exists, so a writer that stopped between the
create and the hint move has still committed. The first commit creates the hint.

A commit that fails (a conflict, a store error) after writing its manifests
leaves them behind, unreferenced; no reader looks at a file no snapshot names.
The writer deletes nothing: data files, old manifests and old metadata files
stay until a maintenance job removes them.

Before anything is written the commit refuses what it could not publish: a
writer whose table uuid or schema is not the table's (the table's current
schema, or an add-column extension of it), a data file whose content is not 0, a
delete file whose content is not 1 or 2, a data or position-delete file whose
partition tuple does not match the spec, an equality delete that carries a tuple
or lists no equality ids. `prepare_commit` and `publish_commit` are the two halves
of a commit (everything but the commit, then the create); holding two prepared
commits of one table and publishing both is how the race is tested.

Every delete file's sequence number is stamped by the commit. A table keeps one
partition spec; a commit under another is refused. A caller's extra summary key
may not collide with one the commit writes. Table uuids and snapshot ids are
UUIDv7-derived (komira_uuid), so two writers on different hosts never mint the
same id; `gen_table_uuid` therefore raises when the entropy source fails.

## Paths

Every path the table stores (`location` in metadata.json, the manifest-list and
manifest paths, `data_file.file_path`, the `file_path` rows of position deletes)
is an object-store key exactly as the caller built it from `location`, not a URI
with a scheme (the spec says "full URI with FS scheme"). The store normalizes its
keys (no leading `/`, `//` collapsed), so a `s3://bucket/key` location would not
read back through this package. An engine opens the table only if it resolves the
stored keys the way the store does: an absolute filesystem path as `location`
works, as does a relative one when the engine's working directory is the store's
root. Writing full URIs needs a separate base-URI setting that is not here.

## Against the spec

Checked against the Apache Iceberg table spec, format version 2:

- `metadata.json` carries every required field; `refs.main` names
  `current-snapshot-id` whenever there is a current snapshot; the `schemas`
  array can keep earlier schemas.
- A partitioned table also lists an unpartitioned spec (`spec-id` + 1), which
  the manifest of its equality deletes is written under: such a delete file
  carries no partition tuple, so it applies to the whole table (a global
  delete). A position delete applies only to data files of its own spec and
  partition, so on a partitioned table it goes in a manifest under the table
  spec and carries its data file's partition tuple.
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
- Delete files are Avro (the spec allows any file format). The position-delete
  schema is the spec's (`file_path` id 2147483546, `pos` id 2147483545), but an
  engine that reads only Parquet delete files will not apply them. Equality
  delete files carry the table's field ids with the column named `f<id>`.
- Data files carry no `PARQUET:field_id` column metadata: a reader binds the
  columns to field ids through the `schema.name-mapping.default` table
  property.
- `total-delete-files`, `total-position-deletes`, `total-equality-deletes` and
  `total-files-size` are not in the summary; its delete counters are the
  `added-*` ones of the commit.
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

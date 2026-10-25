# komira_iceberg

A file-based Apache Iceberg v2 table writer and reader. A set of Parquet data
files becomes a table any Iceberg engine reads by pointing at the object store;
there is no catalog service. A commit is a create-if-absent write of the next
metadata file, so concurrent writers never overwrite each other.

This part of the package is the table model. The data-file and delete-file
writers, the reader and the table writer follow in later parts.

## What it holds

This part is the table model. The metadata.json emitter, the manifests, the
reader and the table writer follow in later parts.

| module | what |
|---|---|
| `iceberg_types` | the column type tags and their spec names, `IcebergSchema` (field ids 1..N in column order), `add-column` evolution, `DataFileInfo` and `ColumnBound`, the JSON escaper |
| `iceberg_bounds` | single-value serialization (table spec Appendix D) and the min/max scan of an Arrow column, null and NaN aware |
| `iceberg_partition` | `PartitionSpec` with the `identity` and `bucket[N]` transforms, the murmur3 bucket hash, per-row partition values, a path-safe partition key, routing rows to partitions |
| `iceberg_row_value` | the Avro row form of a typed cell, and the encode-boundary type check |

## Against the spec

Checked against the Apache Iceberg table spec, format version 2:

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
- The Avro row form is required-only: a null cell encodes as its type's zero
  value.

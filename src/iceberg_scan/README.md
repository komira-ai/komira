# iceberg_scan

Reads Apache Iceberg tables of format version 1 and 2, written by any engine
(Java, Spark, pyiceberg, this repository's `iceberg` writer), from local files.
It is what stands under `iceberg_scan('<path>')` in SQL and
`register_iceberg_table` in the SDK: everything that reads a byte of a table
lives here, and the packages above it (`sql`, `sdk_exec`, `lowering`,
`pipeline_exec`) hold only the plumbing.

It is a different package from `iceberg`, the writer of the file-based tables
of `cdc_ingest`, which decodes only the bytes its own writer emits. This one
finds every field of an Avro file by name in the schema the file carries, reads
`metadata.json` through a JSON parser, and depends on no object store, clock or
network.

## What it holds

| module | what |
|---|---|
| `avro_datum` | any Avro object container file decoded by its own header's schema into a flat arena: unions resolved to their branch, arrays in both block forms, maps, enums, fixed, every codec `avro` has; the header's key-value map |
| `table_metadata` | the `metadata.json` of any writer: schemas, partition specs, snapshots, the current snapshot (`refs.main`, else `current-snapshot-id`), the name mapping property; v1 and v2, format version 3 refused |
| `table_ref` | a path (a `*.metadata.json` file, or a table directory read through `metadata/version-hint.text`) resolved to a table pinned to a snapshot and schema; the Arrow type of every column; the `komira.iceberg.table` scan binding; `local_path_of`, which turns a stored path into a local one |
| `manifests` | the manifest list and the manifest entries, with each file's column metrics, partition values and sequence number |
| `prune` | which files a filter can skip: identity partition values, manifest partition summaries and column bounds and counts |
| `scan_planner` | `plan_iceberg_scan`: the data files worth reading and the delete files that apply to them, as the `IcebergScanSpec` a physical plan carries |
| `scan_reader` | `read_iceberg_scan`: the rows of those files, deletes applied, each column bound by field id or name |
| `table_fixture` | builders of the metadata and manifest bytes of a small table, for tests |

## The path of a scan

`resolve_iceberg_table(path, allow_moved_paths, snapshot_id)` reads the
metadata file and pins the snapshot (the current one, or `snapshot_from_id`)
and the schema. `iceberg_scan_binding` turns the result into the scan binding a
logical plan carries: its identity is the metadata path, the table root, the
relocation flag, the snapshot and the schema, and its gate is the zonemap
family's, so the optimizer pushes simple comparisons into the scan.
At lowering, `plan_iceberg_scan(binding, filter)` re-reads the metadata,
skips manifests and files the filter cannot match, matches delete files, and
returns the files in a fixed order. At run time `read_iceberg_scan(spec)` reads
them. Pruning never changes a result: the pushed filter is applied again as an
operator over the rows.

```text
var table = resolve_iceberg_table("warehouse/orders", False, None)
var binding = iceberg_scan_binding(table)            # what the plan carries
var planned = plan_iceberg_scan(binding, filter)     # planned.spec, planned.counts
var rows = read_iceberg_scan(planned.spec)           # one RecordBatch
```

### Paths

`path` is a metadata file, or a table directory: then the file read is
`<dir>/metadata/v<N>.metadata.json` for the N in `metadata/version-hint.text`;
a directory with no hint is `ICEBERG_TABLE_VERSION_UNKNOWN`, naming it. Bare
paths and `file:` URIs are read; any other scheme is `ICEBERG_PATH_UNSUPPORTED`.
With `allow_moved_paths`, a stored URI under the table's recorded `location` is
rewritten to the table root plus the rest of the URI, whatever its scheme, so a
table copied to another directory still reads.

### Types

boolean, int, long, float, double, string, date, timestamp (microseconds, no
zone), timestamptz (microseconds, `UTC`) and decimal(P, S) with P up to 38 have
an Arrow type; every other type (binary, uuid, fixed, time, struct, list, map)
is `ICEBERG_TYPE_UNSUPPORTED`, naming the column and the type, when the table
is resolved. A column added after a data file was written reads as null from
that file; an int column promoted to long reads widened, and float to double.

### Deletes

Position deletes (Parquet or Avro) and equality deletes (Parquet or Avro) are
applied. A position delete applies to a data file whose sequence number is at
or below its own, when it names the file (`referenced_data_file`) or has the
file's spec and partition; an equality delete applies to a data file whose
sequence number is strictly below its own, when it was written under an
unpartitioned spec or has the file's spec and partition. A delete file that
applies to no remaining data file is not listed. Puffin deletion vectors, ORC
data files and format version 3 are
`OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED`.

## Errors

Every refusal is `TOKEN: detail`:

| token | when |
|---|---|
| `ICEBERG_TABLE_VERSION_UNKNOWN` | a table directory with no `metadata/version-hint.text` |
| `ICEBERG_METADATA_INVALID` | no table at the path, a metadata file that is not JSON or not metadata, a version hint that is no number |
| `ICEBERG_SNAPSHOT_NOT_FOUND` | `snapshot_from_id` names a snapshot the table lacks |
| `ICEBERG_TYPE_UNSUPPORTED` | a column of a type with no Arrow mapping here |
| `ICEBERG_PATH_UNSUPPORTED` | a stored or given path of a scheme other than `file` |
| `ICEBERG_MANIFEST_INVALID` | a manifest list, manifest or Avro delete file that does not decode, or that holds the wrong kind of file |
| `ICEBERG_DATA_FILE_MISMATCH` | a data or delete file that cannot be read, or a column that cannot be read at its bound type |
| `OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED` | format version 3, an ORC data file, a delete file of a format other than Parquet or Avro, an equality delete over a field the scanned schema lacks |

## Examples

The metadata of a table, as any writer wrote it:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from iceberg_scan.table_metadata import parse_iceberg_metadata

var md = parse_iceberg_metadata(
    '{"format-version": 2, "location": "file:///warehouse/orders",'
    ' "current-schema-id": 0,'
    ' "schemas": [{"schema-id": 0, "fields": ['
    '{"id": 1, "name": "id", "required": true, "type": "long"},'
    '{"id": 2, "name": "price", "required": false, "type": "decimal(9, 2)"}]}],'
    ' "snapshots": [{"snapshot-id": 11, "sequence-number": 1,'
    ' "manifest-list": "file:///warehouse/orders/metadata/snap-11.avro"}],'
    ' "refs": {"main": {"snapshot-id": 11, "type": "branch"}}}'
)
assert_equal(md.current_snapshot_id.value(), 11)
assert_equal(md.snapshot_by_id(11).sequence_number, 1)
assert_equal(md.schema_by_id(0).fields[1].type_name, "decimal(9,2)")
```

A format version 3 table is refused by name, and a type the scan cannot read is
refused naming its column:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from iceberg_scan.table_metadata import parse_iceberg_metadata
from iceberg_scan.table_ref import iceberg_arrow_type

var refused_v3 = False
try:
    _ = parse_iceberg_metadata('{"format-version": 3}')
except e:
    refused_v3 = True
    assert_equal(
        String(e), "OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: format-version 3"
    )
assert_true(refused_v3)
var refused_type = False
try:
    _ = iceberg_arrow_type("uuid", "ref")
except e:
    refused_type = True
    assert_equal(
        String(e),
        "ICEBERG_TYPE_UNSUPPORTED: column 'ref' has the type 'uuid', which is not read yet",
    )
assert_true(refused_type)
```

## Tests

The tests are welded into the build (`BUCK` says what each file proves). They
write small tables into the test's scratch directory: metadata, manifest lists
and manifests built by `table_fixture` in the layout Iceberg Java writes
(its Avro schemas, `["null", T]` unions, maps as arrays of key and value
records, deflate), data and Parquet delete files written by `parquet_writer`.
No test reads the network or a fixed path.

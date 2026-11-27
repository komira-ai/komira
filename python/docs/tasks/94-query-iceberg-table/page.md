# How do I query an Iceberg table?

Name the table's directory (or one of its `metadata.json` files) in SQL with `iceberg_scan('path')` and run the query with `Session.sql`; `snapshot_from_id = n` reads the table as of an older snapshot. A local table is read; a table of a catalog is not read yet.

<!-- include example.py -->
```python
import json
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira

# komira reads Iceberg tables and does not write them, so this program first
# writes a small one the way the Iceberg spec lays one out: Parquet data files,
# a manifest (Avro) listing them, a manifest list (Avro) per snapshot, and the
# table's metadata.json. A real table comes from Spark, Trino, pyiceberg or
# another engine: skip to "Query the table" below.


def varint(n):  # an Avro int or long: zig-zag, then 7 bits a byte
    n = (n << 1) ^ (n >> 63)
    out = bytearray()
    while n > 0x7F:
        out.append(n & 0x7F | 0x80)
        n >>= 7
    return bytes(out + bytes([n]))


def encode(schema, value):  # the Avro types the files below use
    if isinstance(schema, list):  # ["null", type]
        return varint(0) if value is None else varint(1) + encode(schema[1], value)
    if isinstance(schema, dict):  # a record
        return b"".join(encode(f["type"], value[f["name"]]) for f in schema["fields"])
    if schema == "string":
        return varint(len(value.encode())) + value.encode()
    return varint(value)  # int, long


def write_avro(path, schema, records, meta):  # an Avro container file, one block
    header = {"avro.schema": json.dumps(schema), "avro.codec": "null", **meta}
    body = b"".join(encode(schema, r) for r in records)
    sync = bytes(range(16))  # any 16 bytes, the same at the end of each block
    head = b"".join(encode("string", k) + encode("string", v) for k, v in header.items())
    path.write_bytes(b"Obj\x01" + varint(len(header)) + head + varint(0) + sync
                     + varint(len(records)) + varint(len(body)) + body + sync)
    return path.stat().st_size


def record(name, *fields):  # an Avro record of (name, type, Iceberg field id)
    return {"type": "record", "name": name,
            "fields": [{"name": n, "type": t, "field-id": i} for n, t, i in fields]}


DATA_FILE = record("r2", ("content", "int", 134), ("file_path", "string", 100),
                   ("file_format", "string", 101), ("partition", record("r102"), 102),
                   ("record_count", "long", 103), ("file_size_in_bytes", "long", 104))
ENTRY = record("manifest_entry", ("status", "int", 0), ("snapshot_id", ["null", "long"], 1),
               ("sequence_number", ["null", "long"], 3), ("data_file", DATA_FILE, 2))
MANIFEST = record("manifest_file", ("manifest_path", "string", 500), ("manifest_length", "long", 501),
                  ("partition_spec_id", "int", 502), ("content", "int", 517),
                  ("sequence_number", "long", 515), ("min_sequence_number", "long", 516),
                  ("added_snapshot_id", "long", 503), ("added_files_count", "int", 504),
                  ("existing_files_count", "int", 505), ("deleted_files_count", "int", 506),
                  ("added_rows_count", "long", 512), ("existing_rows_count", "long", 513),
                  ("deleted_rows_count", "long", 514))
SCHEMA = {"type": "struct", "schema-id": 0, "fields": [
    {"id": 1, "name": "city", "required": False, "type": "string"},
    {"id": 2, "name": "fare", "required": False, "type": "double"}]}

table = Path("trips").absolute()
(table / "data").mkdir(parents=True)
(table / "metadata").mkdir()
manifests, snapshots = [], []
for seq, rows in enumerate([{"city": ["Lima", "Oslo", "Lima"], "fare": [12.5, 30.0, 7.5]},
                            {"city": ["Oslo", "Pune"], "fare": [18.0, 4.0]}], start=1):
    snap = 1000 + seq  # one append per snapshot: a data file, its manifest, a list
    data = table / "data" / f"part-{seq}.parquet"
    pq.write_table(pa.table(rows, schema=pa.schema(
        [pa.field(f["name"], pa.string() if f["type"] == "string" else pa.float64(),
                  metadata={"PARQUET:field_id": str(f["id"])}) for f in SCHEMA["fields"]])), data)
    entry = {"status": 1, "snapshot_id": snap, "sequence_number": None, "data_file": {
        "content": 0, "file_path": data.as_uri(), "file_format": "PARQUET", "partition": {},
        "record_count": len(rows["city"]), "file_size_in_bytes": data.stat().st_size}}
    manifest = table / "metadata" / f"manifest-{seq}.avro"
    size = write_avro(manifest, ENTRY, [entry], {"schema": json.dumps(SCHEMA), "partition-spec": "[]",
                                                 "partition-spec-id": "0", "format-version": "2", "content": "data"})
    manifests.append({"manifest_path": manifest.as_uri(), "manifest_length": size, "partition_spec_id": 0,
                      "added_snapshot_id": snap, "added_files_count": 1, "existing_files_count": 0,
                      "deleted_files_count": 0, "content": 0, "sequence_number": seq, "min_sequence_number": seq,
                      "added_rows_count": len(rows["city"]), "existing_rows_count": 0, "deleted_rows_count": 0})
    listing = table / "metadata" / f"snap-{snap}.avro"
    write_avro(listing, MANIFEST, manifests, {"snapshot-id": str(snap), "sequence-number": str(seq),
                                              "format-version": "2"})
    snapshots.append({"snapshot-id": snap, "sequence-number": seq, "timestamp-ms": 1800000000000 + seq,
                      "manifest-list": listing.as_uri(), "summary": {"operation": "append"}, "schema-id": 0})
(table / "metadata" / "v1.metadata.json").write_text(json.dumps({
    "format-version": 2, "table-uuid": "8f4e6a3c-1b2d-4c5e-9f00-000000000094", "location": table.as_uri(),
    "last-sequence-number": 2, "last-updated-ms": 1800000000002, "last-column-id": 2,
    "schemas": [SCHEMA], "current-schema-id": 0, "partition-specs": [{"spec-id": 0, "fields": []}],
    "default-spec-id": 0, "last-partition-id": 999, "sort-orders": [{"order-id": 0, "fields": []}],
    "default-sort-order-id": 0, "snapshots": snapshots, "current-snapshot-id": 1002}))
(table / "metadata" / "version-hint.text").write_text("1")

# Query the table: iceberg_scan names the table's directory (or one of its
# metadata.json files) in the SQL; snapshot_from_id reads an older snapshot.
with komira.Session() as s:
    by_city = s.sql("SELECT city, count(*) AS trips, sum(fare) AS total FROM iceberg_scan('trips') "
                    "GROUP BY city ORDER BY city")
    for row in by_city.to_arrow().to_pylist():
        print(row)
    first = s.sql("SELECT count(*) AS trips FROM iceberg_scan('trips', snapshot_from_id = 1001)")
    print(first.to_arrow().to_pylist())
    try:
        s.sql("SELECT count(*) FROM iceberg_scan('trips', snapshot_from_id = 7)")
    except komira.KomiraError as e:
        print(type(e).__name__, e.code)
```

Output:

<!-- include expected_output.txt -->
```text
{'city': 'Lima', 'trips': 2, 'total': 20.0}
{'city': 'Oslo', 'trips': 2, 'total': 48.0}
{'city': 'Pune', 'trips': 1, 'total': 4.0}
[{'trips': 3}]
BindError ICEBERG_SNAPSHOT_NOT_FOUND
```

## Notes

- The first part of the program writes a two-snapshot table because komira does not write Iceberg tables; with a table another engine wrote, the program is the last block alone.
- `iceberg_scan('path')` takes a table directory, read through its `metadata/version-hint.text`, or a `*.metadata.json` file. The answers are DuckDB's for the same table and query: position and equality deletes apply, and a filter on a partition column or a column's bounds skips the files it cannot match.
- `allow_moved_paths = true` reads a table copied away from the location its metadata records (DuckDB's option of the same name). Without it, a table whose files are not where its manifests say fails when the query runs, with `ICEBERG_MANIFEST_INVALID`.
- `snapshot_from_id = n` reads snapshot `n`; an id the table does not have raises `BindError` with the code `ICEBERG_SNAPSHOT_NOT_FOUND`, as the last line shows. A path with no table raises `BindError` (`ICEBERG_METADATA_INVALID`), and a directory without `metadata/version-hint.text` does too (`ICEBERG_TABLE_VERSION_UNKNOWN`: name the `.metadata.json` file instead). Each error's `code` is the engine's `ICEBERG_*` name.
- Only local files are read: a bare path or a `file:` URI. An `s3://` or other location raises `BindError` (`ICEBERG_PATH_UNSUPPORTED`).
- Columns of type boolean, int, long, float, double, string, date, timestamp, timestamptz and decimal are read; a table with another type (binary, uuid, fixed, time, struct, list, map) is refused, naming the column (`ICEBERG_TYPE_UNSUPPORTED`). Format versions 1 and 2 are read; version 3 is refused.
- Not read yet: a table of an Iceberg REST catalog, by its name as `catalog.namespace.table` with `komira.iceberg(...)` and `Session.add_sql_binding` (komira-ai/komira#2481). `probe_catalog.py` beside this page tries it and must fail with the line in its `.error.txt` file. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- There is no DataFrame reader of an Iceberg table yet; run `iceberg_scan` through `Session.sql` and use `.to_arrow()`, or another output of a `Result`.

## Related

- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
- [How do I read Parquet or CSV files from S3?](../31-read-parquet-csv-files-s3/page.md) (rank 31, partial)
- [How do I run SQL on a CSV or Parquet file (or a DataFrame)?](../37-run-sql-csv-parquet-file/page.md) (rank 37, partial)
- [How do I read files from Google Cloud Storage or Azure Blob?](../93-read-files-google-cloud-storage-azure/page.md) (rank 93, partial)

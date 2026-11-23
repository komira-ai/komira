# komira_iceberg_test_tables

Test-only. Writes version-2 Iceberg tables to a local directory **the way
Iceberg Java lays one out**, so a reader tested on them is tested on the
shape a foreign writer produces, not on the shape of komira's own writer
([`src/iceberg`](../../../iceberg/README.md)).

| what | how it is laid out |
|---|---|
| `metadata/v<N>.metadata.json`, `metadata/version-hint.text` | one metadata file per commit, pretty-printed (`"key" : value`), with `refs.main`, every snapshot (summary, `manifest-list`), a snapshot log and a metadata log; the hint holds `N` with no newline |
| `metadata/snap-<id>-1-<uuid>.avro` | a snapshot's manifest list: Avro, deflate, the `manifest_file` record with field ids, a `partitions` summary per partition field, `snapshot-id`, `parent-snapshot-id` (the text `null` for none), `sequence-number` and `format-version` in the header |
| `metadata/<uuid>-m0.avro` | a manifest: Avro, deflate, Java's `manifest_entry` / `r2` / `r102` schemas (`field-id` attributes, every optional field a `["null", T]` union, a field-id-keyed map as an array of `{key, value}` records), `schema`, `schema-id`, `partition-spec`, `partition-spec-id`, `format-version` and `content` in the header |
| `data/<col>=<value>/<name>.parquet` | a data file or a delete file, written by `parquet_writer` (or `avro`: `.avro`) |

Every path a manifest records is `<location>/<path under the root>`: an
absolute `file:` URI under the table's recorded location, which is not where
the files are. A test that reads the table from where it is reads it as a
moved table.

A manifest entry is what Java writes. An ADDED entry leaves `sequence_number`
and `file_sequence_number` null (they are inherited from the manifest list); an
EXISTING or DELETED one states them. A data file records `value_counts`,
`null_value_counts`, `nan_value_counts` (doubles only), `lower_bounds`,
`upper_bounds` (single-value serialization, no NaN, exact strings) and
`split_offsets`; a delete file none of the maps; an equality delete its
`equality_ids`; a position delete, when asked, the one `referenced_data_file`.
Every partition field is a nullable union.

Every column of a Parquet file carries its Iceberg field id as its Parquet
field id, as Iceberg Java, Spark and pyiceberg write their files (a position
delete file's `file_path` and `pos` carry the reserved ids 2147483546 and
2147483545). The metadata also holds `schema.name-mapping.default`.

## Writing a table

`TestTable(root, location, columns, partition_by)` writes under the local
directory `root` and records paths under `location`. Partitioning is the
identity of the named long, int, date or string columns. Each commit adds a
snapshot (id `SNAPSHOT_ID_BASE + n`, sequence number `n`; `snapshot_id(n)`)
and a metadata version, and lists its new manifests before the previous
snapshot's:

| method | commit |
|---|---|
| `append(files)` | a manifest of `TestDataFile`s, ADDED |
| `add_position_deletes(name, partition, deletes, file_format, referenced)` | one position-delete file (Parquet or `"AVRO"`), its rows sorted by path then position |
| `add_equality_deletes(name, partition, columns, rows, file_format)` | one equality-delete file of the named table columns |
| `overwrite(removed, added)` | each manifest holding a removed data file is rewritten (the file DELETED, the others EXISTING with their own sequence numbers), then a manifest of the added files |
| `create()` | a table with no snapshot (version 1) |

```text
var table = TestTable(root, "file:///warehouse/db/orders", columns, ["region"])
table.append([TestDataFile("a1", [string_cell("east")], rows)])
table.add_position_deletes("pos_1", [string_cell("east")], [PositionDelete("a1", 1)])
table.overwrite(["a1"], [TestDataFile("a2", [string_cell("east")], more_rows)])
```

`orders_fixture.mojo` writes the table `orders` of
[`komira_iceberg_scan_conformance`](../../conformance/komira_iceberg_scan_conformance/README.md)
(six commits: two appends, a position delete, an equality delete older than
a later append that reinserts a deleted key, an overwrite that marks a data
file DELETED), and lists its files (`orders_files()`), which a build rule names
as the outputs of the program that writes it.

## Bounds and counts

The single-value serialization of a bound, and the counts of a column of rows,
are plain functions:

```mojo
from komira_iceberg_test_tables.metrics import column_metrics, single_value_bytes
from komira_iceberg_test_tables.table_model import (
    TT_LONG,
    TableCell,
    TableColumn,
    TableRow,
    int_cell,
    null_cell,
)
from std.testing import assert_equal, assert_true

var cells = List[TableCell]()
cells.append(int_cell(300))
cells.append(null_cell())
cells.append(int_cell(-2))
var rows = List[TableRow]()
for i in range(len(cells)):
    var one = List[TableCell]()
    one.append(cells[i].copy())
    rows.append(TableRow(one^))
var m = column_metrics(TableColumn(1, "n", TT_LONG, False), rows, 0)
assert_equal(Int(m.value_count), 3)
assert_equal(Int(m.null_count), 1)
assert_true(m.has_bounds)
# 8 bytes, little-endian two's complement: -2 is the lower bound, 300 the upper.
assert_equal(Int(m.lower[0]), 254)
assert_equal(Int(m.upper[0]), 44)
assert_equal(Int(m.upper[1]), 1)
assert_equal(len(single_value_bytes(TT_LONG, int_cell(7))), 8)
```

## Errors

A refusal is an `Error` whose message names the call, e.g.
`TestTable.overwrite: a is not a live data file of the table`,
`TestTable: the file name f1 is used twice`,
`komira_iceberg_test_tables: a partition column is a long, an int, a date or a string, not type 3`.

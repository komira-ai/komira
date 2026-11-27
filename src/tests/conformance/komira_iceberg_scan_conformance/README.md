# komira_iceberg_scan_conformance

Test-only. `iceberg_scan` through `run_sql`, held to the answers of the pinned
DuckDB's Iceberg extension over one table written the way Iceberg Java
writes one. No library depends on this package; the Python test
`//python/tests:iceberg_scan_test` stages its table, `oracle/cases.sql` and
`:answers` and runs the same cases through `Session.sql`.

```sql
SELECT region, count(*) AS n
FROM iceberg_scan('orders', allow_moved_paths = true, snapshot_from_id = 6000000005)
GROUP BY region ORDER BY region
```

## The table

`orders` is written by [`komira_iceberg_test_tables`](../../helpers/komira_iceberg_test_tables/README.md)
(`write_orders_fixture`) in six commits, partitioned by the identity of
`region`, its manifests recording `file:///warehouse/db/orders`, which is not
where the files are (hence `allow_moved_paths = true`):

| snapshot | commit | live rows after it |
|---|---|---|
| 6000000001 | append: east `a1` (4 rows), west `b1` (3), north `n1` (3) | 10 |
| 6000000002 | append: east `a2` (3) | 13 |
| 6000000003 | position deletes (east): `a1` position 1, `a2` position 2 | 11 |
| 6000000004 | equality delete on `order_id` (east): 3 and 6, older than any later file | 9 |
| 6000000005 | append: east `a3` (order 3 again, and 8): the equality delete does not apply to it | 11 |
| 6000000006 | overwrite: `b1` removed (its manifest rewritten, the file DELETED), west `b2` (2 rows) added | 10 |

Columns: `order_id` long, `qty` int, `region` string, `price` double (one NaN),
`ship_date` date (in 2027), `paid` boolean, `note` string (nullable, with
nulls).

## How it runs

- `:orders_writer` is the program (`runner/main.mojo`); `:orders_table` runs it
  as a build action, each file it writes a sub-target
  ([`orders_files.bzl`](orders_files.bzl) lists them);
- `:answers` runs [`oracle/cases.sql`](oracle/cases.sql) in the pinned DuckDB
  with `avro` and `iceberg` loaded (the `extensions` of `sql_oracle`,
  [tools/build/sql](../../../../tools/build/sql/README.md)) over the staged
  table: one `<case>.tsv` per line, each `COPY (SELECT ... ORDER BY ...)`;
- `tests/test_iceberg_scan_parity.mojo` runs each line through `run_sql` over
  the staged table (`'orders'` replaced by its path) and compares the rows with
  DuckDB's by value, then checks reading a metadata file path, an unknown
  snapshot (`ICEBERG_SNAPSHOT_NOT_FOUND`) and a moved table read without
  `allow_moved_paths`.

# How do I read a partitioned dataset and skip partitions you do not need?

Register the dataset by a glob over its files, or name the glob in `read_parquet`: the `key=value` directories become columns, and a `WHERE` on one of them leaves the other directories unread.

<!-- include example.py -->
```python
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira

# A Hive-partitioned dataset: one directory per yr and region.
parts = {
    (2028, "east"): ([1, 2], [120, 80]),
    (2028, "west"): ([3], [45]),
    (2029, "east"): ([4, 5], [200, 150]),
    (2029, "west"): ([6], [60]),
}
for (yr, region), (ids, amounts) in parts.items():
    folder = Path("sales") / f"yr={yr}" / f"region={region}"
    folder.mkdir(parents=True)
    pq.write_table(pa.table({"order_id": ids, "amount": amounts}), folder / "part-0.parquet")

with komira.Session() as s:
    # The glob finds every file; yr and region become columns.
    s.register_parquet("sales", "sales/**/*.parquet")

    # A WHERE on a partition column keeps only the matching directories.
    recent = s.sql("SELECT order_id, yr, region FROM sales WHERE yr = 2029 ORDER BY order_id")
    print(recent.to_arrow().to_pylist())

    per_region = s.sql(
        "SELECT region, count(*) AS n FROM sales WHERE yr = 2029 GROUP BY region ORDER BY region"
    )
    print(per_region.to_arrow().to_pylist())

    # The same without registering a table: name the glob in the query.
    root = Path("sales").resolve()
    every = s.sql(
        f"SELECT order_id, region FROM read_parquet('{root}/**/*.parquet', hive_partitioning = true)"
        " ORDER BY order_id"
    )
    print(every.to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'order_id': 4, 'yr': 2029, 'region': 'east'}, {'order_id': 5, 'yr': 2029, 'region': 'east'}, {'order_id': 6, 'yr': 2029, 'region': 'west'}]
[{'region': 'east', 'n': 2}, {'region': 'west', 'n': 1}]
[{'order_id': 1, 'region': 'east'}, {'order_id': 2, 'region': 'east'}, {'order_id': 3, 'region': 'west'}, {'order_id': 4, 'region': 'east'}, {'order_id': 5, 'region': 'east'}, {'order_id': 6, 'region': 'west'}]
```

## Notes

- The partition columns (`yr`, `region`) come after the data columns, typed from their values: whole numbers as integers, dates as dates, timestamps as timestamps, other text as strings.
- `register_parquet` also takes one directory (every Parquet file under it) or a glob such as `sales/yr=2029/*/*.parquet`; `hive_partitioning = false` in `read_parquet` leaves the key columns out.
- A glob that matches no file, and files whose schemas differ, are refused by name.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`.

## Related

- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
- [How do I read many files matching a pattern into one table?](../19-read-many-files-matching-pattern-table/page.md) (rank 19, partial)
- How do I read Parquet or CSV files from S3? (rank 31, gap; no page yet)
- How do I write a dataset partitioned by a column? (rank 97, gap; no page yet)

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

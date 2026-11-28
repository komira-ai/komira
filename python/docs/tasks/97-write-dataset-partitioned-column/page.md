# How do I write a dataset partitioned by a column?

Add `PARTITION_BY (<columns>)` to a `COPY` run through `Session.sql`: it writes one `column=value` directory per distinct value, one file in each, and returns the row count.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("sales.csv").write_text(
    "order_id,amount,year,month\n"
    "1,120,2027,1\n"
    "2,40,2027,2\n"
    "3,75,2028,1\n"
    "4,200,2027,1\n"
)

with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    # PARTITION_BY writes one directory per (year, month) pair, with one file in each.
    written = s.sql(
        "COPY (SELECT order_id, amount, year, month FROM sales ORDER BY order_id)"
        " TO 'sales_by_month' (FORMAT parquet, PARTITION_BY (year, month))"
    ).to_arrow()
    print("rows written:", written.column(0).to_pylist()[0])

    # The files, named relative to the directory.
    tree = Path("sales_by_month")
    for name in sorted(p.relative_to(tree).as_posix() for p in tree.rglob("*.parquet")):
        print(name)

    # Read the tree back: the year and month directories become columns again.
    s.register_parquet("back", "sales_by_month/**/*.parquet")
    print(s.sql("SELECT order_id, amount, year, month FROM back ORDER BY order_id").to_arrow().to_pylist())

    # A WHERE on a partition column reads only the matching directory.
    print(s.sql("SELECT order_id FROM back WHERE year = 2027 AND month = 1 ORDER BY order_id").to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
rows written: 4
year=2027/month=1/data_0.parquet
year=2027/month=2/data_0.parquet
year=2028/month=1/data_0.parquet
[{'order_id': 1, 'amount': 120, 'year': 2027, 'month': 1}, {'order_id': 2, 'amount': 40, 'year': 2027, 'month': 2}, {'order_id': 3, 'amount': 75, 'year': 2028, 'month': 1}, {'order_id': 4, 'amount': 200, 'year': 2027, 'month': 1}]
[{'order_id': 1}, {'order_id': 4}]
```

## Notes

- The tree is the one DuckDB's `COPY ... PARTITION_BY` writes: one directory level per listed column, in the list's order, and one file per directory named `data_0.parquet` (`data_0.csv`, `data_0.csv.gz` or `data_0.csv.zst` with `FORMAT csv`). `PARTITION_BY year` without parentheses names one column.
- The partition columns are not stored in the files; a reader takes them from the directory names. komira, DuckDB and pyarrow read the tree back with Hive partitioning (`read_parquet('<dir>/**/*.parquet', hive_partitioning = true)`, or `register_parquet` over the glob as above).
- A directory name is escaped as DuckDB escapes it: every byte but letters, digits and `- _ . ~` becomes `%XX` (`a/b` is `a%2Fb`). NULL is `__HIVE_DEFAULT_PARTITION__` and the empty string an empty name (`k=`). DuckDB and pyarrow read both back; komira's reader refuses a NULL or empty partition by name, as it did before this write existed.
- The target must not exist or be an empty directory; its parent directory must exist. A target that is a file or holds anything is refused with `COPY_TARGET_EXISTS`, and `OVERWRITE`, `OVERWRITE_OR_IGNORE`, `APPEND`, `WRITE_PARTITION_COLUMNS`, `FILE_SIZE_BYTES`, `PER_THREAD_OUTPUT` and `FILENAME_PATTERN` are refused by name. `FORMAT json` with `PARTITION_BY` is refused, as DuckDB refuses it.
- A partition column may be an integer, a boolean, a string, a date or a decimal. A float, timestamp or other column is refused with `COPY_TYPE_UNSUPPORTED` before anything is written. A column the query does not have is a `BindError`.
- The whole result is computed in memory and then grouped, as for a `COPY` to one file. Each file is written whole, but the tree is not written as one unit: a failure part way leaves the files written so far.
- The pandas-shaped `df.to_parquet(path, partition_cols=[...])` and `komira.pl`'s `sink_parquet(path, partition_by=...)` do not write a partitioned tree yet; they come in a later change, with the plan's write target carrying the partition columns. Today, write the tree with `COPY`.

## Related

- [How do I write a table to Parquet?](../27-write-table-parquet/page.md) (rank 27, works)
- [How do I read a partitioned dataset and skip partitions you do not need?](../98-read-partitioned-dataset-skip-partitions-need/page.md) (rank 98, works)
- [How do I write a table to a CSV file?](../11-write-table-csv-file/page.md) (rank 11, partial)

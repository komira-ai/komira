# How do I read a Parquet file?

Register the file with `Session.register_parquet` (or name it in SQL with `read_parquet('file')`), or read it as a pandas-shaped frame with `komira.read_parquet`, or as a lazy polars-shaped frame with `komira.pl.scan_parquet`.

<!-- include example.py -->
```python
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira
import komira.pl as kpl

# A small Parquet file to read: a null in the file reads as NULL.
pq.write_table(
    pa.table(
        {
            "id": [3, 1, 2],
            "name": ["Cy", "Ana", "Bo"],
            "score": [None, 9.5, 7.0],
        }
    ),
    "people.parquet",
)

# SQL: register the file as a table, or name it in the query.
with komira.Session() as s:
    s.register_parquet("people", "people.parquet")
    print(s.sql("SELECT * FROM people ORDER BY id").to_arrow().to_pylist())
    print(s.sql("SELECT name FROM read_parquet('people.parquet') ORDER BY name").to_arrow().to_pylist())
    print(s.sql("SELECT count(*) AS n FROM 'people.parquet'").to_arrow().to_pylist())

# pandas-shaped: komira.read_parquet reads the schema from the file's footer
# now and the rows when the frame runs.
df = komira.read_parquet(Path("people.parquet"))
print(df.columns)
print(df.dtypes["id"], df.dtypes["name"], df.dtypes["score"])
print(df[["id", "name"]].sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: scan_parquet is lazy; collect() runs it.
lf = kpl.scan_parquet("people.parquet")
print(lf.select("id", "score").sort("id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'Ana', 'score': 9.5}, {'id': 2, 'name': 'Bo', 'score': 7.0}, {'id': 3, 'name': 'Cy', 'score': None}]
[{'name': 'Ana'}, {'name': 'Bo'}, {'name': 'Cy'}]
[{'n': 3}]
['id', 'name', 'score']
int64 string float64
[{'id': 1, 'name': 'Ana'}, {'id': 2, 'name': 'Bo'}, {'id': 3, 'name': 'Cy'}]
[{'id': 1, 'score': 9.5}, {'id': 2, 'score': 7.0}, {'id': 3, 'score': None}]
```

## Notes

- The file's footer gives the column names and types when you register or read it, so a missing or unreadable file fails there; the rows are read when a query or frame runs.
- A null in the file reads as NULL (`None` in Python).
- In SQL, `FROM read_parquet('file')` and `FROM 'file.parquet'` both work without registering; `parquet_scan(...)` is not supported.
- `komira.read_parquet` takes a path and `session` only: there is no `columns=` argument, so select columns on the frame afterwards (`df[["id", "name"]]`) as the example does.
- `komira.pl.scan_parquet` is lazy; there is no eager `komira.pl.read_parquet`, so call `.collect()`.
- Only local files are read here; URLs are tracked by komira-ai/komira#2345 (https) and komira-ai/komira#2337 (s3, gs, az).

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I read a JSON file and write the records to a database?](../22-read-json-file-write-records-database/page.md) (rank 22, partial)
- [How do I read many files matching a pattern into one table?](../19-read-many-files-matching-pattern-table/page.md) (rank 19, partial)
- [How do I look at the first rows, row count and columns of a dataset?](../5-look-at-first-rows-and-columns/page.md) (rank 5, works)

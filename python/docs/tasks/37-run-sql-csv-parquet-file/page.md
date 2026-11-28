# How do I run SQL on a CSV or Parquet file (or a DataFrame)?

Name the file in `FROM` (`FROM 'sales.csv'`, `read_csv`, `read_parquet`) or register it with `Session.register_csv` / `register_parquet`, register a DataFrame or an Arrow table with `Session.register(name, obj)`, and run the SQL with `Session.sql`.

<!-- include example.py -->
```python
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira

# A CSV file and a Parquet file to query.
Path("sales.csv").write_text(
    "id,region,amount\n"
    "1,east,120\n"
    "2,west,80\n"
    "3,east,45\n"
    "4,north,200\n"
    "5,west,150\n"
)
targets = pa.table({"region": ["east", "west", "north"], "target": [100, 100, 150]})
pq.write_table(targets, "targets.parquet")

with komira.Session() as s:
    # SQL straight on a file: the path in FROM, or read_csv / read_parquet.
    by_region = s.sql(
        "SELECT region, count(*) AS orders, max(amount) AS biggest, avg(amount) AS mean"
        " FROM 'sales.csv' GROUP BY region ORDER BY region"
    )
    for row in by_region.to_arrow().to_pylist():
        print(row)
    print(s.sql("SELECT * FROM read_parquet('targets.parquet') ORDER BY region").to_arrow().to_pylist())

    # Register the files as tables to join them.
    s.register_csv("sales", "sales.csv")
    s.register_parquet("targets", "targets.parquet")
    over = s.sql(
        "SELECT s.id AS id, s.region AS region, s.amount AS amount, t.target AS target"
        " FROM sales AS s JOIN targets AS t ON s.region = t.region"
        " WHERE s.amount > t.target ORDER BY s.id"
    )
    print(over.to_arrow().to_pylist())

    # A DataFrame or an Arrow table in memory is a table once registered.
    df = komira.read_csv("sales.csv")
    s.register("big", df[df["amount"] > 100])
    print(s.sql("SELECT id, amount FROM big ORDER BY id").to_arrow().to_pylist())
    s.register("goals", targets)
    print(s.sql("SELECT region FROM goals WHERE target > 100").to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'region': 'east', 'orders': 2, 'biggest': 120, 'mean': 82.5}
{'region': 'north', 'orders': 1, 'biggest': 200, 'mean': 200.0}
{'region': 'west', 'orders': 2, 'biggest': 150, 'mean': 115.0}
[{'region': 'east', 'target': 100}, {'region': 'north', 'target': 150}, {'region': 'west', 'target': 100}]
[{'id': 1, 'region': 'east', 'amount': 120, 'target': 100}, {'id': 4, 'region': 'north', 'amount': 200, 'target': 150}, {'id': 5, 'region': 'west', 'amount': 150, 'target': 100}]
[{'id': 1, 'amount': 120}, {'id': 4, 'amount': 200}, {'id': 5, 'amount': 150}]
[{'region': 'north'}]
```

## Notes

- `FROM '<path>'` picks the reader from the extension (`.csv`, `.parquet`, `.json`, `.jsonl` or `.ndjson`; any other extension, such as `.tsv` or `.csv.gz`, is refused by name, so spell the reader out) and names the table after the file, so `FROM 'sales.csv'` is also `sales`. `read_csv('<path>')`, `read_parquet('<path>')` and `read_json('<path>')` say the same by name; `read_parquet` also takes a glob.
- A registered table is the same file under a name you choose; use it when a query reads the file more than once or joins it with another.
- `AVG` over an integer column answers a float, and `MAX` an integer, as in the output above.
- `Session.register(name, obj)` takes a komira DataFrame or `komira.pl.LazyFrame` (its plan runs then), or any object with the Arrow C stream interface (`__arrow_c_stream__`): a `pyarrow.Table`, `RecordBatch` or `RecordBatchReader`, and a pandas or polars DataFrame, which have it too. It is DuckDB's `register(name, obj)`.
- The rows are copied when the call is made, and every query reads the copy: a change to the frame afterwards is not seen until it is registered again. A `pyarrow.RecordBatchReader` is read then, once, and its table answers every query; giving the same reader to `register` again is refused by name.
- Registering a name again replaces its table, of any kind, as DuckDB's `register` does. A column of a nested type (a list, a struct, a map) is refused by name: `UnsupportedOperation` with the code `TABLE_TYPE_UNSUPPORTED`.
- DuckDB also finds a frame by its Python variable name (`SELECT * FROM df` with no `register`); komira does not, and that query fails as an unknown table: register the frame first. komira-ai/komira#2391 tracks it.
- Parquet objects on `s3://` and Azure Blob are bound to a name with `Session.add_sql_binding` and `komira.files` ([rank 31](../31-read-parquet-csv-files-s3/page.md)); a URL written in the SQL text, `gs://` and `https://` are not read yet: komira-ai/komira#2337 and komira-ai/komira#2345.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
- [How do I join two tables on a key?](../10-join-two-tables-on-key/page.md) (rank 10, works)
- [How do I group by a column and sum another column?](../4-group-by-column-and-sum/page.md) (rank 4, works)
- [How do I write a table to Parquet?](../27-write-table-parquet/page.md) (rank 27, works)

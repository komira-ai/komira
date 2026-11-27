# How do I read many files matching a pattern into one table?

Put the pattern in the path: `register_parquet`, `register_csv` and `register_json` take `sales/sales_*.csv`, and so do SQL's `read_parquet`, `read_csv`, `read_json` and `FROM 'sales/sales_*.csv'`; the pandas- and polars-shaped readers take one file, so match the files with `pathlib` and `concat` them.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl
import pyarrow as pa
import pyarrow.parquet as pq

# One file per month in a folder, all with the same columns. A file that
# does not match the pattern sits beside them.
Path("sales").mkdir()
months = {"jan": [(1, "a", 2.5), (2, "b", 3.5)], "feb": [(3, "c", 1.5)], "mar": [(4, "d", 0.5), (5, "e", 4.5)]}
for month, rows in months.items():
    ids, names, amts = zip(*rows)
    table = pa.table({"id": list(ids), "name": list(names), "amt": list(amts)})
    pq.write_table(table, f"sales/sales_{month}.parquet")
    csv = "id,name,amt\n" + "".join(f"{i},{n},{a}\n" for i, n, a in rows)
    Path(f"sales/sales_{month}.csv").write_text(csv)
    lines = "".join(f'{{"id": {i}, "name": "{n}", "amt": {a}}}\n' for i, n, a in rows)
    Path(f"sales/sales_{month}.jsonl").write_text(lines)
pq.write_table(pa.table({"id": [9], "name": ["skip"], "amt": [9.0]}), "sales/notes.parquet")
Path("sales/notes.csv").write_text("note\nskip\n")

# The pattern goes in the path, for Parquet, CSV and JSON Lines alike, and the
# files it matches read as one table.
with komira.Session() as s:
    s.register_parquet("sales", "sales/sales_*.parquet")
    print(s.sql("SELECT * FROM sales ORDER BY id").to_arrow().to_pylist())
    both = s.sql("SELECT count(*) AS n, sum(amt) AS total FROM read_parquet('sales/sales_*.parquet')")
    print(both.to_arrow().to_pylist())

    s.register_csv("sales_csv", "sales/sales_*.csv")
    print(s.sql("SELECT * FROM sales_csv ORDER BY id").to_arrow().to_pylist())
    csv_sql = s.sql("SELECT count(*) AS n, sum(amt) AS total FROM read_csv('sales/sales_*.csv')")
    print(csv_sql.to_arrow().to_pylist())
    print(s.sql("SELECT max(id) AS last FROM 'sales/sales_*.csv' WHERE amt > 1").to_arrow().to_pylist())

    s.register_json("sales_json", "sales/sales_*.jsonl")
    print(s.sql("SELECT name FROM sales_json ORDER BY id").to_arrow().to_pylist())

# The pandas- and polars-shaped readers take one file: match the files with
# pathlib, then concat.
files = sorted(Path("sales").glob("sales_*.csv"))
df = komira.concat([komira.read_csv(str(f)) for f in files])
print(df.sort_values("id").materialize().to_arrow().to_pylist())

lf = pl.concat([pl.scan_csv(str(f)) for f in files])
print(lf.sort("id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'a', 'amt': 2.5}, {'id': 2, 'name': 'b', 'amt': 3.5}, {'id': 3, 'name': 'c', 'amt': 1.5}, {'id': 4, 'name': 'd', 'amt': 0.5}, {'id': 5, 'name': 'e', 'amt': 4.5}]
[{'n': 5, 'total': 12.5}]
[{'id': 1, 'name': 'a', 'amt': 2.5}, {'id': 2, 'name': 'b', 'amt': 3.5}, {'id': 3, 'name': 'c', 'amt': 1.5}, {'id': 4, 'name': 'd', 'amt': 0.5}, {'id': 5, 'name': 'e', 'amt': 4.5}]
[{'n': 5, 'total': 12.5}]
[{'last': 5}]
[{'name': 'a'}, {'name': 'b'}, {'name': 'c'}, {'name': 'd'}, {'name': 'e'}]
[{'id': 1, 'name': 'a', 'amt': 2.5}, {'id': 2, 'name': 'b', 'amt': 3.5}, {'id': 3, 'name': 'c', 'amt': 1.5}, {'id': 4, 'name': 'd', 'amt': 0.5}, {'id': 5, 'name': 'e', 'amt': 4.5}]
[{'id': 1, 'name': 'a', 'amt': 2.5}, {'id': 2, 'name': 'b', 'amt': 3.5}, {'id': 3, 'name': 'c', 'amt': 1.5}, {'id': 4, 'name': 'd', 'amt': 0.5}, {'id': 5, 'name': 'e', 'amt': 4.5}]
```

## Notes

- A pattern takes `*` and `?` within a folder, `[...]`, `{a,b}`, and one `**` that matches the folder and every folder below it (`ds/**/*.csv`). The files are listed in sorted order of their paths (the rows come in no promised order, so sort before printing), and a name starting with `.` is matched only by a pattern that spells the `.`.
- A pattern that matches nothing is refused by name: `CSV_GLOB_NO_MATCH`, `JSON_GLOB_NO_MATCH` or `PARQUET_GLOB_NO_MATCH`, with the pattern.
- The types are inferred from every file. CSV files must have the same columns in the same order, else `CSV_FILES_SCHEMA_MISMATCH` names the file and how it differs; a column that is BIGINT in one file and DOUBLE in another reads as DOUBLE, and any other two types read as VARCHAR. JSON Lines files may have different keys: the table has the keys of all of them, and a file without a key reads it as NULL. One key with two types other than BIGINT and DOUBLE is `JSON_FILES_SCHEMA_MISMATCH`. Parquet files must have the same schema.
- A Parquet folder of Hive-style `key=value` directories registered by its name reads as one table with the keys as columns. A bare folder in `read_parquet(...)` in SQL is refused and names the glob to use.
- The pandas-shaped `komira.read_parquet` and `komira.read_csv`, and the polars-shaped `scan_parquet` and `scan_csv`, take one file and no pattern: komira-ai/komira#2386. The rows of a `concat` have no promised order, so sort before printing.
- A list of paths, `read_csv(['a.csv', 'b.csv'])`, is refused and names the pattern form. A column holding the name of the file each row came from (DuckDB's `filename=true`) and `union_by_name=true` are refused by name.
- A pattern over the Parquet objects of an `s3://` or `az://` location is bound with `Session.add_sql_binding` and `komira.files` ([rank 31](../31-read-parquet-csv-files-s3/page.md)); `gs://`, and a pattern written in the SQL text, are tracked by komira-ai/komira#2337.
- `komira.concat` is newer than the PyPI release 0.1.1623.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
- [How do I concatenate (stack) tables with the same columns?](../18-concatenate-tables-same-columns/page.md) (rank 18, works)
- [How do I convert a folder of CSV files to Parquet?](../99-convert-folder-csv-files-parquet/page.md) (rank 99, works)

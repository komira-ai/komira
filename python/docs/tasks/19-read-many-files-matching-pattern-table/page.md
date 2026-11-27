# How do I read many files matching a pattern into one table?

For Parquet, put the pattern in the path (`register_parquet("sales", "sales/sales_*.parquet")` or `read_parquet('...')` in SQL); for CSV, match the files with `pathlib` and stack them with `UNION ALL`, `komira.concat` or `komira.pl.concat`.

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
pq.write_table(pa.table({"id": [9], "name": ["skip"], "amt": [9.0]}), "sales/notes.parquet")

# Parquet and SQL: the pattern goes in the path, and the files read as one table.
with komira.Session() as s:
    s.register_parquet("sales", "sales/sales_*.parquet")
    print(s.sql("SELECT * FROM sales ORDER BY id").to_arrow().to_pylist())
    both = s.sql("SELECT count(*) AS n, sum(amt) AS total FROM read_parquet('sales/sales_*.parquet')")
    print(both.to_arrow().to_pylist())

# CSV has no pattern yet: Python matches the files, komira reads each one.
files = sorted(Path("sales").glob("sales_*.csv"))
print(len(files), "csv files")

# SQL: register each file, then stack them with UNION ALL.
with komira.Session() as s:
    for i, f in enumerate(files):
        s.register_csv(f"part{i}", str(f))
    stacked = " UNION ALL ".join(f"SELECT * FROM part{i}" for i in range(len(files)))
    print(s.sql(f"SELECT * FROM ({stacked}) ORDER BY id").to_arrow().to_pylist())

# pandas-shaped: read each file, then concat.
df = komira.concat([komira.read_csv(str(f)) for f in files])
print(df.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: scan each file lazily, then concat.
lf = pl.concat([pl.scan_csv(str(f)) for f in files])
print(lf.sort("id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'a', 'amt': 2.5}, {'id': 2, 'name': 'b', 'amt': 3.5}, {'id': 3, 'name': 'c', 'amt': 1.5}, {'id': 4, 'name': 'd', 'amt': 0.5}, {'id': 5, 'name': 'e', 'amt': 4.5}]
[{'n': 5, 'total': 12.5}]
3 csv files
[{'id': 1, 'name': 'a', 'amt': 2.5}, {'id': 2, 'name': 'b', 'amt': 3.5}, {'id': 3, 'name': 'c', 'amt': 1.5}, {'id': 4, 'name': 'd', 'amt': 0.5}, {'id': 5, 'name': 'e', 'amt': 4.5}]
[{'id': 1, 'name': 'a', 'amt': 2.5}, {'id': 2, 'name': 'b', 'amt': 3.5}, {'id': 3, 'name': 'c', 'amt': 1.5}, {'id': 4, 'name': 'd', 'amt': 0.5}, {'id': 5, 'name': 'e', 'amt': 4.5}]
[{'id': 1, 'name': 'a', 'amt': 2.5}, {'id': 2, 'name': 'b', 'amt': 3.5}, {'id': 3, 'name': 'c', 'amt': 1.5}, {'id': 4, 'name': 'd', 'amt': 0.5}, {'id': 5, 'name': 'e', 'amt': 4.5}]
```

## Notes

- A Parquet pattern works in SQL and in `register_parquet`: `*` matches within a folder and `**` matches folders below it (`ds/**/*.parquet`), and `FROM 'sales/*.parquet'` works too. A folder of Hive-style `key=value` directories registered by its name reads as one table with the keys as columns. A bare folder in `read_parquet(...)` in SQL is refused and names the glob to use.
- CSV and JSON Lines take no pattern today: `register_csv`, `register_json` and SQL `read_csv('sales/sales_*.csv')` read one file, and a pattern fails as a missing file. DuckDB reads the whole set: komira-ai/komira#2385.
- The pandas-shaped `komira.read_parquet` and `komira.read_csv`, and the polars-shaped `scan_parquet` and `scan_csv`, take one file and no pattern, for Parquet as well: komira-ai/komira#2386.
- `probe_glob_pattern.py` beside this page tries SQL `read_csv('sales/sales_*.csv')` and must fail with the line in `probe_glob_pattern.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- The files must have the same columns in the same types: `UNION ALL` and `concat` refuse a mismatch rather than fill it in. The rows of a `concat` have no promised order, so sort before printing.
- A list of paths, and a column holding the name of the file each row came from (DuckDB's `filename=true`), are not available: the second is refused by name.
- Patterns over `s3://`, `gs://` and `az://` URLs are tracked by komira-ai/komira#2337.
- `komira.concat` is newer than the PyPI release 0.1.1623.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
- [How do I concatenate (stack) tables with the same columns?](../18-concatenate-tables-same-columns/page.md) (rank 18, works)
- How do I convert a folder of CSV files to Parquet? (rank 99, works; no page yet)

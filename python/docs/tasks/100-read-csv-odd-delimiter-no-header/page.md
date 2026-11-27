# How do I read a CSV with an odd delimiter, no header or extra lines?

Name the delimiter, `register_csv(..., delimiter="|")` in SQL or `komira.read_csv(..., sep=";")` on the pandas-shaped frame; read a file with no header line with `register_csv(..., header=False)` or `komira.read_csv(..., header=None)`. Lines to skip above the header are not read yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira

# A pipe-separated file and a semicolon-separated one, each with a header line.
Path("orders.psv").write_text("id|name|qty\n1|Ana|3\n2|Bo|5\n")
Path("orders_eu.csv").write_text("id;name;qty\n3;Cy;7\n4;Di;2\n")

# SQL: name the delimiter when you register the file.
with komira.Session() as s:
    s.register_csv("orders", "orders.psv", delimiter="|")
    print(s.sql("SELECT * FROM orders ORDER BY id").to_arrow().to_pylist())

# pandas-shaped: sep= is the delimiter, as in pandas.
eu = komira.read_csv("orders_eu.csv", sep=";")
print(eu.sort_values("id").materialize().to_arrow().to_pylist())

# No header line: every line is a row, and the columns are named column0,
# column1, ... as DuckDB names them.
Path("scores.csv").write_text('1,Ana,3\n2,"Bo, Jr.",5\n')

with komira.Session() as s:
    s.register_csv("scores", "scores.csv", header=False)
    print(s.sql("SELECT * FROM scores ORDER BY column0").to_arrow().to_pylist())

bare = komira.read_csv("scores.csv", header=None)
print(bare.sort_values("column0").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'Ana', 'qty': 3}, {'id': 2, 'name': 'Bo', 'qty': 5}]
[{'id': 3, 'name': 'Cy', 'qty': 7}, {'id': 4, 'name': 'Di', 'qty': 2}]
[{'column0': 1, 'column1': 'Ana', 'column2': 3}, {'column0': 2, 'column1': 'Bo, Jr.', 'column2': 5}]
[{'column0': 1, 'column1': 'Ana', 'column2': 3}, {'column0': 2, 'column1': 'Bo, Jr.', 'column2': 5}]
```

## Notes

- A delimiter is one ASCII character: `|`, `;`, a tab, or any other single ASCII character. `read_csv` takes it as `sep=`, `register_csv` as `delimiter=`, and SQL's `read_csv('file', delim = ';')` as `delim`.
- A file with no header line: `register_csv(..., header=False)`, `komira.read_csv(..., header=None)` or SQL's `read_csv('file', header = false)` read every line as a row, and name the columns `column0`, `column1`, ... as DuckDB does (with eleven or more columns the index is padded to the same width: `column00`, `column01`, ..., `column10`). pandas would label them `0`, `1`, `2`; komira follows DuckDB's names, so the same SQL gives the same answer in both.
- Skipping lines above the header (DuckDB's `skip`, pandas' `skiprows`) is not read yet: SQL's `read_csv` refuses the `skip` option by name rather than ignore it, and `komira.read_csv` has no `skiprows`. `probe_skip_lines.py` tries it and must fail with the line in `probe_skip_lines.error.txt`. komira-ai/komira#2365 tracks it.
- The day the probe runs to the end, this page's check goes red, and the page and the catalogue status change with it.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I run SQL on a CSV or Parquet file (or a DataFrame)?](../37-run-sql-csv-parquet-file/page.md) (rank 37, partial)
- [How do I process a CSV that does not fit in memory?](../28-process-csv-larger-than-memory/page.md) (rank 28, partial)
- [How do I read many files matching a pattern into one table?](../19-read-many-files-matching-pattern-table/page.md) (rank 19, partial)

# How do I remove duplicate rows?

Use `SELECT DISTINCT` in SQL, `drop_duplicates()` on the pandas-shaped frame or `unique()` on the polars-shaped one. To keep one whole row per value of some columns, use `SELECT DISTINCT ON (...)` or `QUALIFY row_number() OVER (...) = 1` in SQL, or `drop_duplicates(subset=[...])` on the pandas-shaped frame or `unique(subset=...)` on the polars-shaped one.

<!-- include example.py -->
```python
from pathlib import Path

import komira
from komira import pl

Path("people.csv").write_text(
    "id,name,city\n"
    "1,Ana,Oslo\n"
    "2,Bo,Rome\n"
    "1,Ana,Oslo\n"
    "3,Cy,Oslo\n"
    "2,Bo,Rome\n"
    "4,Ana,Lima\n"
)

# SQL: DISTINCT drops rows equal on every column.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    print(s.sql("SELECT DISTINCT id, name, city FROM people ORDER BY id").to_arrow().to_pylist())

    # One row per name: DISTINCT ON keeps the first row of each name under
    # ORDER BY, here the highest id.
    latest = s.sql(
        "SELECT DISTINCT ON (name) id, name, city FROM people ORDER BY name, id DESC"
    )
    print(latest.to_arrow().to_pylist())

    # Or number the rows of each name and keep number 1 with QUALIFY, a filter
    # over a window function's result.
    first = s.sql(
        "SELECT id, name, city FROM people"
        " QUALIFY row_number() OVER (PARTITION BY name ORDER BY id) = 1 ORDER BY id"
    )
    print(first.to_arrow().to_pylist())

# pandas-shaped: drop_duplicates() on whole rows; keep=False drops every copy.
df = komira.read_csv("people.csv")
print(df.drop_duplicates().sort_values("id").materialize().to_arrow().to_pylist())
print(df.drop_duplicates(keep=False).sort_values("id").materialize().to_arrow().to_pylist())

# One whole row per name: subset= compares only the named columns. Any one row
# of each name is kept (a plan has no row order), so print the names and columns.
one = df.drop_duplicates(subset=["name"]).sort_values("name").materialize().to_arrow().to_pylist()
print([r["name"] for r in one], list(one[0]))

# keep=False keeps the rows whose name no other row has; duplicated() marks rows.
print(df.drop_duplicates(subset=["name"], keep=False).materialize().to_arrow().to_pylist())
print(df[df.duplicated("name", keep=False)].sort_values("id").materialize().to_arrow().to_pylist())

# Only the names: select the column first.
print(df[["name"]].drop_duplicates().sort_values("name").materialize().to_arrow().to_pylist())

# polars-shaped: unique() on whole rows, or on a subset of columns.
lf = pl.scan_csv("people.csv")
print(lf.unique().sort("id").collect().to_arrow().to_pylist())
print(lf.unique(subset=["name"]).select("name").sort("name").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'Ana', 'city': 'Oslo'}, {'id': 2, 'name': 'Bo', 'city': 'Rome'}, {'id': 3, 'name': 'Cy', 'city': 'Oslo'}, {'id': 4, 'name': 'Ana', 'city': 'Lima'}]
[{'id': 4, 'name': 'Ana', 'city': 'Lima'}, {'id': 2, 'name': 'Bo', 'city': 'Rome'}, {'id': 3, 'name': 'Cy', 'city': 'Oslo'}]
[{'id': 1, 'name': 'Ana', 'city': 'Oslo'}, {'id': 2, 'name': 'Bo', 'city': 'Rome'}, {'id': 3, 'name': 'Cy', 'city': 'Oslo'}]
[{'id': 1, 'name': 'Ana', 'city': 'Oslo'}, {'id': 2, 'name': 'Bo', 'city': 'Rome'}, {'id': 3, 'name': 'Cy', 'city': 'Oslo'}, {'id': 4, 'name': 'Ana', 'city': 'Lima'}]
[{'id': 3, 'name': 'Cy', 'city': 'Oslo'}, {'id': 4, 'name': 'Ana', 'city': 'Lima'}]
['Ana', 'Bo', 'Cy'] ['id', 'name', 'city']
[{'id': 3, 'name': 'Cy', 'city': 'Oslo'}]
[{'id': 1, 'name': 'Ana', 'city': 'Oslo'}, {'id': 1, 'name': 'Ana', 'city': 'Oslo'}, {'id': 2, 'name': 'Bo', 'city': 'Rome'}, {'id': 2, 'name': 'Bo', 'city': 'Rome'}, {'id': 4, 'name': 'Ana', 'city': 'Lima'}]
[{'name': 'Ana'}, {'name': 'Bo'}, {'name': 'Cy'}]
[{'id': 1, 'name': 'Ana', 'city': 'Oslo'}, {'id': 2, 'name': 'Bo', 'city': 'Rome'}, {'id': 3, 'name': 'Cy', 'city': 'Oslo'}, {'id': 4, 'name': 'Ana', 'city': 'Lima'}]
[{'name': 'Ana'}, {'name': 'Bo'}, {'name': 'Cy'}]
```

## Notes

- `SELECT DISTINCT`, `df.drop_duplicates()` and `lf.unique()` compare every column, so `keep="first"` and `keep="last"` return the same rows.
- `df.drop_duplicates(keep=False)` and `lf.unique(subset=[...], keep="none")` keep only the rows that no other row equals; `df.drop_duplicates(subset=[...], keep=False)` keeps the rows whose value of those columns no other row has.
- To keep one whole row per value of some columns, write `SELECT DISTINCT ON (cols) ... ORDER BY ...`: it keeps the first row of each value under the query's whole `ORDER BY`, as in DuckDB, and the `ORDER BY` need not begin with those columns. `QUALIFY row_number() OVER (PARTITION BY cols ORDER BY ...) = 1` does the same with the `ORDER BY` of the window choosing the row; QUALIFY filters after the window functions and before `DISTINCT`, `ORDER BY` and `LIMIT`, and may name a window written inline or a SELECT alias. Without an `ORDER BY`, DISTINCT ON keeps any one row of each value, as DuckDB does.
- `df.drop_duplicates(subset=[...])` and `lf.unique(subset=[...])` keep any one row of each value: pandas' `keep="first"` and `keep="last"` are accepted but do not pick the first or the last row, since a plan has no row order. To choose which row survives, use SQL `DISTINCT ON` or `QUALIFY` with an `ORDER BY`.
- `df.duplicated(subset, keep)` is a bool column of the frame for a filter or `assign`: `df[~df.duplicated("name")]` keeps one row of each name, as `drop_duplicates(subset=["name"])` does, though each may keep a different row of a name. `df["name"].unique()` is refused, since it gives an array of values; use `df[["name"]].drop_duplicates()` for the distinct values of a column.
- The columns of a `subset` of fewer than every column must be int64, int32, float64, bool or string, the types the engine's window sorts; a date or a timestamp there is refused when the plan runs. The same holds for the keys of `DISTINCT ON` and the `PARTITION BY` of a window.
- Also not available: polars `keep="first"` / `"last"` and `maintain_order=True` are refused because a plan has no row order.
- The result has no promised row order: sort it before printing.
- `lf.unique(subset=..., keep="none")`, `df.drop_duplicates(subset=[...])` of fewer than every column and `df.duplicated()` are newer than the PyPI release 0.1.1623.

## Related

- [How do I drop rows with missing values?](../7-drop-rows-missing-values/page.md) (rank 7, works)
- [How do I count how many times each value appears?](../9-count-each-value/page.md) (rank 9, works)
- [How do I concatenate (stack) tables with the same columns?](../18-concatenate-tables-same-columns/page.md) (rank 18, works)
- [How do I validate data: nulls, uniqueness, ranges?](../59-validate-data-nulls-uniqueness-ranges/page.md) (rank 59, works)

# How do I count the rows of a table?

Run `SELECT count(*)` in SQL; on a pandas-shaped frame use `df.agg(n=(column, "size"))`, and on a polars-shaped one `select(len())`.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

# An empty field reads as NULL.
Path("items.csv").write_text(
    "id,region,score\n"
    "1,east,9\n"
    "2,west,7\n"
    "3,east,\n"
    "4,north,5\n"
    "5,west,8\n"
)

# SQL: count(*) counts rows; count(column) counts the rows where it is not NULL.
with komira.Session() as s:
    s.register_csv("items", "items.csv")
    counts = s.sql("SELECT count(*) AS n, count(score) AS scored FROM items")
    print(counts.to_arrow().to_pylist())

# pandas-shaped: len(df) needs a query to run, so count with a "size" aggregate.
df = komira.read_csv("items.csv")
print(df.agg(n=("id", "size")).materialize().to_arrow().to_pylist())
print(df.groupby("region").size().materialize().to_arrow().to_pylist())

# polars-shaped: select(len()) is one row holding the count.
print(kpl.scan_csv("items.csv").select(kpl.len()).collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'n': 5, 'scored': 4}]
[{'n': 5}]
[{'region': 'east', 'size': 2}, {'region': 'north', 'size': 1}, {'region': 'west', 'size': 2}]
[{'len': 5}]
```

## Notes

- `count(*)` counts every row; `count(column)` skips the rows where the column is NULL, so the two differ when a column has gaps.
- A komira frame is a plan, not rows, so `len(df)` raises an error telling you to run a query, and `df.shape`, `df.size` and `df.empty` are refused the same way. Write `df.agg(n=(column, "size")).materialize()`: `"size"` counts rows, `"count"` skips missing values.
- Per group, `df.groupby(key).size()` gives the row count as a column named `size`, sorted by the key.
- `kpl.len()` is an `Int64` named `len`, where polars answers a `UInt32`.
- The count comes back as a one-row table, a list holding one dict such as `{'n': 5}`, so read `to_arrow().to_pylist()[0]["n"]` for the number.

## Related

- [How do I look at the first rows, row count and columns of a dataset?](../5-look-at-first-rows-and-columns/page.md) (rank 5, works)
- [How do I count how many times each value appears?](../9-count-each-value/page.md) (rank 9, works)
- How do I count rows per group? (rank 35, works; no page yet)
- How do I get the distinct values of a column? (rank 63, works)

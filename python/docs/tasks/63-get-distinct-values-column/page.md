# How do I get the distinct values of a column?

Use `SELECT DISTINCT column` (and `count(DISTINCT column)` for how many), or `drop_duplicates()` on a one-column pandas-shaped frame, or `unique()` on a polars-shaped one.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

Path("orders.csv").write_text(
    "order_id,customer,region\n"
    "1,Ana,east\n"
    "2,Bo,west\n"
    "3,Ana,east\n"
    "4,Cy,north\n"
    "5,Bo,west\n"
)

# SQL: DISTINCT for the values, count(DISTINCT ...) for how many there are.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    values = s.sql("SELECT DISTINCT region FROM orders ORDER BY region")
    print(values.to_arrow().to_pylist())
    how_many = s.sql("SELECT count(DISTINCT region) AS regions FROM orders")
    print(how_many.to_arrow().to_pylist())

# pandas-shaped: keep the column, drop its duplicate rows, sort for a stable order.
df = komira.read_csv("orders.csv")
regions = df[["region"]].drop_duplicates().sort_values("region")
print(regions.materialize().to_arrow().to_pylist())
print(df.agg(regions=("region", "nunique")).materialize().to_arrow().to_pylist())

# polars-shaped: unique and n_unique.
lf = pl.scan_csv("orders.csv")
print(lf.select("region").unique().sort("region").collect().to_arrow().to_pylist())
print(lf.select(pl.col("region").n_unique().alias("regions")).collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'region': 'east'}, {'region': 'north'}, {'region': 'west'}]
[{'regions': 3}]
[{'region': 'east'}, {'region': 'north'}, {'region': 'west'}]
[{'regions': 3}]
[{'region': 'east'}, {'region': 'north'}, {'region': 'west'}]
[{'regions': 3}]
```

## Notes

- A distinct has no promised row order: add `ORDER BY`, `sort_values` or `sort` before you rely on the order, as the example does.
- `drop_duplicates(subset=[...])` keeps whole rows, one for each value of the named columns. Select the column first, as `df[["region"]].drop_duplicates()`, to get the distinct values of one column or of a few.
- `Series.unique()` is refused by name and `Series.nunique()` does not exist: a column is not a list of values until it runs. Select it as a one-column frame (`df[["region"]]`) instead, and use `DataFrame.nunique()` or `agg(name=(column, "nunique"))` to count.
- `nunique` and `count(DISTINCT ...)` do not count NULL; polars-shaped `n_unique` counts a NULL as one value, as polars does. `nunique(dropna=False)` is refused.
- On the polars-shaped frame, `unique(keep="first")`, `keep="last"` and `maintain_order=True` are refused, since a plan has no row order; sort the result instead.

## Related

- How do I count the rows of a table? (rank 62, works)
- How do I find (not drop) duplicate rows? (rank 57, works; no page yet)
- How do I take the first or last N rows? (rank 65, works)
- How do I validate data: nulls, uniqueness, ranges? (rank 59, works; no page yet)

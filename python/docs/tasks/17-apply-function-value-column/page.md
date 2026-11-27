# How do I apply a function to every value in a column?

Write the function as an expression over the column: a built-in SQL function in `SELECT`, arithmetic and `.str` methods on a pandas-shaped Series, or expressions in `with_columns` on the polars-shaped frame. A Python function of your own (`Series.apply`, `map_elements`) is not available yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

Path("items.csv").write_text("name,price,qty\nana,10.5,4\nbo,3.25,9\ncy,8,16\n")

# SQL: a function of a column is an expression in SELECT.
with komira.Session() as s:
    s.register_csv("items", "items.csv")
    out = s.sql(
        "SELECT name, upper(name) AS shout, sqrt(qty) AS root,"
        " price * 2 AS double_price,"
        " CASE WHEN price > 5 THEN 'high' ELSE 'low' END AS band"
        " FROM items ORDER BY name"
    )
    for row in out.to_arrow().to_pylist():
        print(row)

# pandas-shaped: arithmetic and .str methods on a column, then assign.
df = komira.read_csv("items.csv")
df = df.assign(shout=df["name"].str.upper(), double_price=df["price"] * 2)
print(df.sort_values("name").materialize().to_arrow().to_pylist())

# polars-shaped: expressions in with_columns.
lf = pl.scan_csv("items.csv").with_columns(
    pl.col("name").str.to_uppercase().alias("shout"),
    (pl.col("price") * 2).alias("double_price"),
)
print(lf.sort("name").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'name': 'ana', 'shout': 'ANA', 'root': 2.0, 'double_price': 21.0, 'band': 'high'}
{'name': 'bo', 'shout': 'BO', 'root': 3.0, 'double_price': 6.5, 'band': 'low'}
{'name': 'cy', 'shout': 'CY', 'root': 4.0, 'double_price': 16.0, 'band': 'high'}
[{'name': 'ana', 'price': 10.5, 'qty': 4, 'shout': 'ANA', 'double_price': 21.0}, {'name': 'bo', 'price': 3.25, 'qty': 9, 'shout': 'BO', 'double_price': 6.5}, {'name': 'cy', 'price': 8.0, 'qty': 16, 'shout': 'CY', 'double_price': 16.0}]
[{'name': 'ana', 'price': 10.5, 'qty': 4, 'shout': 'ANA', 'double_price': 21.0}, {'name': 'bo', 'price': 3.25, 'qty': 9, 'shout': 'BO', 'double_price': 6.5}, {'name': 'cy', 'price': 8.0, 'qty': 16, 'shout': 'CY', 'double_price': 16.0}]
```

## Notes

- In SQL, the built-in scalar functions work as in DuckDB: `upper`, `lower`, `length`, `substr`, `replace`, `concat`, `abs`, `sqrt`, `power`, `exp`, `ln`, `floor`, `ceil`, `round(x)`, `CASE WHEN`, `CAST`, and arithmetic. Pick the one that does what your function does, and the engine runs it over every value.
- The pandas-shaped Series has arithmetic, comparisons, `astype`, `isin`, the `.str` and `.dt` accessors, and the cumulative and window verbs. The polars-shaped `Expr` has arithmetic, `abs`, `cast`, `fill_null`, `is_in`, `when/then/otherwise`, the `.str` namespace and the aggregate and window verbs.
- A Python function of your own over each value is not available. `Series.apply`, `Series.map` and `DataFrame.apply` do not exist, and nor does a public `udf` decorator: komira-ai/komira#2332. `probe_series_apply.py` beside this page tries `df["price"].apply(...)` and must fail with the line in `probe_series_apply.error.txt`.
- The polars-shaped `Expr.map_elements` does not exist either: komira-ai/komira#2384. `probe_polars_map_elements.py` must fail with the line in `probe_polars_map_elements.error.txt`.
- SQL cannot call a Python function: komira-ai/komira#2330.
- Some everyday functions have no method or no form yet: `round(x, digits)` in SQL is refused (only `round(x)` runs), and `Series.round`, `Series.abs` and `Expr.round` do not exist: komira-ai/komira#2383.
- The day a probe runs to the end, this page's check goes red, and the page and the catalogue status change with it.
- The `.str` accessor of the pandas-shaped Series is newer than the PyPI release 0.1.1623.

## Related

- [How do I change a column's data type?](../12-change-column-data-type/page.md) (rank 12, works)
- [How do I rename columns?](../16-rename-columns/page.md) (rank 16, works)
- [How do I add a new column computed from other columns?](../3-add-computed-column/page.md) (rank 3, works)

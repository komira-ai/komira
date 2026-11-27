# How do I add a new column computed from other columns?

Write the arithmetic as a `SELECT` expression with an alias, or pass a Series expression to `assign` (or `df["name"] = ...`) on a pandas-shaped frame, or an aliased expression to `with_columns` on a polars-shaped one.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

Path("orders.csv").write_text(
    "item,qty,spare,price\n"
    "pen,5,1,2.5\n"
    "ink,3,0,7.25\n"
    "pad,4,2,6.0\n"
)

# SQL: each computed column is an expression with an alias in SELECT.
# int + int is an int, int * float is a float, and / always gives a float.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    rows = s.sql(
        "SELECT item, qty + spare AS stock, price * qty AS total,"
        " (qty + spare) / 2 AS half FROM orders ORDER BY item"
    )
    for row in rows.to_arrow().to_pylist():
        print(row)

# pandas-shaped: assign(name=...) returns a new frame, and df["name"] = ...
# adds the column to the frame itself. Nothing runs until materialize().
df = komira.read_csv("orders.csv")
df = df.assign(stock=df["qty"] + df["spare"], total=df["price"] * df["qty"])
df["half"] = df["stock"] / 2
print(df.columns)
print(df.dtypes["stock"], df.dtypes["total"], df.dtypes["half"])
out = df[["item", "stock", "total", "half"]].sort_values("item")
print(out.materialize().to_arrow().to_pylist())

# polars-shaped: with_columns takes expressions named with alias.
lf = kpl.scan_csv("orders.csv").with_columns(
    (kpl.col("qty") + kpl.col("spare")).alias("stock"),
    (kpl.col("price") * kpl.col("qty")).alias("total"),
)
lf = lf.with_columns((kpl.col("stock") / 2).alias("half"))
out = lf.select("item", "stock", "total", "half").sort("item").collect()
print(out.to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'item': 'ink', 'stock': 3, 'total': 21.75, 'half': 1.5}
{'item': 'pad', 'stock': 6, 'total': 24.0, 'half': 3.0}
{'item': 'pen', 'stock': 6, 'total': 12.5, 'half': 3.0}
['item', 'qty', 'spare', 'price', 'stock', 'total', 'half']
int64 float64 float64
[{'item': 'ink', 'stock': 3, 'total': 21.75, 'half': 1.5}, {'item': 'pad', 'stock': 6, 'total': 24.0, 'half': 3.0}, {'item': 'pen', 'stock': 6, 'total': 12.5, 'half': 3.0}]
[{'item': 'ink', 'stock': 3, 'total': 21.75, 'half': 1.5}, {'item': 'pad', 'stock': 6, 'total': 24.0, 'half': 3.0}, {'item': 'pen', 'stock': 6, 'total': 12.5, 'half': 3.0}]
```

## Notes

- `+`, `-` and `*` of two int64 columns give int64; an int64 column with a float64 one gives float64. `/` is true division and always gives float64, as in Python: `3 / 2` is `1.5`, and `6 / 2` is `3.0`.
- `assign(name=value)` returns a new frame; `df["name"] = value` changes the frame itself. A name that is already a column is replaced in place, and a new name is added after the existing columns.
- `assign` takes a function too, called with the frame as the earlier keywords left it, so `df.assign(a=df["x"] + 1, b=lambda f: f["a"] * 2)` can use the column `a`.
- A value is a Series of the same frame or a single literal (`df["flag"] = 1`). A Series of another frame is refused, since a komira frame has no index to line two frames up by, and so is a Python list of values.
- A polars-shaped expression is named with `.alias("name")`; an expression with no alias is named after its leftmost column, so `kpl.col("qty") + 1` replaces `qty`. `with_columns` adds new names after the existing columns.
- The pandas-shaped and polars-shaped frames only plan the work: the rows are computed at `materialize()` and `collect()`. `columns` and `dtypes` of the pandas-shaped frame answer at once, without running anything.
- `df.eval(...)` and `df.query(...)` are refused, because komira does not parse an expression given as text; write the expression with Series, as above.

## Related

- [How do I select columns and filter rows?](../2-select-columns-filter-rows/page.md) (rank 2, works)
- How do I add a column with if/else (case when) logic? (rank 30, works; no page yet)
- [How do I change a column's data type?](../12-change-column-data-type/page.md) (rank 12, works)
- [How do I apply a function to every value in a column?](../17-apply-function-value-column/page.md) (rank 17, partial)

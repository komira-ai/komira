# How do I select or drop columns?

Name the columns you want: in `SELECT`, in a list of names on the pandas-shaped frame, or with `select` on the polars-shaped one. To drop columns, name the rest, or call `drop` on the polars-shaped frame.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

Path("orders.csv").write_text(
    "order_id,customer,region,amount,note\n"
    "1,Ana,east,120,gift\n"
    "2,Bo,west,80,rush\n"
    "3,Cy,north,200,gift\n"
)

# SQL: select the columns you want by name. To drop columns, name the others.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    kept = s.sql("SELECT order_id, customer, amount FROM orders ORDER BY order_id")
    print(kept.to_arrow().to_pylist())

# pandas-shaped: a list of names selects columns.
df = komira.read_csv("orders.csv")
print(df.columns)
picked = df[["order_id", "customer"]]
print(picked.sort_values("order_id").materialize().to_arrow().to_pylist())

# There is no df.drop: keep every column that is not in the list to drop.
dropped = df[[c for c in df.columns if c not in ("region", "note")]]
print(dropped.columns)
print(dropped.sort_values("order_id").materialize().to_arrow().to_pylist())

# polars-shaped: select keeps columns, drop removes them.
lf = kpl.scan_csv("orders.csv")
print(lf.select("order_id", "customer").sort("order_id").collect().to_arrow().to_pylist())
print(lf.drop("region", "note").sort("order_id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 2, 'customer': 'Bo', 'amount': 80}, {'order_id': 3, 'customer': 'Cy', 'amount': 200}]
['order_id', 'customer', 'region', 'amount', 'note']
[{'order_id': 1, 'customer': 'Ana'}, {'order_id': 2, 'customer': 'Bo'}, {'order_id': 3, 'customer': 'Cy'}]
['order_id', 'customer', 'amount']
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 2, 'customer': 'Bo', 'amount': 80}, {'order_id': 3, 'customer': 'Cy', 'amount': 200}]
[{'order_id': 1, 'customer': 'Ana'}, {'order_id': 2, 'customer': 'Bo'}, {'order_id': 3, 'customer': 'Cy'}]
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 2, 'customer': 'Bo', 'amount': 80}, {'order_id': 3, 'customer': 'Cy', 'amount': 200}]
```

## Notes

- SQL has no drop: list the columns to keep in `SELECT`. DuckDB's `SELECT * EXCLUDE (...)` is not parsed yet (komira-ai/komira#2390); `probe_sql_exclude.py` beside this page tries it and must fail with the line in `probe_sql_exclude.error.txt`.
- The pandas-shaped frame has no `drop` method (`df.drop(columns=[...])` raises `AttributeError`, komira-ai/komira#2390; `probe_pandas_drop.py` shows the line). Keep the columns you want with `df[[...]]`, as the example does with `df.columns`.
- `komira.pl` frames take `select("a", "b")` and `drop("a", "b")`; `drop` of a name the frame lacks raises `KeyError` unless you pass `strict=False`.
- Nothing runs until `materialize()` (pandas-shaped) or `collect()` (polars-shaped); both give a result you read with `to_arrow()`.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`. The example sorts by `order_id`, which every printed frame keeps.

## Related

- [How do I select columns and filter rows?](../2-select-columns-filter-rows/page.md) (rank 2, works)
- How do I add a new column computed from other columns? (rank 3, works; no page yet)
- How do I rename columns? (rank 16, works; no page yet)
- How do I reorder columns? (rank 66, works; no page yet)

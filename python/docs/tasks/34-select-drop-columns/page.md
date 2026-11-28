# How do I select or drop columns?

Name the columns you want: in `SELECT`, in a list of names on the pandas-shaped frame, or with `select` on the polars-shaped one. To drop columns, write `SELECT * EXCLUDE (...)` in SQL, or call `drop` on either frame.

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

# SQL: select the columns you want by name, or drop some with * EXCLUDE.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    kept = s.sql("SELECT order_id, customer, amount FROM orders ORDER BY order_id")
    print(kept.to_arrow().to_pylist())
    rest = s.sql("SELECT * EXCLUDE (region, note) FROM orders ORDER BY order_id")
    print(rest.to_arrow().to_pylist())

# pandas-shaped: a list of names selects columns, and drop removes them.
df = komira.read_csv("orders.csv")
print(df.columns)
picked = df[["order_id", "customer"]]
print(picked.sort_values("order_id").materialize().to_arrow().to_pylist())
dropped = df.drop(columns=["region", "note"])
print(dropped.columns)
print(dropped.sort_values("order_id").materialize().to_arrow().to_pylist())
print(df.drop(["note"], axis=1).columns)

# polars-shaped: select keeps columns, drop removes them.
lf = kpl.scan_csv("orders.csv")
print(lf.select("order_id", "customer").sort("order_id").collect().to_arrow().to_pylist())
print(lf.drop("region", "note").sort("order_id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 2, 'customer': 'Bo', 'amount': 80}, {'order_id': 3, 'customer': 'Cy', 'amount': 200}]
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 2, 'customer': 'Bo', 'amount': 80}, {'order_id': 3, 'customer': 'Cy', 'amount': 200}]
['order_id', 'customer', 'region', 'amount', 'note']
[{'order_id': 1, 'customer': 'Ana'}, {'order_id': 2, 'customer': 'Bo'}, {'order_id': 3, 'customer': 'Cy'}]
['order_id', 'customer', 'amount']
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 2, 'customer': 'Bo', 'amount': 80}, {'order_id': 3, 'customer': 'Cy', 'amount': 200}]
['order_id', 'customer', 'region', 'amount']
[{'order_id': 1, 'customer': 'Ana'}, {'order_id': 2, 'customer': 'Bo'}, {'order_id': 3, 'customer': 'Cy'}]
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 2, 'customer': 'Bo', 'amount': 80}, {'order_id': 3, 'customer': 'Cy', 'amount': 200}]
```

## Notes

- `SELECT * EXCLUDE (region, note)` is every column but those named, in the table's order, as in DuckDB; one name may go without the parentheses (`* EXCLUDE note`), and the names match in any case. A table-qualified star takes the list too: `SELECT o.* EXCLUDE (note) FROM orders AS o JOIN customers AS c ON ...`. Over a join, `* EXCLUDE (k)` drops the column `k` of both sides. A name the star does not have, and a list that names every column, are refused with a `BindError` naming them. DuckDB's `* REPLACE (...)` and `* RENAME (...)` are not built and are refused by name: write the column with its expression or `AS` instead.
- The pandas-shaped frame takes `df.drop(columns=[...])` and `df.drop([...], axis=1)`, a list or one name. A name the frame lacks raises `KeyError`, unless you pass `errors="ignore"`, which skips it. A komira frame has no index, so `drop` of row labels (`axis=0`, `index=`) raises `UnsupportedOperation`, and so does a `drop` that would leave no column.
- `komira.pl` frames take `select("a", "b")` and `drop("a", "b")`; `drop` of a name the frame lacks raises `KeyError` unless you pass `strict=False`.
- Nothing runs until `materialize()` (pandas-shaped) or `collect()` (polars-shaped); both give a result you read with `to_arrow()`.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`. The example sorts by `order_id`, which every printed frame keeps.

## Related

- [How do I select columns and filter rows?](../2-select-columns-filter-rows/page.md) (rank 2, works)
- [How do I add a new column computed from other columns?](../3-add-computed-column/page.md) (rank 3, works)
- [How do I rename columns?](../16-rename-columns/page.md) (rank 16, works)
- [How do I reorder columns?](../66-reorder-columns/page.md) (rank 66, works)

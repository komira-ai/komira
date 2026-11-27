# How do I add a column with if/else (case when) logic?

Use `CASE WHEN ... THEN ... ELSE ... END` in SQL, or `when(...).then(...).otherwise(...)` in `komira.pl`.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

Path("orders.csv").write_text(
    "order_id,customer,amount\n"
    "1,Ana,120\n"
    "2,Bo,80\n"
    "3,Cy,45\n"
    "4,Ana,200\n"
    "5,Bo,\n"
)

# SQL: CASE WHEN tries the branches in order; ELSE covers the rest.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    sized = s.sql(
        "SELECT order_id, amount,"
        " CASE WHEN amount >= 100 THEN 'large'"
        "      WHEN amount >= 50 THEN 'medium'"
        "      WHEN amount IS NULL THEN 'unknown'"
        "      ELSE 'small' END AS size"
        " FROM orders ORDER BY order_id"
    )
    for row in sized.to_arrow().to_pylist():
        print(row)

# polars-shaped: when(...).then(...), more .when(...).then(...), then
# .otherwise(...), inside with_columns.
amount = pl.col("amount")
size = (
    pl.when(amount >= 100).then(pl.lit("large"))
    .when(amount >= 50).then(pl.lit("medium"))
    .otherwise(pl.lit("small"))
)
lazy = pl.scan_csv("orders.csv").with_columns(size.alias("size"))
for row in lazy.sort("order_id").select("order_id", "amount", "size").collect().to_arrow().to_pylist():
    print(row)
```

Output:

<!-- include expected_output.txt -->
```text
{'order_id': 1, 'amount': 120, 'size': 'large'}
{'order_id': 2, 'amount': 80, 'size': 'medium'}
{'order_id': 3, 'amount': 45, 'size': 'small'}
{'order_id': 4, 'amount': 200, 'size': 'large'}
{'order_id': 5, 'amount': None, 'size': 'unknown'}
{'order_id': 1, 'amount': 120, 'size': 'large'}
{'order_id': 2, 'amount': 80, 'size': 'medium'}
{'order_id': 3, 'amount': 45, 'size': 'small'}
{'order_id': 4, 'amount': 200, 'size': 'large'}
{'order_id': 5, 'amount': None, 'size': 'small'}
```

## Notes

- `CASE` tries its `WHEN` branches in order and takes the first that holds; a row no branch holds for gets the `ELSE` value, or NULL if there is no `ELSE`.
- A comparison with NULL is not true, so a missing amount falls through to the next branch. The SQL example catches it with `WHEN amount IS NULL`; the `komira.pl` example has no such branch, so row 5 gets `small`.
- `komira.pl` chains more branches with `.when(...).then(...)` before `.otherwise(...)`; the values are numbers or strings, and boolean values are not supported yet.
- The pandas-shaped frame has no `Series.where`, `mask` or `apply` today: use SQL or `komira.pl` for a column that chooses per row (komira-ai/komira#2370).

## Related

- [How do I filter rows where a value is in a list?](../29-filter-rows-value-list/page.md) (rank 29, works)
- [How do I select columns and filter rows?](../2-select-columns-filter-rows/page.md) (rank 2, works)
- How do I find and fill missing values? (rank 6, works; no page yet)

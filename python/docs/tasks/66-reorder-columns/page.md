# How do I reorder columns?

Name the columns in the order you want: in `SELECT`, in a list index `df[["b", "a"]]` on a pandas-shaped frame, or in `select(...)` on a polars-shaped frame.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

Path("orders.csv").write_text(
    "order_id,customer,amount\n"
    "1,Ana,120\n"
    "2,Bo,80\n"
    "3,Cy,200\n"
)

# SQL: the columns come out in the order SELECT names them.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    table = s.sql("SELECT amount, order_id, customer FROM orders ORDER BY order_id").to_arrow()
    print(table.column_names)
    print(table.to_pylist()[0])

# pandas-shaped: index with the list of names in the order you want.
df = komira.read_csv("orders.csv")
print(df.columns)
print(sorted(df.columns))
reordered = df[["amount", "customer", "order_id"]]
print(reordered.columns)
print(reordered.sort_values("order_id").materialize().to_arrow().to_pylist()[0])

# polars-shaped: select names the columns in order.
lazy = pl.scan_csv("orders.csv").select("customer", "amount", "order_id")
print(lazy.columns)
print(lazy.sort("order_id").collect().to_arrow().to_pylist()[0])
```

Output:

<!-- include expected_output.txt -->
```text
['amount', 'order_id', 'customer']
{'amount': 120, 'order_id': 1, 'customer': 'Ana'}
['order_id', 'customer', 'amount']
['amount', 'customer', 'order_id']
['amount', 'customer', 'order_id']
{'amount': 120, 'customer': 'Ana', 'order_id': 1}
['customer', 'amount', 'order_id']
{'customer': 'Ana', 'amount': 120, 'order_id': 1}
```

## Notes

- Every form gives a new frame or result; nothing changes in place. Columns you leave out are dropped, so list all of them to keep them all.
- `sorted(df.columns)` is the alphabetical order; pass it as the list, `df[sorted(df.columns)]`, to put every column in that order.
- A frame has no index, so `reindex`, `sort_index` and `set_index` are refused: reorder the columns with a list of names instead.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`.

## Related

- How do I select or drop columns? (rank 34, works; no page yet)
- [How do I rename columns?](../16-rename-columns/page.md) (rank 16, works)
- [How do I sort rows by one or more columns?](../8-sort-rows-by-columns/page.md) (rank 8, works)
- How do I turn a table into a list of dicts? (rank 67, works)

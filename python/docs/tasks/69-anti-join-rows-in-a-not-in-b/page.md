# How do I find rows in A that are not in B (anti-join)?

Keep the rows of A with no match in B: `WHERE NOT EXISTS` in SQL, `df[~df["k"].isin(other["k"])]` on a pandas-shaped frame, or `join(how="anti")` on a polars-shaped one.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

Path("customers.csv").write_text("id,name\n1,Ana\n2,Bo\n3,Cy\n4,Di\n")
Path("orders.csv").write_text("order_id,customer_id\n10,1\n11,1\n12,3\n")

# SQL: NOT EXISTS keeps the customers that have no order.
with komira.Session() as s:
    s.register_csv("customers", "customers.csv")
    s.register_csv("orders", "orders.csv")
    idle = s.sql(
        "SELECT c.id AS id, c.name AS name FROM customers AS c"
        " WHERE NOT EXISTS (SELECT 1 FROM orders AS o WHERE o.customer_id = c.id)"
        " ORDER BY id"
    )
    print(idle.to_arrow().to_pylist())

# pandas-shaped: ~isin with a column of the other frame is an anti join.
customers = komira.read_csv("customers.csv")
orders = komira.read_csv("orders.csv")
idle = customers[~customers["id"].isin(orders["customer_id"])]
print(idle.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: join(how="anti").
lf = pl.scan_csv("customers.csv").join(
    pl.scan_csv("orders.csv"), left_on="id", right_on="customer_id", how="anti"
)
print(lf.sort("id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 2, 'name': 'Bo'}, {'id': 4, 'name': 'Di'}]
[{'id': 2, 'name': 'Bo'}, {'id': 4, 'name': 'Di'}]
[{'id': 2, 'name': 'Bo'}, {'id': 4, 'name': 'Di'}]
```

## Notes

- An anti join returns only A's columns, and a row of A once however many rows of B match it.
- A NULL key matches nothing, so a row of A whose key is NULL is kept, as with `NOT EXISTS` in DuckDB. `NOT IN (SELECT ...)` and `LEFT JOIN ... WHERE b.k IS NULL` are other SQL spellings; `NOT EXISTS` is the one that never surprises with NULLs in B.
- On the pandas-shaped frame, `isin(other["k"])` with a Series of another frame (of the same session) is a condition of `df[...]` and nothing else: do not combine it with `&` or `|`; filter with it alone, then filter that result by the other conditions.
- `merge(how="left_anti")`, `merge(how="anti")` and `merge(indicator=True)` are refused by name; write `~isin` instead.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`.

## Related

- [How do I join two tables on a key?](../10-join-two-tables-on-key/page.md) (rank 10, works)
- How do I left join and keep unmatched rows? (rank 36, works; no page yet)
- How do I compare two datasets and show the differences? (rank 70, works)
- How do I join on multiple columns? (rank 73, works)

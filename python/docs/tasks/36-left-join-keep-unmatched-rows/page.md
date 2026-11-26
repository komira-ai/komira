# How do I left join and keep unmatched rows?

Use `LEFT JOIN` in SQL, or `merge(..., how="left")` on a pandas-shaped frame: every row of the left table stays, and the right table's columns are null where nothing matched.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("customers.csv").write_text(
    "customer_id,name\n"
    "1,Ana\n"
    "2,Bo\n"
    "3,Cy\n"
)
Path("orders.csv").write_text(
    "order_id,customer_id,amount\n"
    "10,1,120\n"
    "11,1,45\n"
    "12,3,200\n"
    "13,9,70\n"
)

# SQL: LEFT JOIN keeps every customer; Bo has no order, so Bo's order columns are NULL.
with komira.Session() as s:
    s.register_csv("customers", "customers.csv")
    s.register_csv("orders", "orders.csv")
    joined = s.sql(
        "SELECT c.name, o.order_id, o.amount FROM customers c"
        " LEFT JOIN orders o ON o.customer_id = c.customer_id"
        " ORDER BY c.name, o.order_id"
    )
    print(joined.to_arrow().to_pylist())

    # Only the unmatched rows: customers with no order.
    unmatched = s.sql(
        "SELECT c.name FROM customers c"
        " LEFT JOIN orders o ON o.customer_id = c.customer_id"
        " WHERE o.order_id IS NULL ORDER BY c.name"
    )
    print(unmatched.to_arrow().to_pylist())

    # COUNT(o.order_id) skips NULLs, so an unmatched customer counts 0.
    counts = s.sql(
        "SELECT c.name, COUNT(o.order_id) AS n_orders FROM customers c"
        " LEFT JOIN orders o ON o.customer_id = c.customer_id"
        " GROUP BY c.name ORDER BY c.name"
    )
    print(counts.to_arrow().to_pylist())

# pandas-shaped: merge with how="left".
customers = komira.read_csv("customers.csv")
orders = komira.read_csv("orders.csv")
merged = customers.merge(orders, on="customer_id", how="left")
print(merged.sort_values(["customer_id", "order_id"]).materialize().to_arrow().to_pylist())

# The customers with no order: keep the rows whose key is not in the other frame.
no_orders = customers[~customers["customer_id"].isin(orders["customer_id"])]
print(no_orders[["name"]].materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'name': 'Ana', 'order_id': 10, 'amount': 120}, {'name': 'Ana', 'order_id': 11, 'amount': 45}, {'name': 'Bo', 'order_id': None, 'amount': None}, {'name': 'Cy', 'order_id': 12, 'amount': 200}]
[{'name': 'Bo'}]
[{'name': 'Ana', 'n_orders': 2}, {'name': 'Bo', 'n_orders': 0}, {'name': 'Cy', 'n_orders': 1}]
[{'customer_id': 1, 'name': 'Ana', 'order_id': 10, 'amount': 120}, {'customer_id': 1, 'name': 'Ana', 'order_id': 11, 'amount': 45}, {'customer_id': 2, 'name': 'Bo', 'order_id': None, 'amount': None}, {'customer_id': 3, 'name': 'Cy', 'order_id': 12, 'amount': 200}]
[{'name': 'Bo'}]
```

## Notes

- Order 13 belongs to customer 9, who is not in `customers`: a left join drops right rows with no left match. `how="outer"` (a full join) keeps the unmatched rows of both sides; `how="right"` keeps every order but drops Bo.
- To find the unmatched rows, add `WHERE o.order_id IS NULL` in SQL, or filter with `~df["key"].isin(other["key"])` on the frame. This release has no `merge(indicator=True)`, and it refuses it by name.
- A null key matches nothing, as in SQL (pandas matches null keys to each other, which komira does not).
- A join promises no row order: sort with `ORDER BY` or `sort_values` (or `merge(sort=True)`) before reading rows.
- In `merge`, a key column named alike on both sides appears once; any other shared column name gets the `_x` and `_y` suffixes (`suffixes=` changes them). The right-hand integer columns come back with nulls, so they print as `None`.

## Related

- How do I join two tables on a key? (rank 10, works; no page yet)
- [How do I count rows per group?](../35-count-rows-per-group/page.md) (rank 35, works)
- How do I find rows in A that are not in B (anti-join)? (rank 69, works; no page yet)
- How do I join on multiple columns? (rank 73, works; no page yet)

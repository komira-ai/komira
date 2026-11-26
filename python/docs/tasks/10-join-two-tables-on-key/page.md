# How do I join two tables on a key?

Write `JOIN ... ON` in SQL, or call `df.merge(other, on="key")` on a pandas-shaped frame or `lf.join(other, on="key")` on a polars-shaped one, and sort the result, since a join has no row order.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

# Orders 10-12 have a customer. Order 13 has none: customer 4 is not listed.
# Both files have a city column.
Path("customers.csv").write_text(
    "customer_id,name,city\n"
    "1,Ana,Oslo\n"
    "2,Bo,Lima\n"
    "3,Cy,Rome\n"
)
Path("orders.csv").write_text(
    "order_id,customer_id,amount,city\n"
    "10,1,120,Oslo\n"
    "11,2,80,Bergen\n"
    "12,1,45,Oslo\n"
    "13,4,200,Rome\n"
)

# SQL: JOIN ... ON keeps the rows that match, LEFT JOIN keeps every order and
# gives NULL where no customer matches.
with komira.Session() as s:
    s.register_csv("customers", "customers.csv")
    s.register_csv("orders", "orders.csv")
    inner = s.sql(
        "SELECT o.order_id AS order_id, c.name AS name, o.amount AS amount"
        " FROM orders AS o JOIN customers AS c ON o.customer_id = c.customer_id"
        " ORDER BY order_id"
    )
    print(inner.to_arrow().to_pylist())
    left = s.sql(
        "SELECT o.order_id AS order_id, c.name AS name"
        " FROM orders AS o LEFT JOIN customers AS c ON o.customer_id = c.customer_id"
        " ORDER BY order_id"
    )
    print(left.to_arrow().to_pylist())

# pandas-shaped: merge is an inner join on the key column. A name both frames
# have besides the key is suffixed, _x and _y unless you say otherwise.
orders = komira.read_csv("orders.csv")
customers = komira.read_csv("customers.csv")
print(orders.merge(customers, on="customer_id").columns)
joined = orders.merge(customers, on="customer_id", suffixes=("_order", "_customer"))
print(joined.columns)

# A join has no row order: sort before you print.
pick = ["order_id", "name", "amount"]
print(joined[pick].sort_values("order_id").materialize().to_arrow().to_pylist())

kept = orders.merge(customers, on="customer_id", how="left")
print(kept[pick].sort_values("order_id").materialize().to_arrow().to_pylist())

# polars-shaped: join(other, on=..., how=...).
lf = kpl.scan_csv("orders.csv").join(kpl.scan_csv("customers.csv"), on="customer_id", how="left")
print(lf.select("order_id", "name").sort("order_id").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'order_id': 10, 'name': 'Ana', 'amount': 120}, {'order_id': 11, 'name': 'Bo', 'amount': 80}, {'order_id': 12, 'name': 'Ana', 'amount': 45}]
[{'order_id': 10, 'name': 'Ana'}, {'order_id': 11, 'name': 'Bo'}, {'order_id': 12, 'name': 'Ana'}, {'order_id': 13, 'name': None}]
['order_id', 'customer_id', 'amount', 'city_x', 'name', 'city_y']
['order_id', 'customer_id', 'amount', 'city_order', 'name', 'city_customer']
[{'order_id': 10, 'name': 'Ana', 'amount': 120}, {'order_id': 11, 'name': 'Bo', 'amount': 80}, {'order_id': 12, 'name': 'Ana', 'amount': 45}]
[{'order_id': 10, 'name': 'Ana', 'amount': 120}, {'order_id': 11, 'name': 'Bo', 'amount': 80}, {'order_id': 12, 'name': 'Ana', 'amount': 45}, {'order_id': 13, 'name': None, 'amount': 200}]
[{'order_id': 10, 'name': 'Ana'}, {'order_id': 11, 'name': 'Bo'}, {'order_id': 12, 'name': 'Ana'}, {'order_id': 13, 'name': None}]
```

## Notes

- `JOIN` is an inner join. SQL also has `LEFT JOIN`, `RIGHT JOIN`, `FULL JOIN` and `CROSS JOIN`; where no row matches, the other side's columns are NULL (`None` in Python).
- `merge` takes `how="inner"` (the default), `"left"`, `"right"`, `"outer"` or `"cross"`. Name keys that differ between the tables with `left_on=` and `right_on=`; with no key named, the columns both frames have are the keys.
- A key named alike in both frames appears once in the answer. Every other name both frames have is suffixed: `_x` and `_y` by default, or the pair you pass as `suffixes=`. The polars-shaped `join` suffixes the right frame's name with `suffix`, `_right` by default, so the `city` of `customers` would be `city_right`.
- A join gives rows in no promised order. Sort them with `ORDER BY`, `sort_values` or `sort`, using keys that leave no ties among the rows you print; `merge(..., sort=True)` sorts by the key.
- A NULL key matches nothing, in SQL and in `merge` alike. pandas matches a missing key to another missing key; komira does not.
- Both frames must be on one session: read them with the same `session=`, or with neither. `df.join(other)` is refused because it joins on the index: `DataFrame.join joins on the index, which komira frames do not have; use merge(other, on=...)`. `merge` also refuses the index arguments, `indicator` and `validate`; use `df[df["k"].isin(other["k"])]` for a semi join and `df[~df["k"].isin(other["k"])]` for an anti join.

## Related

- How do I left join and keep unmatched rows? (rank 36, works; no page yet)
- How do I join on multiple columns? (rank 73, works; no page yet)
- How do I find rows in A that are not in B (anti-join)? (rank 69, works; no page yet)
- How do I join many tables in one query? (rank 74, works; no page yet)

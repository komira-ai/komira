# How do I join many tables in one query?

Chain `JOIN ... ON` clauses in one SQL query, or chain `merge` calls on pandas-shaped frames; each step joins one more table to the result so far.

<!-- include example.py -->
```python
from pathlib import Path

import komira

# Four small tables: orders point at customers and products, customers at regions.
Path("orders.csv").write_text(
    "order_id,customer_id,product_id,qty\n"
    "1,1,10,2\n"
    "2,2,11,1\n"
    "3,1,11,3\n"
    "4,3,10,1\n"
)
Path("customers.csv").write_text("customer_id,name,region_id\n1,Ana,100\n2,Bo,200\n3,Cy,100\n")
Path("products.csv").write_text("product_id,product\n10,pen\n11,ink\n")
Path("regions.csv").write_text("region_id,region\n100,north\n200,south\n")

with komira.Session() as s:
    # SQL: one JOIN ... ON per extra table, each joined to a table already named.
    for name in ("orders", "customers", "products", "regions"):
        s.register_csv(name, f"{name}.csv")
    rows = s.sql(
        "SELECT order_id, name, product, region, qty"
        " FROM orders AS o"
        " JOIN customers AS c ON o.customer_id = c.customer_id"
        " JOIN products AS p ON o.product_id = p.product_id"
        " JOIN regions AS r ON c.region_id = r.region_id"
        " ORDER BY order_id"
    )
    for row in rows.to_arrow().to_pylist():
        print(row)

# pandas-shaped: chain merge calls, each on the key the two sides share.
joined = (
    komira.read_csv("orders.csv")
    .merge(komira.read_csv("customers.csv"), on="customer_id")
    .merge(komira.read_csv("products.csv"), on="product_id")
    .merge(komira.read_csv("regions.csv"), on="region_id")
)
out = joined[["order_id", "name", "product", "region", "qty"]]
print(out.sort_values("order_id").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'order_id': 1, 'name': 'Ana', 'product': 'pen', 'region': 'north', 'qty': 2}
{'order_id': 2, 'name': 'Bo', 'product': 'ink', 'region': 'south', 'qty': 1}
{'order_id': 3, 'name': 'Ana', 'product': 'ink', 'region': 'north', 'qty': 3}
{'order_id': 4, 'name': 'Cy', 'product': 'pen', 'region': 'north', 'qty': 1}
[{'order_id': 1, 'name': 'Ana', 'product': 'pen', 'region': 'north', 'qty': 2}, {'order_id': 2, 'name': 'Bo', 'product': 'ink', 'region': 'south', 'qty': 1}, {'order_id': 3, 'name': 'Ana', 'product': 'ink', 'region': 'north', 'qty': 3}, {'order_id': 4, 'name': 'Cy', 'product': 'pen', 'region': 'north', 'qty': 1}]
```

## Notes

- In SQL every `JOIN` after the first names a table already in the query, so the tables can form a chain (orders, customers, regions) or a star (orders with products). Qualify a column that two tables share, as `o.customer_id`.
- A column name only one table has needs no qualifier, so the `SELECT` list above names none.
- In the frame, `merge` joins on the column the two sides share; give `on=` the key of each step. A column both sides hold that is not a key gets the suffixes `_x` and `_y`, so name distinct columns or pass `suffixes=`.
- A join matches a NULL key to nothing, as SQL's `=` does, in the frame too (not as pandas does).
- Neither way promises a row order: sort the answer with `ORDER BY` or `sort_values`.

## Related

- How do I join two tables on a key? (rank 10, works; no page yet)
- [How do I left join and keep unmatched rows?](../36-left-join-keep-unmatched-rows/page.md) (rank 36, works)
- How do I join on multiple columns? (rank 73, works)
- How do I cross join two tables? (rank 71, works)
- How do I join where a value falls between two bounds? (rank 75, works)

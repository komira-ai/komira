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

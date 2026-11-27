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

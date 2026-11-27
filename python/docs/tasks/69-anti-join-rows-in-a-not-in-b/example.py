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

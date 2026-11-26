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

from pathlib import Path

import komira
import komira.pl as kpl

Path("orders.csv").write_text(
    "order_id,customer,region,amount,note\n"
    "1,Ana,east,120,gift\n"
    "2,Bo,west,80,rush\n"
    "3,Cy,north,200,gift\n"
)

# SQL: select the columns you want by name, or drop some with * EXCLUDE.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    kept = s.sql("SELECT order_id, customer, amount FROM orders ORDER BY order_id")
    print(kept.to_arrow().to_pylist())
    rest = s.sql("SELECT * EXCLUDE (region, note) FROM orders ORDER BY order_id")
    print(rest.to_arrow().to_pylist())

# pandas-shaped: a list of names selects columns, and drop removes them.
df = komira.read_csv("orders.csv")
print(df.columns)
picked = df[["order_id", "customer"]]
print(picked.sort_values("order_id").materialize().to_arrow().to_pylist())
dropped = df.drop(columns=["region", "note"])
print(dropped.columns)
print(dropped.sort_values("order_id").materialize().to_arrow().to_pylist())
print(df.drop(["note"], axis=1).columns)

# polars-shaped: select keeps columns, drop removes them.
lf = kpl.scan_csv("orders.csv")
print(lf.select("order_id", "customer").sort("order_id").collect().to_arrow().to_pylist())
print(lf.drop("region", "note").sort("order_id").collect().to_arrow().to_pylist())

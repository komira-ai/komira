from pathlib import Path

import komira

Path("orders.csv").write_text(
    "order_id,customer,region,amount\n"
    "1,Ana,east,120\n"
    "2,Bo,west,80\n"
    "3,Ana,east,45\n"
    "4,Cy,north,200\n"
    "5,Bo,west,150\n"
    "6,Cy,south,60\n"
)
wanted = ["east", "north"]

# SQL: IN keeps the rows whose value is in the list, NOT IN the others.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    kept = s.sql("SELECT order_id, region FROM orders WHERE region IN ('east', 'north') ORDER BY order_id")
    print(kept.to_arrow().to_pylist())
    rest = s.sql("SELECT order_id, region FROM orders WHERE region NOT IN ('east', 'north') ORDER BY order_id")
    print(rest.to_arrow().to_pylist())

# pandas-shaped: isin takes a Python list; ~ negates it.
df = komira.read_csv("orders.csv")
kept = df[df["region"].isin(wanted)].sort_values("order_id")
print(kept.materialize().to_arrow().to_pylist())
rest = df[~df["region"].isin(wanted)].sort_values("order_id")
print(rest.materialize().to_arrow().to_pylist())

# Numbers work the same way.
ids = df[df["order_id"].isin([2, 4, 6])][["order_id", "customer"]].sort_values("order_id")
print(ids.materialize().to_arrow().to_pylist())

from pathlib import Path

import komira
import komira.pl as kpl

Path("orders.csv").write_text(
    "order_id,customer,region,amount\n"
    "1,Ana,east,120\n"
    "2,Bo,west,80\n"
    "3,Ana,east,45\n"
    "4,Cy,north,200\n"
    "5,Bo,west,150\n"
)

# SQL: count(*) per GROUP BY key.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    per_region = s.sql(
        "SELECT region, count(*) AS orders FROM orders"
        " GROUP BY region ORDER BY orders DESC, region"
    )
    print(per_region.to_arrow().to_pylist())

# pandas-shaped: groupby(...).size() has the keys and a column named size.
df = komira.read_csv("orders.csv")
print(df.groupby("region").size().materialize().to_arrow().to_pylist())

busiest = df.groupby("region").size().sort_values(["size", "region"], ascending=[False, True])
print(busiest.head(2).materialize().to_arrow().to_pylist())

# Two keys: one row per pair that occurs.
pairs = df.groupby(["region", "customer"]).size()
print(pairs.materialize().to_arrow().to_pylist())

# polars-shaped: group_by(...).len() has the keys and a column named len.
lf = kpl.scan_csv("orders.csv")
print(lf.group_by("region").len().sort("region").collect().to_arrow().to_pylist())

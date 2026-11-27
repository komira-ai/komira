from pathlib import Path

import komira
import komira.pl as kpl

Path("orders.csv").write_text(
    "order_id,region,amount\n"
    "1,east,120.5\n"
    "2,west,80.0\n"
    "3,east,45.25\n"
    "4,north,200.0\n"
    "5,west,150.5\n"
)

# SQL: GROUP BY the column, sum() the other, ORDER BY to fix the row order.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    totals = s.sql(
        "SELECT region, sum(amount) AS total FROM orders"
        " GROUP BY region ORDER BY region"
    )
    print(totals.to_arrow().to_pylist())

# pandas-shaped: groupby sorts the groups by their keys, as pandas does.
df = komira.read_csv("orders.csv")
print(df.groupby("region")["amount"].sum().materialize().to_arrow().to_pylist())

# Name the output column.
named = df.groupby("region").agg(total=("amount", "sum"))
print(named.materialize().to_arrow().to_pylist())

# polars-shaped: group_by has no row order, so sort the answer.
lf = kpl.scan_csv("orders.csv")
by_region = lf.group_by("region").agg(kpl.col("amount").sum()).sort("region")
print(by_region.collect().to_arrow().to_pylist())

from pathlib import Path

import komira
import komira.pl as kpl

Path("orders.csv").write_text(
    "item,qty,spare,price\n"
    "pen,5,1,2.5\n"
    "ink,3,0,7.25\n"
    "pad,4,2,6.0\n"
)

# SQL: each computed column is an expression with an alias in SELECT.
# int + int is an int, int * float is a float, and / always gives a float.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    rows = s.sql(
        "SELECT item, qty + spare AS stock, price * qty AS total,"
        " (qty + spare) / 2 AS half FROM orders ORDER BY item"
    )
    for row in rows.to_arrow().to_pylist():
        print(row)

# pandas-shaped: assign(name=...) returns a new frame, and df["name"] = ...
# adds the column to the frame itself. Nothing runs until materialize().
df = komira.read_csv("orders.csv")
df = df.assign(stock=df["qty"] + df["spare"], total=df["price"] * df["qty"])
df["half"] = df["stock"] / 2
print(df.columns)
print(df.dtypes["stock"], df.dtypes["total"], df.dtypes["half"])
out = df[["item", "stock", "total", "half"]].sort_values("item")
print(out.materialize().to_arrow().to_pylist())

# polars-shaped: with_columns takes expressions named with alias.
lf = kpl.scan_csv("orders.csv").with_columns(
    (kpl.col("qty") + kpl.col("spare")).alias("stock"),
    (kpl.col("price") * kpl.col("qty")).alias("total"),
)
lf = lf.with_columns((kpl.col("stock") / 2).alias("half"))
out = lf.select("item", "stock", "total", "half").sort("item").collect()
print(out.to_arrow().to_pylist())

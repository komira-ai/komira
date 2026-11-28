from pathlib import Path

import komira
import komira.pl as pl

Path("items.csv").write_text("name,price,qty\nana,10.5,4\nbo,3.25,9\ncy,8,16\n")

# SQL: a function of a column is an expression in SELECT.
with komira.Session() as s:
    s.register_csv("items", "items.csv")
    out = s.sql(
        "SELECT name, upper(name) AS shout, sqrt(qty) AS root,"
        " price * 2 AS double_price,"
        " CASE WHEN price > 5 THEN 'high' ELSE 'low' END AS band"
        " FROM items ORDER BY name"
    )
    for row in out.to_arrow().to_pylist():
        print(row)

# pandas-shaped: arithmetic and .str methods on a column, then assign.
df = komira.read_csv("items.csv")
df = df.assign(shout=df["name"].str.upper(), double_price=df["price"] * 2)
print(df.sort_values("name").materialize().to_arrow().to_pylist())

# polars-shaped: expressions in with_columns.
lf = pl.scan_csv("items.csv").with_columns(
    pl.col("name").str.to_uppercase().alias("shout"),
    (pl.col("price") * 2).alias("double_price"),
)
print(lf.sort("name").collect().to_arrow().to_pylist())

# Your own Python function: SQL does not call one, so run the query and
# apply the function to the rows of its result.
def band(price):
    return "high" if price > 5 else "low"


with komira.Session() as s:
    s.register_csv("items", "items.csv")
    rows = s.sql("SELECT name, price FROM items ORDER BY name").to_arrow().to_pylist()
print([{**row, "band": band(row["price"])} for row in rows])

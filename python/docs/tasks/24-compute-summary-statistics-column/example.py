from pathlib import Path

import komira
import komira.pl as pl

# A column with a missing value: the statistics skip it.
Path("prices.csv").write_text(
    "item,price\n"
    "a,10\n"
    "b,20\n"
    "c,20\n"
    "d,30\n"
    "e,50\n"
    "f,\n"
)

# SQL: one row of aggregates over the column.
with komira.Session() as s:
    s.register_csv("prices", "prices.csv")
    stats = s.sql(
        "SELECT count(*) AS rows, count(price) AS n, count(DISTINCT price) AS distinct_n,"
        " min(price) AS lo, max(price) AS hi, sum(price) AS total, avg(price) AS mean"
        " FROM prices"
    )
    print(stats.to_arrow().to_pylist())

# pandas-shaped: each reduction is a method of the frame, one row back.
df = komira.read_csv("prices.csv")
prices = df[["price"]]
print(prices.mean().materialize().to_arrow().to_pylist())
print(prices.max().materialize().to_arrow().to_pylist())

# Several statistics at once, each named.
named = df.agg(n=("price", "count"), lo=("price", "min"), hi=("price", "max"), mean=("price", "mean"))
print(named.materialize().to_arrow().to_pylist())

# polars-shaped: aggregate expressions in select.
lf = pl.scan_csv("prices.csv")
print(lf.select(pl.col("price").mean().alias("mean"), pl.col("price").max().alias("hi")).collect().to_arrow().to_pylist())

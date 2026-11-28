from pathlib import Path

import komira
import komira.pl as pl

def rounded(rows):
    """Floats to 3 places, so the printed line does not depend on the last bit."""
    return [{k: round(v, 3) for k, v in row.items()} for row in rows]


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

    # The median and the quartiles, and the sample standard deviation and variance.
    spread = s.sql(
        "SELECT median(price) AS median, quantile_cont(price, 0.25) AS q1, quantile_cont(price, 0.75) AS q3,"
        " stddev_samp(price) AS sd, var_samp(price) AS var"
        " FROM prices"
    )
    print(rounded(spread.to_arrow().to_pylist()))

# pandas-shaped: each reduction is a method of the frame, one row back.
df = komira.read_csv("prices.csv")
prices = df[["price"]]
print(prices.mean().materialize().to_arrow().to_pylist())
print(prices.max().materialize().to_arrow().to_pylist())
print(prices.median().materialize().to_arrow().to_pylist())
print(rounded(prices.std().materialize().to_arrow().to_pylist()))
print(rounded(prices.var().materialize().to_arrow().to_pylist()))

# Several statistics at once, each named.
named = df.agg(n=("price", "count"), lo=("price", "min"), hi=("price", "max"), mean=("price", "mean"))
print(named.materialize().to_arrow().to_pylist())

# A quantile of a column is one number, a float, so Series.quantile runs at once.
print(df["price"].quantile(0.75))

# polars-shaped: aggregate expressions in select.
lf = pl.scan_csv("prices.csv")
print(lf.select(pl.col("price").mean().alias("mean"), pl.col("price").max().alias("hi")).collect().to_arrow().to_pylist())
spread = lf.select(
    pl.col("price").median().alias("median"),
    pl.col("price").std().alias("std"),
    pl.col("price").var(ddof=0).alias("var_pop"),
)
print(rounded(spread.collect().to_arrow().to_pylist()))

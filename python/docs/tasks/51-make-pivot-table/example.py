from pathlib import Path

import komira
from komira import pl

Path("sales.csv").write_text(
    "region,product,amount\n"
    "east,pen,10\n"
    "east,ink,5\n"
    "west,pen,7\n"
    "west,pen,3\n"
    "north,ink,9\n"
)

# SQL: one conditional sum per new column, one output row per region.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    wide = s.sql(
        "SELECT region,"
        " sum(CASE WHEN product = 'pen' THEN amount ELSE 0 END) AS pen,"
        " sum(CASE WHEN product = 'ink' THEN amount ELSE 0 END) AS ink"
        " FROM sales GROUP BY region ORDER BY region"
    )
    print(wide.to_arrow().to_pylist())

# polars-shaped: the same conditional sums with when/then/otherwise.
pen = pl.when(pl.col("product") == "pen").then(pl.col("amount")).otherwise(0)
ink = pl.when(pl.col("product") == "ink").then(pl.col("amount")).otherwise(0)
wide = (
    pl.scan_csv("sales.csv")
    .group_by("region")
    .agg(pen.sum().alias("pen"), ink.sum().alias("ink"))
    .sort("region")
    .collect()
)
print(wide.to_arrow().to_pylist())

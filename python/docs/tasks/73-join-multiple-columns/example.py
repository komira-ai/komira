from pathlib import Path

import komira
import komira.pl as pl

Path("sales.csv").write_text(
    "region,product,units\n"
    "east,apple,10\n"
    "east,pear,5\n"
    "west,apple,7\n"
    "west,pear,3\n"
)
Path("prices.csv").write_text(
    "region,product,price\n"
    "east,apple,2\n"
    "east,pear,4\n"
    "west,apple,3\n"
    "north,apple,9\n"
)

# SQL: put every key in ON, joined with AND.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    s.register_csv("prices", "prices.csv")
    on = s.sql(
        "SELECT s.region, s.product, s.units, p.price FROM sales s"
        " JOIN prices p ON s.region = p.region AND s.product = p.product"
        " ORDER BY s.region, s.product"
    )
    print(on.to_arrow().to_pylist())

    # Keys spelled alike on both sides can go in USING, which keeps one copy.
    using = s.sql(
        "SELECT region, product, units, price FROM sales"
        " JOIN prices USING (region, product) ORDER BY region, product"
    )
    print(using.to_arrow().to_pylist())

# pandas-shaped: merge(on=[...]).
sales = komira.read_csv("sales.csv")
prices = komira.read_csv("prices.csv")
merged = sales.merge(prices, on=["region", "product"])
print(merged.sort_values(["region", "product"]).materialize().to_arrow().to_pylist())

# polars-shaped: join(on=[...]).
joined = pl.scan_csv("sales.csv").join(pl.scan_csv("prices.csv"), on=["region", "product"])
print(joined.sort("region", "product").collect().to_arrow().to_pylist())

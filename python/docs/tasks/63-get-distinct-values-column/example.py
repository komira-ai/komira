from pathlib import Path

import komira
import komira.pl as pl

Path("orders.csv").write_text(
    "order_id,customer,region\n"
    "1,Ana,east\n"
    "2,Bo,west\n"
    "3,Ana,east\n"
    "4,Cy,north\n"
    "5,Bo,west\n"
)

# SQL: DISTINCT for the values, count(DISTINCT ...) for how many there are.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    values = s.sql("SELECT DISTINCT region FROM orders ORDER BY region")
    print(values.to_arrow().to_pylist())
    how_many = s.sql("SELECT count(DISTINCT region) AS regions FROM orders")
    print(how_many.to_arrow().to_pylist())

# pandas-shaped: keep the column, drop its duplicate rows, sort for a stable order.
df = komira.read_csv("orders.csv")
regions = df[["region"]].drop_duplicates().sort_values("region")
print(regions.materialize().to_arrow().to_pylist())
print(df.agg(regions=("region", "nunique")).materialize().to_arrow().to_pylist())

# polars-shaped: unique and n_unique.
lf = pl.scan_csv("orders.csv")
print(lf.select("region").unique().sort("region").collect().to_arrow().to_pylist())
print(lf.select(pl.col("region").n_unique().alias("regions")).collect().to_arrow().to_pylist())

from pathlib import Path

import komira
import komira.pl as pl

Path("orders.csv").write_text(
    "order_id,customer,amount\n"
    "1,Ana,120\n"
    "2,Bo,80\n"
    "3,Cy,45\n"
    "4,Ana,200\n"
    "5,Bo,\n"
)

# SQL: CASE WHEN tries the branches in order; ELSE covers the rest.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    sized = s.sql(
        "SELECT order_id, amount,"
        " CASE WHEN amount >= 100 THEN 'large'"
        "      WHEN amount >= 50 THEN 'medium'"
        "      WHEN amount IS NULL THEN 'unknown'"
        "      ELSE 'small' END AS size"
        " FROM orders ORDER BY order_id"
    )
    for row in sized.to_arrow().to_pylist():
        print(row)

# polars-shaped: when(...).then(...), more .when(...).then(...), then
# .otherwise(...), inside with_columns.
amount = pl.col("amount")
size = (
    pl.when(amount >= 100).then(pl.lit("large"))
    .when(amount >= 50).then(pl.lit("medium"))
    .otherwise(pl.lit("small"))
)
lazy = pl.scan_csv("orders.csv").with_columns(size.alias("size"))
for row in lazy.sort("order_id").select("order_id", "amount", "size").collect().to_arrow().to_pylist():
    print(row)

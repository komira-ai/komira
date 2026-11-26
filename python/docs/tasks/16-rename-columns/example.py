from pathlib import Path

import komira
from komira import pl

Path("orders.csv").write_text(
    "order_id,customer,amount\n"
    "1,Ana,120\n"
    "2,Bo,80\n"
    "3,Cy,45\n"
)

# SQL: AS gives a column a new name in the result.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    table = s.sql(
        "SELECT order_id AS id, customer AS name, amount AS total"
        " FROM orders ORDER BY id"
    ).to_arrow()
    print(table.column_names)
    print(table.to_pylist())

# pandas-shaped: rename(columns=...) takes a dict of old to new names.
# A name the frame lacks ("region") is skipped.
df = komira.read_csv("orders.csv")
print(df.rename(columns={"order_id": "id", "amount": "total", "region": "area"}).columns)

# Or a function of each name, or a prefix on every column.
print(df.rename(columns=str.upper).columns)
print(df.add_prefix("o_").columns)

# polars-shaped: rename takes a dict or a function; alias names an expression.
lf = pl.scan_csv("orders.csv")
print(lf.rename({"amount": "total"}).columns)
print(lf.select(pl.col("amount").alias("total")).columns)

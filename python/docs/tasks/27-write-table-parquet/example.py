from pathlib import Path

import komira

Path("orders.csv").write_text(
    "order_id,customer,amount\n"
    "1,Ana,120\n"
    "2,Bo,40\n"
    "3,Ana,75\n"
    "4,Cy,200\n"
)

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    # COPY writes a query's result to one Parquet file and returns the row count.
    written = s.sql(
        "COPY (SELECT order_id, customer, amount FROM orders WHERE amount >= 75 ORDER BY order_id)"
        " TO 'big_orders.parquet' (FORMAT parquet)"
    ).to_arrow()
    print("rows written:", written.column(0).to_pylist()[0])

    # Read the file back to check it.
    s.register_parquet("big_orders", "big_orders.parquet")
    print(s.sql("SELECT * FROM big_orders ORDER BY order_id").to_arrow().to_pylist())

# The pandas-shaped frame reads the new file too.
df = komira.read_parquet("big_orders.parquet")
print(df.groupby("customer").agg(total=("amount", "sum")).sort_values("customer").materialize().to_arrow().to_pylist())

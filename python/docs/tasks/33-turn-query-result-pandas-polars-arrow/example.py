from pathlib import Path

import pyarrow as pa

import komira
import komira.pl as kpl

Path("orders.csv").write_text(
    "order_id,customer,region,amount\n"
    "1,Ana,east,120\n"
    "2,Bo,west,80\n"
    "3,Ana,east,45\n"
    "4,Cy,north,200\n"
    "5,Bo,west,150\n"
)

QUERY = "SELECT order_id, customer, amount FROM orders WHERE amount > 100 ORDER BY order_id"

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")

    # SQL: a query's answer is a Result, and to_arrow() reads it as a pyarrow Table.
    table = s.sql(QUERY).to_arrow()
    print(table.num_rows, table.column_names)
    print(table.to_pylist())
    print(table.to_pydict())

    # A Result is read once: reading it again says so.
    result = s.sql(QUERY)
    result.to_arrow()
    try:
        result.to_arrow()
    except komira.KomiraError as e:
        print(e)

    # Any Arrow reader takes a Result as it is: pa.table reads it whole, and
    # to_reader() hands over its record batches as they arrive.
    print(pa.table(s.sql(QUERY)).equals(table))
    print(sum(batch.num_rows for batch in s.sql(QUERY).to_reader()))

# pandas-shaped: materialize() runs the frame and returns the same Result.
df = komira.read_csv("orders.csv")
big = df[df["amount"] > 100][["order_id", "customer", "amount"]]
print(big.sort_values("order_id").materialize().to_arrow().to_pylist() == table.to_pylist())

# polars-shaped: collect() runs the frame and returns the same Result.
lf = kpl.scan_csv("orders.csv")
big = lf.filter(kpl.col("amount") > 100).select("order_id", "customer", "amount")
print(big.sort("order_id").collect().to_arrow().to_pylist() == table.to_pylist())

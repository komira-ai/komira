from pathlib import Path

import komira

Path("orders.csv").write_text(
    "order_id,customer,amount\n"
    "1,Ana,120\n"
    "2,Bo,80\n"
    "3,Cy,200\n"
)

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")

    # Read the rows, then loop over plain Python dicts.
    rows = s.sql("SELECT * FROM orders ORDER BY order_id").to_arrow().to_pylist()
    for row in rows:
        print(row["order_id"], row["customer"], row["amount"])

    # A big table: loop over the batches as they arrive, never holding all rows.
    reader = s.sql("SELECT customer, amount FROM orders ORDER BY customer").to_reader()
    for batch in reader:
        for row in batch.to_pylist():
            print(row)

# pandas-shaped: there is no iterrows(); run the frame, then loop over the rows.
df = komira.read_csv("orders.csv")
for row in df.sort_values("order_id").materialize().to_arrow().to_pylist():
    print(row["customer"])

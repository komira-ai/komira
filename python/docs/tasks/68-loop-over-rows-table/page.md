# How do I loop over the rows of a table?

Run the query, then loop over `to_arrow().to_pylist()`, a list of one dict per row; for a table too big to hold, loop over the batches of `to_reader()`.

<!-- include example.py -->
```python
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
```

Output:

<!-- include expected_output.txt -->
```text
1 Ana 120
2 Bo 80
3 Cy 200
{'customer': 'Ana', 'amount': 120}
{'customer': 'Bo', 'amount': 80}
{'customer': 'Cy', 'amount': 200}
Ana
Bo
Cy
```

## Notes

- Looping row by row is slow in any engine: when the work is a calculation, write it in SQL (`SELECT amount * 2 ...`) or as a column expression on the frame, and loop only to hand rows to other Python code.
- A komira frame is a plan, not rows, so `for row in df` raises `UnsupportedOperation`, and `df.iterrows()`, `itertuples()` and `items()` raise `AttributeError` ("needs the rows: run the frame with materialize()..."). Write `df.materialize().to_arrow().to_pylist()` instead.
- A `Result` is read once: use `to_arrow()` or `to_reader()`, not both.
- `to_reader()` gives `pyarrow` record batches; the batch sizes are the engine's, so rely on the order of rows, not on where a batch ends.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- How do I turn a table into a list of dicts? (rank 67, works)
- How do I count the rows of a table? (rank 62, works)
- How do I take the first or last N rows? (rank 65, works)
- How do I turn a query result into pandas, polars or Arrow? (rank 33, works; no page yet)

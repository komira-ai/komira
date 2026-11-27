# How do I write a table to Parquet?

Run `COPY (SELECT ...) TO 'file.parquet' (FORMAT parquet)` through `Session.sql`; it writes one Parquet file and returns the row count. The frame has no `to_parquet` yet.

<!-- include example.py -->
```python
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
```

Output:

<!-- include expected_output.txt -->
```text
rows written: 3
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 3, 'customer': 'Ana', 'amount': 75}, {'order_id': 4, 'customer': 'Cy', 'amount': 200}]
[{'customer': 'Ana', 'total': 195}, {'customer': 'Cy', 'total': 200}]
```

## Notes

- `COPY` writes the rows of any query, so it also writes a whole table (`COPY (SELECT * FROM orders) TO ...`). Put an `ORDER BY` in the query when the file's row order matters.
- The write returns a one-row result holding the number of rows written.
- The frame and `komira.pl` have no writer of their own yet: `df.to_parquet(path)` and `lf.sink_parquet(path)` raise `AttributeError` (komira-ai/komira#2368). `probe_frame_to_parquet.py` and `probe_lazy_sink_parquet.py` beside this page try them and must fail with the lines in their `.error.txt` files. The day one of them runs, this page's check goes red, and the page and the catalogue status change with it.
- One file per `COPY`: writing a directory of files partitioned by a column is not supported yet: komira-ai/komira#2346.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I write a table to a CSV file?](../11-write-table-csv-file/page.md) (rank 11, partial)
- How do I write a dataset partitioned by a column? (rank 97, gap; no page yet)

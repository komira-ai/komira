# How do I rename columns?

Give a column a new name with `AS` in `SELECT`, or call `rename(columns={"old": "new"})` on a pandas-shaped frame or `rename({"old": "new"})` on a polars-shaped one.

<!-- include example.py -->
```python
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
```

Output:

<!-- include expected_output.txt -->
```text
['id', 'name', 'total']
[{'id': 1, 'name': 'Ana', 'total': 120}, {'id': 2, 'name': 'Bo', 'total': 80}, {'id': 3, 'name': 'Cy', 'total': 45}]
['id', 'customer', 'total']
['ORDER_ID', 'CUSTOMER', 'AMOUNT']
['o_order_id', 'o_customer', 'o_amount']
['order_id', 'customer', 'total']
['total']
```

## Notes

- `rename` takes a dict of old to new names or a function of each name (`str.upper`, `str.lower`, a lambda), and returns a new frame: frames do not change in place, so `rename(inplace=True)` and `df.columns = [...]` are refused with a message naming what to write instead.
- A name the frame lacks is skipped, as pandas does; pass `errors="raise"` to the pandas-shaped `rename`, or leave the polars-shaped `strict=True` default, to have it refused. Two columns given the same name are refused.
- `rename(index=...)` renames row labels, and komira frames have no index, so it is refused by name.
- Not built: `set_axis`, a Series `rename`, `pl.all().name.prefix(...)` and the other `name` namespace methods, and DuckDB's `SELECT * RENAME (...)`, `SELECT * EXCLUDE (...)`, the column list of an alias (`FROM t AS x(a, b)`) and `ALTER TABLE ... RENAME COLUMN`. Rename in `SELECT ... AS ...` or with the frame's `rename` instead.
- A SQL alias is a plain name: a double-quoted identifier such as `AS "Total Amount"` is refused with a syntax error (komira-ai/komira#2382). Give such a name on the frame (`rename(columns={"amount": "Total Amount"})`).
- `DataFrame.rename` and `add_prefix` are newer than the PyPI release 0.1.1623.

## Related

- [How do I change a column's data type?](../12-change-column-data-type/page.md) (rank 12, works)
- [How do I apply a function to every value in a column?](../17-apply-function-value-column/page.md) (rank 17, partial)
- How do I select or drop columns? (rank 34, works; no page yet)
- How do I lowercase, trim and replace text in a column? (rank 42, works; no page yet)

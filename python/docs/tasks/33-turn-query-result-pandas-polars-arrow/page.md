# How do I turn a query result into pandas, polars or Arrow?

Every query ends in a `Result`: `to_arrow()` gives a `pyarrow.Table`, `to_pandas()` a pandas `DataFrame` and `to_polars()` a polars `DataFrame`, from SQL (`s.sql(...)`), from a pandas-shaped frame (`.materialize()`) and from a polars-shaped one (`.collect()`).

<!-- include example.py -->
```python
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
```

Output:

<!-- include expected_output.txt -->
```text
3 ['order_id', 'customer', 'amount']
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 4, 'customer': 'Cy', 'amount': 200}, {'order_id': 5, 'customer': 'Bo', 'amount': 150}]
{'order_id': [1, 4, 5], 'customer': ['Ana', 'Cy', 'Bo'], 'amount': [120, 200, 150]}
the result was already read: run the query again to read it again
True
3
True
True
```

## Notes

- Arrow is built in: the program above needs only komira, pyarrow and protobuf, so `to_arrow()`, `to_reader()` and `pa.table(result)` always work. `table.to_pylist()` gives plain Python dicts.
- pandas and polars are optional. komira imports one only when you call `to_pandas()` or `to_polars()`, and without it that call raises `ImportError` naming what to install (`pip install pandas`, `pip install polars`) and leaves the result unread. The check that runs this page has neither, so the calls below are shown but not run.

<!-- not-tested: needs pandas and polars, which the check does not install -->
```python
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    pdf = s.sql(QUERY).to_pandas()  # a pandas.DataFrame, via pyarrow's Table.to_pandas()
    pldf = s.sql(QUERY).to_polars()  # a polars.DataFrame, via polars.from_arrow

pdf = df.materialize().to_pandas()  # from the pandas-shaped frame
pldf = lf.collect().to_polars()  # from the polars-shaped frame
```

- `to_pandas()` uses pyarrow's default dtype mapping, so a column with NULLs becomes float or object, as it does for any Arrow table. To keep Arrow's types, call `to_arrow().to_pandas(types_mapper=pandas.ArrowDtype)`.
- A frame has no `to_pandas()` or `to_arrow()` of its own: it is a plan, not rows. Run it with `materialize()` (pandas-shaped) or `collect()` (polars-shaped) first.
- A `Result` is read once, by whichever of `to_arrow`, `to_reader`, `to_pandas`, `to_polars` or `pa.table(result)` comes first; run the query again to read it again. `pa.table(result)` and polars or DuckDB reading a `Result` directly use the Arrow PyCapsule stream; they refuse a requested schema rather than cast.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I select columns and filter rows?](../2-select-columns-filter-rows/page.md) (rank 2, works)
- [How do I write a table to Parquet?](../27-write-table-parquet/page.md) (rank 27, partial)
- [How do I run SQL on a CSV or Parquet file (or a DataFrame)?](../37-run-sql-csv-parquet-file/page.md) (rank 37, partial)

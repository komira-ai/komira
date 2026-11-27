# How do I change a column's data type?

Cast it: `df.astype({"col": "int64"})` on the pandas-shaped frame, `pl.col("col").cast("int64")` on the polars-shaped one, or `CAST(col AS type)` in SQL.

<!-- include example.py -->
```python
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira
import komira.pl as pl

# Every column here starts as text, as it does in many exported files.
pq.write_table(
    pa.table(
        {
            "id": ["1", "2", "3"],
            "price": ["1.5", "2.25", "10"],
            "qty": ["3", "4", "5"],
        }
    ),
    "items.parquet",
)

# pandas-shaped: astype takes one dtype per column, or one dtype for a Series.
df = komira.read_parquet("items.parquet")
typed = df.astype({"id": "int64", "price": "float64", "qty": "int32"})
print(typed.dtypes)
print(typed.sort_values("id").materialize().to_arrow().to_pylist())
print(df["id"].astype("int64").dtype)

# polars-shaped: cast a column in with_columns.
lf = pl.scan_parquet("items.parquet").with_columns(
    pl.col("id").cast("int64"),
    pl.col("price").cast("float64"),
    pl.col("qty").cast("int32"),
)
print({f.name: str(f.type) for f in lf.collect().to_arrow().schema})

# SQL: CAST(x AS type) or x::type, here from numbers to text and to double.
Path("nums.csv").write_text("id,qty\n1,3\n2,4\n3,5\n")
with komira.Session() as s:
    s.register_csv("nums", "nums.csv")
    rows = s.sql(
        "SELECT CAST(id AS VARCHAR) AS id, qty::DOUBLE AS qty FROM nums ORDER BY qty"
    )
    print(rows.to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'id': 'int64', 'price': 'float64', 'qty': 'int32'}
[{'id': 1, 'price': 1.5, 'qty': 3}, {'id': 2, 'price': 2.25, 'qty': 4}, {'id': 3, 'price': 10.0, 'qty': 5}]
int64
{'id': 'int64', 'price': 'double', 'qty': 'int32'}
[{'id': '1', 'qty': 3.0}, {'id': '2', 'qty': 4.0}, {'id': '3', 'qty': 5.0}]
```

## Notes

- `astype` takes a pyarrow type, a komira name (`"int64"`, `"float64"`, `"string"`), a pandas spelling (`"Int64"`, `"str"`) or `int`, `float` and `str`. `dtypes` shows the result.
- Text to a number works in `astype`, in polars `cast` (the example does it) and in SQL `CAST`, and reads as DuckDB reads it (`'2.5'` is 3 as an integer); SQL `TRY_CAST` makes text that is not a number NULL.
- Number to number, and integer to text, work in all three. A float to an integer rounds half to even (2.5 becomes 2) in SQL `CAST`, as DuckDB does, and in `astype`, where pandas truncates toward zero (komira-ai/komira#2376); polars `cast` truncates, as polars does. Check a float column before casting it down.
- SQL `CAST` reaches `INTEGER`, `BIGINT`, `REAL`, `DOUBLE` and, from an integer, `VARCHAR`; `TRY_CAST` reaches the four numbers from text, a number or a boolean. Other targets (`DATE`, `TIMESTAMP`, `SMALLINT`, `BOOLEAN`, `DECIMAL` over a column), and `TRY_CAST` to `VARCHAR` or from a `DECIMAL`, are refused by name.
- Parsing text into a date is a task of its own: it is not done by `astype("date32")` or `cast`, which refuse or fail on text (rank 23).
- A value that does not convert fails the query; `astype(errors="ignore")` is refused.
- `DataFrame.astype` and `Series.astype` are newer than the PyPI release 0.1.1623.

## Related

- [How do I parse strings into dates?](../23-parse-strings-dates/page.md) (rank 23, partial)
- [How do I rename columns?](../16-rename-columns/page.md) (rank 16, works)
- [How do I select or drop columns?](../34-select-drop-columns/page.md) (rank 34, partial)
- [How do I apply a function to every value in a column?](../17-apply-function-value-column/page.md) (rank 17, partial)

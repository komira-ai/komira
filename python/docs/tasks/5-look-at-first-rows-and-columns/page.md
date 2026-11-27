# How do I look at the first rows, row count and columns of a dataset?

Read the column names from `df.columns`, take the first rows of a sorted frame with `head(n)` (or `ORDER BY ... LIMIT n` in SQL), and count the rows with `count(*)`, `df.agg(n=(column, "size"))` or `kpl.len()`.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

# A small CSV file: the last fare is empty, so it reads as NULL.
Path("trips.csv").write_text(
    "id,city,km,fare\n"
    "1,Oslo,3,12.5\n"
    "2,Lima,8,20.0\n"
    "3,Oslo,5,7.5\n"
    "4,Rome,2,30.0\n"
    "5,Lima,11,\n"
)

# SQL: count(*) counts the rows, ORDER BY with LIMIT takes the first rows.
with komira.Session() as s:
    s.register_csv("trips", "trips.csv")
    print(s.sql("SELECT count(*) AS n FROM trips").to_arrow().to_pylist())
    for row in s.sql("SELECT * FROM trips ORDER BY id LIMIT 2").to_arrow().to_pylist():
        print(row)

# pandas-shaped: the column names and types are known without running a query.
df = komira.read_csv("trips.csv")
print(df.columns)
print(df.dtypes["id"], df.dtypes["km"], df.dtypes["fare"])

# The first rows of a sorted frame. An unsorted frame has no first rows.
print(df.sort_values("id").head(2).materialize().to_arrow().to_pylist())

# The row count is a reduction: "size" counts rows, count() counts the
# values that are not NULL in each column.
print(df.agg(n=("id", "size")).materialize().to_arrow().to_pylist())
print(df.count().materialize().to_arrow().to_pylist())

# polars-shaped: the same, with kpl.len() for the row count.
lf = kpl.scan_csv("trips.csv")
print(lf.columns)
print(lf.sort("id").head(2).collect().to_arrow().to_pylist())
print(lf.select(kpl.len()).collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'n': 5}]
{'id': 1, 'city': 'Oslo', 'km': 3, 'fare': 12.5}
{'id': 2, 'city': 'Lima', 'km': 8, 'fare': 20.0}
['id', 'city', 'km', 'fare']
int64 int64 float64
[{'id': 1, 'city': 'Oslo', 'km': 3, 'fare': 12.5}, {'id': 2, 'city': 'Lima', 'km': 8, 'fare': 20.0}]
[{'n': 5}]
[{'id': 5, 'city': 5, 'km': 5, 'fare': 4}]
['id', 'city', 'km', 'fare']
[{'id': 1, 'city': 'Oslo', 'km': 3, 'fare': 12.5}, {'id': 2, 'city': 'Lima', 'km': 8, 'fare': 20.0}]
[{'len': 5}]
```

## Notes

- `df.columns` and `df.dtypes` (and `lf.columns`) come from the schema the engine inferred when the file was read; they run no query. `dtypes` gives each column's Arrow type name, such as `int64` and `float64`.
- `head(n)` of an unsorted frame returns some `n` rows, and a SQL `LIMIT` with no `ORDER BY` does the same. Sort first, with keys that leave no ties among the rows you keep. `tail(n)` takes the last rows of a sorted frame.
- `size` counts the rows and `count` counts the values that are not NULL, so `df.count()` shows the NULLs: `fare` has four values in five rows. In polars-shaped code the row count is `kpl.len()`, named `len` in the result; `kpl.col("fare").count()` counts the values that are not NULL.
- `len(df)` and `len(lf)` raise `UnsupportedOperation`, because a frame is a plan and the count needs a query to run. Count the rows as above.
- `df.shape`, `df.size` and `df.empty` are refused: `.shape needs a query to run: count rows with df.agg(n=(column, "size")).materialize()`. `df.iloc[:5]` and `df[:5]` are refused too; write `df.sort_values(...).head(5)`.
- `df.info()` and `df.describe()` are refused: `.info() reports on a pandas object; run with materialize(), then call to_pandas().info()`. That needs pandas installed. For summary statistics computed by komira, see the related task on them below.
- `komira.pl.count()` is refused: `komira.pl.count() is refused: it named both questions in polars; say komira.pl.len() for rows or komira.pl.col(name).count() for non-null values`.

## Related

- [How do I sort rows by one or more columns?](../8-sort-rows-by-columns/page.md) (rank 8, works)
- [How do I compute summary statistics of a column?](../24-compute-summary-statistics-column/page.md) (rank 24, partial)
- [How do I count the rows of a table?](../62-count-rows-table/page.md) (rank 62, works)
- [How do I take the first or last N rows?](../65-take-first-last-n-rows/page.md) (rank 65, works)

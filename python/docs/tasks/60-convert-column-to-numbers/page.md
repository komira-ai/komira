# How do I convert a column to numbers, turning bad values into null?

On a polars-shaped frame, `pl.col(name).cast("int64", strict=False)` (or `"float64"`) turns text into numbers and every value that is not a number into null. In SQL, `TRY_CAST(x AS BIGINT)` (or `DOUBLE`) does the same.

<!-- include example.py -->
```python
from pathlib import Path

import komira
from komira import pl

Path("readings.csv").write_text(
    "sensor,count,level\n"
    "a,12,12.5\n"
    "b,oops,n/a\n"
    "c,7,7\n"
    "d,,\n"
    "e,3,3.25\n"
)

# polars-shaped: cast with strict=False makes a value that is not a number null.
numbers = (
    pl.scan_csv("readings.csv")
    .with_columns(
        pl.col("count").cast("int64", strict=False),
        pl.col("level").cast("float64", strict=False),
    )
    .sort("sensor")
    .collect()
)
print(numbers.to_arrow().to_pylist())

# The converted column is a number, so it aggregates: nulls are skipped.
totals = (
    pl.scan_csv("readings.csv")
    .select(
        pl.col("count").cast("int64", strict=False).sum().alias("count_sum"),
        pl.col("level").cast("float64", strict=False).mean().alias("level_mean"),
    )
    .collect()
)
row = totals.to_arrow().to_pylist()[0]
print(row["count_sum"], f"{row['level_mean']:.2f}")

# pandas-shaped: astype converts a clean column, but a value that is not a
# number fails the query instead of becoming null.
df = komira.read_csv("readings.csv")
try:
    df.assign(count=df["count"].astype("int64")).materialize()
except komira.KomiraError:
    print("astype failed")

# SQL: TRY_CAST makes a value that is not a number NULL; CAST fails the query.
# Text reads as DuckDB reads it: '2.5' is 3 as a BIGINT, and '1e3' is a number.
Path("raw.csv").write_text("sensor,reading\na,12\nb,oops\nc,2.5\nd,\ne,1e3\n")
with komira.Session() as s:
    s.register_csv("raw", "raw.csv")
    rows = s.sql(
        "SELECT sensor, TRY_CAST(reading AS BIGINT) AS n, TRY_CAST(reading AS DOUBLE) AS x"
        " FROM raw ORDER BY sensor"
    )
    print(rows.to_arrow().to_pylist())
    try:
        s.sql("SELECT CAST(reading AS BIGINT) AS n FROM raw").to_arrow()
    except komira.KomiraError:
        print("CAST failed")
```

Output:

<!-- include expected_output.txt -->
```text
[{'sensor': 'a', 'count': 12, 'level': 12.5}, {'sensor': 'b', 'count': None, 'level': None}, {'sensor': 'c', 'count': 7, 'level': 7.0}, {'sensor': 'd', 'count': None, 'level': None}, {'sensor': 'e', 'count': 3, 'level': 3.25}]
22 7.58
astype failed
[{'sensor': 'a', 'n': 12, 'x': 12.0}, {'sensor': 'b', 'n': None, 'x': None}, {'sensor': 'c', 'n': 3, 'x': 2.5}, {'sensor': 'd', 'n': None, 'x': None}, {'sensor': 'e', 'n': 1000, 'x': 1000.0}]
CAST failed
```

## Notes

- Empty fields and text such as `oops` or `n/a` become null; the converted column aggregates like any number column, skipping the nulls.
- Without `strict=False`, in the pandas-shaped `astype` and in SQL `CAST`, a value that is not a number fails the query.
- Text reads as a number the way DuckDB reads it, in all three: around it whitespace is allowed, a fraction rounds an integer half away from zero (`'2.5'` is 3, `'-2.5'` is -3), and `'1e3'`, `'1_000'` and `'0x1F'` are numbers. polars would make `'2.5'` null as an `int64` and pandas would fail on it.
- There is no `komira.to_numeric` yet, and `astype` has no `errors="coerce"`: `probe_to_numeric.py` beside this page tries `komira.to_numeric(..., errors="coerce")` and must fail with the line in `probe_to_numeric.error.txt`. pandas picks `int64` or `float64` from the data, which a plan cannot do before it runs, so the type it answers is still to be decided (komira-ai/komira#2402). The day it runs, this page's check goes red, and the page and the catalogue status change with it.

## Related

- [How do I change a column's data type?](../12-change-column-data-type/page.md) (rank 12, works)
- [How do I replace specific values such as 'N/A' with null?](../55-replace-values-with-null/page.md) (rank 55, partial)
- How do I find and fill missing values? (rank 6, works; no page yet)
- [How do I validate data: nulls, uniqueness, ranges?](../59-validate-data-nulls-uniqueness-ranges/page.md) (rank 59, works)

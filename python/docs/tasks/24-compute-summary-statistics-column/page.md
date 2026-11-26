# How do I compute summary statistics of a column?

Aggregate the column in SQL (`count`, `min`, `max`, `sum`, `avg`), or call the reduction on a pandas-shaped frame or a polars-shaped expression; the median and the standard deviation are not run yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

# A column with a missing value: the statistics skip it.
Path("prices.csv").write_text(
    "item,price\n"
    "a,10\n"
    "b,20\n"
    "c,20\n"
    "d,30\n"
    "e,50\n"
    "f,\n"
)

# SQL: one row of aggregates over the column.
with komira.Session() as s:
    s.register_csv("prices", "prices.csv")
    stats = s.sql(
        "SELECT count(*) AS rows, count(price) AS n, count(DISTINCT price) AS distinct_n,"
        " min(price) AS lo, max(price) AS hi, sum(price) AS total, avg(price) AS mean"
        " FROM prices"
    )
    print(stats.to_arrow().to_pylist())

# pandas-shaped: each reduction is a method of the frame, one row back.
df = komira.read_csv("prices.csv")
prices = df[["price"]]
print(prices.mean().materialize().to_arrow().to_pylist())
print(prices.max().materialize().to_arrow().to_pylist())

# Several statistics at once, each named.
named = df.agg(n=("price", "count"), lo=("price", "min"), hi=("price", "max"), mean=("price", "mean"))
print(named.materialize().to_arrow().to_pylist())

# polars-shaped: aggregate expressions in select.
lf = pl.scan_csv("prices.csv")
print(lf.select(pl.col("price").mean().alias("mean"), pl.col("price").max().alias("hi")).collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'rows': 6, 'n': 5, 'distinct_n': 4, 'lo': 10, 'hi': 50, 'total': Decimal('130'), 'mean': 26.0}]
[{'price': 26.0}]
[{'price': 50}]
[{'n': 5, 'lo': 10, 'hi': 50, 'mean': 26.0}]
[{'mean': 26.0, 'hi': 50}]
```

## Notes

- A missing value (an empty field in a CSV file) is skipped by every statistic: `count(*)` counts the 6 rows, `count(price)` the 5 values.
- `sum` of an integer column is a `Decimal` in SQL, as in DuckDB, where its type is a 128-bit integer.
- `df.mean()`, `df.max()` and the other reductions of a frame give one row; select the column first (`df[["price"]]`) to get only its statistic.
- Not run yet: `median`, `stddev`, `var` and their SQL spellings, on the SQL, pandas-shaped and polars-shaped sides alike, grouped or not: komira-ai/komira#2367. The engine refuses them when the query runs, and `probe_median.py` beside this page tries `df[["price"]].median()` and must fail with the line in `probe_median.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- Percentiles (`quantile_cont`, `approx_quantile`) are refused by name in SQL, and `df.describe()` is refused with a pointer to `to_pandas().describe()`.
- A `Series` has no reductions of its own: take them from the frame.

## Related

- [How do I compute several aggregates at once with named outputs?](../25-compute-aggregates-once-named-outputs/page.md) (rank 25, works)
- How do I group by a column and sum another column? (rank 4, works; no page yet)
- How do I count the rows of a table? (rank 62, works; no page yet)
- How do I get the distinct values of a column? (rank 63, works; no page yet)

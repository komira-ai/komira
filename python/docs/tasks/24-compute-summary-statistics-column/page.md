# How do I compute summary statistics of a column?

Aggregate the column in SQL (`count`, `min`, `max`, `sum`, `avg`, `median`, `stddev_samp`, `var_samp`, `quantile_cont`), or call the reduction on a pandas-shaped frame (`df[["price"]].median()`, `.std()`, `.var()`, and `df["price"].quantile(q)` for one number) or a polars-shaped expression.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

def rounded(rows):
    """Floats to 3 places, so the printed line does not depend on the last bit."""
    return [{k: round(v, 3) for k, v in row.items()} for row in rows]


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

    # The median and the quartiles, and the sample standard deviation and variance.
    spread = s.sql(
        "SELECT median(price) AS median, quantile_cont(price, 0.25) AS q1, quantile_cont(price, 0.75) AS q3,"
        " stddev_samp(price) AS sd, var_samp(price) AS var"
        " FROM prices"
    )
    print(rounded(spread.to_arrow().to_pylist()))

# pandas-shaped: each reduction is a method of the frame, one row back.
df = komira.read_csv("prices.csv")
prices = df[["price"]]
print(prices.mean().materialize().to_arrow().to_pylist())
print(prices.max().materialize().to_arrow().to_pylist())
print(prices.median().materialize().to_arrow().to_pylist())
print(rounded(prices.std().materialize().to_arrow().to_pylist()))
print(rounded(prices.var().materialize().to_arrow().to_pylist()))

# Several statistics at once, each named.
named = df.agg(n=("price", "count"), lo=("price", "min"), hi=("price", "max"), mean=("price", "mean"))
print(named.materialize().to_arrow().to_pylist())

# A quantile of a column is one number, a float, so Series.quantile runs at once.
print(df["price"].quantile(0.75))

# polars-shaped: aggregate expressions in select.
lf = pl.scan_csv("prices.csv")
print(lf.select(pl.col("price").mean().alias("mean"), pl.col("price").max().alias("hi")).collect().to_arrow().to_pylist())
spread = lf.select(
    pl.col("price").median().alias("median"),
    pl.col("price").std().alias("std"),
    pl.col("price").var(ddof=0).alias("var_pop"),
)
print(rounded(spread.collect().to_arrow().to_pylist()))
```

Output:

<!-- include expected_output.txt -->
```text
[{'rows': 6, 'n': 5, 'distinct_n': 4, 'lo': 10, 'hi': 50, 'total': Decimal('130'), 'mean': 26.0}]
[{'median': 20.0, 'q1': 20.0, 'q3': 30.0, 'sd': 15.166, 'var': 230.0}]
[{'price': 26.0}]
[{'price': 50}]
[{'price': 20.0}]
[{'price': 15.166}]
[{'price': 230.0}]
[{'n': 5, 'lo': 10, 'hi': 50, 'mean': 26.0}]
30.0
[{'mean': 26.0, 'hi': 50}]
[{'median': 20.0, 'std': 15.166, 'var_pop': 184.0}]
```

## Notes

- A missing value (an empty field in a CSV file) is skipped by every statistic: `count(*)` counts the 6 rows, `count(price)` the 5 values.
- `sum` of an integer column is a `Decimal` in SQL, as in DuckDB, where its type is a 128-bit integer.
- `df.mean()`, `df.max()` and the other reductions of a frame give one row; select the column first (`df[["price"]]`) to get only its statistic.
- `median`, `stddev` and `variance` skip missing values, as the other statistics do. `stddev` and `variance` are the sample ones, the same as `stddev_samp` and `var_samp`; `stddev_pop` and `var_pop` are the population ones. Over one value the sample ones are NULL and the population ones 0; over no value every one of them is NULL.
- In the pandas-shaped frame `std()` and `var()` take `ddof=1` (the sample one, the default) or `ddof=0` (the population one); any other `ddof` is refused by name. The polars-shaped `std(ddof)` and `var(ddof)` take the same two. The same reductions work on `df.groupby(...)` and in `df.agg(...)`, and in SQL with `GROUP BY`.
- `median` and `quantile_cont` run over integer and floating-point columns and give a float; over a decimal column or a column that is not a number the engine refuses them by name. `quantile_cont(x, q)` takes one constant `q` from 0 to 1; a list of fractions, `quantile_disc` and `quantile` are refused by name.
- `df["price"].quantile(q)` is the one `Series` method that runs a query: like pandas it gives a Python float (NaN when the column has no values), by linear interpolation, which is `quantile_cont`. It takes one `q` from 0 to 1; a list of fractions and an `interpolation` other than `"linear"` are refused by name.
- The statistics are printed rounded to three places so that the output does not depend on the last bit of a float.
- `df.describe()` is refused with a pointer to `to_pandas().describe()`; ask for each statistic as above.

## Related

- [How do I compute several aggregates at once with named outputs?](../25-compute-aggregates-once-named-outputs/page.md) (rank 25, works)
- How do I group by a column and sum another column? (rank 4, works; no page yet)
- [How do I count the rows of a table?](../62-count-rows-table/page.md) (rank 62, works)
- [How do I get the distinct values of a column?](../63-get-distinct-values-column/page.md) (rank 63, works)

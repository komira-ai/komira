# How do I group by a column and sum another column?

Group by the column in SQL with `GROUP BY` and `sum()`, or call `df.groupby("region")["amount"].sum()` on a pandas-shaped frame, or `group_by("region").agg(kpl.col("amount").sum())` on a polars-shaped one.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

Path("orders.csv").write_text(
    "order_id,region,amount\n"
    "1,east,120.5\n"
    "2,west,80.0\n"
    "3,east,45.25\n"
    "4,north,200.0\n"
    "5,west,150.5\n"
)

# SQL: GROUP BY the column, sum() the other, ORDER BY to fix the row order.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    totals = s.sql(
        "SELECT region, sum(amount) AS total FROM orders"
        " GROUP BY region ORDER BY region"
    )
    print(totals.to_arrow().to_pylist())

# pandas-shaped: groupby sorts the groups by their keys, as pandas does.
df = komira.read_csv("orders.csv")
print(df.groupby("region")["amount"].sum().materialize().to_arrow().to_pylist())

# Name the output column.
named = df.groupby("region").agg(total=("amount", "sum"))
print(named.materialize().to_arrow().to_pylist())

# polars-shaped: group_by has no row order, so sort the answer.
lf = kpl.scan_csv("orders.csv")
by_region = lf.group_by("region").agg(kpl.col("amount").sum()).sort("region")
print(by_region.collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'region': 'east', 'total': 165.75}, {'region': 'north', 'total': 200.0}, {'region': 'west', 'total': 230.5}]
[{'region': 'east', 'amount': 165.75}, {'region': 'north', 'amount': 200.0}, {'region': 'west', 'amount': 230.5}]
[{'region': 'east', 'total': 165.75}, {'region': 'north', 'total': 200.0}, {'region': 'west', 'total': 230.5}]
[{'region': 'east', 'amount': 165.75}, {'region': 'north', 'amount': 200.0}, {'region': 'west', 'amount': 230.5}]
```

## Notes

- `groupby(...)` sorts the groups by their keys, as pandas does (`sort=True`); with `sort=False` the rows come back in no promised order. A SQL `GROUP BY` and a polars-shaped `group_by` promise no order either, so sort the answer with `ORDER BY` or `.sort(...)`.
- A pandas-shaped `groupby` leaves out the rows whose key is missing; `dropna=False` keeps them as one group, last. SQL and the polars-shaped `group_by` keep a NULL key as a group of its own.
- Missing values are skipped by `sum`. A group with no values sums to 0 in the pandas-shaped frame; `sum(min_count=1)` leaves it missing.
- The key columns come first in the answer and are always columns: a komira frame has no index, so `as_index` changes nothing.
- A SQL `sum()` of an integer column comes back as `DECIMAL(38, 0)`, which Python reads as `Decimal`; the pandas-shaped and polars-shaped frames keep `int64`. The example sums a float column, whose total is a float in all three.
- `agg` takes the name of a reduction (`"sum"`, `"mean"`, `"min"`, `"max"`, `"count"`, `"size"`, `"nunique"`), not a Python function. `komira.NamedAgg` is refused: use a tuple, `agg(out=("column", "func"))`.

## Related

- [How do I count how many times each value appears?](../9-count-each-value/page.md) (rank 9, works)
- [How do I sort rows by one or more columns?](../8-sort-rows-by-columns/page.md) (rank 8, works)
- How do I compute several aggregates at once with named outputs? (rank 25, works; no page yet)
- [How do I compute summary statistics of a column?](../24-compute-summary-statistics-column/page.md) (rank 24, partial)

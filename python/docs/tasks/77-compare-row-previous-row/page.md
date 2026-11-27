# How do I compare each row with the previous row (lag, lead, change)?

In SQL use the window functions `lag` and `lead`, and take the change as `x - prev` over them in an outer query; on a sorted pandas-shaped frame use `shift()`, `diff()` and `pct_change()` of a column, and in `komira.pl` `shift()` and `diff()`.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

# Daily sales, one row per step t.
Path("sales.csv").write_text("t,sales\n1,10\n2,13\n3,13\n4,9\n")

# SQL: lag looks at the previous row in the window's order, lead at the next
# one; both read NULL where there is no such row. The change from the
# previous row is the value minus its lag, taken in an outer query.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    for row in s.sql(
        "SELECT t, sales, prev, nxt, sales - prev AS change FROM ("
        "  SELECT t, sales,"
        "  lag(sales) OVER (ORDER BY t) AS prev,"
        "  lead(sales) OVER (ORDER BY t) AS nxt"
        "  FROM sales"
        ") ORDER BY t"
    ).to_arrow().to_pylist():
        print(row)

# pandas-shaped: sort the frame, then shift, diff and pct_change of a column.
# shift(-1) looks one row ahead; diff and pct_change answer floats, as pandas.
df = komira.read_csv("sales.csv").sort_values("t")
changes = df.assign(
    prev=df["sales"].shift(1),
    nxt=df["sales"].shift(-1),
    change=df["sales"].diff(),
    pct=df["sales"].pct_change(),
)
for row in changes.materialize().to_arrow().to_pylist():
    row["pct"] = None if row["pct"] is None else round(row["pct"], 4)
    print(row)

# polars-shaped: shift and diff on a sorted frame; diff keeps the int type.
lf = kpl.scan_csv("sales.csv").sort("t").with_columns(
    kpl.col("sales").shift(1).alias("prev"),
    kpl.col("sales").diff().alias("change"),
)
for row in lf.collect().to_arrow().to_pylist():
    print(row)
```

Output:

<!-- include expected_output.txt -->
```text
{'t': 1, 'sales': 10, 'prev': None, 'nxt': 13, 'change': None}
{'t': 2, 'sales': 13, 'prev': 10, 'nxt': 13, 'change': 3}
{'t': 3, 'sales': 13, 'prev': 13, 'nxt': 9, 'change': 0}
{'t': 4, 'sales': 9, 'prev': 13, 'nxt': None, 'change': -4}
{'t': 1, 'sales': 10, 'prev': None, 'nxt': 13, 'change': None, 'pct': None}
{'t': 2, 'sales': 13, 'prev': 10, 'nxt': 13, 'change': 3.0, 'pct': 0.3}
{'t': 3, 'sales': 13, 'prev': 13, 'nxt': 9, 'change': 0.0, 'pct': 0.0}
{'t': 4, 'sales': 9, 'prev': 13, 'nxt': None, 'change': -4.0, 'pct': -0.3077}
{'t': 1, 'sales': 10, 'prev': None, 'change': None}
{'t': 2, 'sales': 13, 'prev': 10, 'change': 3}
{'t': 3, 'sales': 13, 'prev': 13, 'change': 0}
{'t': 4, 'sales': 9, 'prev': 13, 'change': -4}
```

## Notes

- `lag(x)` is the value of `x` one row back in the window's order, and `lead(x)` one row ahead; `lag(x, 2)` goes two rows back, and `lag(x, 1, 0)` reads 0 instead of NULL where there is no such row.
- The order is the one in `OVER (ORDER BY ...)`; add `PARTITION BY k` to compare within each group, so the first row of every group has no previous row.
- A row with no previous (or next) row reads NULL, and so does its change.
- A window function must be a whole item of the `SELECT` list today: `sales - lag(sales) OVER (ORDER BY t)` in one item is refused by name, so the example takes the difference in an outer query (komira-ai/komira#2379).
- The pandas-shaped verbs read the frame's sort as the row order, so sort first: on a frame that is not sorted, `df["sales"].shift(1)` is refused with `UnsupportedOperation`, as `rolling` is. `shift(n)` goes `n` rows back and `shift(-n)` `n` rows ahead; `diff(n)` is `x - x.shift(n)` and `pct_change(n)` is `x / x.shift(n) - 1`, and both answer float64, as pandas does for an integer column. A previous value of 0 gives `inf`, `-inf` or `NaN` in `pct_change`, as pandas divides.
- `shift` keeps the column's type, so the frame's `prev` above is an integer column with a NULL; pandas itself holds that column as float64 with `NaN`, which is what `to_pandas()` gives. `fill_value`, `freq` and `suffix` are refused by name.
- In `komira.pl`, `shift` and `diff` read the frame's sort, or `.over(..., order_by=...)`, and `diff` keeps the integer type as polars does. `diff(null_behavior="drop")` is refused by name.
- `shift` reads int64, float64 and string columns, and `diff` and `pct_change` int64 and float64 ones (in `komira.pl` also int8 to int32 and float32); a column of another type, such as a timestamp, is refused by name, as SQL's `lag` and `lead` refuse it. In `pct_change` a previous value of -0.0 counts as 0, so its infinity takes the sign of the value, where pandas flips it.

## Related

- How do I compute a rolling average? (rank 76, works)
- How do I add days to a date or take the difference between dates? (rank 79, partial)

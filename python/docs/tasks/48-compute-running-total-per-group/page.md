# How do I compute a running total per group?

Use `SUM(...) OVER (PARTITION BY group ORDER BY ...)` in SQL, or sort a pandas-shaped frame and take `groupby(key)[column].cumsum()`.

<!-- include example.py -->
```python
from pathlib import Path

import komira

# Sales per store and day, not in order.
Path("sales.csv").write_text(
    "store,day,amount\n"
    "north,2,30\n"
    "south,1,5\n"
    "north,1,10\n"
    "south,2,15\n"
    "north,3,20\n"
)

# SQL: a window function, one running total per store.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    sql = (
        "SELECT store, day, amount,"
        " SUM(amount) OVER (PARTITION BY store ORDER BY day"
        " ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running"
        " FROM sales ORDER BY store, day"
    )
    for row in s.sql(sql).to_arrow().to_pylist():
        print(row)

# pandas-shaped: sort, then cumsum within each group.
df = komira.read_csv("sales.csv").sort_values(["store", "day"])
df["running"] = df.groupby("store")["amount"].cumsum()
print(df.materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'store': 'north', 'day': 1, 'amount': 10, 'running': 10}
{'store': 'north', 'day': 2, 'amount': 30, 'running': 40}
{'store': 'north', 'day': 3, 'amount': 20, 'running': 60}
{'store': 'south', 'day': 1, 'amount': 5, 'running': 5}
{'store': 'south', 'day': 2, 'amount': 15, 'running': 20}
[{'store': 'north', 'day': 1, 'amount': 10, 'running': 10}, {'store': 'north', 'day': 2, 'amount': 30, 'running': 40}, {'store': 'north', 'day': 3, 'amount': 20, 'running': 60}, {'store': 'south', 'day': 1, 'amount': 5, 'running': 5}, {'store': 'south', 'day': 2, 'amount': 15, 'running': 20}]
```

## Notes

- The window frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` adds each row to the rows before it in its partition; without `ROWS`, SQL's default frame treats rows with equal `ORDER BY` values as one step.
- A pandas-shaped `cumsum()`, `cummin()` and `cummax()` follow the order the frame was sorted into, so call `sort_values` first; on a frame that is not sorted they are refused, since it has no row order.
- `groupby(key)[column].transform("cumsum")` is refused today (`transform` takes count, max, mean, min or sum); use `cumsum()` on the group.
- A missing value stays missing in the running total (`skipna=True`).
- The new column is assigned to the frame and runs with it; `materialize()` runs the frame.

## Related

- [How do I get the top N rows per group?](../47-get-top-n-rows-per-group/page.md) (rank 47, partial)
- [How do I rank rows within a group?](../49-rank-rows-within-group/page.md) (rank 49, works)
- [How do I compute each row's percent of its group total?](../50-percent-of-group-total/page.md) (rank 50, partial)

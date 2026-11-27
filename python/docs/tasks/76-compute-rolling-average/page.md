# How do I compute a rolling average?

Average over a window of rows with `avg(x) OVER (ORDER BY d ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)`, or sort a pandas-shaped frame and call `rolling(3).mean()` on a column.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("sales.csv").write_text(
    "day_no,sales\n"
    "1,10\n"
    "2,20\n"
    "3,60\n"
    "4,40\n"
    "5,50\n"
)

# SQL: average over the row and the two before it, in day order.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    avg = s.sql(
        "SELECT day_no, sales,"
        " avg(sales) OVER (ORDER BY day_no ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS avg3"
        " FROM sales ORDER BY day_no"
    )
    print(avg.to_arrow().to_pylist())

# pandas-shaped: sort the frame, then rolling(3).mean() of a column.
df = komira.read_csv("sales.csv").sort_values("day_no")
full = df.assign(avg3=df["sales"].rolling(3).mean())
print(full.materialize().to_arrow().column("avg3").to_pylist())

# min_periods=1 averages the first rows over the rows there are, as the SQL does.
early = df.assign(avg3=df["sales"].rolling(3, min_periods=1).mean())
print(early.materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'day_no': 1, 'sales': 10, 'avg3': 10.0}, {'day_no': 2, 'sales': 20, 'avg3': 15.0}, {'day_no': 3, 'sales': 60, 'avg3': 30.0}, {'day_no': 4, 'sales': 40, 'avg3': 40.0}, {'day_no': 5, 'sales': 50, 'avg3': 50.0}]
[None, None, 30.0, 40.0, 50.0]
[{'day_no': 1, 'sales': 10, 'avg3': 10.0}, {'day_no': 2, 'sales': 20, 'avg3': 15.0}, {'day_no': 3, 'sales': 60, 'avg3': 30.0}, {'day_no': 4, 'sales': 40, 'avg3': 40.0}, {'day_no': 5, 'sales': 50, 'avg3': 50.0}]
```

## Notes

- The window is the row and the rows before it in the `ORDER BY`, so the first rows average over fewer than three values. `avg` of an integer column is a double.
- `rolling(3)` gives a missing value (`None` in `to_pylist()`) until three rows are there; `min_periods=1` answers from the first row, as the SQL does. The result is float64.
- On the pandas-shaped frame, `rolling` needs a sorted frame (`sort_values`) and is refused on an unsorted one; a centred or time-based window (`rolling("7D")`, `center=True`) is refused by name.
- The polars-shaped `komira.pl` has `rolling_mean(window_size, min_samples=...)`, read from the frame's sort or `over(order_by=...)`.
- Rolling windows are exact only in the data's order: sort by day (or `ORDER BY`) so the output order is promised.

## Related

- How do I compare each row with the previous row (lag, lead, change)? (rank 77, partial)
- How do I group by month or week? (rank 80, partial)

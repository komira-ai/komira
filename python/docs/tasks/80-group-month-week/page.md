# How do I group by month or week?

Cut the date down with `date_trunc('month', d)` or `date_trunc('week', d)` and `GROUP BY` that; on a pandas-shaped frame, add `.dt.year` and `.dt.month` as columns and group by them.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("orders.csv").write_text(
    "order_id,order_date,amount\n"
    "1,2024-01-03,10\n"
    "2,2024-01-15,20\n"
    "3,2024-01-16,5\n"
    "4,2024-02-05,40\n"
    "5,2024-02-07,15\n"
    "6,2024-02-29,30\n"
)

# SQL: date_trunc cuts a date down to the first day of its month or week.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    by_month = s.sql(
        "SELECT date_trunc('month', order_date) AS month_start, count(*) AS n"
        " FROM orders GROUP BY 1 ORDER BY month_start"
    )
    print(by_month.to_arrow().to_pylist())

    # Weeks start on Monday.
    by_week = s.sql(
        "SELECT date_trunc('week', order_date) AS week_start, count(*) AS n"
        " FROM orders GROUP BY 1 ORDER BY week_start"
    )
    print(by_week.to_arrow().to_pylist())

# pandas-shaped: add the year and the month as columns, then group by them.
df = komira.read_csv("orders.csv")
df = df.assign(year=df["order_date"].dt.year, month=df["order_date"].dt.month)
print(df.groupby(["year", "month"]).size().materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'month_start': datetime.date(2024, 1, 1), 'n': 3}, {'month_start': datetime.date(2024, 2, 1), 'n': 3}]
[{'week_start': datetime.date(2024, 1, 1), 'n': 1}, {'week_start': datetime.date(2024, 1, 15), 'n': 2}, {'week_start': datetime.date(2024, 2, 5), 'n': 2}, {'week_start': datetime.date(2024, 2, 26), 'n': 1}]
[{'year': 2024, 'month': 1, 'size': 3}, {'year': 2024, 'month': 2, 'size': 3}]
```

## Notes

- `date_trunc` of a date is a date: the first day of the month, or the Monday that starts the week (ISO weeks). `date_trunc` of a timestamp stays a timestamp, cut to the start of the unit (midnight of the first day for month and week).
- `date_trunc` also takes `year`, `quarter` and `day`, and the same unit's DuckDB aliases.
- The pandas-shaped frame has no `.dt.week`, no `resample` and no `.dt.to_period`: group by `.dt.year` and `.dt.month` as above, or use SQL for weeks.
- komira.pl (the polars-shaped door) has no `dt.truncate`; use SQL for a truncated date.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`. A pandas-shaped `groupby` sorts by its keys.

## Related

- How do I compute a rolling average? (rank 76, works)
- How do I compare each row with the previous row (lag, lead, change)? (rank 77, partial)
- How do I add days to a date or take the difference between dates? (rank 79, partial)

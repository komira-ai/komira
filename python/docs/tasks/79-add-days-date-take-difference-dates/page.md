# How do I add days to a date or take the difference between dates?

Take the difference in days with `date_diff('day', a, b)` in SQL, and add days to a date column with `order_date + INTERVAL '7' DAY` (a timestamp) or `order_date + 7` (a date).

<!-- include example.py -->
```python
from pathlib import Path

import komira

# Orders with the day each was placed and the day it shipped. A column of
# YYYY-MM-DD values is read as a date.
Path("orders.csv").write_text(
    "id,order_date,ship_date\n"
    "1,2024-01-30,2024-02-02\n"
    "2,2024-02-27,2024-03-01\n"
    "3,2024-03-05,2024-03-05\n"
    "4,2023-12-30,2024-01-03\n"
    "5,2024-01-31,2024-02-20\n"
)

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")

    # date_diff('day', a, b) is the number of days from a to b, as an integer.
    # A date plus an INTERVAL is a timestamp at midnight, as in DuckDB; a
    # date plus a whole number of days is a date. A month is added by calendar
    # month, and a day that the month does not have becomes its last day.
    rows = s.sql(
        "SELECT id,"
        " date_diff('day', order_date, ship_date) AS days,"
        " order_date + INTERVAL '7' DAY AS week_on,"
        " order_date + INTERVAL '1' MONTH AS month_on,"
        " order_date + 7 AS seven_days_on"
        " FROM orders ORDER BY id"
    ).to_arrow().to_pylist()

    # A shifted date compares with another date column: the orders that
    # shipped more than a week after they were placed.
    late = s.sql(
        "SELECT id FROM orders"
        " WHERE ship_date > order_date + INTERVAL '7' DAY ORDER BY id"
    ).to_arrow().to_pylist()

for row in rows:
    print(row["id"], row["days"], row["week_on"], row["month_on"], row["seven_days_on"])
print("late:", [row["id"] for row in late])
```

Output:

<!-- include expected_output.txt -->
```text
1 3 2024-02-06 00:00:00 2024-02-29 00:00:00 2024-02-06
2 3 2024-03-05 00:00:00 2024-03-27 00:00:00 2024-03-05
3 0 2024-03-12 00:00:00 2024-04-05 00:00:00 2024-03-12
4 4 2024-01-06 00:00:00 2024-01-30 00:00:00 2024-01-06
5 20 2024-02-07 00:00:00 2024-02-29 00:00:00 2024-02-07
late: [5]
```

## Notes

- `date_diff('day', a, b)` counts the day boundaries crossed from `a` to `b`, so it is negative when `b` is before `a`; `'week'`, `'month'`, `'year'` and the units below a day work the same way, and `date_sub` counts complete units instead. Both take two dates or two timestamps, as columns or literals, and answer an integer (NULL when either is NULL). `datediff` is another spelling of `date_diff`.
- Adding to a date column works in SQL, with the answers DuckDB gives. `order_date + INTERVAL '7' DAY`, `INTERVAL '7' DAY + order_date`, `order_date - INTERVAL '7' DAY` and `date_add(order_date, INTERVAL '7' DAY)` answer a timestamp at midnight (`datetime.datetime` in Python), also for day units; `order_date + 7`, `7 + order_date` and `order_date - 7` add whole days and answer a date (`datetime.date`). The units are day, week, month and year.
- A month or a year is added by calendar month and keeps the day of the month, or the last day of the month when it has no such day: `2024-01-31 + INTERVAL '1' MONTH` is `2024-02-29`, `2023-01-31 + INTERVAL '1' MONTH` is `2023-02-28`, and `2024-02-29 - INTERVAL '1' YEAR` is `2023-02-28`. A NULL date stays NULL.
- The interval must be a constant: `INTERVAL (n) DAY` with a column for the count is refused by name as a non-constant interval. There is no interval value in a query, so `date - date` giving an interval is not available: use `date_diff`.
- A constant date plus an interval, `DATE '2024-03-01' + INTERVAL '30' DAY`, is folded to a date when the query is bound; DuckDB answers a timestamp there. Compared with a date column it selects the same rows.
- This page covers SQL only. Adding a `pd.Timedelta` to a date column of the pandas-shaped frame (`df["d"] + pd.Timedelta(days=7)` after `komira.read_csv`) is out of its scope, and the frame has no timedelta type: the timedelta accessors (`.dt.total_seconds`, `.dt.days`) are refused by name. Add days and take the difference with SQL as above.

## Related

- How do I compute a rolling average? (rank 76, works)
- How do I compare each row with the previous row (lag, lead, change)? (rank 77, partial)
- How do I group by month or week? (rank 80, partial)
- How do I convert time zones? (rank 78, gap; no page yet)

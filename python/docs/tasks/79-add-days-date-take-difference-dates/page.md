# How do I add days to a date or take the difference between dates?

Take the difference in days with `date_diff('day', a, b)` in SQL, and add days to a date by adding a `datetime.timedelta` to the date once the rows are Python values.

<!-- include example.py -->
```python
from datetime import timedelta
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
)

# date_diff('day', a, b) is the number of days from a to b, as an integer.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    rows = s.sql(
        "SELECT id, order_date, date_diff('day', order_date, ship_date) AS days"
        " FROM orders ORDER BY id"
    ).to_arrow().to_pylist()

# The rows are Python values, so a date plus a timedelta is a date a week on.
for row in rows:
    print(row["id"], row["days"], row["order_date"] + timedelta(days=7))
```

Output:

<!-- include expected_output.txt -->
```text
1 3 2024-02-06
2 3 2024-03-05
3 0 2024-03-12
4 4 2024-01-06
```

## Notes

- `date_diff('day', a, b)` counts the day boundaries crossed from `a` to `b`, so it is negative when `b` is before `a`; `'week'`, `'month'`, `'year'` and the units below a day work the same way, and `date_sub` counts complete units instead. Both take two dates or two timestamps, as columns or literals, and answer an integer (NULL when either is NULL). `datediff` is another spelling of `date_diff`.
- Adding days inside SQL works only for a constant: `DATE '2024-03-01' + INTERVAL '30' DAY` (units day, week, month, year) is folded to a date when the query is bound. Adding an interval to a date column is not supported yet (komira-ai/komira#2388): `probe_column_plus_interval.py` beside this page tries `order_date + INTERVAL '7' DAY` and must fail with the line in `probe_column_plus_interval.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it. Until then, add the days in Python as above, or select the dates and shift them there.
- `date_add` is refused by name (it takes an interval), and there is no interval value in a query, so `date - date` giving an interval is not available: use `date_diff`.
- The pandas-shaped frame (`komira.read_csv`) has no timedelta type: `.dt.total_seconds`, `.dt.days` and the other timedelta accessors are refused by name, so take the difference with `date_diff` in SQL.

## Related

- How do I compute a rolling average? (rank 76, works)
- How do I compare each row with the previous row (lag, lead, change)? (rank 77, works)
- How do I group by month or week? (rank 80, partial)
- How do I convert time zones? (rank 78, gap; no page yet)

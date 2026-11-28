# How do I extract year, month and weekday from a date column?

Call `year(d)`, `month(d)` and `isodow(d)` in SQL, or read `.dt.year`, `.dt.month` and `.dt.weekday` of a date column on a pandas-shaped frame; `dayname(d)` and `monthname(d)` in SQL, and `.dt.day_name()` and `.dt.month_name()`, give the weekday and the month as a name.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("days.csv").write_text(
    "id,d\n"
    "1,2026-10-01\n"
    "2,2026-10-03\n"
    "3,2026-11-15\n"
    "4,2026-12-25\n"
)

# SQL: year(), month() and isodow() (Monday is 1 ... Sunday is 7) read a date;
# dayname() and monthname() name its weekday and month.
with komira.Session() as s:
    s.register_csv("days", "days.csv")
    parts = s.sql(
        "SELECT d, year(d) AS yr, month(d) AS mon, isodow(d) AS dow,"
        " dayname(d) AS day, monthname(d) AS month_name"
        " FROM days ORDER BY id"
    )
    print(parts.to_arrow().to_pylist())

# pandas-shaped: the .dt accessor of a date column. Monday is 0, as in pandas.
df = komira.read_csv("days.csv")
parts = df.assign(
    year=df["d"].dt.year,
    month=df["d"].dt.month,
    weekday=df["d"].dt.weekday,
    day_name=df["d"].dt.day_name(),
    month_name=df["d"].dt.month_name(),
).sort_values("id")[["d", "year", "month", "weekday", "day_name", "month_name"]]
print(parts.materialize().to_arrow().to_pylist())

# The parts are ordinary columns: here, the rows that fall on a weekend.
weekend = df[df["d"].dt.weekday >= 5][["id"]]
print(weekend.sort_values("id").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'d': datetime.date(2026, 10, 1), 'yr': 2026, 'mon': 10, 'dow': 4, 'day': 'Thursday', 'month_name': 'October'}, {'d': datetime.date(2026, 10, 3), 'yr': 2026, 'mon': 10, 'dow': 6, 'day': 'Saturday', 'month_name': 'October'}, {'d': datetime.date(2026, 11, 15), 'yr': 2026, 'mon': 11, 'dow': 7, 'day': 'Sunday', 'month_name': 'November'}, {'d': datetime.date(2026, 12, 25), 'yr': 2026, 'mon': 12, 'dow': 5, 'day': 'Friday', 'month_name': 'December'}]
[{'d': datetime.date(2026, 10, 1), 'year': 2026, 'month': 10, 'weekday': 3, 'day_name': 'Thursday', 'month_name': 'October'}, {'d': datetime.date(2026, 10, 3), 'year': 2026, 'month': 10, 'weekday': 5, 'day_name': 'Saturday', 'month_name': 'October'}, {'d': datetime.date(2026, 11, 15), 'year': 2026, 'month': 11, 'weekday': 6, 'day_name': 'Sunday', 'month_name': 'November'}, {'d': datetime.date(2026, 12, 25), 'year': 2026, 'month': 12, 'weekday': 4, 'day_name': 'Friday', 'month_name': 'December'}]
[{'id': 2}, {'id': 3}]
```

## Notes

- A CSV column whose every value is `YYYY-MM-DD` is read as a date, so no conversion is needed first.
- The weekday number depends on the spelling: SQL `isodow` counts Monday as 1 and Sunday as 7, while `.dt.weekday` (also `.dt.dayofweek`) counts Monday as 0, as pandas does. SQL `dayofweek` counts Sunday as 0.
- `.dt` also has `quarter`, `day` and `dayofyear`, and for a timestamp column `hour`, `minute` and `second`. Every part is an int64 column, except the names, which are string columns.
- The example sorts by `id`, not by the date: sorting by a date column (`ORDER BY d`, `sort_values("d")`) fails today, komira-ai/komira#2408.
- The names are English, as DuckDB's `dayname` and `monthname` are: `Monday` to `Sunday` and `January` to `December`. `.dt.day_name(locale=...)` and `.dt.month_name(locale=...)` are refused, since there is no other language to give. A missing date gives a missing name, and a timestamp gives the name of its date.

## Related

- [How do I parse strings into dates?](../23-parse-strings-dates/page.md) (rank 23, partial)
- [How do I add days to a date or take the difference between dates?](../79-add-days-date-take-difference-dates/page.md) (rank 79, partial)
- [How do I group by month or week?](../80-group-month-week/page.md) (rank 80, partial)
- [How do I filter rows by a date range?](../83-filter-rows-date-range/page.md) (rank 83, works)

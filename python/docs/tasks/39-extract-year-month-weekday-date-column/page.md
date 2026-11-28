# How do I extract year, month and weekday from a date column?

Call `year(d)`, `month(d)` and `isodow(d)` in SQL, or read `.dt.year`, `.dt.month` and `.dt.weekday` of a date column on a pandas-shaped frame.

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

# SQL: year(), month() and isodow() (Monday is 1 ... Sunday is 7) read a date.
with komira.Session() as s:
    s.register_csv("days", "days.csv")
    parts = s.sql(
        "SELECT d, year(d) AS yr, month(d) AS mon, isodow(d) AS dow"
        " FROM days ORDER BY id"
    )
    print(parts.to_arrow().to_pylist())

# pandas-shaped: the .dt accessor of a date column. Monday is 0, as in pandas.
df = komira.read_csv("days.csv")
parts = df.assign(
    year=df["d"].dt.year,
    month=df["d"].dt.month,
    weekday=df["d"].dt.weekday,
).sort_values("id")[["d", "year", "month", "weekday"]]
print(parts.materialize().to_arrow().to_pylist())

# The parts are ordinary columns: here, the rows that fall on a weekend.
weekend = df[df["d"].dt.weekday >= 5][["id"]]
print(weekend.sort_values("id").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'d': datetime.date(2026, 10, 1), 'yr': 2026, 'mon': 10, 'dow': 4}, {'d': datetime.date(2026, 10, 3), 'yr': 2026, 'mon': 10, 'dow': 6}, {'d': datetime.date(2026, 11, 15), 'yr': 2026, 'mon': 11, 'dow': 7}, {'d': datetime.date(2026, 12, 25), 'yr': 2026, 'mon': 12, 'dow': 5}]
[{'d': datetime.date(2026, 10, 1), 'year': 2026, 'month': 10, 'weekday': 3}, {'d': datetime.date(2026, 10, 3), 'year': 2026, 'month': 10, 'weekday': 5}, {'d': datetime.date(2026, 11, 15), 'year': 2026, 'month': 11, 'weekday': 6}, {'d': datetime.date(2026, 12, 25), 'year': 2026, 'month': 12, 'weekday': 4}]
[{'id': 2}, {'id': 3}]
```

## Notes

- A CSV column whose every value is `YYYY-MM-DD` is read as a date, so no conversion is needed first.
- The weekday number depends on the spelling: SQL `isodow` counts Monday as 1 and Sunday as 7, while `.dt.weekday` (also `.dt.dayofweek`) counts Monday as 0, as pandas does. SQL `dayofweek` counts Sunday as 0.
- `.dt` also has `quarter`, `day` and `dayofyear`, and for a timestamp column `hour`, `minute` and `second`. Every part is an int64 column.
- The example sorts by `id`, not by the date: sorting by a date column (`ORDER BY d`, `sort_values("d")`) fails today, komira-ai/komira#2408.
- The weekday as a name (`Monday`) is not available yet: `.dt.day_name()` and `.dt.month_name()` are refused, and so are SQL `dayname()` and `monthname()`. `probe_day_name.py` beside this page tries `.dt.day_name()` and must fail with the line in `probe_day_name.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it. komira-ai/komira#2393 tracks it. Until then, map the number to a name in Python.

## Related

- [How do I parse strings into dates?](../23-parse-strings-dates/page.md) (rank 23, partial)
- [How do I add days to a date or take the difference between dates?](../79-add-days-date-take-difference-dates/page.md) (rank 79, works)
- [How do I group by month or week?](../80-group-month-week/page.md) (rank 80, partial)
- [How do I filter rows by a date range?](../83-filter-rows-date-range/page.md) (rank 83, works)

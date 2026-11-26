# How do I resample a time series to daily, weekly or monthly?

Cut each date down to the start of its day, week or month with `date_trunc` in SQL, then group by the result and aggregate.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("sales.csv").write_text(
    "sold_on,amount\n"
    "2026-10-01,10.5\n"
    "2026-10-01,4.5\n"
    "2026-10-02,20.0\n"
    "2026-10-05,7.5\n"
    "2026-10-07,8.5\n"
    "2026-10-31,4.0\n"
    "2026-11-02,6.5\n"
    "2026-11-03,9.5\n"
)

# SQL: date_trunc cuts each date down to the start of its day, week (Monday) or month.
# komira cannot sort by a date column yet, so the few buckets are sorted in Python.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    for unit in ("day", "week", "month"):
        rows = s.sql(
            "SELECT bucket, sum(amount) AS total, count(*) AS n FROM ("
            f"SELECT date_trunc('{unit}', sold_on) AS bucket, amount FROM sales"
            ") AS b GROUP BY bucket"
        )
        print(unit, sorted(rows.to_arrow().to_pylist(), key=lambda r: r["bucket"]))

# pandas-shaped: group by the date for days (sort=False, as the date is no sort
# key yet), or by its year and month for months.
df = komira.read_csv("sales.csv")
daily = df.groupby("sold_on", sort=False).agg(total=("amount", "sum"))
print(sorted(daily.materialize().to_arrow().to_pylist(), key=lambda r: r["sold_on"]))

df = df.assign(year=df["sold_on"].dt.year, month=df["sold_on"].dt.month)
monthly = df.groupby(["year", "month"]).agg(total=("amount", "sum"), n=("amount", "size"))
print(monthly.materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
day [{'bucket': datetime.date(2026, 10, 1), 'total': 15.0, 'n': 2}, {'bucket': datetime.date(2026, 10, 2), 'total': 20.0, 'n': 1}, {'bucket': datetime.date(2026, 10, 5), 'total': 7.5, 'n': 1}, {'bucket': datetime.date(2026, 10, 7), 'total': 8.5, 'n': 1}, {'bucket': datetime.date(2026, 10, 31), 'total': 4.0, 'n': 1}, {'bucket': datetime.date(2026, 11, 2), 'total': 6.5, 'n': 1}, {'bucket': datetime.date(2026, 11, 3), 'total': 9.5, 'n': 1}]
week [{'bucket': datetime.date(2026, 9, 28), 'total': 35.0, 'n': 3}, {'bucket': datetime.date(2026, 10, 5), 'total': 16.0, 'n': 2}, {'bucket': datetime.date(2026, 10, 26), 'total': 4.0, 'n': 1}, {'bucket': datetime.date(2026, 11, 2), 'total': 16.0, 'n': 2}]
month [{'bucket': datetime.date(2026, 10, 1), 'total': 55.0, 'n': 6}, {'bucket': datetime.date(2026, 11, 1), 'total': 16.0, 'n': 2}]
[{'sold_on': datetime.date(2026, 10, 1), 'total': 15.0}, {'sold_on': datetime.date(2026, 10, 2), 'total': 20.0}, {'sold_on': datetime.date(2026, 10, 5), 'total': 7.5}, {'sold_on': datetime.date(2026, 10, 7), 'total': 8.5}, {'sold_on': datetime.date(2026, 10, 31), 'total': 4.0}, {'sold_on': datetime.date(2026, 11, 2), 'total': 6.5}, {'sold_on': datetime.date(2026, 11, 3), 'total': 9.5}]
[{'year': 2026, 'month': 10, 'total': 55.0, 'n': 6}, {'year': 2026, 'month': 11, 'total': 16.0, 'n': 2}]
```

## Notes

- `date_trunc('week', ...)` starts the week on Monday: 2026-10-01 and 2026-10-02 fall in the week of 2026-09-28. The other units are `'day'`, `'month'`, `'quarter'` and `'year'`.
- Sorting by a date column fails today (`ORDER BY bucket`, or `groupby` on a date with its default `sort=True`): komira-ai/komira#2408. Until it is fixed, sort the answer in Python, as the example does, or group by integer parts such as `.dt.year` and `.dt.month`, which sort.
- A bucket with no rows has no row in the answer: komira does not fill gaps, so a day, week or month without sales is missing rather than 0.
- The CSV reader infers a date column (`YYYY-MM-DD`) as a date, and `date_trunc` of a date gives a date (DuckDB widens the date and gives a timestamp; the day it names is the same). For a timestamp column (from Parquet, say), `date_trunc` gives a timestamp, and `.dt.floor("D")` on the pandas-shaped frame cuts it to the day, or to `"h"`, `"min"` or `"s"`.
- The pandas-shaped frame has no `resample`: `df.resample(...)` raises `AttributeError`, since a komira frame has no time index, and `.dt.floor` takes no week or month. Group by the date for days, or by `.dt.year` and `.dt.month` for months; for weeks, use the SQL form. `probe_pandas_resample.py` beside this page tries `df.resample("MS", on=...)` and must fail with the line in `probe_pandas_resample.error.txt`; komira-ai/komira#2392 tracks the frame forms. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- There is no polars-shaped form of this task: the `komira.pl` frame has no `dt` namespace or `group_by_dynamic` today.
- Sum a float column here: SQL `sum` of an integer column answers a 128-bit decimal (`Decimal('15')`), not an integer.

## Related

- [How do I extract year, month and weekday from a date column?](../39-extract-year-month-weekday-date-column/page.md) (rank 39, partial)
- How do I group by month or week? (rank 80, works; no page yet)
- How do I fill gaps in a time series so every date is present? (rank 81, gap; no page yet)
- How do I parse strings into dates? (rank 23, partial; no page yet)

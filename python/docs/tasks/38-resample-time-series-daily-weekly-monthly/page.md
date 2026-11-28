# How do I resample a time series to daily, weekly or monthly?

Cut each date down to the start of its day, week or month with `date_trunc` in SQL, then group by the result and aggregate; or write `df.resample(rule, on=column)` on the pandas-shaped frame, or `group_by_dynamic(column, every=...)` on `komira.pl`.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

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

# pandas-shaped: resample by the date column. pandas labels a day by itself, a
# week ("W") by the Sunday that ends it, and a month by its first day ("MS") or
# its last ("ME"). The buckets come in no order, so they are sorted in Python.
df = komira.read_csv("sales.csv")
for rule in ("D", "W", "MS", "ME"):
    totals = df.resample(rule, on="sold_on")["amount"].sum()
    print(rule, sorted(totals.materialize().to_arrow().to_pylist(), key=lambda r: r["sold_on"]))

# polars-shaped: group_by_dynamic names each window by its start, as
# col("sold_on").dt.truncate(every) does (a week starts on Monday).
lf = kpl.scan_csv("sales.csv")
for every in ("1d", "1w", "1mo"):
    windows = lf.group_by_dynamic("sold_on", every=every).agg(
        kpl.col("amount").sum().alias("total"), kpl.len().alias("n")
    )
    print(every, sorted(windows.collect().to_arrow().to_pylist(), key=lambda r: r["sold_on"]))
```

Output:

<!-- include expected_output.txt -->
```text
day [{'bucket': datetime.date(2026, 10, 1), 'total': 15.0, 'n': 2}, {'bucket': datetime.date(2026, 10, 2), 'total': 20.0, 'n': 1}, {'bucket': datetime.date(2026, 10, 5), 'total': 7.5, 'n': 1}, {'bucket': datetime.date(2026, 10, 7), 'total': 8.5, 'n': 1}, {'bucket': datetime.date(2026, 10, 31), 'total': 4.0, 'n': 1}, {'bucket': datetime.date(2026, 11, 2), 'total': 6.5, 'n': 1}, {'bucket': datetime.date(2026, 11, 3), 'total': 9.5, 'n': 1}]
week [{'bucket': datetime.date(2026, 9, 28), 'total': 35.0, 'n': 3}, {'bucket': datetime.date(2026, 10, 5), 'total': 16.0, 'n': 2}, {'bucket': datetime.date(2026, 10, 26), 'total': 4.0, 'n': 1}, {'bucket': datetime.date(2026, 11, 2), 'total': 16.0, 'n': 2}]
month [{'bucket': datetime.date(2026, 10, 1), 'total': 55.0, 'n': 6}, {'bucket': datetime.date(2026, 11, 1), 'total': 16.0, 'n': 2}]
D [{'sold_on': datetime.date(2026, 10, 1), 'amount': 15.0}, {'sold_on': datetime.date(2026, 10, 2), 'amount': 20.0}, {'sold_on': datetime.date(2026, 10, 5), 'amount': 7.5}, {'sold_on': datetime.date(2026, 10, 7), 'amount': 8.5}, {'sold_on': datetime.date(2026, 10, 31), 'amount': 4.0}, {'sold_on': datetime.date(2026, 11, 2), 'amount': 6.5}, {'sold_on': datetime.date(2026, 11, 3), 'amount': 9.5}]
W [{'sold_on': datetime.date(2026, 10, 4), 'amount': 35.0}, {'sold_on': datetime.date(2026, 10, 11), 'amount': 16.0}, {'sold_on': datetime.date(2026, 11, 1), 'amount': 4.0}, {'sold_on': datetime.date(2026, 11, 8), 'amount': 16.0}]
MS [{'sold_on': datetime.date(2026, 10, 1), 'amount': 55.0}, {'sold_on': datetime.date(2026, 11, 1), 'amount': 16.0}]
ME [{'sold_on': datetime.date(2026, 10, 31), 'amount': 55.0}, {'sold_on': datetime.date(2026, 11, 30), 'amount': 16.0}]
1d [{'sold_on': datetime.date(2026, 10, 1), 'total': 15.0, 'n': 2}, {'sold_on': datetime.date(2026, 10, 2), 'total': 20.0, 'n': 1}, {'sold_on': datetime.date(2026, 10, 5), 'total': 7.5, 'n': 1}, {'sold_on': datetime.date(2026, 10, 7), 'total': 8.5, 'n': 1}, {'sold_on': datetime.date(2026, 10, 31), 'total': 4.0, 'n': 1}, {'sold_on': datetime.date(2026, 11, 2), 'total': 6.5, 'n': 1}, {'sold_on': datetime.date(2026, 11, 3), 'total': 9.5, 'n': 1}]
1w [{'sold_on': datetime.date(2026, 9, 28), 'total': 35.0, 'n': 3}, {'sold_on': datetime.date(2026, 10, 5), 'total': 16.0, 'n': 2}, {'sold_on': datetime.date(2026, 10, 26), 'total': 4.0, 'n': 1}, {'sold_on': datetime.date(2026, 11, 2), 'total': 16.0, 'n': 2}]
1mo [{'sold_on': datetime.date(2026, 10, 1), 'total': 55.0, 'n': 6}, {'sold_on': datetime.date(2026, 11, 1), 'total': 16.0, 'n': 2}]
```

## Notes

- `date_trunc('week', ...)` starts the week on Monday: 2026-10-01 and 2026-10-02 fall in the week of 2026-09-28. The other units are `'day'`, `'month'`, `'quarter'` and `'year'`.
- `df.resample(rule, on=column)` takes pandas' rules `"D"`, `"W"` (`"W-SUN"`), `"MS"` and `"ME"` (`"M"`), and labels each bucket as pandas does: a week, Monday to Sunday, by its Sunday, so 2026-10-01 is in the week pandas calls 2026-10-04 and SQL calls 2026-09-28; a month by its first day (`"MS"`) or its last (`"ME"`). The groups are SQL's `date_trunc` groups. A komira frame has no time index, so `on=` is required; the bucket keeps the column's name. Other rules, a multiple such as `"2D"`, and `closed` or `label` other than pandas' default are refused by name, and so is `.dt.floor("W")`, as pandas refuses it.
- `komira.pl` has `col("sold_on").dt.truncate(every)` and `group_by_dynamic("sold_on", every=...)` for `"1d"`, `"1w"` and `"1mo"`, as polars spells them: a window is named by its start, the week from Monday, as in SQL. polars needs the frame sorted by the index first; komira does not, and gives the windows in no order.
- Sorting by a date column fails today (`ORDER BY bucket`, or `groupby` on a date with its default `sort=True`): komira-ai/komira#2408. Until it is fixed, sort the answer in Python, as the example does. `resample` and `group_by_dynamic` give their buckets in no order for the same reason.
- A bucket with no rows has no row in the answer: komira does not fill gaps, so a day, week or month without sales is missing rather than 0 (pandas' `resample` gives such a bucket a row; filling the gaps is komira-ai/komira#2343). A row with no date is in no bucket, as in pandas.
- The CSV reader infers a date column (`YYYY-MM-DD`) as a date, and `date_trunc` of a date gives a date (DuckDB widens the date and gives a timestamp; the day it names is the same); `resample` and `dt.truncate` keep the date too. For a timestamp column (from Parquet, say), each gives a timestamp at the bucket's midnight, and `.dt.floor("D")` on the pandas-shaped frame cuts it to the day, or to `"h"`, `"min"` or `"s"`.
- Sum a float column here: SQL `sum` of an integer column answers a 128-bit decimal (`Decimal('15')`), not an integer.

## Related

- [How do I extract year, month and weekday from a date column?](../39-extract-year-month-weekday-date-column/page.md) (rank 39, partial)
- [How do I group by month or week?](../80-group-month-week/page.md) (rank 80, partial)
- How do I fill gaps in a time series so every date is present? (rank 81, gap; no page yet)
- [How do I parse strings into dates?](../23-parse-strings-dates/page.md) (rank 23, partial)

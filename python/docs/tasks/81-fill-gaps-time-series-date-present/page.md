# How do I fill gaps in a time series so every date is present?

Make every date with `generate_series(start, stop, INTERVAL '1' DAY)` in `FROM`, `LEFT JOIN` the data onto it, and turn the missing values into 0 with `COALESCE`.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("visits.csv").write_text(
    "day,page\n"
    "2024-01-02,home\n"
    "2024-01-02,about\n"
    "2024-01-03,home\n"
    "2024-01-06,pricing\n"
)

with komira.Session() as s:
    s.register_csv("visits", "visits.csv")

    # generate_series gives one row per day from the first date to the last,
    # both included. LEFT JOIN the counts onto it: a day without visits has
    # no count (NULL), and COALESCE makes it 0.
    rows = s.sql(
        "SELECT t.d, COALESCE(v.n, 0) AS n"
        " FROM generate_series(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '1' DAY) AS t(d)"
        " LEFT JOIN (SELECT day, count(*) AS n FROM visits GROUP BY day) AS v"
        " ON v.day = t.d"
        " ORDER BY t.d"
    )
    for r in rows.to_arrow().to_pylist():
        print(r["d"].date(), r["n"])

    # range stops before the end: the Mondays of January 2024.
    weeks = s.sql(
        "SELECT * FROM range(DATE '2024-01-01', DATE '2024-02-01', INTERVAL '1' WEEK)"
    )
    print([r["range"].date().isoformat() for r in weeks.to_arrow().to_pylist()])
```

Output:

<!-- include expected_output.txt -->
```text
2024-01-01 0
2024-01-02 2
2024-01-03 1
2024-01-04 0
2024-01-05 0
2024-01-06 1
2024-01-07 0
['2024-01-01', '2024-01-08', '2024-01-15', '2024-01-22', '2024-01-29']
```

## Notes

- `generate_series(start, stop, step)` includes `stop`; `range(start, stop, step)` stops before it. Both follow DuckDB's table functions of the same names.
- Over dates and timestamps the step is an `INTERVAL` literal: `YEAR`, `MONTH`, `WEEK`, `DAY`, `HOUR`, `MINUTE` or `SECOND`, positive or negative. A date series is a `TIMESTAMP` column (midnight of each day), as in DuckDB, so the example prints `.date()`.
- A month step keeps the day of the month where it can and moves it to the last day of a shorter month, and it does not move back: from `2024-01-31` by one month gives 01-31, 02-29, 03-29, 04-29.
- Over integers the step defaults to 1, and `generate_series(n)` / `range(n)` start at 0. Any series can be negative.
- A step pointing away from `stop` gives no rows, and so does a NULL argument. A step of 0 is refused (`interval cannot be 0!`), as DuckDB refuses it.
- The arguments are literals. A column as an argument (DuckDB's lateral form, one series per row) is refused by name.
- The series column is named `generate_series` or `range`; `AS t(d)` names it `d`.
- A `DATE` column joins with the series' `TIMESTAMP` at midnight, as in the example, and so do two `DATE` or two `TIMESTAMP` columns.
- There is no frame form yet: the pandas-shaped frame has no `reindex`, `asfreq` or `resample`, and the polars-shaped `komira.pl` has no `upsample`. Use the SQL form.

## Related

- [How do I resample a time series to daily, weekly or monthly?](../38-resample-time-series-daily-weekly-monthly/page.md) (rank 38, partial)
- [How do I group by month or week?](../80-group-month-week/page.md) (rank 80, partial)
- [How do I left join and keep unmatched rows?](../36-left-join-keep-unmatched-rows/page.md) (rank 36, works)

- **A date column plus an interval or a number of days.** `Session.sql` accepts
  `d + INTERVAL '7' DAY`, `INTERVAL '1' MONTH + d`, `d - INTERVAL '1' YEAR`,
  `date_add(d, INTERVAL '2' DAY)` (units day, week, month and year) and `d + 7`,
  `7 + d`, `d - 7` for a date column `d`, as DuckDB answers them: the interval
  forms give a timestamp at midnight, the integer forms give a date, a month or a
  year keeps the day of the month or takes the month's last day (`2024-01-31 + INTERVAL '1' MONTH`
  is `2024-02-29`), and a NULL date stays NULL. An `INTERVAL` whose count is a
  column is refused as a non-constant interval.

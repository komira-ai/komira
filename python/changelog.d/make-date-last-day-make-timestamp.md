- **Building dates and timestamps from their parts.** `Session.sql` runs `make_date(year, month, day)`,
  `last_day(date)` and the six-argument `make_timestamp(year, month, day, hour, minute, seconds)`,
  with DuckDB's answers: a February 29 only in a leap year, an hour of 24 only at midnight, seconds
  rounded to the microsecond, and a NULL argument giving NULL. Before, `sql` refused all three by
  name. An invalid constant argument, such as `make_date(2029, 2, 29)`, raises `BindError` with
  DuckDB's message; a column holding an invalid row raises `KomiraError` when the query runs. A call
  over columns inside a `WHERE` is still refused, by the filter.

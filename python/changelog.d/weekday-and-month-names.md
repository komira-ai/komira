- **Weekday and month names.** `s.dt.day_name()` and `s.dt.month_name()` of a date or timestamp
  column give the English name of each value's weekday (`'Monday'`) and month (`'October'`) as a
  string column, and the SQL functions `dayname(d)` and `monthname(d)` give the same names, as
  DuckDB does. A missing value gives a missing name, and a timestamp names the day of its date.
  `locale=` is refused: the names are English only.

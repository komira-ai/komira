- **Resampling a time series.** `df.resample(rule, on=column)` buckets the rows of the
  pandas-shaped frame by the day (`"D"`), the week from Monday to Sunday labelled by its Sunday
  (`"W"`, pandas' `"W-SUN"`), or the month labelled by its first (`"MS"`) or last (`"ME"`, `"M"`)
  day of a date or timestamp column, and gives a `GroupBy` by the bucket, which keeps the column's
  name: `df.resample("MS", on="sold_on")["amount"].sum()`. Each bucket is the engine's
  `date_trunc`. A row with no date is left out; a bucket with no rows has no row, and the answer
  has no row order. Other rules, `closed` and `label` other than pandas' default, `origin`,
  `offset` and a time zone raise `UnsupportedOperation`, and so do `.dt.floor("W")` and the other
  calendar rules, as pandas refuses them. In `komira.pl`, `Expr.dt` (an `ExprDateTimeNameSpace`)
  has `truncate(every)` for `"1d"`, `"1w"` and `"1mo"`, and `LazyFrame.group_by_dynamic(index,
  every=..., group_by=None)` groups by that truncation with polars' default windows.

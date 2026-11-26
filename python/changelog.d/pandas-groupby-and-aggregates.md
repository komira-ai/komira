- **Group-by and aggregates in the pandas-shaped DataFrame.** `df.groupby(by, *, sort=True,
  dropna=True)` gives a `komira.GroupBy` whose `agg(...)`, `sum`, `mean`, `median`, `std`, `var`,
  `min`, `max`, `count`, `size` and `nunique` return a frame of the keys and one column per output,
  sorted by the keys unless `sort=False`, with the rows of a missing key left out unless
  `dropna=False`. `df.agg(...)` and the frame's `sum`, `mean`, `median`, `std`, `var`, `min`, `max`,
  `count` and `nunique` give a one-row frame. `aggregate` is another name for `agg`, on the frame and on the `GroupBy`. A
  sum of nothing is 0, as in pandas.
  `df.drop_duplicates()` keeps one of each set of equal rows, or with `keep=False` only the rows no
  other row equals. Each builds an aggregate or distinct node of the plan, run with no SQL. The engine
  refuses at `materialize()` what it does not compute yet: `median`, `std` and `var`, a grouped sum
  or mean of a float column, the mean of a boolean column, and `min`, `max` or `nunique` of a column type it does not fold.

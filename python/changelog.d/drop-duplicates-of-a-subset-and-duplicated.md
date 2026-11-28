- **Duplicates by some columns.** `df.drop_duplicates(subset=[...])` over fewer than every column
  keeps one whole row for each value of the named columns, and `keep=False` keeps the rows whose
  value no other row has. `df.duplicated(subset=None, keep="first")` is a bool Series of the frame,
  true for every row of a value but one (every row of a repeated value with `keep=False`), for a
  filter or `assign`. A plan has no row order, so `keep="first"` and
  `keep="last"` keep any one row of each value, not the first or the last as pandas does. Both are
  built with a window, so a subset column must be int64, int32, float64, bool or string; another
  type is refused when the plan runs (`LOWERING_WINDOW_UNSERVED`). `Series.unique()` is refused by
  name: it gives an array of values in pandas; use `df[[column]].drop_duplicates()`.

- **`DataFrame.explode` and `LazyFrame.explode`.** `df.explode("tags")` (and `komira.pl`'s
  `lf.explode("tags")`) replaces a list column by one row per element, the other columns repeating.
  A row whose list is empty or NULL gives one row holding NULL, as pandas and polars do. One column,
  given by its name, is supported: a list of columns is refused by name, and so is a column that is
  not a list. `ignore_index` is accepted and does nothing, since a frame has no index. The frame keeps
  its row order unless it is sorted by the exploded column.

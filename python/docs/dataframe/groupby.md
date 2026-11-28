# Group-by and aggregates

```python
by_id = df.groupby("id").agg(total=("value", "sum"), n=("value", "size"))
print(by_id.columns)                      # ['id', 'total', 'n']
stats = df[["value"]].median()            # one row, the column value
```

- **`df.groupby(by, *, sort=True, dropna=True)`** gives a `komira.GroupBy`.
  Its reductions return a frame whose columns are the keys, then one column
  per output: a komira frame has no index, so the keys are columns
  (`as_index` is accepted and changes nothing). `sort=True` sorts the answer
  by the keys, missing keys last; `sort=False` promises no row order.
  `dropna=True` leaves out the rows with a missing key; `dropna=False` keeps
  their group. `gb["v"]` and `gb[["v", "w"]]` choose the columns to reduce.
- **Reductions.** `sum`, `mean`, `median`, `std` and `var` (`ddof=1`, the sample
  one and the default, or `ddof=0`, the population one), `min`,
  `max`, `count` (values that are not missing), `nunique` (distinct values
  that are not missing) and, on a GroupBy, `size` (rows, the column `size`).
  `sum`, `mean`, `median`, `std` and `var` need numeric or boolean columns
  (`numeric_only=True` leaves the others out); a boolean counts True as 1. A
  sum of nothing is 0 (`min_count=1` makes it missing), as in pandas.
- **`agg`.** Named outputs, `agg(total=("v", "sum"))`; a dict of column to
  reduction, each output named after its column; one reduction's name; and on
  one chosen column, `gb["v"].agg(["sum", "mean"])` or `gb["v"].agg(t="sum")`.
- **The frame's own reductions.** `df.agg(...)`, `df.sum()` and the others
  reduce every column to a one-row frame, where pandas gives a Series: like
  every verb they are lazy, and the number comes from `materialize()`.
- **Refused by name** with `UnsupportedOperation`: a Python function in
  `agg`, `first`, `last` and the other choices by row order, `ddof` other
  than 0 or 1, `skipna=False`, `nunique(dropna=False)` and `axis=1`. A missing
  value is NULL: unlike pandas, a NaN in a float column is a value in these
  reductions, not a missing one ([`fillna` and `dropna`](missing_values.md)
  (newer than 0.1.1623) do read it as missing).

Which reductions the engine computes today is on
[its own page](aggregates_engine.md); [drop_duplicates](drop_duplicates.md)
has one too. Back to [the DataFrame overview](overview.md).

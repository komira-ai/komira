# Windows

```python
by_day = orders.sort_values("day")
by_day["running"] = by_day.groupby("id")["value"].cumsum()
orders["share"] = orders["value"] / orders.groupby("id")["value"].transform("sum")
above = orders[orders["value"] > orders.groupby("id")["value"].transform("mean")]
```

A window gives one value per row, as a `Series` of the frame, to assign or to
filter by, alone or in an expression:

- **`df.groupby(k)["c"].transform(f)`**, `f` one of `"sum"`, `"mean"`,
  `"min"`, `"max"`, `"count"`: the row's group reduced; an empty sum is 0.
- On a sorted frame ([row order](row_order.md)), **`cumsum()`, `cummin()` and
  `cummax()`** of a column or of `df.groupby(k)["c"]`, in the sort's order
  (missing values first or last as the sort put them), and
  **`rolling(n, min_periods=None)`** with `sum()`, `mean()`, `min()` and
  `max()` (float64; missing when fewer than `min_periods`, by default `n`, of
  the window's rows hold a value).
- **`rank(method="min")` or `rank(method="dense")`** of a column or of a
  group's column, as float64, a missing value's rank missing
  (`na_option="keep"`), last (`"bottom"`) or first (`"top"`).

Under `groupby(dropna=True)` a row whose key is missing gets a missing value.
A GroupBy (and a Series) taken before `df["x"] = ...` changed the frame is
stale, so take `df.groupby(k)["c"]` again for each window you set, and set a
window of a sorted frame on that sorted frame, not on the frame it was sorted
from.

**Refused by name** with `UnsupportedOperation`: a running or rolling window
of a frame that is not sorted; pandas' default `rank(method="average")`, and
`"max"` and `"first"`; `rank(pct=True)`; a centred or time-based `rolling`; a
Python function in `transform`.

Back to [the DataFrame overview](overview.md).

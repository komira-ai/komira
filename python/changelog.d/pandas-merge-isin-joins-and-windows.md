- **Joins and windows in the pandas-shaped DataFrame.** `df.merge(other, how=..., on=... |
  left_on=..., right_on=..., sort=False, suffixes=("_x", "_y"))` joins two frames of one session
  (`how` "inner", "left", "right", "outer" or "cross"), naming the columns as pandas does.
  `df[df["k"].isin(other["k"])]` is a semi join and `df[~df["k"].isin(other["k"])]` an anti join.
  `df.groupby(k)["c"].transform("sum" | "mean" | "min" | "max" | "count")`, and on a sorted frame
  `cumsum`, `cummin`, `cummax` and `rolling(n, min_periods=None)` with `sum`, `mean`, `min` and
  `max`, and `rank(method="min" | "dense", na_option="keep" | "bottom" | "top")` give a `Series` of
  the frame to assign or filter by, alone or in an expression. Each builds join and window nodes of
  the plan, run with no SQL. Unlike pandas, a missing key matches nothing. Refused by name: `merge`
  on the index, `indicator`, `validate`, and the anti `how`s (use `~isin`); a running or rolling
  window of an unsorted frame; `rank(method="average")` (pandas' default), `"max"` and `"first"`.

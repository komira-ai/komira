- **shift, diff and pct_change.** On a sorted pandas-shaped frame, `Series.shift(periods=1)` gives
  the value `periods` rows before (after, when negative), missing where there is no such row;
  `Series.diff(periods=1)` is `s - s.shift(periods)` and `Series.pct_change(periods=1)` is
  `s / s.shift(periods) - 1`, both float64 as pandas gives them, with pandas' inf, -inf or NaN over
  a previous value of 0. In `komira.pl`, `Expr.shift(n=1)` and `Expr.diff(n=1, null_behavior="ignore")`
  read the frame's sort or `over(order_by=...)` and keep the column's type. Each is a LAG or LEAD
  window of the plan, run with no SQL. Refused by name: an unsorted frame, `fill_value`, `freq`,
  `suffix`, `fill_method`, `null_behavior="drop"`, and the verbs over every column of a frame.

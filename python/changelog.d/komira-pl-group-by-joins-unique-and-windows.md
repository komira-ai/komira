- **komira.pl: group-by, joins, unique and windows.** `lf.group_by(keys).agg(...)` (and `len`,
  `sum`, `mean`, `median`, `min`, `max`, `n_unique`) gives one row per group, the null key a group
  of its own. `lf.join(other, on=..., how=...)` takes every `how` polars has (`inner`, `left`,
  `right`, `full`, `semi`, `anti`, `cross`), `left_on`/`right_on`, `suffix` and `coalesce`, and
  gives polars' output columns. `lf.unique(subset=None, keep="any"|"none")` keeps one row per
  value, or only the rows no other row shares. `expr.over(keys, order_by=...)` computes an
  expression per partition; an aggregate beside row-wise values in `select`, `with_columns` or
  `filter` is broadcast over the rows, as in polars. `rank` (`"average"`, `"min"`, `"max"`,
  `"dense"`), `cum_sum`, `cum_count`, `cum_min`, `cum_max` and `rolling_sum`, `rolling_mean`,
  `rolling_min`, `rolling_max` (with `min_samples`) read the frame's sort or `over(order_by=...)`.
  Each builds plan nodes (an aggregate, a join, a distinct, a window) run with no SQL. Refused by
  name: anything that needs row order the plan does not have (`maintain_order=True`,
  `keep="first"`/`"last"`, `rank("ordinal")`, a running or rolling window of an unsorted frame
  without `order_by`), `nulls_equal=True`, and a key that is an expression. A rank, `len()` and
  `cum_count()` are Int64 where polars gives UInt32. The engine refuses when the query runs what it
  does not compute yet, such as a grouped sum or mean of a float column.

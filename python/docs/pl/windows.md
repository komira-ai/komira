# komira.pl: windows

`expr.over(keys, order_by=...)` computes an expression per partition; an
aggregate beside row-wise values in `select`, `with_columns` or `filter` is
broadcast over the rows, as in polars. `rank` (`"average"`, `"min"`, `"max"`,
`"dense"`), `cum_sum`, `cum_count`, `cum_min`, `cum_max` and `rolling_sum`,
`rolling_mean`, `rolling_min`, `rolling_max` (with `min_samples`) read the
frame's sort or `over(order_by=...)`.

Each builds a window node run with no SQL. Refused by name: `rank("ordinal")`,
a running or rolling window of an unsorted frame without `order_by`, and a
window of a window. A rank and `cum_count()` are Int64 where polars gives
UInt32.

Back to [expressions](expressions.md).

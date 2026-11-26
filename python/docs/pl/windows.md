# komira.pl: windows

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`expr.over(keys, order_by=...)` computes an expression per partition; an
aggregate beside row-wise values in `select`, `with_columns` or `filter` is
broadcast over the rows, as in polars. `rank` (`"average"`, `"min"`, `"max"`,
`"dense"`), `cum_sum`, `cum_count`, `cum_min`, `cum_max` and `rolling_sum`,
`rolling_mean`, `rolling_min`, `rolling_max` (with `min_samples`) read the
frame's sort or `over(order_by=...)`.

Each builds a window node run with no SQL. Refused by name: `rank("ordinal")`,
a running or rolling window of an unsorted frame without `order_by`, and a
window of a window. `rank()` (but for `"average"`, a Float64) and
`cum_count()` are Int64 where polars gives UInt32 (see
[count types](expressions.md)).

Back to [expressions](expressions.md).

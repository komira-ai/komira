# komira.pl: windows

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`expr.over(keys, order_by=...)` computes an expression per partition; an
aggregate beside row-wise values in `select`, `with_columns` or `filter` is
broadcast over the rows, as in polars. `rank` (`"average"`, `"min"`, `"max"`,
`"dense"`), `cum_sum`, `cum_count`, `cum_min`, `cum_max` and `rolling_sum`,
`rolling_mean`, `rolling_min`, `rolling_max` (with `min_samples`), `shift(n)`
and `diff(n)` read the frame's sort or `over(order_by=...)`. `shift` and
`diff` keep the column's type, null where there is no row `n` before (or
after, for a negative `n`).

Each builds a window node run with no SQL. Refused by name: `rank("ordinal")`,
a running, rolling or shifted window of an unsorted frame without `order_by`,
a window of a window, `shift(fill_value=...)`, `diff(null_behavior="drop")`,
and `shift` or `diff` of a column type the windows do not read (a bool, an
unsigned integer, a date or time; `diff` of a string). `rank()` (but for `"average"`, a Float64) and
`cum_count()` are Int64 where polars gives UInt32 (see
[count types](expressions.md)).

Back to [expressions](expressions.md).

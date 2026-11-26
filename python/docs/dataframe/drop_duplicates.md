# drop_duplicates

`df.drop_duplicates()` keeps one of each set of equal rows (`keep="first"` and
`"last"` give the same rows); `keep=False` keeps only the rows no other row
equals. `subset` must name every column: to keep one row per value of some
columns, select those columns first. The answer has no row order.

Back to [the DataFrame overview](overview.md).

# drop_duplicates

`df.drop_duplicates()` keeps one of each set of equal rows (`keep="first"` and
`"last"` give the same rows); `keep=False` keeps only the rows no other row
equals. The answer has no row order.

`df.drop_duplicates(subset=["name"])` compares only the named columns and keeps
one whole row for each value of them. A plan has no row order, so with
`keep="first"` or `keep="last"` the row kept is any one of the rows of that
value, not the first or the last as in pandas; sort the answer, not the input.
`keep=False` keeps only the rows whose value no other row has. A NULL is a
value of its own. The subset is built with a window (`ROW_NUMBER` or a count
per value), so its columns must be of a type the engine's window sorts (int64,
int32, float64, bool, string); another is refused when the plan runs.

`df.duplicated(subset, keep)` is a bool Series of the same frame: true for every
row of a value but one (`keep="first"` or `"last"`, the one left false being any
of them) or for every row of a value more than one row has (`keep=False`). Use
it in a filter or `assign`, as `df[df.duplicated("name", keep=False)]`.

`s.unique()` of a Series is refused: it gives an array of values in pandas,
which needs the rows. Select the column as a frame instead,
`df[["name"]].drop_duplicates()`.

Back to [the DataFrame overview](overview.md).

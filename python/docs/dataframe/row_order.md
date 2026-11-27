# Row order

A frame that was not sorted promises no row order, so `head(n)` on it gives
some `n` rows. After `sort_values`, a filter, a projection that keeps the sort
columns, an `assign`, `fillna`, `replace`, `rename` or `astype` (newer than
0.1.1623) that changes none of them, `dropna` (newer than 0.1.1623), `head`, `tail` (newer
than 0.1.1623) and the semi and anti joins of
[`isin` with another frame](merge.md) (newer than 0.1.1623) keep the order;
`merge` (newer than 0.1.1623) gives an unordered frame unless `sort=True`.
`tail(n)` of a frame that was not sorted, or of a `head`, raises
`UnsupportedOperation` (newer than 0.1.1623).

Back to [the DataFrame overview](overview.md).

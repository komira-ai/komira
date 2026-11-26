# Row order

A frame that was not sorted promises no row order, so `head(n)` on it gives
some `n` rows. After `sort_values`, a filter, a projection that keeps the sort
columns, an `assign`, `fillna`, `rename` or `astype` that changes none of them,
`dropna`, `head` and `tail` keep the order. `tail(n)` of a frame that was not
sorted, or of a `head`, raises `UnsupportedOperation`.

Back to [the DataFrame overview](overview.md).

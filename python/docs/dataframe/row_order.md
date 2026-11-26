# Row order

A frame that was not sorted promises no row order, so `head(n)` on it gives
some `n` rows. After `sort_values`, a filter, a projection that keeps the
sort columns, an `assign` that replaces none of them and `head` keep the
order.

Back to [the DataFrame overview](overview.md).

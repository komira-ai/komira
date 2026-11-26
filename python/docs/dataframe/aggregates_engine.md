# What the engine runs today

The engine's aggregation computes `sum`, `mean`, `min`, `max`, `count`, `size`
and `nunique`. With a group key, `sum` takes integer and boolean columns and
`mean` integer ones, neither float ones. `min` and `max` take numbers. `nunique` takes
numbers and strings. A reduction outside that (`median`, `std`, `var`, a
grouped float sum, the `mean` of a boolean column, the `min` of a string, ...)
builds its plan and is refused at `materialize()` with a `KomiraError` naming
the engine's step. It runs with no change here once the engine computes it.

The reductions are on [the group-by page](groupby.md).

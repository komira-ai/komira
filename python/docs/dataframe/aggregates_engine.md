# What the engine runs today

The engine's aggregation computes `sum`, `mean`, `min`, `max`, `count`, `size`
and `nunique`, with or without a group key. `sum` and `mean` take integer,
float and boolean columns (float ones with a group key newer than 0.1.1623).
`min` and `max` take numbers. `nunique` takes
numbers and strings. A reduction outside that (`median`, `std`, `var`, the
`min` of a string, the `max` of a boolean, ...)
builds its plan and is refused at `materialize()` with a `KomiraError` naming
the engine's step. It runs with no change here once the engine computes it.

The reductions are on [the group-by page](groupby.md).

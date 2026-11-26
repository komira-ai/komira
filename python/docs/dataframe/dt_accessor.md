# The `.dt` accessor

`s.dt`, on a timestamp or a date column: `year`, `quarter`, `month`, `day`,
`dayofweek` (Monday is 0) and `dayofyear`; of a timestamp also `hour`,
`minute`, `second`, `microsecond` and `floor(freq)` to one unit (`"D"`, `"h"`,
`"min"`, `"s"`, `"ms"`, `"us"`). Each field is int64.

Back to [the DataFrame overview](overview.md).

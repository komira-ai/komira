# The `.dt` accessor

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`s.dt`, on a timestamp or a date column: `year`, `quarter`, `month`, `day`,
`dayofweek` (Monday is 0) and `dayofyear`; of a timestamp also `hour`,
`minute`, `second`, `microsecond` and `floor(freq)` to one unit (`"D"`, `"h"`,
`"min"`, `"s"`, `"ms"`, `"us"`). Each field is int64. A week or a month has no
fixed length, and `floor("W")`, `floor("MS")` and `floor("ME")` are refused,
as pandas refuses them: bucket by week or month with
[`df.resample(rule, on=column)`](groupby.md#resample).

Back to [the DataFrame overview](overview.md).

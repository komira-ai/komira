# The `.dt` accessor

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`s.dt`, on a timestamp or a date column: `year`, `quarter`, `month`, `day`,
`dayofweek` (Monday is 0) and `dayofyear`; of a timestamp also `hour`,
`minute`, `second`, `microsecond` and `floor(freq)` to one unit (`"D"`, `"h"`,
`"min"`, `"s"`, `"ms"`, `"us"`). Each field is int64.

`s.dt.day_name()` and `s.dt.month_name()`, on a timestamp or a date column,
are the English name of each value's weekday (`"Monday"` .. `"Sunday"`) and
month (`"January"` .. `"December"`), as a string column; a missing value gives
a missing name, and a timestamp names the day of its date. `locale=` is
refused: the names are English only.

Back to [the DataFrame overview](overview.md).

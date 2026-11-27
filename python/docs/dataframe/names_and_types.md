# Names and types

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`df.rename(columns={...})` (a dict or a function of the name; a name the frame
does not have is skipped unless `errors="raise"`), `df.add_prefix(p)` and
`df.add_suffix(s)` rename columns.

`df.astype(dtype)` or `df.astype({"col": dtype})` casts, `dtype` a pyarrow type
or a name (`int64`, `float64`, `string`, `date32`, ..., and pandas' `"Int64"`,
`"boolean"`, `"str"`, or `int`, `float`, `bool`, `str`); a cast the engine does
not run (to `bool`, or a timestamp or a date to a string) is refused at
`materialize()`. A Series casts the same way with `s.astype(dtype)`.

Back to [the DataFrame overview](overview.md).

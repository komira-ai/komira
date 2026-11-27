# The `.str` accessor

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`s.str`, on a string column: `lower`, `upper`, `len`, `startswith`,
`endswith`, `contains` (a regular expression unless `regex=False`, and
`case=False`), `match`, `fullmatch`, `replace` (every occurrence, literal
unless `regex=True`), `slice(start, stop)` with bounds of 0 or more, `pad`
(never cuts a longer string) and `extract(pat, expand=False)` of one group (a
string that does not match gives `''`, where pandas gives NaN).

A regular expression over a computed Series (`s.str.lower().str.contains(p)`)
is refused at `materialize()` today: assign the computed column first. `strip`
and the others pandas has are refused by name.

Back to [the DataFrame overview](overview.md).

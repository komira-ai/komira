# The `.str` accessor

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`s.str`, on a string column: `lower`, `upper`, `len`, `strip`, `lstrip`,
`rstrip`, `startswith`,
`endswith`, `contains` (a regular expression unless `regex=False`, and
`case=False`), `match`, `fullmatch`, `replace` (every occurrence, literal
unless `regex=True`), `slice(start, stop)` with bounds of 0 or more, `pad`
(never cuts a longer string) and `extract(pat, expand=False)` of one group (a
string that does not match gives `''`, where pandas gives NaN).

A regular expression over a computed Series (`s.str.lower().str.contains(p)`)
is refused at `materialize()` today: assign the computed column first. The
other methods pandas has are refused by name.

`strip()`, `lstrip()` and `rstrip()` with no argument remove what Python's
`str.strip()` removes: a space, a tab, a newline, a non-breaking space and the
other Unicode whitespace. `to_strip="xy"` removes any of the characters `x` and
`y`: it is a set, not a prefix. SQL `trim(s)` removes spaces only, as DuckDB's
does, and `trim(s, chars)` removes the characters of `chars`.

Back to [the DataFrame overview](overview.md).

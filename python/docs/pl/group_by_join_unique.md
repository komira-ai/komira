# komira.pl: group-by, joins and unique

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

- **`lf.group_by(keys)`** gives a `LazyGroupBy`: `agg(...)`, `len`, `sum`,
  `mean`, `median`, `min`, `max` and `n_unique` give one row per group, the
  null key a group of its own.
- **`lf.join(other, on=..., how=...)`** takes every `how` polars has (`inner`,
  `left`, `right`, `full`, `semi`, `anti`, `cross`), `left_on`/`right_on`,
  `suffix` and `coalesce`, and gives polars' output columns.
- **`lf.unique(subset=None, keep="any"|"none")`** keeps one row per value, or
  only the rows no other row shares.

Each builds plan nodes (an aggregate, a join, a distinct) run with no SQL.
Refused by name: what needs row order the plan does not have
(`maintain_order=True`, `keep="first"`/`"last"`), `nulls_equal=True`, a key
that is an expression, and a join of keys of two types. `len()` is Int64 where
polars gives UInt32. The engine refuses when the query runs what it does not
compute yet, such as a grouped sum or mean of a float column.

Back to [lazy frames](frames.md).

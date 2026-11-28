# komira.pl: group-by, joins and unique

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

- **`lf.group_by(keys)`** gives a `LazyGroupBy`: `agg(...)`, `len`, `sum`,
  `mean`, `median`, `min`, `max` and `n_unique` give one row per group, the
  null key a group of its own.
- **`lf.group_by_dynamic(index, every=..., group_by=None)`** gives a
  `LazyGroupBy` by the window of the Date or Datetime column `index`: the
  day (`"1d"`), the week from Monday (`"1w"`) or the month (`"1mo"`), each
  named by its start, `col(index).dt.truncate(every)`, after the `group_by`
  keys. Only polars' default windows are built (`closed="left"`,
  `label="left"`, `start_by="window"`, `period` equal to `every`, no
  `offset`). The index need not be sorted; the windows come out in no order,
  a row whose index is null is in no window (polars needs the index sorted
  and its nulls dropped first), and a window with no rows has no row.
- **`lf.join(other, on=..., how=...)`** takes every `how` polars has (`inner`,
  `left`, `right`, `full`, `semi`, `anti`, `cross`), `left_on`/`right_on`,
  `suffix` and `coalesce`, and gives polars' output columns.
- **`lf.unique(subset=None, keep="any"|"none")`** keeps one row per value, or
  only the rows no other row shares.

Each builds plan nodes (an aggregate, a join, a distinct) run with no SQL.
Refused by name: what needs row order the plan does not have
(`maintain_order=True`, `keep="first"`/`"last"`), `nulls_equal=True`, a key
that is an expression, and a join of keys of two types. `len()`, `count()`
and `n_unique()` are Int64 where polars gives UInt32 (see
[count types](expressions.md)). The engine refuses when the query runs what
it does not compute yet, such as a grouped sum or mean of a float column.

Back to [lazy frames](frames.md).

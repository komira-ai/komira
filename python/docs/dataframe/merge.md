# merge, and isin with another frame

```python
orders = komira.read_parquet("orders.parquet")
people = komira.read_parquet("people.parquet")
joined = orders.merge(people, on="id", how="left")            # suffixes _x, _y
known = orders[orders["id"].isin(people["id"])]               # a semi join
unknown = orders[~orders["id"].isin(people["id"])]            # an anti join
```

- **`df.merge(other, how="inner", on=None, left_on=None, right_on=None, sort=False,
  suffixes=("_x", "_y"))`** joins two frames of one session: `how` is
  `"inner"`, `"left"`, `"right"`, `"outer"` or `"cross"`, and with no keys
  named the columns both frames have are the keys. The answer has the left
  frame's columns, then the right one's, as pandas names them: a key named
  alike on both sides once (for `"outer"`, the value of the side that has
  one), every other shared name suffixed. It has no row order; `sort=True`
  sorts it by the keys. Unlike pandas, a missing key matches nothing, not
  another missing key.
- **`df[df["k"].isin(other["k"])]`** keeps the rows whose `k` is a value of
  `other["k"]` (a semi join), and `df[~df["k"].isin(other["k"])]` the others
  (an anti join), `other` being this frame or another of its session. A
  sorted frame stays sorted. That form is a condition of `df[...]` alone: it
  cannot be combined with `&` or `|` or assigned. A row whose key is missing
  is never in, so `~isin` keeps it.
- **Refused by name** with `UnsupportedOperation`: `merge` with the index
  (`left_index`, `right_index`), `indicator`, `validate`, `how="left_anti"`,
  `"right_anti"`, `"semi"` and `"anti"` (use `isin`), `sort=True` with keys
  named differently on the two sides, and frames of two sessions.

Back to [the DataFrame overview](overview.md).

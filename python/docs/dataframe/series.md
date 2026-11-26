# Series

Comparisons, `+ - * /` (true division, as Python's), unary `-`,
`& | ~` over boolean Series, `isin([...])` with at most 64 values, `dtype`
and `astype(dtype)` ([names and types](names_and_types.md)). The
[`.str`](str_accessor.md) and [`.dt`](dt_accessor.md) accessors have pages of
their own. A Series works only in its own frame's verbs: one of another frame,
or one taken before `df["x"] = ...` changed its frame, raises
`UnsupportedOperation`.

`s.value_counts()` is refused by name: pandas gives a Series indexed by the
values, and a komira Series has no index. Count the rows per value with
`df.groupby(column).size()`, and sort them with
`sort_values("size", ascending=False)`.

Back to [the DataFrame overview](overview.md).

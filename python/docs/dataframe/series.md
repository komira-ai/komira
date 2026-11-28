# Series

Comparisons, `+ - * /` (true division, as Python's), unary `-`,
`& | ~` over boolean Series, `isna()` and `notna()` (and `isnull()`,
`notnull()`, newer than 0.1.1623; [missing values](missing_values.md)), `isin([...])` with at most 64 values (and
`isin(other["k"])`, a [semi join](merge.md), newer than 0.1.1623), the
[window verbs](windows.md) (newer than 0.1.1623), `dtype` and `astype(dtype)`
(newer than 0.1.1623) ([names and types](names_and_types.md)). The
[`.str`](str_accessor.md) and [`.dt`](dt_accessor.md) accessors (newer than
0.1.1623) have pages of their own. A Series works only in its own frame's verbs
(`isin(other["k"])` aside, newer than 0.1.1623): one of another frame,
or one taken before `df["x"] = ...` changed its frame, raises
`UnsupportedOperation`.

`s.round(decimals=0)` rounds an int or float column (int8 to int64, float32,
float64) to `decimals` places, halves to even as pandas does: `2.5` becomes
`2.0` and `0.5` becomes `0.0`, while SQL's `round(x, d)` rounds halves away
from zero (`round(2.5)` is 3). A negative `decimals` rounds left of the point
(`round(-2)` of 1250 is 1200, and SQL's gives 1300), and an int column is
unchanged for `decimals >= 0`. The result has the column's type. `decimals` is
an int within int32. A decimal, unsigned, string or other column, and the
`*args` and `**kwargs` pandas ignores, are refused by name.

`s.value_counts()` (newer than 0.1.1623) is refused by name: pandas gives a
Series indexed by the values, and a komira Series has no index. Count the rows
per value with `df.groupby(column).size()`, and sort them with
`sort_values("size", ascending=False)`.

Back to [the DataFrame overview](overview.md).

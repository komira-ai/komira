# Series

Comparisons, `+ - * /` (true division, as Python's), unary `-`,
`& | ~` over boolean Series, `isin([...])` with at most 64 values, and
`dtype`. A Series works only in its own frame's verbs: one of another frame,
or one taken before `df["x"] = ...` changed its frame, raises
`UnsupportedOperation`.

Back to [the DataFrame overview](overview.md).

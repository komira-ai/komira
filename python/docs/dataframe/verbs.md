# Verbs

`df["x"]` is a `Series`; `df[["a", "b"]]` keeps those columns;
`df[cond]` keeps the rows where the boolean Series `cond` is true (a function
of the frame is accepted too); `df.assign(x=...)` and `df["x"] = ...` set a
column from a Series of the frame, a literal, or a function called with the
frame; `df.sort_values(by, ascending=True, na_position="last")` sorts (rows
that tie come out in any order); `df.head(n=5)` takes `n` rows; `df.copy()`.

The example that uses them is on [the overview](overview.md).

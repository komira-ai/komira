# Verbs

`df["x"]` is a `Series`; `df[["a", "b"]]` keeps those columns;
`df[cond]` keeps the rows where the boolean Series `cond` is true (a function
of the frame is accepted too); `df.assign(x=...)` and `df["x"] = ...` set a
column from a Series of the frame, a literal, or a function called with the
frame; `df.sort_values(by, ascending=True, na_position="last")` sorts (rows
that tie come out in any order); `df.head(n=5)` takes `n` rows; `df.copy()`.

Newer than 0.1.1623: `df.drop(columns=["a", "b"])`, or `df.drop(["a", "b"], axis=1)`,
keeps every other column in its order. A name the frame does not have is a
`KeyError` unless `errors="ignore"`, which skips it; a frame has no row labels
to drop, so `axis=0` and `index=` are refused.

The example that uses them is on [the overview](overview.md).

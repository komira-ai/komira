# No index, and nothing runs by accident

`len(df)`, `bool(df)`, `iter(df)` and converting a frame or a Series to an
array or an Arrow stream raise `UnsupportedOperation` naming `materialize()`.
No attribute is a column: `df.value` raises `AttributeError` saying to write
`df["value"]`, and a pandas name komira does not have (`df.loc`, `df.query`,
`komira.melt`, ...) raises `AttributeError` saying why and what to write
instead. `sort_values(inplace=True)`, a stable sort, `head(-n)` and `df[0:5]`
raise `UnsupportedOperation`.

The refusals are tabled in
[the verbs document](../../../docs/design/dataframe_surface_verbs.md).
Back to [the DataFrame overview](overview.md).

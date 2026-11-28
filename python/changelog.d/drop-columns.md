- **Dropping columns.** `df.drop(columns=["a", "b"])` and `df.drop(["a", "b"], axis=1)` on the
  pandas-shaped DataFrame keep every other column in its order; a name the frame does not have raises
  `KeyError`, and `errors="ignore"` skips it. Row labels (`axis=0`, `index=`) and `inplace=True` raise
  `UnsupportedOperation`. In SQL, `SELECT * EXCLUDE (a, b) FROM t` keeps every column but those named,
  as in DuckDB, and so does a table-qualified star, `SELECT o.* EXCLUDE (note) FROM orders AS o JOIN
  ...`, which also runs without the list; a name the star does not have, and a list that names every
  column, raise `BindError`. `* REPLACE (...)` and `* RENAME (...)` raise `ParseError` naming them.

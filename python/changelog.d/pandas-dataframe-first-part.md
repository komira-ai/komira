- **The pandas-shaped DataFrame, first part.** `komira.read_parquet(path)`, `komira.read_csv(path, *,
  sep=",", header="infer")` and `komira.read_json(path, lines=True)` make a lazy `komira.DataFrame` of
  a file, its schema read now, on the session given as `session=` or the process's default session.
  `df["x"]` (a `komira.Series`, whose `dtype` is the name of its Arrow type as the engine derives it,
  and whose `isin(values)` takes a list or tuple of at most 64 literals: a `Series` argument raises
  `UnsupportedOperation`, being a semi join), `df[["a", "b"]]`, `df[cond]`, `assign`, `df["x"] = ...`,
  `sort_values`, `head` and `copy` build a plan and run nothing; `materialize()` runs it through the
  engine's plan entry, with no SQL, and returns a `Result`; `explain()` returns the engine's text of
  the plan. `columns`, `dtypes` and `repr` run nothing. A pandas name komira does not have raises
  `AttributeError` saying what to write instead, and `len(df)` and the other conversions raise
  `UnsupportedOperation` naming `materialize()`. They need libkomira ABI 1.8.

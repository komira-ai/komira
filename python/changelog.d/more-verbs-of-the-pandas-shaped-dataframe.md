- **More verbs of the pandas-shaped DataFrame.** `df.fillna(value or {col: value})` and
  `df.dropna(how="any"|"all", subset=None)`, where a NaN in a float column is missing as NULL is;
  `df.rename(columns=dict or function, errors="ignore"|"raise")`, `df.add_prefix` and
  `df.add_suffix`; `df.astype(dtype or {col: dtype})` and `s.astype(dtype)`, a dtype being a pyarrow
  type, a name of the design's table, a pandas spelling (`"Int64"`, `"boolean"`, `"str"`) or `int`,
  `float`, `bool` and `str`; `df.tail(n)` of a sorted frame; `komira.concat(frames)` of frames with
  the same columns and types; `s.value_counts()` is refused by name, since a komira Series has no index to
  hold the values (count them with `df.groupby(column).size()`); and the `s.str`
  (`lower`, `upper`, `len`, `startswith`, `endswith`, `contains`, `match`, `fullmatch`, `replace`,
  `slice`, `pad`, `extract`) and `s.dt` (`year`, `quarter`, `month`, `day`, `hour`, `minute`,
  `second`, `microsecond`, `dayofweek`, `dayofyear`, `floor`) accessors. Each builds plan nodes and
  runs with no SQL. The engine refuses at `materialize()` a cast it does not run (to `bool`, or a
  timestamp or a date to a string) and a regular expression over a computed Series. Arguments that
  need an index or row positions (`axis=1`, `inplace=True`, `thresh=`, ...) raise
  `UnsupportedOperation` naming what to write instead; `str.strip` and the other pandas methods not
  built raise `AttributeError` saying why.

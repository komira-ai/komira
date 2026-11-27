- **Replace values of the pandas-shaped DataFrame, or turn them into null.**
  `df.replace(["N/A", "n/a", "-"], None)` and `s.replace("N/A", None)` put a NULL of the column's
  own type where a listed value was. The forms are pandas 3's: a value or a list with a value or a
  list of the same length, `{column: value}`, a dict value per column, and with no value
  `{old: new}` or `{column: {old: new}}`. Matching is exact, by the column's type, as pandas
  decides it; a replacement that would change a column's type, a bool, decimal, date or timestamp
  column a value could be in, `regex=True` and `inplace=True` raise `UnsupportedOperation` naming
  what to write instead. Each changed column is one CASE in one projection, run with no SQL.

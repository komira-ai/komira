- **`isna` and `notna` on the pandas-shaped DataFrame and Series.** `s.isna()` and `s.notna()` give a
  boolean Series, and `df.isna()` and `df.notna()` a frame of booleans with the same column names, so
  `df.isna().sum()` counts the missing values of each column, `df[df["score"].isna()]` keeps the rows
  where `score` is missing and `df.assign(has_score=df["score"].notna())` adds a column. A value is
  missing when it is NULL, or NaN in a float column, as `dropna` and `fillna` read it; the answer is
  never NULL. `isnull` and `notnull` are the same methods under pandas' other names. Each builds plan
  nodes and runs with no SQL.

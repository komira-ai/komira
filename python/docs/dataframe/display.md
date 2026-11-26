# In a notebook

A frame shows as a table of its column names over their types, and runs
nothing. A `Result` (`df.materialize()`, or `s.sql(...)`) shows its first ten
rows at most, saying when there are more, and is still unread afterwards:
`to_arrow()` and the other terminals read every row.

Back to [the DataFrame overview](overview.md).

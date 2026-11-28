- **Melt and unpivot.** `df.melt(id_vars=None, value_vars=None, var_name=None, value_name="value")`
  and `komira.melt(df, ...)` turn wide columns into long rows as pandas' `melt` does, and
  `lf.unpivot(on=None, *, index=None, variable_name=None, value_name=None)` of `komira.pl` as polars'
  `unpivot` does: the id columns, a column holding each melted column's name (`variable` by
  default) and one holding its value (`value`), every column not an id melted when none are named,
  missing values kept as rows. The plan is a union of one projection per melted column, run with no
  SQL, and the answer has no row order. Melted columns of two types (pandas would give an object
  column, polars a common type), no column to melt, `ignore_index=False`, `col_level` and a tuple
  column name raise `UnsupportedOperation`; pandas' own errors (`value_name` naming a column,
  `id_vars` naming one twice, a column the frame lacks) are raised with pandas' messages.

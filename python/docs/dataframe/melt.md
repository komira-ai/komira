# melt

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`df.melt(id_vars=None, value_vars=None, var_name=None, value_name="value")`
turns wide columns into long rows, as pandas' `melt`: the `id_vars` columns,
then `var_name` (`"variable"` when None) holding a melted column's name, then
`value_name` holding its value, one block of rows per column of `value_vars`
(every column not in `id_vars` when None). A missing value stays a row.
`komira.melt(df, ...)` is the same call.

```python
import komira

df = komira.read_csv("scores.csv")   # name, q1, q2, q3
long = df.melt(id_vars=["name"], var_name="quarter", value_name="score")
print(long.columns)                  # ['name', 'quarter', 'score']
```

The plan is a union of one projection per melted column, run with no SQL. The
answer has no row order: sort it with `sort_values`. Unlike pandas:

- the melted columns must be of one type (pandas would make an object column
  of an int and a float); cast them first with `astype`;
- `ignore_index=False` and `col_level` are refused, since a frame has no row
  index and one level of column names;
- a call with no column to melt is refused, and so is a `var_name` that is an
  id column's name or `value_name` (pandas would give two columns of one name).

The polars-shaped frame has the same verb as `lf.unpivot(on, index=...,
variable_name=..., value_name=...)` ([komira.pl](../pl/frames.md)).

Back to [the DataFrame overview](overview.md).

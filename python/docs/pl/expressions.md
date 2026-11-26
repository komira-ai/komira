# komira.pl: expressions

`Expr` has the operators, `alias`, `cast`, the null tests, `fill_null`,
`is_in`, `is_between`, `abs`, the aggregates, the [windows](windows.md) and
`.str`. Expressions are built
with `col`, `lit` and `when` (see [lazy frames](frames.md)).

**Count types.** polars answers a count as UInt32, and `komira.pl` answers
it as Int64: `len()`, `count()`, `n_unique()`, `str.len_chars()`, and
`sum()` of a boolean or a UInt32 column. The values are polars'; only the
type differs, in `schema` and in the collected frame. The engine casts to no
UInt32 yet. A program that needs polars' types casts after collecting:
`out.to_polars().with_columns(pl.col("len").cast(pl.UInt32))`.

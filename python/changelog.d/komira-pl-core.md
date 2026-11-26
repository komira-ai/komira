- **komira.pl, the polars-shaped frames (core).** `import komira.pl as kpl`: `kpl.scan_parquet`,
  `scan_ndjson` and `scan_csv` make a lazy `LazyFrame` (reading the file's schema, nothing else), and
  `select`, `with_columns`, `filter`, `sort`, `head`, `limit`, `slice`, `tail`, `top_k`, `bottom_k`,
  `drop`, `rename`, `drop_nulls` and `kpl.concat` build its plan, with `kpl.col`, `kpl.lit`,
  `kpl.when`, `kpl.len` and the expression operators (`~expr` and `expr.not_()` negate a boolean),
  `abs()`, `alias(name)` (the output name, a non-empty `str`), the null tests `is_null()` and
  `is_not_null()`, `fill_null(value)` (`strategy=` and `limit=` raise `UnsupportedOperation`), `cast`,
  `is_in`, `is_between`, aggregates (`n_unique()` counts a null as one value, as polars does, and is an
  Int64) and the `.str` functions of `kpl.ExprStringNameSpace`: `to_lowercase()`, `to_uppercase()`,
  `len_chars()`, `starts_with(prefix)`, `ends_with(suffix)` and `contains(pattern, literal=True)`, which
  refuses a regular expression. `kpl.Expr` is the class of an expression and `kpl.LazyFrame` of a
  frame, whose `width` is its number of columns and whose `collect_schema()` is `schema`. `collect()` runs the plan through the engine's plan entry, not
  through SQL, and returns a `Result`; `schema` and `explain()` run nothing. Output names and types
  follow polars 1.44.2, except that a count, `len()`, `str.len_chars()` and the sum of a boolean or a UInt32
  column are Int64 where polars gives UInt32; what the engine cannot run is refused by name (today `median()`, `std()`, `var()` and `min()` or `max()` of a string column build their
  plans and the engine refuses them when the frame is collected).

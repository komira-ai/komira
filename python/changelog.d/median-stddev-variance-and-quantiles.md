- **Median, standard deviation, variance and quantiles run.** `median`, `stddev`, `stddev_samp`,
  `stddev_pop`, `variance`, `var_samp` and `var_pop` run in SQL, grouped or not, with DuckDB's answers
  (NULLs skipped; one value gives NULL for the sample forms and 0.0 for the population ones), and so do
  `quantile_cont(x, q)` with one constant `q` from 0 to 1. `DataFrame.median`, `DataFrame.std` and
  `DataFrame.var`, their `GroupBy` forms, and the polars-shaped `Expr.median`, `Expr.std` and
  `Expr.var` run as well; `std` and `var` take `ddof=0` (the population one) beside `ddof=1`. The new
  `Series.quantile` gives one quantile of a column as a Python float, by linear interpolation, and is
  the first `Series` method that runs a query when it is called.

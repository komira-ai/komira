- **`Series.round`.** `s.round(decimals=0)` of the pandas-shaped Series rounds an int8 to int64,
  float32 or float64 column to `decimals` places, halves to even as pandas does (`2.5` becomes
  `2.0`, `0.5` becomes `0.0`), with the column's type for the result; a negative `decimals` rounds
  left of the point (`round(-2)` of 1250 is 1200), and an int column is unchanged for
  `decimals >= 0`. `decimals` must be an int within int32. A decimal, unsigned or non-numeric
  column and any extra argument (pandas ignores numpy's) raise `UnsupportedOperation`. SQL's
  `round(x, d)` and `trunc(x, d)` take a digit count too, and round halves away from zero as DuckDB
  does. It needs a libkomira with the digit-count round.

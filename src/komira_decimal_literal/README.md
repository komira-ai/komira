# komira_decimal_literal

DECIMAL literals the way DuckDB reads and folds them. One module,
`decimal_literal`, imported by name:

- `decimal_from_literal_text(text)`: the `ScalarValue` of a literal such as
  `0.06`, `-0.5` or `100.00`. Its precision is the number of digits, the
  leading zero included, and its scale the digits after the point, so `0.06` is
  DECIMAL(3, 2) and `0.060` is DECIMAL(4, 3). A literal past 38 digits has no
  DECIMAL type here (DuckDB reads it as a DOUBLE) and gives `None`.
- `decimal_fold_binary(op, a, b)`: `a + b`, `a - b` or `a * b` for two literals
  of which at least one is a DECIMAL and the other a DECIMAL or an integer.
  An integer literal is DECIMAL(10, 0) when it fits INT32 and DECIMAL(19, 0)
  otherwise. `+` and `-` have scale max(s1, s2) and precision
  max(p1 - s1, p2 - s2) + max(s1, s2) + 1; `*` has scale s1 + s2 and precision
  p1 + p2. A result that needs more than 38 digits gives `None`: the node is
  left for the runtime, as DuckDB leaves it to a DOUBLE.
- `decimal_negate(a)`: the negation of a DECIMAL literal, same type.

The types are the ones DuckDB prints for `typeof(<expr>)`; the SQL conformance
package `komira_decimal_compare_conformance` holds DuckDB's own answers.
